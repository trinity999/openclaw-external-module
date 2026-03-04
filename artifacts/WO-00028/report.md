# WO-00028 ClickHouse Sink Worker — Design Report

**Work Order:** WO-00028
**Category:** implementation/CRITICAL
**Analyst:** openclaw-field-processor
**Date:** 2026-03-05
**Source commit:** trinity999/Pandavs-Framework@cebd2d5

---

## 1. Executive Summary

The Pandavs pipeline currently persists all scan events into SQLite (`scan_persistence.db`) via `persistence_gateway.py`. Phase 2 of PHASE_IMPLEMENTATION_PLAN.md requires a sink worker that reads unsynced events from the SQLite outbox (added by WO-00023) and delivers them to ClickHouse at `127.0.0.1:9000`. This document defines the complete production-grade ClickHouse sink worker contract: batch claim protocol, idempotent upsert key strategy, retry/backoff behavior, ledger update protocol, and replay compatibility.

The worker must satisfy three guarantees simultaneously:
1. **No loss** — every event in `sink_outbox` reaches ClickHouse exactly once or is promoted to DLQ for human review
2. **Replay safety** — running the worker multiple times on the same events must not create duplicate rows in ClickHouse
3. **Backpressure compliance** — the worker must not saturate SQLite or the network when ClickHouse is slow

---

## 2. Source Analysis

### 2.1 Event schema (persistence_gateway.py lines 72-84)

```python
events table:
  event_id    TEXT PRIMARY KEY  -- SHA-256 hash: tool|kind|asset|value|port|source_file|line_no
  tool        TEXT              -- 'dnsx', 'dig', 'httpx', 'naabu'
  event_kind  TEXT              -- 'dns_resolution', 'http_probe', 'port_open', 'raw'
  asset       TEXT              -- subdomain/host
  value       TEXT              -- resolved IP, URL, port number
  port        INTEGER
  status      TEXT
  ts          TEXT              -- ISO8601 from source file or utc_now()
  source_file TEXT
  line_no     INTEGER
  raw_json    TEXT              -- original JSON blob
```

The `event_id` SHA-256 hash is the **natural idempotency key** for ClickHouse deduplication. It is stable across reruns for the same source line.

### 2.2 Outbox schema (WO-00023 sink_outbox table)

```sql
sink_outbox:
  outbox_id       INTEGER PK AUTOINCREMENT
  event_id        TEXT NOT NULL REFERENCES events(event_id)
  sink_target     TEXT CHECK('clickhouse', 'neo4j')
  status          TEXT CHECK('PENDING', 'SYNCED', 'FAILED', 'DEAD_LETTER')
  retry_count     INTEGER DEFAULT 0
  max_retries     INTEGER DEFAULT 5
  next_retry_at   TEXT
  last_error_class    TEXT
  last_error_message  TEXT
  UNIQUE(event_id, sink_target)
```

The worker claims from `sink_outbox WHERE sink_target='clickhouse' AND status IN ('PENDING','FAILED') AND next_retry_at <= now()`.

### 2.3 ClickHouse target (DATABASE_OPS.md lines 79-114)

```
Host:     127.0.0.1:9000 (native protocol, WSL)
User:     default
Password: pandavs_ch_2026
Database: pandavs_recon
Known tables: dns_history (4.6M+ rows at time of last check)
```

Known failure patterns from DATABASE_OPS.md:
- Config directory wipe → `clickhouse-server` exits silently on start; port 9000 never opens
- `no-password.xml` + `default-password.xml` conflict → `CANNOT_LOAD_CONFIG` on startup
- Recovery: `apt-get install --reinstall clickhouse-server` regenerates configs; does NOT touch `/var/lib/clickhouse/`

### 2.4 Phase 2 acceptance criteria (PHASE_IMPLEMENTATION_PLAN.md lines 67-70)

```
- Successful test insert/read in ClickHouse and Neo4j
- Deterministic backfill from SQLite to DB with resume support
- Re-running sink does not duplicate DB records
```

---

## 3. ClickHouse Table Design

The target ClickHouse table must use a `ReplacingMergeTree` engine to support idempotent re-ingestion.

### 3.1 DDL: `pandavs_recon.scan_events`

```sql
CREATE TABLE IF NOT EXISTS pandavs_recon.scan_events
(
    event_id        String,      -- SHA-256 idempotency key from persistence_gateway
    tool            String,
    event_kind      String,
    asset           Nullable(String),
    value           Nullable(String),
    port            Nullable(Int32),
    status          Nullable(String),
    ts              DateTime64(3, 'UTC'),
    source_file     String,
    line_no         UInt32,
    raw_json        String,
    ingested_at     DateTime64(3, 'UTC') DEFAULT now64()
)
ENGINE = ReplacingMergeTree(ingested_at)
ORDER BY (event_id)
PRIMARY KEY (event_id)
SETTINGS index_granularity = 8192;
```

**Why `ReplacingMergeTree(ingested_at)`:** When the same `event_id` is inserted twice (e.g., during replay), ClickHouse keeps the version with the latest `ingested_at` and discards the older copy asynchronously during merges. Queries using `FINAL` modifier return only the latest version immediately. This is the canonical ClickHouse idempotency pattern for event streams.

### 3.2 Supporting tables

```sql
-- DNS-specific materialized view for backward compatibility with dns_history
CREATE MATERIALIZED VIEW IF NOT EXISTS pandavs_recon.dns_history_mv
TO pandavs_recon.dns_history
AS SELECT
    asset AS subdomain,
    value AS resolved_ip,
    ts    AS first_seen,
    ts    AS last_seen,
    'A'   AS record_type
FROM pandavs_recon.scan_events
WHERE event_kind = 'dns_resolution'
  AND asset IS NOT NULL
  AND value IS NOT NULL;
```

---

## 4. Worker Design

### 4.1 Worker Loop Overview

```
1. CLAIM batch from sink_outbox (BEGIN IMMEDIATE, N=500 rows)
2. FETCH corresponding events from events table
3. BATCH INSERT into ClickHouse (clickhouse-driver native protocol)
4. For each row:
   - If success → UPDATE sink_outbox status=SYNCED, INSERT event_sync_ledger
   - If ALREADY_SYNCED (ConstraintViolation or duplicate) → mark SYNCED (idempotent success)
   - If RETRYABLE error → UPDATE retry_count+1, next_retry_at=exponential_backoff, status=FAILED
   - If NON_RETRYABLE or retry_count >= max_retries → INSERT dead_letter_events, status=DEAD_LETTER
5. RELEASE claim (cleanup or commit)
6. Sleep eval_interval_s (default: 60s) before next batch
```

### 4.2 Batch Claim Protocol (SQLite)

```python
def claim_outbox_batch(conn: sqlite3.Connection, batch_size: int = 500,
                        worker_id: str = None) -> List[dict]:
    """
    Atomically claim a batch of PENDING/FAILED outbox rows for clickhouse delivery.
    Uses BEGIN IMMEDIATE to prevent double-claim with concurrent workers.
    Returns list of outbox row dicts.
    """
    now_iso = utc_now()
    conn.isolation_level = None  # manual transaction control
    conn.execute("BEGIN IMMEDIATE")
    rows = conn.execute("""
        SELECT outbox_id, event_id
        FROM sink_outbox
        WHERE sink_target = 'clickhouse'
          AND status IN ('PENDING', 'FAILED')
          AND (next_retry_at IS NULL OR next_retry_at <= :now)
        ORDER BY outbox_id ASC
        LIMIT :batch_size
    """, {"now": now_iso, "batch_size": batch_size}).fetchall()

    if not rows:
        conn.execute("ROLLBACK")
        return []

    outbox_ids = [r["outbox_id"] for r in rows]
    placeholders = ",".join("?" * len(outbox_ids))
    conn.execute(f"""
        UPDATE sink_outbox
        SET status = 'CLAIMED', updated_at = :now
        WHERE outbox_id IN ({placeholders})
    """, [now_iso] + outbox_ids)

    conn.execute("COMMIT")
    return [dict(r) for r in rows]
```

**Note:** `status='CLAIMED'` is a transient in-flight state not in the original WO-00023 schema. If the worker crashes, a reaper (equivalent to WO-00022's `reclaim_stale_leases`) must return CLAIMED rows to PENDING after a timeout (default: 600s). Add this to the `sink_outbox` DDL as an allowed status value.

**Alternative (no CLAIMED state):** Use `last_error_message = 'worker_id:<id>'` with a timestamp to track in-flight rows without schema change. Less clean but schema-compatible with WO-00023.

### 4.3 Event Fetch and Batch Build

```python
def fetch_events_for_outbox(conn: sqlite3.Connection, event_ids: List[str]) -> Dict[str, dict]:
    """Fetch event rows from SQLite for the given event_ids."""
    placeholders = ",".join("?" * len(event_ids))
    rows = conn.execute(
        f"SELECT * FROM events WHERE event_id IN ({placeholders})",
        event_ids
    ).fetchall()
    return {r["event_id"]: dict(r) for r in rows}
```

### 4.4 ClickHouse Insert (clickhouse-driver)

```python
from clickhouse_driver import Client

def build_ch_client() -> Client:
    return Client(
        host='127.0.0.1',
        port=9000,
        user='default',
        password='pandavs_ch_2026',
        database='pandavs_recon',
        settings={
            'insert_deduplicate': True,   # ClickHouse server-side dedup hint
            'connect_timeout': 10,
            'send_receive_timeout': 120,
        }
    )

def clickhouse_batch_insert(client: Client, events: List[dict]) -> Tuple[int, List[str]]:
    """
    Insert batch into scan_events. Returns (rows_inserted, failed_event_ids).
    Uses INSERT ... VALUES with native protocol for efficiency.
    Deduplication: ReplacingMergeTree on ORDER BY (event_id) handles replay.
    """
    rows = []
    for ev in events:
        rows.append({
            'event_id': ev['event_id'],
            'tool': ev['tool'],
            'event_kind': ev['event_kind'],
            'asset': ev.get('asset'),
            'value': ev.get('value'),
            'port': ev.get('port'),
            'status': ev.get('status'),
            'ts': parse_ts(ev['ts']),   # convert ISO8601 -> datetime
            'source_file': ev['source_file'],
            'line_no': ev['line_no'],
            'raw_json': ev['raw_json'],
        })
    client.execute(
        'INSERT INTO scan_events VALUES',
        rows,
        types_check=True,
    )
    return len(rows), []
```

### 4.5 Outcome Recording

```python
def record_outcomes(conn: sqlite3.Connection, outcomes: List[dict],
                    batch_id: str, taxonomy: dict) -> None:
    """
    outcomes: list of {outbox_id, event_id, outcome, error_class, error_msg, duration_ms}
    taxonomy: retry_taxonomy.json loaded as dict (from WO-00023)
    """
    now = utc_now()
    for o in outcomes:
        oid = o['outbox_id']
        eid = o['event_id']
        outcome = o['outcome']  # 'SUCCESS', 'ALREADY_SYNCED', 'RETRYABLE', 'NON_RETRYABLE'

        if outcome in ('SUCCESS', 'ALREADY_SYNCED'):
            conn.execute("""
                UPDATE sink_outbox SET status='SYNCED', synced_at=:now, updated_at=:now
                WHERE outbox_id=:oid
            """, {'now': now, 'oid': oid})
            conn.execute("""
                INSERT OR IGNORE INTO event_sync_ledger
                    (event_id, sink_target, synced_at, delivery_attempt, batch_id, rows_written, duration_ms)
                VALUES (:eid, 'clickhouse', :now, :attempt, :batch_id, 1, :dur)
            """, {'eid': eid, 'now': now, 'attempt': o.get('attempt',1),
                  'batch_id': batch_id, 'dur': o.get('duration_ms', 0)})

        elif outcome == 'RETRYABLE':
            retry_count = o['retry_count'] + 1
            max_retries = o.get('max_retries', 5)
            backoff_s = min(300 * (2 ** retry_count), 14400)  # max 4h
            next_retry = add_seconds(now, backoff_s)
            if retry_count >= max_retries:
                _promote_to_dlq(conn, o, now)
            else:
                conn.execute("""
                    UPDATE sink_outbox
                    SET status='FAILED', retry_count=:rc, next_retry_at=:nr,
                        last_error_class=:cls, last_error_message=:msg, last_failed_at=:now,
                        updated_at=:now
                    WHERE outbox_id=:oid
                """, {'rc': retry_count, 'nr': next_retry,
                      'cls': o['error_class'], 'msg': o['error_msg'],
                      'now': now, 'oid': oid})

        else:  # NON_RETRYABLE
            _promote_to_dlq(conn, o, now)
    conn.commit()
```

---

## 5. Idempotency / Replay Safety Analysis

| Scenario | Behavior |
|---|---|
| Worker inserts event, marks SYNCED, then crashes before committing SQLite update | On restart: row still shows PENDING/CLAIMED; re-inserts to ClickHouse. `ReplacingMergeTree` accepts duplicate; dedup happens at merge time. `INSERT OR IGNORE` into `event_sync_ledger` prevents duplicate ledger rows. Net: **safe** |
| Worker inserts event successfully, marks SYNCED, then same event re-queued | `UNIQUE(event_id, sink_target)` on `sink_outbox` prevents re-queuing. If bypassed: `ReplacingMergeTree` deduplication handles ClickHouse-side. Net: **safe** |
| ClickHouse returns partial success for a batch | Use per-row INSERT (or verify rows_inserted == expected); for ClickHouse native driver, batch inserts are atomic per block. If block rejected: mark all as FAILED/RETRYABLE. Net: **safe, may retry more than necessary** |
| ALREADY_SYNCED detection | ClickHouse does not raise a constraint error for duplicates on `ReplacingMergeTree`. Instead: before insert, optionally check `SELECT count() FROM scan_events FINAL WHERE event_id IN (...)`. For high-volume replay, skip this check and rely on `ReplacingMergeTree`. |

**Key insight:** Because ClickHouse's `ReplacingMergeTree` accepts all inserts and deduplicates asynchronously, the worker does NOT need per-row existence checks before inserting. This makes replay trivially safe: insert the same event_id N times and ClickHouse converges to one row. The `FINAL` modifier on reads ensures correct counts during inter-merge windows.

---

## 6. Retry / Backoff Policy

Sourced from WO-00023 `retry_taxonomy.json` (ClickHouse rules CH-R01 through CH-R11):

| Error Class | Examples | Action |
|---|---|---|
| RETRYABLE | `NETWORK_ERROR`, `TIMEOUT`, `SERVER_OVERLOADED`, `MEMORY_LIMIT_EXCEEDED` | Retry with exponential backoff; backoff_s = min(300 * 2^retry_count, 14400) |
| NON_RETRYABLE | `BAD_ARGUMENTS`, `UNKNOWN_TABLE`, `TYPE_MISMATCH`, `AUTH_FAILED` | Move to DLQ immediately |
| ALREADY_SYNCED | Duplicate key on unique table (not applicable for ReplacingMergeTree) | Mark SYNCED |

**Backoff schedule:**
- Retry 1: 300s (5 min)
- Retry 2: 600s (10 min)
- Retry 3: 1200s (20 min)
- Retry 4: 2400s (40 min)
- Retry 5: 4800s → cap at 14400s (4h) → promote to DLQ

---

## 7. Operational Integration

### 7.1 CLI entry point

```bash
# Run one sweep (process all pending outbox rows, then exit):
python3 clickhouse_sink_worker.py run-once --db state/scan_persistence.db --batch-size 500

# Continuous loop (sleep 60s between sweeps):
python3 clickhouse_sink_worker.py loop --db state/scan_persistence.db --interval 60

# Check current outbox status:
python3 clickhouse_sink_worker.py status --db state/scan_persistence.db
```

### 7.2 ClickHouse connectivity check (pre-flight)

```python
def check_clickhouse_health(client: Client) -> bool:
    try:
        result = client.execute("SELECT 1")
        return result == [(1,)]
    except Exception as e:
        log.warning(f"ClickHouse health check failed: {e}")
        return False
```

If health check fails: backoff 60s and retry (do not mark outbox rows as FAILED — connectivity issue, not event issue).

### 7.3 Throughput targets

| Metric | Target |
|---|---|
| Batch size (rows per ClickHouse insert) | 500 |
| Expected throughput | ~50k events/minute (10 batches/min × 500 rows) |
| Sink lag SLO | < 2h (from WO-00024 alert policy ALT-04) |
| Steady-state success rate | >= 99% |
| Replay duplicate rate | <= 0.1% (ReplacingMergeTree + FINAL) |

---

## 8. Design Decisions

| ID | Decision | Rationale |
|---|---|---|
| DD-1 | `ReplacingMergeTree` on `scan_events` | Simplest ClickHouse idempotency pattern; no per-row existence check needed; replay safe |
| DD-2 | `ORDER BY (event_id)` = `PRIMARY KEY (event_id)` | event_id SHA-256 is globally unique per event; enables point lookups and deduplication |
| DD-3 | Batch claim via `BEGIN IMMEDIATE` | Same pattern as WO-00022 chunk_queue; prevents double-claim without external coordination |
| DD-4 | `CLAIMED` transient status | Allows crash recovery (reaper returns stale CLAIMED rows to PENDING) without losing track of in-flight rows |
| DD-5 | clickhouse-driver native protocol (not HTTP) | Native protocol ~3-5x faster than HTTP for bulk inserts; supports streaming blocks |
| DD-6 | Per-row outcome mapping (not all-or-nothing batch) | If some events fail type validation, others in the same batch should succeed; per-row tracking improves retry precision |

---

## 9. Risks

| ID | Risk | Severity | Mitigation |
|---|---|---|---|
| R1 | ClickHouse config wipe recurrence (DATABASE_OPS.md known issue) | HIGH | Worker detects connection failure before claiming batch; does not mark rows FAILED; logs actionable runbook reference |
| R2 | `ReplacingMergeTree` dedup is asynchronous; queries during merge see duplicates | MEDIUM | Use `SELECT ... FINAL` in all integrity-check queries; document in hourly report MON-03 |
| R3 | `raw_json` TEXT field contains arbitrarily large JSON blobs | MEDIUM | Cap individual row size pre-insert (warn + truncate if > 1MB); ClickHouse has `max_query_size` limits |
| R4 | Worker and ingestion loop both write to scan_persistence.db concurrently | LOW | WAL mode already enabled; SQLite WAL supports concurrent readers + one writer; claim uses `BEGIN IMMEDIATE` |
| R5 | Backfill of 4.6M+ existing rows may saturate ClickHouse | MEDIUM | Rate-limit backfill batch: `--batch-size 500 --interval 2` (250k rows/min); allow interleaved scan data during catch-up |

---

## 10. Validation Strategy

1. **Unit**: Insert 100 events into SQLite, run worker, verify `SELECT count() FROM scan_events FINAL` = 100 in ClickHouse
2. **Idempotency**: Run worker twice; verify ClickHouse count unchanged; verify all `sync_ledger` rows have `delivery_attempt` = 1
3. **Retry**: Simulate ClickHouse DOWN; verify rows remain FAILED with retry_count increments; bring ClickHouse up; verify rows clear
4. **DLQ**: Set `max_retries=1` for one row; verify after 2 RETRYABLE failures it moves to `dead_letter_events`
5. **Throughput**: Time backfill of 4.6M rows; must complete in < 20h at 50k events/min target rate

---

## 11. KPIs

| Metric | Target |
|---|---|
| Sink write success rate (steady state) | >= 99% |
| Replay duplicate rate (ClickHouse FINAL count vs SQLite events count) | <= 0.1% |
| Sink lag (oldest PENDING/FAILED outbox age) | < 2h |
| DLQ accumulation rate | 0 (new events); DLQ drains after root cause fix |
| Worker crash recovery time (CLAIMED rows reaper) | <= 600s |

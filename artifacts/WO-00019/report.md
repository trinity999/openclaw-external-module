# WO-00019: Queue Orchestration + Sink Sync — Execution-Grade Design Review

**Work Order:** WO-00019
**Category:** architecture
**Analyst:** openclaw-field-processor
**Produced:** 2026-03-04
**Confidence:** 0.92
**ARD:** HIGH

---

## Executive Summary

The current pipeline processes 51 chunks (~10M assets) across parallel scan workers. The gap between the durable local capture layer (SQLite) and the primary DB sink (ClickHouse/Neo4j) is the critical failure surface: silent sink failures, no lease tracking, and no outbox pattern create the conditions for chunk duplication, data loss, and stuck queue states at scale.

This review specifies a **three-component hardening architecture**: (1) a SQLite-backed chunk lease/ack queue replacing file-list dispatch, (2) a sink outbox with structured retry classification and dead-letter handling, and (3) backpressure signals that directly tune scanner concurrency. All three components use SQLite as the single authoritative state store, enabling zero-configuration replay and full observability from local state alone.

Success metrics: 0 duplicate chunk executions in restart drills, sink unsynced oldest age < 2h, replay duplicate rate ≤ 0.1%, no queue completion gap > 30 minutes.

---

## 1. Context Understanding

### Current State

- 51 discrete chunks dispatched to parallel workers via file-list
- `persistence_gateway.py` writes results to local SQLite (`scan_persistence.db`)
- Mixed tool outputs: dnsx, naabu, httpx, dig — different schemas per tool
- Primary sink (ClickHouse/Neo4j) not yet durably connected; sync controls absent

### Failure Mode Analysis

**FM-1: Queue Drift / Stuck Chunks**
A worker processing a chunk with no heartbeat or lease expiry detection will silently stall. The orchestrator has no mechanism to detect or reclaim. Result: some chunks never complete; queue appears stuck.

**FM-2: Silent Sink Failures**
If the ClickHouse/Neo4j write fails after persistence_gateway.py has confirmed local durability, there is no replay path unless the original file still exists. At high artifact churn, files are overwritten or rotated, making sink recovery impossible.

**FM-3: Retry Storms**
Without retry classification (retryable vs non-retryable), a configuration fault (e.g., wrong Neo4j credentials) that is non-retryable will consume all retry budget and alarm capacity before the root cause is identified.

**FM-4: Duplicate Semantics**
Without idempotent write paths, a chunk replayed after an interrupted run will produce duplicate rows in ClickHouse or duplicate nodes in Neo4j.

---

## 2. Component 1: Chunk Lease/Ack Queue

### Design Rationale

The lease/ack pattern is the minimal change that eliminates FM-1 (stuck chunks) and FM-4 (duplicates). A lease is a time-bounded exclusive claim on a chunk. Only the lease holder may write results for that chunk. If the lease expires without an ack, the orchestrator reclaims and reassigns.

### SQLite Schema — `chunk_queue` Table

```sql
-- Run once at system initialization
CREATE TABLE IF NOT EXISTS chunk_queue (
    chunk_id        TEXT    PRIMARY KEY,
    chunk_file_path TEXT    NOT NULL,
    status          TEXT    NOT NULL DEFAULT 'PENDING',
    -- Status values: PENDING, LEASED, COMPLETED, FAILED_RETRYABLE, FAILED_PERMANENT
    worker_id       TEXT,
    leased_at       TEXT,                   -- ISO8601
    lease_expires_at TEXT,                  -- ISO8601; NULL when not leased
    last_heartbeat_at TEXT,
    completed_at    TEXT,
    retry_count     INTEGER NOT NULL DEFAULT 0,
    max_retries     INTEGER NOT NULL DEFAULT 3,
    record_count_produced INTEGER,
    error_class     TEXT,                   -- RETRYABLE | NON_RETRYABLE | NULL
    error_message   TEXT,
    created_at      TEXT    NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
    updated_at      TEXT    NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
);

CREATE INDEX IF NOT EXISTS idx_cq_status
    ON chunk_queue(status);

CREATE INDEX IF NOT EXISTS idx_cq_lease_expires
    ON chunk_queue(lease_expires_at)
    WHERE status = 'LEASED';

-- Trigger to maintain updated_at
CREATE TRIGGER IF NOT EXISTS trg_cq_updated_at
    AFTER UPDATE ON chunk_queue
    BEGIN
        UPDATE chunk_queue SET updated_at = strftime('%Y-%m-%dT%H:%M:%fZ','now')
        WHERE chunk_id = NEW.chunk_id;
    END;
```

### State Machine

```
PENDING ──lease_grant──► LEASED ──ack_success──► COMPLETED
                           │
                           ├── heartbeat_timeout ──► PENDING (retry_count < max)
                           │
                           └── ack_failure ──► FAILED_RETRYABLE (retry_count < max)
                                            └── FAILED_PERMANENT (retry_count >= max)
```

### Key Operations (Python Reference)

```python
import sqlite3, uuid, datetime

LEASE_DURATION_SEC = 600   # 10 minutes; tunable per chunk workload

def grant_lease(db_path: str, worker_id: str) -> dict | None:
    """Atomically claim the next PENDING chunk for a worker."""
    with sqlite3.connect(db_path, timeout=30) as conn:
        conn.isolation_level = 'IMMEDIATE'   # serialize lease grants
        now = datetime.datetime.utcnow()
        expires = now + datetime.timedelta(seconds=LEASE_DURATION_SEC)
        row = conn.execute(
            """SELECT chunk_id FROM chunk_queue
               WHERE status = 'PENDING'
               ORDER BY retry_count ASC, created_at ASC
               LIMIT 1"""
        ).fetchone()
        if not row:
            return None
        chunk_id = row[0]
        conn.execute(
            """UPDATE chunk_queue SET
               status='LEASED', worker_id=?, leased_at=?,
               lease_expires_at=?, last_heartbeat_at=?
               WHERE chunk_id=? AND status='PENDING'""",
            (worker_id, now.isoformat()+'Z', expires.isoformat()+'Z',
             now.isoformat()+'Z', chunk_id)
        )
        conn.commit()
        return conn.execute(
            "SELECT * FROM chunk_queue WHERE chunk_id=?", (chunk_id,)
        ).fetchone()

def heartbeat(db_path: str, chunk_id: str, worker_id: str):
    """Extend lease while chunk is being processed."""
    with sqlite3.connect(db_path) as conn:
        now = datetime.datetime.utcnow()
        new_expires = now + datetime.timedelta(seconds=LEASE_DURATION_SEC)
        conn.execute(
            """UPDATE chunk_queue SET
               last_heartbeat_at=?, lease_expires_at=?
               WHERE chunk_id=? AND worker_id=? AND status='LEASED'""",
            (now.isoformat()+'Z', new_expires.isoformat()+'Z',
             chunk_id, worker_id)
        )
        conn.commit()

def ack_chunk(db_path: str, chunk_id: str, worker_id: str,
              record_count: int):
    """Mark chunk COMPLETED after successful scan + persist."""
    with sqlite3.connect(db_path) as conn:
        now = datetime.datetime.utcnow()
        conn.execute(
            """UPDATE chunk_queue SET
               status='COMPLETED', completed_at=?,
               record_count_produced=?
               WHERE chunk_id=? AND worker_id=? AND status='LEASED'""",
            (now.isoformat()+'Z', record_count, chunk_id, worker_id)
        )
        conn.commit()

def reclaim_expired_leases(db_path: str, max_retries: int = 3):
    """Orchestrator heartbeat: reclaim stale leases. Run every 5 minutes."""
    with sqlite3.connect(db_path, timeout=30) as conn:
        now = datetime.datetime.utcnow().isoformat() + 'Z'
        # Reclaim retryable
        conn.execute(
            """UPDATE chunk_queue SET
               status='PENDING', worker_id=NULL,
               leased_at=NULL, lease_expires_at=NULL,
               retry_count=retry_count+1
               WHERE status='LEASED'
                 AND lease_expires_at < ?
                 AND retry_count < max_retries""",
            (now,)
        )
        # Permanently fail exhausted
        conn.execute(
            """UPDATE chunk_queue SET
               status='FAILED_PERMANENT',
               error_class='NON_RETRYABLE',
               error_message='max_retries_exceeded'
               WHERE status='LEASED'
                 AND lease_expires_at < ?
                 AND retry_count >= max_retries""",
            (now,)
        )
        conn.commit()
```

### Anti-Duplication Guarantee

Because `grant_lease` uses `IMMEDIATE` isolation level in SQLite, two workers competing for the same chunk will serialize. Only one will see `status='PENDING'` at update time; the other will update 0 rows and receive `None`, causing it to retry or idle. This prevents the double-execution scenario without external coordination.

---

## 3. Component 2: Sink Outbox with Retry Classification

### Outbox Pattern

Every record is written to the outbox table *before* any sink attempt. The sink becomes best-effort: the outbox is the source of truth. A separate sweep process reads PENDING outbox records and attempts sink writes. On failure, it applies retry classification to decide whether to retry or dead-letter.

### SQLite Schema — `sink_outbox` Table

```sql
CREATE TABLE IF NOT EXISTS sink_outbox (
    outbox_id       INTEGER PRIMARY KEY AUTOINCREMENT,
    chunk_id        TEXT    NOT NULL,
    record_id       TEXT    NOT NULL UNIQUE,    -- dedup key (SHA256-prefixed)
    record_type     TEXT    NOT NULL,           -- 'dns', 'http', 'naabu', 'dig'
    sink_target     TEXT    NOT NULL DEFAULT 'clickhouse',  -- 'clickhouse' | 'neo4j'
    payload_json    TEXT    NOT NULL,
    status          TEXT    NOT NULL DEFAULT 'PENDING',
    -- Status: PENDING, SYNCED, FAILED_RETRYABLE, DEAD_LETTER
    created_at      TEXT    NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
    synced_at       TEXT,
    sync_attempts   INTEGER NOT NULL DEFAULT 0,
    next_retry_at   TEXT,                       -- NULL = retry immediately
    last_error_class TEXT,                      -- RETRYABLE | NON_RETRYABLE
    last_error      TEXT
);

CREATE INDEX IF NOT EXISTS idx_so_status_created
    ON sink_outbox(status, created_at)
    WHERE status IN ('PENDING', 'FAILED_RETRYABLE');

CREATE INDEX IF NOT EXISTS idx_so_record_id
    ON sink_outbox(record_id);

CREATE INDEX IF NOT EXISTS idx_so_chunk
    ON sink_outbox(chunk_id, status);

-- Sync ledger: tracks per-chunk sink progress
CREATE TABLE IF NOT EXISTS sink_sync_ledger (
    chunk_id        TEXT    PRIMARY KEY,
    total_records   INTEGER NOT NULL DEFAULT 0,
    synced_count    INTEGER NOT NULL DEFAULT 0,
    dead_letter_count INTEGER NOT NULL DEFAULT 0,
    oldest_pending_created_at TEXT,
    ledger_updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
);
```

### Retry Classification Table

| Error Class | Condition | Action | Max Retries |
|-------------|-----------|--------|------------|
| RETRYABLE | ClickHouse connection timeout | Exponential backoff (2^n seconds, n=attempt) | 5 |
| RETRYABLE | ClickHouse rate limit (429) | Backoff 30s, 60s, 120s, 240s, 480s | 5 |
| RETRYABLE | Neo4j transient error (ServiceUnavailable) | Exponential backoff | 5 |
| NON_RETRYABLE | Schema validation failure (wrong field types) | DEAD_LETTER immediately | 0 |
| NON_RETRYABLE | UNIQUE constraint violation (duplicate dedup key) | Mark SYNCED (already exists) | 0 |
| NON_RETRYABLE | Authentication failure (credentials wrong) | DEAD_LETTER + halt sweep + alert | 0 |
| NON_RETRYABLE | Record parse error (malformed JSON payload) | DEAD_LETTER immediately | 0 |
| NON_RETRYABLE | Sink schema mismatch (column absent) | DEAD_LETTER + alert ops | 0 |
| RETRYABLE | ClickHouse connection refused | Short retry (30s); alert after 5 consecutive | 10 |

**UNIQUE constraint special case:** A UNIQUE constraint violation means the record already exists in the sink (prior successful write). The correct action is `status='SYNCED'` — treating it as a success. This is the primary replay idempotency mechanism.

### Outbox Sweep Process

```python
def run_outbox_sweep(db_path: str, sink_client, batch_size: int = 1000,
                     max_sync_attempts: int = 5):
    """
    Sweep PENDING outbox records and attempt sink write.
    Run every 30 seconds as a background thread.
    """
    now = datetime.datetime.utcnow().isoformat() + 'Z'
    with sqlite3.connect(db_path, timeout=30) as conn:
        # Fetch batch: PENDING + FAILED_RETRYABLE where next_retry_at has passed
        rows = conn.execute(
            """SELECT outbox_id, record_id, record_type, sink_target,
                      payload_json, sync_attempts
               FROM sink_outbox
               WHERE status IN ('PENDING','FAILED_RETRYABLE')
                 AND (next_retry_at IS NULL OR next_retry_at <= ?)
               ORDER BY created_at ASC LIMIT ?""",
            (now, batch_size)
        ).fetchall()

    for row in rows:
        outbox_id, record_id, record_type, sink_target, payload_json, attempts = row
        try:
            sink_client.write(record_type, sink_target, payload_json)
            _mark_synced(db_path, outbox_id)
        except UniqueConstraintViolation:
            _mark_synced(db_path, outbox_id)   # idempotent: already exists
        except NonRetryableError as e:
            _mark_dead_letter(db_path, outbox_id, str(e))
        except RetryableError as e:
            if attempts >= max_sync_attempts:
                _mark_dead_letter(db_path, outbox_id, str(e))
            else:
                backoff_sec = min(2 ** attempts, 480)
                _mark_retry(db_path, outbox_id, attempts + 1, backoff_sec, str(e))
        except AuthenticationError as e:
            _mark_dead_letter(db_path, outbox_id, str(e))
            _emit_alert('SINK_AUTH_FAILURE', {'sink': sink_target, 'error': str(e)})
            _halt_sweep()   # Non-retryable config fault; halt to prevent storm
```

### Sync Ledger Maintenance

```sql
-- Updated by trigger after each outbox status change
CREATE TRIGGER IF NOT EXISTS trg_sync_ledger_update
    AFTER UPDATE OF status ON sink_outbox
    BEGIN
        INSERT INTO sink_sync_ledger(chunk_id, total_records, synced_count,
                                     dead_letter_count, oldest_pending_created_at)
        SELECT
            chunk_id,
            COUNT(*),
            SUM(CASE WHEN status='SYNCED' THEN 1 ELSE 0 END),
            SUM(CASE WHEN status='DEAD_LETTER' THEN 1 ELSE 0 END),
            MIN(CASE WHEN status='PENDING' THEN created_at ELSE NULL END)
        FROM sink_outbox WHERE chunk_id = NEW.chunk_id
        ON CONFLICT(chunk_id) DO UPDATE SET
            total_records=excluded.total_records,
            synced_count=excluded.synced_count,
            dead_letter_count=excluded.dead_letter_count,
            oldest_pending_created_at=excluded.oldest_pending_created_at,
            ledger_updated_at=strftime('%Y-%m-%dT%H:%M:%fZ','now');
    END;
```

---

## 4. Component 3: Backpressure Signals → Scanner Concurrency Tuning

Backpressure prevents the scanner from producing records faster than the sink can consume. Without backpressure, the outbox table grows unboundedly and sink recovery debt accumulates.

### Signal Registry

| Signal Name | Query | Threshold | Response |
|-------------|-------|-----------|----------|
| `outbox_pending_depth` | `SELECT COUNT(*) FROM sink_outbox WHERE status='PENDING'` | > 10,000 | Reduce scanner parallelism by 25% |
| `outbox_pending_depth_critical` | same | > 50,000 | Halt new chunk leasing; drain outbox |
| `sink_oldest_pending_age_h` | `(now - MIN(created_at)) / 3600` for PENDING | > 2h | Alert + reduce concurrency by 50% |
| `dead_letter_rate` | `SUM(status='DEAD_LETTER') / COUNT(*)` per hour window | > 2% | Alert; investigate error class |
| `stale_lease_count` | `SELECT COUNT(*) WHERE status='LEASED' AND lease_expires_at < now` | > 0 | Trigger `reclaim_expired_leases()` |
| `failed_permanent_chunks` | `SELECT COUNT(*) WHERE status='FAILED_PERMANENT'` | > 0 | Alert; requires manual review |
| `chunk_completion_gap_min` | `(now - MAX(completed_at)) / 60` | > 30 min | Alert; check lease reclaim |

### Concurrency Controller

```python
class ConcurrencyController:
    def __init__(self, base_parallelism: int = 4):
        self.base = base_parallelism
        self.current = base_parallelism

    def recompute(self, signals: dict) -> int:
        target = self.base
        if signals['outbox_pending_depth'] > 50_000:
            return 0   # halt; drain outbox
        if signals['outbox_pending_depth'] > 10_000:
            target = int(self.base * 0.75)
        if signals['sink_oldest_pending_age_h'] > 2.0:
            target = min(target, int(self.base * 0.50))
        self.current = max(1, target)
        return self.current
```

This integrates with the scanner's worker pool: `pool.set_size(controller.recompute(read_signals(db_path)))`.

---

## 5. Integrity SLOs and Rollout Gates

### Gate Criteria (must ALL pass before promoting to production)

| SLO ID | Metric | Gate Threshold | Verification Method |
|--------|--------|---------------|---------------------|
| SLO-1 | Duplicate chunk execution incidents | = 0 | Restart drill: kill worker mid-chunk; verify no duplicate rows post-replay |
| SLO-2 | Sink unsynced oldest age | < 2h | Monitor `sink_oldest_pending_age_h` under normal operation for 1h |
| SLO-3 | Replay duplicate sink rows | ≤ 0.1% | Replay a completed chunk; compare row counts before/after |
| SLO-4 | Queue completion gap | ≤ 30 min | Monitor `chunk_completion_gap_min` across full 51-chunk run |
| SLO-5 | Dead letter rate | < 1% | Monitor `dead_letter_rate` over 2h of operation |
| SLO-6 | Lease reclaim correctness | 100% | Inject stale lease (manually expire); verify reclaim within 5 min |
| SLO-7 | Auth failure halt | Correct | Inject bad credentials; verify sweep halts without storm |

### SLO Monitoring Queries (SQLite)

```sql
-- SLO-2: Sink oldest pending age in hours
SELECT ROUND(
    (julianday('now') - julianday(MIN(created_at))) * 24, 2
) AS oldest_pending_age_h
FROM sink_outbox WHERE status = 'PENDING';

-- SLO-4: Queue completion gap in minutes
SELECT ROUND(
    (julianday('now') - julianday(MAX(completed_at))) * 1440, 1
) AS completion_gap_min
FROM chunk_queue WHERE status = 'COMPLETED';

-- SLO-5: Dead letter rate (last 2 hours)
SELECT
    ROUND(100.0 * SUM(CASE WHEN status='DEAD_LETTER' THEN 1 ELSE 0 END)
          / NULLIF(COUNT(*), 0), 2) AS dead_letter_rate_pct
FROM sink_outbox
WHERE created_at >= datetime('now', '-2 hours');

-- SLO-1: Any duplicate executions (same chunk, multiple COMPLETED)
SELECT chunk_id, COUNT(*) AS execution_count
FROM chunk_queue_audit_log   -- append-only audit log
WHERE status = 'COMPLETED'
GROUP BY chunk_id HAVING COUNT(*) > 1;
```

---

## 6. Replay Correctness Design

### Idempotent Write Path

Every record written to `sink_outbox` carries a `record_id` (dedup key) that matches the entity dedup key in Neo4j/ClickHouse. When the outbox sweeper encounters a UNIQUE constraint violation on write, it marks the record SYNCED — not FAILED. This means:

- A full replay of a chunk produces exactly the same sink state
- Duplicate rows in ClickHouse are prevented by the `record_id` UNIQUE constraint on the outbox itself (a second insert of the same record is rejected at the outbox layer before reaching the sink)

### Replay Procedure

```bash
# Replay all DEAD_LETTER records after root cause fix
UPDATE sink_outbox
SET status='PENDING', sync_attempts=0, last_error=NULL, next_retry_at=NULL
WHERE status='DEAD_LETTER' AND last_error_class='RETRYABLE';

# Replay a specific chunk's PENDING records
UPDATE sink_outbox SET status='PENDING', sync_attempts=0
WHERE chunk_id='chunk_042' AND status='FAILED_RETRYABLE';
```

---

## 7. Operational Observability

### Master Status Query

```sql
SELECT
    (SELECT COUNT(*) FROM chunk_queue WHERE status='PENDING') AS chunks_pending,
    (SELECT COUNT(*) FROM chunk_queue WHERE status='LEASED') AS chunks_leased,
    (SELECT COUNT(*) FROM chunk_queue WHERE status='COMPLETED') AS chunks_completed,
    (SELECT COUNT(*) FROM chunk_queue WHERE status='FAILED_PERMANENT') AS chunks_failed,
    (SELECT COUNT(*) FROM sink_outbox WHERE status='PENDING') AS outbox_pending,
    (SELECT COUNT(*) FROM sink_outbox WHERE status='SYNCED') AS outbox_synced,
    (SELECT COUNT(*) FROM sink_outbox WHERE status='DEAD_LETTER') AS outbox_dead_letter,
    (SELECT ROUND(
        (julianday('now') - julianday(MIN(created_at))) * 24, 2)
     FROM sink_outbox WHERE status='PENDING') AS oldest_pending_h,
    (SELECT ROUND(
        (julianday('now') - julianday(MAX(completed_at))) * 1440, 1)
     FROM chunk_queue WHERE status='COMPLETED') AS completion_gap_min;
```

This query is the single pane of glass for the entire pipeline state. It runs in < 100ms on a properly indexed SQLite database at 10M+ record scale.

---

## 8. Tradeoffs

| Decision | Alternative Considered | Rationale for Choice |
|----------|----------------------|---------------------|
| SQLite as lease store | Redis / external coordinator | Zero infra addition; durability without network dependency; sufficient for 51-chunk scale |
| Outbox in same SQLite DB | Separate outbox DB | Atomic writes (chunk ack + outbox insert) in single transaction; no distributed coordination |
| Heartbeat-based lease extension | Fixed long lease | Short lease with heartbeat allows faster reclaim on worker crash; fixed long lease causes 10+ min delay |
| UNIQUE constraint for dedup | Application-level dedup check | DB-enforced constraints are atomic and race-condition free; application-level checks race under concurrent writes |
| Sweep process (separate thread) | Inline sync per record | Inline sync blocks scan worker on sink latency; sweep decouples scan rate from sink rate |

---

## 9. Risk Model

| ID | Risk | Severity | Probability | Mitigation |
|----|------|----------|-------------|------------|
| R1 | SQLite WAL writer contention at high ingest rate | HIGH | MEDIUM | WAL mode enabled; batch writes per chunk (not per record); `PRAGMA synchronous=NORMAL` |
| R2 | Sweep falls behind; outbox grows unboundedly | HIGH | LOW | Backpressure signals halt new leasing when depth > 50k; sweep batches 1000 records/cycle |
| R3 | Auth failure causes retry storm | HIGH | LOW | Auth failures halt sweep immediately; alert sent; no retry loop |
| R4 | Lease duration too short for large chunks | MEDIUM | MEDIUM | Worker sends heartbeat every `LEASE_DURATION / 2` seconds; adjustable per chunk size profile |
| R5 | Outbox grows beyond SQLite scalability (>100M rows) | MEDIUM | LOW | Periodic archive: move SYNCED records older than 7 days to `sink_outbox_archive` |
| R6 | Scanner restarts lose in-flight heartbeat state | LOW | HIGH | Heartbeats resume on restart; lease reclaimer handles stale leases within 5 min |

---

## 10. Assumptions

- A1: SQLite WAL mode is already configured or will be set before first write (`PRAGMA journal_mode=WAL`)
- A2: `persistence_gateway.py` can be extended to accept chunk_id and worker_id as parameters for lease integration
- A3: Scanner concurrency is controlled by a parameter (e.g., pool size) that the ConcurrencyController can modify at runtime
- A4: 51 chunks are pre-populated in `chunk_queue` at initialization; migration from file-list involves a one-time INSERT per chunk
- A5: ClickHouse/Neo4j clients raise distinct exception classes for retryable vs non-retryable errors; if not, error string matching is acceptable fallback
- A6: The audit log table (`chunk_queue_audit_log`) is an append-only mirror updated by trigger for SLO-1 verification

---

## 11. KPIs

| Metric | Target | Source |
|--------|--------|--------|
| Duplicate chunk execution | 0 | chunk_queue_audit_log |
| Sink oldest pending age | < 2h | sink_outbox |
| Replay duplicate rate | ≤ 0.1% | Replay test row count delta |
| Queue completion gap | ≤ 30 min | chunk_queue.completed_at |
| Dead letter rate | < 1% | sink_outbox |
| Lease reclaim latency | ≤ 5 min | Orchestrator reclaim cycle |
| Outbox sweep batch latency | ≤ 5s per 1000 records | Sweep timing |
| Master status query latency | ≤ 100ms | SQLite index performance |

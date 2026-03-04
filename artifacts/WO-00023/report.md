# WO-00023 — SQLite Outbox + Sync Ledger + Dead Letter Queue
## Data-Engineering Design for Guaranteed Sink Reliability

**Status:** COMPLETED
**Category:** data-engineering
**Priority:** HIGH
**Analyst:** openclaw-field-processor
**Produced:** 2026-03-04
**Source reviewed:** `trinity999/Pandavs-Framework` @ `cebd2d5`

---

## 1. Executive Summary

`persistence_gateway.py` durably captures scan events into SQLite `events` table, but provides no mechanism to track which events have been delivered to downstream sinks (ClickHouse, Neo4j). Phase 2 of `PHASE_IMPLEMENTATION_PLAN.md` calls for a `persistence_db_sink.py` with sync markers and a dead-letter bucket.

This Work Order produces the schema and worker algorithm for:
- **`sink_outbox`** — queues every event for delivery to each configured sink
- **`event_sync_ledger`** — immutable delivery receipts per event+sink combination
- **`dead_letter_events`** — preserves full context of permanently failed deliveries
- **Retry taxonomy** — classifies errors into retryable vs non-retryable classes

The design is fully additive to `scan_persistence.db` and is built around the existing `events.event_id` hash as the natural idempotency key.

---

## 2. Context Understanding

### 2.1 Existing Schema (from persistence_gateway.py lines 53-105)

```sql
-- Already exists in scan_persistence.db:
CREATE TABLE events (
  event_id TEXT PRIMARY KEY,   -- SHA-256[:64] of tool|kind|asset|value|port|source_file|line_no
  tool TEXT NOT NULL,
  event_kind TEXT NOT NULL,
  asset TEXT, value TEXT, port INTEGER, status TEXT,
  ts TEXT NOT NULL,
  source_file TEXT NOT NULL,
  line_no INTEGER NOT NULL,
  raw_json TEXT NOT NULL
);

CREATE TABLE ingest_runs (
  run_id TEXT PRIMARY KEY,
  started_ts TEXT, ended_ts TEXT,
  files_seen INTEGER, files_processed INTEGER,
  events_inserted INTEGER, events_deduped INTEGER, errors INTEGER,
  note TEXT
);
```

**What is missing for sink delivery:**
- No column on `events` tracks which sinks have received the event
- No retry state, no error capture per sink
- No dead-letter bucket for events that cannot be delivered after N attempts
- No idempotency key for the sink write (to prevent double-insert in ClickHouse)

### 2.2 Downstream Sinks (from PHASE_IMPLEMENTATION_PLAN.md + DATABASE_OPS.md)

| Sink | Technology | Write Pattern |
|------|-----------|---------------|
| ClickHouse | `pandavs_recon` DB, WSL `127.0.0.1:9000` | Batch insert (INSERT INTO table VALUES ...) |
| Neo4j | Docker `pandavs-neo4j-fixed`, Bolt `localhost:7687` | Cypher MERGE (idempotent by node property) |

ClickHouse is the primary sink; Neo4j is secondary (graph linkage). Both must be written without duplication.

### 2.3 Existing Scale (from DATABASE_OPS.md, 2026-02-21 backup)

| Table | Rows |
|-------|------|
| ClickHouse `dns_history` | 4,615,917 |
| Neo4j `:Subdomain` nodes | 10,011,955 |
| Neo4j Total relationships | 20,076,357 |

New events from the 51-chunk full pass will add O(millions) of rows. The outbox design must be efficient under sustained high-volume writes.

### 2.4 Phase 2 Spec (PHASE_IMPLEMENTATION_PLAN.md lines 51-74)

The plan explicitly calls for:
- `persistence_db_sink.py` reading unsynced events from SQLite
- Sync markers per event: `synced_clickhouse`, `synced_neo4j`, `sync_error`
- Retry with exponential backoff + dead-letter for repeated failures

This WO implements those markers as a separate outbox table rather than columns on `events` — keeping ingestion and delivery concerns cleanly separated.

---

## 3. Analytical Reasoning

### 3.1 Why a Separate Outbox Table (not columns on `events`)

**Alternative A — Add columns to `events`:**
```sql
ALTER TABLE events ADD COLUMN synced_clickhouse INTEGER DEFAULT 0;
ALTER TABLE events ADD COLUMN synced_neo4j INTEGER DEFAULT 0;
ALTER TABLE events ADD COLUMN sync_error TEXT;
```
Problem: `ALTER TABLE ADD COLUMN` in SQLite requires a table lock. At 10M+ rows, this may hang for minutes. Also, mixing ingestion state (event_id, asset, value) with delivery state (synced, retry_count) in one row violates single-responsibility and makes the table harder to index efficiently.

**Alternative B — Separate `sink_outbox` table (chosen):**
- One row per (event_id, sink_target) pair
- Indexed separately on delivery status
- Independent retry state per sink
- Zero impact on existing `events` schema
- `INSERT OR IGNORE` on event_id+sink_target pairs ensures idempotent population

### 3.2 Outbox Population Strategy

The outbox is populated at ingest time (inside `persistence_gateway.py` after `insert_event()` succeeds) or lazily (a backfill script queries `events` for event_ids not yet in `sink_outbox`). Lazy backfill is recommended for the initial Phase 2 deployment since there are already millions of events in `events` with no outbox entries.

**Backfill SQL:**
```sql
INSERT OR IGNORE INTO sink_outbox (event_id, sink_target, status, created_at, updated_at)
SELECT event_id, 'clickhouse', 'PENDING', datetime('now'), datetime('now')
FROM events
WHERE event_id NOT IN (
    SELECT event_id FROM sink_outbox WHERE sink_target = 'clickhouse'
);
```

### 3.3 Retry Classification Rationale

Errors divide into two fundamental classes:

**RETRYABLE:** Errors where the sink is temporarily unavailable or overloaded. The same payload, retried later, will succeed.
- ClickHouse `CONNECTION_REFUSED`, `TIMEOUT`, `TOO_MANY_PARTS` (rate limiting)
- Neo4j `ServiceUnavailable`, `SessionExpired`, `TransientError`

**NON_RETRYABLE:** Errors where the payload itself is malformed or the constraint prevents insertion. Retrying will always fail.
- ClickHouse `BAD_ARGUMENTS`, `TYPE_MISMATCH`, `UNKNOWN_TABLE`
- Neo4j `ConstraintValidationFailed`, `SyntaxError`
- `UNIQUE_CONSTRAINT_VIOLATION` from sink: event already exists → mark SYNCED (not FAILED)

**Special case — ALREADY_SYNCED:** If ClickHouse returns "duplicate key" or Neo4j `MERGE` finds existing node with same properties → this is a success state. Mark `SYNCED`, not failed. This is the idempotent replay path.

### 3.4 Dead Letter Design

Dead letter entries capture the full delivery context at time of final failure:
- Complete `raw_json` payload (from `events.raw_json`)
- Full error message and class
- All N retry attempt records (from `sink_outbox_retry_log`)
- Timestamp of first attempt and last attempt

This enables manual triage: operator inspects `dead_letter_events`, understands why delivery failed, and can either fix the payload or the sink schema before requesting replay.

---

## 4. Design Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Schema location | `sink_outbox` and `event_sync_ledger` in same `scan_persistence.db` | Single WAL file; avoids cross-DB joins for event_id lookups |
| Outbox rows | One per (event_id, sink_target) | Per-sink independent retry; ClickHouse failure doesn't block Neo4j delivery |
| Primary delivery key | `event_id` (existing SHA-256 hash) | Stable, content-addressed; collision-proof for current volume |
| Sync ledger | Immutable append-only rows | Audit trail for every delivery; never overwrite |
| Batch size | 500 events per sweep cycle | Balance throughput vs transaction lock time on WAL |
| Retry limit | 5 per sink | Higher than chunk_queue (3) because sink failures are more transient |
| DLQ trigger | On 5th failure OR non-retryable error on 1st attempt | Non-retryable errors escalate immediately; no wasted retries |

---

## 5. Tradeoffs

| Tradeoff | Cost | Benefit |
|----------|------|---------|
| Separate outbox table vs columns | Extra table + JOIN for full event | Clean separation; independent sink states; zero schema migration on events |
| One row per (event_id, sink_target) | 2× rows at 2 sinks | Full per-sink retry independence |
| Sync ledger as separate table | Extra writes per delivery | Immutable audit trail; idempotent replay detection |
| Lazy outbox backfill | Initial delay before old events are delivered | Zero impact on live ingestion path; no ingestion pause required |

---

## 6. Risks

| Risk | Severity | Mitigation |
|------|----------|-----------|
| Outbox grows unbounded if sinks are permanently down | HIGH | Monitor `sink_outbox` depth; alert if > 100k PENDING. Auto-escalate to DLQ after 5 retries |
| Duplicate writes to ClickHouse on retry | MEDIUM | Use `INSERT INTO ... IF NOT EXISTS` (ClickHouse dedup) or `INSERT OR IGNORE` pattern; event_id as dedup key |
| Neo4j MERGE race condition | LOW | MERGE is inherently idempotent; concurrent MERGE on same node properties is safe in Neo4j |
| Sync ledger grows very large (10M events × 2 sinks) | MEDIUM | Archive/partition ledger after 30 days; PENDING/FAILED rows remain hot; SYNCED rows are cold |
| SQLite WAL checkpoint lag under heavy outbox writes | LOW | WAL mode handles concurrent outbox writes; NORMAL synchronous is safe |

---

## 7. Recommendations

1. **Apply `sqlite_schema_migration.sql`** to `scan_persistence.db` before starting Phase 2 sink work
2. **Run backfill query** for existing events (~millions) — populate `sink_outbox` for both `clickhouse` and `neo4j` targets
3. **Implement `outbox_sweep_worker.py`** using the algorithm in this WO: read PENDING batch → write to sink → mark SYNCED or increment failure
4. **Use `retry_taxonomy.json`** as the lookup table in the sweep worker to determine RETRYABLE vs NON_RETRYABLE per error string
5. **Monitor `dead_letter_events`** count — any non-zero count requires human triage
6. **Separate sweep frequency by sink:** ClickHouse sweep every 60s (fast batch); Neo4j sweep every 300s (graph writes are slower)

---

## 8. Implementation Model

### 8.1 Outbox Sweep Algorithm (pseudo-Python)

```python
def outbox_sweep(db_path, sink_target, batch_size=500):
    conn = sqlite3.connect(db_path)

    # Fetch batch of PENDING events for this sink
    rows = conn.execute("""
        SELECT o.outbox_id, o.event_id, e.raw_json, e.tool, e.event_kind
        FROM sink_outbox o
        JOIN events e ON e.event_id = o.event_id
        WHERE o.sink_target = ? AND o.status = 'PENDING'
          AND (o.next_retry_at IS NULL OR o.next_retry_at <= datetime('now'))
        ORDER BY o.created_at ASC
        LIMIT ?
    """, (sink_target, batch_size)).fetchall()

    for outbox_id, event_id, raw_json, tool, event_kind in rows:
        try:
            if sink_target == 'clickhouse':
                write_to_clickhouse(event_id, raw_json, tool, event_kind)
            elif sink_target == 'neo4j':
                write_to_neo4j(event_id, raw_json, tool, event_kind)

            # Mark SYNCED + write immutable ledger entry
            _mark_synced(conn, outbox_id, event_id, sink_target)

        except Exception as e:
            error_class = classify_error(sink_target, str(e))  # see retry_taxonomy.json
            _handle_failure(conn, outbox_id, event_id, sink_target, str(e), error_class)

    conn.close()
```

### 8.2 `_mark_synced()` (idempotent)

```python
def _mark_synced(conn, outbox_id, event_id, sink_target):
    now = utc_now()
    conn.execute("""
        UPDATE sink_outbox SET status='SYNCED', synced_at=?, updated_at=?
        WHERE outbox_id=?
    """, (now, now, outbox_id))
    conn.execute("""
        INSERT OR IGNORE INTO event_sync_ledger
          (event_id, sink_target, synced_at, delivery_attempt)
        VALUES (?, ?, ?, (SELECT coalesce(max(delivery_attempt),0)+1
                          FROM event_sync_ledger WHERE event_id=? AND sink_target=?))
    """, (event_id, sink_target, now, event_id, sink_target))
    conn.commit()
```

### 8.3 `_handle_failure()` (RETRYABLE vs NON_RETRYABLE)

```python
def _handle_failure(conn, outbox_id, event_id, sink_target, error_msg, error_class):
    now = utc_now()
    row = conn.execute("""
        SELECT retry_count, max_retries FROM sink_outbox WHERE outbox_id=?
    """, (outbox_id,)).fetchone()
    retry_count, max_retries = row

    if error_class == 'ALREADY_SYNCED':
        # Idempotent replay — sink already has this event. Mark SYNCED.
        _mark_synced(conn, outbox_id, event_id, sink_target)
        return

    if error_class == 'NON_RETRYABLE' or (retry_count + 1) >= max_retries:
        # Move to dead letter
        new_status = 'DEAD_LETTER'
        conn.execute("""
            INSERT OR IGNORE INTO dead_letter_events
              (event_id, sink_target, final_error_class, final_error_message,
               total_attempts, first_attempted_at, last_attempted_at, raw_json_snapshot)
            SELECT ?, ?, ?, ?, ?, o.created_at, ?, e.raw_json
            FROM sink_outbox o JOIN events e ON e.event_id=o.event_id
            WHERE o.outbox_id=?
        """, (event_id, sink_target, error_class, error_msg[:512],
              retry_count + 1, now, outbox_id))
    else:
        new_status = 'FAILED'
        backoff = 60 * (2 ** retry_count)  # 60s, 120s, 240s, 480s, 960s
        next_retry = _add_seconds_to_iso(now, backoff)
        conn.execute("""
            UPDATE sink_outbox SET
                status='FAILED', retry_count=retry_count+1,
                last_error_class=?, last_error_message=?,
                last_failed_at=?, next_retry_at=?, updated_at=?
            WHERE outbox_id=?
        """, (error_class, error_msg[:512], now, next_retry, now, outbox_id))

    conn.execute("""
        UPDATE sink_outbox SET status=? WHERE outbox_id=?
    """, (new_status, outbox_id))
    conn.commit()
```

---

## 9. Validation Strategy

| Test | Pass Condition |
|------|---------------|
| **Idempotent backfill:** Run backfill twice | Second run inserts 0 rows (INSERT OR IGNORE) |
| **Idempotent sweep:** Run sweep twice on SYNCED events | No duplicate writes to ClickHouse/Neo4j; ledger shows 1 entry per event+sink |
| **RETRYABLE error drill:** Take ClickHouse offline; run sweep | `sink_outbox.status = 'FAILED'`, retry_count increments; restored CH receives batch |
| **NON_RETRYABLE error drill:** Send malformed payload | Immediately escalates to `dead_letter_events`; no retry |
| **ALREADY_SYNCED replay:** Insert event already in ClickHouse | Status → SYNCED; ledger shows delivery_attempt = N+1 |
| **Full backlog clearance:** All 51 chunks complete, sweep runs | 0 PENDING rows in `sink_outbox` after sweep cycle |
| **DLQ audit:** Inspect dead_letter_events | raw_json_snapshot present; final_error_message explains failure |

---

## 10. KPIs

| KPI | Target | SQL |
|-----|--------|-----|
| Replay idempotency duplicate rate | ≤ 0.1% | Count ledger entries per event_id per sink; flag where count > 1 |
| Sink backlog oldest age | < 2h (steady state) | `SELECT max((julianday('now')-julianday(created_at))*24) FROM sink_outbox WHERE status='PENDING'` |
| Dead letter count | 0 (alert on any) | `SELECT count(*) FROM dead_letter_events WHERE reviewed_at IS NULL` |
| Retry storm prevention | RETRYABLE errors use exponential backoff | No event has retry_count > 1 within 60s of first failure |
| Delivery coverage | 100% of events SYNCED or DLQ | `SELECT count(*) FROM events e WHERE NOT EXISTS (SELECT 1 FROM sink_outbox o WHERE o.event_id=e.event_id AND o.status='SYNCED')` |

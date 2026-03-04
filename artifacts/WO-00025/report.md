# WO-00025 Failure-Drill Matrix & Test Harness Plan

**Work Order:** WO-00025
**Category:** testing/HIGH
**Analyst:** openclaw-field-processor
**Date:** 2026-03-05
**Source commit:** trinity999/Pandavs-Framework@cebd2d5

---

## 1. Executive Summary

The Pandavs scan pipeline spans three autonomous stages — scan execution, SQLite persistence, and sink delivery — each running as independent processes. Infrastructure instability is a documented recurring reality (DATABASE_OPS.md 2026-03-04 incident: ClickHouse and Neo4j both went unreachable due to runtime mismatches). This Work Order defines a systematic failure-drill matrix covering every process kill, DB outage, and backlog-drain scenario, with measurable pass/fail criteria grounded in the actual source code and existing recovery infrastructure from WO-00022, WO-00023, and WO-00024.

**Success targets:** MTTR < 15 min | Zero unrecoverable event loss | Replay duplicate rate <= 0.1%

---

## 2. Source Analysis

### 2.1 Phase 3 Failure Drills (PHASE_IMPLEMENTATION_PLAN.md lines 95-98)

```
Failure drills:
  - Kill process mid-run and resume
  - DB down scenario and replay on recovery
```

### 2.2 Phase 3 Acceptance Criteria (lines 99-103)

```
- Pipeline recovers from interruptions without loss
- Hourly reports show monotonic progress
- Integrity checks pass at chunk-level and run-level
```

### 2.3 Phase 4 Acceptance Criteria (lines 132-138)

```
- Ops visibility without ad-hoc debugging
- Fast recovery path documented and tested
- Stable continuous operation for multi-day run window
```

### 2.4 INSERT OR IGNORE idempotency (persistence_gateway.py lines 245-266)

`insert_event()` uses `INSERT OR IGNORE INTO events(...)` — any duplicate `event_id` is silently dropped. This makes persistence re-runs naturally idempotent: replaying all result files from scratch produces the same event count.

### 2.5 ingest_runs error counter (persistence_gateway.py lines 91-101)

`ingest_runs.errors` tracks per-run parse failures. A post-drill integrity check reads `SELECT SUM(errors) FROM ingest_runs WHERE started_ts >= '<drill_start>'` to confirm no unexpected parse failures occurred during recovery.

### 2.6 Known failure patterns (DATABASE_OPS.md lines 79-114)

- **ClickHouse config wipe**: `clickhouse-server` starts silently but port 9000 never opens; fix is `apt-get install --reinstall clickhouse-server` + password override restore. Data at `/var/lib/clickhouse/` survives.
- **Neo4j container restart loop**: `docker ps` shows `Restarting (1)`. Fix: `docker restart pandavs-neo4j-fixed` after correcting heap config.
- **Python module gaps**: `validators` import missing; blocks neo4j_manager.py but NOT persistence_gateway.py (which has no such dependency).

### 2.7 Recovery infrastructure inventory

| Component | Recovery Mechanism |
|---|---|
| chunk_queue (WO-00022) | `reclaim_stale_leases()` returns expired LEASED rows to PENDING; worker restart picks up from PENDING |
| sink_outbox (WO-00023) | CLAIMED rows reaped to PENDING after 600s; FAILED rows eligible for retry at `next_retry_at` |
| persistence_gateway.py | `files.status='pending'` rows are re-attempted on next ingest loop; `INSERT OR IGNORE` prevents event duplication |
| event_sync_ledger (WO-00023) | Append-only; `INSERT OR IGNORE` prevents duplicate delivery receipts |

---

## 3. Failure-Drill Matrix Design

The matrix covers three axes:
- **Failure Mode (FM)**: What breaks
- **Pipeline Stage (PS)**: Where it breaks
- **Expected Recovery Behavior (ERB)**: What must happen within MTTR

Full matrix is in `failure_drill_matrix.csv`. Summary of 20 drills follows.

### 3.1 Stage 1: Scanner (chunk_queue)

**FM-01: SIGKILL scan worker mid-chunk (run_full_dns_pass.sh)**
- What happens: chunk transitions from LEASED → never ACKed; heartbeat thread dies
- Recovery: After `lease_ttl` (default 7200s) expires OR after immediate `reclaim_stale_leases()`, chunk returns to PENDING. Next worker picks it up.
- Verification: `SELECT status, chunk_id FROM chunk_queue` shows PENDING for killed chunk; result file may be incomplete (partial) — re-run generates fresh output file.
- MTTR: `lease_ttl` seconds for auto-reclaim; OR 0s if operator manually calls `reclaim_stale_leases()` (preferred for drills)
- **Drill injection**: `kill -9 $(pgrep -f run_full_dns_pass)` while one chunk is LEASED

**FM-02: Scanner killed at queue boundary (no chunk LEASED)**
- What happens: shell exits between `done < "$QUEUE"` iterations
- Recovery: Trivially restart — chunk_queue tracks all PENDING chunks; no state is lost
- Verification: `SELECT COUNT(*) FROM chunk_queue WHERE status='COMPLETED'` unchanged after restart

**FM-03: SIGKILL queue_controller.py during `grant_lease()`**
- What happens: `BEGIN IMMEDIATE` transaction may or may not have committed; SQLite WAL atomicity guarantees either full commit or full rollback
- Recovery: If commit happened: chunk is LEASED (reaper handles it). If rollback: chunk is PENDING. Either way, no corruption.
- Verification: `PRAGMA integrity_check` on scan_persistence.db returns 'ok'

### 3.2 Stage 2: Persistence (persistence_gateway.py)

**FM-04: SIGKILL persistence gateway during file ingest**
- What happens: `ingest_file()` interrupted mid-line; partial events may have been INSERTed (each `insert_event()` is a separate transaction)
- Recovery: On restart, `files.status` for interrupted file is still 'pending'; gateway re-reads from line 0. `INSERT OR IGNORE` prevents duplicate events.
- Verification: `SELECT COUNT(*) FROM events` same before and after re-ingest
- **Drill injection**: `kill -9 $(pgrep -f persistence_gateway)` during active ingest; restart; compare event counts

**FM-05: SQLite write failure (disk full)**
- What happens: `INSERT INTO events` raises `sqlite3.OperationalError: disk full`
- Recovery: Gateway marks file as `status='error'` in `files` table; logs error; moves to next file. On disk space recovery, re-running resets error files to pending.
- Verification: `SELECT file_path, last_error FROM files WHERE status='error'` lists affected files
- **Drill injection**: Fill disk to 99%+ capacity before running ingest-once; observe error rows

**FM-06: Persistence gateway loop exits (cron not running)**
- What happens: No new events ingested; `ingest_runs` has no recent entries
- Recovery: WO-00024 ALT-02 fires if errors exceed threshold; report shows ingest_errors rising
- Verification: `SELECT MAX(started_ts) FROM ingest_runs` should be within last 15 minutes for healthy operation

**FM-07: Large malformed result file (parser failure)**
- What happens: `parse_dig_text_line` or `parse_event_from_json` raises exception for one line; `last_error` set; other lines still processed
- Recovery: File status = 'error'; `ingest_runs.errors += 1`; other files proceed
- Verification: `SELECT total_lines, events_inserted, events_deduped FROM ingest_runs` shows expected ratios

### 3.3 Stage 3: ClickHouse Sink

**FM-08: ClickHouse config directory wipe (documented failure)**
- What happens: Port 9000 unreachable; `clickhouse_sink_worker.py` health check fails on every sweep
- Recovery: Worker skips sweeps (rows stay PENDING); no retry_count increments (connectivity, not event failure). After CH recovery: all PENDING rows process normally.
- Verification: No new `FAILED` rows during outage; `SYNCED` count picks up after recovery
- **Drill injection**: `sudo service clickhouse-server stop`; observe outbox holds; `sudo service clickhouse-server start`; observe drain

**FM-09: ClickHouse sink worker SIGKILL mid-batch insert**
- What happens: 500 rows CLAIMED; ClickHouse insert may have partially succeeded; SQLite CLAIMED rows never updated
- Recovery: Reaper on next startup returns CLAIMED rows to PENDING; re-inserts to ClickHouse (ReplacingMergeTree handles duplicates)
- Verification: `SELECT count() FROM pandavs_recon.scan_events FINAL` increases by correct amount; no excess rows vs SQLite count

**FM-10: ClickHouse auth failure (password changed)**
- What happens: All inserts fail with `AUTHORIZATION_FAILED` (NON_RETRYABLE per taxonomy)
- Recovery: All batch rows promoted to DLQ; ALT-03 fires on next evaluation; operator fixes auth
- Verification: `SELECT COUNT(*) FROM dead_letter_events WHERE reviewed_at IS NULL` > 0; ALT-03 fires
- **Drill injection**: Change CH password temporarily; run one sweep; restore password; manually replay DLQ

**FM-11: ClickHouse table schema mismatch (TYPE_MISMATCH)**
- What happens: Insert fails with `TYPE_MISMATCH` (NON_RETRYABLE)
- Recovery: Rows promoted to DLQ; requires schema fix before replay
- Verification: DLQ entries have `final_error_class='NON_RETRYABLE'`

**FM-12: ClickHouse sustained MEMORY_LIMIT_EXCEEDED (RETRYABLE)**
- What happens: Large batch hits CH memory limit; error is RETRYABLE; retry_count increments
- Recovery: Exponential backoff; reduce batch_size; CH recovers; rows drain
- Verification: Observe `retry_count` values in `sink_outbox`; eventually SYNCED; no DLQ escalation

### 3.4 Stage 4: Neo4j Sink (future / placeholder)

**FM-13: Neo4j container restart loop**
- What happens: `docker ps` shows `pandavs-neo4j-fixed` Restarting (1); all Neo4j inserts fail
- Recovery: sink_outbox neo4j rows FAIL with RETRYABLE; backoff accumulates; after `docker restart pandavs-neo4j-fixed` recovery proceeds
- Verification: `SELECT COUNT(*) FROM sink_outbox WHERE sink_target='neo4j' AND status='FAILED'` peaks then drains

**FM-14: Neo4j ConstraintValidationFailed on replay (ALREADY_SYNCED)**
- What happens: Re-running neo4j sink on existing Subdomain nodes raises `ConstraintValidationFailed`
- Recovery: Error classified as ALREADY_SYNCED by taxonomy; outbox row marked SYNCED; no retry; no DLQ
- Verification: Replay does not increment `retry_count`; rows go SYNCED immediately

### 3.5 Cross-Stage Failures

**FM-15: All three workers killed simultaneously**
- What happens: chunk_queue has LEASED chunks; sink_outbox has CLAIMED rows; persistence has pending files
- Recovery: Reaper for each component (lease reaper, claim reaper) returns rows to startable states; restart all workers
- Verification: After restart: `SELECT status, COUNT(*) FROM chunk_queue GROUP BY status` shows progression; `SELECT status, COUNT(*) FROM sink_outbox WHERE sink_target='clickhouse' GROUP BY status` drains

**FM-16: Pipeline restart from zero (full wipe of runtime, DB survives)**
- What happens: OS-level restart; all processes killed; scan_persistence.db survives (WAL mode, SQLite is a file)
- Recovery: Restart persistence gateway (resumes from `files.status='pending'`); restart queue_controller (chunks at LEASED reclaimed; COMPLETED not re-run); restart sink workers
- Verification: `SELECT COUNT(*) FROM events` before and after restart; should be identical or higher (new events added post-restart)

**FM-17: SQLite WAL file corruption (torn write simulation)**
- What happens: `truncate --size 0 scan_persistence.db-wal` while writers are active
- Recovery: SQLite WAL atomicity: if WAL is corrupted, uncommitted transactions are lost; committed transactions are durable in main DB file. Worst case: last in-progress batch of events lost.
- Verification: `PRAGMA integrity_check` should return 'ok'; only in-flight events (not yet committed) may be lost
- **Note**: This is the most severe failure mode; max data loss = one ingest_file() call worth of events

### 3.6 Backlog Drain Drills

**FM-18: Drain 10k PENDING outbox rows after 2h ClickHouse outage**
- Setup: Stop CH for 2h; run scan + persistence; accumulate ~10k outbox rows
- Drain procedure: Restart CH; run clickhouse_sink_worker.py run-once; time to drain
- Verification: `SELECT COUNT(*) FROM sink_outbox WHERE status='SYNCED' AND synced_at >= '<recovery_ts>'` = 10k; time to completion < 12 minutes at 50k events/min

**FM-19: Replay correctness after full outbox drain**
- Setup: After FM-18 drain, run clickhouse_sink_worker.py run-once again
- Expected: Zero new SYNCED rows (all already SYNCED); `event_sync_ledger` counts unchanged
- Verification: idempotency guarantee

**FM-20: Concurrent scan + replay (backpressure)**
- Setup: Run scanner (48 parallel DNS workers) + persistence gateway + clickhouse_sink concurrently under sustained load
- Monitor: `scan_persistence.db` WAL size; no SQLITE_BUSY errors; all three processes make progress
- Verification: Hourly report shows monotonic increases in all three: coverage_pct, events_total, clickhouse_synced

---

## 4. Test Harness Architecture

### 4.1 Harness Components

```
run_failure_drill.sh <DRILL_ID>
├── pre_check()          — snapshot SQLite state before drill
├── inject_failure()     — inject specific failure mode
├── wait_recovery()      — poll until recovery or timeout (MTTR)
├── post_check()         — compare SQLite state after recovery
├── record_result()      — write pass/fail + duration to drill_results.csv
└── cleanup()            — restore any modified configs
```

### 4.2 Pre/Post Snapshot Queries

```sql
-- Snapshot to run before and after each drill:
CREATE TEMPORARY TABLE drill_snapshot AS
SELECT
    (SELECT COUNT(*) FROM chunk_queue WHERE status='COMPLETED')  AS chunks_completed,
    (SELECT COUNT(*) FROM events)                                AS events_total,
    (SELECT COUNT(*) FROM sink_outbox WHERE status='SYNCED' AND sink_target='clickhouse') AS ch_synced,
    (SELECT COUNT(*) FROM sink_outbox WHERE status='DEAD_LETTER') AS dlq_count,
    (SELECT COUNT(*) FROM dead_letter_events WHERE reviewed_at IS NULL) AS unreviewed_dlq,
    (SELECT COALESCE(SUM(errors),0) FROM ingest_runs WHERE started_ts >= datetime('now','-1 hour')) AS ingest_errors,
    strftime('%Y-%m-%dT%H:%M:%SZ','now') AS snapshot_ts;
```

### 4.3 Acceptance Criteria per Drill

Each drill must verify:
1. **No unrecoverable loss**: `events_total` post >= `events_total` pre (monotonic)
2. **No DLQ escalation** (for non-auth failure drills): `unreviewed_dlq` post = 0
3. **MTTR <= 15 min**: time from failure injection to full recovery
4. **Replay idempotency**: running each worker twice after recovery produces identical row counts in all tables

### 4.4 MTTR Measurement

```bash
# Measure MTTR in drill harness:
FAILURE_TS=$(date +%s)
# ... inject failure, wait for recovery condition ...
RECOVERY_TS=$(date +%s)
MTTR=$((RECOVERY_TS - FAILURE_TS))
echo "MTTR: $MTTR seconds"
# Pass if: MTTR <= 900 (15 minutes)
```

For automatic recovery drills (FM-03, FM-09): MTTR starts at failure injection; ends when all previously CLAIMED/LEASED rows return to terminal state (COMPLETED or SYNCED).

For manual-intervention drills (FM-08, FM-10): MTTR starts at failure injection; ends when operator completes documented fix procedure and rows drain.

---

## 5. Design Decisions

| ID | Decision | Rationale |
|---|---|---|
| D1 | Drills use SIGKILL, not SIGTERM | SIGKILL simulates unclean crash (OOM, kill -9); harder failure mode than graceful shutdown; ensures recovery path is exercised, not cleanup code |
| D2 | Pre/post snapshot in SQLite temporary table | Avoids external tooling dependency; same DB as the system under test; snapshot is part of the WAL-mode read-only session |
| D3 | All 20 drills are isolated and independently runnable | No drill depends on state from a previous drill; each drill has its own setup/teardown; enables selective re-running |
| D4 | Backlog drain drills use real outbox row accumulation | Synthetic drills (force-insert fake rows) would not test the actual claim/deliver/ack path; real accumulation validates the full path |
| D5 | WAL corruption drill (FM-17) is observational only | Truncating WAL is destructive; drill is run on a dedicated copy of scan_persistence.db, not production; validates SQLite durability semantics |

---

## 6. Risk Model

| Risk | Severity | Mitigation |
|---|---|---|
| Drill FM-17 (WAL corruption) damages production DB | HIGH | Run on copy: `cp scan_persistence.db /tmp/drill_copy.db` |
| Drill FM-10 (auth change) leaves CH permanently inaccessible | MEDIUM | Document exact restore steps; time-bound drill (5 min max) |
| MTTR measured by drill harness diverges from real incident MTTR | LOW | Document manual steps separately; drills measure automated recovery time only |
| ReplacingMergeTree merge hasn't run during idempotency check | LOW | Always use `SELECT ... FINAL` in verification queries |

---

## 7. KPIs

| Metric | Target | Measurement |
|---|---|---|
| Recovery MTTR | < 15 min (< 900s) | Drill harness timer |
| Unrecoverable event loss | Zero | `events_total` post >= pre for all drills |
| Replay duplicate rate | <= 0.1% | `count() FINAL` in CH vs `COUNT(*)` in SQLite events |
| Drill suite execution time | < 4 hours total | All 20 drills serialized |
| Drill pass rate (first run) | >= 80% | Identifies implementation gaps immediately |

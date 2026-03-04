# WO-00024 Observability Report
## Hourly Reporting Spec + Alert Policy for Pandavs Scan Pipeline

**Work Order:** WO-00024
**Category:** observability
**Priority:** HIGH
**Analyst:** openclaw-field-processor
**Date:** 2026-03-04
**Source commit:** trinity999/Pandavs-Framework@cebd2d5

---

## 1. Executive Summary

The Pandavs scan pipeline runs 51 DNS/HTTP chunks over ~10M assets with three sequential concerns: scan execution, SQLite persistence, and sink delivery (ClickHouse + Neo4j). Prior Work Orders (WO-00022, WO-00023) added durable queue control and outbox/DLQ infrastructure. WO-00024 closes the observability gap by defining:

1. A **formal hourly report schema** with concrete SQL queries for all counters
2. A **typed alert policy** with thresholds, detection queries, and severity classification
3. **Monotonic metric design** to guarantee reports are auditable and non-contradictory across consecutive emission windows

Without structured observability, operators cannot distinguish between "pipeline is healthy and slow" vs "pipeline is stalled" — the failure mode Phase 4 of PHASE_IMPLEMENTATION_PLAN.md explicitly targets.

---

## 2. Source Analysis

### 2.1 Run script log structure (run_full_dns_pass.sh lines 10, 17, 28)

```bash
# Line 10 — session open event:
echo "[$(date -u +%FT%TZ)] START full_dns_pass queue=$(wc -l < "$QUEUE")" | tee -a "$LOG"

# Line 17 — per-chunk start:
echo "[$(date -u +%FT%TZ)] CHUNK_START $bn" | tee -a "$LOG"

# Line 28 — per-chunk completion with I/O stats:
echo "[$(date -u +%FT%TZ)] CHUNK_DONE $bn in=$in_count resolved=$out_count out=$out" | tee -a "$LOG"
```

The log file at `logs/full_dns_pass_<ts>.log` is the low-level execution record. It does NOT survive restarts as a queryable store — it's append-only text. The chunk_queue SQLite table (WO-00022) replaces this as the canonical progress store; its `completed_at` timestamps allow rate computation without log parsing.

### 2.2 Persistence gateway ingest_runs table (persistence_gateway.py lines 91-101)

```sql
CREATE TABLE IF NOT EXISTS ingest_runs (
  run_id           TEXT    PRIMARY KEY,
  started_ts       TEXT    NOT NULL,
  ended_ts         TEXT,
  files_seen       INTEGER NOT NULL DEFAULT 0,
  files_processed  INTEGER NOT NULL DEFAULT 0,
  events_inserted  INTEGER NOT NULL DEFAULT 0,
  events_deduped   INTEGER NOT NULL DEFAULT 0,
  errors           INTEGER NOT NULL DEFAULT 0,
  note             TEXT
);
```

This table records per-ingest-run counters. `events_inserted` + `events_deduped` gives the total attempted event volume; `errors` is the persistence failure counter that feeds `ALERT_PERSISTENCE_ERRORS`.

### 2.3 File registration pattern (persistence_gateway.py lines 223-242)

The `register_files()` function upserts into the `files` table: `status`, `last_line`, `total_lines`, `last_error`, `last_seen_ts`. A file stuck in `status='pending'` with no `last_seen_ts` update indicates a stalled ingestion worker, complementary to chunk_queue heartbeat monitoring.

### 2.4 Phase 4 monitoring requirements (PHASE_IMPLEMENTATION_PLAN.md lines 109-138)

Required monitoring outputs:
- backlog size
- ingest lag
- chunk completion rate
- DB sync lag

Required alert triggers:
- no chunk progress > 30 min
- persistence errors > threshold
- DB sync failures repeated > N

### 2.5 Required report fields (PHASE_IMPLEMENTATION_PLAN.md lines 152-160)

```
Hourly report fields:
- chunks completed / 51
- % assets covered
- persistence events total
- DB sync total (ClickHouse / Neo4j)
- estimated ETA
- blockers (if any)
```

---

## 3. Gap Analysis

| Metric Needed | Data Available | Gap |
|---|---|---|
| Chunks completed | chunk_queue.status=COMPLETED | None (WO-00022 delivered) |
| Coverage % | chunk_queue + 51 denominator | None |
| Events persisted | events table COUNT(*) | None |
| ClickHouse synced | event_sync_ledger (WO-00023) | None |
| Neo4j synced | event_sync_ledger (WO-00023) | None |
| Sink lag (outbox age) | sink_outbox.created_at (WO-00023) | None |
| Ingest errors | ingest_runs.errors | None |
| Chunk processing rate | chunk_queue.completed_at timestamps | Requires window query |
| ETA | rate × remaining | Computed from above |
| No-progress detection | MAX(chunk_queue.completed_at) | Requires time comparison |
| Dead letter count | dead_letter_events (WO-00023) | None |
| Last chunk completed | chunk_queue.completed_at MAX | None |

All required data sources are available in `scan_persistence.db` after WO-00022 and WO-00023 migrations. Zero new schema changes required for this work order.

---

## 4. Design Decisions

### D1: All metrics derived from SQLite, not log files
Rationale: Log files are text-append streams requiring parsing, are not queryable, and do not survive cross-process restarts cleanly. The `chunk_queue` and `ingest_runs` tables provide structured, timestamped, transactionally-consistent data. Log files remain valuable for post-mortem but are not the primary metrics source.

### D2: Hourly report is a snapshot, not a diff
Rationale: Monotonic counters (total events, total synced) are simpler to validate for correctness — they can only increase. Reporters compare consecutive snapshots to compute deltas if needed. This prevents "negative rate" bugs from double-counting.

### D3: ETA computed over rolling 1-hour window
Rationale: Using the most recent 1-hour completion rate for ETA provides a responsive estimate that reacts to actual pipeline speed rather than a stale cumulative average.

### D4: Alert evaluation runs at report emission time + continuous sweep
Rationale: Alerting tied to report emission (every hour) gives a baseline. The no-progress alert (30-minute threshold) requires a tighter polling interval — a 5-minute sweep query independently checks `MAX(chunk_queue.completed_at)`.

### D5: False-alert suppression via `min_consecutive_fires`
Rationale: A single missed heartbeat should not page an operator. Alert rules require ≥2 consecutive evaluation cycles above threshold before firing, keeping false alert rate under 5%.

### D6: Dead letter alerts are immediate (no consecutive requirement)
Rationale: Any unreviewed DLQ entry is an operational incident requiring human attention. Unlike slow-burn threshold alerts, DLQ entries are discrete events and must alert on first occurrence.

---

## 5. Hourly Report SQL Queries

All queries run against `scan_persistence.db`. Execute in one SQLite session for consistency.

### MON-01 — Chunk completion counter
```sql
SELECT
    COUNT(*) AS chunks_completed,
    51       AS chunks_total,
    ROUND(COUNT(*) * 100.0 / 51, 2) AS coverage_pct
FROM chunk_queue
WHERE status = 'COMPLETED';
```

### MON-02 — Persistence events total
```sql
SELECT COUNT(*) AS persistence_events_total FROM events;
```

### MON-03 — DB sync totals (per sink)
```sql
SELECT
    sink_target,
    COUNT(*) AS synced_count
FROM event_sync_ledger
GROUP BY sink_target;
-- Returns rows for 'clickhouse' and 'neo4j'
```

### MON-04 — Sink outbox status summary
```sql
SELECT
    status,
    COUNT(*) AS row_count
FROM sink_outbox
GROUP BY status;
```

### MON-05 — Oldest pending outbox age (sink lag)
```sql
SELECT
    ROUND(
        (julianday('now') - julianday(MIN(created_at))) * 24.0,
        2
    ) AS sink_lag_h
FROM sink_outbox
WHERE status IN ('PENDING', 'FAILED');
-- NULL if no pending/failed rows (healthy state)
```

### MON-06 — Ingest errors in last 1 hour
```sql
SELECT COALESCE(SUM(errors), 0) AS ingest_errors_last_h
FROM ingest_runs
WHERE started_ts >= datetime('now', '-1 hour');
```

### MON-07 — Last chunk completed timestamp + rolling completion rate
```sql
SELECT
    MAX(completed_at) AS last_chunk_completed_ts,
    SUM(CASE WHEN completed_at >= datetime('now', '-1 hour') THEN 1 ELSE 0 END) AS chunks_completed_last_h
FROM chunk_queue
WHERE status = 'COMPLETED';
```

### MON-08 — ETA estimate (computed from rate)
```sql
-- Compute remaining chunks and rate, then divide
WITH rate_cte AS (
    SELECT
        SUM(CASE WHEN completed_at >= datetime('now', '-1 hour') THEN 1 ELSE 0 END) AS rate_per_h,
        51 - COUNT(*) AS remaining
    FROM chunk_queue
    WHERE status = 'COMPLETED'
)
SELECT
    rate_per_h,
    remaining,
    CASE
        WHEN rate_per_h > 0 THEN ROUND(CAST(remaining AS REAL) / rate_per_h, 2)
        ELSE NULL
    END AS eta_h
FROM rate_cte;
```

### MON-09 — No-progress detection (alert input)
```sql
-- Returns seconds since last chunk completed
SELECT
    ROUND((julianday('now') - julianday(MAX(completed_at))) * 86400.0) AS seconds_since_last_chunk,
    MAX(completed_at) AS last_chunk_ts
FROM chunk_queue
WHERE status = 'COMPLETED';
-- Alert if seconds_since_last_chunk > 1800 (30 min)
-- NULL if no chunks completed yet (use started_ts as baseline instead)
```

### MON-10 — Dead letter unreviewed count (alert input)
```sql
SELECT COUNT(*) AS unreviewed_dlq_count
FROM dead_letter_events
WHERE reviewed_at IS NULL;
```

### MON-11 — Full hourly status matrix (composite query)
```sql
-- One-shot hourly report query (runs all counters atomically)
SELECT
    strftime('%Y-%m-%dT%H:%M:%SZ', 'now')  AS report_ts,
    (SELECT COUNT(*) FROM chunk_queue WHERE status = 'COMPLETED')  AS chunks_completed,
    51                                                              AS chunks_total,
    ROUND((SELECT COUNT(*) FROM chunk_queue WHERE status = 'COMPLETED') * 100.0 / 51, 2) AS coverage_pct,
    (SELECT COUNT(*) FROM events)                                   AS persistence_events_total,
    (SELECT COUNT(*) FROM event_sync_ledger WHERE sink_target = 'clickhouse') AS synced_clickhouse,
    (SELECT COUNT(*) FROM event_sync_ledger WHERE sink_target = 'neo4j')      AS synced_neo4j,
    (SELECT COUNT(*) FROM sink_outbox WHERE status IN ('PENDING','FAILED'))   AS sink_outbox_pending,
    (SELECT COUNT(*) FROM dead_letter_events WHERE reviewed_at IS NULL)       AS dlq_unreviewed,
    (SELECT ROUND((julianday('now') - julianday(MIN(created_at)))*24.0, 2)
     FROM sink_outbox WHERE status IN ('PENDING','FAILED'))          AS sink_lag_h,
    (SELECT COALESCE(SUM(errors),0) FROM ingest_runs
     WHERE started_ts >= datetime('now','-1 hour'))                  AS ingest_errors_last_h,
    (SELECT MAX(completed_at) FROM chunk_queue WHERE status='COMPLETED') AS last_chunk_completed_ts;
```

---

## 6. Alert Policy Design

### Alert Taxonomy

| Alert ID | Name | Severity | Detection | Threshold |
|---|---|---|---|---|
| ALT-01 | NoChunkProgress | HIGH | Time since last COMPLETED | > 1800s (30 min) |
| ALT-02 | PersistenceErrors | MEDIUM | ingest_errors_last_h | > 10 per hour |
| ALT-03 | DeadLetterAccumulation | HIGH | dlq_unreviewed count | ≥ 1 (any) |
| ALT-04 | SinkBacklogAge | HIGH | sink_lag_h | > 2.0 hours |
| ALT-05 | SyncFailurePattern | MEDIUM | sink_outbox.status=FAILED count | > 50 |
| ALT-06 | CoverageStalled | MEDIUM | coverage_pct unchanged for 2h | Same pct 2 consecutive reports |

### Severity Definitions
- **HIGH**: Requires operator response within 15 minutes; may indicate data loss or pipeline halt
- **MEDIUM**: Requires investigation within 2 hours; indicates degraded operation or growing backlog

### False-alert Suppression
- HIGH alerts: fire on first positive evaluation (no delay — data integrity)
- MEDIUM alerts: require 2 consecutive positive evaluation cycles (default eval period: 5 min) before firing
- Exception: ALT-03 (DeadLetterAccumulation) fires immediately regardless of severity tier

---

## 7. Metrics Architecture

```
scan_persistence.db
┌───────────────────────────────────────────────────────────────┐
│  chunk_queue        → ALT-01 (no-progress), MON-01, MON-07   │
│  events             → MON-02 (persistence total)              │
│  ingest_runs        → ALT-02 (errors), MON-06                 │
│  sink_outbox        → ALT-04 (lag), ALT-05 (failures), MON-04│
│  event_sync_ledger  → MON-03 (ClickHouse/Neo4j counts)        │
│  dead_letter_events → ALT-03 (DLQ count), MON-10             │
└───────────────────────────────────────────────────────────────┘
           ↓ (MON-11 composite query, runs hourly)
hourly_report.json (one file per hour, ISO8601 filename)
           ↓
alert_evaluator.py (runs every 5 min, reads hourly_report.json)
           ↓
alert_log.json (append-only alert fire record)
```

---

## 8. Report Continuity Protocol

To achieve 100% hourly report continuity:
1. A cron or systemd timer runs `generate_hourly_report.sh` at `0 * * * *`
2. The report script runs MON-11 and writes to `reports/hourly_<YYYYMMDDTHH>.json`
3. A gap detector checks that `reports/` contains one file per elapsed hour since pipeline start
4. Missing report files trigger MEDIUM alert: `ReportMissing`
5. Alert evaluator reads the latest N reports for trend detection (CoverageStalled)

---

## 9. Validation Strategy

After deploying the observability stack:

1. **Continuity drill**: Let pipeline run 2 hours; verify 2 report files exist, coverage_pct monotonically increasing
2. **No-progress drill**: Pause chunk_queue artificially (set all to LEASED without heartbeat); verify ALT-01 fires within 35 minutes
3. **DLQ drill**: Manually insert one dead_letter_events row with reviewed_at=NULL; verify ALT-03 fires on next eval
4. **ETA accuracy check**: At 50% coverage, compare eta_h with actual completion time; should be within ±20%

---

## 10. Success Metrics Verification

| Metric | Target | Measurement |
|---|---|---|
| Hourly report continuity | 100% | Count of reports/ files vs elapsed hours since start |
| False alert rate | < 5% | Alerts fired but operator confirmed no incident / total alerts |
| No-progress detection latency | ≤ 30 min | Time from last CHUNK_DONE to ALT-01 fire; measured in drill |

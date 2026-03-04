# Failure Drill Acceptance Checklist
## WO-00025 | trinity999/Pandavs-Framework@cebd2d5

This checklist is the go/no-go gate for pipeline rollout. All items must pass before expanding to additional scan modules.

---

## Pre-Drill Setup Checklist

- [ ] `scan_persistence.db` exists and passes `PRAGMA integrity_check` → 'ok'
- [ ] `chunk_queue` table populated with 51 chunks (from `populate_chunk_queue()`)
- [ ] `sink_outbox` table present (WO-00023 migration applied)
- [ ] `event_sync_ledger` table present (WO-00023 migration applied)
- [ ] `dead_letter_events` table present (WO-00023 migration applied)
- [ ] ClickHouse `pandavs_recon.scan_events` table exists with `ReplacingMergeTree` engine
- [ ] ClickHouse health: `clickhouse-client --query "SELECT 1"` returns 1
- [ ] Neo4j health: `docker ps | grep pandavs-neo4j-fixed` shows Up (not Restarting)
- [ ] Baseline snapshot taken: `SELECT COUNT(*) FROM events; SELECT COUNT(*) FROM chunk_queue WHERE status='COMPLETED'`

---

## Section A: Scanner Recovery

| # | Drill | Pass Condition | Result | MTTR (s) | Notes |
|---|---|---|---|---|---|
| A1 | FM-01: SIGKILL scan worker mid-chunk | LEASED chunk returns to PENDING within 900s; re-runs to COMPLETED | [ ] PASS / [ ] FAIL | | |
| A2 | FM-02: Scanner killed at queue boundary | COMPLETED count unchanged; restart resumes from PENDING | [ ] PASS / [ ] FAIL | | |
| A3 | FM-03: SIGKILL during grant_lease() | `PRAGMA integrity_check` = 'ok'; no chunk stuck in undefined state | [ ] PASS / [ ] FAIL | | |

**Section A required to pass: all 3**
**Section A go/no-go: [ ] PASS (proceed) / [ ] FAIL (fix WO-00022 before rollout)**

---

## Section B: Persistence Recovery

| # | Drill | Pass Condition | Result | MTTR (s) | Notes |
|---|---|---|---|---|---|
| B1 | FM-04: SIGKILL persistence_gateway mid-ingest | `events` count same after re-ingest (INSERT OR IGNORE) | [ ] PASS / [ ] FAIL | | |
| B2 | FM-05: Disk full during SQLite write | Error files logged; non-affected files processed; events count non-zero | [ ] PASS / [ ] FAIL | | |
| B3 | FM-06: Persistence loop exit | ALT-02 alert fires within 10 min (or ingest_errors visible); restart recovers | [ ] PASS / [ ] FAIL | | |
| B4 | FM-07: Malformed result file | Bad lines logged as errors; good lines processed; ingest_runs.errors incremented correctly | [ ] PASS / [ ] FAIL | | |

**Section B required to pass: B1 (mandatory), B3 (mandatory), B2 and B4 (advisory)**
**Section B go/no-go: [ ] PASS (proceed) / [ ] FAIL (fix persistence_gateway before rollout)**

---

## Section C: ClickHouse Sink Recovery

| # | Drill | Pass Condition | Result | MTTR (s) | Notes |
|---|---|---|---|---|---|
| C1 | FM-08: ClickHouse port 9000 unreachable | No new FAILED rows during outage; PENDING rows drain after CH restart | [ ] PASS / [ ] FAIL | | |
| C2 | FM-09: SIGKILL sink worker mid-batch | CLAIMED rows reaped; CH count FINAL correct; no excess | [ ] PASS / [ ] FAIL | | |
| C3 | FM-10: ClickHouse auth failure | DLQ populated; ALT-03 alert fires; manual replay clears DLQ | [ ] PASS / [ ] FAIL | | |
| C4 | FM-11: TYPE_MISMATCH | DLQ entry has NON_RETRYABLE class; no retry attempted | [ ] PASS / [ ] FAIL | | |
| C5 | FM-12: MEMORY_LIMIT_EXCEEDED | retry_count increments; backoff applies; clears after recovery | [ ] PASS / [ ] FAIL | | |

**Section C required to pass: C1, C2 (mandatory); C3, C4, C5 (recommended)**
**Section C go/no-go: [ ] PASS (proceed) / [ ] FAIL (fix clickhouse_sink_worker before rollout)**

---

## Section D: Neo4j Sink Recovery (if Neo4j sync enabled)

| # | Drill | Pass Condition | Result | MTTR (s) | Notes |
|---|---|---|---|---|---|
| D1 | FM-13: Neo4j container restart loop | FAILED rows accumulate during outage; drain after `docker restart` | [ ] PASS / [ ] FAIL | | |
| D2 | FM-14: ConstraintValidationFailed replay | ALREADY_SYNCED classification; status=SYNCED; retry_count=0 | [ ] PASS / [ ] FAIL | | |

**Section D required to pass if Neo4j sink is enabled: D1, D2**
**Section D go/no-go: [ ] PASS / [ ] SKIP (Neo4j not yet enabled) / [ ] FAIL**

---

## Section E: Cross-Stage and Backlog Drills

| # | Drill | Pass Condition | Result | MTTR (s) | Notes |
|---|---|---|---|---|---|
| E1 | FM-15: All three workers SIGKILL | All reapers recover in-flight rows; workers restart and converge | [ ] PASS / [ ] FAIL | | |
| E2 | FM-16: Full runtime restart (OS reboot simulation) | events count intact; chunk_queue intact; all workers resume | [ ] PASS / [ ] FAIL | | |
| E3 | FM-17: SQLite WAL corruption (on copy) | `PRAGMA integrity_check` = 'ok' on test copy | [ ] PASS / [ ] FAIL | | |
| E4 | FM-18: Drain 10k rows after 2h CH outage | All 10k rows SYNCED; elapsed < 720s (12 min) | [ ] PASS / [ ] FAIL | | |
| E5 | FM-19: Replay correctness post-drain | Second run produces 0 new SYNCED rows; counts identical | [ ] PASS / [ ] FAIL | | |
| E6 | FM-20: Concurrent scan + persistence + replay | All workers make progress; no SQLITE_BUSY; hourly report monotonic | [ ] PASS / [ ] FAIL | | |

**Section E required to pass: E1, E2, E4, E5 (mandatory); E3, E6 (strongly recommended)**
**Section E go/no-go: [ ] PASS (proceed to production rollout) / [ ] FAIL (hold until fixed)**

---

## Overall Gate: Production Rollout Authorization

**Pre-conditions for production rollout authorization:**

```
[Mandatory] Section A: PASS (all 3)
[Mandatory] Section B: B1 + B3 = PASS
[Mandatory] Section C: C1 + C2 = PASS
[Mandatory] Section E: E1 + E2 + E4 + E5 = PASS
[Optional]  Section D: PASS or SKIP
[Advisory]  Section C: C3 + C4 + C5 = PASS
[Advisory]  Section E: E3 + E6 = PASS
```

- [ ] **AUTHORIZED FOR ROLLOUT**: All mandatory sections PASS
- [ ] **NOT AUTHORIZED**: One or more mandatory sections FAIL → open remediation tasks

---

## KPI Summary After Full Drill Suite

Record actual measured values here after running all drills:

| KPI | Target | Measured | Pass? |
|---|---|---|---|
| Max MTTR (worst-case drill) | < 900s (15 min) | | |
| Unrecoverable event loss (drills FM-04, FM-09, FM-16) | 0 | | |
| ClickHouse replay duplicate rate (FM-19) | <= 0.1% | | |
| Drill suite total execution time | < 4 hours | | |
| Drill first-run pass rate | >= 80% (16/20) | | |

---

## Drill Results Log

| drill_id | run_date | pass | mttr_s | notes |
|---|---|---|---|---|
| FM-01 | | | | |
| FM-02 | | | | |
| FM-03 | | | | |
| FM-04 | | | | |
| FM-05 | | | | |
| FM-06 | | | | |
| FM-07 | | | | |
| FM-08 | | | | |
| FM-09 | | | | |
| FM-10 | | | | |
| FM-11 | | | | |
| FM-12 | | | | |
| FM-13 | | | | |
| FM-14 | | | | |
| FM-15 | | | | |
| FM-16 | | | | |
| FM-17 | | | | |
| FM-18 | | | | |
| FM-19 | | | | |
| FM-20 | | | | |

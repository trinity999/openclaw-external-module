# EXECUTION TRACKER — Pandavs Scan Pipeline Hardening
## 36-Hour Implementation Window

**Session Start:** _______________  (fill in: ISO8601 timestamp)
**Operator:** _______________
**Scanner State at Start:** _______________ chunks COMPLETED / 51 total
**DB Path:** `ops/day1/state/scan_persistence.db`
**Tracker Version:** WO-00021 v1.0
**Framework Source:** WO-00019 (architecture) + WO-00020 (strategy)

---

## CRITICAL RULES (READ BEFORE STARTING)

- [ ] WAL mode must remain enabled throughout ALL phases
- [ ] Never modify `dedup key formula` during execution window
- [ ] Never truncate `sink_outbox`
- [ ] Never disable WAL mode
- [ ] Never connect Pandavs before H18 Gate passes
- [ ] Never run schema migrations during active scan
- [ ] Never delete `FAILED_PERMANENT` entries from chunk_queue
- [ ] Never run inline sink writes without outbox

**If any rule is violated:** STOP. Invoke rollback playbook for current phase. Log incident before continuing.

---

## PHASE 1: H0–H6 — Zero-Loss Local Capture

**Phase Start Time:** _______________
**Phase Objective:** Establish SQLite durability layer. All records safe in SQLite before any sink attempt.

### Task Checklist

#### T001 — Enable SQLite WAL Mode
- **Assigned Hour Window:** H0–H1
- **Started At:** _______________
- **Completed At:** _______________
- **Acceptance Test:** Run `PRAGMA journal_mode` → must return `wal`
  - [ ] `PRAGMA journal_mode` returns `wal`
  - [ ] Concurrent read during active write succeeds without `SQLITE_BUSY`
- **Result:** [ ] PASS  [ ] FAIL
- **Notes:** _______________

#### T002 — Initialize chunk_queue Table
- **Assigned Hour Window:** H0–H2
- **Dependencies:** T001 PASS
- **Started At:** _______________
- **Completed At:** _______________
- **Acceptance Tests:**
  - [ ] `chunk_queue` table exists with all columns (chunk_id, status, worker_id, leased_at, lease_expires_at, last_heartbeat_at, completed_at, retry_count, max_retries, record_count_produced, error_class, error_message, created_at, updated_at)
  - [ ] `SELECT count(*) FROM chunk_queue` returns `51`
  - [ ] `idx_cq_status` index present
  - [ ] `idx_cq_lease_expires` index present (WHERE status='LEASED' partial)
- **Result:** [ ] PASS  [ ] FAIL
- **Notes:** _______________

#### T003 — Implement grant_lease() with IMMEDIATE Isolation
- **Assigned Hour Window:** H1–H3
- **Dependencies:** T002 PASS
- **Started At:** _______________
- **Completed At:** _______________
- **Acceptance Tests:**
  - [ ] 10 concurrent lease requests yield exactly 1 successful grant per chunk
  - [ ] No duplicate `LEASED` rows observable at any concurrency level
  - [ ] `conn.isolation_level = 'IMMEDIATE'` confirmed in implementation
- **Result:** [ ] PASS  [ ] FAIL
- **Notes:** _______________

#### T004 — Create sink_outbox and sink_sync_ledger Tables
- **Assigned Hour Window:** H2–H4
- **Dependencies:** T001 PASS
- **Started At:** _______________
- **Completed At:** _______________
- **Acceptance Tests:**
  - [ ] `sink_outbox` table exists with `UNIQUE(record_id)` constraint
  - [ ] Insert of duplicate `record_id` raises `UNIQUE constraint failed` (not generic error)
  - [ ] `sink_sync_ledger` table exists
- **Result:** [ ] PASS  [ ] FAIL
- **Notes:** _______________

#### T005 — Integrate Outbox Write into persistence_gateway.py
- **Assigned Hour Window:** H3–H5
- **Dependencies:** T003 PASS, T004 PASS
- **Started At:** _______________
- **Completed At:** _______________
- **Acceptance Tests:**
  - [ ] Every chunk completion writes ≥1 record to `sink_outbox` before returning
  - [ ] WAL durability confirmed via fsync checkpoint (no data loss on simulated crash)
  - [ ] Zero records in source that are absent from `sink_outbox` after chunk completes
- **Result:** [ ] PASS  [ ] FAIL
- **Notes:** _______________

#### T006 — Deploy Master Status Query as Monitoring Baseline
- **Assigned Hour Window:** H5–H6
- **Dependencies:** T002 PASS, T004 PASS
- **Started At:** _______________
- **Completed At:** _______________
- **Acceptance Tests:**
  - [ ] Status query returns in <100ms
  - [ ] Baseline snapshot captured and saved (timestamp + values)
  - [ ] All columns non-null in baseline snapshot
- **Baseline Snapshot (H1):**
  ```
  chunks_pending: ___
  chunks_leased: ___
  chunks_completed: ___
  chunks_failed: ___
  outbox_pending: ___
  outbox_synced: ___
  outbox_dead_letter: ___
  ```
- **Result:** [ ] PASS  [ ] FAIL
- **Notes:** _______________

---

### H6 GO-GATE EVALUATION

**Evaluated At:** _______________
**Evaluator:** _______________

| # | Gate Criterion | Query / Test | Actual Result | Pass? |
|---|---------------|-------------|---------------|-------|
| 1 | WAL active | `PRAGMA journal_mode` | ___________ | [ ] |
| 2 | chunk_queue populated | `SELECT count(*) FROM chunk_queue` | ___________ | [ ] |
| 3 | sink_outbox receiving records | `SELECT count(*) FROM sink_outbox WHERE created_at > datetime('now','-5 minutes')` | ___________ | [ ] |
| 4 | Zero SQLITE_BUSY errors in last 30 min | Error log scan | ___________ | [ ] |
| 5 | Master status query baseline logged | Monitor output | ___________ | [ ] |

**H6 Gate Decision:**
- [ ] **GO** — All 5 criteria pass. Proceed to Phase 2.
- [ ] **NO-GO** — One or more criteria fail. Criteria failing: _______________

**If NO-GO:** Document failing criteria above. Fix. Re-evaluate at H: ___

---

## PHASE 2: H6–H18 — Sink Connection + Queue Lifecycle

**Phase Start Time:** _______________  (must be ≥ H6 Gate PASS time)
**Phase Objective:** Connect live sinks, harden queue lifecycle, prove SLO-1 (zero duplicate chunks).

### Task Checklist

#### T007 — Implement Outbox Sweep (Dry-Run First)
- **Assigned Hour Window:** H6–H8
- **Dependencies:** T005 PASS
- **Started At:** _______________
- **Completed At:** _______________
- **Acceptance Tests:**
  - [ ] Dry-run mode: all pending outbox records logged, zero sink writes executed
  - [ ] Zero records dropped during dry-run
  - [ ] Record format valid (no parse errors in dry-run log)
  - [ ] Dry-run log reviewed and signed off before enabling live writes
- **Result:** [ ] PASS  [ ] FAIL
- **Notes:** _______________

#### T008 — Implement Heartbeat + Stale Lease Reclaim
- **Assigned Hour Window:** H7–H9
- **Dependencies:** T003 PASS
- **Started At:** _______________
- **Completed At:** _______________
- **Acceptance Tests:**
  - [ ] `heartbeat()` updates `last_heartbeat_at` within 1 cycle after call
  - [ ] `reclaim_expired_leases()` resets LEASED rows older than 2× heartbeat interval to PENDING
  - [ ] Inject stale lease test: lease not reclaimed before 2× interval, reclaimed after
- **Heartbeat Interval Configured:** _______________ seconds
- **Result:** [ ] PASS  [ ] FAIL
- **Notes:** _______________

#### T009 — Deploy Backpressure Controller
- **Assigned Hour Window:** H8–H11
- **Dependencies:** T007 PASS, T008 PASS
- **Started At:** _______________
- **Completed At:** _______________
- **Acceptance Tests:**
  - [ ] `outbox_pending_depth > 10000` → scanner concurrency reduced 25% (logged)
  - [ ] `outbox_pending_depth > 50000` → new lease grants halted (logged)
  - [ ] ORS receives backpressure signal within 1 heartbeat cycle
  - [ ] Backpressure auto-releases when depth drops below threshold
- **Result:** [ ] PASS  [ ] FAIL
- **Notes:** _______________

#### T010 — Run SLO-1 + SLO-2 Drills
- **Assigned Hour Window:** H9–H13
- **Dependencies:** T008 PASS, T009 PASS
- **Started At:** _______________
- **Completed At:** _______________

**SLO-1 DRILL (Duplicate Chunk Execution):**
- Query: `SELECT chunk_id, count(*) FROM chunk_queue WHERE status='COMPLETED' GROUP BY chunk_id HAVING count(*)>1`
- Expected: 0 rows returned
- Actual rows returned: _______________
- [ ] **SLO-1 PASS** (0 rows)  [ ] **SLO-1 FAIL** (any rows)

⚠️ **IF SLO-1 FAILS: STOP. DO NOT CONTINUE TO T011. DO NOT ENTER PHASE 3. Fix lease isolation and re-run drill.**

**SLO-2 DRILL (Outbox Age):**
- Query: `SELECT max((julianday('now') - julianday(created_at))*24) FROM sink_outbox WHERE synced_at IS NULL`
- Expected: < 2.0 hours
- Actual value: _______________ hours
- [ ] **SLO-2 PASS** (< 2.0h)  [ ] **SLO-2 FAIL** (≥ 2.0h)

**T010 Result:** [ ] PASS (both SLOs pass)  [ ] FAIL
- **Notes:** _______________

#### T011 — Validate Outbox Age Under Load; Enable Live Sink Writes
- **Assigned Hour Window:** H11–H14
- **Dependencies:** T010 PASS
- **Started At:** _______________
- **Completed At:** _______________
- **Acceptance Tests:**
  - [ ] Oldest pending outbox record age < 2h confirmed under simulated full throughput
  - [ ] Dry-run passed T007 (prerequisite)
  - [ ] Live sink write mode enabled
  - [ ] First live sync batch confirmed: `SELECT count(*) FROM sink_outbox WHERE synced_at IS NOT NULL` > 0
- **Result:** [ ] PASS  [ ] FAIL
- **Notes:** _______________

#### T012 — Deploy Hourly Monotonic Metrics Cron
- **Assigned Hour Window:** H13–H16
- **Dependencies:** T005 PASS, T011 PASS
- **Started At:** _______________
- **Completed At:** _______________
- **Acceptance Tests:**
  - [ ] Cron reads `chunk_queue.record_count_produced` (not file counts)
  - [ ] Cron reads `sink_outbox.synced_count` (not file counts)
  - [ ] 3 consecutive hourly reports show monotonically increasing values
  - [ ] No file-system count used in any report output
- **3 Consecutive Reports (fill in):**

  | Hour | events_persisted | sink_synced_count | Monotonic? |
  |------|-----------------|-------------------|------------|
  | H___ | ___________ | ___________ | [ ] |
  | H___ | ___________ | ___________ | [ ] |
  | H___ | ___________ | ___________ | [ ] |

- **Result:** [ ] PASS  [ ] FAIL
- **Notes:** _______________

---

### H18 GO-GATE EVALUATION (HARD GATE — BLOCKS PATH B)

**Evaluated At:** _______________
**Evaluator:** _______________

| # | Gate Criterion | Query / Test | Actual Result | Pass? |
|---|---------------|-------------|---------------|-------|
| 1 | SLO-1: Zero duplicate chunk executions | `SELECT chunk_id, count(*) ... HAVING count(*)>1` | ___________ rows | [ ] |
| 2 | SLO-2: Outbox age < 2h | `max((julianday now - created_at)*24) WHERE synced_at IS NULL` | ___________ h | [ ] |
| 3 | Heartbeat reclaim working | Inject stale lease test | ___________ | [ ] |
| 4 | Backpressure signals active | Inject depth >10001 test | ___________ | [ ] |
| 5 | DB-derived cron deployed (3 monotonic reports) | Report log | ___________ | [ ] |
| 6 | Live sink writes confirmed | `count(*) WHERE synced_at IS NOT NULL` | ___________ | [ ] |

**H18 Gate Decision:**
- [ ] **GO** — All 6 criteria pass. Proceed to Phase 3.
- [ ] **NO-GO** — One or more criteria fail. Criteria failing: _______________

⚠️ **SLO-1 FAIL = MANDATORY STOP. Phase 3 is BLOCKED regardless of all other criteria.**

**If NO-GO:** Fix failing criteria. Re-evaluate at H: ___. Phase 3 start shifts accordingly.

---

## PHASE 3: H18–H36 — Pandavs Parallel Sink Integration

**Phase Start Time:** _______________  (must be ≥ H18 Gate PASS time)
**Phase Objective:** Add Pandavs as parallel sink. Verify integrity. Prepare for Path B promotion.

⚠️ **Phase 3 is ADDITIVE. SQLite outbox sweep continues unchanged throughout Phase 3.**

### Task Checklist

#### T013 — Validate Pandavs Connectivity + Schema Compatibility
- **Assigned Hour Window:** H18–H20
- **Dependencies:** H18 Gate PASS
- **Started At:** _______________
- **Completed At:** _______________
- **Acceptance Tests:**
  - [ ] Pandavs module responds on configured endpoint
  - [ ] Schema compatibility check passes (zero type mismatches)
  - [ ] Host runtime match confirmed (Python version, library versions)
  - [ ] Test write of 1 record succeeds and is retrievable from Pandavs
- **Result:** [ ] PASS  [ ] FAIL
- **If FAIL:** [ ] Abort Phase 3. Maintain Path A indefinitely. Document reason: _______________

#### T014 — Add Pandavs as Parallel sink_target in sink_outbox
- **Assigned Hour Window:** H19–H22
- **Dependencies:** T013 PASS
- **Started At:** _______________
- **Completed At:** _______________
- **Acceptance Tests:**
  - [ ] `sink_outbox` sweep writes to both SQLite sink AND `sink_target='pandavs'`
  - [ ] Zero records dropped during dual-write activation
  - [ ] SQLite outbox sweep continues unmodified alongside Pandavs writes
  - [ ] Pandavs write errors logged and do NOT affect SQLite outbox records
- **Result:** [ ] PASS  [ ] FAIL
- **Notes:** _______________

#### T015 — Dual-Write Verification: Row Count Comparison
- **Assigned Hour Window:** H21–H25
- **Dependencies:** T014 PASS
- **Started At:** _______________
- **3h Dual-Write Window Ends At:** _______________
- **Acceptance Tests:**
  - [ ] After 3h dual-write: `sink_outbox.synced_count` = _______________
  - [ ] After 3h dual-write: Pandavs `ingested_count` = _______________
  - [ ] Delta %: `|pandavs_count - outbox_count| / outbox_count * 100` = _______________ %
  - [ ] Delta < 1.0%
- **Result:** [ ] PASS (delta < 1%)  [ ] FAIL (delta ≥ 1%)
- **If FAIL:** Pause dual-write. Audit missing records. Do NOT proceed to T016.

#### T016 — DB-Derived Metrics: Pandavs Comparison Column
- **Assigned Hour Window:** H23–H27
- **Dependencies:** T015 PASS
- **Started At:** _______________
- **Completed At:** _______________
- **Acceptance Tests:**
  - [ ] Hourly report includes `sink_outbox.synced_count` column
  - [ ] Hourly report includes `pandavs_ingest_count` column
  - [ ] Delta column computed each hour
  - [ ] Both columns monotonically increasing across reported window

  | Hour | outbox_synced | pandavs_ingest | delta_pct | Both Monotonic? |
  |------|--------------|----------------|-----------|----------------|
  | H___ | ___________ | ___________ | ___% | [ ] |
  | H___ | ___________ | ___________ | ___% | [ ] |
  | H___ | ___________ | ___________ | ___% | [ ] |

- **Result:** [ ] PASS  [ ] FAIL
- **Notes:** _______________

#### T017 — MTTR Drill: Kill Pandavs, Measure Restart + Catch-Up
- **Assigned Hour Window:** H27–H30
- **Dependencies:** T015 PASS
- **Drill Start Time:** _______________
- **Pandavs Killed At:** _______________
- **Pandavs Restarted At:** _______________
- **Catch-Up Complete At:** _______________
- **Total MTTR:** _______________ minutes
- **Acceptance Test:** MTTR < 15 minutes
- **Result:** [ ] PASS (<15 min)  [ ] FAIL (≥15 min)
- **Notes:** _______________

#### T018 — Contingency Validation: Rollback Test
- **Assigned Hour Window:** H27–H30
- **Dependencies:** T014 PASS
- **Test Start Time:** _______________
- **Rollback Initiated At:** _______________
- **Path A Restored At:** _______________
- **Total Rollback Time:** _______________ minutes
- **Acceptance Tests:**
  - [ ] Disabling `sink_target='pandavs'` restores Path A within 5 minutes
  - [ ] Zero records lost on rollback (outbox pending depth unchanged)
  - [ ] Outbox pending depth post-rollback: _______________
- **Result:** [ ] PASS  [ ] FAIL
- **Notes:** _______________

---

### H36 GO-GATE EVALUATION (PATH B PROMOTION)

**Evaluated At:** _______________
**Evaluator:** _______________

| # | Gate Criterion | Method | Actual Result | Pass? |
|---|---------------|--------|---------------|-------|
| 1 | Integrity delta < 1% | T015 result | ___% | [ ] |
| 2 | Hourly monotonicity 100% for 18h | T016 report log | ___________ | [ ] |
| 3 | MTTR drill < 15 min | T017 result | ___ min | [ ] |
| 4 | Rollback test < 5 min / 0 records lost | T018 result | ___________ | [ ] |
| 5 | Dead letter count = 0 | `count(*) WHERE status='DEAD_LETTER'` | ___________ | [ ] |
| 6 | Zero unhandled Pandavs crashes in 18h | Error log | ___________ | [ ] |

**H36 Gate Decision:**
- [ ] **GO** — All 6 criteria pass. Pandavs promoted to primary sink. SQLite outbox sweep disabled for Pandavs path.
- [ ] **NO-GO** — One or more criteria fail. **ROLLBACK TO PATH A INDEFINITELY.**

**If NO-GO:** Disable `sink_target='pandavs'`. Document failure mode: _______________
**Path B retry window:** Schedule new 36h window after root cause resolved. Do not retry within same window.

---

## HOURLY REPORT LOG

Fill in at each hourly mark. `sink_lag_h > 2.0` is an immediate blocker regardless of phase.

| Hour | Phase | chunks_done | coverage_pct | events_persisted | sink_lag_h | eta_h | blockers | gate_status | active_tasks |
|------|-------|------------|-------------|-----------------|------------|-------|----------|-------------|-------------|
| H1 | H0-H6 | | | | | | | N/A | |
| H2 | H0-H6 | | | | | | | N/A | |
| H3 | H0-H6 | | | | | | | N/A | |
| H4 | H0-H6 | | | | | | | N/A | |
| H5 | H0-H6 | | | | | | | N/A | |
| H6 | H0-H6 | | | | | | | **GATE** | |
| H7 | H6-H18 | | | | | | | N/A | |
| H8 | H6-H18 | | | | | | | N/A | |
| H9 | H6-H18 | | | | | | | N/A | |
| H10 | H6-H18 | | | | | | | N/A | |
| H11 | H6-H18 | | | | | | | N/A | |
| H12 | H6-H18 | | | | | | | N/A | |
| H13 | H6-H18 | | | | | | | N/A | |
| H14 | H6-H18 | | | | | | | N/A | |
| H15 | H6-H18 | | | | | | | N/A | |
| H16 | H6-H18 | | | | | | | N/A | |
| H17 | H6-H18 | | | | | | | N/A | |
| H18 | H6-H18 | | | | | | | **GATE** | |
| H19 | H18-H36 | | | | | | | N/A | |
| H20 | H18-H36 | | | | | | | N/A | |
| H21 | H18-H36 | | | | | | | N/A | |
| H22 | H18-H36 | | | | | | | N/A | |
| H23 | H18-H36 | | | | | | | N/A | |
| H24 | H18-H36 | | | | | | | N/A | |
| H25 | H18-H36 | | | | | | | N/A | |
| H26 | H18-H36 | | | | | | | N/A | |
| H27 | H18-H36 | | | | | | | N/A | |
| H28 | H18-H36 | | | | | | | N/A | |
| H29 | H18-H36 | | | | | | | N/A | |
| H30 | H18-H36 | | | | | | | N/A | |
| H31 | H18-H36 | | | | | | | N/A | |
| H32 | H18-H36 | | | | | | | N/A | |
| H33 | H18-H36 | | | | | | | N/A | |
| H34 | H18-H36 | | | | | | | N/A | |
| H35 | H18-H36 | | | | | | | N/A | |
| H36 | H18-H36 | | | | | | | **GATE** | |

**SQL to generate one hourly row:**
```sql
SELECT
  count(CASE WHEN status='COMPLETED' THEN 1 END)       AS chunks_done,
  round(count(CASE WHEN status='COMPLETED' THEN 1 END) * 100.0 / 51, 2) AS coverage_pct,
  sum(CASE WHEN record_count_produced IS NOT NULL THEN record_count_produced ELSE 0 END) AS events_persisted
FROM chunk_queue;

SELECT
  round(max((julianday('now') - julianday(created_at)) * 24), 2) AS sink_lag_h
FROM sink_outbox
WHERE synced_at IS NULL;
```

---

## INCIDENT LOG

Use this section to record any blocker, anomaly, or gate failure during the execution window.

| Timestamp | Phase | Task | Incident | Action Taken | Resolved At |
|-----------|-------|------|----------|-------------|-------------|
| | | | | | |
| | | | | | |
| | | | | | |

---

## FINAL STATUS

**H36 Reached At:** _______________
**Outcome:**
- [ ] PATH B PROMOTED — Pandavs is primary sink. SQLite outbox sweep disabled for Pandavs path.
- [ ] PATH A INDEFINITE — H36 gate failed. Pandavs deferred. Root cause: _______________
- [ ] PARTIAL — H18 gate failed. Phase 3 deferred. Root cause: _______________

**Total chunks completed:** _______________ / 51
**Total events persisted:** _______________
**Final sink_lag_h:** _______________
**Gate summary:** H6: [ ] PASS [ ] FAIL | H18: [ ] PASS [ ] FAIL | H36: [ ] PASS [ ] FAIL / N/A

**Operator sign-off:** _______________ at _______________

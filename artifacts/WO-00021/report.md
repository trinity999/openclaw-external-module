# WO-00021 — Execution Tracking Framework
## Hour-Based Implementation Tracker for Pandavs Scan Pipeline Hardening

**Status:** COMPLETED
**Category:** execution-tracking
**Priority:** CRITICAL
**Analyst:** openclaw-field-processor
**Produced:** 2026-03-04
**Depends On:** WO-00019 (architecture), WO-00020 (strategy)

---

## 1. Purpose and Scope

This framework translates the architectural recommendations of WO-00019 and the merged implementation strategy of WO-00020 into an operational execution tracker. Its purpose is threefold:

1. **Track** — Every task is assigned a precise hour window, owner slot, dependency chain, and acceptance test. Nothing is "done" without passing its test.
2. **Gate** — Each phase ends with an explicit go/no-go evaluation. Promotion to the next phase is evidence-gated, not time-gated.
3. **Rollback** — Every gate has a defined rollback action. There is no ambiguous "partial" state.

The 36-hour window is divided into three phases:

| Phase | Window | Objective | Path |
|-------|--------|-----------|------|
| Phase 1 | H0–H6 | Zero-loss local capture | Path A |
| Phase 2 | H6–H18 | Sink connection + queue lifecycle | Path A |
| Phase 3 | H18–H36 | Pandavs parallel sink integration | Path B (additive) |

Phase 3 begins **only** if and when the H18 Go-Gate passes. If the H18 gate fails, Path A continues indefinitely and Phase 3 is deferred.

---

## 2. Foundational Constraints (Non-Negotiable)

These constraints apply to all tasks in all phases. Violation at any point is grounds for immediate rollback regardless of phase.

| Constraint | Requirement |
|-----------|-------------|
| `write_before_sink` | Every record durably written to SQLite before any sink attempt |
| `idempotent_write` | Duplicate `record_id` insert = 0 additional rows (UNIQUE constraint enforced) |
| `no_schema_breaking` | New columns only; no DROP, RENAME, type changes without versioned migration |
| `audit_log_preserved` | `chunk_queue_audit_log` is append-only; no deletes |
| `rollback_path` | Every task reversible without data loss |
| `unique_constraint` | UNIQUE on `record_id` in `sink_outbox` and all sink tables |
| `no_scan_pause` | Active scanning must not be paused longer than the heartbeat interval |
| `wal_mode_always` | SQLite WAL mode must remain enabled throughout all phases |

---

## 3. Phase 1: H0–H6 — Zero-Loss Local Capture

**Objective:** Establish the foundational SQLite durability layer. All records safe in SQLite before any sink is attempted.

### 3.1 Task Matrix

| Task ID | Task | H-Min | H-Max | Dependencies | Acceptance Test |
|---------|------|-------|-------|-------------|----------------|
| T001 | Enable SQLite WAL mode | H0 | H1 | — | `PRAGMA journal_mode` returns `WAL`; concurrent read during active write succeeds without `SQLITE_BUSY` |
| T002 | Initialize `chunk_queue` table | H0 | H2 | T001 | Table exists with all columns per WO-00019 schema; 51 rows inserted; `idx_cq_status` and `idx_cq_lease_expires` indexes present |
| T003 | Implement `grant_lease()` with IMMEDIATE isolation | H1 | H3 | T002 | 10 concurrent lease requests yield exactly 1 successful grant per chunk; no duplicate `LEASED` rows observable at any point |
| T004 | Create `sink_outbox` and `sink_sync_ledger` tables | H2 | H4 | T001 | `sink_outbox` exists with `UNIQUE(record_id)` constraint; inserting duplicate `record_id` raises `UNIQUE constraint failed`, not generic error |
| T005 | Integrate outbox write into `persistence_gateway.py` | H3 | H5 | T003, T004 | Every chunk completion writes ≥1 record to `sink_outbox` before returning; WAL durability confirmed via fsync checkpoint |
| T006 | Deploy master status query as monitoring baseline | H5 | H6 | T002, T004 | Query returns chunk counts by status and outbox pending depth in <100ms; baseline snapshot captured and logged |

### 3.2 Dependency Graph (Phase 1)

```
T001 (WAL)
  ├── T002 (chunk_queue) ──→ T003 (grant_lease) ──→ T005 (outbox write)
  └── T004 (sink_outbox) ──→ T005 (outbox write)
                                                    T006 (status query)
```

### 3.3 H6 Go-Gate

**ALL criteria must be TRUE to promote to Phase 2:**

| Gate Criterion | Verification Method | Pass Condition |
|----------------|--------------------|--------------------|
| WAL active | `PRAGMA journal_mode` | Returns `wal` |
| chunk_queue populated | `SELECT count(*) FROM chunk_queue` | Returns 51 |
| sink_outbox receiving | `SELECT count(*) FROM sink_outbox WHERE created_at > datetime('now','-5 minutes')` | > 0 |
| No SQLITE_BUSY errors | Error log scan | Zero `SQLITE_BUSY` in last 30 min |
| Status query baseline | Monitor output | Snapshot logged with non-null values for all columns |

**No-Go Action (if any criterion fails):** Do not proceed to Phase 2. Fix the failing criterion. Re-run H6 gate evaluation. Phase 2 start time shifts accordingly.

### 3.4 Phase 1 Rollback Playbook

| Scenario | Rollback Action |
|----------|----------------|
| WAL mode causes I/O errors | `PRAGMA journal_mode=DELETE` — revert to rollback journal; investigate disk/filesystem |
| chunk_queue schema conflict | Drop and recreate `chunk_queue` (data is at-source; replay from chunk files) |
| grant_lease() deadlock loop | Disable lease system; revert to file-list dispatch; preserve existing scan output |
| sink_outbox constraint failure | Drop and recreate `sink_outbox` (no records synced yet; replay from outbox) |
| persistence_gateway crash loop | Revert to previous `persistence_gateway.py`; all prior SQLite data preserved |

---

## 4. Phase 2: H6–H18 — Sink Connection + Queue Lifecycle

**Objective:** Connect the sink outbox to live sinks, harden queue lifecycle (heartbeat + reclaim), install backpressure, and prove zero duplicate chunk execution in SLO-1 drill.

### 4.1 Task Matrix

| Task ID | Task | H-Min | H-Max | Dependencies | Acceptance Test |
|---------|------|-------|-------|-------------|----------------|
| T007 | Implement outbox sweep (dry-run first) | H6 | H8 | T005 | Dry-run: all pending outbox records logged, zero sink writes, zero records dropped; log confirms record format valid |
| T008 | Implement heartbeat + stale lease reclaim | H7 | H9 | T003 | `heartbeat()` updates `last_heartbeat_at`; `reclaim_expired_leases()` returns LEASED rows older than 2× heartbeat interval to PENDING |
| T009 | Deploy backpressure controller | H8 | H11 | T007, T008 | `outbox_pending_depth > 10000` → scanner concurrency reduced 25%; `> 50000` → new lease grants halted; ORS receives signal within 1 heartbeat cycle |
| T010 | Run SLO-1 + SLO-2 drills | H9 | H13 | T008, T009 | SLO-1: 0 duplicate `chunk_id` rows in any completed_at window; SLO-2: no outbox record older than 2h under normal throughput |
| T011 | Validate outbox age; enable live sink writes | H11 | H14 | T010 | Oldest pending outbox record < 2h confirmed under simulated full throughput; live sink mode enabled after dry-run passes |
| T012 | DB-derived hourly monotonic metrics cron | H13 | H16 | T005, T011 | Cron reads `chunk_queue.record_count_produced` and `sink_outbox.synced_count`; output monotonically increasing across 3 consecutive hours; no file-system count in output |

### 4.2 Dependency Graph (Phase 2)

```
T007 (outbox sweep)
  ↑ T005
T008 (heartbeat+reclaim)
  ↑ T003
T009 (backpressure) ← T007, T008
T010 (SLO drills) ← T008, T009   ← CRITICAL GATE BLOCKER
T011 (live sink write) ← T010
T012 (DB metrics cron) ← T005, T011
```

### 4.3 H18 Go-Gate (Hard Gate — Blocks All Path B Work)

**ALL criteria must be TRUE. This is the single most important gate in the entire 36h window.**

| Gate Criterion | Verification Method | Pass Condition |
|----------------|--------------------|--------------------|
| SLO-1: Zero duplicate chunk executions | `SELECT chunk_id, count(*) FROM chunk_queue WHERE status='COMPLETED' GROUP BY chunk_id HAVING count(*)>1` | Returns 0 rows |
| SLO-2: Outbox age | `SELECT max((julianday('now') - julianday(created_at))*24) FROM sink_outbox WHERE synced_at IS NULL` | < 2.0 hours |
| Heartbeat reclaim working | Inject stale lease; confirm auto-reclaim within 2× heartbeat interval | Stale lease → PENDING in ≤ 2× interval |
| Backpressure signals active | Inject 10001 pending records; confirm concurrency reduction logged | Concurrency reduction logged within 1 cycle |
| DB-derived cron deployed | Check 3 consecutive hourly reports | All 3 monotonically increasing, no file counts |
| Live sink writes confirmed | `SELECT count(*) FROM sink_outbox WHERE synced_at IS NOT NULL` | > 0 |

**No-Go Action:** If SLO-1 fails (any duplicates detected): **DO NOT START PHASE 3 UNDER ANY CIRCUMSTANCES.** The lease system has a correctness bug. Stop, fix `grant_lease()` isolation, re-run SLO-1 drill. Phase 3 is blocked until SLO-1 passes clean.

If any other criterion fails: Fix the criterion. Re-evaluate. Phase 3 start time shifts accordingly.

### 4.4 Phase 2 Rollback Playbook

| Scenario | Rollback Action |
|----------|----------------|
| Outbox sweep drops records | Halt sweep; run outbox integrity check (`count(*) WHERE synced_at IS NULL vs total`); restore from chunk replay |
| Heartbeat storm (too many reclaims) | Increase heartbeat interval; temporarily disable reclaim; manually inspect LEASED rows |
| Backpressure controller halts scanning | Override: set `outbox_pending_depth_override = 0`; investigate sink write failures causing depth growth |
| SLO-1 fails (duplicate chunks) | Rollback `grant_lease()` to previous version; switch to file-list dispatch; audit `chunk_queue` for source of duplication |
| Live sink write fails permanently | Disable live write mode; return to dry-run; investigate sink connectivity / schema mismatch |
| DB cron produces non-monotonic output | Halt cron; investigate record deletion or incorrect query; revert to previous reporting method |

---

## 5. Phase 3: H18–H36 — Pandavs Parallel Sink Integration

**Phase 3 starts ONLY after H18 Go-Gate passes with all criteria TRUE.**

**Objective:** Add Pandavs as a second, parallel sink alongside SQLite outbox. Verify data integrity across both sinks. Prepare for Path B promotion if H36 gate passes.

### 5.1 Task Matrix

| Task ID | Task | H-Min | H-Max | Dependencies | Acceptance Test |
|---------|------|-------|-------|-------------|----------------|
| T013 | Validate Pandavs connectivity + schema compatibility | H18 | H20 | GATE-H18 | Pandavs module responds; schema compatibility check passes (no type mismatches); host runtime match confirmed |
| T014 | Add Pandavs as parallel `sink_target` in `sink_outbox` | H19 | H22 | T013 | `sink_outbox` sweep writes to both SQLite sink AND Pandavs; zero records dropped during dual-write activation; SQLite sweep continues |
| T015 | Dual-write verification: row count comparison | H21 | H25 | T014 | Row count delta between `sink_outbox.synced_count` and Pandavs `ingested_count` < 1% after 3h dual-write window |
| T016 | DB-derived metrics: add Pandavs sink comparison column | H23 | H27 | T015 | Hourly report includes `sink_outbox.synced_count` and `pandavs_ingest_count` side-by-side; delta column computed; both monotonically increasing |
| T017 | MTTR drill: kill Pandavs, measure restart+catch-up | H27 | H30 | T015 | Pandavs module killed; restart + full catch-up to current outbox head completed in < 15 minutes |
| T018 | Contingency validation: rollback test | H27 | H30 | T014 | Disabling `sink_target='pandavs'` restores Path A fully within 5 minutes; zero records lost on rollback; outbox shows correct pending depth |

### 5.2 Dependency Graph (Phase 3)

```
GATE-H18
  └── T013 (connectivity) → T014 (dual-write) → T015 (row count) → T016 (metrics)
                                               → T017 (MTTR drill)
                                               → T018 (rollback test)
```

### 5.3 H36 Go-Gate (Path B Promotion)

**ALL criteria must be TRUE to promote Pandavs to primary sink:**

| Gate Criterion | Verification Method | Pass Condition |
|----------------|--------------------|--------------------|
| Integrity delta | `(pandavs_count - outbox_synced_count) / outbox_synced_count * 100` | < 1.0% |
| Hourly monotonicity | 18h of hourly reports | 100% monotonically increasing for both sink columns |
| MTTR drill | T017 result | Restart + catch-up < 15 minutes |
| Rollback test | T018 result | < 5 min rollback; 0 records lost |
| Dead letter rate | `SELECT count(*) FROM sink_outbox WHERE status='DEAD_LETTER'` | 0 (or explainable with root cause + fix) |
| Pandavs runtime stability | Error log | Zero unhandled Pandavs module crashes in 18h window |

**No-Go Action:** If H36 gate fails: **Rollback to Path A indefinitely.** Disable `sink_target='pandavs'` in outbox sweep. Document failure mode. Path B integration deferred until root cause resolved and new 36h window scheduled.

### 5.4 Phase 3 Rollback Playbook

| Scenario | Rollback Action |
|----------|----------------|
| T013 fails (schema incompatible) | Abort Phase 3; maintain Path A indefinitely; do not attempt T014 |
| T013 fails (runtime mismatch) | Abort Phase 3; document host dependency gap; escalate |
| Pandavs sink drops records during T014 | Halt Pandavs writes; verify all records still in SQLite outbox; investigate Pandavs error log |
| Row count delta > 1% in T015 | Pause dual-write; run integrity audit; identify missing records; do not proceed to T016 until delta < 1% |
| MTTR > 15 min in T017 | Do not promote; investigate catch-up throughput; optimize or defer |
| Rollback test fails in T018 | Critical: rollback mechanism is broken; halt Phase 3; restore Path A manually; audit outbox |

---

## 6. Hourly Report Schema

Every hour of the execution window, the following metrics must be captured and logged. This schema is the ground truth for all phase gate evaluations and leadership reporting.

```json
{
  "report_hour": "<int — hour offset from start, e.g. 3>",
  "reported_at": "<ISO8601 timestamp>",
  "current_phase": "<H0-H6 | H6-H18 | H18-H36>",
  "chunks_done": "<int — count of chunk_queue WHERE status='COMPLETED'>",
  "coverage_pct": "<float — chunks_done / 51 * 100>",
  "events_persisted": "<int — sum(record_count_produced) FROM chunk_queue>",
  "sink_lag_h": "<float — max((now - created_at) in hours) WHERE synced_at IS NULL in sink_outbox>",
  "eta_h": "<float — estimated hours to H36 gate or current phase completion>",
  "blockers": "<list[string] — active blockers by task ID or description; empty list if none>",
  "gate_status": "<PENDING | PASS | FAIL | N/A>",
  "active_task_ids": "<list[string] — task IDs currently in progress>"
}
```

**Derivation rules:**
- `chunks_done`: `SELECT count(*) FROM chunk_queue WHERE status='COMPLETED'`
- `coverage_pct`: `chunks_done / 51.0 * 100` — use DB count, not file count
- `events_persisted`: `SELECT sum(record_count_produced) FROM chunk_queue WHERE record_count_produced IS NOT NULL`
- `sink_lag_h`: `SELECT max((julianday('now') - julianday(created_at)) * 24) FROM sink_outbox WHERE synced_at IS NULL`
- `eta_h`: Estimated by current task progress vs remaining task budget in hour_budget_matrix.csv
- `blockers`: Human-populated field; any gate criterion that cannot currently pass

**Non-negotiable:** `sink_lag_h` is the canary metric. If it exceeds 2.0h at any point during Phases 1–2, it is an immediate blocker, regardless of phase and regardless of other metrics.

---

## 7. Risk Escalation Protocol

| Risk Signal | Threshold | Escalation Action |
|-------------|-----------|------------------|
| `sink_lag_h` | > 2.0h | Immediate: reduce concurrency 50%; alert operator |
| Dead letter rate | > 0 | Immediate: investigate DLQ entry; halt if rate > 0.1%/h |
| Duplicate chunk execution | Any | Immediate: rollback to file-list dispatch; halt Phase 2+ |
| Pandavs crash rate | > 0 in 18h window | Block H36 gate; do not promote |
| Row count delta | > 1% | Pause dual-write; audit before continuing |
| Task behind schedule | > 2h late | Escalate to operator; assess gate impact |
| Non-monotonic hourly report | Any | Investigate immediately; block gate evaluation |

---

## 8. Template Reuse Guidelines

This execution tracker is designed for reuse in subsequent scan pipeline hardening cycles:

- **For nuclei/enrichment lane additions**: Replace T001–T006 with nuclei-specific setup tasks; retain Phase 2 backpressure and SLO patterns; Phase 3 gate criteria remain identical
- **For additional worker counts**: Scale heartbeat interval analysis in T008; adjust backpressure thresholds in T009; SLO-1 and SLO-2 remain unchanged
- **For schema-breaking changes**: Requires a new 36h window with a versioned migration task replacing T001; never overlap schema migration with a live Phase 3 window

---

## 9. Summary

| | Phase 1 (H0–H6) | Phase 2 (H6–H18) | Phase 3 (H18–H36) |
|--|--|--|--|
| **Tasks** | T001–T006 | T007–T012 | T013–T018 |
| **Gate** | H6 Go-Gate | H18 Go-Gate (HARD) | H36 Go-Gate |
| **Gate Blocker** | WAL + chunk_queue + outbox | SLO-1 (0 duplicates) | Delta < 1% + MTTR < 15m |
| **Rollback** | Revert schema; restore scan | Revert grant_lease(); file-list dispatch | Disable Pandavs sink_target |
| **Path** | Path A | Path A | Path B (additive) |
| **Total Tasks** | 6 | 6 | 6 |
| **Critical Path (h)** | 5.0 | 8.0 | 12.0 |

**The H18 Go-Gate is the single most important checkpoint.** No Path B work begins until it passes. No exceptions.

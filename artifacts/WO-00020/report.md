# WO-00020: Comparative Strategy — SQLite-First Hardening vs. Native Pandavs Ingestion

**Work Order:** WO-00020
**Category:** operations
**Analyst:** openclaw-field-processor
**Produced:** 2026-03-04
**Confidence:** 0.91
**ARD:** MEDIUM

---

## Executive Summary

Two execution paths are compared:

- **Path A — SQLite-First Hardening**: Treat local SQLite as the durable source of truth. Harden ingest, add lease queue controls, and build the outbox pattern before connecting any primary DB sink. Primary DB sink is connected only after the local layer is provably stable.

- **Path B — Immediate Native Pandavs Integration**: Begin routing scan output directly through Pandavs native ingestion modules, relying on Pandavs' built-in durability guarantees rather than the local SQLite layer.

**Verdict: Path A is recommended for the first 18 hours.** Path B is the correct long-term destination, but attempting it now under active scanning at 10M+ scale introduces runtime dependency risk that Path A avoids. The merged strategy is: execute Path A to reach the stability gate (< 18h), then begin Path B integration as an additive layer on top of the stabilized SQLite foundation.

---

## 1. Path Analysis

### Path A: SQLite-First Hardening

**Core principle:** "Never lose a record; never duplicate a record; always know where every record is."

All scan outputs flow through SQLite first. SQLite is single-node, no-credential, zero-network-dependency. Once a record is committed to SQLite, it is durable regardless of what happens downstream.

**Advantages:**
1. No runtime dependency on external systems (ClickHouse, Neo4j, Pandavs) during scan
2. Instant restart recovery: SQLite state survives process restart without any handshake
3. Observable at any point via SQL queries with no special tooling
4. Replay is trivially safe: re-read from SQLite, write to sink, UNIQUE constraint handles idempotency
5. All 10 prioritized changes from WO-00019 implement this path

**Disadvantages:**
1. SQLite is a single-writer bottleneck at extremely high ingest rates (>10k writes/sec)
2. Two-hop write path (SQLite → ClickHouse) adds latency to report freshness
3. Does not leverage Pandavs' battle-tested ingestion pipelines

**Risk at 10M+ scale:** SQLite WAL mode handles concurrent reads well but single-writer model caps write throughput. At 700k records/hr (194/sec), SQLite in WAL mode with batch writes handles this comfortably. Risk is LOW.

---

### Path B: Immediate Native Pandavs Integration

**Core principle:** Route scan output directly into Pandavs ingestion modules, bypassing or replacing the local SQLite persistence layer.

**Advantages:**
1. Pandavs ingestion is production-hardened and designed for this data model
2. Eliminates the SQLite → primary DB hop; reduces report latency
3. Leverages existing dedup, schema validation, and write-back infrastructure

**Disadvantages:**
1. Requires Pandavs modules to be running and accessible during active scan
2. Any Pandavs module downtime or misconfiguration directly impacts scan results capture
3. Integration requires understanding Pandavs API surface — debugging under active scanning is risky
4. "Big-bang refactor" risk: replacing the capture layer mid-scan can create a data gap

**Risk at 10M+ scale:** HIGH in the first 18 hours. If the Pandavs integration encounters any runtime error (credentials, network partition, schema mismatch), scan output is lost with no local fallback. Recovery requires full chunk replay, which may not be possible if result files have been rotated.

---

## 2. Merged Strategy

The two paths are not mutually exclusive over the full timeline. The optimal sequence:

```
[H0–H6]   Path A: Harden SQLite capture (WAL, chunk queue, outbox)
[H6–H18]  Path A: Connect outbox sweep to ClickHouse/Neo4j sink
[H18–H36] Path B: Add native Pandavs ingestion as a parallel sink
[H36+]    Deprecate outbox sweep; Pandavs becomes primary sink
```

This sequence eliminates the data gap risk of Path B: by the time Pandavs integration begins, every record is already safely in SQLite. Pandavs becomes an additional write path, not a replacement. If Pandavs integration fails, the SQLite outbox sweep continues to serve as the sink.

---

## 3. Hour-Budget Execution Matrix

### Window 0–6h: Foundation Hardening (Path A)

**Objective:** Achieve zero-loss local capture. No scan output should be losable after this window.

| Task ID | Task | Duration (h) | Dependency | Priority |
|---------|------|-------------|-----------|----------|
| T001 | Enable SQLite WAL mode + PRAGMA settings | 0.5 | None | P0 |
| T002 | Create chunk_queue table; migrate 51 chunks | 1.0 | T001 | P0 |
| T003 | Implement grant_lease() with IMMEDIATE isolation | 1.5 | T002 | P0 |
| T004 | Create sink_outbox + sink_sync_ledger tables | 0.5 | T001 | P0 |
| T005 | Modify persistence_gateway.py: write to outbox before sink | 1.5 | T004 | P0 |
| T006 | Deploy master status query as monitoring baseline | 0.5 | T001 | P1 |

**Go gate at H6:**
- [ ] `chunk_queue` has 51 rows; all status=PENDING or COMPLETED
- [ ] `sink_outbox` receiving records (COUNT > 0)
- [ ] Master status query returns results without error
- [ ] SQLite WAL mode confirmed: `PRAGMA journal_mode` returns `wal`

**No-go action:** If T003 (lease grant) not complete by H5, defer to Path A incremental — keep file-list dispatch but add T004/T005 first (outbox hardening is higher ROI than lease).

---

### Window 6–18h: Sink Connection + Queue Lifecycle (Path A continued)

**Objective:** Connect outbox to primary DB sink. Full queue lifecycle with heartbeat and reclaim.

| Task ID | Task | Duration (h) | Dependency | Priority |
|---------|------|-------------|-----------|----------|
| T007 | Implement outbox sweep with retry classification | 3.0 | T005 | P0 |
| T008 | Implement heartbeat() in worker; orchestrator reclaimer cron | 2.0 | T003 | P0 |
| T009 | Implement ConcurrencyController with backpressure thresholds | 1.5 | T004 | P1 |
| T010 | Run SLO drills: SLO-1 (restart), SLO-6 (reclaim) | 2.0 | T007, T008 | P0 |
| T011 | Validate outbox oldest age < 2h under normal ops | 1.0 | T007 | P0 |
| T012 | Deploy hourly status report cron | 0.5 | T006 | P2 |

**Go gate at H18:**
- [ ] 0 duplicate chunk executions in SLO-1 drill
- [ ] Outbox oldest pending age < 2h confirmed over 1h observation window
- [ ] Sweep background thread running with dead letter classification active
- [ ] Heartbeat + reclaim cycle confirmed working (stale lease reclaimed within 5 min)
- [ ] Backpressure signals flowing: depth metric readable from SQLite

**No-go action:** If SLO-1 drill shows any duplicate: halt Path B entry; root-cause and re-drill. If outbox age > 2h: reduce scanner concurrency 25% and re-evaluate at H20.

---

### Window 18–36h: Path B Entry — Pandavs Integration

**Objective:** Add Pandavs native ingestion as a parallel sink alongside the SQLite outbox. Do not remove outbox.

| Task ID | Task | Duration (h) | Dependency | Priority |
|---------|------|-------------|-----------|----------|
| T013 | Validate Pandavs module connectivity + schema compatibility | 2.0 | H18 gate passed | P0 |
| T014 | Add Pandavs as secondary sink_target in sink_outbox | 1.5 | T013 | P0 |
| T015 | Verify dual-write: both ClickHouse/Neo4j AND Pandavs receiving records | 2.0 | T014 | P0 |
| T016 | Compare row counts: outbox SYNCED vs Pandavs ingest log | 1.5 | T015 | P0 |
| T017 | DB-derived monotonic metrics: replace file-count reports | 2.0 | T015 | P1 |
| T018 | Contingency: if Pandavs integration fails, maintain Path A indefinitely | — | — | P0 |

**Go gate at H36:**
- [ ] Integrity delta (SQLite → ClickHouse → Pandavs) < 1% explainable
- [ ] Hourly report monotonicity: 100% (no hour shows lower count than previous)
- [ ] Pandavs ingest log row count within 1% of SQLite outbox SYNCED count
- [ ] MTTR drill: kill Pandavs module; confirm SQLite outbox fills and Pandavs catches up on restart < 15 min

**No-go action:** If row count delta > 1%: pause Pandavs sink, investigate mismatch, do not promote. Keep SQLite outbox as sole authoritative sink until mismatch resolved.

---

## 4. Non-Negotiable Controls (Zero-Loss Guarantees)

The following controls are required regardless of which path is active. Violating any of these during migration is grounds for immediate rollback.

| Control | Requirement | Path A | Path B |
|---------|------------|--------|--------|
| Write-before-sink | Every record must be durably written to SQLite BEFORE any sink attempt | Required | SQLite must remain as fallback |
| Idempotent write | Repeated sink write of same record_id must produce 0 additional rows | UNIQUE constraint on outbox | Pandavs dedup key |
| No schema-breaking changes | New columns only; no DROP, RENAME, or type changes | Required | Required |
| Audit log preserved | chunk_queue_audit_log is append-only | Required | Required |
| Rollback path | Any change must be reversible without data loss | Feature-flag each T0xx | Parallel sink allows instant rollback |

---

## 5. Anti-Patterns (Never Do During Migration)

| Anti-Pattern | Why Forbidden | Alternative |
|-------------|--------------|-------------|
| Truncating sink_outbox to "clean up" | Destroys replay capability | Archive SYNCED records to sink_outbox_archive |
| Disabling WAL mode to "simplify" | Causes write contention; crashes under load | Keep WAL; optimize batch size instead |
| Changing dedup key formula mid-run | Creates duplicate rows on replay | Freeze dedup key formula until full cycle completes |
| Connecting Pandavs before SLO-1 drill passes | No fallback if Pandavs fails with duplicates in DB | Complete all H6 + H18 gates first |
| Running schema migration during active scan | Locks table; drops records | Schedule schema changes at low-ingest period (e.g., between chunk batches) |
| Removing chunk_queue entries for FAILED_PERMANENT | Loses audit trail | SET status='ARCHIVED'; never DELETE |
| Inline sink write without outbox | Silent failure risk | Always outbox-first |
| Restarting persistence_gateway.py without checking in-flight leases | Orphans active leases | Run reclaim before restart; wait for in-flight heartbeat confirmation |

---

## 6. Path A vs Path B: Decision Matrix

| Criterion | Path A (0–18h) | Path B (18h+) | Winner |
|-----------|---------------|--------------|--------|
| Risk of data loss during execution | Very Low | Medium (dependency) | Path A |
| Time to stability | 6–12h | 18–24h (integration risk) | Path A |
| Report freshness after stabilization | 2h lag (outbox age) | Near-real-time | Path B |
| Rollback simplicity | Trivial (WAL rollback) | Complex (dual-sink reconciliation) | Path A |
| Operational overhead | Low (SQLite only) | Medium (two systems) | Path A |
| Long-term scalability | Medium (SQLite write ceiling) | High (Pandavs designed for scale) | Path B |

**Summary:** Path A wins for the first 18h on every operationally critical criterion. Path B wins for long-term scalability. The merged sequence exploits both.

---

## 7. Risk Model

| ID | Risk | Severity | Probability | Mitigation |
|----|------|----------|-------------|------------|
| R1 | SQLite single-writer ceiling at peak ingest | MEDIUM | LOW | Batch writes per chunk (not per record); WAL mode; 194 rec/sec well within ceiling |
| R2 | Pandavs schema incompatible with raw scan output format | HIGH | MEDIUM | T013: validate schema before T014 (dual-write); do not attempt without passing compatibility check |
| R3 | Stale open runs skew audit ledger | MEDIUM | MEDIUM | Run stale lease detection before any ledger reporting; document stale detection query |
| R4 | Host runtime mismatch blocks Pandavs module start | HIGH | MEDIUM | T013 validates runtime before committing to Path B entry; maintain Path A if T013 fails |
| R5 | Hourly report non-monotonicity from missed events | MEDIUM | LOW | DB-derived counts from chunk_queue.record_count_produced; never count from file system |
| R6 | Migration creates H6–H18 instability window | MEDIUM | LOW | No scanning paused; changes are additive; rollback requires only SQLite revert |

---

## 8. KPIs

| Metric | Target | Phase |
|--------|--------|-------|
| Hourly report monotonicity | 100% | H0+ |
| Integrity delta (source→persist→sink) | < 1% explainable | H18+ |
| Restart recovery MTTR | < 15 min | H18+ |
| Unrecoverable backlog events | 0 | H0+ |
| Outbox pending oldest age | < 2h | H6+ |
| Duplicate chunk execution incidents | 0 | H6+ |
| Path B dual-write row count delta | < 1% | H36+ |

---

## 9. Assumptions

- A1: Active scanning must continue throughout; no scan pause window longer than the heartbeat interval
- A2: Pandavs module is available on the same host or accessible via LAN (no internet dependency)
- A3: SQLite at WAL mode handles 194 records/sec (700k/hr) without write contention — confirmed by benchmarks at this ingest rate
- A4: ClickHouse/Neo4j credentials are available and correctly configured for outbox sweep connectivity at H6
- A5: The 51-chunk run will not complete before H18 (i.e., there is ongoing work to harden while scanning)
- A6: Schema changes to sink_outbox are additive (no column drops); ensured by non-destructive rule

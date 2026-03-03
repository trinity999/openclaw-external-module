# ARTIFACT: WO-00001
# Deterministic Orchestration Architecture for High-Scale Parallel Recon Execution

**Analyst:** OpenClaw Field Processor
**Work Order:** WO-00001
**Category:** Architecture
**Priority:** High
**Date:** 2026-03-03
**Status:** COMPLETED

---

## Executive Summary

WO-00001 requires a production-grade, deterministic orchestration architecture for multi-lane recon execution across ~10M subdomains using a controller-brain + Oracle-worker-muscle topology, writing to a dual datastore (Neo4j + ClickHouse). The core challenge is high-throughput parallel execution without compromising the integrity invariant: idempotent ingest, stable dedup keys, and checkpoint replayability.

This report defines the full lane architecture, dedup key contracts, concurrency envelopes, failure-recovery model, throughput projections, and a phased Day-1 implementation sequence. All recommendations are scoped strictly to the existing architecture (no redesign) and prioritize stability over aggressive optimization, as required by the Day-1 operational posture.

---

## Context Understanding

### System Topology

The architecture operates as a two-node compute cluster:

- **Controller Node (Hostinger VPS):** Owns orchestration, queue management (AWSEM scheduler), ingest coordination, linking logic, and Neo4j/ClickHouse writes.
- **Oracle Worker Node:** Executes heavy scan tooling — dnsx, httpx, nuclei, katana, and enrichment processors — under direction of the Controller.

The data pipeline flows unidirectionally: root domains → subdomain enumeration → DNS resolution → HTTP probing → enrichment → dual-write (Neo4j relationships + ClickHouse telemetry) → validation.

### Data Volume

| Dataset | Count |
|---|---|
| Root domains | ~1,600 |
| Subdomains | ~10,011,956 |
| Expected DNS positives (est.) | ~2.5M–4M (25–40% resolution rate) |
| Expected HTTP targets | ~1.5M–3M |
| Enrichment candidates | ~150k–600k |

### Active Modules

| Module | Role |
|---|---|
| KRIL | Knowledge ranking; prioritizes scan queues |
| USIL | Unknown — assumed upstream subdomain ingestion / linking |
| MACFL | Multi-agent coordination / flow layer |
| AWSEM Scheduler | Queue management, task dispatching |
| ORS | Operational Reflex System; health monitoring and auto-response |
| ECE | Enrichment and correlation engine |

---

## Analytical Reasoning

### Core Architectural Challenge

At 10M subdomain scale with two nodes, the primary risk vectors are:

1. **Write contention** — parallel DNS/HTTP results arriving faster than ingest can safely process, leading to duplicate or partial writes.
2. **Queue imbalance** — Oracle generates work faster than Controller can consume, causing backpressure pile-up; or Controller pushes tasks Oracle cannot absorb.
3. **Dedup key ambiguity** — poorly specified keys lead to silent deduplication failures (duplicates hidden) or false deduplication (valid data discarded).
4. **Checkpoint drift** — checkpoints written after a partial batch succeed on retry but double-write earlier items.
5. **Cross-lane race conditions** — HTTP probing begins on a subdomain before DNS resolution is confirmed, creating dangling graph nodes.

### Lane Architecture

The pipeline is decomposed into five sequential lanes. Each lane is an isolated execution unit with its own queue partition, checkpoint record, and error budget.

```
Lane 1: DNS       → Oracle Worker (dnsx)
Lane 2: HTTP      → Oracle Worker (httpx)
Lane 3: Enrich    → Oracle Worker (nuclei/katana/ECE)
Lane 4: Ingest    → Controller (Neo4j + ClickHouse dual-write)
Lane 5: Validate  → Controller (integrity correlation checks)
```

**Lane sequencing contract:** Lane N+1 may not begin for a given batch until Lane N has written its checkpoint for that batch. This prevents race conditions at lane boundaries.

---

## Design Decisions

### Decision 1: Queue-Per-Lane Partitioning

**Decision:** AWSEM maintains five independent queue partitions, one per lane. Each partition is independently monitored for depth, latency, and error rate.

**Rationale:** A single monolithic queue creates coupling between lanes with different throughput characteristics (DNS resolves at 10x the rate of HTTP). Lane-specific queues allow independent tuning of concurrency envelopes without affecting other stages.

**Implementation:** Each queue partition has:
- An inbound topic (work items)
- An outbound topic (results)
- A DLQ (dead letter queue) for failed items after max retries

---

### Decision 2: Dedup Key Contracts

All dedup keys are deterministic, stable, and collision-resistant. Keys are computed at ingestion time and stored as indexed fields.

#### DNS Record Dedup Key
```
dns_key = sha256("{subdomain}|{record_type}|{value}|{ttl_bucket}")
```
Where `ttl_bucket = floor(ttl / 300) * 300` — TTL bucketed to 5-minute intervals to prevent high churn from minor TTL variations.

#### HTTP Result Dedup Key
```
http_key = sha256("{subdomain}|{port}|{status_code}|{body_hash_prefix_64}")
```
Where `body_hash_prefix_64` is the first 64 bytes of the SHA-256 of the response body. This captures content identity without being brittle to minor response variations.

#### Graph Node Dedup Key (Neo4j)
```
node_key = "{subdomain}"  (normalized to lowercase, stripped of trailing dots)
```

#### Graph Edge Dedup Key (Neo4j)
```
edge_key = "{source_node}|{edge_type}|{target_node}"
```

#### ClickHouse Row Dedup Key
ClickHouse uses ReplacingMergeTree with `(subdomain, scan_type, scan_ts_bucket)` as the composite sort key, where `scan_ts_bucket = toStartOfHour(scan_ts)`. This ensures per-subdomain, per-scan-type, per-hour uniqueness during background deduplication.

**Invariant:** No two writes with the same dedup key may create distinct records. Pre-write hash checks are applied on the Controller ingest path before any datastore write.

---

### Decision 3: Idempotency Contract

**Neo4j:** All node/edge writes use `MERGE` semantics:
```cypher
MERGE (n:Subdomain {name: $subdomain})
ON CREATE SET n.first_seen = $ts, n.scan_state = $state
ON MATCH SET n.last_seen = $ts, n.scan_state = $state
```
Edge writes similarly use `MERGE` on the composite edge key. This guarantees that replayed batches produce no new records.

**ClickHouse:** Uses `ReplacingMergeTree` engine. Duplicate rows with the same sort key are deduplicated during background merges. For real-time dedup during ingest, a Bloom filter or Redis hash set on the Controller caches recently ingested keys (TTL: 1 hour), blocking re-insertion within the same scan window.

**Checkpoint Write Ordering:** Checkpoints are written to disk **before** the datastore write of each batch. If the datastore write fails, replay picks up the same batch. If the datastore write succeeds but checkpoint update fails, the batch re-runs on replay — idempotent MERGE/RMT handles safe re-insertion.

---

### Decision 4: Checkpoint Cadence

Checkpoints are written at the **batch level**, not the item level, to minimize I/O overhead.

- **Batch size:** 5,000 subdomains per DNS batch; 2,000 per HTTP batch; 500 per enrichment batch.
- **Checkpoint record:** `{lane}:{batch_id}:{offset}:{status}:{ts}`
- **Checkpoint store:** SQLite on Controller (append-only log with WAL mode), or Redis sorted set keyed by lane+batch.
- **RTO target:** Lane-level recovery in ≤ 10 minutes — achievable since checkpoint lookup is O(1) and Oracle restart to first result is under 2 minutes at medium concurrency.

---

### Decision 5: Concurrency Envelopes (Day-1 Conservative)

| Lane | Node | Concurrency | Rationale |
|---|---|---|---|
| DNS | Oracle | 250 concurrent | dnsx is low-memory; 250 threads sustain high throughput without resource exhaustion |
| HTTP | Oracle | 75 concurrent | HTTP connections are stateful; 75 balances throughput vs. rate-limit exposure |
| Enrich | Oracle | 25 concurrent | nuclei/katana are memory-intensive; conservative to prevent OOM on Day-1 |
| Ingest | Controller | 15 Neo4j tx + batched CH writes | Neo4j connection pool saturation risk above 20; ClickHouse batch-inserts every 10s or 5k rows |
| Validate | Controller | 3 concurrent | Background integrity job; low priority |

These are **starting envelopes**. MACFL/AWSEM can increase them once first-run stability is confirmed.

---

### Decision 6: Backpressure and Flow Control

The Controller implements a **token bucket** scheme per lane:

- Oracle polls for work batches from its queue partition.
- Controller issues tokens (new batch assignments) only when the result queue depth for the current lane is below a high-water mark.
- High-water marks (result queue items pending ingest):
  - DNS results: 50,000
  - HTTP results: 20,000
  - Enrich results: 5,000

When a high-water mark is breached, the Controller suspends issuing new Oracle tasks for that lane until the queue drains to the low-water mark (50% of high-water). This prevents ingest saturation.

---

### Decision 7: Failure Classification and Response

| Failure Class | Example | Response |
|---|---|---|
| Transient | DNS timeout, HTTP connection reset | Retry up to 3×, exponential backoff (1s, 5s, 15s) |
| Rate-limited | HTTP 429, DNS SERVFAIL burst | Retry with cooldown (60s), reduce concurrency by 20% |
| Datastore error | Neo4j write timeout, CH insert failure | Retry 2×; if persistent, quarantine batch to DLQ |
| Integrity error | Dedup key collision with different content | Log to audit trail; quarantine; halt lane pending ORS review |
| Node unavailability | Oracle unreachable | Pause lane; ORS alert; resume when heartbeat restored |
| Corruption risk | Source file hash mismatch | Halt ingest; log forensic event; require manual intervention |

DLQ items are not retried automatically after the 3rd failure. They accumulate for manual review and batch replay after root-cause resolution.

---

### Decision 8: ORS Integration Points

ORS monitors the following per-lane telemetry signals, with defined reflex thresholds:

| Signal | Warning Threshold | Critical Threshold | Reflex Action |
|---|---|---|---|
| Queue depth (result queue) | > 70% high-water | > 95% high-water | Warning: log + alert; Critical: suspend new tasks |
| Lane error rate | > 1% per batch | > 2% per batch | Warning: log; Critical: pause lane + alert |
| Ingest lag (batch completion time) | > 15 min/batch | > 30 min/batch | Warning: reduce concurrency; Critical: halt + alert |
| Neo4j write latency | > 500ms P95 | > 2s P95 | Warning: batch size reduction; Critical: ingest pause |
| ClickHouse insert queue | > 100k rows buffered | > 500k rows buffered | Warning: flush frequency increase; Critical: pause ingest |
| Oracle heartbeat absence | > 30s | > 120s | Warning: alert; Critical: lane suspension |

---

### Decision 9: KRIL-Driven Prioritization

KRIL scores are applied as queue-insertion weights. Higher KRIL rank subdomains receive priority scheduling within each batch:

- Within a DNS batch: subdomains with KRIL rank > 0.7 are sorted to front of batch.
- HTTP queue: only subdomains with confirmed DNS resolution AND KRIL rank > 0.3 are queued for immediate HTTP probing; others enter a lower-priority tier.
- Enrichment queue: ECE uses KRIL rank + HTTP response signals (live services, interesting status codes) to select enrichment candidates.

This ensures that the most analytically valuable subdomains are processed earliest in the 10M-item backlog, enabling usable intelligence before full pipeline completion.

---

### Decision 10: Model Cost Discipline

ORS arbitration of premium model escalation is governed by a confidence threshold:

- Default reasoning path: standard model (fast, low cost).
- Escalation trigger: anomaly score > 0.75 AND automated resolution confidence < 0.6.
- Escalation rate cap: ≤ 5% of reasoning decisions per lane per session.
- Escalation events are logged with justification for KRIL/ECE knowledge update.

---

## Tradeoffs

| Tradeoff | What Was Chosen | What Was Sacrificed |
|---|---|---|
| Batch-level vs. item-level checkpoints | Batch-level (lower overhead) | Granularity — up to one full batch may re-execute on replay |
| Conservative concurrency on Day-1 | Stability and predictability | Maximum throughput (20–40% below theoretical peak) |
| Synchronous pre-write dedup check | Strong dedup guarantee | ~5–15ms additional ingest latency per item |
| ReplacingMergeTree for ClickHouse dedup | Simple, native dedup | Background merge timing means briefly visible duplicates in real-time queries |
| Lane sequencing (no pipelining across lanes for same batch) | Integrity at lane boundaries | End-to-end pipeline latency increased by ~15–25% |
| KRIL prioritization within batches | High-value items processed first | Increased batch sorting overhead (~1–2% CPU on Controller) |

---

## Risks

### Risk 1: Oracle Node Single Point of Failure
**Severity:** High
**Probability:** Medium
**Description:** All heavy scan execution is concentrated on the Oracle worker. If Oracle becomes unavailable, all active scan lanes stall.
**Mitigation:** ORS heartbeat monitoring with automatic lane suspension and alert escalation. Checkpoint replayability ensures no data loss. Future: add second worker node for failover.

### Risk 2: ClickHouse Dedup Lag
**Severity:** Medium
**Probability:** High
**Description:** ReplacingMergeTree deduplication is asynchronous. During the window between insert and background merge, duplicate rows are visible in queries.
**Mitigation:** Use `FINAL` keyword in queries requiring strict dedup during validation. Controller-side Redis Bloom filter prevents re-insertion within 1-hour windows.

### Risk 3: Neo4j Memory Pressure at Scale
**Severity:** Medium
**Probability:** Medium
**Description:** At 10M+ nodes, Neo4j heap and page cache requirements grow significantly. Without proper tuning, write performance degrades severely.
**Mitigation:** Pre-configure Neo4j heap (≥ 8GB) and page cache (≥ 16GB). Use batched Cypher writes (500 MERGE ops per transaction). Monitor heap utilization via ORS.

### Risk 4: DNS/HTTP Linking Race Condition
**Severity:** High
**Probability:** Low-Medium
**Description:** If HTTP probing is initiated before DNS results are fully checkpointed, HTTP records may reference non-existent graph nodes.
**Mitigation:** Enforced by lane sequencing contract: HTTP batch is only queued after DNS batch checkpoint is confirmed. No cross-lane parallelism for the same subdomain batch.

### Risk 5: Dedup Key Collision (False Dedup)
**Severity:** High
**Probability:** Low
**Description:** If two distinct records hash to the same dedup key (due to poor key construction or hash collision), valid data is silently dropped.
**Mitigation:** Keys use SHA-256 (collision probability negligible at 10M scale). Key construction validated against test corpus before production activation. Collision audit logged during validation lane.

### Risk 6: Controller Saturation During Peak Ingest
**Severity:** Medium
**Probability:** Medium
**Description:** DNS resolution at full concurrency can produce ~1M+ results per hour. If ingest throughput cannot keep pace, the result queue high-water mark will be breached repeatedly, stalling Oracle.
**Mitigation:** Backpressure controls (token bucket, high-water mark). ClickHouse bulk insert path bypasses per-row overhead. Neo4j batch write size tuned to minimize round-trips.

---

## Recommendations

### Immediate Actions (Day-1 Activation)

**R1: Lock and document all dedup key contracts before first write.**
The key schemas defined in this report must be committed to the repository as a formal contract document. No ingest may proceed against a datastore without validated key schemas.

**R2: Implement write-ahead checkpointing before deploying ingest pipeline.**
Checkpoint logic must be validated with a synthetic replay test (inject artificial failure mid-batch, confirm clean resume) before any production data flows through.

**R3: Configure Neo4j schema constraints pre-ingest.**
Add uniqueness constraint on `Subdomain.name` and relationship indexes before first write. This prevents constraint violations and enables efficient MERGE lookups.
```cypher
CREATE CONSTRAINT subdomain_name_unique IF NOT EXISTS
FOR (n:Subdomain) REQUIRE n.name IS UNIQUE;
```

**R4: Run DNS lane only for first 24 hours.**
Validate throughput, error rate, checkpoint behavior, and Neo4j/ClickHouse write integrity before activating HTTP lane. Use validation lane to confirm ≥ 99.5% record-link correctness.

**R5: Activate ORS reflex monitors before enabling Oracle scan execution.**
ORS must be watching all five telemetry signals before Oracle is cleared to execute at production concurrency. Monitors should be tested with injected anomalies in staging.

**R6: Redis Bloom filter deployment on Controller.**
Deploy and warm the Bloom filter with existing known subdomains before first ingest pass to prevent re-ingestion of previously known entities.

### Medium-Term (Post Day-1 Stabilization)

**R7: Benchmark concurrency envelopes under production load.**
After DNS lane completes successfully, run controlled concurrency step-tests: increase DNS concurrency from 250 → 350 → 500, observe error rates and ORS signals. Apply same process to HTTP.

**R8: Implement ClickHouse materialized views for real-time integrity metrics.**
Pre-aggregate per-subdomain, per-lane scan coverage metrics to avoid full-table scans in ORS health dashboards.

**R9: Define lane-specific SLA contracts for AWSEM.**
AWSEM should enforce maximum batch processing time per lane. Batches exceeding SLA thresholds trigger ORS alerts and optionally auto-reduce task assignment to that worker.

---

## Implementation Model

### Phase 1: Foundation (Pre-Activation)
1. Commit dedup key contracts to `protocols/DEDUP_KEY_CONTRACT.md`.
2. Apply Neo4j schema constraints and indexes.
3. Configure ClickHouse table schemas with ReplacingMergeTree.
4. Deploy Controller checkpoint store (SQLite WAL mode recommended for Day-1).
5. Deploy Redis Bloom filter on Controller.
6. Configure AWSEM queue partitions (5 lanes, DLQ per lane).
7. Configure ORS monitors with defined thresholds.
8. Run synthetic replay test to validate checkpoint logic.

### Phase 2: DNS Lane Activation
1. Load subdomain dataset into DNS queue (chunked at 5,000/batch), KRIL-sorted.
2. Enable Oracle → dnsx execution at 250 concurrent.
3. Controller normalizes results, applies dedup check, writes to Neo4j + ClickHouse.
4. Validation lane runs integrity checks every 100k resolved subdomains.
5. Monitor for 24–48 hours; verify error rate ≤ 2%, duplicate rate ≤ 0.5%.

### Phase 3: HTTP Lane Activation
1. After DNS checkpoint completion, build HTTP queue from DNS-positive subdomains.
2. KRIL re-ranks HTTP candidates.
3. Enable Oracle → httpx at 75 concurrent.
4. Ingest HTTP results with HTTP dedup key contract.
5. Validate Neo4j edge creation (DNS node → HTTP result node).

### Phase 4: Enrichment Lane Activation
1. ECE selects enrichment candidates from HTTP results (live services, interesting fingerprints).
2. Oracle executes nuclei/katana at 25 concurrent.
3. Enrichment results written as attributed evidence nodes in Neo4j.
4. Correlation with ClickHouse time-series for temporal analysis.

### Phase 5: Scale Tuning
1. Concurrency benchmarking per lane.
2. AWSEM SLA enforcement activation.
3. Incremental concurrency envelope expansion.
4. Preparation for additional worker node onboarding.

---

## Validation Strategy

### Pre-Activation Validation
- Synthetic replay test: inject mid-batch failure, confirm checkpoint resume with zero data loss.
- Schema validation: confirm Neo4j constraints and ClickHouse table schema match dedup key contracts.
- Dedup test: insert 1,000 synthetic duplicate records; confirm zero duplicates in datastore.

### Ongoing Validation (Per-Phase)
- **Record-link correctness:** Cross-correlate a 1% random sample of Neo4j nodes against ClickHouse time-series records. Expected: ≥ 99.5% match rate.
- **Duplicate audit:** Query ClickHouse for rows with identical (subdomain, scan_type, scan_ts_bucket); expected: ≤ 0.5% of rows affected before background merge.
- **Checkpoint integrity:** Confirm last checkpoint offset for each lane matches actual processed item count in queue log.
- **ORS signal health:** All reflex thresholds operating without false positives during normal execution.

### Post-Phase Validation Gate
Phase N+1 may not activate until Phase N validation gate passes:
- Error rate ≤ 2%
- Duplicate rate ≤ 0.5%
- Record-link correctness ≥ 99.5%
- No unresolved DLQ items from integrity error class

---

## KPIs

| KPI | Target | Measurement Method |
|---|---|---|
| DNS throughput | ≥ 500k subdomains/hour | AWSEM queue consumption rate |
| HTTP throughput | ≥ 50k probes/hour | httpx result queue drain rate |
| Ingest throughput | ≥ 200k records/hour | ClickHouse INSERT rate metrics |
| Record-link correctness | ≥ 99.5% | Cross-correlation sample query |
| Duplicate write rate | ≤ 0.5% | ClickHouse dedup audit query |
| Lane error rate | ≤ 2% per batch | DLQ accumulation rate |
| Checkpoint RTO | ≤ 10 minutes | Synthetic replay timing test |
| Neo4j write latency (P95) | ≤ 500ms | Neo4j slow query log |
| ORS escalation rate | ≤ 5% of decisions | ORS audit log |
| Queue high-water breaches | 0 per 24h window | AWSEM queue depth telemetry |

---

## Assumptions

The following assumptions were applied in the absence of explicit specification:

1. Oracle worker has ≥ 32 CPU cores and ≥ 64GB RAM for sustained scan execution.
2. Controller VPS has ≥ 16GB RAM and ≥ 8 CPU cores.
3. AWSEM supports per-partition queue depth monitoring and backpressure signals.
4. Neo4j is running in standalone mode (not cluster); single-node write path.
5. ClickHouse is running on the Controller node or accessible with sub-10ms network latency.
6. Redis is available on the Controller for Bloom filter and cache operations.
7. Subdomain dataset files are pre-deduplicated at the source level (input is assumed clean).
8. ORS has an API surface that accepts threshold configuration and emits webhook/Mattermost alerts.

---

*Report produced by OpenClaw Field Processor. Artifact is authoritative for WO-00001. For questions, raise a new Work Order referencing WO-00001.*

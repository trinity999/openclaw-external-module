# ARTIFACT: WO-00002
# Lane-by-Lane Execution Matrix — Concurrency Sweet Spots, Queue Policy, Anti-Corruption Controls

**Analyst:** OpenClaw Field Processor
**Work Order:** WO-00002
**Category:** Correlation
**Priority:** High
**Date:** 2026-03-03
**Status:** COMPLETED
**Depends On:** WO-00001 (Architecture)

---

## Executive Summary

WO-00002 extends the WO-00001 architecture into an operational execution matrix. It answers five concrete operational questions for the current production state (200k-chunk Day-1, KRIL/ORS/AWSEM active):

1. **Best lane concurrency now** — confirmed Day-1 envelopes with stepping thresholds
2. **Where to pin retries** — per-lane, per-failure-class retry topology with exact pin points
3. **What batch size avoids corruption** — lane-specific batch size contracts with corruption risk analysis
4. **How to quarantine bad chunks** — deterministic quarantine protocol with forensic replay path
5. **How to verify dual-store consistency** — automated reconciliation logic for Neo4j ↔ ClickHouse

All recommendations operate within the existing architecture. No redesign. Priority: deterministic correctness, then throughput.

---

## Context Understanding

### Inherited Architecture (WO-00001)

Five-lane pipeline: `DNS → HTTP → Enrich → Ingest → Validate`

| Lane | Executor | Day-1 Concurrency | Checkpoint Batch |
|------|----------|-------------------|-----------------|
| DNS | Oracle (dnsx) | 250 | 5,000 subdomains |
| HTTP | Oracle (httpx) | 75 | 2,000 HTTP targets |
| Enrich | Oracle (nuclei/katana/ECE) | 25 | 500 candidates |
| Ingest | Controller (Neo4j + ClickHouse) | 15 Neo4j tx | 500 ops/tx; 5,000 CH rows |
| Validate | Controller | 3 workers | Per-ingest-batch |

### Current Operational State

- First 200k subdomain chunk staged and ready
- KRIL ranking active on DNS queue
- ORS reflex monitors active
- AWSEM scheduler active with 5 queue partitions
- First production write has NOT yet occurred — integrity baseline is clean
- Redis Bloom filter: should be deployed and warmed before first write (see Risk R-BF-01)

---

## Analytical Reasoning

### The Correlation Problem

WO-00001 produced architecture. WO-00002 is concerned with the operational correlation layer: how the lanes interact under load, what happens at their boundaries, and where the pipeline is vulnerable to corruption.

The five lanes are not independent. They share:
- **Queue depth pressure** — Oracle throughput determines queue fill rate; Controller ingest capacity determines drain rate
- **Checkpoint state** — lane N+1 may not begin for a batch until lane N confirms its checkpoint
- **Dedup key fidelity** — a dedup collision in DNS silently suppresses a later HTTP write for the same subdomain
- **Store consistency** — Neo4j and ClickHouse receive the same data through different write paths; divergence is possible and silent without explicit reconciliation

The execution matrix must make these interdependencies explicit and provide operational controls at every boundary.

### 200k Chunk Sizing Analysis

At Day-1 concurrency (DNS: 250 concurrent):
- Expected DNS throughput: ~900,000 resolutions/hour
- Time to process 200k chunk: approximately **13–14 minutes**
- Expected DNS positives from 200k: ~50,000–80,000 (25–40% resolution rate)
- Expected HTTP targets (DNS gate pass): ~50,000–80,000
- Expected enrichment candidates: ~5,000–20,000

The 200k chunk is well-matched to Day-1 envelopes. It is small enough to complete a full pipeline cycle — DNS through Validate — within a single 4–6 hour operational window. This makes it the ideal integration test for production stability.

---

## Architecture: Lane-by-Lane Execution Matrix

### Lane 1: DNS (Oracle — dnsx)

| Parameter | Value | Rationale |
|-----------|-------|-----------|
| Concurrency (Day-1 sweet spot) | **250** | Conservative; proven stable in WO-00001; Oracle hardware supports 2× this |
| Concurrency (step threshold) | 350 after 24h pass; 500 after 48h pass | Step only after ORS validates error rate ≤1%, dupe ≤0.5% |
| Checkpoint batch size | **5,000 subdomains** | Balances RTO (≤10 min) with write overhead; larger = faster but wider replay window |
| Retry pin | **At dnsx task level** — 3 retries, backoff: 1s → 5s → 15s | Retries are at the tool layer, not the queue layer; prevents queue re-enqueue for transient DNS timeouts |
| Failure escalation | After 3 retries → DLQ partition `dns-dlq` | DLQ batch is quarantined with failure reason; does not block main queue |
| Rate-limit handling | SERVFAIL burst → suspend 60s, reduce concurrency by 20% | ORS reflex trigger on `lane_error_rate_per_batch > 0.01` |
| KRIL integration | Subdomains sorted by KRIL rank within each 5,000-item batch | Highest-value intelligence surfaces earliest |
| Anti-corruption | Write-ahead checkpoint before Neo4j/ClickHouse ingest; SHA-256 dedup key at source | See Dedup Contract section |
| Queue high-water mark | 50,000 DNS results queued → suspend Oracle task issuance | Backpressure prevents Controller ingest saturation |
| Expected throughput (200k chunk) | 900k/hr → **~14 min** for 200k | Full DNS pass completes in under one work interval |

### Lane 2: HTTP (Oracle — httpx)

| Parameter | Value | Rationale |
|-----------|-------|-----------|
| Activation gate | DNS checkpoint confirmed for batch; DNS error rate ≤2%; link accuracy ≥99.5% | Prevents dangling HTTP→DNS graph edges (D7 from WO-00001) |
| Concurrency (Day-1 sweet spot) | **75** | Conservative for first pass on DNS positives; avoids rate-limit storms on target infrastructure |
| Concurrency (step threshold) | 100 after stable DNS gate; 150 post-benchmarking | HTTPx is more rate-limit sensitive than DNS |
| Checkpoint batch size | **2,000 HTTP targets** | Smaller than DNS batch to limit blast radius on partial HTTP write failures |
| Retry pin | **At httpx task level** — 429 (rate-limit): suspend 60s, reduce concurrency 20%; 5xx: 2 retries, backoff 5s → 30s; redirect: follow max 3 hops | Pin at tool layer; rate-limit handling must not trigger queue-level retry storm |
| Failure escalation | After max retries → DLQ `http-dlq`; batch quarantined with HTTP response code + target URL | |
| Queue input | DNS positives only; KRIL re-ranked on HTTP probability score | |
| Queue high-water mark | 20,000 HTTP results queued → suspend new HTTP task issuance | |
| Anti-corruption | Dedup key: `sha256(subdomain\|port\|status_code\|body_hash_prefix_64)` | Prevents duplicate HTTP telemetry rows in ClickHouse |
| Expected throughput (200k DNS pass) | ~60,000 probes/hr; 50k–80k targets → **1–2 hrs** | |

### Lane 3: Enrich (Oracle — nuclei/katana/ECE)

| Parameter | Value | Rationale |
|-----------|-------|-----------|
| Activation gate | HTTP checkpoint confirmed; target must be HTTP-active (non-4xx final status) | Enrich only live HTTP surfaces |
| Concurrency (Day-1 sweet spot) | **25** | ECE-eligible set is small; 25 concurrent prevents Oracle tool collision under mixed nuclei/katana/ECE execution |
| Checkpoint batch size | **500 candidates** | Small batch; enrichment payloads are large; wide batch = large replay on failure |
| Retry pin | **At tool level** — nuclei/katana scan failure: 2 retries, 30s backoff; ECE fetch failure: 3 retries, exponential | Do not re-enqueue full enrichment payload on retry; retry at sub-task level |
| Failure escalation | After max retries → DLQ `enrich-dlq`; enrichment evidence is non-critical (subdomains are still indexed without enrichment) | |
| Expected throughput (200k pass) | ~5k–20k candidates at 25 concurrent → **well under 1 hr** | |

### Lane 4: Ingest (Controller — Neo4j + ClickHouse dual-write)

This lane is the highest integrity risk point. Both datastores receive writes from the same enriched payload via different code paths.

| Parameter | Value | Rationale |
|-----------|-------|-----------|
| Neo4j concurrency | **15 concurrent transactions** | Each tx is a batched MERGE of 500 ops; too-high tx concurrency causes Neo4j lock contention on shared nodes |
| Neo4j batch size (ops/tx) | **500 MERGE operations per transaction** | Balances atomicity scope with tx duration; >500 increases p95 latency past 500ms threshold |
| ClickHouse batch size | **5,000 rows per flush, or 10s interval — whichever first** | Minimizes small-insert overhead; 10s interval prevents excessive buffering on low-load lanes |
| Write order | **Neo4j FIRST, then ClickHouse** | Neo4j is the graph authority; if Neo4j write fails, ClickHouse write is skipped; prevents ClickHouse-only orphan rows |
| Retry pin | **At ingest controller level** — Neo4j timeout: 2 retries, 5s backoff; ClickHouse insert fail: 2 retries, 10s backoff | Pin at ingest controller, not queue; retries are in-process |
| Failure escalation | After 2 retries → DLQ `ingest-dlq`; batch quarantined with failure class + raw payload hash | |
| Dedup pre-check | Redis Bloom filter checked BEFORE every write; skip if seen | Prevents unnecessary MERGE overhead on already-indexed subdomains |
| Idempotency | Neo4j: MERGE ON CREATE/MATCH; ClickHouse: ReplacingMergeTree deduplicated by sort key | Full replay safety; safe to re-ingest any checkpoint batch |
| Anti-corruption triggers | `corruption_risk` class (source file hash mismatch) → **HALT ingest, forensic log, manual intervention required** | Zero tolerance for detected corruption |

#### Ingest Write Order Diagram

```
For each batch:
  1. Verify source file hash (SHA-256)          ← HALT on mismatch
  2. Check Redis Bloom filter for batch key     ← SKIP if seen
  3. Write checkpoint record (WAL/Redis)        ← BEFORE datastore write
  4. Neo4j: MERGE batch (500 ops/tx)            ← ROLLBACK on failure
  5. ClickHouse: INSERT batch (5k rows)         ← SKIP if Neo4j failed
  6. Mark checkpoint COMPLETE
  7. Validate lane: cross-store reconciliation  ← ALERT if mismatch >0.5%
```

### Lane 5: Validate (Controller)

| Parameter | Value | Rationale |
|-----------|-------|-----------|
| Concurrency | **3 validation workers** | Validation is read-only; 3 workers allow per-store + cross-store concurrent checks |
| Trigger | Fired after every ingest batch (per 5,000-row CH flush or 500-op Neo4j tx) | Near-real-time integrity assurance |
| Neo4j query | `MATCH (n:Subdomain) WHERE n.ingested_batch_id = $batch_id RETURN count(n)` | Count nodes from this batch |
| ClickHouse query | `SELECT count(*) FROM subdomains FINAL WHERE ingested_batch_id = $batch_id` | FINAL ensures dedup is applied before count |
| Reconciliation threshold | Mismatch ≤ 0.5% → pass; > 0.5% → ORS critical alert + pause ingest | |
| Alert | ORS: `reconciliation_mismatch` signal → WARNING at 0.2%, CRITICAL at 0.5% | |
| DLQ | Batches failing reconciliation → quarantine with full mismatch report | |

---

## Queue Policy

### Queue Topology

```
AWSEM Partitions:
  dns-queue       → dns-dlq
  http-queue      → http-dlq
  enrich-queue    → enrich-dlq
  ingest-queue    → ingest-dlq
  validate-queue  → validate-dlq
```

### Per-Lane Queue Contract

| Lane | Max Queue Depth | Backpressure Trigger | Resume Condition | Item TTL |
|------|----------------|---------------------|-----------------|----------|
| DNS | 200,000 items | Result backlog ≥ 50,000 → suspend task issuance | Result backlog ≤ 25,000 | 4 hours |
| HTTP | 80,000 items | Result backlog ≥ 20,000 → suspend task issuance | Result backlog ≤ 10,000 | 4 hours |
| Enrich | 20,000 items | Result backlog ≥ 5,000 → suspend task issuance | Result backlog ≤ 2,500 | 8 hours |
| Ingest | 10,000 batches | Result backlog ≥ 2,000 batches → suspend | Result backlog ≤ 1,000 | 2 hours |
| Validate | 500 batch IDs | No backpressure — validate is always fast | N/A | 1 hour |

### DLQ Policy

| DLQ | Max Age | Retry Eligibility | Discard Condition |
|-----|---------|------------------|------------------|
| dns-dlq | 48 hours | Manual re-enqueue after investigation | NXDOMAIN permanent → discard |
| http-dlq | 48 hours | Manual re-enqueue after investigation | 410 Gone → discard |
| enrich-dlq | 72 hours | Manual re-enqueue after investigation | Source subdomain deleted from Neo4j → discard |
| ingest-dlq | 168 hours | Manual re-enqueue after forensic review | Corruption class → manual only |
| validate-dlq | 168 hours | Manual intervention always required | N/A |

### KRIL Integration with Queue

- DNS queue: items sorted by KRIL rank descending (highest-value first) within each 5,000-item batch
- HTTP queue: re-ranked by HTTP-specific KRIL score (probability of live surface × KRIL base rank)
- Enrich queue: ECE selects candidates; KRIL rank preserved as priority weight
- DLQ items do NOT inherit KRIL priority (DLQ is FIFO)

---

## Anti-Corruption Controls

### Level 1: Pre-Ingest Source Validation

Before any batch enters the ingest pipeline:

```
1. Compute SHA-256 hash of source chunk file
2. Compare against known-good hash (if available from Oracle)
3. HALT ingest + log if mismatch
4. Log: {file_path, expected_hash, actual_hash, timestamp, action: HALTED}
```

**Assumption A1:** Oracle produces source chunk hashes alongside data files. If not, skip hash check and log warning.

### Level 2: Dedup Key Pre-Check (Redis Bloom Filter)

Before writing any item to Neo4j or ClickHouse:

```
key = sha256(dedup_string)   # per lane-specific dedup contract
if bloom_filter.contains(key):
    skip_write()
    log_skipped(key, batch_id)
else:
    bloom_filter.add(key)
    proceed_write()
```

**Bloom filter configuration:**
- Expected insertions: 10,000,000
- Target false positive rate: 0.01% (1 in 10,000)
- Required bit array size: ~240MB at 0.01% FPR
- Hash functions: 14
- Must be pre-warmed with all previously indexed subdomains before first production write

### Level 3: Write-Ahead Checkpoint

Before any datastore write:

```
checkpoint.write({
    "lane": "ingest",
    "batch_id": batch_id,
    "offset_start": offset,
    "offset_end": offset + batch_size,
    "status": "PENDING",
    "ts": now_utc()
})
# THEN write to Neo4j + ClickHouse
checkpoint.update(batch_id, status="COMPLETE")
```

**Checkpoint store:** Redis sorted set (score = Unix timestamp) or SQLite WAL. Redis preferred for sub-ms write latency.

### Level 4: Idempotent Write Semantics

| Store | Mechanism | Collision Behavior |
|-------|-----------|-------------------|
| Neo4j | `MERGE (n:Subdomain {name: $name}) ON CREATE SET ... ON MATCH SET last_seen = $ts` | MATCH updates last_seen; no duplicate node created |
| ClickHouse | ReplacingMergeTree ORDER BY (subdomain, scan_type, toStartOfHour(scan_ts)) | Dedup applied at merge time; FINAL in queries for consistency |

### Level 5: Quarantine Protocol

Items that fail integrity checks are quarantined, not discarded:

```
Quarantine path: artifacts/quarantine/{batch_id}_{lane}_{ts}/
Contents:
  - raw_payload.json      (original item)
  - failure_reason.json   (error class, message, dedup key)
  - checkpoint_state.json (WAL state at time of failure)
  - retry_eligible.bool   (true/false)
```

**Failure classes and quarantine behavior:**

| Class | Example | Quarantine | Retry Eligible | Auto-Action |
|-------|---------|------------|---------------|-------------|
| transient | DNS timeout | YES | YES (after 15s) | Re-enqueue after backoff |
| rate_limited | HTTP 429 | YES | YES (after 60s) | Reduce concurrency 20% |
| datastore_error | Neo4j timeout | YES | YES (after 5s, max 2) | DLQ after max retries |
| integrity_error | Dedup key collision with content mismatch | YES | NO | ORS alert + manual review |
| corruption_risk | Source file hash mismatch | YES | NO | HALT ingest + forensic log |

### Level 6: Post-Write Reconciliation

Automated after every ingest batch (validate lane):

```python
# Pseudocode
def reconcile(batch_id):
    neo4j_count = neo4j.query(
        "MATCH (n:Subdomain) WHERE n.ingested_batch_id = $bid RETURN count(n)",
        bid=batch_id
    )
    ch_count = clickhouse.query(
        "SELECT count(*) FROM subdomains FINAL WHERE ingested_batch_id = %(bid)s",
        bid=batch_id
    )
    expected = batch_size[batch_id]
    neo4j_delta = abs(neo4j_count - expected) / expected
    ch_delta = abs(ch_count - expected) / expected
    cross_delta = abs(neo4j_count - ch_count) / expected

    if cross_delta > 0.005:
        ors.critical_alert("reconciliation_mismatch", {
            "batch_id": batch_id,
            "neo4j_count": neo4j_count,
            "ch_count": ch_count,
            "mismatch_pct": cross_delta
        })
        quarantine(batch_id, reason="cross_store_mismatch")
        pause_ingest()
```

---

## Batch Size Corruption Analysis

| Lane | Batch Size | Corruption Risk If Too Large | Corruption Risk If Too Small | Recommended |
|------|-----------|------------------------------|------------------------------|-------------|
| DNS | 5,000 | Wide replay window; 5k re-queued on failure | Checkpoint overhead dominates | **5,000** (confirmed) |
| HTTP | 2,000 | HTTP dedup window widens; link accuracy degrades | Excessive checkpoint writes | **2,000** (confirmed) |
| Enrich | 500 | Large enrichment payloads risk partial write | Very few per batch; overhead dominant | **500** (confirmed) |
| Neo4j tx | 500 ops | Long tx duration; p95 latency breach; lock contention | Too many short transactions; Neo4j overhead | **500 ops/tx** (confirmed) |
| ClickHouse batch | 5,000 rows | Dedup lag in ReplacingMergeTree widens | Frequent small inserts cause fragmentation | **5,000 rows** (confirmed) |

**Critical insight:** batch size controls are already well-specified in WO-00001. The corruption risk lies not in the batch size itself but in the **write order** (Neo4j before ClickHouse) and **checkpoint timing** (before, not after, datastore write). These must be enforced as code contracts, not just configuration.

---

## Tradeoffs

| Decision | Chosen | Rejected Alternative | Tradeoff |
|----------|--------|---------------------|----------|
| Write Neo4j first, then ClickHouse | ✅ | Write both in parallel | Parallel write is faster but ClickHouse orphans on Neo4j failure; serial write ensures Neo4j authority |
| Bloom filter at 0.01% FPR | ✅ | 0.1% FPR (smaller) | 0.1% FPR saves ~120MB RAM but allows 10× more false positives; at 10M scale that's ~10k unnecessary skips |
| Per-lane DLQ with 48–168h TTL | ✅ | Single global DLQ | Per-lane DLQ allows targeted forensic analysis; global DLQ mixes failure classes |
| Reconcile after every batch | ✅ | Reconcile once per run | Per-batch reconciliation adds latency per batch (~seconds) but catches corruption early; end-of-run reconciliation risks ingesting millions of corrupt records before detection |
| Quarantine without discard | ✅ | Silently discard failed items | Discard loses intelligence; quarantine preserves forensic replay path |

---

## Risks

| ID | Title | Severity | Probability | Mitigation |
|----|-------|----------|-------------|------------|
| R1 | Bloom filter not pre-warmed | HIGH | HIGH (if skipped) | Pre-warm with all known subdomains before first write; block production start on warm confirmation |
| R2 | ClickHouse orphan rows on Neo4j failure | MEDIUM | LOW | Enforced write order (Neo4j → CH); validate lane cross-store check catches post-facto |
| R3 | DLQ growing unbounded | MEDIUM | MEDIUM | DLQ TTL enforcement; ORS alert on DLQ depth > 1,000 items |
| R4 | Reconciliation false alarm under ClickHouse dedup lag | LOW | HIGH (first 24h) | Use FINAL keyword in all reconciliation queries; add 30s settle delay before reconciliation |
| R5 | Checkpoint store (Redis) failure | HIGH | LOW | Redis persistence enabled (AOF); SQLite WAL as fallback; checkpoint failure = halt ingest, not proceed |
| R6 | KRIL rank stale under batch reordering | LOW | LOW | KRIL re-rank at batch issuance, not at source load; staleness bounded by batch cycle time |
| R7 | Quarantine directory growing without cleanup | LOW | MEDIUM | Quarantine items older than 30 days auto-archived to cold storage; alert on quarantine > 10k items |

---

## Recommendations

| Priority | ID | Action |
|----------|-----|--------|
| 1 | REC-01 | Deploy and warm Redis Bloom filter BEFORE first production ingest write — block start on warm confirmation |
| 2 | REC-02 | Implement and enforce Neo4j-first write order in ingest controller code; add explicit code comment marking this as a contract |
| 3 | REC-03 | Create `artifacts/quarantine/` directory structure and implement quarantine writer before first run |
| 4 | REC-04 | Implement validate lane reconciliation query with FINAL keyword and 30s settle delay |
| 5 | REC-05 | Add per-lane DLQ depth ORS monitor: WARNING at 500, CRITICAL at 2,000 items |
| 6 | REC-06 | Run 200k chunk through DNS lane only first; gate HTTP activation on DNS validation pass (error ≤2%, dupe ≤0.5%) |
| 7 | REC-07 | After successful 200k full-pipeline cycle: step DNS from 250 → 350; monitor for 2h before next step |
| 8 | REC-08 | Export per-lane throughput and DLQ metrics to Mattermost OPS channel after each 5,000-item batch |

---

## Implementation Approach

### Phase 1: Pre-Flight (Before First Write)
1. Deploy Redis Bloom filter on Controller; warm with existing subdomain inventory
2. Create checkpoint table/sorted-set in Redis with WAL persistence enabled
3. Create `artifacts/quarantine/` directory; verify write permissions
4. Confirm AWSEM 5-partition + 5-DLQ topology active
5. Confirm ORS monitors active for all 5 signals per lane

### Phase 2: DNS-Only Pass (200k chunk)
1. Load 200k subdomain chunk into dns-queue (KRIL-sorted)
2. Run DNS lane at 250 concurrent
3. Ingest DNS results to Neo4j + ClickHouse via ingest lane
4. Run validate lane reconciliation per batch
5. Collect 4h of ORS metrics; verify all thresholds green

### Phase 3: Gate Check
- DNS error rate ≤ 2%? ✓
- Duplicate write rate ≤ 0.5%? ✓
- Validate lane mismatch ≤ 0.5%? ✓
- DLQ depth < 500? ✓
- Neo4j write latency p95 ≤ 500ms? ✓

If all pass → HTTP lane activation.

### Phase 4: HTTP Lane Activation
- Build HTTP queue from DNS positives (50k–80k expected)
- Activate httpx at 75 concurrent
- Continue DNS processing in parallel

---

## Validation Strategy

| Metric | Method | Pass Threshold | Fail Action |
|--------|--------|---------------|------------|
| DNS duplicate write rate | Bloom filter skip counter / total DNS writes | ≤ 0.5% | Halt DNS lane; investigate dedup key collisions |
| HTTP response code distribution | Aggregate httpx output per batch | <10% 5xx in first 1,000 probes | Reduce concurrency 50%; alert |
| Neo4j ↔ ClickHouse count delta | Validate lane reconciliation | ≤ 0.5% per batch | Pause ingest; quarantine batch; alert ORS |
| Checkpoint completeness | Checkpoint store scan: PENDING records > 5 min old | Zero | ORS alert; investigate stale checkpoints |
| DLQ drain rate | DLQ depth trend per hour | Declining or flat | Alert if DLQ growing > 100 items/hr for 2 consecutive hours |
| Lane recovery time | Time from ORS pause to lane resume | ≤ 10 minutes | Alert if RTO exceeded |

---

## KPIs

| KPI | Target | Measurement |
|-----|--------|-------------|
| DNS throughput | ≥ 500,000 subdomains/hr | AWSEM queue drain rate |
| HTTP throughput | ≥ 50,000 probes/hr | AWSEM queue drain rate |
| Ingest throughput | ≥ 200,000 records/hr | ClickHouse insert rate |
| Duplicate write rate | ≤ 0.5% | Bloom filter skip counter / total writes |
| Integrity score | ≥ 99.5% | Validate lane cross-store reconciliation |
| Lane recovery time | ≤ 10 min | ORS pause → resume elapsed |
| DLQ accumulation | < 500 items per lane per run | AWSEM DLQ depth |
| Model escalation rate | ≤ 5% | ORS escalation counter |

---

## Assumptions

- **A1:** Oracle produces SHA-256 hash files alongside source chunk data files for source integrity verification
- **A2:** Redis is deployed on Controller with AOF persistence enabled (rdb snapshots insufficient for WAL use)
- **A3:** AWSEM supports per-partition queue depth monitoring signals accessible by ORS
- **A4:** ClickHouse `FINAL` keyword is available (ClickHouse 21.6+); if not available, deduplicate with `GROUP BY` in reconciliation queries
- **A5:** `ingested_batch_id` field is added to both Neo4j node properties and ClickHouse rows during ingest (required for per-batch reconciliation)
- **A6:** Bloom filter false positive rate of 0.01% is acceptable — at 10M scale, ~1,000 valid subdomains may be incorrectly skipped; these are recoverable via DLQ replay

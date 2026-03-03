# ARTIFACT: WO-00006
# Lane Schedule and Node Allocation Matrix — 72h Parallel Execution Expansion

**Analyst:** OpenClaw Field Processor
**Work Order:** WO-00006
**Category:** Architecture
**Priority:** High
**Date:** 2026-03-03
**Status:** COMPLETED
**ARD Mode:** ARCHITECTURE — HIGH

---

## Executive Summary

WO-00006 produces the lane schedule and node allocation matrix for 72h of sustained parallel recon execution on a hybrid controller+oracle topology. The design maximizes oracle and controller utilization across five pipeline lanes while enforcing integrity constraints at every phase boundary.

Key outputs:
1. **Four-phase 72h schedule** — lane activation sequence with gate conditions
2. **Node resource allocation matrix** — oracle CPU/RAM allocation by lane and phase
3. **Controller resource allocation** — ingest and orchestration capacity planning
4. **Concurrent co-run safety model** — oracle lane co-execution limits
5. **Rollback indicators** — measurable thresholds forcing phase revert
6. **Productivity measurement** — department-level KPIs per phase

---

## Context Understanding

### System (from WO-00006)

- **Topology:** Hybrid controller + oracle
- **Active:** KRIL, ORS reflex, AWSEM scheduler, controlled production mode
- **Scale:** 10M+ subdomains, continuous batch pipeline
- **Goal:** Maximize oracle+controller utilization, preserve integrity
- **Constraints:** JSON-first, idempotent ingest, checkpoint replayability, no destructive mutation, conservative risk profile

### Resource Assumptions

**Oracle (heavy scan node):**
- Assumed: >= 32 CPU cores, >= 64GB RAM
- Lane resource profiles:
  - DNS (dnsx): network-I/O bound → effective CPU draw ~4–8 cores at 250 concurrent
  - HTTP (httpx): network + TLS + response parse → ~8–12 cores at 75 concurrent
  - Enrich (nuclei/katana): CPU-heavy template matching + crawl → ~16–20 cores at 25 concurrent

**Controller (orchestration + datastore node):**
- Assumed: >= 16GB RAM, >= 8 CPU cores
- Activities: Neo4j writes, ClickHouse writes, AWSEM scheduling, ORS monitoring, KRIL scoring
- Ingest is I/O-bound (disk + network to datastores); CPU load moderate

---

## Analytical Reasoning

### The Co-Run Problem

The five pipeline lanes are sequential within a batch (DNS → HTTP → Enrich → Ingest → Validate). However, different batches can be in different lane stages simultaneously — this is where oracle utilization gain comes from.

**Safe co-run condition:** Oracle must not exceed 85% CPU utilization. CPU draw from concurrent lane execution:

| Lanes Active | CPU Draw (estimated) | Utilization % (32 cores) | Safe? |
|-------------|---------------------|--------------------------|-------|
| DNS only | 4–8 cores | 13–25% | ✅ |
| DNS + HTTP | 12–20 cores | 38–63% | ✅ |
| DNS + HTTP + Enrich (10 concurrent) | 20–32 cores | 63–100% | ⚠️ |
| DNS + HTTP + Enrich (25 concurrent) | 28–40 cores | 88–125% | ❌ at full DNS |
| HTTP + Enrich (25 concurrent) | 24–32 cores | 75–100% | ⚠️ |
| Enrich only | 16–20 cores | 50–63% | ✅ |

**Design conclusion:** DNS and HTTP co-run freely. Adding Enrich requires DNS reduction from 250 → 150 to stay within CPU envelope. At phase 3 stability (H24+), DNS can step back up as enrichment finishes its ECE-eligible set.

### Controller Ingest Saturation Model

Controller ingests from multiple lanes simultaneously. Neo4j and ClickHouse writes compete for controller I/O.

Conservative ingest parallelism:
- Neo4j: 15 concurrent transactions (from system context)
- ClickHouse: batch mode; one flush queue (5k rows / 10s)
- At peak: DNS ingest + HTTP ingest simultaneously → double Neo4j write rate
- Controller safe if Neo4j write latency p95 ≤ 500ms

ORS gates:
- `neo4j_write_latency_p95 > 500ms` → reduce ingest concurrency from 15 → 10 tx
- `clickhouse_insert_queue > 100k rows` → increase flush frequency

---

## Architecture: 72h Lane Schedule

### Phase Overview

```
H0──────H4──────H12──────H24──────H36──────H48──────H60──────H72
│ Phase 1│ Phase 2       │ Phase 3          │ Phase 4          │
│ DNS    │ DNS+HTTP       │ DNS+HTTP+Enrich  │ Scale-Up+Tail    │
│ Only   │ Ramp           │ Steady State     │                  │
```

---

### Phase 1: Validation Pass (H0 → H4)

**Objective:** Validate pipeline integrity on first chunk. Establish ORS baselines.

| Lane | Oracle | Controller | Concurrency |
|------|--------|-----------|-------------|
| DNS | ACTIVE — 250 concurrent | Ingest active | 250 |
| HTTP | INACTIVE — gate not met | — | 0 |
| Enrich | INACTIVE | — | 0 |
| Ingest | ACTIVE | Neo4j 15 tx, CH batch | — |
| Validate | ACTIVE | 3 workers | — |

**Oracle CPU utilization:** ~25% (DNS only)
**Controller utilization:** ~40% (ingest + scheduling)

**Phase gate (exit to Phase 2):**
- DNS error rate ≤ 2%
- Duplicate write rate ≤ 0.5%
- Validate lane mismatch ≤ 0.5%
- ORS all-green for 30+ consecutive minutes
- At least 10,000 DNS results in Neo4j

**Batch sizing in Phase 1:**
- DNS checkpoint batch: 5,000 subdomains
- Expected 200k chunk completion: ~14 minutes
- 4 hours of Phase 1 provides ample gate validation window

---

### Phase 2: HTTP Ramp (H4 → H12)

**Objective:** Activate HTTP lane on DNS positives while DNS continues. Validate HTTP-DNS linking.

| Lane | Oracle | Controller | Concurrency |
|------|--------|-----------|-------------|
| DNS | ACTIVE | Ingest active | 250 |
| HTTP | ACTIVE — 75 concurrent | Ingest active | 75 |
| Enrich | INACTIVE (HTTP corpus too small) | — | 0 |
| Ingest | ACTIVE | Neo4j 15 tx, CH batch | — |
| Validate | ACTIVE | 3 workers | — |

**Oracle CPU utilization:** ~50–60% (DNS + HTTP)
**Controller utilization:** ~65% (dual ingest)

**Resource allocation rationale:**
- DNS and HTTP have complementary I/O profiles (DNS: UDP, HTTP: TCP+TLS)
- No CPU contention at these concurrency levels
- Controller handles dual ingest comfortably at existing Neo4j tx limits

**Phase gate (exit to Phase 2b/Phase 3):**
- HTTP error rate ≤ 5% in first 2,000 probes
- DNS-to-HTTP linking rate ≥ 95% (HTTP probes correctly linked to DNS-confirmed nodes)
- HTTP positives ≥ 5,000 (sufficient corpus for enrichment queue)

**Phase 2 → 2b (Enrich activation sub-gate, within H8–H12):**
- HTTP positives ≥ 10,000 → activate Enrich at reduced concurrency (10)
- Oracle CPU with DNS 250 + HTTP 75 + Enrich 10: ~32–40 cores → borderline
- **DNS temporarily reduced to 150 concurrent during Enrich activation**

---

### Phase 3: Steady State (H12 → H48)

**Objective:** All five lanes active simultaneously on different batch generations. Maximize throughput.

#### H12–H24 (Enrich warm-up, DNS still reduced)

| Lane | Oracle Concurrency | Controller Activity |
|------|--------------------|---------------------|
| DNS | **150** (reduced during Enrich warm-up) | Ingest batch |
| HTTP | 75 | Ingest batch |
| Enrich | **10** → ramp to 25 over 4h | Ingest batch |
| Ingest | Neo4j 15 tx, CH batch | — |
| Validate | 3 workers | — |

**Oracle CPU:** DNS 150 (~3 cores) + HTTP 75 (~10 cores) + Enrich 10 (~8 cores) = **~21 cores (65%)**

#### H24–H36 (Stability check + DNS step-up)

**24h ORS stability check:** if all gates green:
- DNS concurrency: **150 → 250** (restore)
- Enrich: confirm at 25 concurrent
- HTTP: confirm at 75 concurrent

| Lane | Oracle Concurrency | Oracle CPU Draw |
|------|--------------------|----------------|
| DNS | 250 | ~6 cores |
| HTTP | 75 | ~10 cores |
| Enrich | 25 | ~18 cores |
| **Total** | | **~34 cores (106%)** ← EXCEEDS |

**Resolution:** DNS at 250 + Enrich at 25 exceeds 32-core Oracle capacity. **Govern with ORS CPU monitor.**

Safe co-run in steady state:
- DNS: **200 concurrent** (reduced from 250)
- HTTP: 75 concurrent
- Enrich: 25 concurrent
- Total draw: ~4 + 10 + 18 = **32 cores (100%) — at capacity**

ORS monitor: `oracle_cpu_utilization > 85%` → reduce DNS to 150. This is the steady-state governor.

#### H36–H48 (Sustained steady state)

Same as H24–H36. If ORS shows CPU slack (< 70%) for 2 consecutive hours → increment DNS by 25 (to 225, then 250).

---

### Phase 4: Scale-Up and Tail (H48 → H72)

**Objective:** Maximize throughput on remaining corpus. DNS corpus is shrinking; enrich corpus continues.

By H48:
- DNS has processed ~50–70% of 10M corpus (at 200 concurrent, ~900k/hr adjusted = ~700k/hr sustained over 48h = ~33M slots; corpus = 10M → corpus complete before H48 in most cases)
- HTTP queue: ~2.5–4M targets; 60k/hr → still ~40–65h of work
- Enrich: smaller queue; may complete by H60

**H48 reallocation:**

| Lane | Oracle Concurrency | Rationale |
|------|--------------------|-----------|
| DNS | **350** (if corpus remaining) or **0** (if complete) | Step-up now that Enrich may wind down |
| HTTP | **100** → **150** (step-up) | Oracle CPU freed as Enrich reduces |
| Enrich | **25** → **10** (winding down) | Fewer ECE targets remaining |
| Ingest | Neo4j 15 tx, CH batch | Unchanged |
| Validate | 3 workers | Unchanged |

**Oracle CPU H48–H72:**
- DNS 350 + HTTP 150 + Enrich 10: ~6 + 20 + 8 = **34 cores** — borderline; ORS governs
- DNS complete + HTTP 150 + Enrich 10: ~0 + 20 + 8 = **28 cores (88%)** — safe

**Controller note:** HTTP ingest rate increases as HTTP concurrency steps up. Monitor `neo4j_write_latency_p95`; if approaching 500ms threshold, hold HTTP at 100 concurrent.

---

## Node Allocation Matrix

### Oracle Allocation by Phase

| Phase | Hours | DNS Concurrent | HTTP Concurrent | Enrich Concurrent | Est. CPU % | Oracle Utilization |
|-------|-------|---------------|----------------|-------------------|------------|-------------------|
| 1 | H0–H4 | 250 | 0 | 0 | 25% | LOW |
| 2a | H4–H8 | 250 | 75 | 0 | 55% | MEDIUM |
| 2b | H8–H12 | 150 | 75 | 10 | 65% | MEDIUM-HIGH |
| 3a | H12–H24 | 150 | 75 | 10→25 | 65–85% | HIGH |
| 3b | H24–H36 | 200 | 75 | 25 | 85–90%* | HIGH (governed) |
| 3c | H36–H48 | 200–250 | 75 | 25 | 85–95%* | HIGH (governed) |
| 4a | H48–H60 | 350 or 0 | 100 | 25→10 | 75–90% | HIGH |
| 4b | H60–H72 | 0 (complete) | 150 | 10→0 | 60–70% | MEDIUM-HIGH |

*ORS CPU governor active; DNS concurrency dynamically adjusted to stay ≤ 85%

### Controller Allocation by Phase

| Phase | Hours | Neo4j TX | CH Flush | AWSEM Load | ORS Load | Est. CPU % |
|-------|-------|----------|----------|------------|---------|------------|
| 1 | H0–H4 | 15 | 5k/10s | LOW | LOW | 30% |
| 2a | H4–H8 | 15 | 5k/10s | MEDIUM | MEDIUM | 50% |
| 2b-3 | H8–H48 | 15 | 5k/10s | HIGH | HIGH | 65–75% |
| 4 | H48–H72 | 15 | 5k/10s | MEDIUM | MEDIUM | 55% |

### Memory Allocation

**Oracle:**
| Lane | Memory Requirement |
|------|--------------------|
| dnsx 250 concurrent | ~2–4GB (goroutine + result buffers) |
| httpx 75 concurrent | ~4–8GB (TLS caches, response buffers) |
| nuclei 25 concurrent | ~8–16GB (template loading, crawl state) |
| OS + tools | ~4GB |
| **Total peak (all three)** | **~18–32GB of 64GB** — safe |

**Controller:**
| Activity | Memory Requirement |
|----------|--------------------|
| Neo4j JVM heap | ≥ 8GB |
| Neo4j page cache | ≥ 16GB |
| ClickHouse insert buffer | ~2–4GB |
| AWSEM queue state | ~1–2GB |
| Redis (Bloom filter + checkpoint) | ~512MB–1GB |
| OS + overhead | ~2GB |
| **Total** | **~30–33GB of 16GB** ← EXCEEDS |

**Controller memory risk:** Neo4j alone requires ≥ 24GB (heap + page cache). If controller has only 16GB RAM, Neo4j must share with ClickHouse buffer and Redis.

**Resolution options (in priority order):**
1. Move ClickHouse to Oracle node (separate process, uses Oracle RAM slack — ~30GB available)
2. Reduce Neo4j page cache to 8GB (performance impact; acceptable if SSD-backed)
3. Move Redis to Oracle node (lightweight; ~1GB)
4. Upgrade Controller RAM (recommended for sustained 72h operation)

**Recommended controller config for 72h:**
- Neo4j heap: 6GB
- Neo4j page cache: 8GB (reduced; SSD required)
- ClickHouse on Oracle: moves ~4GB buffer off controller
- Redis on controller: 512MB
- OS overhead: 2GB
- **Total: ~16.5GB** — fits 16GB with careful tuning (swap risk; 32GB controller preferred)

---

## Rollback Indicators

### Phase Rollback Gates

| Phase | Rollback Trigger | Rollback Action |
|-------|-----------------|----------------|
| Phase 1 | DNS error rate > 2% sustained 15 min | Reduce DNS to 150; investigate before Phase 2 |
| Phase 1 | Validate mismatch > 0.5% | HALT ingest; quarantine batch; do not proceed to Phase 2 |
| Phase 2 | HTTP error rate > 10% in first 2k probes | Reduce HTTP to 50 concurrent; re-evaluate gate |
| Phase 2 | DNS-HTTP link rate < 90% | HALT HTTP activation; investigate linking logic |
| Phase 2b | Oracle CPU > 90% sustained 10 min | Reduce Enrich to 5; DNS back to 250 |
| Phase 3 | Neo4j write latency p95 > 500ms | Reduce Neo4j tx from 15 → 10; alert |
| Phase 3 | Any lane DLQ > 2,000 items | Pause affected lane; investigate before resuming |
| Phase 4 | HTTP error rate > 15% at 100 concurrent | Revert HTTP to 75; hold scale-up |
| Any | ORS CRITICAL signal on any monitor | Pause affected lane; execute ORS reflex; alert Mattermost |
| Any | Checkpoint PENDING > 5 min | HALT ingest; investigate stale checkpoint |

### Global Rollback (Full Stop)

Triggers requiring full pipeline halt:
- Source file hash mismatch (corruption_risk class)
- Reconciliation mismatch > 2% (double the warning threshold) on two consecutive batches
- Oracle node unreachable > 120 seconds
- Controller disk I/O saturation (ingest queue growing unbounded)

---

## ORS Monitor Additions for 72h Schedule

| Signal | Warning | Critical | Reflex |
|--------|---------|----------|--------|
| oracle_cpu_utilization_pct | 80% | 90% | Warning: reduce DNS by 25; Critical: pause DNS lane |
| controller_neo4j_latency_p95_ms | 400 | 500 | Warning: reduce Neo4j tx to 10; Critical: pause ingest alert |
| dns_http_link_rate_pct | <95% | <90% | Warning: alert; Critical: halt HTTP lane |
| lane_dlq_depth | 500 | 2000 | Warning: alert; Critical: pause lane |
| phase_gate_violation | — | any gate failed | Suppress next-phase activation; alert |
| controller_disk_write_queue_mb | 500 | 1000 | Warning: reduce batch size; Critical: halt ingest |

---

## Productivity Measurement

### Per-Department KPIs

**DNS Department (Oracle — dnsx):**
- `dns_resolutions_per_hour` target: ≥ 700k/hr (sustained average across 72h)
- `dns_positive_rate` target: ≥ 20%
- `dns_error_rate` target: ≤ 2%
- `dns_dlq_accumulation` target: < 500 items per 24h

**HTTP Department (Oracle — httpx):**
- `http_probes_per_hour` target: ≥ 50k/hr
- `http_positive_rate` target: ≥ 30% (live surfaces)
- `http_error_rate_5xx` target: ≤ 5%
- `http_link_rate` target: ≥ 95% (correctly linked to DNS-confirmed nodes)

**Enrichment Department (Oracle — nuclei/katana):**
- `enrichment_targets_per_hour` target: ≥ 5k/hr
- `findings_per_hour` target: ≥ 50 (critical + high severity findings)
- `oracle_enrichment_cpu_utilization` target: 50–75%

**Ingest Department (Controller):**
- `ingest_records_per_hour` target: ≥ 200k
- `neo4j_write_latency_p95` target: ≤ 500ms
- `clickhouse_insert_queue_depth` target: ≤ 100k rows
- `validate_mismatch_rate` target: ≤ 0.5% per batch

**Operations (ORS + AWSEM):**
- `incident_mttr` target: ≤ 20 min (ORS alert to resolution)
- `premium_model_escalation_rate` target: ≤ 5%
- `dlq_resolution_rate` target: ≥ 80% of DLQ items resolved within 4h

---

## Tradeoffs

| Decision | Chosen | Rejected | Tradeoff |
|----------|--------|----------|----------|
| DNS reduced to 200 in Phase 3 steady state | ✅ | DNS at 250 with Enrich 25 | 250 + Enrich 25 exceeds Oracle CPU; 200 stays within envelope; 11% throughput sacrifice for stability |
| Enrich starts at 10 concurrent, ramps to 25 | ✅ | Enrich at 25 from activation | Avoids CPU spike at activation; 4h ramp allows ORS to confirm safe CPU envelope |
| Phase 1 is DNS-only for 4h | ✅ | Immediate multi-lane start | 4h validation window catches integrity issues before HTTP/Enrich activated; cost: 4h of single-lane throughput |
| Controller memory: Neo4j page cache reduced to 8GB | ✅ | Full 16GB page cache | 16GB page cache requires 32GB+ controller RAM; 8GB page cache with SSD is adequate for 10M node graph |
| HTTP step-up from 75→100→150 in Phase 4 | ✅ | HTTP at 150 from Phase 2 | Aggressive HTTP concurrency under DNS co-run risks rate-limit storms; step-up after DNS corpus reduces |

---

## Risks

| ID | Title | Severity | Probability | Mitigation |
|----|-------|----------|-------------|------------|
| R1 | Oracle CPU exceeds 85% in Phase 3 | HIGH | HIGH | ORS CPU monitor governs DNS concurrency; DNS is most compressible lane |
| R2 | Controller RAM insufficient for Neo4j + ClickHouse | HIGH | MEDIUM | Move ClickHouse to Oracle; reduce Neo4j page cache; 32GB controller recommended |
| R3 | HTTP corpus larger than expected, HTTP lane never completes in 72h | MEDIUM | MEDIUM | HTTP step-up in Phase 4 (100→150) accelerates; HTTP is the long-tail lane |
| R4 | Phase gate failure delays multi-lane activation | MEDIUM | LOW | Phase 1 validation window builds confidence; gates are measurable and clear |
| R5 | DLQ accumulation under high-error network conditions | MEDIUM | MEDIUM | Per-lane DLQ monitors; 72h operation may encounter network instability |
| R6 | Neo4j performance degrades at 10M+ node scale | HIGH | LOW | Heap + page cache tuning; batch size ≤ 500 ops/tx; avoid full-graph scans |
| R7 | Oracle node thermal throttling under 90%+ CPU sustained | LOW | LOW | Monitor oracle_cpu_temp ORS signal if available; CPU governor limits prevent runaway |

---

## Recommendations

| Priority | ID | Action |
|----------|-----|--------|
| 1 | REC-01 | Add oracle_cpu_utilization ORS monitor before Phase 1 starts; set governor reflex to reduce DNS by 25 at 80% CPU |
| 2 | REC-02 | Assess controller RAM before 72h start; if 16GB, move ClickHouse write path to Oracle node |
| 3 | REC-03 | Implement phase gate automation in AWSEM — next lane does not activate until gate signals confirmed by ORS |
| 4 | REC-04 | Export phase transition events and per-lane KPIs to Mattermost OPS channel on each phase change |
| 5 | REC-05 | Set DNS concurrency governor: ORS auto-reduces DNS by 25 at CPU > 80%; auto-restores after 30-min stable period |
| 6 | REC-06 | Pre-configure Neo4j heap (6GB) and page cache (8GB) before Phase 1; verify Neo4j starts within 5 min of config |
| 7 | REC-07 | Define per-lane rollback config flags; any phase rollback reverts concurrency without data loss |
| 8 | REC-08 | Measure and record `time_to_phase_n` for each phase transition; compare against this schedule for calibration |

---

## Validation Strategy

| Gate | Measurement | Pass | Fail Action |
|------|------------|------|-------------|
| Phase 1 → Phase 2 | dns_error_rate ≤ 2%, validate_mismatch ≤ 0.5%, ORS green 30 min | Activate HTTP | Hold Phase 1; alert |
| Phase 2 → Phase 2b | http_positive_rate ≥ 5k targets, http_link_rate ≥ 95% | Activate Enrich at 10 | Hold Phase 2; reduce HTTP to 50 |
| Phase 2b → Phase 3 | oracle_cpu < 80%, enrich_rate stable | Ramp Enrich to 25 | Hold Enrich at 10 |
| Phase 3 → 24h gate | All ORS signals green 2h | Step DNS to 200; allow Phase 4 planning | Hold Phase 3 concurrency |
| Phase 4 HTTP step-up | http_error_rate < 5% at current concurrency | Increment HTTP by 25 | Hold current concurrency |

---

## KPIs

| KPI | Target |
|-----|--------|
| Throughput increase vs. single-lane baseline | ≥ 30% |
| Oracle utilization (CPU) | 65–85% sustained |
| Controller utilization | 50–75% |
| Validate mismatch rate | ≤ 0.5% per batch |
| Incident MTTR | ≤ 20 min |
| Phase gate violations requiring manual intervention | 0 |
| DLQ accumulation per lane per 24h | < 500 items |
| DNS corpus completion | 100% by H48 |
| HTTP corpus completion | ≥ 80% by H72 |

---

## Assumptions

- **A1:** Oracle: >= 32 CPU cores, >= 64GB RAM; CPU governor available via ORS signal
- **A2:** Controller: >= 16GB RAM (32GB preferred); SSD-backed storage for Neo4j
- **A3:** AWSEM supports concurrency adjustment on running lanes without restart
- **A4:** ORS can read oracle_cpu_utilization as a real-time signal (e.g., from system metrics endpoint or agent)
- **A5:** Phase gate signals are evaluated by ORS automatically; manual override available
- **A6:** ClickHouse can be relocated to Oracle node if controller RAM is insufficient (no schema changes required; connection string update only)
- **A7:** Net scan corpus is ~10M subdomains; DNS lane can complete full corpus within 48h at sustained 200 concurrent (actual: ~700k/hr sustained = 14h for 10M; buffer for retries and rate-limit pauses)

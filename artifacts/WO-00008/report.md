# ARTIFACT: WO-00008
# Recon Data Platform v1 — End-to-End Architecture

**Analyst:** OpenClaw Field Processor
**Work Order:** WO-00008
**Category:** Architecture
**Priority:** High
**Date:** 2026-03-03
**Status:** COMPLETED
**ARD Mode:** ARCHITECTURE — HIGH

---

## Executive Summary

WO-00008 delivers the Recon Data Platform v1 architecture covering the full pipeline from scan execution through to analyst API consumption. The architecture is organized as seven vertical layers, three horizontally partitioned delivery phases (≤2 weeks each), and a coherent dual-store authority model.

The platform is designed for:
- 10M+ FQDN corpus at continuous batch cadence
- Multi-lane parallel scan (DNS → HTTP → Enrichment) with strict integrity controls
- Dual-store canonical authority (Neo4j graph + ClickHouse telemetry)
- Analyst consumption via REST API and Mattermost reporting

---

## Context Understanding

**Stack:** Hybrid controller (orchestration, ingest, API) + Oracle worker (heavy scans). Active subsystems: KRIL, ORS, AWSEM.

**Constraints:** JSON-first outputs, idempotent ingest, checkpoint-first write order, no destructive mutation, conservative risk profile.

**Design philosophy:** Deterministic and extensible architecture with staged delivery and measurable outcomes.

**Known risks to architect against:** Data drift under concurrent writes, duplicate writes, weak prioritization signal, frontend over-complexity, unbounded token burn.

---

## System Architecture

### Overview

```
+------------------+          +------------------+          +------------------+
|  CORPUS MANAGER  |  -----> |    ORACLE NODE   |  -----> |   PARSER LAYER   |
| (AWSEM scheduler)|          | (dnsx httpx nuc) |          | (Controller)     |
+------------------+          +------------------+          +------------------+
                                                                     |
                    +------------------------------------------------+
                    v
+------------------+          +------------------+          +------------------+
|  CHECKPOINT STR  |  <----> |   INGEST LAYER   |  -----> |    NEO4J GRAPH   |
| (Redis/SQLite)   |          | (Controller)     |          | (canonical auth) |
+------------------+          +------------------+          +------------------+
                                      |
                                      v
                             +------------------+
                             |   CLICKHOUSE     |
                             | (telemetry store)|
                             +------------------+
                                      |
                    +-----------------+------------------+
                    v                                    v
         +------------------+               +------------------+
         |  SCORING / KRIL  |               |   ANALYST API    |
         | (Controller)     |               | (REST + MM)      |
         +------------------+               +------------------+
                                                      |
                                                      v
                                            +------------------+
                                            |  ORS + AWSEM     |
                                            | (meta-layer)     |
                                            +------------------+
```

---

### Layer 1: Corpus Manager (AWSEM Scheduler)

**Responsibility:** Partition and dispatch scan tasks across lanes and phases.

**Inputs:**
- Source FQDN file (SHA-256 verified at session start)
- Phase gate signals from ORS

**Partitioning contract:**
- Chunk size: 10,000 FQDNs per DNS task; 1,000 FQDNs per HTTP task; 50 FQDNs per Enrich task
- Chunk ID: `SHA256(source_hash + chunk_offset)[:16]`
- Chunks are idempotent units — replaying a chunk ID produces the same result

**Queue structure:**
```
dns_queue           → [dns_task: {chunk_id, fqdns[], priority}]
http_queue          → [http_task: {chunk_id, fqdns[], dns_batch_id}]
enrich_queue        → [enrich_task: {chunk_id, fqdns[], http_batch_id, kril_score}]
dns_dlq             → [failed dns_tasks]
http_dlq            → [failed http_tasks]
enrich_dlq          → [failed enrich_tasks]
```

**Phase gate enforcement:**
- HTTP queue blocked until Phase 1 gate confirmed (ORS signal)
- Enrich queue blocked until Phase 2b gate confirmed
- Gate state stored in AWSEM; not re-evaluated after passage

---

### Layer 2: Scan Execution (Oracle Node)

**Responsibility:** Execute scan tools against task chunks; write results atomically to temp dir.

#### DNS Sub-Lane

| Property | Value |
|----------|-------|
| Tool | dnsx |
| Concurrency | 250 (Phase 1), 200 (Phase 3 steady state) |
| Input | FQDN list from dns_task |
| Timeout per target | 30s |
| Output schema | `{fqdn, a_records[], aaaa_records[], cname_chain[], mx[], txt[], ns[], resolved, error, scanned_at, batch_id}` |
| Output location | `/tmp/oracle-work/{batch_id}/dns/{chunk_id}.json` → atomic move on success |

#### HTTP Sub-Lane

| Property | Value |
|----------|-------|
| Tool | httpx |
| Concurrency | 75 (Phase 2), 100–150 (Phase 4 step-up) |
| Input | DNS positives only |
| Timeout per target | 30s |
| Output schema | `{fqdn, url, ip, status_code, content_length, content_type, title, headers{}, body_hash, redirect_chain[], responded_at, batch_id}` |
| Output location | `/tmp/oracle-work/{batch_id}/http/{chunk_id}.json` → atomic move |

#### Enrich Sub-Lane

| Property | Value |
|----------|-------|
| Tools | nuclei (vuln templates) + katana (crawl) |
| Concurrency | 10→25 (ramp), 25 (steady state) |
| Input | HTTP positives with KRIL score ≥ threshold |
| Timeout per target | nuclei: 5 min; katana: 2 min |
| Output schema | `{fqdn, tool, template_id, severity, cvss, finding_class, evidence{}, crawl_links[], discovered_at, batch_id}` |
| Output location | `/tmp/oracle-work/{batch_id}/enrich/{chunk_id}.json` → atomic move |

**Oracle responsibilities:**
- Output size limits enforced (dnsx 10MB, httpx 50MB, nuclei 100MB per batch)
- Tool version pinned in deployment manifest
- Heartbeat to Controller every 30s
- Work directory cleaned after successful batch transfer

---

### Layer 3: Parser (Controller)

**Responsibility:** Transform raw tool outputs into normalized, validated, deduplicated records ready for ingest.

#### Parser Contract (per tool)

**dnsx_parser_v1:**
```
Input:  /tmp/oracle-work/{batch_id}/dns/{chunk_id}.json
Schema: {fqdn:str, a_records:[str], resolved:bool, error:str|null, scanned_at:ISO8601, batch_id:str}
Normalizations:
  - fqdn.lower().rstrip('.')
  - a_records sorted and deduplicated
  - scanned_at → UTC ISO8601
Dedup key: SHA256(fqdn + "dns")[:32]
On schema fail: quarantine(record, reason) → DLQ
Output: normalized_dns_record[]
```

**httpx_parser_v1:**
```
Input:  /tmp/oracle-work/{batch_id}/http/{chunk_id}.json
Schema: {fqdn:str, url:str, ip:str, status_code:int, body_hash:str, responded_at:ISO8601, batch_id:str}
Normalizations:
  - fqdn.lower(), url.lower()
  - body_hash: SHA256(response_body) — static content only; dynamic content flag if body varies
Dedup key: SHA256(fqdn + url + status_code)[:32]
On schema fail: quarantine(record, reason) → DLQ
Output: normalized_http_record[]
```

**nuclei_parser_v1:**
```
Input:  /tmp/oracle-work/{batch_id}/enrich/{chunk_id}.json
Schema: {fqdn:str, template_id:str, severity:enum[info|low|medium|high|critical], evidence:{}, discovered_at:ISO8601}
Normalizations:
  - template_id as canonical identifier
  - severity mapped to severity_int (info=0, low=1, medium=2, high=3, critical=4)
Dedup key: SHA256(fqdn + template_id + evidence_hash)[:32]
On schema fail: quarantine(record, reason) → DLQ
Output: normalized_finding_record[]
```

**katana_parser_v1:**
```
Input:  included in enrich output
Schema: {fqdn:str, crawl_links:[str], discovered_at:ISO8601}
Normalizations:
  - crawl_links normalized to FQDN-only (strip paths for entity linking)
Dedup key: SHA256(fqdn + "crawl" + batch_id)[:32]
Output: normalized_crawl_record[]
```

**Quarantine protocol:**
- Malformed records written to `artifacts/quarantine/{batch_id}/`
- Quarantine event emitted to ORS signal bus
- DLQ depth reported to Mattermost on 100-item increment

---

### Layer 4: Ingest (Controller)

**Responsibility:** Write normalized records to dual stores with checkpoint safety and write order enforcement.

#### Checkpoint-First Write Order (enforced by code assertion)

```
1. bloom_filter.check(dedup_key) → skip if seen (FPR 0.01%)
2. checkpoint(PENDING, dedup_key, batch_id)
3. neo4j_write(record)           ← ASSERT: checkpoint=PENDING first
4. clickhouse_write(record)      ← ASSERT: neo4j_write succeeded
5. checkpoint(COMPLETED, dedup_key)
6. bloom_filter.add(dedup_key)
```

On any step failure: retry step (up to max_retries), then DLQ. Never skip checkpoint.

#### Neo4j Schema (Graph Authority)

```cypher
// Nodes
(:Subdomain {name, key_hash, a_records[], first_seen, last_seen, resolved, kril_score, asset_risk_score, ingested_batch_id})
(:IPAddress {addr, ptr, asn, country, org, first_seen, last_seen})
(:Service {port, protocol, banner, product, version})
(:HTTPResponse {url, status_code, content_type, title, body_hash, first_seen})
(:Finding {template_id, severity, severity_int, cvss, finding_class, confirmed_at})
(:Domain {name, tld, registrar, expires_at})

// Relationships
(:Subdomain)-[:RESOLVES_TO]->(:IPAddress)
(:Subdomain)-[:IS_SUBDOMAIN_OF]->(:Domain)
(:IPAddress)-[:HOSTS]->(:Service)
(:Subdomain)-[:RESPONDS_WITH]->(:HTTPResponse)
(:Subdomain)-[:HAS_FINDING]->(:Finding)
(:Subdomain)-[:LINKS_TO]->(:Subdomain)    // From katana crawl
(:Subdomain)-[:SAN_PEER]->(:Subdomain)    // From TLS SAN co-occurrence

// Constraints (mandatory before first write)
CREATE CONSTRAINT subdomain_name_unique IF NOT EXISTS FOR (n:Subdomain) REQUIRE n.name IS UNIQUE;
CREATE CONSTRAINT ip_addr_unique IF NOT EXISTS FOR (n:IPAddress) REQUIRE n.addr IS UNIQUE;
CREATE CONSTRAINT finding_key_unique IF NOT EXISTS FOR (n:Finding) REQUIRE n.template_id IS NOT NULL;
```

**Write patterns:**
- `MERGE (n:Subdomain {name: $fqdn}) SET n += $props` — idempotent merge
- Batch size: ≤500 ops per transaction
- Transaction timeout: 60s
- On timeout: retry with half batch size

#### ClickHouse Schema (Telemetry)

```sql
-- DNS telemetry
CREATE TABLE dns_scan_log (
    batch_id    String,
    fqdn        String,
    key_hash    FixedString(32),
    a_records   Array(String),
    resolved    UInt8,
    error       Nullable(String),
    scanned_at  DateTime,
    version     UInt64
) ENGINE = ReplacingMergeTree(version)
  ORDER BY (fqdn, batch_id)
  PARTITION BY toYYYYMM(scanned_at);

-- HTTP telemetry
CREATE TABLE http_scan_log (
    batch_id        String,
    fqdn            String,
    url             String,
    key_hash        FixedString(32),
    ip              String,
    status_code     UInt16,
    content_length  UInt64,
    body_hash       FixedString(64),
    title           Nullable(String),
    responded_at    DateTime,
    version         UInt64
) ENGINE = ReplacingMergeTree(version)
  ORDER BY (fqdn, url, batch_id);

-- Findings telemetry
CREATE TABLE findings_log (
    batch_id        String,
    fqdn            String,
    template_id     String,
    key_hash        FixedString(32),
    severity        LowCardinality(String),
    severity_int    UInt8,
    cvss            Nullable(Float32),
    finding_class   String,
    discovered_at   DateTime,
    version         UInt64
) ENGINE = ReplacingMergeTree(version)
  ORDER BY (fqdn, template_id, batch_id);
```

**Read patterns:** All reconciliation queries use `FINAL` keyword. Background merge monitored by ORS.

---

### Layer 5: Scoring (Controller)

**Responsibility:** Compute KRIL scores and risk/value scores; write back to Neo4j after each scan cycle.

#### KRIL Score (0–100)

Composite signal ranking per subdomain:

| Signal | Weight | Description |
|--------|--------|-------------|
| http_positive | 30 | HTTP response received (binary, high signal) |
| status_interesting | 20 | Status codes 200, 301, 302, 401, 403 (not 404/5xx) |
| finding_density | 25 | Count of nuclei findings × severity_weight |
| link_complexity | 10 | Unique outbound crawl links (graph richness) |
| recency_bonus | 15 | Scanned in last 24h × active_scan_bonus |

Score computed in T2 batch (50 targets per call) per WO-00004 routing policy.

**Write-back:** `MATCH (n:Subdomain {name: $fqdn}) SET n.kril_score = $score` — after each DNS/HTTP cycle.

#### Risk/Value Score

| Score | Formula | Purpose |
|-------|---------|---------|
| `asset_risk_score` | severity_weighted_finding_count × ip_diversity_factor | Prioritize high-risk assets |
| `bounty_potential_score` | scope_membership × asset_risk_score × kril_score | Prioritize findings for submission |
| `freshness_score` | 1.0 if scanned < 24h, decay(last_seen) otherwise | Deprioritize stale data |

---

### Layer 6: Analyst API (Controller)

**Responsibility:** Expose structured query interface for human analysts and external integrations.

#### REST API Endpoints (v1)

```
GET  /api/v1/subdomains
     ?filter=resolved|http_positive|has_findings
     &sort=kril_score|asset_risk_score|first_seen
     &severity=critical|high|medium|low
     &limit=100&offset=0
     Response: {subdomains: [...], total: int, page: int}

GET  /api/v1/subdomains/{fqdn}
     Response: {subdomain, ip_addresses[], http_responses[], findings[], kril_score, last_scanned}

GET  /api/v1/findings
     ?severity=critical|high&template_id=...&sort=discovered_at
     &limit=100
     Response: {findings: [...], total: int}

GET  /api/v1/graph/neighbors
     ?seed_fqdn=...&depth=2&relationship=LINKS_TO|SAN_PEER
     Response: {nodes: [...], edges: [...], hop_count: int}

GET  /api/v1/stats/summary
     Response: {
       corpus_total: int, dns_completed_pct: float,
       http_completed_pct: float, findings_total: int,
       critical_findings: int, slo_status: {...},
       phase_current: int, last_updated: ISO8601
     }

GET  /api/v1/stats/throughput
     ?window=1h|6h|24h
     Response: {dns_per_hour: float, http_per_hour: float, ...}
```

**API query backend:** Neo4j Cypher for graph queries; ClickHouse for aggregate stats and throughput metrics.

**Latency SLO:**
- p99 response time ≤ 2s for all endpoints
- `/graph/neighbors` depth ≤ 3 hops enforced (prevents full-graph traversal)

#### Mattermost Reporting

| Report | Trigger | Channel | Content |
|--------|---------|---------|---------|
| Hourly KPI | Every 60 min | `#ops-monitoring` | Throughput per lane, SLO status, DLQ counts |
| Phase transition | Phase gate passed | `#ops-critical` | Phase name, gate metrics, next phase config |
| Alert | ORS signal breach | `#ops-critical` | Alert ID, metric value, threshold, reflex taken |
| Session summary | 72h completion | `#ops-critical` | Total corpus processed, findings, SLO compliance |

---

### Layer 7: ORS + AWSEM (Meta-Layer)

**ORS (Operational Reflex System):**
- Monitors 15 signals from alert catalog (ALT-001 through ALT-015)
- Autonomous reflexes: reduce concurrency, pause lane, alert Mattermost
- Heartbeat monitored by external watchdog (≤ 60s absence = alert)
- Config in `ors_config.json` — no hardcoded thresholds

**AWSEM (Scheduler):**
- Per-lane queues with enforced depth caps (not advisory)
- Phase gate automation: next lane activation requires ORS gate confirmation
- DLQ with TTL and manual re-enqueue only
- Concurrency caps enforced at dispatch level

---

## Three Phased Milestones

### Phase 1 (Weeks 1–2): Core Ingest Pipeline

**Scope:**
- DNS lane operational (250 concurrent)
- Parser + checkpoint + Neo4j + ClickHouse ingest
- Basic ORS (8 signals: DNS throughput, Neo4j latency, checkpoint staleness, controller disk)
- Health API endpoint (`/api/v1/stats/summary`)

**Gate criteria:**
- DNS error rate ≤ 2%
- Neo4j write latency p95 ≤ 500ms
- Checkpoint integrity test passes (kill Redis → SQLite WAL fallback verified)
- 10,000 Subdomain nodes ingested successfully

**Deliverable:** 10M DNS corpus processable, entities in Neo4j and ClickHouse.

**Week 1 tasks:**
- Deploy Redis (AOF, noeviction), Neo4j (constraints, heap/cache), ClickHouse (schema)
- Implement checkpoint store (Redis + SQLite fallback)
- Implement Bloom filter (Redis, 10M insertions)
- Implement dnsx parser and DNS ingest path
- Unit test: checkpoint integrity, write order assertion, dedup key contracts

**Week 2 tasks:**
- Integrate AWSEM dns_queue with concurrency cap
- Add ORS 8-signal monitors
- Implement basic `/api/v1/stats/summary`
- Run 1h validation pass with 100k FQDN sample
- Fix issues; verify SLOs

---

### Phase 2 (Weeks 3–4): HTTP + Enrichment + Scoring

**Scope:**
- HTTP lane operational (75 concurrent)
- Enrichment lane operational (10→25 concurrent)
- KRIL scoring loop (T2 batch, 50 targets/call)
- Full ORS (15 signals)
- Phase gate automation in AWSEM
- Risk/value scoring write-back to Neo4j

**Gate criteria (to activate HTTP):**
- Phase 1 gate passed (verified ORS green 30 min)
- HTTP error rate ≤ 10% on first 2,000 probes
- DNS-HTTP link rate ≥ 95% (HTTP positives linked to DNS records)

**Gate criteria (to activate Enrich):**
- HTTP positives ≥ 10,000
- KRIL scores computed for HTTP positive set

**Deliverable:** HTTP positives identified and scored; findings enriched and ranked.

**Week 3 tasks:**
- Implement httpx parser and HTTP ingest path
- Implement HTTP phase gate in AWSEM
- Implement KRIL scoring batch (T2 call, 50 targets)
- Implement ORS signals 9-15

**Week 4 tasks:**
- Implement nuclei + katana parsers and enrichment ingest path
- Implement enrich phase gate in AWSEM (gradual ramp: 10→25 over 4h)
- Implement risk/value scoring
- Run full multi-lane 12h test
- Fix issues; verify all SLOs

---

### Phase 3 (Weeks 5–6): Analyst API + Reporting + Intelligence Layer

**Scope:**
- Full REST API (5 endpoints)
- Mattermost reporting (4 report types)
- ClickHouse materialized views for dashboard queries
- Graph next-hop API (`/api/v1/graph/neighbors`)
- TLS SAN expansion integration (passive corpus expansion)

**Gate criteria:**
- All REST endpoints respond p99 ≤ 2s under load test (100 concurrent requests)
- Mattermost hourly report delivers for 3 consecutive hours
- Graph neighbor query at depth=2 returns in ≤ 2s for 95% of seeds

**Deliverable:** Production-ready analyst platform; intelligence consumable without raw data access.

**Week 5 tasks:**
- Implement all REST API endpoints backed by Neo4j + ClickHouse
- Implement Mattermost webhooks (4 report types)
- Implement ClickHouse materialized views (hourly throughput, finding summary)

**Week 6 tasks:**
- Implement graph next-hop query (Cypher, max depth 3)
- Integrate TLS SAN expansion (passive corpus growth)
- Load test all endpoints
- Document API; create runbook
- Run 72h full production simulation

---

## Ingest Latency SLOs by Stage

| Stage | Metric | Target | Warning | Critical |
|-------|--------|--------|---------|----------|
| DNS scan → parser output | dns_parse_latency_p95_ms | ≤ 200ms | > 200ms | > 500ms |
| Parser output → Neo4j committed | neo4j_write_latency_p95_ms | ≤ 500ms | > 400ms | > 500ms |
| Parser output → ClickHouse committed | ch_insert_latency_p95_ms | ≤ 300ms | > 300ms | > 1000ms |
| HTTP scan → parser output | http_parse_latency_p95_ms | ≤ 500ms | > 500ms | > 1500ms |
| Enrichment finding → ingest complete | enrich_ingest_latency_p95_ms | ≤ 5000ms | > 5000ms | > 10000ms |
| KRIL score → Neo4j write-back | kril_writeback_latency_p95_ms | ≤ 500ms | > 500ms | > 1000ms |
| API query response | api_response_p99_ms | ≤ 2000ms | > 1500ms | > 2000ms |
| End-to-end (scan → queryable) | e2e_ingest_latency_p95_min | ≤ 5 min | > 5 min | > 15 min |

---

## Component Dependency Map

```
AWSEM ─────────────────────────────── drives → Oracle execution
Oracle ─────────────────────────────── feeds → Parser
Parser ──────────────────────────────── feeds → Checkpoint → Neo4j → ClickHouse
Checkpoint ─────────────────────────── backed by → Redis (primary) / SQLite (fallback)
Neo4j ──────────────────────────────── feeds → Scoring, Graph API
ClickHouse ─────────────────────────── feeds → Stats API, Materialized Views
Scoring ────────────────────────────── writes back to → Neo4j
ORS ────────────────────────────────── monitors → all layers; controls → AWSEM
Mattermost ─────────────────────────── receives from → ORS, API reporting module
```

**Critical path (data must flow through):**
AWSEM → Oracle → Parser → Checkpoint → Neo4j → ClickHouse → API

**Parallel-safe layers:**
- DNS and HTTP can run concurrently (after Phase 1 gate)
- Scoring can run concurrently with ingest (reads current batch; writes to prior batch nodes)
- API queries can run anytime (read-only; no lock contention with ingest under proper isolation)

---

## Tradeoffs

| Decision | Chosen | Rejected | Rationale |
|----------|--------|----------|-----------|
| Dual-store authority (Neo4j + ClickHouse) | ✅ | Single store | Neo4j excels at graph traversal and entity linking; ClickHouse excels at time-series aggregation. Combining both avoids forcing either store into an unsuitable workload. |
| Neo4j-first write order | ✅ | ClickHouse-first | Neo4j is the canonical entity graph — if Neo4j write fails, the entity doesn't exist and CH insert is meaningless. Neo4j-first ensures consistency. |
| Checkpoint before any write | ✅ | Write-then-checkpoint | Write-then-checkpoint cannot recover partial writes. Checkpoint-first enables replay from exactly the failed record. |
| Bloom filter for pre-write dedup | ✅ | Query-then-write | Querying Neo4j per record before write creates O(N) query overhead. Bloom filter reduces this to O(1) with 0.01% FPR acceptable at 10M scale. |
| AWSEM dispatch-level concurrency caps | ✅ | Advisory limits | Advisory limits allow burst overcommit causing Oracle CPU spikes. Dispatch-level enforcement prevents overcommit structurally. |
| Three 2-week phases | ✅ | Big-bang delivery | Staged delivery allows early production use (Phase 1 DNS data usable while HTTP and API are built). Reduces rework risk. |
| REST API backed by Neo4j + ClickHouse | ✅ | API backed by files | File-backed API cannot support real-time filtering, sorting, or graph traversal at analyst speed. |

---

## Risks

| ID | Title | Severity | Probability | Mitigation |
|----|-------|----------|-------------|------------|
| R1 | Neo4j degrades at 10M+ node scale | HIGH | LOW | Heap+page cache pre-configured; MERGE batch ≤ 500 ops; no full-graph scans during ingest |
| R2 | ClickHouse background merge falls behind | HIGH | MEDIUM | ORS monitors clickhouse_parts_per_table; OPTIMIZE TABLE on WARNING |
| R3 | API query performance degrades under load | MEDIUM | MEDIUM | Materialized views for aggregate queries; depth limit on graph traversal; index pre-verified |
| R4 | Enrichment DLQ accumulation | MEDIUM | MEDIUM | Per-lane DLQ TTL; ORS alert at 500 items; Enrich concurrency auto-reduced on Oracle memory pressure |
| R5 | Phase gate failure delays multi-lane activation | MEDIUM | LOW | Gate metrics are measurable and observable; Phase 1 window builds high confidence before commit |
| R6 | Scoring batch bottleneck | LOW | LOW | KRIL scoring runs after scan cycle, not inline; does not block ingest throughput |

---

## Recommendations

| Priority | ID | Action |
|----------|-----|--------|
| 1 | REC-01 | Build DNS ingest path end-to-end (Phase 1) before adding HTTP — validates foundation before complexity |
| 2 | REC-02 | Apply Neo4j schema constraints and verify before first production write |
| 3 | REC-03 | Implement phase gate automation in AWSEM before Phase 2 — manual gate timing is error-prone at 72h |
| 4 | REC-04 | Add ORS 15-signal monitoring before Phase 2 start — enrichment + scoring add complexity |
| 5 | REC-05 | Implement `/api/v1/stats/summary` in Phase 1 — gives immediate operational visibility |
| 6 | REC-06 | Use ClickHouse materialized views for all aggregate API queries — prevents query latency regression as data grows |
| 7 | REC-07 | Defer graph visualization frontend to Phase 3 — REST API + Mattermost sufficient for Phase 1-2 intelligence consumption |
| 8 | REC-08 | Run 1h dry-run for each phase before committing to 72h operation window |

---

## Implementation Approach

### What is Reusable from Existing Stack
- AWSEM queue infrastructure: reuse, add HTTP/Enrich queues and phase gate logic
- ORS signal framework: reuse, extend from 8 to 15 signals
- Checkpoint store (Redis/SQLite): reuse as-is
- Bloom filter (Redis): reuse as-is
- Neo4j connection pool: reuse, extend schema
- ClickHouse connection: reuse, extend schema

### What Must Be Built (Net New)
- httpx and nuclei/katana parsers (dnsx parser assumed existing)
- Phase gate logic in AWSEM
- KRIL scoring module (T2 batch call integration)
- Risk/value scoring logic
- REST API layer (5 endpoints)
- Mattermost reporting module
- ClickHouse materialized views

### What Can Run in Parallel Safely (Development)
- HTTP parser development (no dependency on Enrich)
- KRIL scoring module (no dependency on HTTP parser; uses parsed records as input)
- REST API endpoint development (mock data for testing)
- Mattermost reporting module (mock events for testing)

### What Should Be Deferred
- Multi-worker Oracle (additional Oracle nodes) — defer to v1.1
- Frontend dashboard — defer to v1.1 (Mattermost + API sufficient for v1)
- Full Cypher-based graph analytics — defer to after Phase 3 stability confirmed

---

## Validation Strategy

| Check | Method | Pass Condition |
|-------|--------|---------------|
| DNS ingest end-to-end | Run 10k FQDN sample; verify Neo4j + ClickHouse | All records in both stores; checkpoint COMPLETED for all |
| HTTP phase gate | Verify gate blocks HTTP until ORS confirms | HTTP queue not drained until gate confirmed |
| Dedup correctness | Replay same 1k FQDNs twice | Zero duplicate nodes in Neo4j |
| Write order enforcement | Inject Neo4j failure; check ClickHouse | No ClickHouse write on Neo4j failure |
| API latency | Load test all endpoints (100 concurrent) | p99 ≤ 2s for all endpoints |
| Graph neighbor query | Query depth=2 on 100 seed FQDNs | All return in ≤ 2s |
| KRIL score write-back | Verify kril_score updated in Neo4j after each cycle | Score monotonically updating per cycle |
| Mattermost reporting | Trigger hourly report manually | Report received in #ops-monitoring |

---

## KPIs

| KPI | Target |
|-----|--------|
| Phase 1 deliverable completion | DNS corpus processable end-to-end |
| Phase 2 deliverable completion | HTTP positives + findings scored and enriched |
| Phase 3 deliverable completion | Analyst API functional; reports delivered |
| Data loss under replay | ≤ 0.5% |
| e2e ingest latency p95 | ≤ 5 min (scan to queryable) |
| API query latency p99 | ≤ 2s |
| Throughput vs single-lane baseline | ≥ 30% improvement |
| Schema constraint coverage | 100% (all entity types constrained before write) |

---

## Assumptions

- **A1:** Oracle has ≥ 32 CPU cores, ≥ 64GB RAM; Controller has ≥ 16GB RAM (32GB recommended)
- **A2:** Redis, Neo4j, ClickHouse deployable on Controller or Oracle as needed based on RAM constraints
- **A3:** AWSEM supports concurrency cap enforcement at dispatch level (not advisory)
- **A4:** ORS reads real-time signals from Neo4j, ClickHouse, and Redis
- **A5:** Mattermost webhook URL available for reporting integration
- **A6:** dnsx, httpx, nuclei, katana tools available on Oracle with version pinning
- **A7:** REST API requires no auth for v1 (internal network only); auth layer deferred to v1.1
- **A8:** ClickHouse materialized views sufficient for analyst dashboard queries without additional BI layer

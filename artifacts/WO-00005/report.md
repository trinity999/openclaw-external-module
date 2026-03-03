# ARTIFACT: WO-00005
# High-ROI Recon Technique Upgrade Portfolio

**Analyst:** OpenClaw Field Processor
**Work Order:** WO-00005
**Category:** Research
**Priority:** High
**Date:** 2026-03-03
**Status:** COMPLETED
**ARD Mode:** RESEARCH — EXPANSIVE

---

## Executive Summary

WO-00005 identifies five high-ROI recon technique upgrades applicable to the current hybrid controller+oracle stack without architectural redesign. Each technique is evaluated on expected gain, implementation complexity, rollback indicators, cost impact, and productivity measurement.

Portfolio is ordered by deployment readiness — techniques that can be activated immediately precede those requiring pipeline additions.

| Rank | Technique | Expected Gain | Complexity | Rollback Risk |
|------|-----------|--------------|------------|---------------|
| T1 | TLS SAN Subdomain Expansion | +15–30% corpus coverage | LOW | LOW |
| T2 | Nuclei Template Auto-Selection from HTTP Fingerprint | −60–80% enrichment scan time | MEDIUM | LOW |
| T3 | Passive DNS Overlay (Pre-Resolution Feed) | +20–40% coverage on inactive subdomains | LOW | VERY LOW |
| T4 | Dynamic KRIL Re-Ranking on Live Signal | +30–50% faster time-to-insight | MEDIUM | MEDIUM |
| T5 | Graph-Driven Next-Hop Discovery (Neo4j Pattern Queries) | +15–30% novel high-value target discovery | HIGH | LOW |

All techniques operate within: JSON-first outputs, idempotent ingest, checkpoint replayability, no destructive mutation.

---

## Context Understanding

System: Hybrid controller+oracle, 10M+ subdomains, batch pipeline, KRIL/ORS/AWSEM active.
Goal: +30% throughput increase without integrity regression.
Constraint: Conservative risk profile. No architecture redesign.
Scope: Techniques that fit within the existing lane structure.

---

## Analytical Reasoning

### Selection Criteria

Techniques were evaluated against four dimensions:

1. **ROI** — gain-to-effort ratio: coverage expansion, throughput increase, or time-to-insight improvement
2. **Fit** — compatibility with existing JSON-first, lane-sequential architecture
3. **Risk** — probability of integrity regression, data corruption, or pipeline instability
4. **Parallelizability** — whether the technique can activate independently of others

Rejected candidates:
- Full corpus re-scan strategies (destructive, not additive)
- External data broker integrations (cost unbounded, not auditable)
- Async agent spawning beyond current controller capacity (architecture change)

---

## Technique Portfolio

---

### T1 — TLS SAN Subdomain Expansion

**Complexity:** LOW | **Deploy:** Immediate (HTTP lane add-on)

#### What It Is
Every HTTPS response carries a TLS certificate. Certificates include a Subject Alternative Names (SANs) extension listing all valid domain names for that certificate. A single wildcard cert for `*.example.com` issued across 10 services will list all 10 hostnames in the SANs field.

Parsing SANs from every HTTPS target yields new subdomain candidates not present in the original corpus.

#### Implementation
```
HTTP lane (httpx) → extract TLS SANs from each HTTPS response
Controller parses SAN list → normalize + deduplicate against Bloom filter
New candidates → re-enter DNS queue with KRIL priority score
```

- httpx supports `--tls-grab` / `-tls-probe` flags for certificate extraction in JSON output
- SAN parsing is string processing; no external dependencies
- Bloom filter dedup prevents re-scanning known subdomains
- KRIL scores new candidates at median priority until DNS confirms them

#### Expected Gain
- TLS certificates often cover 10–100+ SANs per host
- At 60,000 HTTP probes/hr with 25% HTTPS, ~15,000 certs scanned/hr
- Conservative 5 new unique SANs per cert = **75,000 new candidates/hr** feeding back to DNS queue
- Estimated corpus expansion: **+15–30%** over full run

#### Cost Impact
- No additional Oracle invocations beyond what HTTP lane already does
- SAN parsing CPU cost: negligible (Controller-side string processing)
- New DNS queue entries: ~75k/hr at existing DNS throughput → absorbed within existing envelope

#### Rollback Indicators
- DNS queue depth exceeding high-water mark → ORS backpressure already handles this
- SAN dedup rate < 50% (most SANs are new, not seen before) → indicates Bloom filter not pre-warmed
- Rollback trigger: disable SAN extraction flag in httpx config; zero pipeline disruption

#### Productivity Measurement
- `san_candidates_generated / http_probes` ratio per hour
- `san_dns_positive_rate` — what % of SAN candidates resolve (indicates intel quality)
- Target: san_dns_positive_rate ≥ 15%

---

### T2 — Nuclei Template Auto-Selection from HTTP Fingerprint

**Complexity:** MEDIUM | **Deploy:** Next sprint (requires fingerprint→template mapping table)

#### What It Is
Nuclei is a template-based scanner. Running all templates on all targets wastes Oracle capacity — a WordPress template is irrelevant on a Java Spring Boot API. HTTP fingerprinting (server header, X-Powered-By, response body patterns, Wappalyzer-style heuristics) identifies the technology stack. Template selection is then targeted.

#### Implementation
```
HTTP lane output → technology fingerprint extraction (Controller-side)
Controller maps fingerprint → nuclei template subset
Enrich lane (Oracle) runs only matched template subsets
Unclassified targets → run "universal" template subset (20% of all templates)
```

**Fingerprint-to-template mapping (examples):**

| Fingerprint Signal | Template Subset | Approx Template Count |
|-------------------|----------------|----------------------|
| Server: Apache | apache, php, generic-web | ~200 |
| X-Powered-By: PHP | php, wordpress, drupal, generic-web | ~300 |
| Server: nginx + React SPA | nginx, generic-web, api | ~150 |
| X-Powered-By: Express | nodejs, express, generic-web | ~100 |
| Server: Tomcat | java, tomcat, struts, generic-web | ~150 |
| No match | universal (20% of all) | ~400 |

Assuming nuclei has ~2,000 templates total:
- Targeted scan: 100–300 templates per target
- Universal fallback: ~400 templates per target
- vs. full scan: 2,000 templates per target

#### Expected Gain
- **6–20× reduction** in nuclei execution time per target
- At 25 concurrent enrichment workers, this multiplies effective throughput equivalently
- Same or better detection rate (false negatives only for misclassified targets, covered by universal fallback)

#### Cost Impact
- Fingerprint extraction: Controller-side, no Oracle cost
- Template mapping table: one-time creation
- Oracle enrichment time: **−60–80%** → Oracle cores freed for DNS/HTTP lane acceleration

#### Rollback Indicators
- Detection rate drop > 15% compared to baseline universal scan → fingerprint misclassification
- High "unclassified" rate > 30% → fingerprint signals insufficient; expand heuristics
- Rollback: revert template selection to universal; no data loss

#### Productivity Measurement
- `templates_executed / target` ratio (should be 100–400, not 2,000)
- `findings_per_hour` (should match or exceed pre-technique baseline)
- `oracle_enrichment_utilization` (should free 60–80% of enrichment time)

---

### T3 — Passive DNS Overlay (Pre-Resolution Feed)

**Complexity:** LOW | **Deploy:** Immediate (API integration only)

#### What It Is
Passive DNS (PDNS) databases collect historical DNS resolution data. Subdomains that were live 6 months ago but are currently NXDOMAIN will not be found by active dnsx scanning — but PDNS records them.

Before dispatching a batch to Oracle for active resolution, the Controller queries PDNS APIs for historical records of those subdomains. PDNS hits get pre-labeled with their last-seen data and fed to the ingest lane directly (bypassing Oracle DNS resolution).

This expands intelligence on inactive assets — high-value for attack surface mapping.

#### Implementation
```
Pre-DNS-dispatch: Controller sends subdomain batch to PDNS API
PDNS results (if any) → pre-labeled DNS records → ingest directly
Remaining subdomains (no PDNS hit) → Oracle dnsx for active resolution
```

**Candidate PDNS sources (general knowledge):**
- SecurityTrails API (commercial, rate-limited)
- VirusTotal passive DNS (free tier rate-limited)
- CIRCL PDNS (free, research-focused)
- Shodan historical DNS (commercial)

Implementation uses whichever PDNS source is available. Output normalized to same JSON schema as active dnsx output.

#### Expected Gain
- PDNS typically covers 20–40% of historical subdomain activity
- Coverage of inactive assets: significant for attack surface completeness
- **+20–40% coverage expansion** on the inactive subdomain population
- Oracle DNS load reduction: subdomains with PDNS hits skip active resolution → Oracle focused on unknowns

#### Cost Impact
- PDNS API calls: low cost (often free tier sufficient)
- No additional Oracle scan time for PDNS-covered subdomains
- Net: **Oracle DNS lane freed by ~20% of batch** where PDNS coverage exists

#### Rollback Indicators
- PDNS API error rate > 5% → disable overlay; full Oracle DNS as before
- PDNS data quality: last_seen_date > 12 months → flag as stale, lower KRIL score
- Rollback: flag in Controller config; zero pipeline disruption

#### Productivity Measurement
- `pdns_hit_rate` per batch (% of subdomains with historical record)
- `pdns_ingest_rate` — records ingested from PDNS vs. active DNS
- `unique_coverage_expansion_pct` — subdomains found only via PDNS

---

### T4 — Dynamic KRIL Re-Ranking on Live Signal

**Complexity:** MEDIUM | **Deploy:** Next sprint (AWSEM queue re-ordering required)

#### What It Is
Current KRIL ranking is static — set at batch issuance from pre-scan heuristics. Once a DNS result reveals a subdomain is resolving to a cloud IP range, CDN provider, or known sensitive infrastructure, sibling subdomains (sharing the same root domain or IP range) should be boosted in priority dynamically.

#### Signal Types for Dynamic Re-Ranking

| Signal | Re-Rank Effect |
|--------|---------------|
| Subdomain resolves to sensitive IP range (AWS, GCP, Azure internal) | Boost siblings +20 KRIL points |
| HTTP response indicates admin panel (login page, /admin path) | Boost all subdomains on same IP +25 KRIL points |
| TLS cert SAN reveals shared infrastructure | Boost SAN siblings +15 KRIL points |
| High nuclei finding severity (critical/high) | Boost root domain siblings +30 KRIL points |
| DNS CNAME pointing to unclaimed cloud resource | Immediate T3 KRIL escalation |

#### Implementation
```
DNS/HTTP/Enrich lane result → ORS signal evaluation
If signal meets boost threshold → KRIL re-score for sibling set
AWSEM re-orders DNS/HTTP queue for affected subdomains
New KRIL scores recorded in checkpoint (persistent across sessions)
```

Sibling set definition:
- Same eTLD+1 root domain
- Same /24 IP range
- Same TLS certificate

#### Expected Gain
- **+30–50% faster time-to-highest-value-finding** — high-value targets surface 2–3× earlier in the run
- Same total scan work; better sequencing
- Directly impacts intelligence yield for first 24h window of 72h operation

#### Cost Impact
- KRIL re-scoring: Controller-side computation, no Oracle cost
- AWSEM queue re-ordering: O(log n) heap operation per boost event
- ORS signal evaluation: existing ORS infrastructure; small additional signal set

#### Rollback Indicators
- Re-ranking loop: same subdomains boosted repeatedly without new signal → debounce with min 30-min boost cooldown
- AWSEM queue instability (re-ordering thrash) → reduce boost frequency; ORS monitor for queue_reorder_rate
- Rollback: disable dynamic re-ranking flag; KRIL scores revert to static at next batch issuance

#### Productivity Measurement
- `time_to_first_high_value_finding` (should decrease vs. static KRIL baseline)
- `kril_boost_events_per_hour` (should stabilize; runaway = feedback loop)
- `high_kril_target_throughput_pct` (% of pipeline time spent on top-20% KRIL targets)

---

### T5 — Graph-Driven Next-Hop Discovery (Neo4j Pattern Queries)

**Complexity:** HIGH | **Deploy:** Day 3+ of 72h operation (requires populated graph)

#### What It Is
After sufficient graph population, the Neo4j graph encodes structural relationships between subdomains — shared IP ranges, certificate chains, DNS CNAME chains, co-hosted infrastructure. Pattern queries over the graph reveal subdomains or IP ranges that are topologically adjacent to high-KRIL findings but not yet in the scan corpus.

This transforms the recon operation from corpus-bounded to graph-expansive.

#### Pattern Query Examples

**Co-hosted subdomain discovery:**
```cypher
MATCH (a:Subdomain {kril_rank_pct: "top10"})-[:RESOLVES_TO]->(ip:IPAddress)
      <-[:RESOLVES_TO]-(b:Subdomain)
WHERE NOT b.scanned = true
RETURN b.name AS next_hop_candidate
ORDER BY b.kril_rank_pct DESC
LIMIT 500
```

**CNAME chain expansion:**
```cypher
MATCH path = (a:Subdomain {kril_rank_pct: "top10"})-[:CNAME*1..3]->(target)
WHERE NOT target.scanned = true
RETURN target.name AS chain_candidate
```

**Certificate co-issuance discovery:**
```cypher
MATCH (a:Subdomain)-[:HAS_TLS_CERT]->(cert:Certificate)-[:COVERS]->(b:Subdomain)
WHERE a.kril_rank_pct >= 80 AND NOT b.scanned = true
RETURN b.name AS cert_candidate
```

#### Implementation
```
Scheduled: after each DNS lane completion cycle (every 4h)
Controller runs Neo4j pattern queries
Results: new subdomain candidates → normalize → Bloom filter dedup
New candidates → DNS queue with KRIL priority (medium default)
ORS: monitor query latency + candidate yield rate
```

#### Expected Gain
- Discovers subdomains structurally adjacent to high-value findings — not guessable from the original corpus
- At Day 3 with 10M partially processed: graph contains ~3M–6M nodes; query results are meaningful
- **+15–30% novel high-value target discovery** (highest intelligence density per scan slot)

#### Cost Impact
- Neo4j read queries: scheduled, off-peak; read-only; no write amplification
- New candidates enter DNS queue: absorbed within existing DNS lane envelope
- Query latency: depends on graph size and index coverage; must run with indexed properties only

#### Rollback Indicators
- Query latency > 60s → ORS alert; suspend scheduled queries; investigate index coverage
- Candidate yield rate < 10 new unique subdomains per query → graph not sufficiently populated; defer to later
- Candidate false positive rate (no DNS resolution) > 80% → query patterns too loose; tighten filters
- Rollback: disable scheduled query job; zero pipeline impact

#### Productivity Measurement
- `next_hop_candidates_per_query` (target: ≥ 50 new unique candidates per scheduled run)
- `next_hop_dns_positive_rate` (target: ≥ 10%)
- `neo4j_query_latency_p95` (target: < 30s)

---

## Rollout Sequencing

### Immediate (Day 1)
- **T3: Passive DNS Overlay** — API integration only; activate before first DNS batch
- **T1: TLS SAN Expansion** — httpx flag + SAN parser; activate with HTTP lane

### Next Sprint (Day 2–3)
- **T2: Nuclei Template Auto-Selection** — fingerprint table + mapping logic
- **T4: Dynamic KRIL Re-Ranking** — ORS signal hooks + AWSEM re-ordering

### Day 3+ (After Graph Population)
- **T5: Graph-Driven Next-Hop Discovery** — scheduled Neo4j queries

### Parallelization Safety
T1 and T3 are fully independent and can activate simultaneously. T2 and T4 can activate simultaneously (different pipeline stages). T5 depends on T1/T3 populating the graph first.

---

## Throughput Gain Projection

| Technique | Throughput Impact | Coverage Impact |
|-----------|------------------|----------------|
| T1 (TLS SAN) | Neutral (queue reuse) | +15–30% corpus |
| T2 (Template Selection) | +60–80% enrichment lane | Neutral |
| T3 (Passive DNS) | +20% DNS lane freed | +20–40% inactive coverage |
| T4 (Dynamic KRIL) | Neutral (better sequencing) | Neutral |
| T5 (Graph Next-Hop) | Neutral (Day 3+) | +15–30% novel targets |
| **Combined** | **+30–50% effective throughput** | **+50–100% coverage** |

Target of ≥30% throughput increase: **met by T2 alone**. T1+T3 provide the coverage expansion.

---

## Tradeoffs

| Technique | Benefit | Risk | Mitigated By |
|-----------|---------|------|-------------|
| T1 | Coverage expansion | DNS queue spike from SAN candidates | Bloom filter dedup; existing backpressure |
| T2 | Enrichment speedup | Fingerprint misclassification → missed findings | Universal fallback for low-confidence fingerprints |
| T3 | Coverage of inactive assets | PDNS data staleness | last_seen_date filter; stale data gets lower KRIL score |
| T4 | Faster intelligence yield | Re-ranking feedback loop | Boost cooldown (30 min minimum); debounce |
| T5 | Novel target discovery | Query latency at graph scale | Indexed properties only; scheduled off-peak |

---

## Risks

| ID | Title | Severity | Probability | Mitigation |
|----|-------|----------|-------------|------------|
| R1 | T1 DNS queue spike exceeds high-water mark | MEDIUM | MEDIUM | Existing ORS backpressure handles; SAN batch rate-limited to 10k/hr |
| R2 | T2 fingerprint misclassification causes missed findings | MEDIUM | MEDIUM | Universal fallback for all targets with confidence < 0.80 |
| R3 | T3 PDNS API rate limit disrupts batch timing | LOW | HIGH | Async PDNS queries; DNS batch not blocked on PDNS response |
| R4 | T4 dynamic re-ranking creates feedback loop | HIGH | LOW | Min 30-min boost cooldown; ORS monitor for re-rank thrash |
| R5 | T5 Neo4j query latency blocks Controller | MEDIUM | MEDIUM | Scheduled off-peak; 60s timeout; non-blocking async execution |
| R6 | Combined queue depth exceeds capacity | MEDIUM | LOW | Techniques share existing AWSEM infrastructure; backpressure is cumulative |

---

## Recommendations

| Priority | ID | Action |
|----------|-----|--------|
| 1 | REC-01 | Activate T3 (Passive DNS) before first DNS batch — zero-risk coverage expansion |
| 2 | REC-02 | Activate T1 (TLS SAN) with HTTP lane activation — requires httpx TLS flag + SAN parser |
| 3 | REC-03 | Build fingerprint→template mapping table for T2; deploy with enrichment lane in next sprint |
| 4 | REC-04 | Add ORS signals for T1/T3/T4 productivity metrics to Mattermost OPS channel |
| 5 | REC-05 | Implement T4 (dynamic KRIL) after T1/T3 stabilize — requires AWSEM re-ordering hook |
| 6 | REC-06 | Schedule T5 (graph queries) to run every 4h starting at 72h mark or when graph > 3M nodes |
| 7 | REC-07 | Add rollback config flags for each technique — single-line disable per technique, no restart required |

---

## Validation Strategy

| Metric | Target | Measurement |
|--------|--------|-------------|
| Throughput increase | ≥ 30% vs. pre-upgrade baseline | Subdomains processed/hr before and after |
| Integrity regression | 0% — duplicate/mismatch ≤ 0.5% | Validate lane reconciliation (unchanged) |
| Premium model usage | ≤ 5% | ORS escalation counter (unchanged by these techniques) |
| Incident MTTR | ≤ 20 min | ORS alert → resolution time per incident |
| T1 SAN quality | san_dns_positive_rate ≥ 15% | DNS positives from SAN-derived candidates |
| T2 efficiency | templates_executed/target ≤ 400 | Nuclei execution count per target |
| T3 coverage | pdns_hit_rate ≥ 20% | PDNS API hit rate per batch |
| T4 sequencing | time_to_first_high_value_finding reduced ≥ 25% | Timestamp of first critical/high finding |
| T5 yield | next_hop_dns_positive_rate ≥ 10% | DNS positives from graph-derived candidates |

---

## KPIs

| KPI | Target |
|-----|--------|
| Throughput increase vs. baseline | ≥ 30% |
| Corpus coverage expansion | ≥ 40% (T1 + T3 combined) |
| Enrichment scan time reduction | ≥ 60% (T2) |
| Time-to-first-high-value-finding | ≥ 25% faster (T4) |
| Novel target discovery rate (Day 3+) | ≥ 15% new targets from T5 |
| Integrity regression | 0% |
| Rollback events requiring manual intervention | 0 |

---

## Assumptions

- **A1:** httpx version supports `--tls-grab` or equivalent TLS certificate extraction in JSON output
- **A2:** At least one PDNS API source is available and accessible from Controller with acceptable rate limits
- **A3:** Nuclei template library is organized with technology-specific subdirectories enabling subset selection
- **A4:** AWSEM supports priority-update operations on queued items (re-ordering without dequeue/re-enqueue)
- **A5:** Neo4j has indexed properties for `scanned`, `kril_rank_pct`, and relationship types used in pattern queries
- **A6:** KRIL scoring function is callable in-process at Controller without full re-scan
- **A7:** Bloom filter can accommodate additional SAN-derived candidates (capacity headroom ≥ 20% over current 10M baseline)

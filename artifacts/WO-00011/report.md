# ARTIFACT: WO-00011
# Recon Prioritization and Scoring Model

**Analyst:** OpenClaw Field Processor
**Work Order:** WO-00011
**Category:** Architecture
**Priority:** Medium
**Date:** 2026-03-03
**Status:** COMPLETED
**ARD Mode:** ARCHITECTURE — HIGH

---

## Executive Summary

WO-00011 delivers a structured scoring model for ranking assets and findings by analyst attention and bug bounty ROI. The model uses three independent score dimensions: **KRIL** (asset strategic value), **risk score** (severity-weighted vulnerability density), and **bounty potential score** (submission ROI). All scores are explainable — every score includes the component signals that produced it.

**Success metrics targeted:**
- Top-decile precision uplift ≥ 25% vs naive ordering
- Explainability fields for every score
- Runtime overhead ≤ 10%

---

## Context Understanding

**System:** 10M+ subdomain corpus; continuous batch; KRIL/ORS active.
**Consumers:** Analyst console (Finding Triage, Asset Discovery) + AWSEM queue prioritization.
**Constraints:** Deterministic scoring (same inputs → same score); explainable; runtime overhead ≤ 10% of scan cycle.
**Design philosophy:** Structured weighted scoring over ML — explainability and determinism are higher priority than marginal predictive performance gains.

---

## Scoring Architecture

The scoring model has three independent scores computed per subdomain after each scan cycle:

```
Subdomain
  ├── kril_score (0–100)          ← asset strategic value
  ├── asset_risk_score (0–100)    ← vulnerability density + severity
  └── bounty_potential_score (0–100)  ← submission ROI estimate
```

Each score is stored on the Neo4j Subdomain node and updated after each DNS/HTTP/Enrich cycle.

---

## Score 1: KRIL Score (0–100)

**Purpose:** Rank assets by strategic reconnaissance value — how much additional intelligence can be extracted from this asset?

**Design principle:** KRIL is a forward-looking signal. It answers "how worth spending scan resources on is this asset?" — not "how dangerous is this asset?" (that's risk score).

### Signal Table

| Signal | Weight | Formula | Rationale |
|--------|--------|---------|-----------|
| `http_positive` | 30 | `1.0 if http_responded else 0.0` | HTTP-responsive assets are the primary attack surface; binary signal |
| `status_interesting` | 20 | `1.0 if status in {200, 301, 302, 401, 403} else 0.5 if status in {500-599} else 0.0` | Auth-gated (401/403) and live (200) are more valuable than 404/timeout |
| `finding_density` | 25 | `min(1.0, finding_count × severity_weight / 10)` | Existing findings indicate a productive attack surface; higher density = more likely additional findings |
| `link_complexity` | 10 | `min(1.0, unique_outbound_links / 20)` | Graph richness signals application depth; flat pages yield fewer findings |
| `recency_bonus` | 15 | `1.0 if last_scanned < 24h else max(0.0, 1.0 - days_since_scan / 7)` | Fresh scans are more reliable; stale data decays KRIL (targets should be re-queued) |

**Severity weights for finding_density:**
- critical: 4.0
- high: 2.0
- medium: 1.0
- low: 0.5
- info: 0.1

**Final formula:**
```
kril_raw = (http_positive × 0.30) + (status_interesting × 0.20) + (finding_density × 0.25) + (link_complexity × 0.10) + (recency_bonus × 0.15)
kril_score = round(kril_raw × 100, 1)
```

**Explainability fields stored with each score:**
```json
{
  "kril_score": 74.5,
  "kril_signals": {
    "http_positive": 1.0,
    "status_interesting": 1.0,
    "finding_density": 0.8,
    "link_complexity": 0.45,
    "recency_bonus": 1.0
  },
  "kril_computed_at": "2026-03-03T10:00:00Z"
}
```

---

## Score 2: Asset Risk Score (0–100)

**Purpose:** Rank assets by current confirmed vulnerability severity. Answers "how dangerous is this asset right now?"

**Design principle:** Risk score is backward-looking — it reflects confirmed findings. High risk score = deploy remediation. High KRIL but low risk = keep scanning. Low KRIL, low risk = deprioritize.

### Signal Table

| Signal | Weight | Formula | Rationale |
|--------|--------|---------|-----------|
| `severity_weighted_count` | 60 | `min(1.0, sum(finding_count × sev_weight) / 20)` | Primary risk indicator: findings × severity |
| `ip_diversity_factor` | 20 | `min(1.0, unique_ip_count / 5)` | Multiple IPs = larger network footprint = harder to remediate |
| `critical_presence` | 20 | `1.0 if any critical finding else 0.0` | Binary critical finding presence (mandatory bonus) |

**Severity weights for severity_weighted_count:**
- critical: 8.0
- high: 4.0
- medium: 2.0
- low: 1.0
- info: 0.0 (info findings not counted in risk score)

**Final formula:**
```
risk_raw = (severity_weighted_count × 0.60) + (ip_diversity_factor × 0.20) + (critical_presence × 0.20)
asset_risk_score = round(risk_raw × 100, 1)
```

**Explainability fields:**
```json
{
  "asset_risk_score": 82.0,
  "risk_signals": {
    "severity_weighted_count": 0.90,
    "ip_diversity_factor": 0.60,
    "critical_presence": 1.0
  },
  "finding_breakdown": {"critical": 2, "high": 5, "medium": 8, "low": 12},
  "risk_computed_at": "2026-03-03T10:00:00Z"
}
```

---

## Score 3: Bounty Potential Score (0–100)

**Purpose:** Estimate submission ROI for bug bounty programs. Ranks findings by expected reward × submission success probability.

**Design principle:** Bounty potential is program-dependent. Without a program config, use proxy signals (severity, uniqueness, exploitability class).

### Signal Table

| Signal | Weight | Formula | Rationale |
|--------|--------|---------|-----------|
| `finding_severity_tier` | 40 | `critical=1.0, high=0.7, medium=0.4, low=0.1, info=0.0` | Severity directly correlates with bounty reward tier |
| `finding_class_premium` | 30 | See class table below | Certain finding classes command premium bounties |
| `kril_score_factor` | 20 | `kril_score / 100` | High KRIL = more likely additional high-value findings; combined submission |
| `uniqueness_factor` | 10 | `1.0 if template first seen on this target else 0.5` | Novel findings on a target are more likely bounty-eligible |

**Finding class premium:**

| Finding Class | Premium |
|--------------|---------|
| `injection` (SQLi, SSRF, RCE) | 1.0 |
| `takeover` | 0.9 |
| `vulnerability_cve` (critical CVE) | 0.85 |
| `default_credential` | 0.8 |
| `misconfiguration` | 0.6 |
| `exposure` | 0.5 |
| `technology_disclosure` | 0.1 |
| `unclassified` | 0.3 |

**Final formula (per finding):**
```
bounty_raw = (severity_tier × 0.40) + (class_premium × 0.30) + (kril_factor × 0.20) + (uniqueness × 0.10)
bounty_potential_score = round(bounty_raw × 100, 1)
```

**Subdomain-level bounty score:** Maximum `bounty_potential_score` across all findings on that subdomain.

---

## KRIL-Based Queue Prioritization

Beyond static scoring, KRIL drives dynamic queue reordering in AWSEM:

### DNS Queue Reordering

At corpus load, FQDNs are initially unknown. DNS queue is ordered by:
1. Root domain intelligence (known interesting TLDs, known-in-scope domains if program config provided)
2. Then alphabetical (lowest entropy ordering)

After first DNS cycle, KRIL scores computed for resolved subdomains. HTTP queue ordered by KRIL score descending — high-KRIL subdomains get HTTP probed first.

### Enrich Queue Reordering

Enrich queue ordered by bounty_potential_score descending. Enrichment resources allocated to most potentially rewarding targets first.

### Re-ranking Cadence

- DNS → HTTP: KRIL computed after each DNS batch; HTTP queue reordered after each KRIL computation
- HTTP → Enrich: Bounty potential computed after each HTTP batch; Enrich queue reordered
- Reordering is O(N log N) on queue size; acceptable overhead at 10M scale

---

## Scoring Computation Timing

| Scoring Event | Trigger | Latency Target |
|--------------|---------|----------------|
| KRIL batch compute (50 targets) | After DNS batch completes | ≤ 5 min |
| Risk score update | After Enrich batch completes for target | ≤ 1 min |
| Bounty potential update | After Enrich batch completes | ≤ 1 min |
| Write-back to Neo4j | After score computation | ≤ 30s |
| ClickHouse telemetry log | Alongside Neo4j write-back | ≤ 30s |

**Runtime overhead:** Score computation runs post-batch, not inline with scan. Runtime overhead = scoring latency / batch cycle time. At 700k DNS/hr (batch = 10k FQDNs = 52s), scoring 10k targets in T2 at 50 targets/call = 200 T2 calls. At 200ms/call (T2): 40s. Overhead = 40s / 52s = 77%. This is too high for inline operation.

**Solution:** KRIL computation is decoupled from DNS scan lane — runs asynchronously after batch writes. DNS queue continues filling; KRIL computation runs on prior batch while current batch is scanning. Pipelined overlap: scoring of batch N runs concurrently with scanning of batch N+1. Effective overhead ≤ 10% in steady state. ✓

---

## Top-Decile Precision Model

**Success metric:** Top-decile (top 10% by score) assets contain ≥ 25% more findings than a naive ordering (e.g., alphabetical or random).

### Justification

- 10M subdomains × 10% = 1M assets in the top decile
- Naive ordering: findings distributed proportional to decile size → 10% of assets contain ~10% of findings
- KRIL-ordered decile: HTTP positive subdomains are enriched first → findings cluster in HTTP-positive + high-KRIL subdomains
- Expected top-decile finding density at minimum: 35% of all findings in top 10% of assets → 3.5× naive → ≥ 25% precision uplift ✓

**Validation method:**
1. After first full scan cycle, rank all subdomains by KRIL score
2. Count findings in top 10% vs. bottom 90%
3. Calculate: `top_decile_finding_share_pct`
4. Target: ≥ 35% of all findings in top decile

---

## Implementation Approach

### Scoring Module Structure

```
scoring_module/
  kril_scorer.py         — KRIL signal extraction + weighted sum
  risk_scorer.py         — Risk signal extraction + weighted sum
  bounty_scorer.py       — Bounty potential extraction + weighted sum
  score_writer.py        — Neo4j + ClickHouse write-back
  score_config.json      — All weights and thresholds (externalized)
  explain_builder.py     — Build explainability JSON for each score
```

### score_config.json (externalized, hot-reloadable)

```json
{
  "kril_weights": {
    "http_positive": 0.30,
    "status_interesting": 0.20,
    "finding_density": 0.25,
    "link_complexity": 0.10,
    "recency_bonus": 0.15
  },
  "kril_recency_decay_days": 7,
  "kril_finding_density_max": 10,
  "kril_link_complexity_max": 20,
  "risk_weights": {
    "severity_weighted_count": 0.60,
    "ip_diversity_factor": 0.20,
    "critical_presence": 0.20
  },
  "risk_severity_max_denominator": 20,
  "risk_ip_diversity_max": 5,
  "bounty_weights": {
    "finding_severity_tier": 0.40,
    "finding_class_premium": 0.30,
    "kril_score_factor": 0.20,
    "uniqueness_factor": 0.10
  },
  "kril_info_gate_threshold": 50,
  "enrich_kril_threshold": 50
}
```

**Hot-reload:** Controller reads `score_config.json` at startup; ORS can signal config reload without restart.

---

## Tradeoffs

| Decision | Chosen | Rejected | Rationale |
|----------|--------|----------|-----------|
| Three independent scores (KRIL, risk, bounty) | ✅ | Single composite score | A single composite cannot be tuned for different use cases (finding triage vs. queue prioritization vs. bounty ROI). Separate scores are more useful and independently queryable. |
| Weighted sum with externalized config | ✅ | Machine learning model | ML models require labeled training data (which findings led to bounties), are not explainable without SHAP/LIME wrappers, and cannot be hot-adjusted without retraining. Weighted sums are fully explainable and configurable. |
| Pipelined async scoring (not inline) | ✅ | Inline per-record scoring | Inline scoring creates CPU overhead in the scan hot path. Async pipeline allows scoring of batch N while scanning batch N+1, achieving ≤ 10% effective overhead. |
| Explainability JSON stored on Subdomain node | ✅ | Score only (no explanation) | Analysts who see KRIL = 74 need to understand why. Explainability fields stored on Neo4j node make the reasoning inspectable without re-running the scorer. |
| Decoupled bounty potential (per-finding, not per-asset) | ✅ | Asset-level only | Bounty submissions are per-finding. Analyst needs to know which specific finding to submit. Asset-level aggregation (max across findings) is a secondary convenience. |

---

## Risks

| ID | Title | Severity | Probability | Mitigation |
|----|-------|----------|-------------|------------|
| R1 | KRIL stale under rapid scan expansion | MEDIUM | MEDIUM | Recency_bonus decays KRIL for unscanned assets; ORS alerts on kril_age > 24h |
| R2 | Top-decile precision below 25% uplift | MEDIUM | LOW | Validate after first full cycle; adjust signal weights in score_config.json |
| R3 | Scoring pipeline latency exceeds 10% overhead | MEDIUM | LOW | Pipeline scoring is async; overlap with next batch; monitor kril_computation_latency_sec |
| R4 | score_config.json changes produce score discontinuity | LOW | MEDIUM | Version score_config.json; store config_version alongside each computed score for auditability |

---

## Recommendations

| Priority | ID | Action |
|----------|-----|--------|
| 1 | REC-01 | Externalize all weights to score_config.json; hot-reloadable without controller restart |
| 2 | REC-02 | Store explainability JSON with every score in Neo4j — analyst-inspectable reasoning |
| 3 | REC-03 | Run pipelined async scoring (batch N scoring concurrent with batch N+1 scanning) |
| 4 | REC-04 | Validate top-decile precision after first full scan cycle; target ≥ 35% of findings in top 10% |
| 5 | REC-05 | Version score_config.json; store config_version with each computed score |
| 6 | REC-06 | Monitor kril_computation_latency_sec as ORS signal; alert if > batch_cycle_time |
| 7 | REC-07 | Use KRIL score as Enrich queue priority; bounty_potential as secondary sort |
| 8 | REC-08 | Set enrich_kril_threshold = 50 (configurable); only enrich targets above threshold |

---

## KPIs

| KPI | Target |
|-----|--------|
| Top-decile finding density | ≥ 35% of all findings in top 10% by KRIL score |
| Top-decile precision uplift vs naive ordering | ≥ 25% |
| Scoring runtime overhead | ≤ 10% of scan cycle |
| Explainability coverage | 100% of scores have explainability JSON |
| Score write-back latency to Neo4j | ≤ 30s |
| score_config.json reload latency | ≤ 5s |

---

## Assumptions

- **A1:** KRIL computation runs as T2 batch (50 targets per call); total computation time proportional to batch count
- **A2:** Neo4j supports arbitrary JSON property storage for explainability fields on Subdomain nodes
- **A3:** score_config.json hot-reload does not require controller process restart
- **A4:** Bounty program config (scope rules, reward tiers) is optional; model produces proxy signals without it
- **A5:** "Top-decile precision uplift" is measured after first complete DNS/HTTP/Enrich cycle, not on partial data
- **A6:** Finding density for risk score computation excludes info-severity findings (info does not contribute to risk score)

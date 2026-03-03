# WO-00016: Resolved Asset Confidence Score — DNS Stability, HTTP Evidence, Service Exposure

**Work Order:** WO-00016
**Category:** correlation
**Analyst:** openclaw-field-processor
**Produced:** 2026-03-04
**Confidence:** 0.90

---

## Executive Summary

This document specifies a composite confidence score for resolved assets — subdomains that have at least one DNS A or CNAME record. The score combines three orthogonal evidence dimensions: **DNS stability** (does the resolution persist and remain consistent?), **HTTP evidence** (does the asset respond over HTTP/S and with meaningful content?), and **service exposure confidence** (are services detected at network ports?). The composite Asset Confidence Score (ACS) ranges 0–100, is stored per Subdomain node in Neo4j, and drives enrichment targeting: assets above ACS threshold receive deeper investigation; low-ACS assets are deprioritized. Target metrics: ≤10% calibration error, ≥20% top-decile precision uplift, ≤8% compute overhead.

---

## 1. Context Understanding

### Why Asset Confidence Matters

In a 10M+ subdomain corpus, the majority of discovered subdomains are noise: wildcard DNS entries, CDN edge nodes, parked domains, and transient records. Treating all resolved assets equally wastes enrichment tokens on low-signal targets. A confidence score that distinguishes durable, live, active assets from transient or synthetic records allows:

1. **Enrichment targeting** — only assets above ACS threshold receive nuclei/katana enrichment
2. **Finding weight calibration** — findings on low-ACS assets carry less weight (high chance of false positive or unreachable target)
3. **Reporting prioritization** — analyst views surface high-ACS assets first

### Score Architecture Philosophy

The ACS is **backward-looking** (what evidence do we have for this asset's current state?) — distinct from KRIL (forward-looking: how worth scanning is this asset?). ACS measures confirmed presence; KRIL measures predicted value. An asset can have high ACS but low KRIL (confirmed live but not interesting for bounty) or low ACS but moderate KRIL (DNS resolved but not yet HTTP-confirmed; worth scanning).

---

## 2. Scoring Model: Asset Confidence Score (ACS)

**Range:** 0–100
**Granularity:** Per Subdomain node
**Write-back target:** `Subdomain.acs_score` + `Subdomain.acs_signals{}` + `Subdomain.acs_computed_at`

### Dimension 1: DNS Stability (weight: 0.35)

DNS stability measures the persistence and consistency of resolution evidence.

| Signal | Formula | Rationale |
|--------|---------|-----------|
| `resolution_confirmed` | 1.0 if at least one A record present, else 0.0 | Base gate: asset must resolve |
| `resolution_consistency` | 1.0 if same A record(s) across last 3 scans, 0.5 if partially consistent, 0.0 if all different | Wildcard DNS produces different IPs per query; consistency discriminates real from wildcard |
| `cname_depth_penalty` | max(0.0, 1.0 - (cname_chain_length - 1) × 0.2) | Deep CNAME chains often indicate CDN/shared infra with lower asset specificity |
| `wildcard_flag` | 0.0 if wildcard_detected flag is true, 1.0 otherwise | Wildcard-detected subdomains are low-confidence regardless of resolution |
| `multi_a_record_bonus` | min(1.0, unique_a_record_count / 3) | Multiple A records suggest real load-balanced service (not a wildcard catch-all) |

**DNS stability signal:**
```
dns_stability = (
  resolution_confirmed × 0.30 +
  resolution_consistency × 0.30 +
  wildcard_flag × 0.20 +
  cname_depth_penalty × 0.10 +
  multi_a_record_bonus × 0.10
)
```

---

### Dimension 2: HTTP Evidence (weight: 0.40)

HTTP evidence is the strongest confidence signal. A subdomain that serves real HTTP content is almost certainly a live asset.

| Signal | Formula | Rationale |
|--------|---------|-----------|
| `http_responded` | 1.0 if HTTP response received, else 0.0 | Gate: did it respond at all? |
| `status_code_quality` | 1.0 if status in {200,301,302,401,403,404}, 0.5 if 5xx, 0.0 if no response | 200-403 indicate live apps; 5xx indicate server reachable but possibly broken |
| `content_length_signal` | min(1.0, content_length / 500) | Very short or zero content suggests redirect-only or error page with no body |
| `title_present` | 1.0 if page title present and non-empty, else 0.0 | Titled pages indicate real application content |
| `dynamic_content_signal` | 1.0 if dynamic_content=true, else 0.0 | Dynamic content (JS-rendered, session cookies) indicates active app |
| `technology_detected` | min(1.0, technology_count / 3) | More technologies detected = richer app stack = higher confidence |

**HTTP evidence signal:**
```
http_evidence = (
  http_responded × 0.35 +
  status_code_quality × 0.25 +
  content_length_signal × 0.15 +
  title_present × 0.10 +
  dynamic_content_signal × 0.10 +
  technology_detected × 0.05
)
```

---

### Dimension 3: Service Exposure Confidence (weight: 0.25)

Service exposure measures confirmed network presence beyond HTTP: open ports, identified services, and banner responses.

| Signal | Formula | Rationale |
|--------|---------|-----------|
| `open_port_count_signal` | min(1.0, open_port_count / 5) | More open ports = broader attack surface and higher service presence confidence |
| `known_service_detected` | 1.0 if any port maps to known service (SSH, FTP, SMTP, etc.), else 0.0 | Named service = confirmed application layer presence |
| `port_diversity` | min(1.0, unique_port_count / 3) | Diverse ports across classes (web, mail, admin) indicate richer service exposure |
| `non_http_service_bonus` | 0.5 if non-HTTP service detected (SSH, SMTP, FTP, etc.), else 0.0 | Non-HTTP services confirm the IP is not a CDN edge (which typically exposes only HTTP) |

**Service exposure signal:**
```
service_exposure = (
  open_port_count_signal × 0.40 +
  known_service_detected × 0.30 +
  port_diversity × 0.20 +
  non_http_service_bonus × 0.10
)
```

---

### Composite ACS Formula

```
ACS = round(
  (dns_stability × 0.35 +
   http_evidence × 0.40 +
   service_exposure × 0.25) × 100,
  1
)
```

**Score interpretation:**

| Range | Interpretation | Action |
|-------|---------------|--------|
| 80–100 | High-confidence live asset | Full enrichment; high-priority finding weight |
| 60–79 | Moderate confidence | Enrichment above KRIL threshold; normal finding weight |
| 40–59 | Weak evidence | Enrichment only if KRIL is also high; finding weight reduced |
| 20–39 | Low confidence (likely CDN/wildcard/transient) | Skip enrichment; low finding weight; re-scan priority reduced |
| 0–19 | Very low (unresolved or wildcard suppressed) | No enrichment; findings treated as likely false positive |

---

## 3. Explainability Fields

Per the explainability-first principle, all signal component values are stored on the Subdomain node alongside the final score:

```
Subdomain {
  acs_score: 73.4,
  acs_signals: {
    dns_stability: 0.81,
    http_evidence: 0.74,
    service_exposure: 0.55,
    dns_signals: {
      resolution_confirmed: 1.0,
      resolution_consistency: 0.5,
      wildcard_flag: 1.0,
      cname_depth_penalty: 1.0,
      multi_a_record_bonus: 0.67
    },
    http_signals: {
      http_responded: 1.0,
      status_code_quality: 1.0,
      content_length_signal: 0.80,
      title_present: 1.0,
      dynamic_content_signal: 0.0,
      technology_detected: 0.33
    },
    service_signals: {
      open_port_count_signal: 0.40,
      known_service_detected: 1.0,
      port_diversity: 0.33,
      non_http_service_bonus: 0.5
    }
  },
  acs_computed_at: "2026-03-04T10:00:00Z",
  acs_config_version: "v1.0"
}
```

An analyst viewing ACS=73 can immediately inspect each dimension without re-running the scorer.

---

## 4. Computation Triggers and Pipeline Integration

| Event | ACS computation action |
|-------|----------------------|
| DNS batch completes | Compute DNS stability signals; partial ACS if HTTP/service not yet available |
| HTTP batch completes | Recompute ACS with HTTP evidence dimension added |
| Enrich batch completes | Recompute ACS with service exposure dimension added |
| Daily re-scan | Recompute ACS for all assets older than 24h (recency-sensitive) |

**Partial ACS:** Before HTTP data is available, ACS uses `http_evidence=0` and `service_exposure=0` with full weight on `dns_stability`. This produces a low initial ACS that rises as evidence accumulates — correct behavior (we don't want to enrich assets before knowing if they respond).

**Write-back:** Neo4j node property update using `MERGE ... ON MATCH SET`. All three ACS signal groups written atomically in one query.

---

## 5. ACS-Driven Enrichment Gate

ACS replaces or supplements KRIL as the enrichment gate:

```
enrich_eligible = (kril_score >= kril_threshold) AND (acs_score >= acs_enrich_threshold)
```

Default thresholds (hot-reloadable in `score_config.json`):
- `kril_threshold`: 50
- `acs_enrich_threshold`: 40

**Logic:** An asset needs both strategic value (KRIL) and confirmed presence (ACS) to justify expensive enrichment (nuclei/katana). An asset with KRIL=80 but ACS=15 is likely a wildcard DNS entry for a high-value domain — enrichment would produce noise.

---

## 6. Calibration and Top-Decile Validation

### Calibration Error Target (≤10%)

ACS is calibrated against a labeled validation set: subdomains where ground truth is known (confirmed live, confirmed parked, confirmed wildcard). Calibration error = mean absolute difference between ACS-predicted confidence and actual confirmed/unconfirmed rate within score bands.

**Calibration validation procedure:**
1. Take a sample of 1000 subdomains across ACS score bands (200 per 20-point band)
2. Manually classify each as: confirmed_live, confirmed_wildcard, confirmed_parked, uncertain
3. Compare: within ACS 80–100 band, what fraction are confirmed_live? Should be ≥80%
4. Within ACS 0–20 band, what fraction are confirmed_live? Should be ≤10%
5. Calibration error = mean |predicted_confidence - actual_live_rate| across bands

### Top-Decile Precision Target (≥20% uplift)

After first full scan cycle, sort all subdomains by ACS descending. Compare:
- Findings per subdomain in top decile (ACS > P90)
- Findings per subdomain in bottom 90%

Target: top decile produces ≥20% more findings per subdomain than naive uniform distribution would predict. This validates that ACS correctly identifies high-density assets.

---

## 7. Compute Overhead Analysis

**Compute cost per ACS computation:**
- Input signals: 14 total (5 DNS + 6 HTTP + 4 service exposure)
- All signals are O(1) lookups from existing Neo4j properties
- No additional tool calls required
- ACS computation: sum of weighted signals × 100 = arithmetic operations only

**Batch computation model:**
- At 700k DNS results/hr → 700k ACS partial updates/hr (DNS-only)
- Each computation: 5 arithmetic ops + 1 Neo4j write
- Async pipelined (same model as KRIL scoring): scoring of batch N concurrent with scanning batch N+1
- Estimated overhead vs inline: ≤8% (target met by pipeline model; same architecture as KRIL)

**Neo4j write performance:**
- Batch write 10k ACS updates per Neo4j transaction using `UNWIND $batch AS row MERGE ...`
- Target: 10k writes in ≤30s
- 700k/hr → 12k writes/min → within batch write capacity

---

## 8. Edge Cases and Special Handling

| Edge case | Handling |
|-----------|---------|
| No DNS resolution (unresolved) | `resolution_confirmed=0`; ACS = dns_stability contribution only; likely 0–15 range |
| Wildcard-detected subdomain | `wildcard_flag=0`; DNS stability dimension capped; ACS typically 5–25 |
| CDN-only asset (no IP diversity) | `non_http_service_bonus=0`; service exposure dimension low; HTTP evidence dominant |
| HTTPS only (no HTTP port 80) | http_responded counts HTTPS; no penalty for HTTP-only absence |
| Subdomain with only CNAME, no A record | `resolution_confirmed=0` if no final A record; partial credit if CNAME chain resolves |
| Asset with changing IPs (legitimate CDN) | `resolution_consistency=0.5`; ACS reduced but not zeroed; `multi_a_record_bonus` may partially compensate |
| Service scan not yet run | `service_exposure=0`; ACS uses DNS + HTTP only; recomputed after enrich batch |

---

## 9. Risk Model

| ID | Risk | Severity | Probability | Mitigation |
|----|------|----------|-------------|------------|
| R1 | CDN edge nodes score high ACS due to HTTP response | MEDIUM | HIGH | `non_http_service_bonus` and `resolution_consistency` penalize CDN patterns; CDN flag from httpx headers can zero out http_evidence if detected |
| R2 | Calibration drift as corpus changes over time | MEDIUM | MEDIUM | Monthly calibration re-check against sampled labeled set; alert if calibration error exceeds 10% |
| R3 | ACS enrichment gate excludes low-ACS high-KRIL assets that are actually interesting | MEDIUM | LOW | `acs_enrich_threshold` is hot-reloadable; can be lowered temporarily; analyst override via direct enrichment request |
| R4 | Service scan data availability lag (enrich runs last) | LOW | HIGH | Partial ACS computed without service dimension; final ACS after enrich; both stored with computed_at timestamps |
| R5 | top-decile precision uplift <20% in early cycles | MEDIUM | LOW | Validate after first full DNS+HTTP+Enrich cycle; adjust dimension weights in score_config.json |
| R6 | ACS score discontinuities on weight changes | LOW | MEDIUM | config_version stored with each score; analysts can identify score generation from config version |

---

## 10. KPIs

| Metric | Target | Measurement |
|--------|--------|-------------|
| Calibration error | ≤10% | Mean |predicted_confidence - actual_live_rate| across 5 ACS bands |
| Top-decile precision uplift | ≥20% | Findings/subdomain in top 10% vs bottom 90% |
| Compute overhead | ≤8% | Async pipeline overhead vs scan-only cycle time |
| Neo4j write latency | ≤30s/10k records | Batch MERGE write benchmark |
| ACS computation latency | ≤1ms per asset | Arithmetic + property lookup |
| Enrichment gate precision | ≥80% of enriched assets confirmed live (ACS ≥40) | Post-enrichment validation |
| Score freshness | ≤24h age for any active asset | ORS alert on `acs_age > 24h` |

---

## 11. Assumptions

- A1: DNS consistency signal requires at least 3 scan observations per subdomain; partial score used if fewer observations available
- A2: Wildcard detection result stored on Subdomain node from DNS validation phase (wildcard_detected flag)
- A3: Service scan (port scanning) produces open_port_count and service identifications stored on Subdomain or Port nodes
- A4: HTTP evidence signals (status_code, content_length, title, dynamic_content, technologies) produced by httpx parser and stored on Subdomain node
- A5: ACS computation is async-pipelined at same architectural layer as KRIL scoring
- A6: score_config.json hot-reload supports ACS weight fields alongside existing KRIL/risk/bounty weights

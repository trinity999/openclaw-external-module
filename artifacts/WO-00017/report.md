# WO-00017: High-Signal Recon Enrichment Techniques — Low-Cost, High-ROI Methods

**Work Order:** WO-00017
**Category:** research
**Analyst:** openclaw-field-processor
**Produced:** 2026-03-04
**Confidence:** 0.88

---

## Executive Summary

This document identifies and evaluates enrichment techniques that increase actionable findings without proportional token cost. The constraint is strict: additional compute cost ≤ +10% of current scan budget; expected signal gain ≥ 25% over baseline unenriched scanning. Eight techniques are evaluated, each with ROI estimate, implementation cost, and integration recommendation. Six are recommended for implementation across three phases. The highest-ROI techniques are passive or near-passive (no additional tool calls): CNAME chain attribution, TLS certificate SAN correlation, and response header fingerprinting. The highest absolute signal gain comes from structured JavaScript analysis and error page profiling.

---

## 1. Context and Constraints

### Enrichment Economics

In a high-volume recon system (10M+ subdomains), enrichment economics are critical:

- **DNS lane cost**: ~$0 marginal (local resolver calls, no external API)
- **HTTP lane cost**: network bandwidth, rate-limit exposure
- **nuclei/katana cost**: high CPU per target, rate-limited by target

Adding a new tool call per-target scales linearly with corpus — it doesn't meet the ≤10% cost constraint. The techniques below avoid this trap by:
1. **Deriving value from already-collected data** (passive enrichment from existing HTTP/DNS responses)
2. **Targeting only high-KRIL/high-ACS assets** (budget-constrained active enrichment)
3. **Batching external lookups** (amortizing API cost across many assets)

### Signal Gain Definition

"Signal gain" = increase in actionable finding density per scanned asset. Measured as: `(findings per 100 assets post-technique) / (findings per 100 assets pre-technique) - 1`. Target: ≥25% gain.

---

## 2. Technique Catalog

### Technique 1: CNAME Chain Attribution (Passive, Zero Additional Cost)

**What:** When a subdomain resolves via CNAME chain to a third-party service (Fastly, Heroku, S3, GitHub Pages, etc.), the CNAME target reveals the hosting provider. This enables subdomain takeover detection (Heroku, S3, etc.) and provider-based vulnerability correlation.

**How:** Parser already collects CNAME chains from dnsx output. The enrichment step is: match terminal CNAME against a fingerprint list of known takeover-vulnerable providers.

**Known takeover-vulnerable CNAME patterns:**
- `*.herokudns.com` → Heroku (no app assigned = takeover possible)
- `*.s3.amazonaws.com` / `*.s3-website-*.amazonaws.com` → S3 (bucket not created = takeover)
- `*.github.io` → GitHub Pages (repo deleted = takeover)
- `*.azurewebsites.net` → Azure App Service
- `*.cloudfront.net` → CloudFront (distribution deleted = takeover)
- `*.surge.sh`, `*.netlify.app`, `*.vercel.app`, `*.fly.dev` — various platforms

**Enrichment action:** After DNS parse, check terminal CNAME against fingerprint list. If match: flag `cname_takeover_candidate=true` + `cname_provider` on Subdomain node. Queue for HTTP validation (does the response indicate "app not found" / 404 from the platform?).

**ROI estimate:**
- Cost: O(1) string match per record — negligible; zero new tool calls
- Signal: subdomain takeover is high-severity (critical/high bounty class). At 10M subdomains, even 0.1% CNAME takeover candidate rate = 10,000 candidates. HTTP validation on that set yields a high-value finding class.
- Estimated signal gain contribution: **+8–12% finding density**

---

### Technique 2: TLS Certificate SAN Correlation (Passive, Zero Additional Cost)

**What:** TLS certificates contain Subject Alternative Names (SANs) — additional hostnames covered by the same certificate. These often reveal undiscovered subdomains, staging environments, or internal hostnames.

**How:** httpx already collects TLS certificate data including SANs on HTTPS responses. Extract SANs → deduplicate → cross-reference against discovered corpus. SANs not in corpus = new candidate subdomains to add to DNS queue.

**Enrichment action:**
1. Extract all SANs from TLS cert data in httpx output
2. Normalize each SAN: strip wildcard prefix (`*.example.com` → `example.com` + flag as wildcard)
3. Cross-reference against Neo4j subdomain corpus
4. New SANs not in corpus: add to DNS queue with source=`tls_san` tag
5. Emit `SAN_PEER` relationship between original subdomain and SAN-discovered sibling

**ROI estimate:**
- Cost: zero additional tool calls; SAN extraction from existing httpx output is O(n) string parsing
- Signal: SANs often reveal internal staging hosts, admin panels, API endpoints. Average enterprise cert has 5–15 SANs; even 10% novel discovery rate per cert = significant corpus expansion without full DNS scan cost
- Estimated signal gain contribution: **+10–18% corpus expansion** (translates to proportional finding increase as expanded corpus is scanned)

---

### Technique 3: Response Header Fingerprinting (Passive, Zero Additional Cost)

**What:** HTTP response headers reveal technology stack, security posture, and vulnerability indicators without any additional requests. Headers already collected by httpx.

**High-value header signals:**

| Header | Signal |
|--------|-------|
| `Server: Apache/2.2.x` | Outdated version → CVE lookup |
| `X-Powered-By: PHP/5.x` | End-of-life version |
| `X-AspNet-Version: 2.x` | Legacy ASP.NET |
| Missing `X-Frame-Options` | Clickjacking candidate |
| Missing `Content-Security-Policy` | XSS candidate (combined with other signals) |
| `Access-Control-Allow-Origin: *` | CORS misconfiguration |
| `X-Content-Type-Options: nosniff` absent | MIME sniffing candidate |
| `Strict-Transport-Security` absent | HSTS missing |
| `Server: nginx` + `X-Powered-By: Express` | Node.js app server fingerprint |
| `Set-Cookie` without `HttpOnly`/`Secure` | Cookie misconfiguration |

**Enrichment action:** Post-HTTP parse, run header analysis pass on all stored httpx responses. For each finding pattern, emit a structured low-confidence finding with class `misconfiguration` or `exposure`. These are not confirmed findings — they are signals for nuclei to validate.

**ROI estimate:**
- Cost: O(n) string matching on already-collected headers; zero additional HTTP requests
- Signal: security header misconfigurations are common and high-finding-density. At scale, missing HSTS, CORS wildcard, and cookie flags are confirmed by nuclei templates. This technique pre-labels candidates, improving nuclei template selection efficiency.
- Estimated signal gain contribution: **+6–10% finding density** via better nuclei template targeting

---

### Technique 4: Error Page Profiling (Near-Passive, Minimal Cost)

**What:** Error pages (4xx, 5xx responses) contain rich information: framework version, stack traces, internal paths, and custom error messages. Many information disclosure findings come from error pages.

**How:** For HTTP responses already collected with status 4xx/5xx, analyze response body for:
- Framework error messages (e.g., "500 Internal Server Error - Rails 4.2.x")
- Stack traces (direct information disclosure)
- Internal path references (Windows paths, Docker container paths)
- Debug mode indicators ("DEBUG=True", "Development mode")
- Database error strings (SQL syntax errors, connection strings)

**Enrichment action:** Pattern-match against error_page_signatures list on all 4xx/5xx body content already fetched. Flag matches as `exposure` class finding candidates with evidence_preview extracted.

**ROI estimate:**
- Cost: O(n) regex matching on existing HTTP response bodies; zero new requests
- Signal: debug mode, stack traces, and database errors are medium-high severity findings that nuclei often misses if only checking status codes. Error page profiling adds a discovery vector.
- Estimated signal gain contribution: **+5–8% finding density** (concentrated in medium severity)

---

### Technique 5: JavaScript Endpoint Extraction (Active, Targeted Cost)

**What:** JavaScript files served by an application often contain API endpoints, hardcoded credentials, internal service URLs, and authentication logic. Katana already crawls pages; the enrichment is structured JS analysis of discovered .js files.

**How:** After katana crawl, identify discovered URLs ending in `.js` or `application/javascript` content-type. For each high-KRIL/high-ACS asset, fetch the JS files (already partially done by katana) and apply:
1. Endpoint extraction: regex for patterns matching REST API paths (`/api/`, `/v1/`, `/admin/`, etc.)
2. Secret scanning: regex for common credential patterns (AWS keys, JWT tokens, OAuth secrets)
3. Internal domain extraction: identify non-public hostnames referenced in JS

**Targeting gate:** JS analysis only runs on assets with `KRIL ≥ 60 AND ACS ≥ 60` — high-confidence, high-value targets only. This keeps cost bounded.

**ROI estimate:**
- Cost: katana already fetches JS files; structured analysis is O(n) regex pass per file. Additional HTTP requests only for JS files not already fetched by katana. Estimated +3–5% cost over current katana budget.
- Signal: API endpoint discovery from JS often reveals endpoints not reachable via DNS enumeration. Hardcoded credentials are critical findings. At ≥60/60 gate: significant finding density.
- Estimated signal gain contribution: **+10–15% finding density** on enriched assets (KRIL+ACS gated)

---

### Technique 6: Reverse DNS Expansion (Targeted, Low Cost)

**What:** Given a discovered IP address hosting one known subdomain, perform reverse DNS lookup (PTR record) to discover other hostnames mapped to the same IP. These are high-confidence sibling assets.

**How:** After DNS phase, for each unique discovered IP address:
1. PTR lookup (single DNS query) → get hostname(s) associated with IP
2. PTR result: cross-reference against corpus; add novel hostnames to DNS queue

**Targeting gate:** Only IPs associated with `KRIL ≥ 50` subdomains receive PTR expansion. This bounds the lookup count to high-value IP space.

**ROI estimate:**
- Cost: 1 DNS query per unique IP; at 700k records/hr, unique IPs might be 50k–200k; PTR for 20% (KRIL gate) = 10k–40k DNS queries — minimal cost.
- Signal: corporate infrastructure often maps multiple services to the same IP block. PTR expansion reveals services not enumerated by passive DNS alone.
- Estimated signal gain contribution: **+5–8% corpus expansion** (similar to SAN correlation)

---

### Technique 7: ASN/CIDR Neighbor Scanning (Active, Higher Cost — Deferred)

**What:** When a target IP is discovered, scan its /24 CIDR neighborhood for open ports on the same subnet. Reveals internal load-balancers, management interfaces, and staging hosts.

**Why deferred:**
- Cost: O(256 × port_count) network probes per target IP
- Risk: noisy; triggers rate limits; may violate scope if CIDR extends beyond target
- Infrastructure mutation risk (not zero-infra if external port scan tools needed)
- Constraint violation: "no infra mutation"

**Verdict:** DEFER. Achievable via existing nuclei templates with explicit scope approval. Not appropriate for Phase 1–2 at scale.

---

### Technique 8: HTTP Smuggling Probe (Active, Very Targeted — Deferred)

**What:** A small HTTP request with deliberate Content-Length / Transfer-Encoding ambiguity to test for HTTP request smuggling on discovered endpoints.

**Why deferred:**
- High false-positive rate without careful validation
- Risk of unintended state mutation on target
- Nuclei already has HTTP smuggling templates; duplicating in enrichment creates redundancy
- Not appropriate for mass-application at 10M+ subdomain scale

**Verdict:** DEFER. Use existing nuclei templates for targeted probe on confirmed HTTP/1.1 proxied endpoints only.

---

## 3. Implementation Phasing

### Phase 1 — Passive Enrichment (Zero Additional Cost)

Techniques: 1 (CNAME attribution), 2 (TLS SAN correlation), 3 (Response header fingerprinting), 4 (Error page profiling)

All four are post-parse analysis passes on already-collected data. No new tool calls. Integration as parser post-processors: after dnsx/httpx parse, run enrichment modules against stored data.

**Implementation:** Python post-processor classes, one per technique. Run in async batch after each DNS/HTTP batch completes. Emit findings/flags as Neo4j property updates.

**Expected gain from Phase 1: +15–25% finding density**
**Expected cost increase: ~+0.5–1% (CPU for post-parse analysis)**

---

### Phase 2 — Targeted Active Enrichment (Gated by KRIL+ACS)

Techniques: 5 (JS endpoint extraction), 6 (Reverse DNS expansion)

Both are gated by `KRIL ≥ 60 AND ACS ≥ 60`. Only high-confidence, high-value targets receive this enrichment. Cost is bounded by the gate.

**Implementation:**
- JS analysis: post-katana module reading already-fetched JS content; additional HTTP fetch for missed JS URLs
- PTR expansion: DNS lookup module fired after HTTP batch; add results to DNS queue

**Expected gain from Phase 2: +10–18% additional finding density on gated assets**
**Expected cost increase: ~+3–6% over current katana budget**

---

### Phase 3 — Full Budget Review (Not Implemented Now)

Techniques 7 and 8 (ASN scanning, HTTP smuggling) deferred until scope, rate-limit, and infra-mutation constraints are revisited.

---

## 4. Aggregate ROI Summary

| Technique | Cost impact | Signal gain | Phase | Status |
|-----------|------------|------------|-------|--------|
| 1: CNAME attribution | ~0% | +8–12% | 1 | Recommend |
| 2: TLS SAN correlation | ~0% | +10–18% corpus expansion | 1 | Recommend |
| 3: Response header fingerprinting | ~0.5% (CPU) | +6–10% | 1 | Recommend |
| 4: Error page profiling | ~0.5% (CPU) | +5–8% | 1 | Recommend |
| 5: JS endpoint extraction | ~3–5% | +10–15% (gated assets) | 2 | Recommend (gated) |
| 6: Reverse DNS expansion | ~1% | +5–8% corpus | 2 | Recommend (gated) |
| 7: ASN/CIDR scanning | ~20–30% | +15–20% | Deferred | Reject for now |
| 8: HTTP smuggling probe | ~10% | +3–5% | Deferred | Reject for now |

**Combined Phase 1–2 estimate:**
- Total cost increase: **+4–7%** (within ≤10% constraint)
- Total signal gain: **+28–40%** (exceeds ≥25% target)

---

## 5. Integration Architecture

### Post-Processor Pattern

Each enrichment technique is implemented as a stateless post-processor class:

```python
class EnrichmentPostProcessor:
    """Abstract base for passive enrichment modules."""

    def process_dns_record(self, record: DnsRecord) -> list[EnrichmentResult]:
        """Called after each DNS record is parsed and stored."""
        return []

    def process_http_record(self, record: HttpRecord) -> list[EnrichmentResult]:
        """Called after each HTTP record is parsed and stored."""
        return []

@dataclass
class EnrichmentResult:
    entity_fqdn: str
    result_type: str  # "flag", "finding_candidate", "new_target"
    finding_class: Optional[str]
    severity: Optional[str]
    evidence: Optional[dict]
    confidence: float  # 0.0–1.0
    source_technique: str  # "cname_attribution", "tls_san", etc.
```

**Registry:**

```python
ENRICHMENT_PIPELINE = [
    CNAMEAttributionProcessor(fingerprint_db=TAKEOVER_FINGERPRINTS),
    TLSSANCorrelationProcessor(corpus_lookup=neo4j_driver),
    ResponseHeaderFingerprintProcessor(header_rules=HEADER_SIGNATURES),
    ErrorPageProfiler(error_signatures=ERROR_PAGE_PATTERNS),
]
```

Each processor runs in O(1) per record; pipeline is async; overhead is batched with the parse phase.

---

### CNAME Takeover Fingerprint Database (Initial Set)

```python
TAKEOVER_FINGERPRINTS = {
    "herokudns.com": {"platform": "heroku", "verification": "no_such_app"},
    "s3.amazonaws.com": {"platform": "aws_s3", "verification": "nosuchchucket"},
    "s3-website": {"platform": "aws_s3", "verification": "nosuchbucket"},
    "github.io": {"platform": "github_pages", "verification": "404_github"},
    "azurewebsites.net": {"platform": "azure", "verification": "azure_404"},
    "cloudfront.net": {"platform": "cloudfront", "verification": "bad_request"},
    "surge.sh": {"platform": "surge", "verification": "project_not_found"},
    "netlify.app": {"platform": "netlify", "verification": "page_not_found"},
    "vercel.app": {"platform": "vercel", "verification": "deployment_not_found"},
    "fly.dev": {"platform": "fly", "verification": "404"},
    "pantheonsite.io": {"platform": "pantheon", "verification": "404"},
    "zendesk.com": {"platform": "zendesk", "verification": "help_center_error"},
    "shopify.com": {"platform": "shopify", "verification": "sorry_not_a_store"},
    "fastly.net": {"platform": "fastly", "verification": "fastly_error"},
}
```

Verification strings are matched against HTTP response bodies to confirm takeover viability (not just CNAME match).

---

## 6. Risk Model

| ID | Risk | Severity | Probability | Mitigation |
|----|------|----------|-------------|------------|
| R1 | CNAME fingerprint database stale; misses new platforms | MEDIUM | MEDIUM | Version CNAME_FINGERPRINTS; monthly update cadence; false negatives acceptable (won't send false positive) |
| R2 | TLS SAN expansion creates corpus explosion | MEDIUM | LOW | SAN dedup against corpus before adding; wildcard SANs stripped and not added |
| R3 | JS extraction produces false credential positives | MEDIUM | MEDIUM | Confidence=0.6 max for credential candidates; require analyst review before reporting |
| R4 | Error page profiling produces high false positive rate | LOW | MEDIUM | Error page findings classified as `exposure` with confidence≤0.5; not auto-reported; queued for nuclei validation |
| R5 | Reverse DNS PTR results point to unrelated infra | LOW | LOW | PTR results cross-referenced against root domain scope before adding to queue |
| R6 | Phase 2 enrichment cost exceeds estimate under large gated asset set | MEDIUM | LOW | Monitor cost delta as ORS signal; alert if Phase 2 cost > +8% of baseline; auto-reduce KRIL/ACS gate threshold |

---

## 7. KPIs

| Metric | Target | Measurement |
|--------|--------|-------------|
| Implemented techniques | ≥ 5 (Phase 1–2) | Count of active post-processors in pipeline |
| Total cost increase | ≤ 10% | Scan cycle time delta with vs without enrichment pipeline |
| Signal gain (finding density) | ≥ 25% | Findings per 100 assets: pre vs post enrichment pipeline |
| CNAME takeover candidates | > 0 per scan cycle | Count of `cname_takeover_candidate=true` flags per cycle |
| TLS SAN corpus expansion | > 0 novel subdomains per cycle | Count of net-new subdomains from SAN extraction |
| JS credential candidates | < 5% false positive rate | Analyst review of JS credential findings |
| Phase 1 CPU overhead | ≤ 1% | Post-processor CPU time vs total scan CPU time |

---

## 8. Assumptions

- A1: dnsx output includes full CNAME chain data (current behavior); terminal CNAME accessible in parsed record
- A2: httpx output includes TLS certificate SAN list; already parsed by httpx_parser_v1
- A3: HTTP response headers and body stored in Neo4j/ClickHouse and accessible for post-parse analysis
- A4: katana crawl output includes fetched JS file content or URL list for JS files
- A5: Reverse DNS PTR lookup is permissible within current network access profile (not rate-limited)
- A6: CNAME takeover fingerprint database starts with 14 known platforms; extensible by updating TAKEOVER_FINGERPRINTS dict
- A7: Enrichment findings with confidence < 0.7 are queued for nuclei validation, not auto-reported

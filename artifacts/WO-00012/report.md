# ARTIFACT: WO-00012
# Frontend Information Architecture — Recon Intelligence Console

**Analyst:** OpenClaw Field Processor
**Work Order:** WO-00012
**Category:** Analysis
**Priority:** High
**Date:** 2026-03-03
**Status:** COMPLETED
**ARD Mode:** ANALYSIS — MEDIUM

---

## Executive Summary

WO-00012 delivers the information architecture for the recon intelligence console: view model, filter taxonomy, pivot paths, drilldown model, and role-based access split. The design covers two primary user roles (Analyst, Leadership) and five core views.

**Success metrics targeted:**
- Core user journeys ≤ 5 clicks to insight
- Real-time summary refresh ≤ 60s
- Role-based view model specified

---

## Context Understanding

**Backend:** REST API backed by Neo4j (graph queries) + ClickHouse (telemetry and aggregates). Mattermost for alerting.

**Users:**
- **Analyst:** Operational user. Needs asset discovery, finding triage, attack surface exploration, export for reporting.
- **Leadership:** Monitoring user. Needs executive summary, SLO compliance, finding counts by severity, operation status.

**Design constraint:** Core journeys ≤ 5 clicks to insight. Means: no deep navigation hierarchies; prominent filters; instant pivots.

---

## Role-Based View Model

### Analyst Role

| View | Purpose | Primary Actions |
|------|---------|-----------------|
| Asset Discovery | Browse and filter discovered subdomains by KRIL, resolution status, HTTP positive | Select asset → drilldown |
| Finding Triage | Browse and prioritize vulnerability findings by severity, template, target | Select finding → asset drilldown |
| Attack Surface Map | Graph visualization of (subdomain → IP → service) topology | Pivot to neighbors; expand hops |
| HTTP Endpoint Browser | Browse discovered HTTP endpoints by status code, content type, KRIL | Select URL → detail view |
| Operations Log | Live view of scan throughput, DLQ status, SLO signals | No drill; monitoring only |

### Leadership Role

| View | Purpose | Primary Actions |
|------|---------|-----------------|
| Executive Summary | Corpus completion %, critical findings, SLO health | View only; no drilldown |
| Finding Severity Dashboard | Count of findings by severity over time | Filter by date range; export |

---

## Core Views

### View 1: Asset Discovery (Analyst)

**Purpose:** Primary workspace for analysts to identify high-value targets.

**Default display columns:**

| Column | Source | Sortable |
|--------|--------|----------|
| FQDN | Subdomain.name | YES |
| KRIL Score | Subdomain.kril_score | YES (default sort, desc) |
| Status | Subdomain.resolved | YES |
| A Records | Subdomain.a_records | NO |
| HTTP Positive | Derived: HTTPEndpoint exists | YES |
| Findings | Count of linked Findings | YES |
| Critical Findings | Count of severity=critical Findings | YES |
| First Seen | Subdomain.first_seen | YES |
| Last Seen | Subdomain.last_seen | YES |

**Filters:**

| Filter | Type | Values |
|--------|------|--------|
| Resolution Status | Toggle | Resolved / Unresolved / All |
| HTTP Positive | Toggle | Yes / No / All |
| KRIL Score | Range slider | 0–100 |
| Has Findings | Toggle | Yes / No / All |
| Finding Severity | Multi-select | Critical / High / Medium / Low / Info |
| Root Domain | Search/select | Autocomplete from Domain list |
| First Seen | Date range | From / To |
| Last Seen | Date range | From / To |
| IP Address | Text search | Exact or prefix match |

**Pagination:** 100 rows per page; total count displayed.

**Pivots available from row:**
- Click FQDN → Asset Detail (View 1 drilldown)
- Click IP Address → IP Detail (shows all subdomains resolving to this IP)
- Click Findings count → Finding Triage (pre-filtered to this asset)
- Click root domain → Asset Discovery pre-filtered to that domain

**User journey: "Find critical findings on high-value targets"**
1. Open Asset Discovery
2. Filter: KRIL ≥ 70, Severity = Critical
3. Sort by KRIL Score desc
4. Click FQDN → Asset Detail
5. Click Finding → Finding Detail

**≤ 5 clicks to critical finding detail.** ✓

---

### View 1a: Asset Detail (Drilldown)

**Triggered by:** Click on FQDN in Asset Discovery.

**Sections:**

```
[FQDN Header]   api.example.com
[Metadata Bar]  KRIL: 87 | Resolved: YES | First Seen: 2026-03-01 | Last Seen: 2026-03-03
[IP Addresses]  1.2.3.4 (AS15169 / Google LLC / US) | [pivot to IP Detail]
[HTTP Endpoints] Table: URL / Status / Content-Type / Body Hash / First Seen
[Findings]       Table: Template ID / Severity / Finding Class / Confirmed At / [detail link]
[Graph Preview] Visual: 1-hop neighbors (links to, SAN peers) [expand link]
[CNAME Chain]   If applicable: alias.example.com → target.example.com
[Technologies]  nginx/1.24.0, React 18
```

---

### View 2: Finding Triage (Analyst)

**Purpose:** Prioritize and review vulnerability findings across the full corpus.

**Default display columns:**

| Column | Source | Sortable |
|--------|--------|----------|
| FQDN | Vulnerability.fqdn | YES |
| Template ID | Vulnerability.template_id | YES |
| Severity | Vulnerability.severity | YES (default sort: critical first) |
| Finding Class | Vulnerability.finding_class | YES |
| CVSS | Vulnerability.cvss | YES |
| KRIL Score | Subdomain.kril_score (joined) | YES |
| Confirmed At | Vulnerability.confirmed_at | YES |
| Evidence | Truncated preview | NO |

**Filters:**

| Filter | Type | Values |
|--------|------|--------|
| Severity | Multi-select | Critical / High / Medium / Low / Info |
| Finding Class | Multi-select | vulnerability_cve / misconfiguration / exposure / injection / takeover / etc. |
| Template ID | Text search | Partial match |
| KRIL Score | Range slider | 0–100 |
| FQDN | Text search | Partial match |
| Root Domain | Search/select | |
| Confirmed After | Date picker | |
| Confirmed Before | Date picker | |

**Pivots from row:**
- Click FQDN → Asset Detail
- Click Template ID → Template Detail (all assets with this template finding)

**User journey: "Triage all critical CVE findings"**
1. Open Finding Triage
2. Filter: Severity = Critical, Finding Class = vulnerability_cve
3. Sort by KRIL Score desc
4. Click FQDN → Asset Detail
5. Click Finding → detail

**≤ 5 clicks.** ✓

---

### View 2a: Template Detail (Drilldown)

**Triggered by:** Click on Template ID in Finding Triage.

**Sections:**

```
[Template Header]  CVE-2023-12345 — Remote Code Execution — CRITICAL (CVSS: 9.8)
[Affected Assets]  Table of all FQDNs with this finding, sorted by KRIL Score desc
[Timeline]         Chart: confirmed_at distribution over time
[Export Button]    Download affected FQDNs as CSV for bug bounty submission
```

---

### View 3: Attack Surface Map (Analyst)

**Purpose:** Graph visualization of entity relationships for attack surface exploration.

**Entry points:**
- Search by FQDN (seed node)
- Navigate from Asset Detail "View in Graph" button
- Search by IP address (show all subdomains resolving to this IP)

**Graph display:**

| Node Type | Color | Shape | Label |
|-----------|-------|-------|-------|
| Subdomain | Blue | Circle | FQDN (truncated) |
| IPAddress | Green | Square | IP addr |
| Finding (critical) | Red | Diamond | Template ID |
| Finding (high) | Orange | Diamond | Template ID |
| Domain | Gray | Large circle | Root domain |

| Edge Type | Style | Label |
|-----------|-------|-------|
| RESOLVES_TO | Solid | — |
| LINKS_TO | Dashed | "links to" |
| SAN_PEER | Dotted | "SAN" |
| HAS_FINDING | Red solid | severity |

**Depth controls:** Depth 1 / 2 / 3 (max); default = 1 hop.

**Node actions:**
- Click node → highlight connected edges
- Right-click node → "View Asset Detail" / "Filter to this IP" / "Find similar findings"
- Double-click node → expand one more hop

**Performance constraint:** Max 500 nodes displayed; if result exceeds 500, show top-500 by KRIL score with "Showing top 500 of N nodes" notice.

**User journey: "Explore attack surface from a high-KRIL finding"**
1. Navigate to Asset Detail (from Finding Triage)
2. Click "View in Graph"
3. Set depth = 2
4. Identify linked assets
5. Click linked asset → Asset Detail

**≤ 5 clicks.** ✓

---

### View 4: HTTP Endpoint Browser (Analyst)

**Purpose:** Review discovered HTTP endpoints; identify interesting response patterns.

**Default display columns:**

| Column | Source | Sortable |
|--------|--------|----------|
| URL | HTTPEndpoint.url | YES |
| FQDN | HTTPEndpoint.fqdn | YES |
| Status Code | HTTPEndpoint.status_code | YES |
| Content Type | HTTPEndpoint.content_type | YES |
| Title | HTTPEndpoint.title | NO |
| Content Length | HTTPEndpoint.content_length | YES |
| Dynamic Content | HTTPEndpoint.dynamic_content | YES |
| First Seen | HTTPEndpoint.first_seen | YES |

**Filters:**

| Filter | Type | Values |
|--------|------|--------|
| Status Code | Multi-select / range | 200 / 301 / 302 / 401 / 403 / 404 / 5xx / custom range |
| Content Type | Multi-select | text/html / application/json / application/xml / etc. |
| FQDN | Text search | |
| Root Domain | Search/select | |
| Has Title | Toggle | Yes / No |
| Dynamic Content | Toggle | Yes / No / All |
| KRIL Score | Range slider | 0–100 (of parent Subdomain) |

**Interesting status filter presets:**
- "Juicy Endpoints": status IN (200, 401, 403) AND content_type = application/json
- "Admin Panels": title CONTAINS "admin" OR title CONTAINS "dashboard" (case-insensitive)
- "Dynamic Content": dynamic_content = true (may have CSRF-protected forms)

---

### View 5: Operations Log (Analyst / Leadership)

**Purpose:** Live operational monitoring. NOT a drilldown view — read-only status panel.

**Sections:**

```
[Throughput Panel]
  DNS: 680k/hr ● HTTP: 47k/hr ● Enrich: 4.8k/hr ● Ingest: 195k/hr
  [Trend sparklines: last 6h]

[SLO Status Panel]
  ✅ DNS Throughput: 680k/hr (target 700k)
  ✅ Neo4j Write Latency p95: 420ms (target 500ms)
  ⚠️ ClickHouse Parts: 520 (warning at 500)
  ✅ DLQ Depth: 23 (target < 500)

[Phase Status]
  Current Phase: 3 — Steady State
  DNS Corpus: 74% complete
  HTTP Corpus: 31% complete
  Phase started: H12 | Elapsed: 18h | Remaining: ~30h

[Recent Alerts]
  [2026-03-03 14:22] ALT-009 ClickHouse parts 520 — WARNING
  [2026-03-03 12:01] Phase 3 activated (ORS confirmed gate)
  [2026-03-03 08:15] Phase 2 activated

[Active DLQ Items]
  DNS DLQ: 0 | HTTP DLQ: 12 | Enrich DLQ: 3
```

**Refresh:** Auto-refresh every 30s (targets ≤ 60s SLO). Last refresh timestamp displayed.

---

### View 6: Executive Summary (Leadership)

**Purpose:** One-page operation health for leadership. No drilldown — export only.

**Sections:**

```
[Operation Summary]
  Status: ● ACTIVE — Phase 3 Steady State
  Elapsed: 18h / 72h | Est. Completion: 2026-03-04 06:00 UTC

[Corpus Progress]
  DNS: ██████████░░░░ 74% of 10M
  HTTP: ████░░░░░░░░░ 31% of 2.5M estimated
  Enrichment: ██░░░░░░░░░░░ 18% of 450k estimated

[Findings Summary]
  Critical: 12 | High: 87 | Medium: 341 | Low: 1,204 | Info: 8,902
  New in last 24h: 3 critical, 22 high

[SLO Compliance]
  Throughput: ✅ All lanes meeting targets
  Integrity: ✅ Mismatch rate 0.08% (target ≤ 0.5%)
  MTTR: ✅ No incidents requiring > 20 min resolution

[Export]  [Download PDF Report]  [Download Findings CSV]
```

**Refresh:** 60s auto-refresh. Timestamp displayed.

---

## Filter Taxonomy

### Filter Precedence

All filters are AND-combined (not OR) by default. UI should clearly indicate active filter count and support "Clear All Filters" with one click.

### Persistent Filter State

Filters persist within a session. Navigating to Asset Detail and back returns to the same filtered list. Shareable filter URLs (filter state encoded in URL query parameters) for analyst collaboration.

### Filter Performance

- All filter operations served by pre-indexed queries (Neo4j indexes on kril_score, severity, template_id, fqdn; ClickHouse materialized views for aggregates)
- Filter response time target: ≤ 1s for any single-dimension filter on full corpus
- Complex multi-filter: ≤ 3s

---

## Pivot Map

```
Asset Discovery
  → Asset Detail (click FQDN)
      → IP Detail (click IP)
          → All subdomains on IP
          → Finding Triage (filtered to IP)
      → Finding Detail (click finding)
          → Template Detail (click template ID)
              → All affected assets
      → Graph View (click "View in Graph")
          → Asset Detail (click node)
  → Finding Triage (click finding count)
  → Asset Discovery (click root domain)

Finding Triage
  → Asset Detail (click FQDN)
  → Template Detail (click template ID)

HTTP Endpoint Browser
  → Asset Detail (click FQDN)
  → Finding Triage (if endpoint has findings)

Attack Surface Map
  → Asset Detail (click node)
  → IP Detail (click IP node)
```

**Maximum pivot depth from any entry point: 3.** All pivots reachable in ≤ 3 hops. ✓

---

## User Journey Validation

| Journey | Steps | Clicks | ≤5? |
|---------|-------|--------|-----|
| Find critical findings on high-KRIL assets | Asset Discovery → filter → click FQDN → click finding | 4 | ✓ |
| Identify all assets on a specific IP | Asset Discovery → click IP address | 2 | ✓ |
| Find all assets vulnerable to a specific CVE | Finding Triage → filter template ID → view list | 3 | ✓ |
| Export assets with critical findings for reporting | Finding Triage → filter severity=critical → Template Detail → Download CSV | 4 | ✓ |
| Explore attack surface neighbors of a target | Asset Discovery → Asset Detail → View in Graph → set depth 2 → click neighbor | 5 | ✓ |
| Check operation status | Operations Log (one click from nav) | 1 | ✓ |
| Leadership: get finding count summary | Executive Summary (one click from nav) | 1 | ✓ |

All core journeys ≤ 5 clicks. ✓

---

## Implementation Approach

### Minimum Viable Console (Phase 1)

Build in this order (parallels WO-00008 Phase 3):

1. **Operations Log** — Lowest complexity; highest operational value. Just an API proxy to `/api/v1/stats/summary` and `/api/v1/stats/throughput`. Build first.
2. **Asset Discovery** — Core analyst view. Filterable table backed by `/api/v1/subdomains`. Add filters incrementally.
3. **Asset Detail** — Single FQDN detail page. Static layout; multiple API calls.

### Phase 2 (after Phase 1 stable)

4. **Finding Triage** — Table backed by `/api/v1/findings`.
5. **Template Detail** — Aggregate view; single Cypher query.
6. **Executive Summary** — Mostly derived from existing API endpoints.

### Phase 3 (graph visualization)

7. **Attack Surface Map** — Requires graph rendering library (D3.js or Cytoscape.js). Highest complexity; highest analyst value.
8. **HTTP Endpoint Browser** — Table backed by enhanced API endpoint.

### Technology Recommendation (defer to WO-00013)

Tech stack selection is explicitly WO-00013 scope. This document is technology-agnostic — all views are defined as data models and user journeys, not framework-specific implementations.

---

## Tradeoffs

| Decision | Chosen | Rejected | Rationale |
|----------|--------|----------|-----------|
| AND-only filter combination | ✅ | OR option | OR filters with 10+ filter dimensions create counterintuitive results and performance issues. AND is the safe default; analysts can iterate. |
| ≤ 500 nodes in graph view | ✅ | Unlimited | Graph rendering with 10k+ nodes is unusable in browser. 500 node cap with KRIL-based prioritization shows the most valuable portion of the graph. |
| URL-encoded filter state | ✅ | Session storage only | Shareable filter URLs enable analyst collaboration (share a pre-filtered view in Mattermost). Session-only filters are not shareable. |
| Separate Analyst/Leadership roles | ✅ | Single unified view | Leadership needs aggregate KPIs and SLO compliance; analysts need row-level filtering and graph drilldowns. A single view trying to serve both is cluttered for both. |
| Operations Log as separate view | ✅ | Embedded in all views | Persistent sidebar status panels distract during deep analysis. Dedicated Operations Log view lets analysts focus on data when needed, monitor when needed. |

---

## Risks

| ID | Title | Severity | Probability | Mitigation |
|----|-------|----------|-------------|------------|
| R1 | Graph view unusable at high node count | HIGH | MEDIUM | 500 node cap; KRIL-prioritized display; "Showing top N of M" notice |
| R2 | Filter query latency with complex multi-filter | MEDIUM | MEDIUM | Pre-indexed Neo4j properties; ClickHouse materialized views; ≤3s SLO for complex filters |
| R3 | Frontend over-complexity (scope creep) | MEDIUM | HIGH | Strict phase ordering; no graph view until Phase 3; no feature additions before Phase 1 ships |
| R4 | Summary refresh delay > 60s | LOW | LOW | Operations Log backed by ClickHouse materialized view (not live query); 30s auto-refresh |

---

## Recommendations

| Priority | ID | Action |
|----------|-----|--------|
| 1 | REC-01 | Build Operations Log first — immediately useful for 72h operation monitoring even before analyst views |
| 2 | REC-02 | Implement shareable filter URLs from day 1 — enables analyst collaboration via Mattermost |
| 3 | REC-03 | Add "interesting presets" to HTTP Endpoint Browser filter panel (Juicy Endpoints, Admin Panels, Dynamic Content) |
| 4 | REC-04 | Enforce ≤ 500 node cap in graph view with KRIL-based prioritization and visible count notice |
| 5 | REC-05 | Add "Export CSV" to Finding Triage and Template Detail views — bug bounty submission workflow |
| 6 | REC-06 | Implement persistent filter state within session; "Clear All Filters" as one-click action |
| 7 | REC-07 | Defer graph visualization to Phase 3 (highest complexity); REST API views sufficient for Phase 1-2 |
| 8 | REC-08 | Tech stack decision to WO-00013 — this document is technology-agnostic |

---

## KPIs

| KPI | Target |
|-----|--------|
| Core user journeys (all defined) | ≤ 5 clicks |
| Operations Log refresh | ≤ 30s (target); ≤ 60s (SLO) |
| Filter response time (single dimension) | ≤ 1s |
| Filter response time (complex multi-filter) | ≤ 3s |
| Graph view max nodes | ≤ 500 |
| Pivot depth from any entry point | ≤ 3 hops |

---

## Assumptions

- **A1:** REST API endpoints (`/api/v1/subdomains`, `/api/v1/findings`, `/api/v1/graph/neighbors`, `/api/v1/stats/summary`) are available as the data backend
- **A2:** Neo4j indexes on kril_score, severity, template_id are applied before frontend query load
- **A3:** ClickHouse materialized views provide aggregate stats without full-table scans
- **A4:** Frontend tech stack TBD in WO-00013; this design is framework-agnostic
- **A5:** Authentication and authorization is out of scope for v1 (internal network only); access control for leadership vs. analyst role deferred to v1.1
- **A6:** Mattermost is available for analyst collaboration (shareable filter URLs sent via Mattermost)

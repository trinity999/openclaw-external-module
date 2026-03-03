# WO-00013: Tech Stack Recommendation — Frontend + API Layer

**Work Order:** WO-00013
**Category:** research
**Analyst:** openclaw-field-processor
**Produced:** 2026-03-03
**Confidence:** 0.92

---

## Executive Decision

**Recommended stack: FastAPI (API) + React/Vite (frontend)**

- API: Python/FastAPI + Uvicorn + Gunicorn — runs on controller host, zero additional infrastructure
- Frontend: React 18 + Vite 5 + TanStack Query/Table + recharts — static build served by nginx
- Deployment: nginx reverse proxy on controller host (Phase 1–2); optional VPS isolation at Phase 3+
- Additional monthly ops cost: **$0** for Phase 1–2 (on controller host); **$20–40/mo** if VPS split chosen

---

## 1. Requirements Derivation

From WO-00012 (IA design) and system context:

| Requirement | Implication |
|-------------|-------------|
| 8 views with sortable/filterable analyst tables | Frontend needs mature table library with server-side sort/filter support |
| Neo4j + ClickHouse dual-store backend | API must speak both; Python ecosystem has mature official drivers |
| Graph view (Phase 3, 500-node cap, Cytoscape) | Frontend needs DOM-based graph renderer; must be lazy-loaded |
| Internal network only (v1) | No SSR/SEO needed; static SPA is sufficient |
| Low-ops overhead (constraint) | Minimize runtime dependencies, deployment surfaces, and config complexity |
| Python controller already in production | API in Python = same language, same driver versions, same team |
| Operations Log: 30s auto-refresh | Frontend needs server-state polling; TanStack Query handles this cleanly |
| URL-encoded shareable filter state | React Router + URLSearchParams; no state manager needed |
| Export CSV/PDF (Finding Triage, Executive Summary) | API generates CSV; PDF via browser print-to-PDF or wkhtmltopdf on server |
| Phase-ordered delivery (Ops Log → Tables → Graph) | Stack must allow incremental build without upfront complexity |

---

## 2. Candidate Matrix

Three candidates evaluated on six dimensions: ops overhead, dev familiarity, performance, graph support, ecosystem maturity, and monthly cost.

### Candidate 1: FastAPI + React/Vite (RECOMMENDED)

| Dimension | Rating | Notes |
|-----------|--------|-------|
| Ops overhead | Low | Uvicorn + systemd on existing host; nginx serves static build |
| Dev familiarity | High | Python API (same as controller); React is industry standard |
| Performance | High | Async FastAPI; Vite produces <200KB initial JS bundle |
| Graph support | Full | Cytoscape.js Phase 3; code-split, loaded on demand |
| Ecosystem maturity | Very High | neo4j-driver 5.x, clickhouse-connect 0.7+, TanStack v5 |
| Monthly cost (Phase 1–2) | $0 | On controller host |
| Monthly cost (Phase 3, VPS) | $20–40/mo | 2vCPU / 4GB VPS |

**Verdict:** Best all-around fit. Python API eliminates language mismatch with controller. React ecosystem provides the mature table, chart, and graph components needed by the IA. Zero extra infrastructure in Phase 1–2.

---

### Candidate 2: FastAPI + Next.js

| Dimension | Rating | Notes |
|-----------|--------|-------|
| Ops overhead | Medium | Next.js requires Node.js runtime for SSR; adds second process |
| Dev familiarity | Medium | React familiar but Next.js abstractions (App Router, RSC) add learning curve |
| Performance | High | SSR/SSG provides fast initial load — unnecessary for internal auth-gated tool |
| Graph support | Full | react-force-graph or Cytoscape.js adapter available |
| Ecosystem maturity | Very High | Largest React meta-framework ecosystem |
| Monthly cost | $30–60/mo | Needs Node.js server or Vercel; cannot serve SSR as static files |

**Verdict:** Overkill for internal tooling. SSR provides no benefit when the tool is internal (no SEO, no public indexing). Adds Node.js ops burden and Next.js complexity. The App Router's streaming/RSC features are net-negative complexity for a data-heavy analyst console.

---

### Candidate 3: FastAPI + SvelteKit

| Dimension | Rating | Notes |
|-----------|--------|-------|
| Ops overhead | Medium | SvelteKit SSR needs Node.js adapter; adapter-static possible but limits routing |
| Dev familiarity | Low-Medium | Svelte is less common than React; onboarding cost for new analysts |
| Performance | Very High | Smallest runtime bundle; no virtual DOM overhead |
| Graph support | Partial | d3.js works but no first-class Svelte graph components at scale |
| Ecosystem maturity | Medium | Fewer table/chart components than React; svelte-table less battle-tested |
| Monthly cost | $0–30/mo | Can static-adapt but complex multi-layout SvelteKit apps may require Node |

**Verdict:** Superior performance characteristics but smaller ecosystem and higher team familiarity cost. TanStack Table (critical for analyst views) is React-native; Svelte port is community-maintained and less featured. Not recommended given ecosystem gap in table/graph components.

---

### Candidate Comparison Summary

| | FastAPI + React/Vite | FastAPI + Next.js | FastAPI + SvelteKit |
|---|---|---|---|
| Ops overhead | ★ Low | ★★ Medium | ★★ Medium |
| Team familiarity | ★ High | ★★ Medium | ★★★ Low |
| Table library quality | ★ TanStack v8 | ★ TanStack v8 | ★★ svelte-table |
| Graph visualization | ★ Cytoscape.js | ★ react-force-graph | ★★ d3 only |
| Phase 1–2 cost | ★ $0 | ★★ $30–60/mo | ★ $0–30/mo |
| SSR necessity | ✗ Not needed | ✓ Adds | ✓ Adds |
| **Decision** | **RECOMMENDED** | Reject | Reject |

---

## 3. Recommended Stack — Full Specification

### 3.1 API Layer: FastAPI

```
Runtime:    Python 3.12 + Uvicorn 0.30+ (async ASGI)
Process:    Gunicorn + Uvicorn workers (4 workers = 4 vCPU async)
Framework:  FastAPI 0.115+
Validation: Pydantic v2 (schema coercion at boundary)
Config:     python-dotenv + Pydantic settings
```

**Database drivers:**

| Store | Driver | Notes |
|-------|--------|-------|
| Neo4j | `neo4j` 5.x (official) | Built-in async connection pool; bolt protocol |
| ClickHouse | `clickhouse-connect` 0.7+ | HTTP-based; async support; handles FINAL queries |

**API mount points (from WO-00012 IA):**

```
/api/v1/subdomains                    → Neo4j subdomain listing (kril_score sort)
/api/v1/subdomains/{fqdn}             → Neo4j single subdomain detail
/api/v1/findings                      → Neo4j finding listing (severity sort)
/api/v1/findings?template_id={id}     → Template detail filtered findings
/api/v1/graph/neighbors               → Neo4j graph traversal (depth 1–3, 500 cap)
/api/v1/stats/summary                 → ClickHouse materialized view aggregate
/api/v1/stats/throughput              → ClickHouse time-series for Operations Log
/api/v1/subdomains/{fqdn}/endpoints   → Neo4j HTTP endpoint list
```

**Response format:** All endpoints return `application/json`; paginated responses use `{data: [...], total: N, page: N, page_size: N}`.

**Performance:**
- Neo4j async driver with pool_size=50 handles concurrent analyst queries
- ClickHouse materialized views for `/api/v1/stats/*` → no full-table scans
- Target: p95 < 500ms for single-dimension filter, p95 < 2s for complex multi-filter

---

### 3.2 Frontend Layer: React 18 + Vite 5

```
Build tool:  Vite 5 (ESBuild + Rollup; <5s dev startup, <30s prod build)
Framework:   React 18 (concurrent mode, Suspense for loading states)
Routing:     React Router v6 (URL-encoded filter state in search params)
```

**Library choices by concern:**

| Concern | Library | Rationale |
|---------|---------|-----------|
| Server state + polling | TanStack Query v5 | 30s auto-refresh (Operations Log); stale-while-revalidate; cache invalidation |
| Analyst tables (sort/filter) | TanStack Table v8 | Virtualised rows for 10k+ subdomain lists; column sort; header filter inputs |
| KPI / telemetry charts | recharts 2.x | AreaChart for throughput, BarChart for severity distribution; React-native |
| Graph view (Phase 3) | Cytoscape.js 3.x | 500-node cap; KRIL-sized nodes; edge coloring by relationship type |
| CSS | Tailwind CSS 3.x | Utility-first; no design system overhead; dark theme ready |
| URL filter state | React Router URLSearchParams | Shareable filter URLs (Mattermost collaboration, WO-00012 requirement) |
| CSV export | papaparse + FileSaver | Client-side CSV generation from API response |
| PDF export | Browser print dialog | `window.print()` with `@media print` CSS; zero server cost |

**Code splitting strategy:**
- Cytoscape.js (graph, ~300KB) is dynamic-imported only when Attack Surface Map view loads
- recharts (~200KB) split per route — only loaded by Operations Log and Executive Summary
- Initial bundle target: <150KB (Vite tree-shaking + code split)

---

## 4. Deployment Architecture

### Option A: Monorepo on Controller Host (Recommended for Phase 1–2)

```
Controller Host
├── /opt/recon-api/          FastAPI app (systemd: recon-api.service)
│   ├── Uvicorn :8000        (internal only, not exposed to internet)
│   └── neo4j + clickhouse-connect drivers
├── /var/www/recon-ui/       React static build (npm run build output)
└── nginx :80
    ├── /api/*               proxy_pass http://127.0.0.1:8000
    └── /*                   root /var/www/recon-ui; try_files SPA fallback
```

**nginx config skeleton:**
```nginx
server {
    listen 80;
    server_name recon.internal;  # internal hostname

    location /api/ {
        proxy_pass http://127.0.0.1:8000;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_read_timeout 30s;
    }

    location / {
        root /var/www/recon-ui;
        try_files $uri $uri/ /index.html;  # SPA fallback
    }
}
```

**Systemd unit (FastAPI):**
```ini
[Unit]
Description=Recon API (FastAPI/Uvicorn)
After=network.target

[Service]
User=recon
WorkingDirectory=/opt/recon-api
ExecStart=/opt/recon-api/venv/bin/gunicorn \
    -w 4 -k uvicorn.workers.UvicornWorker \
    -b 127.0.0.1:8000 main:app
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
```

**Phase 1–2 cost: $0 additional** (co-located on existing controller host).

---

### Option B: Separate Lightweight VPS (Phase 3+ or on load)

Trigger: If API query load causes measurable latency increase on controller (monitor via ORS signal `api_p95_latency_ms`).

```
VPS (2vCPU / 4GB RAM)
├── recon-api (FastAPI)      same Docker image or systemd unit
├── nginx                    reverse proxy + static file server
└── Internal VPN             Neo4j + ClickHouse access over WireGuard/internal net

Monthly cost: ~$20–40/mo (Hetzner CX21 or DigitalOcean Basic)
```

---

## 5. Monthly Cost Model

### Phase 1–2: On Controller Host

| Component | Cost |
|-----------|------|
| FastAPI (Uvicorn + systemd) | $0 (existing host) |
| React static build (nginx) | $0 (existing nginx) |
| Neo4j driver queries | $0 (existing Neo4j) |
| ClickHouse queries | $0 (existing ClickHouse) |
| **Total additional** | **$0/mo** |

### Phase 3: VPS Split (if triggered)

| Component | Cost |
|-----------|------|
| Hetzner CX21 (2vCPU/4GB) | €3.79/mo (~$4/mo) |
| Hetzner CX32 (4vCPU/8GB) | €9.59/mo (~$10/mo) |
| DigitalOcean Basic 2vCPU | $18/mo |
| **Typical range** | **$4–20/mo** |

### Phase 3: Optional: Hosted Neo4j Aura (if self-host retirement considered)

| Tier | Cost | Notes |
|------|------|-------|
| Aura Free | $0 | 200k nodes limit — insufficient for 10M subdomains |
| Aura Professional | ~$65/mo | 200GB storage, sufficient for corpus |
| Self-hosted (current) | $0 extra | Recommended: keep self-hosted for cost |

**Recommendation: Keep Neo4j + ClickHouse self-hosted. Aura Professional adds $65/mo with no operational benefit for internal tooling.**

---

## 6. Implementation Phasing (aligned with WO-00012 build phases)

### Phase 1: Operations Log + Asset Discovery + Asset Detail (≤2 weeks)

**API deliverables:**
- `/api/v1/stats/summary` → ClickHouse aggregate query
- `/api/v1/stats/throughput` → ClickHouse time-series
- `/api/v1/subdomains` → Neo4j list with sort + filter
- `/api/v1/subdomains/{fqdn}` → Neo4j single detail

**Frontend deliverables:**
- React + Vite scaffold with Tailwind
- React Router with 3 routes (/, /assets, /assets/:fqdn)
- TanStack Query polling for Operations Log (30s)
- TanStack Table for Asset Discovery (kril_score sort default)
- URL-encoded filter state from day 1

**Infrastructure:**
- FastAPI on controller host (systemd)
- nginx static serve + /api proxy
- `npm run build` → deploy to `/var/www/recon-ui`

---

### Phase 2: Finding Triage + Template Detail + Executive Summary (≤2 weeks)

**API deliverables:**
- `/api/v1/findings` → Neo4j finding list with multi-filter support
- `/api/v1/findings?template_id={id}` → Template detail list
- CSV export endpoint: `GET /api/v1/findings.csv` (generates CSV from query params)

**Frontend deliverables:**
- Finding Triage view with TanStack Table (severity + kril_score sort)
- Template Detail view with affected assets table + timeline
- Executive Summary view with recharts KPI panels
- CSV export button (FileSaver client-side from API JSON, or direct .csv endpoint)
- PDF export via browser print dialog (CSS @media print stylesheet)

---

### Phase 3: Attack Surface Map + HTTP Endpoint Browser (≤3 weeks, higher complexity)

**API deliverables:**
- `/api/v1/graph/neighbors` → Neo4j BFS traversal (depth param 1–3, 500 node cap)
- `/api/v1/subdomains/{fqdn}/endpoints` → HTTP endpoint list with filter support

**Frontend deliverables:**
- Cytoscape.js dynamic import (code-split, only loaded on /graph route)
- Node coloring: Subdomain (blue), IPAddress (orange), Finding (red)
- Edge coloring by relationship type (RESOLVES_TO, HAS_FINDING, SAN_PEER, LINKS_TO)
- Node size proportional to kril_score
- Depth selector (1/2/3) + FQDN/IP search entry point
- 500-node cap notice if corpus exceeds cap
- HTTP Endpoint Browser view with preset filters (Juicy Endpoints, Admin Panels, Dynamic Content)

---

## 7. Migration and Rollback Plan

### API Rollback

Since FastAPI is stateless (all state in Neo4j + ClickHouse), rollback = redeploy previous version.

**Rollback procedure:**
```bash
# Keep last 3 deployed versions in /opt/recon-api-versions/
ls /opt/recon-api-versions/
# v1.2.1 v1.2.0 v1.1.3

# Rollback to previous version:
systemctl stop recon-api
ln -sfn /opt/recon-api-versions/v1.2.0 /opt/recon-api
systemctl start recon-api
# Total downtime: <10s
```

**Blue-green nginx swap (zero downtime):**
```bash
# Run new version on port 8001, validate, then swap
systemctl start recon-api-blue  # port 8001
# Run smoke tests against :8001
nginx -s reload  # swap upstream to 8001
systemctl stop recon-api-green  # port 8000
```

### Frontend Rollback

Static build: keep last 3 build directories.

```bash
ls /var/www/
# recon-ui/         (current symlink target)
# recon-ui-v1.2.1/
# recon-ui-v1.2.0/
# recon-ui-v1.1.3/

# Rollback:
ln -sfn /var/www/recon-ui-v1.2.0 /var/www/recon-ui
nginx -s reload
# Total downtime: 0s (nginx serves symlink target instantly)
```

### Database Migration

- API is read-only in Phase 1–2 (all writes go through controller)
- No schema migration on the API side
- If Neo4j property names change: update FastAPI query layer only, no data migration
- ClickHouse: add new materialized views alongside old (additive only); deprecate after validation

---

## 8. Risk Model

| ID | Risk | Severity | Probability | Mitigation |
|----|------|----------|-------------|------------|
| R1 | FastAPI query latency under concurrent analyst load | MEDIUM | LOW | Async driver + Neo4j connection pool (pool_size=50); ClickHouse materialized views for aggregates |
| R2 | Cytoscape.js bundle size bloats initial load | LOW | LOW | Dynamic import (code split); only loaded on Phase 3 graph route; target <150KB initial bundle |
| R3 | TanStack Table virtualisation breaks on 50k+ rows | MEDIUM | LOW | Paginate API responses (page_size=100); virtualised row renderer for in-memory data |
| R4 | React scope creep before Phase 1 ships | HIGH | MEDIUM | Strict phase gate: no graph imports until Phase 3; no additional views before Phase 1 complete |
| R5 | nginx SPA routing breaks on direct URL access | LOW | LOW | `try_files $uri $uri/ /index.html` in nginx config; standard SPA fallback |
| R6 | ClickHouse FINAL query latency on high-ingest periods | MEDIUM | MEDIUM | Materialized view pre-aggregates; API queries MV not raw table; 30s refresh SLO |
| R7 | VPS cost trigger undefined | LOW | MEDIUM | Define ORS signal: alert if `api_p95_latency_ms > 2000` for 3 consecutive minutes |

---

## 9. Assumptions

- A1: Controller host has sufficient CPU headroom for FastAPI (4 Uvicorn workers ≈ 4 vCPU)
- A2: neo4j-driver 5.x async session is compatible with existing Neo4j version on controller host
- A3: ClickHouse materialized views exist for stats aggregates (required by WO-00012 filter performance targets)
- A4: Internal network access only for v1 (no TLS termination required beyond nginx HTTP for LAN)
- A5: npm build toolchain available on controller host or CI; frontend deployment is static file copy
- A6: Authentication deferred to v1.1 (WO-00012 A5); no JWT/session middleware needed in Phase 1
- A7: Python version on controller host is 3.11+ (FastAPI + Pydantic v2 requirement)

---

## 10. Recommended Actions (Priority Order)

| Priority | ID | Action |
|----------|----|--------|
| 1 | REC-01 | Scaffold FastAPI app with `/api/v1/stats/summary` and `/api/v1/subdomains` first — feeds Operations Log and Asset Discovery (Phase 1) |
| 2 | REC-02 | Create systemd unit for Uvicorn + nginx config with SPA fallback before writing first React component |
| 3 | REC-03 | Implement URL-encoded filter state (React Router URLSearchParams) from day 1 — cannot retrofit cheaply |
| 4 | REC-04 | Use TanStack Query for all API calls — enables 30s polling for Operations Log with zero custom code |
| 5 | REC-05 | Set up Vite code splitting: dynamic import for Cytoscape.js from Phase 1 — prevents bundle bloat later |
| 6 | REC-06 | Define ORS signal `api_p95_latency_ms` — triggers VPS split decision if controller host saturates |
| 7 | REC-07 | Keep last 3 frontend builds in versioned directories — enables <0s rollback via nginx symlink swap |
| 8 | REC-08 | Use ClickHouse materialized views for all `/api/v1/stats/*` endpoints — required for ≤1s filter SLO |

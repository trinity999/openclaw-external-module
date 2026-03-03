# ARTIFACT: WO-00009
# Canonical Entity Model and Deterministic Dedup Strategy

**Analyst:** OpenClaw Field Processor
**Work Order:** WO-00009
**Category:** Correlation
**Priority:** High
**Date:** 2026-03-03
**Status:** COMPLETED
**ARD Mode:** ANALYSIS — MEDIUM

---

## Executive Summary

WO-00009 delivers the canonical entity model for the recon data platform, covering seven entity types (Domain, Subdomain, IPAddress, Port, HTTPEndpoint, Service, Vulnerability) with deterministic dedup keys and linking rules. The model resolves the two primary entity integrity risks at scale: phantom duplication (one real entity split into multiple records) and phantom collapse (distinct entities merged under a shared attribute).

**Success metrics targeted:**
- Duplicate entity rate ≤ 0.5%
- Link precision ≥ 99% on validation sample
- Reconciliation runtime ≤ 20 min per batch

---

## Context Understanding

**Scale:** 10M+ subdomains, continuous batch pipeline, parallel ingest lanes.
**Stores:** Neo4j (canonical graph authority), ClickHouse (telemetry, dedup validation).
**Constraints:** JSON-first, idempotent ingest, replay-safe, no destructive mutation.
**Risk profile:** Conservative — false positives in entity linking (phantom collapse) are worse than false negatives (phantom duplication), because merging distinct entities corrupts graph topology irreversibly.

---

## Entity Model

### Entity Hierarchy

```
Domain (root authority)
  └── Subdomain (many per domain)
        ├── RESOLVES_TO → IPAddress (many per subdomain)
        │     └── HOSTS → Port (many per IP)
        │           └── RUNS → Service (one per port)
        ├── RESPONDS_WITH → HTTPEndpoint (many per subdomain)
        ├── HAS_VULNERABILITY → Vulnerability (many per subdomain)
        └── LINKS_TO → Subdomain (crawl-discovered)
        └── SAN_PEER → Subdomain (TLS SAN co-occurrence)
```

---

### Entity 1: Domain

**Identity:** Root public domain (eTLD+1).

**Canonical key:** `domain.name` — normalized to lowercase, eTLD+1 extracted.

| Property | Type | Description |
|----------|------|-------------|
| `name` | String (UNIQUE) | Normalized eTLD+1: `example.com` |
| `tld` | String | Top-level domain: `com` |
| `registrar` | String | WHOIS registrar (if available) |
| `first_seen` | DateTime | First observation |
| `last_seen` | DateTime | Most recent observation |

**Dedup key:** `SHA256("domain:" + name.lower())[:32]`

**Linking rule:** Every Subdomain `IS_SUBDOMAIN_OF` exactly one Domain. Domain extracted by stripping leftmost label until eTLD+1 remains (using public suffix list).

**Edge case:** `co.uk`, `com.au` are multi-level eTLDs. Use public suffix list (PSL) for eTLD+1 extraction, not naive split.

---

### Entity 2: Subdomain

**Identity:** Fully Qualified Domain Name (FQDN).

**Canonical key:** `subdomain.name` — normalized to lowercase FQDN without trailing dot.

| Property | Type | Description |
|----------|------|-------------|
| `name` | String (UNIQUE) | Normalized FQDN: `api.example.com` |
| `key_hash` | String | Dedup key (stored for validation) |
| `a_records` | String[] | Current A record IPs (array, sorted) |
| `aaaa_records` | String[] | Current AAAA record IPs |
| `cname_chain` | String[] | CNAME resolution chain |
| `resolved` | Boolean | True if DNS resolution succeeded |
| `kril_score` | Float | KRIL rank (0-100); updated per cycle |
| `asset_risk_score` | Float | Risk/value composite |
| `first_seen` | DateTime | First DNS scan |
| `last_seen` | DateTime | Most recent scan |
| `ingested_batch_id` | String | Last ingest batch reference |

**Dedup key:** `SHA256("subdomain:" + fqdn.lower().rstrip('.'))[:32]`

**Normalization:**
- `FQDN.lower()`
- Strip trailing dot: `api.example.com.` → `api.example.com`
- Strip `www.` prefix only if explicit scope rule requires it (default: preserve `www.example.com` as distinct from `example.com`)

**Edge case: CNAME aliases.** If `alias.example.com CNAME target.other.com`, create two Subdomain nodes and link them: `(alias)-[:CNAME_TO]->(target)`. Do NOT collapse them into one node — they are distinct assets with potentially distinct ownership.

**Edge case: Wildcard DNS.** `*.example.com` resolves all random subdomains to a single IP. Do NOT ingest wildcard resolution results as individual Subdomain nodes. Detect wildcard by checking if 5 random probes on `{uuid}.example.com` all resolve to the same IP. Flag parent domain as `wildcard: true` and suppress wildcard-matching FQDN ingest.

---

### Entity 3: IPAddress

**Identity:** IPv4 or IPv6 address string.

**Canonical key:** `ip.addr` — normalized to dotted decimal (IPv4) or compressed notation (IPv6).

| Property | Type | Description |
|----------|------|-------------|
| `addr` | String (UNIQUE) | `1.2.3.4` or `2001:db8::1` |
| `ptr` | String | PTR record (reverse DNS) |
| `asn` | String | ASN number: `AS15169` |
| `org` | String | ASN org name |
| `country` | String | GeoIP country code |
| `first_seen` | DateTime | First scan |
| `last_seen` | DateTime | Most recent scan |

**Dedup key:** `SHA256("ip:" + addr)[:32]`

**Normalization:**
- IPv4: strip leading zeros (`01.002.003.004` → `1.2.3.4`)
- IPv6: compress to canonical form (`0:0:0:1` → `::1`)

**Linking rule:** `(:Subdomain)-[:RESOLVES_TO]->(:IPAddress)` — one MERGE per (fqdn, ip) pair observed in DNS results. Multiple subdomains may share an IP (shared hosting — this is expected and structurally correct).

**Edge case: CDN IPs.** A subdomain behind Cloudflare will resolve to a CDN IP, not the origin. CDN IP is still a valid entity — it represents the network location the scanner reached. Tag with `cdn: true` if IP falls within known CDN CIDR ranges (maintained as config list).

---

### Entity 4: Port

**Identity:** (IPAddress, port_number, protocol) tuple.

**Canonical key:** Composite of IP + port + protocol.

| Property | Type | Description |
|----------|------|-------------|
| `ip_addr` | String | Parent IP address |
| `port_number` | Integer | Port number (0-65535) |
| `protocol` | String | `tcp` or `udp` |
| `state` | String | `open`, `filtered`, `closed` |
| `banner` | String | Service banner (raw) |
| `first_seen` | DateTime | First scan |
| `last_seen` | DateTime | Most recent scan |

**Dedup key:** `SHA256("port:" + ip_addr + ":" + port_number + ":" + protocol)[:32]`

**Linking rule:** `(:IPAddress)-[:HOSTS]->(:Port)` — one node per unique (ip, port, protocol) triplet.

---

### Entity 5: HTTPEndpoint

**Identity:** (FQDN, URL path, HTTP method) tuple. URL must be canonicalized before dedup.

**Canonical key:** Composite of fqdn + canonical_url + method.

| Property | Type | Description |
|----------|------|-------------|
| `fqdn` | String | Parent subdomain FQDN |
| `url` | String | Canonical URL (see normalization) |
| `method` | String | HTTP method: `GET`, `POST`, etc. |
| `status_code` | Integer | Most recent HTTP status |
| `content_type` | String | Response content-type |
| `content_length` | Integer | Response body size |
| `title` | String | HTML `<title>` value |
| `body_hash` | String | SHA256 of response body (static only) |
| `redirect_target` | String | Final URL after redirect chain |
| `first_seen` | DateTime | First probe |
| `last_seen` | DateTime | Most recent probe |

**Dedup key:** `SHA256("http:" + fqdn.lower() + "|" + canonical_url + "|" + method.upper())[:32]`

**URL canonicalization:**
1. Strip fragment: `https://example.com/page#section` → `https://example.com/page`
2. Lowercase scheme and host: `HTTPS://Example.COM/` → `https://example.com/`
3. Normalize path: remove double slashes, resolve `.` and `..`
4. Sort query parameters alphabetically: `?b=2&a=1` → `?a=1&b=2`
5. Strip tracking params (utm_source, utm_medium, fbclid, etc.) per configurable blocklist

**Edge case: Dynamic content.** Body hash will differ per response if content is dynamic (timestamps, CSRF tokens). Flag as `dynamic_content: true` if body_hash changes between two consecutive probes of the same URL. Do NOT update body_hash on every probe for dynamic URLs — use first-seen hash.

---

### Entity 6: Service

**Identity:** (Port, service_name, version) tuple.

**Canonical key:** Composite of port dedup key + service_name + version.

| Property | Type | Description |
|----------|------|-------------|
| `port_key` | String | Parent Port dedup key |
| `service_name` | String | Normalized service name: `nginx`, `apache` |
| `product` | String | Product name from banner |
| `version` | String | Detected version string |
| `cpe` | String | CPE identifier if matched |
| `first_seen` | DateTime | First detection |

**Dedup key:** `SHA256("service:" + port_key + "|" + service_name.lower() + "|" + version)[:32]`

---

### Entity 7: Vulnerability

**Identity:** (FQDN, template_id) pair — a finding is always anchored to the subdomain where it was discovered.

**Canonical key:** Composite of fqdn + template_id + evidence_hash.

| Property | Type | Description |
|----------|------|-------------|
| `fqdn` | String | Subdomain where found |
| `template_id` | String | Nuclei template ID |
| `severity` | String | `info`, `low`, `medium`, `high`, `critical` |
| `severity_int` | Integer | 0-4 for sorting |
| `cvss` | Float | CVSS score if available |
| `finding_class` | String | Category: `exposure`, `misconfiguration`, `injection`, etc. |
| `evidence_hash` | String | SHA256 of evidence content |
| `confirmed_at` | DateTime | First confirmation |
| `last_confirmed` | DateTime | Most recent confirmation |

**Dedup key:** `SHA256("vuln:" + fqdn.lower() + "|" + template_id + "|" + evidence_hash)[:32]`

**Edge case: Same template, different evidence.** If nuclei fires the same template_id twice on the same fqdn but with different evidence (e.g., two different exposed files), create TWO Vulnerability nodes — they are distinct findings with distinct evidence. Evidence_hash differentiates them.

**Edge case: Transient findings.** If a finding is confirmed once and not confirmed in subsequent scans, do NOT delete the Vulnerability node — mark `last_confirmed` unchanged. Deletion is a destructive mutation. Analyst decides whether to archive.

---

## Dedup Key Registry

| Entity | Key Formula | Example |
|--------|-------------|---------|
| Domain | `SHA256("domain:" + name.lower())[:32]` | `SHA256("domain:example.com")[:32]` |
| Subdomain | `SHA256("subdomain:" + fqdn.lower().rstrip('.'))[:32]` | `SHA256("subdomain:api.example.com")[:32]` |
| IPAddress | `SHA256("ip:" + addr)[:32]` | `SHA256("ip:1.2.3.4")[:32]` |
| Port | `SHA256("port:" + ip + ":" + port + ":" + proto)[:32]` | `SHA256("port:1.2.3.4:443:tcp")[:32]` |
| HTTPEndpoint | `SHA256("http:" + fqdn + "\|" + url + "\|" + method.upper())[:32]` | `SHA256("http:api.example.com\|/v1/users\|GET")[:32]` |
| Service | `SHA256("service:" + port_key + "\|" + name.lower() + "\|" + version)[:32]` | `SHA256("service:{port_key}\|nginx\|1.24.0")[:32]` |
| Vulnerability | `SHA256("vuln:" + fqdn.lower() + "\|" + template_id + "\|" + evidence_hash)[:32]` | `SHA256("vuln:api.example.com\|CVE-2023-XXXX\|{hash}")[:32]` |

**Key construction rules:**
- Prefix by entity type (prevents cross-type key collision even if content is identical)
- Pipe `|` separator between components (pipes not valid in FQDNs, URLs, or template IDs)
- Lowercase all string inputs before hashing
- Output: 32-character hex string (sufficient uniqueness at 10M+ scale; SHA256 collision probability negligible)

---

## Linking Rules and Relationship Dedup

Each relationship in the graph is also deduplicated by a relationship key.

| Relationship | From | To | Rel Key |
|-------------|------|----|---------|
| IS_SUBDOMAIN_OF | Subdomain | Domain | `SHA256(subdomain_key + "→PARENT→" + domain_key)[:32]` |
| RESOLVES_TO | Subdomain | IPAddress | `SHA256(subdomain_key + "→DNS→" + ip_key + batch_id)[:32]` |
| HOSTS | IPAddress | Port | `SHA256(ip_key + "→PORT→" + port_key)[:32]` |
| RUNS | Port | Service | `SHA256(port_key + "→SVC→" + service_key)[:32]` |
| RESPONDS_WITH | Subdomain | HTTPEndpoint | `SHA256(subdomain_key + "→HTTP→" + endpoint_key)[:32]` |
| HAS_VULNERABILITY | Subdomain | Vulnerability | `SHA256(subdomain_key + "→VULN→" + vuln_key)[:32]` |
| LINKS_TO | Subdomain | Subdomain | `SHA256(source_subdomain_key + "→LINK→" + target_subdomain_key)[:32]` |
| SAN_PEER | Subdomain | Subdomain | `SHA256(MIN(a_key,b_key) + "→SAN→" + MAX(a_key,b_key))[:32]` |
| CNAME_TO | Subdomain | Subdomain | `SHA256(alias_key + "→CNAME→" + target_key)[:32]` |

**SAN_PEER symmetry:** SAN relationships are undirected (A peers with B = B peers with A). Using MIN/MAX of the two keys ensures the relationship key is the same regardless of which direction is created first.

**RESOLVES_TO includes batch_id:** DNS resolution is a time-bound observation. Including batch_id in the relationship key allows the same (subdomain, IP) pair to be recorded again in a later batch without dedup collision — enabling historical tracking. The Subdomain node's `a_records[]` property is updated (SET +=) on each scan.

---

## Cross-Store Reconciliation

### Purpose

ClickHouse stores every ingest event as a row. Neo4j stores the current canonical entity state. Reconciliation verifies they agree.

### Reconciliation Query Pattern

```sql
-- ClickHouse: count unique fqdns ingested since last reconciliation (use FINAL)
SELECT COUNT(DISTINCT fqdn) FROM dns_scan_log FINAL
WHERE batch_id IN (<recent_batch_ids>);

-- Neo4j: count Subdomain nodes with matching batch reference
MATCH (n:Subdomain) WHERE n.ingested_batch_id IN <recent_batch_ids>
RETURN COUNT(n);
```

**Mismatch threshold:** Neo4j count within ±0.5% of ClickHouse count = PASS. > 0.5% difference = ALERT.

**Reconciliation cadence:** After every ingest batch completion (not per-record). Batch = one AWSEM chunk.

### 30-Second Settle Delay

ClickHouse background merge must complete before FINAL query reflects the correct state. Always wait 30s after last INSERT in a batch before running reconciliation. Add 60s buffer if ORS reports clickhouse_parts_per_table > 300.

---

## Wildcard DNS Detection Protocol

Wildcard DNS inflates the corpus by resolving all probed subdomains. Detection prevents ingesting millions of phantom subdomains.

**Detection algorithm:**
```
FOR each root domain D in corpus:
  probes = [random_uuid() + "." + D for _ in range(5)]
  results = dns_resolve(probes)
  if all(r.a_records == results[0].a_records for r in results):
    mark D.wildcard = True
    filter out any FQDN matching *.D from ingest queue (except explicitly known valid subdomains)
```

**Execution:** Run once per root domain at corpus load. Re-run if DNS results for a domain start resolving unexpectedly (ORS signal: `unexpected_resolution_rate_spike`).

---

## Validation Suite

### Test 1: Dedup Key Uniqueness
- Generate 100k FQDNs from synthetic corpus
- Compute dedup keys for all
- Assert: zero SHA256 collisions

### Test 2: Cross-Entity Prefix Isolation
- Generate dedup keys for identical string values across entity types
- Assert: `SHA256("domain:example.com")` ≠ `SHA256("subdomain:example.com")` (different prefix)

### Test 3: Replay Idempotency
- Ingest same batch of 10k records twice
- Assert: Neo4j node count unchanged; ClickHouse FINAL count unchanged; no new relationships created

### Test 4: CNAME Alias Isolation
- Ingest one alias FQDN and one target FQDN with CNAME relationship
- Assert: two distinct Subdomain nodes; one CNAME_TO relationship

### Test 5: Wildcard Suppression
- Configure a domain with wildcard DNS
- Run ingest pipeline against 1k synthetic FQDNs under that domain
- Assert: zero new Subdomain nodes ingested for wildcard FQDNs

### Test 6: Link Precision
- Create 1k known (subdomain, IP) pairs
- Ingest via DNS parser
- Assert: ≥ 99% of (subdomain, IP) links present in Neo4j as RESOLVES_TO relationships
- Assert: zero links between incorrect (subdomain, IP) pairs

### Test 7: Reconciliation Accuracy
- Ingest 10k records
- Run reconciliation after 30s settle
- Assert: Neo4j count within ±0.5% of ClickHouse FINAL count

---

## Tradeoffs

| Decision | Chosen | Rejected | Rationale |
|----------|--------|----------|-----------|
| Entity-type prefix in dedup key | ✅ | No prefix | Prevents cross-type key collision; `domain:example.com` and `subdomain:example.com` are distinct |
| CNAME aliases as distinct nodes | ✅ | Collapse to target | Alias and target can have distinct ownership, findings, and KRIL scores. Collapsing would corrupt analyst attribution |
| Relationship key includes batch_id for RESOLVES_TO | ✅ | Strict (fqdn, ip) dedup | DNS resolution is time-bound; IP assignments change. Batch_id in rel key enables historical tracking while still deduplicating within-batch |
| SAN_PEER as MIN/MAX key | ✅ | Directed key | SAN relationship is undirected. Directed key would require checking both directions on every insert. MIN/MAX ensures structural idempotency |
| Wildcard suppression at load time | ✅ | Filter at parse time | Corpus-level wildcard detection prevents sending millions of phantom FQDNs to Oracle. Filtering at parse time is too late; wasteful Oracle resources |
| Conservative phantom-collapse over phantom-duplication | ✅ | Aggressive merge | At 10M scale, wrong merge corrupts graph topology irreversibly. A phantom duplicate is visible and deletable. A wrong merge hides relationships. |

---

## Risks

| ID | Title | Severity | Probability | Mitigation |
|----|-------|----------|-------------|------------|
| R1 | Wildcard inflation before detection | HIGH | MEDIUM | Run wildcard detection before queue dispatch; ORS monitors unexpected_resolution_rate_spike |
| R2 | Dynamic body_hash causing false dedup misses | MEDIUM | MEDIUM | Flag dynamic content on first hash change; never update body_hash for dynamic endpoints |
| R3 | Multi-level eTLD extraction failures | MEDIUM | LOW | Use PSL (public suffix list) library; unit test against known multi-level eTLDs (co.uk, com.au) |
| R4 | RESOLVES_TO relationship explosion (high-rotation IPs) | MEDIUM | LOW | Relationship key includes batch_id — but archived relationships accumulate. Implement relationship pruning for stale > 90d RESOLVES_TO (not destructive mutation — archival flag) |
| R5 | Reconciliation false positive (ClickHouse merge lag) | LOW | MEDIUM | 30s settle delay; extend to 60s if clickhouse_parts_per_table > 300 |

---

## Recommendations

| Priority | ID | Action |
|----------|-----|--------|
| 1 | REC-01 | Implement wildcard DNS detection as corpus pre-processing step before first scan dispatch |
| 2 | REC-02 | Use public suffix list (PSL) library for eTLD+1 extraction — do not implement custom split logic |
| 3 | REC-03 | Store dedup key as `key_hash` property on every Neo4j node — enables fast lookup and post-hoc audit |
| 4 | REC-04 | Run all 7 validation suite tests before first production write; add as pre-operation checklist |
| 5 | REC-05 | Implement SAN_PEER relationship creation from TLS certificate SAN fields (passive corpus expansion + relationship enrichment) |
| 6 | REC-06 | Set reconciliation cadence to per-batch (not per-record and not per-hour) for accurate mismatch detection |
| 7 | REC-07 | Flag `dynamic_content: true` on HTTPEndpoints where body_hash changes between two consecutive probes |
| 8 | REC-08 | Implement CNAME_TO relationship creation from DNS CNAME chain records in dnsx output |

---

## Assumptions

- **A1:** eTLD+1 extraction uses the Mozilla Public Suffix List; PSL library available as dependency
- **A2:** dnsx output includes full CNAME chain, allowing CNAME_TO relationship construction
- **A3:** ClickHouse tables use ReplacingMergeTree(version) where version = Unix timestamp of ingest
- **A4:** 30s settle delay is sufficient for ClickHouse background merge on batches of ≤ 100k rows; extend for larger batches
- **A5:** Wildcard detection runs per root domain at corpus load; estimated cost: 5 DNS queries per domain × domain count in corpus
- **A6:** SHA256 prefix-tagged keys at 32 hex characters provide sufficient uniqueness for 10M+ entities (collision probability ≪ 1 in 10^30)

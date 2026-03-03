# ARTIFACT: WO-00010
# Parser Contracts for Multi-Tool JSON Outputs

**Analyst:** OpenClaw Field Processor
**Work Order:** WO-00010
**Category:** Research
**Priority:** High
**Date:** 2026-03-03
**Status:** COMPLETED
**ARD Mode:** RESEARCH — EXPANSIVE (controlled)

---

## Executive Summary

WO-00010 delivers robust parser contracts for dnsx, httpx, nuclei, and katana — the four scan tools that produce structured JSON outputs consumed by the ingest pipeline. Each parser contract covers: expected schema, required/optional fields, normalization transforms, dedup key construction, schema version detection, malformed record quarantine protocol, and known tool output quirks.

**Success metrics targeted:**
- Parser success ≥ 99% of valid records
- Malformed quarantine coverage 100%
- Schema migration policy defined

---

## Context Understanding

**Pipeline position:** Parsers sit between Oracle tool output files and the Controller ingest layer. They are the single normalization surface — anything that does not pass parser validation must be quarantined before touching Neo4j or ClickHouse.

**Scale:** 10M+ subdomains, continuous batch pipeline. Parser must handle high throughput without becoming a bottleneck.

**Design philosophy:** Fail loudly on schema violations — do not silently coerce malformed data into partially valid records. Every quarantine event is an observable signal.

---

## Parser Design Principles

### P1: Strict-then-quarantine

Parser first attempts full schema validation. On any required field missing, type mismatch, or normalization failure: quarantine the record with reason code. Never silently drop or partially ingest.

### P2: Required vs. optional field contract

Every parser defines a clear required/optional split:
- **Required:** Missing = quarantine
- **Optional:** Missing = null/default; absence is acceptable and documented

### P3: Schema version detection

Tool output schemas evolve with tool upgrades. Every parser must detect the schema version from the output structure and route to the correct parse path. Version is detected from field presence patterns (not a version header — most tools don't emit one).

### P4: Idempotent normalization

Running normalization twice on the same input must produce the same output. No random components (timestamps from parser execution, UUIDs generated mid-parse) are added during normalization.

### P5: Single entry point for FQDN normalization

All parsers call the same `normalize_fqdn(fqdn)` function. No inline FQDN normalization logic in individual parsers.

### P6: Quarantine completeness

Quarantine record includes: original raw record, batch_id, chunk_id, parser_name, schema_version_detected, quarantine_reason_code, quarantine_at. Enables post-hoc forensic analysis of all rejected records.

---

## Parser Contract: dnsx

**Tool:** dnsx (DNS resolver and enumerator)
**Output format:** NDJSON (one JSON object per line per resolved FQDN)
**Typical output rate:** 700k+ resolutions/hour at 250 concurrent

### Expected Schema (v1)

```json
{
  "host": "api.example.com",
  "resolver": "8.8.8.8:53",
  "a": ["1.2.3.4", "1.2.3.5"],
  "aaaa": [],
  "cname": ["cdn.example.net"],
  "mx": [],
  "ns": ["ns1.example.com"],
  "txt": [],
  "ptr": [],
  "status_code": "NOERROR",
  "timestamp": "2026-03-03T00:00:00.000Z"
}
```

### Field Contract

| Field | Type | Required | Normalization | Notes |
|-------|------|----------|---------------|-------|
| `host` | String | YES | `normalize_fqdn()` | Primary identity — quarantine if absent or empty |
| `a` | String[] | NO | Sort, deduplicate | Empty array if no A records |
| `aaaa` | String[] | NO | Sort, deduplicate, compress IPv6 | Empty array if no AAAA records |
| `cname` | String[] | NO | `normalize_fqdn()` on each | CNAME chain; first element is immediate target |
| `mx` | String[] | NO | Parse priority+host | Format: `"10 mail.example.com"` |
| `ns` | String[] | NO | `normalize_fqdn()` on each | Authoritative NS records |
| `txt` | String[] | NO | No normalization | Raw TXT records |
| `ptr` | String[] | NO | `normalize_fqdn()` on each | PTR records |
| `status_code` | String | NO | Uppercase | `NOERROR`, `NXDOMAIN`, `SERVFAIL`, etc. |
| `timestamp` | String | NO | Parse ISO8601 → UTC DateTime | Used for `last_seen` |

### Computed Fields

| Field | Formula |
|-------|---------|
| `resolved` | `len(a) > 0 OR len(aaaa) > 0` |
| `dedup_key` | `SHA256("subdomain:" + host.lower().rstrip('.'))[:32]` |
| `batch_id` | Injected by AWSEM task metadata (not from tool output) |
| `scanned_at` | `timestamp` parsed, or ingest_time if absent |

### Schema Version Detection

| Indicator | Version | Action |
|-----------|---------|--------|
| `host` field present | v1 (current) | Standard parse path |
| `name` field instead of `host` | v0 (legacy) | Remap `name` → `host`; continue parse |
| Neither `host` nor `name` | unknown | Quarantine with `SCHEMA_UNKNOWN` |

### Known Tool Quirks

- **NXDOMAIN records:** dnsx may output NXDOMAIN results (unresolved FQDNs). `status_code = "NXDOMAIN"` → set `resolved = false`; ingest as unresolved Subdomain (useful to track that it was probed).
- **Empty arrays vs. absent fields:** dnsx sometimes omits `"a": []` entirely instead of emitting an empty array. Parser must treat absent array fields as empty (not as missing required fields).
- **Wildcard records:** If `a` records match previously detected wildcard IPs for the parent domain, flag `wildcard_hit: true` and quarantine from ingest (not a real subdomain).
- **SERVFAIL vs. NXDOMAIN:** SERVFAIL indicates infrastructure issue, not non-existence. Do NOT set `resolved = false` for SERVFAIL — the subdomain may exist but DNS is temporarily broken. Queue for retry.

### Quarantine Reason Codes (dnsx)

| Code | Condition |
|------|-----------|
| `DNS_MISSING_HOST` | `host` field absent or empty |
| `DNS_INVALID_FQDN` | Host is not a valid FQDN |
| `DNS_WILDCARD_HIT` | A records match detected wildcard IPs |
| `DNS_SCHEMA_UNKNOWN` | Neither `host` nor `name` field present |
| `DNS_JSON_PARSE_ERROR` | Line is not valid JSON |

---

## Parser Contract: httpx

**Tool:** httpx (HTTP prober and web fingerprinter)
**Output format:** NDJSON
**Typical output rate:** 50k probes/hour at 75 concurrent

### Expected Schema (v1)

```json
{
  "timestamp": "2026-03-03T00:00:00.000Z",
  "url": "https://api.example.com/",
  "host": "api.example.com",
  "port": "443",
  "scheme": "https",
  "path": "/",
  "method": "GET",
  "status_code": 200,
  "content_length": 4096,
  "content_type": "application/json",
  "title": "API Gateway",
  "body": null,
  "headers": {
    "server": "nginx/1.24.0",
    "x-powered-by": "Express"
  },
  "words": 42,
  "lines": 10,
  "a": ["1.2.3.4"],
  "final_url": "https://api.example.com/",
  "redirect_chain": [],
  "failed": false,
  "no_color": true
}
```

### Field Contract

| Field | Type | Required | Normalization | Notes |
|-------|------|----------|---------------|-------|
| `url` | String | YES | URL canonicalization (see WO-00009) | Quarantine if absent |
| `host` | String | YES | `normalize_fqdn()` | Quarantine if absent |
| `status_code` | Integer | YES | As-is | Quarantine if absent or non-integer |
| `content_length` | Integer | NO | As-is | -1 if not provided |
| `content_type` | String | NO | Lowercase; strip parameters | `"application/json; charset=utf-8"` → `"application/json"` |
| `title` | String | NO | Strip whitespace | HTML title text |
| `headers` | Object | NO | Lowercase all keys | Header names case-insensitive per RFC |
| `a` | String[] | NO | Sort, deduplicate | Resolved IP addresses of host |
| `final_url` | String | NO | URL canonicalization | After redirect chain |
| `redirect_chain` | String[] | NO | As-is | Ordered redirect steps |
| `failed` | Boolean | NO | As-is | True if request failed entirely |

### Computed Fields

| Field | Formula |
|-------|---------|
| `fqdn` | `host` normalized |
| `ip` | First element of `a[]`, or null |
| `body_hash` | `SHA256(response_body_bytes)` if body available; null otherwise |
| `dedup_key` | `SHA256("http:" + fqdn + "\|" + canonical_url + "\|GET")[:32]` |
| `responded_at` | `timestamp` parsed to UTC |

### Schema Version Detection

| Indicator | Version | Action |
|-----------|---------|--------|
| `url` + `host` + `status_code` present | v1 (current) | Standard path |
| `input` field instead of `host` | v0 (legacy) | Remap `input` → `host` |
| `failed: true` AND `status_code` absent | Error record | Parse as failed probe; don't quarantine |

### Known Tool Quirks

- **`body` field:** httpx v1.2+ can emit `body` in the output if `--include-response-body` flag is used. This produces very large NDJSON lines. Parser must handle absent `body` (default) and present `body` (with configurable max size limit).
- **`content_length: -1`:** httpx emits -1 when server sends Transfer-Encoding: chunked. Treat as unknown length; do not quarantine.
- **`failed: true` records:** httpx emits a record with `failed: true` when a connection fails. These are valid records — they represent a probed FQDN that returned no HTTP response. Ingest as `HTTPEndpoint` with `status_code: null` and `failed: true`.
- **Port in URL vs. port field:** `url: "https://api.example.com:8443/"` and `port: "8443"` should both be parsed; canonical URL should preserve non-standard port.
- **Redirect chain inconsistency:** httpx sometimes includes the original URL in `redirect_chain[0]`. Deduplicate against `url` field to avoid self-referencing redirect.

### Quarantine Reason Codes (httpx)

| Code | Condition |
|------|-----------|
| `HTTP_MISSING_URL` | `url` field absent or empty |
| `HTTP_MISSING_HOST` | `host` field absent or empty |
| `HTTP_MISSING_STATUS` | `status_code` absent (for non-failed records) |
| `HTTP_INVALID_STATUS` | `status_code` is not an integer |
| `HTTP_BODY_TOO_LARGE` | Response body exceeds configured max (50MB) |
| `HTTP_JSON_PARSE_ERROR` | Line is not valid JSON |
| `HTTP_SCHEMA_UNKNOWN` | Cannot detect schema version |

---

## Parser Contract: nuclei

**Tool:** nuclei (vulnerability template scanner)
**Output format:** NDJSON
**Typical output rate:** 5k targets/hour at 25 concurrent; findings rate: ~50/hour

### Expected Schema (v1)

```json
{
  "template-id": "CVE-2023-12345",
  "template-path": "/nuclei-templates/cves/2023/CVE-2023-12345.yaml",
  "template": {
    "id": "CVE-2023-12345",
    "name": "CVE-2023-12345 - Remote Code Execution",
    "severity": "critical",
    "description": "...",
    "reference": ["https://nvd.nist.gov/vuln/detail/CVE-2023-12345"],
    "classification": {
      "cvss-metrics": "CVSS:3.1/AV:N/AC:L...",
      "cvss-score": 9.8,
      "cve-id": "CVE-2023-12345"
    },
    "tags": ["cve", "rce", "apache"]
  },
  "host": "https://api.example.com",
  "matched-at": "https://api.example.com/endpoint",
  "request": "GET /endpoint HTTP/1.1\r\n...",
  "response": "HTTP/1.1 200 OK\r\n...",
  "ip": "1.2.3.4",
  "timestamp": "2026-03-03T00:00:00.000Z",
  "type": "http",
  "matcher-name": "status",
  "extracted-results": ["admin"],
  "curl-command": "curl -X GET ..."
}
```

### Field Contract

| Field | Type | Required | Normalization | Notes |
|-------|------|----------|---------------|-------|
| `template-id` | String | YES | As-is | Quarantine if absent |
| `host` | String | YES | Extract FQDN from URL | `https://api.example.com` → `api.example.com` |
| `matched-at` | String | YES | URL canonicalization | Specific URL where finding was confirmed |
| `template.severity` | String | YES | Lowercase | `critical`, `high`, `medium`, `low`, `info` |
| `timestamp` | String | YES | Parse ISO8601 → UTC | Quarantine if absent |
| `template.classification.cvss-score` | Float | NO | As-is | null if absent |
| `ip` | String | NO | Normalize IP | null if absent |
| `extracted-results` | String[] | NO | As-is | Values extracted by template matchers |
| `request` | String | NO | Truncate to 4KB | Raw HTTP request |
| `response` | String | NO | Truncate to 4KB | Raw HTTP response |

### Computed Fields

| Field | Formula |
|-------|---------|
| `fqdn` | FQDN extracted from `host` URL |
| `severity_int` | `info=0, low=1, medium=2, high=3, critical=4` |
| `finding_class` | Derived from template tags (see classification table below) |
| `evidence_hash` | `SHA256(matched_at + template_id + (extracted_results or ""))[:32]` |
| `dedup_key` | `SHA256("vuln:" + fqdn + "\|" + template_id + "\|" + evidence_hash)[:32]` |

### Finding Class Classification

| Tags Present | finding_class |
|-------------|--------------|
| `cve` | `vulnerability_cve` |
| `misconfig` | `misconfiguration` |
| `exposure` | `exposure` |
| `default-login` | `default_credential` |
| `injection` | `injection` |
| `xss` | `injection` |
| `sqli` | `injection` |
| `takeover` | `takeover` |
| `tech` | `technology_disclosure` |
| (none matched) | `unclassified` |

### Schema Version Detection

| Indicator | Version | Action |
|-----------|---------|--------|
| `template-id` + `template.severity` | v2+ (current) | Standard path |
| `templateID` (camelCase) | v1 (legacy) | Remap fields; continue |
| Neither present | unknown | Quarantine with `NUCLEI_SCHEMA_UNKNOWN` |

### Known Tool Quirks

- **`request`/`response` fields size:** nuclei can include full raw HTTP request and response. These can be 10KB+ per finding. Parser MUST truncate to 4KB each before storing in evidence. Store truncation flag.
- **Multiple findings per run:** nuclei can fire multiple templates on the same target in one run. Each finding is a separate NDJSON line — correct behavior.
- **Informational findings flood:** `severity: info` findings are extremely high volume (tech stack disclosure, etc.). Consider filtering `info` findings by KRIL score threshold at parser level — only ingest `info` findings for targets with KRIL ≥ 50.
- **Template path vs. template ID:** Template path includes version directory (`/2023/`). Use `template-id` (not path) as the canonical identifier — paths change across template updates.
- **Missing classification block:** Older templates may not include `template.classification`. Parser must handle absent classification gracefully — set `cvss: null`, `cve_id: null`.

### Quarantine Reason Codes (nuclei)

| Code | Condition |
|------|-----------|
| `NUCLEI_MISSING_TEMPLATE_ID` | `template-id` field absent |
| `NUCLEI_MISSING_HOST` | `host` field absent |
| `NUCLEI_MISSING_SEVERITY` | `template.severity` absent |
| `NUCLEI_MISSING_TIMESTAMP` | `timestamp` absent |
| `NUCLEI_INVALID_SEVERITY` | severity not in allowed set |
| `NUCLEI_SCHEMA_UNKNOWN` | Cannot detect schema version |
| `NUCLEI_JSON_PARSE_ERROR` | Line is not valid JSON |

---

## Parser Contract: katana

**Tool:** katana (web crawler)
**Output format:** NDJSON
**Typical output rate:** Crawl depth-dependent; ~1k URLs/hour per target

### Expected Schema (v1)

```json
{
  "timestamp": "2026-03-03T00:00:00.000Z",
  "request": {
    "method": "GET",
    "endpoint": "https://api.example.com/dashboard",
    "raw": "GET /dashboard HTTP/1.1\r\n..."
  },
  "response": {
    "status_code": 200,
    "headers": {"content-type": "text/html"},
    "body": "<html>...</html>",
    "technologies": ["React", "nginx"]
  },
  "source": "https://api.example.com/",
  "depth": 1
}
```

### Field Contract

| Field | Type | Required | Normalization | Notes |
|-------|------|----------|---------------|-------|
| `request.endpoint` | String | YES | URL canonicalization | The crawled URL — quarantine if absent |
| `request.method` | String | NO | Uppercase | Default `GET` if absent |
| `response.status_code` | Integer | NO | As-is | null if absent |
| `response.technologies` | String[] | NO | As-is | Tech stack fingerprints from Wappalyzer |
| `source` | String | NO | URL canonicalization | Parent URL that linked to this URL |
| `depth` | Integer | NO | As-is | Crawl depth from seed |
| `timestamp` | String | NO | Parse ISO8601 → UTC | |

### Computed Fields

| Field | Formula |
|-------|---------|
| `fqdn` | `normalize_fqdn(extract_host(request.endpoint))` |
| `canonical_url` | `canonicalize_url(request.endpoint)` |
| `source_fqdn` | `normalize_fqdn(extract_host(source))` if source present |
| `cross_origin` | `fqdn != source_fqdn` — true if crawl discovered a link to a different domain |
| `dedup_key` | `SHA256("http:" + fqdn + "\|" + canonical_url + "\|" + method)[:32]` |

### Entity Output

katana output is used for:
1. **HTTPEndpoint enrichment:** Add discovered URLs as HTTPEndpoint nodes linked to parent Subdomain
2. **LINKS_TO relationship:** If `cross_origin = false`, create `(source_subdomain)-[:LINKS_TO]->(target_subdomain)` for cross-page links within same domain
3. **Technology disclosure:** Store `technologies` on Subdomain node property `technologies[]`

### Schema Version Detection

| Indicator | Version | Action |
|-----------|---------|--------|
| `request.endpoint` present | v1 (current) | Standard path |
| `url` field at root (no `request` wrapper) | v0 (legacy) | Remap; extract `url` as endpoint |
| Neither present | unknown | Quarantine |

### Known Tool Quirks

- **Binary content URLs:** katana may crawl binary files (PDFs, images). URLs pointing to binary content produce large `response.body` fields. Parser MUST check `content-type` header; if binary content type → skip body; still ingest URL as HTTPEndpoint.
- **Cross-origin crawl:** If katana discovers links to external domains (scope escape), those external FQDNs should be noted but NOT ingested as Subdomain nodes (unless they are in scope). Flag `out_of_scope: true` on cross-origin HTTPEndpoints.
- **Duplicate URL discovery:** katana may visit the same URL multiple times at different depths. Dedup key (fqdn + canonical_url + method) handles this — idempotent ingest via MERGE.
- **JavaScript-rendered content:** katana uses a headless browser; URLs discovered via JS execution may have query strings or fragments that need strict canonicalization to avoid dedup explosion.

### Quarantine Reason Codes (katana)

| Code | Condition |
|------|-----------|
| `KATANA_MISSING_ENDPOINT` | `request.endpoint` absent |
| `KATANA_INVALID_URL` | URL is not parseable |
| `KATANA_SCHEMA_UNKNOWN` | Cannot detect schema version |
| `KATANA_JSON_PARSE_ERROR` | Line is not valid JSON |

---

## Schema Versioning and Migration Policy

### Version Detection Strategy

Parsers detect schema version by field presence patterns, not a version header field. This is because none of the four tools emit a formal schema version in their output.

**Version detection algorithm:**
```
def detect_schema_version(record, tool):
    if tool == "dnsx":
        if "host" in record:    return "v1"
        if "name" in record:    return "v0"
        return "unknown"
    if tool == "httpx":
        if "url" in record and "host" in record:   return "v1"
        if "input" in record:                       return "v0"
        return "unknown"
    if tool == "nuclei":
        if "template-id" in record:   return "v2"
        if "templateID" in record:    return "v1"
        return "unknown"
    if tool == "katana":
        if "request" in record and "endpoint" in record["request"]:  return "v1"
        if "url" in record:                                          return "v0"
        return "unknown"
```

### Schema Migration Rules

| Tool | Old Version | New Version | Migration |
|------|------------|-------------|-----------|
| dnsx | v0 (`name`) | v1 (`host`) | `record["host"] = record.pop("name")` |
| httpx | v0 (`input`) | v1 (`host`) | `record["host"] = record.pop("input")` |
| nuclei | v1 (`templateID`) | v2 (`template-id`) | `record["template-id"] = record.pop("templateID")` |
| katana | v0 (`url`) | v1 (`request.endpoint`) | `record["request"] = {"endpoint": record.pop("url"), "method": "GET"}` |

**Migration principle:** Migrations are always additive remaps — never destructive. Original field name consumed; target field populated. If migration produces an invalid state, quarantine with `MIGRATION_FAILED` reason.

### Forward Compatibility Rule

When a new tool version adds previously unknown fields:
- Parser MUST accept and ignore unknown optional fields without quarantining
- Parser must NOT reject records for having extra fields
- Schema version is bumped only when required fields change or existing field semantics change

---

## Quarantine Protocol

### Quarantine Record Format

```json
{
  "quarantine_id": "SHA256(batch_id + chunk_id + record_line_num)[:16]",
  "batch_id": "abc123",
  "chunk_id": "def456",
  "parser_name": "dnsx_parser_v1",
  "schema_version_detected": "v1",
  "quarantine_reason_code": "DNS_MISSING_HOST",
  "quarantine_at": "2026-03-03T00:05:00Z",
  "original_record": { /* raw parsed JSON or null if JSON parse failed */ },
  "original_line": "raw_line_string_if_json_failed"
}
```

### Quarantine Storage

- Location: `artifacts/quarantine/{batch_id}/{chunk_id}.ndjson`
- Retention: 14 days minimum; 30 days recommended
- Write mode: Append-only (never overwrite existing quarantine records)
- ORS signal: `quarantine_event_count` per batch; WARNING if > 100/batch; CRITICAL if > 1% of batch

### Quarantine Monitoring

| Signal | Threshold | Action |
|--------|-----------|--------|
| `quarantine_events_per_batch` | > 100 | WARNING to Mattermost |
| `quarantine_rate_pct` | > 1% of batch | CRITICAL; investigate parser |
| `quarantine_reason_code_new` | First occurrence of new code | ALERT; may indicate tool upgrade |
| `json_parse_error_rate_pct` | > 0.1% of lines | CRITICAL; may indicate Oracle output corruption |

### Quarantine Review Process

1. ORS alerts on quarantine threshold breach
2. Analyst reviews quarantine records in `artifacts/quarantine/`
3. If systematic (many same reason code): update parser contract; re-process from quarantine after fix
4. If isolated (< 5 records same code): accept as data quality noise; archive

---

## Performance Characteristics

### Parser Throughput Targets

| Parser | Input Rate | Target Parse Rate | Bottleneck Risk |
|--------|-----------|-------------------|----------------|
| dnsx_parser_v1 | 700k records/hr | 800k records/hr | LOW — simple field mapping |
| httpx_parser_v1 | 50k records/hr | 100k records/hr | MEDIUM — URL canonicalization overhead |
| nuclei_parser_v1 | 50 findings/hr | 1k records/hr | LOW — low volume |
| katana_parser_v1 | 1k URLs/hr per target | 10k records/hr | LOW — low volume |

**Bottleneck mitigation:**
- dnsx and httpx parsers: process in parallel (separate goroutines/threads per chunk)
- URL canonicalization: cache canonical form for same raw URL within a batch (avoid redundant computation)
- Body hash computation: use streaming SHA256 (no need to buffer full response body into memory)

### Memory Constraints

- Max record buffer per parse call: 10MB
- Max line size: 1MB (reject lines exceeding this as malformed)
- Streaming NDJSON parse: do not load full file into memory; parse line-by-line

---

## Implementation Scaffolds

### Python Reference Implementation (dnsx_parser_v1)

```python
import json, hashlib, datetime
from typing import Optional

def normalize_fqdn(fqdn: str) -> Optional[str]:
    if not fqdn:
        return None
    return fqdn.lower().rstrip('.')

def compute_dedup_key(entity_type: str, *components: str) -> str:
    raw = entity_type + ":" + "|".join(c.lower() for c in components)
    return hashlib.sha256(raw.encode()).hexdigest()[:32]

def parse_dnsx_record(raw_line: str, batch_id: str, chunk_id: str) -> dict:
    try:
        record = json.loads(raw_line)
    except json.JSONDecodeError as e:
        return quarantine(None, raw_line, batch_id, chunk_id, "dnsx_parser_v1", "DNS_JSON_PARSE_ERROR", str(e))

    schema_version = detect_dnsx_schema(record)
    if schema_version == "v0":
        record["host"] = record.pop("name")
    elif schema_version == "unknown":
        return quarantine(record, raw_line, batch_id, chunk_id, "dnsx_parser_v1", "DNS_SCHEMA_UNKNOWN", "no host or name field")

    fqdn = normalize_fqdn(record.get("host", ""))
    if not fqdn:
        return quarantine(record, raw_line, batch_id, chunk_id, "dnsx_parser_v1", "DNS_MISSING_HOST", "empty fqdn")

    a_records = sorted(set(record.get("a", [])))
    aaaa_records = sorted(set(record.get("aaaa", [])))

    return {
        "entity": "Subdomain",
        "fqdn": fqdn,
        "a_records": a_records,
        "aaaa_records": aaaa_records,
        "cname_chain": [normalize_fqdn(c) for c in record.get("cname", []) if c],
        "resolved": len(a_records) > 0 or len(aaaa_records) > 0,
        "status_code": record.get("status_code", "").upper() or None,
        "scanned_at": parse_timestamp(record.get("timestamp")),
        "dedup_key": compute_dedup_key("subdomain", fqdn),
        "batch_id": batch_id,
        "quarantine": False
    }

def detect_dnsx_schema(record: dict) -> str:
    if "host" in record: return "v1"
    if "name" in record: return "v0"
    return "unknown"
```

---

## Tradeoffs

| Decision | Chosen | Rejected | Rationale |
|----------|--------|----------|-----------|
| Schema version by field presence | ✅ | Version header field | Tools don't emit version headers. Field presence detection is universally applicable. |
| Strict-then-quarantine | ✅ | Silent coercion | Silently coercing malformed records produces corrupt ingest data. Quarantine preserves forensic record of all data quality issues. |
| Truncate request/response to 4KB | ✅ | Store full raw | Full nuclei request/response can be 50KB+ per finding. At 50 findings/hour over 72h = 50MB of raw HTTP in the graph — unnecessary and query-expensive. 4KB preserves sufficient context. |
| NDJSON line-by-line streaming | ✅ | Load file then parse | Tools produce files up to 100MB per batch. Loading entire file into memory before parsing exhausts Controller RAM. Streaming maintains O(1) memory usage. |
| Info-severity KRIL gate | ✅ | Ingest all severity levels | Nuclei produces thousands of `info` findings (tech disclosure) per run. Gating on KRIL ≥ 50 reduces noise by ~70% for low-value assets while preserving findings for high-value targets. |

---

## Risks

| ID | Title | Severity | Probability | Mitigation |
|----|-------|----------|-------------|------------|
| R1 | Tool upgrade breaks schema silently | HIGH | MEDIUM | Version detection catches v0→v1 transitions; new unknown schemas quarantine; ORS alerts on new quarantine reason codes |
| R2 | Nuclei response body size causes memory spike | HIGH | MEDIUM | Truncate response to 4KB at parse time; never buffer full body |
| R3 | URL canonicalization edge cases (encoded chars, IDN) | MEDIUM | MEDIUM | Use battle-tested URL library (urllib.parse or equivalent); don't implement custom canonicalization |
| R4 | katana JS-rendered URL dedup explosion | MEDIUM | LOW | Strict URL canonicalization including query param normalization; session-scoped dedup cache within AWSEM chunk |
| R5 | High quarantine rate masking systematic parser bug | MEDIUM | LOW | ORS alert on quarantine_rate > 1%; new reason code alert for first-occurrence detection |

---

## Recommendations

| Priority | ID | Action |
|----------|-----|--------|
| 1 | REC-01 | Implement single shared `normalize_fqdn()` and `canonicalize_url()` functions called by all four parsers |
| 2 | REC-02 | Use streaming NDJSON parse (line-by-line) — never load full file into memory |
| 3 | REC-03 | Add `quarantine_reason_code` ORS monitor with first-occurrence alerting for new codes |
| 4 | REC-04 | Truncate nuclei `request` and `response` fields to 4KB at parse time; store `evidence_truncated: true` flag |
| 5 | REC-05 | Gate nuclei `info` findings by KRIL score ≥ 50; configurable threshold in parser config |
| 6 | REC-06 | Run all 4 parser contracts against synthetic malformed inputs as pre-deployment test suite |
| 7 | REC-07 | Use established URL library (not custom) for canonicalization — IDN, percent-encoding, and port normalization have well-known edge cases |
| 8 | REC-08 | Set `max_line_size_bytes = 1048576` (1MB); lines exceeding this are quarantined as `OVERSIZED_RECORD` |

---

## Validation Strategy

| Check | Method | Pass Condition |
|-------|--------|---------------|
| dnsx parser — valid record | Parse synthetic valid NDJSON | All required fields extracted; dedup key correct |
| dnsx parser — missing host | Parse record without `host` | Quarantined with `DNS_MISSING_HOST` |
| dnsx parser — v0 schema | Parse record with `name` field | Remapped to `host`; parsed successfully |
| httpx parser — URL canonicalization | Parse URL with fragment, tracking params, unsorted query | Canonical URL matches expected |
| nuclei parser — classification | Parse records with each tag set | `finding_class` assigned correctly |
| nuclei parser — truncation | Parse record with 10KB response field | Stored as 4KB; `evidence_truncated: true` |
| katana parser — cross-origin | Parse record linking to external domain | `cross_origin: true`; not ingested as Subdomain |
| All parsers — JSON parse error | Inject non-JSON line | Quarantined with `JSON_PARSE_ERROR` |
| Quarantine record format | Verify quarantine record structure | All required quarantine fields present |
| Idempotency | Parse same record twice | Same output both times |

---

## KPIs

| KPI | Target |
|-----|--------|
| Parser success rate | ≥ 99% of valid records pass |
| Quarantine coverage | 100% of malformed records quarantined |
| JSON parse error rate | < 0.1% of lines |
| dnsx parse throughput | ≥ 800k records/hour |
| httpx parse throughput | ≥ 100k records/hour |
| URL canonicalization correctness | 100% pass against test vector suite |
| Schema version detection accuracy | 100% correct for v0 and v1 schemas |

---

## Assumptions

- **A1:** All four tools output NDJSON format (one JSON object per line); no multi-line JSON
- **A2:** Tool output files are complete before parser starts; atomic file move from temp dir guarantees this
- **A3:** NDJSON files may be up to 100MB per batch; streaming parse is required
- **A4:** URL canonicalization library handles IDN (internationalized domain names) correctly
- **A5:** nuclei template tags are the primary source for `finding_class` classification; template taxonomy may evolve
- **A6:** katana headless browser JavaScript execution may produce URLs with dynamic query parameters; canonicalization must normalize these
- **A7:** `info` severity gate (KRIL ≥ 50) threshold is configurable; default is conservative (50) but can be lowered for full corpus coverage

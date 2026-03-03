# ARTIFACT: WO-00003
# Senior Integrity Audit — Neo4j + ClickHouse Dual-Ingest Contracts

**Analyst:** OpenClaw Field Processor
**Work Order:** WO-00003
**Category:** Audit
**Priority:** High
**Date:** 2026-03-03
**Status:** COMPLETED

---

## Executive Summary

WO-00003 is a senior integrity audit of a dual-write ingest system — controller-managed, serving two datastores (Neo4j graph, ClickHouse telemetry) — operating over a 10M+ subdomain corpus at parallel write concurrency.

The audit covers five domains:

1. **Canonical dedup key definition** — what uniquely identifies a record in each store
2. **Idempotency contracts** — whether write paths are genuinely replay-safe
3. **Rollback boundaries** — what is atomic, what is not, and how to recover
4. **Quarantine design** — how failed integrity items are isolated
5. **Validation suite** — concrete, runnable queries for online integrity verification

**Top finding:** The system has structural idempotency at the individual write level (MERGE for Neo4j, ReplacingMergeTree for ClickHouse) but has an unprotected integrity gap at the inter-store boundary — a partial write (Neo4j success, ClickHouse fail) produces cross-store drift that is not detectable without explicit per-batch reconciliation. This must be closed before ramping concurrency.

---

## Context Understanding

### System Architecture (from WO-00003)

- **Controller:** Ingest coordinator. Manages linking logic. Writes to Neo4j (graph relationships) and ClickHouse (telemetry rows). Orchestrates pipeline flow.
- **Oracle:** Heavy probe executor (DNS, HTTP, enrichment tooling). Produces JSON-first output fed to Controller.
- **Data format:** JSON-first — Oracle output is structured JSON; Controller parses and dual-writes.
- **Scale:** 10M+ subdomains; high write amplification under parallel lanes expected.
- **Current state:** Initial ingestion path exists and functions. High-scale parallel-lane stress path is not proven. This audit gates that ramp.

### Audit Scope

This audit does NOT evaluate scan logic, tooling correctness, or network behavior. It evaluates exclusively:
- Whether the ingest contract is integrity-safe under scale
- Whether the dual-write path is idempotent and recoverable
- Whether a concrete validation suite can verify integrity online

---

## Analytical Reasoning

### Why Dual-Store Integrity Is Hard

A single-store system has atomic transaction semantics — one commit either succeeds or fails. A dual-store system does not. Neo4j and ClickHouse are independent processes with no shared transaction coordinator. This creates a fundamental integrity gap:

```
Controller writes Neo4j → SUCCESS
Controller writes ClickHouse → FAILURE
Result: Neo4j node exists. ClickHouse row does not. Cross-store drift.
```

Neither database is aware of the other's state. There is no two-phase commit available without an external coordinator. The integrity contract must therefore be enforced at the **Controller layer** through:

1. Defined write order (authority store first)
2. Per-batch reconciliation after write
3. Idempotent retry semantics (replay-safe)
4. Checkpoint-based recovery

### Write Amplification Risk

At parallel lane concurrency over 10M subdomains, the same subdomain may be processed by multiple lanes simultaneously (DNS + HTTP in overlapping time windows). If dedup keys are imprecise, this produces:
- **Duplicate Neo4j nodes** — graph topology corrupted
- **Duplicate ClickHouse rows** — telemetry double-counted before background merge
- **Duplicate edge relationships** — incorrect relationship counts in graph queries

The dedup key is the first line of defense. It must be precise, stable, and normalized.

---

## Audit Finding 1: Canonical Dedup Key Definition

### Neo4j Dedup Keys

Neo4j uses MERGE semantics to achieve idempotency. MERGE requires a unique identifying property (or combination) for each node type.

#### Subdomain Node
```
dedup_key = lowercase(strip(fqdn))
property: name = "api.example.com"
MERGE (n:Subdomain {name: $name})
```
**Risks:**
- Case sensitivity: `API.example.com` and `api.example.com` are different strings — must lowercase at source
- Trailing dot: DNS FQDNs may include trailing dot (`api.example.com.`) — must strip
- Unicode: International domain names must be normalized to ACE/punycode form before keying

**Verdict:** Key is structurally sound. Normalization (lowercase, strip trailing dot, punycode) must be enforced at Controller ingestion boundary — not database level.

#### DNS Record Node
```
dedup_key = sha256(lowercase(fqdn) + "|" + record_type.upper() + "|" + value + "|" + ttl_bucket)
where ttl_bucket = floor(ttl / 300) * 300   (5-minute TTL buckets)
property: key_hash = sha256(...)
MERGE (n:DnsRecord {key_hash: $key_hash})
```
**Risks:**
- TTL variability: DNS TTLs fluctuate within a scan window; without bucketing, the same A record creates multiple dedup keys across time. TTL bucketing (300s window) collapses this
- Value normalization: IP addresses must be in canonical form (no leading zeros); CNAME values must be lowercased
- Record type: must be uppercased (A, AAAA, CNAME, MX, TXT) to prevent case-split keys

**Verdict:** Bucketed TTL approach is correct. Normalization requirements must be codified.

#### HTTP Result Node
```
dedup_key = sha256(lowercase(fqdn) + "|" + str(port) + "|" + str(status_code) + "|" + body_hash[:64])
where body_hash = sha256(response_body)[:64]  (first 64 hex chars of body hash)
property: key_hash = sha256(...)
MERGE (n:HttpResult {key_hash: $key_hash})
```
**Risks:**
- Dynamic content: HTML pages with timestamps, session IDs, or CSRFs in the body will produce different body hashes on each scan → different dedup keys → duplicate nodes
- Recommendation: Use only the first 512 bytes of body for hashing, after stripping known-dynamic patterns, OR use a structural fingerprint (title + meta + h1 content) rather than full body hash
- Port normalization: HTTP on port 80 implied and explicit must map to same key; HTTPS on 443 similarly

**Verdict:** Body fingerprinting approach needs hardening against dynamic content. Recommend structural body fingerprint (first 512 bytes stripped of session-specific content) over full body hash.

#### Neo4j Edge (Relationship)
```
dedup_key = source_node_key + "|" + relationship_type + "|" + target_node_key
MERGE (a:Subdomain {name: $src})-[r:HAS_DNS]->(b:DnsRecord {key_hash: $tgt})
```
**Risk:** If source or target node does not exist at time of MERGE, Neo4j may implicitly create a minimal node. This must be prevented — both endpoints must be confirmed to exist before relationship MERGE.

**Verdict:** Pre-confirm both endpoint nodes exist before relationship MERGE. Fail and DLQ if either is missing.

### ClickHouse Dedup Keys

ClickHouse ReplacingMergeTree uses the ORDER BY key as the dedup key. The most recent row (by version column) survives after background merge.

```sql
CREATE TABLE subdomains (
    fqdn String,
    scan_type Enum('dns', 'http', 'enrich'),
    scan_ts DateTime,
    ...
    ingested_batch_id String,
    version UInt64  -- Unix timestamp of ingest; higher = newer
) ENGINE = ReplacingMergeTree(version)
ORDER BY (fqdn, scan_type, toStartOfHour(scan_ts));
```

**Dedup key:** `(fqdn, scan_type, toStartOfHour(scan_ts))`

**Risks:**
- ClickHouse dedup is EVENTUAL — duplicates exist between INSERT and background merge. Queries must use FINAL to see deduplicated view
- Two concurrent INSERTs of the same (fqdn, scan_type, hour) tuple will both persist until background merge — this is expected ClickHouse behavior, not a bug
- Version column must be a monotonically increasing value; Unix timestamp is acceptable if system clock is reliable

**Verdict:** Key is structurally sound. All SELECT queries in validation must use FINAL. Monitoring must account for dedup lag in the post-INSERT window (typically 30–300 seconds depending on part count).

---

## Audit Finding 2: Idempotency Contracts

### Neo4j Idempotency

**Node creation (MERGE):**
```cypher
MERGE (n:Subdomain {name: $name})
ON CREATE SET n.created_at = $ts, n.ingested_batch_id = $batch_id
ON MATCH SET n.last_seen = $ts
```
✅ **Idempotent:** Second MERGE on same name updates `last_seen` only; does not create duplicate

**Property update risk:**
```cypher
// UNSAFE — accumulates values on each replay
MERGE (n:Subdomain {name: $name})
ON MATCH SET n.tags = n.tags + $new_tags

// SAFE — overwrites with explicit value
MERGE (n:Subdomain {name: $name})
ON MATCH SET n.tags = $tags
```
⚠️ **Critical contract:** All ON MATCH SET clauses must use `=` (assignment), never `+=` or list append. Accumulated writes break idempotency.

**Relationship creation:**
```cypher
MERGE (a:Subdomain {name: $src})-[r:HAS_DNS {key_hash: $key}]->(b:DnsRecord {key_hash: $tgt})
ON CREATE SET r.created_at = $ts
```
✅ **Idempotent** IF both nodes exist. ❌ **Unsafe** if either node missing — MERGE will create a minimal node without required properties.

**Transaction atomicity:**
- Neo4j batches run in a single transaction (500 ops)
- Full transaction rollback on any error → all 500 ops rolled back
- Safe to retry the full batch
- ⚠️ Risk: Transaction timeout on large batches under write pressure. Batch size must stay ≤ 500 ops to keep p95 latency below 500ms threshold

### ClickHouse Idempotency

**INSERT idempotency:**
```sql
INSERT INTO subdomains (fqdn, scan_type, scan_ts, version, ...) VALUES (...)
```
⚠️ **INSERT is not idempotent by default in ClickHouse.** Multiple INSERTs of the same row create multiple parts; background merge eventually deduplicates. Until merge:
- Duplicate rows exist in storage
- COUNT(*) without FINAL returns inflated count
- Reconciliation queries must always use FINAL

**Mitigation:** Track inserted batch IDs in checkpoint store. On retry, verify batch was not already successfully inserted before re-inserting.

**Row-level idempotency check (pre-insert):**
```sql
SELECT count(*) FROM subdomains FINAL
WHERE fqdn = %(fqdn)s AND scan_type = %(scan_type)s
AND toStartOfHour(scan_ts) = toStartOfHour(%(scan_ts)s)
```
If count > 0 → skip INSERT (batch already ingested). This is a read-before-write pattern and adds latency; use checkpoint store as primary guard to avoid querying ClickHouse on every row.

---

## Audit Finding 3: Partial Write Scenarios and Rollback Boundaries

### Partial Write Taxonomy

| Scenario | Neo4j State | ClickHouse State | Detectable? | Recovery |
|----------|------------|-----------------|------------|----------|
| A: Neo4j success, ClickHouse fail | Node exists | Row missing | Via reconciliation | Re-insert ClickHouse only |
| B: ClickHouse success, Neo4j fail (if wrong order) | Node missing | Row exists | Via reconciliation | Insert Neo4j; OR re-insert both if write order enforced |
| C: Neo4j node created, relationship MERGE fails | Orphan node | No row | Orphan query in Neo4j | Retry relationship MERGE; create ClickHouse row |
| D: Crash between Neo4j write and ClickHouse write | Node exists | Row missing | PENDING checkpoint | Resume from checkpoint; re-insert ClickHouse |
| E: Neo4j transaction timeout (partial tx) | Transaction rolled back; zero ops persisted | No row | Checkpoint remains PENDING | Retry full batch |
| F: ClickHouse INSERT partial (large batch split) | Node exists | Partial rows | Row count mismatch | Re-insert missing rows via row-level check |

### Rollback Boundary Definitions

**Neo4j rollback boundary:** The transaction (batch of ≤ 500 MERGE ops).
- Either all 500 ops commit or none do
- On timeout or error: full rollback; retry full batch
- Safe because MERGE is idempotent

**ClickHouse rollback boundary:** Does NOT have transactions. Rollback is simulated:
- On INSERT failure: identify rows NOT written via row-level SELECT FINAL
- Re-insert only the missing rows (using checkpoint + SELECT verification)
- Alternatively: re-insert entire batch — dedup key contract ensures no logical corruption (duplicate rows merge at background merge time)

**Recommended approach:** Re-insert entire ClickHouse batch on any INSERT failure. Background merge handles dedup. Mark batch as requiring reconciliation-pass to confirm.

### Write Order Contract (Authority Establishment)

```
REQUIRED ORDER:
  1. Verify source hash
  2. Write checkpoint (status=PENDING)
  3. Neo4j MERGE batch       ← authority write
  4. IF Neo4j SUCCESS:
       ClickHouse INSERT batch ← telemetry write
  5. IF Neo4j FAILURE:
       Route batch to ingest-DLQ (do NOT write ClickHouse)
  6. Update checkpoint (status=COMPLETE)
```

Rationale: Neo4j is the graph authority. ClickHouse is telemetry. If telemetry writes but graph doesn't exist, downstream graph queries return wrong topology. If graph writes but telemetry doesn't, downstream telemetry queries show gaps — recoverable and less severe.

---

## Audit Finding 4: Quarantine Design

### Quarantine as Integrity Boundary

Quarantine is not a garbage bin — it is a **forensic replay path**. Every quarantined item must be recoverable.

### Quarantine Directory Structure

```
artifacts/quarantine/
  {batch_id}_{lane}_{unix_ts}/
    raw_payload.json          # original Oracle JSON output, unmodified
    failure_reason.json       # structured failure metadata
    checkpoint_state.json     # checkpoint WAL state at time of failure
    retry_eligible.bool       # true/false
    reconciliation_delta.json # if cross-store mismatch triggered quarantine
```

### failure_reason.json schema

```json
{
  "failure_class": "integrity_error | corruption_risk | datastore_error | transient | rate_limited",
  "failure_detail": "string — specific error message",
  "dedup_key": "sha256 of the dedup key that triggered failure",
  "store_affected": "neo4j | clickhouse | both",
  "neo4j_state": "success | rollback | unknown",
  "clickhouse_state": "success | partial | failed | skipped",
  "timestamp": "ISO8601",
  "retry_eligible": true
}
```

### Quarantine Trigger Conditions

| Trigger | Class | Auto-Retry | Action |
|---------|-------|-----------|--------|
| Neo4j transaction timeout | datastore_error | YES (max 2) | Retry full batch after 5s |
| ClickHouse INSERT fail | datastore_error | YES (max 2) | Retry INSERT after 10s |
| Cross-store mismatch > 0.5% | integrity_error | NO | ORS alert + quarantine batch + pause ingest |
| Source file hash mismatch | corruption_risk | NO | HALT ingest + forensic log + manual review |
| Dedup key collision with content mismatch | integrity_error | NO | ORS alert + quarantine item + manual review |
| Neo4j orphan node detected | integrity_error | YES | Re-run relationship MERGE after 30s |
| Checkpoint PENDING > 5 min | integrity_error | YES | Resume from checkpoint |

### Rollback + Quarantine Flow

```
On integrity_error or corruption_risk:
  1. Stop ingest for affected batch
  2. Write to quarantine/{batch_id}_{lane}_{ts}/
  3. Update checkpoint status = QUARANTINED
  4. Emit ORS signal: quarantine_triggered
  5. IF retry_eligible:
       Schedule re-enqueue to DLQ after backoff
  6. IF NOT retry_eligible:
       Alert Mattermost; await manual review
  7. Resume ingest on NEXT batch (do not block pipeline on quarantined batch)
```

---

## Audit Finding 5: Online Integrity Verification — Validation Suite

All queries below are safe to run during live ingest. ClickHouse queries use FINAL. Neo4j queries are read-only MATCH statements.

### Suite 1: Duplicate Detection

**Neo4j — duplicate Subdomain nodes:**
```cypher
MATCH (n:Subdomain)
WITH n.name AS name, count(n) AS cnt
WHERE cnt > 1
RETURN name, cnt
ORDER BY cnt DESC
LIMIT 100;
```
Expected: zero results. Any result indicates a dedup key failure.

**Neo4j — duplicate DNS records for same subdomain:**
```cypher
MATCH (n:Subdomain)-[:HAS_DNS]->(d:DnsRecord)
WITH n.name AS fqdn, d.record_type AS rtype, d.value AS rval, count(d) AS cnt
WHERE cnt > 1
RETURN fqdn, rtype, rval, cnt
ORDER BY cnt DESC
LIMIT 100;
```
Expected: zero results.

**ClickHouse — duplicate rows (pre-merge window):**
```sql
SELECT fqdn, scan_type, toStartOfHour(scan_ts) AS hour, count(*) AS cnt
FROM subdomains
WHERE scan_ts >= now() - INTERVAL 1 HOUR
GROUP BY fqdn, scan_type, hour
HAVING cnt > 1
ORDER BY cnt DESC
LIMIT 100;
```
Expected: zero results (or very low count from pre-merge window — acceptable if < 0.5% of rows).

### Suite 2: Cross-Store Reconciliation

**Per-batch reconciliation (run after each ingest batch):**
```cypher
// Step 1: Neo4j count
MATCH (n:Subdomain) WHERE n.ingested_batch_id = $batch_id RETURN count(n) AS neo4j_count;
```
```sql
-- Step 2: ClickHouse count
SELECT count(*) AS ch_count FROM subdomains FINAL
WHERE ingested_batch_id = %(batch_id)s;
```
```python
# Step 3: Reconcile
delta = abs(neo4j_count - ch_count) / max(neo4j_count, ch_count, 1)
if delta > 0.005:
    quarantine(batch_id)
    ors.critical("reconciliation_mismatch", delta=delta, batch_id=batch_id)
```
Expected: delta ≤ 0.005 (0.5%).

**Full-table reconciliation (run off-peak, max 15 min target):**
```cypher
MATCH (n:Subdomain) RETURN count(n) AS neo4j_total;
```
```sql
SELECT count(*) AS ch_total FROM subdomains FINAL
WHERE scan_type = 'dns';  -- count primary DNS entries only for comparison
```
Expected: count within ±0.5% accounting for ClickHouse scan_type partitioning.

### Suite 3: Orphan Detection

**Neo4j — subdomain nodes with no DNS relationships (orphans):**
```cypher
MATCH (n:Subdomain)
WHERE NOT (n)-[:HAS_DNS]->()
AND n.created_at < datetime() - duration('PT1H')
RETURN count(n) AS orphan_count;
```
Expected: bounded by known DNS-negative subdomains. Flag if orphan_count grows faster than ingest rate.

**Neo4j — DNS records with no parent subdomain:**
```cypher
MATCH (d:DnsRecord)
WHERE NOT ()-[:HAS_DNS]->(d)
RETURN count(d) AS orphan_dns_count;
```
Expected: zero. Any result indicates a relationship MERGE failure.

### Suite 4: Partial Write Detection

**ClickHouse rows without corresponding Neo4j node (requires controller-level join):**
```python
# Controller logic — sample-based (1% of recent batches)
ch_fqdns = clickhouse.query("""
    SELECT DISTINCT fqdn FROM subdomains FINAL
    WHERE scan_ts >= now() - INTERVAL 1 HOUR
    ORDER BY rand() LIMIT 1000
""")
for fqdn in ch_fqdns:
    count = neo4j.query(
        "MATCH (n:Subdomain {name: $name}) RETURN count(n)", name=fqdn
    )
    if count == 0:
        flag_orphan_ch_row(fqdn)
```
Expected: zero orphan CH rows. Any orphan indicates partial write (CH write occurred, Neo4j write failed or was skipped).

### Suite 5: Checkpoint Integrity

**Stale PENDING checkpoints (checkpoint store — Redis or SQLite):**
```sql
SELECT batch_id, lane, status, ts
FROM checkpoints
WHERE status = 'PENDING'
AND ts < datetime('now', '-5 minutes')
ORDER BY ts ASC;
```
Expected: zero results. PENDING > 5 minutes indicates a write in progress that stalled. ORS alert and manual investigation required.

**Checkpoint completeness (all batch IDs have COMPLETE status):**
```sql
SELECT count(*) AS incomplete
FROM checkpoints
WHERE status != 'COMPLETE' AND status != 'QUARANTINED'
AND ts < datetime('now', '-15 minutes');
```
Expected: zero.

### Suite 6: Idempotency Verification (Replay Test)

To verify idempotency contracts hold under replay:

```
1. Select a known-good ingest batch (batch_id = X)
2. Re-run full ingest pipeline on batch X
3. After re-ingest:
   a. Run Suite 1 (duplicate detection) — must still return zero
   b. Run Suite 2 reconciliation for batch X — counts must match pre-replay
   c. Verify Neo4j node properties: only last_seen should have changed
4. If any duplicate detected: idempotency contract is broken; halt ingest; investigate
```

This test must be run:
- Before first production concurrency ramp
- After any ingest code change
- After any schema change to Neo4j or ClickHouse table definition

### Suite 7: Rollback Verification

After a simulated or real ingest failure:

```cypher
// Verify no partial Neo4j write
MATCH (n:Subdomain) WHERE n.ingested_batch_id = $failed_batch_id RETURN count(n);
```
Expected: zero (transaction rolled back).

```sql
-- Verify no partial ClickHouse write (should be zero if write order enforced)
SELECT count(*) FROM subdomains FINAL WHERE ingested_batch_id = %(failed_batch_id)s;
```
Expected: zero (if ClickHouse write was skipped on Neo4j failure per write order contract).

---

## Tradeoffs

| Decision | Chosen | Rejected | Tradeoff |
|----------|--------|----------|----------|
| Neo4j-first write order | ✅ | Parallel write or CH-first | Sequential is slower but prevents CH orphan rows; CH orphans are harder to detect and clean than Neo4j orphan nodes |
| ReplacingMergeTree for CH dedup | ✅ | Deduplicate at INSERT time via pre-check | Pre-check (SELECT before INSERT) adds per-row read latency; RMT amortizes dedup cost at background merge time |
| FINAL in all reconciliation queries | ✅ | Rely on background merge | Without FINAL, reconciliation sees inflated counts; FINAL adds ~2-5x query cost but is correct |
| Quarantine on disk (filesystem) | ✅ | Quarantine in a database | DB quarantine requires a working DB connection; filesystem quarantine works even during DB failure |
| Per-batch reconciliation (not per-row) | ✅ | Per-row reconciliation | Per-row is accurate but 500× more expensive at scale; batch-level (0.5% tolerance) is sufficient for integrity assurance |
| TTL bucketing for DNS dedup keys | ✅ | Exact TTL in key | Exact TTL creates a new dedup key every time TTL decrements; bucketing collapses the key space to ~5-minute windows |

---

## Risks

| ID | Title | Severity | Probability | Mitigation |
|----|-------|----------|-------------|------------|
| R1 | Accumulating property SET breaks idempotency | HIGH | MEDIUM | Code audit: find all ON MATCH SET += patterns and replace with = |
| R2 | Dynamic body content creates duplicate HTTP result nodes | HIGH | HIGH | Switch to structural body fingerprint (first 512B stripped of session content) |
| R3 | ClickHouse FINAL query cost spikes under heavy insert load | MEDIUM | HIGH | Schedule full-table reconciliation off-peak; limit FINAL queries during high-insert windows |
| R4 | Relationship MERGE creates implicit nodes on missing endpoint | HIGH | LOW | Pre-confirm both endpoints exist before any relationship MERGE; DLQ if missing |
| R5 | Cross-store drift undetected between batches | HIGH | MEDIUM | Per-batch reconciliation in validate lane — not end-of-run only |
| R6 | Checkpoint store failure during write | HIGH | LOW | Redis AOF persistence; SQLite WAL fallback; checkpoint failure = halt, not proceed |
| R7 | Stale PENDING checkpoints from crashed sessions | MEDIUM | MEDIUM | ORS monitor: PENDING > 5 min → alert; resume procedure in place |
| R8 | ClickHouse orphan rows from wrong write order | HIGH | LOW (if contract enforced) | Write order enforced as code contract; orphan detection in Suite 4 catches post-facto |

---

## Recommendations

| Priority | ID | Action |
|----------|-----|--------|
| 1 | REC-01 | Code audit: scan all Neo4j write code for `ON MATCH SET +=` or list-append patterns; replace with `=` assignment before any production write |
| 2 | REC-02 | Switch HTTP result body fingerprint from full body hash to structural fingerprint (first 512B, stripped of session-specific patterns) |
| 3 | REC-03 | Add endpoint pre-confirmation guard before every relationship MERGE: verify both source and target nodes exist; DLQ relationship item if either missing |
| 4 | REC-04 | Add `ingested_batch_id` field to both Neo4j node properties and ClickHouse rows — required for per-batch reconciliation |
| 5 | REC-05 | Implement per-batch validate lane with Suite 2 reconciliation; 30s settle delay; FINAL keyword in all CH queries |
| 6 | REC-06 | Implement all 7 validation suites; integrate Suite 1 (duplicate detection) and Suite 5 (checkpoint integrity) as pre-ramp gates |
| 7 | REC-07 | Run Suite 6 (idempotency replay test) before first concurrency ramp; must pass with zero duplicates detected |
| 8 | REC-08 | Add ORS monitor for stale PENDING checkpoints: WARNING at 3 min, CRITICAL at 5 min |
| 9 | REC-09 | Normalize all fqdn inputs at Controller boundary before keying: lowercase, strip trailing dot, punycode-convert IDNs |
| 10 | REC-10 | Add DLQ monitor to ORS: WARNING at 500 items, CRITICAL at 2,000 items per lane |

---

## Validation Strategy

### Pre-Ramp Gate (must pass before concurrency increase)

- [ ] Suite 1: Zero duplicates in current dataset
- [ ] Suite 3: Zero orphan nodes in current dataset
- [ ] Suite 5: Zero stale PENDING checkpoints
- [ ] Suite 6: Idempotency replay test passes (zero new duplicates after re-ingest)
- [ ] Suite 7: Rollback verification passes (zero partial writes after simulated failure)

### Continuous Online Monitoring

- Suite 2 (reconciliation): after every ingest batch
- Suite 5 (checkpoint integrity): every 60 seconds via ORS monitor
- Suite 1 (duplicate detection): once per hour during active ingest
- Suite 4 (orphan CH row sample): once per hour, 1% sample

### Off-Peak Full Validation

- Full-table Suite 2 reconciliation: once per 24h during low-load window
- Full orphan scan (Suite 3): once per 24h
- Target: complete within 15 minutes per batch (success metric from WO-00003)

---

## KPIs

| KPI | Target | Measurement |
|-----|--------|-------------|
| Reconciliation mismatch | ≤ 0.5% per batch | Suite 2 cross-store count delta |
| Duplicate suppression accuracy | ≥ 99% | Suite 1 zero results; Bloom filter skip rate |
| Validation runtime per batch | ≤ 15 min | Suite wall-clock time per 5,000-item batch |
| Orphan node count | 0 | Suite 3 queries |
| Stale PENDING checkpoints | 0 | Suite 5 query |
| Partial write detection rate | 0 | Suite 4 orphan CH row count |
| Idempotency replay pass rate | 100% | Suite 6 result |

---

## Assumptions

- **A1:** Controller has write access to both Neo4j and ClickHouse datastores from a single process
- **A2:** Neo4j supports MERGE semantics (available in all Neo4j versions ≥ 3.x)
- **A3:** ClickHouse table uses ReplacingMergeTree engine with a version column (monotonically increasing; Unix timestamp is acceptable)
- **A4:** An `ingested_batch_id` field can be added to both Neo4j node properties and ClickHouse rows without schema-breaking changes (new property/column, nullable default)
- **A5:** ClickHouse version ≥ 21.6 for FINAL keyword in SELECT; if earlier version, use GROUP BY dedup workaround in reconciliation queries
- **A6:** Checkpoint store (Redis or SQLite) is accessible from Controller at all times; failure of checkpoint store halts ingest rather than proceeding
- **A7:** FQDN normalization (lowercase, strip trailing dot) can be applied at Controller ingest boundary without downstream impact on existing data

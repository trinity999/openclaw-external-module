# ARTIFACT: WO-00007
# Engineering Maintenance Hardening Checklist and Observability Map

**Analyst:** OpenClaw Field Processor
**Work Order:** WO-00007
**Category:** Audit
**Priority:** Medium
**Date:** 2026-03-03
**Status:** COMPLETED
**ARD Mode:** AUDIT — HIGH+

---

## Executive Summary

WO-00007 delivers a comprehensive hardening checklist and observability map for continuous 10M+ scale recon operations. Coverage spans eight system layers with adversarial thinking applied throughout — edge cases, failure signatures, and silent failure modes are prioritized.

**Hardening domains audited:**
1. Checkpoint store (Redis/SQLite)
2. Neo4j graph database
3. ClickHouse telemetry store
4. AWSEM scheduler and queue system
5. ORS reflex monitor
6. Controller process
7. Oracle scan node and tooling
8. Network and credential security

**Observability outputs:**
- SLO definitions with warning/critical thresholds
- Alert catalog with deduplication and suppression rules
- Failure signature library — what each failure class looks like before it becomes catastrophic

---

## Context Understanding

System: Hybrid controller+oracle, 10M+ subdomains, continuous batch pipeline.
Operational mode: Controlled production, Mattermost-first reporting.
Active: KRIL, ORS, AWSEM.
Constraints: JSON-first, idempotent ingest, checkpoint replayability, no destructive mutation.
Success metrics: MTTR ≤ 20 min, throughput ≥ 30% baseline, mismatch ≤ 0.5%, premium model ≤ 5%.

---

## Hardening Checklist

### Layer 1: Checkpoint Store (Redis / SQLite WAL)

The checkpoint store is the operational memory of the pipeline. Its failure is silent and catastrophic — writes proceed without checkpoint, replay becomes impossible.

| # | Check | Action | Priority |
|---|-------|--------|----------|
| C1.1 | Redis AOF persistence enabled (`appendonly yes`) | Set in redis.conf; verify with `CONFIG GET appendonly` | CRITICAL |
| C1.2 | Redis RDB snapshots disabled or secondary only | AOF supersedes RDB for WAL use; RDB can cause checkpoint-write latency spikes during fork | HIGH |
| C1.3 | Redis bound to localhost or VPN interface only | `bind 127.0.0.1`; reject external connections | CRITICAL |
| C1.4 | Redis authentication enabled (`requirepass`) | Reject unauthenticated connections; rotate password on access change | HIGH |
| C1.5 | Redis `maxmemory` set with `allkeys-lru` eviction disabled | Checkpoint data must NOT be evictable; use `noeviction` policy | CRITICAL |
| C1.6 | Redis `maxmemory` = checkpoint_estimated_max × 2 | Bloom filter (~240MB) + checkpoint records (~100MB typical) → set 1GB minimum | HIGH |
| C1.7 | Stale PENDING checkpoint monitor active | ORS signal: `checkpoint_pending_age_min > 3 = WARNING, > 5 = CRITICAL` | CRITICAL |
| C1.8 | SQLite WAL fallback tested and validated | Run synthetic checkpoint write → Redis kill → verify SQLite WAL records checkpoint | HIGH |
| C1.9 | Checkpoint TTL enforced | COMPLETED checkpoints older than 72h deleted; prevents unbounded growth | MEDIUM |
| C1.10 | Redis replication configured (if available) | Even single-node Redis benefits from `save ""` + AOF-only; no replication required for single node | LOW |

**Audit failure mode:** Redis running without AOF → all checkpoints lost on Redis restart → full corpus replay required → data duplication risk if ingest already occurred.

---

### Layer 2: Neo4j Graph Database

| # | Check | Action | Priority |
|---|-------|--------|----------|
| C2.1 | Schema constraints applied | `CREATE CONSTRAINT subdomain_name_unique IF NOT EXISTS FOR (n:Subdomain) REQUIRE n.name IS UNIQUE` — blocks silent duplicates at DB level | CRITICAL |
| C2.2 | Indexes on all query properties | Index: `name`, `key_hash`, `ingested_batch_id`, `scanned`, `kril_rank_pct` — verify with `SHOW INDEXES` | HIGH |
| C2.3 | Heap size pre-configured | `dbms.memory.heap.initial_size=6g` and `dbms.memory.heap.max_size=6g` — fixed size prevents GC instability | HIGH |
| C2.4 | Page cache pre-configured | `dbms.memory.pagecache.size=8g` (SSD-backed) — auto-sizing causes latency spikes on first cold query | HIGH |
| C2.5 | Transaction timeout set | `dbms.transaction.timeout=60s` — prevents runaway queries holding locks on ingest batch nodes | CRITICAL |
| C2.6 | Default credentials rotated | `neo4j/neo4j` default must be changed before first production write | CRITICAL |
| C2.7 | Bolt TLS enabled | `dbms.connector.bolt.tls_level=REQUIRED` — encrypt controller-Neo4j communication | HIGH |
| C2.8 | Log rotation configured | `dbms.tx_log.rotation.size=256m` and `dbms.tx_log.rotation.keep_number=10` — prevent log disk exhaustion | MEDIUM |
| C2.9 | Write query timeout enforced | All MERGE queries have explicit timeout; reject if Neo4j does not respond within 30s | HIGH |
| C2.10 | Backup scheduled | Daily Neo4j dump or streaming backup to cold storage; verify backup integrity weekly | MEDIUM |
| C2.11 | Max concurrent connections limited | `dbms.connector.bolt.thread_pool_max_size=50` — prevents connection pile-up under controller retry storm | HIGH |
| C2.12 | Query log enabled for slow queries | `dbms.logs.query.enabled=true`, `dbms.logs.query.threshold=5000ms` — audit slow queries in production | MEDIUM |

**Audit failure mode:** Missing unique constraint on Subdomain.name → MERGE creates duplicate nodes silently if two concurrent writes on same subdomain race. Constraint adds write latency but prevents graph corruption.

---

### Layer 3: ClickHouse Telemetry Store

| # | Check | Action | Priority |
|---|-------|--------|----------|
| C3.1 | ReplacingMergeTree version column verified monotonic | `version` column = Unix timestamp; verify clock synchronization between Oracle and Controller | HIGH |
| C3.2 | FINAL keyword enforced in all reconciliation queries | Code audit: search for COUNT(*) FROM subdomains without FINAL; add FINAL | CRITICAL |
| C3.3 | INSERT timeout configured | `insert_timeout=30` seconds; prevents hanging inserts from blocking ingest lane | HIGH |
| C3.4 | Max insert block size tuned | `max_insert_block_size=1048576` (1M rows); prevents OOM on oversized batch inserts | MEDIUM |
| C3.5 | Remote access restricted | Bind ClickHouse to controller/oracle IPs only; reject public internet access | CRITICAL |
| C3.6 | Authentication enabled | `users.xml` with password hash; no default no-auth access | HIGH |
| C3.7 | Background merge monitoring | ORS signal: `clickhouse_parts_per_table > 500 = WARNING, > 1000 = CRITICAL` — excessive parts = dedup lag + query slowdown | HIGH |
| C3.8 | Part compaction settings tuned | `merge_tree.max_parts_in_total=2000` — ClickHouse auto-merges; verify merge is keeping pace with inserts | MEDIUM |
| C3.9 | Disk space monitoring | ORS signal: `clickhouse_disk_free_pct < 20% = WARNING, < 10% = CRITICAL` | HIGH |
| C3.10 | Backup policy | ClickHouse table backup via `BACKUP TABLE ... TO ...` or filesystem snapshot; daily minimum | MEDIUM |

**Audit failure mode:** ClickHouse background merge falling behind under high insert rate → parts accumulate → FINAL queries slow from seconds to minutes → reconciliation SLO breached → validate lane backs up.

---

### Layer 4: AWSEM Scheduler and Queue System

| # | Check | Action | Priority |
|---|-------|--------|----------|
| C4.1 | Queue max depth enforced at enqueue | AWSEM must reject (not silently drop) items exceeding max depth; rejection triggers backpressure | CRITICAL |
| C4.2 | DLQ TTL enforced | Each DLQ has maximum item age; expired items logged and discarded (not silently retained forever) | HIGH |
| C4.3 | Dead-letter visibility timeout configured | DLQ items must NOT auto-re-visible to primary queue; manual re-enqueue only | CRITICAL |
| C4.4 | Concurrency caps enforced at dispatch level | AWSEM must not dispatch more than concurrency_cap tasks simultaneously per lane; advisory caps are insufficient | CRITICAL |
| C4.5 | Per-lane queue depth monitored | ORS signal per lane: `queue_depth_pct_high_water > 0.7 = WARNING, > 0.95 = CRITICAL` | HIGH |
| C4.6 | Task deduplication at enqueue | AWSEM must reject duplicate task IDs within TTL window; prevents double-dispatch under retry conditions | HIGH |
| C4.7 | DLQ visibility to Mattermost | DLQ depth reported to OPS channel on every 100-item increment; DLQ is not silent | MEDIUM |
| C4.8 | AWSEM process restart safety | On AWSEM restart, in-flight tasks must be reclaimed via checkpoint store; no phantom tasks | HIGH |
| C4.9 | Lane isolation enforced | DNS queue DLQ cannot affect HTTP queue processing; per-lane isolation is structural | HIGH |

**Audit failure mode:** AWSEM concurrency cap as advisory only → dispatcher issues 400 tasks instead of 250 → Oracle CPU spikes → tool failures → DLQ cascade → all lanes degrade simultaneously.

---

### Layer 5: ORS Reflex Monitor

The ORS is the autonomous stability system. Its failure is the most dangerous: silent ORS failure means no automated response to degradation.

| # | Check | Action | Priority |
|---|-------|--------|----------|
| C5.1 | ORS heartbeat self-monitor | ORS must emit a heartbeat signal to an external watchdog; watchdog alerts if heartbeat absent > 60s | CRITICAL |
| C5.2 | Reflex actions are idempotent | Triggering the same reflex twice must produce the same system state; test: fire reflex → verify → fire again → verify no change | CRITICAL |
| C5.3 | Alert deduplication enforced | Same alert not sent more than once per 10-minute window; prevents Mattermost flood during sustained degradation | HIGH |
| C5.4 | Alert suppression after reflex | After a reflex fires (e.g., reduce concurrency), suppress the triggering alert for 30 min; prevents re-trigger before reflex takes effect | HIGH |
| C5.5 | All thresholds in config, not hardcoded | ORS thresholds in `ors_config.json`; no threshold hardcoded in ORS source; verify with code grep | HIGH |
| C5.6 | ORS static fallback table | If ORS process fails, a static fallback table in AWSEM applies safe defaults (suspend all lanes) | CRITICAL |
| C5.7 | Signal source health monitoring | ORS must monitor that its signal sources (Neo4j, ClickHouse, Redis) are responsive; dead signal = stale thresholds | HIGH |
| C5.8 | Reflex audit log | Every reflex action logged with: signal value, threshold, action taken, timestamp | MEDIUM |
| C5.9 | Manual override capability | ORS must support `ors suspend [lane]` and `ors resume [lane]` commands for operator override | MEDIUM |
| C5.10 | ORS test mode | Ability to run ORS in dry-run mode (log reflexes but don't execute) for threshold calibration | LOW |

**Audit failure mode:** ORS process crashes silently → no heartbeat detected (if C5.1 implemented) OR never detected (if not) → escalation storms, CPU overloads, DLQ cascades proceed without automated response.

---

### Layer 6: Controller Process

| # | Check | Action | Priority |
|---|-------|--------|----------|
| C6.1 | Write order contract enforced as code assertion | `assert neo4j_write_succeeded before clickhouse_write()` — code-level enforcement, not just documentation | CRITICAL |
| C6.2 | Checkpoint write before datastore write enforced as code assertion | `assert checkpoint_written_pending before neo4j_write()` — verified at unit test level | CRITICAL |
| C6.3 | Quarantine directory write-protected | Only controller process UID can write to `artifacts/quarantine/`; prevent accidental modification | HIGH |
| C6.4 | Max concurrent connections to Neo4j enforced | Connection pool max set in controller; prevents connection pile-up under retry storm | HIGH |
| C6.5 | Controller memory limits set | Process memory limit (systemd `MemoryMax` or Docker `--memory`); prevents OOM from buffering spike | HIGH |
| C6.6 | Graceful shutdown handler | SIGTERM → flush in-flight batches → write final checkpoint → exit; no abrupt kill during ingest | HIGH |
| C6.7 | FQDN normalization at single entry point | Single `normalize_fqdn()` function; no inline normalization; verified with grep | HIGH |
| C6.8 | Structured logging with correlation IDs | Every log line includes `batch_id`, `lane`, `timestamp`; supports post-hoc forensic analysis | MEDIUM |
| C6.9 | Source file hash verification enabled | SHA-256 check on every source chunk before ingest; HALT on mismatch (not warn) | CRITICAL |
| C6.10 | Retry limits enforced at controller level | Max retry counts hardcoded as constants; no unbounded retry loops | HIGH |

**Audit failure mode:** Controller has no memory limit → nuclei output buffering on large enrichment findings causes RAM spike → controller OOM → ingest halts → checkpoint in PENDING state indefinitely → no alerts (ORS not watching controller process memory).

---

### Layer 7: Oracle Scan Node and Tooling

| # | Check | Action | Priority |
|---|-------|--------|----------|
| C7.1 | Scan tool versions pinned | dnsx, httpx, nuclei, katana: versions pinned in deployment manifest; no `latest` tag | HIGH |
| C7.2 | Per-tool output size limit | dnsx: max 10MB output per batch; httpx: max 50MB; nuclei: max 100MB per target | HIGH |
| C7.3 | Per-tool timeout per target | dnsx: 30s; httpx: 30s; nuclei: 5 min per target — enforced at tool invocation level | CRITICAL |
| C7.4 | Tool output written to temp dir | Tool writes to `/tmp/oracle-work/{batch_id}/`; moved to final location on success; prevents partial file reads | HIGH |
| C7.5 | Oracle output JSON schema validation | Controller validates Oracle output against schema before processing; reject malformed output | CRITICAL |
| C7.6 | Tool process memory limits | ulimit or cgroup limits per tool process; nuclei OOM-kill should not take down Oracle node | HIGH |
| C7.7 | Oracle heartbeat to Controller | Oracle sends heartbeat to Controller every 30s; Controller ORS monitors absence > 30s = WARNING, > 120s = CRITICAL | CRITICAL |
| C7.8 | Nuclei template updates managed | Nuclei templates updated on controlled schedule (not auto-update during 72h operation) | MEDIUM |
| C7.9 | Oracle work directory cleanup | `/tmp/oracle-work/` cleaned after batch completion; disk exhaustion risk from partial run artifacts | HIGH |
| C7.10 | Rate limiter per tool per domain | dnsx: max 10 concurrent queries per root domain; httpx: max 5 concurrent per IP — prevents scan footprint from triggering WAF/IDS | MEDIUM |

**Audit failure mode:** Nuclei run against a target that returns a 10MB JavaScript response body → nuclei buffers into RAM × 25 concurrent targets = 250MB nuclei RAM spike → Oracle OOM → nuclei process killed → enrichment items silently lost → DLQ grows → no alert if C5.7 (signal source health) not watching Oracle output rate.

---

### Layer 8: Network and Credential Security

| # | Check | Action | Priority |
|---|-------|--------|----------|
| C8.1 | Controller-Oracle on private network or VPN | No Controller-Oracle traffic on public internet; use private LAN or WireGuard VPN | CRITICAL |
| C8.2 | Neo4j Bolt TLS enabled | `dbms.connector.bolt.tls_level=REQUIRED` | HIGH |
| C8.3 | ClickHouse HTTPS enabled | Native protocol TLS or HTTPS interface; not plaintext | HIGH |
| C8.4 | Redis TLS or UNIX socket | For same-host Redis: UNIX socket preferred (lower latency, no network attack surface) | HIGH |
| C8.5 | All credentials in secrets manager or env file | No credentials in source code; `.env` file not committed to git; gitignore enforced | CRITICAL |
| C8.6 | Credential rotation schedule | All DB passwords rotated after each major operation (post-72h); rotation tested quarterly | MEDIUM |
| C8.7 | Mattermost webhook URL treated as secret | Webhook URL in env file; not in logs or source; rotation if exposed | HIGH |
| C8.8 | Oracle SSH key-based access only | Password auth disabled on Oracle SSH; only controller's public key authorized | HIGH |
| C8.9 | Firewall rules for datastore ports | Neo4j bolt (7687), ClickHouse native (9000), Redis (6379): accept only from controller/oracle IPs | CRITICAL |
| C8.10 | Audit log for credential access | All DB auth events logged; alert on failed auth > 3 attempts/min | MEDIUM |

---

## Observability Map

### SLO Definitions

| SLO | Metric | Target | Warning | Critical |
|-----|--------|--------|---------|----------|
| DNS Throughput | dns_resolutions_per_hour | ≥ 700k | < 600k | < 500k |
| HTTP Throughput | http_probes_per_hour | ≥ 50k | < 40k | < 30k |
| Enrich Throughput | enrich_targets_per_hour | ≥ 5k | < 3k | < 1k |
| Ingest Throughput | ingest_records_per_hour | ≥ 200k | < 150k | < 100k |
| Neo4j Write Latency | neo4j_write_latency_p95_ms | ≤ 500 | > 400 | > 500 |
| ClickHouse Insert Queue | clickhouse_insert_queue_rows | ≤ 100k | > 100k | > 500k |
| Validate Mismatch | reconciliation_mismatch_pct | ≤ 0.5% | > 0.2% | > 0.5% |
| Lane DLQ Depth | dlq_depth_per_lane | < 500 | ≥ 500 | ≥ 2000 |
| Premium Model Usage | premium_escalation_rate | ≤ 5% | > 4% | > 5% |
| Checkpoint Staleness | checkpoint_pending_age_min | 0 | > 3 | > 5 |
| Incident MTTR | ors_alert_to_resolution_min | ≤ 20 | > 15 | > 20 |
| Oracle CPU | oracle_cpu_utilization_pct | ≤ 85% | > 80% | > 90% |
| ClickHouse Part Count | clickhouse_parts_per_table | < 500 | ≥ 500 | ≥ 1000 |
| Oracle Heartbeat | oracle_heartbeat_absence_sec | 0 | > 30 | > 120 |

### Alert Catalog

| Alert ID | Signal | Threshold | Severity | Dedup Window | Suppression After Reflex |
|----------|--------|-----------|----------|-------------|--------------------------|
| ALT-001 | dns_resolutions_per_hour | < 500k | CRITICAL | 10 min | 30 min |
| ALT-002 | http_probes_per_hour | < 30k | CRITICAL | 10 min | 30 min |
| ALT-003 | neo4j_write_latency_p95_ms | > 500 | CRITICAL | 5 min | 30 min |
| ALT-004 | reconciliation_mismatch_pct | > 0.5% | CRITICAL | per batch | manual clear |
| ALT-005 | dlq_depth_per_lane | ≥ 2000 | CRITICAL | 10 min | manual clear |
| ALT-006 | checkpoint_pending_age_min | > 5 | CRITICAL | 2 min | manual clear |
| ALT-007 | oracle_heartbeat_absence_sec | > 120 | CRITICAL | 5 min | manual clear |
| ALT-008 | oracle_cpu_utilization_pct | > 90% | CRITICAL | 5 min | 30 min |
| ALT-009 | clickhouse_parts_per_table | ≥ 1000 | WARNING | 30 min | 60 min |
| ALT-010 | clickhouse_disk_free_pct | < 10% | CRITICAL | 10 min | manual clear |
| ALT-011 | premium_escalation_rate | > 5% | WARNING | 60 min | 60 min |
| ALT-012 | ors_heartbeat_absence_sec | > 60 | CRITICAL | 2 min | — |
| ALT-013 | controller_disk_write_queue_mb | > 1000 | CRITICAL | 5 min | 30 min |
| ALT-014 | dlq_depth_per_lane | ≥ 500 | WARNING | 10 min | 30 min |
| ALT-015 | dns_http_link_rate_pct | < 90% | CRITICAL | 10 min | manual clear |

**Alert routing:** All CRITICAL alerts → Mattermost `#ops-critical` + on-call ping. WARNING alerts → Mattermost `#ops-monitoring` only.

### Failure Signature Library

Each signature describes the observable symptom pattern before the failure becomes catastrophic. Named for operator recognition.

---

#### FS-01: DNS Queue Starvation

**What is happening:** Oracle cannot drain the DNS result queue fast enough; Controller is issuing DNS tasks faster than Oracle returns results.

**Signature:**
```
dns_resolutions_per_hour: falling (was 700k, now 400k, trending down)
awsem_dns_queue_depth: growing (was 10k, now 40k, trending toward 50k high-water)
oracle_cpu_utilization_pct: LOW (Oracle is idle — queue is empty, not full)
```

**Distinguish from:** DNS tool failure (where CPU is zero AND queue is full). Queue starvation shows empty queue + idle Oracle.

**Pre-catastrophe window:** 20–40 minutes before DLQ starts accumulating.

**Reflex:** Check Oracle connectivity; verify dnsx process running; restart Oracle heartbeat monitor.

---

#### FS-02: HTTP Rate-Limit Storm

**What is happening:** Target infrastructure rate-limiting httpx; Oracle is backing off, reducing effective throughput.

**Signature:**
```
http_probes_per_hour: falling sharply (was 50k, now 15k)
oracle_cpu_utilization_pct: dropping (httpx backing off = less CPU)
http_dlq_depth: growing slowly (rate-limited items retrying and failing)
http_error_rate_429: high (> 20% of probes receiving 429)
```

**Distinguish from:** HTTP tool failure (where DLQ grows fast and CPU is zero).

**Pre-catastrophe window:** 30–60 minutes before HTTP corpus processing significantly behind schedule.

**Reflex:** Reduce HTTP concurrency by 30%; increase 429 cooldown to 120s; alert Mattermost.

---

#### FS-03: Ingest Saturation

**What is happening:** Controller cannot write to Neo4j fast enough; ingest queue growing, checkpoint PENDING records accumulating.

**Signature:**
```
neo4j_write_latency_p95_ms: rising (was 200ms, now 450ms, trending toward 500ms)
ingest_queue_depth: growing
checkpoint_pending_count: increasing
clickhouse_insert_queue_rows: growing (ingest backup affects CH flush too)
```

**Pre-catastrophe window:** 10–15 minutes before Neo4j latency breaches 500ms SLO.

**Reflex:** Reduce Neo4j concurrent transactions from 15 → 10; reduce ingest batch size from 500 → 200 ops/tx; alert.

---

#### FS-04: ClickHouse Dedup Lag Spike

**What is happening:** ClickHouse background merge is not keeping pace with INSERT rate; part count growing; FINAL queries slowing.

**Signature:**
```
clickhouse_parts_per_table: growing (was 100, now 600, trending toward 1000)
validate_reconciliation_query_duration_sec: rising (from 2s to 20s)
reconciliation_mismatch_pct: oscillating (spikes then resolves as merge catches up)
```

**Distinguish from:** Real data mismatch (which does NOT resolve on its own).

**Pre-catastrophe window:** 1–2 hours before FINAL queries take > 60s (validate lane timeout).

**Reflex:** Force manual merge: `OPTIMIZE TABLE subdomains FINAL`; reduce ClickHouse INSERT rate temporarily; alert.

---

#### FS-05: DLQ Cascade

**What is happening:** One lane's DLQ accumulates → its downstream lane starves → multiple lanes degrade in sequence.

**Signature:**
```
[Lane X]_dlq_depth: growing rapidly (> 100 items/hr new accumulation)
[Lane X+1]_queue_depth: low (upstream starvation)
[Lane X+1]_probes_per_hour: falling
multiple_lane_throughput: degrading simultaneously
```

**Distinguish from:** Single-lane failure (where only one lane is affected).

**Pre-catastrophe window:** 30–60 minutes before multiple lanes show critical SLO breach.

**Reflex:** Investigate Lane X DLQ root cause first; do not treat downstream lanes in isolation; alert with full cascade signature.

---

#### FS-06: Oracle Memory Pressure

**What is happening:** Nuclei or katana processing a target with large/complex response → buffering into Oracle RAM → approaching OOM.

**Signature:**
```
oracle_memory_utilization_pct: rising (was 50%, now 80%, trending)
enrich_targets_per_hour: falling (Oracle slowing under memory pressure)
enrich_dlq_depth: growing (memory-pressured targets failing timeout)
nuclei_process_restart_count: increasing (OOM kills)
```

**Distinguish from:** Oracle CPU overload (where CPU is high; memory is stable).

**Pre-catastrophe window:** 20–40 minutes before nuclei processes start OOM-killing.

**Reflex:** Reduce enrich concurrency from 25 → 10; add nuclei output size limit; alert; investigate large-response targets in DLQ.

---

#### FS-07: Checkpoint Store Failure

**What is happening:** Redis is not persisting checkpoints; new checkpoints appear to write but are not durable; or Redis is unreachable.

**Signature:**
```
checkpoint_pending_age_min: rising for ALL batches (not just one)
checkpoint_write_error_rate: > 0 (Redis connection errors in controller logs)
ingest_throughput: still running (controller continues without checkpoint — dangerous)
```

**Distinguish from:** Single stale checkpoint (which is isolated to one batch_id).

**Pre-catastrophe window:** Immediate — every ingest write without checkpoint is a replay integrity violation.

**Reflex:** HALT ingest immediately; switch to SQLite WAL fallback; investigate Redis; do not resume until checkpoint store confirmed healthy.

---

#### FS-08: Neo4j Lock Contention

**What is happening:** Multiple concurrent MERGE transactions competing on the same Subdomain node (e.g., DNS + HTTP ingest simultaneously writing to the same subdomain's properties).

**Signature:**
```
neo4j_write_latency_p95_ms: spike from 200ms to > 2000ms
neo4j_deadlock_rate: > 0 (visible in Neo4j logs)
ingest_error_rate: rising (transactions failing with LockException)
ingest_throughput: variable (some batches fast, some very slow)
```

**Distinguish from:** General Neo4j slowness (which shows uniformly elevated latency, not variance).

**Pre-catastrophe window:** 5–10 minutes before transaction failures begin causing DLQ accumulation.

**Reflex:** Reduce Neo4j concurrent transactions from 15 → 5; add transaction retry with exponential backoff; investigate which Subdomain nodes are hotspots (likely nodes shared across many DNS/HTTP findings).

---

## Implementation Approach

### Hardening Prioritization

**Phase 1 — Critical (before first production write):**
- C1.1, C1.3, C1.5 (Redis persistence + security)
- C2.1, C2.5, C2.6 (Neo4j constraints + auth + timeout)
- C3.2, C3.5, C3.6 (ClickHouse FINAL enforcement + security)
- C4.1, C4.3, C4.4 (AWSEM caps enforced + DLQ isolation)
- C5.1, C5.6 (ORS heartbeat + static fallback)
- C6.1, C6.2, C6.9 (Write order + checkpoint assertions + source hash)
- C7.3, C7.5, C7.7 (Tool timeouts + schema validation + Oracle heartbeat)
- C8.1, C8.5, C8.9 (Network isolation + credentials + firewall)

**Phase 2 — High (within first 24h of operation):**
- Remaining HIGH priority items from all layers

**Phase 3 — Medium (continuous improvement):**
- Backup schedules, audit logs, credential rotation schedules

### Observability Integration

All SLO metrics must be:
1. Emitted to ORS signal bus (not just logged)
2. Published to Mattermost `#ops-monitoring` hourly summary
3. Queryable via dashboard (ClickHouse materialized view preferred)
4. Correlated with batch_id for post-hoc forensic analysis

---

## Tradeoffs

| Decision | Chosen | Rejected | Tradeoff |
|----------|--------|----------|----------|
| Redis `noeviction` policy | ✅ | LRU eviction | LRU would silently evict checkpoint data under memory pressure; noeviction causes Redis to return errors instead — controller detects and switches to SQLite fallback |
| Alert dedup 10-minute window | ✅ | Per-event alerts | Per-event floods Mattermost under sustained degradation; 10-minute window limits to ~6 alerts/hour per signal |
| Failure signatures as named patterns | ✅ | Raw metric definitions only | Named patterns accelerate operator recognition; raw metrics require operator to correlate manually under time pressure |
| HALT ingest on checkpoint store failure | ✅ | Continue with degraded persistence | Continuing without checkpoint means ingest data cannot be safely replayed; the cost of halting is minutes; the cost of corrupt data is hours of forensic recovery |

---

## Risks

| ID | Title | Severity | Probability | Mitigation |
|----|-------|----------|-------------|------------|
| R1 | ORS process fails silently without heartbeat monitor | CRITICAL | MEDIUM | C5.1 (ORS heartbeat) is the primary mitigation; without it, ORS failure is invisible |
| R2 | Redis evicts checkpoint data under memory pressure | CRITICAL | MEDIUM | C1.5 (noeviction policy); verified via Redis CONFIG GET maxmemory-policy |
| R3 | Neo4j constraint missing allows silent duplicate nodes | HIGH | MEDIUM | C2.1 applied before first write; verified via SHOW CONSTRAINTS |
| R4 | ClickHouse FINAL missing in reconciliation query | HIGH | HIGH | C3.2 code audit; add FINAL to all reconciliation queries |
| R5 | Oracle tool timeout not set; runaway nuclei blocks Enrich lane | HIGH | MEDIUM | C7.3 enforced at Oracle invocation level |
| R6 | Controller credential in source code committed to git | CRITICAL | LOW | C8.5 verified before first commit; gitignore enforced |
| R7 | Alert flood during sustained degradation | MEDIUM | HIGH | Alert dedup window (C5.3) prevents Mattermost flood |

---

## Recommendations

| Priority | ID | Action |
|----------|-----|--------|
| 1 | REC-01 | Implement ORS heartbeat watchdog (C5.1) — most dangerous gap; ORS silence is invisible without it |
| 2 | REC-02 | Set Redis noeviction + verify AOF before first production write (C1.1, C1.5) |
| 3 | REC-03 | Apply Neo4j schema constraints (C2.1) and verify with SHOW CONSTRAINTS |
| 4 | REC-04 | Code audit: FINAL in all ClickHouse reconciliation queries (C3.2) |
| 5 | REC-05 | Set per-tool timeouts on Oracle (C7.3): dnsx 30s, httpx 30s, nuclei 5 min |
| 6 | REC-06 | Set Neo4j transaction timeout 60s (C2.5) and max connections 50 (C2.11) |
| 7 | REC-07 | Implement failure signature detection in ORS for FS-01 through FS-08 |
| 8 | REC-08 | Add alert deduplication (10 min window) and reflex suppression (30 min) to all ORS alerts |
| 9 | REC-09 | Enforce firewall rules: only controller/oracle IPs accepted on ports 7687, 9000, 6379 (C8.9) |
| 10 | REC-10 | Run hardening checklist verification before each 72h operation window start |

---

## Validation Strategy

| Check | Verification Method | Pass Condition |
|-------|---------------------|---------------|
| Redis AOF active | `redis-cli CONFIG GET appendonly` | `appendonly yes` |
| Neo4j constraint applied | `SHOW CONSTRAINTS` | Subdomain.name UNIQUE exists |
| Neo4j timeout set | `neo4j.conf grep transaction.timeout` | `60s` |
| ClickHouse FINAL in code | `grep -r "FROM subdomains" --include="*.py"` | All instances include `FINAL` |
| Tool timeouts | Oracle invocation log for each tool | Timeout error on 30s/5min marker |
| ORS heartbeat | External watchdog received heartbeat | Last heartbeat < 60s ago |
| Firewall rules | `nmap -p 7687,9000,6379 [controller_ip]` from external host | Connection refused |
| Alert dedup | Trigger test alert 10× in 5 min | Only 1 Mattermost message |
| HALT on checkpoint failure | Kill Redis; run ingest | Controller halts; switches to SQLite |
| Write order assertion | Inject Neo4j failure; observe CH | No CH write on Neo4j failure |

---

## KPIs

| KPI | Target |
|-----|--------|
| Hardening checklist items completed before first write | 100% of CRITICAL items |
| Alert false positive rate | < 5% of alerts |
| MTTR from ORS alert to resolution | ≤ 20 min |
| Failure signature recognition time | ≤ 5 min (operator identifies named pattern) |
| SLO breach rate | < 1 breach per 24h sustained operation |
| Undetected failures | 0 (every failure class has a defined signature) |

---

## Assumptions

- **A1:** ORS has an API surface for heartbeat emission; external watchdog (cron + HTTP check) is acceptable
- **A2:** Redis version supports AOF and `noeviction` maxmemory-policy (Redis 3.0+)
- **A3:** Neo4j version supports schema constraints (Neo4j 4.0+)
- **A4:** ClickHouse version supports FINAL keyword and ReplacingMergeTree (ClickHouse 21.6+)
- **A5:** Mattermost webhook is available for ORS alert routing
- **A6:** Oracle exposes system metrics (CPU, memory) accessible to Controller ORS via HTTP endpoint or SSH command
- **A7:** Alert dedup implementation is at ORS level (not Mattermost); ORS tracks last-sent time per alert ID

# WO-00030: Replay Debt Burn-Down Strategy
## Source: trinity999/Pandavs-Framework@cebd2d5

---

## 1. What Is Replay Debt?

Replay debt is the count of events that have been durably ingested into SQLite (`events` table)
but not yet successfully written to a downstream sink (ClickHouse or Neo4j).

It accumulates when:
- A sink worker is stopped, crashed, or rate-limited
- A sink database is down (ClickHouse WSL restart, Neo4j container restart loop)
- A batch of rows exhausts retries and enters the dead-letter queue (DLQ)
- A new sink is added after existing events were already ingested

The debt is stored in `sink_outbox` — one row per (event, sink_target) pair.
The `events` table is the authoritative source of truth; `sink_outbox` is the catch-up queue.

---

## 2. Debt Measurement Formulas

### 2.1 Active Debt (per sink)

```sql
-- ClickHouse active debt (PENDING + FAILED, retry-eligible)
SELECT COUNT(*) AS ch_active_debt
FROM   sink_outbox
WHERE  sink_target = 'clickhouse'
  AND  status IN ('PENDING', 'FAILED')
  AND  (next_retry_at IS NULL OR next_retry_at <= CURRENT_TIMESTAMP);

-- Neo4j active debt
SELECT COUNT(*) AS neo4j_active_debt
FROM   sink_outbox
WHERE  sink_target = 'neo4j'
  AND  status IN ('PENDING', 'FAILED')
  AND  (next_retry_at IS NULL OR next_retry_at <= CURRENT_TIMESTAMP);
```

### 2.2 Backoff-Deferred Debt (not yet retry-eligible)

```sql
-- Events failing but waiting for backoff window to expire
SELECT sink_target, COUNT(*) AS deferred_debt,
       MIN(next_retry_at) AS next_eligible_at
FROM   sink_outbox
WHERE  status = 'FAILED'
  AND  next_retry_at > CURRENT_TIMESTAMP
GROUP  BY sink_target;
```

### 2.3 Dead Debt (DLQ — requires manual intervention)

```sql
SELECT sink_target, COUNT(*) AS dead_debt
FROM   sink_outbox
WHERE  status = 'DEAD'
GROUP  BY sink_target;
```

### 2.4 Total Debt Snapshot

```sql
SELECT
    sink_target,
    SUM(CASE WHEN status = 'PENDING' THEN 1 ELSE 0 END) AS pending,
    SUM(CASE WHEN status = 'FAILED'
             AND (next_retry_at IS NULL OR next_retry_at <= CURRENT_TIMESTAMP) THEN 1 ELSE 0 END) AS failed_eligible,
    SUM(CASE WHEN status = 'FAILED'
             AND next_retry_at > CURRENT_TIMESTAMP THEN 1 ELSE 0 END) AS failed_deferred,
    SUM(CASE WHEN status = 'DEAD'  THEN 1 ELSE 0 END) AS dead,
    SUM(CASE WHEN status = 'SYNCED' OR status = 'CLAIMED' THEN 0 ELSE 1 END) AS total_outstanding
FROM   sink_outbox
GROUP  BY sink_target;
```

### 2.5 Burn Rate (rows per hour)

```sql
-- Rows synced in the last hour (proxy for sink throughput)
SELECT sink_target,
       COUNT(*) AS synced_last_hour
FROM   event_sync_ledger
WHERE  synced_at >= datetime('now', '-1 hour')
  AND  outcome = 'SYNCED'
GROUP  BY sink_target;
```

### 2.6 Ingest Rate (events added per hour)

```sql
-- New events arriving from scanner (SQLite ingest throughput)
SELECT COUNT(*) AS ingested_last_hour
FROM   events
WHERE  ts >= datetime('now', '-1 hour');
```

---

## 3. Hour-Based Burn-Down Model

### Linear model

```
debt(t + 1h) = debt(t)  -  sync_rate_h  +  ingest_rate_h

Where:
  debt(t)         = active debt at time t (from §2.1)
  sync_rate_h     = rows synced per hour (from §2.5)
  ingest_rate_h   = new events ingested per hour (from §2.6)
```

### Halving time formula

When scans are running (ingest_rate_h > 0):

```
halving_time_h = debt(t) / (sync_rate_h - ingest_rate_h)

Requirement for debt reduction:
  sync_rate_h > ingest_rate_h  →  net_burn_rate_h > 0
```

When scans are paused (ingest_rate_h = 0, full burn-down mode):

```
halving_time_h = debt(t) / (2 × sync_rate_h)
full_drain_time_h = debt(t) / sync_rate_h
```

### Target

**Halving time ≤ 4 hours** from peak debt (under normal scan conditions).

To meet this: `sync_rate_h ≥ ingest_rate_h + (debt_peak / 4)`

At observed ingest rates of ~5,000 events/hour and a typical debt peak of 200,000 events:

```
sync_rate_h ≥ 5,000 + (200,000 / 4) = 55,000 rows/hour
```

With CH batch_size=500 at 30s intervals and Neo4j batch_size=200 at 30s intervals:

```
CH  max theoretical: 500 × (3600/30) = 60,000 rows/hour  ✓ meets target
Neo4j max theoretical: 200 × (3600/30) = 24,000 rows/hour  ✓ (debt halves in ~8h at peak)
```

Neo4j halving time at peak 200k debt: ~8 hours. **Acceptable** — Neo4j writes are expensive; Neo4j debt threshold for go/no-go should be lower than CH threshold (§5).

---

## 4. Priority Replay Ordering

The sink workers already process by `ORDER BY created_at ASC` (FIFO). For accelerated catch-up,
the priority ordering must additionally consider:

| Priority | Criteria | Rationale |
|----------|----------|-----------|
| 1 (highest) | PENDING, retry_count=0 | Fresh rows — highest probability of success; no backoff wait |
| 2 | FAILED, retry_count=1, retry-eligible | Already failed once but likely transient; eligible for next attempt |
| 3 | FAILED, retry_count 2-4, retry-eligible | Fewer remaining retries; still recoverable |
| 4 | FAILED, retry_count=MAX_RETRIES-1 | Last chance before DLQ — process before promoting |
| DLQ (manual) | status='DEAD' | Require operator diagnosis; do not auto-requeue without root cause fix |

**DNS resolution events (event_kind='dns_resolution') take priority** over future event kinds
(httpx, naabu) in Phase-1 rollout — they are the validated, tested write path.

**ClickHouse before Neo4j** during burst catch-up: CH writes are ~3x faster per row and
the CH schema (ReplacingMergeTree) absorbs duplicates more gracefully. Neo4j MERGE is
correct but heavier — pace it to avoid Bolt connection exhaustion.

---

## 5. Throttle Policy During Catch-Up

The WO-00026 adaptive controller already adjusts PARALLEL based on `sink_lag_h`.
The replay throttle policy works alongside it:

### 5.1 Active Scan + Catch-Up (concurrent)

```
Target: scan throughput degradation ≤ 20%

Rules:
  IF ingest_lag_s > 120s (YELLOW):
    → CH replay_batch_size = 200 (down from 500)
    → Neo4j replay_batch_size = 100 (down from 200)
    → sweep_interval = 60s (up from 30s)

  IF ingest_lag_s > 300s (RED):
    → CH replay_batch_size = 100
    → Neo4j replay_batch_size = 50
    → sweep_interval = 120s
    → do NOT start new scan modules

  IF ingest_lag_s <= 120s AND debt_active > 0 (GREEN + backlog):
    → run at full batch_size (500/200)
    → sweep_interval = 15s (accelerated)
```

### 5.2 Scan Paused / Quiet Window (bulk burn-down)

When the scanner is not running (no new ingest) — typically during off-hours:

```
  CH replay_batch_size = 1000 (2× normal)
  Neo4j replay_batch_size = 400 (2× normal)
  sweep_interval = 10s (3× faster)
  PARALLEL has no impact on sink workers (independent processes)
```

### 5.3 DLQ Growth Throttle

```
  IF dead_debt > 100 in 1 hour:
    → STOP accepting new FAILED rows into current retry cycle
    → Diagnose root cause before resuming replay
    → Alert: "DLQ rate spike — replay paused"
```

---

## 6. Go/No-Go Gates for New Scan Modules

Before enabling any new scan module (Phase-2 httpx, Phase-2 naabu), the following
debt gates must be GREEN:

| Gate | Threshold | Required Before |
|------|-----------|-----------------|
| G-1: CH active debt | < 10,000 events | Enabling httpx ClickHouse writes |
| G-2: Neo4j active debt | < 5,000 events | Enabling naabu Port nodes |
| G-3: CH dead_debt | = 0 (or < 5) | Any new CH schema change |
| G-4: Neo4j dead_debt | = 0 (or < 5) | Any new Neo4j node type |
| G-5: DLQ rate last 24h | < 0.5% of synced | Any new event kind in sink_outbox |
| G-6: Burn rate positive | sync_rate_h > ingest_rate_h | Any new scan module (adds ingest) |

**Rationale**: enabling a new scan module increases `ingest_rate_h`. If `sync_rate_h ≤ ingest_rate_h`
at that moment, debt grows unboundedly. G-6 ensures the system has headroom.

---

## 7. Escalation Thresholds

| Level | Trigger | Response |
|-------|---------|----------|
| YELLOW | CH or Neo4j active debt > 50,000 | Reduce batch size (§5.1), log to operator dashboard |
| RED | CH or Neo4j active debt > 200,000 | Throttle sink sweep to 120s interval, alert operator |
| CRITICAL | Debt growing for > 2 consecutive hours | Pause new module activation, page operator |
| EMERGENCY | Dead debt > 500 events | Stop all replays, diagnose DLQ, restore sink health first |
| HALVING MISS | halving_time_h > 8h | Operator must evaluate: pause scanner entirely for burn-down, or scale sink workers |

---

## 8. No Data Loss Guarantees

Replay safety relies on three properties already in place:

1. **INSERT OR IGNORE** in `persistence_gateway.py insert_event()` — events are stored in SQLite exactly once; SQLite is the authoritative record (no event loss even if sinks are down for days).

2. **MERGE idempotency** — both CH (ReplacingMergeTree) and Neo4j (MERGE patterns) accept the same event twice without creating duplicates; replay at any volume is safe.

3. **sink_outbox PENDING state** — rows are never deleted until explicitly SYNCED or DEAD; a crashed worker leaves rows in CLAIMED state which are reaped back to PENDING within CLAIMED_TTL_S (600s).

These three properties together guarantee: **zero event loss, zero duplicate corruption from replay**.

---

## 9. Cross-WO Dependencies

| WO | Dependency |
|----|-----------|
| WO-00022 | chunk_queue + reclaim_stale_leases() — scanner backlog drain |
| WO-00023 | sink_outbox, event_sync_ledger, dead_letter_events, retry taxonomy |
| WO-00025 | FM-08 (CH outage) and FM-15 (Neo4j outage) drills validate replay recovery |
| WO-00026 | Adaptive controller PARALLEL adjustment during catch-up (sink_lag_h signal) |
| WO-00028 | CH sink worker — implements the throttle-aware batch claiming |
| WO-00029 | Neo4j sink worker — implements MERGE-5 idempotent replay |

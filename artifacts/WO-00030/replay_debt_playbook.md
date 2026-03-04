# Replay Debt Burn-Down Playbook
## Work Order: WO-00030 | Pandavs Recon Framework

---

## Audience

Operator performing backfill/catch-up after a sink outage, worker restart, or DLQ accumulation event.
Assumes SQLite (`scan_persistence.db`) is healthy and events are durable.

---

## Playbook Overview

```
STEP 0: Triage — measure debt and identify root cause
STEP 1: Restore sink health (ClickHouse or Neo4j)
STEP 2: Verify workers are running and claiming
STEP 3: Select catch-up throttle tier
STEP 4: Monitor burn-down hourly
STEP 5: Declare resolved or escalate
```

---

## STEP 0: Triage — Measure Debt

Run the full debt snapshot:

```bash
python3 -c "
import sqlite3, json
conn = sqlite3.connect('scan_persistence.db')
conn.row_factory = sqlite3.Row
rows = conn.execute('''
  SELECT
    sink_target,
    SUM(CASE WHEN status = \"PENDING\" THEN 1 ELSE 0 END) pending,
    SUM(CASE WHEN status = \"FAILED\"
             AND (next_retry_at IS NULL OR next_retry_at <= datetime(\"now\")) THEN 1 ELSE 0 END) failed_eligible,
    SUM(CASE WHEN status = \"FAILED\"
             AND next_retry_at > datetime(\"now\") THEN 1 ELSE 0 END) failed_deferred,
    SUM(CASE WHEN status = \"DEAD\" THEN 1 ELSE 0 END) dead,
    SUM(CASE WHEN status = \"CLAIMED\" THEN 1 ELSE 0 END) claimed
  FROM sink_outbox
  GROUP BY sink_target
''').fetchall()
for r in rows:
    print(dict(r))
conn.close()
"
```

Determine triage level:

| Condition | Level |
|-----------|-------|
| active_debt < 5,000 per sink | GREEN — workers will self-heal |
| active_debt 5k-50k per sink | YELLOW — monitor hourly |
| active_debt 50k-200k per sink | RED — apply catch-up throttle |
| active_debt > 200k per sink | CRITICAL — pause new scans, full burn-down |
| dead_debt > 0 | DLQ intervention required |

---

## STEP 1: Restore Sink Health

### ClickHouse (WSL)

```bash
# Check if running
wsl -d Ubuntu-22.04 -- bash -c "ss -tlnp | grep 9000"

# Start if not running
wsl -d Ubuntu-22.04 -- clickhouse-server --daemon \
    --config-file=/etc/clickhouse-server/config.xml

# Verify connection
wsl -d Ubuntu-22.04 -- clickhouse-client \
    --user default --password pandavs_ch_2026 \
    --query "SELECT version(), currentDatabase()"
```

If `CANNOT_LOAD_CONFIG` error (no-password.xml conflict):
```bash
# Remove conflicting config (see DATABASE_OPS.md)
echo 'Alex@123' | sudo -S rm /etc/clickhouse-server/users.d/no-password.xml
# Then restart
echo 'Alex@123' | sudo -S service clickhouse-server restart
```

### Neo4j (Docker)

```powershell
# Check container status
docker ps -a | grep pandavs-neo4j-fixed

# Start if stopped
docker start pandavs-neo4j-fixed

# If stuck in restart loop (stale PID file):
docker rm -f pandavs-neo4j-fixed
cd C:\Users\abhij\project_pandavs\pandavs-recon-framework
docker run -d `
  --name pandavs-neo4j-fixed `
  --publish 7687:7687 --publish 7474:7474 --publish 7473:7473 `
  --env-file .neo4j_docker.env `
  --volume pandavs-neo4j-secure-data:/data `
  --volume pandavs-neo4j-secure-logs:/logs `
  --restart unless-stopped `
  neo4j:5.9
# Wait ~45s then verify:
docker exec pandavs-neo4j-fixed neo4j status
```

---

## STEP 2: Verify Workers Are Running

```bash
# Check sink worker processes
ps aux | grep -E "clickhouse_sink|neo4j_sync" | grep -v grep

# Check recent outbox claims (should see status=CLAIMED if workers are running)
python3 -c "
import sqlite3
conn = sqlite3.connect('scan_persistence.db')
print(conn.execute('''
  SELECT sink_target, status, COUNT(*) cnt,
         MAX(claimed_at) last_claim, MAX(synced_at) last_sync
  FROM sink_outbox
  GROUP BY sink_target, status
  ORDER BY sink_target, status
''').fetchall())
"

# If workers are NOT running, start them:
nohup python3 clickhouse_sink_worker.py --db scan_persistence.db loop \
    >> logs/ch_sink.log 2>&1 &
echo $! > state/ch_sink.pid

nohup python3 neo4j_sync_worker.py --db scan_persistence.db loop \
    >> logs/neo4j_sync.log 2>&1 &
echo $! > state/neo4j_sync.pid
```

---

## STEP 3: Select Catch-Up Throttle Tier

Choose the tier that matches current conditions:

### Tier A — Normal operation (debt < 50k, scanner running)

Workers run at default settings. No intervention needed.
Monitor hourly (STEP 4). Expect self-resolution within 4h.

```
CH:    batch_size=500, sweep_interval=30s
Neo4j: batch_size=200, sweep_interval=30s
```

### Tier B — Elevated debt (50k-200k, scanner running)

Reduce batch sizes to protect scan ingest lag. Update worker config:

```
CH:    batch_size=200, sweep_interval=60s
Neo4j: batch_size=100, sweep_interval=60s

Scan PARALLEL: let WO-00026 adaptive controller manage (do not force)
Do NOT start new scan modules (go/no-go gate G-1/G-2 will fail)
```

Expected halving time: ~6h (at 200k peak debt, ingest_rate 5k/h):
```
net_burn = sync_rate - ingest_rate
CH net_burn  ≈ (200 × 60) - 5,000 = 7,000/h → halving in ~14h  (Tier A: 30,000/h → halving in ~4h)
```

**If in Tier B, prefer to pause scanner for 2h and run Tier C for a 2× faster drain.**

### Tier C — Bulk burn-down (scanner paused or off-hours)

Scanner not ingesting. Run at 2× batch size, 3× sweep speed:

```bash
# Restart workers with accelerated settings (pass via env vars)
BATCH_SIZE_CH=1000 SWEEP_INTERVAL=10 nohup python3 clickhouse_sink_worker.py loop &
BATCH_SIZE_NEO4J=400 SWEEP_INTERVAL=10 nohup python3 neo4j_sync_worker.py loop &
```

Expected full drain of 200k CH debt at 0 ingest:
```
drain_rate = 1000 rows/batch × (3600s / 10s per sweep) = 360,000 rows/h
drain_time = 200,000 / 360,000 ≈ 0.56h → ~34 minutes for ClickHouse
drain_time = 200,000 / 144,000 ≈ 1.4h → ~83 minutes for Neo4j
```

### Tier D — DLQ intervention (dead_debt > 0)

**Do not try to auto-requeue DLQ rows** until root cause is fixed.

1. Inspect DLQ rows:
```bash
python3 -c "
import sqlite3
conn = sqlite3.connect('scan_persistence.db')
rows = conn.execute('''
  SELECT d.sink_target, d.failure_reason, d.promoted_at,
         e.event_kind, e.tool, e.asset
  FROM   dead_letter_events d
  JOIN   events e ON e.event_id = d.event_id
  ORDER  BY d.promoted_at DESC
  LIMIT  20
''').fetchall()
for r in rows: print(r)
"
```

2. Classify failure reason:
   - `NON_RETRYABLE: AuthError` → fix credentials, then re-enqueue
   - `NON_RETRYABLE: SyntaxError` → fix Cypher/ClickHouse schema mismatch
   - `NON_RETRYABLE: TYPE_MISMATCH` → fix event parse logic
   - Exhausted retries (transient) → re-enqueue after sink health restored

3. Re-enqueue DLQ rows after fix:
```sql
-- Re-enqueue as PENDING (reset retry_count)
UPDATE sink_outbox
SET    status       = 'PENDING',
       retry_count  = 0,
       last_error   = NULL,
       next_retry_at = NULL,
       updated_at   = CURRENT_TIMESTAMP
WHERE  status = 'DEAD'
  AND  sink_target = 'clickhouse';   -- or 'neo4j'
-- Also remove from dead_letter_events if re-enqueuing
DELETE FROM dead_letter_events
WHERE  sink_target = 'clickhouse' AND event_id IN (
    SELECT event_id FROM sink_outbox WHERE status = 'PENDING'
);
```

---

## STEP 4: Monitor Burn-Down Hourly

Run this query every hour during catch-up:

```bash
python3 - <<'PYEOF'
import sqlite3, datetime

conn = sqlite3.connect('scan_persistence.db')
now  = datetime.datetime.utcnow().strftime("%Y-%m-%d %H:%M:%S")

# Debt snapshot
debt = conn.execute('''
  SELECT sink_target,
    SUM(CASE WHEN status IN ("PENDING","FAILED") AND (next_retry_at IS NULL OR next_retry_at <= datetime("now")) THEN 1 ELSE 0 END) active,
    SUM(CASE WHEN status = "DEAD" THEN 1 ELSE 0 END) dead
  FROM sink_outbox GROUP BY sink_target
''').fetchall()

# Burn rate (last hour)
rates = conn.execute('''
  SELECT sink_target, COUNT(*) synced_h
  FROM   event_sync_ledger
  WHERE  synced_at >= datetime("now","-1 hour") AND outcome = "SYNCED"
  GROUP  BY sink_target
''').fetchall()
rate_map = {r[0]: r[1] for r in rates}

# Ingest rate (last hour)
ingest_h = conn.execute('''
  SELECT COUNT(*) FROM events WHERE ts >= datetime("now","-1 hour")
''').fetchone()[0]

print(f"\n=== Debt Snapshot {now} UTC ===")
print(f"{'Sink':<12} {'Active':>10} {'Dead':>6} {'Synced/h':>10} {'Ingest/h':>10} {'Halving(h)':>12}")
print("-" * 64)
for d in debt:
    sink, active, dead = d
    synced_h  = rate_map.get(sink, 0)
    net_burn  = synced_h - ingest_h
    halving   = round(active / net_burn, 1) if net_burn > 0 and active > 0 else "∞"
    print(f"{sink:<12} {active:>10} {dead:>6} {synced_h:>10} {ingest_h:>10} {str(halving):>12}")
print()
conn.close()
PYEOF
```

### Halving time targets

| halving_time_h | Action |
|----------------|--------|
| ≤ 4h | GREEN — on track |
| 4h – 8h | YELLOW — acceptable for Neo4j; investigate if CH |
| > 8h | RED — escalate (§STEP 5) |
| ∞ (sync_rate ≤ ingest_rate) | CRITICAL — debt growing; must intervene |

---

## STEP 5: Resolution or Escalation

### Resolution (self-heal confirmed)

```
✓ active_debt < 5,000 for both sinks
✓ dead_debt = 0
✓ halving_time_h ≤ 4h (or debt already drained)
✓ DLQ rate last 24h < 0.5%
→ Resume normal operation. Log resolution timestamp.
```

### Go/No-Go check before new scan module activation

```
GATE   THRESHOLD           SINK        STATUS
G-1    CH active < 10,000  clickhouse  [ ] PASS / [ ] FAIL
G-2    Neo4j active < 5k   neo4j       [ ] PASS / [ ] FAIL
G-3    CH dead = 0         clickhouse  [ ] PASS / [ ] FAIL
G-4    Neo4j dead = 0      neo4j       [ ] PASS / [ ] FAIL
G-5    DLQ rate < 0.5%     both        [ ] PASS / [ ] FAIL
G-6    sync_rate > ingest  both        [ ] PASS / [ ] FAIL
→ ALL PASS: authorized to enable new scan module
→ ANY FAIL: defer module activation
```

### Escalation triggers

| Trigger | Action |
|---------|--------|
| debt growing for > 2 consecutive hours | Pause scanner, run Tier C drain |
| dead_debt > 500 in < 1 hour | Stop all sink workers, diagnose NON_RETRYABLE root cause |
| halving_time_h → ∞ for both sinks | Sink health issue; restart sinks and workers |
| No new SYNCED rows in 30 min (workers running) | Check worker logs; likely auth or connection failure |

---

## Appendix: Quick Reference SQL

```sql
-- Current active debt (copy-paste ready)
SELECT sink_target,
       SUM(CASE WHEN status IN ('PENDING','FAILED')
                AND (next_retry_at IS NULL OR next_retry_at <= CURRENT_TIMESTAMP)
                THEN 1 ELSE 0 END) active_debt
FROM sink_outbox GROUP BY sink_target;

-- Last 5 DLQ promotions
SELECT d.sink_target, d.failure_reason, d.promoted_at, e.event_kind, e.asset
FROM   dead_letter_events d JOIN events e ON e.event_id = d.event_id
ORDER  BY d.promoted_at DESC LIMIT 5;

-- Sync rate last hour
SELECT sink_target, COUNT(*) synced_h
FROM   event_sync_ledger
WHERE  synced_at >= datetime('now', '-1 hour') AND outcome = 'SYNCED'
GROUP  BY sink_target;

-- Verify idempotency after debt drain (Neo4j)
-- Before and after values should match after second sync run:
-- MATCH ()-[r:RESOLVES_TO]->() RETURN count(r) AS resolves_to_count;
```

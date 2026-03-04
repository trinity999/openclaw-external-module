# WO-00026 Adaptive Concurrency & Backpressure Controller

**Work Order:** WO-00026
**Category:** performance/HIGH
**Analyst:** openclaw-field-processor
**Date:** 2026-03-05
**Source commit:** trinity999/Pandavs-Framework@cebd2d5

---

## 1. Executive Summary

The Pandavs DNS scan loop (`run_full_dns_pass.sh`) uses a fixed `PARALLEL=48` for all 51 chunks. This hardcoded value cannot adapt to resolver health, network congestion, SQLite write pressure, or sink backlog growth. The result is chunk completion variance (fast chunks finish in minutes; congested chunks stall for hours) and periodic resolver timeout bursts that generate noise in result files.

This Work Order proposes an **adaptive concurrency controller** that dynamically tunes `PARALLEL` based on real-time lag, error rate, and outbox backlog signals — all already available in `scan_persistence.db` without new instrumentation.

**Success targets:** chunk completion variance reduced >= 20% | no-progress windows > 30 min reduced to near-zero | resolver timeout/error bursts reduced >= 25%

---

## 2. Source Analysis

### 2.1 Current scanner (run_full_dns_pass.sh lines 1-31)

```bash
PARALLEL="${PARALLEL:-48}"                    # line 4: static, env-overridable
QUEUE="$BASE/state/dnsx_queue.txt"           # line 5: input chunk list

while IFS= read -r chunk; do                 # line 11: sequential chunk loop
  ...
  awk 'NF{print $1}' "$chunk" \
    | xargs -P "$PARALLEL" -n 1 sh -c '...' \
    > "$out"                                  # line 22-27: parallel DNS per chunk
done < "$QUEUE"
```

**Key observation:** `PARALLEL` controls the number of simultaneous DNS queries within one chunk. The per-chunk xargs exits and `PARALLEL` is re-evaluated for the next chunk. This means PARALLEL can be changed between chunks with zero code modification — the env var simply needs to be updated before the next iteration.

### 2.2 PHASE_IMPLEMENTATION_PLAN.md lines 115-124 (Phase 4 monitoring)

```
Monitoring outputs:
  - backlog size
  - ingest lag
  - chunk completion rate
  - DB sync lag
```

These are the exact signals the adaptive controller should consume.

### 2.3 PHASE_IMPLEMENTATION_PLAN.md lines 142-149 (Execution priorities)

```
1. Keep scan loop running nonstop (balanced concurrency).
2. Keep persistence loop running and verify counts increasing.
5. Validate end-to-end before expanding next scan modules.
```

"Balanced concurrency" is explicitly cited as Priority 1 — confirming this is a design intent, not just an optimization.

### 2.4 persistence_gateway.py lines 56-57 (WAL mode)

```python
PRAGMA journal_mode=WAL;
PRAGMA synchronous=NORMAL;
```

WAL mode supports concurrent readers + one writer. The adaptive controller will run as an additional reader — no schema changes needed.

### 2.5 register_files (persistence_gateway.py lines 223-242)

`register_files()` updates `file_mtime`, `file_size`, `last_seen_ts` on every ingest loop. The delta between `file_mtime` and `last_seen_ts` = ingest lag (how stale result files are relative to disk).

---

## 3. Signal Inventory

The controller uses four signals from `scan_persistence.db`:

| Signal | Query | Interpretation |
|---|---|---|
| `chunk_error_rate_h` | `SELECT (100.0 * SUM(lines_in - lines_out) / NULLIF(SUM(lines_in),0)) FROM chunk_queue WHERE completed_at >= datetime('now','-1h')` | % input lines that produced no DNS answer; high = resolver saturation |
| `ingest_lag_s` | `SELECT ROUND(AVG((julianday('now') - julianday(last_seen_ts)) * 86400)) FROM files WHERE status='pending'` | Seconds since persistence gateway last saw pending files; high = gateway behind scan |
| `sink_lag_h` | `SELECT ROUND((julianday('now') - julianday(MIN(created_at)))*24.0, 2) FROM sink_outbox WHERE status IN ('PENDING','FAILED')` | Age of oldest unsent outbox row; high = sink backlog growing |
| `chunk_completion_rate_h` | `SELECT COUNT(*) FROM chunk_queue WHERE status='COMPLETED' AND completed_at >= datetime('now','-1h')` | Chunks completed in last hour; zero = no-progress |

---

## 4. Control Loop Design

### 4.1 Governor algorithm

```
Every evaluation_interval (default: 5 minutes):
  1. Read four signals from scan_persistence.db
  2. Classify operating zone (GREEN / YELLOW / RED) per signal
  3. If any signal in RED → decrease PARALLEL
  4. If all signals in GREEN for N consecutive evals → increase PARALLEL
  5. Write new PARALLEL value to state/parallel_setting.txt
  6. Scan loop reads PARALLEL from state/parallel_setting.txt at chunk boundary
```

### 4.2 Zone classification thresholds

| Signal | GREEN | YELLOW | RED |
|---|---|---|---|
| `chunk_error_rate_h` (%) | < 5% | 5-15% | > 15% |
| `ingest_lag_s` | < 120s | 120-300s | > 300s |
| `sink_lag_h` | < 1.0h | 1.0-2.0h | > 2.0h |
| `chunk_completion_rate_h` | >= 1 chunk | — | 0 (no progress) |

### 4.3 Adjustment rules

| Condition | Action | Magnitude |
|---|---|---|
| Any signal RED | Decrease PARALLEL | × 0.75 (step down 25%) |
| chunk_completion_rate_h = 0 for >= 2 evals | Decrease PARALLEL | × 0.5 (step down 50%) |
| All signals GREEN for >= 3 consecutive evals | Increase PARALLEL | × 1.20 (step up 20%) |
| Increase would exceed PARALLEL_MAX | Clamp at PARALLEL_MAX | (no change) |
| Decrease would go below PARALLEL_MIN | Clamp at PARALLEL_MIN | (no change) |

**Constants:**
```
PARALLEL_MIN = 4   (safe minimum; always enough parallelism to make progress)
PARALLEL_MAX = 96  (double the default; avoid DNS resolver saturation beyond this)
PARALLEL_DEFAULT = 48
EVAL_INTERVAL_S = 300  (5 minutes)
GREEN_STREAK_REQUIRED = 3  (consecutive evals before stepping up)
```

### 4.4 Anti-flap mechanism

To prevent rapid oscillation between PARALLEL values:
- Track `consecutive_increases` and `consecutive_decreases`
- After a decrease, enforce a `cooldown_evals=2` (10 minutes) before the next increase
- After an increase, enforce `cooldown_evals=1` (5 minutes) before the next decrease
- Never adjust more than once per evaluation cycle

---

## 5. Integration with run_full_dns_pass.sh

The scanner reads `PARALLEL` from an env var. The controller writes to `state/parallel_setting.txt`. A one-line modification to the script reads the file at chunk boundaries:

```bash
# Add after line 11 (inside while loop, before xargs call):
if [ -f "$BASE/state/parallel_setting.txt" ]; then
  PARALLEL=$(cat "$BASE/state/parallel_setting.txt")
fi
```

This is the **only modification required to run_full_dns_pass.sh**. The controller runs as a separate background process writing the setting file; the scanner picks it up at the next chunk boundary.

**No disruption to in-flight chunks:** The xargs already running at PARALLEL=48 finishes at its current setting. Only the next chunk starts at the new PARALLEL value.

---

## 6. Backpressure Propagation Chain

```
DNS Resolver Saturation (external)
    ↓ causes: chunk_error_rate_h > 15%
Controller detects RED zone
    ↓ decreases: PARALLEL 48 → 36
Fewer simultaneous DNS queries
    ↓ reduces: resolver timeout rate
Error rate drops to GREEN zone
    ↓ after 3 consecutive GREEN evals
Controller increases: PARALLEL 36 → 43
    ↓ (gentle ramp-up)
Steady state at optimized value

SQLite Write Pressure (internal)
    ↓ causes: ingest_lag_s > 300s (gateway falling behind)
Controller detects RED zone
    ↓ decreases: PARALLEL
Fewer new result lines per second
    ↓ gateway catches up
ingest_lag_s returns to GREEN
    ↓ PARALLEL restored
```

---

## 7. Tuning Rules (Measurable)

### Rule T1: Initial calibration
- Run 2 chunks at PARALLEL=48 (baseline)
- Record average chunk completion time and error rate
- If error_rate > 10%: start at PARALLEL=32

### Rule T2: Resolver saturation detection
- If chunk_error_rate_h rises from < 5% to > 15% within one 5-minute window: immediate decrease (do not wait for GREEN streak)
- Threshold rationale: DNS A-record resolution failure rate > 15% indicates resolver overload, not target absence

### Rule T3: Persistence gateway lag response
- If ingest_lag_s > 300s: reduce PARALLEL by 25% every eval until lag < 120s
- Rationale: Scan produces data faster than persistence consumes it; reducing scan rate relieves write pressure on SQLite WAL

### Rule T4: Sink backlog response
- If sink_lag_h > 2.0h: cap PARALLEL at current value (no further increase)
- Rationale: Sink backlog growing means CH/Neo4j cannot keep up; scanning faster makes it worse

### Rule T5: No-progress response
- If chunk_completion_rate_h = 0 for 2 consecutive evals (10 min): log WARNING and decrease PARALLEL by 50%
- If chunk_completion_rate_h = 0 for 6 consecutive evals (30 min): this triggers WO-00024 ALT-01 alert; controller logs CRITICAL and reduces PARALLEL to PARALLEL_MIN
- Rationale: If no chunks completing, extreme parallelism is not helping; reduce load to isolate root cause

### Rule T6: Scale-up ceiling
- Never increase PARALLEL above PARALLEL_MAX=96
- Never increase PARALLEL if any signal is YELLOW or RED
- Increase only by 20% per eval step (avoid sudden jumps that could re-saturate resolvers)

---

## 8. Variance Reduction Analysis

**Chunk completion variance** = max(chunk_duration) - min(chunk_duration) across all chunks in a session.

With PARALLEL=48 static:
- Fast chunks (small asset files, healthy resolvers): complete in ~15 min
- Slow chunks (large files, congested resolver path): may take 3+ hours
- Variance: up to 165 minutes

With adaptive control:
- Congested chunks detected by rising error_rate → PARALLEL reduced → fewer competing DNS requests → resolver recovers
- Fast chunks get PARALLEL maintained or increased → no degradation
- Expected effect: slow chunk duration decreases (resolver recovers from saturation); fast chunk duration unchanged
- Target variance reduction: >= 20% (from ~165 min to ~130 min or better)

---

## 9. Design Decisions

| ID | Decision | Rationale |
|---|---|---|
| DD-1 | Controller reads signals from SQLite (no new instrumentation) | All required signals already in scan_persistence.db; zero additional log parsing |
| DD-2 | PARALLEL written to file (not env var) | File is persistent across process restarts; env var would be lost on shell exit |
| DD-3 | One-line patch to run_full_dns_pass.sh | Minimal invasive change; scanner remains functional without controller |
| DD-4 | Green streak of 3 required before increase | Prevents overshoot after transient recovery; 15-min stability window before ramping up |
| DD-5 | Decrease magnitude 25% (not binary on/off) | Gradual reduction allows finding the optimal stable PARALLEL instead of oscillating between 0 and MAX |
| DD-6 | PARALLEL_MIN=4 (not 0) | Zero parallelism would halt scanning; 4 workers always makes measurable progress |

---

## 10. Risks

| ID | Risk | Severity | Mitigation |
|---|---|---|---|
| R1 | Controller reduces PARALLEL too aggressively; scan stalls | MEDIUM | PARALLEL_MIN=4 floor; ALT-01 alert fires if no chunk completes in 30min |
| R2 | chunk_error_rate_h metric unreliable if chunk size varies wildly | LOW | Normalize by lines_in denominator; handle NULLIF(SUM(lines_in),0) zero case |
| R3 | state/parallel_setting.txt read failure (disk error) | LOW | Scanner fallback: if file unreadable, use PARALLEL_DEFAULT=48 |
| R4 | Controller and scanner race at chunk boundary | NEGLIGIBLE | File write is atomic (single integer); chunk reads it at start of each iteration |

---

## 11. KPIs

| Metric | Target | Measurement |
|---|---|---|
| Chunk completion variance reduction | >= 20% | (max_duration - min_duration) with vs without controller |
| No-progress windows > 30min | Near-zero | COUNT of ALT-01 fires per 51-chunk run |
| Resolver timeout/error burst reduction | >= 25% | (SUM(lines_in - lines_out) / SUM(lines_in)) baseline vs adaptive |
| PARALLEL at steady state | 32-64 (expected optimal range) | Logged by controller every eval cycle |
| Controller evaluation overhead | < 100ms per eval | SQLite query time for 4 signals |

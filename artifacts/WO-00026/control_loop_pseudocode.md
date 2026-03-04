# Adaptive Concurrency Controller — Pseudocode
## File: `adaptive_controller.py`
**Source:** WO-00026 | trinity999/Pandavs-Framework@cebd2d5

---

## Overview

```
adaptive_controller.py
├── read_signals()             — 4 SQLite queries → signal dict
├── classify_zones()           — GREEN/YELLOW/RED per signal
├── evaluate_rules()           — match rules from tuning_policy.yaml
├── compute_adjustment()       — new PARALLEL value
├── write_parallel()           — atomic write to state/parallel_setting.txt
├── log_state()                — append to logs/parallel_history.csv
└── main_loop()                — eval every 300s indefinitely
```

---

## Full Pseudocode

```python
#!/usr/bin/env python3
"""
adaptive_controller.py
Reads scan/persistence/sink signals from scan_persistence.db and
adjusts PARALLEL concurrency setting for run_full_dns_pass.sh.

Reads:  scan_persistence.db (WAL mode, read-only queries)
Writes: state/parallel_setting.txt (atomic rename)
Logs:   logs/adaptive_controller.log
        logs/parallel_history.csv
"""

import csv
import math
import os
import sqlite3
import time
import logging
import yaml
from datetime import datetime, timezone
from pathlib import Path

# ── Config ────────────────────────────────────────────────────────────────────
DB_PATH            = "state/scan_persistence.db"
POLICY_PATH        = "adaptive_tuning_policy.yaml"   # = tuning_policy.yaml renamed
PARALLEL_SETTING   = "state/parallel_setting.txt"
PARALLEL_HISTORY   = "logs/parallel_history.csv"
EVAL_INTERVAL_S    = 300
PARALLEL_DEFAULT   = 48
PARALLEL_MIN       = 4
PARALLEL_MAX       = 96

log = logging.getLogger("adaptive_ctrl")
logging.basicConfig(level=logging.INFO,
    format="%(asctime)s [%(levelname)s] adaptive_ctrl — %(message)s")


# ── State ─────────────────────────────────────────────────────────────────────
class ControllerState:
    def __init__(self, parallel: int = PARALLEL_DEFAULT):
        self.parallel = parallel
        self.consecutive_green_evals = 0
        self.consecutive_red_evals = 0      # any-signal-red streak
        self.no_progress_evals = 0          # chunk_completion_rate_h=0 streak
        self.last_adjustment_eval = -999
        self.last_increase_eval = -999
        self.last_decrease_eval = -999
        self.eval_count = 0
        self.adjustments_this_hour = []     # list of epoch timestamps


# ── Signal reading ────────────────────────────────────────────────────────────
SIGNAL_QUERIES = {
    "chunk_error_rate_h": """
        SELECT ROUND(
            100.0 * SUM(lines_in - lines_out) / NULLIF(SUM(lines_in), 0), 2
        ) AS v
        FROM chunk_queue
        WHERE status = 'COMPLETED'
          AND completed_at >= datetime('now', '-1 hour')
    """,
    "ingest_lag_s": """
        SELECT ROUND(
            AVG((julianday('now') - julianday(last_seen_ts)) * 86400.0)
        ) AS v
        FROM files
        WHERE status = 'pending'
    """,
    "sink_lag_h": """
        SELECT ROUND(
            (julianday('now') - julianday(MIN(created_at))) * 24.0, 2
        ) AS v
        FROM sink_outbox
        WHERE status IN ('PENDING', 'FAILED')
    """,
    "chunk_completion_rate_h": """
        SELECT COUNT(*) AS v
        FROM chunk_queue
        WHERE status = 'COMPLETED'
          AND completed_at >= datetime('now', '-1 hour')
    """,
}


def read_signals(db_path: str) -> dict:
    """Read all four monitoring signals from SQLite. Returns dict of signal_name -> value (or None)."""
    conn = sqlite3.connect(db_path, timeout=10)
    conn.row_factory = sqlite3.Row
    signals = {}
    for name, query in SIGNAL_QUERIES.items():
        try:
            row = conn.execute(query).fetchone()
            signals[name] = row["v"] if row else None
        except Exception as e:
            log.warning(f"Signal {name} query failed: {e}")
            signals[name] = None
    conn.close()
    return signals


# ── Zone classification ───────────────────────────────────────────────────────
def classify_zone(signal_name: str, value) -> str:
    """Classify a signal value into GREEN / YELLOW / RED."""
    if value is None:
        # All signals use null_behavior: green
        return "GREEN"

    thresholds = {
        "chunk_error_rate_h": {"green_max": 5.0, "red_min": 15.0},
        "ingest_lag_s":        {"green_max": 120,  "red_min": 300},
        "sink_lag_h":          {"green_max": 1.0,  "red_min": 2.0},
        "chunk_completion_rate_h": {"green_min": 1},   # special: lower is worse
    }
    t = thresholds.get(signal_name, {})

    if signal_name == "chunk_completion_rate_h":
        if value >= t.get("green_min", 1):
            return "GREEN"
        return "RED"  # 0 chunks/hour

    if value <= t.get("green_max", float("inf")):
        return "GREEN"
    if value >= t.get("red_min", float("inf")):
        return "RED"
    return "YELLOW"


def classify_all_zones(signals: dict) -> dict:
    return {name: classify_zone(name, val) for name, val in signals.items()}


# ── Adjustment logic ──────────────────────────────────────────────────────────
def compute_new_parallel(zones: dict, state: ControllerState) -> tuple:
    """
    Returns (new_parallel, reason_str)
    Applies rules in priority order.
    """
    current = state.parallel
    eval_n = state.eval_count
    now_epoch = time.time()

    # Anti-flap: cap adjustments per hour
    state.adjustments_this_hour = [t for t in state.adjustments_this_hour
                                    if now_epoch - t < 3600]
    if len(state.adjustments_this_hour) >= 8:
        return current, "anti_flap: max 8 adjustments/hour reached"

    any_red   = any(z == "RED"    for z in zones.values())
    any_yellow = any(z == "YELLOW" for z in zones.values())
    all_green  = all(z == "GREEN"  for z in zones.values())
    no_progress = zones["chunk_completion_rate_h"] == "RED"

    # Track streaks
    if all_green:
        state.consecutive_green_evals += 1
        state.consecutive_red_evals = 0
    elif any_red:
        state.consecutive_red_evals += 1
        state.consecutive_green_evals = 0
    else:  # yellow
        state.consecutive_green_evals = 0
        state.consecutive_red_evals = 0

    if no_progress:
        state.no_progress_evals += 1
    else:
        state.no_progress_evals = 0

    # Rule R5: Emergency (no progress 30min = 6 evals)
    if state.no_progress_evals >= 6:
        new_p = PARALLEL_MIN
        return new_p, "R5_emergency_no_progress_30min"

    # Rule R4: Hard reduction (no progress 10min = 2 evals)
    if state.no_progress_evals >= 2:
        if eval_n - state.last_decrease_eval >= 3:  # cooldown 3 evals
            new_p = max(PARALLEL_MIN, int(current * 0.50))
            state.last_decrease_eval = eval_n
            state.adjustments_this_hour.append(now_epoch)
            return new_p, "R4_no_progress_10min_50pct_reduction"

    # Rule R1/R2: Error rate or ingest lag RED
    if zones["chunk_error_rate_h"] == "RED" or zones["ingest_lag_s"] == "RED":
        if eval_n - state.last_decrease_eval >= 2:  # cooldown 2 evals
            new_p = max(PARALLEL_MIN, int(current * 0.75))
            state.last_decrease_eval = eval_n
            state.adjustments_this_hour.append(now_epoch)
            reason = "R1_error_rate_red" if zones["chunk_error_rate_h"] == "RED" else "R2_ingest_lag_red"
            return new_p, reason

    # Rule R3: Sink backlog RED — hold (no increase allowed)
    if zones["sink_lag_h"] == "RED":
        return current, "R3_sink_lag_red_hold"

    # Rule R7: Any YELLOW — hold
    if any_yellow:
        return current, "R7_yellow_hold"

    # Rule R6: All GREEN streak — step up
    if all_green and state.consecutive_green_evals >= 3:
        if eval_n - state.last_increase_eval >= 1:  # cooldown 1 eval
            new_p = min(PARALLEL_MAX, int(current * 1.20))
            if new_p != current:
                state.last_increase_eval = eval_n
                state.adjustments_this_hour.append(now_epoch)
                return new_p, f"R6_green_streak_{state.consecutive_green_evals}_evals"

    return current, "no_change"


# ── Output ────────────────────────────────────────────────────────────────────
def write_parallel(parallel: int, setting_file: str) -> None:
    """Atomically write PARALLEL value to setting file."""
    tmp = setting_file + ".tmp"
    with open(tmp, "w") as f:
        f.write(str(parallel))
    os.replace(tmp, setting_file)   # atomic rename on POSIX


def log_state(parallel: int, reason: str, signals: dict, zones: dict,
              history_file: str) -> None:
    """Append one row to parallel_history.csv."""
    now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    row = {
        "ts": now,
        "parallel": parallel,
        "reason": reason,
        "chunk_error_rate_h": signals.get("chunk_error_rate_h"),
        "ingest_lag_s": signals.get("ingest_lag_s"),
        "sink_lag_h": signals.get("sink_lag_h"),
        "chunk_completion_rate_h": signals.get("chunk_completion_rate_h"),
        "zones": str({k: v for k, v in zones.items()}),
    }
    write_header = not Path(history_file).exists()
    with open(history_file, "a", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=list(row.keys()))
        if write_header:
            writer.writeheader()
        writer.writerow(row)


# ── Main loop ─────────────────────────────────────────────────────────────────
def main_loop(db_path: str = DB_PATH, eval_interval: int = EVAL_INTERVAL_S) -> None:
    state = ControllerState()

    # Restore previous PARALLEL if setting file exists
    if Path(PARALLEL_SETTING).exists():
        try:
            state.parallel = int(open(PARALLEL_SETTING).read().strip())
            log.info(f"Restored PARALLEL={state.parallel} from {PARALLEL_SETTING}")
        except Exception:
            log.warning("Could not read existing parallel_setting.txt; using default")

    log.info(f"Adaptive controller started — db={db_path}, interval={eval_interval}s, "
             f"parallel={state.parallel}")

    while True:
        t0 = time.time()
        state.eval_count += 1

        try:
            signals = read_signals(db_path)
            zones = classify_all_zones(signals)
            new_parallel, reason = compute_new_parallel(zones, state)

            if new_parallel != state.parallel:
                log.info(f"PARALLEL: {state.parallel} → {new_parallel} (reason: {reason})")
                state.parallel = new_parallel
                write_parallel(new_parallel, PARALLEL_SETTING)
            else:
                log.debug(f"PARALLEL unchanged: {state.parallel} (reason: {reason})")
                write_parallel(state.parallel, PARALLEL_SETTING)  # keep file fresh

            log_state(state.parallel, reason, signals, zones, PARALLEL_HISTORY)

        except Exception as e:
            log.error(f"Eval {state.eval_count} failed: {e}")
            # On failure: keep current PARALLEL; do not modify setting file

        elapsed = time.time() - t0
        sleep_s = max(0, eval_interval - elapsed)
        time.sleep(sleep_s)


if __name__ == "__main__":
    import argparse
    p = argparse.ArgumentParser(description="Pandavs Adaptive Concurrency Controller")
    p.add_argument("--db", default=DB_PATH)
    p.add_argument("--interval", type=int, default=EVAL_INTERVAL_S)
    args = p.parse_args()
    main_loop(args.db, args.interval)
```

---

## Scanner Integration Patch

Add the following 4 lines inside the while loop of `run_full_dns_pass.sh`, immediately before the `awk | xargs` command:

```bash
# Read adaptive PARALLEL setting if available (adaptive_controller.py manages this file)
if [ -f "$BASE/state/parallel_setting.txt" ]; then
  PARALLEL=$(cat "$BASE/state/parallel_setting.txt" 2>/dev/null || echo "$PARALLEL")
  echo "[$(date -u +%FT%TZ)] PARALLEL_SETTING $PARALLEL" | tee -a "$LOG"
fi
```

This is the complete modification to the scanner. The controller is fully independent — the scanner falls back to the original `PARALLEL` env var if the file doesn't exist.

---

## Deployment

```bash
# Start adaptive controller (background, persistent)
nice -n 15 python3 adaptive_controller.py \
    --db /root/.openclaw/workspace/UserFiles/Pandavs-Framework/ops/day1/state/scan_persistence.db \
    --interval 300 >> logs/adaptive_controller.log 2>&1 &

# Monitor PARALLEL changes
tail -f logs/parallel_history.csv

# Check current PARALLEL
cat state/parallel_setting.txt

# Run scanner (now reads from setting file at each chunk boundary)
bash run_full_dns_pass.sh
```

---

## Variance Measurement

Record before/after metrics using:

```sql
-- Chunk duration variance query:
SELECT
    MIN(ROUND((julianday(completed_at) - julianday(leased_at)) * 86400)) AS min_chunk_s,
    MAX(ROUND((julianday(completed_at) - julianday(leased_at)) * 86400)) AS max_chunk_s,
    ROUND(AVG((julianday(completed_at) - julianday(leased_at)) * 86400)) AS avg_chunk_s,
    MAX(ROUND((julianday(completed_at) - julianday(leased_at)) * 86400)) -
    MIN(ROUND((julianday(completed_at) - julianday(leased_at)) * 86400)) AS variance_s
FROM chunk_queue
WHERE status = 'COMPLETED'
  AND leased_at IS NOT NULL;
```

Target: `variance_s` reduced by >= 20% vs baseline (static PARALLEL=48 run).

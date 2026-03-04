# ClickHouse Sink Worker — Implementation Specification
## File: `clickhouse_sink_worker.py`
**Source:** WO-00028 | trinity999/Pandavs-Framework@cebd2d5

---

## Module Structure

```
clickhouse_sink_worker.py
├── constants / config
├── build_ch_client()           — connect to CH; raise on auth failure
├── check_ch_health()           — SELECT 1 preflight
├── claim_outbox_batch()        — BEGIN IMMEDIATE claim; returns list[dict]
├── release_stale_claims()      — reaper: CLAIMED rows older than timeout → PENDING
├── fetch_events_for_batch()    — bulk SELECT from events table
├── build_ch_rows()             — map SQLite Event dicts → CH row dicts
├── clickhouse_batch_insert()   — execute INSERT; return (success_ids, failed)
├── classify_error()            — map exception → RETRYABLE/NON_RETRYABLE/ALREADY_SYNCED
├── record_outcomes()           — UPDATE outbox + INSERT ledger in SQLite tx
├── promote_to_dlq()            — INSERT dead_letter_events, UPDATE outbox DEAD_LETTER
├── run_sweep()                 — one full batch cycle (claim → insert → record)
├── run_once()                  — run until outbox empty, then exit
├── run_loop()                  — run_sweep every interval_s indefinitely
└── cli_main()                  — argparse: run-once / loop / status
```

---

## Full Worker Pseudocode

```python
#!/usr/bin/env python3
"""
clickhouse_sink_worker.py
Reads PENDING/FAILED outbox rows for sink_target='clickhouse' and delivers
them to ClickHouse pandavs_recon.scan_events using native protocol.

Dependencies:
    pip install clickhouse-driver

Database: scan_persistence.db (WAL mode, managed by persistence_gateway.py)
Tables:   sink_outbox, events, event_sync_ledger, dead_letter_events (all from WO-00023)
"""

import argparse
import json
import logging
import sqlite3
import time
import uuid
from datetime import datetime, timezone
from typing import Dict, List, Optional, Tuple

# ── Config ────────────────────────────────────────────────────────────────────
CH_HOST         = "127.0.0.1"
CH_PORT         = 9000
CH_USER         = "default"
CH_PASSWORD     = "pandavs_ch_2026"
CH_DATABASE     = "pandavs_recon"
CH_TABLE        = "scan_events"
DEFAULT_DB      = "state/scan_persistence.db"
BATCH_SIZE      = 500          # rows per ClickHouse insert block
CLAIM_TIMEOUT_S = 600          # seconds before stale CLAIMED rows are released
SLEEP_INTERVAL  = 60           # seconds between sweeps in loop mode
BACKOFF_BASE_S  = 300          # base for exponential backoff (seconds)
BACKOFF_MAX_S   = 14400        # 4 hours max
MAX_RETRIES     = 5

log = logging.getLogger("ch_sink_worker")
logging.basicConfig(level=logging.INFO,
    format="%(asctime)s [%(levelname)s] ch_sink_worker — %(message)s")


# ── DB helpers ────────────────────────────────────────────────────────────────
def open_db(path: str) -> sqlite3.Connection:
    conn = sqlite3.connect(path, timeout=30)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA foreign_keys=ON")
    return conn

def utc_now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

def add_seconds(ts_iso: str, seconds: int) -> str:
    from datetime import datetime, timezone
    dt = datetime.fromisoformat(ts_iso.replace("Z", "+00:00"))
    from datetime import timedelta
    return (dt + timedelta(seconds=seconds)).strftime("%Y-%m-%dT%H:%M:%SZ")


# ── Claim protocol ────────────────────────────────────────────────────────────
def claim_outbox_batch(conn: sqlite3.Connection, batch_size: int,
                       worker_id: str) -> List[dict]:
    """
    Atomically mark up to `batch_size` PENDING/FAILED+ready rows as CLAIMED.
    Uses BEGIN IMMEDIATE (same pattern as WO-00022) to prevent double-claim.
    """
    now = utc_now()
    conn.isolation_level = None
    conn.execute("BEGIN IMMEDIATE")
    try:
        rows = conn.execute("""
            SELECT outbox_id, event_id, retry_count, max_retries
            FROM sink_outbox
            WHERE sink_target = 'clickhouse'
              AND status IN ('PENDING', 'FAILED')
              AND (next_retry_at IS NULL OR next_retry_at <= :now)
            ORDER BY outbox_id ASC
            LIMIT :bs
        """, {"now": now, "bs": batch_size}).fetchall()

        if not rows:
            conn.execute("ROLLBACK")
            return []

        ids = [r["outbox_id"] for r in rows]
        ph = ",".join("?" * len(ids))
        conn.execute(f"""
            UPDATE sink_outbox
            SET status = 'CLAIMED',
                last_error_message = 'worker_id:{worker_id}',
                updated_at = '{now}'
            WHERE outbox_id IN ({ph})
        """, ids)
        conn.execute("COMMIT")
        return [dict(r) for r in rows]
    except Exception:
        conn.execute("ROLLBACK")
        raise


def release_stale_claims(conn: sqlite3.Connection, timeout_s: int = CLAIM_TIMEOUT_S) -> int:
    """
    Reaper: any row stuck in CLAIMED for > timeout_s returns to PENDING.
    Run at worker startup and every N sweeps.
    """
    now = utc_now()
    # updated_at for CLAIMED rows is set when claim happened; compute cutoff
    cutoff = add_seconds(now, -timeout_s)
    cur = conn.execute("""
        UPDATE sink_outbox
        SET status = 'PENDING', last_error_message = 'reclaimed_after_timeout', updated_at = ?
        WHERE sink_target = 'clickhouse'
          AND status = 'CLAIMED'
          AND updated_at <= ?
    """, (now, cutoff))
    conn.commit()
    return cur.rowcount


# ── Event fetch ───────────────────────────────────────────────────────────────
def fetch_events(conn: sqlite3.Connection, event_ids: List[str]) -> Dict[str, dict]:
    ph = ",".join("?" * len(event_ids))
    rows = conn.execute(
        f"SELECT * FROM events WHERE event_id IN ({ph})", event_ids
    ).fetchall()
    return {r["event_id"]: dict(r) for r in rows}


# ── ClickHouse integration ────────────────────────────────────────────────────
def build_ch_client():
    from clickhouse_driver import Client
    return Client(
        host=CH_HOST, port=CH_PORT,
        user=CH_USER, password=CH_PASSWORD,
        database=CH_DATABASE,
        settings={
            "insert_deduplicate": True,
            "connect_timeout": 10,
            "send_receive_timeout": 120,
        }
    )

def check_ch_health(client) -> bool:
    try:
        result = client.execute("SELECT 1")
        return result == [(1,)]
    except Exception as e:
        log.warning(f"CH health check failed: {e}")
        return False


def parse_ts(ts_str: str):
    """Convert ISO8601 string to datetime (ClickHouse native protocol requires datetime)."""
    try:
        return datetime.fromisoformat(ts_str.replace("Z", "+00:00"))
    except Exception:
        return datetime.now(timezone.utc)


def build_ch_rows(events: List[dict]) -> List[dict]:
    rows = []
    for ev in events:
        rows.append({
            "event_id":    ev["event_id"],
            "tool":        ev["tool"],
            "event_kind":  ev["event_kind"],
            "asset":       ev.get("asset"),
            "value":       ev.get("value"),
            "port":        ev.get("port"),
            "status":      ev.get("status"),
            "ts":          parse_ts(ev["ts"]),
            "source_file": ev["source_file"],
            "line_no":     ev["line_no"],
            "raw_json":    ev["raw_json"][:1_000_000],  # cap at 1MB
        })
    return rows


def clickhouse_batch_insert(client, rows: List[dict]) -> None:
    """
    Insert rows into scan_events. Raises on error.
    ReplacingMergeTree handles deduplication by event_id asynchronously.
    """
    client.execute(
        f"INSERT INTO {CH_TABLE} (event_id, tool, event_kind, asset, value, port, "
        f"status, ts, source_file, line_no, raw_json) VALUES",
        rows,
        types_check=True,
    )


# ── Error classification ──────────────────────────────────────────────────────
# Sourced from WO-00023 retry_taxonomy.json ClickHouse rules (CH-R01..CH-R11)
RETRYABLE_PATTERNS = [
    "NETWORK_ERROR", "TIMEOUT", "CONNECT_TIMEOUT", "RECEIVE_TIMEOUT",
    "SERVER_OVERLOADED", "MEMORY_LIMIT_EXCEEDED", "TOO_MANY_SIMULTANEOUS_QUERIES",
    "SOCKET_TIMEOUT", "BROKEN_PIPE", "ConnectionRefusedError",
    "ServiceUnavailable",
]
NON_RETRYABLE_PATTERNS = [
    "BAD_ARGUMENTS", "UNKNOWN_TABLE", "TYPE_MISMATCH", "UNKNOWN_TYPE",
    "CANNOT_PARSE", "ILLEGAL_COLUMN", "AUTHORIZATION_FAILED",
    "AUTHENTICATION_FAILED", "AuthError",
]

def classify_error(exc: Exception) -> str:
    msg = str(exc)
    for p in NON_RETRYABLE_PATTERNS:
        if p in msg:
            return "NON_RETRYABLE"
    for p in RETRYABLE_PATTERNS:
        if p in msg:
            return "RETRYABLE"
    return "RETRYABLE"  # default: assume transient unless known otherwise


# ── Outcome recording ─────────────────────────────────────────────────────────
def record_success(conn: sqlite3.Connection, outbox_rows: List[dict],
                   batch_id: str, duration_ms: int) -> None:
    now = utc_now()
    for row in outbox_rows:
        oid = row["outbox_id"]
        eid = row["event_id"]
        attempt = row.get("retry_count", 0) + 1

        conn.execute("""
            UPDATE sink_outbox
            SET status='SYNCED', synced_at=:now, updated_at=:now
            WHERE outbox_id=:oid
        """, {"now": now, "oid": oid})

        conn.execute("""
            INSERT OR IGNORE INTO event_sync_ledger
                (event_id, sink_target, synced_at, delivery_attempt,
                 batch_id, rows_written, duration_ms)
            VALUES (:eid, 'clickhouse', :now, :attempt, :batch_id, 1, :dur)
        """, {"eid": eid, "now": now, "attempt": attempt,
              "batch_id": batch_id, "dur": duration_ms})

    conn.commit()
    log.info(f"Batch {batch_id}: {len(outbox_rows)} rows SYNCED")


def record_retryable_failure(conn: sqlite3.Connection, row: dict,
                              error_class: str, error_msg: str) -> None:
    now = utc_now()
    retry_count = row.get("retry_count", 0) + 1
    max_retries = row.get("max_retries", MAX_RETRIES)

    if retry_count >= max_retries:
        promote_to_dlq(conn, row, "NON_RETRYABLE (max_retries exhausted)", error_msg)
        return

    backoff_s = min(BACKOFF_BASE_S * (2 ** retry_count), BACKOFF_MAX_S)
    next_retry = add_seconds(now, backoff_s)

    conn.execute("""
        UPDATE sink_outbox
        SET status='FAILED', retry_count=:rc, next_retry_at=:nr,
            last_error_class=:cls, last_error_message=:msg,
            last_failed_at=:now, updated_at=:now
        WHERE outbox_id=:oid
    """, {"rc": retry_count, "nr": next_retry, "cls": error_class,
          "msg": error_msg[:1024], "now": now, "oid": row["outbox_id"]})

    conn.execute("""
        INSERT INTO sink_outbox_retry_log
            (outbox_id, event_id, sink_target, attempt_number, attempted_at,
             error_class, error_message, outcome)
        VALUES (:oid, :eid, 'clickhouse', :attempt, :now, :cls, :msg, 'FAILED')
    """, {"oid": row["outbox_id"], "eid": row["event_id"],
          "attempt": retry_count, "now": now, "cls": error_class,
          "msg": error_msg[:1024]})

    conn.commit()
    log.warning(f"Outbox {row['outbox_id']} retry {retry_count}/{max_retries}, "
                f"next at {next_retry}")


def promote_to_dlq(conn: sqlite3.Connection, row: dict,
                   final_error_class: str, final_error_msg: str) -> None:
    now = utc_now()
    total_attempts = row.get("retry_count", 0) + 1

    event = conn.execute(
        "SELECT raw_json FROM events WHERE event_id=?", (row["event_id"],)
    ).fetchone()
    raw_snapshot = event["raw_json"] if event else "{}"

    conn.execute("""
        INSERT OR IGNORE INTO dead_letter_events
            (event_id, sink_target, final_error_class, final_error_message,
             total_attempts, first_attempted_at, raw_json_snapshot)
        VALUES (:eid, 'clickhouse', :cls, :msg, :attempts, :now, :raw)
    """, {"eid": row["event_id"], "cls": final_error_class,
          "msg": final_error_msg[:2048], "attempts": total_attempts,
          "now": now, "raw": raw_snapshot})

    conn.execute("""
        UPDATE sink_outbox
        SET status='DEAD_LETTER', updated_at=:now
        WHERE outbox_id=:oid
    """, {"now": now, "oid": row["outbox_id"]})

    conn.commit()
    log.error(f"Event {row['event_id']} promoted to DLQ: {final_error_class}")


# ── Main sweep ────────────────────────────────────────────────────────────────
def run_sweep(conn: sqlite3.Connection, ch_client, worker_id: str,
              batch_size: int = BATCH_SIZE) -> int:
    """
    Execute one full batch cycle.
    Returns: number of events processed in this sweep.
    """
    # Reap any stale CLAIMED rows (from previous crashed run)
    reclaimed = release_stale_claims(conn)
    if reclaimed:
        log.info(f"Reclaimed {reclaimed} stale CLAIMED rows → PENDING")

    # Preflight health check
    if not check_ch_health(ch_client):
        log.warning("ClickHouse unreachable — skipping sweep, will retry next interval")
        return 0

    outbox_rows = claim_outbox_batch(conn, batch_size, worker_id)
    if not outbox_rows:
        log.debug("Outbox empty (clickhouse) — nothing to do")
        return 0

    event_ids = [r["event_id"] for r in outbox_rows]
    events_map = fetch_events(conn, event_ids)

    # Build CH row list, skip events not found (data integrity issue)
    found_rows = [r for r in outbox_rows if r["event_id"] in events_map]
    missing_ids = set(event_ids) - set(events_map.keys())
    if missing_ids:
        log.error(f"Missing events in SQLite for {len(missing_ids)} outbox rows — "
                  f"promoting to DLQ")
        for r in outbox_rows:
            if r["event_id"] in missing_ids:
                promote_to_dlq(conn, r, "NON_RETRYABLE",
                               "event_id not found in events table")

    batch_id = str(uuid.uuid4())
    ch_rows = build_ch_rows([events_map[r["event_id"]] for r in found_rows])

    t0 = time.time()
    try:
        clickhouse_batch_insert(ch_client, ch_rows)
        duration_ms = int((time.time() - t0) * 1000)
        record_success(conn, found_rows, batch_id, duration_ms)
        return len(found_rows)
    except Exception as exc:
        duration_ms = int((time.time() - t0) * 1000)
        error_class = classify_error(exc)
        error_msg = str(exc)
        log.error(f"Batch insert failed ({error_class}): {error_msg[:256]}")
        # Per-row: mark all found_rows with same error
        for r in found_rows:
            if error_class == "NON_RETRYABLE":
                promote_to_dlq(conn, r, error_class, error_msg)
            else:
                record_retryable_failure(conn, r, error_class, error_msg)
        return 0


# ── Entry points ──────────────────────────────────────────────────────────────
def run_once(db_path: str, batch_size: int = BATCH_SIZE) -> None:
    worker_id = str(uuid.uuid4())[:8]
    conn = open_db(db_path)
    client = build_ch_client()
    log.info(f"Worker {worker_id} — run-once mode, batch_size={batch_size}")
    total = 0
    while True:
        processed = run_sweep(conn, client, worker_id, batch_size)
        total += processed
        if processed == 0:
            break
    log.info(f"run-once complete — {total} events processed")
    conn.close()


def run_loop(db_path: str, interval_s: int = SLEEP_INTERVAL,
             batch_size: int = BATCH_SIZE) -> None:
    worker_id = str(uuid.uuid4())[:8]
    conn = open_db(db_path)
    client = build_ch_client()
    log.info(f"Worker {worker_id} — loop mode, interval={interval_s}s, "
             f"batch_size={batch_size}")
    while True:
        run_sweep(conn, client, worker_id, batch_size)
        time.sleep(interval_s)


def print_status(db_path: str) -> None:
    conn = open_db(db_path)
    rows = conn.execute("""
        SELECT status, COUNT(*) as cnt
        FROM sink_outbox
        WHERE sink_target = 'clickhouse'
        GROUP BY status
    """).fetchall()
    print("ClickHouse outbox status:")
    for r in rows:
        print(f"  {r['status']:15s}: {r['cnt']:>8d}")
    lag = conn.execute("""
        SELECT ROUND((julianday('now') - julianday(MIN(created_at)))*24, 2) as lag_h
        FROM sink_outbox
        WHERE sink_target='clickhouse' AND status IN ('PENDING','FAILED')
    """).fetchone()
    if lag and lag['lag_h']:
        print(f"  Oldest pending age: {lag['lag_h']}h")
    conn.close()


def cli_main():
    p = argparse.ArgumentParser(description="ClickHouse Sink Worker")
    sub = p.add_subparsers(dest="cmd")
    ro = sub.add_parser("run-once", help="Process all pending rows then exit")
    ro.add_argument("--db", default=DEFAULT_DB)
    ro.add_argument("--batch-size", type=int, default=BATCH_SIZE)
    lp = sub.add_parser("loop", help="Run continuously")
    lp.add_argument("--db", default=DEFAULT_DB)
    lp.add_argument("--interval", type=int, default=SLEEP_INTERVAL)
    lp.add_argument("--batch-size", type=int, default=BATCH_SIZE)
    st = sub.add_parser("status", help="Print outbox status")
    st.add_argument("--db", default=DEFAULT_DB)
    args = p.parse_args()

    if args.cmd == "run-once":
        run_once(args.db, args.batch_size)
    elif args.cmd == "loop":
        run_loop(args.db, args.interval, args.batch_size)
    elif args.cmd == "status":
        print_status(args.db)
    else:
        p.print_help()


if __name__ == "__main__":
    cli_main()
```

---

## Setup: ClickHouse Table DDL

Run once in ClickHouse before starting the worker:

```sql
-- Create database (safe if exists)
CREATE DATABASE IF NOT EXISTS pandavs_recon;

-- Main events table with ReplacingMergeTree for idempotent replay
CREATE TABLE IF NOT EXISTS pandavs_recon.scan_events
(
    event_id        String,
    tool            LowCardinality(String),
    event_kind      LowCardinality(String),
    asset           Nullable(String),
    value           Nullable(String),
    port            Nullable(Int32),
    status          Nullable(String),
    ts              DateTime64(3, 'UTC'),
    source_file     String,
    line_no         UInt32,
    raw_json        String,
    ingested_at     DateTime64(3, 'UTC') DEFAULT now64()
)
ENGINE = ReplacingMergeTree(ingested_at)
PARTITION BY toYYYYMM(ts)
ORDER BY (event_id)
PRIMARY KEY (event_id)
SETTINGS index_granularity = 8192;

-- Fast lookup indexes
ALTER TABLE pandavs_recon.scan_events ADD INDEX idx_tool (tool) TYPE bloom_filter GRANULARITY 1;
ALTER TABLE pandavs_recon.scan_events ADD INDEX idx_kind (event_kind) TYPE bloom_filter GRANULARITY 1;
ALTER TABLE pandavs_recon.scan_events ADD INDEX idx_asset (asset) TYPE bloom_filter GRANULARITY 3;

-- Integrity check (use FINAL for dedup-correct count)
-- SELECT count() FROM pandavs_recon.scan_events FINAL;
```

---

## Deployment

```bash
# Install dependency
pip install clickhouse-driver

# Backfill existing outbox rows
python3 clickhouse_sink_worker.py run-once \
    --db /root/.openclaw/workspace/UserFiles/Pandavs-Framework/ops/day1/state/scan_persistence.db \
    --batch-size 500

# Continuous sync (60s interval)
nice -n 10 python3 clickhouse_sink_worker.py loop \
    --db /root/.openclaw/workspace/UserFiles/Pandavs-Framework/ops/day1/state/scan_persistence.db \
    --interval 60

# Status check
python3 clickhouse_sink_worker.py status \
    --db /root/.openclaw/workspace/UserFiles/Pandavs-Framework/ops/day1/state/scan_persistence.db
```

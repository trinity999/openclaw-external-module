# WO-00022 — Chunk Worker State Machine
## Lease / Heartbeat / Reaper / Ack — Implementation Reference

**Version:** 1.0
**Produced:** 2026-03-04
**Target file:** `ops/day1/queue_controller.py` (new file to create)

---

## 1. State Machine Diagram

```
                      populate_chunk_queue()
                              │
                              ▼
                         [ PENDING ]
                              │
              grant_lease() ──┘ (BEGIN IMMEDIATE)
                              │
                              ▼
                         [ LEASED ] ──── heartbeat() every 60s ────┐
                              │                                      │
                    ┌─────────┼──────────────────┐                  │
                    │         │                  │                   │
              success      failure          lease_expires_at        │
             (ack_chunk)  (ack_chunk)       < now AND no heartbeat  │
                    │         │                  │                   │
                    ▼         ▼                  ▼                  │
              [COMPLETED]  [FAILED]          reaper()               │
                          (if retry_count    reclaim_stale_leases() │
                           < max_retries)           │               │
                               │                   └──► [PENDING]   │
                               │  retry_count >= max_retries        │
                               ▼                                    │
                        [FAILED_PERMANENT]                          │
                         (human review)                             │
                                                        ────────────┘
                                                        (heartbeat loop)
```

---

## 2. Function Signatures and Implementation

### 2.1 `ensure_chunk_queue(conn)`

```python
def ensure_chunk_queue(conn: sqlite3.Connection) -> None:
    """Apply schema_patch.sql to the connection. Idempotent."""
    with open("artifacts/WO-00022/schema_patch.sql") as f:
        conn.executescript(f.read())
    conn.commit()
```

---

### 2.2 `populate_chunk_queue(db_path, queue_file)`

```python
import hashlib, sqlite3

def populate_chunk_queue(db_path: str, queue_file: str) -> int:
    """
    Seed chunk_queue from dnsx_queue.txt.
    Idempotent: INSERT OR IGNORE — safe to call multiple times.
    Returns number of NEW rows inserted.
    """
    chunks = []
    with open(queue_file) as f:
        for line in f:
            path = line.strip()
            if path:
                chunks.append(path)

    conn = sqlite3.connect(db_path, timeout=30)
    ensure_chunk_queue(conn)

    inserted = 0
    now = utc_now()
    for chunk_path in chunks:
        chunk_id = hashlib.sha256(chunk_path.encode()).hexdigest()[:16]
        cur = conn.execute("""
            INSERT OR IGNORE INTO chunk_queue
              (chunk_id, chunk_file_path, status, created_at, updated_at)
            VALUES (?, ?, 'PENDING', ?, ?)
        """, (chunk_id, chunk_path, now, now))
        if cur.rowcount > 0:
            conn.execute("""
                INSERT INTO chunk_queue_audit_log
                  (chunk_id, from_status, to_status, event_type, detail, logged_at)
                VALUES (?, NULL, 'PENDING', 'SEEDED', ?, ?)
            """, (chunk_id, f'{{"path":"{chunk_path}"}}', now))
            inserted += 1

    conn.commit()
    conn.close()
    return inserted
```

---

### 2.3 `grant_lease(db_path, worker_id, lease_ttl_s=7200)`

```python
import sqlite3, time
from dataclasses import dataclass
from typing import Optional

@dataclass
class ChunkLease:
    chunk_id: str
    chunk_file_path: str
    worker_id: str
    leased_at: str
    lease_expires_at: str

def grant_lease(db_path: str, worker_id: str, lease_ttl_s: int = 7200) -> Optional[ChunkLease]:
    """
    Atomically claim the next PENDING chunk.
    Uses BEGIN IMMEDIATE to serialize concurrent workers.
    Returns ChunkLease or None if queue is exhausted.

    CRITICAL: isolation_level=None + BEGIN IMMEDIATE is the correct pattern.
    Do NOT use conn.execute('BEGIN') — that starts a DEFERRED transaction.
    """
    conn = sqlite3.connect(db_path, timeout=30)
    conn.isolation_level = None  # autocommit OFF; we manage transactions manually
    now = utc_now()

    try:
        # Run reaper inline before granting (piggyback pattern)
        _reclaim_stale_leases_internal(conn, now)

        conn.execute("BEGIN IMMEDIATE")

        row = conn.execute("""
            SELECT chunk_id, chunk_file_path
            FROM chunk_queue
            WHERE status = 'PENDING'
            ORDER BY priority ASC, created_at ASC
            LIMIT 1
        """).fetchone()

        if row is None:
            conn.execute("ROLLBACK")
            conn.close()
            return None

        chunk_id, chunk_file_path = row
        leased_at = now
        # lease_expires_at = leased_at + lease_ttl_s (ISO8601 arithmetic)
        expires = _add_seconds_to_iso(leased_at, lease_ttl_s)

        conn.execute("""
            UPDATE chunk_queue
            SET status='LEASED',
                worker_id=?,
                leased_at=?,
                lease_expires_at=?,
                last_heartbeat_at=?,
                updated_at=?
            WHERE chunk_id=?
        """, (worker_id, leased_at, expires, leased_at, now, chunk_id))

        conn.execute("""
            INSERT INTO chunk_queue_audit_log
              (chunk_id, from_status, to_status, worker_id, event_type, detail, logged_at)
            VALUES (?, 'PENDING', 'LEASED', ?, 'LEASE_GRANTED',
                    json_object('lease_ttl_s', ?), ?)
        """, (chunk_id, worker_id, lease_ttl_s, now))

        conn.execute("COMMIT")
        conn.close()

        return ChunkLease(
            chunk_id=chunk_id,
            chunk_file_path=chunk_file_path,
            worker_id=worker_id,
            leased_at=leased_at,
            lease_expires_at=expires,
        )

    except Exception:
        try:
            conn.execute("ROLLBACK")
        except Exception:
            pass
        conn.close()
        raise
```

---

### 2.4 `heartbeat(db_path, chunk_id, worker_id)`

```python
def heartbeat(db_path: str, chunk_id: str, worker_id: str) -> bool:
    """
    Update last_heartbeat_at for an active lease.
    Returns True if update succeeded (row still LEASED by this worker).
    Returns False if lease was reclaimed by reaper.

    Call every 60s from a background thread while chunk is being processed.
    """
    conn = sqlite3.connect(db_path, timeout=30)
    now = utc_now()
    cur = conn.execute("""
        UPDATE chunk_queue
        SET last_heartbeat_at=?, updated_at=?
        WHERE chunk_id=? AND worker_id=? AND status='LEASED'
    """, (now, now, chunk_id, worker_id))
    rows_updated = cur.rowcount
    conn.commit()
    conn.close()
    return rows_updated > 0
```

**Heartbeat thread pattern:**

```python
import threading

def start_heartbeat_thread(db_path: str, chunk_id: str, worker_id: str,
                           interval_s: int = 60) -> threading.Event:
    stop_event = threading.Event()
    def _loop():
        while not stop_event.wait(timeout=interval_s):
            alive = heartbeat(db_path, chunk_id, worker_id)
            if not alive:
                break  # lease was reclaimed; worker should abort
    t = threading.Thread(target=_loop, daemon=True)
    t.start()
    return stop_event  # caller calls stop_event.set() to stop the thread
```

---

### 2.5 `ack_chunk(db_path, chunk_id, worker_id, success, ...)`

```python
def ack_chunk(
    db_path: str,
    chunk_id: str,
    worker_id: str,
    success: bool,
    lines_in: int = 0,
    lines_out: int = 0,
    output_file_path: str = None,
    error: str = None,
    max_retries: int = 3,
    retry_backoff_s: int = 300,  # 5 min base backoff; doubles each retry
) -> str:
    """
    Acknowledge chunk completion or failure.
    Returns new status: 'COMPLETED', 'FAILED', or 'FAILED_PERMANENT'.
    """
    conn = sqlite3.connect(db_path, timeout=30)
    conn.isolation_level = None
    now = utc_now()

    conn.execute("BEGIN IMMEDIATE")

    row = conn.execute("""
        SELECT retry_count, max_retries FROM chunk_queue
        WHERE chunk_id=? AND worker_id=? AND status='LEASED'
    """, (chunk_id, worker_id)).fetchone()

    if row is None:
        conn.execute("ROLLBACK")
        conn.close()
        raise ValueError(f"Chunk {chunk_id} not LEASED by {worker_id} — already reclaimed?")

    current_retry, _max = row

    if success:
        new_status = 'COMPLETED'
        conn.execute("""
            UPDATE chunk_queue SET
                status='COMPLETED',
                completed_at=?,
                output_file_path=?,
                lines_in=?,
                lines_out=?,
                worker_id=?,
                updated_at=?
            WHERE chunk_id=?
        """, (now, output_file_path, lines_in, lines_out, worker_id, now, chunk_id))
        detail = f'{{"lines_in":{lines_in},"lines_out":{lines_out},"output":"{output_file_path}"}}'
        event_type = 'ACK_SUCCESS'
    else:
        new_retry = current_retry + 1
        if new_retry >= max_retries:
            new_status = 'FAILED_PERMANENT'
            conn.execute("""
                UPDATE chunk_queue SET
                    status='FAILED_PERMANENT',
                    retry_count=?,
                    last_error=?,
                    last_failed_at=?,
                    worker_id=NULL,
                    updated_at=?
                WHERE chunk_id=?
            """, (new_retry, (error or '')[:512], now, now, chunk_id))
        else:
            new_status = 'FAILED'
            backoff = retry_backoff_s * (2 ** current_retry)  # exponential
            next_retry = _add_seconds_to_iso(now, backoff)
            conn.execute("""
                UPDATE chunk_queue SET
                    status='FAILED',
                    retry_count=?,
                    last_error=?,
                    last_failed_at=?,
                    next_retry_at=?,
                    worker_id=NULL,
                    leased_at=NULL,
                    lease_expires_at=NULL,
                    updated_at=?
                WHERE chunk_id=?
            """, (new_retry, (error or '')[:512], now, next_retry, now, chunk_id))
        detail = f'{{"error":"{(error or "")[:128]}","retry":{new_retry}}}'
        event_type = 'ACK_FAIL'

    conn.execute("""
        INSERT INTO chunk_queue_audit_log
          (chunk_id, from_status, to_status, worker_id, event_type, detail, logged_at)
        VALUES (?, 'LEASED', ?, ?, ?, ?, ?)
    """, (chunk_id, new_status, worker_id, event_type, detail, now))

    conn.execute("COMMIT")
    conn.close()
    return new_status
```

---

### 2.6 `reclaim_stale_leases(db_path)`

```python
def reclaim_stale_leases(db_path: str) -> int:
    """
    Reaper: return expired leases to PENDING (if under max_retries)
    or FAILED_PERMANENT (if max_retries reached).
    Returns count of leases reclaimed.
    Safe to call any time, any frequency.
    """
    conn = sqlite3.connect(db_path, timeout=30)
    conn.isolation_level = None
    now = utc_now()

    conn.execute("BEGIN IMMEDIATE")

    # Find expired leases
    expired = conn.execute("""
        SELECT chunk_id, worker_id, retry_count, max_retries
        FROM chunk_queue
        WHERE status = 'LEASED'
          AND lease_expires_at < ?
    """, (now,)).fetchall()

    reclaimed = 0
    for chunk_id, worker_id, retry_count, max_retries in expired:
        new_retry = retry_count + 1
        if new_retry >= max_retries:
            new_status = 'FAILED_PERMANENT'
            conn.execute("""
                UPDATE chunk_queue SET
                    status='FAILED_PERMANENT',
                    retry_count=?,
                    last_error='LEASE_EXPIRED_MAX_RETRIES',
                    last_failed_at=?,
                    worker_id=NULL,
                    updated_at=?
                WHERE chunk_id=?
            """, (new_retry, now, now, chunk_id))
        else:
            new_status = 'PENDING'
            backoff = 300 * (2 ** retry_count)
            next_retry = _add_seconds_to_iso(now, backoff)
            conn.execute("""
                UPDATE chunk_queue SET
                    status='PENDING',
                    retry_count=?,
                    last_error='LEASE_EXPIRED',
                    last_failed_at=?,
                    next_retry_at=?,
                    worker_id=NULL,
                    leased_at=NULL,
                    lease_expires_at=NULL,
                    last_heartbeat_at=NULL,
                    updated_at=?
                WHERE chunk_id=?
            """, (new_retry, now, next_retry, now, chunk_id))

        conn.execute("""
            INSERT INTO chunk_queue_audit_log
              (chunk_id, from_status, to_status, worker_id, event_type, detail, logged_at)
            VALUES (?, 'LEASED', ?, ?, 'RECLAIMED',
                    json_object('reason','LEASE_EXPIRED','retry',?), ?)
        """, (chunk_id, new_status, worker_id, new_retry, now))
        reclaimed += 1

    conn.execute("COMMIT")
    conn.close()
    return reclaimed
```

---

### 2.7 Helper: `_add_seconds_to_iso(iso_str, seconds)`

```python
from datetime import datetime, timezone, timedelta

def _add_seconds_to_iso(iso_str: str, seconds: int) -> str:
    dt = datetime.fromisoformat(iso_str.replace('Z', '+00:00'))
    return (dt + timedelta(seconds=seconds)).strftime('%Y-%m-%dT%H:%M:%SZ')

def utc_now() -> str:
    return datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
```

---

## 3. CLI Entry Point (`queue_controller.py`)

```python
#!/usr/bin/env python3
"""
Queue controller CLI for chunk lease management.
Usage:
  python3 queue_controller.py seed   --db <db> --queue <file>
  python3 queue_controller.py status --db <db>
  python3 queue_controller.py reap   --db <db>
  python3 queue_controller.py run    --db <db> --results <dir> [--workers N]
"""
import argparse, json, sys

DB_PATH = "/root/.openclaw/workspace/UserFiles/Pandavs-Framework/ops/day1/state/scan_persistence.db"
QUEUE_FILE = "/root/.openclaw/workspace/UserFiles/Pandavs-Framework/ops/day1/state/dnsx_queue.txt"
RESULTS_DIR = "/root/.openclaw/workspace/UserFiles/Pandavs-Framework/ops/day1/results"

def main():
    p = argparse.ArgumentParser()
    p.add_argument("cmd", choices=["seed","status","reap","run"])
    p.add_argument("--db", default=DB_PATH)
    p.add_argument("--queue", default=QUEUE_FILE)
    p.add_argument("--results", default=RESULTS_DIR)
    p.add_argument("--workers", type=int, default=3)
    p.add_argument("--lease-ttl", type=int, default=7200)
    args = p.parse_args()

    if args.cmd == "seed":
        n = populate_chunk_queue(args.db, args.queue)
        print(json.dumps({"ok": True, "seeded": n}))

    elif args.cmd == "status":
        conn = sqlite3.connect(args.db)
        rows = conn.execute("""
            SELECT status, count(*) FROM chunk_queue GROUP BY status ORDER BY count(*) DESC
        """).fetchall()
        total = conn.execute("SELECT count(*) FROM chunk_queue").fetchone()[0]
        done = dict(rows).get('COMPLETED', 0)
        print(json.dumps({"ok": True, "total": total, "coverage_pct": round(done*100.0/max(total,1),1),
                          "by_status": dict(rows)}))
        conn.close()

    elif args.cmd == "reap":
        n = reclaim_stale_leases(args.db)
        print(json.dumps({"ok": True, "reclaimed": n}))

    elif args.cmd == "run":
        # Launch N concurrent workers (simple threading model)
        import threading
        stop = threading.Event()
        def _worker():
            worker_id = f"{os.uname().nodename}-{os.getpid()}-{int(time.time())}"
            while not stop.is_set():
                lease = grant_lease(args.db, worker_id, args.lease_ttl)
                if lease is None:
                    break
                hb_stop = start_heartbeat_thread(args.db, lease.chunk_id, worker_id)
                try:
                    result = run_dig_chunk(lease.chunk_file_path, args.results)
                    ack_chunk(args.db, lease.chunk_id, worker_id, success=True, **result)
                except Exception as e:
                    ack_chunk(args.db, lease.chunk_id, worker_id, success=False, error=str(e))
                finally:
                    hb_stop.set()

        threads = [threading.Thread(target=_worker, daemon=True) for _ in range(args.workers)]
        for t in threads: t.start()
        for t in threads: t.join()
        print(json.dumps({"ok": True, "done": True}))

if __name__ == "__main__":
    sys.exit(main() or 0)
```

---

## 4. Integration: Replacing run_full_dns_pass.sh Loop

**Before (current):**
```bash
while IFS= read -r chunk; do
  [ -z "$chunk" ] && continue
  # ... awk | xargs -P 48 ... → out file
done < "$QUEUE"
```

**After (lease-controlled):**
```bash
# Seed once (idempotent)
python3 ops/day1/queue_controller.py seed --db "$DB" --queue "$QUEUE"

# Run workers (3 concurrent, each picks up next PENDING chunk)
python3 ops/day1/queue_controller.py run --db "$DB" --results "$RES" --workers 3

# Cron for reaper (every 2 min as safety net)
# */2 * * * * python3 /path/to/queue_controller.py reap --db "$DB"
```

The `run_dig_chunk()` function inside the Python worker replicates the exact `awk | xargs -P 48 dig` logic from the shell script but with subprocess control, timeout, and structured output capture.

---

## 5. State Transition Table (Complete)

| Current Status | Trigger | New Status | Function |
|---------------|---------|-----------|---------|
| — | populate_chunk_queue() | PENDING | `populate_chunk_queue` |
| PENDING | Worker calls grant_lease() | LEASED | `grant_lease` |
| LEASED | Worker acks success | COMPLETED | `ack_chunk(success=True)` |
| LEASED | Worker acks failure, retry_count < max | FAILED | `ack_chunk(success=False)` |
| LEASED | Worker acks failure, retry_count >= max | FAILED_PERMANENT | `ack_chunk(success=False)` |
| LEASED | lease_expires_at < now, retry < max | PENDING | `reclaim_stale_leases` |
| LEASED | lease_expires_at < now, retry >= max | FAILED_PERMANENT | `reclaim_stale_leases` |
| FAILED | next_retry_at <= now | PENDING | `reclaim_stale_leases` |
| FAILED | Operator manual reset | PENDING | Manual SQL update |
| FAILED_PERMANENT | Operator manual reset | PENDING | Manual SQL update |

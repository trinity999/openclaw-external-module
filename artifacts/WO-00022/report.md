# WO-00022 — Lease-Based Chunk Queue Controller
## Implementation Design for Nonstop Resumable Scan Execution

**Status:** COMPLETED
**Category:** implementation
**Priority:** CRITICAL
**Analyst:** openclaw-field-processor
**Produced:** 2026-03-04
**Source reviewed:** `trinity999/Pandavs-Framework` @ `cebd2d5`

---

## 1. Executive Summary

The current `ops/day1/run_full_dns_pass.sh` reads chunks from `state/dnsx_queue.txt` using a bare `while IFS= read -r chunk; done` loop. This is a single-pass, stateless execution model: if the process dies mid-queue, there is zero recovery information. The next run either re-processes every chunk (duplicating work) or skips entirely (losing progress).

This Work Order produces an implementation patch to replace that model with a **lease-based chunk queue** backed by SQLite. Key properties:

- **Atomic claim:** Only one worker can lease a given chunk at a time, enforced at the DB level via `BEGIN IMMEDIATE`
- **Heartbeat:** Workers ping the DB while processing; dead workers are detectable
- **Reaper:** A lightweight process reclaims stale leases, returning chunks to PENDING
- **Ack:** Completion is written transactionally with statistics
- **Idempotent re-run:** Re-invoking the scanner after a crash resumes from exactly where it left off — already-COMPLETED chunks are skipped

---

## 2. Context Understanding

### 2.1 Current Scanner Architecture (from source)

```
run_full_dns_pass.sh:
  PARALLEL=48
  QUEUE=$BASE/state/dnsx_queue.txt   ← flat file, one chunk path per line

  while IFS= read -r chunk; do
    bn=$(basename "$chunk")
    ts=$(date -u +%Y%m%dT%H%M%SZ)
    out="$RES/dig_lane_${bn}_${ts}.txt"
    # ... awk | xargs -P 48 ...
  done < "$QUEUE"
```

**Failure modes identified:**
1. **No crash recovery:** SIGKILL, OOM, host reboot → queue position lost. Next run restarts from line 1
2. **No concurrency guard:** Two instances of the script would process the same chunks simultaneously
3. **No progress visibility:** Only log file shows progress; no queryable state
4. **No per-chunk timing:** Cannot distinguish stuck chunks (hung xargs) from slow-but-alive ones
5. **No duplicate prevention:** Chunk output filenames include timestamp (`_${ts}`), so reruns produce new files that re-enter the persistence pipeline

### 2.2 Persistence Layer (from source)

`persistence_gateway.py` already uses SQLite at `state/scan_persistence.db` with WAL mode. The new `chunk_queue` table will be added to the **same DB file** — this avoids introducing a second SQLite file and leverages the already-established WAL+synchronous=NORMAL configuration.

Key existing tables: `files`, `events`, `ingest_runs` — all remain untouched (additive schema change).

### 2.3 Scale Context

- 51 chunks; each chunk ~196k assets (10M / 51)
- `xargs -P 48` = 48 parallel `dig` calls per chunk
- Chunks take minutes to hours each depending on DNS response rates
- Scanner runs nonstop (continuous loop mode intended); must survive multi-day operation

---

## 3. Analytical Reasoning

### 3.1 Why SQLite as the Queue Backend

SQLite is already present, initialized with WAL, and managed by `persistence_gateway.py`. Using it as the queue backend means:
- No new infrastructure (no Redis, no external queue service)
- Lease state survives process restarts (persisted to disk)
- Single-writer guarantee via `BEGIN IMMEDIATE` serializes lease grants
- Atomic commit of lease + ack + stats in one transaction

Alternative (file-based locking with `.lock` files) was rejected: file locks are not portable across NFS, do not survive OS reboots cleanly, and offer no queryable state for observability.

### 3.2 Lease Semantics

A lease is a time-bounded claim on a chunk. The state machine is:

```
PENDING → LEASED (grant_lease)
LEASED  → COMPLETED (ack_chunk, success)
LEASED  → FAILED (ack_chunk, error, retry_count < max_retries)
FAILED  → PENDING (after backoff, reaper re-queues)
LEASED  → PENDING (reaper, lease_expires_at < now AND heartbeat absent)
FAILED permanently → FAILED_PERMANENT (retry_count >= max_retries)
```

Lease duration is `lease_ttl` seconds (default: 7200 = 2h). A chunk that takes more than 2h is likely hung. The heartbeat interval is 60s — a worker that stops heartbeating for >2× interval is presumed dead.

### 3.3 Atomicity via BEGIN IMMEDIATE

SQLite's `BEGIN IMMEDIATE` acquires a reserved lock at transaction start, preventing any other writer from entering a write transaction concurrently. The grant_lease sequence is:

```sql
BEGIN IMMEDIATE;
  SELECT chunk_id FROM chunk_queue
  WHERE status = 'PENDING'
  ORDER BY priority ASC, created_at ASC
  LIMIT 1;
  -- if row found:
  UPDATE chunk_queue SET status='LEASED', worker_id=?, leased_at=?, lease_expires_at=?, ...
COMMIT;
```

This is a single read-modify-write cycle under exclusive write lock. Even with N concurrent workers, exactly one receives the lease.

### 3.4 Heartbeat + Reaper Design

- **Heartbeat:** Worker calls `UPDATE chunk_queue SET last_heartbeat_at=? WHERE chunk_id=? AND worker_id=?` every 60s
- **Reaper:** Runs every 120s (or on lease acquisition attempt). Query: `UPDATE chunk_queue SET status='PENDING', worker_id=NULL, leased_at=NULL, lease_expires_at=NULL WHERE status='LEASED' AND lease_expires_at < strftime('%Y-%m-%dT%H:%M:%SZ','now')`
- The reaper can be co-located in the same Python process or run as a separate cron

### 3.5 Integration with run_full_dns_pass.sh

Two integration strategies:

**Option A — Python wrapper (recommended):** Replace the bash `while` loop with a Python script that calls `grant_lease()`, invokes the `awk | xargs` subprocess, captures output, calls `ack_chunk()`. The bash scanner becomes a library call.

**Option B — Shell + SQLite CLI:** Use `sqlite3` binary inline in the bash script to grant/ack leases. Portable but fragile — requires `sqlite3` binary, no native `BEGIN IMMEDIATE` transaction in shell.

**Recommendation: Option A.** Python is already present (persistence_gateway.py uses it). The Python wrapper gains precise subprocess control, timing, and error capture.

---

## 4. Design Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Queue backend | SQLite (existing DB) | Already present, WAL-enabled, no new deps |
| Lease duration | 7200s (2h) | Longest expected chunk runtime with margin |
| Heartbeat interval | 60s | Low overhead; 2× threshold = 120s for reaper |
| Reaper trigger | On grant_lease() + separate cron | Piggybacks on natural usage; cron as safety net |
| Max retries | 3 | After 3 failures, FAILED_PERMANENT; human review |
| Concurrency model | Multiple workers, each Python process | WAL supports concurrent readers; IMMEDIATE serializes writes |
| Chunk priority field | INTEGER default 0 | Future: prioritize smaller/faster chunks first |
| Worker ID | `{hostname}-{pid}-{timestamp}` | Unique per process; survives hostname reuse in containers |

---

## 5. Tradeoffs

| Tradeoff | Accepted Cost | Benefit |
|----------|--------------|---------|
| SQLite single writer | Lease grants serialized (~1ms/grant) | Zero concurrency bugs; no external service |
| Heartbeat writes | 60s × (active_workers) extra writes | Precise stuck-detection vs stale lease accumulation |
| Python wrapper replaces shell loop | Slightly more code | Full error handling, subprocess timeout, structured logging |
| Same DB file as persistence | Schema dependency | Single WAL file, no cross-DB joins needed |

---

## 6. Risks

| Risk | Severity | Mitigation |
|------|----------|-----------|
| SQLite write contention under many workers | MEDIUM | WAL handles reads; IMMEDIATE serializes writes; grants are fast (< 1ms) |
| Reaper too aggressive (reclaims active worker) | HIGH | Heartbeat interval (60s) << lease_ttl (7200s); only reclaims if `lease_expires_at` passed |
| Worker dies after lease grant, before ack | MEDIUM | Reaper reclaims after `lease_expires_at`; max 2h delay before retry |
| Chunk output filename collision on retry | LOW | Retry uses new timestamp suffix; persistence gateway deduplicates by event_id |
| Schema migration fails on running DB | HIGH | Additive-only (new table); uses `CREATE TABLE IF NOT EXISTS`; zero risk to existing data |

---

## 7. Recommendations

1. **Use `populate_chunk_queue.py`** to seed the 51 chunks from `dnsx_queue.txt` into the DB once at pipeline setup. After seeding, the flat file is no longer the source of truth.
2. **Replace the `while read` loop** in `run_full_dns_pass.sh` with a Python orchestrator (`run_chunk_worker.py`) that uses `grant_lease()` / `heartbeat()` / `ack_chunk()`.
3. **Run 3–6 workers concurrently** (one per available CPU cluster, not 51 — chunks are long-running, not instant). Each worker calls `grant_lease()` to get its next chunk.
4. **Deploy the reaper** as a `cron` entry: `*/2 * * * * python3 ops/day1/queue_controller.py reap` or inline at grant time.
5. **Add master status query** as a monitoring endpoint queryable from `persistence_gateway.py status`.

---

## 8. Implementation Model

### 8.1 Schema (see `schema_patch.sql`)

New table `chunk_queue` added to `scan_persistence.db`. No existing tables altered.

### 8.2 Worker Flow (Python)

```python
# Pseudocode for run_chunk_worker.py
def worker_loop(db_path, results_dir, worker_id, lease_ttl=7200):
    while True:
        chunk = grant_lease(db_path, worker_id, lease_ttl)
        if chunk is None:
            break  # queue exhausted

        heartbeat_thread = start_heartbeat(db_path, chunk.chunk_id, worker_id, interval=60)
        try:
            result = run_dig_pass(chunk.chunk_file_path, results_dir, PARALLEL=48)
            ack_chunk(db_path, chunk.chunk_id, worker_id,
                      success=True,
                      lines_in=result.lines_in,
                      lines_out=result.lines_out,
                      output_file=result.output_file)
        except Exception as e:
            ack_chunk(db_path, chunk.chunk_id, worker_id,
                      success=False, error=str(e))
        finally:
            heartbeat_thread.stop()
```

### 8.3 Seeding

```python
def populate_chunk_queue(db_path, queue_file):
    chunks = [line.strip() for line in open(queue_file) if line.strip()]
    conn = sqlite3.connect(db_path)
    ensure_chunk_queue(conn)
    for chunk_path in chunks:
        chunk_id = hashlib.sha256(chunk_path.encode()).hexdigest()[:16]
        conn.execute("""
            INSERT OR IGNORE INTO chunk_queue
            (chunk_id, chunk_file_path, status, created_at, updated_at)
            VALUES (?, ?, 'PENDING', ?, ?)
        """, (chunk_id, chunk_path, utc_now(), utc_now()))
    conn.commit()
    conn.close()
```

---

## 9. Validation Strategy

| Test | Pass Condition |
|------|---------------|
| **Crash drill:** Kill worker mid-chunk, restart | Chunk returns to PENDING within `lease_ttl`; reaper reclaims; no duplicate output in next run |
| **Concurrent workers:** Start 3 workers simultaneously | Each worker receives distinct chunk; no chunk processed by >1 worker concurrently |
| **Full 51-chunk run:** Complete all chunks | 51 rows with `status='COMPLETED'`; 0 in PENDING/LEASED |
| **Heartbeat validation:** Monitor `last_heartbeat_at` | Updates every ≤65s while worker active |
| **Idempotent re-run:** Re-run after all COMPLETED | 0 new leases granted; 0 chunks re-processed |
| **Max retries:** Inject 3 failing chunks | After 3 failures, status = `FAILED_PERMANENT`; alert generated |

---

## 10. KPIs

| KPI | Target | Source Query |
|-----|--------|-------------|
| Duplicate chunk execution | 0 per restart drill | `SELECT count(*) FROM chunk_queue WHERE status='COMPLETED' GROUP BY chunk_id HAVING count(*) > 1` |
| Stuck chunk recovery time | ≤ 10 min | `lease_ttl` set to 7200s, but reaper runs every 120s; practically: reaper detects expiry at next poll |
| Chunk queue completion | 51/51 COMPLETED | `SELECT count(*) FROM chunk_queue WHERE status='COMPLETED'` |
| Monotonic chunk progress | Strictly increasing over restarts | `SELECT completed_at FROM chunk_queue WHERE status='COMPLETED' ORDER BY completed_at` |
| Worker heartbeat freshness | ≤ 65s behind current time | `SELECT chunk_id, (julianday('now')-julianday(last_heartbeat_at))*86400 FROM chunk_queue WHERE status='LEASED'` |

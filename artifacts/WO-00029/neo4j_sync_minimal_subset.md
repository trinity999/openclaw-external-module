# Neo4j Sync Worker — Minimal Subset Specification
## Work Order: WO-00029 | Phase-1: dns_resolution events only

---

## Overview

`neo4j_sync_worker.py` is the Neo4j counterpart of `clickhouse_sink_worker.py` (WO-00028).
It claims batches of `dns_resolution` events from `sink_outbox` (where `sink_target='neo4j'`),
translates each event into graph parameters, and executes idempotent MERGE writes against
the `reconnaissance` database using the composite MERGE-5 pattern from `cypher_merge_patterns.cypher`.

**Phase-1 scope**: `event_kind = 'dns_resolution'` only.
All other event kinds are skipped with outcome `ALREADY_SYNCED` (they will be handled in Phase-2/3).

---

## Dependencies

```
pip install neo4j          # Bolt driver — no validators import, no neo4j_manager.py
# pip install validators   # NOT used — avoids documented import failure (DATABASE_OPS.md §Issue-2)
```

Standard library only beyond `neo4j`: `sqlite3`, `uuid`, `hashlib`, `datetime`,
`argparse`, `logging`, `os`, `sys`, `time`, `csv`.

---

## Configuration Constants

```python
# neo4j_sync_worker.py — configuration block

DB_PATH          = "scan_persistence.db"
NEO4J_URI        = "bolt://localhost:7687"
NEO4J_USER       = "neo4j"
NEO4J_PASSWORD   = "pandavs_neo4j_2026"   # from .neo4j_docker.env NEO4J_AUTH
NEO4J_DATABASE   = "reconnaissance"

BATCH_SIZE       = 200          # events per claim; smaller than CH (500) — graph writes are heavier
CLAIMED_TTL_S    = 600          # seconds before stale CLAIMED rows are reaped back to PENDING
LOOP_INTERVAL_S  = 30           # sweep frequency in loop mode
MAX_RETRIES      = 5            # after which → dead_letter_events
BASE_BACKOFF_S   = 300          # retry_backoff = BASE_BACKOFF_S * (2 ** retry_count), cap 14400s
MAX_BACKOFF_S    = 14400
SINK_TARGET      = "neo4j"
PHASE1_KIND      = "dns_resolution"

# Multi-part TLDs for root domain extraction (mirrors neo4j_manager.py _extract_root_domain)
MULTI_PART_TLDS  = {
    "co.uk", "com.au", "com.br", "co.in", "co.nz", "co.za",
    "org.uk", "net.au", "gov.au", "ac.uk", "me.uk",
}
```

---

## ID Generation (mirrors neo4j_manager.py exactly)

```python
import uuid

NAMESPACE_DNS = uuid.NAMESPACE_DNS
NAMESPACE_URL = uuid.NAMESPACE_URL

def generate_subdomain_id(subdomain: str) -> str:
    """sub_ + uuid5(NAMESPACE_DNS, subdomain.lower())"""
    return f"sub_{uuid.uuid5(NAMESPACE_DNS, subdomain.strip().lower())}"

def generate_ip_id(ip_address: str) -> str:
    """ip_ + uuid5(NAMESPACE_URL, ip_address)"""
    return f"ip_{uuid.uuid5(NAMESPACE_URL, ip_address.strip())}"

def generate_domain_id(root_domain: str) -> str:
    """dom_ + uuid5(NAMESPACE_DNS, root_domain.lower())"""
    return f"dom_{uuid.uuid5(NAMESPACE_DNS, root_domain.strip().lower())}"
```

---

## Root Domain Extraction (mirrors neo4j_manager.py `_extract_root_domain_from_subdomain`)

```python
def extract_root_domain(subdomain: str) -> str:
    """
    Extract root domain from a FQDN.
    Handles multi-part TLDs (co.uk, com.au, etc.).

    Examples:
        api.example.com       → example.com
        mail.example.co.uk    → example.co.uk
        example.com           → example.com  (already root)
    """
    parts = subdomain.strip().lower().split(".")
    if len(parts) <= 2:
        return subdomain.lower()

    # Check if last two parts form a multi-part TLD
    candidate_tld = f"{parts[-2]}.{parts[-1]}"
    if candidate_tld in MULTI_PART_TLDS:
        # Need at least 3 parts total: label + two-part TLD
        if len(parts) >= 3:
            return f"{parts[-3]}.{candidate_tld}"
        else:
            return subdomain.lower()
    else:
        return f"{parts[-2]}.{parts[-1]}"
```

---

## SQLite Helpers

```python
import sqlite3
import contextlib

def open_db(db_path: str = DB_PATH) -> sqlite3.Connection:
    conn = sqlite3.connect(db_path, isolation_level=None, timeout=30)
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA synchronous=NORMAL")
    conn.row_factory = sqlite3.Row
    return conn
```

---

## Stale Claim Reaper

```python
import time

def reap_stale_claims(conn: sqlite3.Connection) -> int:
    """
    Return CLAIMED rows older than CLAIMED_TTL_S back to PENDING.
    Prevents stranded batches after worker crash.
    Returns count of reaped rows.
    """
    cutoff = time.time() - CLAIMED_TTL_S
    cur = conn.execute(
        """
        UPDATE sink_outbox
        SET    status = 'PENDING',
               updated_at = CURRENT_TIMESTAMP
        WHERE  sink_target = ?
          AND  status = 'CLAIMED'
          AND  claimed_at < datetime(?, 'unixepoch')
        """,
        (SINK_TARGET, cutoff),
    )
    return cur.rowcount
```

---

## Batch Claim (BEGIN IMMEDIATE for serialized concurrent access)

```python
def claim_outbox_batch(conn: sqlite3.Connection) -> list[sqlite3.Row]:
    """
    Atomically claim up to BATCH_SIZE rows from sink_outbox for Neo4j.
    Uses BEGIN IMMEDIATE to serialize concurrent workers (mirrors WO-00022 chunk_queue pattern).

    Only claims dns_resolution events in Phase-1.
    Only claims rows whose retry backoff has elapsed (next_retry_at IS NULL or <= now).
    """
    conn.execute("BEGIN IMMEDIATE")
    try:
        rows = conn.execute(
            """
            SELECT so.outbox_id, so.event_id, so.retry_count
            FROM   sink_outbox so
            JOIN   events e ON e.event_id = so.event_id
            WHERE  so.sink_target = ?
              AND  so.status IN ('PENDING', 'FAILED')
              AND  e.event_kind  = ?
              AND  (so.next_retry_at IS NULL OR so.next_retry_at <= CURRENT_TIMESTAMP)
            ORDER BY so.created_at ASC
            LIMIT  ?
            """,
            (SINK_TARGET, PHASE1_KIND, BATCH_SIZE),
        ).fetchall()

        if not rows:
            conn.execute("COMMIT")
            return []

        outbox_ids = [r["outbox_id"] for r in rows]
        placeholders = ",".join("?" * len(outbox_ids))
        conn.execute(
            f"""
            UPDATE sink_outbox
            SET    status     = 'CLAIMED',
                   claimed_at = CURRENT_TIMESTAMP,
                   updated_at = CURRENT_TIMESTAMP
            WHERE  outbox_id IN ({placeholders})
            """,
            outbox_ids,
        )
        conn.execute("COMMIT")
        return rows
    except Exception:
        conn.execute("ROLLBACK")
        raise
```

---

## Event Fetch

```python
def fetch_events_for_outbox(
    conn: sqlite3.Connection, outbox_ids: list[int]
) -> dict[int, sqlite3.Row]:
    """
    Fetch full event rows for claimed outbox entries.
    Returns {outbox_id: event_row}.
    """
    placeholders = ",".join("?" * len(outbox_ids))
    rows = conn.execute(
        f"""
        SELECT so.outbox_id, e.*
        FROM   sink_outbox so
        JOIN   events e ON e.event_id = so.event_id
        WHERE  so.outbox_id IN ({placeholders})
        """,
        outbox_ids,
    ).fetchall()
    return {r["outbox_id"]: r for r in rows}
```

---

## Event → Graph Parameter Mapping

```python
def map_dns_event_to_params(event_row: sqlite3.Row) -> list[dict]:
    """
    Convert a dns_resolution event row into a list of MERGE-5 parameter dicts.
    One dict per IP address (event.value is a comma-joined list from dnsx/dig).

    Returns [] if the event cannot be mapped (non-dns_resolution, malformed).

    Example:
        event.asset = "api.example.com"
        event.value = "1.2.3.4,5.6.7.8"
        → returns two param dicts, one per IP
    """
    if event_row["event_kind"] != PHASE1_KIND:
        return []   # skip non-dns_resolution silently

    subdomain = (event_row["asset"] or "").strip()
    if not subdomain:
        return []

    raw_value = (event_row["value"] or "").strip()
    ip_list   = [ip.strip() for ip in raw_value.split(",") if ip.strip()]
    if not ip_list:
        return []

    root_domain = extract_root_domain(subdomain)
    ts          = event_row["ts"] or datetime.datetime.utcnow().isoformat()

    # Infer record_type from IP format (A vs AAAA)
    def _record_type(ip: str) -> str:
        return "AAAA" if ":" in ip else "A"

    params_list = []
    for ip in ip_list:
        params_list.append({
            "subdomain_id": generate_subdomain_id(subdomain),
            "subdomain":    subdomain,
            "domain_id":    generate_domain_id(root_domain),
            "root_domain":  root_domain,
            "ip_id":        generate_ip_id(ip),
            "ip_address":   ip,
            "ip_type":      "ipv6" if ":" in ip else "ipv4",
            "record_type":  _record_type(ip),
            "ts":           ts,
        })
    return params_list
```

---

## Neo4j Write — MERGE-5 Composite Pattern

```python
# Cypher: composite MERGE in one transaction (from cypher_merge_patterns.cypher MERGE-5)
_MERGE5_CYPHER = """
MERGE (s:Subdomain {subdomain_id: $subdomain_id})
SET   s.subdomain = $subdomain, s.resolution_status = 'resolved',
      s.last_updated = datetime(), s.last_found_date = datetime($ts), s.status = 'active'
SET   s.first_seen = CASE WHEN s.first_seen IS NULL THEN datetime($ts) ELSE s.first_seen END

WITH s
MERGE (d:Domain {domain_id: $domain_id})
  ON CREATE SET d.domain = $root_domain, d.created_at = datetime(),
                d.is_root_domain = true, d.status = 'active'
MERGE (s)-[rb:BELONGS_TO]->(d)
  ON CREATE SET rb.created_at = datetime()

WITH s
MERGE (i:IP {ip_id: $ip_id})
  ON CREATE SET i.ip_address = $ip_address, i.ip_type = $ip_type,
                i.first_seen = datetime(), i.last_updated = datetime()
  ON MATCH SET  i.last_updated = datetime()
MERGE (s)-[rr:RESOLVES_TO]->(i)
  ON CREATE SET rr.record_type = $record_type, rr.first_seen = datetime($ts), rr.last_seen = datetime($ts)
  ON MATCH SET  rr.last_seen = datetime($ts)

RETURN s.subdomain_id AS subdomain_id, d.domain_id AS domain_id,
       i.ip_id AS ip_id, type(rr) AS resolves_to_type
"""

def write_dns_event(session, params: dict) -> None:
    """
    Execute MERGE-5 composite pattern for one (subdomain, IP) pair.
    session: neo4j.Session (auto-managed by driver context manager)
    Raises on Neo4j errors — caller handles classification + retry.
    """
    session.run(_MERGE5_CYPHER, **params)
```

---

## Error Classification

```python
from neo4j.exceptions import (
    AuthError,
    ServiceUnavailable,
    TransientError,
    CypherSyntaxError,
    ConstraintError,
    ClientError,
)

# Error class constants
ALREADY_SYNCED  = "ALREADY_SYNCED"   # node exists, constraint hit — safe to mark SYNCED
NON_RETRYABLE   = "NON_RETRYABLE"    # auth failure, syntax error — manual intervention
RETRYABLE       = "RETRYABLE"        # transient / service down — retry with backoff
UNKNOWN         = "UNKNOWN"          # unrecognized — treat as RETRYABLE conservatively

def classify_neo4j_error(exc: Exception) -> str:
    """
    Map a Neo4j exception to retry taxonomy.

    ALREADY_SYNCED  — ConstraintValidationFailed: node/rel already exists with same key
    NON_RETRYABLE   — AuthError, CypherSyntaxError, ClientError (bad params)
    RETRYABLE       — ServiceUnavailable, TransientError (deadlock, temp outage)
    UNKNOWN         — anything else (conservative: retry)
    """
    if isinstance(exc, ConstraintError):
        return ALREADY_SYNCED
    if isinstance(exc, (AuthError, CypherSyntaxError)):
        return NON_RETRYABLE
    if isinstance(exc, ClientError):
        # Neo4j ClientError covers type mismatches, bad param names
        code = getattr(exc, "code", "")
        if "SyntaxError" in code or "InvalidArgument" in code or "TypeError" in code:
            return NON_RETRYABLE
        return RETRYABLE
    if isinstance(exc, (ServiceUnavailable, TransientError)):
        return RETRYABLE
    return UNKNOWN
```

---

## Outcome Recording

```python
import datetime

def _compute_next_retry(retry_count: int) -> str:
    """
    Exponential backoff: BASE_BACKOFF_S * 2^retry_count, capped at MAX_BACKOFF_S.
    Returns ISO8601 timestamp string for next_retry_at.
    """
    delay = min(BASE_BACKOFF_S * (2 ** retry_count), MAX_BACKOFF_S)
    next_ts = datetime.datetime.utcnow() + datetime.timedelta(seconds=delay)
    return next_ts.strftime("%Y-%m-%dT%H:%M:%S")

def record_success(conn: sqlite3.Connection, outbox_id: int, event_id: str) -> None:
    conn.execute(
        """
        UPDATE sink_outbox
        SET    status = 'SYNCED', synced_at = CURRENT_TIMESTAMP, updated_at = CURRENT_TIMESTAMP
        WHERE  outbox_id = ?
        """,
        (outbox_id,),
    )
    # event_sync_ledger tracks authoritative sync time per event per sink
    conn.execute(
        """
        INSERT OR REPLACE INTO event_sync_ledger (event_id, sink_target, synced_at, outcome)
        VALUES (?, ?, CURRENT_TIMESTAMP, 'SYNCED')
        """,
        (event_id, SINK_TARGET),
    )

def record_already_synced(conn: sqlite3.Connection, outbox_id: int, event_id: str) -> None:
    """
    ConstraintValidationFailed — node already exists. Mark SYNCED (not a failure).
    """
    record_success(conn, outbox_id, event_id)

def record_retryable_failure(
    conn: sqlite3.Connection, outbox_id: int, retry_count: int, error_msg: str
) -> None:
    next_retry = _compute_next_retry(retry_count)
    conn.execute(
        """
        UPDATE sink_outbox
        SET    status        = 'FAILED',
               retry_count   = retry_count + 1,
               last_error    = ?,
               next_retry_at = ?,
               updated_at    = CURRENT_TIMESTAMP
        WHERE  outbox_id = ?
        """,
        (error_msg[:1000], next_retry, outbox_id),
    )

def promote_to_dlq(
    conn: sqlite3.Connection, outbox_id: int, event_id: str, error_msg: str
) -> None:
    """
    Move exhausted row to dead_letter_events; remove from active outbox.
    """
    conn.execute(
        """
        INSERT OR IGNORE INTO dead_letter_events
            (event_id, sink_target, failure_reason, promoted_at)
        VALUES (?, ?, ?, CURRENT_TIMESTAMP)
        """,
        (event_id, SINK_TARGET, error_msg[:2000]),
    )
    conn.execute(
        "UPDATE sink_outbox SET status = 'DEAD', updated_at = CURRENT_TIMESTAMP WHERE outbox_id = ?",
        (outbox_id,),
    )

def record_non_retryable(
    conn: sqlite3.Connection, outbox_id: int, event_id: str, error_msg: str
) -> None:
    """
    Non-retryable error: log and promote directly to DLQ — no retry attempts.
    """
    promote_to_dlq(conn, outbox_id, event_id, f"NON_RETRYABLE: {error_msg}")
```

---

## Sweep (one complete batch cycle)

```python
from neo4j import GraphDatabase

def run_sweep(conn: sqlite3.Connection, driver) -> dict:
    """
    Execute one full sweep:
      1. Reap stale CLAIMED rows
      2. Claim a batch
      3. Fetch event data
      4. For each event: map → write_dns_event per IP → record outcome
      5. Return sweep stats

    Returns: {reaped, claimed, synced, already_synced, retryable, non_retryable, skipped}
    """
    stats = dict(reaped=0, claimed=0, synced=0, already_synced=0,
                 retryable=0, non_retryable=0, skipped=0)

    # Step 1: reap stale claims
    stats["reaped"] = reap_stale_claims(conn)

    # Step 2: claim batch
    batch = claim_outbox_batch(conn)
    if not batch:
        return stats
    stats["claimed"] = len(batch)

    # Step 3: fetch full event data
    outbox_ids   = [r["outbox_id"] for r in batch]
    events_by_id = fetch_events_for_outbox(conn, outbox_ids)

    # Step 4: process each row
    with driver.session(database=NEO4J_DATABASE) as session:
        for outbox_row in batch:
            oid       = outbox_row["outbox_id"]
            ev        = events_by_id.get(oid)

            if ev is None:
                # Outbox row with no matching event — ghost row; mark synced to clear
                record_success(conn, oid, "UNKNOWN")
                stats["skipped"] += 1
                continue

            event_id    = ev["event_id"]
            retry_count = outbox_row["retry_count"] or 0

            # Skip non-dns_resolution in Phase-1 (future phase will handle)
            if ev["event_kind"] != PHASE1_KIND:
                record_success(conn, oid, event_id)   # mark done — nothing to write
                stats["skipped"] += 1
                continue

            param_list = map_dns_event_to_params(ev)
            if not param_list:
                record_success(conn, oid, event_id)   # malformed — skip
                stats["skipped"] += 1
                continue

            # Write one MERGE-5 per IP in the value list
            event_ok  = True
            last_exc  = None
            for params in param_list:
                try:
                    write_dns_event(session, params)
                except Exception as exc:
                    last_exc  = exc
                    event_ok  = False
                    break   # stop processing IPs for this event on first error

            if event_ok:
                record_success(conn, oid, event_id)
                stats["synced"] += 1
            else:
                err_class = classify_neo4j_error(last_exc)
                err_msg   = str(last_exc)[:1000]

                if err_class == ALREADY_SYNCED:
                    record_already_synced(conn, oid, event_id)
                    stats["already_synced"] += 1
                elif err_class == NON_RETRYABLE:
                    record_non_retryable(conn, oid, event_id, err_msg)
                    stats["non_retryable"] += 1
                else:
                    # RETRYABLE or UNKNOWN
                    if retry_count >= MAX_RETRIES:
                        promote_to_dlq(conn, oid, event_id, err_msg)
                        stats["non_retryable"] += 1   # count as exhausted
                    else:
                        record_retryable_failure(conn, oid, retry_count, err_msg)
                        stats["retryable"] += 1

    return stats
```

---

## Entry Points (CLI subcommands)

```python
import argparse
import logging
import sys

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [neo4j_sync] %(levelname)s %(message)s",
)
log = logging.getLogger("neo4j_sync")

def run_once(args) -> None:
    """Execute a single sweep and exit. Exit code 0 on success, 1 on fatal error."""
    conn   = open_db(args.db)
    driver = GraphDatabase.driver(NEO4J_URI, auth=(NEO4J_USER, NEO4J_PASSWORD))
    try:
        stats = run_sweep(conn, driver)
        log.info("sweep complete: %s", stats)
    except Exception as exc:
        log.error("sweep failed: %s", exc)
        sys.exit(1)
    finally:
        driver.close()
        conn.close()

def run_loop(args) -> None:
    """
    Run sweeps in a continuous loop every LOOP_INTERVAL_S seconds.
    Intended for production use under a process supervisor (systemd, Docker, supervisord).
    """
    conn   = open_db(args.db)
    driver = GraphDatabase.driver(NEO4J_URI, auth=(NEO4J_USER, NEO4J_PASSWORD))
    try:
        while True:
            try:
                stats = run_sweep(conn, driver)
                log.info("sweep: %s", stats)
            except Exception as exc:
                log.warning("sweep error (continuing): %s", exc)
            time.sleep(LOOP_INTERVAL_S)
    finally:
        driver.close()
        conn.close()

def run_status(args) -> None:
    """Print current sink_outbox queue depth by status for neo4j sink."""
    conn = open_db(args.db)
    rows = conn.execute(
        """
        SELECT so.status, COUNT(*) AS cnt
        FROM   sink_outbox so
        JOIN   events e ON e.event_id = so.event_id
        WHERE  so.sink_target = ?
          AND  e.event_kind   = ?
        GROUP  BY so.status
        ORDER  BY so.status
        """,
        (SINK_TARGET, PHASE1_KIND),
    ).fetchall()
    conn.close()
    print(f"{'STATUS':<15} {'COUNT':>10}")
    print("-" * 27)
    for r in rows:
        print(f"{r['status']:<15} {r['cnt']:>10}")
    if not rows:
        print("(no rows)")

def cli_main() -> None:
    parser = argparse.ArgumentParser(
        prog="neo4j_sync_worker",
        description="Phase-1 Neo4j sync worker — dns_resolution events",
    )
    parser.add_argument("--db", default=DB_PATH, help="SQLite database path")
    sub = parser.add_subparsers(dest="cmd", required=True)

    sub.add_parser("run-once", help="Execute one sweep and exit")
    sub.add_parser("loop",     help="Run sweeps continuously (production mode)")
    sub.add_parser("status",   help="Print outbox queue depth and exit")

    args = parser.parse_args()
    if   args.cmd == "run-once": run_once(args)
    elif args.cmd == "loop":     run_loop(args)
    elif args.cmd == "status":   run_status(args)

if __name__ == "__main__":
    cli_main()
```

---

## Deployment Instructions

### 1. Install driver

```bash
pip install neo4j
# Do NOT install validators — it causes import failures in this environment
```

### 2. Verify Neo4j connectivity

```bash
# Container must be running: docker ps | grep pandavs-neo4j-fixed
# If not running: see DATABASE_OPS.md §Neo4j Recovery

python3 - <<'EOF'
from neo4j import GraphDatabase
d = GraphDatabase.driver("bolt://localhost:7687", auth=("neo4j","pandavs_neo4j_2026"))
with d.session(database="reconnaissance") as s:
    r = s.run("RETURN 1 AS ok")
    print("Neo4j connected:", r.single()["ok"])
d.close()
EOF
```

### 3. Verify sink_outbox has Neo4j rows

```bash
python3 neo4j_sync_worker.py --db scan_persistence.db status
```

Expected output (before first sync):
```
STATUS          COUNT
---------------------------
PENDING           47832    ← dns_resolution events awaiting Neo4j write
```

### 4. Run one sweep (dry-run equivalent — MERGE is idempotent)

```bash
python3 neo4j_sync_worker.py --db scan_persistence.db run-once
```

### 5. Run in production loop

```bash
# Foreground (development):
python3 neo4j_sync_worker.py --db scan_persistence.db loop

# Background with nohup:
nohup python3 neo4j_sync_worker.py --db scan_persistence.db loop \
    >> logs/neo4j_sync.log 2>&1 &
echo $! > state/neo4j_sync.pid
```

### 6. Post-sync integrity check

Run the integrity queries from `cypher_merge_patterns.cypher` in Neo4j Browser or cypher-shell:

```cypher
// Count RESOLVES_TO edges — should match or exceed dns_resolution event count
MATCH ()-[r:RESOLVES_TO]->()
RETURN count(r) AS resolves_to_count;

// Orphan check — should return 0
MATCH (s:Subdomain)
WHERE NOT (s)-[:BELONGS_TO]->()
RETURN count(s) AS orphaned_subdomains;
```

---

## Phase-2 Expansion Path (no new nodes required)

When httpx/naabu data is available, the worker is extended in-place:

| Phase   | Event kind       | New node types | New relationship types | Worker change       |
|---------|-----------------|----------------|------------------------|---------------------|
| Phase-1 | dns_resolution  | Subdomain, IP, Domain | RESOLVES_TO, BELONGS_TO | This spec          |
| Phase-2a| dns_resolution  | (none)         | (none)                 | SET webserver props on Subdomain  |
| Phase-2b| naabu port scan | Port           | HAS_PORT               | MERGE Port + HAS_PORT from cypher_merge_patterns.cypher Phase-2 preview |

The Phase-1 worker is fully forward-compatible — Phase-2 changes are additive SET operations
on existing nodes, no destructive schema changes.

---

## Key Design Decisions

| ID  | Decision | Rationale |
|-----|----------|-----------|
| DD-1 | batch_size=200 | Graph writes have higher per-operation overhead than CH INSERT; smaller batches keep session alive and transaction scopes tight |
| DD-2 | MERGE-5 composite per event | Single Bolt round-trip per (subdomain, IP) pair; atomic; preferred over 4 separate round-trips |
| DD-3 | One write_dns_event() per IP in comma-joined list | persistence_gateway.py dnsx parser joins IPs with commas; must split to avoid garbage ip_id from "1.2.3.4,5.6.7.8" |
| DD-4 | ALREADY_SYNCED → mark SYNCED (not FAILED) | ConstraintValidationFailed means the node was already written correctly; retrying is wasteful and would always fail |
| DD-5 | direct neo4j driver (not neo4j_manager.py) | validators import failure (DATABASE_OPS.md §Issue-2); ID generation reproduced inline via same uuid5 logic |
| DD-6 | Root domain extraction mirrors neo4j_manager.py | Generated domain_id must match existing Domain nodes; must use identical multi-part TLD logic |
| DD-7 | CLAIMED reaper at 600s | Identical to CH worker; prevents stranded batches on crash; safe because MERGE is idempotent |

-- ============================================================
-- WO-00022: Chunk Queue Lease/Heartbeat/Ack Schema Patch
-- Target: ops/day1/state/scan_persistence.db
-- Type: ADDITIVE — no existing tables altered
-- Safe to run multiple times (IF NOT EXISTS guards)
-- ============================================================

PRAGMA journal_mode=WAL;
PRAGMA synchronous=NORMAL;

-- ============================================================
-- TABLE: chunk_queue
-- Central lease queue for 51-chunk scanner execution.
-- One row per chunk file. Status drives the state machine.
-- ============================================================
CREATE TABLE IF NOT EXISTS chunk_queue (
    -- Identity
    chunk_id            TEXT    PRIMARY KEY,        -- SHA-256[:16] of chunk_file_path; stable across restarts
    chunk_file_path     TEXT    NOT NULL UNIQUE,    -- Absolute path to chunk file (e.g. /root/.openclaw/.../chunk_001.txt)

    -- State machine
    -- PENDING → LEASED → COMPLETED
    -- LEASED  → FAILED  (error, retry_count < max_retries)
    -- FAILED  → PENDING (reaper, after backoff)
    -- FAILED_PERMANENT (retry_count >= max_retries; requires human intervention)
    status              TEXT    NOT NULL DEFAULT 'PENDING'
                        CHECK(status IN ('PENDING','LEASED','COMPLETED','FAILED','FAILED_PERMANENT')),

    -- Lease fields (populated on LEASED; cleared on COMPLETED/FAILED)
    worker_id           TEXT,                       -- '{hostname}-{pid}-{timestamp}'
    leased_at           TEXT,                       -- ISO8601 UTC
    lease_expires_at    TEXT,                       -- leased_at + lease_ttl_s; reaper target
    last_heartbeat_at   TEXT,                       -- Updated every 60s by active worker

    -- Completion fields (populated on COMPLETED)
    completed_at        TEXT,                       -- ISO8601 UTC
    output_file_path    TEXT,                       -- Absolute path to dig output file
    lines_in            INTEGER,                    -- Input line count (assets in chunk)
    lines_out           INTEGER,                    -- Output line count (resolved assets)

    -- Retry tracking
    retry_count         INTEGER NOT NULL DEFAULT 0,
    max_retries         INTEGER NOT NULL DEFAULT 3,
    last_error          TEXT,                       -- Last failure message (truncated to 512 chars)
    last_failed_at      TEXT,                       -- ISO8601 UTC of last failure

    -- Scheduling
    priority            INTEGER NOT NULL DEFAULT 0, -- Lower = higher priority; default equal for all chunks
    next_retry_at       TEXT,                       -- For FAILED state: earliest time reaper may re-queue

    -- Audit
    created_at          TEXT    NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
    updated_at          TEXT    NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now'))
);

-- ============================================================
-- INDEXES for chunk_queue
-- ============================================================

-- Primary dispatch path: find next PENDING chunk
CREATE INDEX IF NOT EXISTS idx_cq_status_priority
    ON chunk_queue(status, priority ASC, created_at ASC);

-- Reaper path: find expired leases
CREATE INDEX IF NOT EXISTS idx_cq_lease_expires
    ON chunk_queue(lease_expires_at)
    WHERE status = 'LEASED';

-- Reaper path: find FAILED chunks ready for retry
CREATE INDEX IF NOT EXISTS idx_cq_retry_ready
    ON chunk_queue(next_retry_at)
    WHERE status = 'FAILED';

-- Worker health monitoring
CREATE INDEX IF NOT EXISTS idx_cq_worker
    ON chunk_queue(worker_id)
    WHERE status = 'LEASED';

-- ============================================================
-- TRIGGER: auto-update updated_at on any row change
-- ============================================================
CREATE TRIGGER IF NOT EXISTS trg_cq_updated_at
    AFTER UPDATE ON chunk_queue
    FOR EACH ROW
BEGIN
    UPDATE chunk_queue
    SET updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now')
    WHERE chunk_id = OLD.chunk_id;
END;

-- ============================================================
-- TABLE: chunk_queue_audit_log
-- Append-only audit trail. One row per state transition.
-- Never delete from this table.
-- ============================================================
CREATE TABLE IF NOT EXISTS chunk_queue_audit_log (
    log_id          INTEGER PRIMARY KEY AUTOINCREMENT,
    chunk_id        TEXT    NOT NULL REFERENCES chunk_queue(chunk_id),
    from_status     TEXT,
    to_status       TEXT    NOT NULL,
    worker_id       TEXT,
    event_type      TEXT    NOT NULL,   -- 'LEASE_GRANTED','HEARTBEAT','ACK_SUCCESS','ACK_FAIL','RECLAIMED','SEEDED'
    detail          TEXT,               -- JSON blob with context (lines_in, lines_out, error, etc.)
    logged_at       TEXT    NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now'))
);

CREATE INDEX IF NOT EXISTS idx_cqal_chunk_id
    ON chunk_queue_audit_log(chunk_id, logged_at DESC);

CREATE INDEX IF NOT EXISTS idx_cqal_event_type
    ON chunk_queue_audit_log(event_type, logged_at DESC);

-- ============================================================
-- QUERY LIBRARY (for reference / monitoring)
-- ============================================================

-- [MON-1] Master queue status view
-- SELECT
--     status,
--     count(*) AS count,
--     min(created_at) AS oldest,
--     max(updated_at) AS latest_update
-- FROM chunk_queue
-- GROUP BY status
-- ORDER BY count DESC;

-- [MON-2] Currently leased chunks with heartbeat age
-- SELECT
--     chunk_id,
--     worker_id,
--     leased_at,
--     lease_expires_at,
--     last_heartbeat_at,
--     round((julianday('now') - julianday(last_heartbeat_at)) * 86400) AS heartbeat_age_s,
--     round((julianday(lease_expires_at) - julianday('now')) * 86400) AS lease_remaining_s
-- FROM chunk_queue
-- WHERE status = 'LEASED'
-- ORDER BY leased_at ASC;

-- [MON-3] Stale leases (expired but not yet reclaimed)
-- SELECT chunk_id, worker_id, lease_expires_at,
--     round((julianday('now') - julianday(lease_expires_at)) * 86400) AS expired_ago_s
-- FROM chunk_queue
-- WHERE status = 'LEASED'
--   AND lease_expires_at < strftime('%Y-%m-%dT%H:%M:%SZ','now')
-- ORDER BY lease_expires_at ASC;

-- [MON-4] Failed chunks eligible for retry
-- SELECT chunk_id, retry_count, max_retries, last_error, next_retry_at
-- FROM chunk_queue
-- WHERE status = 'FAILED'
--   AND (next_retry_at IS NULL OR next_retry_at <= strftime('%Y-%m-%dT%H:%M:%SZ','now'))
-- ORDER BY next_retry_at ASC;

-- [MON-5] Completion summary with throughput
-- SELECT
--     count(*) AS completed,
--     sum(lines_in) AS total_assets_attempted,
--     sum(lines_out) AS total_assets_resolved,
--     round(sum(lines_out) * 100.0 / nullif(sum(lines_in),0), 2) AS resolution_pct,
--     min(completed_at) AS first_completed,
--     max(completed_at) AS last_completed
-- FROM chunk_queue
-- WHERE status = 'COMPLETED';

-- [MON-6] Full pipeline pane-of-glass
-- SELECT
--     (SELECT count(*) FROM chunk_queue WHERE status='PENDING') AS pending,
--     (SELECT count(*) FROM chunk_queue WHERE status='LEASED') AS leased,
--     (SELECT count(*) FROM chunk_queue WHERE status='COMPLETED') AS completed,
--     (SELECT count(*) FROM chunk_queue WHERE status='FAILED') AS failed,
--     (SELECT count(*) FROM chunk_queue WHERE status='FAILED_PERMANENT') AS failed_permanent,
--     (SELECT count(*) FROM chunk_queue) AS total,
--     (SELECT round(count(*) * 100.0 / 51, 1) FROM chunk_queue WHERE status='COMPLETED') AS coverage_pct;

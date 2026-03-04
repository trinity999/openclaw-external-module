-- ============================================================
-- WO-00023: Sink Outbox + Event Sync Ledger + Dead Letter Queue
-- Target: ops/day1/state/scan_persistence.db
-- Type: ADDITIVE — no existing tables altered (events, files, ingest_runs untouched)
-- Safe to run multiple times (IF NOT EXISTS guards throughout)
-- Run BEFORE starting persistence_db_sink.py Phase 2 work
-- ============================================================

PRAGMA journal_mode=WAL;
PRAGMA synchronous=NORMAL;

-- ============================================================
-- TABLE: sink_outbox
-- One row per (event_id × sink_target) delivery job.
-- Populated at ingest time OR by backfill query (see below).
-- Drives the outbox sweep worker (persistence_db_sink.py).
-- ============================================================
CREATE TABLE IF NOT EXISTS sink_outbox (
    outbox_id           INTEGER PRIMARY KEY AUTOINCREMENT,

    -- Link to event (FK to events.event_id)
    event_id            TEXT    NOT NULL REFERENCES events(event_id),

    -- Which sink this row targets
    -- 'clickhouse' | 'neo4j' | extensible for future sinks
    sink_target         TEXT    NOT NULL
                        CHECK(sink_target IN ('clickhouse', 'neo4j')),

    -- Delivery state machine
    -- PENDING → SYNCED (success)
    -- PENDING → FAILED (transient error, will retry)
    -- FAILED  → PENDING (after next_retry_at, by sweep worker)
    -- FAILED  → DEAD_LETTER (after max_retries or NON_RETRYABLE error)
    -- PENDING/FAILED → SYNCED (ALREADY_SYNCED: idempotent replay)
    status              TEXT    NOT NULL DEFAULT 'PENDING'
                        CHECK(status IN ('PENDING','SYNCED','FAILED','DEAD_LETTER')),

    -- Timing
    created_at          TEXT    NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
    updated_at          TEXT    NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
    synced_at           TEXT,                           -- Populated on SYNCED
    last_failed_at      TEXT,                           -- Populated on FAILED/DEAD_LETTER

    -- Retry tracking
    retry_count         INTEGER NOT NULL DEFAULT 0,
    max_retries         INTEGER NOT NULL DEFAULT 5,
    next_retry_at       TEXT,                           -- Earliest time for next attempt
    last_error_class    TEXT,                           -- From retry_taxonomy (RETRYABLE|NON_RETRYABLE|ALREADY_SYNCED)
    last_error_message  TEXT,                           -- Truncated to 512 chars

    -- Uniqueness: one delivery job per (event_id, sink_target)
    UNIQUE(event_id, sink_target)
);

-- Indexes for sink_outbox
CREATE INDEX IF NOT EXISTS idx_so_status_target
    ON sink_outbox(sink_target, status, created_at ASC);

CREATE INDEX IF NOT EXISTS idx_so_retry_ready
    ON sink_outbox(sink_target, next_retry_at)
    WHERE status = 'FAILED';

CREATE INDEX IF NOT EXISTS idx_so_event_id
    ON sink_outbox(event_id);

-- Trigger: auto-update updated_at
CREATE TRIGGER IF NOT EXISTS trg_so_updated_at
    AFTER UPDATE ON sink_outbox
    FOR EACH ROW
BEGIN
    UPDATE sink_outbox SET updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now')
    WHERE outbox_id = OLD.outbox_id;
END;

-- ============================================================
-- TABLE: event_sync_ledger
-- Immutable append-only delivery receipts.
-- One row per successful delivery (event_id + sink_target + attempt number).
-- Never UPDATE or DELETE from this table.
-- ============================================================
CREATE TABLE IF NOT EXISTS event_sync_ledger (
    ledger_id           INTEGER PRIMARY KEY AUTOINCREMENT,
    event_id            TEXT    NOT NULL REFERENCES events(event_id),
    sink_target         TEXT    NOT NULL,
    synced_at           TEXT    NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
    delivery_attempt    INTEGER NOT NULL DEFAULT 1,     -- 1 = first delivery, >1 = replay
    batch_id            TEXT,                           -- Optional: identifies sweep batch
    rows_written        INTEGER,                        -- Rows actually written to sink
    duration_ms         INTEGER                         -- Sink write duration
);

CREATE INDEX IF NOT EXISTS idx_esl_event_id
    ON event_sync_ledger(event_id, sink_target);

CREATE INDEX IF NOT EXISTS idx_esl_synced_at
    ON event_sync_ledger(synced_at DESC);

CREATE INDEX IF NOT EXISTS idx_esl_target
    ON event_sync_ledger(sink_target, synced_at DESC);

-- ============================================================
-- TABLE: dead_letter_events
-- Permanent failure records for events that could not be delivered.
-- Requires human triage before replay.
-- ============================================================
CREATE TABLE IF NOT EXISTS dead_letter_events (
    dlq_id              INTEGER PRIMARY KEY AUTOINCREMENT,
    event_id            TEXT    NOT NULL REFERENCES events(event_id),
    sink_target         TEXT    NOT NULL,

    -- Failure details
    final_error_class   TEXT    NOT NULL,               -- RETRYABLE_EXHAUSTED | NON_RETRYABLE | SCHEMA_MISMATCH | UNKNOWN
    final_error_message TEXT,                           -- Full error message (up to 512 chars)
    total_attempts      INTEGER NOT NULL DEFAULT 1,

    -- Timeline
    first_attempted_at  TEXT,
    last_attempted_at   TEXT    NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
    added_to_dlq_at     TEXT    NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),

    -- Payload snapshot (raw_json at time of failure, for forensics + replay)
    raw_json_snapshot   TEXT,

    -- Triage
    reviewed_at         TEXT,                           -- Set by operator after investigation
    reviewed_by         TEXT,
    review_note         TEXT,
    replay_requested    INTEGER NOT NULL DEFAULT 0,     -- 0=no, 1=yes; sweep worker checks this
    replayed_at         TEXT,

    UNIQUE(event_id, sink_target)                       -- One DLQ entry per (event, sink)
);

CREATE INDEX IF NOT EXISTS idx_dle_event_id
    ON dead_letter_events(event_id);

CREATE INDEX IF NOT EXISTS idx_dle_unreviewed
    ON dead_letter_events(added_to_dlq_at DESC)
    WHERE reviewed_at IS NULL;

CREATE INDEX IF NOT EXISTS idx_dle_replay_ready
    ON dead_letter_events(added_to_dlq_at)
    WHERE replay_requested = 1 AND replayed_at IS NULL;

-- ============================================================
-- TABLE: sink_outbox_retry_log
-- Per-attempt detail log (optional, for forensics).
-- One row per delivery attempt per outbox entry.
-- ============================================================
CREATE TABLE IF NOT EXISTS sink_outbox_retry_log (
    log_id              INTEGER PRIMARY KEY AUTOINCREMENT,
    outbox_id           INTEGER NOT NULL REFERENCES sink_outbox(outbox_id),
    event_id            TEXT    NOT NULL,
    sink_target         TEXT    NOT NULL,
    attempt_number      INTEGER NOT NULL,
    attempted_at        TEXT    NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
    error_class         TEXT,
    error_message       TEXT,
    duration_ms         INTEGER,
    outcome             TEXT    NOT NULL  -- 'SYNCED' | 'FAILED' | 'DEAD_LETTERED'
                        CHECK(outcome IN ('SYNCED','FAILED','DEAD_LETTERED'))
);

CREATE INDEX IF NOT EXISTS idx_sorl_outbox_id
    ON sink_outbox_retry_log(outbox_id, attempt_number ASC);

-- ============================================================
-- BACKFILL QUERIES (run once after migration)
-- Populate sink_outbox for all existing events not yet tracked.
-- ============================================================

-- [BACKFILL-1] Populate ClickHouse outbox for all existing events
-- INSERT OR IGNORE INTO sink_outbox (event_id, sink_target, status, created_at, updated_at)
-- SELECT event_id, 'clickhouse', 'PENDING', datetime('now'), datetime('now')
-- FROM events
-- WHERE event_id NOT IN (SELECT event_id FROM sink_outbox WHERE sink_target='clickhouse');

-- [BACKFILL-2] Populate Neo4j outbox for all existing events
-- INSERT OR IGNORE INTO sink_outbox (event_id, sink_target, status, created_at, updated_at)
-- SELECT event_id, 'neo4j', 'PENDING', datetime('now'), datetime('now')
-- FROM events
-- WHERE event_id NOT IN (SELECT event_id FROM sink_outbox WHERE sink_target='neo4j');

-- ============================================================
-- MONITORING QUERIES
-- ============================================================

-- [MON-A] Outbox status by sink
-- SELECT sink_target, status, count(*) AS cnt,
--     min(created_at) AS oldest, max(updated_at) AS latest
-- FROM sink_outbox GROUP BY sink_target, status ORDER BY sink_target, status;

-- [MON-B] Outbox oldest pending age per sink
-- SELECT sink_target,
--     round(max((julianday('now')-julianday(created_at))*24),2) AS oldest_pending_h
-- FROM sink_outbox WHERE status='PENDING'
-- GROUP BY sink_target;

-- [MON-C] Delivery throughput last 1h
-- SELECT sink_target, count(*) AS synced_last_1h
-- FROM event_sync_ledger
-- WHERE synced_at > datetime('now','-1 hour')
-- GROUP BY sink_target;

-- [MON-D] Dead letter count by sink (unreviewed)
-- SELECT sink_target, count(*) AS unreviewed_dlq,
--     min(added_to_dlq_at) AS oldest_dlq_entry
-- FROM dead_letter_events WHERE reviewed_at IS NULL
-- GROUP BY sink_target;

-- [MON-E] Events not yet SYNCED to any sink
-- SELECT count(*) AS unsynced_events
-- FROM events e
-- WHERE NOT EXISTS (
--     SELECT 1 FROM sink_outbox o
--     WHERE o.event_id = e.event_id AND o.status = 'SYNCED'
--       AND o.sink_target = 'clickhouse'
-- );

-- [MON-F] Full sink health pane-of-glass
-- SELECT
--     (SELECT count(*) FROM sink_outbox WHERE status='PENDING') AS outbox_pending,
--     (SELECT count(*) FROM sink_outbox WHERE status='SYNCED') AS outbox_synced,
--     (SELECT count(*) FROM sink_outbox WHERE status='FAILED') AS outbox_failed,
--     (SELECT count(*) FROM sink_outbox WHERE status='DEAD_LETTER') AS outbox_dlq,
--     (SELECT count(*) FROM dead_letter_events WHERE reviewed_at IS NULL) AS dlq_unreviewed,
--     (SELECT count(*) FROM event_sync_ledger) AS total_deliveries,
--     (SELECT count(DISTINCT event_id) FROM event_sync_ledger) AS unique_events_delivered;

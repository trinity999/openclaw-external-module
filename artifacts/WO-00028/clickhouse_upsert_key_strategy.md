# ClickHouse Upsert Key Strategy
## Document: WO-00028 | trinity999/Pandavs-Framework@cebd2d5

---

## 1. The Problem

ClickHouse does not support `INSERT OR IGNORE` or `UPSERT` semantics in the same way as SQLite or PostgreSQL. Standard `MergeTree` tables accept all inserts including duplicates. For an event pipeline that:
- May replay the same events during backfill
- May have worker crashes that cause re-insertion of in-flight batches
- Must guarantee `replay duplicate rate <= 0.1%`

...a pure MergeTree will accumulate duplicate rows on every replay.

---

## 2. Solution: ReplacingMergeTree + event_id as ORDER BY key

### 2.1 Key choice: `event_id` (SHA-256 hash)

The `event_id` is computed in `persistence_gateway.py` as:

```python
hashlib.sha256(
    f"{tool}|{kind}|{asset}|{value}|{port}|{source_file}|{line_no}".encode()
).hexdigest()
```

Properties:
- **Deterministic**: same input always produces same hash — safe for replay
- **Globally unique per event**: captures all meaningful dimensions (tool, type, host, value, file position)
- **Already the SQLite PRIMARY KEY**: natural join key between SQLite and ClickHouse

### 2.2 Table engine: `ReplacingMergeTree(ingested_at)`

```sql
ENGINE = ReplacingMergeTree(ingested_at)
ORDER BY (event_id)
```

- **How it works**: When `OPTIMIZE TABLE ... FINAL` runs (or background merge occurs), ClickHouse keeps only the row with the greatest `ingested_at` for each unique `ORDER BY` key (`event_id`). Earlier duplicates are discarded.
- **`ingested_at` as version column**: A later insertion of the same `event_id` with a newer `ingested_at` will "win" — representing the most recent write (possibly with updated metadata).
- **No schema conflict**: Two workers inserting the same event_id at the same time is safe — eventual consistency via merge.

### 2.3 Deduplication window

`ReplacingMergeTree` deduplication is **asynchronous** — merges happen in background. During the inter-merge window, queries may return duplicates. Resolution:

```sql
-- Correct count (dedup-aware):
SELECT count() FROM pandavs_recon.scan_events FINAL;

-- Correct lookup:
SELECT * FROM pandavs_recon.scan_events FINAL WHERE event_id = '...';
```

The `FINAL` modifier forces a synchronous dedup step. This has a query-time cost but is acceptable for integrity checks. For bulk analytics (aggregate queries), omit `FINAL` and accept small overcounts until next merge — typically < 1% for active tables.

---

## 3. Alternative Strategies Considered and Rejected

### 3.1 `CollapsingMergeTree` or `VersionedCollapsingMergeTree`
- **Requires** explicit `sign` (+1/-1) column for insert/delete pairs
- **Adds complexity** to the sink worker (must track whether an event_id exists before inserting)
- **Rejected**: event stream is append-only; no need for in-place updates or deletions

### 3.2 Pre-insert existence check (`SELECT ... WHERE event_id IN (...)`)
- **Approach**: Before each batch, SELECT all event_ids from ClickHouse and filter out already-present ones
- **Problem at scale**: 500-row batch → 500-element IN clause → expensive for 4.6M+ row tables; adds network round-trip; still race-condition-prone for concurrent workers
- **Rejected**: `ReplacingMergeTree` handles this server-side without per-row checks

### 3.3 `INSERT INTO ... SELECT ... WHERE event_id NOT IN (...)`
- **Problem**: Non-atomic; another writer can insert between the SELECT and INSERT
- **Rejected**: ReplacingMergeTree is simpler and correct

### 3.4 Separate dedup table (`event_id_seen` with `AggregatingMergeTree`)
- **Approach**: Maintain a separate `seen` table; check before insert
- **Problem**: Two-table consistency is hard to maintain; adds schema surface area
- **Rejected**: ReplacingMergeTree's single-table approach is sufficient

---

## 4. Partition Strategy

```sql
PARTITION BY toYYYYMM(ts)
```

- Partitions by the source event timestamp (not ingestion timestamp)
- Keeps DNS scan data from the same month together for efficient range scans
- Allows partition-level management (drop old data, optimize specific partitions)
- Expected partition size: ~1-2 months of data; 4.6M existing rows fit in one partition

---

## 5. Key Cardinality Analysis

| Field | Cardinality | Type |
|---|---|---|
| `event_id` | ~4.6M+ unique (PK) | SHA-256 hex (64 chars) |
| `tool` | 4 (`dnsx`, `dig`, `httpx`, `naabu`) | LowCardinality(String) |
| `event_kind` | 4 (`dns_resolution`, `http_probe`, `port_open`, `raw`) | LowCardinality(String) |
| `asset` | ~10M (one per subdomain) | Nullable(String) |
| `value` | ~10M (IPs, URLs) | Nullable(String) |
| `port` | ~65535 unique | Nullable(Int32) |

**`LowCardinality(String)` for `tool` and `event_kind`**: ClickHouse stores low-cardinality fields as dictionary-encoded integers internally, reducing storage and improving filter performance. For 4-value fields like `tool`, this yields ~10x compression on those columns.

---

## 6. Replay Duplicate Rate Guarantee

**Target:** <= 0.1% duplicate rate

**Mechanism:**
1. Each `event_id` appears exactly once in SQLite `events` (PRIMARY KEY constraint)
2. `sink_outbox` has `UNIQUE(event_id, sink_target)` — prevents double-queuing
3. ClickHouse `ReplacingMergeTree` deduplicates on `event_id` ORDER BY key during merge
4. Between merges: `SELECT ... FINAL` resolves duplicates at query time

**Calculation:**
- If 4.6M events are inserted twice (full replay), ClickHouse will have 9.2M rows pre-merge
- After `OPTIMIZE TABLE scan_events FINAL`: 4.6M rows (0% duplicates)
- During inter-merge window: max temporary duplicate fraction depends on merge speed (typically < 1% of rows in any query window due to ClickHouse's aggressive background merging)
- Therefore the <= 0.1% steady-state target is achievable

---

## 7. Summary: Key Design Choices

| Choice | Value | Why |
|---|---|---|
| Table engine | ReplacingMergeTree(ingested_at) | Idempotent replay; no per-row checks needed |
| ORDER BY / PK | (event_id) | SHA-256 unique per event; maps to SQLite PK |
| Partition | toYYYYMM(ts) | Temporal locality; efficient range scans |
| Dedup at read | `FINAL` modifier on integrity queries | Correct counts without waiting for background merge |
| tool / event_kind | LowCardinality(String) | 4-value fields; storage + filter efficiency |
| Insert method | clickhouse-driver native protocol batch | 3-5x faster than HTTP for bulk inserts |
| Existence check | None pre-insert | ReplacingMergeTree handles server-side; avoids N+1 SELECT |

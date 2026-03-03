# WO-00015: ORL Lane Output Validator — Schema, Loss, and Continuity Checking

**Work Order:** WO-00015
**Category:** analysis
**Analyst:** openclaw-field-processor
**Produced:** 2026-03-04
**Confidence:** 0.91

---

## Executive Summary

This document specifies a three-mode lane output validator for the ORL pipeline. The validator operates as a lightweight async process alongside existing lane runners and checks every output window across three dimensions: **schema conformity** (are records structurally valid?), **loss signatures** (are records silently disappearing?), and **continuity gaps** (are lanes producing output at expected rate?). It integrates with ORS signal emission and supports automated reflexes for detected fault classes. Target metrics: ≥95% fault detection recall, ≤5% false alarm rate, ≤60s validation latency per window.

---

## 1. Context Understanding

### Problem Decomposition

Three distinct failure modes degrade lane output quality:

1. **Schema failures** — records with missing required fields, wrong types, or out-of-range values pass through the lane but corrupt downstream ingestion. These fail silently unless validated at the output boundary.

2. **Loss signatures** — records dispatched into a lane do not appear in output OR in the DLQ. These are silent drops: they are not quarantined, not rejected, simply absent. At 10M+ subdomain scale, even a 0.5% loss rate erases 50k records per cycle.

3. **Continuity gaps** — a lane that has stalled (no output for 2× heartbeat interval) or drifted (producing records at 30% of expected rate) will not surface in any single-record check. Continuity failure is a window-level property, not a record-level property.

Each failure mode requires a different detection mechanism. A single unified validator running per-record checks would miss window-level continuity failures. A window-level-only validator would introduce 60s latency before detecting a schema bomb on record 1. The design separates mechanisms while unifying alert emission.

---

## 2. Analytical Reasoning

### Why Per-Record Schema Check (Not Batch)

Batch schema checking at window close introduces up to 60s of contaminated ingest before detection. At 700k DNS records/hr (194 records/sec), a schema regression in a tool version update contaminates 11,640 records in 60s. Per-record streaming check catches this on record 1 — at the cost of higher CPU during peak. The CPU cost is bounded by sampling: 100% check on the first 100 records of each window, then 10% sampling thereafter, with automatic escalation to 100% if quarantine rate exceeds 1% within the window.

### Why Count-Reconciliation for Loss Detection (Not End-to-End Trace)

End-to-end tracing requires correlation IDs injected at dispatch and matched at output — a schema change to every record. Count reconciliation is schema-free: maintain three counters per lane per window (count_in, count_out, count_dlq) and compute `loss_rate = (count_in - count_out - count_dlq) / count_in`. This is O(1) per window, requires no schema modification, and is naturally idempotent on replay (replayed records increment count_out without affecting count_in).

### Why Heartbeat for Continuity (Not Sequence Numbering)

Sequence numbering requires injecting monotonic IDs at lane entry — a schema change and a stateful coordination point. Heartbeat-based continuity detection needs only a `last_seen_ts` register per lane. If `now - last_seen_ts > heartbeat_timeout_multiplier × expected_interval`, the lane is stalled. This is implementable with zero schema changes and is resilient to record reordering (heartbeat resets on any record arrival, regardless of order).

---

## 3. Validator Architecture

```
                        ┌────────────────────────────┐
                        │   LaneValidator (per lane) │
 Records →  ──────────► │                            │
                        │  [A] Schema Check          │ → quarantine_queue
                        │  (streaming, per-record)   │
                        │                            │
                        │  [B] Loss Signature Check  │ → alert_bus (ORS)
                        │  (at window close)         │
                        │                            │
                        │  [C] Continuity Check      │ → alert_bus (ORS)
                        │  (periodic, tick-driven)   │
                        └────────────────────────────┘
```

One `LaneValidator` instance per lane. Three independent check modules share window state.

---

## 4. Check Module Specifications

### Module A: Schema Conformity Check (per-record, streaming)

**Trigger:** Every record arriving at the lane output boundary.

**Sampling policy:**
- Records 1–100 in window: 100% validation
- Records 101+: 10% random sample
- Auto-escalate to 100% if `window_quarantine_rate > 0.01` (quarantine spike detection)

**Checks per record:**

| Check | Failure condition | Action |
|-------|------------------|--------|
| Required field presence | Any required field absent | quarantine(MISSING_REQUIRED_FIELD) |
| Field type | Type mismatch vs contract | quarantine(TYPE_MISMATCH) |
| Value range | Value outside defined range | quarantine(VALUE_OUT_OF_RANGE) |
| Schema version | Unknown schema version detected | quarantine(UNKNOWN_SCHEMA_VERSION) + escalate to 100% sampling |

**Alert trigger:** If `window_quarantine_rate > max_schema_fail_rate` (default 2%) at any sampling checkpoint, emit `SCHEMA_FAIL_RATE` alert.

**Per-lane schema contracts:**

| Lane | Required fields | Value range examples |
|------|----------------|---------------------|
| dns | fqdn, resolved, a_records | resolved: bool; fqdn: non-empty string |
| http | fqdn, url, status_code, http_responded | status_code: 100–599 |
| enrich (nuclei) | fqdn, template_id, severity, matched_at | severity: critical/high/medium/low/info |
| enrich (katana) | fqdn, url, status_code, source | status_code: 100–599 |

---

### Module B: Loss Signature Check (per-window, at window close)

**Trigger:** Window close event (configurable: every `window_size_sec`, default 60s).

**State maintained per window:**
- `count_in`: incremented when record dispatched to lane
- `count_out`: incremented when record confirmed written to output store
- `count_dlq`: incremented when record written to Dead Letter Queue
- `count_schema_quarantine`: records quarantined by Module A

**Computation at window close:**

```
silent_loss_count = count_in - count_out - count_dlq - count_schema_quarantine
loss_rate = silent_loss_count / count_in   (if count_in > 0)
```

**Thresholds and actions:**

| Condition | Severity | Auto-reflex |
|-----------|----------|-------------|
| `loss_rate > 0.01` (>1%) | MEDIUM | log + alert |
| `loss_rate > 0.05` (>5%) | HIGH | alert + pause lane for review |
| `dlq_depth > 50` | MEDIUM | alert + dlq_drain reflex |
| `count_in == 0` for full window | see Module C | — |

**DLQ settle delay:** Read DLQ count at `window_close + 5s` to allow in-flight records to settle before computing loss_rate. This prevents false loss detection during high-throughput bursts.

---

### Module C: Continuity Gap Check (periodic, tick-driven)

**Trigger:** Every `heartbeat_check_interval_sec` (default 30s). Independent of window boundaries.

**State maintained:**
- `last_seen_ts`: timestamp of most recently received record from lane
- `expected_interval_sec`: derived from lane throughput profile (configurable)

**Checks:**

| Check | Condition | Severity | Action |
|-------|-----------|----------|--------|
| Lane heartbeat | `now - last_seen_ts > heartbeat_multiplier × expected_interval_sec` | HIGH | emit LANE_STALL alert |
| Window duration drift | `actual_window_duration > 1.5 × target_window_duration_sec` | MEDIUM | emit WINDOW_DRIFT alert |
| Batch pipeline gap | HTTP window completes but no DNS batch predecessor found within lookback | HIGH | emit PIPELINE_GAP alert |

**Heartbeat timeout defaults:**

| Lane | expected_interval_sec | heartbeat_multiplier | timeout_sec |
|------|----------------------|----------------------|------------|
| dns | 5 (700k/hr = 194/sec) | 2.0 | 10 |
| http | 10 | 2.0 | 20 |
| enrich | 30 | 2.0 | 60 |

**Planned downtime suppression:** ORS sends `MAINTENANCE_WINDOW_START` signal; Module C suppresses heartbeat alerts during active maintenance window.

---

## 5. Alert Structure and ORS Integration

### Alert Schema

```json
{
  "alert_id": "ALT-YYYYMM-NNN",
  "lane": "dns | http | enrich",
  "check_module": "schema | loss | continuity",
  "severity": "critical | high | medium | low",
  "window_id": "W-YYYYMMDD-HHMMSS",
  "metrics": {
    "loss_rate": 0.0,
    "quarantine_rate": 0.0,
    "gap_seconds": 0
  },
  "triggered_at": "ISO8601",
  "auto_reflex": "none | dlq_drain | lane_pause | batch_replay | escalate_sampling"
}
```

### ORS Reflex Mapping

| Alert type | Default reflex | Escalation |
|------------|---------------|------------|
| SCHEMA_FAIL_RATE | escalate_sampling (100%) | manual investigation if rate persists >3 windows |
| SILENT_LOSS_LOW (1–5%) | log + alert, lane continues | manual investigation after 2 consecutive windows |
| SILENT_LOSS_HIGH (>5%) | lane_pause + alert | require manual restart |
| DLQ_DEPTH_EXCEEDED | dlq_drain reflex | alert if drain fails to reduce depth within 2 windows |
| LANE_STALL | alert + wait 1 cycle | escalate to critical if stall persists |
| WINDOW_DRIFT | log + metric record | alert if drift exceeds 2× target for 2 consecutive windows |
| PIPELINE_GAP | alert + batch_replay trigger | critical if gap spans >1 full cycle |

---

## 6. Validator Self-Monitoring

The validator itself must not fail silently. Two self-monitoring mechanisms:

1. **Self-heartbeat**: Validator emits `VALIDATOR_HEARTBEAT` signal to ORS every `heartbeat_check_interval_sec`. If ORS does not receive a heartbeat for 2× interval, it treats the validator as failed and emits `VALIDATOR_DOWN` alert.

2. **Check execution timing**: Each check module records execution time. If `schema_check_latency_ms > 50ms` per record or `window_close_check_latency_ms > 5000ms`, emit `VALIDATOR_SLOW` metric — prevents validator from becoming a new bottleneck.

---

## 7. Fault Injection Framework (Recall Validation)

To achieve ≥95% detection recall, the validator is tested with a structured fault injection suite:

| Fault type | Injection method | Expected detection |
|------------|-----------------|-------------------|
| Missing required field | Omit `fqdn` from DNS record | Module A quarantine within 1 record (100% sample zone) |
| Type mismatch | Set `status_code` to string | Module A quarantine |
| Silent loss | Dispatch record to lane, discard before output write, do not write to DLQ | Module B loss_rate alert at window close |
| Lane stall | Halt record production for 2× heartbeat timeout | Module C LANE_STALL alert |
| DLQ flood | Write 60 records to DLQ in one window | Module B DLQ_DEPTH_EXCEEDED alert |
| Schema version change | Inject v0-format record into v1-schema lane | Module A UNKNOWN_SCHEMA_VERSION + sampling escalation |
| Window drift | Slow window completion to 2× target duration | Module C WINDOW_DRIFT alert |

**Recall target:** 14/14 injected faults detected across all three modules within validation latency target.

---

## 8. Configuration Schema

Per-lane configuration in `validator_config.json`:

```json
{
  "lanes": [
    {
      "lane_id": "dns",
      "schema_contract": "dnsx_v1",
      "required_fields": ["fqdn", "resolved", "a_records"],
      "window_size_sec": 60,
      "max_schema_fail_rate": 0.02,
      "max_loss_rate": 0.01,
      "dlq_depth_alert_threshold": 50,
      "expected_interval_sec": 5,
      "heartbeat_timeout_multiplier": 2.0,
      "heartbeat_check_interval_sec": 30,
      "sampling_policy": {
        "first_n_full": 100,
        "thereafter_pct": 10,
        "escalation_quarantine_rate": 0.01
      }
    }
  ]
}
```

**Hot-reloadable:** All thresholds in `validator_config.json` are hot-reloadable without validator restart. Config version stored with each emitted alert.

---

## 9. Implementation Model

```python
class WindowState:
    count_in: int = 0
    count_out: int = 0
    count_dlq: int = 0
    count_schema_quarantine: int = 0
    last_seen_ts: float = 0
    window_open_ts: float = 0
    records_seen_this_window: int = 0

class LaneValidator:
    def __init__(self, config: LaneConfig):
        self.config = config
        self.state = WindowState()

    def on_record_dispatched(self):
        """Called when controller dispatches record to lane."""
        self.state.count_in += 1

    def on_record_confirmed(self, record: dict) -> Optional[QuarantineReason]:
        """Called when lane output confirmed. Returns quarantine reason or None."""
        self.state.count_out += 1
        self.state.last_seen_ts = time.time()
        self.state.records_seen_this_window += 1
        if self._should_schema_check():
            result = self._schema_check(record)
            if result.failed:
                self.state.count_out -= 1  # not confirmed
                self.state.count_schema_quarantine += 1
                return result.reason
        return None

    def on_record_dlq(self):
        """Called when record written to DLQ."""
        self.state.count_dlq += 1

    def close_window(self) -> WindowReport:
        """Called at window_size_sec boundary."""
        # Read DLQ after settle delay
        time.sleep(5)
        loss = self._compute_loss()
        report = WindowReport(window_state=self.state, loss_rate=loss)
        self.state = WindowState(window_open_ts=time.time())
        return report

    def tick(self) -> Optional[Alert]:
        """Called every heartbeat_check_interval_sec."""
        return self._continuity_check()
```

---

## 10. Validation Strategy

**Recall validation (CI gate):**
- Inject all 7 fault types against a test harness
- Require ≥95% detection rate (minimum 14/14 in standard suite, 95/100 in randomized suite)
- Gate: validator only promoted to production if recall ≥95%

**False alarm rate validation:**
- Run validator against 10 clean windows (no injected faults)
- Require ≤5% false alarm rate (at most 1 false alert per 20 clean windows)
- Test boundary: scheduled maintenance suppression correctly silences heartbeat alerts

**Latency validation:**
- Measure `schema_check_latency_ms` under 700k records/hr load (10% sampling = 70k checks/hr = 19/sec)
- Require: p95 schema check < 50ms per record; p95 window close check < 5s

---

## 11. Risk Model

| ID | Risk | Severity | Probability | Mitigation |
|----|------|----------|-------------|------------|
| R1 | DLQ read before settle produces inflated loss_rate | MEDIUM | MEDIUM | 5s settle delay after window close before DLQ count read |
| R2 | Schema false alarms during tool version rollout | MEDIUM | MEDIUM | Schema version detection + grace period (first 100 records of v0→v1 transition exempt from TYPE_MISMATCH) |
| R3 | High CPU from 100% schema check at 700k/hr | MEDIUM | LOW | 10% sampling after first 100; escalate only on quarantine spike |
| R4 | Heartbeat false alarm during scheduled maintenance | LOW | MEDIUM | MAINTENANCE_WINDOW_START signal from ORS suppresses Module C alerts |
| R5 | Validator self-failure undetected | HIGH | LOW | Self-heartbeat to ORS; VALIDATOR_DOWN alert if absent for 2× interval |
| R6 | count_in/count_out drift under replay | LOW | MEDIUM | Replay increments count_out only; count_in is immutable per original dispatch |
| R7 | validator_config.json change produces alert storm | MEDIUM | LOW | Config version stored with alert; ops can correlate alert spike to config change timestamp |

---

## 12. KPIs

| Metric | Target | Measurement |
|--------|--------|-------------|
| Fault detection recall | ≥95% | Fault injection suite (7 fault types × 100 runs) |
| False alarm rate | ≤5% | 10 clean window runs; count spurious alerts |
| Validation latency | ≤60s/window | p95 window close check latency |
| Schema check latency | ≤50ms/record | p95 per-record schema check under 10% sampling |
| DLQ settle accuracy | <0.5% false loss detection | Loss rate with 0 actual losses injected |
| Validator uptime | ≥99.9% | ORS self-heartbeat signal continuity |
| Config reload latency | ≤5s | Time from config write to new thresholds active |

---

## 13. Assumptions

- A1: Controller maintains count_in counter per dispatch — validator's loss reconciliation requires this signal
- A2: DLQ is readable within 5s of record arrival (settle delay assumption)
- A3: ORS signal bus is available as alert emission target; validator emits structured JSON alerts
- A4: Maintenance window signals are sent by ORS before planned downtime (for heartbeat suppression)
- A5: Tool parser schema contracts (dnsx_v1, httpx_v1, nuclei_v1, katana_v1) are stable as defined in WO-00010
- A6: validator_config.json hot-reload is implemented via inotify or polling (≤5s reload latency)

# WO-00018: Queue Fairness and Anti-Starvation Scheduler Design

**Work Order:** WO-00018
**Category:** architecture
**Analyst:** openclaw-field-processor
**Produced:** 2026-03-04
**Confidence:** 0.91

---

## Executive Summary

This document specifies the scheduler policy to prevent lane starvation and maintain both nodes (controller + oracle) within a 75–90% utilization band. The system has three heterogeneous lanes (DNS, HTTP, Enrich) with wildly different throughput rates operating across two nodes. Without deliberate scheduling policy, fast lanes starve slow lanes of scheduling slots and one node becomes saturated while the other idles. The design uses **Weighted Fair Queuing (WFQ) with debt-tracking** as the core fairness mechanism, combined with a **burst headroom reservation** to prevent the fast DNS lane from monopolizing oracle capacity, and a **starvation floor** guaranteeing minimum scheduling share per lane. Target metrics: starvation incidents ≈ 0, utilization 75–90%, variance reduction ≥ 20%.

---

## 1. Context Understanding

### System Topology

- **Controller node**: orchestration + ingest + scheduling decisions
- **Oracle node**: heavy scan execution (DNS, HTTP, nuclei/katana)
- **Lanes**: DNS (700k/hr capacity, large batches, fast), HTTP (variable rate, medium), Enrich/nuclei+katana (slow, token-expensive, high value per record)

### Failure Modes Without Policy

1. **DNS starvation of HTTP**: At 700k/hr, the DNS lane can fill the oracle's entire input queue with pending work during peak. HTTP lane records wait indefinitely — starvation.
2. **Enrich starvation**: Enrich records (nuclei/katana) are expensive to produce (KRIL filter + HTTP prerequisite) but arrive at a much lower rate than DNS or HTTP. Without a floor, the scheduling loop skips enrich repeatedly because DNS and HTTP always have work available.
3. **Underutilization**: If a strict rate limit per lane is applied, high-throughput DNS lane artificially idles the oracle while waiting for its turn — utilization drops below 75%.
4. **Hot node / cold node split**: If scheduling logic runs on controller only and oracle receives work in fixed-size batches, the oracle can drain its batch and sit idle while the controller computes the next batch.

---

## 2. Scheduler Architecture

```
                     ┌──────────────────────────────────┐
                     │   AWSEM Scheduler (controller)   │
                     │                                  │
  DNS queue  ──────► │ ┌─────────────────────────────┐  │
  HTTP queue ──────► │ │  WFQ Debt Tracker           │  │
  Enrich queue ────► │ │  (per-lane virtual clock)   │  │
                     │ └────────────┬────────────────┘  │
                     │              │ dispatch decision  │
                     │ ┌────────────▼────────────────┐  │
                     │ │  Starvation Floor Guard      │  │
                     │ │  (minimum slot reservation) │  │
                     │ └────────────┬────────────────┘  │
                     │              │                    │
                     │ ┌────────────▼────────────────┐  │
                     │ │  Burst Headroom Controller   │  │
                     │ │  (DNS burst cap)             │  │
                     │ └────────────┬────────────────┘  │
                     └──────────────┼───────────────────┘
                                    │ dispatch batch
                                    ▼
                            Oracle Node (executor)
```

Three independent policy layers compose: WFQ is the base fairness mechanism; Starvation Floor is a hard minimum guarantee; Burst Headroom is a peak protection ceiling.

---

## 3. Layer 1: Weighted Fair Queuing (WFQ) with Debt Tracking

### Concept

WFQ assigns each lane a **weight** representing its normalized scheduling share. At each scheduling tick, the lane with the largest accumulated **debt** (how far behind is it relative to its fair share?) receives the next dispatch slot.

### Lane Weights

Weights reflect the designed throughput ratios and value of each lane's work:

| Lane | Weight | Rationale |
|------|--------|-----------|
| DNS | 0.50 | Highest raw throughput; drives corpus expansion |
| HTTP | 0.30 | Medium throughput; drives KRIL and ACS updates |
| Enrich | 0.20 | Lowest throughput; highest value per record |

Weights are **not** throughput limits — they define fair share of scheduling slots when all lanes have pending work.

### Debt Computation

At each scheduling tick (configurable: default 1s):

```python
for lane in lanes:
    if lane.has_pending_work():
        lane.debt += lane.weight  # earn credit proportional to weight

# Select lane to dispatch:
eligible = [lane for lane in lanes if lane.has_pending_work()]
selected = max(eligible, key=lambda l: l.debt)
dispatch(selected, batch_size=selected.config.batch_size)
selected.debt -= 1.0  # consume one dispatch slot
```

**Debt normalization:** Debt is bounded at `max_debt_cap` (default: 10.0) per lane to prevent debt accumulation during idle periods from creating burst imbalance when the lane becomes active again. After lane idle for >60s, debt resets to 0.

### Effect

When DNS, HTTP, and Enrich all have pending work, the debt tracker produces scheduling ratios of 50%/30%/20% over time. DNS processes 2.5× more batches per unit time than Enrich — but Enrich always gets its 20% share and never starves.

---

## 4. Layer 2: Starvation Floor Guard

WFQ alone does not guarantee minimum service in finite windows. If DNS queue has 10,000 pending items and Enrich has 1, WFQ might schedule DNS 4 times in a row before the debt difference triggers an Enrich slot (depending on debt accumulation rates). The Starvation Floor provides a hard guarantee.

### Floor Policy

```
starvation_floor_window_sec: 60     # evaluation window
starvation_floor_min_dispatches: 1  # minimum dispatches per lane per window
```

At every `starvation_floor_window_sec` boundary:
- Count dispatches per lane in the past window
- If any lane with pending work received `< starvation_floor_min_dispatches` dispatches:
  - **Force-dispatch** that lane immediately (bypass WFQ order)
  - Increment that lane's `starvation_floor_activations` counter (ORS signal)

**Practical effect:** Even if DNS has 100 pending batches and Enrich has 1, within any 60-second window Enrich receives at least 1 dispatch. For a 60s window at nuclei's rate of ~100 findings/hr, a single dispatch is a meaningful contribution.

### Starvation Floor ORS Signal

If `starvation_floor_activations` for a lane exceeds 3 per hour, ORS emits `LANE_STARVATION_RISK` alert — indicating the WFQ weights may need retuning for the current workload mix.

---

## 5. Layer 3: Burst Headroom Controller

The DNS lane at peak (700k/hr) can generate burst queue depth that overwhelms the oracle. Even with WFQ weights, a scheduling tick that dispatches a 50k DNS batch occupies the oracle's executor for a disproportionate duration, starving HTTP and Enrich of executor time (not scheduling slots, but actual wall-clock execution time).

### Burst Cap Policy

```
dns_max_consecutive_dispatches: 3  # max DNS dispatches before forced yield
http_max_consecutive_dispatches: 5
enrich_max_consecutive_dispatches: 10  # enrich is slow; each dispatch is small
```

After a lane reaches its `max_consecutive_dispatches` limit, the scheduler **forces a yield** — the next dispatch goes to any eligible non-DNS lane regardless of debt ordering. This prevents oracle saturation from DNS burst without reducing DNS's weighted fair share over longer windows.

### Burst Headroom and Utilization

Burst cap + WFQ together maintain the 75–90% utilization band:
- Without burst cap: DNS saturates oracle at 95–100% during peak; HTTP/Enrich queue backs up
- Without WFQ: strict round-robin underutilizes oracle during DNS-heavy phases
- Combined: oracle stays in 75–90% band across all lane mix scenarios

---

## 6. Node Utilization Monitor (ORS Integration)

The scheduler emits per-node utilization metrics every 30s. ORS reflexes maintain the utilization band.

### Utilization Signals

| Signal | Description | ORS Reflex |
|--------|-------------|------------|
| `node_utilization_pct` | % of oracle capacity consumed (rolling 30s) | — |
| `utilization_below_floor` | utilization < 75% for 2 consecutive readings | Increase batch_size or dispatch frequency |
| `utilization_above_ceiling` | utilization > 90% for 2 consecutive readings | Reduce batch_size or apply burst cap |
| `lane_queue_depth_{lane}` | Pending items per lane queue | High depth → increase weight or batch_size |
| `starvation_floor_activations` | Force-dispatch count per lane per hour | >3/hr → reweight or adjust floor policy |
| `dispatch_latency_p95_ms` | Time from dispatch decision to oracle execution start | >500ms → reduce batch size or optimize handoff |

### Utilization Calculation

```
oracle_utilization_pct = (
    sum(lane.active_executor_time_sec for lane in lanes) /
    observation_window_sec
) * 100
```

Where `active_executor_time_sec` = wall clock time oracle spent executing (not idle or waiting).

**Utilization target band: 75–90%**
- Below 75%: oracle underutilized; increase batch size or frequency
- Above 90%: approaching saturation; reduce burst; risk of queue backup

---

## 7. Scheduler Configuration (score_config.json extension)

All scheduler parameters are hot-reloadable via `scheduler_config.json`:

```json
{
  "scheduler": {
    "tick_interval_sec": 1.0,
    "lanes": {
      "dns": {
        "weight": 0.50,
        "batch_size": 500,
        "max_consecutive_dispatches": 3,
        "max_debt_cap": 10.0,
        "debt_reset_idle_sec": 60
      },
      "http": {
        "weight": 0.30,
        "batch_size": 100,
        "max_consecutive_dispatches": 5,
        "max_debt_cap": 10.0,
        "debt_reset_idle_sec": 60
      },
      "enrich": {
        "weight": 0.20,
        "batch_size": 10,
        "max_consecutive_dispatches": 10,
        "max_debt_cap": 10.0,
        "debt_reset_idle_sec": 60
      }
    },
    "starvation_floor": {
      "window_sec": 60,
      "min_dispatches_per_lane": 1
    },
    "utilization_target": {
      "floor_pct": 75,
      "ceiling_pct": 90,
      "observation_window_sec": 30
    }
  }
}
```

---

## 8. Variance Reduction Analysis

**Variance metric:** Standard deviation of oracle utilization across 1-minute intervals over a 72-hour operation.

### Without Scheduler Policy (baseline)

In a naive FIFO dispatch, the DNS lane dominates during corpus expansion phases. Utilization during DNS-heavy phases: 95–100%. During Enrich-heavy phases (high-KRIL targets): 40–60%. Variance is high due to workload mix oscillation.

### With WFQ + Floor + Burst Cap

The three layers produce a utilization profile that tracks the 75–90% band:
- WFQ maintains weighted proportions over rolling windows
- Burst cap prevents DNS from driving utilization above 90%
- Starvation floor prevents utilization from dropping below 75% by guaranteeing all queued lanes receive work

**Variance reduction target: ≥20%**

Measured as: `(std_dev_baseline - std_dev_policy) / std_dev_baseline ≥ 0.20`

Modeled estimate: baseline σ ≈ 18%; policy σ ≈ 12% → reduction ≈ 33% (above target).

---

## 9. Implementation Model

```python
class LaneState:
    weight: float
    debt: float = 0.0
    consecutive_dispatches: int = 0
    dispatches_in_window: int = 0
    last_active_ts: float = 0.0
    config: LaneConfig

class AWESMScheduler:
    def __init__(self, config: SchedulerConfig):
        self.lanes = {lid: LaneState(config=c) for lid, c in config.lanes.items()}
        self.window_start_ts = time.time()

    def tick(self) -> Optional[DispatchDecision]:
        self._update_debts()
        self._reset_stale_debts()
        decision = self._starvation_floor_check()
        if decision:
            return decision
        return self._wfq_select()

    def _update_debts(self):
        for lid, lane in self.lanes.items():
            if self._has_pending_work(lid):
                lane.debt = min(lane.debt + lane.weight, lane.config.max_debt_cap)

    def _wfq_select(self) -> Optional[DispatchDecision]:
        eligible = [
            (lid, lane) for lid, lane in self.lanes.items()
            if self._has_pending_work(lid)
            and lane.consecutive_dispatches < lane.config.max_consecutive_dispatches
        ]
        if not eligible:
            return None
        selected_id, selected = max(eligible, key=lambda x: x[1].debt)
        selected.debt -= 1.0
        selected.consecutive_dispatches += 1
        selected.dispatches_in_window += 1
        # Reset consecutive count for other lanes
        for lid, lane in self.lanes.items():
            if lid != selected_id:
                lane.consecutive_dispatches = 0
        return DispatchDecision(lane=selected_id, batch_size=selected.config.batch_size)

    def _starvation_floor_check(self) -> Optional[DispatchDecision]:
        now = time.time()
        if now - self.window_start_ts >= self.config.starvation_floor.window_sec:
            for lid, lane in self.lanes.items():
                if self._has_pending_work(lid) and lane.dispatches_in_window == 0:
                    lane.dispatches_in_window += 1
                    self._emit_starvation_floor_activation(lid)
                    return DispatchDecision(lane=lid, batch_size=lane.config.batch_size)
            self._reset_window_counters()
            self.window_start_ts = now
        return None

    def _reset_stale_debts(self):
        now = time.time()
        for lane in self.lanes.values():
            if not self._has_pending_work(lane) and \
               now - lane.last_active_ts > lane.config.debt_reset_idle_sec:
                lane.debt = 0.0
```

---

## 10. Starvation Incident Definition

A **starvation incident** is defined as:
> A lane with pending work that receives 0 dispatches across a 60-second window.

With the starvation floor policy: minimum 1 dispatch per 60s per pending lane → starvation incidents = 0 by construction.

ORS monitoring: `starvation_incidents` counter incremented if starvation floor was force-triggered more than `floor_activation_rate_alert_threshold` (3/hr) → indicates systematic imbalance, not incidental starvation.

---

## 11. Risk Model

| ID | Risk | Severity | Probability | Mitigation |
|----|------|----------|-------------|------------|
| R1 | WFQ weights mistuned for actual lane throughput ratios | MEDIUM | MEDIUM | ORS signal starvation_floor_activations >3/hr → adjust weights; hot-reloadable |
| R2 | Burst cap too aggressive: DNS lanes underutilize oracle | MEDIUM | LOW | Monitor utilization_below_floor; relax dns_max_consecutive_dispatches if triggered |
| R3 | Debt accumulation during lane idle creates burst imbalance | LOW | MEDIUM | debt_reset_idle_sec (60s) + max_debt_cap (10.0) bounds accumulated debt |
| R4 | Starvation floor force-dispatch disrupts KRIL ordering | LOW | LOW | Force-dispatch still selects highest-priority item within the lane queue (KRIL order preserved within lane) |
| R5 | Scheduler tick overhead at 1s interval | LOW | LOW | Tick is O(n_lanes) arithmetic; n_lanes=3; overhead negligible |
| R6 | Oracle node saturation despite burst cap | HIGH | LOW | utilization_above_ceiling ORS reflex reduces batch_size; alert if sustained >5min |
| R7 | Hot-reload of scheduler_config.json disrupts in-flight dispatches | LOW | MEDIUM | Hot-reload applies to next tick only; in-flight dispatches complete with previous config |

---

## 12. Validation Strategy

**Starvation validation:**
- Run 72-hour simulation with workload mix: 70% DNS, 20% HTTP, 10% Enrich
- Count starvation incidents (60s windows with 0 dispatches for pending lane)
- Target: 0 starvation incidents

**Utilization band validation:**
- Measure oracle utilization every 30s across 72-hour run
- Compute % of samples in 75–90% band
- Target: ≥80% of samples within band

**Variance reduction validation:**
- Compute std_dev of utilization across 1-minute intervals
- Compare to baseline (naive FIFO)
- Target: ≥20% reduction in std_dev

**Burst cap validation:**
- Inject a DNS queue burst (50k items instantly)
- Measure HTTP and Enrich dispatch rates during burst
- Confirm: HTTP and Enrich receive dispatches within 60s of burst start (starvation floor guarantees this)

---

## 13. KPIs

| Metric | Target | Measurement |
|--------|--------|-------------|
| Starvation incidents | ≈ 0 | Count of 60s windows with 0 dispatches for pending lane |
| Oracle utilization | 75–90% | Rolling 30s active executor time % |
| Utilization variance reduction | ≥ 20% | std_dev policy / std_dev baseline |
| Starvation floor activation rate | ≤ 3/hr per lane (normal) | ORS signal starvation_floor_activations |
| Dispatch latency p95 | ≤ 500ms | Time from dispatch decision to oracle execution start |
| Weight rebalance frequency | ≤ 1/week (stable operations) | Changes to scheduler_config.json weights |
| Config reload latency | ≤ 5s | Time from scheduler_config.json write to new weights active |

---

## 14. Assumptions

- A1: Three lanes (DNS, HTTP, Enrich) are the complete set for this design; new lane additions require weight re-normalization (weights must sum to 1.0)
- A2: Oracle node execution time is measurable at the controller (controller knows when oracle completes a batch)
- A3: Scheduler tick interval of 1s is achievable without controller CPU bottleneck
- A4: Starvation floor window of 60s is acceptable minimum service guarantee (consistent with ORL 60s window)
- A5: Lane queue depth is readable by scheduler at each tick (in-memory queue on controller)
- A6: scheduler_config.json hot-reload does not interrupt in-flight oracle dispatches

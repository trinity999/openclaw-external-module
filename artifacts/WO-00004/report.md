# ARTIFACT: WO-00004
# Cost-Optimized Model Routing Policy for 72h High-Load Recon Operations

**Analyst:** OpenClaw Field Processor
**Work Order:** WO-00004
**Category:** Research
**Priority:** Medium
**Date:** 2026-03-03
**Status:** COMPLETED

---

## Executive Summary

WO-00004 produces a deterministic model routing policy for a multi-lane recon system operating over 72 hours of high task volume. The policy implements **cheapest-capable-first** routing with validated escalation gates — no premium model usage without confirmed failure at a lower tier.

Key outputs:
1. **Task family taxonomy** — 9 task families mapped to model tiers
2. **Routing decision table** — deterministic per-family routing with escalation conditions
3. **Escalation trigger specification** — quantified thresholds replacing subjective assessment
4. **Arbitration budget** — premium model usage cap with ORS enforcement
5. **KRIL impact analysis** — how selective mode directly reduces token spend
6. **Confidence threshold framework** — quality gates per task family
7. **Projected cost savings** — ≥20% reduction from untuned baseline, ≥80% vs. premium-only

---

## Context Understanding

### System State (from WO-00004)

- **Limited autonomy active** — human-in-loop for critical decisions; model routing governs analytical sub-tasks
- **KRIL selective mode** — only top-ranked targets receive deep analysis; lower-ranked targets get lightweight processing
- **ORS reflex active** — operational signals trigger automatic responses
- **AWSEM scheduler active** — task queue management and dispatch
- **Scale:** High task volume from parallel lanes; recurring status/reporting overhead
- **Gap:** No deeply tuned cost-quality frontier exists today; routing is either ad-hoc or defaulting to premium

### The Routing Problem

A recon system at scale issues two categories of LLM tasks:
1. **Structural tasks** — parsing, validation, classification, reporting — well-defined inputs, deterministic expected outputs; small, fast models handle these correctly
2. **Reasoning tasks** — anomaly investigation, enrichment interpretation, pattern detection — open-ended inputs requiring multi-step inference; larger models are required

Without explicit routing, all tasks tend to default to the highest-capability model available. At 72h high-load operation, this is economically unsustainable and creates unnecessary latency where fast cheap models would suffice.

The routing policy must:
- Route structural tasks to Tier 1 (cheapest, fastest)
- Route analytical tasks to Tier 2 (mid-tier, balanced)
- Reserve Tier 3 (premium) for validated failure at Tier 2, or for tasks explicitly classified as requiring deep reasoning
- Never escalate based on opinion — only on measurable signals

---

## Analytical Reasoning

### Model Tier Definitions

Three tiers are defined by capability and cost. Specific model IDs are not pinned to allow provider flexibility.

| Tier | Capability Profile | Cost Index | Latency | Examples |
|------|-------------------|------------|---------|----------|
| T1 — Lightweight | JSON parsing, classification, regex-equivalent pattern matching, template-fill summarization | 1× | Fast (<1s) | Haiku-class, GPT-3.5-class |
| T2 — Analytical | Multi-step reasoning, pattern detection, ranked analysis, structured inference with uncertainty | 5× | Medium (1–5s) | Sonnet-class, GPT-4o-mini-class |
| T3 — Premium | Deep reasoning, novel architecture proposals, adversarial analysis, complex multi-constraint optimization | 25× | Slow (5–30s) | Opus-class, GPT-4-class |

**Cost index is relative.** T3 at 25× T1 means 1 T3 call costs as much as 25 T1 calls. Routing decisions must account for this multiplier explicitly.

### Task Volume Composition (estimated for recon workload)

Based on typical multi-lane recon pipeline task distribution:

| Task Family | Volume % | Tier Assignment |
|-------------|----------|----------------|
| F1: Structured parsing (DNS/HTTP JSON, schema validation) | 35% | T1 |
| F2: Alert triage / classification | 20% | T1 |
| F3: Status/batch reporting (Mattermost summaries) | 12% | T1 |
| F4: HTTP response pattern analysis | 10% | T2 |
| F5: KRIL target ranking and scoring | 8% | T2 |
| F6: Enrichment finding interpretation | 7% | T2 |
| F7: Anomaly investigation (high KRIL score + unusual signal) | 5% | T2 → T3 escalation |
| F8: ORS reflex reasoning (real-time operational response) | 2% | T1 (must be fast) |
| F9: Architecture / critical decision | 1% | T3 (direct, no routing) |

### Cost Model: Untuned vs. Routed

**Untuned baseline (all tasks on T2):**
- Normalized cost = 100 tasks × 5× = 500 cost units

**Premium-only baseline (all tasks on T3):**
- Normalized cost = 100 tasks × 25× = 2,500 cost units

**Routed policy (this document):**
- T1 tasks: (35+20+12+2)% × 1× = 69 cost units
- T2 tasks: (10+8+7+5-escalation)% × 5× = ~25 tasks × 5 = 125 cost units
- T3 tasks: (1 + escalation)% × 25× = ~6 tasks × 25 = 150 cost units
- **Total: ~344 cost units**

**Savings vs. untuned T2 baseline:** ~31% reduction
**Savings vs. premium-only baseline:** ~86% reduction

**Token reduction target (≥20%):** Achieved comfortably.

---

## Architecture: Routing Decision Table

### Routing Logic

```
for each task:
  family = classify_task(task)
  tier = routing_table[family].default_tier
  result = invoke_model(tier, task)
  if validate(result, family) == FAIL:
    result = invoke_model(tier + 1, task)
    if validate(result, family) == FAIL:
      result = invoke_model(T3, task)  # final escalation
      ors.track_escalation()
  return result
```

### Task Family Routing Table

#### F1: Structured Parsing

**Definition:** Extract structured fields from raw tool output (DNS JSON, HTTP response metadata, subdomain list processing). Output format is fully defined. Correct output is deterministic.

| Attribute | Value |
|-----------|-------|
| Default tier | T1 |
| Escalation condition | JSON parse failure OR schema validation failure |
| Escalation target | T2 (once); if T2 fails, discard and log — not T3 |
| Confidence threshold | Not applicable — output is validated by schema, not confidence score |
| Max retries before escalation | 1 (T1 retry) |
| Token budget per call | Low: < 500 input tokens, < 200 output tokens |
| KRIL influence | None — parsing is input-independent |

**Routing decision:** T1. Never escalates to T3. If T2 fails, the raw input is malformed — log and quarantine, do not burn T3 credits on parsing failures.

#### F2: Alert Triage / Classification

**Definition:** Classify an ORS signal, DNS anomaly flag, or HTTP response into a predefined category (CRITICAL / WARNING / INFO / IGNORE). Small finite label set.

| Attribute | Value |
|-----------|-------|
| Default tier | T1 |
| Escalation condition | Confidence < 0.70 OR output not in allowed label set |
| Escalation target | T2 |
| Confidence threshold | ≥ 0.70 for T1 pass; ≥ 0.85 for T2 pass |
| Max retries before escalation | 0 (classify is single-shot; low confidence → escalate immediately) |
| Token budget per call | Low: < 300 input, < 50 output |
| KRIL influence | High-KRIL targets get T2 classification directly (skip T1) |

**KRIL routing gate for F2:** If target KRIL rank ≥ 90th percentile → route F2 directly to T2. Cost-per-insight improvement outweighs T1 savings on high-value targets.

#### F3: Status / Batch Reporting

**Definition:** Generate Mattermost status summaries, batch completion reports, operational dashboards. Template-driven; content is factual (counts, rates, durations).

| Attribute | Value |
|-----------|-------|
| Default tier | T1 |
| Escalation condition | Output fails template structure validation |
| Escalation target | T2 (template retry) |
| Confidence threshold | Not applicable — output validated by template schema |
| Token budget per call | Medium: < 1,000 input (batch metrics), < 500 output |
| KRIL influence | None |
| Frequency | Once per batch completion + once per hour for OPS channel |

#### F4: HTTP Response Pattern Analysis

**Definition:** Analyze HTTP response clusters for patterns — fingerprint similarity, unexpected status code distributions, WAF/CDN detection, redirect chain analysis.

| Attribute | Value |
|-----------|-------|
| Default tier | T2 |
| Escalation condition | Confidence < 0.65 OR contradictory pattern signals detected |
| Escalation target | T3 |
| Confidence threshold | ≥ 0.65 for T2 pass; T3 is final |
| Max retries before escalation | 1 (T2 retry with wider context window) |
| Token budget per call | Medium: < 2,000 input, < 500 output |
| KRIL influence | Only T2 invoked on targets with KRIL rank ≥ 50th percentile; below that → skip pattern analysis |

**KRIL gate for F4:** Suppresses pattern analysis on low-KRIL targets entirely. At scale, this eliminates 50% of F4 invocations.

#### F5: KRIL Target Ranking and Scoring

**Definition:** Score and rank subdomains by intelligence value based on DNS/HTTP/enrichment signals. Requires reasoning about relative value of findings.

| Attribute | Value |
|-----------|-------|
| Default tier | T2 |
| Escalation condition | Score distribution anomalous (all scores in narrow band — ranking failed) |
| Escalation target | T2 retry with different prompt strategy |
| Confidence threshold | Distribution check: scores must span at least 40-point range (0–100 scale) |
| Token budget per call | Medium: batch scoring preferred; < 3,000 input for batch of 50 targets |
| KRIL influence | Self-referential — this IS the KRIL scoring task |

**Batch scoring:** KRIL ranking must score in batches of 50 targets per call — single-target scoring is 50× more expensive per insight. Batch scoring is T2 only.

#### F6: Enrichment Finding Interpretation

**Definition:** Interpret nuclei/katana/ECE output — what does a specific finding mean? Is this a confirmed vulnerability, a false positive, or requires further investigation?

| Attribute | Value |
|-----------|-------|
| Default tier | T2 |
| Escalation condition | Confidence < 0.60 OR finding classified as novel/unknown class |
| Escalation target | T3 |
| Confidence threshold | ≥ 0.60 for T2 pass; T3 is final |
| Max retries before escalation | 0 (enrichment is high-value; escalate immediately on uncertainty) |
| Token budget per call | Medium-High: < 4,000 input (finding + context), < 1,000 output |
| KRIL influence | F6 only invoked for KRIL rank ≥ 70th percentile targets |

#### F7: Anomaly Investigation

**Definition:** Deep investigation of a high-signal anomaly — unusual DNS behavior, suspicious HTTP fingerprint, potential active threat indicator. Requires multi-step reasoning with adversarial awareness.

| Attribute | Value |
|-----------|-------|
| Default tier | T2 (primary) |
| Escalation condition | Confidence < 0.55 OR anomaly score from KRIL ≥ 0.80 |
| Escalation target | T3 (direct for anomaly_score ≥ 0.80; T2→T3 otherwise) |
| Confidence threshold | T2 pass: ≥ 0.55; anything below → T3 |
| Max retries before escalation | 0 for anomaly_score ≥ 0.80; 1 T2 retry otherwise |
| Token budget per call | High: < 8,000 input (full anomaly context), < 2,000 output |
| KRIL influence | Direct T3 routing for KRIL rank ≥ 95th percentile + anomaly_score ≥ 0.75 |
| ORS tracking | Each T3 invocation increments escalation counter |

#### F8: ORS Real-Time Reflex

**Definition:** Immediate operational response to ORS signal — generate action recommendation from predefined reflex table. Must complete in < 2 seconds.

| Attribute | Value |
|-----------|-------|
| Default tier | T1 |
| Escalation condition | NEVER escalate ORS reflex — latency constraint overrides quality |
| Escalation target | N/A |
| Confidence threshold | N/A — ORS reflex output is action selection from a closed set |
| Token budget per call | Very low: < 200 input, < 100 output |
| KRIL influence | None |
| Latency requirement | < 2 seconds end-to-end |

**Design note:** ORS reflex tasks must never wait for model escalation. If T1 fails to produce a valid action from the closed set, default to the predefined safe reflex (e.g., suspend lane) — do not escalate. This is a latency-critical path.

#### F9: Architecture / Critical Decision

**Definition:** Novel architectural recommendation, complex multi-constraint reasoning, or any task requiring integration of domain knowledge with system context. Rare.

| Attribute | Value |
|-----------|-------|
| Default tier | T3 (direct) |
| Escalation condition | N/A — T3 is the ceiling |
| Confidence threshold | Human review required regardless of confidence |
| Token budget per call | Uncapped within T3 context window |
| KRIL influence | None |
| Frequency | < 1% of task volume; occurs on-demand, not in-lane |

---

## Escalation Trigger Specification

### Quantified Escalation Gates

All escalation decisions must be measurable. No "subjective complexity" assessment.

| Trigger | Measurement | Threshold | Action |
|---------|------------|-----------|--------|
| Confidence score | Model-reported logprob or confidence field | < tier-specific threshold (see per-family) | Escalate to next tier |
| Output schema validation failure | JSON schema check or regex match on output | Fail | Escalate (1 retry at same tier first) |
| Output label not in allowed set | Enum membership check | Not in set | Escalate immediately |
| Anomaly score from KRIL | KRIL signal: anomaly_score field | ≥ 0.80 | Route F7 directly to T3 |
| Score distribution degenerate (F5) | Range of KRIL scores in batch | < 40-point range | Retry T2 with different prompt |
| Novel/unknown class (F6) | Classification output = "unknown" or "novel" | Any | Escalate to T3 |
| Token budget exceeded | Input token count before invocation | > family budget | Truncate or split; do not escalate for token count alone |
| Latency constraint (F8) | Time budget | T1 must complete < 2s | Never escalate; use predefined fallback |

### Escalation Rate Enforcement

The ORS arbitration subsystem tracks escalation rate in real time.

```
Escalation budget:
  premium_escalation_rate = T3_invocations / total_invocations
  target: <= 5% (0.05)

ORS monitor:
  signal: premium_escalation_rate
  warning: 0.04  (80% of budget consumed)
  critical: 0.05 (budget reached)
  reflex_warning: alert_mattermost
  reflex_critical: throttle_T3_invocations AND alert_mattermost AND log

Throttle mechanism:
  If escalation_rate >= 0.05:
    NEW T3 invocations are queued (not rejected)
    Queue drains at rate = (total_invocations × 0.05 - completed_T3) per hour
    Non-premium tasks continue without interruption
    Alert: weekly executive brief includes escalation rate and cost
```

**Budget accounting period:** Rolling 1-hour window. Spike tolerance: up to 8% for ≤ 10 minutes (covers burst anomaly events); sustained > 5% for > 10 minutes triggers throttle.

---

## KRIL Impact on Token Spend

KRIL selective mode is the highest-leverage token spend reduction mechanism. It gates which targets receive expensive analytical tasks.

### KRIL Gate Thresholds by Task Family

| Task Family | KRIL Threshold for Invocation |
|-------------|------------------------------|
| F1 (parsing) | All targets (no gate) |
| F2 (classification) | All targets; T2 direct if ≥ 90th percentile |
| F3 (reporting) | All targets (aggregate; not per-target) |
| F4 (HTTP pattern analysis) | ≥ 50th percentile only |
| F5 (KRIL ranking) | All targets (prerequisite task) |
| F6 (enrichment interpretation) | ≥ 70th percentile only |
| F7 (anomaly investigation) | ≥ 80th percentile only; T3 direct if ≥ 95th + anomaly ≥ 0.75 |
| F8 (ORS reflex) | All targets (operational, not per-target) |
| F9 (architecture) | N/A (on-demand) |

### Token Spend Reduction from KRIL Gating

At 10M subdomains with a KRIL score distribution:
- Top 50% (KRIL ≥ 50): ~5M targets → receive F4 analysis
- Top 30% (KRIL ≥ 70): ~3M targets → receive F6 enrichment interpretation
- Top 20% (KRIL ≥ 80): ~2M targets → receive F7 anomaly investigation

Without KRIL gating (all targets analyzed):
- F4: 10M targets × T2 cost = 50M cost units
- F6: 10M targets × T2 cost = 50M cost units
- F7: 10M targets × T2 cost = 50M cost units

With KRIL gating:
- F4: 5M targets × T2 = 25M cost units (50% reduction)
- F6: 3M targets × T2 = 15M cost units (70% reduction)
- F7: 2M targets × T2 = 10M cost units (80% reduction)

**KRIL gating alone reduces analytical task token spend by ~60-70%.**

### KRIL Selective Mode vs. Full Mode

KRIL selective mode (as described in WO-00004) restricts enrichment tooling to high-KRIL targets. This compounds with the model routing savings:
- Fewer enrichment outputs → fewer F6/F7 model invocations → direct token reduction
- KRIL selective mode is effectively a pre-filter that reduces the input volume to expensive model families

---

## Confidence Threshold Framework

### Threshold Table by Task Family

| Family | T1 Pass Threshold | T2 Pass Threshold | T3 Ceiling |
|--------|------------------|------------------|------------|
| F1 | Schema validates | Schema validates | Never |
| F2 | ≥ 0.70 | ≥ 0.85 | Never |
| F3 | Template validates | Template validates | Never |
| F4 | N/A (T2 default) | ≥ 0.65 | Pass |
| F5 | N/A (T2 default) | Distribution range ≥ 40pts | Retry T2 only |
| F6 | N/A (T2 default) | ≥ 0.60 | Pass |
| F7 | N/A (T2 default) | ≥ 0.55 | Pass |
| F8 | Closed set match | N/A | Never |
| F9 | N/A (T3 direct) | N/A | Human review |

### Confidence Score Requirements

**The model must emit a confidence score or the routing cannot escalate on confidence.** Either:
- Model produces a `"confidence": 0.0–1.0` field in structured output
- Model uses logprob-based confidence estimation at the controller level
- Controller uses a fast validator model (T1) to score T2/T3 output before accepting

**Recommendation:** Require structured output with `confidence` field for all F4–F9 tasks. F1–F3 use schema/template validation as the quality gate instead of confidence scores.

---

## 72-Hour Operation Plan

### Hour 0–2: Warm-up
- All tasks route to T1 by default
- Routing table loaded and ORS escalation counter initialized to 0
- KRIL scores loaded; threshold gates active
- Monitor: escalation rate expected 0% in first hour (parsing/classification tasks dominate)

### Hour 2–24: Full operational ramp
- All 5 lanes active; task volume at peak
- F4/F5/F6 tasks increasing as enrichment pipeline processes KRIL-selected targets
- Expected escalation rate: 2–4% (within budget)
- ORS monitor watching: escalation_rate, token_cost_per_hour, T1/T2/T3 task volume ratio

### Hour 24–48: Stable operation
- Escalation rate should stabilize
- Weekly (daily) executive brief generated via F3 (T1)
- Any anomaly investigations (F7) from first 24h processed by T2/T3
- Cost dashboard updated hourly to OPS channel

### Hour 48–72: Wind-down and reporting
- Enrichment pipeline completes on remaining KRIL-selected targets
- Final F5 KRIL re-rank across full corpus
- F9 (architecture review if needed): RUDRA orchestrator triggered on-demand
- Final executive brief: token spend breakdown, escalation rate, quality scores

---

## Tradeoffs

| Decision | Chosen | Rejected | Tradeoff |
|----------|--------|----------|----------|
| ORS reflex on T1 with predefined fallback | ✅ | ORS on T2 for quality | T2 for ORS adds 1–5s latency; reflex decisions must be < 2s; correctness matters less than speed for reflexes |
| KRIL gate at 50th percentile for F4 | ✅ | 25th or 75th percentile | 50th percentile balances coverage (most interesting targets) vs. cost (skip bottom half) |
| Escalation rate tracked rolling 1h | ✅ | Per-session tracking | Rolling 1h catches burst events without punishing sustained elevated load; per-session tracking is too coarse for 72h operation |
| F6 zero T2 retries before T3 escalation | ✅ | 1 retry before escalation | Enrichment findings are high-value; T2 uncertainty on enrichment means the finding may be novel → T3 is appropriate immediately |
| F9 routes direct to T3 | ✅ | F9 starts at T2 | Architecture decisions by T2 may produce plausible-but-wrong recommendations; the cost of a T3 call for F9 is acceptable given F9 volume is < 1% |
| KRIL score as task routing modifier | ✅ | Flat routing regardless of KRIL | KRIL provides the best available signal for which targets deserve expensive analysis; ignoring it means uniform spend regardless of target value |

---

## Risks

| ID | Title | Severity | Probability | Mitigation |
|----|-------|----------|-------------|------------|
| R1 | Model confidence field absent or miscalibrated | HIGH | MEDIUM | Require structured output with confidence field; add T1 validator model to score T2/T3 output |
| R2 | T3 escalation burst during anomaly cluster | HIGH | MEDIUM | Rolling 1h budget + spike tolerance window (8% for ≤ 10 min); queue overflow T3 tasks instead of rejecting |
| R3 | KRIL scores stale under rapid scan expansion | MEDIUM | MEDIUM | Re-rank KRIL in batch after each DNS/HTTP lane cycle; routing gates use latest available KRIL scores |
| R4 | T1 model quality degradation on edge cases | MEDIUM | LOW | Schema/template validation catches T1 failures; escalation to T2 provides recovery path |
| R5 | Cost model inaccurate (token volumes different from estimate) | MEDIUM | MEDIUM | Instrument actual T1/T2/T3 invocation counts from hour 1; adjust routing thresholds if cost exceeds projection |
| R6 | ORS reflex predefined fallback too conservative | LOW | LOW | Review fallback actions quarterly; most reflex actions are lane suspension which is safe-by-default |
| R7 | F5 batch scoring produces degenerate distribution | LOW | LOW | Distribution range check triggers T2 retry with different prompt; ORS alert on repeated distribution failures |

---

## Recommendations

| Priority | ID | Action |
|----------|-----|--------|
| 1 | REC-01 | Require structured JSON output with `confidence: float` field for all F4–F9 task families; fail task if field absent |
| 2 | REC-02 | Instrument real-time T1/T2/T3 invocation counter in ORS; add escalation_rate ORS monitor: WARNING 4%, CRITICAL 5% |
| 3 | REC-03 | Set KRIL gate thresholds per routing table before first high-load operation; verify KRIL scores are current |
| 4 | REC-04 | Implement F5 batch scoring (50 targets per T2 call) — single-target scoring is 50× more expensive per insight |
| 5 | REC-05 | Add token cost metric to weekly executive brief: T1/T2/T3 call counts, cost-per-lane, escalation rate |
| 6 | REC-06 | Run 1h dry-run with routing table active and escalation rate monitored before 72h operation begins |
| 7 | REC-07 | Review actual escalation rate at 24h mark; if > 4%, investigate which task family is over-escalating and tighten thresholds |
| 8 | REC-08 | Define routing_policy.json as a versioned config file consumed by controller; do not hardcode routing in application code |

---

## Implementation Approach

### routing_policy.json Schema

```json
{
  "version": "1.0.0",
  "model_tiers": {
    "T1": {"model_id": "<lightweight-model>", "cost_index": 1, "max_latency_ms": 2000},
    "T2": {"model_id": "<analytical-model>", "cost_index": 5, "max_latency_ms": 10000},
    "T3": {"model_id": "<premium-model>", "cost_index": 25, "max_latency_ms": 60000}
  },
  "escalation_budget": {
    "premium_rate_target": 0.05,
    "premium_rate_warning": 0.04,
    "spike_tolerance_rate": 0.08,
    "spike_tolerance_window_min": 10,
    "budget_window_hours": 1
  },
  "task_families": {
    "F1": {"default_tier": "T1", "escalation_target": "T2", "escalation_condition": "schema_fail", "max_retries_before_escalation": 1, "max_escalation_tier": "T2"},
    "F2": {"default_tier": "T1", "escalation_target": "T2", "confidence_threshold_T1": 0.70, "confidence_threshold_T2": 0.85, "kril_direct_T2_threshold": 90, "max_escalation_tier": "T2"},
    "F3": {"default_tier": "T1", "escalation_target": "T2", "escalation_condition": "template_fail", "max_escalation_tier": "T2"},
    "F4": {"default_tier": "T2", "escalation_target": "T3", "confidence_threshold_T2": 0.65, "kril_invoke_threshold": 50, "max_retries_before_escalation": 1},
    "F5": {"default_tier": "T2", "batch_size": 50, "escalation_condition": "score_range_lt_40", "escalation_action": "retry_T2_different_prompt"},
    "F6": {"default_tier": "T2", "escalation_target": "T3", "confidence_threshold_T2": 0.60, "escalation_on_unknown_class": true, "kril_invoke_threshold": 70, "max_retries_before_escalation": 0},
    "F7": {"default_tier": "T2", "escalation_target": "T3", "confidence_threshold_T2": 0.55, "anomaly_score_direct_T3": 0.80, "kril_invoke_threshold": 80, "kril_direct_T3_threshold": 95, "kril_direct_T3_anomaly_threshold": 0.75},
    "F8": {"default_tier": "T1", "max_latency_ms": 2000, "escalation_policy": "never", "fallback_action": "suspend_lane"},
    "F9": {"default_tier": "T3", "human_review_required": true}
  }
}
```

### Routing Controller Pseudocode

```python
def route_task(task, kril_score=None):
    family = classify_task_family(task)
    policy = routing_policy["task_families"][family]

    # KRIL gate check
    if "kril_invoke_threshold" in policy:
        if kril_score is None or kril_score < policy["kril_invoke_threshold"]:
            return None  # Task suppressed by KRIL gate; no model invocation

    # KRIL direct-to-T3 check
    if "kril_direct_T3_threshold" in policy:
        if (kril_score >= policy["kril_direct_T3_threshold"] and
            task.anomaly_score >= policy.get("kril_direct_T3_anomaly_threshold", 1.0)):
            return invoke_with_budget_check("T3", task)

    # Standard routing
    tier = policy["default_tier"]
    result = invoke_model(tier, task)

    if not validate(result, policy):
        if policy.get("escalation_policy") == "never":
            return policy["fallback_action"]
        max_tier = policy.get("max_escalation_tier", "T3")
        tier = escalate(tier, max_tier)
        result = invoke_with_budget_check(tier, task)

    return result

def invoke_with_budget_check(tier, task):
    if tier == "T3" and ors.escalation_rate() >= 0.05:
        ors.queue_T3_task(task)  # Queue, don't reject
        return None  # Handled async
    return invoke_model(tier, task)
```

---

## Validation Strategy

| Metric | Measurement | Pass Threshold | Frequency |
|--------|-------------|---------------|-----------|
| Premium escalation rate | T3 invocations / total invocations | ≤ 5% | Rolling 1h |
| Token cost vs. untuned baseline | Actual cost / projected untuned cost | ≤ 80% (≥ 20% reduction) | Per hour |
| Quality score P1/P2 outputs | Human spot-check or F9 evaluation of F6/F7 outputs | ≥ 0.90 | Per 24h |
| F2 classification accuracy | Validate against known labels from sample | ≥ 95% | Per 24h |
| F5 KRIL score distribution | Range check across batch | ≥ 40-point spread | Per batch |
| Routing table coverage | Task families with unclassified family → default T2 | < 1% unclassified | Per hour |
| ORS reflex latency | F8 end-to-end time | < 2000ms p99 | Continuous |

---

## KPIs

| KPI | Target | Measurement |
|-----|--------|-------------|
| Premium model usage rate | ≤ 5% of invocations | T3 call counter / total calls |
| Token cost reduction | ≥ 20% vs. untuned T2 baseline | Cost tracking per tier per hour |
| Quality score P1/P2 | ≥ 0.90 | Spot-check evaluation per 24h |
| ORS reflex latency | < 2s p99 | F8 task completion time |
| KRIL gating effectiveness | ≥ 50% reduction in F4/F6/F7 volume vs. no-gate | Invocation count per family |

---

## Assumptions

- **A1:** The model framework supports three tiers (lightweight, analytical, premium); specific model IDs are configurable via routing_policy.json
- **A2:** Models in F4–F9 can produce structured JSON output with a `confidence` field; if not natively available, a T1 validator model can score T2/T3 output
- **A3:** KRIL scores are available at task dispatch time (pre-computed, not real-time); routing gates consume the KRIL score attached to each task
- **A4:** ORS has an API surface for tracking escalation counters and emitting threshold alerts
- **A5:** Controller can classify tasks into the 9 defined task families by inspecting task type metadata (not content); family classification does not itself require an LLM call
- **A6:** "Limited autonomy" means human review is available for F9 outputs within the 72h window; the routing policy does not assume fully autonomous operation for architecture-class decisions
- **A7:** Token cost index (T1:T2:T3 = 1:5:25) is approximate; actual cost ratio should be validated against provider pricing and adjusted in routing_policy.json

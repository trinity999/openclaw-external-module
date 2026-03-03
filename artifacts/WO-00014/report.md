# WO-00014: Monthly Idea Re-Audit Framework — EKLAVYA/ATLAS Source Harvesting

**Work Order:** WO-00014
**Category:** research
**Analyst:** openclaw-field-processor
**Produced:** 2026-03-04
**Confidence:** 0.89

---

## Executive Summary

This document specifies a recurring monthly framework for harvesting and evaluating ideas from EKLAVYA, ATLAS, and related sources. The framework is designed for a system with **limited tolerance for integration churn** and **strict deterministic operations** — it must efficiently extract high-ROI future candidates while suppressing noise that wastes analyst attention and token budget.

The framework produces one structured monthly output per cycle meeting: ≥10 candidate insights, ≥3 high-confidence candidates with full impact hypotheses, and ≤20% low-value noise in the final shortlist.

**Core mechanism:** A two-stage filter (pre-filter → scored evaluation) with a five-dimension scoring model, integration staging windows, and explicit sunset criteria prevents shortlist bloat while maintaining traceability.

---

## 1. Context Understanding

### Operational Environment

The primary runtime (Pandavs) is in controlled production with ongoing high-volume recon operations. The external module serves as the asynchronous analysis bench — meaning ideas are not adopted in real-time but evaluated on a deliberate cycle that respects integration risk.

**Key tension:** External sources (EKLAVYA, ATLAS) will generate more ideas than the system can safely absorb. Without disciplined curation, two failure modes emerge:

1. **Over-adoption**: Idea churn destabilizes deterministic operations and introduces unplanned dependencies.
2. **Under-adoption**: Valuable improvements are never re-evaluated after initial deferral, and compound improvements are missed.

The framework resolves this tension by making re-evaluation systematic and evidence-gated, not intuition-driven.

### Source Characterization

From the Work Order context:
- **EKLAVYA**: Primary intelligence source — active insights and operational patterns relevant to the runtime
- **ATLAS**: Primary intelligence source — strategic or research-grade content for staged adoption consideration
- **Related sources**: Future registry entries; framework must accommodate additional feeds without structural change

Both sources are treated as **idea-producing inputs**, not authoritative instructions. Ideas are harvested, not executed.

---

## 2. Framework Architecture

The framework has five operational layers:

```
[Layer 1: Source Registry]      → tracks all input sources, versions, last-harvested date
[Layer 2: Harvest Protocol]     → cadence + mechanics for reading each source
[Layer 3: Pre-filter Gate]      → rejects structurally disqualifying ideas before scoring
[Layer 4: Scoring Engine]       → 5-dimension composite score (0–100) per candidate
[Layer 5: Staging + Reporting]  → integrates winners into Now/Near/Later/Backlog; monthly report
```

---

## 3. Source Registry

The source registry is a persistent JSON file (`artifacts/idea-registry/source_registry.json`) updated whenever a new source is added or audited.

### Registry Schema

```json
{
  "sources": [
    {
      "id": "SRC-001",
      "name": "EKLAVYA",
      "type": "primary",
      "last_harvested": "YYYY-MM-DD",
      "harvest_method": "manual_review | automated_pull",
      "focus_domain": "operational_patterns",
      "active": true
    },
    {
      "id": "SRC-002",
      "name": "ATLAS",
      "type": "primary",
      "last_harvested": "YYYY-MM-DD",
      "harvest_method": "manual_review",
      "focus_domain": "strategic_research",
      "active": true
    }
  ]
}
```

### Adding New Sources

New sources are appended with a unique `SRC-NNN` ID and `active: false` until the first harvest completes. This prevents untested sources from appearing in shortlist output without full evaluation.

---

## 4. Monthly Harvest Protocol

### Cadence

**Trigger:** First Tuesday of each month (or equivalent fixed calendar anchor).

**Duration target:** ≤14 days from harvest open to report delivery.

### Day-by-Day Schedule

| Days | Activity |
|------|----------|
| 1–3 | Harvest: scan all active sources; capture raw ideas with source attribution |
| 4–6 | Score: apply 5-dimension scoring to each harvested idea |
| 7 | Noise pass: reject ideas scoring <25; document rejection reason |
| 8–10 | Impact hypothesis drafting for all candidates scoring ≥50 |
| 11–12 | Staging decision: assign each surviving candidate to integration window |
| 13–14 | Report generation; commit to Notion Decision Register + Obsidian |

### Harvest Mechanics

For each active source:

1. **Review changes since last harvest** — new commits, new sections, updated patterns
2. **Capture raw idea entries** — freeform; include source ID, date, and raw description
3. **Assign provisional idea ID** — `IDEA-YYYYMM-NNN` (year-month + sequence)
4. **Do not evaluate during harvest** — capture only; evaluation is separate

Raw harvest log format:

```
IDEA-202503-001
Source: SRC-001 (EKLAVYA)
Harvested: 2025-03-01
Raw: [free-form description of the idea as encountered in source]
```

---

## 5. Pre-filter Gate (Stage 1)

The pre-filter gate applies before scoring. It prevents obviously disqualifying ideas from consuming evaluation bandwidth. An idea failing any pre-filter criterion is **immediately rejected** with a documented reason code.

### Pre-filter Criteria

| Code | Criterion | Rationale |
|------|-----------|-----------|
| PF-01 | Already implemented in current runtime | Duplicate capability; no marginal value |
| PF-02 | Directly contradicts deterministic/integrity constraints | Violates non-negotiable system properties |
| PF-03 | Requires external dependency with no documented fallback | Introduces single point of failure |
| PF-04 | No quantifiable ROI pathway | Budget discipline; no token spend on unanchorable ideas |
| PF-05 | Requires irreversible data mutation | Non-destructive principle violation |
| PF-06 | Active sunset status (3 consecutive cycles ≤25 score) | Protocol-closed; do not re-evaluate |

### Pre-filter Output

Rejected ideas are recorded in the monthly report under **Noise Registry** with their rejection code. This enables:
- Calibration of filter quality over time (if too many ideas hit PF-01, harvest is targeting wrong areas)
- Audit trail for why ideas were not advanced
- ≤20% noise target measurement (noise = ideas that enter scoring but score <25)

> **Target:** Pre-filter should eliminate ≥50% of raw harvested ideas before scoring. This keeps scorer bandwidth focused.

---

## 6. Scoring Engine (Stage 2)

All ideas that pass pre-filter are evaluated on five dimensions. Each dimension scores 0–3.

### Scoring Dimensions

| Dimension | ID | Score 0 | Score 1 | Score 2 | Score 3 |
|-----------|----|---------|---------|---------|---------|
| Strategic fit | D1 | No alignment with current ops | Weak alignment | Partial alignment | Direct fit with active workflow |
| Impact potential | D2 | No measurable ROI | Minor throughput/quality gain | Significant gain in one area | High ROI: throughput, cost, or coverage |
| Integration risk | D3 | High risk (complex deps, churn) | Moderate risk | Low risk with known path | Near-zero risk; additive only |
| Ops discipline alignment | D4 | Violates budget/determinism | Marginal concern | Compliant with minor caveats | Fully aligned: deterministic, budget-safe |
| Evidence quality | D5 | Theoretical only | Anecdotal or single source | Benchmark or limited test | Production data or replicated evidence |

### Composite Score

```
composite_score = round(((D1 + D2 + D3 + D4 + D5) / 15) × 100, 1)
```

### Score Thresholds

| Range | Classification | Action |
|-------|---------------|--------|
| 75–100 | High-confidence candidate | Immediately shortlisted; impact hypothesis required |
| 50–74 | Deferred candidate | 3-month re-evaluation scheduled |
| 25–49 | Low-priority idea | 6-month re-evaluation scheduled |
| 0–24 | Noise | Rejected; logged in noise registry |

### Noise Target Calculation

The ≤20% noise constraint applies to the post-pre-filter shortlist. If 20 ideas pass pre-filter and 4 score <25, noise rate = 20% — within target. Pre-filter quality is the primary lever for keeping noise low.

---

## 7. Impact Hypothesis Template

Every idea scoring ≥50 requires a written impact hypothesis. This is the integration decision artifact — a structured justification used when the idea transitions to an actual implementation ticket.

### Template

```
IMPACT HYPOTHESIS: [IDEA-ID]
---
Idea: [one-sentence description]
Source: [SRC-ID]

IF we integrate [specific capability or pattern from source],
THEN we expect [measurable outcome: throughput delta, cost delta, error rate change, coverage gain],
BECAUSE [evidence or reasoning: benchmark, observed behavior, logical derivation],
WITH integration cost of [effort estimate: days / sprint fraction],
AND reversibility: [HIGH | MEDIUM | LOW] (can we remove it cleanly if wrong?).

Confidence in hypothesis: [0.0–1.0]
Re-evaluation trigger: [condition that would upgrade or downgrade this hypothesis]
```

### Why Structured Hypothesis

Unstructured justifications ("this seems useful") produce adoption decisions that are hard to audit and hard to revoke. The hypothesis forces three disciplines:
1. **Specificity** — what exactly changes?
2. **Evidence** — what grounds the expectation?
3. **Reversibility** — how do we undo it if wrong?

Reversibility is especially critical in systems with limited tolerance for churn — ideas with LOW reversibility require higher evidence quality before advancing.

---

## 8. Integration Staging Windows

Candidates scoring ≥50 are assigned to an integration window based on composite score, reversibility, and ops readiness.

### Window Definitions

| Window | Label | Horizon | Criteria for assignment |
|--------|-------|---------|------------------------|
| W0 | Now | Current cycle | Score ≥75, reversibility HIGH, ops ready, impact hypothesis complete |
| W1 | Near-term | 1–3 months | Score ≥65, design path clear, effort estimate <1 sprint |
| W2 | Medium-term | 3–6 months | Score ≥50, requires design work before implementation |
| W3 | Long-term | 6–12 months | Score ≥50 but premature given current ops priorities |
| BL | Backlog | Unscheduled | Score ≥50 but blocked by external dependency or competing priority |
| SN | Sunset | Closed | 3 consecutive monthly cycles without score improvement above 25 |

### Window Promotion / Demotion

An idea advances to an earlier window when:
- New evidence raises composite score above the next window threshold
- A blocking dependency resolves
- Ops capacity opens

An idea demotes to a later window when:
- Implementation reveals higher integration risk than estimated (D3 reassessment)
- Priority shift in primary runtime operations
- Contradicting evidence emerges from a different source

---

## 9. Monthly Report Template

The monthly report is the primary deliverable consumed by Notion Decision Register and Obsidian research notes.

### Report Structure

```markdown
# IDEA HARVEST — [YYYY-MM]

## Harvest Summary
- Sources surveyed: [N]
- Raw ideas harvested: [N]
- Pre-filter rejections: [N] (codes: PF-XX frequency)
- Ideas entered scoring: [N]
- Noise rejections (score <25): [N] / noise rate: [N%] (target ≤20%)
- Shortlisted candidates: [N]

## High-Confidence Candidates (score ≥75)
[For each: IDEA-ID, score, source, one-line description, impact hypothesis summary, staging window]

## Deferred Candidates (score 50–74)
[For each: IDEA-ID, score, source, one-line description, re-eval date]

## Low-Priority Ideas (score 25–49)
[For each: IDEA-ID, score, source, one-line description, re-eval date]

## Noise Registry
[Pre-filter rejections + scored rejections with reason codes]

## Staging Map
[Table: Window → IDEA-IDs assigned]

## Sunset Decisions
[IDEA-IDs closed this cycle with 3rd consecutive low-score notation]

## Source Registry Status
[For each source: last harvested date, ideas harvested this cycle, source health notes]

## Framework Calibration Notes
[Noise rate trend, pre-filter hit rate, dimension score distributions]
```

---

## 10. Persistent Idea Ledger

Between monthly cycles, ideas are tracked in a persistent ledger (`artifacts/idea-registry/idea_ledger.json`). This prevents re-harvesting the same idea in future cycles and maintains scoring history.

### Ledger Entry Schema

```json
{
  "id": "IDEA-202503-001",
  "source": "SRC-001",
  "harvested_at": "2025-03-01",
  "raw_description": "...",
  "pre_filter_result": "PASSED | REJECTED",
  "pre_filter_code": null,
  "scores": {
    "D1_strategic_fit": 2,
    "D2_impact_potential": 3,
    "D3_integration_risk": 2,
    "D4_ops_discipline": 3,
    "D5_evidence_quality": 1,
    "composite": 73.3
  },
  "classification": "deferred",
  "staging_window": "W1",
  "impact_hypothesis": "...",
  "cycle_history": [
    {"cycle": "2025-03", "composite": 73.3, "window": "W1"},
    {"cycle": "2025-04", "composite": 78.0, "window": "W0"}
  ],
  "sunset_count": 0,
  "status": "active | sunset | adopted | rejected"
}
```

### Ledger Operations

- **New idea**: append entry, status = `active`
- **Re-evaluated idea**: append to `cycle_history`, update composite + window
- **Adopted idea**: status → `adopted`, record adoption date and implementation WO reference
- **Sunset**: after 3 consecutive cycles with composite <25, status → `sunset` (never re-evaluated)

---

## 11. Sunset Protocol

Ideas that cannot achieve a composite score above 25 across three consecutive monthly cycles are permanently closed. This prevents the backlog from accumulating stale ideas that consume review time indefinitely.

### Sunset Trigger

```
IF idea.sunset_count >= 3 AND composite < 25 in current cycle:
    → status = "sunset"
    → add to Sunset Decisions in monthly report
    → never re-evaluated unless explicitly overridden by operator
```

### Operator Override

A sunsetted idea may be re-opened only if:
1. The primary source (EKLAVYA/ATLAS) significantly revises the underlying concept
2. A new external dependency that blocked the idea resolves
3. Explicit operator override with documented rationale in Notion Decision Register

Override creates a new idea entry with `parent_id` referencing the sunsetted entry — the sunset record is never modified.

---

## 12. Framework Calibration Metrics

These metrics are tracked per cycle to detect framework drift:

| Metric | Target | Alert If |
|--------|--------|---------|
| Noise rate | ≤20% | >25% for 2 consecutive cycles |
| High-confidence candidates | ≥3/cycle | <2 for 2 consecutive cycles |
| Pre-filter hit rate | ≥50% of raw ideas | <30% (harvest targeting wrong areas) |
| Candidate shortlist size | ≥10 | <8 (insufficient source coverage) |
| Sunset rate | <10%/cycle | >20% (scoring model too harsh) |
| Hypothesis completeness | 100% of ≥50 ideas | <90% (execution gap) |

When alert conditions fire, the following actions apply:

| Alert | Action |
|-------|--------|
| Noise rate >25% | Review pre-filter criteria; tighten PF-04 (ROI pathway) threshold |
| High-confidence <2 | Expand source coverage; check if scoring is over-penalizing D5 |
| Pre-filter <30% hit rate | Harvest is targeting low-value areas; refocus review scope |
| Shortlist <8 | Add a new active source to registry |
| Sunset rate >20% | Review D2/D3 weights; system may be over-cautious on integration risk |

---

## 13. Risk Model

| ID | Risk | Severity | Probability | Mitigation |
|----|------|----------|-------------|------------|
| R1 | Idea churn: adoption rate exceeds ops stability threshold | HIGH | MEDIUM | W0 gate requires reversibility=HIGH + score ≥75; design review required before W0 promotion |
| R2 | Pre-filter over-tuned: good ideas rejected early | MEDIUM | MEDIUM | Track pre-filter hit rate; quarterly calibration review of PF criteria |
| R3 | Harvest misses high-value source updates | MEDIUM | LOW | Source registry tracks `last_harvested`; staleness alert if >35 days |
| R4 | Impact hypotheses written but never acted on | HIGH | MEDIUM | Notion Decision Register integration: W0 items auto-create implementation ticket prompt |
| R5 | Framework drift: scoring becomes inconsistent across cycles | MEDIUM | MEDIUM | Publish D1–D5 anchor examples in framework documentation; re-score sample each cycle |
| R6 | Token waste on low-quality sources added to registry | LOW | MEDIUM | New sources start `active: false`; require 1 trial harvest before activation |
| R7 | Ledger grows unbounded | LOW | LOW | Sunset entries archived annually; ledger query filtered to `active` by default |

---

## 14. Recommended Actions (Priority Order)

| Priority | ID | Action |
|----------|----|--------|
| 1 | REC-01 | Create `artifacts/idea-registry/source_registry.json` with EKLAVYA (SRC-001) and ATLAS (SRC-002) as initial active sources |
| 2 | REC-02 | Create `artifacts/idea-registry/idea_ledger.json` with empty `ideas: []` array — establishes persistent state before first harvest |
| 3 | REC-03 | Run first harvest immediately (D1–D3 of cadence) — establishes baseline shortlist and calibrates pre-filter against actual source content |
| 4 | REC-04 | Enforce impact hypothesis for every idea ≥50 before the W1/W0 gate — prevents "interesting but unspecified" ideas from entering ops backlog |
| 5 | REC-05 | Set Notion Decision Register template to accept monthly report staging map directly — prevents copy-paste translation errors |
| 6 | REC-06 | Review pre-filter hit rate after first 3 cycles — calibrate PF-04 (ROI pathway) based on actual rejection pattern |
| 7 | REC-07 | Add ORS-equivalent alert for `source_staleness_days > 35` — ensures no source is silently missed for more than one cycle |
| 8 | REC-08 | Quarterly framework review: inspect sunset rate, noise rate trend, D5 score distribution — identifies systematic scoring bias |

---

## 15. Assumptions

- A1: EKLAVYA and ATLAS produce at minimum 5–15 new or updated ideas per monthly cycle (sufficient to meet ≥10 shortlist target after pre-filter + scoring)
- A2: Pre-filter can eliminate ≥50% of raw harvested ideas using structural criteria before scoring begins
- A3: The scoring dimensions D1–D5 are anchored by a shared understanding of "strategic fit" relative to Pandavs runtime characteristics
- A4: Notion Decision Register and Obsidian are writable by the analyst at month-end (report delivery step)
- A5: Ideas adopted from W0 window have their implementation tracked via a separate WO or ticket system (outside this framework's scope)
- A6: Source content is accessible to the analyst within the harvest window (days 1–3); access issues are reported as framework alerts
- A7: The ledger schema is append-only; no historical scoring data is modified after a cycle closes

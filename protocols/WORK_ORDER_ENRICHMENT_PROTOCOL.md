# RUDRA WORK ORDER ENRICHMENT PROTOCOL (WOEP)

## Principle
External analysts should never need to guess system intent.

## Mandatory pre-delegation interrogation
1. What does analyst not know?
2. What assumptions are implicit?
3. What constraints are unstated?
4. What failure modes exist?
5. What scale characteristics matter?
6. Which prior decisions influence task?
7. What outputs are expected downstream?
8. What would a senior auditor ask first?

## Required sections in every work order
- REPOSITORY ACCESS NOTE (explicitly state analyst has GitHub access)
- SOURCE REFERENCE MAP (repo path + local mirror path + line ranges)
- SYSTEM OVERVIEW SNAPSHOT
- CURRENT STATE OF PRODUCT
- SCALE CHARACTERISTICS
- CONSTRAINTS
- KNOWN RISKS
- ANALYST QUESTIONS (with proactive answers)
- DESIGN PHILOSOPHY
- SUCCESS METRICS (quantified)
- OUTPUT CONSUMPTION PLAN
- FUTURE EXTENSION CONTEXT

## Source-reference rules (mandatory)
1. For each critical file, include `path + line ranges` (e.g., `ops/day1/persistence_gateway.py lines 53-105`).
2. Include both GitHub repo path and local mirror absolute path.
3. Reference only relevant ranges tied to objective; avoid broad whole-file references.
4. If lines change later, update work order references when status is still QUEUED.

## Validation gate
Work order invalid if any required section is missing, non-actionable, or lacks line-ranged source references.

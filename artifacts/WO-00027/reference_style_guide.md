# Reference Style Guide
## Pandavs Recon Framework — Field Processor Normative Standard
## Work Order: WO-00027

---

## Purpose

This guide defines the **normative** reference formats used in all Pandavs Recon Framework
work order artifacts. "Normative" means these formats are required, not optional.
Deviating from these formats causes reference ambiguity — the primary documentation failure mode.

---

## Rule 1: Repository References Must Be Commit-Pinned

**Always** include owner, repo, branch, and commit hash.

### Canonical format

```
<owner>/<repo> -> <branch> @ <commit_hash>
```

### Examples

```
trinity999/Pandavs-Framework -> adding-httpx-intelligence-engine @ cebd2d5
trinity999/openclaw-external-module -> main @ a1b2c3d
```

### DO NOT use (ambiguous):

```
Pandavs-Framework                        ← no owner, no commit
adding-httpx-intelligence-engine         ← branch only, drifts over time
github.com/trinity999/Pandavs-Framework  ← no commit pin, no branch
```

**Rationale**: Branch names move. Commit hashes are immutable.
A reference without a commit hash becomes unresolvable as the branch advances.

---

## Rule 2: File + Line References Must Include Path from Repo Root

**Always** include the full repo-relative path and an explicit line range.

### Canonical format

```
`<path/from/repo/root/file.ext>` lines <start>-<end>
```

### Examples

```
`ops/day1/persistence_gateway.py` lines 91-101
`ops/day1/PHASE_IMPLEMENTATION_PLAN.md` lines 142-160
`DATABASE_OPS.md` lines 32-50
`src/pandavs_recon_framework/database/neo4j_manager.py` lines 337-348
```

### DO NOT use (ambiguous):

```
persistence_gateway.py line 91          ← no repo path; ambiguous if multiple files exist
PHASE_IMPLEMENTATION_PLAN.md           ← no line numbers; reader must search entire file
neo4j_manager.py:337                    ← colon format inconsistent with other citations
```

**Rationale**: Line numbers without a commit anchor are meaningless (file changes).
The commit pin from Rule 1 anchors the line reference.
Always verify line numbers at the pinned commit before writing them in an artifact.

---

## Rule 3: GitHub Raw URLs Must Use Commit Hash (Not Branch Name)

When providing raw GitHub URLs for verification:

### Canonical format

```
https://raw.githubusercontent.com/<owner>/<repo>/<commit_hash>/<path/to/file>
```

### Example

```
https://raw.githubusercontent.com/trinity999/Pandavs-Framework/cebd2d5/ops/day1/persistence_gateway.py
```

### DO NOT use:

```
https://raw.githubusercontent.com/trinity999/Pandavs-Framework/main/ops/day1/persistence_gateway.py
```

**Rationale**: The branch-based URL returns different content after any commit to that branch.
The commit-hash URL is stable and deterministic.

---

## Rule 4: structured_output.json Must Include All 11 Canonical Fields

Every `structured_output.json` must contain these fields in this order:

```
1.  work_order        (string: "WO-XXXXX")
2.  category          (string: one of implementation/testing/performance/operations/documentation)
3.  priority          (string: one of critical/high/medium/low)
4.  analyst           (string: "openclaw-field-processor")
5.  produced_at       (string: ISO8601 UTC — "YYYY-MM-DDTHH:MM:SSZ")
6.  source_commit     (string: "owner/repo@commit_hash")
7.  confidence        (number: 0.0-1.0)
8.  key_findings      (array of strings — minimum 3)
9.  decisions         (array of objects: {id, decision, rationale})
10. risk_model        (array of objects: {id, risk, severity, mitigation})
11. artifacts         (array of strings — all artifact filenames)
```

Optional but strongly recommended:
```
12. cross_wo_dependencies  (object: {WO-XXXXX: "description"})
13. metrics                (object: {key: value})
```

**NEVER use**: `findings` (always `key_findings`). Field name inconsistency is a compliance failure.

---

## Rule 5: Commit Messages Must Follow Canonical Formats

Two commit types are defined:

### Status-update commit (during WO processing)

```
status-update: WO-XXXXX <FROM_STATUS> → <TO_STATUS> (<short description, ≤60 chars>)
```

Examples:
```
status-update: WO-00029 QUEUED → IN_PROGRESS (Neo4j sync minimal subset)
status-update: WO-00027 QUEUED → IN_PROGRESS (operator handoff template)
status-update: WO-00029 BLOCKED — validators import failure (partial artifacts)
```

### Analysis-pass commit (completion, with all artifacts)

```
analysis-pass: WO-XXXXX STATUS=COMPLETED — <artifact summary> (<key choices, ≤80 chars>)
```

Examples:
```
analysis-pass: WO-00029 STATUS=COMPLETED — Neo4j sync minimal subset (dns_resolution, MERGE patterns)
analysis-pass: WO-00028 STATUS=COMPLETED — ClickHouse sink worker (ReplacingMergeTree, BEGIN IMMEDIATE)
```

### DO NOT use (non-standard):

```
WO-00029 done                                 ← no status prefix
Completed analysis of Neo4j sync              ← no WO number
fix: update status                            ← generic commit message
```

---

## Rule 6: Artifact Files Must Use snake_case Naming

### Canonical naming

```
report.md
structured_output.json
<descriptive_topic_name>.md
<descriptive_topic_name>.csv
<descriptive_topic_name>.yaml
<descriptive_topic_name>.json
```

### DO NOT use:

```
Report.md             ← PascalCase
reportFile.md         ← camelCase
report-file.md        ← kebab-case (allowed in some projects but not here)
WO-00027-report.md    ← WO number prefix (WO number belongs in the directory, not filename)
```

**Rationale**: All files in `artifacts/WO-XXXXX/` are already namespaced by the directory.
Embedding the WO number in filenames adds redundant noise.

---

## Rule 7: Line Number Claims Must Be Verified at the Pinned Commit

Before writing `file.ext lines A-B` in any artifact:

1. Fetch the file at the pinned commit (not HEAD)
2. Read lines A-B
3. Confirm the content matches what you are citing
4. If line numbers have shifted: update to the correct range and note the discrepancy

### Verification method (bash)

```bash
# Fetch at pinned commit
curl -sL "https://raw.githubusercontent.com/trinity999/Pandavs-Framework/cebd2d5/ops/day1/persistence_gateway.py" \
    -o /tmp/pg_verify.py

# Print lines 91-101 to confirm
python3 -c "
with open('/tmp/pg_verify.py') as f:
    lines = f.readlines()
for i, line in enumerate(lines[90:101], start=91):
    print(f'{i}: {line}', end='')
"
```

---

## Rule 8: Environment Assumptions Must Be Declared in Reports

Any artifact that depends on environment-specific paths, binaries, or credentials must
include a **## Environment Assumptions** section listing:

- OS / runtime (Windows, WSL, OpenClaw Linux, Docker)
- Required binaries (e.g., `neo4j` Python package, `clickhouse-client`, `dnsx`)
- Path assumptions (e.g., `ops/day1/state/scan_persistence.db` relative to project root)
- Known failure modes for this environment (from DATABASE_OPS.md §Primary recurring issues)

### Minimal example

```markdown
## Environment Assumptions
- Runtime: WSL Ubuntu-22.04 + Windows PowerShell (dual environment)
- Python: 3.10+; packages: `neo4j`, `sqlite3` (stdlib)
- NOT required: `validators` (intentionally excluded — import failure risk)
- DB path: `ops/day1/state/scan_persistence.db` relative to project root
- Encoding: always run with `PYTHONIOENCODING=utf-8` on Windows terminals
```

---

## Rule 9: confidence Score Guidance

The `confidence` field in `structured_output.json` reflects source verification quality.

| Score Range | Meaning | When to use |
|-------------|---------|-------------|
| 0.95-0.97 | High — source directly verified | All referenced source files fetched and line numbers confirmed |
| 0.90-0.94 | Medium-high — mostly verified | Source read but ≥1 line range unconfirmed due to access limitation |
| 0.80-0.89 | Medium — significant inference | GitHub repo inaccessible; worked from cached files or prior session context |
| < 0.80 | Low — substantial inference | Use only with explicit "confidence_note" field explaining gaps |

**Never use 1.0** — no artifact is perfectly verifiable.

---

## Rule 10: Cross-WO Dependencies Must Be Explicit

If an artifact references work produced in another WO (tables, functions, policies, schemas),
include `cross_wo_dependencies` in `structured_output.json` AND a cross-reference in `report.md`.

### Format

```json
"cross_wo_dependencies": {
  "WO-00023": "sink_outbox schema — retry taxonomy (RETRYABLE/NON_RETRYABLE/ALREADY_SYNCED)",
  "WO-00026": "adaptive_controller.py parallel_setting.txt — affects scanner throughput during replay"
}
```

**Omitting this field** when dependencies exist is a compliance failure.
Downstream operators need to know which WOs must be completed before this one can be deployed.

---

## Compliance Checklist (self-check before commit)

```
[ ] Commit message uses canonical format (Rule 5)
[ ] All source refs include commit hash + line range (Rules 1, 2)
[ ] structured_output.json has all 11 canonical fields (Rule 4)
[ ] "key_findings" (not "findings") — field name correct (Rule 4)
[ ] Artifact files are snake_case.ext (Rule 6)
[ ] cross_wo_dependencies present if any WO referenced (Rule 10)
[ ] confidence score reflects actual source verification level (Rule 9)
[ ] Environment assumptions documented if runtime-specific (Rule 8)
```

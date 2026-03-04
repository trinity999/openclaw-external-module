# Pandavs Recon Framework — Operator Handoff Template
## RUDRA WORKBENCH Field Processor Onboarding

---

## SECTION 0: Pre-Flight Checklist (complete before first work order)

Run these 4 checks. Any failure → fix before starting WOs.

```bash
# CHECK 1: Python imports (validators causes neo4j_manager.py crash)
python3 -c "import validators; print('validators OK')" 2>&1 || echo "MISSING: pip install validators (or avoid importing neo4j_manager.py)"

# CHECK 2: Database connectivity
python3 - <<'EOF'
import sqlite3, sys
try:
    c = sqlite3.connect("ops/day1/state/scan_persistence.db")
    r = c.execute("SELECT COUNT(*) FROM events").fetchone()
    print(f"SQLite OK — {r[0]} events")
except Exception as e:
    print(f"SQLite FAIL: {e}")
EOF

# CHECK 3: Terminal encoding (Windows cp1252 crashes on Unicode)
python3 -c "
import sys, io
sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8', errors='replace')
print('UTF-8 encoding OK')
"
# If this fails, set: $env:PYTHONIOENCODING="utf-8" (PowerShell) or PYTHONIOENCODING=utf-8 (bash)

# CHECK 4: Working directory
pwd  # Should resolve to the project root (contains ops/, src/, DATABASE_OPS.md)
ls ops/day1/state/scan_persistence.db 2>/dev/null && echo "DB path OK" || echo "DB path mismatch — confirm cwd"
```

---

## SECTION 1: Repository Reference Card

| Property | Value |
|----------|-------|
| **Primary repo** | `trinity999/Pandavs-Framework` |
| **Active branch** | `adding-httpx-intelligence-engine` |
| **Pinned commit** | `cebd2d5` |
| **Companion repo** | `trinity999/openclaw-external-module` |
| **Companion branch** | `main` |
| **SQLite DB** | `ops/day1/state/scan_persistence.db` |
| **Results dir** | `ops/day1/results/` |
| **Work orders dir** | `work_orders/` (companion repo) |
| **Artifacts dir** | `artifacts/WO-XXXXX/` (companion repo) |

### Database connection details

| DB | Host | Port | User | Database |
|----|------|------|------|----------|
| ClickHouse (WSL) | `127.0.0.1` | `9000` | `default` | `pandavs_recon` |
| Neo4j (Docker) | `bolt://localhost` | `7687` | `neo4j` | `reconnaissance` |

> See `DATABASE_OPS.md` for full start/stop/verify procedures.

---

## SECTION 2: Work Order Lifecycle

```
QUEUED → IN_PROGRESS → COMPLETED
```

### Commit protocol

```bash
# On status change: QUEUED → IN_PROGRESS
git commit -m "status-update: WO-XXXXX QUEUED → IN_PROGRESS (short description)"

# On completion (after all artifacts written)
git commit -m "analysis-pass: WO-XXXXX STATUS=COMPLETED — artifact summary"
```

### Always commit in this order:
1. Stage `work_orders/WO-XXXXX.md` status change
2. Stage all `artifacts/WO-XXXXX/` files
3. Single commit with the `analysis-pass:` message above

### Artifact folder confinement rule

> **Only write files inside `artifacts/WO-XXXXX/`.** Never modify files outside this directory
> unless explicitly updating `work_orders/WO-XXXXX.md` STATUS or `registry/work_order_registry.json`.

---

## SECTION 3: Mandatory Artifact Checklist

Every WO must produce all artifacts listed in its `## EXPECTED ARTIFACTS` section.
The four most common artifact types:

| File | Required fields |
|------|----------------|
| `report.md` | Context, findings, key decisions, cross-WO deps |
| `structured_output.json` | All 11 canonical fields (see §4) |
| `[topic_name].md` | Operational document (pseudocode, runbook, template, spec) |
| `[topic_name].csv` / `.yaml` / `.json` | Structured data artifact |

---

## SECTION 4: structured_output.json Canonical Template

Copy this template for every new WO. Replace ALL `<...>` placeholders.

```json
{
  "work_order": "WO-XXXXX",
  "category": "<implementation|testing|performance|operations|documentation>",
  "priority": "<critical|high|medium|low>",
  "analyst": "openclaw-field-processor",
  "produced_at": "<YYYY-MM-DDTHH:MM:SSZ>",
  "source_commit": "<owner/repo@commit_hash>",
  "confidence": <0.80-0.97>,

  "key_findings": [
    "<finding 1 — specific, quantified where possible>",
    "<finding 2>",
    "<finding 3>"
  ],

  "decisions": [
    {
      "id": "D1",
      "decision": "<what was decided>",
      "rationale": "<why this option over alternatives>"
    }
  ],

  "risk_model": [
    {
      "id": "R1",
      "risk": "<what could go wrong>",
      "severity": "<HIGH|MEDIUM|LOW>",
      "mitigation": "<concrete countermeasure>"
    }
  ],

  "cross_wo_dependencies": {
    "WO-XXXXX": "<what this WO depends on from that WO>"
  },

  "metrics": {
    "<metric_name>": <value>
  },

  "artifacts": [
    "report.md",
    "structured_output.json",
    "<other_artifact_1.md>",
    "<other_artifact_2.ext>"
  ]
}
```

**Confidence guidance**:
- `0.95-0.97`: Source code directly confirmed via file read; all assumptions verified
- `0.90-0.94`: Source read but partial; one assumption unconfirmed
- `0.80-0.89`: Significant inference; source unavailable (e.g., private repo access failed)

---

## SECTION 5: Source Reference Format

See `reference_style_guide.md` for full rules.

**Quick reference** (use these formats; no other formats accepted):

```
# Repository reference (in WO headers):
trinity999/Pandavs-Framework -> adding-httpx-intelligence-engine @ cebd2d5

# File + line range reference (in report.md prose):
`ops/day1/persistence_gateway.py` lines 91-101

# GitHub raw URL (for verification):
https://raw.githubusercontent.com/trinity999/Pandavs-Framework/cebd2d5/ops/day1/persistence_gateway.py

# Canonical source commit field (in structured_output.json):
"source_commit": "trinity999/Pandavs-Framework@cebd2d5"
```

---

## SECTION 6: Recurring Environment Issues — Fast Fix Reference

| Issue | Symptom | Fix |
|-------|---------|-----|
| `validators` missing | `ModuleNotFoundError: validators` on any script that imports neo4j_manager.py | `pip install validators` OR avoid importing neo4j_manager.py; use neo4j driver directly |
| cp1252 encoding | `UnicodeEncodeError: 'charmap' codec can't encode` on any file with Unicode chars (→, ✗, etc.) | `$env:PYTHONIOENCODING="utf-8"` in PowerShell; or wrap stdout in `io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8', errors='replace')` |
| pandavs-hybrid-architecture path missing | `check_db_health.py` ClickHouse section fails with FileNotFoundError | Run health check with `PYTHONIOENCODING=utf-8`; the CH health check failure is cosmetic if CH is actually running |
| Tool not in PATH | `dnsx: command not found` etc. | Add `~/go/bin` to PATH; verify with `which dnsx` |
| SQLite path mismatch | `OperationalError: no such table` | Confirm cwd is the project root; path is relative `ops/day1/state/scan_persistence.db` |
| Neo4j container restart loop | `docker logs pandavs-neo4j-fixed` shows stale PID file | `docker rm -f pandavs-neo4j-fixed` then recreate with `--env-file .neo4j_docker.env` |

---

## SECTION 7: WO Priority Order (RUDRA WORKBENCH)

Process work orders in this priority order:
1. `CRITICAL` priority, `STATUS: PENDING` or `STATUS: IN_PROGRESS`
2. `HIGH` priority, `STATUS: PENDING`
3. `HIGH` priority, `STATUS: IN_PROGRESS` (resume incomplete)
4. `MEDIUM` priority, `STATUS: PENDING`
5. `LOW` priority, `STATUS: PENDING`

**Never** reprocess a WO with `STATUS: COMPLETED`.

---

## SECTION 8: Escalation Format

When a WO cannot be completed (missing source, blocked dependency, ambiguous requirement):

```markdown
## BLOCKED: WO-XXXXX

**Blocked by**: <specific reason — missing source file / dependency WO not complete / etc.>
**Attempted**: <what was tried>
**Needs**: <exactly what is needed to unblock>
**Workaround**: <what partial output was produced despite the block>
```

Commit with message:
```
status-update: WO-XXXXX BLOCKED — <reason> (partial artifacts at artifacts/WO-XXXXX/)
```

---

## Quick-Start: First Work Order in 20 Minutes

```
Minute 0-3:   Complete Section 0 pre-flight checklist
Minute 3-5:   git pull --rebase; scan work_orders/ for QUEUED/IN_PROGRESS
Minute 5-7:   Read selected WO; note EXPECTED ARTIFACTS and SOURCE REFERENCE MAP
Minute 7-10:  Fetch source files (GitHub raw or local /tmp cache); read relevant lines
Minute 10-15: Write artifacts to artifacts/WO-XXXXX/
Minute 15-17: Update work_orders/WO-XXXXX.md STATUS → COMPLETED
Minute 17-20: git add + git commit with canonical message; git push
```

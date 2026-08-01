# Debate v3: Hermes Model Registry + Dynamic Reviewer Selection Implementation Plan

> **For Hermes:** Use subagent-driven-development to implement this plan task-by-task.

**Goal:** Turn cc-debate's Hermes plugin into a self-tuning review engine that picks the best
mix of reviewer models — by diversity, completeness, effort, budget and sandbox/harness —
from a data-refreshed model registry, dispatched through **acpx** (the unified transport).

**Architecture:** The Hermes side is an **orchestration plugin** (stage → dispatch → synthesize
→ debate → verdict). Model access is **transport-agnostic**: acpx, opencode, and Hermes all
reach the same providers (OpenRouter, Nous, DeepSeek, Z.AI, OpenAI…). **acpx is the transport**
for every diverse reviewer — one CLI, any provider/model from the registry; a `subagent`
backend is the cheap same-model default. A **platform-adaptive sandbox wrapper**
(bwrap/sandbox-exec/Docker) gives `repo-aware` seats real OS isolation. **`codex-exec` is
eliminated**: repo-reading is a generic acpx property (cwd=repo) and Codex **subscription
credits** are available to the plain acpx `codex` agent via OAuth (`CODEX_HOME/auth.json`; use
the CLI route, not native-ACP — openclaw/acpx#91560).

**Tech Stack:** Python 3 stdlib (json, subprocess, urllib), jq, acpx (existing),
bwrap/sandbox-exec (host), `hermes` subagents, existing debate scripts + tests.

**Acceptance criteria:**
- Registry schema has `model + price(cost_per_task) + strengths + effort + harness + repo-aware` on every entry and lints clean.
- `refresh-models.py` pulls current-gen models/effort/cost from **Artificial Analysis** (primary) + **LMArena** (complement); offline fallback; latest-first.
- `select-panel.py` returns a panel per the heuristic and passes unit tests (diversity, effort floor, budget, harness feasibility, low-diversity warning).
- `run-acpx-review` dispatches a reviewer to any provider/model via acpx (codex OAuth route fixed); sandbox wrapper picks bwrap→sandbox-exec→Docker by host and isolates a `repo-aware` seat.
- `codex-exec` seat removed from config/presets; README documents the removal + credit routing.
- `debate` plugin SKILL.md documents registry + selection + harness + sandbox; `code-review` still wraps it.

---

## Task 1: Registry schema + seed data
**Objective:** Ship `hermes/templates/debate-models.json` with the full schema.
**Files:** Create `hermes/templates/debate-models.json`; Test `tests/test-registry-schema.py`.
**Step 1 (test):** every entry has `name, harness, provider, model_id, family, lab, strengths,
effort, effort_range, price{in,out,cost_per_task}, cost, repo_aware, available`; `lab`/`model_id`
unique; `effort`∈`effort_range`; `cost`∈{cheap,mid,premium}; `harness`∈{acpx,subagent}.
**Step 2 (code):** seed current-gen models (GPT-5.6 Luna/Terra/Sol, GLM-5.2, Claude Opus 5,
Gemini 3.1 Pro, DeepSeek V4 Pro) with AA-sourced price/cost_per_task/effort; `repo_aware`
true where cwd=repo reads make sense.
**Step 3:** `python3 tests/test-registry-schema.py` → PASS. **Commit** `feat: add debate model registry schema + seed`.

## Task 2: Selector module
**Objective:** Deterministic `select-panel.py` per the heuristic.
**Files:** Create `scripts/select-panel.py`; Test `tests/test-select-panel.py`.
**Step 1 (test):** (a) distinct labs per seat when possible, (b) strongest-reasoning model on the
deepest seat at `effort>=xhigh`, (c) cheap seats minimize total `cost_per_task`, (d) unusable
harness dropped, (e) N>labs → low-diversity warning.
**Step 2 (code):** read registry, apply harness-feasibility filter, greedily assign lab-diverse
seats with effort floor + cost-per-task budget.
**Step 3:** `python3 tests/test-select-panel.py` → PASS. **Commit** `feat: add dynamic panel selector`.

## Task 3: Datasource refresh
**Objective:** `refresh-models.py` repopulates metrics from AA (+ LMArena).
**Files:** Create `scripts/refresh-models.py`; Test `tests/test-refresh-models.py`.
**Step 1 (test):** mocked AA response → updates strengths/cost_per_task/effort for known ids,
adds new current-gen ids, preserves `harness`/`repo_aware`/`available`, and leaves the file
valid on network failure (offline keeps last good copy).
**Step 2 (code):** fetch AA leaderboard (HF Space/API), map to schema, merge into
`$HERMES_HOME/debate-models.json`; LMArena Elo as secondary confidence. `available` false
unless harness installed.
**Step 3:** `python3 tests/test-refresh-models.py` → PASS. **Commit** `feat: add registry refresh from AA+LMArena`.

## Task 4: acpx transport + sandbox wrapper (removes codex-exec)
**Objective:** One acpx dispatch path (any provider/model) + platform sandbox; delete `codex-exec`.
**Files:** Create `scripts/run-acpx-review.sh` + `scripts/sandbox.py`; Modify `debate-acpx.sample.json`; Test `tests/test-acpx-runner.sh` + `tests/test-sandbox.sh`.
**Step 1 (test):** `run-acpx-review.sh` with MODEL/PROVIDER/PLAN/OUT writes a `VERDICT:` file;
codex path authenticates via OAuth (CODEX_HOME) on the **CLI route** (native-ACP OAuth is
broken — openclaw/acpx#91560); assert no `codex-exec` key remains in the sample config.
**Step 2 (code):** `sandbox.py` selects bwrap (Linux) → sandbox-exec (macOS) → Docker (fallback),
mounts repo read-only for `repo_aware` seats, isolates HOME, wires the cred. `run-acpx-review.sh`
invokes acpx inside it; plan always via file path.
**Step 3:** smoke: sandboxed acpx run against a repo fixture reads a repo file, denied a `$HOME`
read; `codex-exec` gone from sample. **Commit** `feat: acpx transport + platform sandbox; remove codex-exec`.

## Task 5: Plugin SKILL.md integration
**Objective:** Wire registry → selector → acpx transport into `hermes/SKILL.md`.
**Files:** Modify `hermes/SKILL.md`, `hermes/README.md`.
**Step 1:** doc Step 1.5 "route panel": load registry, run `select-panel.py`, get
seat→(model,harness,effort,repo_aware).
**Step 2:** doc Step 2 dispatch each seat via acpx (or `subagent` default), each writing a review file.
**Step 3:** doc effort pinning, budget, low-diversity warning, sandbox/repo-aware, codex-credit note.
Update README with registry/datasource/sandbox sections. **Commit** `docs: integrate registry+selection+transport into debate plugin`.

## Task 6: End-to-end verification + docs
**Objective:** One command proves the pipeline; docs finalized.
**Files:** Modify `README.md`; add `tests/test-e2e.sh`.
**Step 1:** `test-e2e.sh` — refresh (mock) → select → dispatch (mock sandbox/acpx) → synthesize → assert VERDICT + per-seat rounds.
**Step 2:** run full suite green on macOS + Linux.
**Step 3:** README: "Model registry & dynamic selection" (AA primary, LMArena complement), schema, sandbox table, "add a model/harness", "codex-exec removed, credits via acpx OAuth".
**Commit** `test: end-to-end and docs for debate v3`.

---

## Out of scope (deferred)
- Auto-installing harnesses/API keys. Registry marks `available:false`; user opts in.
- Persisting selection outcomes to tune the heuristic (a later data pass).
- Any core Hermes `/`-command change (stays a plugin).

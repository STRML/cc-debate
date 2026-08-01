# Debate v3: Hermes Model Registry + Dynamic Selection Implementation Plan

> **For Hermes:** Use subagent-driven-development to implement this plan task-by-task.

**Goal:** Turn cc-debate's Hermes port (`hermes/`) into a self-tuning review engine that picks the best mix of reviewer models — by diversity, completeness, effort and budget — from a data-refreshed model registry, running each behind its best harness.

**Architecture:** Add a versioned model registry (`debate-models.json`) describing every candidate reviewer (model, price, strengths, effort, harness). Add a datasource-refresh script that repopulates it from Artificial Analysis (primary) + LMArena (complement). Add a deterministic **model-selector** module implementing the diversity×completeness×effort×budget×harness heuristic. Extend the `debate` SKILL.md workflow to run the selector pre-panel and dispatch each seat via its `harness` backend (new `hermes` one-shot runner, plus existing subagent/codex/claude/gemini/opencode). Pure doc/config + Python skill tooling — no core Hermes changes.

**Tech Stack:** Python 3 (stdlib: json, subprocess, urllib; no hard deps), jq (existing), the Hermes `-z -m --provider` one-shot path, gh/curl for datasource fetch, existing debate scripts + tests.

**Acceptance criteria:**
- Registry schema has `model + price + strengths + effort + harness` on every entry and lints clean.
- `refresh-models.py` (a) pulls current-gen models+effort+cost from AA via its HF Space API, (b) falls back gracefully offline, (c) marks `available` only for installed harnesses.
- `select-panel.py` returns a panel per the heuristic and passes unit tests (diversity, effort floor, budget, harness feasibility, low-diversity warning).
- `run-hermes-review.sh` invokes a pinned-model one-shot Hermes reviewer and writes a review file; proved with a live run.
- `debate` SKILL.md documents registry + selection + harness; `code-review` still wraps it.

---

## Task 1: Registry schema + seed data
**Objective:** Define and ship `hermes/templates/debate-models.json` with the full schema.
**Files:**
- Create: `hermes/templates/debate-models.json`
- Test: `tests/test-registry-schema.py`

**Step 1 (test):** assert every entry has `name, harness, provider, model_id, family, lab, strengths, effort, effort_range, price{in,out,cost_per_task}, cost, available`; `lab` and `model_id` unique; `effort` in `effort_range`; `cost` ∈ {cheap,mid,premium}; `harness` ∈ {hermes,subagent,codex,claude,gemini,opencode}.
**Step 2 (code):** ship the seed template keyed by real current-gen models (GPT-5.6 Luna/Terra/Sol, GLM-5.2, Claude Opus 5, Gemini 3.1 Pro, DeepSeek V4 Pro) with AA-sourced price/cost_per_task/effort.
**Step 3:** run the lint: `python3 tests/test-registry-schema.py` → PASS. **Commit** `feat: add debate model registry schema + seed`.

## Task 2: Selector module
**Objective:** Deterministic `select-panel.py` implementing the heuristic.
**Files:**
- Create: `scripts/select-panel.py`
- Test: `tests/test-select-panel.py`

**Step 1 (test):** given a fixture registry, assert (a) distinct labs per seat when possible, (b) the strongest-reasoning model lands on the deepest seat at `effort>=xhigh`, (c) cheap seats minimize total `cost_per_task`, (d) unusable harnesses are dropped, (e) N>labs triggers the low-diversity warning.
**Step 2 (code):** read registry JSON, apply harness-feasibility filter (from a `--installed-harnesses` arg), then greedy lab-diverse assignment with effort floor and cost-per-task budget.
**Step 3:** `python3 tests/test-select-panel.py` → PASS. **Commit** `feat: add dynamic panel selector`.

## Task 3: Datasource refresh
**Objective:** `refresh-models.py` repopulates metrics from AA (+ LMArena), latest-first.
**Files:**
- Create: `scripts/refresh-models.py`
- Test: `tests/test-refresh-models.py`

**Step 1 (test):** with a mocked AA HTTP response, assert it updates `strengths/cost_per_task/effort` for known ids, adds new current-gen ids, preserves `harness`+`available`, and leaves the file valid when the network fails (offline fallback keeps last good copy).
**Step 2 (code):** fetch AA leaderboard (HF Space data / API), map to schema, merge into `$HERMES_HOME/debate-models.json`; LMArena Elo as secondary confidence signal. `available` stays false unless a harness is reported installed.
**Step 3:** `python3 tests/test-refresh-models.py` → PASS. **Commit** `feat: add model registry refresh from AA+LMArena`.

## Task 4: hermes one-shot harness runner
**Objective:** `run-hermes-review.sh` runs a pinned-model reviewer via `hermes -z -m -p`, writes a review file.
**Files:**
- Create: `scripts/run-hermes-review.sh`
- Test: `tests/test-hermes-runner.sh` (smoke)

**Step 1 (test):** smoke — with `MODEL_ID`/`PROVIDER`/`PLAN_PATH`/`OUT` set, expect a review file containing `VERDICT:`.
**Step 2 (code):** `hermes -z "Read $PLAN_PATH; review as <persona>; return VERDICT" -m $MODEL_ID --provider $PROVIDER -Q > $OUT`; guard: plan passed via file path, never inlined; bail with message if `hermes` missing.
**Step 3:** live run against a dummy plan with a real pinned model → file written. **Commit** `feat: add hermes one-shot reviewer harness`.

## Task 5: SKILL.md integration
**Objective:** Wire registry → selector → harness into `hermes/SKILL.md` workflow.
**Files:**
- Modify: `hermes/SKILL.md` (Workflow steps 1-2, Dynamic model selection)
- Modify: `hermes/README.md`

**Step 1:** doc: Step 1.5 "route panel" — load `debate-models.json`, run `select-panel.py --installed-harnesses <..> --seats <personas>`, get seat→(model,harness,effort) mapping.
**Step 2:** doc: Step 2 dispatches each seat via its harness (`hermes` runner for backend=hermes; delegate_task for subagent; external CLI per its skill), each writing a review file.
**Step 3:** doc: effort pinning per seat (deepest seat @xhigh), budget note, low-diversity warning. Update README with registry/datasource section.
**Commit** `docs: integrate model registry + selection into debate skill`.

## Task 6: End-to-end verification + docs
**Objective:** One command proves the whole pipeline; docs finalized.
**Files:** Modify: `README.md`, `docs/plans/*`; add `tests/test-e2e.sh`

**Step 1:** `test-e2e.sh` — refresh (mock) → select → dispatch (mock harness) → synthesize → assert VERDICT + per-seat rounds.
**Step 2:** run full suite `scripts/run-tests.sh`-style: all green on macOS + Linux.
**Step 3:** README: "Model registry & dynamic selection" with datasource section (AA primary, LMArena complement), schema table, and "how to add a model/harness".
**Commit** `test: end-to-end and docs for debate v3`.

---

## Out of scope (deferred)
- Auto-installing harnesses / API keys. Registry marks `available:false`; user opts in.
- Persisting selection outcomes to tune the heuristic (leave for a later data pass).
- Any core Hermes `/`-command changes (stays a skill).

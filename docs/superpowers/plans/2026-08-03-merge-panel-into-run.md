# Merge /debate:panel into /debate:run Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `/debate:run` the single fully-dynamic command — it sizes seats to the review target, picks models + effort via the selector, and in changeset mode dedupes/verifies/ranks findings. Remove `/debate:panel` as a separate command.

**Architecture:** run.md gains three things: (1) changeset-mode seat sizing via `workflows/review-panel.js` classify stage, (2) an always-run `select-panel.py` call that writes `panel.json` and is passed to the runner as `ACPX_SEAT_MODELS`, (3) a post-run report stage in changeset mode that calls the workflow's report stage. `review-panel.js` is reused, not forked — it gains a `plan`-mode branch so it sizes seats for staged plans too. `commands/panel.md` is deleted; its behavior becomes the default changeset path.

**Tech Stack:** bash (run.md, all.md, tests), Node.js (review-panel.js workflow), Python (select-panel.py), jq.

## Global Constraints

- The reference-integrity suite (`tests/test-references.sh`) requires `commands/run.md` to contain "Resolve the panel", "## Step 2: Parallel Review", and "run ALL reviewers from config"; `commands/all.md` must stay a thin alias declaring itself an alias with "exactly one difference" and naming `claude_reviewers`.
- `tests/test-workflow-panel.sh` asserts the workflow's `agent()` call count ≤ 3, `meta` is a pure literal, the lens seats exist in `debate-acpx.sample.json`, and the panel runner is backgrounded + unsandboxed.
- `test-references.sh` version-consistency check: `plugin.json.version == marketplace.json.plugins[0].version`.
- Do NOT close epic #31 in any commit message.
- Tests run individually (not via run-all.sh, which dies at exit 144 in this env).

---

### Task 1: Selector wiring in run.md — plan mode (models + effort for config seats)

**Files:**
- Modify: `commands/run.md`

**Interfaces:**
- Consumes: `select-panel.py --registry <file> --seats <list> --deepest <seat> --installed-harnesses acpx,subagent` → JSON with `.seats[<seat>].model_id`, `.seats[<seat>].effective_effort`, `.seats[<seat>].harness`.
- Consumes: `run-parallel-acpx.sh` reads `ACPX_SEAT_MODELS=<panel.json>`.
- Produces: `$WORK_DIR/panel.json` (selector output) and the registry-resolution rule used by Tasks 2-3.

- [ ] **Step 1: Add the registry-resolution rule to run.md Step 1a, after panel resolution**

Add a subsection documenting the registry pick and the selector invocation, with the graceful-fallback contract:

```text
**Model + effort selection (always).** After the acpx panel resolves (preset /
subset / defaults), the panel selector picks a model and reasoning effort for
every seat. Resolve the registry in this order, first existing wins:
1. `~/.claude/debate-models.json` (the user's seeded/refreshed registry)
2. `<SCRIPT_DIR>/../hermes/templates/debate-models.json` (bundled seed)

Run the selector (Step 2a below) and write its output to
`<WORK_DIR>/panel.json`. If the selector errors or returns no assignment for a
seat (no available model for an installed harness, infeasible `--max-cost`,
empty registry), that seat falls back to its configured agent default with a
`⚠️` warning naming the seat. The panel is never smaller than it would be
without the selector.
```

- [ ] **Step 2: Wire `panel.json` into the Step 2a dispatch**

Modify the Step 2a runner call so the selector runs first and its output is passed to the runner:

```bash
# Resolve registry (first existing wins)
if [ -f "$HOME/.claude/debate-models.json" ]; then
  REGISTRY="$HOME/.claude/debate-models.json"
else
  REGISTRY="<SCRIPT_DIR>/../hermes/templates/debate-models.json"
fi

# Run the selector for the resolved seats
python3 "<SCRIPT_DIR>/select-panel.py" \
  --registry "$REGISTRY" \
  --seats "<resolved-seat-list>" --deepest "<deepest-seat>" \
  --installed-harnesses acpx,subagent > "<WORK_DIR>/panel.json" \
  || echo "⚠️ selector failed for this panel — running configured defaults" >&2

# Dispatch with the per-seat model/effort map
ACPX_SEAT_MODELS="<WORK_DIR>/panel.json" \
  bash "<SCRIPT_DIR>/run-parallel-acpx.sh" "~/.claude/debate-acpx.json" "<REVIEW_ID>" [reviewer1,reviewer2,...]
```

`--deepest` in plan mode is the last seat in the resolved list (the arbiter) unless a preset names one. `ACPX_SEAT_MODELS` is only set when `panel.json` was written; on selector failure, run the runner without it (plan-mode seats fall back to configured defaults).

- [ ] **Step 3: Run the reference-integrity suite**

Run: `bash tests/test-references.sh`
Expected: PASS (run.md still contains "Resolve the panel", "## Step 2: Parallel Review", "run ALL reviewers from config").

- [ ] **Step 4: Commit**

```bash
git add commands/run.md
git commit -m "feat: wire the panel selector into /debate:run (models + effort)"
```

---

### Task 2: Changeset-mode seat sizing — plan mode branch in review-panel.js

**Files:**
- Modify: `workflows/review-panel.js`
- Test: `tests/test-workflow-panel.sh`

**Interfaces:**
- Consumes: classify stage's `pickSeats(diffShape)` — unchanged.
- Produces: `stage: 'classify'` returns `{ stage, diff, seats, seatsSkipped }` when a changeset is under review, and a new `{ stage, seats, seatsSkipped, plan: true }` shape when a plan is staged.

- [ ] **Step 1: Write the failing test**

Add to `tests/test-workflow-panel.sh` a test asserting the workflow supports a `plan` mode where seats come from a passed-in list rather than the diff lens table:

```bash
test_plan_mode_uses_passed_seats() {
  if ! have_node; then
    echo -n "(no node, skipped) "
    return 0
  fi
  node -e '
    const fs = require("fs");
    const src = fs.readFileSync(process.argv[1], "utf8");
    const a = JSON.parse(src.slice(src.indexOf("const A = "), src.indexOf("const WORK_DIR")).replace("const A = ", ""));
    // plan mode must short-circuit classify and return the passed seats
    if (!/if \(A\.plan\)/.test(src)) { console.error("no plan-mode branch"); process.exit(1); }
    if (!/seats:\s*A\.seats/.test(src)) { console.error("plan mode ignores passed seats"); process.exit(1); }
  ' "$WF" 2>&1
}
```

Register it in the run block (after `test_workflow_exists`).

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test-workflow-panel.sh`
Expected: FAIL — "no plan-mode branch".

- [ ] **Step 3: Add the plan-mode branch to review-panel.js**

At the top of the classify stage (before the diff-measuring agent), add:

```js
if (STAGE === 'classify') {
  phase('Classify')

  // Plan mode: the seats are passed in, not sized by a diff. /debate:run with a
  // staged plan resolves its panel from the config; the workflow only carries the
  // seats through so the report stage can reuse the same extract/verify/rank path.
  if (A.plan) {
    log(`plan mode — seats: ${(A.seats || []).join(', ')}`)
    return {
      stage: 'classify',
      plan: true,
      seats: A.seats || [],
      seatsSkipped: [],
    }
  }

  const shape = await agent(...)  // existing classify body unchanged
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test-workflow-panel.sh`
Expected: PASS (17 + 1 new tests).

- [ ] **Step 5: Commit**

```bash
git add workflows/review-panel.js tests/test-workflow-panel.sh
git commit -m "feat: plan-mode branch in review-panel workflow"
```

---

### Task 3: Post-run report stage in run.md (changeset mode only)

**Files:**
- Modify: `commands/run.md`

**Interfaces:**
- Consumes: `review-panel.js` stage `report` with args `{ workDir, repoRoot, stage: 'report', seats, seatsFailed, seatsNotConfigured, diff, seatsSkipped }`.
- Produces: the ranked/deduped/verified finding list that Step 3-4 of run.md present.

- [ ] **Step 1: Add the report stage to run.md Step 3 (presenting results)**

In changeset mode (no staged plan), after the runner completes and the orchestrator works out which seats reported (the existing exit-file check), run the report stage:

```text
**Changeset mode — merge and verify findings in code.** After working out which
seats reported (Step 2c check-results), run the report stage of the panel
workflow. This is what the old `/debate:panel` did after its seats ran: it
transcribes each seat's review into structured findings, groups them by
file:line, has one verifier per location try to refute each claim against the
code, and ranks the survivors.

Workflow({ scriptPath: "~/.claude/debate-workflows/review-panel.js", args: {
  stage: "report", workDir: "<WORK_DIR>", repoRoot: "<REPO_ROOT>",
  seats: ["<the seats that reported>"], seatsFailed: ["..."],
  seatsNotConfigured: ["..."], diff: <diff shape from the classify stage>,
  seatsSkipped: <seatsSkipped from classify>
} })

Present the returned findings (survived, ranked; refuted with why; unverified
labeled as unverified) in place of a hand-rolled dedupe. Then continue to Step 4
synthesis as today — the report's finding list feeds the verdict.
```

The `seatsFailed` / `seatsNotConfigured` / `diff` / `seatsSkipped` come from the classify stage and the step-5 HAVE probe (see Task 4). In plan mode there is no report stage; Step 3-4 read all outputs in full as today.

- [ ] **Step 2: Run the reference suite**

Run: `bash tests/test-references.sh`
Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add commands/run.md
git commit -m "feat: post-run report stage in /debate:run changeset mode"
```

---

### Task 4: Changeset-mode seat sizing + HAVE probe in run.md

**Files:**
- Modify: `commands/run.md`

**Interfaces:**
- Consumes: classify stage output `{ diff, seats, seatsSkipped }`.
- Consumes: the HAVE/UNCONFIGURED probe (from the old panel.md step 5) to drop lens-named seats this machine can't run.
- Produces: the resolved seat list + `--deepest` used by Task 1's selector call, and the `diff`/`seatsSkipped` carried into Task 3's report stage.

- [ ] **Step 1: Add changeset-mode seat resolution to run.md Step 1a**

When no plan is staged (changeset mode), resolve the acpx panel from the lens table instead of the config:

```text
**Changeset mode — the diff sizes the panel.** When no plan is staged, do not
resolve seats from the config. Run the panel workflow's classify stage to measure
the diff and pick the seats:

Workflow({ scriptPath: "~/.claude/debate-workflows/review-panel.js", args: {
  stage: "classify", workDir: "<WORK_DIR>", repoRoot: "<REPO_ROOT>"
} })

It returns `{ diff, seats, seatsSkipped }`. Write that object to
`<WORK_DIR>/panel-state.json` (it is needed again at report time). Then drop the
seats this machine has not configured with the HAVE probe (below). The survivors
are the acpx panel; `--deepest` is `pentester` when present, else the last seat.

**HAVE probe.** For each lens seat, verify its agent can actually spawn — direct
CLI present for antigravity/opus, a registered command for opencode-backed agents,
the CLI on PATH for the rest. A seat that cannot run is reported UNCONFIGURED and
carried into `seatsNotConfigured`; it is never handed to the runner.

**Changeset seats have no config default.** A lens seat has no `reviewers` config
entry behind it, so if the selector returns no assignment for one (no available
model for its harness, or the registry has nothing for it), the seat is **skipped
and reported as failed** with the selector's reason — never run at its agent's
default (there is none). Only plan-mode seats fall back to a configured default.
```

- [ ] **Step 2: Ensure changeset mode also runs the selector (Task 1 wiring is shared)**

The Task 1 selector call applies identically in changeset mode — the resolved seat list feeds `--seats`, `--deepest` as above. Confirm run.md Step 2a's selector block is written so it runs for both modes (the registry/panel.json code from Task 1 is mode-agnostic; only the seat list differs).

- [ ] **Step 3: Run the reference suite**

Run: `bash tests/test-references.sh`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add commands/run.md
git commit -m "feat: changeset mode sizes the panel from the diff in /debate:run"
```

---

### Task 5: Remove /debate:panel command

**Files:**
- Delete: `commands/panel.md`
- Modify: `tests/test-references.sh` (DELETED_FILES list)
- Modify: `tests/test-workflow-panel.sh` (re-point `PANEL_MD` coupling)
- Modify: `README.md`, `codemaps/backend.md`, `hermes/SKILL.md` (drop `/debate:panel` references; run.md now owns the panel behavior)

**Interfaces:**
- Consumes: the panel's runner invocation + report behavior now live in run.md (Tasks 1-4).
- Produces: a repo with no `/debate:panel` command; the reference suite updated so nothing dangles.

- [ ] **Step 1: Delete panel.md and update the reference suite's DELETED_FILES**

Delete `commands/panel.md`. Add `commands/panel.md` to `DELETED_FILES` in `tests/test-references.sh`.

- [ ] **Step 2: Re-point test-workflow-panel.sh away from panel.md**

`tests/test-workflow-panel.sh` greps `$PANEL_MD` in `test_reviews_still_go_through_the_runner`, `test_runner_is_backgrounded_and_unsandboxed`, and `test_failed_extraction_is_not_zero_findings`. Re-point these to `commands/run.md` (which now owns the runner invocation). Update the `PANEL_MD` variable to `RUN_MD="$PROJECT_DIR/commands/run.md"` and the three `grep ... "$PANEL_MD"` sites to `"$RUN_MD"`. The assertions (runner present, backgrounded + unsandboxed, seatsNotTranscribed reported) must now pass against run.md.

- [ ] **Step 3: Run the affected suites**

Run: `bash tests/test-references.sh` and `bash tests/test-workflow-panel.sh`
Expected: both PASS.

- [ ] **Step 4: Update docs referencing /debate:panel**

- `README.md` — remove the `/debate:panel` row from the commands table and the "Panel review (workflow-driven)" section; fold its substance into the `/debate:run` section (the diff-sized panel, file:line grouping, refutation are now what `/debate:run` does in changeset mode). Update the command-table description for `/debate:run` to mention dynamic seat sizing.
- `codemaps/backend.md` — the `run.md` row's purpose and the command table: remove `/debate:panel` mentions; note run.md now invokes the workflow classify/report stages.
- `hermes/SKILL.md` — remove `/debate:panel` references; the skill's dispatch section already describes the dynamic pipeline, ensure no stale panel-command mention remains.
- `hermes/README.md` — same sweep.

- [ ] **Step 5: Run all suites individually**

Run (one per Bash call, per the exit-144 quirk):
- `bash tests/test-references.sh`
- `bash tests/test-workflow-panel.sh`
- `bash tests/test-e2e.sh`
- `bash tests/test-invoke-acpx.sh`
- `bash tests/test-parallel-acpx.sh`
- `python3 tests/test-select-panel.py`

Expected: all PASS.

- [ ] **Step 6: Commit**

```bash
git add -A commands/panel.md tests/test-references.sh tests/test-workflow-panel.sh README.md codemaps/backend.md hermes/SKILL.md hermes/README.md
git commit -m "feat: remove /debate:panel — /debate:run owns the dynamic panel"
```

---

### Task 6: /debate:all alias — dynamic + Claude

**Files:**
- Modify: `commands/all.md`

**Interfaces:**
- Consumes: run.md's new dynamic pipeline (seats, selector, report stage).
- Produces: an alias that inherits the dynamic pipeline; the only difference stays the `claude_reviewers` default.

- [ ] **Step 1: Update all.md's difference statement**

`all.md` already declares itself an alias with "exactly one difference" (the Claude teammates). Update the text so the difference is stated against the *dynamic* run:

```text
This is an alias for `/debate:run` with **exactly one difference**, and it is not a
second copy of the orchestrator. Execute the `run` command as written — same
arguments, same dynamic panel (the diff sizes the seats in changeset mode, the
selector picks models and effort for every seat, and changeset mode dedupes and
verifies findings). Any arguments passed to `/debate:all` apply unchanged.

**The difference — Step 1a, rule 3 (no panel argument).** `/debate:run` spawns no
Claude teammates by default; `/debate:all` does. When no preset and no reviewer
subset is given, resolve `claude_reviewers` from the **top-level** object rather
than treating it as `{}`. Everything else, including Step 2b's handling of that
map, is identical.
```

- [ ] **Step 2: Run the reference suite**

Run: `bash tests/test-references.sh`
Expected: PASS (all.md still declares itself an alias, has no "## Step 2: Parallel Review", names `claude_reviewers`).

- [ ] **Step 3: Commit**

```bash
git add commands/all.md
git commit -m "docs: /debate:all inherits the dynamic panel"
```

---

### Task 7: Docs + codemap sweep

**Files:**
- Modify: `README.md`, `codemaps/backend.md`, `codemaps/architecture.md`, `hermes/SKILL.md`, `hermes/README.md`, `commands/run.md` (any stale "manual config only" framing), `CHANGELOG.md`

**Interfaces:**
- Consumes: the merged behavior from Tasks 1-6.
- Produces: docs that describe one dynamic `/debate:run` (plan mode / changeset mode), no `/debate:panel`.

- [ ] **Step 1: Sweep for stale panel-command and manual-config framing**

Run `rg -n "debate:panel|panel.md|Panel review|panel you picked|diff picked" README.md commands/ hermes/ codemaps/ docs/plans/` and fix every hit: the dynamic pipeline is `/debate:run`'s job now. Update run.md's intro so it no longer reads as purely manual-config.

- [ ] **Step 2: Add a CHANGELOG `[Unreleased]` entry**

Add under `## [Unreleased]` in `CHANGELOG.md`:

```md
- **`/debate:run` is now fully dynamic; `/debate:panel` is gone.** The panel picks
  its own reviewers, models, and effort. A staged plan keeps the config's personas;
  a changeset sizes its own panel from the diff (docs-only → one seat, security →
  the attacker, wide → the full table). The selector assigns model + effort to every
  seat; changeset mode dedupes, verifies, and ranks the findings in code.
```

- [ ] **Step 3: Run the reference suite**

Run: `bash tests/test-references.sh`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add README.md codemaps/backend.md codemaps/architecture.md hermes/SKILL.md hermes/README.md commands/run.md CHANGELOG.md
git commit -m "docs: one dynamic /debate:run, no /debate:panel"
```

---

### Task 8: Integration verification + version bump

**Files:**
- Modify: `.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json`, `CHANGELOG.md`

**Interfaces:**
- Consumes: Tasks 1-7 complete.
- Produces: a merged, green, version-bumped release candidate.

- [ ] **Step 1: Run the full suite set individually**

Run each individually (one Bash call per suite, per the exit-144 quirk):
`test-e2e.sh`, `test-invoke-acpx.sh`, `test-parallel-acpx.sh`, `test-select-panel.py`, `test-references.sh`, `test-workflow-panel.sh`, `test-symlink-health.sh`, `test-cleanup-and-record.sh`.
Expected: all PASS.

- [ ] **Step 2: Bump version to 3.1.0**

Bump `.claude-plugin/plugin.json` and `.claude-plugin/marketplace.json` 3.0.0 → 3.1.0 (feature: one dynamic command). Date the `[Unreleased]` changelog entry as `## [3.1.0] — 2026-08-03 (one dynamic /debate:run)`.

- [ ] **Step 3: Run version-consistency check**

Run: `bash tests/test-references.sh`
Expected: PASS (plugin.json == marketplace.json).

- [ ] **Step 4: Commit**

```bash
git add .claude-plugin/plugin.json .claude-plugin/marketplace.json CHANGELOG.md
git commit -m "chore: release 3.1.0 (one dynamic /debate:run)"
```

- [ ] **Step 5: Tag + release**

Write release notes to `/tmp/claude/release-notes-310.md` (draft → humanizer → my-voice), then:

```bash
git tag v3.1.0 && git push origin v3.1.0
gh release create v3.1.0 --title "v3.1.0 — one dynamic /debate:run" --notes-file /tmp/claude/release-notes-310.md
```

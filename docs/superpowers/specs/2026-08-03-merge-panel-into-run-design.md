# Design: merge /debate:panel into /debate:run — one fully-dynamic command

## Problem

The 3.0.0 headline — self-tuning panels — is only reachable through `/debate:panel`
(which sizes seats to a changeset, picks models + effort via the selector, and
dedupes/verifies/ranks findings). `/debate:run`, the headline command, still resolves
its panel from `~/.claude/debate-acpx.json` and never calls the selector, so a user
running `/debate:run` sees none of the dynamic machinery. There were never meant to
be two commands.

## Goal

`/debate:run` becomes the single command. It:
- sizes seats to the review target (plan mode: config personas; changeset mode: the
  lens table),
- picks models + effort for those seats via `select-panel.py`,
- dispatches through `run-parallel-acpx.sh`,
- in changeset mode, dedupes + verifies + ranks the findings (the panel's report stage).

`/debate:panel` folds in and is removed. Explicit args (preset / subset) remain as
overrides; the default is dynamic.

`/debate:all` stays the alias — same dynamic pipeline, the only difference is the
`claude_reviewers` default (top-level applies under `/debate:all`, `{}` under
`/debate:run`).

## Architecture

### 1. Seat resolution — two paths

**Plan mode** (a `plan.md` is staged): resolve seats exactly as today —
preset → reviewer subset → `default_reviewers` / all config keys. Plan review is
about personas, not diff shape, so the config's seat names stay authoritative.
Models + effort still go through the selector.

**Changeset mode** (no plan, reviewing a diff): the lens table in
`workflows/review-panel.js` (classify stage) sizes the seats from the diff:
docs-only → `auditor`; security-grep → `pentester`; ≥150 added lines →
`simplifier`; non-docs → `antigravity` + `deepseek`; etc. This is the "everything
dynamic" half — the change chooses its own reviewers.

A lens-named seat that is not a key in the config's `reviewers` object (e.g.
`deepseek` on a machine that never ran `create-opencode-agent.sh`) is skipped with a
warning before dispatch — the same `HAVE`/`UNCONFIGURED` probe `/debate:panel` step 5
does. The runner is never handed a seat name it will silently drop.

**`--deepest` in changeset mode:** the deepest seat is the lens table's `pentester`
(attacker / final arbiter) when present, else the last lens seat on the panel. This
mirrors `/debate:panel`'s current behavior; the selector's depth-tier effort scaling
keys off it.

### 2. Selector always runs

After seats resolve, call:

```bash
python3 "$SCRIPT_DIR/select-panel.py" \
  --registry "$REGISTRY" \
  --seats "$SEAT_LIST" --deepest "$DEEPEST" \
  --installed-harnesses acpx,subagent > "$WORK_DIR/panel.json"
```

Registry resolution (in order): `~/.claude/debate-models.json` (user-seeded), else
the bundled `hermes/templates/debate-models.json`. Pass the result to the runner:

```bash
ACPX_SEAT_MODELS="$WORK_DIR/panel.json" \
  bash "$SCRIPT_DIR/run-parallel-acpx.sh" "$CONFIG" "$REVIEW_ID" "$SEAT_LIST"
```

**Graceful fallback.** The selector can error (no model for a harness, `--max-cost`
infeasible, empty registry) or return nothing for a seat. If it fails or a seat has
no assignment, that seat falls back to its configured agent default (today's
behavior) with a warning. `/debate:run` is never worse than it is today. The runner
already reads `panel.json` — `.seats[s].model_id` → `MODEL`, `.seats[s].effective_effort`
→ `EFFORT` — and filters `subagent` seats, so the dispatch side needs no changes.

### 3. Post-run processing — changeset mode only

After the runner completes, run the panel's report stage (`workflows/review-panel.js`
stage `report`): transcribe each seat's `-output.md` into structured findings, group
by `file:line`, verify each claim against the code, rank the survivors. The workflow's
two-stage split already fits: classify runs before dispatch, report after.

**Scope of the report stage: acpx seats only.** The dedupe/verify/rank applies to the
acpx reviewers' output. Claude teammates feed the synthesis/debate loop as today —
they are not double-processed.

**Relationship to run.md's existing Step 3/4.** The report stage does not replace the
full-read + synthesis loop; it sits *in front of* it in changeset mode. The report
stage produces the deduped/verified/ranked finding list. The orchestrator still reads
every `-output.md` in full (Step 3) and synthesizes (Step 4) to reach the
APPROVE/REVISE verdict and drive the revision loop. In plan mode there is no report
stage — the synthesis/debate loop is the whole of it, as today.

### 4. Claude teammates — unchanged

`/debate:run` spawns no Claude teammates by default (`claude_reviewers: {}`); a preset
or `/debate:all` names its own map. The dynamic seat/model/effort machinery is
orthogonal to the Claude side.

## What changes

- **`commands/run.md`** — the merge target. Gains: changeset-mode seat sizing
  (classify), the selector call + `ACPX_SEAT_MODELS`, the post-run report stage in
  changeset mode. Loses: the "everything is manual config" framing.
- **`commands/panel.md`** — deleted. `/debate:panel` is no longer a command; its value
  (deduped, verified, ranked findings) is now what `/debate:run` produces in changeset
  mode.
- **`workflows/review-panel.js`** — reused, not forked. Both stages called from run.md.
  No changes expected unless the merge surfaces one.
- **`commands/all.md`** — `/debate:all` inherits the same pipeline; text updated to say
  it's the Claude-teammates variant of the one dynamic command.
- **`scripts/select-panel.py`** — no change expected (it already emits the
  `effective_effort`/`effective_cost` fields the runner consumes).
- **Docs/codemaps** — the "everything runs through acpx / two commands" framing updated
  across README, commands, hermes docs, codemaps.

## Testing

- **Unit:** selector fallback (registry missing → bundled; selector error → seat falls
  back to configured default); changeset-mode seat sizing (docs-only → auditor, security
  → pentester) covered by the existing lens-table logic + `test-workflow-panel.sh`.
- **Integration:** `/debate:run` in changeset mode produces a deduped/verified/ranked
  report (the e2e path); `/debate:run` with a plan still produces a verdict + revision
  loop. Existing suites (`test-e2e.sh`, `test-workflow-panel.sh`, `test-invoke-acpx.sh`,
  `test-parallel-acpx.sh`) stay green.
- **Removal:** no reference to `/debate:panel` or `commands/panel.md` remains (the
  reference-integrity suite checks command/alias parity).

## Non-goals

- Changing how the selector assigns models/effort (that is shipped and verified).
- Applying the dedupe/verify/rank to Claude teammates in this change.
- Registry schema changes.

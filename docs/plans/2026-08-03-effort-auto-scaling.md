# Plan: Effort auto-scaling via a direct-Codex transport (#31 Q2) — rev 4

Revision 4 after three /debate:run rounds. The approach (direct-Codex
transport) is accepted; this revision resolves the implementation findings.

## Mechanism (verified 2026-08-03)

- `codex exec -c model_reasoning_effort=<level> …` controls reasoning depth
  per call (verified: `reasoning_output_tokens: 0` at low).
- acpx cannot pass it through (`acpx codex exec` has no config passthrough);
  the direct `codex` CLI can. So effort-capable codex seats run direct.

## Direct-Codex branch (invoke-acpx.sh)

A new direct branch for `agent: codex` when an effort is set — the same shape
as the existing `agy`/`opus` branches, reusing the old `codex-exec` retry /
transcript / stale-output-cleanup machinery:

```bash
codex exec --ephemeral \
  -m "${MODEL:-$CONFIG_MODEL}" \
  -c "model_reasoning_effort=$EFFORT" \
  -s read-only \
  -o "$WORK_DIR/${REVIEWER}-output.md" \
  - < "$PROMPT_FILE"
```

- `-m "${MODEL:-$CONFIG_MODEL}"`: the selected model reaches codex (not just
  acpx).
- **Tech-debt flag**: this branch bypasses acpx, so any future acpx middleware
  (telemetry, token-refresh, retry/backoff, proxies) will NOT apply to
  effort-scaled codex seats. The invoke-acpx branch and the plan mark this
  explicitly; the proper upstream fix is `acpx` gaining a config passthrough
  (round-4 antigravity).
- `-c "model_reasoning_effort=$EFFORT"`: the effort override.
- `-s read-only`: no writes.
- `-o`: captures only the final message.
- `- < "$PROMPT_FILE"`: prompt on stdin (reaches EOF; `</dev/null` was a
  contradiction — the prompt IS the stdin).
- `--ephemeral`: one-shot, no session.

The direct-codex predicate (`agent == codex && EFFORT set`) is visible to BOTH
the invoke-acpx session-skip list AND run-parallel's warm-up skip, so a
direct-codex seat never runs `sessions ensure` or a warm-up. No effort-specific
session-collision preflight: a direct-codex seat has no session, and non-codex
transports don't apply effort — that check was dead code (round-3 antigravity).

Non-codex transports with an effort set: agy/opus/acpx log
`EFFORT=<n> not supported by transport <agent>` and run at their default.

## Selector side

`pick()` derives a per-seat runtime effort and costs the panel:

- **Depth-tier step function**, defined in terms of `--min-effort` (so it is
  not a dead knob): deepest seat → `min_effort`, its predecessor →
  one step below, all earlier → two steps below (floor at `low`).
- **Sparse-range membership**: effective effort = the highest value in the
  model's `effort_range` whose rank ≤ the seat tier; none → the range's lowest
  with a warning. A missing/empty `effort_range` defaults to `["medium"]` —
  this is SELECTOR-side only; the schema gate keeps `effort_range` required
  for curated entries (round-3 cartographer). Legacy models that lack it are
  treated as medium-effort.
- **Effort-scaled budget, no double-count**: the registry's `cost_per_task`
  is already measured at the model's DECLARED effort, so
  `effective_cost = cost_per_task × multiplier(effective) / multiplier(declared)`.
  A model run at its declared effort keeps its exact `cost_per_task`
  (regression test). Multipliers (low/medium=1x, high=2x, xhigh=4x, max=8x)
  are a documented, volatile estimate — the selector degrades effort toward
  `low` before failing, and never claims a real spend cap (round-3 antigravity).
- **Degradation is monotonic, not a knapsack, and protects the deepest seat**:
  downgrade the SHALLOWEST seats first, working toward the deepest only as a
  last resort — the deepest seat is the lead reviewer/arbiter, so its reasoning
  is preserved longest (round-4 antigravity). No backtracking, no model
  re-search. If even the all-low panel can't fit, fail.
- **Legacy models are called out**: a model with no `effort_range` defaults to
  `["medium"]` and cannot degrade below it. If a budget constraint can't be met
  because legacy models are locked at `medium`, the failure message names them
  explicitly (round-4 antigravity).
- **Output**: the selector emits `effective_effort` and `effective_cost` per
  seat (distinct from the registry's declared `effort`). Dispatch consumes
  these exact fields.

## Dispatch

`run-parallel-acpx.sh` reads `.seats[$s].effective_effort` and always sets
`EFFORT=${CHILD_EFFORT:-}` (clears inherited state, like MODEL). A
`subagent`-harness seat is **filtered out before spawning** — it is not this
acpx runner's job, and clearing env vars would silently run it through the
configured acpx agent (round-3 cartographer/simplifier). Its dispatch is the
Hermes `delegate_task` route, out of scope here.

## Tests

- selector: tier step function incl. `--min-effort`; sparse-range membership;
  missing `effort_range` defaults; budget keeps declared-effort cost;
  monotonic degradation; `effective_effort`/`effective_cost` in output.
- invoke-acpx: direct-codex command shape (model, `-c`, `-s read-only`, `-o`,
  `- < file`); no `sessions ensure` for direct-codex; agy/opus fallback log;
  mock rejects unsupported flags.
- dispatch: `EFFORT=` always set; subagent filtered pre-spawn; e2e updated
  (it currently greps the acpx log — direct-codex seats write elsewhere).
- registry: schema keeps `effort_range` required; selector-only default.

## Files

- `scripts/select-panel.py`
- `scripts/invoke-acpx.sh`
- `scripts/run-parallel-acpx.sh`
- `tests/mock-codex.sh` (direct-codex command shape), `tests/mock-acpx.sh`
- `tests/test-select-panel.py`, `tests/test-invoke-acpx.sh`,
  `tests/test-parallel-acpx.sh`, `tests/test-e2e.sh`
- Docs that claim "everything runs through acpx": `README.md`,
  `commands/run.md`, `hermes/SKILL.md`, `hermes/README.md`,
  `codemaps/backend.md`, `commands/panel.md`

## Non-goals

- Registry schema change; refresh writing effort; subagent dispatch in this
  runner; applying effort on non-codex transports.

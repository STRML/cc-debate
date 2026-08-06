---
name: debate
description: "Debate a plan across AI reviewers to a consensus verdict."
version: 1.1.0
author: Hermes Agent (port of STRML/cc-debate)
license: MIT
platforms: [linux, macos]
metadata:
  hermes:
    tags: [debate, review, plan, multi-agent, subagents, verification, model-registry]
    related_skills: [codex, claude-code, opencode, hermes-agent, code-review]
---

# Debate: Multi-AI Plan Review

Send the user's implementation plan (or current git changeset) to multiple independent
reviewer agents **in parallel**, collect their feedback, synthesize it, have them argue
out contradictions, and drive to a consensus verdict (APPROVE / REVISE). Max 3 revision
rounds; a post-fix verification pass does not count against the budget.

## Architecture (v3)

This is the Hermes **plugin** that orchestrates the debate workflow. Model access is
**transport-agnostic** — acpx, opencode, and Hermes all reach the same providers (OpenRouter,
Nous, DeepSeek, Z.AI, OpenAI...). Reviewers are dispatched through **acpx**
(`run-acpx-review.sh` -> `run-parallel-acpx.sh`; one CLI, any provider/model from the
registry) — with three direct-CLI exceptions: `antigravity` (agy), `opus` (`claude --print`),
and an effort-scaled `codex` seat (acpx cannot pass `model_reasoning_effort` through, so a
codex seat with an `effective_effort` runs `codex exec` directly). A `subagent` backend stays
as the cheap same-model default. No bespoke "hermes backend". `codex-exec` is gone (repo
reading is generic via acpx; Codex subscription credits work via the plain acpx codex agent's
OAuth).

## The model registry + dynamic selection

Instead of a fixed seat list, the panel is chosen per run from
**`$HERMES_HOME/debate-models.json`** (seed: `templates/debate-models.json`). Each entry:
model + price (cost_per_task + $/M) + strengths + effort (+effort_range) + harness +
repo_aware + family/lab + available.

1. **(Optional) Refresh** the registry:
   `python3 scripts/refresh-models.py --registry $HERMES_HOME/debate-models.json --ttl-hours 168`.
   Pulls the Artificial Analysis Intelligence Index (capability tags on `strengths` at
   the entry's configured effort, plus `price.in`/`price.out` and the `cost` bucket) and
   LMArena human-preference Elo (a new `elo` field, secondary confidence). It never
   touches harness/available/repo_aware/effort/cost_per_task. To also refresh
   `cost_per_task` from a real per-task figure, set `ARTIFICIAL_ANALYSIS_API_KEY` (AA's
   free tier; the keyless mirror has no per-task cost). Offline-safe: if every source
   fails, the last good copy is kept.
   Auto-add is **capped**: a model id a datasource returns that the registry doesn't
   know is only added when it is a genuine improvement — it **dominates** an existing
   `available` model (equal-or-better performance — AA intelligence index, else LMArena
   Elo — at equal-or-lower price — `cost_per_task`, else a blended in/out token price),
   or it is the **strongest model from a lab the registry doesn't have yet** (one per new
   lab). Mid-tier duplicates and strict perf/price tradeoffs are skipped, so a first live
   refresh can't grow the registry by hundreds of stubs. What survives is added as a
   schema-valid entry with safe defaults: `harness:"acpx"`, `effort:"medium"` over the
   full effort_range, `repo_aware:false`, family/lab from the creator when known else
   `unknown`. It arrives **`available:false`** — never selectable. Enable it and confirm
   the harness/pricing before it can be picked.
2. **Route the panel**: `python3 scripts/select-panel.py --registry $HERMES_HOME/debate-models.json
   --seats simplifier,operator,pentester --deepest pentester --installed-harnesses acpx,subagent
   --agents simplifier=codex,operator=codex,pentester=codex`
   -> seat -> {model, harness, provider, model_id, effective_effort, cost_per_task,
   effective_cost, repo_aware}. The selector derives a per-seat reasoning effort
   (`effective_effort`, depth-tiered from the deepest seat down, capped to the model's
   `effort_range`) and an effort-scaled `effective_cost`. Selection: harness-feasibility ->
   lab diversity -> strong-reasoning model on the deepest seat at effort>=xhigh -> cheapest
   cost_per_task elsewhere -> no duplicate model -> low-diversity warning. Under `--max-cost`
   the effort pass degrades monotonically, shallowest seats first, protecting the deepest
   seat's reasoning. **Pass `--agents <seat=agent,...>`** (derive it from your config's
   `.reviewers[].agent`) so each seat is constrained to models its agent can actually run —
   a codex seat gets OpenAI models only, an antigravity seat Google only, and the cc-ds4
   proxy transport only lands on an `opus` seat. Without it the selector fills for lab
   diversity and hands claude-opus-5 / gemini / glm to the local Codex CLI, which refuses
   them at spawn (2026-08-06: 4 of 6 panel seats dead). A seat no agent can fill is left
   unfilled — it degrades to its configured default downstream.
3. **Dispatch** each seat via its harness (`subagent` -> a background Agent teammate
   in `commands/run.md` Step 2a-prime; else acpx), optionally sandboxed
   (`run-acpx-review.sh ... --sandbox --repo-sandbox --repo ROOT` wraps bwrap /
   sandbox-exec / docker, read-only repo mount + isolated HOME for repo-aware seats).
   **The selector's per-seat model reaches the dispatch**: pass the panel output to
   `run-acpx-review.sh --models <panel.json>` (or a flat `{seat: model_id}` file). It forwards
   the map to `run-parallel-acpx.sh`, which sets `MODEL=<model_id>` AND `EFFORT=<effective_effort>`
   on each seat's `invoke-acpx.sh`. A `codex` seat with `EFFORT` runs the codex CLI directly
   (`codex exec --ephemeral -m <model> -c model_reasoning_effort=<level> -s read-only
   -o <outfile> -`); every other transport logs `EFFORT=<level> not supported by transport
   <agent>` and runs at its default. `subagent`-harness seats are filtered out before the
   runner spawns anything — they dispatch as a background Agent teammate (run.md Step
   2a-prime) and never receive `EFFORT` or the fallback log. `--model ID` applies one
   model to every seat in the dispatch.

Seed `debate-models.json` (and refresh) marks `available:false` for harnesses you haven't
configured; only `available:true` + an installed harness are selectable. Refresh
auto-adds brand-new datasource models the same way — they arrive `available:false` and
stay inert until you enable them.

**Adding new models needs consent.** Metric refreshes on existing entries (strengths,
price, elo) always apply automatically. But ADDING entries grows the curated registry,
so the refresh prints the proposed models and prompts `add N new model(s)? [y/N]`
before writing them. In a non-interactive run (cron/CI, no TTY) the additions are
skipped unless you pass **`--apply-new`**. Use **`--dry-run`** to preview what would
be added (and how many metric updates) without writing anything.

## When to use

- A plan is about to become code and you want it stress-tested before writing anything.
- You want competing vantage points (simplifier / operator / pentester) on the same plan.
- You want a second/third/fourth opinion in one shot without sequencing.

## Reviewers on the default panel

| Reviewer (seat) | Persona / angle | Selection |
|---|---|---|
| `simplifier` | Cut scope; over-engineering, YAGNI, complexity to defer. | cheap/speed model, low effort |
| `operator` | Will it run/ship? Ordering, deps, rollback, observability, ops gaps. | mid model |
| `pentester` | Security/robustness; auth, injection, failure modes, edge cases. | strongest reasoning at xhigh |

The registry's `strengths` + `effort` govern which model lands on which seat (see
`references/model-registry.md`).

## Workflow

1. **Stage the subject.** Plan pasted/present -> use verbatim. No plan -> review the current
   changeset (`git diff` vs merge base of the default branch; `DEBATE_DIFF_BASE` overrides).
   Write it to a scratch file (`$HERMES_HOME/debate/<id>/plan.md`) so reviewers read the same
   bytes. **Empty diff -> stop** (nothing to review; reviewers would approve a vacuum).
2. **Route the panel** (above): read registry, run the selector, get seat -> model/harness/effort.
3. **Dispatch in parallel.** Spawn one background Agent teammate per `subagent` seat
   (run.md Step 2a-prime); run acpx seats via `run-acpx-review.sh` in the background
   (fan-out/timeout/retry owned by `run-parallel-acpx.sh`). Each reviewer returns:
   ```
   ## Findings
   - <CRITICAL|HIGH|MED|LOW> <finding>
   ## VERDICT: APPROVE | REVISE
   ```
   Concurrency is capped at `delegation.max_concurrent_children` (default 3); larger panels queue.
4. **Synthesize.** Group overlapping (2+ reviewers) vs unique findings; order by severity.
   Unanimous APPROVE with no CRITICAL/HIGH -> done.
5. **Debate** (skip if `skip-debate`/unanimous). For each contradiction, a debate subagent gets
   both opposing reviews + the plan, returns a resolved position with justification.
6. **Verdict + revision loop.** REVISE -> fix CRITICAL/HIGH (and agreed MED) findings, re-submit
   the *revised* plan to the same panel. Max `max_rounds` revision rounds.
7. **Report.** Verdict per reviewer per round; findings table; debate resolutions; final verdict;
   note seats that produced nothing (distinct from seats that approved).

## Sandbox / safety

acpx permission flags are a policy, not a sandbox. For `repo_aware` or untrusted-diff seats,
run the review inside `scripts/sandbox.py` (bwrap -> sandbox-exec -> docker; read-only repo
mount, isolated HOME, optional `--no-net`). This is real OS isolation at lightweight cost.

## Pitfalls

- Never inline the plan into a shell string — always via file path.
- Parallel, not sequential — one dispatch fan-out.
- Selector never assigns one model to two seats; if the panel comes back thin, the
  low-diversity warning explains why.
- `available:false` seats are skipped silently by the selector — refresh/seed `available`
  truthfully, or the panel shrinks without saying so.
- Stage to `plan.md` first; clean up the scratch dir at the end.

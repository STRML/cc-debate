# Changelog

## [2.4.0] — 2026-06-22 (Antigravity replaces the Gemini reviewer)

### Changed

- **The Google reviewer is now `antigravity`, not `gemini`.** Google is transitioning the Gemini CLI to the [Antigravity CLI](https://antigravity.google), so the direct-CLI Google reviewer now drives `agy` instead of `gemini`. Rename the reviewer's `"agent": "gemini"` to `"agent": "antigravity"` in `~/.claude/debate-acpx.json` (and the reviewer key, by convention). Auth is OAuth (run `agy` once to sign in) or `ANTIGRAVITY_API_KEY` / `GEMINI_API_KEY`.
- `invoke-acpx.sh` handles three `agy` quirks discovered while migrating: the prompt is a **positional argument** (agy ignores stdin in print mode); `agy -p` is run with its stdout on a **Python-allocated pty** because it drops its output (and can hang) when stdout is not a TTY — `script(1)` was rejected because BSD `script` aborts on a non-TTY stdin, which is how the debate runner launches reviewers, and the runner falls back to a plain pipe when pty allocation is denied (e.g. a restrictive sandbox); and because `agy` has **no read-only flag** (`--sandbox` only blocks terminal commands, not file writes), it runs from a throwaway workspace with the plan supplied in-prompt so it never needs repo access.
- Optional `model` config field selects the review model — any display name from `agy models` (e.g. `"Gemini 3.1 Pro (High)"`).
- Requires `python3` on PATH for the `antigravity` reviewer.

## [2.3.0] — 2026-06-09 (Fable + Opus skeptic pair)

### Added

- **Model-tuned skeptic pair.** The single Opus Skeptic in `/debate:all` and `/debate:claude-review` is now two parallel Claude subagents with prompts tuned to each model's measured strengths (from a Fable 5 vs Opus 4.8 panel comparison): the **Fable Skeptic** (`model: fable`) hunts behavioral failures — hang/blocking paths, consumer-side parser gaps — with an explicit "verify library behavior before asserting" rule and a deep-reasoning brief (Fable's accuracy scales with thinking effort); the **Opus Skeptic** (`model: opus`) works a bounded precision checklist — worst-case arithmetic with shown math, boundary conditions, file-by-file consistency sweeps, test-coverage gaps — and must label emergent-behavior claims HYPOTHESIS (Opus's boldest systemic claims were the ones refuted, and its effort scaling plateaus past medium). Convergent findings between the two are the strongest signal.
- **`/debate:fable`** (alias **`/debate:mythos`**) and **`/debate:opus`** — single-skeptic shortcuts.
- **Stored fable preference.** Fable costs ~2x Opus, so `/debate:setup` and `/debate:acpx-setup` now ask once whether to enable the Fable Skeptic and persist `"fable_reviewer": true|false` in `~/.claude/debate-acpx.json`. When `false`, default reviews fall back to a solo Opus Skeptic with the classic broad prompt. `/debate:fable` / `/debate:mythos` override the preference — invoking them by name is explicit consent.

### Changed

- `/debate:claude-double-review` is now skeptic pair + Architect.
- The interactive picker in `/debate:claude-custom-review` lists 6 personalities; `--model` applies only to non-pinned personalities.

## [2.2.4] — 2026-06-07 (reviewer reliability + read-only)

### Added

- **Reviewers are now read-only.** Every reviewer is invoked with write access denied so it cannot edit `plan.md` or any repo file mid-review (an external agent once edited the design doc it was reviewing). acpx agents get `--approve-reads --non-interactive-permissions deny` (reads auto-approved, writes auto-denied because headless can't prompt); gemini gets `--approval-mode plan`; opus/claude gets `--permission-mode plan`. Every generated prompt — initial, debate, verify, revision — also carries an explicit READ-ONLY directive. New test assertions in `tests/test-invoke-acpx.sh` lock in all three flag paths.

### Changed

- **`/debate:all` Step 2 no longer serializes the opus subagent.** The acpx runner Bash call now runs with `run_in_background: true` alongside the opus Agent (also background), both issued in one message, with a new Step 2c that waits for both. Previously a blocking foreground runner meant opus didn't start until acpx returned (~8 min later), running serially and doubling wall-clock.
- **Sequential acpx session warm-up** in `run-parallel-acpx.sh` — one idempotent `sessions ensure` per distinct agent before the parallel submits, eliminating the shared-`~/.acpx`-index race that surfaced as spurious "No acpx session found" / "not authenticated" failures.
- **Opus reviewer model default** bumped to a current id (`claude-opus-4-8`) with per-reviewer `.model` config override; a stale id made `claude --print` return empty with exit 0 (a silent review failure).

## [2.2.3] — 2026-05-28

### Added

- **SAVED gate in `scripts/safe-cleanup.sh`** — cleanup now refuses to delete `<WORK_DIR>` unless `--saved <path>` points to a durable copy of `plan.md` whose SHA matches byte-for-byte. The work dir is the only copy of the reviewed plan until it's persisted; previously a successful review could end with Step 9 deleting that single copy. The gate also rejects a `--saved` path that lives inside the work dir (it would be deleted too), a missing saved file, and a divergent copy. `--force` still bypasses both gates for deliberate abandonment. Argument parsing was reworked to accept `--saved` and `--force` in any order.
- **Step 8 of `/debate:all` now persists the final plan** to a durable location outside `<WORK_DIR>` (back to its source file, or `plan-reviewed-<REVIEW_ID>.md`) before Step 9 cleans up, and passes that path to `safe-cleanup.sh --saved`.
- Six new cases in `tests/test-cleanup-and-record.sh` covering the SAVED gate (refuses without `--saved`, `--force` bypass, saved-not-found, SHA mismatch, saved-inside-work-dir, `--saved` requires a path argument). Suite is now 16 cases.

### Why

The SHA-gated cleanup added in 2.2.0 stopped the orchestrator from wiping artifacts of an *unverified* plan, but nothing forced the *verified* plan to be saved before deletion. On a clean APPROVED run, Step 9 deleted `<WORK_DIR>/plan.md` — the only copy — leaving the user with a review verdict but no plan. The SAVED gate makes durable persistence a precondition for cleanup.

---

## [2.2.2] — 2026-05-12

### Changed

- **`/debate:setup` and `/debate:acpx-setup` now patch `~/.claude/settings.json` directly** instead of printing a snippet for the user to copy. Previous behavior: print the required allowlist and hope the user merged it. Actual behavior in practice: users (and Claude itself in subsequent sessions) assumed the entries were applied because the setup command emitted them, then `/debate:all` silently failed with exit 144 on the next run. The setup commands now Read `~/.claude/settings.json`, diff against the required entries, back up to `~/.claude/settings.json.bak-debate-setup`, Edit-in-place to add only the missing ones, and re-validate with `jq empty` (restoring from backup on parse failure). Output now reports what was added vs already present rather than emitting a JSON blob.

---

## [2.2.1] — 2026-05-12

### Fixed

- **Sandbox allowlist for `~/.acpx/`** — `/debate:setup` and `/debate:acpx-setup` now print `Write(~/.acpx/**)` and `Read(~/.acpx/**)` as required permission allowlist entries. Without them, acpx's per-job queue lock files at `~/.acpx/queues/*.lock` are blocked by the Claude Code sandbox and reviewer subprocesses exit 144. Because `run-parallel-acpx.sh` spawns reviewers via `nohup`/`disown`, the sandbox-blocked-write error never surfaces as a permission prompt — `/debate:all` just reports "all reviewers failed" with no obvious cause. The `/debate:all` command's `allowed-tools` frontmatter now also declares these paths.

---

## [2.2.0] — 2026-05-07

### Added

- **SHA-gated cleanup** (`scripts/safe-cleanup.sh`) — refuses to remove `<WORK_DIR>` if `plan.md` was modified after the last APPROVED reviewer pass. Prevents the failure mode where the orchestrator applies a fix in response to reviewer feedback, claims APPROVED based on its own analysis without re-running reviewers, then wipes the artifacts that would let it notice the gap. Override with `--force` only when explicitly abandoning verification.
- **Round verdict log** (`scripts/record-round.sh`) — appends `{round, sha, verdict, timestamp}` to `<WORK_DIR>/rounds.jsonl` and writes `last-approved-sha.txt` whenever a round closes APPROVED. The /debate:all skill now calls this after each round's verdict is determined.
- **Verification pass (Step 6.5 of /debate:all)** — mandatory re-review when `plan.md` SHA differs from the last reviewer round's SHA. Verification passes are explicitly **off-budget** — they don't burn revision-loop slots, since they're re-reviewing the same logical plan with a fix applied, not iterating on a new revision.
- **SHA self-check (Step 6a of /debate:all)** — orchestrator must compare current `plan.md` SHA against `round-active-plan-sha.txt` before claiming APPROVED.
- Tests for `safe-cleanup.sh` and `record-round.sh` (`tests/test-cleanup-and-record.sh`, 10 cases).

### Changed

- **Stable `WORK_DIR` resolution** — `debate-setup.sh` and `run-parallel-acpx.sh` now resolve `WORK_DIR` via `git rev-parse --show-toplevel` (fallback: `PWD`). Removes the cwd footgun where invoking the runner from a subdirectory produced a silent `plan.md not found` no-op.
- **Loud failure on missing `plan.md`** — `run-parallel-acpx.sh` now prints `pwd`, `realpath`, and a hint to its stderr when `plan.md` is missing, instead of a single easy-to-miss line.
- `WORK_DIR_OVERRIDE` env var on the runner accepts an absolute path as an escape hatch for non-standard layouts.

### Why

The 2.1.x synthesis loop had a quiet substitution failure: when a reviewer flagged a contradiction in the final round, the orchestrator could apply a surgical Edit, reason "this resolves the concern," and write APPROVED — without running any reviewer on the post-fix plan. Step 9 then unconditionally `rm -rf`'d the artifacts. The SHA-gated cleanup makes that substitution structurally impossible to commit silently, and the off-budget verification pass gives the orchestrator the right escape hatch.

---

## [2.1.0] — 2026-04-06

### Changed

- **Consolidated Claude review commands** — replaced `/debate:opus-review` with `/debate:claude-review` (single Skeptic, Opus default), `/debate:claude-double-review` (Skeptic + Architect), and `/debate:claude-custom-review` (interactive personality + model picker). All use Agent tool (context fork) instead of Team mode — more token-efficient, simpler lifecycle.
- **Model selection** — Claude review commands now support `--model sonnet` for faster/cheaper iteration alongside the default Opus.
- **Five reviewer personalities** — Skeptic, Architect, Pentester, Operator, Simplifier.
- **`/debate:all` now includes Claude subagent** — runs an Opus Skeptic Agent in parallel with acpx external reviewers for synthesis.

---

## [2.0.6] — 2026-03-31

### Fixed

- **Full reviewer output reading** — added explicit instructions in `/debate:all` (Steps 3, 4, and Rules) requiring the Read tool on each reviewer's complete output file. Claude was grep-skimming for keywords like "critical|blocker|must fix" instead of reading full reviews, missing 50%+ of findings in practice. Grep/awk/head/tail on reviewer output is now explicitly banned at every synthesis step.

---

## [2.0.3] — 2026-03-19

### Fixed

- **`acpx claude` nested-session guard** — `invoke-acpx.sh` now unsets `CLAUDECODE` and `CLAUDE_CODE_ENTRYPOINT` before invoking the `claude` acpx agent. Claude Code sets these vars to block nested instances; clearing them allows acpx to spawn Claude as an ACP subprocess. This restores the `claude` agent for use in `debate-acpx.json` (knowledge carried over from v1.x `invoke-opus.sh`, dropped during the v2 migration).

- **`/debate:opus-review` rewrite** — no longer routes through acpx. Uses `TeamCreate`+`SendMessage` when available (real conversation continuity between rounds), falls back to Task subagent otherwise. `opus-review-subagent` merged in and removed as a separate command.

---

## [2.0.2] — 2026-03-18

### Fixed

- **Session management** — replaced `sessions new` (always creates a new session, accumulates over time) with `sessions ensure` (idempotent: creates if none exists for the cwd, reuses if one does). Each agent's sessions are namespaced independently, so multiple reviewers in the same cwd don't conflict.

---

## [2.0.1] — 2026-03-18

### Added

- **LiteLLM proxy support** — route reviews through a LiteLLM proxy to any model it supports: local models (Ollama, LM Studio), self-hosted endpoints, or any provider LiteLLM covers. Chain: `acpx → opencode → LiteLLM proxy → model`.
  - `scripts/create-litellm-agent.sh` — helper script: takes `<name> <base_url> <model_alias> [api_key]`, creates the acpx wrapper, and registers the agent in `~/.acpx/config.json`.
  - `/debate:acpx-setup` — LiteLLM added as a third reviewer type in the interactive setup flow.
  - README — new "Any model via LiteLLM" section with setup instructions, model alias requirement, and argument table.
  - MIGRATING.md — updated LiteLLM migration path; added "Using LiteLLM models via opencode" section.

### Fixed

- **Auto-create acpx sessions** — `invoke-acpx.sh` now auto-creates a session when one doesn't exist, eliminating the manual `acpx <agent> sessions new` step on first run.
- **Surface acpx stderr** — when a reviewer fails, stderr is captured to `<name>-stderr.log` and the first 5 lines are printed for immediate diagnostics without needing to dig through files.
- **Empty output handling** — if acpx exits 0 but produces no output, the error is surfaced with stderr contents rather than silently passing an empty review.
- **Trap-based exit file** — `<name>-exit.txt` is always written on unexpected termination (kill, OOM, etc.), preventing the orchestrator from hanging on a missing exit file.

---

## [2.0.0] — 2026-03-17

### Breaking changes

Complete rewrite. All reviewer invocations now go through [acpx](https://github.com/openclaw/acpx). Provider-specific CLIs and API-based curl paths are removed.

See **[MIGRATING.md](MIGRATING.md)** for the full migration guide.

### Removed

- `/debate:codex-review`, `/debate:gemini-review`, `/debate:litellm-review`, `/debate:openrouter-review` — use `/debate:all [reviewer]`
- `/debate:litellm-setup`, `/debate:openrouter-setup` — use `/debate:acpx-setup`
- `invoke-codex.sh`, `invoke-gemini.sh`, `invoke-opus.sh`, `invoke-openai-compat.sh` — replaced by `invoke-acpx.sh`
- `run-parallel.sh`, `run-parallel-openai-compat.sh` — replaced by `run-parallel-acpx.sh`
- `reviewers/` directory — personas moved into `~/.claude/debate-acpx.json`
- Shell mode for `/debate:all`

### Added

- `/debate:acpx-setup` — interactive reviewer configuration with agent probing
- `scripts/invoke-acpx.sh` — unified reviewer invocation (all agents, all providers)
- `scripts/run-parallel-acpx.sh` — parallel runner via nohup background processes
- OpenRouter model support via opencode bridge

### Changed

- Work directory moved from `.claude/tmp/ai-review-*` to `.tmp/ai-review-*`
- Config file changed from `debate-litellm.json` / `debate-openrouter.json` to `~/.claude/debate-acpx.json`
- `/debate:all` now config-driven — no more per-provider arguments

---

## [1.x]

See git log for pre-v2 history.

# Changelog

## [3.2.0] — 2026-08-10 (the parallel runner waits on its own children)

- **`run-parallel-acpx.sh` stopped disowning the reviewers it spawns.** It spawned each
  seat with `nohup … & disown`, which throws away the exit status the kernel is already
  holding, and then rebuilt that status out of files. Each layer under it patched a hole
  the layer above had opened: the child published its code to `<name>-exit.txt`; the
  parent polled every 2s for that file to appear; polling on file *existence* meant an
  exit file could be read while still empty, so `publish_exit` wrote to a temp name and
  renamed; a killed child never published at all, so an EXIT trap synthesized one; that
  trap saw `$?` of 0 on a harness kill and published a success for a seat with no review,
  so a line was added to rewrite 0 to 1. And with no `wait` there was no way to bound the
  run except a second timeout in the parent — `timeout × (retries + 1) + 60` — kept in
  step by hand with the one already inside the child. When the two disagreed, both were
  quiet about it.

  The runner now spawns each seat under `timeout -k 5 <that seat's budget>` and waits on
  it. Same arithmetic, applied to the process it actually bounds. Gone: the poll loop,
  `POLL_INTERVAL`, the SIGTERM-then-SIGKILL ladder, and reading the exit codes back off
  disk to aggregate them.

- **A hung seat dies on its own clock instead of taking the panel with it.** The global
  `MAX_WAIT` killed every reviewer at once when the slowest blew its budget, so one
  wedged seat threw away the reviews that had already landed. Each seat is bounded
  individually now, and the seats that answered are still counted.

  Per-seat bounds need a `timeout` binary, and stock macOS ships neither `timeout` nor
  `gtimeout`. There the runner arms one watchdog for the whole panel at the slowest
  seat's budget — the old global behaviour, kept deliberately, because dropping it would
  leave the most common dev platform with nothing bounding a wedged reviewer.

- **`<name>-exit.txt` is still written for a seat killed before its EXIT trap ran.** The
  orchestrator reads that file, and after a hard kill the wait status is the only account
  of what happened — so the runner writes it there.

- **A non-executable `timeout` on PATH no longer kills every seat at spawn.** Both
  scripts resolved the binary with a bare `command -v`, and bash 3.2 — which is
  `/bin/bash` on stock macOS — answers that with a PATH hit it has not checked for the
  execute bit, where bash 5 skips it and keeps looking. Acting on that answer prefixes
  every agent call with something that cannot run, and the seat dies at exec with code
  126, reading as a dead agent. Both resolvers now require `-x`. `DEBATE_TIMEOUT_BIN`
  pins the binary, or forces the watchdog fallback when set to `none`.

- **`POLL_MAX_WAIT` is rejected when it is not a positive integer.** It reaches `timeout`
  as a duration now, and a malformed one would make `timeout` refuse to run and take
  every seat down instantly. A bad value warns and falls back to the computed budget.

## [3.1.3] — 2026-08-04 (a reviewer's configured `effort` is honored again)

- **`effort` in a reviewer config is load-bearing again, and now decides transport.**
  Since #35 the key was documented as a no-op and linted as one, because only the
  selector-supplied `EFFORT` env var reached the codex branch. That is fine while the
  selector runs — but any other entry point (a preset run, a caller that pins its own
  models, a direct `invoke-acpx.sh` call) left `EFFORT` empty, and an empty effort is
  exactly what routes a codex seat away from the direct CLI and onto acpx. So a config
  that looked fully specified silently ran on a different transport than the one it
  asked for. `effort` now resolves like `model` and `mode`: the per-run env value wins,
  the config is the seat's default, absent both the agent runs at its own default.

  The failure this surfaces on is not subtle. acpx does not drive the local codex CLI —
  it spawns the pinned bridge `@zed-industries/codex-acp@^0.12.0`, whose model support
  trails the CLI's. A seat configured for a current model gets either
  `did not advertise that model` before dispatch, or a bare `Internal error` that is
  really an HTTP 400 (`The '<model>' model requires a newer version of Codex`) — while
  the same model runs fine through `codex exec` on the same machine. Honoring the
  configured effort keeps those seats on the local binary, which is where they worked
  all along.

- **The `effort` lint now checks the value instead of banning the key.** `effort` on a
  non-codex agent is still rejected — every other transport logs the fallback and runs
  at its default, so it reads like configuration while doing nothing. New alongside it:
  the level must be one of `none|minimal|low|medium|high|xhigh|max`. It is passed to
  `codex exec -c model_reasoning_effort=<level>` verbatim, so a typo previously surfaced
  as a codex error mid-run rather than a config error before it.

## [3.1.2] — 2026-08-03 (revert codex effort to the direct CLI; changeset fixes)

- **Codex effort routes back through the direct CLI.** 3.1.1 moved codex effort to
  `acpx codex set reasoning_effort` — that mechanism does not work: `acpx codex exec`
  hardcodes its session options and creates a fresh session per call, so it never replays
  the `set`'s config (verified against the acpx 0.13.0 source and empirically — the exec
  ran at the model's default `xhigh`, not the requested `low`). The working 3.0.0
  mechanism — `codex exec --ephemeral -c model_reasoning_effort=<level>` — is restored.
  This is the same direct-CLI pattern as `antigravity`/`opus`; acpx middleware does not
  apply to it. 3.1.1's genuinely-good fixes stay: the `reap_process_group` `set -e` bug
  (a failing `ps` aborted a seat after a successful exec), the changeset fallback
  wording, the DEBATE_FREEZE_DIFF doc, and the acpx version freshness check.
- **run.md no longer contradicts itself on changeset fallback.** The 3.1.1 change to
  §1f (lens seats fall back to their configured default) conflicted with the unchanged
  §2a/§1a text ("fail closed, no configured default"). Unified: a seat with a `reviewers`
  config entry falls back to it; a lens seat with no config entry is skipped.

## [3.1.1] — 2026-08-03 (codex effort through acpx; changeset fixes)

> **Superseded by 3.1.2.** The acpx-effort transport change in this release was reverted
> in 3.1.2 — `acpx codex set reasoning_effort` does not propagate to `acpx codex exec`.
> The changeset fixes below remain in effect.

- **Codex effort now routes through acpx, not the direct CLI.** Effort auto-scaling shipped
  a direct-`codex` branch in 3.0.0 on an incomplete check of acpx's flags — acpx 0.13.0
  actually exposes `codex set reasoning_effort <level>` session config, which `acpx codex
  exec` honors. A live run showed the direct branch brittle. Codex is now a normal acpx
  seat: effort is set just-in-time via `acpx codex set reasoning_effort` before the exec.
  This also fixed a `set -e` bug in `reap_process_group` where a failing `ps` aborted a
  seat after a successful exec.
- **Changeset seats fall back to their configured default.** The 3.1.0 wording said a lens
  seat with no selector assignment has no config default and must be skipped. A lens seat
  that IS a `reviewers` config key (executor-b, cartographer, deepseek) has one, so it now
  falls back like plan mode. Only a lens seat with no config entry is skipped.
- **`/debate:run` on a specific PR's changeset** — document `DEBATE_FREEZE_DIFF=1` (capture
  the base→head diff and freeze it; the runner regenerates from a clean tree otherwise).
- **`/debate:acpx-setup` warns when acpx < 0.13.0** — the effort auto-scaling baseline.
  `acpx-env-snapshot.sh` compares the installed version and prints the upgrade command.

## [3.1.0] — 2026-08-03 (one dynamic /debate:run)

- **`/debate:run` is now fully dynamic; `/debate:panel` is gone.** The panel picks its
  own reviewers, models, and effort. A staged plan keeps the config's personas; a changeset
  sizes its own panel from the diff (docs-only → one seat, security → the attacker, wide →
  the full table). The selector assigns model + effort to every seat; changeset mode
  dedupes, verifies, and ranks the findings in code.

## [3.0.0] — 2026-08-03 (self-tuning panels: model registry, effort auto-scaling)

The big one. The panel now picks its own reviewers from a data-refreshed model registry, and scales their reasoning effort to seat depth and budget.

### Model registry + dynamic selection

- **`hermes/templates/debate-models.json` — a registry of models.** Each entry carries model + price (`cost_per_task` + $/M) + strengths + effort (`+effort_range`) + harness (best runner for that model) + `repo_aware` + `family/lab` + `available`. Seeded with seven current-gen models; the selector picks from it per run instead of a hardcoded seat list.
- **`scripts/select-panel.py` picks the panel for you.** One model per seat maximising lab diversity, a strong-reasoning model on the deepest seat at effort >= xhigh, cheapest `cost_per_task` elsewhere, never the same model twice, with a low-diversity warning. `--max-cost` is now a **hard panel budget**: if it cannot fit even the cheapest model, or cannot fill every requested seat, the panel fails loudly instead of silently shrinking to a partial or unbudgeted panel. Registry entries that are available but malformed (missing price/strengths/lab) are skipped with a warning instead of crashing the panel.
- **`scripts/refresh-models.py` actually refreshes now.** Parses the Artificial Analysis Intelligence Index (via the automationscookbook mirror) and LMArena human-preference Elo into registry-keyed updates: strengths/effort derived from the index, per-M in/out prices from the source. `cost_per_task` is deliberately left alone (the source exposes whole-index cost, not a per-task number). New datasource model ids are auto-added — capped to genuine improvements (a candidate that dominates an existing available model, or the strongest model from a new lab) and gated behind confirmation; anything added lands `available:false` until you opt in. TTL-guarded and offline-safe. Two refresh bugs fixed along the way: the TTL now keys on the registry file's mtime (an orphaned model used to poison the cache into refetching every run), and a source row with no primary metrics no longer reports a fake successful refresh.
- **A DeepSeek seat, with no proxy in the path.** DeepSeek joins as a reviewer via acpx + opencode, and provider keys consolidate into `~/.claude/debate-keys.json` — one file per provider key instead of a separate env var per seat.
- **`scripts/sandbox.py` — real OS isolation for repo-aware seats.** Platform-adaptive (bwrap / sandbox-exec / docker): read-only repo mount, isolated HOME, optional `--no-net`. It scrubs the caller's env so provider keys never reach a sandboxed seat; the docker backend refuses to start without an explicit image (the old default had no toolchain); the seatbelt HOME now lives under the runner scratch instead of leaking into the OS temp.

### Effort auto-scaling

- **Reasoning effort now scales with seat depth and budget.** The selector derives a per-seat `effective_effort` from a depth-tier step function (`--min-effort` on the deepest seat, one step below for its predecessor, two below for earlier seats), capped to the model's supported `effort_range` — never an unsupported effort. A missing `effort_range` (legacy model) defaults to `["medium"]` and can't degrade below it.
- **Effort-scaled budget, no double-count.** `effective_cost = cost_per_task × mult(eff) / mult(declared)`; a model at its declared effort keeps its exact registry cost. Under `--max-cost` the effort pass degrades monotonically, **protecting the deepest seat** — shallowest seats are downgraded first, the deepest only as a last resort.
- **Effort-capable codex seats run the codex CLI directly.** acpx has no `model_reasoning_effort` passthrough, so a codex seat with an effort set runs `codex exec --ephemeral -m <model> -c model_reasoning_effort=<level> -s read-only -o <outfile> -` directly, reusing the blank-retry machinery. Every other transport logs `EFFORT=<n> not supported by transport <agent>` and runs at its default. This is the same direct-CLI pattern as the existing `antigravity`/`opus` branches; flagged tech debt because it bypasses acpx middleware.

### Dispatch, seats, and fixes

- **The panel selector's per-seat model now actually reaches the acpx call.** `run-acpx-review.sh --models <panel.json>` forwards each seat's `model_id` through `run-parallel-acpx.sh` as `MODEL=<id>`, which `invoke-acpx.sh` passes to acpx (and to the agy/opus direct CLIs) instead of the agent's default. Before this, dynamic reviewer selection was inert end-to-end.
- **`codex-exec` is gone.** The direct-CLI seat is removed; repo reading is a generic acpx property now, and its configs retarget to the plain acpx `codex` agent with `mode: exec`. The effort config key went with it (no seat reads a static per-reviewer effort).
- **A failed session probe now tells you what actually failed.** `invoke-acpx.sh` ran `acpx <agent> sessions ensure` and replaced the failure with one fixed line; acpx had already printed the cause to the discarded stderr, and the causes need completely different fixes — a typo in `debate-acpx.json`, a broken ACP adapter, a missing credential. The probe's stderr is now captured to `<reviewer>-stderr.log`, echoed to the console, and appended to `<reviewer>-output.md` so the cause survives into the debate transcript.
- **The Grounder persona checks a plan's claims against the code.** Every built-in reviewer judges the plan; none checked whether its account of the existing codebase was still true. The Grounder does one mechanical thing — for each present-tense claim (a path, a symbol, a schema, a count, a default), open the file and report CONFIRMED / WRONG / UNVERIFIABLE with a file:line. Only present-tense claims count, so absence of a thing the plan proposes to create is never a finding.
- **The agent adapter acpx leaves running is now reaped.** acpx doesn't tear down the adapter it spawns, and `timeout` only signals the group when it fires — so on the success path every review leaked an orphan tree (13 after ~2 weeks). The runner now kills the process group after the call returns, on both the timeout and success paths.
- **A seat report is reliable, and the panel sizes itself to the diff.** acpx exit 5 (permission-denied) no longer counts as a failed review when a real review arrived; a malformed timeout no longer vanishes from the wait budget; `/debate:panel` picks its seats from what the change actually is.
- **Isolation flags are now promises, not no-ops.** `--repo` and `--no-net` without `--sandbox` fail loudly instead of silently running unsandboxed; guard exits write their own message to `-output.md` so the EXIT trap's generic line no longer masks the real cause.
- **The deepseek lens only fires when the agent is configured.** It used to fire on every non-docs diff, then die at spawn on a fresh clone where the agent was never created — a phantom FAILED seat. The classifier now probes the runtime config and installed agents and only requests the lens when it can actually run.

## [2.9.0] — 2026-07-30 (one-shot reviewers, blank-turn retries, and blank reviews stop passing as success)

- **A blank turn now costs a retry instead of the reviewer's seat.** Some agents end a turn with no final message at random — `kimi-k3` through opencode does it on a large share of turns, on prompts as small as "reply PONG". The new `retries` field (default 1) re-prompts on a blank turn only. A non-zero exit is a real failure that will repeat, and a timeout has already spent its budget, so neither is retried. Set `retries: 0` to switch it off, or 2-3 for an agent you know to be unreliable.

- **A review containing nothing but whitespace no longer counts as delivered.** The empty-output guard tested `[ -s ]`, but acpx terminates even a contentless run with a newline, so an agent that ends its turn without a final message left a 1-byte file that the guard read as a real review. The round logged "Review received", wrote exit 0, and handed the synthesizer a blank. The check now looks for an actual non-whitespace character, so these surface as the failures they always were. This is not hypothetical: `kimi-k3` through opencode ends a large share of its turns with no final message.

- **New reviewer field `mode`, for agents that go quiet after their first turn.** Every acpx reviewer prompted a persistent session, which is right when the agent supports it: context carries across debate rounds. Some do not. An opencode-backed agent such as `kimi-k3` answers the first prompt into a session and then ends every later turn with no content and exit 0, so round 2 records an empty review instead of an error, and the panel silently shrinks. Setting `"mode": "exec"` on a reviewer sends each prompt as a one-shot instead, and skips the `sessions ensure` call it no longer needs. Such a reviewer gives up cross-round continuity and answers every round, which is the better trade when the alternative is a blank file. `mode` defaults to `session`, so existing configs behave exactly as before, and an unrecognized value warns and falls back rather than guessing.

## [2.8.2] — 2026-07-30 (changeset gates hash the diff, not the placeholder)

- **The round SHA and the cleanup gate now follow what was actually reviewed.** `run-parallel-acpx.sh` learned that in 2.8.0. `record-round.sh` and `safe-cleanup.sh` did not, and both kept hashing `plan.md`, which in changeset mode is an empty placeholder. Every changeset round recorded the SHA of the empty string, and `safe-cleanup.sh`'s APPROVED gate compared that constant against itself and passed no matter what had changed. The runner now writes `review-target.txt` and both scripts read it, so one file decides the target instead of three copies of the rule drifting apart.
- **`safe-cleanup.sh` rebuilds the diff before gating on it.** A changeset review covers the working tree, not the snapshot sitting in the work dir. Left alone, a stale `changeset.diff` matches the last approved SHA however far the code has moved since. It is regenerated against the base recorded at run time, so applying a fix and then cleaning up gets refused the same way an edited plan does.
- **The SAVED gate no longer applies in changeset mode.** It exists so a review cannot end with the only copy of a plan deleted. A diff comes from git, so there is nothing to lose, and cleanup stopped asking for `--saved` there.
- Diff generation moved into `scripts/changeset-diff.sh`, shared by the runner and cleanup. It resolves the repo from the work dir rather than the caller's cwd. That also fixes the untracked-file filter, which compared repo-relative paths against an absolute work dir and never matched.

## [2.8.1] — 2026-07-30 (codex prompt via stdin)

- **The `codex-exec` prompt no longer goes in the argument list.** It was passed positionally, and in changeset mode the prompt carries a whole diff — anything past `ARG_MAX` (1 MiB on macOS) fails with `Argument list too long`, so exactly the large reviews that most need a repo-aware reader were the ones that could not run. The prompt is now fed on stdin via `codex exec ... -` with the prompt file redirected in. That redirect also preserves the hang fix: codex blocks forever on a stdin that never reaches EOF, and a regular file gives EOF where an inherited pipe does not. Caught by CodeRabbit on #15. Two regression tests cover it, including one that builds a prompt past `getconf ARG_MAX`.

## [2.8.0] — 2026-07-30 (a reviewer that reads the code, and changeset review)

- **New `codex-exec` agent — the first reviewer with repo access.** Every existing backend is prompt-only. acpx makes no tool calls at all: asked for the declaration line of a method in a file inside its own `--cwd`, it returns null under both `--approve-reads` and `--approve-all`, and a `--verbose` run shows no tool or permission traffic. `agy` is deliberately run from a throwaway workspace because it has no read-only mode. That is fine for judging a plan, but it meant no reviewer could ever check a claim against the actual code. `codex-exec` bypasses acpx and calls `codex exec` directly, which reads files and runs commands, sandboxed with `-s read-only`. New optional `effort` config field, passed as `-c model_reasoning_effort=`. Give it a longer `timeout` than the prompt-only seats.
- **`/debate:run` with no plan staged now reviews your current changeset.** It diffs against the merge base with your default branch and debates that, so the same command works as a code review without new syntax. `DEBATE_DIFF_BASE=<ref>` overrides the comparison point. A staged plan still wins; changeset mode only applies when there is nothing else to review. The prompt follows the target, so reviewers are asked to approve something "ready to merge" rather than "ready to implement".
- **Changeset capture covers untracked files, and the round SHA covers the diff.** `git diff` alone only sees tracked paths, so a newly added file — exactly what a reviewer needs to look at — was silently absent while the review still looked complete. Untracked files are now appended via `git diff --no-index`, with the work dir itself filtered out (it lives inside the repo, so its own artifacts would otherwise read as changes). The round SHA hashes whatever is actually under review, so in changeset mode the mid-round tamper gate covers the diff rather than an empty placeholder plan. When no default-branch merge base exists, the HEAD fallback now says out loud that committed work is excluded instead of quietly reviewing nothing.
- **Two `codex exec` traps handled, both of which look like the CLI silently doing nothing.** It blocks forever on an open stdin, printing `Reading additional input from stdin...` and waiting — the script closes stdin, and a regression test uses a mock that hangs unless it is closed. It also echoes every command it runs to stdout, which can be a whole test suite, so `-o` captures only the final message and the transcript goes to `<reviewer>-transcript.log` instead of the synthesizer's input.

## [2.7.1] — 2026-07-27 (self-healing debate-scripts link)

- **The `~/.claude/debate-scripts` link now follows plugin updates.** It pinned one version directory, and Claude Code deletes version directories nothing is using — so an update left it dangling and every `/debate:*` command died on its first step, `bash ~/.claude/debate-scripts/debate-setup.sh`, with "No such file or directory". The error names a path, not a plugin, which sends you debugging acpx and `debate-acpx.json` instead. A `SessionStart` hook now re-runs `create-links.sh` from `${CLAUDE_PLUGIN_ROOT}`, so the link tracks the installed version without anyone remembering to re-run `/debate:setup`. It also fixes the quieter half: a link to an older version that still exists resolves fine, and commands from the new version were calling the old version's scripts.
- **`/debate:acpx-setup` stopped reporting a healthy link as missing.** The probe was `[ -L ~/.claude/debate-scripts/invoke-acpx.sh ]` — but the symlink is the directory; `invoke-acpx.sh` inside it is a regular file, so `-L` was false whatever the link's state. It now tests that the path resolves and prints where it resolves to, so a link left behind by an older install is visible rather than merely absent. A real file or directory sitting at `~/.claude/debate-scripts` now reads as its own state — `ln -sfn` cannot replace a directory (it drops a nested link inside and exits 0), so `create-links.sh` refuses instead of reporting a refresh that did not happen. Move that path aside and re-run `/debate:setup`; the hook takes over from there.

## [2.7.0] — 2026-07-12 (config presets + /debate:run)

- **Presets.** New optional `presets` object in `debate-acpx.json`. Each preset is a named panel that, for one run, overrides both halves of your config at once — which acpx `reviewers` run and the entire `claude_reviewers` map. Run one by name: `/debate:run tight`. A preset with `"claude_reviewers": {}` runs a Codex/Gemini-only panel with no Claude teammates, which is the case that prompted this — a way to switch to non-Claude reviewers when tokens are tight without hand-editing the config each time. Preset names win over same-named reviewers, and anything with a comma is still read as a reviewer subset, so `codex,antigravity` and every other existing invocation behaves exactly as before.
- **`/debate:all` is now `/debate:run`.** Once a bare argument could be a preset, `all` stopped fitting — `/debate:all tight` reads like a contradiction. `/debate:run` works across all three cases: no argument (every reviewer), a subset, or a preset. `/debate:all` stays as a permanent alias, so existing habits and docs keep working.
- `/debate:acpx-setup` preserves an existing `presets` key when it rewrites the config, the same way it already leaves `claude_reviewers` alone.

## [2.6.0] — 2026-07-11 (file-based Claude-teammate delivery)

- Claude reviewer teammates now write their review to a file, `<WORK_DIR>/claude-<persona>-r<N>-output.md`, the same way the acpx reviewers do. They used to deliver over `SendMessage`, which could drop a review silently and shrink the panel without anyone noticing. `SendMessage` is now just a liveness ping; nobody reads its body.
- A round isn't recorded until every teammate that was spawned has a non-empty output file. Any that are missing get respawned first.
- Wedge detection now checks whether the output file exists (`[ -s … ]`, scoped to this run) instead of grepping `~/.claude/projects` transcripts.
- `/debate:claude-review` and its shortcuts got a `WORK_DIR` and use the same file delivery.

## [2.5.1] — 2026-07-06 (multi-round reviewer wedge fix)

### Fixed

- **Multi-round reviewers wedged: SendMessage to idle teammates never woke them.** In Rounds 2+, the Step 6.5 verification pass, and Step 10 shutdown, the orchestrator SendMessage'd the Round-1 teammates. An idle background teammate is never re-scheduled to read its inbox, so every SendMessage returned success ("Message sent to X's inbox") but the teammate never ran — the orchestrator waited ~50 min on dead mailboxes (observed in production, raw-parts 2026-07-06). Rounds 2+ and the verification pass now **spawn fresh Agent teammates each round** (`claude-<persona>-r<N>` / `claude-<persona>-verify`) with the revision summary + full revised plan inlined, same footer + `SendMessage`-to-`main` delivery as Round 1. Applies to both `commands/all.md` and `commands/claude-review.md` (Step 5).
- **No fallback when a teammate died silently.** Added a wedge detector at every teammate wait point: if ~10 min pass with no result, inspect the per-agent session transcripts' mtimes — none touched since dispatch = dead → respawn fresh instead of waiting or re-pinging.
- **Shutdowns could block completion.** Step 10 / Step 7 shutdown requests to idle teammates may never be read, so they are now **best-effort** — the run finishes without waiting on `shutdown_response`. The cleanup enumeration now also covers every per-round `-r<N>` and `-verify` respawn.

The acpx side (prompt-file + `run-parallel-acpx.sh` re-runs) is unchanged; only the Claude-teammate re-invocation transport changed. Round/SHA bookkeeping (`record-round.sh`, verification-pass budget semantics) is unchanged.

## [2.5.0] — 2026-07-01 (team-mode delivery fix; configurable persona reviewers; `claude_reviewers` schema)

### Fixed

- **Team-mode skeptics never delivered their reviews.** Named `run_in_background` Agent teammates are persistent — they finish, go idle awaiting messages, never auto-return a result, and their plain-text output is not visible to the orchestrator. The Round-1 footer now (a) inlines the plan via `[CURRENT_PLAN]` (general-purpose subagents start fresh and do not inherit context) and (b) requires delivery via `SendMessage` to `main`. This is the root cause of the "skeptic finished with no review text" symptom.
- **Reviewer teammates lingered across runs.** `commands/all.md` Step 10 / `claude-review.md` Step 7 now shut down every spawned teammate via a `SendMessage` `shutdown_request` (not `TaskStop`, which errors on agents) on success and on abort.

### Added

- **Configurable Claude persona reviewers (`claude_reviewers`).** Maps a persona key → model spec. Built-in personas: `skeptic`, `simplifier`, `operator`, `pentester` (bodies in `scripts/reviewer-prompts.md`, the Simplifier/Operator/Pentester adapted from [spencermarx/open-code-review](https://github.com/spencermarx/open-code-review), Apache-2.0). A key can also be a **path to a custom persona file**.
- **Model spec: `false` | `"opus"` | `"sonnet"` | `"fable"` | `"auto"`, or an array.** An array spawns one teammate per model (e.g. `"skeptic": ["fable","opus"]` = the tuned pair). `"fable"` falls back to `"opus"` if fable is deactivated. `"auto"` spawns a persona only when the plan is in its domain (e.g. pentester on security-sensitive changes).
- **Pentester guard:** the built-in `pentester` never runs on `sonnet` (weak at adversarial security reasoning → coerced to `opus` with a warning).

### Changed

- **`fable_reviewer` removed — folded into `claude_reviewers.skeptic`.** `"skeptic": ["fable","opus"]` is the former `fable_reviewer: true`; `"skeptic": "opus"` is the former `false`. The skeptic body is model-tuned (fable → Fable Skeptic, opus → Opus Skeptic, sonnet → Solo Skeptic).
- Reviewer-facing plan delimiters hardened (first/last marker; inner `VERDICT:`/markers treated as plan text). `/debate:all` Rounds 2+ now re-send the full revised plan, not just "revision context".

## [2.4.2] — 2026-07-01 (agy crash on timeout-less macOS; verification pass skipped skeptics)

### Fixed

- **The `antigravity` (`agy`) reviewer crashed with `TIMEOUT_PREFIX[@]: unbound variable` on any macOS without `timeout`/`gtimeout`.** `invoke-acpx.sh` runs under `set -euo pipefail`, and macOS ships bash 3.2, where expanding an **empty** array (`"${TIMEOUT_PREFIX[@]}"`) under `set -u` is treated as an unbound variable and aborts. When neither `timeout` nor `gtimeout` is on PATH (stock macOS, no coreutils) the array is empty, so the agy path died before invoking the CLI instead of running without a timeout wrapper as intended. Fixed with the bash-3.2-safe `"${TIMEOUT_PREFIX[@]+"${TIMEOUT_PREFIX[@]}"}"` expansion. This was also the cause of the red `macos-latest` CI (the runner has no coreutils `timeout`).
- **The Step 6.5 verification pass silently skipped Claude skeptic reviewers.** `/debate:all` runs two reviewer channels — acpx CLIs and the Claude skeptic subagents (`claude-opus-skeptic` / `claude-fable-skeptic`) — and Rounds 2+ re-invoke both. But the verification pass only re-ran the acpx runner, so when a skeptic flagged the fixed issue the pass wrote a prompt file, recorded the round, and reported APPROVED **without re-invoking that skeptic's model** — a fabricated verdict. `commands/all.md` Step 6.5 now requires re-invoking every flagged reviewer across both channels (skeptics via SendMessage, same mechanism as Rounds 2+), with an explicit guard against assuming a verdict for a reviewer not actually re-run.

## [2.4.1] — 2026-06-22 (antigravity reviewer needs an unsandboxed runner)

### Fixed

- **The `antigravity` reviewer failed under the Claude Code sandbox with a misleading error.** `agy` writes a project config to `~/.gemini/config/projects/` before it can open a conversation; that path is outside the sandbox's write allowlist, so the write failed with `operation not permitted` and `agy` then reported `failed to send message: no active conversation`, which landed in the review output as an empty/garbage review (exit 0). It looked like an auth/login problem but was a filesystem-write block. `commands/all.md` Step 2a now directs the orchestrator to launch the `run-parallel-acpx.sh` Bash call with the sandbox disabled (`nohup`/`disown` inside the runner do not lift the seatbelt — only launching the call unsandboxed does). Codex/gemini already needed this for outbound network; the agy migration added a filesystem-write dependency on top. Alternative noted in the step: allowlist `~/.gemini` writes in `settings.json`.

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

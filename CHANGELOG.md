# Changelog

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

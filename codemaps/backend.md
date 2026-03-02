# Backend — debate plugin
_Updated: 2026-03-01_

## Commands (`commands/`)

| File | Slash Command | Purpose |
|------|--------------|---------|
| `all.md` | `/debate:all [skip-debate] [shell-mode]` | Master: parallel review + synthesis + debate (up to 3 rounds) |
| `codex-review.md` | `/debate:codex-review [model]` | Single-reviewer Codex loop (up to 5 rounds) |
| `gemini-review.md` | `/debate:gemini-review [model]` | Single-reviewer Gemini loop (up to 5 rounds) |
| `opus-review.md` | `/debate:opus-review [model]` | Single-reviewer Opus loop via CLI subprocess (up to 5 rounds) |
| `opus-review-subagent.md` | `/debate:opus-review-subagent` | Single-round Opus review via Task tool subagent — no CLI, no temp files |
| `setup.md` | `/debate:setup` | Prerequisite check + stable symlink creation + settings snippet |

## Scripts (`scripts/`)

| File | Purpose |
|------|---------|
| `debate-setup.sh` | Generates `REVIEW_ID`, `WORK_DIR`, outputs `SCRIPT_DIR` (stable symlink or resolved path) |
| `create-links.sh` | Creates `~/.claude/debate-scripts` symlink to installed scripts dir |
| `run-parallel.sh` | Spawns all available reviewers with nohup+disown, polls `*-exit.txt` until done |
| `invoke-codex.sh` | Invokes `codex` CLI with session resume + `--json` output parsing; detects sandbox panic (exit 77) |
| `invoke-gemini.sh` | Invokes `gemini` CLI with session UUID capture via filesystem (not `--list-sessions`) |
| `invoke-opus.sh` | Invokes `claude` CLI as Opus; parses JSON output with `jq`; session resume with fallback |
| `probe-model.sh` | Probes available model tiers for each reviewer (24h cache in `~/.claude/debate-model-probe.json`) |

## Reviewer Definitions (`reviewers/`)

| File | Reviewer | Persona | Default Model |
|------|---------|---------|--------------|
| `codex.md` | OpenAI Codex | The Executor — shell correctness, exit codes, race conditions | `gpt-5.3-codex` |
| `gemini.md` | Google Gemini | The Architect — structure, over-engineering, alternatives | `gemini-3.1-pro-preview` |
| `opus.md` | Claude Opus | The Skeptic — assumptions, unhappy paths, security | `claude-opus-4-6` |

Custom reviewer definitions can be placed at `~/.claude/ai-review/reviewers/<name>.md`.

## Script I/O Contract

Each `invoke-*.sh` script reads from and writes to `$WORK_DIR`:

### Inputs
- `plan.md` — plan to review (always required)
- `*-prompt.txt` — debate/resume prompt (optional; falls back to hardcoded persona prompt)
- `config.env` — model overrides (`CODEX_MODEL`, `GEMINI_MODEL`, `OPUS_MODEL`)

### Outputs
- `*-output.md` — review text
- `*-session-id.txt` — session ID for next resume (empty on failure)
- `*-exit.txt` — exit code (0 = success, 77 = Codex sandbox panic, 124 = timeout)
- `codex-stdout.txt` — raw JSONL stdout (internal; session ID extraction)
- `opus-raw.json` — full JSON response (debugging)

## Invoke Script Timeouts

| Script | Env Var | Default |
|--------|---------|---------|
| `invoke-codex.sh` | `CODEX_TIMEOUT` | 120s |
| `invoke-gemini.sh` | `GEMINI_TIMEOUT` | 240s |
| `invoke-opus.sh` | `OPUS_TIMEOUT` | 300s |

Set env var to `""` to disable timeout. `TIMEOUT_BIN` is not used to disable — scripts re-detect via `command -v`.

## Plugin Metadata (`.claude-plugin/`)

- `plugin.json` — name, version, description, author, license
- `marketplace.json` — marketplace listing with install instructions

Current version: **1.1.18**

# debate

Get a second (and third, and fourth) opinion on your implementation plan. The `debate` plugin sends your plan to multiple AI reviewers simultaneously, synthesizes their feedback, and has them argue out any disagreements — so you get independent review plus a consensus verdict before writing a line of code.

Two modes of operation:

- **CLI mode** — uses provider-specific CLIs (Codex, Gemini, Claude) with session resume across rounds
- **LiteLLM mode** — routes all reviewers through a local [LiteLLM](https://docs.litellm.ai/) proxy, so any model from any provider works with zero new CLI installs

## Quick Start

### CLI mode (provider CLIs)

```bash
# Install
/plugin marketplace add STRML/cc-plan-debate
/plugin install debate@cc-plan-debate

# Check prerequisites
/debate:setup

# Run a review (while in plan mode, or after describing a plan)
/debate:all
```

### LiteLLM mode (any model, no extra CLIs)

```bash
# Install
/plugin marketplace add STRML/cc-plan-debate
/plugin install debate@cc-plan-debate

# Check prerequisites (verifies proxy connectivity + config)
/debate:litellm-setup

# Run a review
/debate:litellm-review
```

Restart Claude Code after installing.

## What it does

```
You: /debate:all

Claude: ✅ codex  ✅ gemini  ✅ opus  — launching parallel review...

  [Codex, Gemini, and Opus review your plan simultaneously]

  ## Codex Review — Round 1        [The Executor]
  The retry logic in Step 4 doesn't handle the case where...
  VERDICT: REVISE

  ## Gemini Review — Round 1       [The Architect]
  Missing error handling when the API is unavailable...
  VERDICT: REVISE

  ## Opus Review — Round 1         [The Skeptic]
  Unstated assumption: this plan assumes the temp directory is writable...
  VERDICT: REVISE

  ## Synthesis
  Unanimous: all reviewers flagged missing error handling
  Unique to Codex: retry logic gap in Step 4
  Unique to Opus: temp directory writability assumption
  Contradictions: none

  ## Final Report
  VERDICT: REVISE — 3 issues to address before implementation

Claude: Revising plan... [updates the plan]
Claude: Sending revised plan back to all reviewers...

  ## Codex Review — Round 2  →  VERDICT: APPROVED ✅
  ## Gemini Review — Round 2  →  VERDICT: APPROVED ✅
  ## Opus Review — Round 2   →  VERDICT: APPROVED ✅

  ## Final Report — Round 2 of 3
  VERDICT: APPROVED — unanimous
```

## Commands

### CLI mode

| Command | Description |
|---------|-------------|
| `/debate:setup` | Check prerequisites, verify auth, print allowlist for unattended use |
| `/debate:all` | All available reviewers in parallel + synthesis + debate |
| `/debate:codex-review` | Single-reviewer Codex loop (up to 5 rounds) |
| `/debate:gemini-review` | Single-reviewer Gemini loop (up to 5 rounds) |
| `/debate:opus-review` | Single-reviewer Opus loop (up to 5 rounds) |
| `/debate:opus-review-subagent` | Single-round Opus review via Task subagent — no CLI, no temp files |

### LiteLLM mode

| Command | Description |
|---------|-------------|
| `/debate:litellm-setup` | Check LiteLLM connectivity, validate config, probe models |
| `/debate:litellm-review` | All configured reviewers in parallel via LiteLLM + synthesis + debate |

## Installation

### From GitHub

```
/plugin marketplace add STRML/cc-plan-debate
/plugin install debate@cc-plan-debate
```

### Local dev

```bash
git clone https://github.com/STRML/cc-plan-debate ~/debate-plugin
/plugin marketplace add ~/debate-plugin
/plugin install debate@debate-dev
```

Restart Claude Code after installing.

## Prerequisites

Run `/debate:setup` to check everything at once. Or manually:

### OpenAI Codex (for `/debate:codex-review` and `/debate:all`)

```bash
npm install -g @openai/codex
export OPENAI_API_KEY=sk-...    # add to ~/.bashrc or ~/.zshrc
```

### Google Gemini (for `/debate:gemini-review` and `/debate:all`)

```bash
npm install -g @google/gemini-cli
gemini auth
```

### Claude Opus (for `/debate:opus-review` and `/debate:all`)

The `claude` CLI is part of Claude Code itself, so it's already installed if you're running this plugin. You also need `jq` to parse its JSON output:

```bash
brew install jq          # macOS
apt install jq           # Linux
```

No API key is required — the `claude` CLI uses Claude Code's stored OAuth credentials automatically.

### GNU timeout — macOS only

macOS doesn't ship `timeout`. Without it the 120s per-reviewer timeout is disabled:

```bash
brew install coreutils
```

## Usage

### `/debate:all [skip-debate] [shell-mode]`

Runs all available reviewers in parallel (Codex 120s, Gemini 240s, Opus 300s timeout). If reviewers disagree, Claude sends targeted questions back to each one to resolve contradictions. Iterates up to 3 revision rounds.

When Claude Code's teammate feature is available, reviewers run as persistent team agents — they maintain context across rounds without re-spawning. Falls back to subagents or shell scripts if unavailable. Missing CLI binaries are automatically substituted with Claude teammates playing the same persona.

```
/debate:all              # full flow with debate
/debate:all skip-debate  # skip debate, go straight to final report
/debate:all shell-mode   # force shell script execution (no team/agent)
```

### `/debate:codex-review [model]`

Iterative loop with Codex only — good when you want faster turnaround or a focused Codex perspective.

```
/debate:codex-review
/debate:codex-review o4-mini
```

### `/debate:gemini-review [model]`

Same workflow with Gemini.

```
/debate:gemini-review
/debate:gemini-review gemini-2.0-flash
```

### `/debate:opus-review [model]`

Iterative loop with Claude Opus as **The Skeptic** — focused on unstated assumptions, unhappy paths, second-order failures, and security. Uses session resume to maintain context across rounds.

```
/debate:opus-review
/debate:opus-review claude-opus-4-6
```

### `/debate:opus-review-subagent`

Single-round Opus review using Claude's built-in Task tool. No CLI subprocess, no temp files, no session management — just fast feedback. Good for a quick sanity check. Use `/debate:opus-review` for iterative multi-round review.

## LiteLLM Mode

LiteLLM mode routes all reviewer calls through a local [LiteLLM](https://docs.litellm.ai/) proxy's OpenAI-compatible API. This means:

- **No provider CLIs needed** — no `codex`, `gemini`, or `claude` binaries to install or authenticate
- **Any model works** — DeepSeek, Gemini via Bedrock, local models, anything LiteLLM can route to
- **Adding a reviewer = adding a JSON entry** — no code changes, no new scripts

The only dependencies are `curl` and `jq`, both pre-installed on most systems.

### Prerequisites

1. A running LiteLLM proxy (default: `http://localhost:8200`)
2. `jq` installed (`brew install jq` / `apt install jq`)
3. The config file at `~/.claude/debate-litellm.json`

Run `/debate:litellm-setup` to verify everything at once.

### Config

Create `~/.claude/debate-litellm.json`:

```json
{
  "base_url": "http://localhost:8200/v1",
  "api_key": "",
  "reviewers": {
    "opus": {
      "model": "claude-opus-4-6",
      "timeout": 300,
      "system_prompt": "You are The Skeptic — a devil's advocate..."
    },
    "deepseek": {
      "model": "deepseek.v3-v1:0",
      "timeout": 120,
      "system_prompt": "You are The Pragmatist — a battle-scarred engineer..."
    },
    "sonnet": {
      "model": "claude-sonnet-4-6",
      "timeout": 180,
      "system_prompt": "You are The Editor — a meticulous code reviewer..."
    }
  }
}
```

Each reviewer entry has:

| Field | Required | Description |
|-------|----------|-------------|
| `model` | Yes | Model ID as it appears in LiteLLM's `/models` endpoint |
| `timeout` | No | Seconds before the API call is killed (default: 120) |
| `system_prompt` | No | Persona and focus areas sent as the system message |

`api_key` is optional — most local LiteLLM proxies don't require auth. The API key can also be set via the `LITELLM_API_KEY` environment variable.

### Adding a reviewer

Add an entry to the `reviewers` object in your config. That's it — no scripts, no binaries, no code changes:

```json
"gemini": {
  "model": "gemini-2.5-pro",
  "timeout": 240,
  "system_prompt": "You are The Architect — a systems architect reviewing for structural integrity..."
}
```

The model ID must match what your LiteLLM proxy exposes. Run `/debate:litellm-setup` to list available models.

### `/debate:litellm-review [reviewers] [skip-debate]`

Runs all configured reviewers in parallel, synthesizes feedback, debates contradictions, and iterates up to 3 revision rounds.

```text
/debate:litellm-review                    # all configured reviewers
/debate:litellm-review opus,deepseek      # specific reviewers only
/debate:litellm-review skip-debate        # skip debate, straight to report
```

### `/debate:litellm-setup`

Validates your LiteLLM setup end-to-end:

1. Checks `curl` and `jq` are installed
2. Reads and validates `~/.claude/debate-litellm.json`
3. Confirms the LiteLLM proxy is reachable
4. Lists available models from the proxy
5. Cross-checks each configured reviewer's model against available models
6. Optionally probes each model with a test request
7. Prints the permission allowlist for unattended use

### CLI mode vs LiteLLM mode

| | CLI mode (`/debate:all`) | LiteLLM mode (`/debate:litellm-review`) |
|---|---|---|
| **Dependencies** | `codex`, `gemini`, `claude` CLIs | `curl`, `jq` |
| **Auth** | Per-provider (API keys, OAuth) | LiteLLM proxy handles it |
| **Session resume** | Yes (multi-turn context) | No (full context re-sent each round) |
| **Adding reviewers** | New script + command changes | JSON config entry |
| **Team mode** | Yes (persistent agent teammates) | No (shell mode only) |
| **Models** | Tied to provider CLIs | Any model LiteLLM supports |

Both modes produce the same output format: per-reviewer reviews, synthesis, debate, and a final verdict.

## Unattended / No-Prompt Use

Each command declares its tool permissions in frontmatter, so Claude Code will ask once per session and remember. To approve permanently across all sessions, run `/debate:setup` to get the exact JSON snippet to add to `~/.claude/settings.json`.

## Troubleshooting

**Gemini produces no output**
Gemini authentication may have expired. Run `gemini auth` to re-authenticate.

**`timeout: command not found`**
Install GNU coreutils: `brew install coreutils` (macOS) or `apt install coreutils` (Linux). Reviews will still work without it, but the 120s timeout won't be enforced.

**Codex session resume fails**
Codex sessions expire after a period of inactivity. The commands automatically fall back to a fresh call and recapture the new session ID.

**Gemini session not found after review**
Session UUID is captured by comparing `~/.gemini/tmp/` session files before and after the review call. If sessions shift concurrently (multiple Gemini processes), the diff may be ambiguous and the command falls back to non-resume mode for subsequent rounds.

**Opus exits with "Claude Code cannot be launched inside another Claude Code session"**
This means the nested-session guard wasn't applied. The commands handle this automatically via `unset CLAUDECODE CLAUDE_CODE_ENTRYPOINT` — if you see this error, ensure you're running the latest version of the plugin.

**Opus review requires `jq`**
The `claude` CLI outputs JSON and requires `jq` to extract the review text and session ID. Install with `brew install jq` (macOS) or `apt install jq` (Linux).

**Codex exits with sandbox panic (exit code 77)**
The Codex binary accesses a macOS system API that is blocked inside Claude Code's sandbox. To fix, add `codex` to `sandbox.excludedCommands` in `~/.claude/settings.json`, or run with `dangerouslyDisableSandbox: true`. The `/debate:setup` command prints the exact snippet.

**Only one reviewer available**
Single-reviewer commands (`/debate:codex-review`, `/debate:gemini-review`, `/debate:opus-review`) and `/debate:all` all work with any subset of reviewers available. With fewer reviewers, `/debate:all` skips any unavailable reviewer and may skip the debate phase if only one succeeds.

**LiteLLM: connection refused**
The proxy isn't running. Start it with `litellm --config your_config.yaml` or whatever command your setup uses. Run `/debate:litellm-setup` to verify connectivity.

**LiteLLM: model not found**
The model ID in `~/.claude/debate-litellm.json` doesn't match what LiteLLM exposes. Run `/debate:litellm-setup` to list available models and update your config accordingly.

**LiteLLM: empty response from API**
The model returned no content. Check LiteLLM proxy logs for errors. Some models may require specific parameters — the raw API response is saved to `<work_dir>/<reviewer>-raw.json` for debugging.

## Security

- Plan content is always passed via **file path or stdin redirect** — never inlined in shell strings
- Dynamic content (revision summaries, AI feedback) is written to temp files and read via `$(cat file)` — never interpolated directly into quoted strings
- Codex runs with `-s read-only` — can read the codebase for context but cannot write files
- Gemini runs with `-s` (sandbox) — cannot execute shell commands
- Gemini runs with `-e ""` — extensions and skills are disabled for each review call
- Opus runs with `--tools ""` — no tool access; `--disable-slash-commands`; `--strict-mcp-config`; hooks disabled — read-only, stateless review
- **LiteLLM mode:** JSON payloads are constructed via `jq` — plan content and prompts are never interpolated into shell strings. API calls use `curl` with content passed via `-d` flag from jq-built JSON. All reviewer output is written to temp files in `/tmp/claude/ai-review-*` and cleaned up after the session.

## Custom Reviewers

### CLI mode

Add reviewer definitions at `~/.claude/ai-review/reviewers/<name>.md`. These override built-in reviewers with the same `name:` frontmatter value. See `reviewers/codex.md` for the format.

### LiteLLM mode

Add an entry to the `reviewers` object in `~/.claude/debate-litellm.json`. Each entry needs a `model` (matching LiteLLM's `/models` output), an optional `timeout`, and an optional `system_prompt` defining the reviewer's persona and focus areas.

## License

MIT

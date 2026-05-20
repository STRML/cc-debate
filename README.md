# debate v2

Get a second (and third, and fourth) opinion on your implementation plan before you write a line of code. `debate` sends your plan to multiple AI reviewers in parallel, synthesizes their feedback, has them argue out contradictions, and produces a consensus verdict.

**v2 is a ground-up rewrite.** Everything now runs through [acpx](https://github.com/openclaw/acpx) — a single unified CLI that talks to any coding agent. No more managing individual CLIs, session files, or API keys per provider. One config, any combination of models.

## Quick Start

```bash
# 1. Install the plugin
/plugin marketplace add STRML/cc-debate
/plugin install debate@cc-debate

# 2. Install acpx
npm install -g acpx@latest

# 3. Configure your review panel (interactive)
/debate:acpx-setup

# 4. Run a review
/debate:all
```

Restart Claude Code after installing the plugin.

---

## How it works

```text
You: /debate:all

Claude: Running parallel review via acpx...

  codex    → agent: codex    (120s)
  gemini   → agent: gemini   (240s)
  mercury  → agent: mercury  (120s)

  ## Codex Review — Round 1
  The retry logic in Step 4 doesn't handle the case where...
  VERDICT: REVISE

  ## Gemini Review — Round 1
  Missing error handling when the API is unavailable...
  VERDICT: REVISE

  ## Mercury Review — Round 1
  Unstated assumption: this plan assumes the temp directory is writable...
  VERDICT: REVISE

  ## Synthesis
  Unanimous: all reviewers flagged missing error handling
  Unique to Codex: retry logic gap in Step 4
  Unique to Mercury: temp directory writability assumption

  ## Final Report
  VERDICT: REVISE — 3 issues to address

Claude: Revising plan...
Claude: Re-submitting to all reviewers...

  ## Codex Review — Round 2   →  VERDICT: APPROVED ✅
  ## Gemini Review — Round 2  →  VERDICT: APPROVED ✅
  ## Mercury Review — Round 2 →  VERDICT: APPROVED ✅

  VERDICT: APPROVED — unanimous after 2 rounds
```

---

## What you need

**Required:**
- [acpx](https://github.com/openclaw/acpx) — `npm install -g acpx@latest`
- [jq](https://jqlang.org) — `brew install jq` / `apt install jq`
- The agent CLIs for whatever reviewers you want (see [Supported Agents](#supported-agents) below)

**Optional:**
- [opencode](https://opencode.ai) — only needed for OpenRouter model access (DeepSeek, Mercury, Kimi, etc.) or LiteLLM proxy access (local models, self-hosted, etc.)

---

## Supported Agents

These are the reviewer backends you can use. Mix and match — pick 2-4 for a useful review panel.

### Built-in acpx agents

These have native Agent Client Protocol support. Install the CLI, and acpx handles the rest.

| Agent name | Model | Install |
|-----------|-------|---------|
| `codex` | OpenAI Codex | `npm install -g @openai/codex` + `OPENAI_API_KEY` |
| `gemini` | Google Gemini 2.x/3.x | `npm install -g @google/gemini-cli` + `gemini auth` + `GEMINI_API_KEY` ¹ |
| `claude` | Claude (Opus/Sonnet) | Already installed — you're running it now |
| `kimi` | Kimi (Moonshot AI) | See [Kimi CLI docs](https://github.com/moonshot-ai/kimi-cli) |
| `kiro` | Kiro (AWS) | See [Kiro docs](https://kiro.dev) |
| `qwen` | Qwen Code | See [Qwen Code docs](https://github.com/QwenLM/qwen-code) |
| `cursor` | Cursor | Install [Cursor IDE](https://cursor.com) |
| `copilot` | GitHub Copilot | `gh extension install github/gh-copilot` |
| `opencode` | OpenCode (default model) | `npm install -g opencode-ai` |
| `kilocode` | Kilocode | `npx @kilocode/cli` |
| `droid` | Factory Droid | See acpx docs |
| `iflow` | iFlow | See acpx docs |
| `pi` | Pi Coding Agent | See acpx docs |
| `openclaw` | OpenClaw | See acpx docs |

> ¹ **Gemini note:** The Gemini CLI's stored OAuth works for direct CLI use but not for acpx's non-interactive subprocess mode. You need a separate API key. Get one free at [aistudio.google.com/apikey](https://aistudio.google.com/apikey), then add it to `~/.claude/settings.json`:
> ```json
> "env": { "GEMINI_API_KEY": "AIza..." }
> ```
>
> **Antigravity CLI transition (June 18, 2026):** Google is migrating Google One and free-tier Gemini CLI users to the new [Antigravity CLI](https://developers.googleblog.com/an-important-update-transitioning-gemini-cli-to-antigravity-cli/). The `GEMINI_API_KEY` path used by this plugin is unaffected — AI Studio API keys bill against AI Studio quota, not Google One OAuth tiers, so the `gemini` reviewer continues to work. Paid Gemini Code Assist Standard/Enterprise users also keep the `gemini` CLI as-is. A dedicated `antigravity` reviewer will be added once [acpx](https://github.com/openclaw/acpx) ships native ACP support for it.

> **Claude note:** Using `claude` as a reviewer means Claude reviewing its own plan — useful for a fresh-context skeptical read, but not truly independent. For independent perspectives, use non-Claude agents. `invoke-acpx.sh` automatically handles the nested-session guard (`CLAUDECODE`) required to run Claude as a subprocess.

### Any model via OpenRouter (using opencode)

For models that don't have a native acpx agent — DeepSeek, Mercury, Mixtral, Kimi K2, GPT variants, or anything else on [openrouter.ai](https://openrouter.ai/models) — you can route through OpenRouter using opencode as the bridge:

```
acpx → opencode (custom agent) → OpenRouter API → any model
```

**Prerequisites:**
- `npm install -g opencode-ai`
- OpenRouter API key from [openrouter.ai/settings/keys](https://openrouter.ai/settings/keys)

**Setup (one time per model):**

> **Tip:** Just run `/debate:acpx-setup` — it does all of this for you interactively.

Or manually:

```bash
# 1. Create a wrapper directory
mkdir -p ~/.acpx/agents/mercury

# 2. Write the opencode config
cat > ~/.acpx/agents/mercury/.opencode.json << 'EOF'
{
  "provider": {
    "openrouter": { "apiKey": "sk-or-v1-..." }
  },
  "agents": {
    "coder": { "model": "openrouter/inception/mercury-2" }
  }
}
EOF
chmod 600 ~/.acpx/agents/mercury/.opencode.json

# 3. Write the launch script
cat > ~/.acpx/agents/mercury/start.sh << 'EOF'
#!/bin/bash
export OPENCODE_CONFIG_CONTENT='{"model":"openrouter/inception/mercury-2"}'
exec opencode acp "$@"
EOF
chmod +x ~/.acpx/agents/mercury/start.sh

# 4. Register with acpx (create/merge into ~/.acpx/config.json)
# Add this entry:
# { "agents": { "mercury": { "command": "/Users/you/.acpx/agents/mercury/start.sh" } } }
```

Then add to `~/.claude/debate-acpx.json`:
```json
"mercury": {
  "agent": "mercury",
  "timeout": 120,
  "model_id": "inception/mercury-2",
  "system_prompt": "You are The Contrarian..."
}
```

**Popular OpenRouter models to consider:**

| Model | OpenRouter ID | Notes |
|-------|--------------|-------|
| DeepSeek R1 | `deepseek/deepseek-r1` | Strong reasoning |
| Inception Mercury | `inception/mercury-2` | Fast, strong coder |
| Kimi K2.5 | `moonshotai/kimi-k2.5` | 1M context |
| Mistral Large | `mistralai/mistral-large` | Good architecture instincts |
| GPT-4.1 | `openai/gpt-4.1` | Broad coverage |
| Gemini 2.5 Pro | `google/gemini-2.5-pro` | Strong if you don't have Gemini CLI |

### Any model via LiteLLM (using opencode)

For local models (Ollama, LM Studio), self-hosted endpoints, or any provider that [LiteLLM](https://github.com/BerriAI/litellm) supports, you can route through a LiteLLM proxy using opencode as the bridge:

```
acpx → opencode (custom agent) → LiteLLM proxy → any model
```

**Prerequisites:**
- `npm install -g opencode-ai`
- A running LiteLLM proxy (`pip install litellm[proxy]` + `litellm --config config.yaml`)

**Model alias requirement:**

opencode resolves model IDs against its built-in OpenAI model list, so the model name you give it must be a known OpenAI model name (e.g. `gpt-4o-mini`). Configure LiteLLM to route that alias to your actual model:

```yaml
# LiteLLM config.yaml
model_list:
  - model_name: gpt-4o-mini         # alias opencode uses
    litellm_params:
      model: ollama/deepseek-r1     # your actual model
      api_base: http://localhost:11434
```

**Setup (one time per agent):**

> **Tip:** Just run `/debate:acpx-setup` — it does all of this for you interactively.

Or manually:

```bash
# Run the helper script
bash ~/.claude/debate-scripts/create-litellm-agent.sh \
  deepseek \
  http://localhost:8200/v1 \
  gpt-4o-mini \
  sk-litellm-optional-key
```

Then add to `~/.claude/debate-acpx.json`:
```json
"deepseek": {
  "agent": "deepseek",
  "timeout": 120,
  "model_id": "deepseek-r1 via LiteLLM",
  "system_prompt": "You are The Pragmatist..."
}
```

**Arguments to `create-litellm-agent.sh`:**

| Arg | Required | Example |
|-----|----------|---------|
| `name` | Yes | `deepseek` |
| `base_url` | Yes | `http://localhost:8200/v1` |
| `model_alias` | Yes | `gpt-4o-mini` (must be a known OpenAI model name) |
| `api_key` | No | `sk-litellm-abc123` (omit if proxy has no auth) |

---

## Config reference

Reviewers live in `~/.claude/debate-acpx.json`. This is the only file you need to edit to change your panel.

```json
{
  "reviewers": {
    "codex": {
      "agent": "codex",
      "timeout": 120,
      "system_prompt": "You are The Executor — find what breaks at runtime. Focus on shell correctness, exit codes, race conditions, file I/O."
    },
    "gemini": {
      "agent": "gemini",
      "timeout": 240,
      "system_prompt": "You are The Architect — review for structural integrity. Focus on approach validity, over-engineering, missing phases, graceful degradation."
    },
    "mercury": {
      "agent": "mercury",
      "timeout": 120,
      "model_id": "inception/mercury-2",
      "system_prompt": "You are The Contrarian — question everything. Focus on hidden assumptions, overlooked alternatives, failure modes under load."
    }
  }
}
```

| Field | Required | Description |
|-------|----------|-------------|
| `agent` | Yes | acpx agent name (see [Supported Agents](#supported-agents)) |
| `timeout` | No | Seconds before the review is killed. Default: 120. Use 240-300 for large/slow agents. |
| `system_prompt` | No | Persona sent as the prompt prefix. Omit for generic reviewer behavior. |
| `model_id` | No | For OpenRouter agents — the underlying model ID (e.g. `inception/mercury-2`). Shown in the summary. |

### Good reviewer personas

The value of multiple reviewers is getting genuinely different lenses. Some ideas:

- **The Executor** — shell correctness, exit codes, race conditions, file I/O, command availability
- **The Architect** — structural integrity, approach validity, over-engineering, missing phases, graceful degradation
- **The Skeptic** — unstated assumptions, unhappy paths, second-order failures, security
- **The Contrarian** — questions conventional wisdom, hidden assumptions, alternatives everyone overlooks, failure modes under load
- **The Pragmatist** — what will actually ship, unnecessary complexity, missing happy path steps, places that assume competence that may not exist

---

## Commands

| Command | What it does |
|---------|-------------|
| `/debate:setup` | Check prerequisites, create `~/.claude/debate-scripts` symlink, detect v1.x configs and migrate, print permission allowlist |
| `/debate:acpx-setup` | Interactive reviewer configuration: pick agents, set up OpenRouter models, probe connectivity |
| `/debate:all [reviewers] [skip-debate]` | Run all (or specific) reviewers in parallel, synthesize, debate, iterate up to 3 rounds |
| `/debate:claude-review` | Claude review — single Skeptic by default, Opus model. Up to 5 rounds. |
| `/debate:claude-double-review` | Two Claude reviewers (Skeptic + Architect) in parallel. |
| `/debate:claude-custom-review` | Interactive picker — choose personalities and model (opus/sonnet). |

### `/debate:all` options

```bash
/debate:all                    # all configured reviewers
/debate:all codex,mercury      # specific subset only
/debate:all skip-debate        # skip debate phase, straight to final report
```

---

## Unattended use (no approval prompts)

Add to `~/.claude/settings.json` to permanently approve all debate tool calls:

```json
{
  "permissions": {
    "allow": [
      "Bash(bash ~/.claude/debate-scripts/debate-setup.sh:*)",
      "Bash(bash ~/.claude/debate-scripts/run-parallel-acpx.sh:*)",
      "Bash(bash ~/.claude/debate-scripts/invoke-acpx.sh:*)",
      "Bash(rm -rf .tmp/ai-review-:*)",
      "Read(.tmp/ai-review*)",
      "Edit(.tmp/ai-review*)",
      "Write(.tmp/ai-review*)"
    ]
  }
}
```

Run `/debate:setup` to print this snippet with verified paths.

---

## Troubleshooting

**Reviewer fails immediately with "No acpx session found"**
For custom agents (OpenRouter via opencode), create a session first: `acpx <agent> sessions new`. `/debate:acpx-setup` does this automatically during the probe step.

**Gemini fails with auth error**
`GEMINI_API_KEY` is not set. Get a free key at [aistudio.google.com/apikey](https://aistudio.google.com/apikey) and add it to `~/.claude/settings.json` under `"env"`. Restart Claude Code.

**OpenRouter model returns wrong answers / ignores persona**
The `OPENCODE_CONFIG_CONTENT` env var may not be taking effect. Verify your `start.sh` exports it correctly and that the model ID matches what's on openrouter.ai/models exactly.

**Reviews time out**
Increase the `timeout` value for that reviewer in `~/.claude/debate-acpx.json`. Large models (DeepSeek R1, Gemini 2.5 Pro) often need 240-300s. The parallel runner automatically sets `MAX_WAIT = max(timeout) + 60s`.

**`timeout: command not found` warning**
Install GNU coreutils: `brew install coreutils` (macOS). Reviews still run without it — the per-reviewer hard kill just won't be enforced.

---

## Migrating from v1.x

If you're upgrading from v1.x (CLI mode, LiteLLM, or OpenRouter), see **[MIGRATING.md](MIGRATING.md)** for:
- Which commands were removed and what replaces them
- How to convert `debate-litellm.json` and `debate-openrouter.json` to the new format
- Which `settings.json` permission patterns to remove and add

The `/debate:setup` command also detects v1.x configs automatically and offers to migrate them.

---

## Security

- Plan content is passed via **file path** — never inlined in shell strings
- AI output (reviews, summaries) is written to temp files — never interpolated into shell commands
- acpx is invoked with `--approve-reads` — agents can read your codebase for context but cannot write files
- Work directories in `.tmp/ai-review-*` are deleted at the end of each review session
- OpenRouter API keys live in `~/.acpx/agents/<name>/.opencode.json` with `chmod 600`

---

## Changelog

See **[CHANGELOG.md](CHANGELOG.md)** for release history.

---

## License

MIT

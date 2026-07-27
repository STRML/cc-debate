# Migrating to debate v2.0.0

v2.0.0 replaces all provider-specific CLIs (codex, gemini, claude) and API-based providers (LiteLLM, OpenRouter) with a single unified approach via [acpx](https://github.com/openclaw/acpx).

## What changed

### Removed commands

| Old command | Replacement |
|-------------|-------------|
| `/debate:codex-review` | `/debate:all codex` |
| `/debate:gemini-review` | `/debate:all gemini` |
| `/debate:litellm-review` | `/debate:all` |
| `/debate:openrouter-review` | `/debate:all` |
| `/debate:litellm-setup` | `/debate:acpx-setup` |
| `/debate:openrouter-setup` | `/debate:acpx-setup` |

### Kept commands (updated)

| Command | What changed |
|---------|-------------|
| `/debate:all` | Now config-driven via `debate-acpx.json`. Shell mode removed. No more persona fallback. |
| `/debate:opus-review` | Renamed to `/debate:claude-review`. Now uses Agent tool (context fork) instead of Team/acpx. Supports model selection (opus/sonnet). |
| `/debate:opus-review-subagent` | Merged into `/debate:claude-review`. |
| `/debate:setup` | Simplified — checks for `acpx` and `jq` only. |

### New commands

| Command | Purpose |
|---------|---------|
| `/debate:acpx-setup` | Interactive config creation + agent probing |
| `/debate:claude-double-review` | Two Claude reviewers (Skeptic + Architect) in parallel |
| `/debate:claude-custom-review` | Interactive personality + model picker |

### Other changes

- Work directory moved from `.claude/tmp/ai-review-*` to `.tmp/ai-review-*`
- `reviewers/` directory removed — personas are now in `debate-acpx.json` config
- `shell-mode` argument removed from `/debate:all`
- Version bumped to 2.0.0

## New dependency: acpx

```bash
npm install -g acpx@latest
```

acpx is a headless CLI that communicates with coding agents via the Agent Client Protocol. It replaces direct CLI invocations (codex, gemini, claude) and API-based calls (curl to LiteLLM/OpenRouter).

The underlying agent CLIs (codex, gemini, etc.) still need to be installed — acpx communicates with them, it doesn't replace them.

## Migrating your config

### From LiteLLM (`~/.claude/debate-litellm.json`)

**Before:**
```json
{
  "base_url": "http://localhost:8200/v1",
  "api_key_env": "LITELLM_API_KEY",
  "reviewers": {
    "opus": {
      "model": "claude-opus-4-6",
      "timeout": 300,
      "system_prompt": "You are The Skeptic..."
    },
    "deepseek": {
      "model": "deepseek.v3-v1:0",
      "timeout": 120,
      "system_prompt": "You are The Pragmatist..."
    }
  }
}
```

**After** (`~/.claude/debate-acpx.json`):

LiteLLM routed API calls to arbitrary models. With acpx, each reviewer maps to an **agent** (a coding CLI), not a model. If you were using LiteLLM to access models that have a corresponding acpx agent, map them directly:

```json
{
  "reviewers": {
    "opus": {
      "agent": "claude",
      "timeout": 300,
      "system_prompt": "You are The Skeptic..."
    },
    "codex": {
      "agent": "codex",
      "timeout": 120,
      "system_prompt": "You are The Pragmatist..."
    }
  }
}
```

If you were using LiteLLM to access models that **don't** have a native acpx agent (e.g., DeepSeek, local models via Ollama, Mixtral), you can still access them through your LiteLLM proxy using the **opencode + LiteLLM** bridge. The chain is:

```
acpx → opencode (custom agent) → LiteLLM proxy → your model
```

**Important:** opencode resolves model IDs against its built-in OpenAI model list. The model alias you configure must be a known OpenAI model name (e.g., `gpt-4o-mini`). Configure LiteLLM to route that alias to your actual model:

```yaml
# LiteLLM config.yaml
model_list:
  - model_name: gpt-4o-mini         # alias opencode uses
    litellm_params:
      model: deepseek/deepseek-r1   # your actual model
```

Then create the acpx wrapper:

```bash
bash ~/.claude/debate-scripts/create-litellm-agent.sh \
  deepseek \
  http://localhost:8200/v1 \
  gpt-4o-mini \
  sk-litellm-optional-key
```

Or run `/debate:acpx-setup` to configure it interactively.

See [Using LiteLLM models via opencode](#using-litellm-models-via-opencode) below.

### From OpenRouter (`~/.claude/debate-openrouter.json`)

Same approach as LiteLLM — map each reviewer to the corresponding acpx agent:

**Before:**
```json
{
  "base_url": "https://openrouter.ai/api/v1",
  "api_key_env": "OPENROUTER_API_KEY",
  "headers": { "HTTP-Referer": "...", "X-Title": "cc-debate" },
  "reviewers": {
    "gpt": { "model": "openai/gpt-5.4-pro", "timeout": 300 },
    "gemini": { "model": "google/gemini-2.5-pro", "timeout": 240 }
  }
}
```

**After:**
```json
{
  "reviewers": {
    "codex": { "agent": "codex", "timeout": 300 },
    "antigravity": { "agent": "antigravity", "timeout": 240 }
  }
}
```

No more `base_url`, `api_key`, or `headers` — acpx handles auth per-agent.

### From CLI mode (codex/gemini/opus direct)

If you were using `/debate:all` in CLI mode, the migration is just creating the config file. The old system auto-detected installed CLIs; the new system requires explicit configuration:

```bash
/debate:acpx-setup
```

This will walk you through selecting agents and creating `~/.claude/debate-acpx.json`.

## Migrating your settings.json

If you have permission allowlists in `~/.claude/settings.json`, update them:

**Remove** (old patterns):
```json
"Bash(bash ~/.claude/debate-scripts/run-parallel.sh:*)",
"Bash(bash ~/.claude/debate-scripts/invoke-codex.sh:*)",
"Bash(bash ~/.claude/debate-scripts/invoke-gemini.sh:*)",
"Bash(bash ~/.claude/debate-scripts/invoke-opus.sh:*)",
"Bash(bash ~/.claude/debate-scripts/invoke-openai-compat.sh:*)",
"Bash(bash ~/.claude/debate-scripts/run-parallel-openai-compat.sh:*)",
"Read(.claude/tmp/ai-review*)",
"Edit(.claude/tmp/ai-review*)",
"Write(.claude/tmp/ai-review*)",
"Bash(rm -rf .claude/tmp/ai-review-:*)"
```

**Add** (new patterns):
```json
"Bash(bash ~/.claude/debate-scripts/run-parallel-acpx.sh:*)",
"Bash(bash ~/.claude/debate-scripts/invoke-acpx.sh:*)",
"Read(.tmp/ai-review*)",
"Edit(.tmp/ai-review*)",
"Write(.tmp/ai-review*)",
"Bash(rm -rf .tmp/ai-review-:*)"
```

Run `/debate:setup` to get the complete updated allowlist.

## Refreshing the symlink

A `SessionStart` hook re-runs `create-links.sh` at the start of every session, so `~/.claude/debate-scripts` follows plugin updates on its own — after an update it already points at the new scripts (`invoke-acpx.sh`, `run-parallel-acpx.sh`). Re-run `/debate:setup` only if `/debate:acpx-setup` reports the link as `not found` or `not a symlink`, which means the hook could not create it.

## Available acpx agents

| Agent | Wraps | Install |
|-------|-------|---------|
| `codex` | OpenAI Codex CLI | `npm install -g @openai/codex` |
| `claude` | Claude Code | Already installed — nested-session guard handled automatically |
| `antigravity` | Google Gemini via Antigravity CLI (`agy`, direct — not acpx) | Install the [Antigravity CLI](https://antigravity.google) + run `agy` to sign in |
| `cursor` | Cursor CLI | Install Cursor IDE |
| `copilot` | GitHub Copilot CLI | `gh extension install github/gh-copilot` |
| `kimi` | Kimi CLI | See kimi docs |
| `kiro` | Kiro CLI | See kiro docs |
| `qwen` | Qwen Code | See qwen docs |
| `opencode` | OpenCode | `npx opencode-ai` |
| `kilocode` | Kilocode | `npx @kilocode/cli` |

See [acpx docs](https://github.com/openclaw/acpx) for the full and up-to-date list.

## Using LiteLLM models via opencode

Models accessible via a LiteLLM proxy (local models, self-hosted, or any provider LiteLLM supports) can be used through opencode as the ACP bridge:

```text
acpx → opencode (custom agent) → LiteLLM proxy → any model
```

**Model alias requirement:**

opencode resolves model IDs against its built-in OpenAI list. Use a known OpenAI model name as the alias (e.g., `gpt-4o-mini`) and configure LiteLLM to route it to your actual model:

```yaml
# LiteLLM config.yaml
model_list:
  - model_name: gpt-4o-mini
    litellm_params:
      model: ollama/deepseek-r1
      api_base: http://localhost:11434
```

**Setup:**

1. Install opencode: `npm install -g opencode-ai`
2. Run `bash ~/.claude/debate-scripts/create-litellm-agent.sh <name> <base_url> <model_alias> [api_key]`
3. Add to `~/.claude/debate-acpx.json`:
   ```json
   "<name>": {
     "agent": "<name>",
     "timeout": 120,
     "model_id": "<description> via LiteLLM"
   }
   ```

**Or run `/debate:acpx-setup`** which walks through this interactively.

---

## Using OpenRouter models via opencode

Models that don't have a native acpx agent (DeepSeek, Mercury, Kimi via Moonshot, Mixtral, etc.) can be accessed through OpenRouter using opencode as the ACP bridge:

```text
acpx → opencode (custom agent) → OpenRouter API → any model
```

**Setup for each model:**

1. Install opencode (see [opencode.ai](https://opencode.ai))
2. Create a wrapper directory: `mkdir -p ~/.acpx/agents/<name>`
3. Write `~/.acpx/agents/<name>/.opencode.json`:
   ```json
   {
     "provider": {
       "openrouter": { "apiKey": "sk-or-v1-..." }
     },
     "agents": {
       "coder": { "model": "openrouter/<model-id>" }
     }
   }
   ```
4. Write `~/.acpx/agents/<name>/start.sh`:
   ```bash
   #!/bin/bash
   export OPENCODE_CONFIG_CONTENT='{"model":"openrouter/<model-id>"}'
   exec opencode acp "$@"
   ```
5. `chmod +x ~/.acpx/agents/<name>/start.sh && chmod 600 ~/.acpx/agents/<name>/.opencode.json`
6. Register in `~/.acpx/config.json`:
   ```json
   { "agents": { "<name>": { "command": "/absolute/path/.acpx/agents/<name>/start.sh" } } }
   ```
7. Add to `~/.claude/debate-acpx.json`:
   ```json
   "<name>": { "agent": "<name>", "timeout": 120 }
   ```

**Or run `/debate:acpx-setup`** which automates this entire process interactively.

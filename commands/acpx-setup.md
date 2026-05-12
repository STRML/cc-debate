---
description: Check acpx CLI installation, validate debate-acpx.json config, probe each configured agent, and print permission allowlist for unattended operation.
allowed-tools: Bash(bash ~/.claude/debate-scripts/acpx-env-snapshot.sh:*), Bash(which npx:*), Bash(acpx:*), Bash(npx acpx@latest:*), Bash(gemini:*), Bash(bash ~/.claude/debate-scripts/debate-setup.sh:*), Bash(bash ~/.claude/debate-scripts/create-litellm-agent.sh:*), Bash(ls:*), Bash(chmod:*), Bash(mkdir:*), Write(~/.claude/debate-acpx.json), Write(~/.acpx/*), Write(~/.opencode.json)
---

# debate — acpx Setup Check

Verify acpx prerequisites and print everything needed for `/debate:all`.

**Environment snapshot:**
!`bash ~/.claude/debate-scripts/acpx-env-snapshot.sh`

---

## Step 1: Check tools and set ACPX_CMD

Determine the acpx invocation command from the snapshot above:
- If `acpx` is found: set `ACPX_CMD=acpx`
- If `acpx` is not found but `npx` is: set `ACPX_CMD="npx acpx@latest"`
- If neither: stop with error

Report:
```text
## debate — acpx Setup Check

### Tools
  ✅ acpx      found at /path/to/acpx (using: acpx)
  ✅ jq        found at /path/to/jq
  ✅ opencode  found at /path/to/opencode (enables OpenRouter models)
```

If `acpx` is not found but `npx` is:
```text
  ⚠️  acpx not installed globally — using: npx acpx@latest (slower first run)
     Install globally: npm install -g acpx@latest
```

If neither `acpx` nor `npx`:
```text
  ❌ acpx not found. Install: npm install -g acpx@latest
```

Note whether `opencode` is available — it's needed for OpenRouter model access (Step 2c) and LiteLLM proxy access (Step 2d).

Both `acpx` (or `npx`) and `jq` are required. Use `ACPX_CMD` for all subsequent acpx invocations in this command.

## Step 2: Check config file

### If config exists (loaded above)

Show the parsed config:
```text
### Config: ~/.claude/debate-acpx.json
  Reviewers:
    codex    → agent: codex    (built-in, 120s timeout)
    gemini   → agent: gemini   (built-in, 240s timeout)
    mercury  → agent: mercury  (custom/opencode, 120s timeout)
```

Proceed to Step 3.

### If config is missing — Interactive Setup

Guide the user through creating a config.

**2a. Ask what agents the user wants:**

Present three categories:

```text
### Reviewer options

Built-in acpx agents (need the agent CLI installed):
  codex    — OpenAI Codex        (npm install -g @openai/codex)
  gemini   — Google Gemini       (npm install -g @google/gemini-cli) ⚠️  needs GEMINI_API_KEY for acpx
  cursor   — Cursor CLI          (install Cursor IDE)
  copilot  — GitHub Copilot CLI  (gh extension install github/gh-copilot)
  kimi     — Kimi CLI
  kiro     — Kiro CLI
  qwen     — Qwen Code
  opencode — OpenCode            (npm install -g opencode-ai)

  claude   — Claude Code         (already installed) ⚠️  requires CLAUDECODE to be
             unset — invoke-acpx.sh handles this automatically
  opus     — Claude Opus 4.6    (already installed) direct CLI invocation, bypasses
             acpx entirely — runs `claude --print --model claude-opus-4-6` via stdin

OpenRouter models via opencode (need opencode + OpenRouter API key):
  Any model on OpenRouter — DeepSeek, Mercury, Kimi, Mixtral, GPT, etc.
  These run through: acpx → opencode → OpenRouter → model

LiteLLM proxy via opencode (need opencode + a running LiteLLM proxy):
  Any model accessible via your LiteLLM proxy — local models (Ollama, LM Studio),
  self-hosted, or any provider LiteLLM supports.
  These run through: acpx → opencode → LiteLLM proxy → model
```

"Pick 2-4 reviewers. For independent perspectives inside Claude, skip the `claude` agent. If you want models from OpenRouter or via LiteLLM, I'll set those up via opencode."

**2b. For each selected reviewer, determine the type:**
- If the user picks a built-in acpx agent name → type: `built-in`
- If the user picks an OpenRouter model (or a model name that isn't a built-in agent) → type: `openrouter`
- If the user picks a LiteLLM-routed model → type: `litellm`

**2c. For OpenRouter reviewers — set up opencode wrappers:**

This requires `opencode` to be installed. If not found:
```text
  ❌ opencode not installed. OpenRouter models require it.
     Install: npm install -g opencode-ai
     Then re-run /debate:acpx-setup
```

For each OpenRouter reviewer, ask for:
1. A short name (e.g., `mercury`, `deepseek`)
2. The OpenRouter model ID (e.g., `inception/mercury-2`, `deepseek/deepseek-r1`)

Then ask for the user's OpenRouter API key (or check if `OPENROUTER_API_KEY` env var is set).

For each OpenRouter reviewer, create a wrapper script and per-agent opencode config:

```bash
mkdir -p ~/.acpx/agents/<name>
```

Write `~/.acpx/agents/<name>/.opencode.json`:
```json
{
  "provider": {
    "openrouter": {
      "apiKey": "<OPENROUTER_API_KEY>"
    }
  },
  "agents": {
    "coder": {
      "model": "openrouter/<model_id>"
    }
  }
}
```

Write `~/.acpx/agents/<name>/start.sh`:
```bash
#!/bin/bash
export OPENCODE_CONFIG_CONTENT='{"model":"openrouter/<model_id>"}'
exec opencode acp "$@"
```

```bash
chmod +x ~/.acpx/agents/<name>/start.sh
chmod 600 ~/.acpx/agents/<name>/.opencode.json
```

Register the custom agent in `~/.acpx/config.json`. Read the existing config first, merge the new agent, and write back:
```json
{
  "agents": {
    "<name>": {
      "command": "/Users/<user>/.acpx/agents/<name>/start.sh"
    }
  }
}
```

Use absolute paths in the command field — acpx exec's the command directly.

**2d. For LiteLLM reviewers — set up opencode wrappers:**

This requires `opencode` to be installed (same check as Step 2c above).

For each LiteLLM reviewer, ask for:
1. A short name (e.g., `deepseek`, `local-llama`, `mixtral`)
2. The LiteLLM proxy base URL (default: `http://localhost:8200/v1`)
3. A model alias — an OpenAI model name that opencode recognizes (default: `gpt-4o-mini`). LiteLLM must be configured to route this alias to your actual model.
4. An API key (optional — leave blank or say "none" if your proxy doesn't require one)

Explain the alias requirement:
```text
  LiteLLM works by aliasing model names. opencode needs to look up the model in its
  built-in list, so the alias must be a known OpenAI model name (gpt-4o-mini is a
  safe default). Configure LiteLLM to route that alias to your actual model:

  # Example LiteLLM config.yaml
  model_list:
    - model_name: gpt-4o-mini       ← alias opencode will use
      litellm_params:
        model: ollama/deepseek-r1   ← your actual model
        api_base: http://localhost:11434
```

Run the helper script to create the wrapper:

```bash
bash ~/.claude/debate-scripts/create-litellm-agent.sh "<name>" "<base_url>" "<model_alias>" "<api_key>"
```

This creates `~/.acpx/agents/<name>/start.sh` and registers the agent in `~/.acpx/config.json`.

**2e. Write the debate config:**

Write `~/.claude/debate-acpx.json` with all selected reviewers. For OpenRouter reviewers, include a `model_id` field so the summary and future setup checks can display the underlying model:

```json
{
  "reviewers": {
    "codex": { "agent": "codex", "timeout": 120, "system_prompt": "..." },
    "mercury": { "agent": "mercury", "timeout": 120, "model_id": "inception/mercury-2", "system_prompt": "..." }
  }
}
```

Built-in agents do not need `model_id`. OpenRouter agents (created via Step 2c) must have it set to the OpenRouter model ID (e.g., `inception/mercury-2`). LiteLLM agents (created via Step 2d) should set it to a descriptive string like `"deepseek-r1 via LiteLLM"` so the summary can display the underlying model.

Set timeout to 240-300 for larger/slower agents, 120 for faster ones.

For system prompts, suggest unique review personas for each reviewer. Examples:
- **The Executor** — shell correctness, exit codes, race conditions, file I/O
- **The Architect** — structural integrity, over-engineering, missing phases, graceful degradation
- **The Skeptic** — unstated assumptions, unhappy paths, second-order failures, security
- **The Contrarian** — questions conventional wisdom, hidden assumptions, scaling bottlenecks
- **The Pragmatist** — what will actually ship, unnecessary complexity, missing happy path steps

---

## Step 3: Probe each agent

For each configured reviewer:

- **Non-gemini, non-opus agents:** ensure a session exists and run a quick test via acpx:
  ```bash
  $ACPX_CMD <agent> sessions ensure 2>&1
  echo "Reply with only the word PONG." | $ACPX_CMD --format quiet --approve-reads <agent>
  ```
- **gemini agent:** probe using direct CLI (see below — ACP mode is broken):
  ```bash
  echo "Reply with only the word PONG." | timeout 5 gemini -s -e ""
  ```
- **opus agent:** probe using direct Claude CLI:
  ```bash
  echo "Reply with only the word PONG." | timeout 30 claude --print --model claude-opus-4-6
  ```

Report:
- Response contains "PONG" → `✅ <name>: <agent> responds`
- Session creation fails or probe times out → `❌ <name>: <agent> failed`

### Gemini agent — direct CLI invocation

The `gemini` agent uses the Gemini CLI directly (not via acpx ACP mode). Gemini CLI's ACP mode hangs indefinitely at the initialize handshake and is not usable. Direct CLI invocation works with both OAuth and API key auth.

**Probe command for gemini:**
```bash
echo "Reply with only the word PONG." | timeout 5 gemini -s -e ""
```
(Use `gtimeout` if `timeout` is not available on macOS.)

- Response contains "PONG" → `✅ gemini: CLI responds`
- Command not found → `❌ gemini: CLI not installed — npm install -g @google/gemini-cli`
- Auth error → see below

**If auth fails:**

Common auth errors come from wrong `selectedType` in `~/.gemini/settings.json`. Valid values:
- `"oauth-personal"` — browser OAuth (default, works for direct CLI)
- `"gemini-api-key"` — uses `GEMINI_API_KEY` env var (required if no browser access)
- `"vertex-ai"` — Google Cloud Vertex AI

`"api-key"` is NOT valid and causes "Invalid auth method selected".

If the user needs API key auth (e.g., headless environment):

```text
  Fix: get a free Gemini API key:

  1. Visit: https://aistudio.google.com/apikey
  2. Click "Create API key" → copy the key (starts with "AIza...")
  3. Set auth type in ~/.gemini/settings.json:
       { "selectedType": "gemini-api-key" }
  4. Add to ~/.claude/settings.json:
       { "env": { "GEMINI_API_KEY": "AIza..." } }
  5. Restart Claude Code, then re-run /debate:acpx-setup to verify.
```

Ask the user if they want to set up the API key now. If yes:
1. Ask them to paste the key
2. Read `~/.claude/settings.json`, add or merge `"env": { "GEMINI_API_KEY": "<key>" }`, write back
3. Read `~/.gemini/settings.json`, set `"selectedType": "gemini-api-key"`, write back
4. Inform them to restart Claude Code for the env var to take effect

### Other agent failure modes

For OpenRouter agents (custom opencode-based agents): a common failure is wrong model ID. Suggest verifying the model ID at openrouter.ai/models.

For custom agents with no acpx session: try `$ACPX_CMD <agent> sessions ensure` first.

## Step 4: Check debate-scripts symlink

From the snapshot: `debate-scripts: symlinked` → ✅ ready; `not found` → ❌ run `/debate:setup`.

## Step 5: Print permission allowlist

```text
### Permission Allowlist

To run /debate:all without approval prompts, add to ~/.claude/settings.json:
```

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
      "Write(.tmp/ai-review*)",
      "Write(~/.acpx/**)",
      "Read(~/.acpx/**)"
    ]
  }
}
```

**The `~/.acpx/**` entries are mandatory.** acpx writes a queue lock to
`~/.acpx/queues/<id>.lock` on every invocation. Without these allowlist
entries, reviewer subprocesses exit 144 — and because they're spawned via
`nohup`/`disown`, the sandbox-blocked-write error never surfaces as a prompt;
`/debate:all` just reports "all reviewers failed" with no obvious cause.

## Step 6: Print summary

For each reviewer from the config loaded above — built-in agents show `built-in`; OpenRouter agents show `openrouter — openrouter/<model_id>`; LiteLLM agents show `litellm — <model_id>`.

```text
### Summary

  acpx:     ✅ ready
  opencode: ✅ ready (enables OpenRouter and LiteLLM models)
  Config:   ✅ valid (N reviewers)
  jq:       ✅ ready
  Scripts:  ✅ symlinked

  Reviewers:
    codex    ✅ built-in    (120s timeout)
    gemini   ✅ built-in    (240s timeout)
    mercury  ✅ openrouter  (120s timeout) — openrouter/inception/mercury-2
    deepseek ✅ litellm     (120s timeout) — deepseek-r1 via LiteLLM

You are ready to run:
  /debate:all                     — parallel review via acpx
  /debate:all codex,mercury       — specific reviewers only
```

If anything is missing, list remaining actions.

---
description: Check acpx CLI installation, validate debate-acpx.json config, probe each configured agent, and print permission allowlist for unattended operation.
allowed-tools: Bash(bash ~/.claude/debate-scripts/acpx-env-snapshot.sh:*), Bash(which npx:*), Bash(acpx:*), Bash(npx acpx@latest:*), Bash(agy:*), Bash(agy models:*), Bash(which agy:*), Bash(bash ~/.claude/debate-scripts/debate-setup.sh:*), Bash(bash ~/.claude/debate-scripts/create-litellm-agent.sh:*), Bash(ls:*), Bash(chmod:*), Bash(mkdir:*), Bash(jq:*), Bash(cp:*), Write(~/.claude/debate-acpx.json), Write(~/.acpx/*), Write(~/.acpx/**), Read(~/.acpx/**), Edit(~/.acpx/**), Write(~/.opencode.json), Read(~/.claude/settings.json), Edit(~/.claude/settings.json), Write(~/.claude/settings.json)
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
    codex        → agent: codex        (built-in, 120s timeout)
    antigravity  → agent: antigravity  (direct CLI, 240s timeout)
    mercury      → agent: mercury      (custom/opencode, 120s timeout)
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
  cursor   — Cursor CLI          (install Cursor IDE)
  copilot  — GitHub Copilot CLI  (gh extension install github/gh-copilot)
  kimi     — Kimi CLI
  kiro     — Kiro CLI
  qwen     — Qwen Code
  opencode — OpenCode            (npm install -g opencode-ai)

Direct-CLI agents (no acpx ACP support — invoke-acpx.sh calls them directly):
  antigravity — Google Gemini via Antigravity CLI (install https://antigravity.google,
             run `agy` once to sign in) — runs `agy -p` under a Python PTY
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
  "claude_reviewers": {
    "skeptic": ["fable", "opus"],
    "simplifier": "opus",
    "operator": "sonnet",
    "pentester": "auto",
    "~/personas/data-modeler.md": "opus"
  },
  "reviewers": {
    "codex": { "agent": "codex", "timeout": 120, "system_prompt": "..." },
    "mercury": { "agent": "mercury", "timeout": 120, "model_id": "inception/mercury-2", "system_prompt": "..." }
  }
}
```

**Claude persona reviewers (`claude_reviewers`) — CALL THIS OUT to the user.** An
optional top-level object that is the entire Claude side of the panel (skeptic +
personas), alongside the acpx CLI reviewers. It maps **persona key → model spec**, and
it is the main way to tailor the Claude side, so explain it during setup rather than
writing it silently.

- **Model spec** — a model or an **array** of models. Each model is `false` (off) ·
  `"opus"` · `"sonnet"` · `"fable"` · `"auto"`. `"auto"` spawns the persona **only when
  the plan is in its domain** (discretion), using its default model; an array spawns one
  teammate per model. `"fable"` falls back to `"opus"` if fable is deactivated.
- **Skeptic** — `skeptic` is a built-in key, model-tuned: `"fable"` → Fable Skeptic,
  `"opus"` → Opus Skeptic, `"sonnet"` → Solo Skeptic. Ask the user (AskUserQuestion)
  whether they want the **tuned pair** `["fable","opus"]` (Fable finds more high-impact
  behavioral issues but costs ~2x Opus) or a solo `"opus"`. This replaces the old
  `fable_reviewer` flag.
- **Other built-in keys** — `simplifier` (accidental complexity / YAGNI, default opus),
  `operator` (reliability / failure modes / 3 AM, default sonnet), `pentester`
  (security / attack surface, default opus). Bodies live in `reviewer-prompts.md`.
- **Custom personas** — any key that isn't a built-in name is treated as a **path to
  your own persona file**; its contents become the reviewer body verbatim. Tell
  the user they can drop a `You are The <Name> …` file anywhere and point a key at it
  (e.g. `"~/personas/data-modeler.md": "opus"`). `"auto"` works for custom personas too
  — the orchestrator reads the body and judges relevance.
- **Pentester guard** — `pentester` **never** runs on `sonnet` (weak at adversarial
  security reasoning → coerced to `opus` with a warning); valid values `"opus"`,
  `"fable"`, `"auto"`, `false`. Recommend `"auto"` as the default so security-relevant
  plans always get a security lens without noise on routine changes. (The guard applies
  only to the built-in `pentester`; custom personas may use `sonnet`.)

If the file already has the `claude_reviewers` key, keep it and skip the question.

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

- **Non-antigravity, non-opus agents:** ensure a session exists and run a quick test via acpx:
  ```bash
  $ACPX_CMD <agent> sessions ensure 2>&1
  echo "Reply with only the word PONG." | $ACPX_CMD --format quiet --approve-reads <agent>
  ```
- **antigravity agent:** probe using the Antigravity CLI directly (see below):
  ```bash
  agy models 2>&1 | head -1
  ```
- **opus agent:** probe using direct Claude CLI:
  ```bash
  echo "Reply with only the word PONG." | timeout 30 claude --print --model claude-opus-4-6
  ```

Report:
- Response contains "PONG" (or `agy models` lists a model) → `✅ <name>: <agent> responds`
- Session creation fails or probe times out → `❌ <name>: <agent> failed`

### Antigravity agent — direct CLI invocation

The `antigravity` agent uses the Antigravity CLI (`agy`) directly — acpx has no native ACP support for it yet. `invoke-acpx.sh` runs `agy -p "<plan>" --sandbox` under a Python PTY (the `agy -p` output drops when stdout is not a TTY) with the prompt passed as a positional argument. Works with OAuth (run `agy` once to sign in) or `ANTIGRAVITY_API_KEY` / `GEMINI_API_KEY`.

**Probe command for antigravity** (lists models only when signed in):
```bash
agy models 2>&1 | head -1
```

- Lists a model name → `✅ antigravity: agy responds`
- "Please sign in to view available models" → `❌ antigravity: not signed in — run 'agy' once to sign in`
- Command not found → `❌ antigravity: agy not installed — install the Antigravity CLI (https://antigravity.google)`
- `python3` missing → `❌ antigravity: python3 required (agy is run under a PTY)`

**If not signed in:**

```text
  Fix: sign in to the Antigravity CLI:

  1. Run `agy` (with no arguments) in a terminal
  2. Follow the browser OAuth flow, or paste the authorization code shown
  3. Re-run /debate:acpx-setup to verify.

  Headless / no browser? Set an API key instead:
  4. Add to ~/.claude/settings.json:
       { "env": { "ANTIGRAVITY_API_KEY": "..." } }
  5. Restart Claude Code, then re-run /debate:acpx-setup.
```

Ask the user if they want to set up an API key now (headless only). If yes:
1. Ask them to paste the key
2. Read `~/.claude/settings.json`, add or merge `"env": { "ANTIGRAVITY_API_KEY": "<key>" }`, write back
3. Inform them to restart Claude Code for the env var to take effect

### Other agent failure modes

For OpenRouter agents (custom opencode-based agents): a common failure is wrong model ID. Suggest verifying the model ID at openrouter.ai/models.

For custom agents with no acpx session: try `$ACPX_CMD <agent> sessions ensure` first.

## Step 4: Check debate-scripts symlink

From the snapshot: `debate-scripts: symlinked` → ✅ ready; `not found` → ❌ run `/debate:setup`.

## Step 5: Patch permission allowlist in ~/.claude/settings.json

**DO NOT just print the snippet.** Actively patch `~/.claude/settings.json`
following the same procedure as `/debate:setup` Step 7 — read, diff, back up,
Edit-in-place the missing entries, re-validate with `jq empty`. See Step 7
of `/debate:setup` for the full procedure (backup file, JSON-parse guard,
restore-on-failure path). Required entries for unattended `/debate:all`:

```
Bash(bash ~/.claude/debate-scripts/debate-setup.sh:*)
Bash(bash ~/.claude/debate-scripts/run-parallel-acpx.sh:*)
Bash(bash ~/.claude/debate-scripts/invoke-acpx.sh:*)
Bash(rm -rf .tmp/ai-review-:*)
Read(.tmp/ai-review*)
Edit(.tmp/ai-review*)
Write(.tmp/ai-review*)
Write(~/.acpx/**)
Read(~/.acpx/**)
Edit(~/.acpx/**)
```

Plus one **repo-scoped read grant** so review subagents can read this repo's
source at its absolute path without prompting. Compute it for the current repo
and add the exact entry to the required set:

```bash
echo "Read($(git rev-parse --show-toplevel 2>/dev/null || pwd)/**)"
```

Scoped to the repo under review rather than a blanket `Read(**)` — the
secret-path deny rules already protect `.env`/`~/.ssh`/`~/.aws`/`secrets/`, so
this only grants read of repo source and won't auto-approve reads in unrelated
projects. The run commands preflight-check this and warn if it's missing.

Report what was added vs already present. If `~/.claude/settings.json` is
malformed JSON, stop and surface the parse error — do not rewrite a file you
can't parse.

**Why this is active rather than instructional:** acpx writes per-job queue
locks to `~/.acpx/queues/<id>.lock` on every invocation. Without
`Write(~/.acpx/**)` in the settings allowlist, the Claude Code sandbox blocks
those writes and reviewer subprocesses exit 144. Because they're spawned via
`nohup`/`disown`, the sandbox-blocked-write error never surfaces as a prompt;
`/debate:all` just reports "all reviewers failed" with no obvious cause.
Printing the snippet and trusting the user to copy it is how this regression
keeps recurring.

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
    codex        ✅ built-in    (120s timeout)
    antigravity  ✅ direct CLI  (240s timeout)
    mercury      ✅ openrouter  (120s timeout) — openrouter/inception/mercury-2
    deepseek ✅ litellm     (120s timeout) — deepseek-r1 via LiteLLM

You are ready to run:
  /debate:all                     — parallel review via acpx
  /debate:all codex,mercury       — specific reviewers only
```

If anything is missing, list remaining actions.

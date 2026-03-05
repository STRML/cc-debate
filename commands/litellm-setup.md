---
description: Check LiteLLM proxy connectivity, list available models, validate debate-litellm.json config, and print permission allowlist for unattended operation.
allowed-tools: Bash(curl -s:*), Bash(bash ~/.claude/debate-scripts/debate-setup.sh:*), Bash(jq:*), Bash(which:*), Bash(ls:*)
---

# debate — LiteLLM Setup Check

Verify LiteLLM proxy prerequisites and print everything needed for `/debate:litellm-review`.

---

## Step 1: Check tools

```bash
which curl
which jq
```

Report:
```text
## debate — LiteLLM Setup Check

### Tools
  ✅ curl    found at /path/to/curl
  ✅ jq      found at /path/to/jq
```

Both are required. If missing:
- `curl`: should be pre-installed on macOS/Linux
- `jq`: `brew install jq` (macOS) / `apt install jq` (Linux)

## Step 2: Check config file

Read `~/.claude/debate-litellm.json`. Report:

- File exists → show the parsed config:
  ```text
  ### Config: ~/.claude/debate-litellm.json
    Base URL:  http://localhost:8200/v1
    API Key:   [set] / [not set]
    Reviewers: opus (claude-opus-4-6), deepseek (deepseek.v3-v1:0), ...
  ```
- File missing → show how to create it:
  ```text
  ❌ Config not found: ~/.claude/debate-litellm.json

  Create it with this template:
  {
    "base_url": "http://localhost:8200/v1",
    "api_key": "",
    "reviewers": {
      "opus": {
        "model": "claude-opus-4-6",
        "timeout": 300,
        "system_prompt": "You are The Skeptic..."
      }
    }
  }
  ```

## Step 3: Check LiteLLM connectivity

Extract `base_url` from config (default: `http://localhost:8200/v1`). Strip any trailing `/v1` suffix to compute the models URL:

```bash
curl -s <MODELS_URL>
```

Report:
- HTTP 200 with model data → `✅ LiteLLM proxy reachable`
- Connection refused → `❌ LiteLLM not running on <url> — start it first`
- Non-200 → `❌ LiteLLM returned error — check proxy logs`

## Step 4: List available models

Parse the `/models` response and list all model IDs:

```text
### Available Models (via LiteLLM)
  - claude-opus-4-6
  - claude-sonnet-4-6
  - deepseek.v3-v1:0
  - ...
```

## Step 5: Validate reviewer config against available models

For each reviewer in the config, check if its `model` value appears in the `/models` response:

```text
### Reviewer Model Validation
  ✅ opus:     claude-opus-4-6    (available)
  ✅ deepseek: deepseek.v3-v1:0   (available)
  ❌ gemini:   gemini-2.5-pro     (NOT in LiteLLM — check proxy config)
```

## Step 6: Test API call (optional quick probe)

For each configured reviewer, make a minimal chat completion request to verify the model actually responds:

```bash
curl -s --max-time 30 \
  -H "Content-Type: application/json" \
  -d '{"model":"<model>","messages":[{"role":"user","content":"Reply with only the word PONG."}],"max_tokens":10}' \
  http://localhost:8200/v1/chat/completions
```

Report:
- Response contains content → `✅ <name>: <model> responds`
- Error/timeout → `❌ <name>: <model> failed — <error message>`

## Step 7: Check debate-scripts symlink

```bash
ls -la ~/.claude/debate-scripts/invoke-litellm.sh
```

Report:
- Found → `✅ invoke-litellm.sh accessible via debate-scripts symlink`
- Not found → `❌ Run /debate:setup first to create the symlink, then re-check`

## Step 8: Print permission allowlist

```text
### Permission Allowlist

To run /debate:litellm-review without approval prompts, add to ~/.claude/settings.json:
```

```json
{
  "permissions": {
    "allow": [
      "Bash(bash ~/.claude/debate-scripts/debate-setup.sh:*)",
      "Bash(bash ~/.claude/debate-scripts/run-parallel-litellm.sh:*)",
      "Bash(bash ~/.claude/debate-scripts/invoke-litellm.sh:*)",
      "Bash(curl -s:*)",
      "Bash(rm -rf /tmp/claude/ai-review-:*)",
      "Read(/tmp/claude/ai-review*)",
      "Edit(/tmp/claude/ai-review*)",
      "Write(/tmp/claude/ai-review*)"
    ]
  }
}
```

## Step 9: Print summary

```text
### Summary

  LiteLLM:   ✅ reachable (http://localhost:8200)
  Config:    ✅ valid (3 reviewers)
  curl:      ✅ ready
  jq:        ✅ ready
  Scripts:   ✅ symlinked

  Reviewers:
    opus      ✅ claude-opus-4-6     (The Skeptic, 300s timeout)
    deepseek  ✅ deepseek.v3-v1:0    (The Pragmatist, 120s timeout)
    sonnet    ✅ claude-sonnet-4-6   (The Editor, 180s timeout)

You are ready to run:
  /debate:litellm-review          — parallel review via LiteLLM
  /debate:litellm-review opus,deepseek  — specific reviewers only
```

If anything is missing, list remaining actions.

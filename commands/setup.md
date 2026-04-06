---
description: Check debate plugin prerequisites, verify acpx is installed, and print the exact settings.json snippet for fully unattended (no-prompt) operation.
allowed-tools: Bash(which acpx:*), Bash(which npx:*), Bash(which jq:*), Bash(bash ~/.claude/plugins/cache/cc-debate/debate/*/scripts/create-links.sh:*), Bash(ls:*), Bash(cat:*), Write(~/.claude/debate-acpx.json)
---

# debate — Setup & Permission Check

Verify all prerequisites for the debate plugin and print everything needed for fully unattended operation.

---

## Step 1: Check acpx

```bash
which acpx || which npx
```

Report:

```text
## debate — Setup Check

### acpx CLI
  ✅ acpx    found at /path/to/acpx
```

If `acpx` is not found but `npx` is:
```text
  ⚠️  acpx not installed globally — will use npx acpx@latest (slower first run)
     Install globally: npm install -g acpx@latest
```

If neither found:
```text
  ❌ acpx not found. Install: npm install -g acpx@latest
```

## Step 2: Check jq

```bash
which jq
```

Report:
- Found → `✅ jq: found at /path/to/jq`
- Missing → `❌ jq: not found — install: brew install jq (macOS) / apt install jq (Linux)`

## Step 3: Check gemini CLI (if configured)

If `gemini` is not in the user's `~/.claude/debate-acpx.json` config, skip this step silently.

Check whether the `gemini` CLI is installed and responding:
```bash
which gemini 2>/dev/null || echo "not found"
```

Report:
- Found → `✅ gemini CLI: found at /path/to/gemini`
- Not found → `❌ gemini CLI: not found — install: npm install -g @google/gemini-cli`

Note: `/debate:all` invokes `gemini` directly (not via acpx) — Gemini CLI's ACP mode is non-functional. OAuth (default auth) works fine for direct CLI invocation. An API key is only required if running in a headless environment without browser access.

## Step 4: Detect v1.x installation and migrate


Check for old config files from v1.x:

```bash
ls ~/.claude/debate-litellm.json ~/.claude/debate-openrouter.json 2>/dev/null
```

Also check `~/.claude/settings.json` for old permission patterns:

```bash
cat ~/.claude/settings.json 2>/dev/null
```

Look for these old patterns in the settings:
- `invoke-codex`, `invoke-gemini`, `invoke-opus`, `invoke-openai-compat`
- `run-parallel.sh` (without `-acpx`), `run-parallel-openai-compat`
- `.claude/tmp/ai-review` (old work dir path, should be `.tmp/ai-review`)
- `probe-model`

### If old configs found

Report:
```text
### v1.x Installation Detected

  ⚠️  Found old config files:
    ~/.claude/debate-litellm.json
    ~/.claude/debate-openrouter.json
```

**Auto-migrate if `~/.claude/debate-acpx.json` does not exist yet:**

Read each old config and extract reviewer entries. Map `model` fields to acpx agents using this table:

| Old model pattern | acpx agent |
|-------------------|------------|
| `claude-opus-*`, `claude-sonnet-*`, `claude-*` | `claude` |
| `gpt-*`, `o1-*`, `o3-*`, `o4-*` | `codex` |
| `gemini-*` | `gemini` |
| Any other model | Skip with warning — no acpx agent equivalent |

For each mappable reviewer from the old config, create an entry in the new format:
```json
{
  "reviewers": {
    "<old-name>": {
      "agent": "<mapped-agent>",
      "timeout": <old-timeout or 120>,
      "system_prompt": "<old system_prompt if present>"
    }
  }
}
```

Merge reviewers from both old configs (litellm + openrouter), deduplicating by name. If both have a reviewer with the same name, prefer the openrouter entry.

Write the merged config to `~/.claude/debate-acpx.json`.

Report:
```text
  ✅ Migrated N reviewer(s) to ~/.claude/debate-acpx.json:
    opus    → agent: claude   (was model: claude-opus-4-6)
    codex   → agent: codex    (was model: gpt-5.3-codex)

  ⚠️  Skipped N reviewer(s) — no acpx agent equivalent:
    deepseek (model: deepseek.v3-v1:0) — no acpx agent for DeepSeek
```

Tell the user:
```text
  Old config files are still present. You can delete them after verifying:
    rm ~/.claude/debate-litellm.json ~/.claude/debate-openrouter.json
```

**If `~/.claude/debate-acpx.json` already exists**, skip auto-migration and just report:
```text
  ℹ️  Old config files found but ~/.claude/debate-acpx.json already exists — skipping migration.
     Delete old configs when ready:
       rm ~/.claude/debate-litellm.json ~/.claude/debate-openrouter.json
```

### If old settings.json patterns found

Report which patterns are stale and show the replacement:
```text
  ⚠️  Stale permission patterns in ~/.claude/settings.json:
    - "Bash(bash ~/.claude/debate-scripts/invoke-codex.sh:*)"     → remove
    - "Bash(bash ~/.claude/debate-scripts/invoke-gemini.sh:*)"    → remove
    - "Bash(bash ~/.claude/debate-scripts/invoke-opus.sh:*)"      → remove
    - "Bash(bash ~/.claude/debate-scripts/run-parallel.sh:*)"     → remove
    - "Read(.claude/tmp/ai-review*)"                              → "Read(.tmp/ai-review*)"

  Replace with the updated allowlist shown in Step 7 below.
  See MIGRATING.md for the complete migration guide.
```

### If no old installation detected

Skip this step silently — no output needed.

## Step 5: Check debate-acpx.json config

Read `~/.claude/debate-acpx.json`. Report:

- File exists → show reviewer list:
  ```text
  ### Config: ~/.claude/debate-acpx.json
    Reviewers:
      codex   → agent: codex    (120s timeout)
      gemini  → agent: gemini   (240s timeout)
  ```
- File missing → suggest running `/debate:acpx-setup` to create it interactively

## Step 6: Create stable scripts symlink

Create `~/.claude/debate-scripts` pointing to the installed version's scripts directory.
This symlink lets the main debate commands invoke scripts without version interpolation.

```bash
bash ~/.claude/plugins/cache/cc-debate/debate/*/scripts/create-links.sh
```

Report:
- Exit 0 → `✅ ~/.claude/debate-scripts created`
- Exit 1 (sandbox error) → show the exact `ln -sfn` command from the script output and tell the user to run it from their regular terminal (outside Claude Code), since the Claude Code sandbox restricts writes to `~/.claude/`

Note: Re-run `/debate:setup` after updating the plugin to refresh this symlink.

## Step 7: Print permission allowlist

Print the complete list of Bash tool patterns needed for fully unattended operation (no approval prompts):

```text
### Permission Allowlist

To run /debate:all and /debate:claude-review without any approval prompts,
add the following to ~/.claude/settings.json:
```

```json
{
  "permissions": {
    "allow": [
      "Bash(bash ~/.claude/debate-scripts/debate-setup.sh:*)",
      "Bash(bash ~/.claude/debate-scripts/run-parallel-acpx.sh:*)",
      "Bash(bash ~/.claude/debate-scripts/invoke-acpx.sh:*)",
      "Bash(which acpx:*)",
      "Bash(which jq:*)",
      "Read(.tmp/ai-review*)",
      "Edit(.tmp/ai-review*)",
      "Write(.tmp/ai-review*)",
      "Bash(rm -rf .tmp/ai-review-:*)"
    ]
  }
}
```

```text
NOTE: These patterns are already declared in the allowed-tools frontmatter of
each command, so each individual session will prompt once and remember within
that session. Adding to settings.json makes approval permanent across all sessions.
```

## Step 8: Print final status

```text
### Summary

  acpx:    ✅ ready
  jq:      ✅ ready (/opt/homebrew/bin/jq)
  Config:  ✅ valid (N reviewers)
  Scripts: ✅ symlinked

You are ready to run:
  /debate:all            — parallel review with synthesis and debate
  /debate:all codex      — single-reviewer via acpx
  /debate:claude-review  — Claude review (default: Skeptic, Opus)
  /debate:claude-double-review — two reviewers (Skeptic + Architect)
  /debate:claude-custom-review — interactive personality + model picker
  /debate:acpx-setup     — configure reviewers
```

If anything is missing, list the remaining actions the user needs to take before the plugin will work correctly.

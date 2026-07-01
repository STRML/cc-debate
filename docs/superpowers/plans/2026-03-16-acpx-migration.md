# Migrate to acpx — Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace all CLI-based (codex, gemini, claude) and API-based (litellm, openrouter) reviewer invocations with a single `acpx`-based approach.

**Architecture:** All reviewers are invoked via `acpx --format quiet --approve-reads <agent> --file <prompt>`. A single `invoke-acpx.sh` script handles prompt assembly, invocation, and output capture. Config-driven via `~/.claude/debate-acpx.json` — no more base_url/api_key management; acpx handles auth per-agent.

**Tech Stack:** acpx CLI (`npm install -g acpx@latest`), bash, jq

**Unchanged files:**
- `commands/opus-review-subagent.md` — uses Claude's built-in Task tool, no external process. No changes needed.
- `scripts/debate-setup.sh` — generates REVIEW_ID/WORK_DIR. No changes needed; `config.env` is no longer written by callers.

---

## Chunk 1: Core Scripts

### Task 1: Create `invoke-acpx.sh`

**Files:**
- Create: `scripts/invoke-acpx.sh`

This script replaces `invoke-codex.sh`, `invoke-gemini.sh`, `invoke-opus.sh`, and `invoke-openai-compat.sh`. It reads agent config from a JSON config file and invokes the reviewer via `acpx`.

- [ ] **Step 1: Write `invoke-acpx.sh`**

```bash
#!/bin/bash
# Generic reviewer invocation via acpx CLI.
# Replaces invoke-codex.sh, invoke-gemini.sh, invoke-opus.sh, invoke-openai-compat.sh.
#
# Usage: invoke-acpx.sh <config_file> <work_dir> <reviewer_name> [timeout]
#   config_file   — path to JSON config (e.g. ~/.claude/debate-acpx.json)
#   work_dir      — temp directory (must contain plan.md)
#   reviewer_name — e.g. "codex", "gemini", "kimi"
#   timeout       — optional override; falls back to config value, then 120s
#
# Config schema:
#   {
#     "reviewers": {
#       "<name>": {
#         "agent": "codex",
#         "timeout": 120,
#         "system_prompt": "You are The Executor..."
#       }
#     }
#   }
#
# Prompt resolution (in order):
#   1. $work_dir/<name>-prompt.txt  (debate/revision rounds write this)
#   2. reviewers.<name>.system_prompt from config + plan.md
#   3. Built-in fallback: generic plan reviewer + plan.md
#
# Output files (all written to $work_dir):
#   <name>-output.md   review text
#   <name>-stderr.log  acpx stderr (for debugging)
#   <name>-exit.txt    exit code (0=success, 124=timeout, 1=error)

set -euo pipefail

CONFIG_FILE="${1:-}"
WORK_DIR="${2:-}"
REVIEWER="${3:-}"
TIMEOUT_ARG="${4:-}"

if [ -z "$CONFIG_FILE" ] || [ -z "$WORK_DIR" ] || [ -z "$REVIEWER" ]; then
  echo "Usage: $0 <config_file> <work_dir> <reviewer_name> [timeout]" >&2
  exit 1
fi

# --- Trap: ensure exit file is always written ---

create_exit_file() {
  local code="${1:-1}"
  local reason="${2:-unknown error}"
  if [ -n "$WORK_DIR" ] && [ -n "$REVIEWER" ]; then
    echo "$code" > "$WORK_DIR/${REVIEWER}-exit.txt"
    if [ ! -f "$WORK_DIR/${REVIEWER}-output.md" ]; then
      echo "invoke-acpx: $reason" > "$WORK_DIR/${REVIEWER}-output.md"
    fi
  fi
}

trap 'create_exit_file "$?" "unexpected exit"' EXIT

if [ ! -d "$WORK_DIR" ]; then
  echo "invoke-acpx: work_dir does not exist: $WORK_DIR" >&2
  exit 1
fi

if [ ! -f "$WORK_DIR/plan.md" ]; then
  echo "invoke-acpx: plan.md not found in $WORK_DIR" >&2
  exit 1
fi

# --- Config ---

if [ ! -f "$CONFIG_FILE" ]; then
  echo "invoke-acpx: config not found: $CONFIG_FILE" >&2
  exit 1
fi

AGENT=$(jq -r --arg rev "$REVIEWER" '.reviewers[$rev].agent // empty' "$CONFIG_FILE")
if [ -z "$AGENT" ]; then
  echo "invoke-acpx: no agent for '$REVIEWER' in $CONFIG_FILE" >&2
  exit 1
fi

CONFIG_TIMEOUT=$(jq -r --arg rev "$REVIEWER" '.reviewers[$rev].timeout // empty' "$CONFIG_FILE")
CONFIG_SYSTEM_PROMPT=$(jq -r --arg rev "$REVIEWER" '.reviewers[$rev].system_prompt // empty' "$CONFIG_FILE")

TIMEOUT="${TIMEOUT_ARG:-${CONFIG_TIMEOUT:-120}}"
if ! [[ "$TIMEOUT" =~ ^[0-9]+$ ]] || [ "$TIMEOUT" -le 0 ]; then
  echo "invoke-acpx: invalid timeout '$TIMEOUT' for '$REVIEWER', using 120s" >&2
  TIMEOUT=120
fi

# --- Prompt ---

PROMPT_FILE=""

if [ -f "$WORK_DIR/${REVIEWER}-prompt.txt" ]; then
  # Debate/revision round — prompt file is the full message
  PROMPT_FILE="$WORK_DIR/${REVIEWER}-prompt.txt"
else
  # Initial review — build prompt from system_prompt + plan
  SYSTEM_PROMPT="${CONFIG_SYSTEM_PROMPT:-You are a senior engineer reviewing an implementation plan. Be specific, direct, and focus on what could go wrong.}"

  {
    echo "$SYSTEM_PROMPT"
    echo ""
    echo "Review this implementation plan:"
    echo ""
    cat "$WORK_DIR/plan.md"
    echo ""
    echo "Be specific and actionable. If the plan is solid and ready to implement, end your review with exactly: VERDICT: APPROVED"
    echo ""
    echo "If changes are needed, end with exactly: VERDICT: REVISE"
  } > "$WORK_DIR/${REVIEWER}-acpx-prompt.txt"

  PROMPT_FILE="$WORK_DIR/${REVIEWER}-acpx-prompt.txt"
fi

# --- Resolve timeout binary ---

TIMEOUT_BIN=""
if command -v timeout > /dev/null 2>&1; then
  TIMEOUT_BIN="timeout"
elif command -v gtimeout > /dev/null 2>&1; then
  TIMEOUT_BIN="gtimeout"
fi

# --- acpx call ---

echo "[$REVIEWER] Submitting plan to $AGENT via acpx (timeout: ${TIMEOUT}s)..." >&2

ACPX_CMD=()
if [ -n "$TIMEOUT_BIN" ] && [ "$TIMEOUT" -gt 0 ]; then
  ACPX_CMD+=("$TIMEOUT_BIN" "$TIMEOUT")
fi
ACPX_CMD+=(acpx --format quiet --approve-reads "$AGENT" --file "$PROMPT_FILE")

set +e
"${ACPX_CMD[@]}" > "$WORK_DIR/${REVIEWER}-output.md" 2>"$WORK_DIR/${REVIEWER}-stderr.log"
EXIT_CODE=$?
set -e

# --- Handle exit codes ---

if [ "$EXIT_CODE" -eq 124 ]; then
  echo "[$REVIEWER] Timed out after ${TIMEOUT}s." >&2
elif [ "$EXIT_CODE" -ne 0 ]; then
  echo "[$REVIEWER] acpx failed (exit $EXIT_CODE)." >&2
  # If output is empty, populate from stderr
  if [ ! -s "$WORK_DIR/${REVIEWER}-output.md" ]; then
    {
      echo "acpx error (exit $EXIT_CODE) for agent '$AGENT':"
      echo ""
      cat "$WORK_DIR/${REVIEWER}-stderr.log" 2>/dev/null || echo "(no stderr)"
    } > "$WORK_DIR/${REVIEWER}-output.md"
  fi
else
  echo "[$REVIEWER] Review received." >&2
fi

echo "$EXIT_CODE" > "$WORK_DIR/${REVIEWER}-exit.txt"

# Check for empty successful response
if [ "$EXIT_CODE" -eq 0 ] && [ ! -s "$WORK_DIR/${REVIEWER}-output.md" ]; then
  echo "[$REVIEWER] Empty response from acpx." >&2
  {
    echo "Empty response from $AGENT via acpx. Stderr:"
    echo ""
    cat "$WORK_DIR/${REVIEWER}-stderr.log" 2>/dev/null || echo "(no stderr)"
  } > "$WORK_DIR/${REVIEWER}-output.md"
  echo "1" > "$WORK_DIR/${REVIEWER}-exit.txt"
  trap - EXIT
  exit 1
fi

trap - EXIT
exit "$EXIT_CODE"
```

- [ ] **Step 2: Make executable**

Run: `chmod +x scripts/invoke-acpx.sh`

- [ ] **Step 3: Verify script parses correctly**

Run: `bash -n scripts/invoke-acpx.sh`
Expected: no output (no syntax errors)

- [ ] **Step 4: Commit**

```bash
git add scripts/invoke-acpx.sh
git commit -m "feat: add invoke-acpx.sh — unified reviewer invocation via acpx CLI"
```

---

### Task 2: Create `run-parallel-acpx.sh`

**Files:**
- Create: `scripts/run-parallel-acpx.sh`

Replaces `run-parallel.sh` and `run-parallel-openai-compat.sh`. Same polling pattern, calls `invoke-acpx.sh`.

- [ ] **Step 1: Write `run-parallel-acpx.sh`**

```bash
#!/bin/bash
# Parallel runner for acpx-based debate reviews.
# Reads reviewer list from config, spawns invoke-acpx.sh for each, polls for completion.
#
# Usage: run-parallel-acpx.sh <config_file> <REVIEW_ID> [reviewer1,reviewer2,...]
#   config_file — path to JSON config (e.g. ~/.claude/debate-acpx.json)
#   REVIEW_ID   — 8-char hex ID (work dir: .claude/tmp/ai-review-<ID>)
#   reviewers   — optional comma-separated list; defaults to all from config

CONFIG_FILE="${1:-}"
REVIEW_ID="${2:-}"
REVIEWER_LIST="${3:-}"

if [ -z "$CONFIG_FILE" ] || [ -z "$REVIEW_ID" ]; then
  echo "Usage: $0 <config_file> <REVIEW_ID> [reviewer1,reviewer2,...]" >&2
  exit 1
fi

# Sanitize REVIEW_ID
if ! [[ "$REVIEW_ID" =~ ^[a-zA-Z0-9_-]+$ ]]; then
  echo "[debate] Invalid REVIEW_ID: must be alphanumeric/dashes/underscores only" >&2
  exit 1
fi

WORK_DIR=".claude/tmp/ai-review-${REVIEW_ID}"

# Note: $() triggers permission prompts in Claude Code, but this script runs
# via nohup/disown outside the sandbox, so it's fine here.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

mkdir -p "$WORK_DIR" || { echo "Failed to create $WORK_DIR" >&2; exit 1; }

if [ ! -f "$WORK_DIR/plan.md" ]; then
  echo "[debate] plan.md not found in $WORK_DIR — nothing to review" >&2
  exit 1
fi

if [ ! -f "$CONFIG_FILE" ]; then
  echo "Config not found: $CONFIG_FILE" >&2
  exit 1
fi

# Get reviewer names: CLI arg or all from config
if [ -n "$REVIEWER_LIST" ]; then
  IFS=',' read -ra REVIEWERS <<< "$REVIEWER_LIST"
else
  REVIEWERS=()
  while IFS= read -r line; do
    REVIEWERS+=("$line")
  done < <(jq -r '.reviewers | keys[]' "$CONFIG_FILE")
fi

if [ ${#REVIEWERS[@]} -eq 0 ]; then
  echo "[debate] No reviewers configured in $CONFIG_FILE" >&2
  exit 1
fi

EXIT_FILES=()

for NAME in "${REVIEWERS[@]}"; do
  AGENT=$(jq -r --arg name "$NAME" '.reviewers[$name].agent // empty' "$CONFIG_FILE")
  if [ -z "$AGENT" ]; then
    echo "[debate] Skipping $NAME — no agent in config" >&2
    continue
  fi

  TIMEOUT=$(jq -r --arg name "$NAME" '.reviewers[$name].timeout // 120' "$CONFIG_FILE")

  echo "[debate] Spawning $NAME ($AGENT, timeout: ${TIMEOUT}s)..." >&2
  rm -f "$WORK_DIR/${NAME}-exit.txt"
  nohup bash "$SCRIPT_DIR/invoke-acpx.sh" "$CONFIG_FILE" "$WORK_DIR" "$NAME" "$TIMEOUT" \
    > /dev/null 2>&1 &
  disown $!
  EXIT_FILES+=("$WORK_DIR/${NAME}-exit.txt")
done

if [ ${#EXIT_FILES[@]} -eq 0 ]; then
  echo "[debate] No reviewers spawned." >&2
  exit 1
fi

echo "[debate] Waiting for ${#EXIT_FILES[@]} reviewer(s)..." >&2

POLL_INTERVAL=2
ELAPSED=0
MAX_WAIT="${POLL_MAX_WAIT:-450}"

while [ "$ELAPSED" -lt "$MAX_WAIT" ]; do
  DONE=0
  for f in "${EXIT_FILES[@]}"; do
    [ -f "$f" ] && DONE=$((DONE + 1))
  done
  if [ "$DONE" -ge "${#EXIT_FILES[@]}" ]; then
    break
  fi
  sleep "$POLL_INTERVAL"
  ELAPSED=$((ELAPSED + POLL_INTERVAL))
done

if [ "$ELAPSED" -ge "$MAX_WAIT" ]; then
  echo "[debate] Timed out waiting for reviewers after ${MAX_WAIT}s." >&2
  rm -f "$WORK_DIR"/*-prompt.txt
  exit 1
else
  echo "[debate] All reviewers complete (${ELAPSED}s elapsed)." >&2
fi

# Aggregate exit codes
WORST_EXIT=0
for f in "${EXIT_FILES[@]}"; do
  if [ -f "$f" ]; then
    CODE=$(cat "$f" 2>/dev/null)
    if [[ "$CODE" =~ ^[0-9]+$ ]]; then
      [ "$CODE" -gt "$WORST_EXIT" ] && WORST_EXIT="$CODE"
    else
      echo "[debate] Warning: non-numeric exit code in $f: '$CODE'" >&2
      [ "$WORST_EXIT" -eq 0 ] && WORST_EXIT=1
    fi
  else
    WORST_EXIT=1
  fi
done

rm -f "$WORK_DIR"/*-prompt.txt

exit "$WORST_EXIT"
```

- [ ] **Step 2: Make executable**

Run: `chmod +x scripts/run-parallel-acpx.sh`

- [ ] **Step 3: Verify script parses correctly**

Run: `bash -n scripts/run-parallel-acpx.sh`
Expected: no output (no syntax errors)

- [ ] **Step 4: Commit**

```bash
git add scripts/run-parallel-acpx.sh
git commit -m "feat: add run-parallel-acpx.sh — parallel runner for acpx-based reviews"
```

---

## Chunk 2: Commands

### Task 3: Create `acpx-setup.md`

**Files:**
- Create: `commands/acpx-setup.md`

Replaces `litellm-setup.md` and `openrouter-setup.md`. Checks for acpx CLI and validates config.

- [ ] **Step 1: Write `acpx-setup.md`**

```markdown
---
description: Check acpx CLI installation, validate debate-acpx.json config, probe each configured agent, and print permission allowlist for unattended operation.
allowed-tools: Bash(which acpx:*), Bash(which npx:*), Bash(which jq:*), Bash(acpx:*), Bash(npx acpx@latest:*), Bash(bash ~/.claude/debate-scripts/debate-setup.sh:*), Bash(ls:*), Bash(chmod:*), Write(~/.claude/debate-acpx.json)
---

# debate — acpx Setup Check

Verify acpx prerequisites and print everything needed for `/debate:all`.

---

## Step 1: Check tools

```bash
which acpx || which npx
which jq
```

Report:
```text
## debate — acpx Setup Check

### Tools
  ✅ acpx   found at /path/to/acpx
  ✅ jq     found at /path/to/jq
```

If `acpx` is not found but `npx` is:
```text
  ⚠️  acpx not installed globally — will use npx acpx@latest (slower first run)
     Install globally: npm install -g acpx@latest
```

If neither `acpx` nor `npx`:
```text
  ❌ acpx not found. Install: npm install -g acpx@latest
```

## Step 2: Check config file

Read `~/.claude/debate-acpx.json`.

### If config exists

Show the parsed config:
```text
### Config: ~/.claude/debate-acpx.json
  Reviewers:
    codex   → agent: codex    (120s timeout)
    gemini  → agent: gemini   (240s timeout)
    kimi    → agent: kimi     (120s timeout)
```

Proceed to Step 3.

### If config is missing — Interactive Setup

Guide the user through creating a config:

**2a. List available acpx agents:**

```text
### Built-in acpx agents:
  codex    — OpenAI Codex CLI
  claude   — Claude Code
  gemini   — Google Gemini CLI
  cursor   — Cursor CLI
  copilot  — GitHub Copilot CLI
  kimi     — Kimi CLI
  kiro     — Kiro CLI
  qwen     — Qwen Code
  opencode — OpenCode
  kilocode — Kilocode
```

**2b. Ask the user to pick 2-4 agents:**

"Pick 2-4 agents for your review panel. The value is getting perspectives from different AI models. If you're running this inside Claude, skip the `claude` agent."

**2c. Write the config:**

Write `~/.claude/debate-acpx.json`:

```json
{
  "reviewers": {
    "<name1>": { "agent": "<agent>", "timeout": 120 },
    "<name2>": { "agent": "<agent>", "timeout": 240 }
  }
}
```

Set timeout to 240-300 for larger/slower agents, 120 for faster ones.

---

## Step 3: Probe each agent

For each configured reviewer, run a quick test:

```bash
echo "Reply with only the word PONG." | acpx --format quiet --approve-reads --timeout 30 <agent>
```

Report:
- Response contains "PONG" → `✅ <name>: <agent> responds`
- Error/timeout → `❌ <name>: <agent> failed — check that the agent CLI is installed`

## Step 4: Check debate-scripts symlink

```bash
ls -la ~/.claude/debate-scripts/invoke-acpx.sh
```

Report:
- Found → `✅ invoke-acpx.sh accessible via debate-scripts symlink`
- Not found → `❌ Run /debate:setup first to refresh the symlink`

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
      "Bash(rm -rf .claude/tmp/ai-review-:*)",
      "Read(.claude/tmp/ai-review*)",
      "Edit(.claude/tmp/ai-review*)",
      "Write(.claude/tmp/ai-review*)"
    ]
  }
}
```

## Step 6: Print summary

```text
### Summary

  acpx:    ✅ ready
  Config:  ✅ valid (N reviewers)
  jq:      ✅ ready
  Scripts: ✅ symlinked

  Reviewers:
    <name1>  ✅ <agent1>   (<timeout>s timeout)
    <name2>  ✅ <agent2>   (<timeout>s timeout)

You are ready to run:
  /debate:all                     — parallel review via acpx
  /debate:all codex,gemini        — specific reviewers only
```

If anything is missing, list remaining actions.
```

- [ ] **Step 2: Commit**

```bash
git add commands/acpx-setup.md
git commit -m "feat: add /debate:acpx-setup command for acpx configuration"
```

---

### Task 4: Rewrite `all.md` to use acpx

**Files:**
- Modify: `commands/all.md`

The current `all.md` hardcodes codex/gemini/opus reviewers with CLI detection and persona fallback. Replace with a config-driven acpx approach that reads reviewers from `~/.claude/debate-acpx.json`.

- [ ] **Step 1: Rewrite `all.md`**

Replace the entire file with the new acpx-based version. Key changes:
- No more `which codex / which gemini / which claude` checks — acpx handles agent availability
- No more shell mode — all invocations go through acpx
- No more persona fallback — acpx handles agent communication
- Config-driven reviewer list from `~/.claude/debate-acpx.json`
- Uses `invoke-acpx.sh` and `run-parallel-acpx.sh`

The new `all.md` should follow the same structure as the current litellm-review.md / openrouter-review.md (Steps 1-9: setup, parallel review, present, synthesize, debate, final report, revision loop, present final plan, cleanup) but reference `invoke-acpx.sh` instead of `invoke-openai-compat.sh` and the config file `~/.claude/debate-acpx.json`.

The description should be updated:
```yaml
---
description: Run ALL configured AI reviewers in parallel via acpx, synthesize feedback, debate contradictions, and produce a consensus verdict. Configure reviewers in ~/.claude/debate-acpx.json.
allowed-tools: Bash(bash ~/.claude/debate-scripts/debate-setup.sh:*), Bash(bash ~/.claude/debate-scripts/invoke-acpx.sh:*), Bash(rm -rf .claude/tmp/ai-review-:*), Write(.claude/tmp/ai-review-*), TeamCreate, TeamDelete, SendMessage, Agent
---
```

**Execution modes:** Keep team mode and agent mode. Remove shell mode entirely.
- **Team mode** (`TeamCreate` available): Create team once in Step 1e. Round 1: spawn Agent per reviewer with `team_name`. Each agent calls `invoke-acpx.sh`. Round 2+: `SendMessage` existing teammates to re-run `invoke-acpx.sh` with new prompt file. `TeamDelete` in Step 9.
- **Agent mode** (fallback): Round 1: spawn Agent per reviewer with `run_in_background: true`, each calls `invoke-acpx.sh`. Round 2+: spawn fresh agents with context injected via prompt file.
- No more persona fallback — if an acpx agent fails, it's reported as failed (not substituted with a Claude persona).

**Debate phase:** Each debate round writes a prompt to `<WORK_DIR>/<name>-prompt.txt`, then invokes `invoke-acpx.sh` which picks up that file. No session resume needed — acpx handles sessions internally. The debate flow is the same as litellm-review.md Step 5.

The step structure follows litellm-review.md with these substitutions:
- `~/.claude/debate-litellm.json` → `~/.claude/debate-acpx.json`
- `invoke-openai-compat.sh` → `invoke-acpx.sh`
- `run-parallel-openai-compat.sh` → `run-parallel-acpx.sh`
- "LiteLLM" → "acpx"
- Remove LiteLLM connectivity check (Step 1b in litellm-review) — not needed; acpx handles agent connectivity
- Remove `base_url` / `api_key` references from config validation
- Config validation: check for `.reviewers` with `.agent` field instead of `.model`
- In the announcement, show agent name instead of model name:
  ```text
  ## acpx Review — Starting

  Reviewers:
    codex   → agent: codex    (The Executor, 120s)
    gemini  → agent: gemini   (The Architect, 240s)
    kimi    → agent: kimi     (120s)
  ```
- Error messages reference `/debate:acpx-setup` instead of `/debate:litellm-setup`
- `/debate:all` accepts optional comma-separated reviewer names as first arg (e.g., `/debate:all codex,gemini`) — this replaces the need for separate single-reviewer commands

- [ ] **Step 2: Verify no broken references**

Run: `grep -r "invoke-codex\|invoke-gemini\|invoke-opus\|invoke-openai-compat\|debate-litellm\|debate-openrouter" commands/all.md`
Expected: no matches

- [ ] **Step 3: Commit**

```bash
git add commands/all.md
git commit -m "feat: rewrite /debate:all to use acpx for all reviewers"
```

---

### Task 5: Migrate `opus-review.md` to acpx

**Files:**
- Modify: `commands/opus-review.md`

Replace direct `claude` CLI invocation with `acpx claude`. The review flow (5-round iterative loop) stays the same, but instead of `invoke-opus.sh` we use `invoke-acpx.sh` with a temporary single-reviewer config.

- [ ] **Step 1: Rewrite `opus-review.md`**

Key changes to the existing file:
- Remove prerequisite check for `which claude` and `which jq` — replace with check for `which acpx`
- Update allowed-tools: replace `invoke-opus.sh` with `invoke-acpx.sh`
  ```yaml
  allowed-tools: Bash(bash ~/.claude/debate-scripts/debate-setup.sh:*), Bash(bash ~/.claude/debate-scripts/invoke-acpx.sh:*), Bash(rm -rf .claude/tmp/ai-review-:*), Write(.claude/tmp/ai-review-*)
  ```
- Step 1 (Setup): Instead of setting MODEL, write a temporary single-reviewer config to `<WORK_DIR>/opus-config.json`:
  ```json
  {
    "reviewers": {
      "opus": {
        "agent": "claude",
        "timeout": 300,
        "system_prompt": "You are The Skeptic — a devil's advocate..."
      }
    }
  }
  ```
- Step 3 (Initial Review): Replace `bash "<SCRIPT_DIR>/invoke-opus.sh"` with:
  ```bash
  bash "<SCRIPT_DIR>/invoke-acpx.sh" "<WORK_DIR>/opus-config.json" "<WORK_DIR>" "opus"
  ```
- Step 6 (Re-submit): Same substitution. No more session ID tracking — each round writes a new prompt file and invokes acpx fresh (acpx manages sessions internally).
- Remove all references to `OPUS_SESSION_ID`, `opus-session-id.txt`, `opus-raw.json`
- Remove `jq` dependency note

- [ ] **Step 2: Commit**

```bash
git add commands/opus-review.md
git commit -m "feat: migrate /debate:opus-review to acpx claude"
```

---

## Chunk 3: Cleanup

### Task 6: Remove old commands

**Files:**
- Delete: `commands/codex-review.md`
- Delete: `commands/gemini-review.md`
- Delete: `commands/litellm-review.md`
- Delete: `commands/openrouter-review.md`
- Delete: `commands/litellm-setup.md`
- Delete: `commands/openrouter-setup.md`

- [ ] **Step 1: Remove old command files**

```bash
git rm commands/codex-review.md commands/gemini-review.md \
      commands/litellm-review.md commands/openrouter-review.md \
      commands/litellm-setup.md commands/openrouter-setup.md
```

- [ ] **Step 2: Commit**

```bash
git commit -m "chore: remove CLI and API-based review commands (replaced by acpx)"
```

---

### Task 7: Remove old scripts

**Files:**
- Delete: `scripts/invoke-codex.sh`
- Delete: `scripts/invoke-gemini.sh`
- Delete: `scripts/invoke-opus.sh`
- Delete: `scripts/invoke-openai-compat.sh`
- Delete: `scripts/run-parallel.sh`
- Delete: `scripts/run-parallel-openai-compat.sh`
- Delete: `scripts/probe-model.sh`

- [ ] **Step 1: Remove old script files**

```bash
git rm scripts/invoke-codex.sh scripts/invoke-gemini.sh scripts/invoke-opus.sh \
      scripts/invoke-openai-compat.sh scripts/run-parallel.sh \
      scripts/run-parallel-openai-compat.sh scripts/probe-model.sh
```

- [ ] **Step 2: Commit**

```bash
git commit -m "chore: remove old invoke and parallel runner scripts (replaced by acpx)"
```

---

### Task 8: Remove `reviewers/` directory

**Files:**
- Delete: `reviewers/codex.md`
- Delete: `reviewers/gemini.md`
- Delete: `reviewers/opus.md`

These files contain CLI-specific invocation instructions (invoke-codex.sh, model flags, session resume patterns) that are now stale. Reviewer personas are configured in `debate-acpx.json` via the `system_prompt` field.

- [ ] **Step 1: Remove reviewer definition files**

```bash
git rm reviewers/codex.md reviewers/gemini.md reviewers/opus.md
rmdir reviewers 2>/dev/null || true
```

- [ ] **Step 2: Commit**

```bash
git commit -m "chore: remove reviewers/ directory (personas now in debate-acpx.json config)"
```

---

### Task 9: Update `create-links.sh`



**Files:**
- Modify: `scripts/create-links.sh`

Remove backward-compat symlinks for old script names. The old symlinks (`invoke-litellm.sh → invoke-openai-compat.sh`, `run-parallel-litellm.sh → run-parallel-openai-compat.sh`) are no longer needed.

- [ ] **Step 1: Update `create-links.sh`**

Remove lines 13-14 (the backward-compat symlink creation):
```bash
  # Backward-compat symlinks for old script names (settings.json allowlists)
  ln -sf invoke-openai-compat.sh "$SELF_DIR/invoke-litellm.sh" 2>/dev/null || true
  ln -sf run-parallel-openai-compat.sh "$SELF_DIR/run-parallel-litellm.sh" 2>/dev/null || true
```

- [ ] **Step 2: Commit**

```bash
git add scripts/create-links.sh
git commit -m "chore: remove backward-compat symlinks from create-links.sh"
```

---

### Task 10: Update `setup.md`

**Files:**
- Modify: `commands/setup.md`

Replace checks for codex/gemini/claude/jq binaries with a check for `acpx`. Remove model probing, sandbox exclusion checks, analytics opt-out checks. Add acpx-specific checks.

- [ ] **Step 1: Rewrite `setup.md`**

Key changes:
- Step 1: Replace `which codex / which gemini / which claude / which jq` with `which acpx` and `which jq`
- Remove Steps 2-3d (Codex version/auth, Gemini auth, Claude CLI, sandbox exclusion, analytics opt-out, model probing, sandbox network/filesystem checks) — these are all agent-specific concerns that acpx handles internally
- Keep Step 3f (create-links.sh symlink creation) — still needed
- Remove Step 4 (timeout binary check) — acpx handles timeouts
- Step 5: Update permission allowlist to reference acpx scripts instead of old scripts:
  ```json
  {
    "permissions": {
      "allow": [
        "Bash(bash ~/.claude/debate-scripts/debate-setup.sh:*)",
        "Bash(bash ~/.claude/debate-scripts/run-parallel-acpx.sh:*)",
        "Bash(bash ~/.claude/debate-scripts/invoke-acpx.sh:*)",
        "Bash(rm -rf .claude/tmp/ai-review-:*)",
        "Read(.claude/tmp/ai-review*)",
        "Edit(.claude/tmp/ai-review*)",
        "Write(.claude/tmp/ai-review*)"
      ]
    }
  }
  ```
- Step 6: Update summary to show acpx status and reference `/debate:all` and `/debate:acpx-setup`
- Update allowed-tools in frontmatter: remove old script references, add acpx references
- Add a check for `~/.claude/debate-acpx.json` — if missing, suggest running `/debate:acpx-setup`

- [ ] **Step 2: Commit**

```bash
git add commands/setup.md
git commit -m "feat: update /debate:setup for acpx-based architecture"
```

---

### Task 11: Update plugin metadata and codemaps

**Files:**
- Modify: `.claude-plugin/plugin.json`
- Modify: `.claude-plugin/marketplace.json`
- Modify: `codemaps/architecture.md`
- Modify: `codemaps/backend.md`

- [ ] **Step 1: Update plugin.json**

Update the description and keywords:
```json
{
  "description": "Multi-model AI plan review: run any acpx-supported agent (Codex, Gemini, Kimi, Qwen, etc.) in parallel, synthesize feedback, debate contradictions",
  "keywords": ["review", "acpx", "ai", "plan-review", "multi-model", "debate"]
}
```

- [ ] **Step 2: Update marketplace.json**

Update both the top-level `description` and the nested plugin `description` and `version`:
```json
{
  "description": "Multi-model AI plan review with parallel execution, synthesis, and debate — any acpx-supported agent",
  "plugins": [{
    "description": "Multi-model AI plan review with parallel execution, synthesis, and debate — any acpx-supported agent",
    "version": "2.0.0"
  }]
}
```

- [ ] **Step 3: Update codemaps/architecture.md**

Replace the execution flow diagram to reflect acpx:
- Remove three execution modes (team/agent/shell) → simplify to team/agent (shell mode is removed)
- Update the top-level layout to remove old scripts
- Update reviewer substitution section — no more persona fallback; acpx handles agent availability
- Update the stable symlink pattern to reference new scripts

- [ ] **Step 4: Update codemaps/backend.md**

Update tables:
- Commands table: remove codex-review, gemini-review, litellm-review, openrouter-review, litellm-setup, openrouter-setup; add acpx-setup
- Scripts table: remove old invoke-*.sh and run-parallel-*.sh and probe-model.sh; add invoke-acpx.sh and run-parallel-acpx.sh
- Remove Reviewer Definitions section (reviewers/ dir deleted)
- Update Script I/O Contract section for invoke-acpx.sh
- Remove Invoke Script Timeouts table (timeouts are config-driven, not env-var-driven)
- Remove custom reviewer path note (`~/.claude/ai-review/reviewers/<name>.md`)

- [ ] **Step 5: Bump version in plugin.json**

Update version from `1.2.5` to `2.0.0` (breaking change: removes CLI and API-based providers).

- [ ] **Step 6: Commit**

```bash
git add .claude-plugin/plugin.json .claude-plugin/marketplace.json codemaps/architecture.md codemaps/backend.md
git commit -m "docs: update plugin metadata and codemaps for acpx migration (v2.0.0)"
```

---

### Task 12: Update README.md

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Update README**

Key changes:
- Update overview to mention acpx instead of individual CLIs
- Update prerequisites: just `acpx` (via `npm install -g acpx@latest`) and `jq`
- Remove individual CLI install instructions (codex, gemini, claude)
- Update quick start to reference `/debate:acpx-setup` and `/debate:all`
- Update config section to show `debate-acpx.json` format
- Remove LiteLLM and OpenRouter sections
- List available acpx agents

- [ ] **Step 2: Commit**

```bash
git add README.md
git commit -m "docs: update README for acpx migration"
```

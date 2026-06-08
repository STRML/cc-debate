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

# --- Resolve acpx binary (support npx fallback) ---

ACPX_BIN=()
if command -v acpx > /dev/null 2>&1; then
  ACPX_BIN=(acpx)
elif command -v npx > /dev/null 2>&1; then
  ACPX_BIN=(npx acpx@latest)
else
  echo "invoke-acpx: acpx not found. Install: npm install -g acpx@latest" >&2
  # Write a meaningful exit file if we can
  if [ -n "$WORK_DIR" ] && [ -n "$REVIEWER" ] && [ -d "$WORK_DIR" ]; then
    echo "1" > "$WORK_DIR/${REVIEWER}-exit.txt"
    echo "acpx not installed. Run: npm install -g acpx@latest" > "$WORK_DIR/${REVIEWER}-output.md"
  fi
  exit 1
fi

# --- Trap: ensure exit file is always written on unexpected exit ---
# Only fires on abnormal termination — normal exit paths call trap - EXIT before returning.

create_exit_file() {
  local code="${1:-1}"
  if [ -n "$WORK_DIR" ] && [ -n "$REVIEWER" ]; then
    echo "$code" > "$WORK_DIR/${REVIEWER}-exit.txt"
    if [ ! -f "$WORK_DIR/${REVIEWER}-output.md" ]; then
      echo "invoke-acpx: process terminated unexpectedly (exit $code)" > "$WORK_DIR/${REVIEWER}-output.md"
    fi
  fi
}

trap 'create_exit_file "$?"' EXIT

if [ ! -d "$WORK_DIR" ]; then
  echo "invoke-acpx: work_dir does not exist: $WORK_DIR" >&2
  exit 1
fi

if [ ! -f "$WORK_DIR/plan.md" ]; then
  echo "invoke-acpx: plan.md not found in $WORK_DIR" >&2
  exit 1
fi

if [ ! -s "$WORK_DIR/plan.md" ]; then
  echo "invoke-acpx: plan.md is empty in $WORK_DIR" >&2
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
CONFIG_MODEL=$(jq -r --arg rev "$REVIEWER" '.reviewers[$rev].model // empty' "$CONFIG_FILE")

# --- Nested Claude guard ---
# When the agent is `claude`, Claude Code's nested-session guard (CLAUDECODE=1)
# blocks acpx from spawning it as an ACP subprocess. Unset the guard vars so the
# child process can start. This was required in v1.x and remains necessary in v2.

if [ "$AGENT" = "claude" ] || [ "$AGENT" = "opus" ]; then
  unset CLAUDECODE CLAUDE_CODE_ENTRYPOINT
fi

# --- Session setup: ensure a session exists for this agent ---
# `sessions ensure` is idempotent: creates a session if none exists for the
# current cwd, reuses one if it does. Avoids accumulating sessions on every run.
# Skip if SKIP_SESSION_CHECK is set (for testing with mock acpx)

if [ -z "${SKIP_SESSION_CHECK:-}" ]; then
  # Gemini and Opus use direct CLI invocation — skip acpx session check.
  if [ "$AGENT" != "gemini" ] && [ "$AGENT" != "opus" ]; then
    echo "[$REVIEWER] Ensuring acpx session for '$AGENT'..." >&2
    if ! "${ACPX_BIN[@]}" "$AGENT" sessions ensure > /dev/null 2>&1; then
      echo "[$REVIEWER] Failed to ensure acpx session for '$AGENT'." >&2
      echo "  Check that the agent CLI is installed and authenticated." >&2
      echo "  Run /debate:acpx-setup to diagnose." >&2
      echo "4" > "$WORK_DIR/${REVIEWER}-exit.txt"
      echo "Failed to ensure acpx session for '$AGENT'. Run /debate:acpx-setup to diagnose." > "$WORK_DIR/${REVIEWER}-output.md"
      trap - EXIT
      exit 4
    fi
    echo "[$REVIEWER] Session ready." >&2
  fi
fi

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
    echo "READ-ONLY REVIEW — HARD RULE: You are reviewing a plan, nothing more. Do NOT create, edit, write, move, rename, or delete any file, and do NOT run any command that mutates the filesystem or repository (no patches, no fixes applied in place). You have read-only access only. Output your review as text in your reply — that text is the entire deliverable. Any write attempt is denied by the sandbox and only wastes the round."
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
else
  echo "[$REVIEWER] WARNING: neither timeout nor gtimeout found — running without timeout enforcement" >&2
  echo "  Install: brew install coreutils (macOS) / apt install coreutils (Linux)" >&2
fi

# --- Shared result handler ---
# Call after running any reviewer command. Uses globals: REVIEWER, WORK_DIR, TIMEOUT, EXIT_CODE.
# $1: label used in log/error messages (e.g. "gemini CLI" or "acpx")

handle_invocation_result() {
  local label="$1"
  if [ "$EXIT_CODE" -eq 124 ]; then
    echo "[$REVIEWER] Timed out after ${TIMEOUT}s." >&2
  elif [ "$EXIT_CODE" -ne 0 ]; then
    echo "[$REVIEWER] $label failed (exit $EXIT_CODE)." >&2
    if [ -s "$WORK_DIR/${REVIEWER}-stderr.log" ]; then
      echo "[$REVIEWER] stderr: $(head -5 "$WORK_DIR/${REVIEWER}-stderr.log")" >&2
    fi
    if [ ! -s "$WORK_DIR/${REVIEWER}-output.md" ]; then
      {
        echo "$label error (exit $EXIT_CODE):"
        echo ""
        cat "$WORK_DIR/${REVIEWER}-stderr.log" 2>/dev/null || echo "(no stderr)"
      } > "$WORK_DIR/${REVIEWER}-output.md"
    fi
  else
    echo "[$REVIEWER] Review received." >&2
  fi

  echo "$EXIT_CODE" > "$WORK_DIR/${REVIEWER}-exit.txt"

  if [ "$EXIT_CODE" -eq 0 ] && [ ! -s "$WORK_DIR/${REVIEWER}-output.md" ]; then
    echo "[$REVIEWER] Empty response from $label." >&2
    {
      echo "Empty response from $label. Stderr:"
      echo ""
      cat "$WORK_DIR/${REVIEWER}-stderr.log" 2>/dev/null || echo "(no stderr)"
    } > "$WORK_DIR/${REVIEWER}-output.md"
    echo "1" > "$WORK_DIR/${REVIEWER}-exit.txt"
    trap - EXIT
    exit 1
  fi

  trap - EXIT
  exit "$EXIT_CODE"
}

# --- Gemini: direct CLI invocation ---
# Gemini CLI's ACP mode (--acp / --experimental-acp) never completes the ACP initialize
# handshake regardless of auth method. Use the gemini CLI directly via stdin instead.
# Works with both OAuth (default) and API key auth.

if [ "$AGENT" = "gemini" ]; then
  if ! command -v gemini > /dev/null 2>&1; then
    echo "[$REVIEWER] gemini CLI not found. Install: npm install -g @google/gemini-cli" >&2
    echo "gemini CLI not installed. Run: npm install -g @google/gemini-cli" > "$WORK_DIR/${REVIEWER}-output.md"
    echo "1" > "$WORK_DIR/${REVIEWER}-exit.txt"
    trap - EXIT
    exit 1
  fi

  echo "[$REVIEWER] Submitting plan to gemini CLI directly (timeout: ${TIMEOUT}s)..." >&2

  GEMINI_CMD=()
  if [ -n "$TIMEOUT_BIN" ] && [ "$TIMEOUT" -gt 0 ]; then
    GEMINI_CMD+=("$TIMEOUT_BIN" "$TIMEOUT")
  fi
  # -s: sandbox  -e "": disable extensions (faster startup)
  # --approval-mode plan: read-only mode — gemini cannot write/edit any file
  # while reviewing (the plan doc stays untouched).
  GEMINI_CMD+=(gemini -s -e "" --approval-mode plan)

  set +e
  "${GEMINI_CMD[@]}" < "$PROMPT_FILE" > "$WORK_DIR/${REVIEWER}-output.md" 2>"$WORK_DIR/${REVIEWER}-stderr.log"
  EXIT_CODE=$?
  set -e

  handle_invocation_result "gemini CLI"
fi

# --- Opus: direct Claude CLI invocation ---
# Uses `claude --print --model <model>` via stdin — bypasses acpx entirely.
# Model comes from the reviewer's config `.model`, defaulting to a CURRENT opus id.
# (A stale id like claude-opus-4-6 makes --print return empty with exit 0 — a silent
# review failure. Keep this default current, or set `.model` per reviewer in config.)
# CLAUDECODE is already unset above so the nested-session guard doesn't block it.

if [ "$AGENT" = "opus" ]; then
  if ! command -v claude > /dev/null 2>&1; then
    echo "[$REVIEWER] claude CLI not found — is Claude Code installed?" >&2
    echo "claude CLI not installed. Ensure Claude Code is on PATH." > "$WORK_DIR/${REVIEWER}-output.md"
    echo "1" > "$WORK_DIR/${REVIEWER}-exit.txt"
    trap - EXIT
    exit 1
  fi

  echo "[$REVIEWER] Submitting plan to Claude Opus directly (timeout: ${TIMEOUT}s)..." >&2

  OPUS_CMD=()
  if [ -n "$TIMEOUT_BIN" ] && [ "$TIMEOUT" -gt 0 ]; then
    OPUS_CMD+=("$TIMEOUT_BIN" "$TIMEOUT")
  fi
  # --permission-mode plan: read-only mode — the reviewer cannot edit/write files.
  OPUS_CMD+=(claude --print --permission-mode plan --model "${CONFIG_MODEL:-claude-opus-4-8}")

  set +e
  "${OPUS_CMD[@]}" < "$PROMPT_FILE" > "$WORK_DIR/${REVIEWER}-output.md" 2>"$WORK_DIR/${REVIEWER}-stderr.log"
  EXIT_CODE=$?
  set -e

  handle_invocation_result "Claude Opus"
fi

# --- acpx call ---

echo "[$REVIEWER] Submitting plan to $AGENT via acpx (timeout: ${TIMEOUT}s)..." >&2

ACPX_CMD=()
if [ -n "$TIMEOUT_BIN" ] && [ "$TIMEOUT" -gt 0 ]; then
  ACPX_CMD+=("$TIMEOUT_BIN" "$TIMEOUT")
fi
# Read-only enforcement: --approve-reads auto-approves read/search requests;
# --non-interactive-permissions deny auto-denies any write/edit/exec the agent
# requests (headless can't prompt, so it denies rather than hangs). This is the
# hard guarantee that a reviewer (e.g. an over-eager external agent) cannot
# modify the plan doc or any file in the repo while reviewing.
ACPX_CMD+=("${ACPX_BIN[@]}" --format quiet --approve-reads --non-interactive-permissions deny "$AGENT" --file "$PROMPT_FILE")

set +e
"${ACPX_CMD[@]}" > "$WORK_DIR/${REVIEWER}-output.md" 2>"$WORK_DIR/${REVIEWER}-stderr.log"
EXIT_CODE=$?
set -e

handle_invocation_result "acpx"

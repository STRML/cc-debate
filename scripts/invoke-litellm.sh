#!/bin/bash
# Generic reviewer invocation via LiteLLM's OpenAI-compatible API.
# Stateless — no session resume. Each call sends full context.
#
# Usage: invoke-litellm.sh <work_dir> <reviewer_name> [model] [timeout]
#   work_dir      — temp directory (must contain plan.md)
#   reviewer_name — e.g. "deepseek", "gemini", "opus"
#   model         — optional override; falls back to config value
#   timeout       — optional override; falls back to config value, then 120s
#
# Config: ~/.claude/debate-litellm.json
#   {
#     "base_url": "http://localhost:8200/v1",
#     "api_key": "",
#     "reviewers": {
#       "<name>": {
#         "model": "...",
#         "timeout": 120,
#         "system_prompt": "..."
#       }
#     }
#   }
#
# Prompt resolution (in order):
#   1. $work_dir/<name>-prompt.txt  (debate/revision rounds write this)
#   2. reviewers.<name>.system_prompt from config
#   3. Built-in fallback: generic plan reviewer
#
# Plan content is always read from plan.md and injected into the user message.
#
# Output files (all written to $work_dir):
#   <name>-output.md   review text
#   <name>-raw.json    full API response (for debugging)
#   <name>-exit.txt    exit code (0=success, 124=timeout, 1=error)

set -euo pipefail

WORK_DIR="${1:-}"
REVIEWER="${2:-}"
MODEL_ARG="${3:-}"
TIMEOUT_ARG="${4:-}"

if [ -z "$WORK_DIR" ] || [ -z "$REVIEWER" ]; then
  echo "Usage: $0 <work_dir> <reviewer_name> [model] [timeout]" >&2
  exit 1
fi

# --- Trap: ensure exit file is always written ---

create_exit_file() {
  local code="${1:-1}"
  local reason="${2:-unknown error}"
  if [ -n "$WORK_DIR" ] && [ -n "$REVIEWER" ]; then
    echo "$code" > "$WORK_DIR/${REVIEWER}-exit.txt"
    if [ ! -f "$WORK_DIR/${REVIEWER}-output.md" ]; then
      echo "invoke-litellm.sh: $reason" > "$WORK_DIR/${REVIEWER}-output.md"
    fi
  fi
}

trap 'create_exit_file "$?" "unexpected exit"' EXIT

if [ ! -d "$WORK_DIR" ]; then
  echo "invoke-litellm.sh: work_dir does not exist: $WORK_DIR" >&2
  exit 1
fi

if [ ! -f "$WORK_DIR/plan.md" ]; then
  echo "invoke-litellm.sh: plan.md not found in $WORK_DIR" >&2
  exit 1
fi

# --- Config ---

CONFIG_FILE="$HOME/.claude/debate-litellm.json"

BASE_URL="http://localhost:8200/v1"
API_KEY=""
CONFIG_MODEL=""
CONFIG_TIMEOUT=""
CONFIG_SYSTEM_PROMPT=""

if [ -f "$CONFIG_FILE" ]; then
  BASE_URL=$(jq -r '.base_url // "http://localhost:8200/v1"' "$CONFIG_FILE")
  API_KEY=$(jq -r '.api_key // ""' "$CONFIG_FILE")
  CONFIG_MODEL=$(jq -r --arg rev "$REVIEWER" '.reviewers[$rev].model // empty' "$CONFIG_FILE")
  CONFIG_TIMEOUT=$(jq -r --arg rev "$REVIEWER" '.reviewers[$rev].timeout // empty' "$CONFIG_FILE")
  CONFIG_SYSTEM_PROMPT=$(jq -r --arg rev "$REVIEWER" '.reviewers[$rev].system_prompt // empty' "$CONFIG_FILE")
else
  echo "invoke-litellm.sh: config not found at $CONFIG_FILE — using defaults" >&2
fi

# Resolve: CLI arg > config > error/default
MODEL="${MODEL_ARG:-${CONFIG_MODEL:-}}"
if [ -z "$MODEL" ]; then
  echo "invoke-litellm.sh: no model for '$REVIEWER' (pass as arg or set in config)" >&2
  exit 1
fi

TIMEOUT="${TIMEOUT_ARG:-${CONFIG_TIMEOUT:-120}}"
API_KEY="${API_KEY:-${LITELLM_API_KEY:-}}"

# --- Prompt ---

SYSTEM_PROMPT=""
USER_PROMPT=""
PLAN_CONTENT="$(cat "$WORK_DIR/plan.md")"

if [ -f "$WORK_DIR/${REVIEWER}-prompt.txt" ]; then
  # Debate/revision round — prompt file is the full user message
  USER_PROMPT="$(cat "$WORK_DIR/${REVIEWER}-prompt.txt")"
else
  # Initial review — use system prompt + plan as user message
  if [ -n "$CONFIG_SYSTEM_PROMPT" ]; then
    SYSTEM_PROMPT="$CONFIG_SYSTEM_PROMPT"
  else
    SYSTEM_PROMPT="You are a senior engineer reviewing an implementation plan. Be specific, direct, and focus on what could go wrong."
  fi

  USER_PROMPT="Review this implementation plan:

$PLAN_CONTENT

Be specific and actionable. If the plan is solid and ready to implement, end your review with exactly: VERDICT: APPROVED

If changes are needed, end with exactly: VERDICT: REVISE"
fi

# --- Build JSON payload (jq handles all escaping) ---

if [ -n "$SYSTEM_PROMPT" ]; then
  PAYLOAD=$(jq -n \
    --arg model "$MODEL" \
    --arg system "$SYSTEM_PROMPT" \
    --arg user "$USER_PROMPT" \
    '{
      model: $model,
      messages: [
        { role: "system", content: $system },
        { role: "user", content: $user }
      ],
      temperature: 0.3
    }')
else
  PAYLOAD=$(jq -n \
    --arg model "$MODEL" \
    --arg user "$USER_PROMPT" \
    '{
      model: $model,
      messages: [
        { role: "user", content: $user }
      ],
      temperature: 0.3
    }')
fi

# --- API call ---

echo "[$REVIEWER] Submitting plan to $MODEL via LiteLLM (timeout: ${TIMEOUT}s)..." >&2

CURL_ARGS=(
  -s -S
  --max-time "$TIMEOUT"
  -H "Content-Type: application/json"
)

if [ -n "$API_KEY" ]; then
  CURL_ARGS+=(-H "Authorization: Bearer $API_KEY")
fi

CURL_ARGS+=(-d "$PAYLOAD" "${BASE_URL}/chat/completions")

set +e
curl "${CURL_ARGS[@]}" > "$WORK_DIR/${REVIEWER}-raw.json" 2>"$WORK_DIR/${REVIEWER}-stderr.log"
EXIT_CODE=$?
set -e

# --- Handle curl exit codes ---

if [ "$EXIT_CODE" -eq 28 ] || [ "$EXIT_CODE" -eq 124 ]; then
  echo "[$REVIEWER] Timed out after ${TIMEOUT}s." >&2
  echo "124" > "$WORK_DIR/${REVIEWER}-exit.txt"
  trap - EXIT
  exit 124
elif [ "$EXIT_CODE" -ne 0 ]; then
  echo "[$REVIEWER] curl failed (exit $EXIT_CODE)." >&2
  {
    echo "curl error (exit $EXIT_CODE):"
    cat "$WORK_DIR/${REVIEWER}-stderr.log"
  } > "$WORK_DIR/${REVIEWER}-output.md"
  echo "$EXIT_CODE" > "$WORK_DIR/${REVIEWER}-exit.txt"
  trap - EXIT
  exit "$EXIT_CODE"
fi

# --- Parse response ---

CONTENT=$(jq -r '.choices[0].message.content // empty' "$WORK_DIR/${REVIEWER}-raw.json" 2>/dev/null)
ERROR=$(jq -r '.error.message // empty' "$WORK_DIR/${REVIEWER}-raw.json" 2>/dev/null)

if [ -n "$ERROR" ]; then
  echo "[$REVIEWER] API error: $ERROR" >&2
  echo "API error from $MODEL: $ERROR" > "$WORK_DIR/${REVIEWER}-output.md"
  echo "1" > "$WORK_DIR/${REVIEWER}-exit.txt"
  trap - EXIT
  exit 1
fi

if [ -z "$CONTENT" ]; then
  echo "[$REVIEWER] Empty response from API." >&2
  {
    echo "Empty response from $MODEL. Raw JSON:"
    echo ""
    cat "$WORK_DIR/${REVIEWER}-raw.json"
  } > "$WORK_DIR/${REVIEWER}-output.md"
  echo "1" > "$WORK_DIR/${REVIEWER}-exit.txt"
  trap - EXIT
  exit 1
fi

echo "$CONTENT" > "$WORK_DIR/${REVIEWER}-output.md"
echo "0" > "$WORK_DIR/${REVIEWER}-exit.txt"
echo "[$REVIEWER] Review received." >&2

trap - EXIT
exit 0

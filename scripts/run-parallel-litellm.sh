#!/bin/bash
# Parallel runner for LiteLLM-based debate reviews.
# Reads reviewer list from ~/.claude/debate-litellm.json, spawns
# invoke-litellm.sh for each, and polls for completion.
#
# Usage: run-parallel-litellm.sh <REVIEW_ID> [reviewer1,reviewer2,...]
#   REVIEW_ID  — 8-char hex ID (work dir: /tmp/claude/ai-review-<ID>)
#   reviewers  — optional comma-separated list; defaults to all from config

REVIEW_ID="$1"
REVIEWER_LIST="${2:-}"

if [ -z "$REVIEW_ID" ]; then
  echo "Usage: $0 <REVIEW_ID> [reviewer1,reviewer2,...]" >&2
  exit 1
fi

# Sanitize REVIEW_ID: allow only alphanumeric, dashes, underscores
if ! [[ "$REVIEW_ID" =~ ^[a-zA-Z0-9_-]+$ ]]; then
  echo "[debate] Invalid REVIEW_ID: must be alphanumeric/dashes/underscores only" >&2
  exit 1
fi

WORK_DIR="/tmp/claude/ai-review-${REVIEW_ID}"
CONFIG_FILE="$HOME/.claude/debate-litellm.json"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

mkdir -p "$WORK_DIR" || { echo "Failed to create $WORK_DIR" >&2; exit 1; }

if [ ! -f "$WORK_DIR/plan.md" ]; then
  echo "[debate] plan.md not found in $WORK_DIR — nothing to review" >&2
  exit 1
fi

if [ ! -f "$CONFIG_FILE" ]; then
  echo "Config not found: $CONFIG_FILE" >&2
  echo "Create it with /debate:litellm-setup or manually." >&2
  exit 1
fi

# Get reviewer names: CLI arg or all from config
if [ -n "$REVIEWER_LIST" ]; then
  IFS=',' read -ra REVIEWERS <<< "$REVIEWER_LIST"
else
  mapfile -t REVIEWERS < <(jq -r '.reviewers | keys[]' "$CONFIG_FILE")
fi

if [ ${#REVIEWERS[@]} -eq 0 ]; then
  echo "[debate] No reviewers configured in $CONFIG_FILE" >&2
  exit 1
fi

EXIT_FILES=()

for NAME in "${REVIEWERS[@]}"; do
  MODEL=$(jq -r --arg name "$NAME" '.reviewers[$name].model // empty' "$CONFIG_FILE")
  if [ -z "$MODEL" ]; then
    echo "[debate] Skipping $NAME — no model in config" >&2
    continue
  fi

  TIMEOUT=$(jq -r --arg name "$NAME" '.reviewers[$name].timeout // 120' "$CONFIG_FILE")

  echo "[debate] Spawning $NAME ($MODEL, timeout: ${TIMEOUT}s)..." >&2
  rm -f "$WORK_DIR/${NAME}-exit.txt"
  nohup bash "$SCRIPT_DIR/invoke-litellm.sh" "$WORK_DIR" "$NAME" "$MODEL" "$TIMEOUT" \
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

# Aggregate reviewer exit codes — propagate worst failure
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
    # Exit file missing means reviewer never completed
    WORST_EXIT=1
  fi
done

# Clean up prompt files after all reviewers have consumed them
rm -f "$WORK_DIR"/*-prompt.txt

exit "$WORST_EXIT"

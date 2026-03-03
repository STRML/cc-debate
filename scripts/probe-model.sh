#!/bin/bash
# Probe for the best available model for a given reviewer CLI.
# Tries models from highest to lowest tier; returns the first that succeeds.
# Results are cached in ~/.claude/debate-model-probe.json (24h TTL).
#
# Usage: probe-model.sh <codex|gemini> [work_dir] [--fresh]
#   codex|gemini — which reviewer to probe
#   work_dir     — optional; if given, writes result to $work_dir/<reviewer>-model.txt
#   --fresh      — skip cache read (still writes cache on success)
#
# Stdout: the working model name, or empty string on failure
#
# Exit codes:
#   0  — model found
#   1  — no model available (auth/network/rate-limit issue, not model tier)
#   2  — codex sandbox panic (requires excludedCommands fix)

REVIEWER=""
WORK_DIR=""
FRESH=0

for ARG in "$@"; do
  case "$ARG" in
    codex|gemini) REVIEWER="$ARG" ;;
    --fresh)      FRESH=1 ;;
    *)            [ -z "$WORK_DIR" ] && WORK_DIR="$ARG" ;;
  esac
done

if [ -z "$REVIEWER" ]; then
  echo "Usage: $0 <codex|gemini> [work_dir] [--fresh]" >&2
  exit 1
fi

case "$REVIEWER" in
  codex)  MODELS=("gpt-5.3-codex" "gpt-4.1" "gpt-4o") ;;
  gemini) MODELS=("gemini-3.1-pro-preview" "gemini-2.5-pro" "gemini-2.0-flash") ;;
esac

CACHE_FILE="$HOME/.claude/debate-model-probe.json"
TIMEOUT_BIN=$(command -v timeout || command -v gtimeout || true)

# Read from cache unless --fresh
if [ "$FRESH" -eq 0 ] && [ -f "$CACHE_FILE" ]; then
  CACHED_AT=$(jq -r ".probed_at // 0" "$CACHE_FILE" 2>/dev/null || echo 0)
  NOW=$(date +%s)
  AGE=$(( NOW - CACHED_AT ))
  if [ "$AGE" -lt 86400 ]; then
    CACHED_MODEL=$(jq -r ".${REVIEWER}_model // empty" "$CACHE_FILE" 2>/dev/null)
    if [ -n "$CACHED_MODEL" ]; then
      echo "$CACHED_MODEL"
      [ -n "$WORK_DIR" ] && echo "$CACHED_MODEL" > "$WORK_DIR/${REVIEWER}-model.txt"
      exit 0
    fi
  fi
fi

FOUND_MODEL=""

for MODEL in "${MODELS[@]}"; do
  PROBE_TMP=$(mktemp /tmp/claude/probe-XXXXXX.txt 2>/dev/null || mktemp)
  PROBE_ERR=$(mktemp /tmp/claude/probe-XXXXXX.err 2>/dev/null || mktemp)
  PROBE_EXIT=0

  if [ "$REVIEWER" = "codex" ]; then
    TIMEOUT_CMD=()
    [ -n "$TIMEOUT_BIN" ] && TIMEOUT_CMD=("$TIMEOUT_BIN" 30)
    "${TIMEOUT_CMD[@]}" codex exec -m "$MODEL" -s read-only --json \
      "Reply with only the word PONG." \
      > "$PROBE_TMP" 2>&1
    PROBE_EXIT=$?

    # Sandbox panic — can't test any model, stop
    if grep -q "Attempted to create a NULL object" "$PROBE_TMP" 2>/dev/null; then
      rm -f "$PROBE_TMP" "$PROBE_ERR"
      echo "probe-model.sh: codex sandbox panic — add debate scripts to sandbox.excludedCommands" >&2
      exit 2
    fi

    rm -f "$PROBE_TMP" "$PROBE_ERR"

    if [ "$PROBE_EXIT" -eq 0 ]; then
      FOUND_MODEL="$MODEL"
      break
    fi
    # Any non-zero (not sandbox panic) → model not available, try next

  else # gemini
    TIMEOUT_CMD=()
    [ -n "$TIMEOUT_BIN" ] && TIMEOUT_CMD=("$TIMEOUT_BIN" 30)
    echo "PONG" | "${TIMEOUT_CMD[@]}" gemini \
      -p "Reply with only the word PONG." \
      -m "$MODEL" -s -e "" \
      > "$PROBE_TMP" 2>"$PROBE_ERR"
    PROBE_EXIT=$?

    # Capture output size before cleanup
    PROBE_OUTPUT_SIZE=$(wc -c < "$PROBE_TMP" 2>/dev/null || echo 0)
    rm -f "$PROBE_TMP" "$PROBE_ERR"

    # Gemini sometimes exits 0 with empty output when the API is unreachable
    # (network blocked in sandbox). Require non-empty output to confirm success.
    if [ "$PROBE_EXIT" -eq 0 ] && [ "$PROBE_OUTPUT_SIZE" -gt 0 ]; then
      FOUND_MODEL="$MODEL"
      break
    fi

    # Timeout or empty output → network/sandbox issue, stop probing
    [ "$PROBE_EXIT" -eq 124 ] && exit 1
    [ "$PROBE_EXIT" -eq 0 ] && exit 1  # exit 0 + empty = false positive
    # Any other non-zero → model not available, try next
  fi
done

if [ -z "$FOUND_MODEL" ]; then
  exit 1
fi

# Write to cache
NOW=$(date +%s)
if [ -f "$CACHE_FILE" ]; then
  CACHE_ENTRY=$(jq '.' "$CACHE_FILE" 2>/dev/null || echo "{}")
else
  CACHE_ENTRY="{}"
fi
echo "$CACHE_ENTRY" | jq \
  --arg model "$FOUND_MODEL" \
  --arg key "${REVIEWER}_model" \
  --argjson now "$NOW" \
  '.[$key] = $model | .probed_at = $now' \
  > "$CACHE_FILE" 2>/dev/null || true

echo "$FOUND_MODEL"
[ -n "$WORK_DIR" ] && echo "$FOUND_MODEL" > "$WORK_DIR/${REVIEWER}-model.txt"
exit 0

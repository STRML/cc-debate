#!/bin/bash
# Mock acpx binary for testing invoke-acpx.sh and run-parallel-acpx.sh.
#
# Behavior is controlled by environment variables:
#   MOCK_ACPX_EXIT     — exit code (default: 0)
#   MOCK_ACPX_RESPONSE — text to write to stdout (default: "Mock review. VERDICT: APPROVED")
#   MOCK_ACPX_DELAY    — seconds to sleep before responding (default: 0)
#   MOCK_ACPX_STDERR   — text to write to stderr (default: "")
#   MOCK_ACPX_LOG      — file to append invocation args to (default: "")
#
# Flaky-agent simulation, for the blank-output retry:
#   MOCK_ACPX_BLANK_ATTEMPTS — first N invocations answer with nothing (default: 0)
#   MOCK_ACPX_COUNTER_FILE   — where the invocation count lives; required by the above
#
# This script mimics `acpx --format quiet --approve-reads <agent> --file <prompt>`.
# It reads the --file argument to verify it exists, then outputs the response.
#
# Session subcommands:
#   MOCK_ACPX_SESSION_LIST_EXIT   — exit code for `<agent> sessions list`   (default: 0)
#   MOCK_ACPX_SESSION_NEW_EXIT    — exit code for `<agent> sessions new`     (default: 0)
#   MOCK_ACPX_SESSION_ENSURE_EXIT — exit code for `<agent> sessions ensure`  (default: 0)
#   MOCK_ACPX_SESSION_STDERR      — text written to stderr by session subcommands (default: "")
#
# When invoked as `acpx <agent> sessions list|new|ensure`, returns the configured exit code.

# Handle session subcommands: acpx <agent> sessions <list|new|ensure>
if [ $# -ge 3 ] && [ "$2" = "sessions" ]; then
  LOG="${MOCK_ACPX_LOG:-}"
  if [ -n "$LOG" ]; then
    echo "acpx $*" >> "$LOG"
  fi
  if [ -n "${MOCK_ACPX_SESSION_STDERR:-}" ]; then
    echo "$MOCK_ACPX_SESSION_STDERR" >&2
  fi
  case "$3" in
    list)
      exit "${MOCK_ACPX_SESSION_LIST_EXIT:-0}"
      ;;
    new)
      exit "${MOCK_ACPX_SESSION_NEW_EXIT:-0}"
      ;;
    ensure)
      exit "${MOCK_ACPX_SESSION_ENSURE_EXIT:-0}"
      ;;
  esac
fi

EXIT_CODE="${MOCK_ACPX_EXIT:-0}"
# Use ${VAR-default} (no colon) so MOCK_ACPX_RESPONSE="" is respected as empty
RESPONSE="${MOCK_ACPX_RESPONSE-Mock review. VERDICT: APPROVED}"
DELAY="${MOCK_ACPX_DELAY:-0}"
STDERR="${MOCK_ACPX_STDERR:-}"
LOG="${MOCK_ACPX_LOG:-}"

# Log the invocation
if [ -n "$LOG" ]; then
  echo "acpx $*" >> "$LOG"
fi

# Parse args to find --file
FILE_ARG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --file) FILE_ARG="$2"; shift 2 ;;
    --format|--approve-reads|--approve-all|--deny-all|--timeout) shift 2 ;;
    --*) shift ;;
    *) shift ;;
  esac
done

# Verify prompt file exists (mimics real acpx behavior)
if [ -n "$FILE_ARG" ] && [ ! -f "$FILE_ARG" ]; then
  echo "Error: file not found: $FILE_ARG" >&2
  exit 1
fi

# Simulate delay
if [ "$DELAY" -gt 0 ] 2>/dev/null; then
  sleep "$DELAY"
fi

# Simulate an agent that ends its first N turns without a final message. Real
# acpx still emits its trailing newline in that case, so the caller sees a
# 1-byte file rather than a 0-byte one — reproduce that, not a bare truncation.
BLANK_ATTEMPTS="${MOCK_ACPX_BLANK_ATTEMPTS:-0}"
COUNTER_FILE="${MOCK_ACPX_COUNTER_FILE:-}"
if [ "$BLANK_ATTEMPTS" -gt 0 ] 2>/dev/null && [ -n "$COUNTER_FILE" ]; then
  ATTEMPT=$(cat "$COUNTER_FILE" 2>/dev/null || echo 0)
  ATTEMPT=$((ATTEMPT + 1))
  echo "$ATTEMPT" > "$COUNTER_FILE"
  if [ "$ATTEMPT" -le "$BLANK_ATTEMPTS" ]; then
    echo ""
    exit "$EXIT_CODE"
  fi
fi

# Output
if [ -n "$STDERR" ]; then
  echo "$STDERR" >&2
fi

# Only output response if non-empty (simulates truly empty output)
if [ -n "$RESPONSE" ]; then
  echo "$RESPONSE"
fi
exit "$EXIT_CODE"

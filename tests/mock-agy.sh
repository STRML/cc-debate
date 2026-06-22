#!/bin/bash
# Mock agy binary (Antigravity CLI) for testing invoke-acpx.sh's direct CLI path.
#
# Behavior is controlled by environment variables (MOCK_AGY_* preferred; MOCK_ACPX_* as fallback):
#   MOCK_AGY_EXIT     — exit code (default: 0)
#   MOCK_AGY_RESPONSE — stdout text (default: "Mock agy review. VERDICT: APPROVED")
#   MOCK_AGY_DELAY    — seconds to sleep (default: 0)
#   MOCK_AGY_STDERR   — text to write to stderr (default: "")
#   MOCK_AGY_LOG      — file to append invocation args to (default: "")
#
# Invoked as: agy -p "<prompt>" --sandbox --print-timeout <dur> [--model <m>]
# The prompt is a POSITIONAL ARGUMENT (agy does not read stdin in print mode).

EXIT_CODE="${MOCK_AGY_EXIT:-${MOCK_ACPX_EXIT:-0}}"
RESPONSE="${MOCK_AGY_RESPONSE-Mock agy review. VERDICT: APPROVED}"
DELAY="${MOCK_AGY_DELAY:-${MOCK_ACPX_DELAY:-0}}"
STDERR="${MOCK_AGY_STDERR:-${MOCK_ACPX_STDERR:-}}"
AGY_LOG="${MOCK_AGY_LOG:-${MOCK_ACPX_LOG:-}}"
if [ -n "$AGY_LOG" ]; then
  echo "agy $*" >> "$AGY_LOG"
fi

# Simulate delay
if [ "$DELAY" -gt 0 ] 2>/dev/null; then
  sleep "$DELAY"
fi

if [ -n "$STDERR" ]; then
  echo "$STDERR" >&2
fi

if [ -n "$RESPONSE" ]; then
  echo "$RESPONSE"
fi
exit "$EXIT_CODE"

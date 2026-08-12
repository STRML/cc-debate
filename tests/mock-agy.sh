#!/bin/bash
# Mock agy binary (Antigravity CLI) for testing invoke-acpx.sh's direct CLI path.
#
# Behavior is controlled by environment variables (MOCK_AGY_* preferred; MOCK_ACPX_* as fallback):
#   MOCK_AGY_EXIT     — exit code (default: 0)
#   MOCK_AGY_RESPONSE — stdout text (default: "Mock agy review. VERDICT: APPROVED")
#   MOCK_AGY_DELAY    — seconds to sleep (default: 0)
#   MOCK_AGY_STDERR   — text to write to stderr (default: "")
#   MOCK_AGY_LOG      — file to append invocation args to (default: "")
#   MOCK_AGY_AUTH_FAIL — if 1, `agy models` exits non-zero (simulates "not signed
#                        in") so the auth pre-flight fails the seat (default: 0)
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

# Auth pre-flight probe: `agy models` lists models when authenticated. Simulate
# failure to exercise invoke-acpx.sh's "not signed in" path.
if [ "$1" = "models" ]; then
  if [ "${MOCK_AGY_AUTH_FAIL:-0}" = "1" ]; then
    echo "You are not logged into Antigravity." >&2
    exit 1
  fi
  echo "mock-model-1"
  exit 0
fi

# Simulate a wedged agent that ignores SIGTERM — the case the runner's process-group
# sweep exists for. A group TERM cannot stop it; only a KILL of the seat's group does,
# and that requires the agent to be IN that group (which needs `timeout --foreground`).
# Absence of the survival marker is the passing condition.
if [ "${MOCK_AGY_IGNORE_TERM:-${MOCK_ACPX_IGNORE_TERM:-0}}" = "1" ]; then
  trap '' TERM
fi

# Simulate delay
if [ "$DELAY" -gt 0 ] 2>/dev/null; then
  sleep "$DELAY"
fi

# Survival marker. Written only if this process outlived its delay, which is how a
# test tells "the runner killed the whole seat" from "the runner killed the wrapper
# and left the agent running". Absence is the passing condition.
if [ -n "${MOCK_AGY_SURVIVED_FILE:-${MOCK_ACPX_SURVIVED_FILE:-}}" ]; then
  echo "survived" > "${MOCK_AGY_SURVIVED_FILE:-${MOCK_ACPX_SURVIVED_FILE:-}}"
fi

if [ -n "$STDERR" ]; then
  echo "$STDERR" >&2
fi

if [ -n "$RESPONSE" ]; then
  echo "$RESPONSE"
fi
exit "$EXIT_CODE"

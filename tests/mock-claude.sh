#!/bin/bash
# Mock claude binary for testing invoke-acpx.sh's opus direct CLI invocation path.
#
# Behavior is controlled by environment variables (MOCK_CLAUDE_* preferred; MOCK_ACPX_* as fallback):
#   MOCK_CLAUDE_EXIT     — exit code (default: 0)
#   MOCK_CLAUDE_RESPONSE — stdout text (default: "Mock Claude Opus review. VERDICT: APPROVED")
#   MOCK_CLAUDE_DELAY    — seconds to sleep (default: 0)
#   MOCK_CLAUDE_STDERR   — text to write to stderr (default: "")
#   MOCK_CLAUDE_LOG      — file to append invocation args to (default: "")
#   MOCK_CLAUDE_ENV_OUT   — file to write proxy env vars to (default: "")
#
# Invoked as: claude --print --model claude-opus-4-6 < prompt_file
# Reads stdin (ignores it) and outputs the mock response.

EXIT_CODE="${MOCK_CLAUDE_EXIT:-${MOCK_ACPX_EXIT:-0}}"
RESPONSE="${MOCK_CLAUDE_RESPONSE-Mock Claude Opus review. VERDICT: APPROVED}"
DELAY="${MOCK_CLAUDE_DELAY:-${MOCK_ACPX_DELAY:-0}}"
STDERR="${MOCK_CLAUDE_STDERR:-${MOCK_ACPX_STDERR:-}}"
CLAUDE_LOG="${MOCK_CLAUDE_LOG:-${MOCK_ACPX_LOG:-}}"

# Log the invocation
if [ -n "$CLAUDE_LOG" ]; then
  echo "claude $*" >> "$CLAUDE_LOG"
fi

# Drain stdin so callers don't block
cat > /dev/null

# Simulate a wedged agent that ignores SIGTERM — the case the runner's process-group
# sweep exists for. A group TERM cannot stop it; only a KILL of the seat's group does,
# and that requires the agent to be IN that group (which needs `timeout --foreground`).
# Absence of the survival marker is the passing condition.
if [ "${MOCK_CLAUDE_IGNORE_TERM:-${MOCK_ACPX_IGNORE_TERM:-0}}" = "1" ]; then
  trap '' TERM
fi

# Simulate delay
if [ "$DELAY" -gt 0 ] 2>/dev/null; then
  sleep "$DELAY"
fi

# Survival marker. Written only if this process outlived its delay, which is how a
# test tells "the runner killed the whole seat" from "the runner killed the wrapper
# and left the agent running". Absence is the passing condition.
if [ -n "${MOCK_CLAUDE_SURVIVED_FILE:-${MOCK_ACPX_SURVIVED_FILE:-}}" ]; then
  echo "survived" > "${MOCK_CLAUDE_SURVIVED_FILE:-${MOCK_ACPX_SURVIVED_FILE:-}}"
fi

if [ -n "$STDERR" ]; then
  echo "$STDERR" >&2
fi

if [ -n "${MOCK_CLAUDE_ENV_OUT:-}" ]; then
  {
    printf 'ANTHROPIC_BASE_URL=%s\n' "${ANTHROPIC_BASE_URL:-}"
    printf 'DS4_ZDR=%s\n' "${DS4_ZDR:-}"
    printf 'MODEL_ARG=%s\n' "$*"
  } > "$MOCK_CLAUDE_ENV_OUT"
fi
if [ -n "$RESPONSE" ]; then
  echo "$RESPONSE"
fi
exit "$EXIT_CODE"

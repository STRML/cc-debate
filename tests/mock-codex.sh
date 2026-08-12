#!/bin/bash
# Mock codex binary for testing invoke-acpx.sh's repo-aware `codex exec` path.
#
# Behavior is controlled by environment variables:
#   MOCK_CODEX_EXIT     — exit code (default: 0)
#   MOCK_CODEX_RESPONSE — text written to the -o file (default: approved review)
#   MOCK_CODEX_DELAY    — seconds to sleep (default: 0)
#   MOCK_CODEX_STDERR   — text to write to stderr (default: "")
#   MOCK_CODEX_LOG      — file to append invocation args to (default: "")
#   MOCK_CODEX_HANG_ON_STDIN=1 — reproduce the real stdin bug: if stdin is not
#                         closed, print the stdin notice and block. With
#                         `</dev/null` the read returns immediately and the mock
#                         proceeds, which is exactly the behavior under test.
#
# Invoked as: codex exec -s read-only -o <file> [-m <model>] [-c k=v] "<prompt>"
# The real binary echoes its whole transcript to stdout and writes only the
# final message to the -o file; the mock mirrors that split.

EXIT_CODE="${MOCK_CODEX_EXIT:-0}"
RESPONSE="${MOCK_CODEX_RESPONSE-Mock codex review. VERDICT: APPROVED}"
DELAY="${MOCK_CODEX_DELAY:-${MOCK_ACPX_DELAY:-0}}"
STDERR="${MOCK_CODEX_STDERR:-}"
CODEX_LOG="${MOCK_CODEX_LOG:-}"

if [ -n "$CODEX_LOG" ]; then
  echo "codex $*" >> "$CODEX_LOG"
fi

# Locate -o <file>, which is where the final message belongs.
OUT_FILE=""
prev=""
for arg in "$@"; do
  [ "$prev" = "-o" ] && OUT_FILE="$arg"
  prev="$arg"
done

# The prompt arrives on stdin when invoked as `codex exec ... -`, which is how
# the real call avoids ARG_MAX. Capture it so tests can assert what was sent.
if [ "${MOCK_CODEX_HANG_ON_STDIN:-0}" = "1" ]; then
  echo "Reading additional input from stdin..."
  # Blocks forever on a stdin that never reaches EOF; returns at once on a
  # regular file or /dev/null.
  if [ -n "${MOCK_CODEX_PROMPT_OUT:-}" ]; then
    cat > "$MOCK_CODEX_PROMPT_OUT"
  else
    cat > /dev/null
  fi
elif [ -n "${MOCK_CODEX_PROMPT_OUT:-}" ]; then
  cat > "$MOCK_CODEX_PROMPT_OUT"
fi

# Simulate a wedged agent that ignores SIGTERM — the case the runner's process-group
# sweep exists for. A group TERM cannot stop it; only a KILL of the seat's group does,
# and that requires the agent to be IN that group (which needs `timeout --foreground`).
# Absence of the survival marker is the passing condition.
if [ "${MOCK_CODEX_IGNORE_TERM:-${MOCK_ACPX_IGNORE_TERM:-0}}" = "1" ]; then
  trap '' TERM
fi

if [ "$DELAY" -gt 0 ] 2>/dev/null; then
  sleep "$DELAY"
fi

# Survival marker. Written only if this process outlived its delay, which is how a
# test tells "the runner killed the whole seat" from "the runner killed the wrapper
# and left the agent running". Absence is the passing condition.
if [ -n "${MOCK_CODEX_SURVIVED_FILE:-${MOCK_ACPX_SURVIVED_FILE:-}}" ]; then
  echo "survived" > "${MOCK_CODEX_SURVIVED_FILE:-${MOCK_ACPX_SURVIVED_FILE:-}}"
fi

[ -n "$STDERR" ] && echo "$STDERR" >&2

# Transcript noise on stdout, mirroring the real binary.
echo "mock codex transcript: reading repo..."

# Record the environment the reviewer actually runs under, so the containment
# wrapper (redirected HOME, scrubbed secrets) is testable without a live model.
if [ -n "${MOCK_CODEX_ENV_OUT:-}" ]; then
  {
    echo "HOME=${HOME:-}"
    echo "CODEX_HOME=${CODEX_HOME:-}"
    echo "SECRET_PRESENT=${DEBATE_TEST_API_KEY+yes}"
    echo "PROVIDER_KEY_PRESENT=${OPENAI_API_KEY+yes}"
    echo "BENIGN_PRESENT=${DEBATE_TEST_BENIGN+yes}"
  } > "$MOCK_CODEX_ENV_OUT"
fi

# Simulate codex exiting 0 without writing a final message for its first N runs.
# The real binary does this, which is why the branch clears a stale output file.
BLANK_ATTEMPTS="${MOCK_CODEX_BLANK_ATTEMPTS:-0}"
COUNTER_FILE="${MOCK_CODEX_COUNTER_FILE:-}"
if [ "$BLANK_ATTEMPTS" -gt 0 ] 2>/dev/null && [ -n "$COUNTER_FILE" ]; then
  ATTEMPT=$(cat "$COUNTER_FILE" 2>/dev/null || echo 0)
  ATTEMPT=$((ATTEMPT + 1))
  echo "$ATTEMPT" > "$COUNTER_FILE"
  if [ "$ATTEMPT" -le "$BLANK_ATTEMPTS" ]; then
    exit "$EXIT_CODE"
  fi
fi

if [ -n "$OUT_FILE" ] && [ -n "$RESPONSE" ]; then
  echo "$RESPONSE" > "$OUT_FILE"
fi

exit "$EXIT_CODE"

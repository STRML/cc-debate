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
DELAY="${MOCK_CODEX_DELAY:-0}"
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

if [ "$DELAY" -gt 0 ] 2>/dev/null; then
  sleep "$DELAY"
fi

[ -n "$STDERR" ] && echo "$STDERR" >&2

# Transcript noise on stdout, mirroring the real binary.
echo "mock codex transcript: reading repo..."

if [ -n "$OUT_FILE" ] && [ -n "$RESPONSE" ]; then
  echo "$RESPONSE" > "$OUT_FILE"
fi

exit "$EXIT_CODE"

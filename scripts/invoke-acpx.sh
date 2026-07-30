#!/bin/bash
# Generic reviewer invocation via acpx CLI.
# Replaces invoke-codex.sh, invoke-gemini.sh, invoke-opus.sh, invoke-openai-compat.sh.
#
# Usage: invoke-acpx.sh <config_file> <work_dir> <reviewer_name> [timeout]
#   config_file   — path to JSON config (e.g. ~/.claude/debate-acpx.json)
#   work_dir      — temp directory (must contain plan.md)
#   reviewer_name — e.g. "codex", "antigravity", "kimi"
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

# A review target is either a plan or, when no plan was staged, the changeset
# the runner captured. Exactly one has to be non-empty.
if [ ! -f "$WORK_DIR/plan.md" ] && [ ! -s "$WORK_DIR/changeset.diff" ]; then
  echo "invoke-acpx: plan.md not found in $WORK_DIR (and no changeset.diff)" >&2
  exit 1
fi

if [ ! -s "$WORK_DIR/plan.md" ] && [ ! -s "$WORK_DIR/changeset.diff" ]; then
  echo "invoke-acpx: nothing to review in $WORK_DIR — plan.md is empty and there is no changeset.diff" >&2
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
CONFIG_EFFORT=$(jq -r --arg rev "$REVIEWER" '.reviewers[$rev].effort // empty' "$CONFIG_FILE")

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
  # Antigravity and Opus use direct CLI invocation — skip acpx session check.
  if [ "$AGENT" != "antigravity" ] && [ "$AGENT" != "opus" ]; then
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
  # Initial review. Review target: an explicit plan when one was prepared,
  # otherwise the current changeset. Falling back to the diff means /debate:run
  # doubles as a code review with no extra syntax — if nobody staged a plan,
  # debate what actually changed. run-parallel-acpx.sh writes changeset.diff.
  TARGET_FILE="$WORK_DIR/plan.md"
  TARGET_NOUN="implementation plan"
  TARGET_VERB="ready to implement"
  if [ ! -s "$TARGET_FILE" ] && [ -s "$WORK_DIR/changeset.diff" ]; then
    TARGET_FILE="$WORK_DIR/changeset.diff"
    TARGET_NOUN="changeset"
    TARGET_VERB="ready to merge"
  fi

  SYSTEM_PROMPT="${CONFIG_SYSTEM_PROMPT:-You are a senior engineer reviewing an ${TARGET_NOUN}. Be specific, direct, and focus on what could go wrong.}"

  {
    echo "$SYSTEM_PROMPT"
    echo ""
    echo "READ-ONLY REVIEW — HARD RULE: You are reviewing a ${TARGET_NOUN}, nothing more. Do NOT create, edit, write, move, rename, or delete any file, and do NOT run any command that mutates the filesystem or repository (no patches, no fixes applied in place). You have read-only access only. Output your review as text in your reply — that text is the entire deliverable. Any write attempt is denied by the sandbox and only wastes the round."
    echo ""
    if [ "$TARGET_NOUN" = "changeset" ]; then
      echo "Review this changeset. Reviewers with repo access should open the surrounding code rather than judging the diff in isolation; reviewers without it should say so instead of guessing at context they cannot see."
    else
      echo "Review this implementation plan:"
    fi
    echo ""
    cat "$TARGET_FILE"
    echo ""
    echo "Be specific and actionable. If it is solid and ${TARGET_VERB}, end your review with exactly: VERDICT: APPROVED"
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
# $1: label used in log/error messages (e.g. "agy (Antigravity CLI)" or "acpx")

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

# --- Antigravity: direct CLI invocation ---
# Antigravity CLI's `agy` is the successor to the Gemini CLI for plan review.
# acpx has no native ACP support for it yet, so invoke `agy` directly. Three quirks
# drive this block (all verified against agy v1.0.x):
#   1. Prompt is a POSITIONAL ARGUMENT — `agy -p "<prompt>"`. stdin is NOT read in
#      print mode (it echoes the input and then times out waiting for a response).
#   2. Non-TTY stdout bug — `agy -p` drops its final response (and can hang) when
#      stdout is not a TTY, which is exactly our case (capturing to a file). We run
#      it under a PTY via `script`, then strip the PTY's ANSI/CR/EOT noise.
#   3. No hard read-only flag — unlike gemini's `--approval-mode plan`, agy has no
#      equivalent, and `--sandbox` only restricts terminal commands (it does NOT
#      prevent file writes). We contain it by running from a throwaway workspace
#      (the full plan is in the prompt arg, so agy needs no repo access) plus the
#      explicit read-only directive already baked into the prompt.
# Works with OAuth (run `agy` once to sign in) or ANTIGRAVITY_API_KEY auth.

if [ "$AGENT" = "antigravity" ]; then
  if ! command -v agy > /dev/null 2>&1; then
    echo "[$REVIEWER] agy CLI not found. Install the Antigravity CLI and run 'agy' once to sign in." >&2
    echo "agy CLI not installed. Install the Antigravity CLI (https://antigravity.google) and run 'agy' to sign in." > "$WORK_DIR/${REVIEWER}-output.md"
    echo "1" > "$WORK_DIR/${REVIEWER}-exit.txt"
    trap - EXIT
    exit 1
  fi

  # A PTY is needed (quirk 2): agy drops its output unless stdout is a TTY. We use a
  # small Python runner rather than `script(1)` because BSD `script` aborts
  # ("tcgetattr/ioctl: Operation not supported on socket") when stdin is not a real
  # TTY — which is exactly how the debate runner launches us (nohup, stdin a
  # pipe/socket). The runner puts ONLY agy's stdout on a pty (stderr stays on our
  # stderr → ${REVIEWER}-stderr.log) and falls back to a plain pipe if the
  # environment forbids pty allocation (e.g. a restrictive sandbox), so it degrades
  # instead of failing. Identical on macOS and Linux.
  PY_BIN=""
  if command -v python3 > /dev/null 2>&1; then
    PY_BIN="python3"
  elif command -v python > /dev/null 2>&1; then
    PY_BIN="python"
  else
    echo "[$REVIEWER] python3 not found — required to run agy under a PTY." >&2
    echo "python3 not installed. Install Python 3 to use the antigravity reviewer." > "$WORK_DIR/${REVIEWER}-output.md"
    echo "1" > "$WORK_DIR/${REVIEWER}-exit.txt"
    trap - EXIT
    exit 1
  fi

  echo "[$REVIEWER] Submitting plan to agy (Antigravity CLI) directly (timeout: ${TIMEOUT}s)..." >&2

  # Prompt as a positional argument (quirk 1). Pass via env so plan content (newlines,
  # quotes, anything) reaches agy verbatim with zero shell/Python re-escaping.
  AGY_PROMPT="$(cat "$PROMPT_FILE")"
  export AGY_PROMPT
  export AGY_BIN; AGY_BIN="$(command -v agy)"
  export AGY_PRINT_TIMEOUT="${TIMEOUT}s"     # Go duration for --print-timeout
  # --model is optional; its value is a display name from `agy models`
  # (e.g. "Gemini 3.1 Pro (High)").
  if [ -n "$CONFIG_MODEL" ]; then
    export AGY_MODEL="$CONFIG_MODEL"
  else
    unset AGY_MODEL || true
  fi

  # Throwaway workspace for read-only containment (quirk 3).
  AGY_WORKSPACE="$WORK_DIR/.agy-workspace"
  mkdir -p "$AGY_WORKSPACE"

  TIMEOUT_PREFIX=()
  if [ -n "$TIMEOUT_BIN" ] && [ "$TIMEOUT" -gt 0 ]; then
    TIMEOUT_PREFIX=("$TIMEOUT_BIN" "$TIMEOUT")
  fi

  # Strip the PTY's ANSI escapes (literal ESC via printf — portable across BSD/GNU sed),
  # carriage returns, and EOT (^D) bytes from the captured output.
  ESC=$(printf '\033')

  set +e
  # Expand the array 3.2-safely: on bash < 4.4 (macOS ships 3.2), "${arr[@]}" of an
  # EMPTY array under `set -u` throws "unbound variable". The +"${...}" guard yields
  # nothing when TIMEOUT_PREFIX is empty (no timeout/gtimeout on PATH) and the elements
  # otherwise — so the agy reviewer runs instead of crashing on timeout-less macOS.
  ( cd "$AGY_WORKSPACE" && "${TIMEOUT_PREFIX[@]+"${TIMEOUT_PREFIX[@]}"}" "$PY_BIN" -c '
import os, sys, subprocess
cmd = [os.environ["AGY_BIN"], "-p", os.environ["AGY_PROMPT"],
       "--sandbox", "--print-timeout", os.environ["AGY_PRINT_TIMEOUT"]]
model = os.environ.get("AGY_MODEL")
if model:
    cmd += ["--model", model]
# Put only agy stdout on a pty so isatty(stdout) is true; stderr stays on fd 2.
master = None
try:
    master, slave = os.openpty()
except OSError:
    master = None
out = b""
if master is not None:
    p = subprocess.Popen(cmd, stdin=subprocess.DEVNULL, stdout=slave, close_fds=True)
    os.close(slave)
    while True:
        try:
            chunk = os.read(master, 65536)
        except OSError:
            break
        if not chunk:
            break
        out += chunk
    os.close(master)
    rc = p.wait()
else:
    p = subprocess.run(cmd, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE)
    out = p.stdout
    rc = p.returncode
sys.stdout.buffer.write(out)
sys.stdout.buffer.flush()
sys.exit(rc if rc and rc > 0 else (1 if rc else 0))
' ) 2>"$WORK_DIR/${REVIEWER}-stderr.log" \
    | sed -E "s/${ESC}\[[0-9;]*[A-Za-z]//g" | tr -d '\r\004' > "$WORK_DIR/${REVIEWER}-output.md"
  EXIT_CODE=${PIPESTATUS[0]}
  set -e

  handle_invocation_result "agy (Antigravity CLI)"
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

# --- codex exec: the repo-aware seat ---
# Every other transport here is prompt-only. acpx makes no tool calls at all
# (measured: asked for the declaration line of a method in a file inside its own
# --cwd, it returned null under both --approve-reads and --approve-all, and a
# --verbose run showed no tool or permission traffic). agy is deliberately run
# from a throwaway workspace because it has no read-only mode. That is fine for
# reviewing a plan, but it means no reviewer can ever check a claim against the
# actual code.
#
# `codex exec` can. It reads files and runs commands, and `-s read-only` keeps it
# from writing anything — verified by asking for a method's declaration line and
# getting the exact line number and verbatim text back.
#
# Three flags are load-bearing:
#   `</dev/null`  — without a closed stdin, codex prints "Reading additional
#                   input from stdin..." and blocks until the timeout kills it.
#                   Under a harness that looks like a silent no-op, and is the
#                   likeliest cause of "codex just returns nothing" reports.
#   `-s read-only`— the sandbox guarantee, equivalent to acpx's
#                   --non-interactive-permissions deny.
#   `-o <file>`   — writes ONLY the final message. codex echoes every command it
#                   runs, so its stdout can carry an entire test suite; pointing
#                   -o at the output file keeps the transcript out of the
#                   synthesizer's input.

if [ "$AGENT" = "codex-exec" ]; then
  if ! command -v codex > /dev/null 2>&1; then
    echo "[$REVIEWER] codex CLI not found." >&2
    echo "codex CLI not installed. Install the Codex CLI and run 'codex' once to sign in." > "$WORK_DIR/${REVIEWER}-output.md"
    echo "1" > "$WORK_DIR/${REVIEWER}-exit.txt"
    trap - EXIT
    exit 1
  fi

  echo "[$REVIEWER] Submitting to codex exec, repo-aware (timeout: ${TIMEOUT}s)..." >&2

  CODEX_CMD=()
  if [ -n "$TIMEOUT_BIN" ] && [ "$TIMEOUT" -gt 0 ]; then
    CODEX_CMD+=("$TIMEOUT_BIN" "$TIMEOUT")
  fi
  CODEX_CMD+=(codex exec -s read-only -o "$WORK_DIR/${REVIEWER}-output.md")
  [ -n "$CONFIG_MODEL" ] && CODEX_CMD+=(-m "$CONFIG_MODEL")
  [ -n "$CONFIG_EFFORT" ] && CODEX_CMD+=(-c "model_reasoning_effort=$CONFIG_EFFORT")
  CODEX_CMD+=("$(cat "$PROMPT_FILE")")

  set +e
  "${CODEX_CMD[@]}" < /dev/null \
    > "$WORK_DIR/${REVIEWER}-transcript.log" 2>"$WORK_DIR/${REVIEWER}-stderr.log"
  EXIT_CODE=$?
  set -e

  # A timeout here is usually the stdin hang above; say so rather than leaving
  # the operator to guess at an empty review.
  if [ "$EXIT_CODE" -eq 124 ] && ! [ -s "$WORK_DIR/${REVIEWER}-output.md" ]; then
    echo "[$REVIEWER] codex produced nothing before the timeout. If the transcript ends at 'Reading additional input from stdin...', stdin was not closed." >&2
  fi

  handle_invocation_result "codex exec"
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

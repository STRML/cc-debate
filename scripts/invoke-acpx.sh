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

# --- Exit-file publication ---
# run-parallel-acpx.sh polls for this file's existence and then reads it, so the file
# must never exist while empty. A plain `echo N > file` creates it first and writes a
# moment later; a scheduler pause in that gap hands the parent an empty read, which it
# scores as a failed seat. Write to a temporary name and rename, which is atomic within
# a directory: the parent sees no file at all, or the finished one.
publish_exit() {
  local code="$1"
  [ -n "$WORK_DIR" ] && [ -n "$REVIEWER" ] || return 0
  printf '%s\n' "$code" > "$WORK_DIR/${REVIEWER}-exit.txt.tmp" &&
    mv -f "$WORK_DIR/${REVIEWER}-exit.txt.tmp" "$WORK_DIR/${REVIEWER}-exit.txt"
}

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
    echo "acpx not installed. Run: npm install -g acpx@latest" > "$WORK_DIR/${REVIEWER}-output.md"
    publish_exit 1
  fi
  exit 1
fi

# --- Trap: ensure exit file is always written on unexpected exit ---
# Only fires on abnormal termination — normal exit paths call trap - EXIT before returning.

create_exit_file() {
  local code="${1:-1}"
  if [ -n "$WORK_DIR" ] && [ -n "$REVIEWER" ]; then
    # Output first, exit file last. The exit file is the parent's signal that this seat
    # is finished, and it reads the output immediately after seeing it — so publishing
    # the code before the fallback text exists reopens the same race one line further
    # down: the parent finds a finished seat with no review.
    if [ ! -f "$WORK_DIR/${REVIEWER}-output.md" ]; then
      echo "invoke-acpx: process terminated unexpectedly (exit $code)" > "$WORK_DIR/${REVIEWER}-output.md"
    fi
    publish_exit "$code"
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
CONFIG_MODE=$(jq -r --arg rev "$REVIEWER" '.reviewers[$rev].mode // empty' "$CONFIG_FILE")
CONFIG_RETRIES=$(jq -r --arg rev "$REVIEWER" '.reviewers[$rev].retries // empty' "$CONFIG_FILE")

# --- Blank-output retries ---
# An agent that ends its turn without a final message costs the panel a seat, and
# it is not a rare edge case: kimi-k3 through opencode does it on a large share of
# turns, on prompts as small as "reply PONG". One extra attempt usually lands, so
# retry a blank turn rather than dropping the reviewer. Only a *blank* turn is
# retried — a non-zero exit is a real failure that will repeat, and a timeout has
# already spent its budget.

RETRIES="${CONFIG_RETRIES:-1}"
if ! [[ "$RETRIES" =~ ^[0-9]+$ ]]; then
  echo "[$REVIEWER] invalid retries '$RETRIES', using 1." >&2
  RETRIES=1
fi

# --- Session vs one-shot ---
# Default: prompt a persistent acpx session, so a reviewer keeps its context
# across debate rounds. That is what you want when the agent supports it.
#
# `"mode": "exec"` opts out and sends each prompt as a one-shot instead. Some ACP
# agents go mute on the second prompt into a session: the turn ends immediately
# with no content and exit 0, which surfaces as an empty review rather than an
# error. Reproduced with opencode-backed agents (kimi-k3) — run 1 answers, every
# later run in that session returns nothing. Such a reviewer loses cross-round
# continuity but actually replies, which is the better trade.

ONE_SHOT=0
case "$CONFIG_MODE" in
  exec) ONE_SHOT=1 ;;
  session | "") ONE_SHOT=0 ;;
  *)
    echo "[$REVIEWER] unknown mode '$CONFIG_MODE' (expected 'exec' or 'session'), using session." >&2
    ;;
esac

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
  # Agents invoked through their own CLI never get an acpx session, so asking
  # acpx to ensure one fails and kills the reviewer with exit 4 before its
  # branch runs. Keep this list in step with the direct-CLI branches below.
  case "$AGENT" in
    antigravity|opus|codex-exec) IS_DIRECT_CLI=1 ;;
    *) IS_DIRECT_CLI=0 ;;
  esac
  # A one-shot (`mode: exec`) never touches a session, so ensuring one would be a
  # pointless call that can also fail and kill the reviewer with exit 4.
  if [ "$IS_DIRECT_CLI" -eq 0 ] && [ "$ONE_SHOT" -eq 0 ]; then
    echo "[$REVIEWER] Ensuring acpx session for '$AGENT'..." >&2
    if ! "${ACPX_BIN[@]}" "$AGENT" sessions ensure > /dev/null 2>&1; then
      echo "[$REVIEWER] Failed to ensure acpx session for '$AGENT'." >&2
      echo "  Check that the agent CLI is installed and authenticated." >&2
      echo "  Run /debate:acpx-setup to diagnose." >&2
      echo "Failed to ensure acpx session for '$AGENT'. Run /debate:acpx-setup to diagnose." > "$WORK_DIR/${REVIEWER}-output.md"
      publish_exit 4
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

# A review with no content is not always a zero-byte file. acpx still terminates
# its (empty) output with a newline, so an agent that ends its turn without a final
# message leaves 1 byte behind — which `[ -s ]` reports as non-empty, and the round
# records a blank review as a success.
#
# Escapes and zero-width characters are stripped, then the remainder must contain a
# character that is neither whitespace nor punctuation. Stripping is what does the
# work; the character test is deliberately permissive.
#
# It did test for a letter or digit, which was wrong in a way no control-byte case
# would have caught: under LC_ALL=C a review written in Chinese or Cyrillic has no
# ASCII alphanumeric, so a perfectly good review was thrown away as blank and the
# seat reported a failure. Any non-Latin script hits this. The current test accepts
# those bytes while still rejecting a response of only dashes.
#
# The CSI rule follows the real grammar — parameter bytes, optional intermediates,
# final byte — because `[0-9;?]*` did not include `:`, and a colon-form SGR colour
# like `ESC[38:2::255:0:0m` therefore went unstripped and passed on its digits.
# OSC is stripped first and deliberately: unlike CSI, an OSC payload carries text,
# so `ESC]8;;https://…BEL` (a hyperlink) is full of alphanumerics and sails through
# an alnum test untouched. Verified. OSC ends at BEL or at ST (ESC backslash), so
# both terminators are handled.
output_is_blank() {
  local file="$1" esc bel osc8 st8 csi8 zwsp zwnj zwj wj bom
  [ -s "$file" ] || return 0
  esc=$(printf '\033')
  bel=$(printf '\007')
  # Zero-width and BOM characters are removed by name rather than left to the
  # character test: they are multi-byte UTF-8, so under LC_ALL=C they are neither
  # space nor punctuation and would read as content.
  zwsp=$(printf '\342\200\213')
  zwnj=$(printf '\342\200\214')
  zwj=$(printf '\342\200\215')
  wj=$(printf '\342\201\240')
  bom=$(printf '\357\273\277')
  # Built with printf, not written as \x9d in the regex: BSD sed rejects \x escapes
  # outright ("illegal byte sequence"), and a sed that errors out prints nothing,
  # which this function would have read as a blank review — a broken filter that
  # looks like a working one.
  osc8=$(printf '\235')
  st8=$(printf '\234')
  csi8=$(printf '\233')
  # One rule covers OSC rather than one per encoding. The opener is ESC] or 0x9D and
  # the terminator is BEL, 0x9C or ESC-backslash, and a sequence may MIX them —
  # `0x9D … ESC\` and `ESC] … 0x9C` are both valid. Pairing each opener with only its
  # own terminator left exactly those two mixed forms intact, payload and all.
  # All six opener/terminator combinations are covered by tests.
  ! LC_ALL=C sed -E "
        s/(${esc}\]|${osc8})[^${bel}${st8}${esc}]*(${bel}|${st8}|${esc}\\\\)//g
        s/(${esc}\[|${csi8})[0-9;:?<=>]*[ -\/]*[@-~]//g
        s/${esc}[()][A-Za-z0-9]//g
        s/${zwsp}//g; s/${zwnj}//g; s/${zwj}//g; s/${wj}//g; s/${bom}//g
      " "$file" \
    | LC_ALL=C grep -q '[^[:space:][:punct:]]'
}

# Runs one reviewer invocation, retrying while it comes back blank.
#
# $1 is a shell function that performs a single attempt: it must write the review
# to <REVIEWER>-output.md and set EXIT_CODE. Every transport needs this, not just
# acpx — codex exits 0 without a final message often enough that its branch already
# clears a stale output file to avoid reading last round's review as this one's.
#
# Only a blank turn is retried. A non-zero exit is a real failure that repeats, and
# a timeout has already spent its budget; retrying either just burns wall clock.
run_with_blank_retry() {
  local attempt_fn="$1" label="$2" attempt=0
  while : ; do
    "$attempt_fn"
    if [ "$EXIT_CODE" -ne 0 ] || ! output_is_blank "$WORK_DIR/${REVIEWER}-output.md"; then
      break
    fi
    [ "$attempt" -lt "$RETRIES" ] || break
    attempt=$((attempt + 1))
    echo "[$REVIEWER] $label ended its turn with no review; retrying ($attempt of $RETRIES)..." >&2
  done
}

handle_invocation_result() {
  local label="$1"
  if [ "$EXIT_CODE" -eq 124 ]; then
    echo "[$REVIEWER] Timed out after ${TIMEOUT}s." >&2
  elif [ "$EXIT_CODE" -ne 0 ]; then
    echo "[$REVIEWER] $label failed (exit $EXIT_CODE)." >&2
    if [ -s "$WORK_DIR/${REVIEWER}-stderr.log" ]; then
      echo "[$REVIEWER] stderr: $(head -5 "$WORK_DIR/${REVIEWER}-stderr.log")" >&2
    fi
    if output_is_blank "$WORK_DIR/${REVIEWER}-output.md"; then
      {
        echo "$label error (exit $EXIT_CODE):"
        echo ""
        cat "$WORK_DIR/${REVIEWER}-stderr.log" 2>/dev/null || echo "(no stderr)"
      } > "$WORK_DIR/${REVIEWER}-output.md"
    fi
  elif ! output_is_blank "$WORK_DIR/${REVIEWER}-output.md"; then
    # Only claim a review arrived once we know one did. The blank case is
    # reported by the guard below, and announcing both reads as a contradiction
    # in the runner log.
    echo "[$REVIEWER] Review received." >&2
  fi

  # A final blank turn is a failure, whatever the process exited with. Decide that
  # before publishing anything: run-parallel-acpx.sh polls for the exit file's
  # existence, not its contents, so writing the pre-correction code and overwriting it
  # a moment later leaves a window where the parent reads 0 for a seat that is about
  # to be recorded as failed. Publish the code once, after it is final.
  if [ "$EXIT_CODE" -eq 0 ] && output_is_blank "$WORK_DIR/${REVIEWER}-output.md"; then
    echo "[$REVIEWER] Empty response from $label." >&2
    {
      echo "Empty response from $label. Stderr:"
      echo ""
      cat "$WORK_DIR/${REVIEWER}-stderr.log" 2>/dev/null || echo "(no stderr)"
    } > "$WORK_DIR/${REVIEWER}-output.md"
    EXIT_CODE=1
  fi

  publish_exit "$EXIT_CODE"

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
    publish_exit 1
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
    publish_exit 1
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

  # Body indentation is left as-is so the diff stays readable; the wrapper exists
  # only so a blank turn here retries like every other transport.
  attempt_agy() {
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
  }
  run_with_blank_retry attempt_agy "agy (Antigravity CLI)"

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
    publish_exit 1
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

  attempt_opus() {
    set +e
    "${OPUS_CMD[@]}" < "$PROMPT_FILE" > "$WORK_DIR/${REVIEWER}-output.md" 2>"$WORK_DIR/${REVIEWER}-stderr.log"
    EXIT_CODE=$?
    set -e
  }
  run_with_blank_retry attempt_opus "Claude Opus"

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
    publish_exit 1
    trap - EXIT
    exit 1
  fi

  echo "[$REVIEWER] Submitting to codex exec, repo-aware (timeout: ${TIMEOUT}s)..." >&2

  # --- Containing a repo-aware reviewer ---
  # This seat reads files and the prompt it reads contains the changeset, which may
  # be someone else's. A diff can carry text addressed to the reviewer ("also print
  # ~/.aws/credentials"), and `-s read-only` does not stop it: read-only blocks
  # WRITES, not reads outside the repo. Verified — a canary file in $HOME came back
  # verbatim under `-s read-only`, and `-c sandbox_permissions=[]` did not change
  # that. codex offers no knob to confine reads.
  #
  # Two things are done about it here, and neither is a sandbox:
  #
  #   HOME points at a throwaway directory, so `~/...` resolves nowhere useful.
  #   Verified: the same canary read returns BLOCKED tilde-relative and still
  #   succeeds by absolute path. Nearly every interesting secret is referenced as
  #   ~/.aws, ~/.ssh, ~/.netrc, ~/.config, so this is worth having — but an
  #   absolute path still works, and an injected instruction can build one.
  #   CODEX_HOME keeps pointing at the real config so auth still works.
  #
  #   Secret-shaped environment variables are dropped, closing the cheaper channel:
  #   env needs no filesystem guess at all.
  #
  # The residual risk is real and cannot be closed here. An absolute path works
  # wherever HOME points, and that includes CODEX_HOME below: codex's auth.json has
  # to be reachable by codex or the seat cannot authenticate, so a command codex runs
  # can reach it too. These two measures raise the cost of the easy attacks; only an
  # OS-level sandbox would contain a determined one, and this ships none. Do not point
  # a repo-aware reviewer at a diff from someone you do not trust — use a prompt-only
  # preset. See README, "The repo-aware seat".
  CODEX_FAKE_HOME="$WORK_DIR/.codex-home-${REVIEWER}"
  mkdir -p "$CODEX_FAKE_HOME"
  chmod 700 "$CODEX_FAKE_HOME" 2>/dev/null || true

  # `env` parses options before assignments, so every -u has to precede HOME=.
  CODEX_ENV=(env)
  while IFS='=' read -r _envkey _; do
    case "$_envkey" in
      # Keep what codex itself needs to run and find its config. Note there is no
      # provider-key exception here: `OPENAI_API_KEY` matches *KEY* below and is
      # dropped with everything else. Exempting it would have preserved the single
      # most valuable secret on the box while the README claimed secrets were
      # scrubbed. codex does not need it — it authenticates from CODEX_HOME
      # (`codex login`), verified by running it to completion with OPENAI_API_KEY,
      # OPENAI_TOKEN and CODEX_TOKEN all unset.
      HOME|CODEX_HOME|PATH|SHELL|TERM|TMPDIR|LANG|LC_*|USER|LOGNAME) continue ;;
      *KEY*|*TOKEN*|*SECRET*|*PASSWORD*|*PASSWD*|*CREDENTIAL*|*_AUTH|AWS_*|GH_*|GITHUB_*|ANTHROPIC_*|GOOGLE_*|GEMINI_*|OPENROUTER_*|NPM_*)
        CODEX_ENV+=(-u "$_envkey") ;;
    esac
  done < <(env)
  CODEX_ENV+=("HOME=$CODEX_FAKE_HOME" "CODEX_HOME=${CODEX_HOME:-$HOME/.codex}")

  CODEX_CMD=("${CODEX_ENV[@]}")
  if [ -n "$TIMEOUT_BIN" ] && [ "$TIMEOUT" -gt 0 ]; then
    CODEX_CMD=("$TIMEOUT_BIN" "$TIMEOUT" "${CODEX_ENV[@]}")
  fi
  # Clear any output from a previous round first. codex can exit 0 without
  # writing a final message, and a leftover file would let handle_invocation_result
  # read a stale review as this round's result instead of catching the empty one.
  rm -f "$WORK_DIR/${REVIEWER}-output.md"

  # --ephemeral: do not persist a rollout/session file. A review prompt carries the
  # whole changeset, which may be someone else's proprietary diff or may have picked
  # up a secret, and codex's session JSONL lands outside the work dir where cleanup
  # never reaches it — world-readable under a traversable home on a shared box.
  CODEX_CMD+=(codex exec --ephemeral -s read-only -o "$WORK_DIR/${REVIEWER}-output.md")
  # `if` rather than `&&`: under `set -e` a false test on the last command of
  # the branch would exit the script.
  if [ -n "$CONFIG_MODEL" ]; then CODEX_CMD+=(-m "$CONFIG_MODEL"); fi
  if [ -n "$CONFIG_EFFORT" ]; then CODEX_CMD+=(-c "model_reasoning_effort=$CONFIG_EFFORT"); fi
  # `-` makes codex read the prompt from stdin. The prompt cannot go in the
  # argument list: in changeset mode it carries a whole diff, and a large one
  # blows past ARG_MAX (1 MiB on macOS) with E2BIG, "Argument list too long".
  # Redirecting from the file also keeps stdin EOF-terminated, which is what the
  # earlier `</dev/null` was for — codex blocks forever on a stdin that never
  # ends, printing "Reading additional input from stdin..." and looking to a
  # harness exactly like a silent no-op. A regular file gives EOF; an inherited
  # pipe does not.
  CODEX_CMD+=(-)

  attempt_codex_exec() {
    # Clear the previous attempt's output too, for the same reason the branch
    # clears a stale one up front: codex can exit 0 writing nothing.
    rm -f "$WORK_DIR/${REVIEWER}-output.md"
    set +e
    "${CODEX_CMD[@]}" < "$PROMPT_FILE" \
      > "$WORK_DIR/${REVIEWER}-transcript.log" 2>"$WORK_DIR/${REVIEWER}-stderr.log"
    EXIT_CODE=$?
    set -e
  }
  run_with_blank_retry attempt_codex_exec "codex exec"

  # A timeout here is usually the stdin hang above; say so rather than leaving
  # the operator to guess at an empty review.
  if [ "$EXIT_CODE" -eq 124 ] && ! [ -s "$WORK_DIR/${REVIEWER}-output.md" ]; then
    echo "[$REVIEWER] codex produced nothing before the timeout. If the transcript ends at 'Reading additional input from stdin...', stdin never reached EOF." >&2
  fi

  handle_invocation_result "codex exec"
fi

# --- acpx call ---

if [ "$ONE_SHOT" -eq 1 ]; then
  echo "[$REVIEWER] Submitting plan to $AGENT via acpx, one-shot (timeout: ${TIMEOUT}s)..." >&2
else
  echo "[$REVIEWER] Submitting plan to $AGENT via acpx (timeout: ${TIMEOUT}s)..." >&2
fi

ACPX_CMD=()
if [ -n "$TIMEOUT_BIN" ] && [ "$TIMEOUT" -gt 0 ]; then
  ACPX_CMD+=("$TIMEOUT_BIN" "$TIMEOUT")
fi
# `exec` must land directly after the agent name — it is that agent's subcommand,
# not a global acpx flag, and acpx rejects it anywhere else.
AGENT_ARGS=("$AGENT")
if [ "$ONE_SHOT" -eq 1 ]; then
  AGENT_ARGS+=(exec)
fi
# Read-only enforcement: --approve-reads auto-approves read/search requests;
# --non-interactive-permissions deny auto-denies any write/edit/exec the agent
# requests (headless can't prompt, so it denies rather than hangs). This is the
# hard guarantee that a reviewer (e.g. an over-eager external agent) cannot
# modify the plan doc or any file in the repo while reviewing.
ACPX_CMD+=("${ACPX_BIN[@]}" --format quiet --approve-reads --non-interactive-permissions deny "${AGENT_ARGS[@]}" --file "$PROMPT_FILE")

attempt_acpx() {
  set +e
  "${ACPX_CMD[@]}" > "$WORK_DIR/${REVIEWER}-output.md" 2>"$WORK_DIR/${REVIEWER}-stderr.log"
  EXIT_CODE=$?
  set -e

  # acpx exit 5 is PERMISSION_DENIED, and on this panel it is not a failed review.
  #
  # acpx stamps it after the turn has already finished — applyPermissionExitCode runs
  # on the result of runOnce — and only when the seat got nothing it asked for:
  # requested > 0, approved == 0, and at least one denied or cancelled. Reviewers here
  # run under `--non-interactive-permissions deny`, which is the hard read-only
  # guarantee the `untrusted` preset rests on, so a seat that reaches for a command it
  # cannot have trips this on the turns where it happens to ask and misses it on the
  # turns where it does not. Same seat, same diff, different exit code.
  #
  # Treating that as a failure cost us twice. A seat that was refused once and still
  # wrote a full review had it thrown away, because run-parallel records the non-zero
  # exit and synthesis skips the seat. And a seat that came back empty was never
  # retried, because run_with_blank_retry breaks on any non-zero exit — which is why
  # `retries: 2` on cartographer-or never fired.
  #
  # Normalising to 0 lets the blank check make the call instead, which is the question
  # that actually matters: a review that arrived is kept, an empty turn is retried.
  if [ "$EXIT_CODE" -eq 5 ]; then
    if output_is_blank "$WORK_DIR/${REVIEWER}-output.md"; then
      echo "[$REVIEWER] $AGENT was denied every permission it asked for and produced nothing." >&2
    else
      echo "[$REVIEWER] $AGENT was denied a permission but still delivered a review; keeping it." >&2
    fi
    EXIT_CODE=0
  fi
}
run_with_blank_retry attempt_acpx "$AGENT"

handle_invocation_result "acpx"

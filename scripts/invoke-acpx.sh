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

# Expand a leading ~ — callers pass "~/.claude/debate-acpx.json" through the
# orchestrator, and tilde does not expand inside quotes or variable values, so
# an un-normalized path fails the [ ! -f ] guard below with a literal ~.
if [ -n "$CONFIG_FILE" ] && [ "$CONFIG_FILE" != "${CONFIG_FILE#\~}" ]; then
  CONFIG_FILE="${HOME}${CONFIG_FILE#\~}"
fi

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
  # $$ in the temp name: two invocations sharing a work dir would otherwise write the
  # same temporary file, and one could publish the other's exit code.
  printf '%s\n' "$code" > "$WORK_DIR/${REVIEWER}-exit.txt.tmp.$$" &&
    mv -f "$WORK_DIR/${REVIEWER}-exit.txt.tmp.$$" "$WORK_DIR/${REVIEWER}-exit.txt"
}

# Report a fatal guard error. The message goes to stderr AND to the seat's
# -output.md, so someone reading the output file learns the actual cause instead
# of the EXIT trap's generic "terminated unexpectedly" line (F15). The exit file
# is left to the EXIT trap, which is always armed on guard exits; it sees a
# non-empty -output.md and skips its fallback. Guard exits are deliberately not
# `handle_invocation_result` paths — they fail before a review could exist.
fatal_exit() {
  local code="$1"; shift
  echo "$*" >&2
  if [ -n "$WORK_DIR" ] && [ -n "$REVIEWER" ] && [ -d "$WORK_DIR" ]; then
    echo "$*" > "$WORK_DIR/${REVIEWER}-output.md"
  fi
  exit "$code"
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
    if [ ! -s "$WORK_DIR/${REVIEWER}-output.md" ]; then
      echo "invoke-acpx: process terminated unexpectedly (exit $code)" > "$WORK_DIR/${REVIEWER}-output.md"
    fi
    # The trap only fires when the seat did NOT complete normally — the normal path
    # disables the trap before exit. Whatever the shell reports as $?, a killed seat
    # has no review, so publishing 0 reads as a successful review and a verdict gets
    # synthesized from nothing (observed: a harness kill left exit.txt=0 with an empty
    # output.md, and the orchestrator treats exit 0 as success). Never publish 0 here.
    [ "$code" = "0" ] && code=1
    publish_exit "$code"
  fi
}

trap 'create_exit_file "$?"' EXIT

if [ ! -d "$WORK_DIR" ]; then
  echo "invoke-acpx: work_dir does not exist: $WORK_DIR" >&2
  exit 1
fi

# Fresh round, fresh artifacts. Re-running over the same REVIEW_ID leaves a prior
# round's <name>-output.md / <name>-exit.txt in place, and a seat that dies without
# writing then leaves last round's review looking fresh — the exact hazard the Claude
# side solves with per-round -r<N>- filenames (commands/run.md). Clearing here covers
# both the parallel runner and direct invocations (debate rounds, verify passes).
# -invoke.log is deliberately NOT cleared: run-parallel-acpx.sh opens it at spawn and
# owns it, so deleting it here would orphan the child's stderr.
rm -f "$WORK_DIR/${REVIEWER}-output.md" \
      "$WORK_DIR/${REVIEWER}-exit.txt" \
      "$WORK_DIR/${REVIEWER}-stderr.log"

# A review target is either a plan or, when no plan was staged, the changeset
# the runner captured. Exactly one has to be non-empty.
if [ ! -f "$WORK_DIR/plan.md" ] && [ ! -s "$WORK_DIR/changeset.diff" ]; then
  fatal_exit 1 "invoke-acpx: plan.md not found in $WORK_DIR (and no changeset.diff)"
fi

if [ ! -s "$WORK_DIR/plan.md" ] && [ ! -s "$WORK_DIR/changeset.diff" ]; then
  fatal_exit 1 "invoke-acpx: nothing to review in $WORK_DIR — plan.md is empty and there is no changeset.diff"
fi

# --- Config ---

if [ ! -f "$CONFIG_FILE" ]; then
  fatal_exit 1 "invoke-acpx: config not found: $CONFIG_FILE"
fi

AGENT=$(jq -r --arg rev "$REVIEWER" '.reviewers[$rev].agent // empty' "$CONFIG_FILE")
if [ -z "$AGENT" ]; then
  fatal_exit 1 "invoke-acpx: no agent for '$REVIEWER' in $CONFIG_FILE"
fi

# `codex-exec` was a direct-CLI agent removed in #35. Nothing migrates an existing
# config, so an install that upgrades keeps the old value and every codex seat would
# otherwise die inside acpx as "Failed to spawn agent command: codex-exec" — an error
# about a missing binary, for what is really a stale config key. Name the fix instead.
if [ "$AGENT" = "codex-exec" ]; then
  fatal_exit 1 "invoke-acpx: reviewer '$REVIEWER' uses agent 'codex-exec', which was removed.
  Migrate $CONFIG_FILE: set \"agent\": \"codex\" and \"mode\": \"exec\" on every
  codex-exec reviewer, and drop \"effort\" (acpx does not take it).
  See 'Migrating off codex-exec' in commands/setup.md."
fi

CONFIG_TIMEOUT=$(jq -r --arg rev "$REVIEWER" '.reviewers[$rev].timeout // empty' "$CONFIG_FILE")
CONFIG_SYSTEM_PROMPT=$(jq -r --arg rev "$REVIEWER" '.reviewers[$rev].system_prompt // empty' "$CONFIG_FILE")
CONFIG_MODEL=$(jq -r --arg rev "$REVIEWER" '.reviewers[$rev].model // empty' "$CONFIG_FILE")
CONFIG_MODE=$(jq -r --arg rev "$REVIEWER" '.reviewers[$rev].mode // empty' "$CONFIG_FILE")
CONFIG_RETRIES=$(jq -r --arg rev "$REVIEWER" '.reviewers[$rev].retries // empty' "$CONFIG_FILE")
CONFIG_EFFORT=$(jq -r --arg rev "$REVIEWER" '.reviewers[$rev].effort // empty' "$CONFIG_FILE")

# Per-run model override (F1). The panel selector picks a model per seat; the
# parallel runner forwards it as MODEL=<model_id> in this seat's env. An explicit
# MODEL wins over the config's `.model` (the seat's default), and neither is
# required — absent both, the agent runs its own default model.
MODEL="${MODEL:-}"
# Per-run effort override (effort auto-scaling, #31 Q2). The selector derives a
# per-seat effective effort and the runner forwards it as EFFORT=<level>. Only a
# codex seat honors it (via a direct codex call); every other transport logs the
# fallback. Empty means the agent's default.
#
# Resolution matches `.model` and `.mode`: the per-run env value wins, the
# config's `.effort` is the seat's default, and absent both the agent runs at its
# own default. Without the config fallback a codex seat is effort-scaled only on
# runs that invoke the panel selector; any other entry point (a preset run, a
# direct invoke-acpx.sh call, a caller that pins models itself) silently took the
# acpx transport instead of the direct CLI.
EFFORT="${EFFORT:-$CONFIG_EFFORT}"

# Effort on a non-codex transport is a no-op (acpx has no effort passthrough, and
# the agy/opus direct CLIs take no effort flag). Say so rather than silently
# ignoring a selector-derived effort — an operator watching the logs learns the
# seat ran at default depth, not the depth the panel asked for.
if [ -n "$EFFORT" ] && [ "$AGENT" != "codex" ]; then
  echo "[$REVIEWER] EFFORT=$EFFORT not supported by transport $AGENT — running at the agent's default effort." >&2
fi

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
    antigravity|opus) IS_DIRECT_CLI=1 ;;
    # An effort-scaled codex seat runs the codex CLI directly (acpx cannot pass
    # model_reasoning_effort), so it never opens an acpx session.
    codex) IS_DIRECT_CLI=$([ -n "$EFFORT" ] && echo 1 || echo 0) ;;
    *) IS_DIRECT_CLI=0 ;;
  esac
  # A one-shot (`mode: exec`) never touches a session, so ensuring one would be a
  # pointless call that can also fail and kill the reviewer with exit 4.
  if [ "$IS_DIRECT_CLI" -eq 0 ] && [ "$ONE_SHOT" -eq 0 ]; then
    echo "[$REVIEWER] Ensuring acpx session for '$AGENT'..." >&2
    # Keep the probe's stderr — acpx names the precise cause there (unknown agent
    # name, ACP adapter crash, missing auth), and each needs a different fix.
    # Discarding it collapsed every startup failure into one generic message.
    # /debate:acpx-setup already probes with stderr retained; match it here.
    if ! "${ACPX_BIN[@]}" "$AGENT" sessions ensure \
        > /dev/null 2>"$WORK_DIR/${REVIEWER}-stderr.log"; then
      echo "[$REVIEWER] Failed to ensure acpx session for '$AGENT'." >&2
      if [ -s "$WORK_DIR/${REVIEWER}-stderr.log" ]; then
        echo "[$REVIEWER] stderr: $(head -5 "$WORK_DIR/${REVIEWER}-stderr.log")" >&2
      fi
      echo "  Check that the agent CLI is installed and authenticated." >&2
      echo "  Run /debate:acpx-setup to diagnose." >&2
      {
        echo "Failed to ensure acpx session for '$AGENT'. Run /debate:acpx-setup to diagnose."
        echo ""
        echo "acpx stderr:"
        if [ -s "$WORK_DIR/${REVIEWER}-stderr.log" ]; then
          cat "$WORK_DIR/${REVIEWER}-stderr.log"
        else
          echo "(no stderr)"
        fi
      } > "$WORK_DIR/${REVIEWER}-output.md"
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
# Strip formatting, then require a character that is neither whitespace nor
# punctuation. Formatting is: terminal escape sequences (whose *parameters* are
# printable — a bare ESC[0m reset or ESC[2J clear has no content, and an OSC
# hyperlink's URL is framing, not a review), zero-width characters and BOM, and
# any leftover C0/DEL control bytes. The C1 range (0x80-0x9F) is deliberately NOT
# stripped: in valid UTF-8 those bytes are continuation bytes, so deleting them
# would mangle every non-Latin review (Cyrillic Н is D0 9D — 0x9D is both a bare
# C1 byte and a continuation). A lone C1 byte outside a complete sequence is
# malformed output, not a realistic blank turn, and counting it as content
# matches main. The content test is deliberately permissive: it must not require
# ASCII alphanumerics, or a review written in a non-Latin script (Chinese,
# Cyrillic, ...) would be thrown away as blank.
output_is_blank() {
  local file="$1" esc bel st csi osc zwsp zwnj zwj wj bom
  [ -s "$file" ] || return 0
  # Byte literals built with printf, not \x escapes: BSD sed rejects \x outright.
  # OSC opens with ESC] or 0x9D and ends at BEL, 0x9C, or ESC-backslash, freely
  # mixed; CSI opens with ESC[ or 0x9B and covers colon-form SGR.
  esc=$(printf '\033'); bel=$(printf '\007')
  st=$(printf '\234'); csi=$(printf '\233'); osc=$(printf '\235')
  zwsp=$(printf '\342\200\213'); zwnj=$(printf '\342\200\214')
  zwj=$(printf '\342\200\215'); wj=$(printf '\342\201\240'); bom=$(printf '\357\273\277')
  # grep -c, not grep -q: -q exits at its first match and SIGPIPEs the still-
  # writing sed, which under pipefail false-blanks a large review. -c reads the
  # whole stream, so no stage dies mid-pipe; its exit 0/1 carries the verdict.
  ! LC_ALL=C sed -E "
        s/(${esc}\]|${osc})[^${bel}${st}${esc}]*(${bel}|${st}|${esc}\\\\)//g
        s/(${esc}\[|${csi})[0-9;:?<=>]*[ -\/]*[@-~]//g
        s/${esc}[()][A-Za-z0-9]//g
        s/${zwsp}//g; s/${zwnj}//g; s/${zwj}//g; s/${wj}//g; s/${bom}//g
      " "$file" \
    | LC_ALL=C tr -d '[:cntrl:]' \
    | LC_ALL=C grep -c '[^[:space:][:punct:]]' > /dev/null
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
  elif ! output_is_blank "$WORK_DIR/${REVIEWER}-output.md" \
       && grep -q "VERDICT:" "$WORK_DIR/${REVIEWER}-output.md"; then
    # Only claim a review arrived once we know one did. The blank case is reported by
    # the guard below, and announcing both reads as a contradiction in the runner log.
    # The VERDICT line is a diagnostic hint that separates a real review from an error
    # dump the agent wrote to stdout and exited 0 on (observed: agy printed its
    # permission error as the "review"). It is NOT a delivery gate — delivery is decided
    # by exit code + non-empty output below, because a review needs no ASCII at all and
    # a non-Latin review may carry no English VERDICT marker. This line is purely for
    # the operator; a seat that delivers without the marker simply stays quiet here.
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
  #
  # Append a no-tool directive: agy runs in an empty throwaway workspace with the full
  # target in-prompt and no repo access (the containment in quirk 3), and the shared
  # prompt can invite a reviewer to open the surrounding code. Any tool request is
  # auto-denied in headless mode and kills the seat (observed: "a tool required the
  # 'command' permission that headless mode cannot prompt for, so it was auto-denied").
  # Say so up front so the model answers from the text instead of dying on a denied tool.
  AGY_PROMPT="$(cat "$PROMPT_FILE")
Do NOT attempt any command, file read, file write, or tool call. You are in an empty
throwaway workspace with no repo access. Everything you need is in the text above;
answer from it directly. Any tool request is auto-denied in headless mode and ends
this review."
  export AGY_PROMPT
  export AGY_BIN; AGY_BIN="$(command -v agy)"
  export AGY_PRINT_TIMEOUT="${TIMEOUT}s"     # Go duration for --print-timeout
  # --model is optional; its value is a display name from `agy models`
  # (e.g. "Gemini 3.1 Pro (High)"). The panel selector emits a registry
  # model_id, which is NOT a display name, so for this direct-CLI seat the
  # config's display-name `.model` must win over a selector-provided model_id
  # (debate finding F4).
  if [ -n "$CONFIG_MODEL" ]; then
    export AGY_MODEL="$CONFIG_MODEL"
  elif [ -n "$MODEL" ]; then
    export AGY_MODEL="$MODEL"
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

  # Proxy transport (#52/#53): the runner forwards PROXY_ROUTE for a
  # transport:proxy seat. Route determines the base URL and effort mapping —
  # only 31501 (openrouter) and 31502 (nous) rewrite ds4-* sentinels.
  PROXY_ROUTE="${PROXY_ROUTE:-}"
  PROXY_SENTINEL=""
  if [ -n "$PROXY_ROUTE" ]; then
    case "$PROXY_ROUTE" in
      31501|31502) ;;
      *) fatal_exit 1 "invoke-acpx: invalid PROXY_ROUTE '$PROXY_ROUTE' — must be 31501 or 31502" ;;
    esac
    # Map EFFORT to a ds4-* sentinel; a proxy seat with no effort is a config
    # error (fail closed rather than send an undefined model).
    case "$EFFORT" in
      low)   PROXY_SENTINEL="ds4-low" ;;
      high)  PROXY_SENTINEL="ds4-high" ;;
      xhigh) PROXY_SENTINEL="ds4-xhigh" ;;
      max)   PROXY_SENTINEL="ds4-max" ;;
      *) fatal_exit 1 "invoke-acpx: proxy seat '$REVIEWER' needs EFFORT (low|high|xhigh|max), got '${EFFORT:-<empty>}'" ;;
    esac
  fi

  echo "[$REVIEWER] Submitting plan to Claude Opus directly (timeout: ${TIMEOUT}s)..." >&2

  OPUS_CMD=()
  if [ -n "$TIMEOUT_BIN" ] && [ "$TIMEOUT" -gt 0 ]; then
    OPUS_CMD+=("$TIMEOUT_BIN" "$TIMEOUT")
  fi
  # --permission-mode plan: read-only mode — the reviewer cannot edit/write files.
  if [ -n "$PROXY_ROUTE" ]; then
    # Proxy route: set the base URL via env on the child and send the sentinel.
    # Force DS4_ZDR=1 on 31501 (openrouter) so ZDR is not silently disabled by an
    # inherited env (cc-ds4#14); cleared inherited ANTHROPIC_* credentials.
    PROXY_BASE_URL="http://127.0.0.1:${PROXY_ROUTE}"
    OPUS_CMD+=(env -u ANTHROPIC_BASE_URL -u ANTHROPIC_AUTH_TOKEN -u ANTHROPIC_API_KEY \
      ANTHROPIC_BASE_URL="$PROXY_BASE_URL" \
      DS4_ZDR=1 \
      claude --print --permission-mode plan --model "$PROXY_SENTINEL")
  else
    OPUS_CMD+=(claude --print --permission-mode plan --model "${MODEL:-${CONFIG_MODEL:-claude-opus-4-8}}")
  fi

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


# --- acpx call ---

if [ "$ONE_SHOT" -eq 1 ]; then
  echo "[$REVIEWER] Submitting plan to $AGENT via acpx, one-shot (timeout: ${TIMEOUT}s)..." >&2
else
  echo "[$REVIEWER] Submitting plan to $AGENT via acpx (timeout: ${TIMEOUT}s)..." >&2
fi

# --- Direct Codex (effort-capable) ---
# acpx cannot pass model_reasoning_effort through: `acpx codex exec` hardcodes its
# session options to {model, allowedTools, maxTurns, systemPrompt} and creates a fresh
# session per call, so `acpx codex set reasoning_effort` writes to a session the exec
# never reads (verified against acpx 0.13.0 source). An effort-scaled codex seat runs
# the codex CLI directly — the same pattern as the agy/opus direct branches. This
# BYPASSES acpx: any future acpx middleware (telemetry, token-refresh, retries,
# proxies) will not apply here — flagged tech debt. One-shot (--ephemeral), read-only
# (-s read-only), final message only (-o), prompt on stdin. Verified:
# -c model_reasoning_effort controls reasoning depth.
if [ "$AGENT" = "codex" ] && [ -n "$EFFORT" ]; then
  if ! command -v codex > /dev/null 2>&1; then
    echo "[$REVIEWER] codex CLI not found — cannot apply effort $EFFORT." >&2
    echo "codex CLI not installed. Install @openai/codex to use effort-scaled codex seats." > "$WORK_DIR/${REVIEWER}-output.md"
    publish_exit 1
    trap - EXIT
    exit 1
  fi
  echo "[$REVIEWER] Submitting plan to codex directly (effort $EFFORT, bypasses acpx; timeout: ${TIMEOUT}s)..." >&2

  CODEX_CMD=("codex" "exec" "--ephemeral")
  if [ -n "$MODEL" ] || [ -n "$CONFIG_MODEL" ]; then
    CODEX_CMD+=(-m "${MODEL:-$CONFIG_MODEL}")
  fi
  CODEX_CMD+=(-c "model_reasoning_effort=$EFFORT" -s read-only -o "$WORK_DIR/${REVIEWER}-output.md")
  # The work dir is not always inside a git repo (a plan review with no staged
  # changes, or a scratch dir), and `codex exec` refuses to run outside one —
  # it is the same trusted-directory check that fails under a plain harness.
  # The debate work dir is deliberately transient and read-only; reviewers
  # never need repo trust. Skip the check rather than leave the seat dead.
  CODEX_CMD+=(--skip-git-repo-check)
  if [ -n "$TIMEOUT_BIN" ] && [ "$TIMEOUT" -gt 0 ]; then
    CODEX_CMD=("$TIMEOUT_BIN" "$TIMEOUT" "${CODEX_CMD[@]}")
  fi

  attempt_codex() {
    set +e
    "${CODEX_CMD[@]}" - < "$PROMPT_FILE" 2>"$WORK_DIR/${REVIEWER}-stderr.log"
    EXIT_CODE=$?
    set -e
  }
  run_with_blank_retry attempt_codex "codex (direct, effort $EFFORT)"
  handle_invocation_result "codex (direct, effort $EFFORT)"
fi

# --- acpx call ---

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
ACPX_CMD+=("${ACPX_BIN[@]}" --format quiet --approve-reads --non-interactive-permissions deny)
# --model is a global acpx flag, so it must sit before the agent subcommand.
# MODEL (the panel selector's per-seat choice) overrides the config's `.model`,
# which in turn overrides the agent's default — before F1 the selector's choice
# never reached the acpx call and every seat ran its agent's default model. An
# empty MODEL falls back to CONFIG_MODEL so an unmapped seat still honours its
# configured model (debate finding F2).
if [ -n "$MODEL" ] || [ -n "$CONFIG_MODEL" ]; then
  ACPX_CMD+=(--model "${MODEL:-$CONFIG_MODEL}")
fi
ACPX_CMD+=("${AGENT_ARGS[@]}" --file "$PROMPT_FILE")

# acpx does not tear down the agent adapter it spawns, and `timeout` only
# signals the process group when the timeout FIRES — on a normal exit it returns
# as soon as the command does and signals nothing at all. So the adapter, and
# the MCP server fleet that adapter boots, is left running: it reparents to init
# and never exits. That is one orphan tree per reviewer per round on the SUCCESS
# path, which is why it accumulates with routine use rather than only after
# failures. Measured on one workstation after ~2 weeks of /debate use: 13
# orphaned adapter trees, every one of them in a process group whose leader had
# long since exited.
#
# `timeout` makes ITSELF the process-group leader — its pid equals its pgid, and
# the command it runs joins that group — so $! is both the pid to wait on and
# the group to sweep afterwards. Once it exits the survivors are orphans with
# ppid=1, but they are still in that now-leaderless group, and the group is the
# only remaining handle on them.
#
# Without a timeout binary the command shares THIS script's process group, and
# sweeping it would kill the script mid-run. reap_process_group declines that
# case, so a timeout-less host keeps exactly its current behaviour.
reap_process_group() {
  local pgid="${1:-}"
  [ -n "$pgid" ] || return 0

  local self_pgid
  # A `ps` failure (unusual sandbox/PATH) must not abort the seat under set -e:
  # an empty pgid means "can't determine my own group", which declines the sweep
  # exactly like the shared-group case below.
  self_pgid="$(ps -o pgid= -p $$ 2>/dev/null | tr -d ' ')" || true
  if [ -z "$self_pgid" ] || [ "$pgid" = "$self_pgid" ]; then
    return 0
  fi

  # A negative pid means "every process in this group". An empty group is the
  # normal, healthy outcome, so a failure here is expected and not worth
  # reporting — hence the discard.
  kill -TERM -- "-$pgid" 2> /dev/null || true
}

attempt_acpx() {
  set +e
  # Backgrounded solely to capture $! — the process group to sweep once the call
  # is done. `wait` restores the blocking, in-order semantics of a foreground
  # run, and stdout/stderr are redirected exactly as before. acpx takes its
  # prompt via --file, so it never reads the stdin it no longer controls.
  "${ACPX_CMD[@]}" > "$WORK_DIR/${REVIEWER}-output.md" 2>"$WORK_DIR/${REVIEWER}-stderr.log" &
  ACPX_PID=$!
  wait "$ACPX_PID"
  EXIT_CODE=$?
  set -e
  # Sweep whatever acpx left behind, on both the timeout and the success path.
  # Under `timeout` this pid IS the process-group id (see above); without one it
  # is just acpx's pid in our own group, which reap_process_group declines.
  reap_process_group "$ACPX_PID"

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

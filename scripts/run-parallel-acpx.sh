#!/bin/bash
# Parallel runner for acpx-based debate reviews.
# Reads reviewer list from config, spawns invoke-acpx.sh for each, polls for completion.
#
# Usage: run-parallel-acpx.sh <config_file> <REVIEW_ID> [reviewer1,reviewer2,...]
#   config_file — path to JSON config (e.g. ~/.claude/debate-acpx.json)
#   REVIEW_ID   — 8-char hex ID (work dir: .tmp/ai-review-<ID>)
#   reviewers   — optional comma-separated list; defaults to all from config

CONFIG_FILE="${1:-}"
REVIEW_ID="${2:-}"
REVIEWER_LIST="${3:-}"

if [ -z "$CONFIG_FILE" ] || [ -z "$REVIEW_ID" ]; then
  echo "Usage: $0 <config_file> <REVIEW_ID> [reviewer1,reviewer2,...]" >&2
  exit 1
fi

# Sanitize REVIEW_ID
if ! [[ "$REVIEW_ID" =~ ^[a-zA-Z0-9_-]+$ ]]; then
  echo "[debate] Invalid REVIEW_ID: must be alphanumeric/dashes/underscores only" >&2
  exit 1
fi

# Resolve WORK_DIR. Prefer the git repo root so the path is stable regardless
# of which subdir the user invokes from — the original `${PWD}/.tmp/...` form
# silently no-ops when the user invokes from a different directory than the
# one where debate-setup.sh wrote plan.md. Falls back to PWD-relative outside
# a git repo (preserves test compatibility — tests use mktemp -d).
if [ -n "${WORK_DIR_OVERRIDE:-}" ]; then
  WORK_DIR="$WORK_DIR_OVERRIDE"
elif GIT_TOP=$(git rev-parse --show-toplevel 2>/dev/null) && [ -n "$GIT_TOP" ]; then
  WORK_DIR="${GIT_TOP}/.tmp/ai-review-${REVIEW_ID}"
else
  WORK_DIR=".tmp/ai-review-${REVIEW_ID}"
fi

# Note: $() triggers permission prompts in Claude Code, but this script runs
# via nohup/disown outside the sandbox, so it's fine here.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

mkdir -p "$WORK_DIR" || { echo "Failed to create $WORK_DIR" >&2; exit 1; }
# The work dir holds the full changeset and every reviewer transcript. On a shared
# machine the default 0755 lets any local account read a diff that may carry
# proprietary code or a secret someone committed by accident.
chmod 700 "$WORK_DIR" 2>/dev/null || true

# No plan staged? Debate the current changeset instead. A review of what
# actually changed is almost always what someone wants when they run this
# without preparing a plan, and it needs no extra syntax. DEBATE_DIFF_BASE
# overrides the comparison point (default: the merge base with the default
# branch, falling back to HEAD so uncommitted work still reviews).
REVIEW_TARGET="$WORK_DIR/plan.md"
if [ ! -s "$WORK_DIR/plan.md" ]; then
  DIFF_BASE=""
  if git rev-parse --git-dir >/dev/null 2>&1; then
    DIFF_BASE=$(bash "$SCRIPT_DIR/changeset-diff.sh" "$WORK_DIR" "$WORK_DIR/changeset.diff") \
      || DIFF_BASE=""
  fi

  if [ ! -s "$WORK_DIR/changeset.diff" ]; then
    echo "[debate] FATAL: no plan.md in $WORK_DIR and no changes to review" >&2
    echo "  pwd:        $(pwd)" >&2
    if command -v realpath >/dev/null 2>&1; then
      echo "  resolved:   $(realpath "$WORK_DIR" 2>/dev/null || echo "(unresolvable)")" >&2
    fi
    echo "  hint:       write a plan to $WORK_DIR/plan.md, or make some changes to review" >&2
    echo "  hint:       set DEBATE_DIFF_BASE=<ref> to pick a different comparison point" >&2
    echo "  hint:       or set WORK_DIR_OVERRIDE=<absolute path> if you know the right work dir" >&2
    exit 1
  fi

  echo "[debate] No plan staged — reviewing the changeset against ${DIFF_BASE:-working tree} ($(wc -l < "$WORK_DIR/changeset.diff" | tr -d ' ') diff lines)." >&2
  REVIEW_TARGET="$WORK_DIR/changeset.diff"
  : > "$WORK_DIR/plan.md"
  printf '%s\n' "$DIFF_BASE" > "$WORK_DIR/changeset-base.txt"
fi

# Tell the rest of the toolchain what this round reviewed. record-round.sh and
# safe-cleanup.sh both gate on the review target, and both used to assume
# plan.md — in changeset mode that is an empty placeholder, so their gates
# hashed the empty string and passed unconditionally (#17).
printf '%s\n' "$(basename "$REVIEW_TARGET")" > "$WORK_DIR/review-target.txt"

# Record the SHA of what reviewers are about to see. The orchestrator (the
# /debate:all skill) then calls record-round.sh after determining the round
# verdict; the SHA there must match this one or someone edited the target
# mid-round. In changeset mode this must hash the DIFF — plan.md is an empty
# placeholder, and hashing it would make the gate pass no matter how much the
# working tree moved underneath the review.
if command -v sha256sum >/dev/null 2>&1; then
  sha256sum "$REVIEW_TARGET" | cut -d' ' -f1 > "$WORK_DIR/round-active-plan-sha.txt"
elif command -v shasum >/dev/null 2>&1; then
  shasum -a 256 "$REVIEW_TARGET" | cut -d' ' -f1 > "$WORK_DIR/round-active-plan-sha.txt"
fi

if [ ! -f "$CONFIG_FILE" ]; then
  echo "Config not found: $CONFIG_FILE" >&2
  exit 1
fi

# Get reviewer names: CLI arg or all from config
# With no explicit subset, prefer a configured `default_reviewers` list over "every
# key in .reviewers". Without it, a config that defines fallback-only seats — an
# agent for when the usual one is broken — runs them on every review, which is the
# opposite of what a fallback is for. Falls back to all keys so existing configs
# that predate the field behave exactly as before.
if [ -n "$REVIEWER_LIST" ]; then
  IFS=',' read -ra RAW_REVIEWERS <<< "$REVIEWER_LIST"
else
  RAW_REVIEWERS=()
  while IFS= read -r line; do
    RAW_REVIEWERS+=("$line")
  # Absent and explicitly-empty are different answers. `default_reviewers: []` means
  # "no default panel, always select explicitly", matching what an empty `reviewers`
  # array already means on a preset. Treating it as absent would hand back the full
  # panel — including the fallback seats this field exists to keep out of it.
  done < <(jq -r '
    if (.default_reviewers | type) == "array"
    then .default_reviewers[]
    else (.reviewers | keys[])
    end' "$CONFIG_FILE")
fi

# Trim whitespace and drop empty tokens
REVIEWERS=()
for r in "${RAW_REVIEWERS[@]}"; do
  r="${r#"${r%%[![:space:]]*}"}"  # ltrim
  r="${r%"${r##*[![:space:]]}"}"  # rtrim
  [ -n "$r" ] && REVIEWERS+=("$r")
done

if [ ${#REVIEWERS[@]} -eq 0 ]; then
  echo "[debate] No reviewers configured in $CONFIG_FILE" >&2
  exit 1
fi

# --- Sequential session warm-up (prevents the parallel-ensure race) ---
# acpx stores sessions in a shared ~/.acpx index. Firing N reviewers at once means
# N concurrent `acpx <agent> sessions ensure` calls racing on that index — writes get
# lost and the immediately-following submit fails with "No acpx session found",
# which the per-reviewer error mislabels as "not authenticated". Warming each
# agent's session sequentially first (ensure is idempotent — it reuses an existing
# session) makes the subsequent parallel submits all find their session.
# Skipped when SKIP_SESSION_CHECK is set (tests / mock acpx), for agents that bypass
# acpx sessions entirely (antigravity, opus and codex-exec are invoked as direct CLIs
# — keep this list in step with IS_DIRECT_CLI in invoke-acpx.sh), and for reviewers
# running one-shot (`mode: "exec"`), which never open a session to warm.
if [ -z "${SKIP_SESSION_CHECK:-}" ]; then
  if command -v acpx >/dev/null 2>&1; then
    WARM_ACPX=(acpx)
  elif command -v npx >/dev/null 2>&1; then
    WARM_ACPX=(npx acpx@latest)
  else
    WARM_ACPX=()
  fi
  if [ ${#WARM_ACPX[@]} -gt 0 ]; then
    declare -A WARMED=()
    for NAME in "${REVIEWERS[@]}"; do
      [[ "$NAME" =~ ^[a-zA-Z0-9_-]+$ ]] || continue
      AGENT=$(jq -r --arg name "$NAME" '.reviewers[$name].agent // empty' "$CONFIG_FILE")
      [ -z "$AGENT" ] && continue
      case "$AGENT" in antigravity|opus|codex-exec) continue ;; esac
      # A one-shot reviewer never touches a session, so warming one for it is
      # wasted work — and a hang or failure here would delay a run that does not
      # need the session at all.
      MODE=$(jq -r --arg name "$NAME" '.reviewers[$name].mode // empty' "$CONFIG_FILE")
      [ "$MODE" = "exec" ] && continue
      [ -n "${WARMED[$AGENT]:-}" ] && continue   # one ensure per distinct agent
      WARMED[$AGENT]=1
      echo "[debate] Warming acpx session for '$AGENT'..." >&2
      "${WARM_ACPX[@]}" "$AGENT" sessions ensure >/dev/null 2>&1 \
        || echo "[debate] Warm-up for '$AGENT' failed (agent may be unconfigured)." >&2
    done
  fi
fi

EXIT_FILES=()
PIDS=()
MAX_REVIEWER_BUDGET=0

for NAME in "${REVIEWERS[@]}"; do
  # Sanitize reviewer name — must be alphanumeric/dash/underscore only
  if ! [[ "$NAME" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    echo "[debate] Skipping '$NAME' — invalid reviewer name (alphanumeric/dash/underscore only)" >&2
    continue
  fi

  AGENT=$(jq -r --arg name "$NAME" '.reviewers[$name].agent // empty' "$CONFIG_FILE")
  if [ -z "$AGENT" ]; then
    echo "[debate] Skipping $NAME — no agent in config" >&2
    continue
  fi

  TIMEOUT=$(jq -r --arg name "$NAME" '.reviewers[$name].timeout // 120' "$CONFIG_FILE")
  # The wait budget must cover a reviewer's WORST case, not its best. invoke-acpx.sh
  # retries a blank turn, and every attempt gets the full timeout, so a reviewer can
  # legitimately need timeout × (retries + 1). Budgeting only one attempt kills it
  # mid-retry and turns a recoverable blank turn into a lost seat on the panel.
  RETRIES=$(jq -r --arg name "$NAME" '.reviewers[$name].retries // 1' "$CONFIG_FILE")
  [[ "$RETRIES" =~ ^[0-9]+$ ]] || RETRIES=1
  # Same fallback RETRIES gets on the line above, and for the same reason. A value
  # like "600s" or 900.5 used to skip the budget entirely, because the guard below
  # had no else — so the seat contributed nothing to MAX_WAIT while invoke-acpx.sh
  # separately rewrote it to 120 and said so only in that seat's own log. The two
  # layers disagreed and both were quiet about it. Warn once, here, where the
  # operator is already reading, and hand the child the value we actually used.
  if ! [[ "$TIMEOUT" =~ ^[0-9]+$ ]] || [ "$TIMEOUT" -le 0 ]; then
    echo "[debate] $NAME: invalid timeout '$TIMEOUT', using 120s" >&2
    TIMEOUT=120
  fi
  WORST=$(( TIMEOUT * (RETRIES + 1) ))
  if [ "$WORST" -gt "$MAX_REVIEWER_BUDGET" ]; then
    MAX_REVIEWER_BUDGET="$WORST"
  fi

  echo "[debate] Spawning $NAME ($AGENT, timeout: ${TIMEOUT}s)..." >&2
  rm -f "$WORK_DIR/${NAME}-exit.txt"
  nohup env SKIP_SESSION_CHECK="${SKIP_SESSION_CHECK:-}" \
    bash "$SCRIPT_DIR/invoke-acpx.sh" "$CONFIG_FILE" "$WORK_DIR" "$NAME" "$TIMEOUT" \
    > /dev/null 2>"$WORK_DIR/${NAME}-invoke.log" &
  PIDS+=("$!")
  disown "${PIDS[$((${#PIDS[@]}-1))]}"
  EXIT_FILES+=("$WORK_DIR/${NAME}-exit.txt")
done

if [ ${#EXIT_FILES[@]} -eq 0 ]; then
  echo "[debate] No reviewers spawned." >&2
  exit 1
fi

echo "[debate] Waiting for ${#EXIT_FILES[@]} reviewer(s)..." >&2

POLL_INTERVAL=2
ELAPSED=0
# MAX_WAIT must be >= the worst-case budget of the slowest reviewer + a startup
# buffer. Worst case is timeout × (retries + 1), not timeout: a reviewer that
# retries a blank turn spends the full timeout on every attempt, and budgeting for
# one attempt would SIGTERM it mid-retry.
# Override with POLL_MAX_WAIT env var.
if [ -n "${POLL_MAX_WAIT:-}" ]; then
  MAX_WAIT="$POLL_MAX_WAIT"
elif [ "$MAX_REVIEWER_BUDGET" -gt 0 ]; then
  MAX_WAIT=$(( MAX_REVIEWER_BUDGET + 60 ))
else
  MAX_WAIT=450
fi

echo "[debate] Waiting for reviewers (max wait: ${MAX_WAIT}s)..." >&2

while [ "$ELAPSED" -lt "$MAX_WAIT" ]; do
  DONE=0
  for f in "${EXIT_FILES[@]}"; do
    [ -f "$f" ] && DONE=$((DONE + 1))
  done
  if [ "$DONE" -ge "${#EXIT_FILES[@]}" ]; then
    break
  fi
  sleep "$POLL_INTERVAL"
  ELAPSED=$((ELAPSED + POLL_INTERVAL))
done

if [ "$ELAPSED" -ge "$MAX_WAIT" ]; then
  echo "[debate] Timed out waiting for reviewers after ${MAX_WAIT}s. Sending SIGTERM..." >&2
  for pid in "${PIDS[@]}"; do
    kill "$pid" 2>/dev/null || true
  done
  # Give child EXIT traps ~3s to write exit files before escalating
  local_wait=0
  while [ "$local_wait" -lt 3 ]; do
    alive=0
    for pid in "${PIDS[@]}"; do
      kill -0 "$pid" 2>/dev/null && alive=1
    done
    [ "$alive" -eq 0 ] && break
    sleep 1
    local_wait=$(( local_wait + 1 ))
  done
  # Escalate any survivors to SIGKILL
  for pid in "${PIDS[@]}"; do
    kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null || true
  done
  rm -f "$WORK_DIR"/*-prompt.txt
  exit 1
else
  echo "[debate] All reviewers complete (${ELAPSED}s elapsed)." >&2
fi

# Aggregate exit codes
WORST_EXIT=0
for f in "${EXIT_FILES[@]}"; do
  if [ -f "$f" ]; then
    CODE=$(cat "$f" 2>/dev/null)
    if [[ "$CODE" =~ ^[0-9]+$ ]]; then
      [ "$CODE" -gt "$WORST_EXIT" ] && WORST_EXIT="$CODE"
    else
      echo "[debate] Warning: non-numeric exit code in $f: '$CODE'" >&2
      [ "$WORST_EXIT" -eq 0 ] && WORST_EXIT=1
    fi
  else
    WORST_EXIT=1
  fi
done

rm -f "$WORK_DIR"/*-prompt.txt

exit "$WORST_EXIT"

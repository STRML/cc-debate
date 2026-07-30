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

# No plan staged? Debate the current changeset instead. A review of what
# actually changed is almost always what someone wants when they run this
# without preparing a plan, and it needs no extra syntax. DEBATE_DIFF_BASE
# overrides the comparison point (default: the merge base with the default
# branch, falling back to HEAD so uncommitted work still reviews).
REVIEW_TARGET="$WORK_DIR/plan.md"
if [ ! -s "$WORK_DIR/plan.md" ]; then
  DIFF_BASE="${DEBATE_DIFF_BASE:-}"
  if git rev-parse --git-dir >/dev/null 2>&1; then
    HAS_HEAD=0
    git rev-parse --verify --quiet HEAD >/dev/null 2>&1 && HAS_HEAD=1

    if [ -z "$DIFF_BASE" ] && [ "$HAS_HEAD" -eq 1 ]; then
      for cand in origin/HEAD origin/main origin/master main master; do
        if git rev-parse --verify --quiet "$cand" >/dev/null 2>&1; then
          DIFF_BASE="$(git merge-base HEAD "$cand" 2>/dev/null || true)"
          [ -n "$DIFF_BASE" ] && break
        fi
      done
      # No default branch, or no shared history with it (shallow clone, grafted
      # history). HEAD still catches uncommitted work; say so rather than
      # implying the whole branch was reviewed.
      if [ -z "$DIFF_BASE" ]; then
        DIFF_BASE="HEAD"
        echo "[debate] No usable default-branch merge base — comparing against HEAD, so committed work on this branch is NOT included. Set DEBATE_DIFF_BASE=<ref> to widen it." >&2
      fi
    fi

    if [ -n "$DIFF_BASE" ]; then
      git --no-pager diff "$DIFF_BASE" > "$WORK_DIR/changeset.diff" 2>/dev/null || true
    elif [ "$HAS_HEAD" -eq 0 ]; then
      # Repo with no commits: everything is untracked, handled below.
      : > "$WORK_DIR/changeset.diff"
    fi

    # `git diff` only covers tracked paths. A new file is exactly the kind of
    # thing a reviewer must see, so append each untracked file as its own diff.
    # --no-index keeps this read-only; `git add -N` would mutate the user's index.
    while IFS= read -r untracked; do
      [ -n "$untracked" ] || continue
      # Skip our own scaffolding. The work dir sits inside the repo, so its
      # plan.md and per-reviewer files are "untracked changes" — without this
      # the review reads its own artifacts and a clean tree looks dirty.
      case "$untracked" in
        "$WORK_DIR"/*|.tmp/*) continue ;;
      esac
      git --no-pager diff --no-index -- /dev/null "$untracked" 2>/dev/null \
        >> "$WORK_DIR/changeset.diff" || true
    done < <(git ls-files --others --exclude-standard 2>/dev/null || true)
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
fi

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
if [ -n "$REVIEWER_LIST" ]; then
  IFS=',' read -ra RAW_REVIEWERS <<< "$REVIEWER_LIST"
else
  RAW_REVIEWERS=()
  while IFS= read -r line; do
    RAW_REVIEWERS+=("$line")
  done < <(jq -r '.reviewers | keys[]' "$CONFIG_FILE")
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
# Skipped when SKIP_SESSION_CHECK is set (tests / mock acpx), and for agents that
# bypass acpx sessions entirely (antigravity and opus use direct CLI invocation).
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
      [ "$AGENT" = "antigravity" ] || [ "$AGENT" = "opus" ] && continue
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
MAX_REVIEWER_TIMEOUT=0

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
  if [[ "$TIMEOUT" =~ ^[0-9]+$ ]] && [ "$TIMEOUT" -gt "$MAX_REVIEWER_TIMEOUT" ]; then
    MAX_REVIEWER_TIMEOUT="$TIMEOUT"
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
# MAX_WAIT must be >= max reviewer timeout + startup buffer.
# Default: max configured reviewer timeout + 60s buffer, minimum 120s.
# Override with POLL_MAX_WAIT env var.
if [ -n "${POLL_MAX_WAIT:-}" ]; then
  MAX_WAIT="$POLL_MAX_WAIT"
elif [ "$MAX_REVIEWER_TIMEOUT" -gt 0 ]; then
  MAX_WAIT=$(( MAX_REVIEWER_TIMEOUT + 60 ))
else
  MAX_WAIT=450
fi

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

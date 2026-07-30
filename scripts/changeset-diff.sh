#!/bin/bash
# changeset-diff.sh — write the changeset under review to a file.
#
# Shared by run-parallel-acpx.sh (which generates the diff reviewers read) and
# safe-cleanup.sh (which regenerates it to tell whether the working tree moved
# after the last APPROVED round). Keeping one copy of the rule is the point:
# record-round.sh and safe-cleanup.sh drifted from the runner precisely because
# each carried its own idea of what was under review (#17).
#
# Usage: changeset-diff.sh <work_dir> <out_path> [base]
#
# Base resolution order: the explicit argument, then DEBATE_DIFF_BASE, then the
# merge base with the default branch, then HEAD. The resolved base is echoed to
# stdout so the caller can report and re-use it.
#
# Exit codes:
#   0 — diff written (it may be empty; the caller decides whether that matters)
#   1 — <work_dir> is not inside a git repo and neither is the current directory
#   2 — usage error

set -euo pipefail

WORK_DIR="${1:-}"
OUT="${2:-}"
BASE="${3:-${DEBATE_DIFF_BASE:-}}"

if [ -z "$WORK_DIR" ] || [ -z "$OUT" ]; then
  echo "Usage: $0 <work_dir> <out_path> [base]" >&2
  exit 2
fi

# Resolve the repo from the work dir when possible, so the diff does not depend
# on which directory the caller happens to be in.
REPO=""
if [ -d "$WORK_DIR" ]; then
  REPO=$(git -C "$WORK_DIR" rev-parse --show-toplevel 2>/dev/null || true)
fi
if [ -z "$REPO" ]; then
  REPO=$(git rev-parse --show-toplevel 2>/dev/null || true)
fi
if [ -z "$REPO" ]; then
  exit 1
fi

HAS_HEAD=0
git -C "$REPO" rev-parse --verify --quiet HEAD >/dev/null 2>&1 && HAS_HEAD=1

if [ -z "$BASE" ] && [ "$HAS_HEAD" -eq 1 ]; then
  for cand in origin/HEAD origin/main origin/master main master; do
    if git -C "$REPO" rev-parse --verify --quiet "$cand" >/dev/null 2>&1; then
      BASE="$(git -C "$REPO" merge-base HEAD "$cand" 2>/dev/null || true)"
      [ -n "$BASE" ] && break
    fi
  done
  # No default branch, or no shared history with it (shallow clone, grafted
  # history). HEAD still catches uncommitted work; say so rather than implying
  # the whole branch was reviewed.
  if [ -z "$BASE" ]; then
    BASE="HEAD"
    echo "[debate] No usable default-branch merge base — comparing against HEAD, so committed work on this branch is NOT included. Set DEBATE_DIFF_BASE=<ref> to widen it." >&2
  fi
fi

: > "$OUT"

if [ -n "$BASE" ]; then
  git -C "$REPO" --no-pager diff "$BASE" >> "$OUT" 2>/dev/null || true
fi

# `git diff` only covers tracked paths. A new file is exactly the kind of thing
# a reviewer must see, so append each untracked file as its own diff.
# --no-index keeps this read-only; `git add -N` would mutate the user's index.
WORK_REL=""
case "$WORK_DIR" in
  "$REPO"/*) WORK_REL="${WORK_DIR#"$REPO"/}" ;;
esac

while IFS= read -r untracked; do
  [ -n "$untracked" ] || continue
  # Skip our own scaffolding. The work dir sits inside the repo, so its plan.md
  # and per-reviewer files are "untracked changes" — without this the review
  # reads its own artifacts and a clean tree looks dirty.
  case "$untracked" in
    .tmp/*) continue ;;
  esac
  if [ -n "$WORK_REL" ]; then
    case "$untracked" in
      "$WORK_REL"/*) continue ;;
    esac
  fi
  git -C "$REPO" --no-pager diff --no-index -- /dev/null "$untracked" 2>/dev/null \
    >> "$OUT" || true
done < <(git -C "$REPO" ls-files --others --exclude-standard 2>/dev/null || true)

printf '%s\n' "$BASE"

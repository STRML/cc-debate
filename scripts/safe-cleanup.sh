#!/bin/bash
# safe-cleanup.sh — gated cleanup for debate review work dirs.
#
# Two safety gates must pass before the work dir is deleted:
#
#   1. APPROVED gate — refuses if the reviewed target moved after the last
#      APPROVED reviewer pass. Prevents the failure mode where the orchestrator
#      applies a fix in response to reviewer feedback, claims APPROVED based on
#      its own analysis (without re-running reviewers), then wipes the artifacts
#      that would let it notice the gap. In plan mode the target is plan.md; in
#      changeset mode it is the diff, which is regenerated here so a stale
#      changeset.diff cannot hide a working tree that has moved on.
#
#   2. SAVED gate — refuses unless --saved points to a durable copy of plan.md
#      whose contents are byte-identical (same SHA). The work dir is ephemeral;
#      this forces the final plan to be persisted somewhere robust BEFORE the
#      only copy is deleted. Without this, a successful review could end with the
#      plan thrown away. This gate does not apply in changeset mode — the diff is
#      reproducible from git, so there is nothing that only exists here.
#
# Both gates are skipped by --force (use only when deliberately abandoning the
# review — e.g. the user is killing it and wants the work dir gone).
#
# Usage: safe-cleanup.sh <work_dir> --saved <saved_plan_path> [--force]
#        safe-cleanup.sh <work_dir> --force
#
# Exit codes:
#   0 — cleaned up (or work_dir already gone, or no plan.md to save)
#   1 — refused by a safety gate (mismatch, missing --saved, missing/divergent
#       saved copy); override with --force
#   2 — usage error

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

WORK_DIR=""
SAVED=""
FORCE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --force)
      FORCE=1
      shift
      ;;
    --saved)
      if [ $# -lt 2 ]; then
        echo "Usage: $0 <work_dir> --saved <saved_plan_path> [--force]" >&2
        echo "  --saved requires a path argument" >&2
        exit 2
      fi
      SAVED="$2"
      shift 2
      ;;
    *)
      if [ -z "$WORK_DIR" ]; then
        WORK_DIR="$1"
        shift
      else
        echo "Usage: $0 <work_dir> --saved <saved_plan_path> [--force]" >&2
        echo "  unexpected argument: $1" >&2
        exit 2
      fi
      ;;
  esac
done

if [ -z "$WORK_DIR" ]; then
  echo "Usage: $0 <work_dir> --saved <saved_plan_path> [--force]" >&2
  exit 2
fi

# Already gone — nothing to do.
if [ ! -d "$WORK_DIR" ]; then
  exit 0
fi

# Compute SHA via sha256sum or shasum -a 256 (macOS).
sha_of() {
  local f="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$f" 2>/dev/null | cut -d' ' -f1
  else
    shasum -a 256 "$f" 2>/dev/null | cut -d' ' -f1
  fi
}

# Resolve a path to absolute without requiring the target to exist.
abspath() {
  local p="$1"
  local dir base
  dir=$(dirname "$p")
  base=$(basename "$p")
  if [ -d "$dir" ]; then
    printf '%s/%s\n' "$(cd "$dir" && pwd)" "$base"
  else
    printf '%s\n' "$p"
  fi
}

if [ -n "$FORCE" ]; then
  rm -rf "$WORK_DIR"
  exit 0
fi

# What the review actually gated on. run-parallel-acpx.sh writes
# review-target.txt; work dirs without one are plan mode. Hardcoding plan.md
# here made the APPROVED gate compare the empty placeholder against itself in
# changeset mode, so it passed no matter what changed (#17). A marker naming
# anything but a plain file in the work dir is refused rather than rewritten —
# a rewritten one could resolve to the work dir itself, which reads as "no
# target" and would delete everything with no gate applied at all.
# record-round.sh applies the same rule.
TARGET_NAME="plan.md"
if [ -s "$WORK_DIR/review-target.txt" ]; then
  TARGET_NAME=$(tr -d '[:space:]' < "$WORK_DIR/review-target.txt")
  case "$TARGET_NAME" in
    ""|.|..|*/*)
      echo "[debate] Refusing to clean up: unusable review-target.txt: '$TARGET_NAME'" >&2
      echo "  work_dir:  $WORK_DIR" >&2
      echo "" >&2
      echo "  It must name a plain file in the work dir (plan.md or changeset.diff)." >&2
      echo "  To delete the work dir anyway, override with --force." >&2
      exit 1
      ;;
  esac
fi
PLAN="$WORK_DIR/$TARGET_NAME"
CHANGESET_MODE=""
[ "$TARGET_NAME" = "plan.md" ] || CHANGESET_MODE=1

APPROVED_FILE="$WORK_DIR/last-approved-sha.txt"

# No target present — nothing to save or mismatch against; safe to clean.
if [ ! -f "$PLAN" ]; then
  rm -rf "$WORK_DIR"
  exit 0
fi

current=$(sha_of "$PLAN")

# A changeset.diff is a snapshot, not the thing under review — the working tree
# is. Left alone it would match the last approved SHA however far the code moved
# since, which is the drift the APPROVED gate exists to catch. Regenerate it
# against the same base and gate on that. If regeneration is not possible (no
# helper, not a repo), fall back to the stored snapshot.
if [ -n "$CHANGESET_MODE" ] && [ -f "$SCRIPT_DIR/changeset-diff.sh" ]; then
  base=""
  if [ -s "$WORK_DIR/changeset-base.txt" ]; then
    base=$(tr -d '[:space:]' < "$WORK_DIR/changeset-base.txt")
  fi
  fresh=$(mktemp)
  if bash "$SCRIPT_DIR/changeset-diff.sh" "$WORK_DIR" "$fresh" "$base" >/dev/null 2>&1; then
    current=$(sha_of "$fresh")
  fi
  rm -f "$fresh"
fi

# --- Gate 1: APPROVED ---
last_approved=""
if [ -f "$APPROVED_FILE" ]; then
  last_approved=$(tr -d '[:space:]' < "$APPROVED_FILE" 2>/dev/null || true)
fi

# An APPROVED round exists and the target drifted past it — refuse.
if [ -n "$last_approved" ] && [ "$current" != "$last_approved" ]; then
  if [ -n "$CHANGESET_MODE" ]; then
    echo "[debate] Refusing to clean up: the changeset moved after the last APPROVED review." >&2
  else
    echo "[debate] Refusing to clean up: plan.md was modified after the last APPROVED review." >&2
  fi
  echo "  work_dir:       $WORK_DIR" >&2
  echo "  reviewed:       $TARGET_NAME" >&2
  echo "  current SHA:    $current" >&2
  echo "  last approved:  $last_approved" >&2
  echo "" >&2
  echo "  The post-fix state was never reviewed. Run a verification round before claiming APPROVED:" >&2
  echo "    /debate:all   (or re-invoke the runner directly)" >&2
  echo "" >&2
  echo "  If you have manually verified the fix and accept the risk, override with:" >&2
  echo "    bash $0 \"$WORK_DIR\" --force" >&2
  exit 1
fi

# --- Gate 2: SAVED ---
# Changeset mode has nothing to persist: the diff is derived from git and can be
# regenerated at any time, unlike a plan that exists only in the work dir.
if [ -n "$CHANGESET_MODE" ]; then
  rm -rf "$WORK_DIR"
  exit 0
fi

# A plan exists, so a durable copy must be proven before deletion.
if [ -z "$SAVED" ]; then
  echo "[debate] Refusing to clean up: no durable copy of the final plan was provided." >&2
  echo "  work_dir:  $WORK_DIR" >&2
  echo "" >&2
  echo "  The work dir is about to be deleted. Save the final plan to a durable" >&2
  echo "  location first, then pass it back so this script can verify the copy:" >&2
  echo "    bash $0 \"$WORK_DIR\" --saved <path-to-saved-plan>" >&2
  echo "" >&2
  echo "  To delete without saving (abandoning the plan), override with --force." >&2
  exit 1
fi

if [ ! -f "$SAVED" ]; then
  echo "[debate] Refusing to clean up: saved plan not found." >&2
  echo "  --saved:  $SAVED" >&2
  echo "" >&2
  echo "  The path passed to --saved does not exist. Write the final plan there first." >&2
  exit 1
fi

# The saved copy must live outside the work dir, or it gets deleted with it.
work_abs=$(cd "$WORK_DIR" && pwd)
saved_abs=$(abspath "$SAVED")
case "$saved_abs" in
  "$work_abs"/*|"$work_abs")
    echo "[debate] Refusing to clean up: the saved plan is inside the work dir." >&2
    echo "  --saved:    $saved_abs" >&2
    echo "  work_dir:   $work_abs" >&2
    echo "" >&2
    echo "  That copy would be deleted along with everything else. Save the plan to a" >&2
    echo "  durable location outside the work dir." >&2
    exit 1
    ;;
esac

saved_sha=$(sha_of "$SAVED")
if [ "$saved_sha" != "$current" ]; then
  echo "[debate] Refusing to clean up: the saved plan does not match plan.md." >&2
  echo "  --saved SHA:   $saved_sha   ($SAVED)" >&2
  echo "  plan.md SHA:   $current   ($PLAN)" >&2
  echo "" >&2
  echo "  The durable copy diverges from the reviewed plan. Re-save plan.md verbatim" >&2
  echo "  to the durable location, then re-run cleanup." >&2
  exit 1
fi

rm -rf "$WORK_DIR"
exit 0

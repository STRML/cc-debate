#!/bin/bash
# record-round.sh — record a reviewer round's review-target SHA and verdict.
#
# The target is plan.md in plan mode and changeset.diff in changeset mode; the
# runner names it in <work_dir>/review-target.txt.
#
# Append-only log of what state each round actually saw, plus a pointer
# to the last APPROVED state. Used by safe-cleanup.sh to detect when the
# orchestrator has applied edits after the last reviewer pass and is about
# to claim victory without verification.
#
# Usage: record-round.sh <work_dir> <round> <verdict>
#   verdict: APPROVED | REVISE | SPLIT | UNDECIDED
#
# Writes:
#   <work_dir>/rounds.jsonl              one JSON line per round
#   <work_dir>/last-approved-sha.txt     overwritten when verdict=APPROVED
#
# Echoes the recorded SHA to stdout (so callers can reference it).

set -euo pipefail

WORK_DIR="${1:-}"
ROUND="${2:-}"
VERDICT="${3:-}"

if [ -z "$WORK_DIR" ] || [ -z "$ROUND" ] || [ -z "$VERDICT" ]; then
  echo "Usage: $0 <work_dir> <round> <verdict>" >&2
  exit 2
fi

if ! [[ "$ROUND" =~ ^[0-9]+$ ]]; then
  echo "[debate] record-round: invalid round number: $ROUND" >&2
  exit 2
fi

case "$VERDICT" in
  APPROVED|REVISE|SPLIT|UNDECIDED) ;;
  *)
    echo "[debate] record-round: invalid verdict: $VERDICT (expected APPROVED|REVISE|SPLIT|UNDECIDED)" >&2
    exit 2
    ;;
esac

# What the round actually reviewed. run-parallel-acpx.sh writes review-target.txt
# (plan.md in plan mode, changeset.diff in changeset mode). Hardcoding plan.md
# here made every changeset round record the SHA of an empty placeholder (#17).
# A marker that names anything but a plain file in the work dir is refused
# rather than rewritten: this feeds a safety gate, so malformed input fails
# closed. safe-cleanup.sh applies the same rule.
TARGET_NAME="plan.md"
if [ -s "$WORK_DIR/review-target.txt" ]; then
  TARGET_NAME=$(tr -d '[:space:]' < "$WORK_DIR/review-target.txt")
  case "$TARGET_NAME" in
    ""|.|..|*/*)
      echo "[debate] record-round: unusable review-target.txt: '$TARGET_NAME'" >&2
      exit 1
      ;;
  esac
fi
TARGET="$WORK_DIR/$TARGET_NAME"

if [ ! -f "$TARGET" ]; then
  echo "[debate] record-round: $TARGET not found" >&2
  exit 1
fi

if command -v sha256sum >/dev/null 2>&1; then
  sha=$(sha256sum "$TARGET" | cut -d' ' -f1)
else
  sha=$(shasum -a 256 "$TARGET" | cut -d' ' -f1)
fi

ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

printf '{"round":%s,"sha":"%s","verdict":"%s","timestamp":"%s"}\n' \
  "$ROUND" "$sha" "$VERDICT" "$ts" >> "$WORK_DIR/rounds.jsonl"

if [ "$VERDICT" = "APPROVED" ]; then
  echo "$sha" > "$WORK_DIR/last-approved-sha.txt"
fi

echo "$sha"

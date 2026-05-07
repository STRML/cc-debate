#!/bin/bash
# record-round.sh — record a reviewer round's plan SHA and verdict.
#
# Append-only log of what plan state each round actually saw, plus a pointer
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

PLAN="$WORK_DIR/plan.md"
if [ ! -f "$PLAN" ]; then
  echo "[debate] record-round: $PLAN not found" >&2
  exit 1
fi

if command -v sha256sum >/dev/null 2>&1; then
  sha=$(sha256sum "$PLAN" | cut -d' ' -f1)
else
  sha=$(shasum -a 256 "$PLAN" | cut -d' ' -f1)
fi

ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

printf '{"round":%s,"sha":"%s","verdict":"%s","timestamp":"%s"}\n' \
  "$ROUND" "$sha" "$VERDICT" "$ts" >> "$WORK_DIR/rounds.jsonl"

if [ "$VERDICT" = "APPROVED" ]; then
  echo "$sha" > "$WORK_DIR/last-approved-sha.txt"
fi

echo "$sha"

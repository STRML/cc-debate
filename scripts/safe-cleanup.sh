#!/bin/bash
# safe-cleanup.sh — gated cleanup for debate review work dirs.
#
# Refuses to delete the work dir if plan.md was modified after the last
# APPROVED reviewer pass. This prevents the failure mode where the orchestrator
# applies a fix in response to reviewer feedback, claims APPROVED based on its
# own analysis (without re-running reviewers on the fixed plan), and then
# wipes the artifacts that would let it notice the gap.
#
# Usage: safe-cleanup.sh <work_dir> [--force]
#
# Exit codes:
#   0 — cleaned up (or work_dir already gone, or no last-approved record yet)
#   1 — refused due to SHA mismatch; override with --force
#   2 — usage error

set -euo pipefail

WORK_DIR="${1:-}"
FORCE=""
if [ "${2:-}" = "--force" ]; then
  FORCE=1
fi

if [ -z "$WORK_DIR" ]; then
  echo "Usage: $0 <work_dir> [--force]" >&2
  exit 2
fi

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

if [ -n "$FORCE" ]; then
  rm -rf "$WORK_DIR"
  exit 0
fi

PLAN="$WORK_DIR/plan.md"
APPROVED_FILE="$WORK_DIR/last-approved-sha.txt"

# No plan present — nothing to mismatch against; safe to clean.
if [ ! -f "$PLAN" ]; then
  rm -rf "$WORK_DIR"
  exit 0
fi

last_approved=""
if [ -f "$APPROVED_FILE" ]; then
  last_approved=$(tr -d '[:space:]' < "$APPROVED_FILE" 2>/dev/null || true)
fi

# No round ever closed APPROVED (REVISE-only, or the user is bailing) — clean.
if [ -z "$last_approved" ]; then
  rm -rf "$WORK_DIR"
  exit 0
fi

current=$(sha_of "$PLAN")

if [ "$current" != "$last_approved" ]; then
  echo "[debate] Refusing to clean up: plan.md was modified after the last APPROVED review." >&2
  echo "  work_dir:       $WORK_DIR" >&2
  echo "  current SHA:    $current" >&2
  echo "  last approved:  $last_approved" >&2
  echo "" >&2
  echo "  The post-fix plan was never reviewed. Run a verification round before claiming APPROVED:" >&2
  echo "    /debate:all   (or re-invoke the runner directly)" >&2
  echo "" >&2
  echo "  If you have manually verified the fix and accept the risk, override with:" >&2
  echo "    bash $0 \"$WORK_DIR\" --force" >&2
  exit 1
fi

rm -rf "$WORK_DIR"
exit 0

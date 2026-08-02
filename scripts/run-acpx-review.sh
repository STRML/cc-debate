#!/bin/bash
# run-acpx-review.sh — dispatch a review panel seat/model through acpx, optionally
# sandboxed (debate v3, #31). Thin wrapper over run-parallel-acpx.sh so the
# fan-out/timeout/retry machinery stays in one place.
#
# Usage:
#   run-acpx-review.sh <config.json> <review-id> <seat,list> [--sandbox] [--repo-sandbox] [--repo ROOT] [--no-net] [--image IMAGE]
#
# The sandbox flags are passed to sandbox.py, which picks bwrap / sandbox-exec /
# docker by host. --repo-sandbox mounts ROOT read-only for repo-aware seats.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG="$1"; REVIEW_ID="$2"; SEATS="$3"; shift 3

SANDBOX=0; REPO_SANDBOX=0; REPO=""; NO_NET=""; IMAGE=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --sandbox) SANDBOX=1;;
    --repo-sandbox) SANDBOX=1; REPO_SANDBOX=1;;
    --repo) shift; REPO="$1";;
    --no-net) NO_NET="--no-net";;
    --image) shift; IMAGE="$1";;
    *)
      echo "run-acpx-review: unknown flag '$1' (supported: --sandbox --repo-sandbox --repo ROOT --no-net --image IMAGE)" >&2
      exit 2
      ;;
  esac
  shift
done

SANDBOX_ARGS=()
[ "$REPO_SANDBOX" = "1" ] && SANDBOX_ARGS+=(--repo-sandbox)
[ -n "$REPO" ] && SANDBOX_ARGS+=(--repo "$REPO")
[ -n "$NO_NET" ] && SANDBOX_ARGS+=("$NO_NET")
[ -n "$IMAGE" ] && SANDBOX_ARGS+=(--image "$IMAGE")

RUNNER=("bash" "$SCRIPT_DIR/run-parallel-acpx.sh" "$CONFIG" "$REVIEW_ID" "$SEATS")
if [ "$SANDBOX" = "1" ]; then
  exec python3 "$SCRIPT_DIR/sandbox.py" "${SANDBOX_ARGS[@]}" -- "${RUNNER[@]}"
else
  exec "${RUNNER[@]}"
fi

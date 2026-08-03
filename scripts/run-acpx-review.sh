#!/bin/bash
# run-acpx-review.sh — dispatch a review panel seat/model through acpx, optionally
# sandboxed (debate v3, #31). Thin wrapper over run-parallel-acpx.sh so the
# fan-out/timeout/retry machinery stays in one place.
#
# Usage:
#   run-acpx-review.sh <config.json> <review-id> <seat,list> [--sandbox] [--repo-sandbox] [--repo ROOT] [--no-net] [--image IMAGE] [--model ID] [--models FILE]
#
# Model selection (F1): the panel selector picks a model per seat, and this wrapper
# is how that reaches the acpx call.
#   --model ID       — one model id for every seat in this dispatch.
#   --models FILE    — per-seat map: the select-panel.py output ({seats: {...}}) or a
#                      flat {seat: model_id}. Seats named in the map use their entry;
#                      seats not named fall back to --model, then to the config's
#                      per-reviewer `.model`, then to the agent's default.
#
# The sandbox flags are passed to sandbox.py, which picks bwrap / sandbox-exec /
# docker by host. --repo-sandbox mounts ROOT read-only for repo-aware seats.
# --repo and --no-net only mean something inside the sandbox; without --sandbox they
# are rejected rather than silently dropped.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG="$1"; REVIEW_ID="$2"; SEATS="$3"; shift 3

SANDBOX=0; REPO_SANDBOX=0; REPO=""; NO_NET=""; IMAGE=""; MODEL=""; MODELS_FILE=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --sandbox) SANDBOX=1;;
    --repo-sandbox) SANDBOX=1; REPO_SANDBOX=1;;
    --repo) [ "$#" -ge 2 ] || { echo "run-acpx-review: --repo needs ROOT" >&2; exit 2; }; shift; REPO="$1";;
    --no-net) NO_NET="--no-net";;
    --image) [ "$#" -ge 2 ] || { echo "run-acpx-review: --image needs IMAGE" >&2; exit 2; }; shift; IMAGE="$1";;
    --model) [ "$#" -ge 2 ] || { echo "run-acpx-review: --model needs ID" >&2; exit 2; }; shift; MODEL="$1";;
    --models) [ "$#" -ge 2 ] || { echo "run-acpx-review: --models needs FILE" >&2; exit 2; }; shift; MODELS_FILE="$1";;
    *)
      echo "run-acpx-review: unknown flag '$1' (supported: --sandbox --repo-sandbox --repo ROOT --no-net --image IMAGE --model ID --models FILE)" >&2
      exit 2
      ;;
  esac
  shift
done

if [ "$REPO_SANDBOX" = "1" ] && [ -z "$REPO" ]; then
  echo "run-acpx-review: --repo-sandbox requires --repo ROOT (the mount target)" >&2
  exit 2
fi

# F4: isolation flags are a promise the caller thinks they bought. --repo, --no-net
# and --image only change anything under the sandbox; without --sandbox they used to
# run the review completely unsandboxed while reading as if isolation was applied.
# That silent no-op is worse than an error, so reject it.
if [ "$SANDBOX" = "0" ] && { [ -n "$REPO" ] || [ -n "$NO_NET" ] || [ -n "$IMAGE" ]; }; then
  echo "run-acpx-review: --repo, --no-net and --image require --sandbox (isolation flags are no-ops without it)" >&2
  exit 2
fi

if [ -n "$MODELS_FILE" ] && [ ! -f "$MODELS_FILE" ]; then
  echo "run-acpx-review: --models FILE not found: $MODELS_FILE" >&2
  exit 2
fi

SANDBOX_ARGS=()
[ "$REPO_SANDBOX" = "1" ] && SANDBOX_ARGS+=(--repo-sandbox)
[ -n "$REPO" ] && SANDBOX_ARGS+=(--repo "$REPO")
[ -n "$NO_NET" ] && SANDBOX_ARGS+=("$NO_NET")
[ -n "$IMAGE" ] && SANDBOX_ARGS+=(--image "$IMAGE")

# Forward model selection to run-parallel-acpx.sh via the environment: DEBATE_MODEL
# for a single model, ACPX_SEAT_MODELS for the per-seat map. Both survive the
# sandbox (bwrap/Seatbelt inherit the parent env; docker forwards them explicitly).
DISPATCH_ENV=()
[ -n "$MODEL" ] && DISPATCH_ENV+=("DEBATE_MODEL=$MODEL")
[ -n "$MODELS_FILE" ] && DISPATCH_ENV+=("ACPX_SEAT_MODELS=$MODELS_FILE")

RUNNER=("bash" "$SCRIPT_DIR/run-parallel-acpx.sh" "$CONFIG" "$REVIEW_ID" "$SEATS")
if [ "$SANDBOX" = "1" ]; then
  # Bare --sandbox leaves SANDBOX_ARGS empty; expanding an empty array under `set -u`
  # is an "unbound variable" error on bash 3.2 (stock macOS), so the sandboxed dispatch
  # dies before reaching sandbox.py. The + guard (same idiom as invoke-acpx.sh's
  # TIMEOUT_PREFIX) expands to nothing when there are no flags.
  exec env ${DISPATCH_ENV[@]+"${DISPATCH_ENV[@]}"} python3 "$SCRIPT_DIR/sandbox.py" ${SANDBOX_ARGS[@]+"${SANDBOX_ARGS[@]}"} -- "${RUNNER[@]}"
else
  exec env ${DISPATCH_ENV[@]+"${DISPATCH_ENV[@]}"} "${RUNNER[@]}"
fi

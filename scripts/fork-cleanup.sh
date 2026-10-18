#!/bin/bash
# fork-cleanup.sh — remove a /debate:fork work dir, and nothing else.
#
# /debate:fork forks run with the session's tools, so any cleanup helper the command is
# allowed to call is also reachable by a fork that the code under review has steered.
# safe-cleanup.sh --force removes whatever path it is given. This takes the one path shape
# debate-setup.sh creates, <repo>/.tmp/ai-review-<8 hex>, and refuses everything else.
#
# Usage: fork-cleanup.sh <work_dir>
#
# Exit codes:
#   0 — removed (or the path was already gone)
#   1 — refused: not a plain directory shaped like <repo>/.tmp/ai-review-<8 hex>
#   2 — usage error

set -euo pipefail

if [ $# -ne 1 ] || [ -z "$1" ]; then
  echo "Usage: $0 <work_dir>" >&2
  exit 2
fi

WORK_DIR="$1"

refuse() {
  echo "fork-cleanup: refusing '$WORK_DIR': $1" >&2
  exit 1
}

# Already gone: nothing to remove, nothing to validate. A dangling symlink is not gone.
if [ ! -e "$WORK_DIR" ] && [ ! -L "$WORK_DIR" ]; then
  exit 0
fi

[ ! -L "$WORK_DIR" ] || refuse "it is a symlink"
[ -d "$WORK_DIR" ] || refuse "it is not a directory"

# Judge the resolved path, so a symlinked parent cannot present another directory under an
# ai-review- name. debate-setup.sh lowercases the id, so only lowercase hex is accepted.
CANON=$(cd "$WORK_DIR" && pwd -P)
case "$CANON" in
  /*/.tmp/ai-review-[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ;;
  *) refuse "it does not resolve to a .tmp/ai-review-<8 hex> directory (got '$CANON')" ;;
esac

rm -rf -- "$CANON"

#!/bin/bash
# debate-setup.sh — initialize a review session.
# Generates REVIEW_ID, creates the temp working directory, and outputs the
# scripts directory so callers can use literal paths for invoke scripts.
#
# Usage: debate-setup.sh
#
# Output (stdout, key=value):
#   REVIEW_ID=<8-char hex>
#   WORK_DIR=<CWD>/.tmp/ai-review-<REVIEW_ID>
#   SCRIPT_DIR=<stable symlink ~/.claude/debate-scripts, or this script's own dir>

REVIEW_ID=$(uuidgen | tr '[:upper:]' '[:lower:]' | head -c 8)

# Use .tmp/ inside the project directory — avoids permission prompts for
# writing to .claude/ ("editing own settings") or /tmp paths. Prefer the git
# toplevel so WORK_DIR is stable regardless of which subdir the user invokes
# from; falls back to PWD when not in a git repo.
if GIT_TOP=$(git rev-parse --show-toplevel 2>/dev/null) && [ -n "$GIT_TOP" ]; then
  WORK_DIR="${GIT_TOP}/.tmp/ai-review-${REVIEW_ID}"
else
  GIT_TOP="${PWD}"
  WORK_DIR="${GIT_TOP}/.tmp/ai-review-${REVIEW_ID}"
fi

mkdir -p "$WORK_DIR" || { echo "ERROR: failed to create $WORK_DIR" >&2; exit 1; }

# Tighten before the caller writes anything into it. run-parallel-acpx.sh also does this,
# but it runs much later: the changeset is written and classified in between, and under a
# normal 022 umask that leaves a 0755 directory holding a 0644 diff of the entire change.
# On a shared machine any local account can read it, and if the run never reaches the
# runner the exposure simply stays. Refuse rather than hand back a directory that cannot
# be protected.
chmod 700 "$WORK_DIR" || { echo "ERROR: failed to secure $WORK_DIR" >&2; exit 1; }

echo "REVIEW_ID=${REVIEW_ID}"
echo "WORK_DIR=${WORK_DIR}"
# Repo root reviewers read source from. The allowlist needs Read(<REPO_ROOT>/**)
# so subagent source reads don't prompt; callers preflight-check this.
echo "REPO_ROOT=${GIT_TOP}"

# Prefer the stable symlink so subsequent Claude Bash tool calls use a path
# that matches the allowed-tools patterns in each command file.
STABLE_LINK="$HOME/.claude/debate-scripts"
if [ -d "$STABLE_LINK" ]; then
  echo "SCRIPT_DIR=${STABLE_LINK}"
else
  SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
  echo "SCRIPT_DIR=${SELF_DIR}"
fi

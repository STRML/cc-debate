#!/bin/bash
# acpx-env-snapshot.sh — print tool versions and debate config for acpx-setup.
#
# Usage: bash ~/.claude/debate-scripts/acpx-env-snapshot.sh
#
# Output: key: value lines, then debate-acpx.json contents

ACPX_PATH=$(command -v acpx 2>/dev/null || true)
if [ -n "$ACPX_PATH" ]; then
  ACPX_VER=$(acpx --version 2>/dev/null || echo "unknown")
  echo "acpx: $ACPX_PATH ($ACPX_VER)"
else
  echo "acpx: not found"
fi

JQ_PATH=$(command -v jq 2>/dev/null || true)
if [ -n "$JQ_PATH" ]; then
  JQ_VER=$(jq --version 2>/dev/null || echo "unknown")
  echo "jq: $JQ_PATH ($JQ_VER)"
else
  echo "jq: not found"
fi

OC_PATH=$(command -v opencode 2>/dev/null || true)
if [ -n "$OC_PATH" ]; then
  OC_VER=$(opencode --version 2>/dev/null || echo "unknown")
  echo "opencode: $OC_PATH ($OC_VER)"
else
  echo "opencode: not found"
fi

# -L on invoke-acpx.sh is always false — the link is the *directory*, and the
# script inside it is a regular file. Test that the path resolves, and report
# which version it resolves to so a link left behind by an older install shows.
DEBATE_LINK="$HOME/.claude/debate-scripts"
if [ -e "$DEBATE_LINK/invoke-acpx.sh" ]; then
  echo "debate-scripts: symlinked -> $(cd "$DEBATE_LINK" && pwd -P)"
else
  echo "debate-scripts: not found"
fi

echo "---"
echo "debate-acpx.json:"
cat ~/.claude/debate-acpx.json 2>/dev/null || echo "not found"

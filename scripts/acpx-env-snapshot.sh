#!/bin/bash
# acpx-env-snapshot.sh — print tool versions and debate config for acpx-setup.
#
# Usage: bash ~/.claude/debate-scripts/acpx-env-snapshot.sh
#
# Output: key: value lines, then debate-acpx.json contents

ACPX_PATH=$(command -v acpx 2>/dev/null || true)
# Minimum version for effort auto-scaling: `acpx codex set reasoning_effort`
# (used by invoke-acpx.sh for effort-scaled codex seats) requires acpx >= 0.13.0.
# Earlier versions run codex at its default effort and say so.
ACPX_MIN="0.13.0"

# Numeric version compare, portably (no sort -V: stock macOS BSD sort lacks it).
# Returns 0 when $1 >= $2. Accepts major.minor.patch; missing components are 0.
version_ge() {
  local a b ia ib i
  IFS='.' read -r -a a <<< "$1"
  IFS='.' read -r -a b <<< "$2"
  for i in 0 1 2; do
    ia="${a[$i]:-0}"; ib="${b[$i]:-0}"
    # Strip any non-numeric suffix (e.g. "0.13.0-beta.1" -> "0")
    ia="${ia%%[^0-9]*}"; ib="${ib%%[^0-9]*}"
    ia="${ia:-0}"; ib="${ib:-0}"
    [ "$ia" -gt "$ib" ] && return 0
    [ "$ia" -lt "$ib" ] && return 1
  done
  return 0
}

if [ -n "$ACPX_PATH" ]; then
  ACPX_VER=$(acpx --version 2>/dev/null || echo "unknown")
  echo "acpx: $ACPX_PATH ($ACPX_VER)"
  if [ "$ACPX_VER" != "unknown" ] && ! version_ge "$ACPX_VER" "$ACPX_MIN"; then
    echo "  ⚠️ acpx < $ACPX_MIN — effort auto-scaling for codex seats needs acpx >= $ACPX_MIN."
    echo "    Upgrade: npm install -g acpx@latest"
  fi
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
if [ -e "$DEBATE_LINK" ] && [ ! -L "$DEBATE_LINK" ]; then
  # A real directory here can hold a copy of the scripts and look healthy, but
  # nothing refreshes it — create-links.sh cannot replace it.
  echo "debate-scripts: not a symlink (real path at $DEBATE_LINK)"
elif [ -e "$DEBATE_LINK/invoke-acpx.sh" ]; then
  echo "debate-scripts: symlinked -> $(cd "$DEBATE_LINK" && pwd -P)"
else
  echo "debate-scripts: not found"
fi

# The workflows link is a second, separate link, and /debate:panel is the only thing
# that needs it. Reporting only the scripts link calls the install healthy while the
# panel cannot start.
WORKFLOW_LINK="$HOME/.claude/debate-workflows"
if [ -e "$WORKFLOW_LINK" ] && [ ! -L "$WORKFLOW_LINK" ]; then
  echo "debate-workflows: not a symlink (real path at $WORKFLOW_LINK)"
elif [ -e "$WORKFLOW_LINK/review-panel.js" ]; then
  echo "debate-workflows: symlinked -> $(cd "$WORKFLOW_LINK" && pwd -P)"
else
  echo "debate-workflows: not found (/debate:panel will not run)"
fi

echo "---"
echo "debate-acpx.json:"
cat ~/.claude/debate-acpx.json 2>/dev/null || echo "not found"

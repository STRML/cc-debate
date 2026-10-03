#!/bin/bash
# Tests for the debate mod (hooks/register.tsx, hooks/seats and hooks/report): the seat pane and progress band, the findings board and the seat scorecard.
#
# The mod's tests are TypeScript under tests/seats/, run by Claude Code's own plugin
# test runner against the plugin folder, so this suite is only the bridge to it. It
# skips, rather than fails, on a Claude Code that has no `plugin test` (mods need
# 2.1.287+), so a contributor on an older build still gets a green bash suite.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

if ! command -v claude >/dev/null 2>&1; then
  echo "  debate mod... SKIP (claude CLI not on PATH)"
  exit 0
fi

if ! claude plugin test --help >/dev/null 2>&1; then
  echo "  debate mod... SKIP (this Claude Code has no 'plugin test'; mods need 2.1.287+)"
  exit 0
fi

echo "  debate mod (claude plugin test)... "
claude plugin test "$PROJECT_DIR"

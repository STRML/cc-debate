#!/bin/bash
# Tests for the ~/.claude/debate-scripts symlink: that create-links.sh repairs a
# link left behind by a removed plugin version, and repoints one left behind by
# an older one.
#
# Every test runs against a throwaway $HOME so the developer's real link is
# never touched.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

PASS=0
FAIL=0

run_test() {
  local name="$1"
  shift
  echo -n "  $name... "
  if "$@"; then
    echo "PASS"
    PASS=$((PASS + 1))
  else
    echo "FAIL"
    FAIL=$((FAIL + 1))
  fi
}

# Build a fake plugin cache with two installed versions, in a fake HOME.
# Echoes the temp root; caller sets HOME to "$root/home".
make_fake_home() {
  local root
  root="$(mktemp -d)"
  local cache="$root/home/.claude/plugins/cache/cc-debate/debate"
  mkdir -p "$root/home/.claude" "$cache/2.6.0/scripts" "$cache/2.7.0/scripts"
  local v
  for v in 2.6.0 2.7.0; do
    cp "$PROJECT_DIR/scripts/create-links.sh" "$cache/$v/scripts/"
    cp "$PROJECT_DIR/scripts/debate-setup.sh" "$cache/$v/scripts/"
    cp "$PROJECT_DIR/scripts/acpx-env-snapshot.sh" "$cache/$v/scripts/"
    touch "$cache/$v/scripts/invoke-acpx.sh"
  done
  echo "$root"
}

# A link pinned to a version the plugin cache no longer has must be repairable
# by running create-links.sh from the version that is still installed. This is
# the failure mode behind "~/.claude/debate-scripts not found" after an update:
# the pinned version directory is gone, so every command's first step exits 127.
test_repairs_link_to_removed_version() {
  local root; root="$(make_fake_home)"
  local out=0
  (
    export HOME="$root/home"
    local cache="$HOME/.claude/plugins/cache/cc-debate/debate"
    bash "$cache/2.6.0/scripts/create-links.sh" >/dev/null
    rm -rf "$cache/2.6.0"
    [ -d "$HOME/.claude/debate-scripts" ] && exit 1   # must be dangling now
    bash "$HOME/.claude/debate-scripts/debate-setup.sh" >/dev/null 2>&1 && exit 1
    bash "$cache/2.7.0/scripts/create-links.sh" >/dev/null
    bash "$HOME/.claude/debate-scripts/debate-setup.sh" >/dev/null 2>&1
  ) || out=1
  rm -rf "$root"
  return $out
}

# create-links.sh must overwrite a link that still resolves but points at an
# older version — otherwise commands from the new version call old scripts.
test_repoints_link_from_older_version() {
  local root; root="$(make_fake_home)"
  local out=0
  (
    export HOME="$root/home"
    local cache="$HOME/.claude/plugins/cache/cc-debate/debate"
    bash "$cache/2.6.0/scripts/create-links.sh" >/dev/null
    bash "$cache/2.7.0/scripts/create-links.sh" >/dev/null
    # Compare resolved paths — on macOS $TMPDIR itself is a symlink.
    [ "$(cd "$HOME/.claude/debate-scripts" && pwd -P)" = "$(cd "$cache/2.7.0/scripts" && pwd -P)" ]
  ) || out=1
  rm -rf "$root"
  return $out
}


# The SessionStart hook is what keeps the link fresh without the user
# remembering to re-run /debate:setup after every update.
test_hook_declares_session_start() {
  local hooks="$PROJECT_DIR/hooks/hooks.json"
  [ -f "$hooks" ] || return 1
  if command -v jq >/dev/null 2>&1; then
    [ "$(jq -r '.hooks.SessionStart[0].hooks[0].command' "$hooks")" != "null" ] || return 1
    jq -r '.hooks.SessionStart[0].hooks[0].command' "$hooks" | grep -q 'create-links.sh'
  else
    grep -q 'SessionStart' "$hooks" && grep -q 'create-links.sh' "$hooks"
  fi
}

echo "symlink health tests"
run_test "repairs a link to a removed version" test_repairs_link_to_removed_version
run_test "repoints a link from an older version" test_repoints_link_from_older_version
run_test "SessionStart hook runs create-links.sh" test_hook_declares_session_start

echo ""
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

#!/bin/bash
# Tests for fork-cleanup.sh: it removes a /debate:fork work dir and refuses every other path.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
FORK_CLEANUP="$PROJECT_DIR/scripts/fork-cleanup.sh"

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

# Each test gets its own sandbox directory, removed afterwards.
new_root() { mktemp -d; }

test_removes_a_review_work_dir() {
  local root
  root=$(new_root)
  mkdir -p "$root/repo/.tmp/ai-review-0badf00d"
  touch "$root/repo/.tmp/ai-review-0badf00d/changeset.diff"
  bash "$FORK_CLEANUP" "$root/repo/.tmp/ai-review-0badf00d" || { rm -rf "$root"; return 1; }
  local gone=0
  [ ! -e "$root/repo/.tmp/ai-review-0badf00d" ] || gone=1
  [ -d "$root/repo/.tmp" ] || gone=1   # only the work dir goes, not its parent
  rm -rf "$root"
  [ "$gone" -eq 0 ]
}

test_missing_dir_is_a_noop() {
  local root
  root=$(new_root)
  bash "$FORK_CLEANUP" "$root/repo/.tmp/ai-review-0badf00d"
  local rc=$?
  rm -rf "$root"
  [ "$rc" -eq 0 ]
}

# Every path below exists, is a real directory, and must survive a refused call.
refuses() {
  local path="$1" rc=0
  bash "$FORK_CLEANUP" "$path" 2>/dev/null || rc=$?
  [ "$rc" -eq 1 ] && [ -e "$path" ]
}

test_refuses_non_review_paths() {
  local root bad=0
  root=$(new_root)
  mkdir -p "$root/repo/.tmp/notes" "$root/Documents" "$root/repo/ai-review-0badf00d" \
           "$root/repo/.tmp/ai-review-0bad" "$root/repo/.tmp/ai-review-0BADF00D" \
           "$root/repo/.tmp/ai-review-0badf00d-extra" "$root/repo/.tmp/xai-review-0badf00d"
  touch "$root/Documents/precious.txt"
  local p
  for p in "$root" "$root/Documents" "$root/repo" "$root/repo/.tmp" "$root/repo/.tmp/notes" \
           "$root/repo/ai-review-0badf00d" "$root/repo/.tmp/ai-review-0bad" \
           "$root/repo/.tmp/ai-review-0BADF00D" "$root/repo/.tmp/ai-review-0badf00d-extra" \
           "$root/repo/.tmp/xai-review-0badf00d"; do
    refuses "$p" || { echo "  did not refuse: $p"; bad=1; }
  done
  [ -f "$root/Documents/precious.txt" ] || bad=1
  rm -rf "$root"
  [ "$bad" -eq 0 ]
}

test_refuses_a_symlink_named_like_a_work_dir() {
  local root bad=0
  root=$(new_root)
  mkdir -p "$root/repo/.tmp" "$root/Documents"
  touch "$root/Documents/precious.txt"
  ln -s "$root/Documents" "$root/repo/.tmp/ai-review-0badf00d"
  refuses "$root/repo/.tmp/ai-review-0badf00d" || { echo "  did not refuse the symlink"; bad=1; }
  [ -f "$root/Documents/precious.txt" ] || bad=1
  rm -rf "$root"
  [ "$bad" -eq 0 ]
}

test_refuses_a_traversal_out_of_a_review_dir() {
  local root bad=0
  root=$(new_root)
  mkdir -p "$root/repo/.tmp/ai-review-0badf00d" "$root/Documents"
  touch "$root/Documents/precious.txt"
  # Names a review dir first, resolves to Documents.
  refuses "$root/repo/.tmp/ai-review-0badf00d/../../../Documents" \
    || { echo "  did not refuse the traversal"; bad=1; }
  [ -f "$root/Documents/precious.txt" ] || bad=1
  rm -rf "$root"
  [ "$bad" -eq 0 ]
}

test_usage_errors() {
  local rc=0
  bash "$FORK_CLEANUP" 2>/dev/null || rc=$?
  [ "$rc" -eq 2 ] || return 1
  rc=0
  bash "$FORK_CLEANUP" "" 2>/dev/null || rc=$?
  [ "$rc" -eq 2 ] || return 1
  rc=0
  bash "$FORK_CLEANUP" /a /b 2>/dev/null || rc=$?
  [ "$rc" -eq 2 ]
}

echo ""
echo "=== fork-cleanup tests ==="
echo ""

run_test "removes a review work dir and only that" test_removes_a_review_work_dir
run_test "missing dir is a no-op" test_missing_dir_is_a_noop
run_test "refuses paths that are not review work dirs" test_refuses_non_review_paths
run_test "refuses a symlink named like a work dir" test_refuses_a_symlink_named_like_a_work_dir
run_test "refuses a traversal out of a review dir" test_refuses_a_traversal_out_of_a_review_dir
run_test "usage errors exit 2" test_usage_errors

echo ""
echo "=== Results: $PASS passed, $FAIL failed ($(( PASS + FAIL )) total) ==="

[ "$FAIL" -eq 0 ]

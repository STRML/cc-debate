#!/bin/bash
# Tests for scripts/safe-cleanup.sh and scripts/record-round.sh.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SAFE_CLEANUP="$PROJECT_DIR/scripts/safe-cleanup.sh"
RECORD_ROUND="$PROJECT_DIR/scripts/record-round.sh"

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

sha_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  else
    shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

# --- record-round.sh ---

test_record_round_appends_jsonl() {
  local d
  d=$(mktemp -d)
  echo "first plan" > "$d/plan.md"

  bash "$RECORD_ROUND" "$d" 1 REVISE >/dev/null
  echo "second plan" > "$d/plan.md"
  bash "$RECORD_ROUND" "$d" 2 APPROVED >/dev/null

  [ -f "$d/rounds.jsonl" ] || { rm -rf "$d"; return 1; }
  local lines
  lines=$(wc -l < "$d/rounds.jsonl" | tr -d ' ')
  [ "$lines" = "2" ] || { rm -rf "$d"; return 1; }
  grep -q '"verdict":"REVISE"' "$d/rounds.jsonl" || { rm -rf "$d"; return 1; }
  grep -q '"verdict":"APPROVED"' "$d/rounds.jsonl" || { rm -rf "$d"; return 1; }

  rm -rf "$d"
}

test_record_round_writes_last_approved_only_on_approved() {
  local d
  d=$(mktemp -d)
  echo "plan" > "$d/plan.md"

  bash "$RECORD_ROUND" "$d" 1 REVISE >/dev/null
  [ ! -f "$d/last-approved-sha.txt" ] || { rm -rf "$d"; return 1; }

  bash "$RECORD_ROUND" "$d" 2 APPROVED >/dev/null
  [ -f "$d/last-approved-sha.txt" ] || { rm -rf "$d"; return 1; }

  local recorded expected
  recorded=$(cat "$d/last-approved-sha.txt")
  expected=$(sha_of "$d/plan.md")
  [ "$recorded" = "$expected" ] || { rm -rf "$d"; return 1; }

  rm -rf "$d"
}

test_record_round_rejects_bad_args() {
  local d
  d=$(mktemp -d)
  echo "plan" > "$d/plan.md"

  set +e
  bash "$RECORD_ROUND" "$d" notanumber APPROVED >/dev/null 2>&1
  local rc1=$?
  bash "$RECORD_ROUND" "$d" 1 NOPE >/dev/null 2>&1
  local rc2=$?
  bash "$RECORD_ROUND" "$d" >/dev/null 2>&1
  local rc3=$?
  set -e

  rm -rf "$d"
  [ "$rc1" -ne 0 ] && [ "$rc2" -ne 0 ] && [ "$rc3" -ne 0 ]
}

test_record_round_fails_without_plan() {
  local d
  d=$(mktemp -d)

  set +e
  bash "$RECORD_ROUND" "$d" 1 APPROVED >/dev/null 2>&1
  local rc=$?
  set -e

  rm -rf "$d"
  [ "$rc" -ne 0 ]
}

# --- safe-cleanup.sh ---

test_safe_cleanup_no_record_proceeds() {
  local d
  d=$(mktemp -d)
  echo "plan" > "$d/plan.md"

  bash "$SAFE_CLEANUP" "$d"
  [ ! -d "$d" ]
}

test_safe_cleanup_matching_sha_proceeds() {
  local d
  d=$(mktemp -d)
  echo "plan v1" > "$d/plan.md"
  bash "$RECORD_ROUND" "$d" 1 APPROVED >/dev/null

  bash "$SAFE_CLEANUP" "$d"
  [ ! -d "$d" ]
}

test_safe_cleanup_refuses_on_mismatch() {
  local d
  d=$(mktemp -d)
  echo "plan v1" > "$d/plan.md"
  bash "$RECORD_ROUND" "$d" 1 APPROVED >/dev/null

  # Edit the plan after the approved round.
  echo "plan v2 (post-fix)" > "$d/plan.md"

  set +e
  bash "$SAFE_CLEANUP" "$d" 2>/dev/null
  local rc=$?
  set -e

  [ "$rc" -eq 1 ] || { rm -rf "$d"; return 1; }
  [ -d "$d" ] || { rm -rf "$d"; return 1; }   # work_dir survives

  # --force overrides
  bash "$SAFE_CLEANUP" "$d" --force
  [ ! -d "$d" ]
}

test_safe_cleanup_missing_dir_is_noop() {
  local d
  d=$(mktemp -d)
  rm -rf "$d"
  bash "$SAFE_CLEANUP" "$d"
}

test_safe_cleanup_revise_only_proceeds() {
  # No round ever closed APPROVED → no last-approved-sha.txt → cleanup OK.
  local d
  d=$(mktemp -d)
  echo "plan" > "$d/plan.md"
  bash "$RECORD_ROUND" "$d" 1 REVISE >/dev/null
  bash "$RECORD_ROUND" "$d" 2 REVISE >/dev/null

  bash "$SAFE_CLEANUP" "$d"
  [ ! -d "$d" ]
}

test_safe_cleanup_usage_error() {
  set +e
  bash "$SAFE_CLEANUP" 2>/dev/null
  local rc=$?
  set -e
  [ "$rc" -eq 2 ]
}

# --- Run ---

echo "Testing safe-cleanup.sh and record-round.sh..."
echo ""

run_test "record-round appends to jsonl"               test_record_round_appends_jsonl
run_test "record-round writes last-approved on APPROVED" test_record_round_writes_last_approved_only_on_approved
run_test "record-round rejects bad args"               test_record_round_rejects_bad_args
run_test "record-round fails without plan.md"          test_record_round_fails_without_plan

run_test "safe-cleanup proceeds without prior record"  test_safe_cleanup_no_record_proceeds
run_test "safe-cleanup proceeds when SHA matches"      test_safe_cleanup_matching_sha_proceeds
run_test "safe-cleanup refuses on SHA mismatch"        test_safe_cleanup_refuses_on_mismatch
run_test "safe-cleanup is no-op if dir missing"        test_safe_cleanup_missing_dir_is_noop
run_test "safe-cleanup proceeds on REVISE-only rounds" test_safe_cleanup_revise_only_proceeds
run_test "safe-cleanup usage error on no args"         test_safe_cleanup_usage_error

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

#!/bin/bash
# Tests for scripts/safe-cleanup.sh and scripts/record-round.sh.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SAFE_CLEANUP="$PROJECT_DIR/scripts/safe-cleanup.sh"
RECORD_ROUND="$PROJECT_DIR/scripts/record-round.sh"
CHANGESET_DIFF="$PROJECT_DIR/scripts/changeset-diff.sh"

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

# A throwaway git repo with one commit on `main`, matching the fixture in
# test-parallel-acpx.sh.
setup_git_repo() {
  local d
  d=$(mktemp -d)
  git -C "$d" init -q
  git -C "$d" config user.email "test@example.com"
  git -C "$d" config user.name "Test"
  git -C "$d" config commit.gpgsign false
  echo "base" > "$d/f.txt"
  git -C "$d" add f.txt >/dev/null 2>&1
  git -C "$d" commit -qm "base" >/dev/null 2>&1
  git -C "$d" branch -M main >/dev/null 2>&1
  echo "$d"
}

# Build a changeset-mode work dir inside $1 with an uncommitted change already
# diffed into it, exactly as run-parallel-acpx.sh leaves it. Echoes the work dir.
setup_changeset_work_dir() {
  local repo="$1"
  local work base
  work="$repo/.tmp/ai-review-changeset"
  mkdir -p "$work"
  : > "$work/plan.md"
  base=$(bash "$CHANGESET_DIFF" "$work" "$work/changeset.diff" 2>/dev/null)
  printf '%s\n' "$base" > "$work/changeset-base.txt"
  echo "changeset.diff" > "$work/review-target.txt"
  echo "$work"
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

# In changeset mode plan.md is an empty placeholder. Recording its SHA logs the
# hash of the empty string for every round, so the drift check compares a
# constant against itself and can never fire (#17).
test_record_round_hashes_the_changeset() {
  local repo work recorded expected
  repo=$(setup_git_repo)
  echo "const movedToken = 1;" >> "$repo/f.txt"
  work=$(setup_changeset_work_dir "$repo")

  recorded=$(bash "$RECORD_ROUND" "$work" 1 APPROVED)
  expected=$(sha_of "$work/changeset.diff")

  [ "$recorded" = "$expected" ] || { rm -rf "$repo"; return 1; }
  [ "$(cat "$work/last-approved-sha.txt")" = "$expected" ] || { rm -rf "$repo"; return 1; }
  grep -q "\"sha\":\"$expected\"" "$work/rounds.jsonl" || { rm -rf "$repo"; return 1; }

  rm -rf "$repo"
}

test_record_round_marker_cannot_escape_work_dir() {
  local d
  d=$(mktemp -d)
  echo "plan" > "$d/plan.md"
  echo "../../etc/hosts" > "$d/review-target.txt"

  set +e
  bash "$RECORD_ROUND" "$d" 1 APPROVED >/dev/null 2>&1
  local rc=$?
  set -e

  rm -rf "$d"
  [ "$rc" -ne 0 ]
}

# --- safe-cleanup.sh ---

# Save a durable copy of plan.md outside the work dir and echo its path.
save_copy() {
  local d="$1"
  local saved
  saved=$(mktemp)
  cat "$d/plan.md" > "$saved"
  echo "$saved"
}

test_safe_cleanup_no_record_proceeds() {
  local d saved
  d=$(mktemp -d)
  echo "plan" > "$d/plan.md"
  saved=$(save_copy "$d")

  bash "$SAFE_CLEANUP" "$d" --saved "$saved"
  rm -f "$saved"
  [ ! -d "$d" ]
}

test_safe_cleanup_matching_sha_proceeds() {
  local d saved
  d=$(mktemp -d)
  echo "plan v1" > "$d/plan.md"
  bash "$RECORD_ROUND" "$d" 1 APPROVED >/dev/null
  saved=$(save_copy "$d")

  bash "$SAFE_CLEANUP" "$d" --saved "$saved"
  rm -f "$saved"
  [ ! -d "$d" ]
}

test_safe_cleanup_refuses_on_mismatch() {
  local d saved
  d=$(mktemp -d)
  echo "plan v1" > "$d/plan.md"
  bash "$RECORD_ROUND" "$d" 1 APPROVED >/dev/null

  # Edit the plan after the approved round, then save a matching durable copy
  # so the only failing gate is the APPROVED gate.
  echo "plan v2 (post-fix)" > "$d/plan.md"
  saved=$(save_copy "$d")

  set +e
  bash "$SAFE_CLEANUP" "$d" --saved "$saved" 2>/dev/null
  local rc=$?
  set -e

  [ "$rc" -eq 1 ] || { rm -rf "$d"; rm -f "$saved"; return 1; }
  [ -d "$d" ] || { rm -rf "$d"; rm -f "$saved"; return 1; }   # work_dir survives

  # --force overrides
  bash "$SAFE_CLEANUP" "$d" --force
  rm -f "$saved"
  [ ! -d "$d" ]
}

test_safe_cleanup_missing_dir_is_noop() {
  local d
  d=$(mktemp -d)
  rm -rf "$d"
  bash "$SAFE_CLEANUP" "$d"
}

test_safe_cleanup_revise_only_proceeds() {
  # No round ever closed APPROVED → no last-approved-sha.txt → APPROVED gate OK.
  local d saved
  d=$(mktemp -d)
  echo "plan" > "$d/plan.md"
  bash "$RECORD_ROUND" "$d" 1 REVISE >/dev/null
  bash "$RECORD_ROUND" "$d" 2 REVISE >/dev/null
  saved=$(save_copy "$d")

  bash "$SAFE_CLEANUP" "$d" --saved "$saved"
  rm -f "$saved"
  [ ! -d "$d" ]
}

test_safe_cleanup_refuses_without_saved() {
  # A plan exists but no durable copy was provided → refuse, work_dir survives.
  local d
  d=$(mktemp -d)
  echo "plan" > "$d/plan.md"

  set +e
  bash "$SAFE_CLEANUP" "$d" 2>/dev/null
  local rc=$?
  set -e

  [ "$rc" -eq 1 ] || { rm -rf "$d"; return 1; }
  [ -d "$d" ] || return 1

  rm -rf "$d"
}

test_safe_cleanup_force_bypasses_missing_saved() {
  local d
  d=$(mktemp -d)
  echo "plan" > "$d/plan.md"

  bash "$SAFE_CLEANUP" "$d" --force
  [ ! -d "$d" ]
}

test_safe_cleanup_refuses_saved_not_found() {
  local d
  d=$(mktemp -d)
  echo "plan" > "$d/plan.md"

  set +e
  bash "$SAFE_CLEANUP" "$d" --saved "/nonexistent/path/plan.md" 2>/dev/null
  local rc=$?
  set -e

  [ "$rc" -eq 1 ] || { rm -rf "$d"; return 1; }
  [ -d "$d" ] || return 1

  rm -rf "$d"
}

test_safe_cleanup_refuses_saved_mismatch() {
  local d saved
  d=$(mktemp -d)
  echo "plan v1" > "$d/plan.md"
  saved=$(mktemp)
  echo "different content" > "$saved"

  set +e
  bash "$SAFE_CLEANUP" "$d" --saved "$saved" 2>/dev/null
  local rc=$?
  set -e

  rm -f "$saved"
  [ "$rc" -eq 1 ] || { rm -rf "$d"; return 1; }
  [ -d "$d" ] || return 1

  rm -rf "$d"
}

test_safe_cleanup_refuses_saved_inside_workdir() {
  # The saved copy must be outside the work dir, or it gets deleted too.
  local d
  d=$(mktemp -d)
  echo "plan" > "$d/plan.md"
  cp "$d/plan.md" "$d/saved-plan.md"

  set +e
  bash "$SAFE_CLEANUP" "$d" --saved "$d/saved-plan.md" 2>/dev/null
  local rc=$?
  set -e

  [ "$rc" -eq 1 ] || { rm -rf "$d"; return 1; }
  [ -d "$d" ] || return 1

  rm -rf "$d"
}

# A diff is reproducible from git, so changeset mode has nothing that only
# exists in the work dir — the SAVED gate does not apply there.
test_safe_cleanup_changeset_needs_no_saved_copy() {
  local repo work
  repo=$(setup_git_repo)
  echo "const cleanToken = 1;" >> "$repo/f.txt"
  work=$(setup_changeset_work_dir "$repo")
  bash "$RECORD_ROUND" "$work" 1 APPROVED >/dev/null

  bash "$SAFE_CLEANUP" "$work" || { rm -rf "$repo"; return 1; }
  [ ! -d "$work" ] || { rm -rf "$repo"; return 1; }

  rm -rf "$repo"
}

# The reviewed artifact is the working tree, not the snapshot on disk. Gating on
# the stale changeset.diff would pass however far the code moved after APPROVED.
test_safe_cleanup_refuses_when_changeset_moved() {
  local repo work
  repo=$(setup_git_repo)
  echo "const reviewedToken = 1;" >> "$repo/f.txt"
  work=$(setup_changeset_work_dir "$repo")
  bash "$RECORD_ROUND" "$work" 1 APPROVED >/dev/null

  # The orchestrator "applies a fix" after the approved round.
  echo "const unreviewedToken = 2;" >> "$repo/f.txt"

  local err
  err=$(mktemp)
  set +e
  bash "$SAFE_CLEANUP" "$work" 2>"$err"
  local rc=$?
  set -e

  [ "$rc" -eq 1 ] || { rm -f "$err"; rm -rf "$repo"; return 1; }
  [ -d "$work" ] || { rm -f "$err"; rm -rf "$repo"; return 1; }
  # It must refuse on the APPROVED gate, not incidentally on the SAVED gate.
  grep -q "changeset moved after the last APPROVED" "$err" \
    || { rm -f "$err"; rm -rf "$repo"; return 1; }
  rm -f "$err"

  # --force still overrides.
  bash "$SAFE_CLEANUP" "$work" --force
  [ ! -d "$work" ] || { rm -rf "$repo"; return 1; }

  rm -rf "$repo"
}

# A marker that resolves to the work dir itself used to read as "no target
# present", which deletes everything with no gate applied at all. A safety gate
# fails closed on malformed input.
test_safe_cleanup_refuses_unusable_marker() {
  local d
  d=$(mktemp -d)
  echo "plan" > "$d/plan.md"
  echo "." > "$d/review-target.txt"

  set +e
  bash "$SAFE_CLEANUP" "$d" 2>/dev/null
  local rc=$?
  set -e

  [ "$rc" -eq 1 ] || { rm -rf "$d"; return 1; }
  [ -d "$d" ] || return 1

  # --force still overrides.
  bash "$SAFE_CLEANUP" "$d" --force
  [ ! -d "$d" ]
}

# The stored base outlives the round: safe-cleanup regenerates against it later.
# A moving ref would drop any commit landed since and defeat the gate.
test_changeset_base_is_a_frozen_sha() {
  local repo work base head
  repo=$(setup_git_repo)
  # Delete every ref the default-branch scan can find, so the HEAD fallback runs.
  git -C "$repo" checkout -q --detach
  git -C "$repo" branch -q -D main
  echo "const fallbackToken = 1;" >> "$repo/f.txt"

  work=$(setup_changeset_work_dir "$repo")
  base=$(tr -d '[:space:]' < "$work/changeset-base.txt")
  head=$(git -C "$repo" rev-parse HEAD)

  [ "$base" = "$head" ] || { rm -rf "$repo"; return 1; }

  rm -rf "$repo"
}

test_safe_cleanup_usage_error() {
  set +e
  bash "$SAFE_CLEANUP" 2>/dev/null
  local rc=$?
  set -e
  [ "$rc" -eq 2 ]
}

test_safe_cleanup_saved_requires_path() {
  local d
  d=$(mktemp -d)
  echo "plan" > "$d/plan.md"

  set +e
  bash "$SAFE_CLEANUP" "$d" --saved 2>/dev/null
  local rc=$?
  set -e

  rm -rf "$d"
  [ "$rc" -eq 2 ]
}

# --- Run ---

echo "Testing safe-cleanup.sh and record-round.sh..."
echo ""

run_test "record-round appends to jsonl"               test_record_round_appends_jsonl
run_test "record-round writes last-approved on APPROVED" test_record_round_writes_last_approved_only_on_approved
run_test "record-round rejects bad args"               test_record_round_rejects_bad_args
run_test "record-round fails without plan.md"          test_record_round_fails_without_plan
run_test "record-round hashes the changeset"           test_record_round_hashes_the_changeset
run_test "record-round marker cannot escape work_dir"  test_record_round_marker_cannot_escape_work_dir

run_test "safe-cleanup proceeds without prior record"  test_safe_cleanup_no_record_proceeds
run_test "safe-cleanup proceeds when SHA matches"      test_safe_cleanup_matching_sha_proceeds
run_test "safe-cleanup refuses on SHA mismatch"        test_safe_cleanup_refuses_on_mismatch
run_test "safe-cleanup is no-op if dir missing"        test_safe_cleanup_missing_dir_is_noop
run_test "safe-cleanup proceeds on REVISE-only rounds" test_safe_cleanup_revise_only_proceeds
run_test "safe-cleanup refuses without --saved"        test_safe_cleanup_refuses_without_saved
run_test "safe-cleanup --force bypasses missing saved" test_safe_cleanup_force_bypasses_missing_saved
run_test "safe-cleanup refuses when saved not found"   test_safe_cleanup_refuses_saved_not_found
run_test "safe-cleanup refuses when saved mismatches"  test_safe_cleanup_refuses_saved_mismatch
run_test "safe-cleanup refuses saved inside work_dir"  test_safe_cleanup_refuses_saved_inside_workdir
run_test "safe-cleanup skips SAVED gate on changeset"  test_safe_cleanup_changeset_needs_no_saved_copy
run_test "safe-cleanup refuses when changeset moved"   test_safe_cleanup_refuses_when_changeset_moved
run_test "safe-cleanup refuses an unusable marker"     test_safe_cleanup_refuses_unusable_marker
run_test "changeset base is a frozen SHA"              test_changeset_base_is_a_frozen_sha
run_test "safe-cleanup usage error on no args"         test_safe_cleanup_usage_error
run_test "safe-cleanup --saved requires a path"        test_safe_cleanup_saved_requires_path

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

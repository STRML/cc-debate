#!/bin/bash
# Tests for scripts/run-parallel-acpx.sh
# Uses mock-acpx.sh as a fake acpx binary.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PARALLEL="$PROJECT_DIR/scripts/run-parallel-acpx.sh"
MOCK="$SCRIPT_DIR/mock-acpx.sh"
MOCK_AGY="$SCRIPT_DIR/mock-agy.sh"
MOCK_CLAUDE="$SCRIPT_DIR/mock-claude.sh"

PASS=0
FAIL=0

# --- Helpers ---

setup_env() {
  local work_dir
  work_dir=$(mktemp -d)

  # Create config with 2 reviewers
  cat > "$work_dir/config.json" << 'EOF'
{
  "reviewers": {
    "alpha": { "agent": "codex", "timeout": 10 },
    "beta": { "agent": "antigravity", "timeout": 10 },
    "gamma": { "agent": "opus", "timeout": 10 }
  }
}
EOF

  echo "$work_dir"
}

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

# --- Tests ---

test_parallel_happy_path() {
  local tmp_dir review_id work_dir
  tmp_dir=$(setup_env)
  review_id="test-$(date +%s)"
  work_dir=".tmp/ai-review-${review_id}"

  mkdir -p "$work_dir"
  echo "Test plan" > "$work_dir/plan.md"

  # Ensure mock acpx is on PATH
  PATH="$SCRIPT_DIR:$PATH" \
  SKIP_SESSION_CHECK=1 \
  MOCK_ACPX_RESPONSE="Mock review. VERDICT: APPROVED" \
    bash "$PARALLEL" "$tmp_dir/config.json" "$review_id" 2>/dev/null

  local exit_code=$?

  # All reviewers should have output
  [ -f "$work_dir/alpha-exit.txt" ] || { rm -rf "$work_dir" "$tmp_dir"; return 1; }
  [ -f "$work_dir/beta-exit.txt" ] || { rm -rf "$work_dir" "$tmp_dir"; return 1; }
  [ -f "$work_dir/gamma-exit.txt" ] || { rm -rf "$work_dir" "$tmp_dir"; return 1; }
  [ -f "$work_dir/alpha-output.md" ] || { rm -rf "$work_dir" "$tmp_dir"; return 1; }
  [ -f "$work_dir/beta-output.md" ] || { rm -rf "$work_dir" "$tmp_dir"; return 1; }
  [ -f "$work_dir/gamma-output.md" ] || { rm -rf "$work_dir" "$tmp_dir"; return 1; }

  # All should succeed
  [ "$(cat "$work_dir/alpha-exit.txt")" = "0" ] || { rm -rf "$work_dir" "$tmp_dir"; return 1; }
  [ "$(cat "$work_dir/beta-exit.txt")" = "0" ] || { rm -rf "$work_dir" "$tmp_dir"; return 1; }
  [ "$(cat "$work_dir/gamma-exit.txt")" = "0" ] || { rm -rf "$work_dir" "$tmp_dir"; return 1; }

  rm -rf "$work_dir" "$tmp_dir"
}

test_subset_reviewers() {
  local tmp_dir review_id work_dir
  tmp_dir=$(setup_env)
  review_id="test-$(date +%s)-sub"
  work_dir=".tmp/ai-review-${review_id}"

  mkdir -p "$work_dir"
  echo "Test plan" > "$work_dir/plan.md"

  # Only run alpha
  PATH="$SCRIPT_DIR:$PATH" \
  SKIP_SESSION_CHECK=1 \
  MOCK_ACPX_RESPONSE="Mock review. VERDICT: APPROVED" \
    bash "$PARALLEL" "$tmp_dir/config.json" "$review_id" "alpha" 2>/dev/null

  # Alpha should exist, beta should NOT
  [ -f "$work_dir/alpha-exit.txt" ] || { rm -rf "$work_dir" "$tmp_dir"; return 1; }
  [ ! -f "$work_dir/beta-exit.txt" ] || { rm -rf "$work_dir" "$tmp_dir"; return 1; }

  rm -rf "$work_dir" "$tmp_dir"
}

test_missing_plan_fails() {
  local tmp_dir review_id work_dir
  tmp_dir=$(setup_env)
  review_id="test-$(date +%s)-noplan"
  work_dir=".tmp/ai-review-${review_id}"

  mkdir -p "$work_dir"
  # No plan.md

  set +e
  bash "$PARALLEL" "$tmp_dir/config.json" "$review_id" 2>/dev/null
  local exit_code=$?
  set -e

  [ "$exit_code" -ne 0 ] || { rm -rf "$work_dir" "$tmp_dir"; return 1; }

  rm -rf "$work_dir" "$tmp_dir"
}

test_missing_config_fails() {
  local review_id work_dir
  review_id="test-$(date +%s)-nocfg"
  work_dir=".tmp/ai-review-${review_id}"

  mkdir -p "$work_dir"
  echo "Test plan" > "$work_dir/plan.md"

  set +e
  bash "$PARALLEL" "/nonexistent/config.json" "$review_id" 2>/dev/null
  local exit_code=$?
  set -e

  [ "$exit_code" -ne 0 ] || { rm -rf "$work_dir"; return 1; }

  rm -rf "$work_dir"
}

test_prompt_files_cleaned_up() {
  local tmp_dir review_id work_dir
  tmp_dir=$(setup_env)
  review_id="test-$(date +%s)-clean"
  work_dir=".tmp/ai-review-${review_id}"

  mkdir -p "$work_dir"
  echo "Test plan" > "$work_dir/plan.md"
  # Simulate leftover prompt files from a prior debate
  echo "old prompt" > "$work_dir/alpha-prompt.txt"

  PATH="$SCRIPT_DIR:$PATH" \
  SKIP_SESSION_CHECK=1 \
  MOCK_ACPX_RESPONSE="Mock review. VERDICT: APPROVED" \
    bash "$PARALLEL" "$tmp_dir/config.json" "$review_id" 2>/dev/null

  # Prompt files should be cleaned up
  [ ! -f "$work_dir/alpha-prompt.txt" ] || { rm -rf "$work_dir" "$tmp_dir"; return 1; }

  rm -rf "$work_dir" "$tmp_dir"
}

test_invalid_review_id_rejected() {
  set +e
  bash "$PARALLEL" "/dev/null" "../escape" 2>/dev/null
  local exit_code=$?
  set -e

  [ "$exit_code" -ne 0 ] || return 1
}

test_reviewer_name_sanitization() {
  # Reviewer names with path traversal or spaces should be skipped, not cause errors
  local tmp_dir review_id work_dir
  tmp_dir=$(mktemp -d)
  review_id="test-$(date +%s)-san"
  work_dir=".tmp/ai-review-${review_id}"

  cat > "$tmp_dir/config.json" << 'EOF'
{
  "reviewers": {
    "../evil": { "agent": "codex", "timeout": 10 },
    "good": { "agent": "codex", "timeout": 10 }
  }
}
EOF

  mkdir -p "$work_dir"
  echo "Test plan" > "$work_dir/plan.md"

  PATH="$SCRIPT_DIR:$PATH" \
  SKIP_SESSION_CHECK=1 \
  MOCK_ACPX_RESPONSE="VERDICT: APPROVED" \
    bash "$PARALLEL" "$tmp_dir/config.json" "$review_id" 2>/dev/null

  # Evil reviewer should be skipped — no exit file with "../evil" in path
  [ ! -f "$work_dir/../evil-exit.txt" ] || { rm -rf "$work_dir" "$tmp_dir"; return 1; }

  # Good reviewer should still run
  [ -f "$work_dir/good-exit.txt" ] || { rm -rf "$work_dir" "$tmp_dir"; return 1; }

  rm -rf "$work_dir" "$tmp_dir"
}

test_whitespace_trimmed_reviewer_list() {
  # "/debate:all codex, antigravity" (space after comma) should work correctly
  local tmp_dir review_id work_dir
  tmp_dir=$(setup_env)
  review_id="test-$(date +%s)-trim"
  work_dir=".tmp/ai-review-${review_id}"

  mkdir -p "$work_dir"
  echo "Test plan" > "$work_dir/plan.md"

  # Pass "alpha, beta" with a space after the comma
  PATH="$SCRIPT_DIR:$PATH" \
  SKIP_SESSION_CHECK=1 \
  MOCK_ACPX_RESPONSE="VERDICT: APPROVED" \
    bash "$PARALLEL" "$tmp_dir/config.json" "$review_id" "alpha, beta" 2>/dev/null

  # Both should have run despite the space
  [ -f "$work_dir/alpha-exit.txt" ] || { rm -rf "$work_dir" "$tmp_dir"; return 1; }
  [ -f "$work_dir/beta-exit.txt" ] || { rm -rf "$work_dir" "$tmp_dir"; return 1; }

  rm -rf "$work_dir" "$tmp_dir"
}

test_invoke_logs_created() {
  # Verify invoke stderr is captured to <name>-invoke.log
  local tmp_dir review_id work_dir
  tmp_dir=$(setup_env)
  review_id="test-$(date +%s)-log"
  work_dir=".tmp/ai-review-${review_id}"

  mkdir -p "$work_dir"
  echo "Test plan" > "$work_dir/plan.md"

  PATH="$SCRIPT_DIR:$PATH" \
  SKIP_SESSION_CHECK=1 \
  MOCK_ACPX_RESPONSE="Mock review. VERDICT: APPROVED" \
    bash "$PARALLEL" "$tmp_dir/config.json" "$review_id" 2>/dev/null

  # Invoke logs should exist for each reviewer
  [ -f "$work_dir/alpha-invoke.log" ] || { rm -rf "$work_dir" "$tmp_dir"; return 1; }
  [ -f "$work_dir/beta-invoke.log" ] || { rm -rf "$work_dir" "$tmp_dir"; return 1; }

  rm -rf "$work_dir" "$tmp_dir"
}

test_one_failure_doesnt_block_others() {
  # If one reviewer fails, others should still complete
  local tmp_dir review_id work_dir
  tmp_dir=$(mktemp -d)
  review_id="test-$(date +%s)-indep"
  work_dir=".tmp/ai-review-${review_id}"

  # Config with a failing and succeeding reviewer
  cat > "$tmp_dir/config.json" << 'EOF'
{
  "reviewers": {
    "good": { "agent": "codex", "timeout": 10 },
    "bad": { "agent": "antigravity", "timeout": 10 }
  }
}
EOF

  mkdir -p "$work_dir"
  echo "Test plan" > "$work_dir/plan.md"

  # Can't selectively fail one mock per reviewer in this setup,
  # so we test that both get exit files regardless
  PATH="$SCRIPT_DIR:$PATH" \
  SKIP_SESSION_CHECK=1 \
  MOCK_ACPX_RESPONSE="Mock review. VERDICT: APPROVED" \
    bash "$PARALLEL" "$tmp_dir/config.json" "$review_id" 2>/dev/null

  # Both should have produced exit files (independent execution)
  [ -f "$work_dir/good-exit.txt" ] || { rm -rf "$work_dir" "$tmp_dir"; return 1; }
  [ -f "$work_dir/bad-exit.txt" ] || { rm -rf "$work_dir" "$tmp_dir"; return 1; }

  rm -rf "$work_dir" "$tmp_dir"
}

# --- Run ---

echo ""
echo "=== run-parallel-acpx.sh tests ==="
echo ""

# Create mock binaries on PATH for acpx, agy, and claude (direct CLI paths)
ln -sf "$MOCK" "$SCRIPT_DIR/acpx"
chmod +x "$SCRIPT_DIR/acpx"
ln -sf "$MOCK_AGY" "$SCRIPT_DIR/agy"
chmod +x "$SCRIPT_DIR/agy"
ln -sf "$MOCK_CLAUDE" "$SCRIPT_DIR/claude"
chmod +x "$SCRIPT_DIR/claude"
trap 'rm -f "$SCRIPT_DIR/acpx" "$SCRIPT_DIR/agy" "$SCRIPT_DIR/claude"' EXIT

run_test "parallel happy path" test_parallel_happy_path
run_test "subset reviewers" test_subset_reviewers
run_test "missing plan fails" test_missing_plan_fails
run_test "missing config fails" test_missing_config_fails
run_test "prompt files cleaned up" test_prompt_files_cleaned_up
run_test "invalid review ID rejected" test_invalid_review_id_rejected
run_test "reviewer name sanitization" test_reviewer_name_sanitization
run_test "whitespace trimmed reviewer list" test_whitespace_trimmed_reviewer_list
run_test "invoke logs created" test_invoke_logs_created
run_test "one failure doesnt block others" test_one_failure_doesnt_block_others

echo ""
echo "=== Results: $PASS passed, $FAIL failed ($(( PASS + FAIL )) total) ==="

[ "$FAIL" -eq 0 ]

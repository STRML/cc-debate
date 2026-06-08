#!/bin/bash
# Tests for scripts/invoke-acpx.sh
# Uses mock-acpx.sh as a fake acpx binary.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
INVOKE="$PROJECT_DIR/scripts/invoke-acpx.sh"
MOCK="$SCRIPT_DIR/mock-acpx.sh"
MOCK_GEMINI="$SCRIPT_DIR/mock-gemini.sh"
MOCK_CLAUDE="$SCRIPT_DIR/mock-claude.sh"

PASS=0
FAIL=0
TESTS=()

# --- Helpers ---

setup_work_dir() {
  local dir
  dir=$(mktemp -d)
  echo "Test plan content" > "$dir/plan.md"
  echo "$dir"
}

setup_config() {
  local dir="$1"
  cat > "$dir/config.json" << 'EOF'
{
  "reviewers": {
    "test-reviewer": {
      "agent": "codex",
      "timeout": 30,
      "system_prompt": "You are a test reviewer."
    },
    "no-prompt": {
      "agent": "gemini",
      "timeout": 60
    },
    "opus-reviewer": {
      "agent": "opus",
      "timeout": 60,
      "system_prompt": "You are The Skeptic."
    }
  }
}
EOF
  echo "$dir/config.json"
}

run_test() {
  local name="$1"
  shift
  TESTS+=("$name")
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

test_happy_path() {
  local work_dir config
  work_dir=$(setup_work_dir)
  config=$(setup_config "$work_dir")

  SKIP_SESSION_CHECK=1 \
  PATH="$SCRIPT_DIR:$PATH" \
  MOCK_ACPX_RESPONSE="Great plan! VERDICT: APPROVED" \
    bash "$INVOKE" "$config" "$work_dir" "test-reviewer" 2>/dev/null

  # Check output file
  [ -f "$work_dir/test-reviewer-output.md" ] || return 1
  grep -q "VERDICT: APPROVED" "$work_dir/test-reviewer-output.md" || return 1

  # Check exit file
  [ -f "$work_dir/test-reviewer-exit.txt" ] || return 1
  [ "$(cat "$work_dir/test-reviewer-exit.txt")" = "0" ] || return 1

  rm -rf "$work_dir"
}

test_prompt_file_used_for_debate() {
  local work_dir config
  work_dir=$(setup_work_dir)
  config=$(setup_config "$work_dir")

  # Write a debate prompt
  echo "Debate: do you still think X?" > "$work_dir/test-reviewer-prompt.txt"

  local log_file="$work_dir/acpx-log.txt"

  SKIP_SESSION_CHECK=1 \
  PATH="$SCRIPT_DIR:$PATH" \
  MOCK_ACPX_RESPONSE="I stand by my position. VERDICT: REVISE" \
  MOCK_ACPX_LOG="$log_file" \
    bash "$INVOKE" "$config" "$work_dir" "test-reviewer" 2>/dev/null

  # The prompt file passed to acpx should be the debate prompt, not the generated one
  grep -q "test-reviewer-prompt.txt" "$log_file" || return 1

  # acpx must be invoked read-only: reads auto-approved, writes auto-denied
  grep -q "\-\-approve-reads" "$log_file" || return 1
  grep -q "\-\-non-interactive-permissions deny" "$log_file" || return 1

  # Should NOT have generated an acpx-prompt file
  [ ! -f "$work_dir/test-reviewer-acpx-prompt.txt" ] || return 1

  rm -rf "$work_dir"
}

test_initial_prompt_includes_plan() {
  local work_dir config
  work_dir=$(setup_work_dir)
  config=$(setup_config "$work_dir")

  SKIP_SESSION_CHECK=1 \
  PATH="$SCRIPT_DIR:$PATH" \
  MOCK_ACPX_RESPONSE="Looks good. VERDICT: APPROVED" \
    bash "$INVOKE" "$config" "$work_dir" "test-reviewer" 2>/dev/null

  # Generated prompt should include system prompt and plan
  [ -f "$work_dir/test-reviewer-acpx-prompt.txt" ] || return 1
  grep -q "You are a test reviewer" "$work_dir/test-reviewer-acpx-prompt.txt" || return 1
  grep -q "Test plan content" "$work_dir/test-reviewer-acpx-prompt.txt" || return 1

  rm -rf "$work_dir"
}

test_fallback_system_prompt() {
  local work_dir config
  work_dir=$(setup_work_dir)
  config=$(setup_config "$work_dir")

  # "no-prompt" reviewer has no system_prompt in config
  SKIP_SESSION_CHECK=1 \
  PATH="$SCRIPT_DIR:$PATH" \
  MOCK_ACPX_RESPONSE="VERDICT: APPROVED" \
    bash "$INVOKE" "$config" "$work_dir" "no-prompt" 2>/dev/null

  # Should use the built-in fallback
  grep -q "senior engineer" "$work_dir/no-prompt-acpx-prompt.txt" || return 1

  rm -rf "$work_dir"
}

test_acpx_failure_populates_output() {
  local work_dir config
  work_dir=$(setup_work_dir)
  config=$(setup_config "$work_dir")

  SKIP_SESSION_CHECK=1 \
  PATH="$SCRIPT_DIR:$PATH" \
  MOCK_ACPX_EXIT=1 \
  MOCK_ACPX_RESPONSE="" \
  MOCK_ACPX_STDERR="connection refused" \
    bash "$INVOKE" "$config" "$work_dir" "test-reviewer" 2>/dev/null || true

  # Exit file should be non-zero
  [ "$(cat "$work_dir/test-reviewer-exit.txt")" != "0" ] || return 1

  # Output should contain error info
  grep -q "acpx error" "$work_dir/test-reviewer-output.md" || return 1

  rm -rf "$work_dir"
}

test_empty_response_detected() {
  local work_dir config
  work_dir=$(setup_work_dir)
  config=$(setup_config "$work_dir")

  set +e
  SKIP_SESSION_CHECK=1 \
  PATH="$SCRIPT_DIR:$PATH" \
  MOCK_ACPX_EXIT=0 \
  MOCK_ACPX_RESPONSE="" \
    bash "$INVOKE" "$config" "$work_dir" "test-reviewer" 2>/dev/null
  local exit_code=$?
  set -e

  # Should fail with exit 1
  [ "$exit_code" -eq 1 ] || return 1

  # Exit file should be 1
  [ "$(cat "$work_dir/test-reviewer-exit.txt")" = "1" ] || return 1

  # Output should mention empty response
  grep -q "Empty response" "$work_dir/test-reviewer-output.md" || return 1

  rm -rf "$work_dir"
}

test_missing_config_fails() {
  local work_dir
  work_dir=$(setup_work_dir)

  set +e
  bash "$INVOKE" "/nonexistent/config.json" "$work_dir" "test" 2>/dev/null
  local exit_code=$?
  set -e

  [ "$exit_code" -ne 0 ] || return 1

  rm -rf "$work_dir"
}

test_missing_plan_fails() {
  local work_dir config
  work_dir=$(mktemp -d)
  config=$(setup_config "$work_dir")

  # No plan.md in work_dir
  set +e
  bash "$INVOKE" "$config" "$work_dir" "test-reviewer" 2>/dev/null
  local exit_code=$?
  set -e

  [ "$exit_code" -ne 0 ] || return 1

  rm -rf "$work_dir"
}

test_unknown_reviewer_fails() {
  local work_dir config
  work_dir=$(setup_work_dir)
  config=$(setup_config "$work_dir")

  set +e
  bash "$INVOKE" "$config" "$work_dir" "nonexistent-reviewer" 2>/dev/null
  local exit_code=$?
  set -e

  [ "$exit_code" -ne 0 ] || return 1

  rm -rf "$work_dir"
}

test_empty_plan_rejected() {
  local work_dir config
  work_dir=$(mktemp -d)
  config=$(setup_config "$work_dir")

  # plan.md exists but is empty
  touch "$work_dir/plan.md"

  set +e
  bash "$INVOKE" "$config" "$work_dir" "test-reviewer" 2>/dev/null
  local exit_code=$?
  set -e

  [ "$exit_code" -ne 0 ] || { rm -rf "$work_dir"; return 1; }

  rm -rf "$work_dir"
}

test_npx_fallback() {
  local work_dir config
  work_dir=$(setup_work_dir)
  config=$(setup_config "$work_dir")

  # Build a minimal PATH containing only our fake npx (no acpx).
  # We use an isolated dir to prevent the system acpx from being found.
  local fake_dir="$work_dir/fake-bin"
  mkdir -p "$fake_dir"

  local mock_path="$MOCK"
  # fake npx: invoked as "npx acpx@latest ..."; shift past package arg then run mock
  printf '#!/bin/bash\nshift\nexec bash "%s" "$@"\n' "$mock_path" > "$fake_dir/npx"
  chmod +x "$fake_dir/npx"

  # Build a sanitized PATH: only essential system dirs + our fake-bin, no acpx
  local safe_path="/usr/bin:/bin:$fake_dir"

  # Verify our fake-bin has npx but NOT acpx
  PATH="$safe_path" command -v npx > /dev/null 2>&1 || { rm -rf "$work_dir"; return 1; }
  PATH="$safe_path" command -v acpx > /dev/null 2>&1 && { rm -rf "$work_dir"; return 1; }  # fail if acpx found

  SKIP_SESSION_CHECK=1 \
  PATH="$safe_path" \
  MOCK_ACPX_RESPONSE="VERDICT: APPROVED" \
    bash "$INVOKE" "$config" "$work_dir" "test-reviewer" 2>/dev/null

  [ "$(cat "$work_dir/test-reviewer-exit.txt")" = "0" ] || { rm -rf "$work_dir"; return 1; }
  grep -q "VERDICT: APPROVED" "$work_dir/test-reviewer-output.md" || { rm -rf "$work_dir"; return 1; }

  rm -rf "$work_dir"
}

test_timeout_override() {
  local work_dir config
  work_dir=$(setup_work_dir)
  config=$(setup_config "$work_dir")
  local log_file="$work_dir/acpx-log.txt"

  # Pass timeout as 4th arg — the invoke script wraps with system timeout binary
  SKIP_SESSION_CHECK=1 \
  PATH="$SCRIPT_DIR:$PATH" \
  MOCK_ACPX_RESPONSE="VERDICT: APPROVED" \
  MOCK_ACPX_LOG="$log_file" \
    bash "$INVOKE" "$config" "$work_dir" "test-reviewer" "45" 2>/dev/null

  # Can't easily verify the timeout value was used (it's an arg to the timeout binary),
  # but we can verify the script succeeded
  [ "$(cat "$work_dir/test-reviewer-exit.txt")" = "0" ] || return 1

  rm -rf "$work_dir"
}

# --- Session check tests ---

test_session_auto_created() {
  # sessions ensure creates a session when none exists, then proceeds
  local work_dir config
  work_dir=$(setup_work_dir)
  config=$(setup_config "$work_dir")
  local log_file="$work_dir/acpx-log.txt"

  PATH="$SCRIPT_DIR:$PATH" \
  MOCK_ACPX_SESSION_ENSURE_EXIT=0 \
  MOCK_ACPX_RESPONSE="Great plan! VERDICT: APPROVED" \
  MOCK_ACPX_LOG="$log_file" \
    bash "$INVOKE" "$config" "$work_dir" "test-reviewer" 2>/dev/null

  [ "$(cat "$work_dir/test-reviewer-exit.txt")" = "0" ] || return 1
  grep -q "VERDICT: APPROVED" "$work_dir/test-reviewer-output.md" || return 1

  # Log should show sessions ensure was called
  grep -q "sessions ensure" "$log_file" || return 1

  rm -rf "$work_dir"
}

test_session_creation_fails_exits_4() {
  # When sessions ensure fails, should exit 4
  local work_dir config
  work_dir=$(setup_work_dir)
  config=$(setup_config "$work_dir")

  set +e
  PATH="$SCRIPT_DIR:$PATH" \
  MOCK_ACPX_SESSION_ENSURE_EXIT=1 \
  MOCK_ACPX_RESPONSE="should not reach this" \
    bash "$INVOKE" "$config" "$work_dir" "test-reviewer" 2>/dev/null
  local exit_code=$?
  set -e

  # Should exit 4
  [ "$exit_code" -eq 4 ] || return 1

  # Exit file should be 4
  [ "$(cat "$work_dir/test-reviewer-exit.txt")" = "4" ] || return 1

  # Output should mention session failure
  grep -q "session" "$work_dir/test-reviewer-output.md" || return 1

  rm -rf "$work_dir"
}

test_session_exists_no_extra_calls() {
  # sessions ensure is idempotent: reuses existing session without creating a new one
  local work_dir config
  work_dir=$(setup_work_dir)
  config=$(setup_config "$work_dir")
  local log_file="$work_dir/acpx-log.txt"

  PATH="$SCRIPT_DIR:$PATH" \
  MOCK_ACPX_SESSION_ENSURE_EXIT=0 \
  MOCK_ACPX_RESPONSE="VERDICT: APPROVED" \
  MOCK_ACPX_LOG="$log_file" \
    bash "$INVOKE" "$config" "$work_dir" "test-reviewer" 2>/dev/null

  [ "$(cat "$work_dir/test-reviewer-exit.txt")" = "0" ] || return 1

  # sessions ensure (not sessions new) is the call — idempotent, no session accumulation
  grep -q "sessions ensure" "$log_file" || return 1
  ! grep -q "sessions new" "$log_file" || return 1

  rm -rf "$work_dir"
}

test_skip_session_check_env() {
  # SKIP_SESSION_CHECK should bypass session validation entirely
  local work_dir config
  work_dir=$(setup_work_dir)
  config=$(setup_config "$work_dir")
  local log_file="$work_dir/acpx-log.txt"

  # Session list would fail, but we skip the check
  SKIP_SESSION_CHECK=1 \
  PATH="$SCRIPT_DIR:$PATH" \
  MOCK_ACPX_SESSION_LIST_EXIT=1 \
  MOCK_ACPX_SESSION_NEW_EXIT=1 \
  MOCK_ACPX_RESPONSE="VERDICT: APPROVED" \
  MOCK_ACPX_LOG="$log_file" \
    bash "$INVOKE" "$config" "$work_dir" "test-reviewer" 2>/dev/null

  # Should succeed — session check was skipped
  [ "$(cat "$work_dir/test-reviewer-exit.txt")" = "0" ] || return 1

  # Log should NOT contain any session commands
  ! grep -q "sessions" "$log_file" || return 1

  rm -rf "$work_dir"
}

test_stderr_surfaced_on_failure() {
  # When acpx fails with stderr, stderr should appear in output
  local work_dir config
  work_dir=$(setup_work_dir)
  config=$(setup_config "$work_dir")

  SKIP_SESSION_CHECK=1 \
  PATH="$SCRIPT_DIR:$PATH" \
  MOCK_ACPX_EXIT=1 \
  MOCK_ACPX_RESPONSE="" \
  MOCK_ACPX_STDERR="Error: rate limit exceeded" \
    bash "$INVOKE" "$config" "$work_dir" "test-reviewer" 2>/dev/null || true

  # Output should contain the stderr content
  grep -q "rate limit exceeded" "$work_dir/test-reviewer-output.md" || return 1

  # Stderr log should also exist
  [ -s "$work_dir/test-reviewer-stderr.log" ] || return 1
  grep -q "rate limit exceeded" "$work_dir/test-reviewer-stderr.log" || return 1

  rm -rf "$work_dir"
}

test_gemini_uses_direct_cli() {
  # When agent is "gemini", invoke-acpx.sh should use the gemini CLI directly
  # (not acpx) because Gemini's ACP mode is non-functional.
  local work_dir config acpx_log gemini_log
  work_dir=$(setup_work_dir)
  config=$(setup_config "$work_dir")
  acpx_log="$work_dir/acpx-log.txt"
  gemini_log="$work_dir/gemini-log.txt"

  SKIP_SESSION_CHECK=1 \
  PATH="$SCRIPT_DIR:$PATH" \
  MOCK_ACPX_LOG="$acpx_log" \
  MOCK_GEMINI_LOG="$gemini_log" \
    bash "$INVOKE" "$config" "$work_dir" "no-prompt" 2>/dev/null

  # Should succeed
  [ "$(cat "$work_dir/no-prompt-exit.txt")" = "0" ] || return 1

  # Output should be from the gemini mock (default: "Mock gemini review. VERDICT: APPROVED")
  grep -q "Mock gemini review" "$work_dir/no-prompt-output.md" || return 1

  # gemini mock was called, in read-only plan mode
  [ -f "$gemini_log" ] || return 1
  grep -q "gemini" "$gemini_log" || return 1
  grep -q "\-\-approval-mode plan" "$gemini_log" || return 1

  # acpx should NOT have been called for this reviewer
  ! grep -q "no-prompt" "$acpx_log" 2>/dev/null || return 1

  rm -rf "$work_dir"
}

test_gemini_skips_session_ensure() {
  # sessions ensure should NOT be called for the gemini agent
  local work_dir config log_file
  work_dir=$(setup_work_dir)
  config=$(setup_config "$work_dir")
  log_file="$work_dir/invoke-log.txt"

  PATH="$SCRIPT_DIR:$PATH" \
  MOCK_ACPX_SESSION_ENSURE_EXIT=1 \
  MOCK_ACPX_LOG="$log_file" \
    bash "$INVOKE" "$config" "$work_dir" "no-prompt" 2>/dev/null

  # Should succeed (session ensure was not called, so its failure doesn't matter)
  [ "$(cat "$work_dir/no-prompt-exit.txt")" = "0" ] || return 1

  # sessions ensure should NOT have been called
  ! grep -q "sessions ensure" "$log_file" 2>/dev/null || return 1

  rm -rf "$work_dir"
}

test_opus_uses_direct_cli() {
  # When agent is "opus", invoke-acpx.sh should use claude --print --model claude-opus-4-8
  # (the current default when config sets no model) directly, not via acpx.
  local work_dir config acpx_log claude_log
  work_dir=$(setup_work_dir)
  config=$(setup_config "$work_dir")
  acpx_log="$work_dir/acpx-log.txt"
  claude_log="$work_dir/claude-log.txt"

  SKIP_SESSION_CHECK=1 \
  PATH="$SCRIPT_DIR:$PATH" \
  MOCK_ACPX_LOG="$acpx_log" \
  MOCK_CLAUDE_LOG="$claude_log" \
    bash "$INVOKE" "$config" "$work_dir" "opus-reviewer" 2>/dev/null

  # Should succeed
  [ "$(cat "$work_dir/opus-reviewer-exit.txt")" = "0" ] || return 1

  # Output should be from claude mock (default: "Mock Claude Opus review. VERDICT: APPROVED")
  grep -q "Mock Claude Opus review" "$work_dir/opus-reviewer-output.md" || return 1

  # claude mock was called with --print, --permission-mode plan (read-only), and --model
  [ -f "$claude_log" ] || return 1
  grep -q "\-\-print" "$claude_log" || return 1
  grep -q "\-\-permission-mode plan" "$claude_log" || return 1
  grep -q "claude-opus-4-8" "$claude_log" || return 1

  # acpx should NOT have been called for this reviewer
  ! grep -q "opus-reviewer" "$acpx_log" 2>/dev/null || return 1

  rm -rf "$work_dir"
}

test_opus_skips_session_ensure() {
  # sessions ensure should NOT be called for the opus agent
  local work_dir config log_file
  work_dir=$(setup_work_dir)
  config=$(setup_config "$work_dir")
  log_file="$work_dir/invoke-log.txt"

  PATH="$SCRIPT_DIR:$PATH" \
  MOCK_ACPX_SESSION_ENSURE_EXIT=1 \
  MOCK_ACPX_LOG="$log_file" \
    bash "$INVOKE" "$config" "$work_dir" "opus-reviewer" 2>/dev/null

  # Should succeed (session ensure was not called, so its failure doesn't matter)
  [ "$(cat "$work_dir/opus-reviewer-exit.txt")" = "0" ] || return 1

  # sessions ensure should NOT have been called
  ! grep -q "sessions ensure" "$log_file" 2>/dev/null || return 1

  rm -rf "$work_dir"
}

# --- Run ---

echo ""
echo "=== invoke-acpx.sh tests ==="
echo ""

# Create mock binaries on PATH for acpx, gemini, and claude (direct CLI paths)
ln -sf "$MOCK" "$SCRIPT_DIR/acpx"
chmod +x "$SCRIPT_DIR/acpx"
ln -sf "$MOCK_GEMINI" "$SCRIPT_DIR/gemini"
chmod +x "$SCRIPT_DIR/gemini"
ln -sf "$MOCK_CLAUDE" "$SCRIPT_DIR/claude"
chmod +x "$SCRIPT_DIR/claude"
trap 'rm -f "$SCRIPT_DIR/acpx" "$SCRIPT_DIR/gemini" "$SCRIPT_DIR/claude"' EXIT

run_test "happy path" test_happy_path
run_test "debate prompt file" test_prompt_file_used_for_debate
run_test "initial prompt includes plan" test_initial_prompt_includes_plan
run_test "fallback system prompt" test_fallback_system_prompt
run_test "acpx failure populates output" test_acpx_failure_populates_output
run_test "empty response detected" test_empty_response_detected
run_test "missing config fails" test_missing_config_fails
run_test "missing plan fails" test_missing_plan_fails
run_test "empty plan rejected" test_empty_plan_rejected
run_test "npx fallback" test_npx_fallback
run_test "unknown reviewer fails" test_unknown_reviewer_fails
run_test "timeout override" test_timeout_override
run_test "session auto-created" test_session_auto_created
run_test "session creation fails exits 4" test_session_creation_fails_exits_4
run_test "session exists no extra calls" test_session_exists_no_extra_calls
run_test "skip session check env" test_skip_session_check_env
run_test "stderr surfaced on failure" test_stderr_surfaced_on_failure
run_test "gemini uses direct CLI" test_gemini_uses_direct_cli
run_test "gemini skips session ensure" test_gemini_skips_session_ensure
run_test "opus uses direct CLI" test_opus_uses_direct_cli
run_test "opus skips session ensure" test_opus_skips_session_ensure

echo ""
echo "=== Results: $PASS passed, $FAIL failed ($(( PASS + FAIL )) total) ==="

[ "$FAIL" -eq 0 ]

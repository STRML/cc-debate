#!/bin/bash
# Tests for scripts/invoke-acpx.sh
# Uses mock-acpx.sh as a fake acpx binary.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
INVOKE="$PROJECT_DIR/scripts/invoke-acpx.sh"
MOCK="$SCRIPT_DIR/mock-acpx.sh"
MOCK_AGY="$SCRIPT_DIR/mock-agy.sh"
MOCK_CLAUDE="$SCRIPT_DIR/mock-claude.sh"
MOCK_CODEX="$SCRIPT_DIR/mock-codex.sh"

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
      "agent": "antigravity",
      "timeout": 60
    },
    "opus-reviewer": {
      "agent": "opus",
      "timeout": 60,
      "system_prompt": "You are The Skeptic."
    },
    "codex-exec-reviewer": {
      "agent": "codex-exec",
      "timeout": 60,
      "model": "gpt-5.6-sol",
      "effort": "high",
      "system_prompt": "You are The Auditor."
    },
    "oneshot-reviewer": {
      "agent": "kimi-k3",
      "timeout": 60,
      "mode": "exec",
      "system_prompt": "You are The Cartographer."
    },
    "retry-reviewer": {
      "agent": "codex",
      "timeout": 60,
      "retries": 2,
      "system_prompt": "You retry."
    },
    "no-retry-reviewer": {
      "agent": "codex",
      "timeout": 60,
      "retries": 0,
      "system_prompt": "You never retry."
    },
    "bad-mode-reviewer": {
      "agent": "codex",
      "timeout": 60,
      "mode": "sesion",
      "system_prompt": "You have a typo in your mode."
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

test_antigravity_uses_direct_cli() {
  # When agent is "antigravity", invoke-acpx.sh should use the agy CLI directly
  # (not acpx) because Antigravity has no native ACP support yet.
  local work_dir config acpx_log agy_log
  work_dir=$(setup_work_dir)
  config=$(setup_config "$work_dir")
  acpx_log="$work_dir/acpx-log.txt"
  agy_log="$work_dir/agy-log.txt"

  SKIP_SESSION_CHECK=1 \
  PATH="$SCRIPT_DIR:$PATH" \
  MOCK_ACPX_LOG="$acpx_log" \
  MOCK_AGY_LOG="$agy_log" \
    bash "$INVOKE" "$config" "$work_dir" "no-prompt" 2>/dev/null

  # Should succeed
  [ "$(cat "$work_dir/no-prompt-exit.txt")" = "0" ] || return 1

  # Output should be from the agy mock (default: "Mock agy review. VERDICT: APPROVED")
  grep -q "Mock agy review" "$work_dir/no-prompt-output.md" || return 1

  # agy mock was called in print mode with --sandbox; NOT gemini's --approval-mode plan
  [ -f "$agy_log" ] || return 1
  grep -q "agy" "$agy_log" || return 1
  grep -q "\-p" "$agy_log" || return 1
  grep -q "\-\-sandbox" "$agy_log" || return 1
  grep -q "\-\-print-timeout" "$agy_log" || return 1
  ! grep -q "\-\-approval-mode plan" "$agy_log" 2>/dev/null || return 1

  # acpx should NOT have been called for this reviewer
  ! grep -q "no-prompt" "$acpx_log" 2>/dev/null || return 1

  rm -rf "$work_dir"
}

test_antigravity_skips_session_ensure() {
  # sessions ensure should NOT be called for the antigravity agent
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

# --- codex exec (repo-aware seat) ---

# Two-sided on purpose. Without the valid-value half, an implementation that
# rejected every effort would pass the invalid-value half while breaking every
# correctly-configured codex seat.
test_codex_effort_invalid_is_refused_before_spawn() {
  local work_dir config
  work_dir=$(setup_work_dir)
  config=$(setup_config "$work_dir")

  jq '.reviewers["codex-exec-reviewer"].effort = "bogus"' "$config" > "$config.tmp" \
    && mv "$config.tmp" "$config"

  SKIP_SESSION_CHECK=1 \
  PATH="$SCRIPT_DIR:$PATH" \
  MOCK_CODEX_RESPONSE="should never run. VERDICT: APPROVED" \
    bash "$INVOKE" "$config" "$work_dir" "codex-exec-reviewer" 2>/dev/null

  [ "$(cat "$work_dir/codex-exec-reviewer-exit.txt")" = "2" ] || return 1
  grep -q "Invalid .effort." "$work_dir/codex-exec-reviewer-output.md" || return 1
  ! grep -q "VERDICT: APPROVED" "$work_dir/codex-exec-reviewer-output.md" || return 1

  rm -rf "$work_dir"
}

test_codex_effort_valid_values_accepted() {
  local work_dir config eff
  work_dir=$(setup_work_dir)
  config=$(setup_config "$work_dir")

  for eff in none minimal low medium high xhigh max; do
    jq --arg e "$eff" '.reviewers["codex-exec-reviewer"].effort = $e' "$config" > "$config.tmp" \
      && mv "$config.tmp" "$config"
    rm -f "$work_dir/codex-exec-reviewer-output.md" "$work_dir/codex-exec-reviewer-exit.txt"

    SKIP_SESSION_CHECK=1 \
    PATH="$SCRIPT_DIR:$PATH" \
    MOCK_CODEX_RESPONSE="Reads fine. VERDICT: APPROVED" \
      bash "$INVOKE" "$config" "$work_dir" "codex-exec-reviewer" 2>/dev/null

    [ "$(cat "$work_dir/codex-exec-reviewer-exit.txt")" = "0" ] || { rm -rf "$work_dir"; return 1; }
    grep -q "VERDICT: APPROVED" "$work_dir/codex-exec-reviewer-output.md" \
      || { rm -rf "$work_dir"; return 1; }
  done

  rm -rf "$work_dir"
}

test_codex_exec_happy_path() {
  local work_dir config
  work_dir=$(setup_work_dir)
  config=$(setup_config "$work_dir")

  SKIP_SESSION_CHECK=1 \
  PATH="$SCRIPT_DIR:$PATH" \
  MOCK_CODEX_RESPONSE="Reads fine. VERDICT: APPROVED" \
    bash "$INVOKE" "$config" "$work_dir" "codex-exec-reviewer" 2>/dev/null

  grep -q "VERDICT: APPROVED" "$work_dir/codex-exec-reviewer-output.md" || return 1
  [ "$(cat "$work_dir/codex-exec-reviewer-exit.txt")" = "0" ] || return 1

  rm -rf "$work_dir"
}

# The real binary blocks forever on an open stdin. The mock reproduces that, so
# this test fails if anyone drops the `</dev/null` from the invocation.
#
# stdin is held genuinely open by a long `sleep` upstream in a pipe — inheriting
# an already-closed stdin from the harness would make the mock return anyway and
# the test would pass without proving anything.
#
# The deadline is hand-rolled rather than `timeout`: macOS runners ship no GNU
# coreutils, so bare `timeout` is not found there and the command under test
# never runs at all. (invoke-acpx.sh itself probes for timeout/gtimeout; this
# test must not assume more than the script does.)
test_codex_exec_closes_stdin() {
  local work_dir config pid waited
  work_dir=$(setup_work_dir)
  config=$(setup_config "$work_dir")

  # A fifo opened read-write never reports EOF, so stdin stays genuinely open
  # without a second process whose lifetime would confuse the deadline.
  local fifo="$work_dir/open-stdin.fifo"
  mkfifo "$fifo"
  exec 9<>"$fifo"

  (
    SKIP_SESSION_CHECK=1 \
    PATH="$SCRIPT_DIR:$PATH" \
    MOCK_CODEX_HANG_ON_STDIN=1 \
    MOCK_CODEX_RESPONSE="Survived. VERDICT: APPROVED" \
    bash "$INVOKE" "$config" "$work_dir" "codex-exec-reviewer" <&9
  ) >/dev/null 2>&1 &
  pid=$!

  waited=0
  while kill -0 "$pid" 2>/dev/null && [ "$waited" -lt 25 ]; do
    sleep 1
    waited=$((waited + 1))
  done

  if kill -0 "$pid" 2>/dev/null; then
    kill -9 "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    exec 9>&-
    rm -rf "$work_dir"
    return 1
  fi
  wait "$pid" 2>/dev/null || true
  exec 9>&-

  grep -q "VERDICT: APPROVED" "$work_dir/codex-exec-reviewer-output.md" || { rm -rf "$work_dir"; return 1; }

  rm -rf "$work_dir"
}

test_codex_exec_is_read_only_and_uses_output_flag() {
  local work_dir config log_file
  work_dir=$(setup_work_dir)
  config=$(setup_config "$work_dir")
  log_file="$work_dir/codex-log.txt"

  SKIP_SESSION_CHECK=1 \
  PATH="$SCRIPT_DIR:$PATH" \
  MOCK_CODEX_LOG="$log_file" \
    bash "$INVOKE" "$config" "$work_dir" "codex-exec-reviewer" 2>/dev/null

  grep -q -- "-s read-only" "$log_file" || return 1
  grep -q -- "-o $work_dir/codex-exec-reviewer-output.md" "$log_file" || return 1
  grep -q -- "-m gpt-5.6-sol" "$log_file" || return 1
  grep -q -- "model_reasoning_effort=high" "$log_file" || return 1

  rm -rf "$work_dir"
}

# codex echoes every command it runs; that transcript must not reach the
# synthesizer, only the final message.
test_codex_exec_transcript_kept_out_of_output() {
  local work_dir config
  work_dir=$(setup_work_dir)
  config=$(setup_config "$work_dir")

  SKIP_SESSION_CHECK=1 \
  PATH="$SCRIPT_DIR:$PATH" \
  MOCK_CODEX_RESPONSE="Clean. VERDICT: APPROVED" \
    bash "$INVOKE" "$config" "$work_dir" "codex-exec-reviewer" 2>/dev/null

  grep -q "mock codex transcript" "$work_dir/codex-exec-reviewer-transcript.log" || return 1
  grep -q "mock codex transcript" "$work_dir/codex-exec-reviewer-output.md" && return 1

  rm -rf "$work_dir"
}

test_codex_exec_empty_output_is_a_failure() {
  local work_dir config
  work_dir=$(setup_work_dir)
  config=$(setup_config "$work_dir")

  SKIP_SESSION_CHECK=1 \
  PATH="$SCRIPT_DIR:$PATH" \
  MOCK_CODEX_RESPONSE="" \
    bash "$INVOKE" "$config" "$work_dir" "codex-exec-reviewer" 2>/dev/null || true

  [ "$(cat "$work_dir/codex-exec-reviewer-exit.txt")" = "1" ] || return 1

  rm -rf "$work_dir"
}

# codex-exec never gets an acpx session, so the session check must not run for
# it. Deliberately does NOT set SKIP_SESSION_CHECK — every other codex test does,
# which is exactly what hid this: acpx would be asked to ensure a session for a
# "codex-exec" agent it does not have, fail, and exit 4 before the branch ran.
test_codex_exec_skips_session_check() {
  local work_dir config log_file
  work_dir=$(setup_work_dir)
  config=$(setup_config "$work_dir")
  log_file="$work_dir/acpx-log.txt"

  PATH="$SCRIPT_DIR:$PATH" \
  MOCK_ACPX_LOG="$log_file" \
  MOCK_CODEX_RESPONSE="Ran. VERDICT: APPROVED" \
    bash "$INVOKE" "$config" "$work_dir" "codex-exec-reviewer" 2>/dev/null

  [ "$(cat "$work_dir/codex-exec-reviewer-exit.txt")" = "0" ] || return 1
  # acpx must never have been called at all for this reviewer.
  [ -f "$log_file" ] && return 1

  rm -rf "$work_dir"
}

# codex can exit 0 without writing a final message. A leftover file from an
# earlier round would then be read as this round's review.
test_codex_exec_clears_stale_output() {
  local work_dir config
  work_dir=$(setup_work_dir)
  config=$(setup_config "$work_dir")

  echo "STALE review from round 1. VERDICT: APPROVED" > "$work_dir/codex-exec-reviewer-output.md"

  SKIP_SESSION_CHECK=1 \
  PATH="$SCRIPT_DIR:$PATH" \
  MOCK_CODEX_RESPONSE="" \
    bash "$INVOKE" "$config" "$work_dir" "codex-exec-reviewer" 2>/dev/null || true

  grep -q "STALE" "$work_dir/codex-exec-reviewer-output.md" && return 1
  [ "$(cat "$work_dir/codex-exec-reviewer-exit.txt")" = "1" ] || return 1

  rm -rf "$work_dir"
}

# The prompt must travel on stdin, not in argv. In changeset mode it carries a
# whole diff, and a large one exceeds ARG_MAX (1 MiB on macOS) with E2BIG.
test_codex_exec_prompt_travels_on_stdin() {
  local work_dir config log_file prompt_out
  work_dir=$(setup_work_dir)
  config=$(setup_config "$work_dir")
  log_file="$work_dir/codex-log.txt"
  prompt_out="$work_dir/seen-prompt.txt"

  echo "PLAN_CONTENT_MARKER" > "$work_dir/plan.md"

  SKIP_SESSION_CHECK=1 \
  PATH="$SCRIPT_DIR:$PATH" \
  MOCK_CODEX_LOG="$log_file" \
  MOCK_CODEX_PROMPT_OUT="$prompt_out" \
    bash "$INVOKE" "$config" "$work_dir" "codex-exec-reviewer" 2>/dev/null

  # argv ends with the stdin marker, and carries no prompt text.
  grep -q -- "codex exec .* -$" "$log_file" || return 1
  grep -q "PLAN_CONTENT_MARKER" "$log_file" && return 1
  # ...and the prompt actually arrived on stdin.
  grep -q "PLAN_CONTENT_MARKER" "$prompt_out" || return 1

  rm -rf "$work_dir"
}

# Regression for E2BIG: a prompt past ARG_MAX must still get through.
test_codex_exec_handles_oversized_prompt() {
  local work_dir config prompt_out limit
  work_dir=$(setup_work_dir)
  config=$(setup_config "$work_dir")
  prompt_out="$work_dir/seen-prompt.txt"

  limit=$(getconf ARG_MAX 2>/dev/null || echo 262144)
  # Comfortably past the limit; as an argv entry this would be E2BIG.
  awk -v n=$(( limit / 40 + 5000 )) 'BEGIN{for(i=0;i<n;i++) print "+ const padding_line_token = 1234567890;"}' \
    > "$work_dir/plan.md"
  echo "TAIL_MARKER_AFTER_BULK" >> "$work_dir/plan.md"

  SKIP_SESSION_CHECK=1 \
  PATH="$SCRIPT_DIR:$PATH" \
  MOCK_CODEX_PROMPT_OUT="$prompt_out" \
    bash "$INVOKE" "$config" "$work_dir" "codex-exec-reviewer" 2>/dev/null

  [ "$(cat "$work_dir/codex-exec-reviewer-exit.txt")" = "0" ] || return 1
  [ "$(wc -c < "$prompt_out")" -gt "$limit" ] || return 1
  grep -q "TAIL_MARKER_AFTER_BULK" "$prompt_out" || return 1

  rm -rf "$work_dir"
}

# An agent that ends its turn with no final message still gets a trailing newline
# from acpx, so the output file is 1 byte and `[ -s ]` calls it non-empty. Before
# this was caught, the round logged "Review received", wrote exit 0, and handed the
# synthesizer a blank review.
test_whitespace_only_response_is_empty() {
  local work_dir config
  work_dir=$(setup_work_dir)
  config=$(setup_config "$work_dir")

  SKIP_SESSION_CHECK=1 \
  PATH="$SCRIPT_DIR:$PATH" \
  MOCK_ACPX_RESPONSE="   " \
    bash "$INVOKE" "$config" "$work_dir" "test-reviewer" 2>/dev/null || true

  [ "$(cat "$work_dir/test-reviewer-exit.txt")" = "1" ] || return 1
  grep -q "Empty response" "$work_dir/test-reviewer-output.md" || return 1

  rm -rf "$work_dir"
}

# Same trap for a response that is only newlines.
test_newline_only_response_is_empty() {
  local work_dir config
  work_dir=$(setup_work_dir)
  config=$(setup_config "$work_dir")

  SKIP_SESSION_CHECK=1 \
  PATH="$SCRIPT_DIR:$PATH" \
  MOCK_ACPX_RESPONSE=$'\n\n' \
    bash "$INVOKE" "$config" "$work_dir" "test-reviewer" 2>/dev/null || true

  [ "$(cat "$work_dir/test-reviewer-exit.txt")" = "1" ] || return 1

  rm -rf "$work_dir"
}

# The blank check must not swallow a real one-line review.
test_short_real_response_still_passes() {
  local work_dir config
  work_dir=$(setup_work_dir)
  config=$(setup_config "$work_dir")

  SKIP_SESSION_CHECK=1 \
  PATH="$SCRIPT_DIR:$PATH" \
  MOCK_ACPX_RESPONSE="OK" \
    bash "$INVOKE" "$config" "$work_dir" "test-reviewer" 2>/dev/null

  [ "$(cat "$work_dir/test-reviewer-exit.txt")" = "0" ] || return 1
  grep -q "^OK$" "$work_dir/test-reviewer-output.md" || return 1

  rm -rf "$work_dir"
}

# The runner log must not say a review arrived and then say it was empty. An
# operator scanning stderr for "Review received" would count a seat that failed.
test_blank_output_does_not_log_review_received() {
  local work_dir config stderr_out
  work_dir=$(setup_work_dir)
  config=$(setup_config "$work_dir")
  stderr_out="$work_dir/invoke-stderr.txt"

  SKIP_SESSION_CHECK=1 \
  PATH="$SCRIPT_DIR:$PATH" \
  MOCK_ACPX_RESPONSE="" \
    bash "$INVOKE" "$config" "$work_dir" "no-retry-reviewer" 2>"$stderr_out" || true

  grep -q "Empty response" "$stderr_out" || return 1
  grep -q "Review received" "$stderr_out" && return 1

  rm -rf "$work_dir"
}

# A terminal reset or a zero-width space is not whitespace by POSIX, so a review
# containing only control bytes used to pass as delivered. Both verified to match
# `[^[:space:]]`, which is why the gate tests for alphanumerics instead.
test_control_bytes_only_response_is_empty() {
  local work_dir config
  work_dir=$(setup_work_dir)
  config=$(setup_config "$work_dir")

  SKIP_SESSION_CHECK=1 \
  PATH="$SCRIPT_DIR:$PATH" \
  MOCK_ACPX_RESPONSE="$(printf '\033[0m')" \
    bash "$INVOKE" "$config" "$work_dir" "no-retry-reviewer" 2>/dev/null || true

  [ "$(cat "$work_dir/no-retry-reviewer-exit.txt")" = "1" ] || return 1

  rm -rf "$work_dir"
}

# OSC payloads carry text, so a lone hyperlink escape is full of alphanumerics and
# survives the alnum test unless OSC is stripped specifically. CSI has no payload,
# which is why stripping it was not enough.
test_osc_only_response_is_empty() {
  local work_dir config
  work_dir=$(setup_work_dir)
  config=$(setup_config "$work_dir")

  SKIP_SESSION_CHECK=1 \
  PATH="$SCRIPT_DIR:$PATH" \
  MOCK_ACPX_RESPONSE="$(printf '\033]8;;https://example.invalid/x\007\033]8;;\007')" \
    bash "$INVOKE" "$config" "$work_dir" "no-retry-reviewer" 2>/dev/null || true

  [ "$(cat "$work_dir/no-retry-reviewer-exit.txt")" = "1" ] || return 1

  rm -rf "$work_dir"
}

# OSC openers (ESC] and 0x9D) and terminators (BEL, 0x9C, ESC-backslash) combine
# freely, including mixed 7-bit/8-bit. Pairing each opener with only its own
# terminator left two live bypasses, so every combination is checked here.
test_osc_all_encodings_count_as_empty() {
  local work_dir config combo n=0
  for combo in \
    '\033]8;;https://example.invalid/x\007' \
    '\033]8;;https://example.invalid/x\033\\' \
    '\033]8;;https://example.invalid/x\234' \
    '\2358;;https://example.invalid/x\234' \
    '\2358;;https://example.invalid/x\007' \
    '\2358;;https://example.invalid/x\033\\'
  do
    n=$((n + 1))
    work_dir=$(setup_work_dir)
    config=$(setup_config "$work_dir")

    SKIP_SESSION_CHECK=1 \
    PATH="$SCRIPT_DIR:$PATH" \
    MOCK_ACPX_RESPONSE="$(printf "$combo")" \
      bash "$INVOKE" "$config" "$work_dir" "no-retry-reviewer" 2>/dev/null || true

    if [ "$(cat "$work_dir/no-retry-reviewer-exit.txt")" != "1" ]; then
      echo "  OSC encoding $n was accepted as a delivered review"
      rm -rf "$work_dir"
      return 1
    fi
    rm -rf "$work_dir"
  done
}

# A review that merely mentions a URL must survive the OSC strip.
test_review_containing_a_url_still_passes() {
  local work_dir config
  work_dir=$(setup_work_dir)
  config=$(setup_config "$work_dir")

  SKIP_SESSION_CHECK=1 \
  PATH="$SCRIPT_DIR:$PATH" \
  MOCK_ACPX_RESPONSE="See https://example.invalid/x for context. VERDICT: REVISE" \
    bash "$INVOKE" "$config" "$work_dir" "no-retry-reviewer" 2>/dev/null

  [ "$(cat "$work_dir/no-retry-reviewer-exit.txt")" = "0" ] || return 1
  grep -q "VERDICT: REVISE" "$work_dir/no-retry-reviewer-output.md" || return 1

  rm -rf "$work_dir"
}

# A colon-form SGR colour is a control sequence whose parameter bytes include ':'.
# A CSI pattern of [0-9;?]* does not match it, and its digits then read as content.
test_colon_sgr_only_response_is_empty() {
  local work_dir config combo
  for combo in '\033[38:2::255:0:0m' '\23338:2::255:0:0m'; do
    work_dir=$(setup_work_dir)
    config=$(setup_config "$work_dir")

    SKIP_SESSION_CHECK=1 \
    PATH="$SCRIPT_DIR:$PATH" \
    MOCK_ACPX_RESPONSE="$(printf "$combo")" \
      bash "$INVOKE" "$config" "$work_dir" "no-retry-reviewer" 2>/dev/null || true

    if [ "$(cat "$work_dir/no-retry-reviewer-exit.txt")" != "1" ]; then
      echo "  colon-form SGR accepted as a delivered review"
      rm -rf "$work_dir"; return 1
    fi
    rm -rf "$work_dir"
  done
}

# A review needs no ASCII at all. Testing for [[:alnum:]] under LC_ALL=C threw away
# every review written in a non-Latin script and reported the seat as failed.
test_non_latin_review_is_not_empty() {
  local work_dir config script
  for script in '\345\220\214\346\204\217\343\200\202' '\320\236\321\210\320\270\320\261\320\272\320\260'; do
    work_dir=$(setup_work_dir)
    config=$(setup_config "$work_dir")

    SKIP_SESSION_CHECK=1 \
    PATH="$SCRIPT_DIR:$PATH" \
    MOCK_ACPX_RESPONSE="$(printf "$script")" \
      bash "$INVOKE" "$config" "$work_dir" "no-retry-reviewer" 2>/dev/null

    if [ "$(cat "$work_dir/no-retry-reviewer-exit.txt")" != "0" ]; then
      echo "  a non-Latin review was discarded as empty"
      rm -rf "$work_dir"; return 1
    fi
    rm -rf "$work_dir"
  done
}

# Punctuation-only output is likewise not a review.
test_punctuation_only_response_is_empty() {
  local work_dir config
  work_dir=$(setup_work_dir)
  config=$(setup_config "$work_dir")

  SKIP_SESSION_CHECK=1 \
  PATH="$SCRIPT_DIR:$PATH" \
  MOCK_ACPX_RESPONSE="---" \
    bash "$INVOKE" "$config" "$work_dir" "no-retry-reviewer" 2>/dev/null || true

  [ "$(cat "$work_dir/no-retry-reviewer-exit.txt")" = "1" ] || return 1

  rm -rf "$work_dir"
}

# codex-exec is a direct-CLI transport and used to bypass the retry loop entirely,
# so a blank Codex turn cost the seat despite `retries` being configured.
test_codex_exec_retries_a_blank_turn() {
  local work_dir config log_file counter
  work_dir=$(setup_work_dir)
  config=$(setup_config "$work_dir")
  log_file="$work_dir/codex-log.txt"
  counter="$work_dir/attempts.txt"

  SKIP_SESSION_CHECK=1 \
  PATH="$SCRIPT_DIR:$PATH" \
  MOCK_CODEX_LOG="$log_file" \
  MOCK_CODEX_COUNTER_FILE="$counter" \
  MOCK_CODEX_BLANK_ATTEMPTS=1 \
  MOCK_CODEX_RESPONSE="Second time. VERDICT: APPROVED" \
    bash "$INVOKE" "$config" "$work_dir" "codex-exec-reviewer" 2>/dev/null

  [ "$(cat "$work_dir/codex-exec-reviewer-exit.txt")" = "0" ] || return 1
  grep -q "VERDICT: APPROVED" "$work_dir/codex-exec-reviewer-output.md" || return 1
  [ "$(grep -c "codex exec" "$log_file")" = "2" ] || return 1

  rm -rf "$work_dir"
}

# --- blank-output retry ---
#
# kimi-k3 through opencode ends a large share of its turns with no final message,
# on prompts as small as "reply PONG". One blank turn should cost a retry, not the
# reviewer's seat on the panel.

test_blank_output_is_retried_then_succeeds() {
  local work_dir config log_file counter
  work_dir=$(setup_work_dir)
  config=$(setup_config "$work_dir")
  log_file="$work_dir/acpx-log.txt"
  counter="$work_dir/attempts.txt"

  SKIP_SESSION_CHECK=1 \
  PATH="$SCRIPT_DIR:$PATH" \
  MOCK_ACPX_LOG="$log_file" \
  MOCK_ACPX_COUNTER_FILE="$counter" \
  MOCK_ACPX_BLANK_ATTEMPTS=1 \
  MOCK_ACPX_RESPONSE="Second time lucky. VERDICT: APPROVED" \
    bash "$INVOKE" "$config" "$work_dir" "retry-reviewer" 2>/dev/null

  [ "$(cat "$work_dir/retry-reviewer-exit.txt")" = "0" ] || return 1
  grep -q "VERDICT: APPROVED" "$work_dir/retry-reviewer-output.md" || return 1
  # Exactly two prompt calls: the blank one and the retry.
  [ "$(grep -c -- "--file" "$log_file")" = "2" ] || return 1

  rm -rf "$work_dir"
}

test_retries_are_bounded() {
  local work_dir config log_file counter
  work_dir=$(setup_work_dir)
  config=$(setup_config "$work_dir")
  log_file="$work_dir/acpx-log.txt"
  counter="$work_dir/attempts.txt"

  # Blank forever. retries=2 means 3 prompt calls total, then give up.
  SKIP_SESSION_CHECK=1 \
  PATH="$SCRIPT_DIR:$PATH" \
  MOCK_ACPX_LOG="$log_file" \
  MOCK_ACPX_COUNTER_FILE="$counter" \
  MOCK_ACPX_BLANK_ATTEMPTS=99 \
    bash "$INVOKE" "$config" "$work_dir" "retry-reviewer" 2>/dev/null || true

  [ "$(cat "$work_dir/retry-reviewer-exit.txt")" = "1" ] || return 1
  grep -q "Empty response" "$work_dir/retry-reviewer-output.md" || return 1
  [ "$(grep -c -- "--file" "$log_file")" = "3" ] || return 1

  rm -rf "$work_dir"
}

test_no_retry_when_first_attempt_answers() {
  local work_dir config log_file
  work_dir=$(setup_work_dir)
  config=$(setup_config "$work_dir")
  log_file="$work_dir/acpx-log.txt"

  SKIP_SESSION_CHECK=1 \
  PATH="$SCRIPT_DIR:$PATH" \
  MOCK_ACPX_LOG="$log_file" \
  MOCK_ACPX_RESPONSE="Answered first time. VERDICT: APPROVED" \
    bash "$INVOKE" "$config" "$work_dir" "retry-reviewer" 2>/dev/null

  [ "$(cat "$work_dir/retry-reviewer-exit.txt")" = "0" ] || return 1
  [ "$(grep -c -- "--file" "$log_file")" = "1" ] || return 1

  rm -rf "$work_dir"
}

test_retries_zero_disables_retry() {
  local work_dir config log_file counter
  work_dir=$(setup_work_dir)
  config=$(setup_config "$work_dir")
  log_file="$work_dir/acpx-log.txt"
  counter="$work_dir/attempts.txt"

  SKIP_SESSION_CHECK=1 \
  PATH="$SCRIPT_DIR:$PATH" \
  MOCK_ACPX_LOG="$log_file" \
  MOCK_ACPX_COUNTER_FILE="$counter" \
  MOCK_ACPX_BLANK_ATTEMPTS=99 \
    bash "$INVOKE" "$config" "$work_dir" "no-retry-reviewer" 2>/dev/null || true

  [ "$(cat "$work_dir/no-retry-reviewer-exit.txt")" = "1" ] || return 1
  [ "$(grep -c -- "--file" "$log_file")" = "1" ] || return 1

  rm -rf "$work_dir"
}

# A crashed agent is not a quiet one. Retrying a real error burns the timeout
# budget on something that will fail the same way.
test_hard_failure_is_not_retried() {
  local work_dir config log_file
  work_dir=$(setup_work_dir)
  config=$(setup_config "$work_dir")
  log_file="$work_dir/acpx-log.txt"

  SKIP_SESSION_CHECK=1 \
  PATH="$SCRIPT_DIR:$PATH" \
  MOCK_ACPX_LOG="$log_file" \
  MOCK_ACPX_EXIT=1 \
  MOCK_ACPX_RESPONSE="" \
  MOCK_ACPX_STDERR="agent exploded" \
    bash "$INVOKE" "$config" "$work_dir" "retry-reviewer" 2>/dev/null || true

  [ "$(cat "$work_dir/retry-reviewer-exit.txt")" = "1" ] || return 1
  [ "$(grep -c -- "--file" "$log_file")" = "1" ] || return 1

  rm -rf "$work_dir"
}

# Default when a reviewer sets no `retries` at all: one retry, so a single blank
# turn does not cost the seat.
test_default_allows_one_retry() {
  local work_dir config log_file counter
  work_dir=$(setup_work_dir)
  config=$(setup_config "$work_dir")
  log_file="$work_dir/acpx-log.txt"
  counter="$work_dir/attempts.txt"

  SKIP_SESSION_CHECK=1 \
  PATH="$SCRIPT_DIR:$PATH" \
  MOCK_ACPX_LOG="$log_file" \
  MOCK_ACPX_COUNTER_FILE="$counter" \
  MOCK_ACPX_BLANK_ATTEMPTS=99 \
    bash "$INVOKE" "$config" "$work_dir" "test-reviewer" 2>/dev/null || true

  [ "$(cat "$work_dir/test-reviewer-exit.txt")" = "1" ] || return 1
  [ "$(grep -c -- "--file" "$log_file")" = "2" ] || return 1

  rm -rf "$work_dir"
}

# --- one-shot (mode: exec) ---
#
# Some ACP agents go mute on the second prompt into a persistent session: the turn
# ends immediately with no content, exit 0, empty output file. Reproduced against
# opencode-backed agents (kimi-k3), where run 1 answers and every later run in the
# same session returns nothing. `mode: "exec"` opts a reviewer out of the session.

test_exec_mode_uses_exec_subcommand() {
  local work_dir config log_file
  work_dir=$(setup_work_dir)
  config=$(setup_config "$work_dir")
  log_file="$work_dir/acpx-log.txt"

  SKIP_SESSION_CHECK=1 \
  PATH="$SCRIPT_DIR:$PATH" \
  MOCK_ACPX_LOG="$log_file" \
  MOCK_ACPX_RESPONSE="One-shot. VERDICT: APPROVED" \
    bash "$INVOKE" "$config" "$work_dir" "oneshot-reviewer" 2>/dev/null

  [ "$(cat "$work_dir/oneshot-reviewer-exit.txt")" = "0" ] || return 1
  grep -q "VERDICT: APPROVED" "$work_dir/oneshot-reviewer-output.md" || return 1

  # `exec` must sit immediately after the agent name, before --file.
  grep -q "kimi-k3 exec --file" "$log_file" || return 1

  rm -rf "$work_dir"
}

test_exec_mode_skips_session_ensure() {
  # A one-shot needs no session, so a failing `sessions ensure` must not sink it.
  # Deliberately does NOT set SKIP_SESSION_CHECK.
  local work_dir config log_file
  work_dir=$(setup_work_dir)
  config=$(setup_config "$work_dir")
  log_file="$work_dir/acpx-log.txt"

  PATH="$SCRIPT_DIR:$PATH" \
  MOCK_ACPX_SESSION_ENSURE_EXIT=1 \
  MOCK_ACPX_LOG="$log_file" \
  MOCK_ACPX_RESPONSE="One-shot. VERDICT: APPROVED" \
    bash "$INVOKE" "$config" "$work_dir" "oneshot-reviewer" 2>/dev/null

  [ "$(cat "$work_dir/oneshot-reviewer-exit.txt")" = "0" ] || return 1
  ! grep -q "sessions ensure" "$log_file" 2>/dev/null || return 1

  rm -rf "$work_dir"
}

# Two successive runs must both produce a review. Under the session path the
# second one comes back empty for opencode-backed agents; the mock cannot
# reproduce that, so this asserts the invariant that matters: neither run
# touches a shared session.
test_exec_mode_repeatable_across_runs() {
  local work_dir config log_file
  work_dir=$(setup_work_dir)
  config=$(setup_config "$work_dir")
  log_file="$work_dir/acpx-log.txt"

  for _ in 1 2; do
    PATH="$SCRIPT_DIR:$PATH" \
    MOCK_ACPX_SESSION_ENSURE_EXIT=1 \
    MOCK_ACPX_LOG="$log_file" \
    MOCK_ACPX_RESPONSE="Round output. VERDICT: REVISE" \
      bash "$INVOKE" "$config" "$work_dir" "oneshot-reviewer" 2>/dev/null

    [ "$(cat "$work_dir/oneshot-reviewer-exit.txt")" = "0" ] || return 1
    [ -s "$work_dir/oneshot-reviewer-output.md" ] || return 1
  done

  [ "$(grep -c "kimi-k3 exec --file" "$log_file")" = "2" ] || return 1

  rm -rf "$work_dir"
}

# Default is unchanged: no `mode` key means the persistent session, as before.
test_session_mode_is_the_default() {
  local work_dir config log_file
  work_dir=$(setup_work_dir)
  config=$(setup_config "$work_dir")
  log_file="$work_dir/acpx-log.txt"

  PATH="$SCRIPT_DIR:$PATH" \
  MOCK_ACPX_LOG="$log_file" \
    bash "$INVOKE" "$config" "$work_dir" "test-reviewer" 2>/dev/null

  [ "$(cat "$work_dir/test-reviewer-exit.txt")" = "0" ] || return 1
  grep -q "sessions ensure" "$log_file" || return 1
  grep -q "codex exec --file" "$log_file" && return 1

  rm -rf "$work_dir"
}

# A typo'd mode must be loud, not silently treated as one-shot or as a session.
test_unknown_mode_warns_and_uses_session() {
  local work_dir config stderr_out
  work_dir=$(setup_work_dir)
  config=$(setup_config "$work_dir")
  stderr_out="$work_dir/invoke-stderr.txt"

  SKIP_SESSION_CHECK=1 \
  PATH="$SCRIPT_DIR:$PATH" \
    bash "$INVOKE" "$config" "$work_dir" "bad-mode-reviewer" 2>"$stderr_out"

  [ "$(cat "$work_dir/bad-mode-reviewer-exit.txt")" = "0" ] || return 1
  grep -q "unknown mode 'sesion'" "$stderr_out" || return 1

  rm -rf "$work_dir"
}

# --- repo-aware seat containment ---
#
# The repo-aware reviewer reads files, and its prompt carries a changeset that may
# not be yours. `codex exec -s read-only` blocks writes, not reads outside the repo:
# a canary in $HOME came back verbatim under it, and sandbox_permissions=[] did not
# change that. Neither of the two mitigations below is a sandbox, and the residual
# risk (absolute paths) stays open — but both are cheap and both are load-bearing,
# so a regression in either should fail here rather than in someone's credentials.

test_codex_exec_runs_with_redirected_home() {
  local work_dir config env_out
  work_dir=$(setup_work_dir)
  config=$(setup_config "$work_dir")
  env_out="$work_dir/seen-env.txt"

  SKIP_SESSION_CHECK=1 \
  PATH="$SCRIPT_DIR:$PATH" \
  MOCK_CODEX_ENV_OUT="$env_out" \
    bash "$INVOKE" "$config" "$work_dir" "codex-exec-reviewer" 2>/dev/null

  # HOME must point inside the work dir, not at the real one.
  grep -q "^HOME=${work_dir}/" "$env_out" || return 1
  # ...and codex must still find its own config, or auth breaks.
  grep -q "^CODEX_HOME=." "$env_out" || return 1

  rm -rf "$work_dir"
}

test_codex_exec_scrubs_secret_env_vars() {
  local work_dir config env_out
  work_dir=$(setup_work_dir)
  config=$(setup_config "$work_dir")
  env_out="$work_dir/seen-env.txt"

  SKIP_SESSION_CHECK=1 \
  PATH="$SCRIPT_DIR:$PATH" \
  MOCK_CODEX_ENV_OUT="$env_out" \
  DEBATE_TEST_API_KEY="should-not-survive" \
  DEBATE_TEST_BENIGN="should-survive" \
  OPENAI_API_KEY="sk-should-not-survive" \
    bash "$INVOKE" "$config" "$work_dir" "codex-exec-reviewer" 2>/dev/null

  grep -q "^SECRET_PRESENT=$" "$env_out" || { echo "  secret-shaped var reached codex"; return 1; }
  # The provider key specifically: an earlier version exempted OPENAI_* ahead of the
  # secret patterns, so the most valuable secret on the box was the one kept.
  grep -q "^PROVIDER_KEY_PRESENT=$" "$env_out" || { echo "  OPENAI_API_KEY reached codex"; return 1; }
  # The scrub must be targeted, not a blanket wipe — codex needs a working env.
  grep -q "^BENIGN_PRESENT=yes$" "$env_out" || { echo "  benign var was wrongly stripped"; return 1; }

  rm -rf "$work_dir"
}

# --- changeset fallback ---

test_changeset_reviewed_when_no_plan() {
  local work_dir config
  work_dir=$(setup_work_dir)
  config=$(setup_config "$work_dir")

  : > "$work_dir/plan.md"
  printf -- '--- a/x.js\n+++ b/x.js\n+const distinctiveDiffToken = 1;\n' > "$work_dir/changeset.diff"

  SKIP_SESSION_CHECK=1 \
  PATH="$SCRIPT_DIR:$PATH" \
    bash "$INVOKE" "$config" "$work_dir" "test-reviewer" 2>/dev/null

  local prompt="$work_dir/test-reviewer-acpx-prompt.txt"
  grep -q "distinctiveDiffToken" "$prompt" || return 1
  grep -q "Review this changeset" "$prompt" || return 1
  grep -q "ready to merge" "$prompt" || return 1

  rm -rf "$work_dir"
}

test_plan_wins_over_changeset() {
  local work_dir config
  work_dir=$(setup_work_dir)
  config=$(setup_config "$work_dir")

  printf -- '--- a/x.js\n+++ b/x.js\n+const shouldNotAppear = 1;\n' > "$work_dir/changeset.diff"

  SKIP_SESSION_CHECK=1 \
  PATH="$SCRIPT_DIR:$PATH" \
    bash "$INVOKE" "$config" "$work_dir" "test-reviewer" 2>/dev/null

  local prompt="$work_dir/test-reviewer-acpx-prompt.txt"
  grep -q "Test plan content" "$prompt" || return 1
  grep -q "shouldNotAppear" "$prompt" && return 1
  grep -q "ready to implement" "$prompt" || return 1

  rm -rf "$work_dir"
}

# --- Run ---

echo ""
echo "=== invoke-acpx.sh tests ==="
echo ""

# Create mock binaries on PATH for acpx, agy, and claude (direct CLI paths)
ln -sf "$MOCK" "$SCRIPT_DIR/acpx"
chmod +x "$SCRIPT_DIR/acpx"
ln -sf "$MOCK_AGY" "$SCRIPT_DIR/agy"
chmod +x "$SCRIPT_DIR/agy"
ln -sf "$MOCK_CLAUDE" "$SCRIPT_DIR/claude"
chmod +x "$SCRIPT_DIR/claude"
ln -sf "$MOCK_CODEX" "$SCRIPT_DIR/codex"
chmod +x "$SCRIPT_DIR/codex"
trap 'rm -f "$SCRIPT_DIR/acpx" "$SCRIPT_DIR/agy" "$SCRIPT_DIR/claude" "$SCRIPT_DIR/codex"' EXIT

run_test "codex effort invalid refused before spawn" test_codex_effort_invalid_is_refused_before_spawn
run_test "codex effort valid values accepted" test_codex_effort_valid_values_accepted
run_test "codex exec happy path" test_codex_exec_happy_path
run_test "codex exec closes stdin" test_codex_exec_closes_stdin
run_test "codex exec read-only + output flags" test_codex_exec_is_read_only_and_uses_output_flag
run_test "codex exec transcript kept out of output" test_codex_exec_transcript_kept_out_of_output
run_test "codex exec empty output is a failure" test_codex_exec_empty_output_is_a_failure
run_test "codex exec skips the acpx session check" test_codex_exec_skips_session_check
run_test "codex exec clears stale output" test_codex_exec_clears_stale_output
run_test "codex exec prompt travels on stdin" test_codex_exec_prompt_travels_on_stdin
run_test "codex exec handles an oversized prompt" test_codex_exec_handles_oversized_prompt
run_test "blank output does not log Review received" test_blank_output_does_not_log_review_received
run_test "blank output is retried then succeeds" test_blank_output_is_retried_then_succeeds
run_test "retries are bounded" test_retries_are_bounded
run_test "no retry when first attempt answers" test_no_retry_when_first_attempt_answers
run_test "retries 0 disables retry" test_retries_zero_disables_retry
run_test "hard failure is not retried" test_hard_failure_is_not_retried
run_test "default allows one retry" test_default_allows_one_retry
run_test "control-bytes-only response counts as empty" test_control_bytes_only_response_is_empty
run_test "OSC-only response counts as empty" test_osc_only_response_is_empty
run_test "OSC in every encoding counts as empty" test_osc_all_encodings_count_as_empty
run_test "review containing a URL still passes" test_review_containing_a_url_still_passes
run_test "colon-form SGR counts as empty" test_colon_sgr_only_response_is_empty
run_test "non-Latin review is not empty" test_non_latin_review_is_not_empty
run_test "punctuation-only response counts as empty" test_punctuation_only_response_is_empty
run_test "codex exec retries a blank turn" test_codex_exec_retries_a_blank_turn
run_test "whitespace-only response counts as empty" test_whitespace_only_response_is_empty
run_test "newline-only response counts as empty" test_newline_only_response_is_empty
run_test "short real response still passes" test_short_real_response_still_passes
run_test "exec mode uses the exec subcommand" test_exec_mode_uses_exec_subcommand
run_test "exec mode skips session ensure" test_exec_mode_skips_session_ensure
run_test "exec mode repeatable across runs" test_exec_mode_repeatable_across_runs
run_test "session mode is the default" test_session_mode_is_the_default
run_test "unknown mode warns and uses session" test_unknown_mode_warns_and_uses_session
run_test "codex exec runs with redirected HOME" test_codex_exec_runs_with_redirected_home
run_test "codex exec scrubs secret env vars" test_codex_exec_scrubs_secret_env_vars
run_test "changeset reviewed when no plan" test_changeset_reviewed_when_no_plan
run_test "plan wins over changeset" test_plan_wins_over_changeset
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
run_test "antigravity uses direct CLI" test_antigravity_uses_direct_cli
run_test "antigravity skips session ensure" test_antigravity_skips_session_ensure
run_test "opus uses direct CLI" test_opus_uses_direct_cli
run_test "opus skips session ensure" test_opus_skips_session_ensure

echo ""
echo "=== Results: $PASS passed, $FAIL failed ($(( PASS + FAIL )) total) ==="

[ "$FAIL" -eq 0 ]

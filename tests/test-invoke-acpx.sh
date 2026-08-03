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
    },
    "model-reviewer": {
      "agent": "codex",
      "timeout": 30,
      "model": "cfg-default-model",
      "system_prompt": "You test model selection."
    },
    "codex-exec-reviewer": {
      "agent": "codex-exec",
      "timeout": 30,
      "system_prompt": "Should never run."
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

test_session_failure_surfaces_acpx_stderr() {
  # The cause of a session failure lives in acpx's stderr (unknown agent name,
  # adapter crash, missing auth). It must reach output.md and the stderr log,
  # otherwise every startup failure looks identical to the user.
  local work_dir config console stderr_text
  work_dir=$(setup_work_dir)
  config=$(setup_config "$work_dir")
  console="$work_dir/console.log"

  # Six lines: the console preview is capped at five, the artifacts keep all six.
  stderr_text=$(printf 'Failed to spawn agent command: codex-exec\nline-2\nline-3\nline-4\nline-5\nline-6-beyond-preview')

  set +e
  PATH="$SCRIPT_DIR:$PATH" \
  MOCK_ACPX_SESSION_ENSURE_EXIT=1 \
  MOCK_ACPX_SESSION_STDERR="$stderr_text" \
    bash "$INVOKE" "$config" "$work_dir" "test-reviewer" 2>"$console"
  local exit_code=$?
  set -e

  [ "$exit_code" -eq 4 ] || return 1

  # The console preview must name the cause, not just report a generic failure.
  grep -q "stderr: Failed to spawn agent command: codex-exec" "$console" || return 1

  # It carries five lines, and stops there.
  grep -q "line-5" "$console" || return 1
  ! grep -q "line-6-beyond-preview" "$console" || return 1

  # The review output and stderr log keep the full text, past the preview cap.
  grep -q "Failed to spawn agent command: codex-exec" \
    "$work_dir/test-reviewer-output.md" || return 1
  grep -q "line-6-beyond-preview" "$work_dir/test-reviewer-output.md" || return 1
  grep -q "line-6-beyond-preview" \
    "$work_dir/test-reviewer-stderr.log" || return 1

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

# --- permission-denied (acpx exit 5) ---

# acpx stamps exit 5 after the turn ends, when the seat got none of the permissions
# it asked for. A review that arrived is still a review, so it must survive.
test_denied_permission_keeps_the_review() {
  local work_dir config
  work_dir=$(setup_work_dir)
  config=$(setup_config "$work_dir")

  SKIP_SESSION_CHECK=1 \
  PATH="$SCRIPT_DIR:$PATH" \
  MOCK_ACPX_EXIT=5 \
  MOCK_ACPX_RESPONSE="Denied a command but reviewed anyway. VERDICT: APPROVED" \
    bash "$INVOKE" "$config" "$work_dir" "test-reviewer" 2>/dev/null

  [ "$(cat "$work_dir/test-reviewer-exit.txt")" = "0" ] || { rm -rf "$work_dir"; return 1; }
  grep -q "VERDICT: APPROVED" "$work_dir/test-reviewer-output.md" || { rm -rf "$work_dir"; return 1; }

  rm -rf "$work_dir"
}

# Exit 5 with nothing to show is a blank turn, and blank turns are retried. Before
# this, run_with_blank_retry broke on the non-zero exit and the seat was lost.
test_denied_permission_blank_is_retried() {
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
  MOCK_ACPX_EXIT=5 \
  MOCK_ACPX_RESPONSE="Second time lucky. VERDICT: APPROVED" \
    bash "$INVOKE" "$config" "$work_dir" "retry-reviewer" 2>/dev/null

  [ "$(cat "$work_dir/retry-reviewer-exit.txt")" = "0" ] || { rm -rf "$work_dir"; return 1; }
  grep -q "VERDICT: APPROVED" "$work_dir/retry-reviewer-output.md" || { rm -rf "$work_dir"; return 1; }
  [ "$(grep -c -- "--file" "$log_file")" = "2" ] || { rm -rf "$work_dir"; return 1; }

  rm -rf "$work_dir"
}

# Denied and blank all the way down still ends as a reported failure, not a silent
# success. Normalising exit 5 must not paper over a seat that never delivered.
test_denied_permission_blank_forever_still_fails() {
  local work_dir config
  work_dir=$(setup_work_dir)
  config=$(setup_config "$work_dir")

  SKIP_SESSION_CHECK=1 \
  PATH="$SCRIPT_DIR:$PATH" \
  MOCK_ACPX_EXIT=5 \
  MOCK_ACPX_RESPONSE="" \
    bash "$INVOKE" "$config" "$work_dir" "test-reviewer" 2>/dev/null || true

  [ "$(cat "$work_dir/test-reviewer-exit.txt")" = "1" ] || { rm -rf "$work_dir"; return 1; }
  grep -q "Empty response" "$work_dir/test-reviewer-output.md" || { rm -rf "$work_dir"; return 1; }

  rm -rf "$work_dir"
}

# --- per-seat model selection (F1) ---
#
# The panel selector picks a model per seat; the parallel runner forwards it as
# MODEL=<id> in this seat's env. Without this, invoke-acpx.sh had no way to
# express it and every acpx seat ran its agent's default model — the selector's
# "dynamic reviewer selection" was inert end-to-end.

test_model_env_reaches_acpx() {
  local work_dir config log_file
  work_dir=$(setup_work_dir)
  config=$(setup_config "$work_dir")
  log_file="$work_dir/acpx-log.txt"

  SKIP_SESSION_CHECK=1 \
  PATH="$SCRIPT_DIR:$PATH" \
  MODEL="gpt-5.6-luna" \
  MOCK_ACPX_LOG="$log_file" \
  MOCK_ACPX_RESPONSE="Reviewed. VERDICT: APPROVED" \
    bash "$INVOKE" "$config" "$work_dir" "test-reviewer" 2>/dev/null

  [ "$(cat "$work_dir/test-reviewer-exit.txt")" = "0" ] || { rm -rf "$work_dir"; return 1; }
  grep -q -- "--model gpt-5.6-luna" "$log_file" || { rm -rf "$work_dir"; return 1; }

  rm -rf "$work_dir"
}

test_model_env_overrides_config_model() {
  local work_dir config log_file
  work_dir=$(setup_work_dir)
  config=$(setup_config "$work_dir")
  log_file="$work_dir/acpx-log.txt"

  SKIP_SESSION_CHECK=1 \
  PATH="$SCRIPT_DIR:$PATH" \
  MODEL="gpt-5.6-luna" \
  MOCK_ACPX_LOG="$log_file" \
    bash "$INVOKE" "$config" "$work_dir" "model-reviewer" 2>/dev/null

  # The per-run MODEL wins over the config's `.model`, which must not appear.
  grep -q -- "--model gpt-5.6-luna" "$log_file" || { rm -rf "$work_dir"; return 1; }
  grep -q -- "--model cfg-default-model" "$log_file" && { rm -rf "$work_dir"; return 1; }

  rm -rf "$work_dir"
}

test_model_env_used_for_opus() {
  local work_dir config log_file
  work_dir=$(setup_work_dir)
  config=$(setup_config "$work_dir")
  log_file="$work_dir/claude-log.txt"

  SKIP_SESSION_CHECK=1 \
  PATH="$SCRIPT_DIR:$PATH" \
  MODEL="claude-opus-5" \
  MOCK_CLAUDE_LOG="$log_file" \
    bash "$INVOKE" "$config" "$work_dir" "opus-reviewer" 2>/dev/null

  grep -q -- "--model claude-opus-5" "$log_file" || { rm -rf "$work_dir"; return 1; }

  rm -rf "$work_dir"
}

test_model_env_used_for_antigravity() {
  local work_dir config log_file
  work_dir=$(setup_work_dir)
  config=$(setup_config "$work_dir")
  log_file="$work_dir/agy-log.txt"

  SKIP_SESSION_CHECK=1 \
  PATH="$SCRIPT_DIR:$PATH" \
  MODEL="gemini-3.1-pro" \
  MOCK_AGY_LOG="$log_file" \
    bash "$INVOKE" "$config" "$work_dir" "no-prompt" 2>/dev/null

  grep -q -- "--model gemini-3.1-pro" "$log_file" || { rm -rf "$work_dir"; return 1; }

  rm -rf "$work_dir"
}

# --- guard-message preservation (F15) ---
#
# The EXIT trap used to overwrite an empty -output.md with the generic
# "process terminated unexpectedly" line on every early guard exit, hiding the
# guard's own diagnostic (e.g. the codex-exec migration instructions) from
# anyone reading the output file. Guards now write their own message first.

test_codex_exec_guard_message_preserved() {
  local work_dir config exit_code
  work_dir=$(setup_work_dir)
  config=$(setup_config "$work_dir")

  set +e
  SKIP_SESSION_CHECK=1 \
  PATH="$SCRIPT_DIR:$PATH" \
    bash "$INVOKE" "$config" "$work_dir" "codex-exec-reviewer" 2>/dev/null
  exit_code=$?
  set -e

  [ "$exit_code" -ne 0 ] || { rm -rf "$work_dir"; return 1; }
  # The guard's own migration message, not the generic trap line.
  grep -q "codex-exec" "$work_dir/codex-exec-reviewer-output.md" || { rm -rf "$work_dir"; return 1; }
  grep -q "Migrate" "$work_dir/codex-exec-reviewer-output.md" || { rm -rf "$work_dir"; return 1; }
  grep -q "process terminated unexpectedly" "$work_dir/codex-exec-reviewer-output.md" && { rm -rf "$work_dir"; return 1; }

  rm -rf "$work_dir"
}

test_missing_config_guard_message_preserved() {
  local work_dir exit_code
  work_dir=$(setup_work_dir)

  set +e
  bash "$INVOKE" "/nonexistent/config.json" "$work_dir" "test-reviewer" 2>/dev/null
  exit_code=$?
  set -e

  [ "$exit_code" -ne 0 ] || { rm -rf "$work_dir"; return 1; }
  grep -q "config not found" "$work_dir/test-reviewer-output.md" || { rm -rf "$work_dir"; return 1; }
  grep -q "process terminated unexpectedly" "$work_dir/test-reviewer-output.md" && { rm -rf "$work_dir"; return 1; }

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
run_test "whitespace-only response counts as empty" test_whitespace_only_response_is_empty
run_test "newline-only response counts as empty" test_newline_only_response_is_empty
run_test "short real response still passes" test_short_real_response_still_passes
run_test "exec mode uses the exec subcommand" test_exec_mode_uses_exec_subcommand
run_test "exec mode skips session ensure" test_exec_mode_skips_session_ensure
run_test "exec mode repeatable across runs" test_exec_mode_repeatable_across_runs
run_test "session mode is the default" test_session_mode_is_the_default
run_test "unknown mode warns and uses session" test_unknown_mode_warns_and_uses_session
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
run_test "session failure surfaces acpx stderr" test_session_failure_surfaces_acpx_stderr
run_test "session exists no extra calls" test_session_exists_no_extra_calls
run_test "skip session check env" test_skip_session_check_env
run_test "stderr surfaced on failure" test_stderr_surfaced_on_failure
run_test "antigravity uses direct CLI" test_antigravity_uses_direct_cli
run_test "antigravity skips session ensure" test_antigravity_skips_session_ensure
run_test "opus uses direct CLI" test_opus_uses_direct_cli
run_test "opus skips session ensure" test_opus_skips_session_ensure
run_test "denied permission keeps the review" test_denied_permission_keeps_the_review
run_test "denied permission blank is retried" test_denied_permission_blank_is_retried
run_test "denied and blank forever still fails" test_denied_permission_blank_forever_still_fails
run_test "MODEL env reaches acpx --model" test_model_env_reaches_acpx
run_test "MODEL env overrides config model" test_model_env_overrides_config_model
run_test "MODEL env used for opus direct CLI" test_model_env_used_for_opus
run_test "MODEL env used for antigravity direct CLI" test_model_env_used_for_antigravity
run_test "codex-exec guard message preserved in output" test_codex_exec_guard_message_preserved
run_test "missing-config guard message preserved in output" test_missing_config_guard_message_preserved

# --- orphan reaping (PR #21) ---

# The mock exits 0, so this is the SUCCESS path — where `timeout` never fires
# and therefore never signals the group. That is precisely the case that
# leaked: acpx returns, its spawned adapter keeps running and reparents to
# init. MOCK_ACPX_ORPHAN makes the mock leave exactly such a child behind.
test_orphaned_adapter_reaped() {
  local work_dir config orphan_file orphan_pid i
  # The reap only works when the acpx call has its own process group, which
  # `timeout`/`gtimeout` provides. Without one (e.g. macOS CI without
  # coreutils) the mock shares this script's group and reap_process_group
  # correctly declines — that is the designed fallback, so skip rather than
  # fail. Verified on ubuntu (coreutils present) and local hosts.
  if ! command -v timeout >/dev/null 2>&1 && ! command -v gtimeout >/dev/null 2>&1; then
    return 0
  fi
  work_dir=$(setup_work_dir)
  config=$(setup_config "$work_dir")
  orphan_file="$work_dir/orphan.pid"

  SKIP_SESSION_CHECK=1 \
  PATH="$SCRIPT_DIR:$PATH" \
  MOCK_ACPX_ORPHAN="$orphan_file" \
    bash "$INVOKE" "$config" "$work_dir" "test-reviewer" 2> /dev/null

  [ -f "$orphan_file" ] || { rm -rf "$work_dir"; return 1; }
  orphan_pid=$(cat "$orphan_file")
  # Give the sweep a moment, then confirm the orphan is gone.
  for i in 1 2 3 4 5; do
    kill -0 "$orphan_pid" 2>/dev/null || break
    sleep 0.2
  done
  if kill -0 "$orphan_pid" 2>/dev/null; then
    echo "  orphan pid $orphan_pid still alive after reap"
    rm -rf "$work_dir"; return 1
  fi
  rm -rf "$work_dir"
}
run_test "orphaned adapter is reaped after a success" test_orphaned_adapter_reaped

echo ""
echo "=== Results: $PASS passed, $FAIL failed ($(( PASS + FAIL )) total) ==="

[ "$FAIL" -eq 0 ]

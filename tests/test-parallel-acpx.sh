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
MOCK_CODEX="$SCRIPT_DIR/mock-codex.sh"

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

# A throwaway git repo with one commit on `main`, so the runner's default base
# resolution (merge-base with the default branch) has something to find.
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

# No plan AND no changes is the only "nothing to review" case left. Run it in a
# clean throwaway repo: inside a repo with uncommitted work, changeset mode is
# supposed to take over, and asserting failure here from the plugin's own dirty
# tree would pass for the wrong reason.
test_missing_plan_fails() {
  local tmp_dir review_id repo exit_code
  tmp_dir=$(setup_env)
  review_id="test-$(date +%s)-noplan"
  repo=$(setup_git_repo)

  set +e
  ( cd "$repo" && PATH="$SCRIPT_DIR:$PATH" SKIP_SESSION_CHECK=1 \
      bash "$PARALLEL" "$tmp_dir/config.json" "$review_id" 2>/dev/null )
  exit_code=$?
  set -e

  [ "$exit_code" -ne 0 ] || { rm -rf "$repo" "$tmp_dir"; return 1; }

  rm -rf "$repo" "$tmp_dir"
}

# --- changeset mode ---

test_changeset_generated_when_no_plan() {
  local tmp_dir review_id repo work_dir
  tmp_dir=$(setup_env)
  review_id="test-$(date +%s)-diff"
  repo=$(setup_git_repo)
  work_dir="$repo/.tmp/ai-review-${review_id}"

  echo "const distinctiveDiffToken = 1;" >> "$repo/f.txt"

  ( cd "$repo" && PATH="$SCRIPT_DIR:$PATH" SKIP_SESSION_CHECK=1 \
      MOCK_ACPX_RESPONSE="Reviewed. VERDICT: APPROVED" \
      bash "$PARALLEL" "$tmp_dir/config.json" "$review_id" 2>/dev/null )

  [ -s "$work_dir/changeset.diff" ] || { rm -rf "$repo" "$tmp_dir"; return 1; }
  grep -q "distinctiveDiffToken" "$work_dir/changeset.diff" || { rm -rf "$repo" "$tmp_dir"; return 1; }
  # The run must actually proceed, not just leave a diff behind.
  [ -f "$work_dir/alpha-output.md" ] || { rm -rf "$repo" "$tmp_dir"; return 1; }

  rm -rf "$repo" "$tmp_dir"
}

# The runner deletes prompt files on cleanup, so the prompt's CONTENT is asserted
# at the invoke-acpx level (see test_changeset_reviewed_when_no_plan). Here we
# only prove a prompt was built and handed over.
test_changeset_reaches_the_reviewer() {
  local tmp_dir review_id repo work_dir log_file
  tmp_dir=$(setup_env)
  review_id="test-$(date +%s)-diffprompt"
  repo=$(setup_git_repo)
  work_dir="$repo/.tmp/ai-review-${review_id}"
  log_file="$tmp_dir/acpx-log.txt"

  echo "const tokenInPrompt = 2;" >> "$repo/f.txt"

  ( cd "$repo" && PATH="$SCRIPT_DIR:$PATH" SKIP_SESSION_CHECK=1 \
      MOCK_ACPX_LOG="$log_file" \
      bash "$PARALLEL" "$tmp_dir/config.json" "$review_id" 2>/dev/null )

  grep -q -- "--file .*alpha-acpx-prompt.txt" "$log_file" || { rm -rf "$repo" "$tmp_dir"; return 1; }
  grep -q "tokenInPrompt" "$work_dir/changeset.diff" || { rm -rf "$repo" "$tmp_dir"; return 1; }

  rm -rf "$repo" "$tmp_dir"
}

test_diff_base_override_respected() {
  local tmp_dir review_id repo work_dir base_sha
  tmp_dir=$(setup_env)
  review_id="test-$(date +%s)-base"
  repo=$(setup_git_repo)
  work_dir="$repo/.tmp/ai-review-${review_id}"

  base_sha=$(git -C "$repo" rev-parse HEAD)
  echo "const committedToken = 3;" >> "$repo/f.txt"
  git -C "$repo" add f.txt >/dev/null 2>&1
  git -C "$repo" commit -qm "committed change" >/dev/null 2>&1

  # Against HEAD the tree is clean; only an explicit base surfaces the commit.
  ( cd "$repo" && PATH="$SCRIPT_DIR:$PATH" SKIP_SESSION_CHECK=1 \
      DEBATE_DIFF_BASE="$base_sha" \
      bash "$PARALLEL" "$tmp_dir/config.json" "$review_id" 2>/dev/null )

  grep -q "committedToken" "$work_dir/changeset.diff" || { rm -rf "$repo" "$tmp_dir"; return 1; }

  rm -rf "$repo" "$tmp_dir"
}

# A new file is exactly what a reviewer must see, and `git diff` alone misses it.
test_untracked_files_included_in_changeset() {
  local tmp_dir review_id repo work_dir
  tmp_dir=$(setup_env)
  review_id="test-$(date +%s)-untracked"
  repo=$(setup_git_repo)
  work_dir="$repo/.tmp/ai-review-${review_id}"

  echo "const brandNewFileToken = 5;" > "$repo/newfile.js"

  ( cd "$repo" && PATH="$SCRIPT_DIR:$PATH" SKIP_SESSION_CHECK=1 \
      bash "$PARALLEL" "$tmp_dir/config.json" "$review_id" 2>/dev/null )

  grep -q "brandNewFileToken" "$work_dir/changeset.diff" || { rm -rf "$repo" "$tmp_dir"; return 1; }

  rm -rf "$repo" "$tmp_dir"
}

# The work dir sits inside the repo, so its own files are untracked. Without a
# filter the review reads its own scaffolding and a clean tree looks dirty.
test_work_dir_excluded_from_changeset() {
  local tmp_dir review_id repo work_dir
  tmp_dir=$(setup_env)
  review_id="test-$(date +%s)-selfscan"
  repo=$(setup_git_repo)
  work_dir="$repo/.tmp/ai-review-${review_id}"

  echo "const realChange = 6;" >> "$repo/f.txt"

  ( cd "$repo" && PATH="$SCRIPT_DIR:$PATH" SKIP_SESSION_CHECK=1 \
      bash "$PARALLEL" "$tmp_dir/config.json" "$review_id" 2>/dev/null )

  grep -q "realChange" "$work_dir/changeset.diff" || { rm -rf "$repo" "$tmp_dir"; return 1; }
  grep -q "ai-review-" "$work_dir/changeset.diff" && { rm -rf "$repo" "$tmp_dir"; return 1; }

  rm -rf "$repo" "$tmp_dir"
}

# In changeset mode the round SHA must cover the diff. plan.md is an empty
# placeholder, and hashing it would make the mid-round gate pass no matter how
# far the working tree moved under the review.
test_round_sha_covers_the_changeset() {
  local tmp_dir review_id repo work_dir recorded expected
  tmp_dir=$(setup_env)
  review_id="test-$(date +%s)-sha"
  repo=$(setup_git_repo)
  work_dir="$repo/.tmp/ai-review-${review_id}"

  echo "const shaToken = 7;" >> "$repo/f.txt"

  ( cd "$repo" && PATH="$SCRIPT_DIR:$PATH" SKIP_SESSION_CHECK=1 \
      bash "$PARALLEL" "$tmp_dir/config.json" "$review_id" 2>/dev/null )

  recorded=$(cat "$work_dir/round-active-plan-sha.txt")
  if command -v sha256sum >/dev/null 2>&1; then
    expected=$(sha256sum "$work_dir/changeset.diff" | cut -d' ' -f1)
  else
    expected=$(shasum -a 256 "$work_dir/changeset.diff" | cut -d' ' -f1)
  fi

  [ "$recorded" = "$expected" ] || { rm -rf "$repo" "$tmp_dir"; return 1; }

  rm -rf "$repo" "$tmp_dir"
}

# record-round.sh and safe-cleanup.sh gate on whatever this marker names. Without
# it they both assume plan.md and gate on an empty placeholder (#17).
test_review_target_marker_written() {
  local tmp_dir review_id repo work_dir plan_work
  tmp_dir=$(setup_env)
  review_id="test-$(date +%s)-marker"
  repo=$(setup_git_repo)
  work_dir="$repo/.tmp/ai-review-${review_id}"

  echo "const markerToken = 8;" >> "$repo/f.txt"

  ( cd "$repo" && PATH="$SCRIPT_DIR:$PATH" SKIP_SESSION_CHECK=1 \
      bash "$PARALLEL" "$tmp_dir/config.json" "$review_id" 2>/dev/null )

  [ "$(cat "$work_dir/review-target.txt")" = "changeset.diff" ] || { rm -rf "$repo" "$tmp_dir"; return 1; }
  # safe-cleanup regenerates the diff against this base to detect drift.
  [ -s "$work_dir/changeset-base.txt" ] || { rm -rf "$repo" "$tmp_dir"; return 1; }

  # Plan mode names plan.md.
  plan_work="$repo/.tmp/ai-review-${review_id}-plan"
  mkdir -p "$plan_work"
  echo "A real staged plan" > "$plan_work/plan.md"
  ( cd "$repo" && PATH="$SCRIPT_DIR:$PATH" SKIP_SESSION_CHECK=1 \
      bash "$PARALLEL" "$tmp_dir/config.json" "${review_id}-plan" 2>/dev/null )
  [ "$(cat "$plan_work/review-target.txt")" = "plan.md" ] || { rm -rf "$repo" "$tmp_dir"; return 1; }

  rm -rf "$repo" "$tmp_dir"
}

test_plan_beats_changeset() {
  local tmp_dir review_id repo work_dir
  tmp_dir=$(setup_env)
  review_id="test-$(date +%s)-planwins"
  repo=$(setup_git_repo)
  work_dir="$repo/.tmp/ai-review-${review_id}"

  mkdir -p "$work_dir"
  echo "A real staged plan" > "$work_dir/plan.md"
  echo "const shouldNotBeReviewed = 4;" >> "$repo/f.txt"

  ( cd "$repo" && PATH="$SCRIPT_DIR:$PATH" SKIP_SESSION_CHECK=1 \
      bash "$PARALLEL" "$tmp_dir/config.json" "$review_id" 2>/dev/null )

  # A staged plan means no diff is captured at all, and the plan survives the run.
  [ -f "$work_dir/changeset.diff" ] && { rm -rf "$repo" "$tmp_dir"; return 1; }
  grep -q "A real staged plan" "$work_dir/plan.md" || { rm -rf "$repo" "$tmp_dir"; return 1; }
  [ -f "$work_dir/alpha-output.md" ] || { rm -rf "$repo" "$tmp_dir"; return 1; }

  rm -rf "$repo" "$tmp_dir"
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

test_accepts_tilde_config() {
  # The orchestrator passes a quoted literal "~/.claude/debate-acpx.json",
  # which never expands inside quotes — the runner must normalize the leading ~
  # itself or the config guard fails (seen in the wild). Point ~/config.json at
  # a real config via a temp HOME and expect a successful review.
  local tmp_dir review_id work_dir fake_home code
  tmp_dir=$(setup_env)
  fake_home=$(mktemp -d)
  review_id="test-$(date +%s)-tilde"
  work_dir=".tmp/ai-review-${review_id}"

  mkdir -p "$work_dir"
  echo "Test plan" > "$work_dir/plan.md"
  cp "$tmp_dir/config.json" "$fake_home/config.json"

  set +e
  HOME="$fake_home" PATH="$SCRIPT_DIR:$PATH" \
    bash "$PARALLEL" "~/config.json" "$review_id" "alpha" 2>/dev/null
  code=$?
  set -e

  [ "$code" -eq 0 ] || { rm -rf "$tmp_dir" "$fake_home" "$work_dir"; return 1; }
  [ -s "$work_dir/alpha-output.md" ] || { rm -rf "$tmp_dir" "$fake_home" "$work_dir"; return 1; }

  rm -rf "$tmp_dir" "$fake_home" "$work_dir"
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

# A config can define seats that only make sense as a fallback — an agent for when
# the usual one is broken. Defaulting to every key in .reviewers runs those on every
# review, which is the opposite of what a fallback is for.
test_default_reviewers_limits_the_default_set() {
  local tmp_dir review_id work_dir
  tmp_dir=$(setup_env)
  review_id="test-$(date +%s)-defset"
  work_dir=".tmp/ai-review-${review_id}"

  cat > "$tmp_dir/config.json" << 'EOF'
{
  "default_reviewers": ["alpha"],
  "reviewers": {
    "alpha": { "agent": "codex", "timeout": 10 },
    "fallback-only": { "agent": "codex", "timeout": 10, "mode": "exec" }
  }
}
EOF

  mkdir -p "$work_dir"
  echo "Test plan" > "$work_dir/plan.md"

  PATH="$SCRIPT_DIR:$PATH" SKIP_SESSION_CHECK=1 \
    bash "$PARALLEL" "$tmp_dir/config.json" "$review_id" 2>/dev/null

  [ -f "$work_dir/alpha-exit.txt" ] || { rm -rf "$work_dir" "$tmp_dir"; return 1; }
  # The fallback seat must not have run.
  [ ! -f "$work_dir/fallback-only-exit.txt" ] || { rm -rf "$work_dir" "$tmp_dir"; return 1; }

  rm -rf "$work_dir" "$tmp_dir"
}

# An explicit empty array is a choice, not an omission: "no default panel, always
# select explicitly". Falling through to every reviewer would do the opposite.
test_empty_default_reviewers_runs_none() {
  local tmp_dir review_id work_dir
  tmp_dir=$(setup_env)
  review_id="test-$(date +%s)-emptydef"
  work_dir=".tmp/ai-review-${review_id}"

  cat > "$tmp_dir/config.json" << 'EOF'
{
  "default_reviewers": [],
  "reviewers": {
    "alpha": { "agent": "codex", "timeout": 10 },
    "beta":  { "agent": "codex", "timeout": 10, "mode": "exec" }
  }
}
EOF

  mkdir -p "$work_dir"
  echo "Test plan" > "$work_dir/plan.md"

  local rc=0
  PATH="$SCRIPT_DIR:$PATH" SKIP_SESSION_CHECK=1 \
    bash "$PARALLEL" "$tmp_dir/config.json" "$review_id" 2>/dev/null || rc=$?

  # Assert the status explicitly. `set -e` does not fire for a command inside a
  # function called as `if "$@"`, so without capturing rc a non-zero exit here
  # would pass silently and the test would prove nothing.
  [ "$rc" -ne 0 ] || { echo "  runner exited 0 with an empty default set"; rm -rf "$work_dir" "$tmp_dir"; return 1; }
  [ ! -f "$work_dir/alpha-exit.txt" ] || { rm -rf "$work_dir" "$tmp_dir"; return 1; }
  [ ! -f "$work_dir/beta-exit.txt" ]  || { rm -rf "$work_dir" "$tmp_dir"; return 1; }

  rm -rf "$work_dir" "$tmp_dir"
}

# Absent the field, behave exactly as before: every reviewer runs.
test_missing_default_reviewers_runs_all() {
  local tmp_dir review_id work_dir
  tmp_dir=$(setup_env)
  review_id="test-$(date +%s)-alldef"
  work_dir=".tmp/ai-review-${review_id}"

  mkdir -p "$work_dir"
  echo "Test plan" > "$work_dir/plan.md"

  PATH="$SCRIPT_DIR:$PATH" SKIP_SESSION_CHECK=1 \
    bash "$PARALLEL" "$tmp_dir/config.json" "$review_id" 2>/dev/null

  [ -f "$work_dir/alpha-exit.txt" ] || { rm -rf "$work_dir" "$tmp_dir"; return 1; }
  [ -f "$work_dir/beta-exit.txt" ] || { rm -rf "$work_dir" "$tmp_dir"; return 1; }
  [ -f "$work_dir/gamma-exit.txt" ] || { rm -rf "$work_dir" "$tmp_dir"; return 1; }

  rm -rf "$work_dir" "$tmp_dir"
}

# The wait budget has to cover retries. Each attempt gets the full timeout, so
# budgeting one attempt SIGTERMs a reviewer mid-retry and loses the seat.
test_wait_budget_accounts_for_retries() {
  local tmp_dir review_id work_dir out
  tmp_dir=$(setup_env)
  review_id="test-$(date +%s)-budget"
  work_dir=".tmp/ai-review-${review_id}"

  cat > "$tmp_dir/config.json" << 'EOF'
{
  "reviewers": {
    "alpha": { "agent": "codex", "timeout": 100, "retries": 3 }
  }
}
EOF

  mkdir -p "$work_dir"
  echo "Test plan" > "$work_dir/plan.md"

  # POLL_MAX_WAIT unset so the runner reports its computed budget.
  # 100 x (3+1) + 60 = 460; the old formula gave 160.
  out=$(PATH="$SCRIPT_DIR:$PATH" SKIP_SESSION_CHECK=1 \
    bash "$PARALLEL" "$tmp_dir/config.json" "$review_id" 2>&1)

  echo "$out" | grep -q "max wait: 460s" || { rm -rf "$work_dir" "$tmp_dir"; return 1; }

  rm -rf "$work_dir" "$tmp_dir"
}

# A timeout that is not a positive integer used to fall out of the budget entirely,
# because the guard had no else. The seat still ran, at the 120s invoke-acpx.sh
# substitutes, so the wait budget and the seat disagreed and neither said so where
# the operator would see it.
test_invalid_timeout_still_counts_toward_budget() {
  local tmp_dir review_id work_dir out
  tmp_dir=$(setup_env)
  review_id="test-$(date +%s)-badtimeout"
  work_dir=".tmp/ai-review-${review_id}"

  cat > "$tmp_dir/config.json" << 'EOF'
{
  "reviewers": {
    "alpha": { "agent": "codex", "timeout": "600s", "retries": 1 }
  }
}
EOF

  mkdir -p "$work_dir"
  echo "Test plan" > "$work_dir/plan.md"

  # Falls back to 120, so 120 x (1+1) + 60 = 300. Before, the seat contributed
  # nothing and MAX_REVIEWER_BUDGET stayed 0, dropping the runner to its 450s floor.
  out=$(PATH="$SCRIPT_DIR:$PATH" SKIP_SESSION_CHECK=1 \
    bash "$PARALLEL" "$tmp_dir/config.json" "$review_id" 2>&1)

  echo "$out" | grep -q "max wait: 300s" || { rm -rf "$work_dir" "$tmp_dir"; return 1; }
  echo "$out" | grep -q "invalid timeout '600s'" || { rm -rf "$work_dir" "$tmp_dir"; return 1; }

  rm -rf "$work_dir" "$tmp_dir"
}

# Warm-up exists to avoid a races on the shared session index. A one-shot reviewer
# has no session, and a direct-CLI agent has no acpx session at all.
test_warmup_skips_exec_mode_and_direct_cli() {
  local tmp_dir review_id work_dir log_file
  tmp_dir=$(setup_env)
  review_id="test-$(date +%s)-warm"
  work_dir=".tmp/ai-review-${review_id}"
  log_file="$tmp_dir/acpx-log.txt"

  cat > "$tmp_dir/config.json" << 'EOF'
{
  "reviewers": {
    "one-shot":  { "agent": "codex",      "timeout": 10, "mode": "exec" },
    "direct":    { "agent": "opus",       "timeout": 10 },
    "sessioned": { "agent": "cursor",     "timeout": 10 }
  }
}
EOF

  mkdir -p "$work_dir"
  echo "Test plan" > "$work_dir/plan.md"

  # No SKIP_SESSION_CHECK: the warm-up loop must actually run.
  PATH="$SCRIPT_DIR:$PATH" MOCK_ACPX_LOG="$log_file" \
    bash "$PARALLEL" "$tmp_dir/config.json" "$review_id" 2>/dev/null

  # Only the sessioned agent gets warmed.
  grep -q "cursor sessions ensure" "$log_file" || { rm -rf "$work_dir" "$tmp_dir"; return 1; }
  grep -q "codex sessions ensure" "$log_file" && { rm -rf "$work_dir" "$tmp_dir"; return 1; }
  grep -q "opus sessions ensure" "$log_file" && { rm -rf "$work_dir" "$tmp_dir"; return 1; }

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

# --- per-seat model selection (F1) ---
#
# The runner must forward the panel selector's per-seat model choice to each
# invoke-acpx.sh child as MODEL=<id>, which passes it to acpx as --model <id>.
# The map is the select-panel.py output (or a flat {seat: model_id}); a
# DEBATE_MODEL fallback covers a single-model dispatch.

test_seat_models_map_reaches_reviewers() {
  local tmp_dir review_id work_dir log_file
  tmp_dir=$(setup_env)
  review_id="test-$(date +%s)-models"
  work_dir=".tmp/ai-review-${review_id}"
  log_file="$tmp_dir/acpx-log.txt"

  cat > "$tmp_dir/models.json" << 'EOF'
{"alpha": "model-alpha-1", "beta": "model-beta-2"}
EOF

  mkdir -p "$work_dir"
  echo "Test plan" > "$work_dir/plan.md"

  PATH="$SCRIPT_DIR:$PATH" \
  SKIP_SESSION_CHECK=1 \
  ACPX_SEAT_MODELS="$tmp_dir/models.json" \
  MOCK_ACPX_LOG="$log_file" \
  MOCK_ACPX_RESPONSE="Reviewed. VERDICT: APPROVED" \
    bash "$PARALLEL" "$tmp_dir/config.json" "$review_id" 2>/dev/null

  [ -f "$work_dir/alpha-exit.txt" ] || { rm -rf "$work_dir" "$tmp_dir"; return 1; }
  [ "$(cat "$work_dir/alpha-exit.txt")" = "0" ] || { rm -rf "$work_dir" "$tmp_dir"; return 1; }
  # alpha (codex) and beta (antigravity) each got their mapped model.
  grep -q -- "--model model-alpha-1" "$log_file" || { rm -rf "$work_dir" "$tmp_dir"; return 1; }
  grep -q -- "--model model-beta-2" "$log_file" || { rm -rf "$work_dir" "$tmp_dir"; return 1; }
  # gamma (opus) is not in the map and no DEBATE_MODEL is set, so it keeps the opus default.
  grep -q -- "--model claude-opus-4-8" "$log_file" || { rm -rf "$work_dir" "$tmp_dir"; return 1; }

  rm -rf "$work_dir" "$tmp_dir"
}

test_seat_models_full_selector_output() {
  # The map can be the select-panel.py output itself, not just a flat map.
  local tmp_dir review_id work_dir log_file
  tmp_dir=$(setup_env)
  review_id="test-$(date +%s)-selectormodel"
  work_dir=".tmp/ai-review-${review_id}"
  log_file="$tmp_dir/acpx-log.txt"

  cat > "$tmp_dir/panel.json" << 'EOF'
{"seats": {"alpha": {"model_id": "selector-alpha-model"}, "beta": {"model_id": "selector-beta-model"}}, "distinct_labs": 2}
EOF

  mkdir -p "$work_dir"
  echo "Test plan" > "$work_dir/plan.md"

  PATH="$SCRIPT_DIR:$PATH" \
  SKIP_SESSION_CHECK=1 \
  ACPX_SEAT_MODELS="$tmp_dir/panel.json" \
  MOCK_ACPX_LOG="$log_file" \
  MOCK_ACPX_RESPONSE="Reviewed. VERDICT: APPROVED" \
    bash "$PARALLEL" "$tmp_dir/config.json" "$review_id" 2>/dev/null

  grep -q -- "--model selector-alpha-model" "$log_file" || { rm -rf "$work_dir" "$tmp_dir"; return 1; }
  grep -q -- "--model selector-beta-model" "$log_file" || { rm -rf "$work_dir" "$tmp_dir"; return 1; }

  rm -rf "$work_dir" "$tmp_dir"
}

test_single_model_env_forwarded() {
  local tmp_dir review_id work_dir log_file
  tmp_dir=$(setup_env)
  review_id="test-$(date +%s)-singlemodel"
  work_dir=".tmp/ai-review-${review_id}"
  log_file="$tmp_dir/acpx-log.txt"

  mkdir -p "$work_dir"
  echo "Test plan" > "$work_dir/plan.md"

  PATH="$SCRIPT_DIR:$PATH" \
  SKIP_SESSION_CHECK=1 \
  DEBATE_MODEL="unified-model" \
  MOCK_ACPX_LOG="$log_file" \
  MOCK_ACPX_RESPONSE="Reviewed. VERDICT: APPROVED" \
    bash "$PARALLEL" "$tmp_dir/config.json" "$review_id" 2>/dev/null

  grep -q -- "--model unified-model" "$log_file" || { rm -rf "$work_dir" "$tmp_dir"; return 1; }

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

# --- effort auto-scaling (#31 Q2) ---
#
# The runner reads .seats[<seat>].effective_effort from the selector output and
# forwards it to each seat's invoke-acpx.sh as EFFORT=<level>. An inherited
# EFFORT from the caller's environment must not leak into a seat without an
# effective_effort entry.

test_effort_forwarded_from_selector_output() {
  local tmp_dir review_id work_dir codex_log
  tmp_dir=$(setup_env)
  review_id="test-$(date +%s)-effort"
  work_dir=".tmp/ai-review-${review_id}"
  codex_log="$tmp_dir/codex-log.txt"

  cat > "$tmp_dir/panel.json" << 'EOF'
{"seats": {"alpha": {"model_id": "m-alpha", "effective_effort": "high"}, "beta": {"model_id": "m-beta", "effective_effort": "low"}}, "distinct_labs": 2}
EOF

  mkdir -p "$work_dir"
  echo "Test plan" > "$work_dir/plan.md"

  PATH="$SCRIPT_DIR:$PATH" \
  SKIP_SESSION_CHECK=1 \
  ACPX_SEAT_MODELS="$tmp_dir/panel.json" \
  MOCK_CODEX_LOG="$codex_log" \
  MOCK_CODEX_RESPONSE="Reviewed. VERDICT: APPROVED" \
    bash "$PARALLEL" "$tmp_dir/config.json" "$review_id" "alpha" 2>/dev/null

  [ "$(cat "$work_dir/alpha-exit.txt")" = "0" ] || { rm -rf "$work_dir" "$tmp_dir"; return 1; }
  grep -q -- "-c model_reasoning_effort=high" "$codex_log" || { rm -rf "$work_dir" "$tmp_dir"; return 1; }

  rm -rf "$work_dir" "$tmp_dir"
}

test_effort_cleared_when_no_entry() {
  # A seat without an effective_effort entry must NOT inherit the caller's
  # EFFORT — the runner always sets EFFORT=<mapped-or-empty>.
  local tmp_dir review_id work_dir codex_log
  tmp_dir=$(setup_env)
  review_id="test-$(date +%s)-noeffort"
  work_dir=".tmp/ai-review-${review_id}"
  codex_log="$tmp_dir/codex-log.txt"

  cat > "$tmp_dir/panel.json" << 'EOF'
{"seats": {"alpha": {"model_id": "m-alpha"}, "beta": {"model_id": "m-beta"}}, "distinct_labs": 2}
EOF

  mkdir -p "$work_dir"
  echo "Test plan" > "$work_dir/plan.md"

  # Deliberately set EFFORT in the caller's env: it must not leak.
  PATH="$SCRIPT_DIR:$PATH" \
  SKIP_SESSION_CHECK=1 \
  ACPX_SEAT_MODELS="$tmp_dir/panel.json" \
  EFFORT="max" \
  MOCK_CODEX_LOG="$codex_log" \
  MOCK_CODEX_RESPONSE="Reviewed. VERDICT: APPROVED" \
    bash "$PARALLEL" "$tmp_dir/config.json" "$review_id" "alpha" 2>/dev/null

  # alpha is a codex seat with no effective_effort, so EFFORT must be empty and
  # the seat runs via acpx (no direct codex call, no reasoning_effort).
  ! grep -q "model_reasoning_effort" "$codex_log" || { rm -rf "$work_dir" "$tmp_dir"; return 1; }
  [ "$(cat "$work_dir/alpha-exit.txt")" = "0" ] || { rm -rf "$work_dir" "$tmp_dir"; return 1; }

  rm -rf "$work_dir" "$tmp_dir"
}

test_subagent_seat_skipped() {
  # A subagent-harness seat is not this runner's job; it must be filtered before
  # spawn — no exit file, and no acpx/codex invocation.
  local tmp_dir review_id work_dir acpx_log codex_log out
  tmp_dir=$(setup_env)
  review_id="test-$(date +%s)-subagent"
  work_dir=".tmp/ai-review-${review_id}"
  acpx_log="$tmp_dir/acpx-log.txt"
  codex_log="$tmp_dir/codex-log.txt"

  cat > "$tmp_dir/panel.json" << 'EOF'
{"seats": {"alpha": {"model_id": "m-alpha", "harness": "subagent", "effective_effort": "high"}}, "distinct_labs": 1}
EOF

  mkdir -p "$work_dir"
  echo "Test plan" > "$work_dir/plan.md"

  out=$(PATH="$SCRIPT_DIR:$PATH" \
    SKIP_SESSION_CHECK=1 \
    ACPX_SEAT_MODELS="$tmp_dir/panel.json" \
    MOCK_ACPX_LOG="$acpx_log" MOCK_CODEX_LOG="$codex_log" \
    bash "$PARALLEL" "$tmp_dir/config.json" "$review_id" "alpha" 2>&1) || true

  [ ! -f "$work_dir/alpha-exit.txt" ] || { rm -rf "$work_dir" "$tmp_dir"; return 1; }
  echo "$out" | grep -q "subagent harness is dispatched by the caller" || { rm -rf "$work_dir" "$tmp_dir"; return 1; }
  [ ! -s "$acpx_log" ] || { rm -rf "$work_dir" "$tmp_dir"; return 1; }
  [ ! -s "$codex_log" ] || { rm -rf "$work_dir" "$tmp_dir"; return 1; }

  rm -rf "$work_dir" "$tmp_dir"
}

test_proxy_opus_provider_not_locked() {
  # An opus seat with a proxy-transport model whose provider is NOT anthropic
  # (e.g. deepseek via cc-ds4) must pass the provider-feasibility guard — the
  # proxy transport already validated the agent (opus), and a proxy model's
  # provider must not be run against the opus anthropic lock (CR finding,
  # PR #60). Without this the opus+deepseek proxy seat dies at spawn.
  local tmp_dir review_id work_dir acpx_log
  tmp_dir=$(setup_env)
  review_id="test-$(date +%s)-proxyopus"
  work_dir=".tmp/ai-review-${review_id}"
  acpx_log="$tmp_dir/acpx-log.txt"

  cat > "$tmp_dir/panel.json" << 'EOF'
{"seats": {"gamma": {"model_id": "deepseek-v4-pro", "provider": "deepseek", "harness": "acpx", "transport": "proxy", "route": 31502, "effective_effort": "high"}}, "distinct_labs": 1}
EOF

  mkdir -p "$work_dir"
  echo "Test plan" > "$work_dir/plan.md"

  PATH="$SCRIPT_DIR:$PATH" \
  SKIP_SESSION_CHECK=1 \
  ACPX_SEAT_MODELS="$tmp_dir/panel.json" \
  MOCK_ACPX_LOG="$acpx_log" \
  MOCK_ACPX_RESPONSE="Reviewed. VERDICT: APPROVED" \
    bash "$PARALLEL" "$tmp_dir/config.json" "$review_id" "gamma" 2>&1 | grep -q "not runnable" \
    && { rm -rf "$work_dir" "$tmp_dir"; return 1; }   # guard must NOT skip it

  [ -f "$work_dir/gamma-exit.txt" ] || { rm -rf "$work_dir" "$tmp_dir"; return 1; }
  [ "$(cat "$work_dir/gamma-exit.txt")" = "0" ] || { rm -rf "$work_dir" "$tmp_dir"; return 1; }

  rm -rf "$work_dir" "$tmp_dir"
}

test_provider_mismatch_runs_config_default() {
  # A provider-lock mismatch must NOT skip the seat: it clears the selected
  # model and runs the agent at its configured default (CR finding, PR #60).
  # The mock acpx invocation log must record NO --model for the seat.
  local tmp_dir review_id work_dir acpx_log out
  tmp_dir=$(setup_env)
  review_id="test-$(date +%s)-provmismatch"
  work_dir=".tmp/ai-review-${review_id}"
  acpx_log="$tmp_dir/acpx-log.txt"

  # alpha is a codex seat; the panel hands it a zai (non-openai) model — the
  # guard must clear it, not skip the seat.
  cat > "$tmp_dir/panel.json" << 'EOF'
{"seats": {"alpha": {"model_id": "glm-5.2", "provider": "zai", "harness": "acpx", "transport": null, "route": null, "effective_effort": "high"}}, "distinct_labs": 1}
EOF

  mkdir -p "$work_dir"
  echo "Test plan" > "$work_dir/plan.md"

  # Capture the runner's output to a FILE, then grep it. Piping straight into
  # `grep -q` races the runner: grep closes the pipe on match, the still-running
  # parent takes SIGPIPE (exit 141), and `set -o pipefail` turns the pipeline
  # into a failure even though the message was emitted.
  out=$(PATH="$SCRIPT_DIR:$PATH" \
    SKIP_SESSION_CHECK=1 \
    ACPX_SEAT_MODELS="$tmp_dir/panel.json" \
    MOCK_ACPX_LOG="$acpx_log" \
    MOCK_ACPX_RESPONSE="Reviewed. VERDICT: APPROVED" \
    bash "$PARALLEL" "$tmp_dir/config.json" "$review_id" "alpha" 2>&1) || true
  echo "$out" | grep -q "will run at its configured default" \
    || { rm -rf "$work_dir" "$tmp_dir"; return 1; }   # guard must emit the degrade message

  # Seat must still spawn (exit file present, code 0) and reach acpx WITHOUT --model
  # or the selected effort (both are cleared so the config default governs).
  [ -f "$work_dir/alpha-exit.txt" ] || { rm -rf "$work_dir" "$tmp_dir"; return 1; }
  [ "$(cat "$work_dir/alpha-exit.txt")" = "0" ] || { rm -rf "$work_dir" "$tmp_dir"; return 1; }
  grep -q -- "--model" "$acpx_log" && { rm -rf "$work_dir" "$tmp_dir"; return 1; }   # no model forwarded
  grep -q -- "reasoning_effort" "$acpx_log" && { rm -rf "$work_dir" "$tmp_dir"; return 1; }   # no selected effort either
  [ -s "$acpx_log" ] || { rm -rf "$work_dir" "$tmp_dir"; return 1; }                 # acpx was invoked

  rm -rf "$work_dir" "$tmp_dir"
}

# A wedged seat must come back at its budget rather than at the agent's own much
# larger timeout, and it must still be accounted for: the orchestrator reads
# <name>-exit.txt, and a seat killed before its EXIT trap could run gets that file
# written from the wait status instead.
#
test_hung_reviewer_dies_at_its_budget() {
  local tmp_dir review_id work_dir out rc start elapsed
  tmp_dir=$(setup_env)
  review_id="test-$(date +%s)-hang"
  work_dir=".tmp/ai-review-${review_id}"

  cat > "$tmp_dir/config.json" << 'EOF'
{
  "reviewers": {
    "alpha": { "agent": "codex", "timeout": 120, "retries": 0 }
  }
}
EOF

  mkdir -p "$work_dir"
  echo "Test plan" > "$work_dir/plan.md"

  start=$SECONDS
  rc=0
  out=$(PATH="$SCRIPT_DIR:$PATH" SKIP_SESSION_CHECK=1 POLL_MAX_WAIT=3 \
    MOCK_ACPX_DELAY=60 \
    bash "$PARALLEL" "$tmp_dir/config.json" "$review_id" 2>&1) || rc=$?
  elapsed=$(( SECONDS - start ))

  local cleanup="$work_dir $tmp_dir"
  # Back at the budget, not at the agent's own 120s timeout.
  [ "$elapsed" -lt 30 ] || {
    echo "DIAG hung: took ${elapsed}s -- $out" >&2; rm -rf $cleanup; return 1; }
  [ "$rc" -ne 0 ] || { echo "DIAG hung: rc=0 -- $out" >&2; rm -rf $cleanup; return 1; }
  echo "$out" | grep -q "alpha ran out of time (seat budget 3s)" || {
    echo "DIAG hung: $out" >&2; rm -rf $cleanup; return 1; }
  # A timeout is recorded as 124; run.md's contract has no signal codes in it.
  [ "$(cat "$work_dir/alpha-exit.txt" 2>&1)" = "124" ] || {
    echo "DIAG hung: exit=[$(cat "$work_dir/alpha-exit.txt" 2>&1)]" >&2
    rm -rf $cleanup; return 1; }

  rm -rf $cleanup
}

# Killing a seat has to kill the agent, not just the invoke-acpx.sh wrapper: a
# wrapper-only kill leaves the agent with ppid 1, still burning tokens after the
# panel reports it dead. The mock writes a marker only if it outlives its delay.
#
# $1 budget: short enough to kill the seat mid-delay, or long enough to let it
# finish. Both directions are asserted, because "no marker" on its own also
# describes a seat that never launched — the run with the long budget is the
# positive control that proves the marker can appear at all.
seat_survival_marker() {
  local budget="$1" tmp_dir review_id work_dir survived waited
  tmp_dir=$(setup_env)
  review_id="test-$(date +%s)-kill$budget"
  work_dir=".tmp/ai-review-${review_id}"
  survived="$tmp_dir/survived.txt"

  cat > "$tmp_dir/config.json" << 'EOF'
{
  "reviewers": {
    "alpha": { "agent": "codex", "timeout": 120, "retries": 0 }
  }
}
EOF

  mkdir -p "$work_dir"
  echo "Test plan" > "$work_dir/plan.md"

  PATH="$SCRIPT_DIR:$PATH" SKIP_SESSION_CHECK=1 POLL_MAX_WAIT="$budget" \
    MOCK_ACPX_DELAY=8 MOCK_ACPX_SURVIVED_FILE="$survived" \
    bash "$PARALLEL" "$tmp_dir/config.json" "$review_id" > /dev/null 2>&1

  # Outlive the mock's delay, so a survivor has time to write its marker.
  waited=0
  while [ "$waited" -lt 12 ] && [ ! -f "$survived" ]; do
    sleep 2
    waited=$(( waited + 2 ))
  done

  [ -f "$survived" ] && echo survived || echo killed
  rm -rf "$work_dir" "$tmp_dir"
}

test_seat_kill_reaches_the_agent_process() {
  local killed lived
  # Positive control first: with room to finish, the marker MUST appear. Without
  # this the negative case below passes just as happily when nothing ever ran.
  lived=$(seat_survival_marker 60)
  [ "$lived" = "survived" ] || {
    echo "DIAG kill: positive control failed - marker absent with a 60s budget ($lived)" >&2
    return 1; }

  killed=$(seat_survival_marker 3)
  [ "$killed" = "killed" ] || {
    echo "DIAG kill: agent outlived the seat kill ($killed)" >&2; return 1; }
}

# POLL_MAX_WAIT is a `timeout` argument now, and `timeout` refuses to run at all on
# a malformed duration — which would kill every seat instantly instead of ignoring
# one bad env var.
test_invalid_poll_max_wait_ignored() {
  local tmp_dir review_id work_dir out
  tmp_dir=$(setup_env)
  review_id="test-$(date +%s)-badwait"
  work_dir=".tmp/ai-review-${review_id}"

  mkdir -p "$work_dir"
  echo "Test plan" > "$work_dir/plan.md"

  out=$(PATH="$SCRIPT_DIR:$PATH" SKIP_SESSION_CHECK=1 POLL_MAX_WAIT="600s" \
    MOCK_ACPX_RESPONSE="Mock review. VERDICT: APPROVED" \
    bash "$PARALLEL" "$tmp_dir/config.json" "$review_id" "alpha" 2>&1)

  echo "$out" | grep -q "invalid POLL_MAX_WAIT" || {
    echo "DIAG no-warning: $out" >&2; rm -rf "$work_dir" "$tmp_dir"; return 1; }
  [ "$(cat "$work_dir/alpha-exit.txt" 2>&1)" = "0" ] || {
    echo "DIAG exit=[$(cat "$work_dir/alpha-exit.txt" 2>&1)] output=[$(head -c 200 "$work_dir/alpha-output.md" 2>&1)] log=[$(head -c 300 "$work_dir/alpha-invoke.log" 2>&1)]" >&2
    rm -rf "$work_dir" "$tmp_dir"; return 1; }

  rm -rf "$work_dir" "$tmp_dir"
}

# --- Run ---

echo ""
echo "=== run-parallel-acpx.sh tests ==="
echo ""

# Create mock binaries on PATH for acpx, agy, claude, and codex (direct CLI paths)
ln -sf "$MOCK" "$SCRIPT_DIR/acpx"
chmod +x "$SCRIPT_DIR/acpx"
ln -sf "$MOCK_AGY" "$SCRIPT_DIR/agy"
chmod +x "$SCRIPT_DIR/agy"
ln -sf "$MOCK_CLAUDE" "$SCRIPT_DIR/claude"
chmod +x "$SCRIPT_DIR/claude"
ln -sf "$MOCK_CODEX" "$SCRIPT_DIR/codex"
chmod +x "$SCRIPT_DIR/codex"
trap 'rm -f "$SCRIPT_DIR/acpx" "$SCRIPT_DIR/agy" "$SCRIPT_DIR/claude" "$SCRIPT_DIR/codex"' EXIT

run_test "parallel happy path" test_parallel_happy_path
run_test "subset reviewers" test_subset_reviewers
run_test "missing plan and no changes fails" test_missing_plan_fails
run_test "changeset generated when no plan" test_changeset_generated_when_no_plan
run_test "changeset reaches the reviewer" test_changeset_reaches_the_reviewer
run_test "DEBATE_DIFF_BASE respected" test_diff_base_override_respected
run_test "untracked files included in changeset" test_untracked_files_included_in_changeset
run_test "work dir excluded from changeset" test_work_dir_excluded_from_changeset
run_test "round SHA covers the changeset" test_round_sha_covers_the_changeset
run_test "review-target marker written" test_review_target_marker_written
run_test "plan beats changeset" test_plan_beats_changeset
run_test "missing config fails" test_missing_config_fails
run_test "tilde config path is expanded" test_accepts_tilde_config
run_test "prompt files cleaned up" test_prompt_files_cleaned_up
run_test "invalid review ID rejected" test_invalid_review_id_rejected
run_test "reviewer name sanitization" test_reviewer_name_sanitization
run_test "whitespace trimmed reviewer list" test_whitespace_trimmed_reviewer_list
run_test "default_reviewers limits the default set" test_default_reviewers_limits_the_default_set
run_test "empty default_reviewers runs none" test_empty_default_reviewers_runs_none
run_test "missing default_reviewers runs all" test_missing_default_reviewers_runs_all
run_test "wait budget accounts for retries" test_wait_budget_accounts_for_retries
run_test "invalid timeout still counts toward budget" test_invalid_timeout_still_counts_toward_budget
run_test "warm-up skips exec mode and direct CLI" test_warmup_skips_exec_mode_and_direct_cli
run_test "invoke logs created" test_invoke_logs_created
run_test "seat models map reaches reviewers" test_seat_models_map_reaches_reviewers
run_test "seat models map accepts full selector output" test_seat_models_full_selector_output
run_test "single DEBATE_MODEL forwarded to all" test_single_model_env_forwarded
run_test "one failure doesnt block others" test_one_failure_doesnt_block_others
run_test "effective_effort forwarded from selector output" test_effort_forwarded_from_selector_output
run_test "EFFORT cleared when no effective_effort entry" test_effort_cleared_when_no_entry
run_test "subagent harness seat skipped by this runner" test_subagent_seat_skipped
run_test "proxy opus seat not provider-locked" test_proxy_opus_provider_not_locked
run_test "provider mismatch runs config default" test_provider_mismatch_runs_config_default
run_test "hung reviewer dies at its budget" test_hung_reviewer_dies_at_its_budget
run_test "seat kill reaches the agent process" test_seat_kill_reaches_the_agent_process
run_test "invalid POLL_MAX_WAIT ignored" test_invalid_poll_max_wait_ignored

echo ""
echo "=== Results: $PASS passed, $FAIL failed ($(( PASS + FAIL )) total) ==="

[ "$FAIL" -eq 0 ]

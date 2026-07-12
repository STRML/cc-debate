#!/bin/bash
# Static checks for dangling references after the acpx migration.
# Verifies no active files reference deleted scripts, commands, or old paths.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Files that should have been deleted in the acpx migration.
# Maintain this list in one place so tests stay in sync.
DELETED_FILES=(
  commands/codex-review.md
  commands/gemini-review.md
  commands/litellm-review.md
  commands/openrouter-review.md
  commands/litellm-setup.md
  commands/openrouter-setup.md
  scripts/invoke-codex.sh
  scripts/invoke-gemini.sh
  scripts/invoke-opus.sh
  scripts/invoke-openai-compat.sh
  scripts/run-parallel.sh
  scripts/run-parallel-openai-compat.sh
  scripts/probe-model.sh
  reviewers/codex.md
  reviewers/gemini.md
  reviewers/opus.md
)

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

# --- Tests ---

test_no_old_invoke_refs() {
  # Should not reference deleted invoke scripts in active files.
  # Exclude setup.md (migration detection) and script comments.
  local found
  found=$(grep -rl --exclude=setup.md "invoke-codex\|invoke-gemini\|invoke-opus\.sh\|invoke-openai-compat" \
    "$PROJECT_DIR/commands" "$PROJECT_DIR/README.md" \
    2>/dev/null || true)
  # For scripts dir, check only non-comment lines
  local script_hits
  script_hits=$(grep -rn "invoke-codex\|invoke-gemini\|invoke-opus\.sh\|invoke-openai-compat" \
    "$PROJECT_DIR/scripts" 2>/dev/null | grep -v "^[^:]*:[0-9]*:#" || true)
  [ -z "$found" ] && [ -z "$script_hits" ] || {
    [ -n "$found" ] && echo "  Found in: $found"
    [ -n "$script_hits" ] && echo "  Found in scripts: $script_hits"
    return 1
  }
}

test_no_old_parallel_refs() {
  # Exclude setup.md (migration detection)
  local found
  found=$(grep -rl --exclude=setup.md "run-parallel\.sh\|run-parallel-openai-compat" \
    "$PROJECT_DIR/commands" "$PROJECT_DIR/scripts" "$PROJECT_DIR/README.md" \
    2>/dev/null || true)
  [ -z "$found" ] || { echo "  Found in: $found"; return 1; }
}

test_no_old_config_refs() {
  # Active commands/scripts should not reference old config files.
  # Exclude setup.md (migration detection)
  local found
  found=$(grep -rl --exclude=setup.md "debate-litellm\.json\|debate-openrouter\.json" \
    "$PROJECT_DIR/commands" "$PROJECT_DIR/scripts" \
    2>/dev/null || true)
  [ -z "$found" ] || { echo "  Found in: $found"; return 1; }
}

test_no_old_command_refs_in_active_files() {
  # Should not reference removed commands in active command files
  local found
  found=$(grep -rl "codex-review\|gemini-review\|litellm-review\|openrouter-review\|litellm-setup\|openrouter-setup" \
    "$PROJECT_DIR/commands" "$PROJECT_DIR/scripts" \
    2>/dev/null || true)
  [ -z "$found" ] || { echo "  Found in: $found"; return 1; }
}

test_no_probe_model_refs() {
  # Exclude setup.md (migration detection)
  local found
  found=$(grep -rl --exclude=setup.md "probe-model" \
    "$PROJECT_DIR/commands" "$PROJECT_DIR/scripts" \
    2>/dev/null || true)
  [ -z "$found" ] || { echo "  Found in: $found"; return 1; }
}

test_no_old_work_dir_in_active_files() {
  # Active commands/scripts should use .tmp/ not .claude/tmp/
  # Exclude setup.md (migration detection)
  local found
  found=$(grep -rl --exclude=setup.md "\.claude/tmp/ai-review" \
    "$PROJECT_DIR/commands" "$PROJECT_DIR/scripts" \
    2>/dev/null || true)
  [ -z "$found" ] || { echo "  Found in: $found"; return 1; }
}

test_deleted_files_dont_exist() {
  local bad=0
  for f in "${DELETED_FILES[@]}"; do
    if [ -f "$PROJECT_DIR/$f" ]; then
      echo "  Still exists: $f"
      bad=1
    fi
  done
  [ "$bad" -eq 0 ]
}

test_new_files_exist() {
  local missing=0
  for f in \
    scripts/invoke-acpx.sh \
    scripts/run-parallel-acpx.sh \
    scripts/acpx-env-snapshot.sh \
    scripts/reviewer-prompts.md \
    commands/acpx-setup.md \
    tests/mock-agy.sh \
    tests/mock-claude.sh \
    MIGRATING.md; do
    if [ ! -f "$PROJECT_DIR/$f" ]; then
      echo "  Missing: $f"
      missing=1
    fi
  done
  [ "$missing" -eq 0 ]
}

test_new_scripts_executable() {
  local bad=0
  for f in scripts/invoke-acpx.sh scripts/run-parallel-acpx.sh scripts/acpx-env-snapshot.sh tests/mock-agy.sh tests/mock-claude.sh; do
    if [ ! -x "$PROJECT_DIR/$f" ]; then
      echo "  Not executable: $f"
      bad=1
    fi
  done
  [ "$bad" -eq 0 ]
}

test_scripts_parse() {
  local bad=0
  for f in scripts/invoke-acpx.sh scripts/run-parallel-acpx.sh scripts/debate-setup.sh scripts/create-links.sh; do
    if ! bash -n "$PROJECT_DIR/$f" 2>/dev/null; then
      echo "  Syntax error: $f"
      bad=1
    fi
  done
  [ "$bad" -eq 0 ]
}

test_skeptic_bodies_single_source() {
  # The Fable/Opus skeptic prompt bodies must live only in scripts/reviewer-prompts.md,
  # not inline in any command file (guards against the cross-file drift we deduped).
  local found
  found=$(grep -rl "Take your time and reason deeply\|Work the bounded checklist below" \
    "$PROJECT_DIR/commands" 2>/dev/null || true)
  [ -z "$found" ] || { echo "  Skeptic body inlined in: $found (should reference reviewer-prompts.md)"; return 1; }
}

test_gitignore_updated() {
  grep -q "^\.tmp/" "$PROJECT_DIR/.gitignore" || return 1
}

test_claude_delivery_is_file_based() {
  # v2.6.0: Claude teammates must deliver to <WORK_DIR>/claude-<persona>-r<N>-output.md,
  # not depend on the mailbox. Guard the file-delivery contract in both command files.
  local bad=0
  for f in commands/all.md commands/claude-review.md; do
    grep -q "output.md" "$PROJECT_DIR/$f" || { echo "  $f: no output-file delivery reference"; bad=1; }
  done
  # The old lossy claim ("SendMessage is the ONLY way your review reaches") must be gone.
  local stale
  stale=$(grep -rl "SendMessage is the ONLY way" "$PROJECT_DIR/commands" 2>/dev/null || true)
  [ -z "$stale" ] || { echo "  stale mailbox-only delivery claim in: $stale"; bad=1; }
  [ "$bad" -eq 0 ]
}

test_version_consistent() {
  local pv mv
  pv=$(jq -r '.version' "$PROJECT_DIR/.claude-plugin/plugin.json")
  mv=$(jq -r '.plugins[0].version' "$PROJECT_DIR/.claude-plugin/marketplace.json")
  [ "$pv" = "$mv" ] || { echo "  plugin.json=$pv marketplace.json=$mv"; return 1; }
}

# --- Run ---

echo ""
echo "=== Reference integrity tests ==="
echo ""

run_test "no old invoke script references" test_no_old_invoke_refs
run_test "no old parallel runner references" test_no_old_parallel_refs
run_test "no old config file references" test_no_old_config_refs
run_test "no old command references" test_no_old_command_refs_in_active_files
run_test "no probe-model references" test_no_probe_model_refs
run_test "no old work dir paths" test_no_old_work_dir_in_active_files
run_test "deleted files gone" test_deleted_files_dont_exist
run_test "new files exist" test_new_files_exist
run_test "new scripts executable" test_new_scripts_executable
run_test "all scripts parse" test_scripts_parse
run_test "skeptic bodies single-source" test_skeptic_bodies_single_source
run_test "claude delivery is file-based" test_claude_delivery_is_file_based
run_test ".gitignore updated" test_gitignore_updated
run_test "version consistent" test_version_consistent

echo ""
echo "=== Results: $PASS passed, $FAIL failed ($(( PASS + FAIL )) total) ==="

[ "$FAIL" -eq 0 ]

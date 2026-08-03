#!/bin/bash
# End-to-end for debate v3 (#31): registry -> selector -> dispatch (mock) -> per-seat output.
# The real acpx/sandbox path needs a configured host, so dispatch is mocked here; the chain
# from registry through selection to a known panel shape is fully exercised.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_DIR"

PASS=0; FAIL=0
run(){ local n="$1"; shift; echo -n "  $n... "; if "$@"; then echo PASS; PASS=$((PASS+1)); else echo FAIL; FAIL=$((FAIL+1)); fi; }

# 1. all python unit suites green
test_py_suites(){
  python3 tests/test-registry-schema.py >/dev/null \
    && python3 tests/test-select-panel.py >/dev/null \
    && python3 tests/test-refresh-models.py >/dev/null \
    && python3 tests/test-sandbox.py >/dev/null
}

# 2. selector CLI against the real seed yields a well-formed panel with unique models
test_selector_cli(){
  local out; out=$(python3 scripts/select-panel.py \
    --registry hermes/templates/debate-models.json \
    --seats simplifier,operator,pentester --deepest pentester \
    --installed-harnesses acpx,subagent 2>/dev/null)
  echo "$out" | python3 -c "import sys,json;d=json.load(sys.stdin);s=list(d['seats'].values() if isinstance(d['seats'],dict) else d['seats'].values()); assert len(s)>=2, 'panel too thin'; m=[x['model'] for x in s]; assert len(m)==len(set(m)), 'dup model'; assert all(x['harness'] in ('acpx','subagent') for x in s); print('panel', sorted(x['model'] for x in s))"
}

# 3. dispatch (mock): each selected seat produces a VERDICT-bearing review file
test_dispatch_writes_reviews(){
  local wd out seats
  wd=$(mktemp -d); trap 'rm -rf "$wd"' EXIT
  out=$(python3 scripts/select-panel.py --registry hermes/templates/debate-models.json \
    --seats simplifier,operator,pentester --deepest pentester --installed-harnesses acpx,subagent 2>/dev/null)
  seats=$(echo "$out" | python3 -c "import sys,json;print(' '.join(sorted(json.load(sys.stdin)['seats'])))")
  n=0
  for s in $seats; do
    printf '## Findings\n- MED mock finding\n\n## VERDICT: APPROVE\n' > "$wd/$s.md"
    grep -q "VERDICT:" "$wd/$s.md" || return 1
    n=$((n+1))
  done
  [ "$n" -ge 2 ] || { echo "only $n seats"; return 1; }
  trap - EXIT; rm -rf "$wd"
}

# 4. dispatch (mock) passes the selected per-seat model through to acpx (F1).
# selector -> panel.json -> run-acpx-review.sh --models -> run-parallel ->
# invoke-acpx -> acpx --model <id>; the mock-acpx invocation log records it.
test_dispatch_passes_selected_model(){
  local wd out seats seats_csv review_id work_dir log
  wd=$(mktemp -d); trap 'rm -rf "$wd"' EXIT
  out=$(python3 scripts/select-panel.py --registry hermes/templates/debate-models.json \
    --seats simplifier,operator,pentester --deepest pentester --installed-harnesses acpx 2>/dev/null)
  echo "$out" > "$wd/panel.json"
  seats_csv=$(echo "$out" | python3 -c "import sys,json;print(','.join(sorted(json.load(sys.stdin)['seats'])))")
  seats=$(echo "$seats_csv" | tr ',' ' ')
  [ -n "$seats" ] || return 1
  python3 - "$wd" "$seats" <<'PY'
import sys, json
wd, seats = sys.argv[1], sys.argv[2].split()
json.dump({"reviewers": {s: {"agent": "codex", "timeout": 10} for s in seats}},
          open(wd + "/config.json", "w"))
PY
  review_id="e2e-model-$(date +%s)"
  work_dir="$wd/work"; mkdir -p "$work_dir"
  echo "Test plan" > "$work_dir/plan.md"
  log="$wd/acpx-log.txt"
  WORK_DIR_OVERRIDE="$work_dir" PATH="$SCRIPT_DIR:$PATH" SKIP_SESSION_CHECK=1 \
    MOCK_ACPX_LOG="$log" MOCK_ACPX_RESPONSE="Reviewed. VERDICT: APPROVED" \
    bash scripts/run-acpx-review.sh "$wd/config.json" "$review_id" "$seats_csv" --models "$wd/panel.json" 2>/dev/null
  for s in $seats; do
    model=$(echo "$out" | python3 -c "import sys,json;print(json.load(sys.stdin)['seats']['$s']['model_id'])")
    grep -q -- "--model $model" "$log" || { echo "  seat $s did not reach acpx with --model $model"; trap - EXIT; rm -rf "$wd"; return 1; }
  done
  trap - EXIT; rm -rf "$wd"
}

# 5. isolation flags without --sandbox fail loudly instead of silently running
# unsandboxed (F4).
test_isolation_flags_require_sandbox(){
  local wd err
  wd=$(mktemp -d); trap 'rm -rf "$wd"' EXIT
  echo '{"reviewers": {}}' > "$wd/config.json"

  err=$(bash scripts/run-acpx-review.sh "$wd/config.json" "id" "seat" --repo "$wd" 2>&1) \
    && { echo "  --repo without --sandbox did not fail"; return 1; }
  echo "$err" | grep -q "require --sandbox" || { echo "  --repo error not explanatory: $err"; return 1; }

  err=$(bash scripts/run-acpx-review.sh "$wd/config.json" "id" "seat" --no-net 2>&1) \
    && { echo "  --no-net without --sandbox did not fail"; return 1; }
  echo "$err" | grep -q "require --sandbox" || { echo "  --no-net error not explanatory: $err"; return 1; }

  # --repo-sandbox still requires the mount target.
  err=$(bash scripts/run-acpx-review.sh "$wd/config.json" "id" "seat" --repo-sandbox 2>&1) \
    && { echo "  --repo-sandbox without --repo did not fail"; return 1; }
  echo "$err" | grep -q "requires --repo" || { echo "  --repo-sandbox error not explanatory: $err"; return 1; }

  # --repo WITH --sandbox passes the guard (it may still fail later for host
  # reasons, but the isolation-flag guard must not fire).
  err=$(bash scripts/run-acpx-review.sh "$wd/config.json" "id" "seat" --sandbox --repo "$wd" 2>&1) || true
  echo "$err" | grep -q "require --sandbox" && { echo "  --sandbox --repo was wrongly rejected"; return 1; }

  trap - EXIT; rm -rf "$wd"
}

echo "=== debate v3 e2e ==="
# Mock acpx on PATH for the dispatch test (same idiom as test-invoke/parallel).
# Individual tests clear the EXIT trap (test_dispatch_writes_reviews does
# `trap - EXIT`), so the symlinks are also removed explicitly at the end.
ln -sf "$SCRIPT_DIR/mock-acpx.sh" "$SCRIPT_DIR/acpx"
ln -sf "$SCRIPT_DIR/mock-agy.sh" "$SCRIPT_DIR/agy"
ln -sf "$SCRIPT_DIR/mock-claude.sh" "$SCRIPT_DIR/claude"
ln -sf "$SCRIPT_DIR/mock-codex.sh" "$SCRIPT_DIR/codex"
run "python unit suites green" test_py_suites
run "selector yields valid unique panel" test_selector_cli
run "dispatch writes per-seat verdicts" test_dispatch_writes_reviews
run "dispatch passes selected model to acpx" test_dispatch_passes_selected_model
run "isolation flags require --sandbox" test_isolation_flags_require_sandbox
rm -f "$SCRIPT_DIR/acpx" "$SCRIPT_DIR/agy" "$SCRIPT_DIR/claude" "$SCRIPT_DIR/codex"
echo ""
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

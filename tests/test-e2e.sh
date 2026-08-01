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

echo "=== debate v3 e2e ==="
run "python unit suites green" test_py_suites
run "selector yields valid unique panel" test_selector_cli
run "dispatch writes per-seat verdicts" test_dispatch_writes_reviews
echo ""
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

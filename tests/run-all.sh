#!/bin/bash
# Run all tests for the debate plugin.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "==============================="
echo "  debate plugin test suite"
echo "==============================="

run_suite() {
  local name="$1"
  local script="$2"
  echo ""
  if bash "$script"; then
    echo "  $name: passed."
  else
    echo "  $name: FAILED."
    return 1
  fi
}

SUITE_FAIL=0

run_suite "invoke-acpx" "$SCRIPT_DIR/test-invoke-acpx.sh" || SUITE_FAIL=$((SUITE_FAIL + 1))
run_suite "run-parallel-acpx" "$SCRIPT_DIR/test-parallel-acpx.sh" || SUITE_FAIL=$((SUITE_FAIL + 1))
run_suite "cleanup + record-round" "$SCRIPT_DIR/test-cleanup-and-record.sh" || SUITE_FAIL=$((SUITE_FAIL + 1))
run_suite "reference integrity" "$SCRIPT_DIR/test-references.sh" || SUITE_FAIL=$((SUITE_FAIL + 1))

echo ""
echo "==============================="
if [ "$SUITE_FAIL" -eq 0 ]; then
  echo "  All 4 suites passed."
else
  echo "  $SUITE_FAIL of 4 suite(s) FAILED."
fi
echo "==============================="

exit "$SUITE_FAIL"

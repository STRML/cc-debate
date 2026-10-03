#!/bin/bash
# Tests for `seat-report.sh --archive`: validating, sanitizing and archiving a panel report.
#
# Each test builds a throwaway world (a HOME, a repo with a review folder, a report) and runs the real script
# against it, so nothing here touches the user's ~/.acpx or a real review.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRIPT="$PROJECT_DIR/scripts/seat-report.sh"

PASS=0
FAIL=0
KEEP="$(mktemp -d)"
trap 'chmod -R u+rwx "$KEEP" 2>/dev/null || true; rm -rf "$KEEP"' EXIT

# Each test runs in a subshell so its HOME and variables never leak into the next.
run_test() {
  local name="$1"
  shift
  echo -n "  $name... "
  if ( "$@" ); then
    echo "PASS"
    PASS=$((PASS + 1))
  else
    echo "FAIL"
    FAIL=$((FAIL + 1))
  fi
}

# --- Helpers ---

# new_world: a HOME, a repo with .tmp/ai-review-ab12cd34 holding three review files and panel.json, and a base report.
new_world() {
  W="$(mktemp -d "$KEEP/world.XXXXXX")"
  export HOME="$W/home"
  ROOT="$W/repo"
  REVIEW="$ROOT/.tmp/ai-review-ab12cd34"
  ARCHIVES="$HOME/.acpx/debate-reports"
  mkdir -p "$HOME" "$REVIEW"
  local seat
  for seat in executor auditor claude-opus-skeptic-r1; do
    printf '# review\n\nfound things\n' > "$REVIEW/$seat-output.md"
  done
  cat > "$REVIEW/panel.json" << 'JSON'
{"seats": {
  "executor":    {"harness": "acpx", "model_id": "gpt-6-luna",     "effective_effort": "medium", "effective_cost": 0.0135},
  "auditor":     {"harness": "acpx", "model_id": "gpt-6-sol",      "effective_effort": "high",   "effective_cost": 0.415},
  "antigravity": {"harness": "acpx", "model_id": "gemini-3.1-pro", "effective_effort": "high",   "effective_cost": 0.34}
}}
JSON
  write_report ""
}

# write_report '<python statements acting on r>' [path]: writes the base panel report after running the statements.
write_report() {
  local mutate="${1:-}" out="${2:-$REVIEW/report.json}"
  ROOT="$ROOT" python3 - "$out" "$mutate" << 'PY'
import json, os, sys

root = os.environ["ROOT"]
r = {
    "stage": "report",
    "diff": {"filesChanged": 2, "linesAdded": 10, "linesRemoved": 3, "docsOnly": False, "summary": "two files"},
    "seatsRun": ["executor", "auditor", "claude-opus-skeptic-r1"],
    "seatsFailed": ["antigravity"],
    "seatsNotConfigured": ["operator"],
    "seatsNotTranscribed": [],
    "seatsSkipped": [{"seat": "pentester", "why": "no security-sensitive change"}],
    "counts": {"raw": 3, "locations": 2, "distinct": 2, "survived": 2, "refuted": 1, "unverified": 1},
    "findings": [
        {"file": root + "/src/a.ts", "line": 12, "severity": "major", "claim": "Reads before it writes",
         "failure": "The old value is returned", "fix": "Write first", "foundBy": ["executor", "auditor"]},
        {"file": "src/b.ts", "line": 0, "severity": "nit", "claim": "Naming", "failure": "It confuses readers",
         "foundBy": ["claude-opus-skeptic-r1"]},
    ],
    "refuted": [
        {"file": "src/c.ts", "line": 3, "severity": "minor", "claim": "Leak", "failure": "Memory grows",
         "foundBy": ["auditor"], "why": "It is freed on exit"},
    ],
    "unverified": [
        {"file": "src/d.ts", "line": 9, "severity": "minor", "claim": "Race", "failure": "Double write",
         "foundBy": ["executor"]},
    ],
}
exec(sys.argv[2])
with open(sys.argv[1], "w") as fh:
    json.dump(r, fh)
PY
}

# run_archive [round]: runs the script on the world's report; sets STATUS (exit code) and OUT (its output).
run_archive() {
  STATUS=0
  OUT="$(bash "$SCRIPT" --archive "$REVIEW/report.json" --round "${1:-1}" 2>&1)" || STATUS=$?
}

# check_json <file> '<python expression over a, the parsed archive>': succeeds when the expression is true.
check_json() {
  python3 - "$1" "$2" << 'PY'
import json, sys

a = json.load(open(sys.argv[1]))
sys.exit(0 if eval(sys.argv[2]) else 1)
PY
}

# --- Tests: saving, seat state, seat meta ---

test_saves_an_archive() {
  new_world
  run_archive 1
  [ "$STATUS" -eq 0 ] || { echo "$OUT"; return 1; }
  local file="$ARCHIVES/ab12cd34-r1.json"
  [ -f "$file" ] || { echo "  no archive at $file"; return 1; }
  check_json "$file" "a['v'] == 1 and a['meta']['id'] == 'ab12cd34' and a['meta']['round'] == 1 and a['meta']['root'] == '$ROOT'" || return 1
  check_json "$file" "len(a['report']['findings']) == 2 and len(a['report']['refuted']) == 1 and len(a['report']['unverified']) == 1" || return 1
}

test_seat_states_follow_the_report_lists() {
  new_world
  run_archive 1
  [ "$STATUS" -eq 0 ] || { echo "$OUT"; return 1; }
  check_json "$ARCHIVES/ab12cd34-r1.json" "a['seatState'] == {'antigravity': 'failed', 'auditor': 'reported', 'claude-opus-skeptic-r1': 'reported', 'executor': 'reported', 'operator': 'not-configured'}"
}

test_seat_meta_comes_from_panel_json() {
  new_world
  run_archive 1
  [ "$STATUS" -eq 0 ] || { echo "$OUT"; return 1; }
  check_json "$ARCHIVES/ab12cd34-r1.json" "a['seatMeta']['executor'] == {'model': 'gpt-6-luna', 'effort': 'medium', 'est_cost': 0.0135}" || return 1
  check_json "$ARCHIVES/ab12cd34-r1.json" "a['seatMeta']['claude-opus-skeptic-r1'] == {'model': None, 'effort': None, 'est_cost': None}"
}

test_a_seat_with_no_review_file_is_unreadable() {
  new_world
  rm "$REVIEW/auditor-output.md"
  run_archive 1
  [ "$STATUS" -eq 0 ] || { echo "$OUT"; return 1; }
  check_json "$ARCHIVES/ab12cd34-r1.json" "a['seatState']['auditor'] == 'unreadable' and a['seatState']['executor'] == 'reported'"
}

test_an_empty_review_file_is_unreadable() {
  new_world
  : > "$REVIEW/auditor-output.md"
  run_archive 1
  [ "$STATUS" -eq 0 ] || { echo "$OUT"; return 1; }
  check_json "$ARCHIVES/ab12cd34-r1.json" "a['seatState']['auditor'] == 'unreadable'"
}

test_a_seat_not_transcribed_is_unreadable() {
  new_world
  write_report "r['seatsNotTranscribed'] = ['auditor']"
  run_archive 1
  [ "$STATUS" -eq 0 ] || { echo "$OUT"; return 1; }
  check_json "$ARCHIVES/ab12cd34-r1.json" "a['seatState']['auditor'] == 'unreadable'"
}

test_failed_and_unstarted_seats_keep_their_state_without_a_review_file() {
  new_world
  rm "$REVIEW/auditor-output.md"
  write_report "r['seatsFailed'] = ['auditor', 'antigravity']"
  run_archive 1
  [ "$STATUS" -eq 0 ] || { echo "$OUT"; return 1; }
  check_json "$ARCHIVES/ab12cd34-r1.json" "a['seatState']['auditor'] == 'failed' and a['seatState']['antigravity'] == 'failed' and a['seatState']['operator'] == 'not-configured'"
}

test_running_again_rewrites_the_same_file() {
  new_world
  run_archive 1
  run_archive 1
  [ "$STATUS" -eq 0 ] || { echo "$OUT"; return 1; }
  [ "$(ls -A "$ARCHIVES" | wc -l | tr -d ' ')" = "1" ]
}

# --- Tests: rejections (nothing is written) ---

# reject_case '<python statements>' '<text the message must contain>': exits non-zero, says why, writes nothing.
reject_case() {
  new_world
  write_report "$1"
  run_archive 1
  [ "$STATUS" -ne 0 ] || { echo "  expected a rejection"; return 1; }
  echo "$OUT" | grep -q -- "$2" || { echo "  message lacked '$2': $OUT"; return 1; }
  [ ! -d "$ARCHIVES" ] || [ -z "$(ls -A "$ARCHIVES")" ] || { echo "  something was written"; return 1; }
}

# reject_round '<round>': a round the writer must refuse.
reject_round() {
  new_world
  STATUS=0
  OUT="$(bash "$SCRIPT" --archive "$REVIEW/report.json" --round "$1" 2>&1)" || STATUS=$?
  [ "$STATUS" -ne 0 ] || { echo "  expected a rejection"; return 1; }
  echo "$OUT" | grep -q -- "--round" || { echo "  message lacked --round: $OUT"; return 1; }
  [ ! -d "$ARCHIVES" ] || [ -z "$(ls -A "$ARCHIVES")" ] || { echo "  something was written"; return 1; }
}

# --- Run ---

echo ""
echo "=== seat-report --archive tests ==="
echo ""

run_test "saves an archive" test_saves_an_archive
run_test "seat states follow the report lists" test_seat_states_follow_the_report_lists
run_test "seat meta comes from panel.json" test_seat_meta_comes_from_panel_json
run_test "a seat with no review file is unreadable" test_a_seat_with_no_review_file_is_unreadable
run_test "an empty review file is unreadable" test_an_empty_review_file_is_unreadable
run_test "a seat not transcribed is unreadable" test_a_seat_not_transcribed_is_unreadable
run_test "failed and unstarted seats keep their state" test_failed_and_unstarted_seats_keep_their_state_without_a_review_file
run_test "running again rewrites the same file" test_running_again_rewrites_the_same_file
run_test "rejects counts that disagree with the arrays" reject_case "r['counts']['survived'] = 5" "counts.survived"
run_test "rejects an array of more than 200 entries" reject_case "r['unverified'] = [dict(r['unverified'][0]) for _ in range(201)]; r['counts']['unverified'] = 201" "more than 200"
run_test "rejects a foundBy outside seatsRun" reject_case "r['findings'][0]['foundBy'] = ['antigravity']" "foundBy"
run_test "rejects a foundBy that is not a list" reject_case "r['findings'][0]['foundBy'] = 'executor'" "foundBy"
run_test "rejects a traversal seat name" reject_case "r['seatsRun'].append('../x')" "seat name"
run_test "rejects a __proto__ seat name" reject_case "r['seatsFailed'].append('__proto__')" "seat name"
run_test "rejects a seat name with .." reject_case "r['seatsFailed'].append('a..b')" "seat name"
run_test "rejects NaN" reject_case "r['counts']['raw'] = float('nan')" "not valid JSON"
run_test "rejects a boolean line" reject_case "r['findings'][0]['line'] = True" "line"
run_test "rejects a negative line" reject_case "r['findings'][0]['line'] = -1" "line"
run_test "rejects an unknown severity" reject_case "r['findings'][0]['severity'] = 'urgent'" "severity"
run_test "rejects a finding with no claim" reject_case "del r['findings'][0]['claim']" "claim"
run_test "rejects a report that is not an object" reject_case "r = []" "not a JSON object"
run_test "rejects a round that is not a number" reject_round "abc"
run_test "rejects round 0" reject_round "0"
run_test "rejects round 1000" reject_round "1000"
run_test "rejects a traversal round" reject_round "1/../../x"

echo ""
echo "=== Results: $PASS passed, $FAIL failed ($(( PASS + FAIL )) total) ==="

[ "$FAIL" -eq 0 ]

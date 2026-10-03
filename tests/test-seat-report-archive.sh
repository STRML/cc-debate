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

# run_archive_timed: like run_archive, but gives up after 10 s (a script that blocks on a special file must not hang the suite).
run_archive_timed() {
  STATUS=0
  OUT="$(python3 - "$SCRIPT" "$REVIEW/report.json" << 'PY' 2>&1
import subprocess, sys

try:
    done = subprocess.run(["bash", sys.argv[1], "--archive", sys.argv[2], "--round", "1"], capture_output=True, text=True, timeout=10)
    print((done.stdout + done.stderr).strip())
    sys.exit(done.returncode)
except subprocess.TimeoutExpired:
    print("timed out: the script blocked")
    sys.exit(124)
PY
)" || STATUS=$?
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

# --- Tests: sanitizing ---

# sanitize_case '<python statements>' '<python expression over a, the saved archive>': saved, and the expression holds.
sanitize_case() {
  new_world
  write_report "$1"
  run_archive 1
  [ "$STATUS" -eq 0 ] || { echo "$OUT"; return 1; }
  check_json "$ARCHIVES/ab12cd34-r1.json" "$2" || { echo "  archive did not satisfy: $2"; return 1; }
}

test_hostile_panel_json_is_capped_and_type_checked() {
  new_world
  python3 -c 'import json,sys; json.dump({"seats": {
    "executor": {"model_id": "gpt‮" + "m" * 100, "effective_effort": "e" * 40, "effective_cost": "free"},
    "auditor": {"model_id": "ok", "effective_effort": "high", "effective_cost": -1},
    "antigravity": {"model_id": "g", "effective_effort": "high", "effective_cost": 0.123456789}}}, open(sys.argv[1], "w"))' "$REVIEW/panel.json"
  run_archive 1
  [ "$STATUS" -eq 0 ] || { echo "$OUT"; return 1; }
  check_json "$ARCHIVES/ab12cd34-r1.json" "len(a['seatMeta']['executor']['model']) == 64 and '‮' not in a['seatMeta']['executor']['model'] and len(a['seatMeta']['executor']['effort']) == 16 and a['seatMeta']['executor']['est_cost'] is None" || return 1
  check_json "$ARCHIVES/ab12cd34-r1.json" "a['seatMeta']['auditor']['est_cost'] is None and a['seatMeta']['antigravity']['est_cost'] == 0.1235"
}

# --- Tests: location guards and archive hygiene ---

# mode_of <path>: the permission bits, in octal, as python prints them.
mode_of() {
  python3 -c 'import os,sys; print(oct(os.stat(sys.argv[1]).st_mode & 0o777))' "$1"
}

test_refuses_a_report_outside_a_review_folder() {
  new_world
  mkdir -p "$ROOT/.tmp/other"
  cp "$REVIEW/report.json" "$ROOT/.tmp/other/report.json"
  STATUS=0
  OUT="$(bash "$SCRIPT" --archive "$ROOT/.tmp/other/report.json" --round 1 2>&1)" || STATUS=$?
  [ "$STATUS" -ne 0 ] && echo "$OUT" | grep -q "ai-review-" && [ ! -d "$ARCHIVES" ]
}

test_refuses_a_review_folder_not_inside_dot_tmp() {
  new_world
  mkdir -p "$ROOT/ai-review-ab12cd34"
  cp "$REVIEW/report.json" "$ROOT/ai-review-ab12cd34/report.json"
  STATUS=0
  OUT="$(bash "$SCRIPT" --archive "$ROOT/ai-review-ab12cd34/report.json" --round 1 2>&1)" || STATUS=$?
  [ "$STATUS" -ne 0 ] && echo "$OUT" | grep -q "ai-review-" && [ ! -d "$ARCHIVES" ]
}

test_refuses_a_symlinked_report() {
  new_world
  mv "$REVIEW/report.json" "$W/elsewhere.json"
  ln -s "$W/elsewhere.json" "$REVIEW/report.json"
  run_archive 1
  [ "$STATUS" -ne 0 ] && echo "$OUT" | grep -q "symlink" && [ ! -d "$ARCHIVES" ]
}

test_refuses_a_symlinked_review_folder() {
  new_world
  ln -s "$REVIEW" "$ROOT/.tmp/ai-review-cafe1234"
  STATUS=0
  OUT="$(bash "$SCRIPT" --archive "$ROOT/.tmp/ai-review-cafe1234/report.json" --round 1 2>&1)" || STATUS=$?
  [ "$STATUS" -ne 0 ] && echo "$OUT" | grep -q "symlink or not yours" && [ ! -d "$ARCHIVES" ]
}

test_refuses_a_report_over_1_mb() {
  new_world
  write_report "r['pad'] = 'x' * 1100000"
  run_archive 1
  [ "$STATUS" -ne 0 ] && echo "$OUT" | grep -q "1 MB" && [ ! -d "$ARCHIVES" ]
}

test_a_symlinked_review_file_is_unreadable() {
  new_world
  rm "$REVIEW/auditor-output.md"
  ln -s "$REVIEW/executor-output.md" "$REVIEW/auditor-output.md"
  run_archive 1
  [ "$STATUS" -eq 0 ] || { echo "$OUT"; return 1; }
  check_json "$ARCHIVES/ab12cd34-r1.json" "a['seatState']['auditor'] == 'unreadable'"
}

test_the_archive_is_private() {
  new_world
  run_archive 1
  [ "$STATUS" -eq 0 ] || { echo "$OUT"; return 1; }
  [ "$(mode_of "$ARCHIVES")" = "0o700" ] && [ "$(mode_of "$ARCHIVES/ab12cd34-r1.json")" = "0o600" ]
}

test_a_symlinked_archive_folder_is_refused() {
  new_world
  mkdir -p "$HOME/.acpx" "$W/elsewhere"
  ln -s "$W/elsewhere" "$ARCHIVES"
  run_archive 1
  [ "$STATUS" -ne 0 ] && echo "$OUT" | grep -q "symlink" && [ -z "$(ls -A "$W/elsewhere")" ]
}

test_pruning_keeps_300_and_only_touches_archives() {
  new_world
  mkdir -p "$ARCHIVES"
  python3 - "$ARCHIVES" << 'PY'
import os, sys

dest = sys.argv[1]
for i in range(305):
    path = os.path.join(dest, "%08x-r1.json" % (i + 1))
    open(path, "w").close()
    os.utime(path, (1000 + i, 1000 + i))
os.symlink("/dev/null", os.path.join(dest, "00000000-r1.json"))
os.utime(os.path.join(dest, "00000000-r1.json"), (1, 1), follow_symlinks=False)
open(os.path.join(dest, "notes.txt"), "w").close()
PY
  run_archive 1
  [ "$STATUS" -eq 0 ] || { echo "$OUT"; return 1; }
  local kept
  kept="$(find "$ARCHIVES" -maxdepth 1 -type f -name '*-r1.json' | wc -l | tr -d ' ')"
  [ "$kept" = "300" ] || { echo "  kept $kept archives"; return 1; }
  [ -f "$ARCHIVES/ab12cd34-r1.json" ] && [ -L "$ARCHIVES/00000000-r1.json" ] && [ -f "$ARCHIVES/notes.txt" ]
}

test_a_failed_write_names_the_entry_to_add() {
  [ "$(id -u)" -ne 0 ] || return 0
  new_world
  mkdir -p "$HOME/.acpx"
  chmod 500 "$HOME/.acpx"
  run_archive 1
  chmod 700 "$HOME/.acpx"
  [ "$STATUS" -ne 0 ] && echo "$OUT" | grep -q 'Write(~/.acpx/\*\*)'
}

test_seat_meta_follows_a_delivery_stem_to_its_manifest_seat() {
  new_world
  printf '# review\n' > "$REVIEW/executor-r1-output.md"
  write_report "r['seatsRun'] = ['executor-r1' if s == 'executor' else s for s in r['seatsRun']]
for key in ('findings', 'refuted', 'unverified'):
    for f in r[key]:
        f['foundBy'] = ['executor-r1' if s == 'executor' else s for s in f['foundBy']]"
  run_archive 1
  [ "$STATUS" -eq 0 ] || { echo "$OUT"; return 1; }
  check_json "$ARCHIVES/ab12cd34-r1.json" "a['seatMeta']['executor-r1'] == {'model': 'gpt-6-luna', 'effort': 'medium', 'est_cost': 0.0135}" || return 1
  check_json "$ARCHIVES/ab12cd34-r1.json" "a['seatMeta']['claude-opus-skeptic-r1'] == {'model': None, 'effort': None, 'est_cost': None}"
}

test_a_named_pipe_as_the_report_is_refused_not_waited_on() {
  new_world
  rm "$REVIEW/report.json"
  mkfifo "$REVIEW/report.json"
  run_archive_timed
  [ "$STATUS" -ne 0 ] && [ "$STATUS" -ne 124 ] && echo "$OUT" | grep -q "cannot read report.json" && [ ! -d "$ARCHIVES" ]
}

test_a_named_pipe_as_panel_json_leaves_the_meta_empty() {
  new_world
  rm "$REVIEW/panel.json"
  mkfifo "$REVIEW/panel.json"
  run_archive_timed
  [ "$STATUS" -eq 0 ] || { echo "status $STATUS: $OUT"; return 1; }
  check_json "$ARCHIVES/ab12cd34-r1.json" "a['seatMeta']['executor'] == {'model': None, 'effort': None, 'est_cost': None}"
}

test_a_named_pipe_as_a_review_file_is_unreadable() {
  new_world
  rm "$REVIEW/auditor-output.md"
  mkfifo "$REVIEW/auditor-output.md"
  run_archive_timed
  [ "$STATUS" -eq 0 ] || { echo "status $STATUS: $OUT"; return 1; }
  check_json "$ARCHIVES/ab12cd34-r1.json" "a['seatState']['auditor'] == 'unreadable'"
}

test_the_archive_folder_is_fsynced_after_the_rename() {
  new_world
  python3 - "$PROJECT_DIR/scripts/seat-archive.py" "$ARCHIVES" << 'PY'
import os, sys

# Load the writer's functions without running its main(), and record which files and folders get fsynced.
source = open(sys.argv[1]).read().replace("\nmain(sys.argv[1:])\n", "\n")
namespace = {"__name__": "seat_archive"}
exec(compile(source, sys.argv[1], "exec"), namespace)

synced = []
real_fsync = os.fsync
os.fsync = lambda fd: (synced.append(os.fstat(fd).st_ino), real_fsync(fd))[1]

namespace["write_archive"](sys.argv[2], "ab12cd34-r1.json", {"v": 1})
sys.exit(0 if os.stat(sys.argv[2]).st_ino in synced else 1)
PY
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
run_test "rejects more than 200 skipped seats" reject_case "r['seatsSkipped'] = [{'seat': 's%d' % i, 'why': 'x'} for i in range(201)]" "more than 200"
run_test "rejects more than 200 seats that ran" reject_case "r['seatsRun'] = r['seatsRun'] + ['s%d' % i for i in range(198)]" "more than 200"
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
run_test "makes an absolute path under the root relative" sanitize_case "" "a['report']['findings'][0]['file'] == 'src/a.ts'"
run_test "marks an absolute path outside the root" sanitize_case "r['findings'][0]['file'] = '/etc/passwd'" "a['report']['findings'][0]['file'] == '(outside repo)'"
run_test "normalizes ../ before the root test" sanitize_case "r['findings'][0]['file'] = root + '/../../etc/x'" "a['report']['findings'][0]['file'] == '(outside repo)'"
run_test "does not take a sibling folder for the root" sanitize_case "r['findings'][0]['file'] = root + '-evil/x'" "a['report']['findings'][0]['file'] == '(outside repo)'"
run_test "marks a relative path that climbs" sanitize_case "r['findings'][0]['file'] = '../../x'" "a['report']['findings'][0]['file'] == '(unsafe path)'"
run_test "labels an empty file" sanitize_case "r['findings'][0]['file'] = ''" "a['report']['findings'][0]['file'] == '(unknown file)'"
run_test "strips bidi, zero-width, surrogate and separator characters" sanitize_case 'r["findings"][0]["claim"] = "a‮b​c\ud800d e\x85f"' "a['report']['findings'][0]['claim'] == 'abcdef'"
run_test "keeps newline and tab" sanitize_case 'r["findings"][0]["failure"] = "one\ntwo\tthree"' "a['report']['findings'][0]['failure'] == 'one\ntwo\tthree'"
run_test "caps text at 2000 characters" sanitize_case "r['findings'][0]['claim'] = 'x' * 2500" "len(a['report']['findings'][0]['claim']) == 2000"
run_test "caps text at 2000 code points, not bytes" sanitize_case "r['findings'][0]['claim'] = '\U0001F600' * 2500" "len(a['report']['findings'][0]['claim']) == 2000"
run_test "keeps one level of scalar diff fields" sanitize_case "r['diff'] = {'summary': 'ok‮', 'filesChanged': 2, 'docsOnly': True, 'nested': {'a': 1}}" "a['report']['diff'] == {'summary': 'ok', 'filesChanged': 2, 'docsOnly': True}"
run_test "accepts a null diff" sanitize_case "r['diff'] = None" "a['report']['diff'] is None"
run_test "accepts a nit, line 0 and no fix" sanitize_case "" "a['report']['findings'][1]['severity'] == 'nit' and a['report']['findings'][1]['line'] == 0 and 'fix' not in a['report']['findings'][1]"
run_test "keeps skipped seats as objects" sanitize_case "" "a['report']['seatsSkipped'] == [{'seat': 'pentester', 'why': 'no security-sensitive change'}]"
run_test "keeps the refuted why" sanitize_case "" "a['report']['refuted'][0]['why'] == 'It is freed on exit'"
run_test "keeps the counts" sanitize_case "" "a['report']['counts']['survived'] == 2 and a['report']['counts']['unverified'] == 1"
run_test "caps and type-checks panel.json fields" test_hostile_panel_json_is_capped_and_type_checked
run_test "a delivery stem finds its manifest seat's model and cost" test_seat_meta_follows_a_delivery_stem_to_its_manifest_seat
run_test "refuses a report outside a review folder" test_refuses_a_report_outside_a_review_folder
run_test "refuses a review folder not inside .tmp" test_refuses_a_review_folder_not_inside_dot_tmp
run_test "refuses a symlinked report" test_refuses_a_symlinked_report
run_test "refuses a symlinked review folder" test_refuses_a_symlinked_review_folder
run_test "refuses a report over 1 MB" test_refuses_a_report_over_1_mb
run_test "a symlinked review file is unreadable" test_a_symlinked_review_file_is_unreadable
run_test "the archive is 0600 in a 0700 folder" test_the_archive_is_private
run_test "a symlinked archive folder is refused" test_a_symlinked_archive_folder_is_refused
run_test "pruning keeps 300 and only touches archives" test_pruning_keeps_300_and_only_touches_archives
run_test "a failed write names the entry to add" test_a_failed_write_names_the_entry_to_add
run_test "the archive folder is fsynced after the rename" test_the_archive_folder_is_fsynced_after_the_rename
run_test "a named pipe as the report is refused, not waited on" test_a_named_pipe_as_the_report_is_refused_not_waited_on
run_test "a named pipe as panel.json leaves the meta empty" test_a_named_pipe_as_panel_json_leaves_the_meta_empty
run_test "a named pipe as a review file is unreadable" test_a_named_pipe_as_a_review_file_is_unreadable

echo ""
echo "=== Results: $PASS passed, $FAIL failed ($(( PASS + FAIL )) total) ==="

[ "$FAIL" -eq 0 ]

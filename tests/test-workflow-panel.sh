#!/bin/bash
# Tests for workflows/review-panel.js — the workflow-driven panel.
#
# There is no way to exercise a workflow end to end from here: it needs the
# Claude Code harness to spawn agents. So these check the things that can be
# checked statically and that would actually break a run — the script parses,
# its declared phases match the phases it starts, its seats exist in the shipped
# sample config, and no agent() call has quietly become a reviewer seat.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
WF="$PROJECT_DIR/workflows/review-panel.js"
SAMPLE="$PROJECT_DIR/debate-acpx.sample.json"

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

have_node() { command -v node > /dev/null 2>&1; }

test_workflow_exists() {
  [ -f "$WF" ]
}

# A syntax error here is invisible until someone spends a panel run finding it.
test_workflow_parses() {
  if ! have_node; then
    echo -n "(no node, skipped) "
    return 0
  fi
  node --check "$WF" > /dev/null 2>&1
}

# meta.phases is what the progress display groups by. A phase() call with no
# matching meta entry gets its own orphan box, which looks like a bug to the user.
test_declared_phases_match_started_phases() {
  local declared started
  declared=$(grep -o "title: '[^']*'" "$WF" | sed "s/title: '//;s/'//" | sort -u)
  started=$(grep -o "phase('[^']*')" "$WF" | sed "s/phase('//;s/')//" | sort -u)
  [ -n "$declared" ] || return 1
  [ "$declared" = "$started" ]
}

# Every seat the lens table can pick must exist in the config the plugin ships,
# or the runner silently skips it and the panel shrinks without saying so.
test_lens_seats_exist_in_sample_config() {
  local seats seat
  seats=$(grep -o "seat: '[^']*'" "$WF" | sed "s/seat: '//;s/'//")
  [ -n "$seats" ] || return 1
  for seat in $seats; do
    jq -e --arg s "$seat" '.reviewers[$s]' "$SAMPLE" > /dev/null 2>&1 || {
      echo -n "($seat missing from sample) "
      return 1
    }
  done
}

# The whole point of the panel is that its reviewers are not Claude. agent() in a
# workflow spawns Claude subagents, so the review itself must go through the
# runner. If this ever fails, someone has turned the panel into one vendor.
test_reviews_still_go_through_the_runner() {
  grep -q "run-parallel-acpx.sh" "$WF"
}

# Dedupe is the reason this workflow exists. Doing it in an agent would put the
# step that scales worst back into a model's context.
test_dedupe_is_code_not_an_agent() {
  # The merge loop must be plain JS: a Map keyed by file:line, no agent() between
  # the extract phase and the verify phase.
  grep -q "const merged = new Map()" "$WF" || return 1
  local between
  between=$(sed -n '/const merged = new Map()/,/const unique = /p' "$WF")
  case "$between" in *"await agent("*) return 1 ;; esac
  return 0
}

# A docs-only diff must not buy the full panel. This is the cheap end of the
# scaling rule and the easiest to regress.
test_docs_only_diff_picks_one_seat() {
  if ! have_node; then
    echo -n "(no node, skipped) "
    return 0
  fi
  node -e '
    const fs = require("fs");
    const src = fs.readFileSync(process.argv[1], "utf8");
    // Lift the lens table and the picker out of the script without running the
    // harness-dependent body.
    const lenses = src.slice(src.indexOf("const LENSES = ["), src.indexOf("// A docs-only change"));
    const picker = src.slice(src.indexOf("function pickSeats"), src.indexOf("const DIFF_SHAPE"));
    const pickSeats = new Function(lenses + picker + "; return pickSeats;")();

    const docs = { filesChanged: 2, linesAdded: 10, linesRemoved: 1, docsOnly: true,
                   securitySensitive: false, touchesFilesystem: false, addsAbstraction: false };
    const small = { filesChanged: 1, linesAdded: 5, linesRemoved: 2, docsOnly: false,
                    securitySensitive: false, touchesFilesystem: false, addsAbstraction: false };
    const wide = { filesChanged: 30, linesAdded: 900, linesRemoved: 100, docsOnly: false,
                   securitySensitive: true, touchesFilesystem: true, addsAbstraction: true };

    const d = pickSeats(docs), s = pickSeats(small), w = pickSeats(wide);
    if (d.length !== 1) { console.error("docs-only picked " + d.length + ": " + d); process.exit(1); }
    if (s.length >= w.length) { console.error("small " + s.length + " not fewer than wide " + w.length); process.exit(1); }
    if (!w.includes("pentester")) { console.error("security diff did not earn the pentester"); process.exit(1); }
    if (s.includes("pentester")) { console.error("trivial diff bought the pentester"); process.exit(1); }
  ' "$WF" 2>&1
}

# Every path interpolated into a command must go through shellArg. A bare ${VAR} splits
# on spaces, and a `~/...` default that is merely quoted is never expanded — either way
# the panel dies before a seat runs. Catching this by eye failed once already: the
# comment above shellArg claimed every path was quoted while two were not.
test_interpolated_paths_are_escaped() {
  local line
  # Any line that runs a command and mentions a path variable must use shellArg for it.
  while IFS= read -r line; do
    case "$line" in
      *'${WORK_DIR}'*|*'${REPO}'*|*'${SCRIPTS}'*|*'${CONFIG}'*)
        case "$line" in
          *'shellArg('*) ;;
          *) echo -n "(unescaped path: ${line#"${line%%[![:space:]]*}"}) "; return 1 ;;
        esac
        ;;
    esac
  done < <(grep -nE "^\s+(cd |bash |awk |sh )" "$WF")
  # And the runner command specifically must escape all four of its arguments.
  local cmd
  cmd=$(grep 'run-parallel-acpx.sh' "$WF" | grep 'bash ')
  [ -n "$cmd" ] || return 1
  case "$cmd" in
    *'shellArg(REPO)'*) ;;
    *) echo -n "(repo not escaped) "; return 1 ;;
  esac
  case "$cmd" in
    *'shellArg(CONFIG)'*) ;;
    *) echo -n "(config not escaped) "; return 1 ;;
  esac
  return 0
}

# shellArg has to survive the three cases that actually break a shell: a space, a
# single quote, and a leading tilde that must still expand.
test_shellarg_handles_hostile_paths() {
  if ! have_node; then
    echo -n "(no node, skipped) "
    return 0
  fi
  node -e '
    const fs = require("fs");
    const src = fs.readFileSync(process.argv[1], "utf8");
    const body = src.slice(src.indexOf("function shellArg(p)"), src.indexOf("// --- lenses"));
    const shellArg = new Function(body + "; return shellArg;")();

    const cases = [
      ["/My Repo/x",  "'"'"'/My Repo/x'"'"'"],
      ["~/a/b",       "\"$HOME\"'"'"'/a/b'"'"'"],
      ["/plain/path", "'"'"'/plain/path'"'"'"],
    ];
    for (const [input, want] of cases) {
      const got = shellArg(input);
      if (got !== want) { console.error(`shellArg(${input}) = ${got}, want ${want}`); process.exit(1); }
    }
    // A single quote must not terminate the quoting.
    const q = shellArg("/it\x27s/here");
    if (q.includes("s/here'"'"'") === false && !q.startsWith("'"'"'")) { console.error("quote not escaped: " + q); process.exit(1); }
    if (q === "'"'"'/it'"'"'s/here'"'"'") { console.error("single quote passed through unescaped"); process.exit(1); }
  ' "$WF" 2>&1
}

# The runner budgets timeout x (retries + 1) + 60s for its slowest seat — over half an
# hour for the 900s seats — and one Bash call is capped at ten minutes. Foreground, it
# is killed mid-panel and the seats still running look like seats that found nothing.
# It also needs out of the sandbox: antigravity writes under ~/.gemini before it can
# open a conversation.
test_runner_is_backgrounded_and_unsandboxed() {
  grep -q 'run_in_background: true' "$WF" || { echo -n "(not backgrounded) "; return 1; }
  grep -q 'dangerouslyDisableSandbox: true' "$WF" || { echo -n "(sandboxed) "; return 1; }
  return 0
}

# Extract maps a missing output file to zero findings, so a runner that never started
# produces the cleanest report the panel can emit. seatsRun must be what reported, not
# what was requested.
test_failed_seats_are_not_reported_as_run() {
  grep -q 'seatsRun: ran' "$WF" || { echo -n "(seatsRun is the request) "; return 1; }
  grep -q 'seatsFailed' "$WF" || { echo -n "(no failed-seat reporting) "; return 1; }
  return 0
}

# line 0 is what the schema tells a seat to use for a finding that is not line-anchored.
# Keyed on file:line alone, every file-level finding in one file collapses into one.
test_unanchored_findings_do_not_collide() {
  if ! have_node; then
    echo -n "(no node, skipped) "
    return 0
  fi
  node -e '
    const fs = require("fs");
    const src = fs.readFileSync(process.argv[1], "utf8");
    const body = src.slice(src.indexOf("function key(f)"), src.indexOf("const merged = new Map()"));
    const key = new Function(body + "; return key;")();

    const a = { file: "README.md", line: 0, claim: "the install step is wrong" };
    const b = { file: "README.md", line: 0, claim: "the licence is missing" };
    if (key(a) === key(b)) { console.error("two distinct file-level findings collided"); process.exit(1); }

    const c = { file: "src/a.js", line: 42, claim: "off by one" };
    const d = { file: "src/a.js", line: 42, claim: "off by one, said differently" };
    if (key(c) !== key(d)) { console.error("same line did not dedupe"); process.exit(1); }
  ' "$WF" 2>&1
}

# The loader parses meta as a pure literal and refuses anything else. A string built
# with + is a BinaryExpression, and it fails the whole workflow before the first phase
# runs — with a message about meta, not about the line that caused it. `node --check`
# does not catch this because the concatenation is valid JavaScript.
test_meta_is_a_pure_literal() {
  local block
  block=$(sed -n '/^export const meta = {/,/^}/p' "$WF")
  [ -n "$block" ] || return 1
  # A comment may legitimately contain either, so judge the code lines only.
  block=$(printf '%s\n' "$block" | grep -v '^\s*//')
  case "$block" in
    *'+'*) echo -n "(concatenation in meta) "; return 1 ;;
  esac
  case "$block" in
    *'${'*) echo -n "(interpolation in meta) "; return 1 ;;
  esac
  case "$block" in
    *'...'*) echo -n "(spread in meta) "; return 1 ;;
  esac
  return 0
}

# --- Run ---

echo ""
echo "=== workflow panel tests ==="
echo ""

run_test "workflow file exists" test_workflow_exists
run_test "workflow parses" test_workflow_parses
run_test "declared phases match started phases" test_declared_phases_match_started_phases
run_test "lens seats exist in sample config" test_lens_seats_exist_in_sample_config
run_test "reviews still go through the runner" test_reviews_still_go_through_the_runner
run_test "dedupe is code, not an agent" test_dedupe_is_code_not_an_agent
run_test "seat count scales with the diff" test_docs_only_diff_picks_one_seat
run_test "interpolated paths are escaped" test_interpolated_paths_are_escaped
run_test "shellArg handles hostile paths" test_shellarg_handles_hostile_paths
run_test "runner is backgrounded and unsandboxed" test_runner_is_backgrounded_and_unsandboxed
run_test "failed seats are not reported as run" test_failed_seats_are_not_reported_as_run
run_test "unanchored findings do not collide" test_unanchored_findings_do_not_collide
run_test "meta is a pure literal" test_meta_is_a_pure_literal

echo ""
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

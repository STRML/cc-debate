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
PANEL_MD="$PROJECT_DIR/commands/panel.md"
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
#
# Checked against panel.md, because the runner is invoked from the command: it blocks
# for up to half an hour and nothing inside a workflow can wait that long. Checking the
# workflow would pass on a passing mention of the runner in a comment, which is exactly
# what it now contains.
test_reviews_still_go_through_the_runner() {
  grep -q "run-parallel-acpx.sh" "$PANEL_MD" || { echo -n "(command never runs the runner) "; return 1; }
  # And the workflow must not quietly take the job back. Three agent() calls is the
  # design — classify, extract, verify — and none of them reviews the diff for defects.
  # Comments discuss agent() at length, so count code lines only.
  local calls
  calls=$(grep -v '^\s*//' "$WF" | grep -c "agent(")
  [ "$calls" -le 3 ] || { echo -n "(workflow grew to $calls agent calls) "; return 1; }
  return 0
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
  local line var
  # Check each variable against its own wrapper, not the line as a whole. A line
  # carrying two paths where only one is escaped would pass a presence check while
  # containing exactly the bug this is here to catch.
  while IFS= read -r line; do
    for var in WORK_DIR REPO SCRIPTS CONFIG; do
      case "$line" in
        *"\${$var}"*)
          case "$line" in
            # shellArg(VAR) or shellArg(`${VAR}/...`)
            *"shellArg($var"*|*"shellArg(\`\${$var}"*) ;;
            *) echo -n "(unescaped \$$var) "; return 1 ;;
          esac
          ;;
      esac
    done
  done < <(grep -nE "^\s+(cd |bash |awk |sh |grep )" "$WF")
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
  grep -q 'run_in_background: true' "$PANEL_MD" || { echo -n "(not backgrounded) "; return 1; }
  grep -q 'dangerouslyDisableSandbox: true' "$PANEL_MD" || { echo -n "(sandboxed) "; return 1; }
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

# The claim is part of the key at every line number. Keyed on file:line alone, two real
# defects on one line became one record, and the version that kept the loser in a side
# list lost a finding in BOTH arrival orders — minor-then-major and major-then-minor.
# Six of seven seats found that independently, so both orders are asserted here.
test_distinct_claims_never_collapse() {
  if ! have_node; then
    echo -n "(no node, skipped) "
    return 0
  fi
  node -e '
    const fs = require("fs");
    const src = fs.readFileSync(process.argv[1], "utf8");
    // The merge loop itself, lifted with its two inputs injected.
    const body = src.slice(src.indexOf("function claimId(f)"), src.indexOf("const unique = "));
    const group = new Function("bySeat", "RANK", body + "; return [...merged.values()];");
    const RANK = { critical: 0, major: 1, minor: 2, nit: 3 };

    // Two distinct defects on one line: one location, both claims kept.
    let out = group([
      { seat: "a", findings: [{ file: "src/a.js", line: 42, severity: "minor", claim: "missing error handling", failure: "x" }] },
      { seat: "b", findings: [{ file: "src/a.js", line: 42, severity: "major", claim: "the argument is not sanitized", failure: "y" }] },
    ], RANK);
    if (out.length !== 1) { console.error("same line split into " + out.length + " locations"); process.exit(1); }
    if (out[0].claims.length !== 2) { console.error("two distinct same-line claims collided"); process.exit(1); }

    // Unanchored findings in one file likewise.
    out = group([
      { seat: "a", findings: [{ file: "README.md", line: 0, severity: "minor", claim: "the install step is wrong", failure: "x" }] },
      { seat: "b", findings: [{ file: "README.md", line: 0, severity: "minor", claim: "the licence is missing", failure: "y" }] },
    ], RANK);
    if (out[0].claims.length !== 2) { console.error("two distinct file-level findings collided"); process.exit(1); }

    // Two seats wording one finding identically merge, and both get the credit.
    out = group([
      { seat: "a", findings: [{ file: "src/a.js", line: 42, severity: "minor", claim: "off by one", failure: "x" }] },
      { seat: "b", findings: [{ file: "src/a.js", line: 42, severity: "critical", claim: "  Off By One  ", failure: "y" }] },
    ], RANK);
    if (out[0].claims.length !== 1) { console.error("identical claims stopped deduping"); process.exit(1); }
    if (out[0].claims[0].seats.length !== 2) { console.error("second seat lost its credit"); process.exit(1); }
    if (out[0].claims[0].severity !== "critical") { console.error("harsher severity not kept"); process.exit(1); }

    // Case-sensitive checkouts: these are different files, not one.
    out = group([
      { seat: "a", findings: [{ file: "src/Foo.js", line: 7, severity: "minor", claim: "x", failure: "f" }] },
      { seat: "b", findings: [{ file: "src/foo.js", line: 7, severity: "minor", claim: "x", failure: "f" }] },
    ], RANK);
    if (out.length !== 2) { console.error("case-distinct paths merged"); process.exit(1); }
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

# The classifier judges securitySensitive by reading, and a model that reads a diff
# touching auth and concludes otherwise silently removes the attacker from the exact
# panel that needed one. A deterministic grep over the diff forces the seat regardless.
test_security_grep_forces_the_pentester() {
  if ! have_node; then
    echo -n "(no node, skipped) "
    return 0
  fi
  node -e '
    const fs = require("fs");
    const src = fs.readFileSync(process.argv[1], "utf8");
    const lenses = src.slice(src.indexOf("const LENSES = ["), src.indexOf("// A docs-only change"));
    const picker = src.slice(src.indexOf("function pickSeats"), src.indexOf("const DIFF_SHAPE"));
    const pickSeats = new Function(lenses + picker + "; return pickSeats;")();

    // The model said no; the grep said yes. The seat must still be bought.
    const missed = { filesChanged: 2, linesAdded: 20, linesRemoved: 3, docsOnly: false,
                     securitySensitive: false, securityGrep: true,
                     touchesFilesystem: false, addsAbstraction: false };
    if (!pickSeats(missed).includes("pentester")) {
      console.error("grep hit did not force the pentester"); process.exit(1);
    }
    // Neither signal: still no pentester on a trivial diff.
    const clean = { ...missed, securityGrep: false };
    if (pickSeats(clean).includes("pentester")) {
      console.error("pentester bought with no security signal"); process.exit(1);
    }
  ' "$WF" 2>&1
}

# A docs-only diff normally earns one seat, but the shortcut used to run before the
# lens table and outrank the pentester's floor. A README whose install step was edited
# to pipe a payload into a shell is docs-only and security-relevant at the same time.
test_docs_only_does_not_outrank_the_security_floor() {
  if ! have_node; then
    echo -n "(no node, skipped) "
    return 0
  fi
  node -e '
    const fs = require("fs");
    const src = fs.readFileSync(process.argv[1], "utf8");
    const lenses = src.slice(src.indexOf("const LENSES = ["), src.indexOf("// A docs-only change"));
    const picker = src.slice(src.indexOf("function pickSeats"), src.indexOf("const DIFF_SHAPE"));
    const pickSeats = new Function(lenses + picker + "; return pickSeats;")();

    const base = { filesChanged: 1, linesAdded: 4, linesRemoved: 1, docsOnly: true,
                   securitySensitive: false, securityGrep: false,
                   touchesFilesystem: false, addsAbstraction: false };
    // Plain docs: still exactly one seat.
    if (pickSeats(base).length !== 1) {
      console.error("plain docs diff stopped being one seat"); process.exit(1);
    }
    // Docs that tripped the grep must still buy the attacker.
    const risky = { ...base, securityGrep: true };
    if (!pickSeats(risky).includes("pentester")) {
      console.error("docs-only shortcut skipped the pentester on a security hit"); process.exit(1);
    }
    const judged = { ...base, securitySensitive: true };
    if (!pickSeats(judged).includes("pentester")) {
      console.error("docs-only shortcut skipped the pentester on a judged risk"); process.exit(1);
    }
  ' "$WF" 2>&1
}

# The panel's whole purpose is that a review which did not happen never looks like a
# review that found nothing. Extract is the last place that can go wrong: agent()
# returns null when a subagent dies, and `(r && r.findings) || []` turns that into an
# empty findings array. Observed on the first successful end-to-end run — seven seats
# wrote real reviews, every transcriber hit a session limit, and the panel reported
# zero findings and looked clean.
test_failed_extraction_is_not_zero_findings() {
  # The seat's result must carry whether the transcriber survived.
  grep -q 'ok: !!r' "$WF" || { echo -n "(extract result drops liveness) "; return 1; }
  # A null result must map back to its seat rather than being filtered away.
  grep -q 'perSeat\[i\] ||' "$WF" || { echo -n "(null result silently dropped) "; return 1; }
  # Losing every transcription must be an error, never an empty report.
  grep -q 'extractFailed.length === ran.length' "$WF" || { echo -n "(total failure not fatal) "; return 1; }
  # And a partial loss must reach the caller.
  grep -q 'seatsNotTranscribed' "$WF" || { echo -n "(partial loss not reported) "; return 1; }
  grep -q 'seatsNotTranscribed' "$PANEL_MD" || { echo -n "(command does not report it) "; return 1; }
  return 0
}

# One verifier now judges every claim on a line at once. That is the whole point of
# grouping, and it is also the risk: a refuted claim must not take its neighbours with
# it, a restatement must fold without losing its seat, and a verdict that never arrived
# must not read as approval. Someone hiding a real defect beside an obvious decoy on one
# line is the case being defended against.
test_one_refuted_claim_does_not_sink_the_line() {
  if ! have_node; then
    echo -n "(no node, skipped) "
    return 0
  fi
  node -e '
    const fs = require("fs");
    const src = fs.readFileSync(process.argv[1], "utf8");
    const body = src.slice(src.indexOf("const survived = []"), src.indexOf("log(`${survived.length}"));
    const assemble = new Function("unique", "judged", body + "; return { survived, killed, unverified };");

    const loc = (claims) => ({ file: "a.js", line: 42, claims });
    const c = (claim, seat) => ({ severity: "major", claim, failure: "f", fix: "", seats: [seat] });

    // Decoy refuted, real finding beside it survives.
    let out = assemble(
      [loc([c("obvious wrong thing", "x"), c("subtle real thing", "y")])],
      [{ verdicts: [{ index: 0, refuted: true, reason: "no" }, { index: 1, refuted: false, reason: "holds" }] }],
    );
    if (out.survived.length !== 1 || out.survived[0].claim !== "subtle real thing") {
      console.error("a refuted claim took its neighbour down with it"); process.exit(1);
    }
    if (out.killed.length !== 1) { console.error("refuted claim not reported"); process.exit(1); }

    // A genuine restatement folds into the earlier claim and both seats get credit.
    out = assemble(
      [loc([c("off by one", "x"), c("the index is one too high", "y")])],
      [{ verdicts: [{ index: 0, refuted: false, reason: "holds" }, { index: 1, refuted: false, reason: "holds", sameAs: 0 }] }],
    );
    if (out.survived.length !== 1) { console.error("restatement did not fold"); process.exit(1); }
    if (out.survived[0].foundBy.length !== 2) { console.error("folded claim lost its seat"); process.exit(1); }

    // A claim the verifier said nothing about is unverified, not approved.
    out = assemble(
      [loc([c("judged", "x"), c("ignored", "y")])],
      [{ verdicts: [{ index: 0, refuted: false, reason: "holds" }] }],
    );
    if (out.unverified.length !== 1 || out.unverified[0].claim !== "ignored") {
      console.error("a claim with no verdict was not reported as unverified"); process.exit(1);
    }

    // A dead verifier leaves every claim at that location unverified, none approved.
    out = assemble([loc([c("one", "x"), c("two", "y")])], [null]);
    if (out.unverified.length !== 2 || out.survived.length !== 0) {
      console.error("a dead verifier did not leave its claims unverified"); process.exit(1);
    }
  ' "$WF" 2>&1
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
run_test "distinct claims never collapse" test_distinct_claims_never_collapse
run_test "meta is a pure literal" test_meta_is_a_pure_literal
run_test "security grep forces the pentester" test_security_grep_forces_the_pentester
run_test "docs-only does not outrank the security floor" test_docs_only_does_not_outrank_the_security_floor
run_test "failed extraction is not zero findings" test_failed_extraction_is_not_zero_findings
run_test "one refuted claim does not sink the line" test_one_refuted_claim_does_not_sink_the_line

echo ""
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

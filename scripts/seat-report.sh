#!/bin/bash
# seat-report.sh — what each seat actually contributed to a panel run.
#
# Usage: seat-report.sh <panel-result.json>
#        /debate:panel ... | seat-report.sh -
#
# Input is the object stage 'report' returns, with its findings/refuted/unverified
# arrays and their foundBy lists.
#
# The lens table claims each seat asks a different question. This is how that claim
# gets checked instead of asserted. For every seat it prints:
#
#   sole      findings only that seat reported, which survived verification
#   corrob    findings it reported that another seat also found
#   refuted   findings it reported that the verifier threw out
#   unver     findings it reported that were never ruled on
#
# `sole` is the number that decides whether a seat earns its slot. A seat with
# sole=0 across several runs is a second sample of a question another seat already
# asks: it costs a full review and adds agreement, which is weak evidence, rather
# than coverage. `refuted` is the other side — a seat with high refuted and low sole
# is spending verifier calls to generate noise.
#
# One run is one data point. The current lens table was built on a single measured
# run of #22 and its thresholds are still guesses; treat a single seat-report the
# same way and collect a few before moving a lens in or out.

set -euo pipefail

SRC="${1:-}"
if [ -z "$SRC" ]; then
  echo "Usage: $0 <panel-result.json>|-" >&2
  exit 2
fi

if [ "$SRC" != "-" ] && [ ! -f "$SRC" ]; then
  echo "seat-report: no such file: $SRC" >&2
  exit 1
fi

# Spool a pipe to a file before python runs. The script below reaches python on
# stdin, so python's own stdin is already spent by the time it starts — reading
# piped JSON from there gets the tail of this heredoc, not the caller's data, and
# the documented `seat-report.sh -` form fails as "input is not JSON".
if [ "$SRC" = "-" ]; then
  SPOOL="$(mktemp)"
  trap 'rm -f "$SPOOL"' EXIT
  cat > "$SPOOL"
  SRC="$SPOOL"
fi

python3 - "$SRC" << 'PY'
import json, sys, collections

try:
    d = json.load(open(sys.argv[1]))
except Exception as e:
    sys.exit("seat-report: input is not JSON (%s)" % e)

survived   = d.get("findings") or []
refuted    = d.get("refuted") or []
unverified = d.get("unverified") or []

ran     = d.get("seatsRun") or []
failed  = d.get("seatsFailed") or []
untrans = d.get("seatsNotTranscribed") or []
unconf  = d.get("seatsNotConfigured") or []

stat = collections.defaultdict(lambda: collections.Counter())
for f in survived:
    by = f.get("foundBy") or []
    for s in by:
        stat[s]["sole" if len(by) == 1 else "corrob"] += 1
for f in refuted:
    for s in (f.get("foundBy") or []):
        stat[s]["refuted"] += 1
for f in unverified:
    for s in (f.get("foundBy") or []):
        stat[s]["unver"] += 1

# Failed and unreadable seats get rows too. Leaving them to the footer was the same
# mistake the panel itself makes when a seat that never ran is indistinguishable from
# one that found nothing: the table is what gets read, so the absence has to be in it.
seats = sorted(set(list(stat) + ran + failed + untrans + unconf),
               key=lambda s: (-stat[s]["sole"], -stat[s]["corrob"], s))

print("seat            sole  corrob  refuted  unver   verdict")
print("-" * 62)
for s in seats:
    c = stat[s]
    if s in untrans:
        verdict = "review unreadable — not counted"
    elif s in unconf:
        verdict = "not configured here — never started"
    elif s in failed or s not in ran:
        verdict = "did not run"
    elif c["sole"]:
        verdict = "earned its slot this run"
    elif c["corrob"]:
        verdict = "corroborated only"
    elif c["refuted"]:
        verdict = "noise this run"
    else:
        verdict = "found nothing"
    print("%-14s %5d %7d %8d %6d   %s"
          % (s, c["sole"], c["corrob"], c["refuted"], c["unver"], verdict))

print()
print("%d finding(s) survived, %d refuted, %d unverified, across %d seat(s) that reported."
      % (len(survived), len(refuted), len(unverified), len(ran)))
if failed:
    print("Did not run: %s" % ", ".join(failed))
if untrans:
    print("Reviewed but unreadable: %s — findings missing from the above."
          % ", ".join(untrans))
print()
print("sole=0 on one run is not a verdict on a seat. Collect several before moving a lens.")
PY

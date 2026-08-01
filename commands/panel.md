---
description: Review the current changeset with a panel sized to the diff, then dedupe and verify the findings before showing them to you.
allowed-tools: Bash, Read, Workflow
---

# Panel review (workflow-driven)

`/debate:run` runs a panel you chose. This runs a panel the diff chose, then does the
merging and the filtering in code instead of in your context.

Use it when the change is big enough that reading six reviews by hand is the expensive
part. Use `/debate:run` when you want a specific set of seats, or when you want the
debate rounds, which this does not do.

## What it does

1. Measures the diff: how many files, whether it touches auth or credentials or the
   filesystem, whether it is docs only.
2. Picks seats from that. A docs-only change gets one. A wide, security-touching
   change gets the full table. The rule is in `workflows/review-panel.js` as plain
   code, so you can read it and argue with it.
3. Runs those seats through `run-parallel-acpx.sh`, exactly as `/debate:run` does. The
   reviewers are still acpx and codex-exec seats. Nothing in the panel is Claude. This
   step runs from here rather than inside the workflow, because it takes up to half an
   hour and nothing inside a workflow can wait that long.
4. Turns each review into structured findings, then merges them on `file:line:claim`. On
   one measured run, five of twelve seats reported the same finding; this collapses that
   without anyone reading twelve files. The claim is in the key because two seats can
   report genuinely different defects on one line, and a merge keyed on location alone
   deletes one of them.
5. Tries to refute each surviving finding against the actual code, and drops the ones
   that do not hold.
6. Returns one ranked list.

## Steps

**1. Check the workflow is linked.**

```bash
ls ~/.claude/debate-workflows/review-panel.js
```

Missing means the symlink has not been created. Run `/debate:setup`, which runs
`create-links.sh`.

**2. Set up the work dir.**

```bash
bash ~/.claude/debate-scripts/debate-setup.sh
```

Note `REVIEW_ID`, `WORK_DIR`, `SCRIPT_DIR` and `REPO_ROOT`.

**3. Write the changeset.**

The workflow reads `<WORK_DIR>/changeset.diff` and does not generate it, because a
workflow script has no filesystem access of its own.

```bash
bash ~/.claude/debate-scripts/changeset-diff.sh "<WORK_DIR>" "<WORK_DIR>/changeset.diff" \
  > "<WORK_DIR>/changeset-base.txt"
```

The redirect is required, not decorative. `changeset-diff.sh` prints the base it resolved
and writes it nowhere; the runner normally persists it, but on the frozen path it *reads*
that file instead of regenerating. Skip the redirect and the base is empty, which
`safe-cleanup.sh` later uses to regenerate the diff for its APPROVED gate — comparing
against nothing.

Set `DEBATE_DIFF_BASE` first if you want a base other than the merge base with the
default branch. If the diff comes back empty, stop and say so; there is nothing to
review and every downstream stage would be measuring an empty file.

**4. Pick the seats.**

```
Workflow({
  scriptPath: "<HOME>/.claude/debate-workflows/review-panel.js",
  args: { stage: "classify", workDir: "<WORK_DIR>", repoRoot: "<REPO_ROOT>" }
})
```

Pass `args` as a real object, not a JSON string — a string reaches the script as a
string and every field reads `undefined`.

It returns `{ diff, seats, seatsSkipped }`. **Write that object to disk before going on:**

```bash
cat > "<WORK_DIR>/panel-state.json"   # paste the returned object
```

Step 6 needs all three fields, and half an hour of seats running separates the two. Held
only in your context, that state is one compaction or one dropped session away from
gone, and the run cannot be finished without re-classifying. On disk it survives both.
Read it back in step 6 rather than trusting recall.

**5. Run the seats. This step is yours, not the workflow's.**

```bash
DEBATE_FREEZE_DIFF=1 bash "<SCRIPT_DIR>/run-parallel-acpx.sh" "<HOME>/.claude/debate-acpx.json" "<REVIEW_ID>" "<seat1,seat2,...>"
```

`DEBATE_FREEZE_DIFF=1` is required here. Without it the runner regenerates
`changeset.diff` from the working tree, and any edit landing between step 4 and now
would hand the seats a different changeset from the one the panel was sized for — the
report would describe the diff that picked the seats while the reviews described
something else.

Run it with `run_in_background: true` and `dangerouslyDisableSandbox: true`, then wait
for the completion notification.

Both flags matter, and so does whose call this is:

- **Background**, because the runner blocks for `timeout x (retries + 1) + 60s` on its
  slowest seat — half an hour for the 900s seats. You get re-invoked when it exits.
- **Unsandboxed**, because the seats need outbound network and the antigravity seat
  writes its project config under `~/.gemini` before it can open a conversation. What
  keeps the seats read-only is not this sandbox but acpx's own
  `--non-interactive-permissions deny`; dropping it removes a second layer, not the only
  one.
- **Yours**, because a workflow `agent()` cannot wait this long by any means. A
  foreground Bash call is capped at ten minutes, a foreground sleep is refused, and
  Monitor schedules a callback into a turn that has already ended. A subagent asked to
  wait returns in under a minute, and the harness then reaps the runner it backgrounded,
  killing every seat mid-review. The whole panel comes back empty and looks clean.

**6. Work out which seats actually reported, then report.**

```bash
for s in <seat1> <seat2> ...; do
  e=$(cat "<WORK_DIR>/$s-exit.txt" 2>/dev/null || echo -1)
  b=$(wc -c < "<WORK_DIR>/$s-output.md" 2>/dev/null || echo 0)
  [ "$e" = "0" ] && [ "$b" -gt 0 ] && echo "RAN $s" || echo "FAILED $s (exit $e, $b bytes)"
done
```

A seat with no exit file never ran at all — `run-parallel-acpx.sh` skips a seat your
config has no entry for, and says nothing about it. Read `<WORK_DIR>/panel-state.json`
back for `diff` and `seatsSkipped`, and feed the split in with them:

```
Workflow({
  scriptPath: "<HOME>/.claude/debate-workflows/review-panel.js",
  args: {
    stage: "report",
    workDir: "<WORK_DIR>",
    repoRoot: "<REPO_ROOT>",
    seats: ["<the RAN ones>"],
    seatsFailed: ["<the FAILED ones>"],
    diff: <the diff object from step 4>,
    seatsSkipped: <the seatsSkipped array from step 4>
  }
})
```

If nothing ran, stop and say so. Do not report a panel that produced no reviews as a
review that found nothing.

**7. Report what it returns.**

The workflow returns the seats it ran, the seats it asked for that produced no review,
the seats it skipped with the reason the diff did not earn each one, the raw and
deduplicated finding counts, the surviving findings ranked, the refuted ones with the
reason each was dropped, and any finding whose verifier never returned.

Show the unverified findings too, and label them as unverified. Nobody refuted them —
the verify step just did not come back — so they are reviewer claims that have not been
checked, which is not the same as findings that survived a check.

Report `seatsFailed` whenever it is non-empty, and say so before the findings rather
than after. A seat that did not run contributes no findings, which is indistinguishable
from a seat that reviewed the diff and approved it — the count of seats that actually
reported is what tells the user how much the review is worth.

**`seatsNotTranscribed` is worse and must be reported the same way.** Those seats did
review the diff, and their reviews are sitting in the work dir, but the transcription
step could not read them back — so their findings are missing from the counts and from
the ranked list. A report carrying a non-empty `seatsNotTranscribed` is incomplete by an
unknown amount. Say which seats, and point at `<WORK_DIR>/<seat>-output.md` so the
reviews can be read directly. Never present such a run as a review that came back
clean.

Show the surviving findings in full. Then say plainly how many were duplicates and how
many were refuted, because those two numbers are what tell the user whether the panel
size was right. A run where nothing was deduplicated and nothing was refuted was
probably too small; one where most findings collapsed into a handful was too big.

**List the refuted findings too, one line each: file:line, the claim, and the reason it
was dropped.** A count is not enough. The verifier is a model asked to argue against a
finding, so it has a refute bias, and the failure that matters here is the one where it
talks itself out of a true finding. Reported as a number, that finding is gone and
nobody can tell it ever existed; reported as a line, a reader who knows the code can
see the kill was wrong. Filtering false positives is only worth doing where the false
negatives stay visible.

**8. Clean up.**

```bash
bash ~/.claude/debate-scripts/safe-cleanup.sh "<WORK_DIR>"
```

Changeset mode needs no `--saved`; the diff is reproducible from git.

## Notes

- This needs the `Workflow` tool, which is a Claude Code built-in. `/debate:run` needs
  only bash, so it remains the portable path.
- The lens table is deliberately readable. If a seat keeps getting skipped on changes
  where you wanted it, change its condition rather than working around it here.
- No debate rounds and no revision loop. This produces a reviewed list, not a
  negotiated verdict.

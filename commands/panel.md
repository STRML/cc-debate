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
   reviewers are still acpx seats. Nothing in the panel is Claude. This
   step runs from here rather than inside the workflow, because it takes up to half an
   hour and nothing inside a workflow can wait that long.
4. Turns each review into structured findings, then groups them by `file:line`. On one
   measured run, five of twelve seats reported the same finding; this collapses that
   without anyone reading twelve files. Identical wording merges in code; the rest is
   left for the verifier, which sees every claim on a line at once.
5. Sends every claim at a location to one verifier, which tries to refute each against
   the actual code and folds genuine restatements together. Claims that do not hold are
   dropped, and a claim the verifier never ruled on is reported as unverified rather
   than assumed good.
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

**5. Drop the seats this machine has not configured.**

The check used to test only that the reviewer entry existed in the config, which is the
wrong test for `deepseek`: the sample config ships its entry, so a fresh clone passed the
check, the runner spawned `acpx deepseek`, the agent was never created, and the seat
landed in `seatsFailed` instead of `seatsNotConfigured` — a phantom failure on every
non-docs panel. The check below verifies the agent can actually spawn, not just that the
config mentions it:

```bash
for s in <seat1> <seat2> ...; do
  a=$(jq -r --arg s "$s" '.reviewers[$s].agent // empty' "$HOME/.claude/debate-acpx.json")
  if [ -z "$a" ]; then
    echo "UNCONFIGURED $s"
  elif [ "$a" = "antigravity" ]; then
    # agy is invoked through python3 (invoke-acpx.sh runs it under a PTY), so both
    # must be present for the seat to actually spawn.
    command -v agy >/dev/null 2>&1 && { command -v python3 >/dev/null 2>&1 || command -v python >/dev/null 2>&1; } \
      && echo "HAVE $s" || echo "UNCONFIGURED $s"
  elif [ "$a" = "opus" ]; then
    command -v claude >/dev/null 2>&1 && echo "HAVE $s" || echo "UNCONFIGURED $s"
  elif [ -f "$HOME/.acpx/config.json" ] && cmd=$(jq -r --arg a "$a" '.agents[$a].command // empty' "$HOME/.acpx/config.json") && [ -n "$cmd" ] && [ -x "$cmd" ]; then
    # The wrapper is executable — check the runtime it boots (an opencode-backed
    # agent's wrapper does `exec opencode acp`), so a missing binary is caught
    # here rather than as a phantom FAILED seat.
    command -v opencode >/dev/null 2>&1 && echo "HAVE $s" || echo "UNCONFIGURED $s"
  elif command -v "$a" >/dev/null 2>&1; then
    echo "HAVE $s"
  else
    echo "UNCONFIGURED $s"
  fi
done
```

The `antigravity` and `opus` branches check the direct CLI they are invoked through
(`agy` / `claude`). A custom opencode-backed agent (`deepseek`, anything from
`create-opencode-agent.sh`) is registered in `~/.acpx/config.json` with an executable
command; the check verifies both. Anything else resolves to an acpx built-in whose CLI
must be on `PATH`. Run only the `HAVE` seats in the next step, and carry the `UNCONFIGURED`
ones into step 7 as `seatsNotConfigured`.

A seat the lens table asks for is not the same as a seat this install owns. The optional
ones — `deepseek`, and anything added with `create-opencode-agent.sh` — need a wrapper, an
acpx registration, a reviewer entry and a key before they can start. Without the check the
runner skips them with a line on stderr nobody reads, they leave no exit file, and step 6
scores a missing file as a dead seat — so every panel on a fresh clone reports seats that
failed when they were never installed. "Not configured" and "failed" want different words.
The classify stage already refuses to request `deepseek` when the agent is absent, so the
probe above mostly confirms the rest of the table; the seat's own `when` in the lens
table is where the request is actually stopped.

**6. Run the seats. This step is yours, not the workflow's.**

```bash
DEBATE_FREEZE_DIFF=1 ACPX_SEAT_MODELS="<WORK_DIR>/panel.json" \
  bash "<SCRIPT_DIR>/run-parallel-acpx.sh" "<HOME>/.claude/debate-acpx.json" "<REVIEW_ID>" "<seat1,seat2,...>"
```

`DEBATE_FREEZE_DIFF=1` is required here. Without it the runner regenerates
`changeset.diff` from the working tree, and any edit landing between step 4 and now
would hand the seats a different changeset from the one the panel was sized for — the
report would describe the diff that picked the seats while the reviews described
something else.

**Pass the selector's model selection.** The seats were picked for their models in step 4;
hand that to dispatch so each seat actually runs the model that earned it the slot. Run the
selector and save its output as `<WORK_DIR>/panel.json`, which `ACPX_SEAT_MODELS` points at:

```bash
python3 "<SCRIPT_DIR>/select-panel.py" \
  --registry "<HOME>/.claude/debate-models.json" \
  --seats "<seat1,seat2,...>" --deepest <deepest-seat> \
  --installed-harnesses acpx,subagent > "<WORK_DIR>/panel.json"
```

The runner reads `.seats[<seat>].model_id` per seat and forwards it as `--model` on the acpx
call (a flat `{seat: model_id}` map works too, and `DEBATE_MODEL=<id>` sets one model for the
whole panel). Without this the seats run their agents' default models and the panel
selection is inert. The registry path above is the standard `$HERMES_HOME/debate-models.json`;
point `--registry` at wherever the registry actually lives.

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

**7. Work out which seats actually reported, then report.**

```bash
for s in <the HAVE seats>; do
  e=$(cat "<WORK_DIR>/$s-exit.txt" 2>/dev/null || echo -1)
  b=$(wc -c < "<WORK_DIR>/$s-output.md" 2>/dev/null || echo 0)
  [ "$e" = "0" ] && [ "$b" -gt 0 ] && echo "RAN $s" || echo "FAILED $s (exit $e, $b bytes)"
done
```

Non-empty is the test, not the whole story: an exit file of 0 with non-empty output can
still be an error dump the agent printed to stdout and exited 0 on. You are reading every
`-output.md` in full below anyway — a seat whose output is an error dump rather than a
review did not deliver, whatever its exit file says. (And the reverse: a review needs no
ASCII, so a non-Latin review may carry no `VERDICT:` marker and still be a valid review.)

Every seat here was configured, so a missing exit file now means it really did die.
Read `<WORK_DIR>/panel-state.json` back for `diff` and `seatsSkipped`, and feed the split
in with them:

```
Workflow({
  scriptPath: "<HOME>/.claude/debate-workflows/review-panel.js",
  args: {
    stage: "report",
    workDir: "<WORK_DIR>",
    repoRoot: "<REPO_ROOT>",
    seats: ["<the RAN ones>"],
    seatsFailed: ["<the FAILED ones>"],
    seatsNotConfigured: ["<the UNCONFIGURED ones from step 5>"],
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

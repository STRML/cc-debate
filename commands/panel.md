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
   reviewers are still acpx and codex-exec seats. Nothing in the panel is Claude.
4. Turns each review into structured findings, then merges them on `file:line`. On one
   measured run, five of twelve seats reported the same finding; this collapses that
   without anyone reading twelve files.
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
bash ~/.claude/debate-scripts/changeset-diff.sh "<WORK_DIR>" "<WORK_DIR>/changeset.diff"
```

Set `DEBATE_DIFF_BASE` first if you want a base other than the merge base with the
default branch. If the diff comes back empty, stop and say so; there is nothing to
review and every downstream stage would be measuring an empty file.

**4. Run it.**

```
Workflow({
  scriptPath: "~/.claude/debate-workflows/review-panel.js",
  args: {
    reviewId:   "<REVIEW_ID>",
    workDir:    "<WORK_DIR>",
    repoRoot:   "<REPO_ROOT>",
    scriptDir:  "<SCRIPT_DIR>",
    configPath: "<HOME>/.claude/debate-acpx.json"
  }
})
```

Use the absolute `SCRIPT_DIR` that `debate-setup.sh` printed, and an absolute
`configPath`. The workflow builds a shell command out of these and quotes each one, so
a `~` would arrive at the shell inside double quotes where it is never expanded. The
workflow rewrites a leading `~/` to `$HOME/` to cover the tilde form, but passing the
resolved path is the version that cannot go wrong.

It runs in the background and notifies you when it finishes. Do not poll it.

**5. Report what it returns.**

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

Show the surviving findings in full. Then say plainly how many were duplicates and how
many were refuted, because those two numbers are what tell the user whether the panel
size was right. A run where nothing was deduplicated and nothing was refuted was
probably too small; one where most findings collapsed into a handful was too big.

**6. Clean up.**

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

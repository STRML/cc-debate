---
description: Run ALL configured AI reviewers in parallel via acpx, synthesize feedback, debate contradictions, and produce a consensus verdict. Configure reviewers in ~/.claude/debate-acpx.json.
allowed-tools: Bash(bash ~/.claude/debate-scripts/debate-setup.sh:*), Bash(bash ~/.claude/debate-scripts/invoke-acpx.sh:*), Bash(bash ~/.claude/debate-scripts/run-parallel-acpx.sh:*), Bash(bash ~/.claude/debate-scripts/record-round.sh:*), Bash(bash ~/.claude/debate-scripts/safe-cleanup.sh:*), Bash(sha256sum:*), Bash(shasum:*), Bash(rm -rf .tmp/ai-review-:*), Write(.tmp/ai-review-*), Write(~/.acpx/**), Read(~/.acpx/**), Agent(subagent_type: general-purpose, model: opus), SendMessage(*)
---

# AI Multi-Model Plan Review (acpx)

Run all configured AI reviewers in parallel via acpx, synthesize their feedback, debate contradictions, and produce a final consensus verdict. Max 3 total **revision** rounds (verification passes — re-reviewing a post-fix plan with no further revisions — do NOT count against this budget; see Step 6.5).

Arguments:
- First arg: optional comma-separated reviewer names (e.g. `codex,gemini`). Defaults to all from config.
- `skip-debate` — skip the targeted debate phase, go straight to final report.

**Reviewer config** (`~/.claude/debate-acpx.json`):
!`cat ~/.claude/debate-acpx.json 2>/dev/null || echo '{"error":"Config not found — run /debate:acpx-setup first."}'`

---

## Step 1: Prerequisites & Setup

### 1a. Validate config

The config is already loaded above. If it contains `"error"`, stop:
```text
Config not found: ~/.claude/debate-acpx.json
Run /debate:acpx-setup to create it.
```

Parse reviewer list. If a comma-separated reviewer list was passed as argument, filter to only those reviewers. Validate each reviewer has an `agent` field.

### 1b. Generate session ID & temp dir

Verify `~/.claude/debate-scripts` exists. If not:
```text
~/.claude/debate-scripts not found.
Run /debate:setup first to create the stable scripts symlink.
```

Run setup:
```bash
bash ~/.claude/debate-scripts/debate-setup.sh
```

Note `REVIEW_ID`, `WORK_DIR`, and `SCRIPT_DIR` from output.

### 1c. Announce

List the reviewers that will run:

```text
## acpx Review — Starting

Reviewers:
  codex    → agent: codex    (120s)
  gemini   → agent: gemini   (240s)
  mercury  → agent: mercury  (120s)
```

### 1d. Verify sessions

`invoke-acpx.sh` creates a new acpx session before every review run — no manual session creation is needed. If a reviewer fails with exit code 4 (session creation failed), it means the agent CLI is not installed or not authenticated. In that case, suggest running `/debate:acpx-setup` to diagnose.

### 1e. Capture the plan

First check whether a plan exists in the current conversation context. If no plan is present, ask the user to paste it or describe what to review. Once a plan is available, write it to `<WORK_DIR>/plan.md`.

---

## Step 2: Parallel Review (Round N)

Track a round counter starting at 1. Check `ROUND <= 3` before executing each round — if exceeded, go to the "max rounds reached" block in Step 7.

Launch the acpx reviewers AND a Claude Opus subagent **in parallel** (same message, multiple tool calls):

### 2a. acpx reviewers (Bash)

```bash
bash "<SCRIPT_DIR>/run-parallel-acpx.sh" "~/.claude/debate-acpx.json" "<REVIEW_ID>" [reviewer1,reviewer2,...]
```

If a reviewer subset was specified, pass the comma-separated list as the third argument. Use `timeout: 480000` on the Bash call (the runner blocks until all reviewers complete or time out).

### 2b. Claude Opus subagent (Agent)

**Round 1:** Spawn a named agent. It forks context, so it already has the plan — do NOT re-send it.

```
Agent:
  name: "claude-skeptic"
  model: "opus"
  subagent_type: "general-purpose"
  description: "Claude Opus skeptic reviewer"
  run_in_background: true
  prompt: |
    You are The Skeptic — a senior engineer who challenges plans by finding what
    everyone else missed. Focus on:
    1. Unstated assumptions — what is assumed true that could be false?
    2. Unhappy paths — what breaks when the first thing goes wrong?
    3. Second-order failures — what does a partial success leave behind?
    4. Security — is any user-controlled content reaching a shell string?
    5. The one fatal flaw — if this plan has one problem, what is it?

    Review the implementation plan in this conversation. The plan is already in
    your context — do not ask for it.

    Provide structured feedback with severity (CRITICAL / MAJOR / MINOR) for
    each concern. Be specific, be direct, be constructive.

    End your response with exactly one of:
      VERDICT: APPROVED — plan is solid and ready to implement
      VERDICT: REVISE — concerns above should be addressed first
```

**Rounds 2+:** Use SendMessage to the existing `claude-skeptic` agent with revision context (same pattern as claude-review skill).

### Cleanup

If the run fails or the user interrupts, clean up before stopping. At this point there is no reviewed-and-saved final plan, so abandon the work dir with `bash "<SCRIPT_DIR>/safe-cleanup.sh" "<WORK_DIR>" --force`. (Without `--force` it will refuse — a prior APPROVED round may not match, and no `--saved` copy exists — which is correct: only `--force` should delete an unsaved plan.)

### Check results

For each configured reviewer, read:
- `<WORK_DIR>/<name>-exit.txt` — exit code
- `<WORK_DIR>/<name>-output.md` — review text

Exit code meanings:
- `0` — success
- `4` — session creation failed (agent not installed or not authenticated)
- `124` — timed out
- Other — error (check `<name>-stderr.log` and `<name>-invoke.log` for details)

**If all reviewers failed:**
```text
## acpx Review — UNDECIDED

All reviewers failed or timed out. No synthesis is possible.

Options:
- Check agent availability with /debate:acpx-setup
- Re-run /debate:all
```
Then clean up and exit.

---

## Step 3: Present Reviewer Outputs

**CRITICAL: You MUST use the Read tool to read each `<name>-output.md` file IN FULL.** Do NOT use grep, awk, sed, head, tail, or any other tool to extract snippets or search for keywords. Do NOT summarize without reading. Each reviewer catches different issues — skimming loses findings. Read every word.

For each completed acpx reviewer:

```text
---
## <Name> Review — Round N (<Agent>)

[FULL content of <name>-output.md — do not truncate or summarize]
```

For the Claude Opus subagent (its result is returned directly — no file to read):

```text
---
## Claude (Skeptic) Review — Round N

[FULL agent response — do not truncate or summarize]
```

For failed/timed-out reviewers:
```text
## <Name> Review — Round N

⚠️ <Name> timed out / failed (exit <code>). Skipping.
```

---

## Step 4: Synthesize

**CRITICAL: Do NOT grep reviewer files for keywords like "critical", "blocker", "must fix", etc. to build your synthesis.** You must synthesize from the full text you already read in Step 3. If you did not read the full output in Step 3, go back and do it now before synthesizing.

Read all successful reviewer outputs and categorize:

```text
## Synthesis — Round N

### Unanimous Agreements
- [Points all reviewers agree on]

### Unique Insights
- [Reviewer]: [Point only this reviewer raised]

### Contradictions
- Point A: <Reviewer1> says X, <Reviewer2> says Y
```

Extract each verdict. Determine overall:
- All APPROVED → skip debate, go to Step 6
- Any REVISE → continue to Step 5
- Only 1 reviewer succeeded → skip debate, use that verdict as final

### Record the round verdict

Once you have the round-level verdict, log it. This binds the verdict to the SHA of the plan reviewers actually saw, so Step 6 can detect any post-review edits and Step 9 can refuse cleanup if the plan drifted past the last APPROVED state.

```bash
bash "<SCRIPT_DIR>/record-round.sh" "<WORK_DIR>" <ROUND_NUM> <VERDICT>
```

`<VERDICT>` must be one of `APPROVED`, `REVISE`, `SPLIT`, `UNDECIDED`.

---

## Step 5: Targeted Debate (unless `skip-debate` was passed or fewer than 2 reviewers succeeded)

Max 2 debate rounds. Skip if no contradictions.

For each contradiction, write a debate prompt to `<WORK_DIR>/<name>-prompt.txt`:

```bash
cat > <WORK_DIR>/<name>-prompt.txt << 'DEBATE_EOF'
There is a disagreement on [topic].

The other reviewer's position:
[quote the specific disagreement from the other reviewer's output]

Your position:
[quote their specific position]

Do you stand by your position, or does the other reviewer's point change your assessment?
Be specific. End with VERDICT: APPROVED or VERDICT: REVISE.
DEBATE_EOF
```

Then re-run just the debating reviewers via invoke-acpx.sh directly (the prompt file will be picked up automatically):

```bash
bash "<SCRIPT_DIR>/invoke-acpx.sh" "~/.claude/debate-acpx.json" "<WORK_DIR>" "<name>"
```

Read the updated `<name>-output.md` and present:

```text
### Debate Round N — [Topic]

**<Reviewer1>:** [response]
**<Reviewer2>:** [response]

**Resolution:** [resolved/unresolved, why]
```

After each debate exchange, delete the prompt file: `rm -f <WORK_DIR>/<name>-prompt.txt`

---

## Step 6: Final Report

### 6a. SHA self-check (CRITICAL — runs before any APPROVED claim)

Before composing the final report, confirm that the plan.md you are about to call APPROVED is the same plan.md the reviewers actually saw. If you applied any Edit/Write to plan.md after the last reviewer round (e.g., a "surgical fix" in response to a Step 5 debate finding), the reviewers have NOT seen that change.

```bash
sha256sum "<WORK_DIR>/plan.md" | cut -d' ' -f1   # or shasum -a 256 on macOS
cat "<WORK_DIR>/round-active-plan-sha.txt"
```

Compare. If they differ, **you MUST run Step 6.5 before reporting APPROVED.** Do not let your own analysis ("I made the fix correctly") substitute for an external reviewer confirming it. That substitution is the exact failure mode this gate exists to prevent.

If you are tempted to write "I applied the fix and it resolves the concern" without running Step 6.5: stop. That sentence is the trap. Run the verification pass.

### 6b. Compose the report

```text
---
## acpx Review — Final Report (Round N of 3)

### Consensus Points
- [Things all reviewers agreed on]

### Unresolved Disagreements
- [Contradictions that remained after debate]

### Claude's Recommendation
[Synthesis: highest-priority concern, is the plan ready?]

### Final-state verification
[Cite the round whose plan SHA matches the current plan.md SHA. If a Step 6.5
verification pass was needed, cite it here too.]

### Overall VERDICT
VERDICT: APPROVED — All reviewers approved the plan (final-state SHA verified).
   OR
VERDICT: REVISE — [Reviewer(s)] identified concerns that should be addressed.
   OR
VERDICT: SPLIT — Reviewers disagree. [Summary]. Claude recommends: [proceed/revise].
```

---

## Step 6.5: Verification Pass (mandatory if plan SHA changed since last reviewer round)

This pass exists to catch the highest-leverage failure mode: the orchestrator applies a fix in response to reviewer feedback, then claims APPROVED based on its own analysis without re-running any reviewer. **A verification pass does NOT count against the 3-round revision budget** — it is re-reviewing the same logical plan with a fix applied, not a new revision cycle.

Triggers:
- Step 6a SHA self-check shows `round-active-plan-sha.txt` (or the most recent `rounds.jsonl` SHA) differs from current `plan.md`.
- You applied any Edit/Write to `plan.md` after Step 5 (debate) without re-running reviewers.

How to run:

1. Write a focused verification prompt for each reviewer that flagged the issue you fixed (or all reviewers if the change is broad). Use the lightest-cost reviewer when one will do — this is verification, not full re-review.
   ```bash
   cat > <WORK_DIR>/<name>-prompt.txt << 'VERIFY_EOF'
   The plan was edited after your previous review to address: [one-line summary].

   Specifically: [diff summary or the changed lines].

   Updated plan:
   [content of plan.md]

   Confirm: does this edit fully resolve your concern without introducing
   regressions? End with VERDICT: APPROVED or VERDICT: REVISE.
   VERIFY_EOF
   ```
2. Re-invoke the runner (parallel) or `invoke-acpx.sh` directly (single reviewer):
   ```bash
   bash "<SCRIPT_DIR>/run-parallel-acpx.sh" "~/.claude/debate-acpx.json" "<REVIEW_ID>" [reviewer1,reviewer2,...]
   ```
3. Read each reviewer's full updated output (Read tool, not grep).
4. Record the verification round:
   ```bash
   bash "<SCRIPT_DIR>/record-round.sh" "<WORK_DIR>" <ROUND_NUM> <VERDICT>
   ```
   Use the same round counter you were on (or `<ROUND_NUM>.v` if your skill state tracks integers — `record-round.sh` accepts integers only, so increment by 1 and note in the report that this round was verification-only).

   Note: `record-round.sh` validates the round is an integer. If you want to mark this as a verification pass without burning a revision-budget slot, use `<previous_round>+1` for the integer arg and **do not** treat it as Round N+1 of the 3-round budget — verification passes are unbounded.
5. If verification returns REVISE, drop back into Step 7 (revision loop) — but the underlying budget counter does not advance.
6. If verification returns APPROVED, return to Step 6 with the new SHA recorded as the latest approved state.

---

## Step 7: Revision Loop (if REVISE or SPLIT, max 3 total rounds)

1. **Claude revises the plan** — address highest-priority concerns
2. Write revision summary:
   ```bash
   cat > <WORK_DIR>/revisions.txt << 'EOF'
   [Revision bullets]
   EOF
   ```
3. Show revisions to user:
   ```text
   ### Revisions (Round N)
   - [What changed and why]
   ```
4. Rewrite `<WORK_DIR>/plan.md` with the revised plan
5. For each reviewer, write a context-rich prompt for the next round:
   ```bash
   cat > <WORK_DIR>/<name>-prompt.txt << 'REVISION_EOF'
   The plan has been revised based on reviewer feedback.

   Changes made:
   [content of revisions.txt]

   Updated plan:
   [content of plan.md]

   Re-review the updated plan. If your previous concerns were addressed, acknowledge it.
   End with VERDICT: APPROVED or VERDICT: REVISE.
   REVISION_EOF
   ```
6. Return to **Step 2** with incremented round counter

If max rounds (3) reached:
```text
## acpx Review — Max Rounds Reached

3 rounds completed. Remaining concerns:
[List unresolved issues]

Options:
- Address remaining concerns manually and re-run
- Proceed at your judgment given the feedback
```

---

## Step 8: Present & Persist Final Plan

Read `<WORK_DIR>/plan.md` and display:

```text
---
## Final Plan

[full plan content]

---
Review complete.
```

Then **persist the final plan to a durable location outside `<WORK_DIR>`** — the work dir is deleted in Step 9, so this is the only chance to save the reviewed plan. Write `<WORK_DIR>/plan.md` verbatim to a path that survives cleanup:

- If the plan originated from a file in the project (e.g. a plan under `docs/.../plans/`), write it back there.
- Otherwise default to `<repo-root>/plan-reviewed-<REVIEW_ID>.md`, or ask the user where they want it.

Record the path you saved to as `<SAVED_PLAN>`. It must be byte-identical to `plan.md` — Step 9 verifies the SHA before deleting anything.

## Step 9: Cleanup

Use `safe-cleanup.sh` instead of raw `rm -rf`. It enforces two gates before deleting the work dir:

1. **APPROVED gate** — refuses if `plan.md` was modified after the last APPROVED reviewer pass, so the artifacts needed to verify a post-fix plan aren't wiped first.
2. **SAVED gate** — refuses unless `--saved` points to a durable copy of `plan.md` with an identical SHA, so a successful review never ends with the only copy of the plan thrown away.

Pass the `<SAVED_PLAN>` path from Step 8:

```bash
bash "<SCRIPT_DIR>/safe-cleanup.sh" "<WORK_DIR>" --saved "<SAVED_PLAN>"
```

If safe-cleanup refuses:

- **APPROVED-gate (SHA mismatch) message:** the plan was edited after the last APPROVED round and Step 6.5 (verification pass) was skipped. **Do not** rerun with `--force` reflexively. Run Step 6.5 now; if verification returns APPROVED, re-save the plan and re-run cleanup.
- **SAVED-gate message** (no `--saved`, saved file not found, divergent SHA, or saved copy inside the work dir): you didn't durably persist the final plan. Complete Step 8 — write `plan.md` to a path outside `<WORK_DIR>` — then re-run with the correct `--saved` path.
- Only use `bash "<SCRIPT_DIR>/safe-cleanup.sh" "<WORK_DIR>" --force` if the user has explicitly directed you to abandon the plan (e.g., aborting the review and wanting the work dir gone).

---

## Rules

- **acpx handles everything** — except `gemini`. Gemini CLI's ACP mode is broken (hangs at initialize). `invoke-acpx.sh` detects `agent: gemini` and falls back to direct CLI invocation (`gemini -s -e ""`), which works with both OAuth and API key auth.
- **Parallel via bash + Agent.** `run-parallel-acpx.sh` runs external reviewers as background processes. A Claude Opus subagent runs in parallel via Agent with `run_in_background: true`. Both launch in the same tool-call message for true parallelism.
- **Debate via direct invoke.** Debate rounds call `invoke-acpx.sh` directly from the main agent (not subagents). Prompt files are picked up automatically.
- **No session resume needed.** acpx manages sessions internally. Each round injects full context via prompt files.
- **Config is king.** Adding a reviewer = adding an entry to `~/.claude/debate-acpx.json`.
- **Security:** Never inline plan content or AI output in shell strings — use files.
- **Timeout:** Each reviewer's timeout is in the config. The runner adds a 60s buffer to MAX_WAIT automatically.
- **Graceful degradation:** If a reviewer fails, skip it in synthesis. If all fail, return UNDECIDED.
- **Debate guard:** Skip debate if fewer than 2 reviewers succeeded.
- **Read fully, never grep-skim.** You MUST read each reviewer's complete output with the Read tool. Never use `grep -A`, `grep -iE`, or keyword extraction to summarize reviews — this reliably misses 50%+ of findings. If you catch yourself reaching for grep on reviewer output, stop and use Read instead.
- **Don't substitute self-analysis for review.** If you Edit/Write `plan.md` after the last reviewer round, you MUST run Step 6.5 (verification pass) before claiming APPROVED. Phrases like "I applied the fix and it resolves the concern" are the exact failure mode the SHA self-check exists to prevent. Verification passes are unbounded — they don't burn revision-budget rounds. Use them.
- **SHA-gated cleanup.** Step 9 uses `safe-cleanup.sh`, not `rm -rf`. It refuses to delete the work dir unless (a) `plan.md` still matches the last APPROVED state and (b) `--saved` points to a durable, byte-identical copy of the plan. A refusal is your signal to verify or to save the plan — not to add `--force`. The work dir is the only copy of the final plan until Step 8 persists it.
- **Revision discipline:** Make real improvements, not cosmetic changes.
- **User control:** If a revision would contradict the user's explicit requirements, skip it and note it.

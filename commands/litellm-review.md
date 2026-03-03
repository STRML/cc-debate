---
description: Run AI reviewers in parallel via LiteLLM proxy, synthesize feedback, debate contradictions, and produce a consensus verdict. Supports any model available through LiteLLM. Configure reviewers in ~/.claude/debate-litellm.json.
allowed-tools: Bash(bash ~/.claude/debate-scripts/debate-setup.sh:*), Bash(bash ~/.claude/debate-scripts/run-parallel-litellm.sh:*), Bash(bash ~/.claude/debate-scripts/invoke-litellm.sh:*), Bash(curl -s:*), Bash(rm -rf /tmp/claude/ai-review-:*), Write(/tmp/claude/ai-review-*)
---

# AI Multi-Model Plan Review (LiteLLM)

Run all configured AI reviewers in parallel via LiteLLM, synthesize their feedback, debate contradictions, and produce a final consensus verdict. Max 3 total revision rounds.

Arguments:
- First arg: optional comma-separated reviewer names (e.g. `opus,deepseek`). Defaults to all from config.
- `skip-debate` — skip the targeted debate phase, go straight to final report.

---

## Step 1: Prerequisites & Setup

### 1a. Validate config

Read `~/.claude/debate-litellm.json`. If missing, stop:
```
Config not found: ~/.claude/debate-litellm.json
Run /debate:litellm-setup to create it.
```

Parse `base_url` and reviewer list. If a comma-separated reviewer list was passed as argument, filter to only those reviewers.

### 1b. Check LiteLLM connectivity

```bash
curl -s --max-time 5 http://localhost:8200/models > /dev/null 2>&1
```

If connection fails, stop:
```
LiteLLM proxy not reachable at <base_url>.
Start your LiteLLM proxy first, then retry.
```

### 1c. Generate session ID & temp dir

Verify `~/.claude/debate-scripts` exists. If not:
```
~/.claude/debate-scripts not found.
Run /debate:setup first to create the stable scripts symlink.
```

Run setup:
```bash
bash ~/.claude/debate-scripts/debate-setup.sh
```

Note `REVIEW_ID`, `WORK_DIR`, and `SCRIPT_DIR` from output.

### 1d. Announce

List the reviewers that will run:

```text
## LiteLLM Review — Starting

Reviewers:
  opus      → claude-opus-4-6     (The Skeptic, 300s)
  deepseek  → deepseek.v3-v1:0    (The Pragmatist, 120s)
  sonnet    → claude-sonnet-4-6   (The Editor, 180s)

Proxy: http://localhost:8200/v1
```

### 1e. Capture the plan

Write the current plan to `<WORK_DIR>/plan.md`.

If there is no plan in context, ask the user to paste it or describe what to review.

---

## Step 2: Parallel Review (Round N)

### Run reviews

Execute the parallel runner:

```bash
bash "<SCRIPT_DIR>/run-parallel-litellm.sh" "<REVIEW_ID>" "<REVIEWER_LIST>"
```

Where `<REVIEWER_LIST>` is the comma-separated list of reviewer names (or omitted for all).

**Important:** This blocks until all reviewers complete. Use `timeout: 600000` on the Bash tool call.

### Check results

For each configured reviewer, read:
- `<WORK_DIR>/<name>-exit.txt` — exit code
- `<WORK_DIR>/<name>-output.md` — review text

Exit code meanings:
- `0` — success
- `124` — timed out
- Other — error (check output for details)

---

## Step 3: Present Reviewer Outputs

For each completed reviewer:

```
---
## <Name> Review — Round N (<Model>)

[content of <name>-output.md]
```

For failed/timed-out reviewers:
```
## <Name> Review — Round N

⚠️ <Name> timed out after <timeout>s / failed (exit <code>). Skipping.
```

---

## Step 4: Synthesize

Read all successful reviewer outputs and categorize:

```
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

---

## Step 5: Targeted Debate (unless `skip-debate` was passed or fewer than 2 reviewers succeeded)

Max 2 debate rounds. Skip if no contradictions.

For each contradiction, write debate prompts to files:

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

Then invoke each debating reviewer:

```bash
bash "<SCRIPT_DIR>/invoke-litellm.sh" "<WORK_DIR>" "<name>"
```

(No model/timeout args needed — they're read from config.)

Read the updated `<name>-output.md` and present:

```
### Debate Round N — [Topic]

**<Reviewer1>:** [response]
**<Reviewer2>:** [response]

**Resolution:** [resolved/unresolved, why]
```

---

## Step 6: Final Report

```
---
## LiteLLM Review — Final Report (Round N of 3)

### Consensus Points
- [Things all reviewers agreed on]

### Unresolved Disagreements
- [Contradictions that remained after debate]

### Claude's Recommendation
[Synthesis: highest-priority concern, is the plan ready?]

### Overall VERDICT
VERDICT: APPROVED — All reviewers approved the plan.
   OR
VERDICT: REVISE — [Reviewer(s)] identified concerns that should be addressed.
   OR
VERDICT: SPLIT — Reviewers disagree. [Summary]. Claude recommends: [proceed/revise].
```

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
   ```
   ### Revisions (Round N)
   - [What changed and why]
   ```
4. Rewrite `<WORK_DIR>/plan.md` with the revised plan
5. For each reviewer, write a context-rich prompt file for the next round:
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
```
## LiteLLM Review — Max Rounds Reached

3 rounds completed. Remaining concerns:
[List unresolved issues]

Options:
- Address remaining concerns manually and re-run
- Proceed at your judgment given the feedback
```

---

## Step 8: Present Final Plan

Read `<WORK_DIR>/plan.md` and display:

```
---
## Final Plan

[full plan content]

---
Review complete.
```

## Step 9: Cleanup

```bash
rm -rf /tmp/claude/ai-review-${REVIEW_ID}
```

---

## Rules

- **No provider CLIs needed.** Everything goes through LiteLLM's OpenAI-compatible API via curl.
- **No session resume.** Each round is stateless — full context is injected via prompt files.
- **Config is king.** Adding a reviewer = adding an entry to `~/.claude/debate-litellm.json`.
- **Security:** Never inline plan content or AI output in shell strings — use files and jq for JSON construction.
- **Timeout:** Each reviewer's timeout is in the config. The parallel runner uses max 450s poll wait.
- **Graceful degradation:** If a reviewer fails, skip it in synthesis. If all fail, return UNDECIDED.
- **Debate guard:** Skip debate if fewer than 2 reviewers succeeded.
- **Revision discipline:** Make real improvements, not cosmetic changes.
- **User control:** If a revision would contradict the user's explicit requirements, skip it and note it.

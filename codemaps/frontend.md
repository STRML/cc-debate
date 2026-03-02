# Frontend — debate plugin
_Updated: 2026-03-01_

## Note

This is a Claude Code CLI plugin — there is no web frontend. "Frontend" here means the user-facing interface: slash commands and their output formatting.

## Slash Commands (User Interface)

```
/debate:setup               Check prerequisites; create stable symlink; print settings.json snippet
/debate:all                 Full parallel review + synthesis + debate (recommended)
/debate:all skip-debate     Skip targeted debate phase
/debate:all shell-mode      Force shell execution (no team/agent)
/debate:codex-review        Iterative Codex-only loop
/debate:gemini-review       Iterative Gemini-only loop
/debate:opus-review         Iterative Opus-only loop (CLI subprocess with session resume)
/debate:opus-review-subagent Single-round Opus review via Task subagent (fast, no subprocess)
```

## Output Format

### Prerequisite Summary (`/debate:all` Step 1)
```
## AI Review — Prerequisite Check
Reviewers found:  ✅ codex  ✅ gemini  ✅ claude
Reviewers missing: ❌ [none]
Tools: ✅ jq
```

### Per-Reviewer Output (Round N)
```
## Codex Review — Round 1   [The Executor]
<concerns>
VERDICT: REVISE

## Gemini Review — Round 1  [The Architect]
<concerns>
VERDICT: REVISE

## Opus Review — Round 1    [The Skeptic]
<concerns>
VERDICT: REVISE
```

### Synthesis
```
## Synthesis
Unanimous: <shared concerns>
Unique to Codex: <codex-only>
Contradictions: <disagreements>
```

### Final Report
```
## Final Report — Round N of 3
VERDICT: APPROVED — unanimous
```

## Allowed Tools (Command Frontmatter)

Commands declare their tool permissions in YAML frontmatter using `allowed-tools:`. This enables Claude Code to auto-approve calls within the declared scope, avoiding per-call permission prompts.

`/debate:setup` prints the exact `settings.json` snippet for session-persistent approval.

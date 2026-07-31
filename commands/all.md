---
description: Everything /debate:run does, plus the Claude teammates — the full panel. Same arguments (preset name, reviewer subset, skip-debate).
allowed-tools: Bash(bash ~/.claude/debate-scripts/debate-setup.sh:*), Bash(bash ~/.claude/debate-scripts/invoke-acpx.sh:*), Bash(bash ~/.claude/debate-scripts/run-parallel-acpx.sh:*), Bash(bash ~/.claude/debate-scripts/record-round.sh:*), Bash(bash ~/.claude/debate-scripts/safe-cleanup.sh:*), Bash(sha256sum:*), Bash(shasum:*), Bash(rm -rf .tmp/ai-review-:*), Write(.tmp/ai-review-*), Write(~/.acpx/**), Read(~/.acpx/**), Read(~/.claude/debate-scripts/reviewer-prompts.md), Agent(subagent_type: general-purpose, model: fable), Agent(subagent_type: general-purpose, model: opus), SendMessage(*)
---

# AI Multi-Model Plan Review (full panel)

This is an alias for `/debate:run` with **exactly one difference**, and it is not a second
copy of the orchestrator. Execute the `run` command as written — same arguments (a preset
name, a comma-separated reviewer subset, and/or `skip-debate`), same steps. Any arguments
passed to `/debate:all` apply unchanged.

**The difference — Step 1a, rule 3 (no panel argument).** `/debate:run` spawns no Claude
teammates by default; `/debate:all` does. When no preset and no reviewer subset is given,
resolve `claude_reviewers` from the **top-level** `claude_reviewers` object rather than
treating it as `{}`. Everything else, including Step 2b's handling of that map, is
identical.

That is the whole point of the two names: `run` is the acpx panel on its own, which is the
cheap and vendor-diverse part, and `all` adds the in-session Claude teammates, which cost
main-loop tokens. A preset that names its own `claude_reviewers` wins under both commands,
so `/debate:run security` still gets its Claude seats.

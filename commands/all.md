---
description: Alias for /debate:run — run all (or a subset, or a named preset) of the configured AI reviewers in parallel, synthesize, debate, produce a consensus verdict.
allowed-tools: Bash(bash ~/.claude/debate-scripts/debate-setup.sh:*), Bash(bash ~/.claude/debate-scripts/invoke-acpx.sh:*), Bash(bash ~/.claude/debate-scripts/run-parallel-acpx.sh:*), Bash(bash ~/.claude/debate-scripts/record-round.sh:*), Bash(bash ~/.claude/debate-scripts/safe-cleanup.sh:*), Bash(sha256sum:*), Bash(shasum:*), Bash(rm -rf .tmp/ai-review-:*), Write(.tmp/ai-review-*), Write(~/.acpx/**), Read(~/.acpx/**), Read(~/.claude/debate-scripts/reviewer-prompts.md), Agent(subagent_type: general-purpose, model: fable), Agent(subagent_type: general-purpose, model: opus), SendMessage(*)
---

# AI Multi-Model Plan Review (alias)

This is an alias for `/debate:run`. Execute the `run` command exactly as written — same
arguments (a preset name, a comma-separated reviewer subset, and/or `skip-debate`), same
steps, same behavior. Any arguments passed to `/debate:all` apply unchanged.

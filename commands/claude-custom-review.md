---
description: Interactive Claude review — choose personalities and model before review starts. Shortcut for claude-review in interactive mode.
allowed-tools: SendMessage(*), Agent(subagent_type: general-purpose, model: fable), Agent(subagent_type: general-purpose, model: opus), Agent(subagent_type: general-purpose, model: sonnet), Read(~/.claude/debate-acpx.json)
---

# Claude Custom Review

This is a shortcut. Execute the `claude-review` skill in **interactive mode**:

- Show the personality picker and model selection from Step 1 of the `claude-review` skill
- Default model is **opus** — only switch to sonnet if the user explicitly asks
- Then follow all remaining steps in the `claude-review` skill exactly

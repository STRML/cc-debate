---
description: Shortcut for claude-review with the Skeptic pair (Fable + Opus) plus the Architect. Accepts --model sonnet to override the Architect's default opus.
allowed-tools: SendMessage(*), Agent(subagent_type: general-purpose, model: fable), Agent(subagent_type: general-purpose, model: opus), Agent(subagent_type: general-purpose, model: sonnet), Read(~/.claude/debate-acpx.json)
---

# Claude Double Review

This is a shortcut. Execute the `claude-review` skill with these presets:

- **Personalities:** Fable Skeptic, Opus Skeptic, Architect (if `fable_reviewer` is `false` in `~/.claude/debate-acpx.json`, the skeptic pair collapses to the Solo Skeptic per the claude-review skill — making this Solo Skeptic + Architect)
- **Model:** the Skeptics use their pinned models; Architect uses opus (or sonnet if `--model sonnet` was passed)

Follow all steps in the `claude-review` skill exactly, including the fable-preference check in Step 1; the personality presets above are otherwise your configuration.

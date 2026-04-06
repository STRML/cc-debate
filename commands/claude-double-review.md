---
description: Shortcut for claude-review with two reviewers (Skeptic + Architect). Accepts --model sonnet to override default opus.
allowed-tools: SendMessage(*), Agent(subagent_type: general-purpose, model: opus), Agent(subagent_type: general-purpose, model: sonnet)
---

# Claude Double Review

This is a shortcut. Execute the `claude-review` skill with these presets:

- **Personalities:** Skeptic, Architect
- **Model:** opus (or sonnet if `--model sonnet` was passed)

Follow all steps in the `claude-review` skill exactly. Skip Step 1 (resolve configuration) — the presets above are your configuration.

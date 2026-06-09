---
description: Shortcut for claude-review with a single Opus Skeptic (precision checks - arithmetic, boundaries, consistency sweeps, test coverage).
allowed-tools: SendMessage(*), Agent(subagent_type: general-purpose, model: opus)
---

# Opus Skeptic Review

This is a shortcut. Execute the `claude-review` skill with these presets:

- **Personalities:** Opus Skeptic only
- **Model:** opus (pinned — `--model` is ignored)

Follow all steps in the `claude-review` skill exactly. Skip Step 1 (resolve configuration) — the presets above are your configuration.

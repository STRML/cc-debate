---
description: Shortcut for claude-review with a single Fable Skeptic (deep behavioral reasoning, pinned to fable). Ignores the stored claude_reviewers.skeptic preference — invoking this is explicit consent to fable's cost.
allowed-tools: SendMessage(*), Agent(subagent_type: general-purpose, model: fable)
---

# Fable Skeptic Review

This is a shortcut. Execute the `claude-review` skill with these presets:

- **Personalities:** Fable Skeptic only
- **Model:** fable (pinned — `--model` is ignored)
- **Skeptic preference:** skip the `claude_reviewers.skeptic` config check — the user asked for fable by name

Follow all steps in the `claude-review` skill exactly. Skip Step 1 (resolve configuration) — the presets above are your configuration.

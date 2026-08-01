# Hermes support for cc-debate

This directory is the Hermes delivery of this repo. `SKILL.md` is a self-contained Hermes
skill that reproduces cc-debate's workflow (parallel AI review → synthesize → debate →
iterate to consensus) using Hermes's native `delegate_task` instead of the acpx/codex/gemini
CLI machinery in `../scripts` and `../commands`.

## Install in Hermes

```bash
# point Hermes at this repo's skill (any of):
hermes skills install ./hermes            # or symlink into $HERMES_HOME/skills/
```

Then trigger with: `debate this plan`, `debate` (reviews current changeset), `debate <preset>`,
`debate codex,pentester`, `debate skip-debate`.

Optional panel config at `$HERMES_HOME/debate.json` — start from `templates/debate.json`.
Set a reviewer's `"backend"` to `codex`/`claude`/`gemini`/`opencode` to shell out to that
CLI for truly independent reviewer models (see the relevant Hermes skill in this repo's
sibling plugins / Hermes's bundled `codex`, `claude-code`, `opencode` skills).

Same config schema (`reviewers`/`presets`/`default_reviewers`/`max_rounds`) as the acpx
panel, minus the Claude-permission and `~/.claude` coupling. See `../README.md` for the
full v2 design rationale.

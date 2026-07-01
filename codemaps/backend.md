# Backend — debate plugin
_Updated: 2026-03-17_

## Commands (`commands/`)

| File | Slash Command | Purpose |
|------|--------------|---------|
| `all.md` | `/debate:all [reviewers] [skip-debate]` | Master: parallel review + synthesis + debate (up to 3 rounds) via acpx |
| `claude-review.md` | `/debate:claude-review` | Consolidated Claude review — 6 personalities (Fable + Opus skeptic pair default), plan inlined into subagent prompt, `claude_reviewers.skeptic` preference |
| `claude-double-review.md` | `/debate:claude-double-review` | Shortcut: skeptic pair + Architect |
| `claude-custom-review.md` | `/debate:claude-custom-review` | Shortcut: interactive personality + model picker |
| `fable.md` | `/debate:fable` | Shortcut: single Fable Skeptic (ignores `claude_reviewers.skeptic` preference) |
| `mythos.md` | `/debate:mythos` | Alias for `/debate:fable` |
| `opus.md` | `/debate:opus` | Shortcut: single Opus Skeptic |
| `acpx-setup.md` | `/debate:acpx-setup` | Config setup: create/validate `~/.claude/debate-acpx.json`, probe agents |
| `setup.md` | `/debate:setup` | Prerequisite check + stable symlink creation + settings snippet |

## Scripts (`scripts/`)

| File | Purpose |
|------|---------|
| `debate-setup.sh` | Generates `REVIEW_ID`, `WORK_DIR` (`.tmp/ai-review-<ID>`), outputs `SCRIPT_DIR` |
| `create-links.sh` | Creates `~/.claude/debate-scripts` symlink to installed scripts dir |
| `invoke-acpx.sh` | Invokes any acpx agent: reads config, builds prompt, wraps with system `timeout`, captures output |
| `run-parallel-acpx.sh` | Spawns `invoke-acpx.sh` per reviewer with nohup+disown, polls `*-exit.txt` until done |

## Script I/O Contract

`invoke-acpx.sh` reads from and writes to `$WORK_DIR`:

### Inputs
- `plan.md` — plan to review (always required)
- `<name>-prompt.txt` — debate/resume prompt (optional; falls back to config system_prompt + plan.md)

### Outputs
- `<name>-output.md` — review text
- `<name>-stderr.log` — acpx stderr (debugging)
- `<name>-exit.txt` — exit code (0 = success, 124 = timeout)
- `<name>-acpx-prompt.txt` — generated initial prompt (debugging)

## Config (`~/.claude/debate-acpx.json`)

```json
{
  "reviewers": {
    "<name>": {
      "agent": "<acpx-agent-name>",
      "timeout": 120,
      "system_prompt": "optional persona prompt"
    }
  }
}
```

Available acpx agents: codex, claude, cursor, copilot, kimi, kiro, qwen, opencode, kilocode. The `antigravity` (agy) and `opus` reviewers are invoked directly, not via acpx.

## Plugin Metadata (`.claude-plugin/`)

- `plugin.json` — name, version, description, author, license
- `marketplace.json` — marketplace listing with install instructions

Current version: **2.0.2**

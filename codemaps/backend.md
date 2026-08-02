# Backend — debate plugin
_Updated: 2026-07-11_

## Commands (`commands/`)

| File | Slash Command | Purpose |
|------|--------------|---------|
| `run.md` | `/debate:run [reviewers\|preset] [skip-debate]` | Master: parallel review + synthesis + debate (up to 3 rounds) via acpx. Alias: `/debate:all` (`all.md`) |
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
| `create-links.sh` | Creates `~/.claude/debate-scripts` and `~/.claude/debate-workflows` symlinks to the installed dirs |
| `changeset-diff.sh` | Writes the changeset under review; builds in a temp file and renames, so a partial diff is never readable as a complete one |
| `create-opencode-agent.sh` | Adds an acpx seat for any models.dev provider via opencode; writes the wrapper AND registers it in `~/.acpx/config.json` |
| `create-litellm-agent.sh` | Same, for providers models.dev does not list — routes through a LiteLLM proxy |
| `seat-report.sh` | Per-seat contribution from a panel result: sole vs corroborated vs refuted, for deciding whether a lens earns its slot |
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

### Claude teammate outputs (v2.6.0 — no script; written by the teammate itself)
The Claude skeptic/persona teammates spawned by `run.md` / `claude-review.md` deliver
file-based like acpx, but without a runner. Each writes its own review to
`<WORK_DIR>/claude-<persona>-r<N>-output.md` (verification pass: `-verify-output.md`).
No exit file — a teammate has delivered iff its output file exists and is non-empty.
`SendMessage` is a liveness ping only. See `codemaps/architecture.md` § Delivery.

## Config (`~/.claude/debate-acpx.json`)

```json
{
  "reviewers": {
    "<name>": {
      "agent": "<acpx-agent-name>",
      "timeout": 120,
      "model": "optional model id",
      "effort": "unused since #35 — no agent reads it; remove from configs",
      "mode": "session | exec",
      "retries": 1,
      "system_prompt": "optional persona prompt"
    }
  }
}
```

Available acpx agents: codex, claude, cursor, copilot, kimi, kiro, qwen, opencode, kilocode. The `antigravity` (agy) and `opus` reviewers are invoked directly, not via acpx.

`effort` is unused since #35 (the codex-exec branch that read it is gone); `tests/test-references.sh` flags any `effort` in a reviewer config as a silent no-op. The luna-floor and 900s-timeout rules went with the seat. The timeout lint (positive integer) remains: both layers otherwise swallow a malformed value.

`mode` defaults to `session` (persistent acpx session, context kept across rounds).
`mode: "exec"` sends one-shots and skips `sessions ensure` — needed for agents that
return an empty turn on the second prompt into a session (seen with opencode-backed
agents such as `kimi-k3`).

`retries` defaults to 1 and covers a different failure: an agent that ends a turn
with no final message at all. Only a blank turn is retried; a non-zero exit or a
timeout goes straight to `handle_invocation_result`. A blank review is detected by
`output_is_blank`, not `[ -s ]` — acpx writes a trailing newline even when the agent
said nothing, so a contentless run is 1 byte, not 0.

## Plugin Metadata (`.claude-plugin/`)

- `plugin.json` — name, version, description, author, license
- `marketplace.json` — marketplace listing with install instructions

Current version: **2.6.0**

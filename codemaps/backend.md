# Backend — debate plugin
_Updated: 2026-08-10_

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
| `select-panel.py` | Picks one model per seat from the registry maximizing distinct labs, strongest-reasoning on the deepest seat, cheapest for the rest; per-seat effort auto-scaling by depth tier. Accepts `--private-repo` (hard ZDR constraint: route 31501 pool, and a private seat no ZDR model can fill fails the panel — no non-ZDR fallback), `--min-effort` (floor for deepest seat), and `--agents <seat=agent,...>` — a per-seat provider-feasibility constraint so a codex seat is never handed claude-opus-5 / gemini / glm (2026-08-06, 4-of-6 dead panel). A seat no agent can fill is left unfilled (degrades to its config default on non-private runs only), not fatal. Hard `--max-cost` budget was removed — effort-tiering is the sole cost lever. |
| `refresh-models.py` | Syncs the local registry from upstream datasources; auto-adds new model IDs, preserves user keys. |
| `invoke-acpx.sh` | Invokes any acpx agent — plus the direct-CLI branches: `antigravity`/`agy`, `opus`/`claude --print` (now proxy-aware via `transport:proxy` + `route`), and effort-scaled `codex` (`codex exec -c model_reasoning_effort`). Reads config, builds prompt, wraps with system `timeout`, captures output |
| `run-parallel-acpx.sh` | Spawns `invoke-acpx.sh` per reviewer under `timeout -k 5 <seat budget>` and `wait`s on them. No `disown` and no poll loop: the wait status IS the seat's exit code, and the runner backfills `<name>-exit.txt` for a seat killed before its EXIT trap ran. Seat budget is `timeout × (retries + 1) + 60`, overridable with `POLL_MAX_WAIT`. On a host with no usable `timeout`/`gtimeout` (stock macOS, GitHub's macos runners), it falls back to one watchdog for the whole panel at the slowest seat's budget — the old global bound, kept because an unbounded panel hangs the orchestrator. Both this script and `invoke-acpx.sh` require the resolved binary to be `-x` — `command -v` reports the first PATH match without checking the execute bit, and using it kills the seat at exec with 126. Teardown (watchdog, and the INT/TERM trap) walks the process tree via `pgrep -P`, because signalling only the pid the runner holds reaps the wrapper and leaves the agent running with ppid 1. Reads `effective_effort`, `harness`, `transport`, and `route` per seat from `panel.json` and forwards them. Skips `subagent`-harness seats (delegated to the caller). |

## Script I/O Contract

`invoke-acpx.sh` reads from and writes to `$WORK_DIR`:

### Inputs
- `plan.md` — plan to review (always required)
- `<name>-prompt.txt` — debate/resume prompt (optional; falls back to config system_prompt + plan.md)
- `MODEL` env (optional) — per-seat model override from the panel selector; passed to acpx as `--model <id>` (or `codex -m <id>` on the direct branch). `run-parallel-acpx.sh` sets it per seat from `ACPX_SEAT_MODELS` (the select-panel.py output or a flat `{seat: model_id}` map) or the single-model `DEBATE_MODEL`.
- `EFFORT` env (optional) — per-seat reasoning effort from the selector (`effective_effort`), falling back to the reviewer's configured `effort`. Only a `codex` seat honors it, via the direct branch (`codex exec -c model_reasoning_effort=<level>`). Every other transport handled by `invoke-acpx.sh` logs `EFFORT=<level> not supported by transport <agent>` and runs at its default. A `subagent`-harness seat never reaches `invoke-acpx.sh` (filtered in `run-parallel-acpx.sh` pre-spawn; dispatched via Hermes `delegate_task` instead), so it receives neither `EFFORT` nor the fallback log. The runner always sets `EFFORT` (empty = agent default), so a caller's `EFFORT` cannot leak into a seat.

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
      "effort": "none|minimal|low|medium|high|xhigh|max — codex seats only",
      "mode": "session | exec",
      "retries": 1,
      "system_prompt": "optional persona prompt"
    }
  },
  "private_repos": ["/path/to/private/repo", "..."] ,
  "presets": { "<name>": { "reviewers": [...], "claude_reviewers": {...} } }
}
```

Available acpx agents: codex, claude, cursor, copilot, kimi, kiro, qwen, opencode, kilocode. Three reviewers are invoked directly, not via acpx: `antigravity` (agy CLI), `opus` (`claude --print`), and an effort-scaled `codex` seat (`codex exec` when `EFFORT` is set — acpx cannot pass `model_reasoning_effort`). This is flagged tech debt: acpx middleware does not apply to direct seats.

The config `effort` key is the seat's default reasoning level, resolved like `model` and `mode`: the runtime `EFFORT` env var (the selector's `effective_effort`) wins, the config is the fallback, and absent both the agent runs at its own default. It matters because effort is also what routes a codex seat to the direct CLI — a codex seat with no effort from either source takes the acpx transport instead. `tests/test-references.sh` lints it two ways: `effort` on a non-codex agent is a no-op, and the value must be one of `none|minimal|low|medium|high|xhigh|max` (it is passed to `codex exec` verbatim, so a typo would otherwise surface as a codex error mid-run). The timeout lint (positive integer) remains: both layers otherwise swallow a malformed value.

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

Current version: **3.2.0**

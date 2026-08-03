# Architecture — debate plugin
_Updated: 2026-08-03_

## Overview

`cc-debate` is a Claude Code plugin that sends implementation plans to multiple AI models for parallel review via [acpx](https://github.com/openclaw/acpx) — with direct-CLI exceptions for `antigravity`/`opus` and an effort-scaled `codex` seat. It synthesizes feedback, resolves contradictions via targeted debate, and produces a consensus verdict before code is written.

## Top-level Layout

```
cc-debate/
├── .claude-plugin/         # Plugin metadata (marketplace.json, plugin.json)
├── commands/               # Claude Code slash commands (*.md skill files)
├── scripts/                # Shell scripts for reviewer invocation and orchestration
├── docs/plans/             # Historical design plans
└── README.md
```

## Execution Flow

```
/debate:run  (alias: /debate:all)
    └── commands/run.md         # Master orchestrator
         ├── 1a. Read ~/.claude/debate-acpx.json
         ├── 1b. Generate REVIEW_ID, WORK_DIR via debate-setup.sh
         ├── 1c. Announce reviewers
         ├── 1d. Write plan.md to WORK_DIR
         ├── 1e. Detect EXEC_MODE (team / agent)
         │
         ├── Round N: Parallel review (acpx reviewers + Claude teammates)
         │    ├── reviewers → run-parallel-acpx.sh → invoke-acpx.sh
         │    │    ├── acpx <agent> (default)
         │    │    ├── agy / claude --print (direct: antigravity / opus)
         │    │    └── codex exec (direct, when EFFORT set — effort auto-scaling)
         │    │    writes <WORK_DIR>/<name>-output.md
         │    └── Claude teammates → Agent tool, run_in_background: true
         │         each writes <WORK_DIR>/claude-<persona>-r<N>-output.md
         │         (SendMessage retained only as a liveness ping)
         │    Rounds 2+/verify respawn fresh teammates (idle ones never wake)
         │
         ├── Step 3: Read ALL output files uniformly (acpx + Claude), reconcile
         │           (every spawned teammate must have a non-empty output file)
         ├── Step 4: Synthesize + check for APPROVED
         ├── Step 5: Debate (targeted per-reviewer questions)
         ├── Step 6: Final report + revision loop
         └── Step 9: Cleanup (rm WORK_DIR, TeamDelete)
```

## Two Execution Modes

| Mode | Trigger | Continuity | Concurrency |
|------|---------|-----------|-------------|
| `team` | `TeamCreate` tool available + succeeded | Real (teammates persist) | Parallel spawns round 1, SendMessage round 2+ |
| `agent` | `TeamCreate` unavailable or failed | Fake (context injection) | Parallel round 1, sequential later |

## Stable Symlink Pattern

`debate:setup` runs `scripts/create-links.sh`, creating `~/.claude/debate-scripts →` installed scripts dir and `~/.claude/debate-workflows →` installed workflows dir. Both are checked by `acpx-env-snapshot.sh`; the workflows link is what `/debate:panel` loads `review-panel.js` from, and an install missing only that link runs everything except the panel.

All command files call `bash ~/.claude/debate-scripts/<script>.sh` — literal, stable path; no version in path, no runtime glob.

## Reviewer Invocation

Reviewers run through `invoke-acpx.sh`, which wraps timeout handling, config resolution, and output file management. Most seats go through `acpx --format quiet --approve-reads <agent> --file <prompt>`, but three run the agent CLI directly:
- `antigravity` — `agy -p "<plan>" --sandbox` under a Python PTY (acpx has no adapter).
- `opus` — `claude --print --permission-mode plan --model <id>` (acpx has no adapter).
- `codex` with `EFFORT` set — `codex exec --ephemeral -m <model> -c model_reasoning_effort=<level> -s read-only -o <outfile> -` (acpx cannot pass `model_reasoning_effort`; effort auto-scaling #31 Q2). A non-codex seat with `EFFORT` logs the fallback and runs at its default.

Reviewer configuration (agent name, timeout, system prompt) is stored in `~/.claude/debate-acpx.json`. The panel selector's per-seat model and effort reach the child as `MODEL`/`EFFORT` env vars via `run-parallel-acpx.sh`.

## Delivery — file-based for every reviewer (v2.6.0)

Both reviewer channels converge on files in `<WORK_DIR>`, so the orchestrator reads
outputs uniformly and never depends on a mailbox message surfacing:

- **reviewers** — the `invoke-acpx.sh` runner captures the agent's output (stdout for acpx/opus, the `-o` file for direct codex) to `<WORK_DIR>/<name>-output.md`. The agent itself is write-denied.
- **Claude teammates** (skeptic/persona, spawned via the Agent tool) — no runner to
  capture output, so each teammate writes its **own** review to
  `<WORK_DIR>/claude-<persona>-r<N>-output.md`. That single write is its only permitted
  one (allowlisted via `Write(.tmp/ai-review*)`); plan.md and repo source stay read-only.
  `SendMessage` to `main` is retained only as a one-line liveness ping — its body is not
  parsed, so a dropped ping loses nothing.

Before v2.6.0 the Claude side was mailbox-based and lossy: a teammate's SendMessage'd
review could drop silently, shrinking the panel. A reconciliation gate now asserts every
spawned teammate produced a non-empty output file before a round is recorded, and wedge
detection keys on file existence (`[ -s … ]`, run-scoped) rather than a cross-run
transcript grep.

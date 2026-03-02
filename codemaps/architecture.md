# Architecture — debate plugin
_Updated: 2026-03-01_

## Overview

`cc-plan-debate` is a Claude Code plugin that sends implementation plans to multiple AI models for parallel review. It synthesizes feedback, resolves contradictions via targeted debate, and produces a consensus verdict before code is written.

## Top-level Layout

```
cc-plan-debate/
├── .claude-plugin/         # Plugin metadata (marketplace.json, plugin.json)
├── commands/               # Claude Code slash commands (*.md skill files)
├── reviewers/              # Reviewer definitions (persona, invocation, output contract)
├── scripts/                # Shell scripts for reviewer invocation and orchestration
├── docs/plans/             # Historical design plans
└── README.md
```

## Execution Flow

```
/debate:all
    └── commands/all.md         # Master orchestrator
         ├── 1a. Check binaries (codex / gemini / claude / jq)
         ├── 1b. Generate REVIEW_ID, WORK_DIR via debate-setup.sh
         ├── 1c. Write plan.md to WORK_DIR
         ├── 1d. Announce reviewers + timeouts
         ├── 1e. Detect EXEC_MODE (team / agent / shell)
         │
         ├── Round N: Parallel review
         │    ├── shell  → run-parallel.sh (nohup + poll)
         │    ├── team   → TeamCreate once + SendMessage for rounds 2+
         │    └── agent  → Agent tool with run_in_background: true
         │
         ├── Step 3: Read output files (codex/gemini/opus-output.md)
         ├── Step 4: Synthesize + check for APPROVED
         ├── Step 5: Debate (targeted per-reviewer questions)
         ├── Step 6: Revise plan (write new plan.md)
         └── Step 9: Cleanup (rm WORK_DIR, TeamDelete)
```

## Three Execution Modes

| Mode | Trigger | Continuity | Concurrency |
|------|---------|-----------|-------------|
| `team` | `TeamCreate` tool available + succeeded | Real (teammates persist) | Parallel spawns round 1, SendMessage round 2+ |
| `agent` | `TeamCreate` unavailable or failed | Fake (context injection) | Parallel round 1, sequential later |
| `shell` | `shell-mode` arg or user preference | N/A (subprocess) | nohup + disown + poll |

## Stable Symlink Pattern

`debate:setup` runs `scripts/create-links.sh`, creating `~/.claude/debate-scripts →` installed scripts dir.

All command files call `bash ~/.claude/debate-scripts/<script>.sh` — literal, stable path; no version in path, no runtime glob.

## Reviewer Substitution

When a CLI binary is missing in team mode, a Claude teammate with the same persona substitutes:
- `codex` missing → teammate "The Executor"
- `gemini` missing → teammate "The Architect"
- `claude` missing → teammate "The Skeptic"

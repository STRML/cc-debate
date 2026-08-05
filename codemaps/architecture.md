# Architecture — debate plugin
_Updated: 2026-08-05_

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

## Panel Auto-tuning (three signals)

`/debate:run` sizes itself on three axes before dispatching:

| Axis | Signal source | Consumed by |
|------|--------------|-------------|
| **Size** | `review-panel.js` classify: filesChanged/linesAdded, securityGrep, addsAbstraction, docsOnly | LENSES table buys/seats seats (`pickSeats()`) in changeset mode |
| **Sensitivity (ZDR)** | `DEBATE_PRIVATE=1` env, `private_repos` config list, or `gh repo view --json isPrivate` → `--private-repo` on the selector | `select-panel.py` fail-closed on private repos: ZDR-only pool (route 31501 = openrouter); insufficient ZDR models → hard error, never a non-ZDR panel. Proxy branch forces `DS4_ZDR=1`. |
| **Difficulty** | classify shape → `--min-effort` tier (linesAdded≥300 or securitySensitive→xhigh, ≥150/addsAbstraction→high, ≥50→medium, else low) | selector's `_tier_for` per-seat effort scaling |

Changeset mode sizes seats from the diff; plan mode uses the config's personas.
Explicit selectors (preset name / reviewer subset) override lens seat-picking but
classify still runs to measure. The selector assigns model+effort per seat; a seat
with no assignment falls back to its configured agent default.

## Two Execution Modes

| Mode | Trigger | Continuity | Concurrency |
|------|---------|-----------|-------------|
| `team` | `TeamCreate` tool available + succeeded | Real (teammates persist) | Parallel spawns round 1, SendMessage round 2+ |
| `agent` | `TeamCreate` unavailable or failed | Fake (context injection) | Parallel round 1, sequential later |

## Stable Symlink Pattern

`debate:setup` runs `scripts/create-links.sh`, creating `~/.claude/debate-scripts →` installed scripts dir and `~/.claude/debate-workflows →` installed workflows dir. Both are checked by `acpx-env-snapshot.sh`; the workflows link is what `/debate:run` loads `review-panel.js` from in changeset mode (classify + report stages), and an install missing only that link degrades changeset review.

All command files call `bash ~/.claude/debate-scripts/<script>.sh` — literal, stable path; no version in path, no runtime glob.

## Reviewer Invocation

Reviewers run through `invoke-acpx.sh`, which wraps timeout handling, config resolution, and output file management. Most seats go through `acpx --format quiet --approve-reads <agent> --file <prompt>`, but three run the agent CLI directly:
- `antigravity` — `agy -p "<plan>" --sandbox` under a Python PTY (acpx has no adapter).
- `opus` — `claude --print --permission-mode plan --model <id>` (acpx has no adapter).
- `codex` with `EFFORT` set — `codex exec ...` (below; acpx cannot pass `model_reasoning_effort`).

Codex with `EFFORT` set runs `codex exec --ephemeral -m <model> -c model_reasoning_effort=<level> -s read-only -o <outfile> -` directly (acpx cannot pass `model_reasoning_effort`; effort auto-scaling #31 Q2). A non-codex seat with `EFFORT` logs the fallback and runs at its default.

Reviewer configuration (agent name, timeout, system prompt) is stored in `~/.claude/debate-acpx.json`. The panel selector's per-seat model and effort reach the child as `MODEL`/`EFFORT` env vars via `run-parallel-acpx.sh`; each falls back to the config's `model`/`effort` when the selector does not supply one, so a run that skips the selector still honors the seat's configured defaults. The selector also forwards `transport: proxy` + `route` per seat, which routes the child to the cc-ds4 proxy (`claude --print --model ds4-<eff>` with `ANTHROPIC_BASE_URL=http://127.0.0.1:<route>`) — this is how a DeepSeek seat gets its effort honored and how ZDR (route 31501) is enforced on private repos. `select-panel.py` takes `--registry`, `--seats`, `--deepest`, `--installed-harnesses`, `--min-effort`, `--private-repo`; the hard `--max-cost` budget path was removed (effort tiering is the only cost lever).

## Delivery — file-based for every reviewer (v2.6.0)

Both reviewer channels converge on files in `<WORK_DIR>`, so the orchestrator reads
outputs uniformly and never depends on a mailbox message surfacing:

- **reviewers** — the `invoke-acpx.sh` runner captures the agent's output to `<WORK_DIR>/<name>-output.md`. The agent itself is write-denied.
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

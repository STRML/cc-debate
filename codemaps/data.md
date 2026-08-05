# Data Models — debate plugin
_Updated: 2026-08-05_

## Temp Work Directory

`<REPO_ROOT>/.tmp/ai-review-<REVIEW_ID>/` (8-char hex ID). `chmod 700`. Deleted by `safe-cleanup.sh` (SHA-gated — refuses if plan drifted post-APPROVED or the plan wasn't durably saved).

```text
ai-review-<ID>/
├── plan.md                     # Review target (plan mode). Overwritten on revision.
├── changeset.diff              # Review target (changeset mode, frozen by changeset-diff.sh)
├── changeset-base.txt          # Base SHA the diff was generated against
├── panel.json                  # Selector output: per-seat model/effort/route/harness/transport
├── panel-state.json            # Classify output: {diff, seats, seatsSkipped}
├── round-active-plan-sha.txt   # SHA of plan.md at last reviewer round (Step 6a gate)
├── last-approved-sha.txt       # SHA at last APPROVED round (cleanup gate)
├── review-target.txt           # "plan.md" or "changeset.diff" (cleanup target gate)
├── rounds.jsonl                # Per-round verdict log: line per {round,verdict,sha,ts}
├── revisions.txt               # Revision summary between rounds (Step 7)

│ # Per acpx reviewer (invoke-acpx.sh / runner):
├── <name>-output.md            # Review text (agent stdout, sanitized)
├── <name>-exit.txt             # Exit code: 0=ok, 4=session fail, 124=timeout
├── <name>-stderr.log           # Agent stderr
├── <name>-invoke.log           # nohup runner log
├── <name>-acpx-prompt.txt      # Generated initial prompt (debugging)
├── <name>-prompt.txt           # Debate/resume prompt (optional; cleared between rounds)

│ # Per Claude teammate (self-written, no runner):
├── claude-<persona>-r<N>-output.md   # Round N review (non-empty = delivered)
├── claude-<persona>-r<N>-b-output.md # Respawn variant (both kept when both land)
├── claude-<persona>-verify-output.md # Verification pass review (Step 6.5)
```

## Registry (`~/.claude/debate-models.json` or `hermes/templates/debate-models.json`)

Keyed by model slug. The bundled seed is the fallback; the user copy is preferred.

```json
{
  "<slug>": {
    "name": "Human-readable",
    "harness": "acpx | subagent",
    "provider": "openai | anthropic | google | deepseek | zai",
    "model_id": "api-model-identifier",
    "family": "oai | claude | gemini | deepseek | glm",
    "lab": "openai | anthropic | google | deepseek | zai",
    "strengths": ["code", "cost", "general", "math", "reasoning", "speed", "tricky"],
    "effort": "low | medium | high | xhigh | max",
    "effort_range": ["low", ..., "max"],
    "price": {"in": 1.0, "out": 5.0, "cost_per_task": 0.07},
    "cost": "cheap | mid | premium",
    "repo_aware": true | false,
    "available": true | false,
    "transport": "proxy",
    "route": 31501 | 31502 | null,
    "source": "user | AA",
    "as_of": "2026-08-03T00:00:00Z",
    "elo": 1455.0
  }
}
```

`transport: "proxy"` + `route` only on DeepSeek proxy-seat entries. Route 31501 = openrouter (ZDR forced via `DS4_ZDR=1`), route 31502 = nous. The selector treats `route == 31501` as the ZDR signal — there is no separate `zdr` boolean field. A `route` outside `{null, 31501, 31502}` is rejected at load.

`effort_range` is the set of effort levels the model supports. Missing → `["medium"]` (legacy, can't step below). `effort` is the model's declared default.

`cost_per_task` is normalized at the model's declared effort. The selector's `_effective_cost` scales it by `EFFORT_MULT[effective]/EFFORT_MULT[declared]` to avoid double-counting.

## Config (`~/.claude/debate-acpx.json`)

```json
{
  "reviewers": {
    "<name>": {
      "agent": "acpx agent name | opus | antigravity | codex",
      "timeout": 120,
      "model": "optional model id (fallback for the agent's default)",
      "effort": "none|minimal|low|medium|high|xhigh|max",
      "mode": "session | exec",
      "retries": 1,
      "system_prompt": "persona prompt override"
    }
  },
  "claude_reviewers": {
    "skeptic":      ["fable", "opus"],
    "simplifier":   "auto",
    "operator":     "false",
    "pentester":    "false",
    "grounder":     "false",
    "/path/to/custom.md": "opus"
  },
  "presets": {
    "tight": {"reviewers": ["executor","auditor","pentester"], "claude_reviewers": {},
              "description": "three seats, Claude-free"},
    "security": {"reviewers": ["executor","auditor","pentester","simplifier"],
                 "claude_reviewers": {"skeptic": ["fable"], "pentester": "opus"}}
  },
  "private_repos": ["/Users/*/git/private-repo", "/Users/*/work/internal"],
  "default_reviewers": ["executor", "auditor", "cartographer", "pentester",
                        "simplifier", "antigravity"]
}
```

`private_repos`: list of repo-root path prefixes. When REPO_ROOT matches one,
or `DEBATE_PRIVATE=1`, or `gh repo view --json isPrivate` returns true,
the selector gets `--private-repo` → prefers route 31501 models.

`claude_reviewers` persona keys: `skeptic` (model-tuned: fable/opus/sonnet), `simplifier`,
`operator`, `pentester`, `grounder`, or a custom persona file path. Model values:
`"opus"`/`"sonnet"`/`"fable"` (spawn), `false` (skip), `"auto"` (spawn if in-domain), or an
array of models. `pentester` never runs on `sonnet` (weak at security by design; force opus).

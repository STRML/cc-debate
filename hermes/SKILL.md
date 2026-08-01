---
name: debate
description: "Debate a plan across AI reviewers to a consensus verdict."
version: 1.0.0
author: Hermes Agent (port of STRML/cc-debate)
license: MIT
platforms: [linux, macos]
metadata:
  hermes:
    tags: [debate, review, plan, multi-agent, subagents, verification]
    related_skills: [codex, claude-code, opencode, hermes-agent]
---

# Debate: Multi-AI Plan Review

Send the user's implementation plan (or current git changeset) to multiple independent
reviewer agents **in parallel**, collect their feedback, synthesize it, have them argue
out contradictions, and drive to a consensus verdict (APPROVE / REVISE). Max **3 revision
rounds**; a post-fix verification pass does not count against the budget.

**Hermes-native port of [STRML/cc-debate](https://github.com/strml/cc-debate).** This
subdirectory is the Hermes delivery of this repo: it uses Hermes **`delegate_task`** for
the reviewer panel instead of the acpx/codex/gemini CLI machinery in `scripts/` and
`commands/`. For model diversity you can optionally point a reviewer at an external CLI
(codex, claude-code, gemini, opencode) — see "External-CLI reviewer backends" below.

## When to use

- A plan is about to become code and you want it stress-tested before writing anything.
- You want competing vantage points (e.g. simplifier vs operator vs pentester) on the same plan.
- You want a second/third/fourth opinion in one shot without sequencing.

## Reviewers on the default panel

Each reviewer is a subagent with a distinct persona. Defaults (define your own in config
at `$HERMES_HOME/debate.json`, template in `templates/debate.json`):

| Reviewer | Persona / angle |
|---|---|
| `simplifier` | Cut scope. Over-engineering, YAGNI, complexity to defer. |
| `operator` | Will it run/ship? Ordering, deps, rollback, observability, ops gaps. |
| `pentester` | Security/robustness. Auth, injection, failure modes, data-integrity. |

Config shape:

```json
{
  "reviewers": {
    "simplifier": { "persona": "…", "backend": "subagent" },
    "operator":   { "persona": "…", "backend": "subagent" },
    "pentester":  { "persona": "…", "backend": "subagent" }
  },
  "presets": { "tight": { "reviewers": ["simplifier"] } },
  "default_reviewers": ["simplifier", "operator", "pentester"],
  "max_rounds": 3
}
```

- `backend: "subagent"` (default) → Hermes `delegate_task` subagent.
- `backend: "codex"|"claude"|"gemini"|"opencode"` → shell out to that CLI for true diversity.

**Panel resolution** (mirrors `debate:run`, first non-flag token wins): preset key →
comma-separated subset → `default_reviewers`, else all. `skip-debate` = skip the debate phase.

## Workflow

1. **Stage the subject.** Plan pasted/present → use it verbatim. No plan → review the current
   changeset (`git diff` vs the merge base of the default branch; `DEBATE_DIFF_BASE` overrides).
   Write it to a scratch file (`$HERMES_HOME/debate/<id>/plan.md`) so reviewers read the same bytes.
2. **Launch the panel in parallel.** One `delegate_task` call with a `tasks` array, one task per
   reviewer. Concurrency is capped at `delegation.max_concurrent_children` (default 3); larger
   panels queue. Each reviewer must return:
   ```
   ## Findings
   - <CRITICAL|HIGH|MED|LOW> <finding>
   ## VERDICT: APPROVE | REVISE
   ```
   Do NOT run reviewers sequentially — the whole point is parallel.
3. **Synthesize.** Group overlapping (2+ reviewers) vs unique findings; order by severity.
   Unanimous APPROVE with no CRITICAL/HIGH → done.
4. **Debate** (skip if `skip-debate`/unanimous). For each contradiction, a debate subagent gets
   both opposing reviews + the plan and returns a resolved position with justification.
5. **Verdict & revision loop.** REVISE → fix CRITICAL/HIGH (and agreed MED) findings, re-submit
   the *revised* plan to the same panel. Max `max_rounds` revision rounds.
6. **Report.** Verdict per reviewer per round; findings table; debate resolutions; final verdict.

## External-CLI reviewer backends

When `backend` isn't `subagent`, don't use delegate_task — shell out via `terminal(..., pty=true)`
per that CLI's skill. Pass the plan **via file path / stdin**, never stitched into a shell
string. Treat the output exactly like a subagent review in steps 3-6.

## Pitfalls

- Never inline the plan into a shell string — always via file.
- Parallel, not sequential — one `delegate_task` with a `tasks` array.
- Subagents inherit the parent model by default; for true independence use external-CLI
  backends or pin reviewer models. Say so when diversity is expected but not configured.
- Stage to `plan.md` first; clean up the scratch dir at the end.

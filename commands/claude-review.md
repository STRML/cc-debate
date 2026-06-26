---
description: Run Claude reviewer(s) on the current plan. Defaults to a Skeptic pair (Fable + Opus, model-tuned prompts). Use claude-double-review to add the Architect, claude-custom-review for interactive picker.
allowed-tools: SendMessage(*), Agent(subagent_type: general-purpose, model: fable), Agent(subagent_type: general-purpose, model: opus), Agent(subagent_type: general-purpose, model: sonnet), Read(~/.claude/debate-acpx.json), Read(~/.claude/settings.json), Bash(git rev-parse --show-toplevel:*)
---

# Claude Plan Review

Run one or more Claude reviewers on the current plan. Iterates until all approve or max 5 rounds reached.

## Entry Points

This skill is invoked via three commands that prefill different defaults:

| Command | Personalities | Model | Interactive? |
|---------|--------------|-------|-------------|
| `/debate:claude-review` | Fable Skeptic + Opus Skeptic | pinned per skeptic | No |
| `/debate:claude-double-review` | Fable Skeptic + Opus Skeptic + Architect | pinned skeptics; Architect on opus | No |
| `/debate:claude-custom-review` | (ask user) | (ask user) | Yes |

Arguments (all entry points):
- `--model sonnet` or `--model opus` — override the default model for non-pinned personalities. The two Skeptics pin their models (fable / opus) — their prompts are tuned to those specific models and don't transfer. An explicit `--model` forces only the non-skeptic reviewers.
- Personality names as positional args override defaults (e.g. `/debate:claude-review pentester --model sonnet`). The bare name `skeptic` means the pair (both Fable and Opus Skeptics).

---

## Personalities

The two Skeptics are a model-tuned pair — same role, complementary strengths. Fable is strongest at deep behavioral reasoning and benefits from extended thinking; Opus is strongest at bounded, precise checks and degrades on open-ended speculation. The prompts encode that split. Run them together by default; their findings overlap on the core (good signal: convergent findings are the most reliable) and diverge on the edges (where each model's unique catches live).

### The Fable Skeptic (default, pinned to model: fable)
```
name: "claude-fable-skeptic"
model: fable
prompt: |
  You are The Skeptic — a senior engineer who challenges plans by finding the
  high-impact failure everyone else missed. Take your time and reason deeply
  about runtime behavior — your accuracy scales with thinking depth, so prefer
  one deeply-traced finding over five shallow ones. Focus on:
  1. Unstated assumptions — what is assumed true that could be false?
  2. Hang and blocking paths — what can stall, spin, deadlock, or block
     forever? Trace the actual runtime path under load, under timing pressure,
     and in degraded modes (the debug build, the retry path, the slow disk).
  3. Consumer-side gaps — for every output or format this plan changes, who
     reads it? Find the parser, regex, dashboard, or downstream tool that
     silently stops matching.
  4. Second-order failures — what does a partial success leave behind?
  5. The one fatal flaw — if this plan has one problem, what is it?

  Verify before you assert: when a claim depends on library, platform, or
  hardware behavior, check the actual source or docs first. If you cannot
  verify, mark the concern UNVERIFIED — do not drop it, and do not overstate it.
```

### The Opus Skeptic (default, pinned to model: opus)
```
name: "claude-opus-skeptic"
model: opus
prompt: |
  You are The Skeptic — a senior engineer who challenges plans with exact,
  checkable analysis. Work the bounded checklist below with precision; do not
  speculate beyond it. Focus on:
  1. Arithmetic and limits — worst-case sizes, truncation, overflow,
     off-by-one. Show the math for every quantitative claim you make.
  2. Boundary conditions — empty input, max-size input, first/last element,
     zero, negative.
  3. Consistency sweeps — every name, label, doc string, and message this plan
     touches: enumerate each surface that must change, file by file. Never
     report a sweep "clean" without listing exactly what you checked.
  4. Test coverage — which behaviors in this plan have no test that would
     catch a regression?
  5. Security — does user-controlled content reach a shell string, query,
     template, or eval?

  Label any claim about emergent system behavior (timing interactions,
  hardware state, concurrency cascades) as HYPOTHESIS — verify before
  treating it as a finding.
```

### The Architect
```
name: "claude-architect"
prompt: |
  You are The Architect — a senior engineer who evaluates whether a plan's
  structure will hold up over time. Focus on:
  1. API boundaries — are the interfaces clean? Will they need breaking changes?
  2. Coupling — are components appropriately decoupled? Hidden dependencies?
  3. Performance — any O(n^2) traps, missing indexes, unbounded queries?
  4. Migration path — can this be deployed incrementally or is it all-or-nothing?
  5. The structural bet — what's the one design decision that will be most
     expensive to reverse if it's wrong?
```

### The Pentester
```
name: "claude-pentester"
prompt: |
  You are The Pentester — a security engineer who thinks like an attacker.
  Focus on:
  1. Attack surface — what new entry points does this create?
  2. Injection vectors — can user input reach shells, queries, templates, or eval?
  3. Auth/authz gaps — can a user access or modify another user's data?
  4. Data exposure — are secrets, tokens, or PII logged, cached, or leaked?
  5. Supply chain — are new dependencies trustworthy? Pinned? Audited?
```

### The Operator
```
name: "claude-operator"
prompt: |
  You are The Operator — an SRE who will be paged when this breaks at 3 AM.
  Focus on:
  1. Deployment — can this be rolled out with zero downtime?
  2. Rollback — if it fails in production, how do you undo it?
  3. Observability — will you know it's broken before users tell you?
  4. Failure modes — what happens when the database is slow, the queue is full,
     or a dependency is down?
  5. The 3 AM question — what will make someone regret merging this?
```

### The Simplifier
```
name: "claude-simplifier"
prompt: |
  You are The Simplifier — a senior engineer allergic to accidental complexity.
  Focus on:
  1. Over-engineering — is this solving a problem that doesn't exist yet?
  2. Unnecessary abstractions — could a direct approach replace an indirection?
  3. Simpler alternatives — is there a boring, obvious way to do this?
  4. YAGNI — which parts can be deferred until actually needed?
  5. The complexity budget — given the value delivered, is the complexity justified?
```

---

## Step 1: Resolve Configuration

### Fable preference

Fable costs roughly 2x Opus, so the Fable Skeptic is opt-in via stored preference. Check `~/.claude/debate-acpx.json` for the top-level key `fable_reviewer`:

- `true` (or key absent) — defaults include the Fable Skeptic as documented above.
- `false` — drop the Fable Skeptic from any *default* set and substitute the **Solo Skeptic** below (classic broad prompt, opus) wherever the pair would have run. An explicit positional arg (`fable-skeptic`, or invoking `/debate:fable` / `/debate:mythos`) always wins over the stored preference — the user asked by name.

```
name: "claude-skeptic"   # Solo Skeptic — used only when fable_reviewer is false
model: opus
prompt: |
  You are The Skeptic — a senior engineer who challenges plans by finding what
  everyone else missed. Focus on:
  1. Unstated assumptions — what is assumed true that could be false?
  2. Unhappy paths — what breaks when the first thing goes wrong?
  3. Second-order failures — what does a partial success leave behind?
  4. Security — is any user-controlled content reaching a shell string?
  5. The one fatal flaw — if this plan has one problem, what is it?
```

Based on the entry point, determine:

1. **Personalities** — from the entry point defaults (adjusted for the fable preference) + any overrides from args
2. **Model** — for non-pinned personalities: `opus` (default) or `sonnet` if `--model sonnet` was passed. The Fable/Opus Skeptics always use their pinned models.

### Fable availability probe

If the Fable Skeptic is in the selected personalities (either by default with `fable_reviewer: true`, or by explicit positional arg / `/debate:fable` / `/debate:mythos`), probe fable before the parallel Agent spawn:

```bash
claude --model fable --print --output-format json 'ok' 2>&1
```

Interpret:
- Exit 0 and non-empty result → fable is live, proceed normally.
- Non-zero exit, or output contains `not available` / `unknown model` / `deactivated` / empty result → fable is deactivated for this account. Drop the Fable Skeptic and substitute the **Solo Skeptic** (defined above). Print a single line to the user: `Fable unavailable — substituting Solo Skeptic.` Do NOT spawn an Agent with `model: fable` afterward — a spawned-but-empty teammate is the failure mode we're avoiding.

If the user invoked `/debate:fable` or `/debate:mythos` explicitly and fable is unavailable, abort with `Fable is deactivated. Use /debate:opus or /debate:claude-review instead.` rather than silently substituting — they asked for fable by name.

If invoked via `claude-custom-review` with no args, show the interactive picker:

```text
## Choose Reviewers

**Personalities** (comma-separated numbers or names, default: 1,2):
1. Fable Skeptic — deep behavioral reasoning: hang paths, consumer gaps (pinned: fable)
2. Opus Skeptic — precision checks: arithmetic, boundaries, sweeps, tests (pinned: opus)
3. Architect — API design, coupling, performance, migration
4. Pentester — attack surface, injection, auth, data exposure
5. Operator — deployment, rollback, observability, failure modes
6. Simplifier — over-engineering, YAGNI, simpler alternatives

**Model** (default: opus, applies to 3-6 only):
- opus — deeper analysis, higher cost
- sonnet — faster, cheaper, good for quick iteration
```

Wait for the user's selection.

### Repo-read permission preflight

The reviewer subagents read repo source at its absolute path. If the allowlist
doesn't cover it, every source read prompts and the subagents fall back to
`sed`/`cat`/`grep` to dodge the prompt (degraded review). Check once before
spawning:

```bash
git rev-parse --show-toplevel 2>/dev/null || pwd
```

Read `~/.claude/settings.json` and scan `.permissions.allow` for an entry
covering `<repo-root>/**` — `Read(<repo-root>/**)` exactly, a broader ancestor
(`Read(/Users/<you>/git/**)`), or a blanket `Read(**)`.

- **Covered** → proceed silently.
- **Missing** → print one `⚠️` line naming the exact entry to add,
  `Read(<repo-root>/**)`, and that `/debate:setup` (run in this repo) adds it
  permanently. Secret paths stay denied. Proceed either way — the review still
  runs, just with prompts.

---

## Step 2: Capture the Plan

If there is no plan in the current context, ask the user what they want reviewed.

Set `ROUND = 1`. Set `MAX_ROUNDS = 5`.

---

## Step 3: Spawn Reviewers (Round 1)

Launch all selected reviewers. Each forks the current context — the plan is already visible. Do NOT re-send the plan.

For each personality, spawn an Agent **in a single message** (parallel if multiple):

```
Agent:
  name: [personality name from Personalities section]
  model: [personality's pinned model if it has one, else the selected model]
  subagent_type: "general-purpose"
  description: "Claude [Personality] reviewer"
  run_in_background: [true if multiple reviewers, false if single]
  prompt: |
    [personality prompt from Personalities section]

    Review the implementation plan in this conversation. The plan is already in
    your context — do not ask for it.

    Provide structured feedback with severity (CRITICAL / MAJOR / MINOR) for
    each concern. Be specific, be direct, be constructive.

    End your response with exactly one of:
      VERDICT: APPROVED — plan is solid and ready to implement
      VERDICT: REVISE — concerns above should be addressed first
```

Go to **Step 4**.

---

## Step 4: Present Reviews & Check Verdicts

Display each review:

```text
---
## [Personality] Review — Round [ROUND]

[review text]
```

If multiple reviewers, add a synthesis:

```text
### Synthesis — Round [ROUND]

**Agreements:** [Points reviewers agree on]
**Unique insights:** [Reviewer]: [Point only this reviewer raised]
**Contradictions:** [Where they disagree, if any]
```

### Check verdicts

- **All APPROVED** → go to **Step 6** (Done)
- **Any REVISE** and `ROUND >= MAX_ROUNDS` → go to **Step 6** with max-rounds note
- **Any REVISE** and `ROUND < MAX_ROUNDS` → go to **Step 5** (Revise)
- No clear verdict but feedback is all positive / no actionable items → treat as approved

---

## Step 5: Revise & Re-submit

1. **Revise the plan** — address concerns from all reviewers. Make real improvements. If a revision contradicts the user's explicit requirements, skip it and note why. If reviewers contradict each other, note the disagreement and pick the stronger argument or ask the user.

2. **Show revisions:**
```text
### Revisions (Round [ROUND])
- [What changed and why, one bullet per concern addressed]
```

3. Increment `ROUND`. Send revisions to **all** agents in parallel (same message):

```
SendMessage:
  to: [agent name]
  summary: "Round [ROUND] revised plan"
  message: |
    I've revised the plan based on feedback. Here is what changed:

    [REVISION_SUMMARY]

    Updated plan:

    ---
    [CURRENT_PLAN]
    ---

    Re-review. Focus on whether prior concerns were addressed and any new
    issues introduced. End with VERDICT: APPROVED or VERDICT: REVISE.
```

Go to **Step 4**.

---

## Step 6: Final Result

**If all approved:**
```text
## Claude Review — Final

Approved after [ROUND] round(s) by [list of personalities] ([model]).

[Summary of each reviewer's final position]

---
## Final Plan

[CURRENT_PLAN]
```

**If max rounds reached:**
```text
## Claude Review — Final

Max rounds ([MAX_ROUNDS]) reached.

Remaining concerns:
[Per-reviewer unresolved issues]

---
## Final Plan

[CURRENT_PLAN]
```

---

## Rules

- All agents fork context — never re-send the plan in Round 1
- Always launch/message all agents in parallel when multiple
- SendMessage continues each agent with full context across rounds
- Claude actively revises between rounds — not just passing messages
- When reviewers contradict, note the disagreement and resolve or ask the user
- Max 5 rounds
- Never interpolate AI-generated text directly into shell strings

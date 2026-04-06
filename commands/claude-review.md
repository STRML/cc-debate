---
description: Run Claude reviewer(s) on the current plan. Defaults to one Opus Skeptic. Use claude-double-review for two, claude-custom-review for interactive picker.
allowed-tools: SendMessage(*), Agent(subagent_type: general-purpose, model: opus), Agent(subagent_type: general-purpose, model: sonnet)
---

# Claude Plan Review

Run one or more Claude reviewers on the current plan. Iterates until all approve or max 5 rounds reached.

## Entry Points

This skill is invoked via three commands that prefill different defaults:

| Command | Personalities | Model | Interactive? |
|---------|--------------|-------|-------------|
| `/debate:claude-review` | Skeptic | opus | No |
| `/debate:claude-double-review` | Skeptic + Architect | opus | No |
| `/debate:claude-custom-review` | (ask user) | (ask user) | Yes |

Arguments (all entry points):
- `--model sonnet` or `--model opus` — override the default model
- Personality names as positional args override defaults (e.g. `/debate:claude-review pentester --model sonnet`)

---

## Personalities

### The Skeptic (default)
```
name: "claude-skeptic"
prompt: |
  You are The Skeptic — a senior engineer who challenges plans by finding what
  everyone else missed. Focus on:
  1. Unstated assumptions — what is assumed true that could be false?
  2. Unhappy paths — what breaks when the first thing goes wrong?
  3. Second-order failures — what does a partial success leave behind?
  4. Security — is any user-controlled content reaching a shell string?
  5. The one fatal flaw — if this plan has one problem, what is it?
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

Based on the entry point, determine:

1. **Personalities** — from the entry point defaults + any overrides from args
2. **Model** — `opus` (default) or `sonnet` if `--model sonnet` was passed

If invoked via `claude-custom-review` with no args, show the interactive picker:

```text
## Choose Reviewers

**Personalities** (comma-separated numbers or names, default: 1):
1. Skeptic — assumptions, unhappy paths, security
2. Architect — API design, coupling, performance, migration
3. Pentester — attack surface, injection, auth, data exposure
4. Operator — deployment, rollback, observability, failure modes
5. Simplifier — over-engineering, YAGNI, simpler alternatives

**Model** (default: opus):
- opus — deeper analysis, higher cost
- sonnet — faster, cheaper, good for quick iteration
```

Wait for the user's selection.

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
  model: [selected model]
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

# debate v2

Get a second (and third, and fourth) opinion on your implementation plan before you write a line of code. `debate` sends your plan to multiple AI reviewers in parallel, synthesizes their feedback, has them argue out contradictions, and produces a consensus verdict.

**v2 is a ground-up rewrite.** Everything now runs through [acpx](https://github.com/openclaw/acpx) — a single unified CLI that talks to any coding agent. No more managing individual CLIs, session files, or API keys per provider. One config, any combination of models.

## Quick Start

```bash
# 1. Install the plugin
/plugin marketplace add STRML/cc-debate
/plugin install debate@cc-debate

# 2. Install acpx
npm install -g acpx@latest

# 3. Configure your review panel (interactive)
/debate:acpx-setup

# 4. Run a review
/debate:run
```

Restart Claude Code after installing the plugin.

### Reviewing a plan vs reviewing your changes

`/debate:run` reviews a plan when one is staged. When no plan is staged, it reviews your current changeset instead — the diff against the merge base with your default branch — so the same command doubles as a code review with no extra syntax.

Set `DEBATE_DIFF_BASE=<ref>` to compare against something else. Pair it with a `codex-exec` reviewer (below) if you want at least one seat that reads the surrounding code rather than judging the diff in isolation.

---

## How it works

```text
You: /debate:run

Claude: Running parallel review via acpx...

  codex        → agent: codex        (120s)
  antigravity  → agent: antigravity  (240s)
  mercury      → agent: mercury      (120s)

  ## Codex Review — Round 1
  The retry logic in Step 4 doesn't handle the case where...
  VERDICT: REVISE

  ## Antigravity Review — Round 1
  Missing error handling when the API is unavailable...
  VERDICT: REVISE

  ## Mercury Review — Round 1
  Unstated assumption: this plan assumes the temp directory is writable...
  VERDICT: REVISE

  ## Synthesis
  Unanimous: all reviewers flagged missing error handling
  Unique to Codex: retry logic gap in Step 4
  Unique to Mercury: temp directory writability assumption

  ## Final Report
  VERDICT: REVISE — 3 issues to address

Claude: Revising plan...
Claude: Re-submitting to all reviewers...

  ## Codex Review — Round 2   →  VERDICT: APPROVED ✅
  ## Antigravity Review — Round 2  →  VERDICT: APPROVED ✅
  ## Mercury Review — Round 2 →  VERDICT: APPROVED ✅

  VERDICT: APPROVED — unanimous after 2 rounds
```

---

## What you need

**Required:**
- [acpx](https://github.com/openclaw/acpx) — `npm install -g acpx@latest`
- [jq](https://jqlang.org) — `brew install jq` / `apt install jq`
- The agent CLIs for whatever reviewers you want (see [Supported Agents](#supported-agents) below)

**Optional:**
- [opencode](https://opencode.ai) — only needed for OpenRouter model access (DeepSeek, Mercury, Kimi, etc.) or LiteLLM proxy access (local models, self-hosted, etc.)

---

## Supported Agents

These are the reviewer backends you can use. Mix and match — pick 2-4 for a useful review panel.

### Built-in acpx agents

These have native Agent Client Protocol support. Install the CLI, and acpx handles the rest.

| Agent name | Model | Install |
|-----------|-------|---------|
| `codex` | OpenAI Codex | `npm install -g @openai/codex` + `OPENAI_API_KEY` |
| `antigravity` | Google Gemini 3.x via Antigravity CLI | Install the [Antigravity CLI](https://antigravity.google) (`agy`) + run `agy` once to sign in ¹ |
| `claude` | Claude (Opus/Sonnet) | Already installed — you're running it now |
| `kimi` | Kimi (Moonshot AI) | See [Kimi CLI docs](https://github.com/moonshot-ai/kimi-cli) |
| `kiro` | Kiro (AWS) | See [Kiro docs](https://kiro.dev) |
| `qwen` | Qwen Code | See [Qwen Code docs](https://github.com/QwenLM/qwen-code) |
| `cursor` | Cursor | Install [Cursor IDE](https://cursor.com) |
| `copilot` | GitHub Copilot | `gh extension install github/gh-copilot` |
| `opencode` | OpenCode (default model) | `npm install -g opencode-ai` |
| `kilocode` | Kilocode | `npx @kilocode/cli` |
| `droid` | Factory Droid | See acpx docs |
| `iflow` | iFlow | See acpx docs |
| `pi` | Pi Coding Agent | See acpx docs |
| `openclaw` | OpenClaw | See acpx docs |

> ¹ **Antigravity note:** acpx has no native ACP support for the Antigravity CLI yet, so `invoke-acpx.sh` calls `agy` directly. Stored OAuth from running `agy` once works fine for this; alternatively set `ANTIGRAVITY_API_KEY` (or `GEMINI_API_KEY`) in `~/.claude/settings.json` for fully headless environments:
> ```json
> "env": { "ANTIGRAVITY_API_KEY": "..." }
> ```
> Pick the review model with the optional `model` config field — any display name from `agy models` (e.g. `"Gemini 3.1 Pro (High)"`). Two `agy` quirks the script handles for you: the prompt is passed as a positional argument (stdin is ignored in print mode), and `agy -p` is run under a PTY (via Python) because it drops its output when stdout is not a TTY. `agy` has no hard read-only flag, so the reviewer is run from a throwaway workspace with the plan supplied in-prompt — it never needs repo access.
>
> **Migrated from the Gemini CLI (June 2026):** Google is [transitioning the Gemini CLI to the Antigravity CLI](https://developers.googleblog.com/an-important-update-transitioning-gemini-cli-to-antigravity-cli/). This plugin's Google reviewer now uses `agy` directly — the old `gemini` agent has been replaced by `antigravity`.

### The repo-aware seat: `codex-exec`

Every agent above is prompt-only. They see the text you send them and nothing else — acpx makes no tool calls, and `agy` is deliberately run from a throwaway workspace because it has no read-only mode. That is the right design for reviewing a plan, but it means no reviewer can check a claim against the actual code.

The `codex-exec` agent can. It bypasses acpx and calls `codex exec` directly, which reads files and runs commands in your repo. Use it when you want a reviewer that verifies rather than infers.

```json
"auditor": {
  "agent": "codex-exec",
  "timeout": 900,
  "model": "gpt-5.6-sol",
  "effort": "high",
  "system_prompt": "You are The Auditor — verify every claim against the code. Ground each finding in a file:line you have actually read."
}
```

`model` is passed to `codex exec -m`, and `effort` becomes `-c model_reasoning_effort=` (`low`, `medium`, `high`). Reads are sandboxed with `-s read-only`, so the reviewer can open anything in the repo and change nothing. Give it a longer `timeout` than the prompt-only seats — it is doing real work, and a review that opens several files takes minutes, not seconds.

Three implementation details, all handled for you.

The prompt goes to codex on stdin (`codex exec ... -` with the prompt file redirected in), never in the argument list. In changeset mode the prompt carries a whole diff, and a large one exceeds `ARG_MAX` — 1 MiB on macOS — and fails with `Argument list too long`.

That redirect doubles as the hang fix. `codex exec` blocks forever on a stdin that never reaches EOF, printing `Reading additional input from stdin...` and waiting, which under a harness looks exactly like a silent no-op. A regular file gives EOF; an inherited pipe does not. If you call `codex exec` yourself with the prompt in argv, add `</dev/null`.

And `codex` echoes every command it runs to stdout, which can be an entire test suite, so the script uses `-o` to capture only the final message. The transcript lands in `<reviewer>-transcript.log` instead of the synthesizer's input.

> **Claude note:** Using `claude` as a reviewer means Claude reviewing its own plan — useful for a fresh-context skeptical read, but not truly independent. For independent perspectives, use non-Claude agents. `invoke-acpx.sh` automatically handles the nested-session guard (`CLAUDECODE`) required to run Claude as a subprocess.

### Any model via OpenRouter (using opencode)

For models that don't have a native acpx agent — DeepSeek, Mercury, Mixtral, Kimi K2, GPT variants, or anything else on [openrouter.ai](https://openrouter.ai/models) — you can route through OpenRouter using opencode as the bridge:

```
acpx → opencode (custom agent) → OpenRouter API → any model
```

**Prerequisites:**
- `npm install -g opencode-ai`
- OpenRouter API key from [openrouter.ai/settings/keys](https://openrouter.ai/settings/keys)

**Setup (one time per model):**

> **Tip:** Just run `/debate:acpx-setup` — it does all of this for you interactively.

Or manually:

```bash
# 1. Create a wrapper directory
mkdir -p ~/.acpx/agents/mercury

# 2. Write the opencode config
cat > ~/.acpx/agents/mercury/.opencode.json << 'EOF'
{
  "provider": {
    "openrouter": { "apiKey": "sk-or-v1-..." }
  },
  "agents": {
    "coder": { "model": "openrouter/inception/mercury-2" }
  }
}
EOF
chmod 600 ~/.acpx/agents/mercury/.opencode.json

# 3. Write the launch script
cat > ~/.acpx/agents/mercury/start.sh << 'EOF'
#!/bin/bash
export OPENCODE_CONFIG_CONTENT='{"model":"openrouter/inception/mercury-2"}'
exec opencode acp "$@"
EOF
chmod +x ~/.acpx/agents/mercury/start.sh

# 4. Register with acpx (create/merge into ~/.acpx/config.json)
# Add this entry:
# { "agents": { "mercury": { "command": "/Users/you/.acpx/agents/mercury/start.sh" } } }
```

Then add to `~/.claude/debate-acpx.json`:
```json
"mercury": {
  "agent": "mercury",
  "timeout": 120,
  "model_id": "inception/mercury-2",
  "system_prompt": "You are The Contrarian..."
}
```

**Popular OpenRouter models to consider:**

| Model | OpenRouter ID | Notes |
|-------|--------------|-------|
| DeepSeek R1 | `deepseek/deepseek-r1` | Strong reasoning |
| Inception Mercury | `inception/mercury-2` | Fast, strong coder |
| Kimi K2.5 | `moonshotai/kimi-k2.5` | 1M context |
| Mistral Large | `mistralai/mistral-large` | Good architecture instincts |
| GPT-4.1 | `openai/gpt-4.1` | Broad coverage |
| Gemini 2.5 Pro | `google/gemini-2.5-pro` | Strong if you don't have the Antigravity CLI |

### Any model via LiteLLM (using opencode)

For local models (Ollama, LM Studio), self-hosted endpoints, or any provider that [LiteLLM](https://github.com/BerriAI/litellm) supports, you can route through a LiteLLM proxy using opencode as the bridge:

```
acpx → opencode (custom agent) → LiteLLM proxy → any model
```

**Prerequisites:**
- `npm install -g opencode-ai`
- A running LiteLLM proxy (`pip install litellm[proxy]` + `litellm --config config.yaml`)

**Model alias requirement:**

opencode resolves model IDs against its built-in OpenAI model list, so the model name you give it must be a known OpenAI model name (e.g. `gpt-4o-mini`). Configure LiteLLM to route that alias to your actual model:

```yaml
# LiteLLM config.yaml
model_list:
  - model_name: gpt-4o-mini         # alias opencode uses
    litellm_params:
      model: ollama/deepseek-r1     # your actual model
      api_base: http://localhost:11434
```

**Setup (one time per agent):**

> **Tip:** Just run `/debate:acpx-setup` — it does all of this for you interactively.

Or manually:

```bash
# Run the helper script
bash ~/.claude/debate-scripts/create-litellm-agent.sh \
  deepseek \
  http://localhost:8200/v1 \
  gpt-4o-mini \
  sk-litellm-optional-key
```

Then add to `~/.claude/debate-acpx.json`:
```json
"deepseek": {
  "agent": "deepseek",
  "timeout": 120,
  "model_id": "deepseek-r1 via LiteLLM",
  "system_prompt": "You are The Pragmatist..."
}
```

**Arguments to `create-litellm-agent.sh`:**

| Arg | Required | Example |
|-----|----------|---------|
| `name` | Yes | `deepseek` |
| `base_url` | Yes | `http://localhost:8200/v1` |
| `model_alias` | Yes | `gpt-4o-mini` (must be a known OpenAI model name) |
| `api_key` | No | `sk-litellm-abc123` (omit if proxy has no auth) |

---

## Config reference

Reviewers live in `~/.claude/debate-acpx.json`. This is the only file you need to edit to change your panel.

```json
{
  "claude_reviewers": {
    "skeptic": ["fable", "opus"],
    "simplifier": "opus",
    "operator": "sonnet",
    "pentester": "auto"
  },
  "reviewers": {
    "codex": {
      "agent": "codex",
      "timeout": 120,
      "system_prompt": "You are The Executor — find what breaks at runtime. Focus on shell correctness, exit codes, race conditions, file I/O."
    },
    "antigravity": {
      "agent": "antigravity",
      "timeout": 240,
      "model": "Gemini 3.1 Pro (High)",
      "system_prompt": "You are The Architect — review for structural integrity. Focus on approach validity, over-engineering, missing phases, graceful degradation."
    },
    "mercury": {
      "agent": "mercury",
      "timeout": 120,
      "model_id": "inception/mercury-2",
      "system_prompt": "You are The Contrarian — question everything. Focus on hidden assumptions, overlooked alternatives, failure modes under load."
    }
  },
  "presets": {
    "tight": {
      "description": "Gemini + Codex only, no Claude teammates — for when tokens are tight",
      "reviewers": ["codex", "antigravity"],
      "claude_reviewers": {}
    }
  }
}
```

| Field | Required | Description |
|-------|----------|-------------|
| `agent` | Yes | acpx agent name (see [Supported Agents](#supported-agents)) |
| `timeout` | No | Seconds before the review is killed. Default: 120. Use 240-300 for large/slow agents. |
| `system_prompt` | No | Persona sent as the prompt prefix. Omit for generic reviewer behavior. |
| `model` | No | For the `antigravity` agent — model display name from `agy models` (e.g. `Gemini 3.1 Pro (High)`). For the `opus` agent — the Claude model id. Omit to use the agent's default. |
| `model_id` | No | For OpenRouter agents — the underlying model ID (e.g. `inception/mercury-2`). Shown in the summary. |
| `mode` | No | `session` (default) prompts a persistent acpx session, so the reviewer keeps its context across debate rounds. `exec` sends every prompt as a one-shot instead. See below. |
| `retries` | No | Extra attempts when the agent ends its turn with no review. Default: 1. Set 0 to disable, or 2-3 for a notably flaky agent. A non-zero exit or a timeout is never retried. |

#### When to set `mode: "exec"`

Some ACP agents answer the first prompt into a session and then go mute: the turn
ends immediately with no content and exit 0, so the round records an **empty
review** rather than an error. Reproduced with opencode-backed agents such as
`kimi-k3` — run 1 answers, every later run in that session returns nothing.

If a reviewer's output file is empty on round 2 while round 1 was fine, try
`"mode": "exec"`. The reviewer loses continuity between rounds (each prompt
arrives cold, and the debate prompt carries its own context anyway).

A separate failure looks similar and `mode` will not fix it: some agents end a
turn with no final message at random, session or not. `kimi-k3` through opencode
does this on a large share of turns, including on a prompt as small as "reply
PONG". That is what `retries` is for. The reviewer is only dropped once its
retries are spent, and the round then reports a real failure rather than an
approval.

### Claude-side reviewers (top-level keys)

The `reviewers` object above is the acpx CLI panel. The optional `claude_reviewers`
object adds in-session **Claude teammate** reviewers that run alongside it, mapping
**persona key → model spec**:

| Field | Values | Description |
|-------|--------|-------------|
| persona key | built-in name or file path | Built-ins: `skeptic`, `simplifier` (accidental complexity / YAGNI), `operator` (reliability / failure modes / 3 AM), `pentester` (security / attack surface) — bodies in `scripts/reviewer-prompts.md`. Any key that isn't a built-in name is treated as a **path to a custom persona file**, whose contents become the reviewer body. |
| model spec | model or array of models | Each model is `false` (off), `"opus"`, `"sonnet"`, `"fable"`, or `"auto"`. An array spawns one teammate per model — e.g. `"skeptic": ["fable","opus"]` runs the tuned pair. |

The **skeptic** is model-tuned: `fable` → Fable Skeptic, `opus` → Opus Skeptic,
`sonnet` → the generic Solo Skeptic. (This replaces the old `fable_reviewer` flag —
`"skeptic": ["fable","opus"]` is the former `fable_reviewer: true`; `"skeptic": "opus"`
is the former `false`.)

**`"fable"`** falls back to `"opus"` (with a warning) if fable is deactivated for the account.

**`"auto"` discretion.** Under `"auto"`, a persona spawns only when the plan touches its
area — `pentester` for security-sensitive changes (auth, untrusted input, secrets/crypto,
shelling out, network, file uploads, permissions), `operator` for reliability/ops changes,
`simplifier` for complexity/structural changes, and a custom persona per the focus its
body describes. Routine (docs/config-only) changes stay lean.

**`pentester` never runs on `sonnet`** (weak at adversarial security reasoning — coerced
to `opus` with a warning); valid values `"opus"`, `"fable"`, `"auto"`, `false`. `"auto"`
is the recommended default: security-relevant plans get a security lens, routine ones
don't. (The guard applies only to the built-in `pentester`; custom personas may use `sonnet`.)

**Custom personas.** Point a key at your own file — e.g. `"~/personas/data-modeler.md": "opus"`.
Write it like the built-in bodies (a `You are The <Name> …` role line + a short focus
checklist); its contents are used verbatim as the reviewer prompt.

### Presets (named panels)

An optional top-level `presets` object lets you save named panel configurations and
switch between them by name, instead of editing `reviewers` / `claude_reviewers` in place
each time. Each preset is a **complete panel definition** that overrides both selectors
for that run:

```json
"presets": {
  "tight": {
    "description": "Gemini + Codex only, no Claude teammates — for when tokens are tight",
    "reviewers": ["codex", "antigravity"],
    "claude_reviewers": {}
  }
}
```

| Field | Description |
|-------|-------------|
| `reviewers` | Array of acpx reviewer names to run (each must be a key in the top-level `reviewers` object). Omit or `[]` to run no acpx reviewers (Claude-only panel). |
| `claude_reviewers` | Persona→model map that **replaces** the top-level `claude_reviewers` for this run. `{}` spawns **no** Claude teammates — the non-Claude, tokens-tight case. Omit to fall back to the top-level default. |
| `description` | Optional one-liner, echoed when the preset is selected. |

Select a preset by name: `/debate:run tight`. A bare argument that matches a preset key
wins over a same-named reviewer, so don't name a preset after a reviewer. Anything with a
comma is still parsed as a reviewer subset, so existing `codex,antigravity` usage is
unaffected.

### Good reviewer personas

The value of multiple reviewers is getting genuinely different lenses. Some ideas:

- **The Executor** — shell correctness, exit codes, race conditions, file I/O, command availability
- **The Architect** — structural integrity, approach validity, over-engineering, missing phases, graceful degradation
- **The Skeptic** — unstated assumptions, unhappy paths, second-order failures, security
- **The Contrarian** — questions conventional wisdom, hidden assumptions, alternatives everyone overlooks, failure modes under load
- **The Pragmatist** — what will actually ship, unnecessary complexity, missing happy path steps, places that assume competence that may not exist

---

## Commands

| Command | What it does |
|---------|-------------|
| `/debate:setup` | Check prerequisites, create `~/.claude/debate-scripts` symlink, detect v1.x configs and migrate, print permission allowlist |
| `/debate:acpx-setup` | Interactive reviewer configuration: pick agents, set up OpenRouter models, probe connectivity |
| `/debate:run [reviewers\|preset] [skip-debate]` | Run all (or a subset, or a named `presets` panel) of reviewers in parallel, synthesize, debate, iterate up to 3 rounds. Alias: `/debate:all`. |
| `/debate:claude-review` | Claude review — model-tuned skeptic pair by default (Fable Skeptic + Opus Skeptic). Up to 5 rounds. |
| `/debate:claude-double-review` | Skeptic pair + Architect in parallel. |
| `/debate:claude-custom-review` | Interactive picker — choose personalities and model. |
| `/debate:fable` | Single Fable Skeptic — deep behavioral reasoning (hang paths, consumer-side gaps). Alias: `/debate:mythos`. |
| `/debate:opus` | Single Opus Skeptic — precision checks (arithmetic, boundaries, consistency sweeps, test coverage). |

**The skeptic pair.** Fable 5 and Opus 4.8 fail differently: in panel comparisons, Fable's unique confirmed findings were behavioral (blocking/hang paths, consumer-side parser gaps) and it self-corrects by verifying library behavior; Opus wins on exact worst-case arithmetic, boundary nits, and labeling consistency, but its emergent-behavior claims get refuted more often. The two skeptic prompts are tuned to those strengths, and convergent findings between them are the strongest signal. Fable costs roughly **2x Opus**, so the pair is opt-in: set `"skeptic": ["fable","opus"]` in `claude_reviewers` for both, or `"skeptic": "opus"` for a solo Opus Skeptic. `/debate:fable` and `/debate:mythos` ignore config — invoking them by name is explicit consent to fable's cost.

### `/debate:run` options

```bash
/debate:run                    # all configured reviewers
/debate:run codex,mercury      # specific acpx subset only
/debate:run tight              # a named preset from the `presets` object (see Config reference)
/debate:run skip-debate        # skip debate phase, straight to final report
```

`/debate:all` is a permanent alias for `/debate:run` — same arguments, same behavior.

---

## Unattended use (no approval prompts)

Add to `~/.claude/settings.json` to permanently approve all debate tool calls:

```json
{
  "permissions": {
    "allow": [
      "Bash(bash ~/.claude/debate-scripts/debate-setup.sh:*)",
      "Bash(bash ~/.claude/debate-scripts/run-parallel-acpx.sh:*)",
      "Bash(bash ~/.claude/debate-scripts/invoke-acpx.sh:*)",
      "Bash(rm -rf .tmp/ai-review-:*)",
      "Read(.tmp/ai-review*)",
      "Edit(.tmp/ai-review*)",
      "Write(.tmp/ai-review*)",
      "Read(/path/to/your/repo/**)"
    ]
  }
}
```

The last entry is a **repo-scoped read grant** so review subagents can read the
repo's source at its absolute path without prompting (replace the placeholder
with your repo root — `git rev-parse --show-toplevel`). It's scoped per repo
rather than a blanket `Read(**)`; secret paths (`.env`, `~/.ssh`, `~/.aws`,
`secrets/`) stay denied. Run `/debate:setup` inside a repo to add that repo's
entry automatically with verified paths.

---

## Troubleshooting

**Reviewer fails immediately with "No acpx session found"**
For custom agents (OpenRouter via opencode), create a session first: `acpx <agent> sessions new`. `/debate:acpx-setup` does this automatically during the probe step.

**Antigravity (`agy`) fails with an auth error**
You're not signed in. Run `agy` once in a terminal to complete the browser OAuth flow. For headless environments, set `ANTIGRAVITY_API_KEY` (or `GEMINI_API_KEY`) in `~/.claude/settings.json` under `"env"` and restart Claude Code.

**Antigravity (`agy`) review comes back empty**
`agy -p` drops its output when stdout is not a TTY; `invoke-acpx.sh` runs it under a PTY via Python to avoid this. If `python3` is missing, or the environment forbids PTY allocation and the bug triggers, install `python3` and ensure the reviewer isn't running under a restrictive sandbox.

**OpenRouter model returns wrong answers / ignores persona**
The `OPENCODE_CONFIG_CONTENT` env var may not be taking effect. Verify your `start.sh` exports it correctly and that the model ID matches what's on openrouter.ai/models exactly.

**Reviews time out**
Increase the `timeout` value for that reviewer in `~/.claude/debate-acpx.json`. Large models (DeepSeek R1, Gemini 2.5 Pro) often need 240-300s. The parallel runner automatically sets `MAX_WAIT = max(timeout) + 60s`.

**`timeout: command not found` warning**
Install GNU coreutils: `brew install coreutils` (macOS). Reviews still run without it — the per-reviewer hard kill just won't be enforced.

---

## Migrating from v1.x

If you're upgrading from v1.x (CLI mode, LiteLLM, or OpenRouter), see **[MIGRATING.md](MIGRATING.md)** for:
- Which commands were removed and what replaces them
- How to convert `debate-litellm.json` and `debate-openrouter.json` to the new format
- Which `settings.json` permission patterns to remove and add

The `/debate:setup` command also detects v1.x configs automatically and offers to migrate them.

---

## Security

- Plan content is passed via **file path** — never inlined in shell strings
- AI output (reviews, summaries) is written to temp files — never interpolated into shell commands
- acpx is invoked with `--approve-reads` — agents can read your codebase for context but cannot write files
- Work directories in `.tmp/ai-review-*` are deleted at the end of each review session
- OpenRouter API keys live in `~/.acpx/agents/<name>/.opencode.json` with `chmod 600`

---

## Changelog

See **[CHANGELOG.md](CHANGELOG.md)** for release history.

---

## License

MIT

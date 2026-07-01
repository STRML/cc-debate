---
description: Check debate plugin prerequisites, verify acpx is installed, and print the exact settings.json snippet for fully unattended (no-prompt) operation.
allowed-tools: Bash(which acpx:*), Bash(which npx:*), Bash(which jq:*), Bash(which agy:*), Bash(bash ~/.claude/plugins/cache/cc-debate/debate/*/scripts/create-links.sh:*), Bash(ls:*), Bash(cat:*), Bash(jq:*), Bash(cp:*), Write(~/.claude/debate-acpx.json), Read(~/.claude/settings.json), Edit(~/.claude/settings.json), Write(~/.claude/settings.json)
---

# debate — Setup & Permission Check

Verify all prerequisites for the debate plugin and print everything needed for fully unattended operation.

---

## Step 1: Check acpx

```bash
which acpx || which npx
```

Report:

```text
## debate — Setup Check

### acpx CLI
  ✅ acpx    found at /path/to/acpx
```

If `acpx` is not found but `npx` is:
```text
  ⚠️  acpx not installed globally — will use npx acpx@latest (slower first run)
     Install globally: npm install -g acpx@latest
```

If neither found:
```text
  ❌ acpx not found. Install: npm install -g acpx@latest
```

## Step 2: Check jq

```bash
which jq
```

Report:
- Found → `✅ jq: found at /path/to/jq`
- Missing → `❌ jq: not found — install: brew install jq (macOS) / apt install jq (Linux)`

## Step 3: Check Antigravity CLI (if configured)

If `antigravity` is not in the user's `~/.claude/debate-acpx.json` config, skip this step silently.

Check whether the `agy` CLI (Antigravity) is installed:
```bash
which agy 2>/dev/null || echo "not found"
```

Report:
- Found → `✅ agy CLI: found at /path/to/agy`
- Not found → `❌ agy CLI: not found — install the Antigravity CLI (https://antigravity.google) and run 'agy' once to sign in`

Note: `/debate:all` invokes `agy` directly (not via acpx) — acpx has no native ACP support for it yet. Running `agy` once to sign in (OAuth) is enough; `ANTIGRAVITY_API_KEY` (or `GEMINI_API_KEY`) is only needed for fully headless environments without browser access. `python3` is also required (the script runs `agy -p` under a Python PTY to work around its non-TTY output bug).

## Step 4: Detect v1.x installation and migrate


Check for old config files from v1.x:

```bash
ls ~/.claude/debate-litellm.json ~/.claude/debate-openrouter.json 2>/dev/null
```

Also check `~/.claude/settings.json` for old permission patterns:

```bash
cat ~/.claude/settings.json 2>/dev/null
```

Look for these old patterns in the settings:
- `invoke-codex`, `invoke-gemini`, `invoke-opus`, `invoke-openai-compat`
- `run-parallel.sh` (without `-acpx`), `run-parallel-openai-compat`
- `.claude/tmp/ai-review` (old work dir path, should be `.tmp/ai-review`)
- `probe-model`

### If old configs found

Report:
```text
### v1.x Installation Detected

  ⚠️  Found old config files:
    ~/.claude/debate-litellm.json
    ~/.claude/debate-openrouter.json
```

**Auto-migrate if `~/.claude/debate-acpx.json` does not exist yet:**

Read each old config and extract reviewer entries. Map `model` fields to acpx agents using this table:

| Old model pattern | acpx agent |
|-------------------|------------|
| `claude-opus-*`, `claude-sonnet-*`, `claude-*` | `claude` |
| `gpt-*`, `o1-*`, `o3-*`, `o4-*` | `codex` |
| `gemini-*` | `antigravity` |
| Any other model | Skip with warning — no acpx agent equivalent |

For each mappable reviewer from the old config, create an entry in the new format:
```json
{
  "reviewers": {
    "<old-name>": {
      "agent": "<mapped-agent>",
      "timeout": <old-timeout or 120>,
      "system_prompt": "<old system_prompt if present>"
    }
  }
}
```

Merge reviewers from both old configs (litellm + openrouter), deduplicating by name. If both have a reviewer with the same name, prefer the openrouter entry.

Write the merged config to `~/.claude/debate-acpx.json`.

Report:
```text
  ✅ Migrated N reviewer(s) to ~/.claude/debate-acpx.json:
    opus    → agent: claude   (was model: claude-opus-4-6)
    codex   → agent: codex    (was model: gpt-5.3-codex)

  ⚠️  Skipped N reviewer(s) — no acpx agent equivalent:
    deepseek (model: deepseek.v3-v1:0) — no acpx agent for DeepSeek
```

Tell the user:
```text
  Old config files are still present. You can delete them after verifying:
    rm ~/.claude/debate-litellm.json ~/.claude/debate-openrouter.json
```

**If `~/.claude/debate-acpx.json` already exists**, skip auto-migration and just report:
```text
  ℹ️  Old config files found but ~/.claude/debate-acpx.json already exists — skipping migration.
     Delete old configs when ready:
       rm ~/.claude/debate-litellm.json ~/.claude/debate-openrouter.json
```

### If old settings.json patterns found

Report which patterns are stale and show the replacement:
```text
  ⚠️  Stale permission patterns in ~/.claude/settings.json:
    - "Bash(bash ~/.claude/debate-scripts/invoke-codex.sh:*)"     → remove
    - "Bash(bash ~/.claude/debate-scripts/invoke-gemini.sh:*)"    → remove
    - "Bash(bash ~/.claude/debate-scripts/invoke-opus.sh:*)"      → remove
    - "Bash(bash ~/.claude/debate-scripts/run-parallel.sh:*)"     → remove
    - "Read(.claude/tmp/ai-review*)"                              → "Read(.tmp/ai-review*)"

  Replace with the updated allowlist shown in Step 7 below.
  See MIGRATING.md for the complete migration guide.
```

### If no old installation detected

Skip this step silently — no output needed.

## Step 5: Check debate-acpx.json config

Read `~/.claude/debate-acpx.json`. Report:

- File exists → show reviewer list:
  ```text
  ### Config: ~/.claude/debate-acpx.json
    Reviewers:
      codex        → agent: codex        (120s timeout)
      antigravity  → agent: antigravity  (240s timeout)
  ```
- File missing → suggest running `/debate:acpx-setup` to create it interactively

### 5b. Skeptic preference (`claude_reviewers.skeptic`)

The Claude skeptic side of `/debate:all` and `/debate:claude-review` can run a model-tuned **pair** — a Fable Skeptic (deep behavioral reasoning) + an Opus Skeptic (precision checks). Fable costs roughly **2x Opus**, so the pair is an opt-in stored as the `skeptic` entry in the `claude_reviewers` object.

Check `~/.claude/debate-acpx.json` for `claude_reviewers.skeptic`:

- Present → report it and move on:
  ```text
  Skeptic: ✅ tuned pair (Fable + Opus)      # "skeptic": ["fable","opus"]
  ```
  or
  ```text
  Skeptic: ⬜ solo Opus — re-run /debate:setup to change      # "skeptic": "opus"
  ```
- Absent → ask the user with AskUserQuestion:
  - **Question:** "Use a Fable 5 skeptic alongside the Opus skeptic? Fable finds more high-impact behavioral issues (hang paths, consumer-side gaps) but costs roughly 2x Opus per review."
  - Options: "Yes — skeptic pair (Recommended)" / "No — Opus only"
  - Then persist: Read `~/.claude/debate-acpx.json`, set `claude_reviewers.skeptic` to `["fable","opus"]` (pair) or `"opus"` (solo), and Write the file back (the Write tool is allowlisted for this path — do not shell out to jq/mv). If the config file doesn't exist yet, note the preference and have `/debate:acpx-setup` write it when creating the file.

The `skeptic` entry is read at review time by `/debate:all`, `/debate:claude-review`, and its shortcuts. `/debate:fable` and `/debate:mythos` always run Fable regardless — invoking them by name is explicit consent.

## Step 6: Create stable scripts symlink

Create `~/.claude/debate-scripts` pointing to the installed version's scripts directory.
This symlink lets the main debate commands invoke scripts without version interpolation.

```bash
bash ~/.claude/plugins/cache/cc-debate/debate/*/scripts/create-links.sh
```

Report:
- Exit 0 → `✅ ~/.claude/debate-scripts created`
- Exit 1 (sandbox error) → show the exact `ln -sfn` command from the script output and tell the user to run it from their regular terminal (outside Claude Code), since the Claude Code sandbox restricts writes to `~/.claude/`

Note: Re-run `/debate:setup` after updating the plugin to refresh this symlink.

## Step 7: Patch permission allowlist in ~/.claude/settings.json

**DO NOT just print the snippet and hope the user copies it. Actively patch
`~/.claude/settings.json` to ensure the required entries are present.**
Past sessions printed the JSON and assumed the user would merge it manually;
they often didn't, and then `/debate:all` silently failed with exit 144 the
next time it ran. The point of this step is to make that impossible.

### 7a. Compute the required entries

The full required allowlist for unattended `/debate:all` and `/debate:claude-review`:

```
Bash(bash ~/.claude/debate-scripts/debate-setup.sh:*)
Bash(bash ~/.claude/debate-scripts/run-parallel-acpx.sh:*)
Bash(bash ~/.claude/debate-scripts/invoke-acpx.sh:*)
Bash(which acpx:*)
Bash(which jq:*)
Read(.tmp/ai-review*)
Edit(.tmp/ai-review*)
Write(.tmp/ai-review*)
Write(~/.acpx/**)
Read(~/.acpx/**)
Edit(~/.acpx/**)
Bash(rm -rf .tmp/ai-review-:*)
```

Plus one **repo-scoped read grant** so review subagents can read this repo's
source at its absolute path without prompting. Compute it for the current repo:

```bash
echo "Read($(git rev-parse --show-toplevel 2>/dev/null || pwd)/**)"
```

Add that exact `Read(<repo-root>/**)` entry to the required set. This is
deliberately scoped to the repo under review rather than a blanket `Read(**)`:
the secret-path deny rules already protect `.env`/`~/.ssh`/`~/.aws`/`secrets/`,
and a per-repo grant avoids auto-approving reads in unrelated projects. Each
repo you review gets its own entry the first time you run `/debate:setup` there;
the run commands preflight-check this and warn if it's missing.

### 7b. Read the current settings.json

Use the Read tool on `~/.claude/settings.json`.

- If the file doesn't exist, create it with `{"permissions":{"allow":[<all required entries>]}}` via Write and skip to 7d.
- If it exists but is malformed JSON, STOP. Print the parse error, the snippet
  the user needs to add manually, and exit Step 7 with a `⚠️` summary line.
  Do not attempt to rewrite a file you can't parse.

### 7c. Diff required vs. present

Compute which required entries are missing from `.permissions.allow`. Use exact
string match — `Write(~/.acpx/**)` does not satisfy `Write(/Users/<you>/.acpx/**)`
and vice versa; allowlist matching is literal.

If all required entries are already present:

```text
### Permission Allowlist
  ✅ ~/.claude/settings.json already contains all required entries (N entries verified)
```

Skip to Step 8.

### 7d. Patch the file

For each missing entry, append it to `.permissions.allow` using the Edit tool.
Insert the new lines together as a group, immediately after an existing
debate/acpx-related entry if one exists (e.g. after
`"Bash(bash ~/.claude/debate-scripts/invoke-acpx.sh:*)"`), otherwise at the
end of the `allow` array. Preserve the rest of the file byte-for-byte —
do not reformat unrelated keys, do not strip comments if a JSONC-style file
has them, do not reorder existing entries.

Before writing, run `jq empty ~/.claude/settings.json` (via Bash) on the
*pre-patch* file to confirm it parses. After writing, re-run `jq empty` to
confirm the patched file is still valid JSON. If the post-patch `jq` fails,
restore from the backup (`cp ~/.claude/settings.json.bak-debate-setup
~/.claude/settings.json`) and report the failure — do NOT leave the user
with a broken settings file.

The backup: before the first Edit, run
`cp ~/.claude/settings.json ~/.claude/settings.json.bak-debate-setup` so
there's a known-good fallback.

### 7e. Report what changed

```text
### Permission Allowlist
  ✅ Patched ~/.claude/settings.json
     Added N entries:
       + Write(~/.acpx/**)
       + Read(~/.acpx/**)
       + Edit(~/.acpx/**)
     M entries already present, left untouched.
     Backup: ~/.claude/settings.json.bak-debate-setup
```

If any entry was added, also print:

```text
  ℹ️  Settings changes take effect on the next session start, not on
     /reload-plugins. Start a new conversation (or run the failing /debate
     command in this session and approve the one-off prompt) for unattended
     operation.
```

### Why this is active rather than instructional

acpx writes a per-job queue lock to `~/.acpx/queues/<id>.lock` on every
invocation. Without `Write(~/.acpx/**)` in the settings allowlist, the
Claude Code sandbox blocks the write and reviewer subprocesses exit 144.
Because `run-parallel-acpx.sh` spawns reviewers via `nohup`/`disown`, the
sandbox-blocked-write error never surfaces as an interactive permission
prompt — `/debate:all` just reports "all reviewers failed" with no obvious
cause. Printing the snippet and trusting the user to copy it is how this
regression keeps recurring. Patch the file directly.

## Step 8: Print final status

```text
### Summary

  acpx:    ✅ ready
  jq:      ✅ ready (/opt/homebrew/bin/jq)
  Config:  ✅ valid (N reviewers)
  Scripts: ✅ symlinked

You are ready to run:
  /debate:all            — parallel review with synthesis and debate
  /debate:all codex      — single-reviewer via acpx
  /debate:claude-review  — Claude review (default: Fable + Opus skeptic pair)
  /debate:claude-double-review — skeptic pair + Architect
  /debate:claude-custom-review — interactive personality + model picker
  /debate:fable          — single Fable Skeptic (alias: /debate:mythos)
  /debate:opus           — single Opus Skeptic
  /debate:acpx-setup     — configure reviewers
```

If anything is missing, list the remaining actions the user needs to take before the plugin will work correctly.

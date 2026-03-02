# Data Models — debate plugin
_Updated: 2026-03-01_

## Temp Work Directory

Created per review session at `/tmp/claude/ai-review-<REVIEW_ID>/` (8-char hex ID).

```
ai-review-<REVIEW_ID>/
├── plan.md                  # Current plan being reviewed (written by all.md, overwritten on revision)
├── config.env               # Model overrides: CODEX_MODEL, GEMINI_MODEL, OPUS_MODEL
│
├── codex-output.md          # Codex review text
├── codex-session-id.txt     # Codex session ID for resume (empty on failure)
├── codex-exit.txt           # Exit code: 0=ok, 77=sandbox panic, 124=timeout
├── codex-stdout.txt         # Raw JSONL stdout (internal use)
├── codex-prompt.txt         # Debate/resume prompt (optional; cleared between rounds)
│
├── gemini-output.md         # Gemini review text
├── gemini-session-id.txt    # Gemini session UUID for resume (empty on failure)
├── gemini-exit.txt          # Exit code: 0=ok, 124=timeout
├── gemini-prompt.txt        # Debate/resume prompt (optional)
├── gemini-call-start        # Timestamp file for session UUID detection (filesystem diff)
│
├── opus-output.md           # Opus review text
├── opus-session-id.txt      # Opus session ID for resume (empty on failure)
├── opus-exit.txt            # Exit code: 0=ok, 124=timeout
├── opus-raw.json            # Full claude CLI JSON response (debugging)
└── opus-prompt.txt          # Debate/resume prompt (optional)
```

**Cleanup:** `rm -rf /tmp/claude/ai-review-<REVIEW_ID>` on completion or interruption.

## config.env Format

```bash
CODEX_MODEL=gpt-5.3-codex
GEMINI_MODEL=gemini-3.1-pro-preview
OPUS_MODEL=claude-opus-4-6
```

Written to `$WORK_DIR/config.env` by `all.md` before invoking reviewers. Sourced by `run-parallel.sh` and individual invoke scripts.

## debate-setup.sh Output

Printed to stdout; caller parses with `eval` or line-by-line:

```
REVIEW_ID=<8-char hex>
WORK_DIR=/tmp/claude/ai-review-<REVIEW_ID>
SCRIPT_DIR=~/.claude/debate-scripts
```

`SCRIPT_DIR` is the stable symlink path when `~/.claude/debate-scripts` exists; falls back to the resolved scripts directory from `installed_plugins.json`.

## Model Probe Cache (`~/.claude/debate-model-probe.json`)

```json
{
  "timestamp": 1740000000,
  "codex": "gpt-5.3-codex",
  "gemini": "gemini-3.1-pro-preview",
  "opus": "claude-opus-4-6"
}
```

TTL: 24 hours. Force refresh with `--fresh` flag on `probe-model.sh`.

## Plugin Metadata

### `.claude-plugin/plugin.json`
```json
{
  "name": "debate",
  "version": "1.1.18",
  "description": "...",
  "author": { "name": "strml", "url": "..." },
  "homepage": "...",
  "repository": "...",
  "license": "MIT",
  "keywords": [...]
}
```

### `.claude-plugin/marketplace.json`
Marketplace listing consumed by `/plugin marketplace add` — includes plugin name, description, source URL.

## Reviewer Definition Frontmatter

```yaml
---
name: codex
binary: codex
display_name: OpenAI Codex
default_model: gpt-5.3-codex
install_command: npm install -g @openai/codex
---
```

Custom reviewer overrides: `~/.claude/ai-review/reviewers/<name>.md` (same format; `name:` field used as key).

## Session Tracking (`~/.claude/sessions/`)

Lightweight per-session tracking only. Not full transcripts. Actual reviewer output goes to `$WORK_DIR/<reviewer>-output.md`.

## Stable Symlink

`~/.claude/debate-scripts` → `~/.claude/plugins/cache/debate-<source>/<version>/scripts/`

Created by `scripts/create-links.sh` (invoked by `/debate:setup`). All command files use this literal path — no version in path, no runtime glob.

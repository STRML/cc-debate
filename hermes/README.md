# Hermes support for cc-debate (debate v3)

`hermes/SKILL.md` is the Hermes **plugin** for the multi-AI debate workflow, now with a
**model registry + dynamic panel selection** (epic #31).

## Layout

- `SKILL.md` — the plugin: stage -> route -> dispatch -> synthesize -> debate -> verdict.
- `templates/debate-models.json` — model registry seed (model + price/cost_per_task +
  strengths + effort + harness + repo_aware + family/lab + available).
- `../scripts/select-panel.py` — pick the model mix for the seats (diversity/completeness/
  effort/budget/harness).
- `../scripts/refresh-models.py` — refresh metrics from Artificial Analysis + LMArena
  (offline-safe, preserves user fields).
- `../scripts/sandbox.py` — platform-adaptive sandbox (bwrap / sandbox-exec / docker) for
  repo-aware or untrusted seats.
- `../scripts/run-acpx-review.sh` — acpx dispatch wrapper (fan-out/timeout/retry in
  `run-parallel-acpx.sh`).

## Install / use

```bash
# seed the registry
cp hermes/templates/debate-models.json $HERMES_HOME/debate-models.json
# (edit `available`/`harness` to match what youve configured; optional) refresh:
python3 scripts/refresh-models.py --registry $HERMES_HOME/debate-models.json --ttl-hours 168
```

Then trigger the skill: `debate this plan`, `debate` (reviews the current changeset), or use
the `code-review` skill (wraps debate with the current changeset as subject). The selector
picks models by lab diversity + effort floor + budget; acpx reaches any provider; sandbox
isolates repo-aware seats.

## Note on `codex-exec`

Removed (see #35, sequenced after #29): repo-reading is a generic acpx property, and Codex
subscription credits work through the plain acpx `codex` agent's OAuth, so the seat is
redundant.

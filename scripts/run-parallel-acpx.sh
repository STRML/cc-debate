#!/bin/bash
# Parallel runner for acpx-based debate reviews.
# Reads reviewer list from config, spawns invoke-acpx.sh for each under `timeout`,
# and waits on them.
#
# Usage: run-parallel-acpx.sh <config_file> <REVIEW_ID> [reviewer1,reviewer2,...]
#   config_file — path to JSON config (e.g. ~/.claude/debate-acpx.json)
#   REVIEW_ID   — 8-char hex ID (work dir: .tmp/ai-review-<ID>)
#   reviewers   — optional comma-separated list; defaults to all from config

CONFIG_FILE="${1:-}"
REVIEW_ID="${2:-}"
REVIEWER_LIST="${3:-}"

# Expand a leading ~ — callers pass "~/.claude/debate-acpx.json" through the
# orchestrator, and tilde does not expand inside quotes or variable values.
if [ -n "$CONFIG_FILE" ] && [ "$CONFIG_FILE" != "${CONFIG_FILE#\~}" ]; then
  CONFIG_FILE="${HOME}${CONFIG_FILE#\~}"
fi

if [ -z "$CONFIG_FILE" ] || [ -z "$REVIEW_ID" ]; then
  echo "Usage: $0 <config_file> <REVIEW_ID> [reviewer1,reviewer2,...]" >&2
  exit 1
fi

# Sanitize REVIEW_ID
if ! [[ "$REVIEW_ID" =~ ^[a-zA-Z0-9_-]+$ ]]; then
  echo "[debate] Invalid REVIEW_ID: must be alphanumeric/dashes/underscores only" >&2
  exit 1
fi

# Resolve WORK_DIR. Prefer the git repo root so the path is stable regardless
# of which subdir the user invokes from — the original `${PWD}/.tmp/...` form
# silently no-ops when the user invokes from a different directory than the
# one where debate-setup.sh wrote plan.md. Falls back to PWD-relative outside
# a git repo (preserves test compatibility — tests use mktemp -d).
if [ -n "${WORK_DIR_OVERRIDE:-}" ]; then
  WORK_DIR="$WORK_DIR_OVERRIDE"
elif GIT_TOP=$(git rev-parse --show-toplevel 2>/dev/null) && [ -n "$GIT_TOP" ]; then
  WORK_DIR="${GIT_TOP}/.tmp/ai-review-${REVIEW_ID}"
else
  WORK_DIR=".tmp/ai-review-${REVIEW_ID}"
fi

# Note: $() triggers permission prompts in Claude Code, but this script runs
# via nohup outside the sandbox, so it's fine here.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Per-seat model selection (F1). The panel selector picks a model per seat;
# the orchestrator hands it to us one of two ways:
#   ACPX_SEAT_MODELS  — path to a JSON map. Either the full select-panel.py
#                       output ({seats: {seat: {model_id: ...}}}) or a flat
#                       {seat: model_id}. A seat with an entry gets that model.
#   DEBATE_MODEL      — a single model id applied to every seat without a map
#                       entry (run-acpx-review.sh --model sets this).
# Each seat's resolved model is forwarded to its invoke-acpx.sh as MODEL=<id>,
# which passes it to acpx as `--model <id>`.
SEAT_MODELS="${ACPX_SEAT_MODELS:-}"
DEBATE_MODEL="${DEBATE_MODEL:-}"

mkdir -p "$WORK_DIR" || { echo "Failed to create $WORK_DIR" >&2; exit 1; }
# The work dir holds the full changeset and every reviewer transcript. On a shared
# machine the default 0755 lets any local account read a diff that may carry
# proprietary code or a secret someone committed by accident.
chmod 700 "$WORK_DIR" 2>/dev/null || true

# No plan staged? Debate the current changeset instead. A review of what
# actually changed is almost always what someone wants when they run this
# without preparing a plan, and it needs no extra syntax. DEBATE_DIFF_BASE
# overrides the comparison point (default: the merge base with the default
# branch, falling back to HEAD so uncommitted work still reviews).
#
# DEBATE_FREEZE_DIFF=1 keeps an existing changeset.diff exactly as the caller wrote it.
# /debate:panel needs that: it measures the diff, picks the seats from what it measured,
# and only then starts this script. Regenerating here would let an edit landing in
# between hand the seats a different changeset from the one the panel was sized for, and
# the report would describe the old shape while the reviews described the new code.
REVIEW_TARGET="$WORK_DIR/plan.md"
if [ ! -s "$WORK_DIR/plan.md" ]; then
  DIFF_BASE=""
  if [ "${DEBATE_FREEZE_DIFF:-}" = "1" ] && [ -s "$WORK_DIR/changeset.diff" ]; then
    DIFF_BASE=$(cat "$WORK_DIR/changeset-base.txt" 2>/dev/null || echo "")
    echo "[debate] Frozen changeset: reviewing $WORK_DIR/changeset.diff as written." >&2
    # changeset-diff.sh prints the base and writes it nowhere, so a caller that froze the
    # diff without capturing that output leaves nothing to read here. Say so: the empty
    # value gets persisted below and safe-cleanup.sh regenerates against it later, which
    # silently compares the working tree to nothing at all.
    if [ -z "$DIFF_BASE" ]; then
      echo "[debate] WARNING: frozen diff has no recorded base ($WORK_DIR/changeset-base.txt is missing or empty)." >&2
      echo "  hint: redirect changeset-diff.sh stdout into that file when you write the diff." >&2
    fi
  elif git rev-parse --git-dir >/dev/null 2>&1; then
    DIFF_BASE=$(bash "$SCRIPT_DIR/changeset-diff.sh" "$WORK_DIR" "$WORK_DIR/changeset.diff") \
      || DIFF_BASE=""
  fi

  if [ ! -s "$WORK_DIR/changeset.diff" ]; then
    echo "[debate] FATAL: no plan.md in $WORK_DIR and no changes to review" >&2
    echo "  pwd:        $(pwd)" >&2
    if command -v realpath >/dev/null 2>&1; then
      echo "  resolved:   $(realpath "$WORK_DIR" 2>/dev/null || echo "(unresolvable)")" >&2
    fi
    echo "  hint:       write a plan to $WORK_DIR/plan.md, or make some changes to review" >&2
    echo "  hint:       set DEBATE_DIFF_BASE=<ref> to pick a different comparison point" >&2
    echo "  hint:       or set WORK_DIR_OVERRIDE=<absolute path> if you know the right work dir" >&2
    exit 1
  fi

  echo "[debate] No plan staged — reviewing the changeset against ${DIFF_BASE:-working tree} ($(wc -l < "$WORK_DIR/changeset.diff" | tr -d ' ') diff lines)." >&2
  REVIEW_TARGET="$WORK_DIR/changeset.diff"
  : > "$WORK_DIR/plan.md"
  printf '%s\n' "$DIFF_BASE" > "$WORK_DIR/changeset-base.txt"
fi

# Tell the rest of the toolchain what this round reviewed. record-round.sh and
# safe-cleanup.sh both gate on the review target, and both used to assume
# plan.md — in changeset mode that is an empty placeholder, so their gates
# hashed the empty string and passed unconditionally (#17).
printf '%s\n' "$(basename "$REVIEW_TARGET")" > "$WORK_DIR/review-target.txt"

# Record the SHA of what reviewers are about to see. The orchestrator (the
# /debate:all skill) then calls record-round.sh after determining the round
# verdict; the SHA there must match this one or someone edited the target
# mid-round. In changeset mode this must hash the DIFF — plan.md is an empty
# placeholder, and hashing it would make the gate pass no matter how much the
# working tree moved underneath the review.
if command -v sha256sum >/dev/null 2>&1; then
  sha256sum "$REVIEW_TARGET" | cut -d' ' -f1 > "$WORK_DIR/round-active-plan-sha.txt"
elif command -v shasum >/dev/null 2>&1; then
  shasum -a 256 "$REVIEW_TARGET" | cut -d' ' -f1 > "$WORK_DIR/round-active-plan-sha.txt"
fi

if [ ! -f "$CONFIG_FILE" ]; then
  echo "Config not found: $CONFIG_FILE" >&2
  exit 1
fi

# Get reviewer names: CLI arg or all from config
# With no explicit subset, prefer a configured `default_reviewers` list over "every
# key in .reviewers". Without it, a config that defines fallback-only seats — an
# agent for when the usual one is broken — runs them on every review, which is the
# opposite of what a fallback is for. Falls back to all keys so existing configs
# that predate the field behave exactly as before.
if [ -n "$REVIEWER_LIST" ]; then
  IFS=',' read -ra RAW_REVIEWERS <<< "$REVIEWER_LIST"
else
  RAW_REVIEWERS=()
  while IFS= read -r line; do
    RAW_REVIEWERS+=("$line")
  # Absent and explicitly-empty are different answers. `default_reviewers: []` means
  # "no default panel, always select explicitly", matching what an empty `reviewers`
  # array already means on a preset. Treating it as absent would hand back the full
  # panel — including the fallback seats this field exists to keep out of it.
  done < <(jq -r '
    if (.default_reviewers | type) == "array"
    then .default_reviewers[]
    else (.reviewers | keys[])
    end' "$CONFIG_FILE")
fi

# Trim whitespace and drop empty tokens
REVIEWERS=()
for r in "${RAW_REVIEWERS[@]}"; do
  r="${r#"${r%%[![:space:]]*}"}"  # ltrim
  r="${r%"${r##*[![:space:]]}"}"  # rtrim
  [ -n "$r" ] && REVIEWERS+=("$r")
done

if [ ${#REVIEWERS[@]} -eq 0 ]; then
  echo "[debate] No reviewers configured in $CONFIG_FILE" >&2
  exit 1
fi

# --- Sequential session warm-up (prevents the parallel-ensure race) ---
# acpx stores sessions in a shared ~/.acpx index. Firing N reviewers at once means
# N concurrent `acpx <agent> sessions ensure` calls racing on that index — writes get
# lost and the immediately-following submit fails with "No acpx session found",
# which the per-reviewer error mislabels as "not authenticated". Warming each
# agent's session sequentially first (ensure is idempotent — it reuses an existing
# session) makes the subsequent parallel submits all find their session.
# Skipped when SKIP_SESSION_CHECK is set (tests / mock acpx), for agents that bypass
# acpx sessions entirely (antigravity and opus are invoked as direct CLIs
# — keep this list in step with IS_DIRECT_CLI in invoke-acpx.sh), for codex-exec (a
# removed agent that invoke-acpx.sh rejects before any session logic — warming it
# would just be a failing call), and for reviewers running one-shot (`mode: "exec"`),
# which never open a session to warm.
if [ -z "${SKIP_SESSION_CHECK:-}" ]; then
  if command -v acpx >/dev/null 2>&1; then
    WARM_ACPX=(acpx)
  elif command -v npx >/dev/null 2>&1; then
    WARM_ACPX=(npx acpx@latest)
  else
    WARM_ACPX=()
  fi
  if [ ${#WARM_ACPX[@]} -gt 0 ]; then
    # A plain string, not `declare -A`: associative arrays need bash 4+ and stock macOS
    # ships 3.2, where `declare -A` is a fatal error under set -e that killed the whole
    # runner. Agent names are sanitized to [a-zA-Z0-9_-] above, so space-delimiting is
    # unambiguous.
    WARMED=""
    for NAME in "${REVIEWERS[@]}"; do
      [[ "$NAME" =~ ^[a-zA-Z0-9_-]+$ ]] || continue
      AGENT=$(jq -r --arg name "$NAME" '.reviewers[$name].agent // empty' "$CONFIG_FILE")
      [ -z "$AGENT" ] && continue
      case "$AGENT" in antigravity|opus|codex-exec) continue ;; esac
      # A one-shot reviewer never touches a session, so warming one for it is
      # wasted work — and a hang or failure here would delay a run that does not
      # need the session at all.
      MODE=$(jq -r --arg name "$NAME" '.reviewers[$name].mode // empty' "$CONFIG_FILE")
      [ "$MODE" = "exec" ] && continue
      [[ "$WARMED" == *" $AGENT "* ]] && continue   # one ensure per distinct agent
      WARMED="$WARMED $AGENT "
      echo "[debate] Warming acpx session for '$AGENT'..." >&2
      "${WARM_ACPX[@]}" "$AGENT" sessions ensure >/dev/null 2>&1 \
        || echo "[debate] Warm-up for '$AGENT' failed (agent may be unconfigured)." >&2
    done
  fi
fi

EXIT_FILES=()
PIDS=()
NAMES=()
BUDGETS=()
MAX_REVIEWER_BUDGET=0

# Signal a seat and everything under it. A seat is a chain — this runner spawns
# `timeout` (or, with no timeout binary, `env`), which runs `bash invoke-acpx.sh`,
# which runs the agent — and signalling only the pid we happen to hold reaps the
# wrapper while the agent keeps running with ppid 1, still burning tokens after the
# panel reports it dead. `pgrep -P` lists direct children only, so recurse, and
# signal children before their parent so nothing is reparented out of reach.
kill_tree() {
  local sig="$1" pid="$2" child
  for child in $(pgrep -P "$pid" 2> /dev/null); do
    kill_tree "$sig" "$child"
  done
  kill "-$sig" "$pid" 2> /dev/null
}

kill_all_seats() {
  local sig="$1" p
  for p in "${PIDS[@]}"; do
    kill_tree "$sig" "$p"
  done
}

# Each reviewer is spawned under `timeout`, so the seat that hangs is the seat that
# dies and the runner needs no supervisor of its own. Stock macOS ships neither
# `timeout` nor `gtimeout` (GitHub's macos runners included), and that is the common
# case, not an exotic one — so the fallback below is a real code path, not a courtesy.
#
# The `-x` test is not defensive noise: `command -v` reports the first PATH match
# without checking the execute bit, on bash 3.2 and bash 5 alike. Verified with the
# same probe name and PATH on 3.2.57 and 5.3.15, with and without a real executable
# behind the dud — both return the dud. Trusting that answer puts an unrunnable
# binary in front of every seat and kills the whole panel with exec code 126.
TIMEOUT_BIN=""
for _tb in timeout gtimeout; do
  _tb_path=$(command -v "$_tb" 2> /dev/null) || continue
  if [ -x "$_tb_path" ]; then
    TIMEOUT_BIN="$_tb_path"
    break
  fi
done
unset _tb _tb_path
# DEBATE_TIMEOUT_BIN pins the binary, or forces the watchdog fallback with `none`.
# A PATH shim cannot stand in for this: `command -v` skips a non-executable entry
# whenever a real binary exists behind it, so on any host with coreutils the shim is
# ignored and the fallback stays untested. (It is only when NOTHING executable is on
# PATH that `command -v` hands back the dud — which is the case the `-x` guard above
# exists for.) An explicit path still has to pass `-x`, or pinning it would walk
# straight back into the 126-at-spawn failure that guard just closed.
case "${DEBATE_TIMEOUT_BIN:-}" in
  "")   ;;
  none) TIMEOUT_BIN="" ;;
  *)
    if [ -x "${DEBATE_TIMEOUT_BIN}" ]; then
      TIMEOUT_BIN="$DEBATE_TIMEOUT_BIN"
    else
      echo "[debate] DEBATE_TIMEOUT_BIN='$DEBATE_TIMEOUT_BIN' is not executable — ignoring it." >&2
    fi
    ;;
esac
if [ -z "$TIMEOUT_BIN" ]; then
  echo "[debate] No usable timeout/gtimeout — bounding the panel with one watchdog instead of each seat." >&2
  echo "  Install coreutils (brew install coreutils) for per-seat bounds." >&2
fi

# POLL_MAX_WAIT overrides the computed per-reviewer budget. It is compared and
# reported as a number of seconds and handed to `timeout` as a duration, so a
# malformed value has to be rejected here rather than passed down: `timeout` exits
# 125 without running anything on a duration it cannot parse, which kills the seat
# at spawn instead of bounding it. Same rule the `timeout` config key already gets.
if [ -n "${POLL_MAX_WAIT:-}" ] && { ! [[ "$POLL_MAX_WAIT" =~ ^[0-9]+$ ]] || [ "$POLL_MAX_WAIT" -le 0 ]; }; then
  echo "[debate] Ignoring invalid POLL_MAX_WAIT '$POLL_MAX_WAIT' — using the computed budget." >&2
  POLL_MAX_WAIT=""
fi

# The model map is load-bearing: a truncated or hand-edited file silently falling
# back to defaults is how a panel loses its model selection without anyone
# noticing (debate finding). Fail loudly when it is set but unusable.
if [ -n "$SEAT_MODELS" ]; then
  if [ ! -f "$SEAT_MODELS" ]; then
    echo "[debate] FATAL: ACPX_SEAT_MODELS is set but the file is missing: $SEAT_MODELS" >&2
    exit 1
  fi
  if ! jq -e . "$SEAT_MODELS" > /dev/null 2>&1; then
    echo "[debate] FATAL: ACPX_SEAT_MODELS is not valid JSON: $SEAT_MODELS" >&2
    exit 1
  fi
fi

for NAME in "${REVIEWERS[@]}"; do
  # Sanitize reviewer name — must be alphanumeric/dash/underscore only
  if ! [[ "$NAME" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    echo "[debate] Skipping '$NAME' — invalid reviewer name (alphanumeric/dash/underscore only)" >&2
    continue
  fi

  AGENT=$(jq -r --arg name "$NAME" '.reviewers[$name].agent // empty' "$CONFIG_FILE")
  if [ -z "$AGENT" ]; then
    echo "[debate] Skipping $NAME — no agent in config" >&2
    continue
  fi

  TIMEOUT=$(jq -r --arg name "$NAME" '.reviewers[$name].timeout // 120' "$CONFIG_FILE")
  # The wait budget must cover a reviewer's WORST case, not its best. invoke-acpx.sh
  # retries a blank turn, and every attempt gets the full timeout, so a reviewer can
  # legitimately need timeout × (retries + 1). Budgeting only one attempt kills it
  # mid-retry and turns a recoverable blank turn into a lost seat on the panel.
  RETRIES=$(jq -r --arg name "$NAME" '.reviewers[$name].retries // 1' "$CONFIG_FILE")
  [[ "$RETRIES" =~ ^[0-9]+$ ]] || RETRIES=1
  # Same fallback RETRIES gets on the line above, and for the same reason. A value
  # like "600s" or 900.5 used to skip the budget entirely, because the guard below
  # had no else — so the seat contributed nothing to MAX_WAIT while invoke-acpx.sh
  # separately rewrote it to 120 and said so only in that seat's own log. The two
  # layers disagreed and both were quiet about it. Warn once, here, where the
  # operator is already reading, and hand the child the value we actually used.
  if ! [[ "$TIMEOUT" =~ ^[0-9]+$ ]] || [ "$TIMEOUT" -le 0 ]; then
    echo "[debate] $NAME: invalid timeout '$TIMEOUT', using 120s" >&2
    TIMEOUT=120
  fi
  WORST=$(( TIMEOUT * (RETRIES + 1) ))
  if [ "$WORST" -gt "$MAX_REVIEWER_BUDGET" ]; then
    MAX_REVIEWER_BUDGET="$WORST"
  fi
  # The seat's own bound: its worst case plus a startup buffer. invoke-acpx.sh puts
  # `timeout` around each agent call, but not around everything it does — an
  # `acpx sessions ensure` that hangs is outside that. This is the bound on the whole
  # child. -k: a child that ignores SIGTERM gets SIGKILL 5s later, so one wedged seat
  # cannot hold the panel open.
  CHILD_BUDGET="${POLL_MAX_WAIT:-$(( WORST + 60 ))}"
  SPAWN_PREFIX=()
  if [ -n "$TIMEOUT_BIN" ]; then
    SPAWN_PREFIX=("$TIMEOUT_BIN" -k 5 "$CHILD_BUDGET")
  fi

  echo "[debate] Spawning $NAME ($AGENT, timeout: ${TIMEOUT}s)..." >&2
  rm -f "$WORK_DIR/${NAME}-exit.txt"

  # Resolve this seat's model: the per-seat map entry wins, then the single-model
  # DEBATE_MODEL, then nothing (the agent's own default). model_id is the value
  # acpx `--model` wants; the selector outputs it under .seats[<seat>].model_id.
  CHILD_MODEL=""
  CHILD_EFFORT=""
  if [ -n "$SEAT_MODELS" ] && [ -f "$SEAT_MODELS" ]; then
    CHILD_MODEL=$(jq -r --arg s "$NAME" '
      if type == "object" and has("seats") then .seats[$s].model_id
      else .[$s] end // empty' "$SEAT_MODELS" 2>/dev/null || true)
    CHILD_EFFORT=$(jq -r --arg s "$NAME" '
      if type == "object" and has("seats") then .seats[$s].effective_effort
      else empty end // empty' "$SEAT_MODELS" 2>/dev/null || true)
    # A seat whose selected model runs on the subagent harness is not this acpx
    # runner's job — running it here would invoke the configured acpx agent for
    # a subagent model. Filter it out; the caller spawns it as a background Agent
    # teammate (run.md Step 2a-prime).
    HARNESS=$(jq -r --arg s "$NAME" '
      if type == "object" and has("seats") then .seats[$s].harness
      else empty end // empty' "$SEAT_MODELS" 2>/dev/null || true)
    if [ "$HARNESS" = "subagent" ]; then
      echo "[debate] Skipping $NAME — subagent harness is dispatched by the caller, not this runner" >&2
      continue
    fi
    # Proxy transport (#52/#53): the registry names a cc-ds4 route. Forward the
    # route (validated to {31501,31502}) so the proxy branch can set the base URL.
    CHILD_TRANSPORT=$(jq -r --arg s "$NAME" '
      if type == "object" and has("seats") then .seats[$s].transport
      else empty end // empty' "$SEAT_MODELS" 2>/dev/null || true)
    CHILD_ROUTE=$(jq -r --arg s "$NAME" '
      if type == "object" and has("seats") then .seats[$s].route
      else empty end // empty' "$SEAT_MODELS" 2>/dev/null || true)
  fi
  [ -z "$CHILD_MODEL" ] && CHILD_MODEL="$DEBATE_MODEL"

  INVOKE_ENV=("SKIP_SESSION_CHECK=${SKIP_SESSION_CHECK:-}")
  # Always set MODEL and EFFORT — empty means "use the agent default" — so an
  # inherited MODEL/EFFORT from the caller's environment cannot leak into a seat
  # that should use its default (debate findings F9 / effort plan).
  INVOKE_ENV+=("MODEL=${CHILD_MODEL:-}")
  INVOKE_ENV+=("EFFORT=${CHILD_EFFORT:-}")
  # A proxy-transport seat dispatches to the claude --print branch (agent opus)
  # with the validated route; reject a route on a non-proxy seat.
  if [ "${CHILD_TRANSPORT:-}" = "proxy" ]; then
    case "${CHILD_ROUTE:-}" in
      31501|31502) ;;
      *) echo "[debate] $NAME: proxy transport with invalid route '${CHILD_ROUTE:-}' — skipping" >&2; continue ;;
    esac
    # The proxy branch in invoke-acpx.sh lives inside `if [ "$AGENT" = "opus" ]`,
    # so a proxy model on any other agent would have PROXY_ROUTE ignored and the
    # model_id forwarded to the wrong CLI. Fail loud here rather than let a
    # drifted panel.json or config send a deepseek model to codex.
    if [ "$AGENT" != "opus" ]; then
      # Degrade to the seat's configured default (same policy as the provider
      # mismatch below): a drifted panel must not silently lose a seat.
      echo "[debate] $NAME: model on proxy transport (route ${CHILD_ROUTE}) needs an 'opus' seat, agent is '$AGENT' — clearing selected model; seat will run at its configured default" >&2
      CHILD_MODEL=""
      CHILD_EFFORT=""
      CHILD_TRANSPORT=""
      INVOKE_ENV+=("MODEL=" "EFFORT=")
    else
      INVOKE_ENV+=("PROXY_ROUTE=${CHILD_ROUTE}")
    fi
  fi

  # Provider-feasibility backstop (mirrors the selector's --agents constraint).
  # The registry's harness names a dispatch class, not an agent, so this checks
  # the model's provider against the agent's lock. Normally the selector already
  # prevented an infeasible assignment; this catches a hand-edited panel.json or
  # a config change between selection and spawn so it degrades to the seat's
  # default with a message instead of a 4-of-6 dead panel.
  # Provider-feasibility only applies to a map that carries provider — the full
  # select-panel.py output always does. A flat {seat: model_id} map has none:
  # the caller pinned the model explicitly, so the runner has nothing to verify
  # against and must pass it through rather than invent a provider.
  CHILD_PROVIDER=$(jq -r --arg s "$NAME" '
    if type == "object" and has("seats") then .seats[$s].provider
    else empty end // empty' "$SEAT_MODELS" 2>/dev/null || true)
  # Proxy transport already validated the agent (opus) above — a proxy model's
  # provider (deepseek/zai/...) must NOT be run against the agent's provider
  # lock, or every non-Anthropic cc-ds4 model on an opus seat would be rejected.
  if [ -n "${CHILD_MODEL:-}" ] && [ -n "$CHILD_PROVIDER" ] && \
     [ "${CHILD_TRANSPORT:-}" != "proxy" ]; then
    # Reset per seat: a locked agent whose provider check PASSES never reassigns
    # SKIP_PROVIDER (the `||` short-circuits), so a stale value from an earlier
    # skipped seat would otherwise skip a runnable one.
    SKIP_PROVIDER=""
    case "$AGENT" in
      codex)        [ "$CHILD_PROVIDER" = "openai" ] || SKIP_PROVIDER="codex only runs openai models (got $CHILD_PROVIDER)" ;;
      antigravity)  [ "$CHILD_PROVIDER" = "google" ] || SKIP_PROVIDER="antigravity only runs google models (got $CHILD_PROVIDER)" ;;
      opus|claude)  [ "$CHILD_PROVIDER" = "anthropic" ] || SKIP_PROVIDER="$AGENT only runs anthropic models (got $CHILD_PROVIDER)" ;;
      *) SKIP_PROVIDER="" ;;   # flexible agent (opencode, custom wrappers) — no lock
    esac
    if [ -n "${SKIP_PROVIDER:-}" ]; then
      # Degrade to the seat's configured default, don't skip: the message below
      # promises the seat still runs, and `continue` would silently lose it
      # (CR finding, PR #60). Clear the selected model/effort so invoke-acpx.sh
      # falls back to the config's .model/.effort, and the PROXY_ROUTE from a
      # non-proxy check must not survive either.
      echo "[debate] $NAME: model ${CHILD_MODEL:-<none>} is not runnable by agent $AGENT — $SKIP_PROVIDER — clearing selected model; seat will run at its configured default" >&2
      CHILD_MODEL=""
      CHILD_EFFORT=""
      unset PROXY_ROUTE
      INVOKE_ENV+=("MODEL=" "EFFORT=")
      INVOKE_ENV+=("PROXY_ROUTE=")
    fi
  fi
  # No `disown`. The kernel already reports when a child finishes and how it exited;
  # disowning threw that away and left the runner to rebuild it out of files and a
  # poll loop. Expand SPAWN_PREFIX bash-3.2-safely — "${arr[@]}" of an empty array
  # under `set -u` is an error on the bash macOS ships.
  nohup "${SPAWN_PREFIX[@]+"${SPAWN_PREFIX[@]}"}" env "${INVOKE_ENV[@]}" \
    bash "$SCRIPT_DIR/invoke-acpx.sh" "$CONFIG_FILE" "$WORK_DIR" "$NAME" "$TIMEOUT" \
    > /dev/null 2>"$WORK_DIR/${NAME}-invoke.log" &
  PIDS+=("$!")
  NAMES+=("$NAME")
  BUDGETS+=("$CHILD_BUDGET")
  EXIT_FILES+=("$WORK_DIR/${NAME}-exit.txt")
done

if [ ${#EXIT_FILES[@]} -eq 0 ]; then
  echo "[debate] No reviewers spawned." >&2
  exit 1
fi

# The longest any seat may now run: the slowest seat's own budget. Worst case is
# timeout × (retries + 1), not timeout — a reviewer that retries a blank turn spends
# the full timeout on every attempt, and budgeting one attempt kills it mid-retry.
# Override per seat with POLL_MAX_WAIT.
if [ -n "${POLL_MAX_WAIT:-}" ]; then
  MAX_WAIT="$POLL_MAX_WAIT"
elif [ "$MAX_REVIEWER_BUDGET" -gt 0 ]; then
  MAX_WAIT=$(( MAX_REVIEWER_BUDGET + 60 ))
else
  MAX_WAIT=450
fi

echo "[debate] Waiting for ${#PIDS[@]} reviewer(s) (max wait: ${MAX_WAIT}s)..." >&2

# Under `timeout` a seat is its own process group, so a signal aimed at this runner's
# group no longer reaches it — cancelling a debate would leave the reviewers running,
# and a survivor from the cancelled round would later overwrite the next round's
# review in the same work dir. Tear the seats down explicitly instead.
trap 'kill_all_seats TERM; exit 130' INT
trap 'kill_all_seats TERM; exit 143' TERM

# Fallback bound for hosts with no `timeout` binary. One sleeping process for the
# whole panel, not a poll loop and not per-seat: it is strictly the old global
# MAX_WAIT behaviour, kept because stock macOS has no other bound and an unbounded
# panel hangs the orchestrator. The seats keep their own budgets wherever `timeout`
# exists, and this never arms there.
WATCHDOG_PID=""
if [ -z "$TIMEOUT_BIN" ]; then
  (
    sleep "$MAX_WAIT"
    kill_all_seats TERM
    sleep 5
    kill_all_seats KILL
  ) &
  WATCHDOG_PID=$!
fi

START=$SECONDS
WORST_EXIT=0

for i in "${!PIDS[@]}"; do
  wait "${PIDS[$i]}"
  CODE=$?
  NAME="${NAMES[$i]}"
  EXIT_FILE="${EXIT_FILES[$i]}"

  # 124 covers two clocks and does not say which fired: the agent's own `timeout`
  # inside invoke-acpx.sh publishes 124 and exits 124, and the outer `timeout` here
  # returns 124 when it kills the whole child. 143/137 is the watchdog on a host
  # without `timeout`. Print the seat's budget either way so the two are separable.
  case "$CODE" in
    124)     echo "[debate] $NAME timed out (seat budget ${BUDGETS[$i]}s)." >&2 ;;
    137|143) echo "[debate] $NAME was killed before it finished (seat budget ${BUDGETS[$i]}s)." >&2 ;;
  esac

  # invoke-acpx.sh publishes its own code and exits with the same one, so the file
  # and the wait status agree on every normal path. They diverge only when the child
  # was killed hard enough that its EXIT trap never ran — then the wait status is the
  # only account of what happened, and it goes in the file the orchestrator reads.
  #
  # 137/143 is written as 124. run.md documents 0/4/124/other, and a seat the
  # watchdog killed for running past its budget IS the timeout case — writing the raw
  # signal code would land it in "other" and send the orchestrator looking for an
  # error that never happened.
  if [ ! -f "$EXIT_FILE" ]; then
    case "$CODE" in
      137|143) printf '124\n' > "$EXIT_FILE" ;;
      *)       printf '%s\n' "$CODE" > "$EXIT_FILE" ;;
    esac
  fi

  [ "$CODE" -gt "$WORST_EXIT" ] && WORST_EXIT="$CODE"
done

trap - INT TERM

# Disarm the watchdog. Order matters and is the opposite of the obvious one: killing
# its `sleep` first is what the sleep is waiting for, so the subshell wakes and runs
# its kill path on the way out. Kill the subshell first so that path can never run,
# then clean up the sleep — whose pid has to be read before the parent link is gone,
# because once the subshell dies it reparents to init and `pgrep -P` cannot find it.
if [ -n "$WATCHDOG_PID" ]; then
  WATCHDOG_SLEEP=$(pgrep -P "$WATCHDOG_PID" 2> /dev/null)
  kill "$WATCHDOG_PID" 2> /dev/null
  [ -n "$WATCHDOG_SLEEP" ] && kill $WATCHDOG_SLEEP 2> /dev/null
fi

rm -f "$WORK_DIR"/*-prompt.txt

echo "[debate] All reviewers finished ($(( SECONDS - START ))s elapsed)." >&2
exit "$WORST_EXIT"

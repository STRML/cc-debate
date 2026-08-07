#!/usr/bin/env python3
"""Dynamic panel selector for debate v3 (#31).

Given the model registry and the seats to fill, pick one model per seat maximising
diversity (distinct labs), completeness (a strong-reasoning model on the deepest seat at
high effort), and budget (minimise total cost_per_task), subject to harness feasibility.

Usage:
  select-panel.py --registry <debate-models.json> --seats <comma,list> \
      [--deepest <seat>] [--installed-harnesses <comma,list>] [--min-effort <effort>] \
      [--private-repo] [--agents <seat=agent,...>]
"""
import argparse, json, math, sys
from collections import Counter

RANK = {"low": 0, "medium": 1, "high": 2, "xhigh": 3, "max": 4}
# Provider-locked agents: a model is runnable by the seat's agent iff the agent
# is not in this map (flexible — acpx/opencode --model passthrough can run
# whatever the registry offers), or the model's provider is in the agent's
# locked set. Mirrors the direct-CLI branches in invoke-acpx.sh: agy runs
# Google models only, claude --print runs Anthropic models only, and the local
# Codex CLI refuses every non-OpenAI model_id it is handed. Without this a
# selector filling for lab diversity assigns claude-opus-5 / gemini-3.1-pro /
# glm-5.2 to a codex seat and the seat dies at spawn (observed, 2026-08-06).
AGENT_PROVIDERS = {
    "codex": {"openai"},
    "antigravity": {"google"},   # agy / Gemini CLI
    "opus": {"anthropic"},       # claude --print
    "claude": {"anthropic"},
}
# A model on the cc-ds4 proxy transport only reaches the right branch when the
# seat's agent is `opus` — the proxy handling in invoke-acpx.sh lives inside the
# opus block. Any other agent receives PROXY_ROUTE it ignores and forwards the
# model_id to its own CLI, which refuses it.
PROXY_AGENT = "opus"
# Effort-scaled cost multiplier (a documented, volatile estimate — not a real
# spend cap). Reasoning effort raises cost; the budget uses this to prefer
# lower effort on shallow seats.
EFFORT_MULT = {"low": 1, "medium": 1, "high": 2, "xhigh": 4, "max": 8}

# Fields the selector dereferences directly. An available entry missing any of
# these cannot be scored or slotted and is treated as unselectable (F13).
REQUIRED_KEYS = {"name", "harness", "provider", "model_id", "lab", "strengths", "effort", "price"}

def cost_of(m):
    """cost_per_task of a registry entry; 0 when absent or malformed."""
    try:
        return float((m.get("price") or {}).get("cost_per_task", 0))
    except (TypeError, ValueError):
        return 0

def _effort_choices(m):
    """Supported efforts for a model, sorted low->high. A missing/empty
    effort_range (legacy model) defaults to ['medium'] — it can't go below."""
    rng = m.get("effort_range")
    if isinstance(rng, list) and rng:
        valid = sorted([e for e in rng if e in RANK], key=lambda e: RANK[e])
        if valid:
            return valid
    return ["medium"]

def _tier_for(seat_index, deepest_index, min_effort):
    """Depth-tier effort target for a seat. The deepest seat (the final arbiter)
    gets --min-effort; its immediate predecessor one step below; all earlier
    seats two steps below, floored at 'low'."""
    depth = max(deepest_index - seat_index, 0)
    step = max(RANK.get(min_effort, 3) - min(depth, 2), 0)
    names = sorted(RANK, key=lambda e: RANK[e])
    return names[min(step, len(names) - 1)]

def _effort_for_model(m, tier):
    """Highest supported effort at or below the depth tier, else the model's
    lowest supported effort (round-2: sparse ranges must not yield an
    unsupported value)."""
    choices = _effort_choices(m)
    tier_rank = RANK.get(tier, RANK["medium"])
    at_or_below = [e for e in choices if RANK[e] <= tier_rank]
    eff = max(at_or_below, key=lambda e: RANK[e]) if at_or_below else choices[0]
    # Proxy transport (cc-ds4 routes) maps effort to a ds4-* sentinel that only
    # supports low/high/xhigh/max — invoke-acpx.sh fatals on 'medium'. Clamp
    # 'medium' down to 'low' (the highest supported value at or below it) so a
    # proxy seat on a shallow depth tier does not die at spawn (2026-08-07
    # finding, PR #60).
    if m.get("transport") == "proxy" and eff == "medium":
        return "low"
    return eff

def _effective_cost(m, eff):
    """cost_per_task scaled by effort WITHOUT double-counting: the registry's
    cost_per_task is already measured at the model's DECLARED effort, so
    effective = cost * mult(eff) / mult(declared). A model at its declared
    effort keeps its exact cost (round-3 simplifier)."""
    dm = EFFORT_MULT.get(m.get("effort") or "medium", 1)
    em = EFFORT_MULT.get(eff, 1)
    return cost_of(m) * em / dm

def _safe_key(key):
    """A registry key may come from an untrusted file; strip control characters so
    it cannot spoof or erase the warning line it is echoed into."""
    return "".join(ch for ch in str(key) if ch >= " " or ch == "\t")

def _runnable(m, agent):
    """Can this registry entry actually be executed by the seat's configured agent?

    `harness` names a dispatch class (acpx/subagent), not an executing agent, so
    feasibility is derived from the model's provider vs the agent's lock:

    - `subagent` models run as Claude Code Agent teammates — the caller
      (run.md Step 2a-prime) dispatches them regardless of the seat's acpx agent.
    - `proxy`-transport models (cc-ds4 routes) only work through an `opus` seat —
      the proxy branch in invoke-acpx.sh lives inside the opus block.
    - A provider-locked agent (codex/antigravity/opus/claude) runs only models of
      its own provider; any other model_id forwarded as `--model` makes the CLI
      refuse (codex with claude-opus-5, agy with deepseek-v4-pro, ...).
    - A flexible agent (opencode, kimi, a custom OpenRouter wrapper) can run
      whatever the registry offers — no lock.
    - An empty agent means the seat has no configured acpx agent, so no acpx-
      runnable model is feasible (subagent models still are).
    """
    if m.get("harness") == "subagent":
        return True
    if m.get("transport") == "proxy":
        return agent == PROXY_AGENT
    if not agent:
        return False
    locked = AGENT_PROVIDERS.get(agent)
    return True if locked is None else m.get("provider") in locked

def load(data):
    """Filter to available models usable via an installed harness.

    Malformed entries (available but missing fields the selector dereferences, or
    with wrong-typed / negative / non-finite values) are skipped with a warning
    instead of crashing the panel (F13). `available: "false"` — a string — is
    truthy and must not select; it must be a real bool.
    """
    out = []
    for key, m in data.items():
        safe = _safe_key(key)
        if not isinstance(m, dict):
            sys.stderr.write("⚠️ registry entry '%s' is not an object; skipping as unselectable\n" % safe)
            continue
        if not isinstance(m.get("available"), bool) or not m["available"]:
            continue
        missing = REQUIRED_KEYS - set(m)
        if missing:
            sys.stderr.write("⚠️ registry entry '%s' missing %s; skipping as unselectable\n" % (safe, sorted(missing)))
            continue
        if not isinstance(m["strengths"], (list, tuple, set)):
            sys.stderr.write("⚠️ registry entry '%s' strengths is not a list; skipping as unselectable\n" % safe)
            continue
        # lab and effort are used as hashable scalar keys/sorts; a list or dict
        # crashes the panel. available is checked above.
        if not isinstance(m["lab"], str) or not isinstance(m["effort"], str):
            sys.stderr.write("⚠️ registry entry '%s' lab/effort must be strings; skipping as unselectable\n" % safe)
            continue
        if not isinstance(m["price"], dict) or not isinstance(m["price"].get("cost_per_task"), (int, float)):
            sys.stderr.write("⚠️ registry entry '%s' price.cost_per_task is not a number; skipping as unselectable\n" % safe)
            continue
        cpt = m["price"]["cost_per_task"]
        if cpt < 0 or not math.isfinite(cpt):
            sys.stderr.write("⚠️ registry entry '%s' price.cost_per_task is negative or non-finite; skipping as unselectable\n" % safe)
            continue
        out.append({**m, "key": key})
    return out

def pick(registry, seats, deepest, installed, min_effort, private=False, agents=None):
    """agents: optional {seat: agent} map constraining each seat to models its
    configured agent can run (see _runnable). None = legacy permissive behavior."""
    route_ok = {None, 31501, 31502}
    pool = [m for m in load(registry)
            if not installed or (m.get("harness") in installed)]
    # Validate route: must be null or an allowed integer; never trust raw
    # registry text in a URL context (#52).
    for m in pool:
        r = m.get("route")
        if r not in route_ok:
            sys.stderr.write("⚠️ registry entry '%s' route %r invalid or untrusted; skipping\n" % (_safe_key(m.get("key", "?")), r))
            pool = [x for x in pool if x is not m]
    if pool and private:
        # ZDR = route 31501 (openrouter). On a private repo, ZDR is a hard
        # constraint, not a preference: filter to zdr-capable entries. If the
        # zdr pool cannot fill every seat, FAIL — a smaller all-ZDR panel beats
        # a full panel that routes private content through non-ZDR models.
        zdr_pool = [m for m in pool if m.get("route") == 31501]
        if not zdr_pool:
            return None, "no ZDR-capable models available for a private repo (route 31501); refusing to route private content through non-ZDR models", 0
        if len(zdr_pool) < len(seats):
            return None, (
                "only %d ZDR model(s) available for %d seats on a private repo; "
                "ZDR is a hard constraint — request fewer seats or add ZDR models"
                % (len(zdr_pool), len(seats))
            ), 0
        pool = zdr_pool
    if not pool:
        return None, "no available models for installed harnesses", 0

    # sort strongest-reasoning first so the deepest seat gets first pick of ability
    by_strength = sorted(pool, key=lambda m: (
        ("reasoning" in m.get("strengths", []) or "tricky" in m.get("strengths", [])),
        RANK.get(m.get("effort"), 0),
    ), reverse=True)

    used_labs = Counter()
    assignment = {}

    def take(pref):
        # prefer a model from an unused lab, then cheapest within an unused family
        for m in pref:
            if used_labs[m.get("lab")] == 0:
                used_labs[m.get("lab")] += 1
                return m, False
        for m in pref:  # fall back: re-use a lab (warn)
            used_labs[m.get("lab")] += 1
            return m, True
        return None, False

    # deepest seat first: strongest reasoning, at least min_effort, and (when
    # the seat's agent is known) only models that agent can actually run.
    agent_pool = [m for m in by_strength if not agents or _runnable(m, agents.get(deepest))]
    first = [m for m in agent_pool if RANK.get(m.get("effort"), 0) >= RANK.get(min_effort, 0)]
    if not first:
        sys.stderr.write("⚠️ no available model reaches effort %s — falling back to strongest available\n" % min_effort)
    deepest_pool = first or agent_pool
    m, _ = take(deepest_pool)
    # The deepest seat is not a hard requirement: an agent with no runnable model
    # leaves that one seat unfilled (it falls back to its configured default
    # downstream) rather than killing the whole panel. A truly empty registry —
    # no models at all, not just none for one agent — still fails closed.
    if m is None and not by_strength:
        return None, "registry empty after filtering", 0
    if m is not None:
        assignment[deepest] = m
        assigned_keys = {m["key"]}
    else:
        assigned_keys = set()
        sys.stderr.write("⚠️ no model runnable by agent for deepest seat '%s' — leaving it unfilled "
                         "(falls back to its configured default)\n" % _safe_key(deepest))

    spent = cost_of(assignment.get(deepest) or {})

    # remaining seats: cheapest cost_per_task, unused lab, never the same model twice.
    for seat in seats:
        if seat == deepest:
            continue
        cands = [x for x in by_strength if x["key"] not in assigned_keys
                 and (not agents or _runnable(x, agents.get(seat)))]
        if not cands:
            continue  # pool smaller than the seat list
        cands.sort(key=lambda x: (used_labs[x.get("lab")] != 0, cost_of(x)))
        m, _ = take(cands)
        if m is None:
            continue
        assignment[seat] = m
        assigned_keys.add(m["key"])

    # --- Effort auto-scaling (epic Q2) ---
    # Derive a per-seat effective effort (depth tier, capped to the model's
    # supported range). The deepest seat (the arbiter) stays at the tier; shallower
    # seats sit one or two steps below, floored at 'low'.
    i_d = seats.index(deepest) if deepest in seats else len(seats) - 1
    eff_by_seat = {}
    for i, seat in enumerate(seats):
        if seat not in assignment:
            continue
        eff_by_seat[seat] = _effort_for_model(assignment[seat], _tier_for(i, i_d, min_effort))

    # Diversity is measured over the seats that were actually FILLED.
    n_labs = len(set(x.get("lab") for x in assignment.values()))
    if n_labs < len(assignment):
        sys.stderr.write(f"⚠️ low model diversity — {len(assignment)} seats, {n_labs} distinct labs\n")

    # Attach the derived effort/cost to the assignment for the output.
    for seat, eff in eff_by_seat.items():
        assignment[seat] = {**assignment[seat], "effective_effort": eff,
                            "effective_cost": _effective_cost(assignment[seat], eff)}

    # ZDR is a hard constraint on a private repo, not a degrade-to-default: a
    # seat left unfilled by agent feasibility would fall back to its configured
    # default, which is NOT proven to route through ZDR (route 31501) — silently
    # shipping private content over a non-ZDR model. The ZDR pool above only
    # checks count; agent filtering can still empty a seat's candidates. Fail
    # closed instead (CR finding, PR #60).
    if private:
        unfilled = [s for s in seats if s not in assignment]
        if unfilled:
            return None, (
                "private repo: %d seat(s) could not be assigned a ZDR-capable model "
                "their agent can run: %s — refusing to route private content through "
                "non-ZDR defaults; add a ZDR-capable model for these seats or drop them"
                % (len(unfilled), ", ".join(_safe_key(s) for s in unfilled))
            ), 0

    return assignment, None, n_labs

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--registry", required=True)
    ap.add_argument("--seats", required=True)            # comma list (order = depth)
    ap.add_argument("--deepest", default=None)           # default = last seat
    ap.add_argument("--installed-harnesses", default="") # comma list
    ap.add_argument("--min-effort", default="xhigh")
    ap.add_argument("--private-repo", action="store_true", default=False)
    ap.add_argument("--agents", default=None,
                    help="comma list 'seat=agent,...' constraining each seat to models "
                         "its configured agent can run; absent = legacy permissive selection")
    a = ap.parse_args()
    seats = [s.strip() for s in a.seats.split(",") if s.strip()]
    deepest = a.deepest or seats[-1] if seats else "pentester"
    if deepest not in seats:
        # --deepest names a seat the caller did not list; honor it rather than let it
        # grab a slot and push a requested seat out.
        seats = seats + [deepest]
    installed = [s.strip() for s in a.installed_harnesses.split(",") if s.strip()]
    agents = None
    if a.agents:
        agents = {}
        for tok in a.agents.split(","):
            seat, _, agent = tok.strip().partition("=")
            if seat:
                agents[seat] = agent
    elif installed:
        # Selection is provider-agnostic without the per-seat map: a codex seat
        # can then be handed claude-opus-5 and dies at spawn. Say so once so a
        # caller that dropped --agents hears it.
        sys.stderr.write("⚠️ no --agents map — per-seat provider feasibility is not enforced; "
                         "a seat may be assigned a model its agent cannot run\n")
    if a.private_repo and not agents:
        # On a private repo the agents map is load-bearing for ZDR correctness:
        # it is what guarantees a seat only gets a ZDR-capable model its agent can
        # actually run. Without it the selector may hand a seat a ZDR model the
        # agent cannot execute (or none at all), and the run falls back to a
        # non-ZDR default. Hard-fail rather than silently weaken the constraint
        # (2026-08-07 finding, PR #60).
        print(json.dumps({"error": "private repo requires --agents <seat=agent,...>: without the "
                          "per-seat agent map the ZDR hard constraint cannot be enforced — "
                          "rejecting to avoid routing private content through non-ZDR defaults"}))
        sys.exit(1)
    reg = json.load(open(a.registry))
    assignment, err, nlabs = pick(reg, seats, deepest, installed, a.min_effort,
                                  private=a.private_repo, agents=agents)
    if assignment is None:
        print(json.dumps({"error": err})); sys.exit(1)
    print(json.dumps({
        "seats": {seat: {"model": m["key"], "name": m.get("name"), "harness": m.get("harness"),
                         "transport": m.get("transport"),
                         "route": m.get("route"),
                         "provider": m.get("provider"), "model_id": m.get("model_id"),
                         "effort": m.get("effective_effort", m.get("effort")),
                         "effective_effort": m.get("effective_effort"),
                         "cost_per_task": cost_of(m),
                         "effective_cost": m.get("effective_cost", cost_of(m)),
                         "repo_aware": m.get("repo_aware")} for seat, m in assignment.items()},
        "distinct_labs": nlabs,
    }, indent=2))

if __name__ == "__main__":
    main()

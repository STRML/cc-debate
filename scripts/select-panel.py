#!/usr/bin/env python3
"""Dynamic panel selector for debate v3 (#31).

Given the model registry and the seats to fill, pick one model per seat maximising
diversity (distinct labs), completeness (a strong-reasoning model on the deepest seat at
high effort), and budget (minimise total cost_per_task), subject to harness feasibility.

Usage:
  select-panel.py --registry <debate-models.json> --seats <comma,list> \
      [--deepest <seat>] [--installed-harnesses <comma,list>] [--min-effort <effort>] \
      [--max-cost <panel USD budget>]

--max-cost is a HARD total panel budget: if any requested seat cannot be filled
within it, selection fails with an error rather than returning a partial panel.
"""
import argparse, json, math, sys
from collections import Counter

RANK = {"low": 0, "medium": 1, "high": 2, "xhigh": 3, "max": 4}
# Binary-float comparisons on decimal budgets (0.10 + 0.20 vs 0.30) are off by
# one ulp; a small tolerance keeps a feasible panel from being rejected.
COST_EPS = 1e-9

# Fields the selector dereferences directly. An available entry missing any of
# these cannot be scored or slotted and is treated as unselectable (F13).
REQUIRED_KEYS = {"name", "harness", "provider", "model_id", "lab", "strengths", "effort", "price"}

def cost_of(m):
    """cost_per_task of a registry entry; 0 when absent or malformed."""
    try:
        return float((m.get("price") or {}).get("cost_per_task", 0))
    except (TypeError, ValueError):
        return 0

def _safe_key(key):
    """A registry key may come from an untrusted file; strip control characters so
    it cannot spoof or erase the warning line it is echoed into."""
    return "".join(ch for ch in str(key) if ch >= " " or ch == "\t")

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

def pick(registry, seats, deepest, installed, min_effort, max_cost=None):
    pool = [m for m in load(registry)
            if not installed or (m.get("harness") in installed)]
    if max_cost is not None:
        # --max-cost is a HARD panel budget, not a ceiling a caller can shrug off.
        # If even the cheapest available model cannot fit under the cap, fail loudly
        # (F5) instead of silently dropping the budget and building an unbudgeted panel.
        within = [m for m in pool if cost_of(m) <= max_cost]
        if not within:
            cheapest = min(pool, key=cost_of) if pool else None
            if cheapest is None:
                return None, "no available models for installed harnesses", 0
            return None, (
                "--max-cost %.2f cannot fit even the cheapest available model '%s' "
                "(cost_per_task %.2f); raise --max-cost or drop the cap"
                % (max_cost, cheapest.get("key", "?"), cost_of(cheapest))
            ), 0
        # Filtering the pool to the cap also bounds the deepest seat's pick, so a
        # single dear model can't swallow the whole panel budget up front (F10).
        pool = within
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

    # deepest seat first: strongest reasoning, at least min_effort. Under a hard
    # budget, RESERVE enough for the rest of the panel before fixing this pick — a
    # greedy strongest-first choice that spends the whole cap is how a feasible panel
    # (one dear model + three cheap ones) got spuriously rejected.
    first = [m for m in by_strength if RANK.get(m.get("effort"), 0) >= RANK.get(min_effort, 0)]
    if not first:
        sys.stderr.write("⚠️ no available model reaches effort %s — falling back to strongest available\n" % min_effort)
    deepest_pool = first or by_strength
    if max_cost is not None and len(seats) > 1:
        cheapest = min(pool, key=cost_of)
        reserve = max_cost - (len(seats) - 1) * cost_of(cheapest)
        reserved = [m for m in deepest_pool if cost_of(m) <= reserve + COST_EPS]
        if reserved:
            deepest_pool = reserved
    m, _ = take(deepest_pool)
    if m is None:
        return None, "registry empty after filtering", 0
    assignment[deepest] = m
    assigned_keys = {m["key"]}

    spent = cost_of(assignment[deepest])

    # remaining seats: cheapest cost_per_task, unused lab, never the same model twice,
    # and never past the panel budget. A requested seat the budget cannot pay for is a
    # HARD error (F10) — a 3-seat request silently becoming 1 seat is not allowed. This
    # applies whenever a seat cannot be filled under a cap (empty pool included), not
    # only when a candidate exists but costs too much.
    unfilled = []
    for seat in seats:
        if seat == deepest:
            continue
        cands = [x for x in by_strength if x["key"] not in assigned_keys]
        if not cands:
            if max_cost is not None:
                unfilled.append(seat)
            continue  # pool smaller than the seat list (pre-existing without a cap)
        if max_cost is not None:
            affordable = [x for x in cands if spent + cost_of(x) <= max_cost + COST_EPS]
            if not affordable:
                unfilled.append(seat)
                continue
            cands = affordable
        cands.sort(key=lambda x: (used_labs[x.get("lab")] != 0, cost_of(x)))
        m, _ = take(cands)
        if m is None:
            if max_cost is not None:
                unfilled.append(seat)
            continue
        assignment[seat] = m
        assigned_keys.add(m["key"])
        spent += cost_of(m)

    if unfilled:
        return None, (
            "--max-cost %.2f cannot fill requested seat(s) %s within budget "
            "(already spent %.2f); raise --max-cost or request fewer seats"
            % (max_cost, ", ".join(unfilled), spent)
        ), 0

    # Diversity is measured over the seats that were actually FILLED — a budget that
    # leaves seats unfilled is now a hard error above, not a diversity problem.
    n_labs = len(set(x.get("lab") for x in assignment.values()))
    if n_labs < len(assignment):
        sys.stderr.write(f"⚠️ low model diversity — {len(assignment)} seats, {n_labs} distinct labs\n")
    return assignment, None, n_labs

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--registry", required=True)
    ap.add_argument("--seats", required=True)            # comma list (order = depth)
    ap.add_argument("--deepest", default=None)           # default = last seat
    ap.add_argument("--installed-harnesses", default="") # comma list
    ap.add_argument("--min-effort", default="xhigh")
    ap.add_argument("--max-cost", type=float, default=None)
    a = ap.parse_args()
    seats = [s.strip() for s in a.seats.split(",") if s.strip()]
    deepest = a.deepest or seats[-1] if seats else "pentester"
    if deepest not in seats:
        # --deepest names a seat the caller did not list; honor it rather than let it
        # grab a slot and push a requested seat out.
        seats = seats + [deepest]
    installed = [s.strip() for s in a.installed_harnesses.split(",") if s.strip()]
    reg = json.load(open(a.registry))
    assignment, err, nlabs = pick(reg, seats, deepest, installed, a.min_effort, a.max_cost)
    if assignment is None:
        print(json.dumps({"error": err})); sys.exit(1)
    print(json.dumps({
        "seats": {seat: {"model": m["key"], "name": m.get("name"), "harness": m.get("harness"),
                         "provider": m.get("provider"), "model_id": m.get("model_id"),
                         "effort": m.get("effort"), "cost_per_task": cost_of(m),
                         "repo_aware": m.get("repo_aware")} for seat, m in assignment.items()},
        "distinct_labs": nlabs,
    }, indent=2))

if __name__ == "__main__":
    main()

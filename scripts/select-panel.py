#!/usr/bin/env python3
"""Dynamic panel selector for debate v3 (#31).

Given the model registry and the seats to fill, pick one model per seat maximising
diversity (distinct labs), completeness (a strong-reasoning model on the deepest seat at
high effort), and budget (minimise total cost_per_task), subject to harness feasibility.

Usage:
  select-panel.py --registry <debate-models.json> --seats <comma,list> \
      [--deepest <seat>] [--installed-harnesses <comma,list>] [--min-effort <effort>]
"""
import argparse, json, sys
from collections import Counter

RANK = {"low": 0, "medium": 1, "high": 2, "xhigh": 3, "max": 4}
EFFORT_ORDER = ["low", "medium", "high", "xhigh", "max"]

def load(data):
    """Filter to available models usable via an installed harness."""
    out = []
    for key, m in data.items():
        if not m.get("available"):
            continue
        out.append({**m, "key": key})
    return out

def pick(registry, seats, deepest, installed, min_effort, max_cost=None):
    pool = [m for m in load(registry)
            if not installed or m["harness"] in installed]
    if max_cost is not None:
        within = [m for m in pool if m["price"].get("cost_per_task", 0) <= max_cost]
        if not within:
            sys.stderr.write("⚠️ --max-cost %.2f excludes every available model; ignoring budget\n" % max_cost)
        else:
            pool = within
    if not pool:
        return None, "no available models for installed harnesses", 0

    # sort strongest-reasoning first so the deepest seat gets first pick of ability
    by_strength = sorted(pool, key=lambda m: (
        ("reasoning" in m["strengths"] or "tricky" in m["strengths"]),
        RANK.get(m["effort"], 0),
    ), reverse=True)

    used_labs = Counter()
    assignment = {}

    def take(pref):
        # prefer a model from an unused lab, then cheapest within an unused family
        for m in pref:
            if used_labs[m["lab"]] == 0:
                used_labs[m["lab"]] += 1
                return m, False
        for m in pref:  # fall back: re-use a lab (warn)
            used_labs[m["lab"]] += 1
            return m, True
        return None, False

    warned = False
    # deepest seat first: strongest reasoning, at least min_effort
    first = [m for m in by_strength if RANK.get(m["effort"],0) >= RANK.get(min_effort,0)]
    if not first:
        sys.stderr.write("⚠️ no available model reaches effort %s — falling back to strongest available\n" % min_effort)
    m, w = take(first or by_strength)
    if m is None:
        return None, "registry empty after filtering", 0
    warned = warned or w
    assignment[deepest] = m
    assigned_keys = {m["key"]}

    # remaining seats: cheapest cost_per_task, unused lab, never the same model twice
    for seat in seats:
        if seat == deepest:
            continue
        cands = [x for x in by_strength if x["key"] not in assigned_keys]
        cands.sort(key=lambda x: (used_labs[x["lab"]] != 0, x["price"].get("cost_per_task", 0)))
        m, w = take(cands)
        if m is None:
            continue
        warned = warned or w
        assignment[seat] = m
        assigned_keys.add(m["key"])

    n_labs = len(set(x["lab"] for x in assignment.values()))
    if n_labs < len(seats):
        warned = True
        sys.stderr.write(f"⚠️ low model diversity — {len(seats)} seats, {n_labs} distinct labs\n")
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
    installed = [s.strip() for s in a.installed_harnesses.split(",") if s.strip()]
    reg = json.load(open(a.registry))
    assignment, err, nlabs = pick(reg, seats, deepest, installed, a.min_effort, a.max_cost)
    if assignment is None:
        print(json.dumps({"error": err})); sys.exit(1)
    print(json.dumps({
        "seats": {seat: {"model": m["key"], "name": m["name"], "harness": m["harness"],
                         "provider": m["provider"], "model_id": m["model_id"],
                         "effort": m["effort"], "cost_per_task": m["price"]["cost_per_task"],
                         "repo_aware": m.get("repo_aware")} for seat, m in assignment.items()},
        "distinct_labs": nlabs,
    }, indent=2))

if __name__ == "__main__":
    main()

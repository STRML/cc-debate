#!/usr/bin/env python3
"""Lint the debate model registry schema (debate v3, #31).

Every entry must carry model + price(cost_per_task) + strengths + effort + harness
(+repo_aware). Unique lab/model_id; valid enums; effort in effort_range. This is the
definition-of-done Task 1 gate: if these invariants break, the dynamic selector (Task 2)
has no sound input to choose from.
"""
import json, os, sys

REQUIRED = {"name", "harness", "provider", "model_id", "family", "lab",
            "strengths", "effort", "effort_range", "price", "cost",
            "repo_aware", "available"}

HARNESS = {"acpx", "subagent"}
TRANSPORT = {"acpx", "proxy", "subagent"}
ROUTES = {None, 31501, 31502}
COST = {"cheap", "mid", "premium"}
EFFORT = {"low", "medium", "high", "xhigh", "max"}
STRENGTHS = {"reasoning", "code", "speed", "cost", "general", "math", "tricky"}

def main():
    here = os.path.dirname(os.path.abspath(__file__))
    path = os.path.normpath(os.path.join(here, "..", "hermes", "templates", "debate-models.json"))
    data = json.load(open(path))
    errs = []
    moons = set()
    for k, m in data.items():
        if not isinstance(m, dict):
            errs.append(f"{k}: not an object"); continue
        missing = REQUIRED - set(m)
        if missing: errs.append(f"{k}: missing {sorted(missing)}")
        if m.get("harness") not in HARNESS: errs.append(f"{k}: bad harness {m.get('harness')}")
        t = m.get("transport")
        if t is not None and t not in TRANSPORT: errs.append(f"{k}: bad transport {t}")
        r = m.get("route")
        if r not in ROUTES: errs.append(f"{k}: bad route {r}")
        # Invariants from the proxy-transport design (#52/#53): proxy seats must
        # be acpx-harness (the subagent skip would drop them), a proxy seat needs
        # a valid route, and a route implies proxy transport.
        if t == "proxy":
            if m.get("harness") != "acpx": errs.append(f"{k}: transport=proxy but harness={m.get('harness')}")
            if r not in (31501, 31502): errs.append(f"{k}: transport=proxy needs route 31501/31502, got {r}")
        if r is not None and t != "proxy": errs.append(f"{k}: route set but transport={t}")
        if m.get("cost") not in COST: errs.append(f"{k}: bad cost {m.get('cost')}")
        if m.get("effort") not in EFFORT: errs.append(f"{k}: bad effort {m.get('effort')}")
        er = set(m.get("effort_range", []))
        if not er.issubset(EFFORT): errs.append(f"{k}: effort_range values out of set")
        if m.get("effort") not in er: errs.append(f"{k}: effort {m.get('effort')} not in effort_range")
        bad = set(m.get("strengths", [])) - STRENGTHS
        if bad: errs.append(f"{k}: unknown strengths {sorted(bad)}")
        p = m.get("price") or {}
        for f in ("in", "out", "cost_per_task"):
            if not isinstance(p.get(f), (int, float)) or p.get(f) < 0:
                errs.append(f"{k}: price.{f} must be non-negative number")
        for flag in ("repo_aware", "available"):
            if not isinstance(m.get(flag), bool): errs.append(f"{k}: {flag} not bool")
        if m.get("elo") is not None and not isinstance(m.get("elo"), (int, float)):
            errs.append(f"{k}: elo must be a number")
        # NOTE: lab uniqueness is NOT enforced here — the registry legitimately holds
        # multiple models from one lab (e.g. GPT-5.6 Luna/Terra/Sol == openai). Lab
        # diversity is enforced by the SELECTOR (Task 2) at panel-pick time, not here.
        if m.get("model_id") in moons: errs.append(f"{k}: duplicate model_id {m.get('model_id')}")
        moons.add(m.get("model_id"))
    if errs:
        print("FAIL: " + "; ".join(errs)); sys.exit(1)
    print(f"OK: {len(data)} entries, schema valid")

if __name__ == "__main__":
    main()

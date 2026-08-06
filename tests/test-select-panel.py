#!/usr/bin/env python3
"""Unit tests for scripts/select-panel.py (debate v3, #31)."""
import importlib.util, io, json, os, sys
_here = os.path.dirname(os.path.abspath(__file__))
_sel_path = os.path.join(_here, "..", "scripts", "select-panel.py")
_spec = importlib.util.spec_from_file_location("select_panel", _sel_path)
select_panel = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(select_panel)

FIX = {
  "luna":  {"name":"Luna","harness":"acpx","provider":"openai","model_id":"luna","family":"oai","lab":"openai","strengths":["speed","cost"],"effort":"high","effort_range":["low","high"],"price":{"in":1,"out":6,"cost_per_task":0.07},"cost":"cheap","repo_aware":False,"available":True},
  "terra": {"name":"Terra","harness":"acpx","provider":"openai","model_id":"terra","family":"oai","lab":"openai","strengths":["reasoning"],"effort":"high","effort_range":["low","high"],"price":{"in":2.5,"out":15,"cost_per_task":0.43},"cost":"mid","repo_aware":False,"available":True},
  "sol":   {"name":"Sol","harness":"acpx","provider":"openai","model_id":"sol","family":"oai","lab":"openai","strengths":["reasoning","tricky"],"effort":"xhigh","effort_range":["low","xhigh"],"price":{"in":5,"out":30,"cost_per_task":1.86},"cost":"premium","repo_aware":False,"available":True},
  "glm":   {"name":"GLM","harness":"acpx","provider":"zai","model_id":"glm-5.2","family":"glm","lab":"zai","strengths":["reasoning","code"],"effort":"max","effort_range":["medium","max"],"price":{"in":0.95,"out":3,"cost_per_task":0.69},"cost":"cheap","repo_aware":True,"available":True},
  "ds":    {"name":"DeepSeek","harness":"subagent","provider":"deepseek","model_id":"ds","family":"ds","lab":"deepseek","strengths":["reasoning","code"],"effort":"high","effort_range":["low","max"],"price":{"in":0.435,"out":0.87,"cost_per_task":0.05},"cost":"cheap","repo_aware":True,"available":True},
  # ZDR proxy variants (route 31501 = openrouter/ZDR, 31502 = nous). ds_or is the
  # only ZDR-capable entry.
  "ds_or": {"name":"DeepSeek ZDR","harness":"acpx","transport":"proxy","route":31501,"provider":"deepseek","model_id":"ds-or","family":"ds","lab":"deepseek","strengths":["reasoning","code"],"effort":"high","effort_range":["low","max"],"price":{"in":0.22,"out":0.44,"cost_per_task":0.03},"cost":"cheap","repo_aware":True,"available":True},
  "ds_n":  {"name":"DeepSeek Nous","harness":"acpx","transport":"proxy","route":31502,"provider":"deepseek","model_id":"ds-n","family":"ds","lab":"deepseek","strengths":["reasoning","code"],"effort":"high","effort_range":["low","max"],"price":{"in":0.22,"out":0.44,"cost_per_task":0.03},"cost":"cheap","repo_aware":True,"available":True},
  "gem1":  {"name":"Gemini Pro","harness":"acpx","provider":"google","model_id":"gem1","family":"gemini","lab":"google","strengths":["reasoning"],"effort":"high","effort_range":["low","high"],"price":{"in":2,"out":12,"cost_per_task":0.34},"cost":"mid","repo_aware":True,"available":True},
  "op1":   {"name":"Opus","harness":"acpx","provider":"anthropic","model_id":"op1","family":"claude","lab":"anthropic","strengths":["reasoning","tricky"],"effort":"xhigh","effort_range":["low","max"],"price":{"in":5,"out":25,"cost_per_task":2.34},"cost":"premium","repo_aware":False,"available":True},
}
SEATS = ["simplifier", "operator", "pentester"]

def run(**kw):
    return select_panel.pick(FIX, SEATS, "pentester", kw.get("installed", []), kw.get("me", "xhigh"))

fails = 0
def check(name, cond, detail=""):
    global fails
    if cond: print(f"  ok: {name}")
    else: fails += 1; print(f"  FAIL: {name} {detail}")

# 1. distinct labs across seats when possible (openai,zai,deepseek -> 3)
a,err,nl = run()
check("distinct labs when possible", a is not None and nl >= 3, f"labs={nl} err={err}")

# 2. strongest-reasoning (effort>=xhigh) lands on deepest seat
pent = a["pentester"]
check("deepest seat is xhigh reasoning", pent["key"] == "sol" or pent["key"] == "glm", pent["key"])
check("deepest effort>=xhigh", pent["effort"] in ("xhigh","max"), pent["effort"])

# 3. cheapest-first on remaining seats (cost_per_task), avoid duplicate model
check("no seat repeats the deepest model", all(m["key"] != pent["key"] for s,m in a.items() if s!="pentester"))
sum_cost = sum(m["price"]["cost_per_task"] for m in a.values())
check("panel is cheap (sum under 1.0)", sum_cost < 1.0, f"sum={sum_cost:.2f}")

# 4. unusable harness dropped: only subagent available
a2,err2,nl2 = run(installed=["subagent"])
check("only subagent harness used", a2 is not None and all(m["harness"]=="subagent" for m in a2.values()), str(a2))

# 5. low diversity warning when seats > labs
RED = {k:v for k,v in FIX.items() if k in ("luna","terra","sol")}  # all openai
a3,err3,nl3 = select_panel.pick(RED, ["a","b","c"], "c", [], "xhigh")
check("warns on low diversity (labs < seats)", nl3 == 1, f"labs={nl3}")

# 6. model_id unique choice: terra never chosen twice
ids = [m["model_id"] for m in a.values()]
check("model_ids unique in assignment", len(ids) == len(set(ids)), ids)

# 7. regression: 3 seats, only one-lab models available -> still no duplicate model
ONELAB = {k: v for k, v in FIX.items() if v["lab"] == "openai"}
a6, err6, nl6 = select_panel.pick(ONELAB, ["a", "b", "c"], "c", [], "xhigh")
u = [m["key"] for m in a6.values()]
check("no duplicate model even with one lab", len(u) == len(set(u)), str(u))

# 8. F13: an available entry missing price/strengths/lab is skipped with a warning,
#     not a crash; the rest of the panel still builds.
MAL = {k: v for k, v in FIX.items()}
MAL["broken"] = {"name": "Broken", "harness": "acpx", "provider": "x", "model_id": "b",
                 "family": "b", "effort": "high", "effort_range": ["high"], "cost": "cheap",
                 "repo_aware": False, "available": True}
a8, err8, nl8 = select_panel.pick(MAL, SEATS, "pentester", [], "xhigh")
picked = [m["key"] for m in a8.values()] if a8 else []
check("malformed available entry skipped, panel survives",
      a8 is not None and "broken" not in picked, f"picked={picked} err={err8}")

# --- effort auto-scaling (#31 Q2) ---

# 12. sparse-range membership: a model whose effort_range does not contain the
#     depth tier gets the highest supported effort AT OR BELOW it — never an
#     unsupported value. glm has range ['medium','max'] (no high/xhigh), so
#     tier high clamps down to medium, tier xhigh clamps down to medium too,
#     and tier max reaches max.
eff = select_panel._effort_for_model(FIX["glm"], "xhigh")
check("sparse-range clamps to highest supported effort",
      eff == "medium", f"got {eff}")
eff2 = select_panel._effort_for_model(FIX["glm"], "max")
check("sparse-range reaches the top at tier max",
      eff2 == "max", f"got {eff2}")
eff3 = select_panel._effort_for_model(FIX["glm"], "low")
check("sparse-range floors at the lowest supported effort",
      eff3 == "medium", f"got {eff3}")

# 13. missing effort_range defaults to ['medium'] and can't be stepped below.
miss = {"name":"M","harness":"acpx","provider":"p","model_id":"m","family":"f",
        "lab":"openai","strengths":["reasoning"],"effort":"medium",
        "price":{"in":1,"out":2,"cost_per_task":0.1},"cost":"cheap",
        "repo_aware":False,"available":True}
check("missing effort_range defaults to medium",
      select_panel._effort_choices(miss) == ["medium"], str(select_panel._effort_choices(miss)))
check("legacy model effort_for_model is medium at any tier",
      select_panel._effort_for_model(miss, "low") == "medium"
      and select_panel._effort_for_model(miss, "xhigh") == "medium")

# 14. _effective_cost keeps the registry cost when the model runs at its declared
#     effort, and scales by the multiplier otherwise (no double-count).
check("declared-effort run keeps exact cost_per_task",
      abs(select_panel._effective_cost(FIX["glm"], "max") - 0.69) < 1e-9,
      f"got {select_panel._effective_cost(FIX['glm'], 'max')}")
check("effort-scaled cost uses mult ratio",
      abs(select_panel._effective_cost(FIX["glm"], "medium") - 0.69 / 8) < 1e-9,
      f"got {select_panel._effective_cost(FIX['glm'], 'medium')}")

# 15. depth tiers: deepest gets --min-effort, predecessor one below, earlier two below.
check("depth tier step function",
      select_panel._tier_for(2, 2, "xhigh") == "xhigh"
      and select_panel._tier_for(1, 2, "xhigh") == "high"
      and select_panel._tier_for(0, 2, "xhigh") == "medium",
      f"{select_panel._tier_for(2,2,'xhigh')},{select_panel._tier_for(1,2,'xhigh')},{select_panel._tier_for(0,2,'xhigh')}")
check("depth tier floors at low",
      select_panel._tier_for(0, 2, "medium") == "low"
      and select_panel._tier_for(1, 2, "medium") == "low"
      and select_panel._tier_for(2, 2, "medium") == "medium")

# 16. a legacy model (no effort_range) is treated as medium effort end-to-end:
#     it is clamped to medium on the deepest seat, cannot be stepped below
#     medium, and keeps its exact cost_per_task (medium mult = 1).
legacy_deep = {**miss, "key": "legacy", "strengths": ["reasoning", "tricky"]}
def _cheap(name, lab):
    return {"name": name, "harness": "acpx", "provider": "p", "model_id": name.lower(),
            "family": "f", "lab": lab, "strengths": ["speed"], "effort": "medium",
            "effort_range": ["low", "high"], "price": {"in": 1, "out": 2, "cost_per_task": 0.3},
            "cost": "cheap", "repo_aware": False, "available": True}
LEGACY2 = {
  "legacy": legacy_deep,                 # no effort_range, declared medium, cost 0.10
  "cheapA": _cheap("CheapA", "l2"),
  "cheapB": _cheap("CheapB", "l3"),
}
a17, err17, nl17 = select_panel.pick(LEGACY2, SEATS, "pentester", [], "xhigh")
check("legacy model on deepest seat stays medium",
      a17 is not None and a17["pentester"]["effective_effort"] == "medium",
      f"err={err17} pentester={a17.get('pentester',{}).get('effective_effort') if a17 else None}")
if a17:
    check("legacy seat keeps exact cost_per_task",
          abs(a17["pentester"]["effective_cost"] - 0.10) < 1e-9,
          f"got {a17['pentester']['effective_cost']}")
    check("legacy seat is named in the assignment",
          a17["pentester"]["key"] == "legacy",
          f"got {a17['pentester']['key']}")

# 18. private-repo ZDR preference: a single ZDR-capable seat picks route 31501
a18, err18, nl18 = select_panel.pick(FIX, ["executor"], "executor", [], "high", private=True)
check("private single-seat picks ZDR route",
      a18 is not None and a18["executor"]["route"] == 31501,
      f"err={err18} got={a18.get('executor',{}).get('route') if a18 else None}")

# 19. private with 1 ZDR for 3 seats -> HARD error, never a non-ZDR panel.
#     ZDR is a privacy constraint: a private repo must not route content through
#     non-ZDR models, even if it means no panel (Hermes P1).
a19, err19, _ = select_panel.pick(FIX, SEATS, "pentester", [], "xhigh", private=True)
check("private 3-seat with 1 ZDR fails closed (never non-ZDR)",
      a19 is None and err19 is not None and "ZDR" in err19,
      f"err={err19}")

# 20. no ZDR models at all on a private repo -> hard error, not a empty panel
NOZDR = {k:v for k,v in FIX.items() if v.get("route") != 31501}  # no ds_or
a21, err21, _ = select_panel.pick(NOZDR, ["executor"], "executor", [], "high", private=True)
check("private with no ZDR models fails closed",
      a21 is None and err21 is not None and "no ZDR-capable" in err21,
      f"err={err21}")

# 21. hostile route value is rejected at load
FIX_BAD = dict(FIX, ds_bad=dict(FIX["ds_or"], route="31501@attacker.example"))
a20, err20, _ = select_panel.pick(FIX_BAD, ["executor"], "executor", [], "high")
check("hostile route rejected", a20 is not None and a20["executor"].get("route") != "31501@attacker.example",
      f"err={err20}")

# --- per-seat agent feasibility (2026-08-06, 4-of-6 dead panel) ---
# `harness` names a dispatch class, not an agent. Each agent is provider-locked:
# codex runs openai only, antigravity runs google only, opus/claude run
# anthropic only, and the cc-ds4 proxy transport only works through an opus
# seat. Without the agents map the selector hands claude-opus-5 / gemini / glm
# to a codex seat, which refuses them at spawn. `agents={seat: agent}` must
# constrain each seat to models its agent can actually run. The direct assertion
# is `_runnable(assigned_model, seat_agent)` — the contract the dispatch chain
# enforces.

# 22. a codex seat is never assigned a model codex cannot run (subagent models
#     are fine — the caller dispatches those as Agent teammates)
a22, err22, nl22 = select_panel.pick(FIX, ["executor", "auditor"], "auditor", [], "xhigh",
                                     agents={"executor": "codex", "auditor": "codex"})
check("codex seats only get runnable models",
      a22 is not None and all(select_panel._runnable(m, "codex") for m in a22.values()),
      f"providers={[m['provider'] for m in (a22 or {}).values()]} err={err22}")

# 23. an antigravity seat gets only models agy can run (google, or subagent)
a23, err23, _ = select_panel.pick(FIX, ["antigravity"], "antigravity", [], "xhigh",
                                  agents={"antigravity": "antigravity"})
check("antigravity seat only gets runnable models",
      a23 is not None and all(select_panel._runnable(m, "antigravity") for m in a23.values()),
      f"got={[(m.get('key'), m.get('provider')) for m in (a23 or {}).values()]}")

# 24. proxy-transport models land on the opus seat, never a codex seat — with
#     only a proxy model + a google model, the opus seat takes the proxy one and
#     the codex seat stays unfilled (both must hold).
a24, err24, _ = select_panel.pick({"ds_or": FIX["ds_or"], "gem1": FIX["gem1"]},
                                  ["a", "b"], "b", [], "xhigh",
                                  agents={"a": "codex", "b": "opus"})
check("proxy model only lands on an opus seat",
      a24 is not None and a24.get("b", {}).get("transport") == "proxy" and "a" not in a24,
      f"got={[(s, m.get('key'), m.get('transport')) for s, m in (a24 or {}).items()]}")

# 24b. a proxy-only registry cannot fill a codex seat (fails to a default, not a
#      wrong-provider model)
a24b, err24b, _ = select_panel.pick({"ds_or": FIX["ds_or"]}, ["c"], "c", [], "xhigh",
                                    agents={"c": "codex"})
check("proxy model never assigned to a codex seat",
      a24b is not None and "c" not in a24b, f"got={a24b}")

# 25. a codex seat with no runnable model goes unfilled (falls back to its
#     configured default downstream), and does NOT kill the panel
a25, err25, _ = select_panel.pick({"g": FIX["gem1"], "op": FIX["op1"]}, ["c"], "c", [], "xhigh",
                                  agents={"c": "codex"})
check("codex seat with only non-openai models goes unfilled",
      a25 is not None and "c" not in a25, f"got={a25}")

# 26. subagent-harness models are assignable to any seat — including one with no
#     configured agent (an empty agent runs nothing acpx-runnable)
a26, err26, _ = select_panel.pick({"ds": FIX["ds"]}, ["lens"], "lens", [], "xhigh",
                                  agents={"lens": ""})
check("subagent model fills an empty-agent seat",
      a26 is not None and a26["lens"]["harness"] == "subagent", f"got={a26}")

# 27. a flexible agent (not provider-locked — opencode/OpenRouter passthrough)
#     keeps today's permissive behavior
a27, err27, _ = select_panel.pick(FIX, ["deepseek", "auditor"], "auditor", [], "xhigh",
                                  agents={"deepseek": "deepseek", "auditor": "codex"})
check("flexible agent keeps permissive selection",
      a27 is not None and all(select_panel._runnable(m, agents) for s, agents in
                              ({"deepseek": "deepseek", "auditor": "codex"}).items()
                              if (m := a27.get(s))),
      f"got={[(s, m.get('key')) for s, m in (a27 or {}).items()]}")

# 28. ZDR hard constraint holds when agent feasibility leaves a seat unfilled:
#     on a private repo, a codex seat with no ZDR-capable (route 31501) model
#     its agent can run must FAIL the panel, not degrade to a non-ZDR default
#     (CR finding, PR #60). ds_or is route 31501 (ZDR); ds_n is route 31502.
a28, err28, _ = select_panel.pick(
    {"ds_or": FIX["ds_or"], "ds_n": FIX["ds_n"]},
    ["codexseat"], "codexseat", [], "xhigh", private=True,
    agents={"codexseat": "codex"})
check("private + codex-only-no-ZDR fails closed (not a non-ZDR default)",
      a28 is None and err28 is not None and "ZDR" in err28 and "codexseat" in err28,
      f"err={err28}")

# 28b. the same panel WITHOUT private (public repo) degrades the codex seat to
#      unfilled rather than failing the whole panel
a28b, err28b, _ = select_panel.pick(
    {"ds_or": FIX["ds_or"], "ds_n": FIX["ds_n"]},
    ["codexseat"], "codexseat", [], "xhigh", private=False,
    agents={"codexseat": "codex"})
check("public repo with no runnable model just leaves the seat unfilled",
      a28b is not None and "codexseat" not in a28b, f"got={a28b} err={err28b}")

# 28c. a private panel where every seat CAN be filled with a ZDR model still
#      works: an opus seat takes ds_or (route 31501, the one ZDR model).
a28c, err28c, _ = select_panel.pick(
    {"ds_or": FIX["ds_or"], "op1": FIX["op1"]},
    ["op"], "op", [], "xhigh", private=True,
    agents={"op": "opus"})
check("private panel with a ZDR model for the seat still fills",
      a28c is not None and a28c["op"]["key"] == "ds_or" and a28c["op"]["route"] == 31501,
      f"got={[(s, m.get('key'), m.get('route')) for s, m in (a28c or {}).items()]} err={err28c}")

print()
print("PASS" if fails == 0 else f"FAIL ({fails})")
sys.exit(0 if fails == 0 else 1)

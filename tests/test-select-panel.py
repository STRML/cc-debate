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

# 8. F5: --max-cost below every available model is a hard error, never a silent
#    unbudgeted panel. The error must name the cheapest available cost.
a8, err8, nl8 = select_panel.pick(FIX, SEATS, "pentester", [], "xhigh", max_cost=0.001)
check("budget below cheapest model is a hard error",
      a8 is None and err8 is not None and "cheapest" in err8, err8)

# 9. F10: --max-cost that cannot fill every requested seat is a hard error; a
#    3-seat request must not silently collapse to 1 seat.
a9, err9, nl9 = select_panel.pick(FIX, SEATS, "pentester", [], "xhigh", max_cost=0.10)
check("budget shortfall for requested seats is a hard error",
      a9 is None and err9 is not None and "cannot fill" in err9,
      f"keys={list(a9.keys()) if a9 else None} err={err9}")

# 10. F13: an available entry missing price/strengths/lab is skipped with a warning,
#     not a crash; the rest of the panel still builds.
MAL = {k: v for k, v in FIX.items()}
MAL["broken"] = {"name": "Broken", "harness": "acpx", "provider": "x", "model_id": "b",
                 "family": "b", "effort": "high", "effort_range": ["high"], "cost": "cheap",
                 "repo_aware": False, "available": True}
a10, err10, nl10 = select_panel.pick(MAL, SEATS, "pentester", [], "xhigh", max_cost=1.0)
picked = [m["key"] for m in a10.values()] if a10 else []
check("malformed available entry skipped, panel survives",
      a10 is not None and "broken" not in picked, f"picked={picked} err={err10}")

# 11. a budget that fits builds the full panel (control for 8-10)
a11, err11, nl11 = select_panel.pick(FIX, SEATS, "pentester", [], "xhigh", max_cost=1.0)
check("budget that fits builds full panel", a11 is not None and len(a11) == len(SEATS), str(a11))

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
check("legacy model cannot step below medium",
      select_panel._step_down(miss, "medium") == "medium")
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

# 16. monotonic degradation protects the deepest seat: under a budget, the
#     SHALLOWEST seats are downgraded first; the deepest seat keeps its effort
#     until every other seat is already at its floor.
#     cheap1/cheap2 declared medium (range low..high), lead declared xhigh.
#     At tier: simplifier(i0)=medium -> low, operator(i1)=high -> high,
#     pentester(i2)=xhigh -> xhigh. Initial total 0.30+0.60+1.86=2.76.
GREEN = {
  "cheap1": {"name":"C1","harness":"acpx","provider":"p","model_id":"c1","family":"f","lab":"l1","strengths":["speed"],"effort":"medium","effort_range":["low","high"],"price":{"in":1,"out":2,"cost_per_task":0.3},"cost":"cheap","repo_aware":False,"available":True},
  "cheap2": {"name":"C2","harness":"acpx","provider":"p","model_id":"c2","family":"f","lab":"l2","strengths":["speed"],"effort":"medium","effort_range":["low","high"],"price":{"in":1,"out":2,"cost_per_task":0.3},"cost":"cheap","repo_aware":False,"available":True},
  "lead":  {"name":"L","harness":"acpx","provider":"p","model_id":"l","family":"f","lab":"l3","strengths":["reasoning","tricky"],"effort":"xhigh","effort_range":["low","xhigh"],"price":{"in":5,"out":30,"cost_per_task":1.86},"cost":"premium","repo_aware":False,"available":True},
}
a16, err16, nl16 = select_panel.pick(GREEN, SEATS, "pentester", [], "xhigh", max_cost=2.5)
check("budget degradation succeeds", a16 is not None, f"err={err16}")
if a16:
    check("deepest seat protected: keeps its effort",
          a16["pentester"]["effective_effort"] == "xhigh",
          f"{a16['pentester']['key']}@{a16['pentester']['effective_effort']}")
    check("shallow seats degraded to their floor",
          a16["simplifier"]["effective_effort"] == "low"
          and a16["operator"]["effective_effort"] == "low",
          f"simplifier@{a16['simplifier']['effective_effort']}, operator@{a16['operator']['effective_effort']}")
    tot16 = sum(m["effective_cost"] for m in a16.values())
    check("degraded panel fits the cap",
          tot16 <= 2.5 + 1e-9, f"total={tot16:.3f}")

# 17. a legacy model (no effort_range) is treated as medium effort end-to-end:
#     it is clamped to medium on the deepest seat, cannot be stepped below
#     medium, and keeps its exact cost_per_task (medium mult = 1).
legacy_deep = {**miss, "key": "legacy", "strengths": ["reasoning", "tricky"]}
LEGACY2 = {
  "legacy": legacy_deep,                 # no effort_range, declared medium, cost 0.10
  "cheapA": {**GREEN["cheap1"], "key": "cheapA"},
  "cheapB": {**GREEN["cheap2"], "key": "cheapB"},
}
a17, err17, nl17 = select_panel.pick(LEGACY2, SEATS, "pentester", [], "xhigh", max_cost=None)
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

print()
print("PASS" if fails == 0 else f"FAIL ({fails})")
sys.exit(0 if fails == 0 else 1)

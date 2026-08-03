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

print()
print("PASS" if fails == 0 else f"FAIL ({fails})")
sys.exit(0 if fails == 0 else 1)

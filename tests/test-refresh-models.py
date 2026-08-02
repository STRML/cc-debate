#!/usr/bin/env python3
"""Unit tests for scripts/refresh-models.py (debate v3, #31)."""
import importlib.util, json, os, sys
_here = os.path.dirname(os.path.abspath(__file__))
_src = os.path.join(_here, "..", "scripts", "refresh-models.py")
_spec = importlib.util.spec_from_file_location("refresh_models", _src)
rm = importlib.util.module_from_spec(_spec); _spec.loader.exec_module(rm)

def clone(o): return json.loads(json.dumps(o))

REG = {
  "luna": {"name":"Luna","harness":"acpx","provider":"openai","model_id":"luna","family":"oai","lab":"openai",
           "strengths":["speed","cost"],"effort":"high","effort_range":["low","high"],
           "price":{"in":1,"out":6,"cost_per_task":0.07},"cost":"cheap","repo_aware":False,"available":True},
}
UPD = {"luna": {"source":"AA","strengths":["reasoning","code"],"effort":"max","effort_range":["medium","max"],
                "price":{"out":8}}}

fails=0
def check(n,c,d=""):
    global fails
    if c: print("  ok:",n)
    else: fails+=1; print("  FAIL:",n,d)

# 1. merge: updates metrics + source/as_of, preserves user-owned fields
o = rm.merge(clone(REG), clone(UPD))["luna"]
check("strengths updated", o["strengths"]==["reasoning","code"], o["strengths"])
check("effort updated to max", o["effort"]=="max")
check("effort_range updated", o["effort_range"]==["medium","max"])
check("price.out updated via merge", o["price"]["out"]==8)
check("price.in preserved (absent in update)", o["price"]["in"]==1)
check("harness preserved", o["harness"]=="acpx")
check("available preserved (user-owned)", o["available"] is True)
check("repo_aware preserved", o["repo_aware"] is False)
check("source recorded", o.get("source")=="AA")
check("as_of recorded", bool(o.get("as_of")))

# 2. parse_payload: valid JSON -> dict; garbage -> None
check("parse valid json", isinstance(rm.parse_payload('{"a":1}'), dict))
check("parse garbage -> None", rm.parse_payload("not json") is None)
check("parse empty -> None", rm.parse_payload("") is None)

# 3. no updates from a failed source does NOT clobber user data
o2 = rm.merge(clone(REG), {})["luna"]
check("no-update merge leaves data intact", o2["strengths"]==["speed","cost"] and o2["effort"]=="high")

print()
print("PASS" if fails==0 else f"FAIL ({fails})")
sys.exit(0 if fails==0 else 1)

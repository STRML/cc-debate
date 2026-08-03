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

# 1. merge: updates metrics + source/as_of, preserves user-owned fields.
# strengths is a UNION: curated tags survive, the update's are added.
o = rm.merge(clone(REG), clone(UPD))["luna"]
check("strengths unioned (curated + update)", o["strengths"]==["code","cost","reasoning","speed"], o["strengths"])
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

# --- best_effort_metrics: Artificial Analysis payload -> registry-keyed updates ---
# Shape mirrors the live source (automationscookbook mirror of artificialanalysis.ai):
# one entry per effort level, base (max) first, sorted by Intelligence Index desc.
AA_PAYLOAD = {"ok": True, "meta": {"source": "artificialanalysis.ai"}, "models": [
  {"slug": "gpt-5-6-luna", "name": "GPT-5.6 Luna (max)", "intelligenceIndex": 51.2,
   "intelligenceIndexCostTotal": 190.87, "priceInputPer1m": 1.0, "priceOutputPer1m": 6.0},
  {"slug": "gpt-5-6-luna-xhigh", "name": "GPT-5.6 Luna (xhigh)", "intelligenceIndex": 49.1,
   "intelligenceIndexCostTotal": 106.08, "priceInputPer1m": 1.0, "priceOutputPer1m": 6.0},
  {"slug": "gemini-3-1-pro-preview", "name": "Gemini 3.1 Pro Preview", "intelligenceIndex": 46.5,
   "intelligenceIndexCostTotal": 815.11, "priceInputPer1m": 1.25, "priceOutputPer1m": 10.0},
  {"slug": "kimi-k3", "name": "Kimi K3", "intelligenceIndex": 57.1,
   "intelligenceIndexCostTotal": 500.0, "priceInputPer1m": 2.0, "priceOutputPer1m": 10.0},
]}
REG_AA = {
  "gpt56_luna": {"name":"GPT-5.6 Luna","harness":"acpx","provider":"openai","model_id":"gpt-5.6-luna",
                 "family":"oai","lab":"openai","strengths":["speed","cost"],"effort":"high",
                 "effort_range":["low","high"],"price":{"in":1.0,"out":6.0,"cost_per_task":0.07},
                 "cost":"cheap","repo_aware":False,"available":True},
  "gemini_31_pro": {"name":"Gemini 3.1 Pro","harness":"acpx","provider":"google","model_id":"gemini-3.1-pro",
                    "family":"google","lab":"google","strengths":["reasoning"],"effort":"high",
                    "effort_range":["low","high"],"price":{"in":1.25,"out":10.0,"cost_per_task":0.5},
                    "cost":"mid","repo_aware":False,"available":True},
}

UPD = rm.best_effort_metrics(AA_PAYLOAD, REG_AA)
check("AA: gpt56_luna matched", "gpt56_luna" in UPD, UPD.keys())
check("AA: strengths derived (reasoning/code/cost)", UPD.get("gpt56_luna", {}).get("strengths")==["reasoning","code","cost"], UPD.get("gpt56_luna"))
check("AA: effort NOT derived (run-config knob preserved)", "effort" not in UPD.get("gpt56_luna", {}), UPD.get("gpt56_luna"))
check("AA: cost bucket derived from price", UPD.get("gpt56_luna", {}).get("cost")=="mid", UPD.get("gpt56_luna"))
check("AA: price mapped from per-M", UPD.get("gpt56_luna", {}).get("price")=={"in":1.0,"out":6.0}, UPD.get("gpt56_luna"))
check("AA: base (max) row wins over -xhigh", UPD.get("gpt56_luna", {}).get("strengths")==["reasoning","code","cost"])
check("AA: gemini matches via variant suffix (preview)", "gemini_31_pro" in UPD, UPD.keys())
check("AA: unknown model ignored", "kimi_k3" not in UPD)
check("AA: cost_per_task untouched (no per-task source)", "cost_per_task" not in UPD.get("gpt56_luna", {}).get("price", {}))
check("AA: empty payload -> {}", rm.best_effort_metrics({}, REG_AA)=={})
check("AA: None payload -> {}", rm.best_effort_metrics(None, REG_AA)=={})

# string-typed numeric fields must not crash the whole source or leak into the registry
AA_STR = {"ok": True, "models": [
  {"slug": "gpt-5-6-luna", "intelligenceIndex": "51.2", "priceInputPer1m": "1.0", "priceOutputPer1m": "6.0"}]}
UPD_STR = rm.best_effort_metrics(AA_STR, REG_AA)
check("AA: string numerics coerced", UPD_STR.get("gpt56_luna", {}).get("price")=={"in":1.0,"out":6.0}, UPD_STR.get("gpt56_luna"))

# unrelated slug must not hijack a registry entry (was: model_id 'opus' matched opus-4-6)
UPD_NO = rm.best_effort_metrics({"ok": True, "models": [{"slug": "opus-4-6", "intelligenceIndex": 55.0,
  "priceInputPer1m": 3.0, "priceOutputPer1m": 15.0}]}, REG_AA)
check("AA: unrelated slug not hijacked (opus-4-6)", UPD_NO=={}, UPD_NO)

# merge the AA update into the registry: user-owned fields survive, strengths union
o3 = rm.merge(clone(REG_AA), clone(UPD))["gpt56_luna"]
check("AA merge: harness preserved", o3["harness"]=="acpx")
check("AA merge: available preserved", o3["available"] is True)
check("AA merge: price.in updated", o3["price"]["in"]==1.0)
check("AA merge: cost_per_task preserved", o3["price"]["cost_per_task"]==0.07)
check("AA merge: effort preserved (not derived)", o3["effort"]=="high")
check("AA merge: strengths unioned", o3["strengths"]==["code","cost","reasoning","speed"], o3["strengths"])
check("AA merge: source recorded", o3.get("source")=="AA")
check("AA merge: as_of recorded", bool(o3.get("as_of")))

# --- per-effort strengths: the row at the entry's configured effort is used ---
PER_EFFORT_REG = {"foo": {"name":"Foo","harness":"acpx","provider":"x","model_id":"foo",
  "effort":"low","effort_range":["low"],"strengths":["general"],
  "price":{"in":1.0,"out":2.0,"cost_per_task":0.01},"family":"x","lab":"x",
  "cost":"cheap","repo_aware":False,"available":True}}
PER_EFFORT_AA = {"ok": True, "models": [
  {"slug": "foo", "intelligenceIndex": 60, "priceInputPer1m": 1.0, "priceOutputPer1m": 2.0},
  {"slug": "foo-low", "intelligenceIndex": 35, "priceInputPer1m": 1.0, "priceOutputPer1m": 2.0},
]}
UPD_PE = rm.best_effort_metrics(PER_EFFORT_AA, PER_EFFORT_REG)
check("per-effort: low-effort row used (idx 35, no reasoning)", UPD_PE.get("foo", {}).get("strengths")==["cost"], UPD_PE.get("foo"))

# --- cost-per-task via the AA free API shape ---
AA_FREE = {"status": "ok", "data": [{"slug": "gpt-5-6-luna", "name": "GPT-5.6 Luna",
  "evaluations": {"artificial_analysis_intelligence_index": 51.2},
  "artificial_analysis_intelligence_index_cost": {"cost_per_task": {"total_cost": 0.18}},
  "pricing": {"price_1m_input_tokens": 0.2, "price_1m_output_tokens": 1.2}}]}
NORM = rm.normalize_aa_free(AA_FREE)
check("aa-free: normalized to mirror shape", NORM["models"][0]["costPerTask"]==0.18, NORM["models"][0])
UPD_CPT = rm.best_effort_metrics(NORM, REG_AA)
check("aa-free: cost_per_task mapped from cost_per_task.total_cost", UPD_CPT.get("gpt56_luna", {}).get("price", {}).get("cost_per_task")==0.18, UPD_CPT.get("gpt56_luna"))

# --- LMArena elo (secondary confidence) ---
LMARENA_ROWS = [
  {"model_name": "gpt-5-6-luna", "category": "overall", "rating": 1380.2, "organization": "openai"},
  {"model_name": "gemini-3.1-pro-preview", "category": "overall", "rating": 1479.5, "organization": "google"},
  {"model_name": "gemini-pro", "category": "overall", "rating": 1130.7, "organization": "google"},
  {"model_name": "random-model", "category": "overall", "rating": 1300.0, "organization": "x"},
]
_old_fetch = rm.fetch_lmarena
rm.fetch_lmarena = lambda: LMARENA_ROWS
try:
    UPD_ELO = rm.lmarena_metrics(REG_AA)
finally:
    rm.fetch_lmarena = _old_fetch
check("lmarena: elo mapped", UPD_ELO.get("gpt56_luna", {}).get("elo")==1380.2, UPD_ELO)
check("lmarena: gemini matches preview, not the key-colliding 'gemini-pro'",
      UPD_ELO.get("gemini_31_pro", {}).get("elo")==1479.5, UPD_ELO)
check("lmarena: unknown model ignored", "random_model" not in UPD_ELO, UPD_ELO)
o4 = rm.merge(clone(REG_AA), clone(UPD_ELO))["gpt56_luna"]
check("merge: elo stored", o4.get("elo")==1380.2, o4)
check("merge: elo merge keeps AA fields when combined", o4["strengths"]==["speed","cost"], o4["strengths"])

print()
print("PASS" if fails==0 else f"FAIL ({fails})")
sys.exit(0 if fails==0 else 1)

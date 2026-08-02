#!/usr/bin/env python3
"""Refresh the debate model registry metrics from benchmark aggregators (#31).

Sources (best-effort; offline safe):
  - Artificial Analysis (primary): Intelligence Index, cost-per-task, effort.
  - LMArena / Chatbot Arena (complement): human-preference Elo.

It does NOT overwrite the fields the user owns: harness, provider, repo_aware,
available. It updates strengths/effort/effort_range/price and records a `source`
+ `as_of` so a stale cache is visible. If every source fails the last good copy
is kept untouched and we exit 1 with a message (offline fallback).

Usage:
  refresh-models.py --registry <debate-models.json> [--out <path>] [--update-source AA|LMArena|all] [--ttl-hours N]
"""
import argparse, json, os, sys, time, urllib.request

# Source: the elastic/plain JSON endpoints are unstable; keep them as pluggable fetchers
# so a path change is a one-line edit, not a re-read of the whole script.
FETCHERS = {
    "AA": ("https://huggingface.co/api/spaces/ArtificialAnalysis/LLM-Performance-Leaderboard", "huggingface"),
    "LMArena": ("https://huggingface.co/api/spaces/lmarena-ai/arena-leaderboard", "huggingface"),
}

# Parser gate. FETCHERS point at live endpoints, but best_effort_metrics() below is a
# stub that returns {} — nothing is parsed yet — so an unconditional fetch would be a
# network round-trip that changes nothing, on every TTL expiry, forever. Wire a real
# parser and flip this to True; the fetch + merge machinery below is what it plugs into.
PARSERS_READY = False

def fetch(url, timeout=15):
    req = urllib.request.Request(url, headers={"User-Agent": "cc-debate-refresh/1.0"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.read().decode("utf-8", "replace")

def parse_payload(text):
    """Try JSON, else bail — these endpoints are spaces, not guaranteed stable JSON."""
    try:
        return json.loads(text)
    except Exception:
        return None

def best_effort_metrics(payload):
    """Best-effort: we cannot rely on the unstable schema, so we return {} and let the
    registry's own data stand. The merge machinery is the durable part; plug a stable
    endpoint here when one exists."""
    return {}

def merge(registry, updates):
    out = dict(registry)
    now = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    for key, m in out.items():
        u = updates.get(key)
        if not u:
            continue
        if u.get("strengths"): m["strengths"] = u["strengths"]
        if u.get("effort"): m["effort"] = u["effort"]
        if u.get("effort_range"): m["effort_range"] = u["effort_range"]
        m.setdefault("price", {})
        for f in ("in", "out", "cost_per_task"):
            if u.get("price", {}).get(f) is not None:
                m["price"][f] = u["price"][f]
        m["source"] = u.get("source", "manual")
        m["as_of"] = now
    return out

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--registry", required=True)
    ap.add_argument("--out", default=None)
    ap.add_argument("--update-source", default="all", choices=["AA", "LMArena", "all"])
    ap.add_argument("--ttl-hours", type=float, default=24*7)
    a = ap.parse_args()

    reg = json.load(open(a.registry))
    # TTL guard: a very fresh manual registry is not worth a network round-trip.
    if all(m.get("as_of") for m in reg.values()):
        oldest = min(time.time() - time.mktime(time.strptime(m["as_of"], "%Y-%m-%dT%H:%M:%SZ"))
                     for m in reg.values() if m.get("as_of"))
        if oldest < a.ttl_hours * 3600:
            print(f"cache fresh ({int(oldest//3600)}h old); skipping refresh (--ttl-hours {a.ttl_hours})")
            out = a.out or a.registry
            json.dump(reg, open(out, "w"), indent=2); open(out, "a").write("\n")
            sys.exit(0)

    if not PARSERS_READY:
        # No parser is wired (best_effort_metrics returns {}), so a fetch could only
        # be discarded. Report that and leave the registry byte-identical instead of
        # burning network + rate-limit budget on a no-op.
        print("no datasource parser wired yet; skipping fetch (registry unchanged)")
        out = a.out or a.registry
        json.dump(reg, open(out, "w"), indent=2); open(out, "a").write("\n")
        sys.exit(0)

    updates = {}
    failures = []
    sources = ["AA", "LMArena"] if a.update_source == "all" else [a.update_source]
    for src in sources:
        try:
            url, kind = FETCHERS[src]
            text = fetch(url)
            payload = parse_payload(text)
            u = best_effort_metrics(payload)
            if u:
                updates = {**updates, **u}
                print(f"{src}: merged {len(u)} model updates")
            else:
                print(f"{src}: datasource schema not wired yet (best_effort_metrics stub) — registry unchanged")
        except Exception as e:
            failures.append(f"{src}: {e}")

    if not updates and failures:
        # all sources failed -> keep last good copy untouched (offline fallback)
        print("ALL SOURCES FAILED; keeping last good copy unchanged", file=sys.stderr)
        for f in failures: print(f"  {f}", file=sys.stderr)
        sys.exit(1)

    out = merge(reg, updates)
    dst = a.out or a.registry
    json.dump(out, open(dst, "w"), indent=2); open(dst, "a").write("\n")
    if updates:
        print(f"registry refreshed ({len(out)} entries) -> {dst}")
    else:
        print(f"registry unchanged ({len(out)} entries) -> {dst} (no datasource merged yet)")

if __name__ == "__main__":
    main()

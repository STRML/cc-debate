#!/usr/bin/env python3
"""Refresh the debate model registry metrics from benchmark aggregators (#31).

Sources (best-effort; offline safe):
  - Artificial Analysis (primary): Intelligence Index -> strengths/effort, prices.
  - LMArena / Chatbot Arena (complement): human-preference Elo — extractor not written yet.

It does NOT overwrite the fields the user owns: harness, provider, repo_aware,
available. It updates strengths/effort/effort_range/price.in/price.out (cost_per_task is
left to the hand-set per-review estimate — the AA source exposes whole-index cost, not a
per-task cost) and records a `source` + `as_of` so a stale cache is visible. If every
source fails the last good copy is kept untouched and we exit 1 (offline fallback).

Usage:
  refresh-models.py --registry <debate-models.json> [--out <path>] [--update-source AA|LMArena|all] [--ttl-hours N]
"""
import argparse, calendar, json, os, sys, time, urllib.request

# AA's own leaderboard JSON endpoint is not stable enough to pin, so the AA fetcher
# points at a free mirror that serves the Artificial Analysis Intelligence Index with
# attribution (https://automationscookbook.com/api/llm-leaderboard, meta.source
# artificialanalysis.ai). Swap this URL for AA's own endpoint when one is confirmed;
# the parser keys on the shape below, not the URL.
FETCHERS = {
    "AA": ("https://automationscookbook.com/api/llm-leaderboard", "json"),
    "LMArena": ("https://huggingface.co/api/spaces/lmarena-ai/arena-leaderboard", "huggingface"),
}

# The AA parser is wired (best_effort_metrics below maps real payloads); LMArena still
# returns nothing and contributes no updates until its extractor lands.
PARSERS_READY = True

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

def _norm(s):
    """Lowercase + drop non-alphanumerics, so `gpt-5.6-luna` == `gpt-5-6-luna`."""
    return "".join(ch for ch in (s or "").lower() if ch.isalnum())

def _effort_from_index(idx):
    if idx is None:
        return None
    if idx >= 58: return "max"
    if idx >= 52: return "xhigh"
    if idx >= 45: return "high"
    if idx >= 38: return "medium"
    return "low"

def _strengths_from(index, price_in):
    s = []
    if index is not None and index >= 45:
        s.append("reasoning")
    if index is not None and index >= 40:
        s.append("code")
    if price_in is not None and price_in < 2:
        s.append("cost")
    if not s:
        s.append("general")
    return s

def best_effort_metrics(payload, registry):
    """Map the Artificial Analysis payload into {registry_key: {strengths, effort, price}}.

    Matches AA models to registry entries by normalized `model_id`/`name` (dot/dash and
    case insensitive), falling back to a prefix match for entries like `gemini-3.1-pro`
    -> AA's `gemini-3-1-pro-preview`. AA lists one entry per effort level
    (`gpt-5-6-luna`, `-xhigh`, `-high`…); the base (max-effort) entry wins, and it sorts
    first because the payload is ordered by Intelligence Index.

    `cost_per_task` is deliberately left alone: the source exposes the whole-index cost
    (`intelligenceIndexCostTotal`), not a per-task cost, and the registry's value is a
    hand-set per-review estimate in a different unit.

    Returns {} when nothing matched (including LMArena's metadata payload, which has no
    `models` array).
    """
    models = (payload or {}).get("models") or []
    if not models or not registry:
        return {}
    # normalized registry lookup: model_id, name and key all point at the entry
    reg_norm = {}
    for key, m in registry.items():
        for candidate in (m.get("model_id"), m.get("name"), key):
            if candidate:
                reg_norm.setdefault(_norm(candidate), key)
    prefixes = sorted(reg_norm, key=len, reverse=True)   # longest first
    updates = {}
    for m in models:
        norm = _norm(m.get("slug")) or _norm(m.get("name"))
        if not norm:
            continue
        key = reg_norm.get(norm)
        if not key:
            for p in prefixes:               # gemini-3.1-pro -> gemini-3-1-pro-preview
                if norm.startswith(p):
                    key = reg_norm[p]
                    break
        if not key or key in updates:
            continue                          # first (max-effort) variant wins
        updates[key] = _aa_to_update(m)
    return updates

def _aa_to_update(m):
    u = {"source": "AA"}
    idx = m.get("intelligenceIndex")
    price_in = m.get("priceInputPer1m")
    price_out = m.get("priceOutputPer1m")
    eff = _effort_from_index(idx)
    if eff:
        u["effort"] = eff
    strengths = _strengths_from(idx, price_in)
    if strengths:
        u["strengths"] = strengths
    price = {}
    if price_in is not None:
        price["in"] = price_in
    if price_out is not None:
        price["out"] = price_out
    if price:
        u["price"] = price
    return u

def write_registry(path, reg):
    """Atomic replace. Write to a temp then rename, so an interrupted refresh never
    truncates the user's curated registry in place."""
    tmp = "%s.tmp" % path
    with open(tmp, "w") as f:
        json.dump(reg, f, indent=2)
        f.write("\n")
    os.replace(tmp, path)

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
    # Parse each as_of defensively — a single hand-edited or odd value used to abort
    # the whole refresh with a traceback instead of being ignored.
    # calendar.timegm, not time.mktime: as_of is a UTC "Z" timestamp written by merge(),
    # and mktime would interpret the naive struct as LOCAL time, skewing the cache age
    # by the host's timezone offset (wrong refresh cadence on non-UTC hosts).
    if all(m.get("as_of") for m in reg.values()):
        ages = []
        for m in reg.values():
            if not m.get("as_of"):
                continue
            try:
                ages.append(time.time() - calendar.timegm(time.strptime(m["as_of"], "%Y-%m-%dT%H:%M:%SZ")))
            except (ValueError, TypeError, OverflowError):
                continue   # malformed as_of — ignore this entry, don't crash
        if ages and min(ages) < a.ttl_hours * 3600:
            print(f"cache fresh ({int(min(ages)//3600)}h old); skipping refresh (--ttl-hours {a.ttl_hours})")
            write_registry(a.out or a.registry, reg)
            sys.exit(0)

    if not PARSERS_READY:
        # No parser is wired (best_effort_metrics returns {}), so a fetch could only
        # be discarded. Report that and leave the registry byte-identical instead of
        # burning network + rate-limit budget on a no-op.
        print("no datasource parser wired yet; skipping fetch (registry unchanged)")
        write_registry(a.out or a.registry, reg)
        sys.exit(0)

    updates = {}
    failures = []
    sources = ["AA", "LMArena"] if a.update_source == "all" else [a.update_source]
    for src in sources:
        try:
            url, kind = FETCHERS[src]
            text = fetch(url)
            payload = parse_payload(text)
            u = best_effort_metrics(payload, reg)
            if u:
                updates = {**updates, **u}
                print(f"{src}: merged {len(u)} model updates")
            else:
                print(f"{src}: no matching models parsed — registry unchanged")
        except Exception as e:
            failures.append(f"{src}: {e}")

    if not updates and failures:
        # all sources failed -> keep last good copy untouched (offline fallback)
        print("ALL SOURCES FAILED; keeping last good copy unchanged", file=sys.stderr)
        for f in failures: print(f"  {f}", file=sys.stderr)
        sys.exit(1)

    out = merge(reg, updates)
    dst = a.out or a.registry
    write_registry(dst, out)
    if updates:
        print(f"registry refreshed ({len(out)} entries) -> {dst}")
    else:
        print(f"registry unchanged ({len(out)} entries) -> {dst} (no datasource merged yet)")

if __name__ == "__main__":
    main()

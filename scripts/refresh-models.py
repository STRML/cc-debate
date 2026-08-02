#!/usr/bin/env python3
"""Refresh the debate model registry metrics from benchmark aggregators (#31).

Sources (best-effort; offline safe):
  - Artificial Analysis (primary): Intelligence Index -> strengths tags, prices.
  - LMArena / Chatbot Arena (complement): human-preference Elo — extractor not written yet.

It does NOT overwrite the fields the user owns: harness, provider, repo_aware,
available, effort, effort_range and cost_per_task. effort/effort_range are run-config
knobs (deriving effort from the index broke the schema gate and the selector's effort
floor), and the AA source exposes whole-index cost, not a per-task cost — so
cost_per_task stays the hand-set per-review estimate. It ADDS capability tags to
strengths (reasoning/code/cost/speed), updates price.in/price.out, re-derives the cost
bucket, and records a `source` + `as_of` so a stale cache is visible. If every source
fails the last good copy is kept untouched and we exit 1 (offline fallback).

Usage:
  refresh-models.py --registry <debate-models.json> [--out <path>] [--update-source AA|LMArena|all] [--ttl-hours N]
"""
import argparse, calendar, copy, json, os, sys, time, urllib.request

# AA's own leaderboard JSON endpoint is not stable enough to pin, so the AA fetcher
# points at a free mirror that serves the Artificial Analysis Intelligence Index with
# attribution (https://automationscookbook.com/api/llm-leaderboard, meta.source
# artificialanalysis.ai). Swap this URL for AA's own endpoint when one is confirmed;
# the parser keys on the shape below, not the URL. LMArena's endpoint is not wired yet.
FETCHERS = {
    "AA": "https://automationscookbook.com/api/llm-leaderboard",
    "LMArena": "https://huggingface.co/api/spaces/lmarena-ai/arena-leaderboard",
}

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

def _num(x):
    """Coerce to float, or None. AA numeric fields can arrive as strings."""
    try:
        return float(x)
    except (TypeError, ValueError):
        return None

# AA lists one row per effort level / variant, suffixed to the base slug
# (gpt-5-6-luna-xhigh, gemini-3-1-pro-preview, glm-5-2-non-reasoning). Matching strips a
# known variant suffix and exact-matches the base against the registry — never an
# arbitrary prefix, which let unrelated slugs land on short/sentinel model_ids like
# "opus" and "(inherits)".
VARIANT_SUFFIXES = ("preview", "nonreasoning", "reasoning", "thinking",
                    "xhigh", "high", "medium", "low", "max")

def _match_key(norm, reg_norm):
    if norm in reg_norm:
        return reg_norm[norm]
    for suf in VARIANT_SUFFIXES:
        if norm.endswith(suf):
            base = norm[:-len(suf)]
            if base in reg_norm:
                return reg_norm[base]
    return None

def _strengths_from(index, price_in, latency):
    """Capability tags from the AA row. Never fabricates a fallback tag — an empty
    result means 'no tags', so merge's union leaves the curated strengths alone."""
    s = []
    if index is not None and index >= 45:
        s.append("reasoning")
    if index is not None and index >= 40:
        s.append("code")
    if price_in is not None and price_in < 2:
        s.append("cost")
    if latency is not None and latency < 5:
        s.append("speed")
    return s or None

def _cost_bucket(price_in):
    if price_in is None:
        return None
    if price_in < 1: return "cheap"
    if price_in < 5: return "mid"
    return "premium"

def best_effort_metrics(payload, registry):
    """Map the Artificial Analysis payload into {registry_key: {strengths, price, cost}}.

    Matches AA models to registry entries by normalized `model_id`/`name` (dot/dash and
    case insensitive), stripping known variant suffixes so `gemini-3-1-pro-preview` maps
    to the `gemini-3.1-pro` entry. Rows are sorted by Intelligence Index descending so
    the base (max-effort) row wins regardless of the source's own ordering.

    `effort`/`effort_range` and `cost_per_task` are deliberately NOT set: effort is a
    run-config knob, and the source exposes whole-index cost, not a per-task cost. merge
    unions strengths so curated tags (tricky/math/speed/general) survive.

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
                n = _norm(candidate)
                if n in reg_norm and reg_norm[n] != key:
                    print("refresh: %s and %s both normalize to '%s'; the second won't match"
                          % (reg_norm[n], key, n), file=sys.stderr)
                reg_norm.setdefault(n, key)
    models = sorted(models, key=lambda m: _num(m.get("intelligenceIndex")) or 0, reverse=True)
    updates = {}
    for m in models:
        norm = _norm(m.get("slug")) or _norm(m.get("name"))
        if not norm:
            continue
        key = _match_key(norm, reg_norm)
        if not key or key in updates:
            continue                          # base (max-effort) row wins
        updates[key] = _aa_to_update(m)
    return updates

def _aa_to_update(m):
    u = {"source": "AA"}
    idx = _num(m.get("intelligenceIndex"))
    price_in = _num(m.get("priceInputPer1m"))
    price_out = _num(m.get("priceOutputPer1m"))
    latency = _num(m.get("latencySeconds"))
    strengths = _strengths_from(idx, price_in, latency)
    if strengths:
        u["strengths"] = strengths
    bucket = _cost_bucket(price_in)
    if bucket:
        u["cost"] = bucket
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
    out = copy.deepcopy(registry)   # never mutate the caller's nested dicts (F9)
    now = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    for key, m in out.items():
        u = updates.get(key)
        if not u:
            continue
        if u.get("strengths"):
            # Union, not replace: curated tags (tricky/math/speed/general) survive the
            # refresh and the AA-derived ones are added.
            m["strengths"] = sorted(set((m.get("strengths") or []) + u["strengths"]))
        if u.get("effort"):
            m["effort"] = u["effort"]
        if u.get("effort_range"):
            m["effort_range"] = u["effort_range"]
        if u.get("cost"):
            m["cost"] = u["cost"]
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

    updates = {}
    failures = []
    sources = ["AA", "LMArena"] if a.update_source == "all" else [a.update_source]
    for src in sources:
        try:
            url = FETCHERS[src]
            text = fetch(url)
            payload = parse_payload(text)
            # The parser is AA-specific (reads slug/intelligenceIndex/price…); don't
            # run it on the LMArena payload, which would mis-stamp it and override AA.
            u = best_effort_metrics(payload, reg) if src == "AA" else {}
            if u:
                updates = {**updates, **u}
                print(f"{src}: merged {len(u)} model updates")
            else:
                print(f"{src}: no matching models parsed — registry unchanged")
        except Exception as e:
            failures.append(f"{src}: {e}")
            print(f"{src}: {e}", file=sys.stderr)   # surface even if another source worked

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

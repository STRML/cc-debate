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
# artificialanalysis.ai). When ARTIFICIAL_ANALYSIS_API_KEY is set, the official free
# endpoint is used instead — it is the only source of a real per-task cost
# (cost_per_task.total_cost), which the mirror does not expose. The parser keys on the
# shape below, not the URL.
FETCHERS = {
    "AA": "https://automationscookbook.com/api/llm-leaderboard",
    "LMArena": ("https://datasets-server.huggingface.co/rows"
                "?dataset=lmarena-ai%%2Fleaderboard-dataset&config=text&split=latest"
                "&offset=%d&length=100"),
}
AA_FREE_URL = "https://artificialanalysis.ai/api/v2/language/models/free"
# The overall leaderboard is ~383 rows, contiguous at the top of the text/latest split.
LMARENA_MAX_ROWS = 500

def fetch(url, timeout=15, headers=None):
    h = {"User-Agent": "cc-debate-refresh/1.0"}
    if headers:
        h.update(headers)
    req = urllib.request.Request(url, headers=h)
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

def _split_variant(norm):
    """Split an AA/LMArena slug into (base, variant): 'gpt56lunahigh' -> ('gpt56luna','high').
    The base (max-effort) row has no suffix; a bare slug is base-only."""
    for suf in VARIANT_SUFFIXES:
        if norm.endswith(suf) and len(norm) > len(suf):
            return norm[:-len(suf)], suf
    return norm, ""

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

def _registry_norm(registry):
    """normalized model_id/name -> registry key, warning on collisions.

    The raw key is deliberately NOT a candidate: keys like `gemini_pro` normalize to
    `geminipro`, which collides with the unrelated LMArena row `gemini-pro`. model_id
    and name are specific enough; the key is not.
    """
    reg_norm = {}
    for key, m in registry.items():
        for candidate in (m.get("model_id"), m.get("name")):
            if candidate:
                n = _norm(candidate)
                if n in reg_norm and reg_norm[n] != key:
                    print("refresh: %s and %s both normalize to '%s'; the second won't match"
                          % (reg_norm[n], key, n), file=sys.stderr)
                reg_norm.setdefault(n, key)
    return reg_norm

def best_effort_metrics(payload, registry):
    """Map the Artificial Analysis payload into {registry_key: {strengths, price, cost}}.

    Matches AA models to registry entries by normalized `model_id`/`name`, splitting
    effort-variant suffixes so `gemini-3-1-pro-preview` maps to `gemini-3.1-pro` and
    `gpt-5-6-luna-xhigh` to `gpt-5.6-luna`. The row AT the entry's configured `effort`
    is preferred (per-effort strengths), else the base (max-effort) row.

    `effort`/`effort_range` are deliberately NOT set (run-config knobs), and
    `cost_per_task` is only set when the row carries a real per-task cost (the AA free
    API, via normalize_aa_free); the mirror exposes only whole-index cost. merge unions
    strengths so curated tags survive.

    Returns {} when nothing matched.
    """
    models = (payload or {}).get("models") or []
    if not models or not registry:
        return {}
    reg_norm = _registry_norm(registry)
    by_base = {}
    for m in models:
        norm = _norm(m.get("slug")) or _norm(m.get("name"))
        if not norm:
            continue
        base, variant = _split_variant(norm)
        if base in reg_norm:
            by_base.setdefault(reg_norm[base], {}).setdefault(variant, m)
    updates = {}
    for key, m in registry.items():
        variants = by_base.get(key)
        if not variants:
            continue
        row = (variants.get(_norm(m.get("effort")))
               or variants.get("")
               or variants.get("max")
               or next(iter(variants.values())))   # e.g. gemini-3-1-pro's 'preview'
        if row:
            updates[key] = _aa_to_update(row)
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
    cpt = _num(m.get("costPerTask"))
    if cpt is not None:
        price["cost_per_task"] = cpt
    if price:
        u["price"] = price
    return u

def normalize_aa_free(payload):
    """Convert the AA free-API shape to the mirror shape best_effort_metrics parses.

    The free API carries the real per-task cost (artificial_analysis_intelligence_index_cost
    -> cost_per_task.total_cost), which the mirror lacks, so cost_per_task becomes
    available here. Other fields map onto the same keys.
    """
    out = {"models": []}
    for m in (payload or {}).get("data") or []:
        evals = m.get("evaluations") or {}
        cost = m.get("artificial_analysis_intelligence_index_cost") or {}
        pricing = m.get("pricing") or {}
        out["models"].append({
            "slug": m.get("slug") or m.get("name"),
            "name": m.get("name"),
            "intelligenceIndex": (evals.get("artificial_analysis_intelligence_index")
                                  or evals.get("intelligence_index")),
            "priceInputPer1m": pricing.get("price_1m_input_tokens"),
            "priceOutputPer1m": pricing.get("price_1m_output_tokens"),
            "costPerTask": (cost.get("cost_per_task") or {}).get("total_cost"),
        })
    return out

def fetch_lmarena(timeout=20):
    """Page the LMArena text leaderboard, returning only the 'overall' category rows."""
    rows = []
    offset = 0
    while offset < LMARENA_MAX_ROWS:
        text = fetch(FETCHERS["LMArena"] % offset, timeout)
        payload = parse_payload(text)
        batch = (payload or {}).get("rows") or []
        if not batch:
            break
        rows += [r["row"] for r in batch if r.get("row", {}).get("category") == "overall"]
        offset += len(batch)
    return rows

def lmarena_metrics(registry):
    """Map LMArena overall Elo rows into {registry_key: {elo}} updates (secondary confidence)."""
    rows = fetch_lmarena()
    if not rows or not registry:
        return {}
    reg_norm = _registry_norm(registry)
    by_base = {}
    for r in rows:
        norm = _norm(r.get("model_name")) or _norm(r.get("organization") or "")
        base, variant = _split_variant(norm)
        if base in reg_norm:
            by_base.setdefault(reg_norm[base], {}).setdefault(variant, r)
    updates = {}
    for key, m in registry.items():
        variants = by_base.get(key)
        if not variants:
            continue
        row = (variants.get(_norm(m.get("effort")))
               or variants.get("")
               or variants.get("max")
               or next(iter(variants.values())))
        if row and _num(row.get("rating")) is not None:
            updates[key] = {"elo": _num(row["rating"]), "source": "LMArena"}
    return updates

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
        if u.get("elo") is not None:
            m["elo"] = u["elo"]
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
    # the whole refresh with a traceback instead of being ignored. Entries without an
    # as_of (a newly hand-added model) don't count toward freshness; they must not
    # defeat the check for the whole registry.
    # calendar.timegm, not time.mktime: as_of is a UTC "Z" timestamp written by merge(),
    # and mktime would interpret the naive struct as LOCAL time, skewing the cache age
    # by the host's timezone offset (wrong refresh cadence on non-UTC hosts).
    ages = []
    for m in reg.values():
        if not m.get("as_of"):
            continue
        try:
            ages.append(time.time() - calendar.timegm(time.strptime(m["as_of"], "%Y-%m-%dT%H:%M:%SZ")))
        except (ValueError, TypeError, OverflowError):
            continue   # malformed as_of — ignore this entry, don't crash
    if ages and min(ages) < a.ttl_hours * 3600:
        # A fresh cache needs no write — rewriting the file would reformat the seed and
        # bury a hand edit in whole-file churn.
        print(f"cache fresh ({int(min(ages)//3600)}h old); skipping refresh (--ttl-hours {a.ttl_hours})")
        sys.exit(0)

    updates = {}
    failures = []
    sources = ["AA", "LMArena"] if a.update_source == "all" else [a.update_source]
    for src in sources:
        try:
            if src == "LMArena":
                u = lmarena_metrics(reg)
            else:
                url = FETCHERS[src]
                headers = None
                key = os.environ.get("ARTIFICIAL_ANALYSIS_API_KEY")
                if src == "AA" and key:
                    url = AA_FREE_URL
                    headers = {"x-api-key": key}
                text = fetch(url, headers=headers)
                payload = parse_payload(text)
                if src == "AA" and url == AA_FREE_URL:
                    payload = normalize_aa_free(payload)
                u = best_effort_metrics(payload, reg)
            if u:
                # AA and LMArena update the same registry keys (AA: strengths/price,
                # LMArena: elo), so union per key — {**updates, **u} would clobber AA's
                # data the moment LMArena adds elo. The first source's `source` tag wins.
                for k, v in u.items():
                    merged = dict(updates.get(k) or {})
                    if "source" in merged:
                        v = {kk: vv for kk, vv in v.items() if kk != "source"}
                    merged.update(v)
                    updates[k] = merged
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

    if not updates:
        # Nothing to merge — leave the file byte-identical. Writing it anyway would
        # reformat the seed and bury a hand edit in whole-file churn.
        print("registry unchanged — no datasource merged")
        sys.exit(0)

    new_ids = sorted(k for k in updates if k not in reg)
    if new_ids:
        # merge() only updates entries already in the registry; a datasource returning a
        # brand-new model can't seed harness/provider/available, so say so rather than
        # silently printing "merged N" while the registry never grows.
        print("new model ids found but not added (need harness/available): " + ", ".join(new_ids),
              file=sys.stderr)
    out = merge(reg, updates)
    dst = a.out or a.registry
    write_registry(dst, out)
    print(f"registry refreshed ({len(out)} entries) -> {dst}")

if __name__ == "__main__":
    main()

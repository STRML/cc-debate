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

Auto-add is CAPPED and GATED. A model id a datasource returns that the registry doesn't
know is only auto-added when it is a genuine registry improvement: it DOMINATES an
existing available model (equal-or-better performance — AA intelligence index, else
LMArena Elo — at equal-or-lower price — cost_per_task, else a blended in/out token
price — with at least one strictly), or it is the strongest model from a lab the
registry doesn't have yet (one per new lab). Mid-tier duplicates and strict tradeoffs
are skipped, so a first live refresh cannot grow the registry by hundreds of stubs.
What survives is added as a schema-valid entry with safe defaults: harness `acpx`,
effort `medium` over the full effort_range, repo_aware false, family/lab derived from
the creator when known else 'unknown', `available: false` — never selectable until a
user enables them and confirms the harness. Metric refreshes on existing entries always
apply automatically; ADDING entries requires confirmation (interactive `[y/N]` prompt,
skipped in non-interactive runs, `--apply-new` to accept headless, `--dry-run` to
preview what would change without writing).

Usage:
  refresh-models.py --registry <debate-models.json> [--out <path>]
      [--update-source AA|LMArena|all] [--ttl-hours N] [--apply-new] [--dry-run]
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

# Reserved key in the updates dict a parser returns: a LIST of schema-complete entries
# for model ids the datasource saw but the registry doesn't know yet. merge() ADDS these;
# every other key in updates is an existing registry entry to update in place.
NEW = "__new__"

# Default effort_range for an auto-added model: the full standard set, so the default
# effort ('medium') always satisfies the schema gate's effort-in-range invariant.
EFFORT_ORDER = ("low", "medium", "high", "xhigh", "max")

# creator/organization -> (family, lab), matching the seed's conventions
# (openai -> oai/openai, google -> gemini/google, zai -> glm/zai, ...). An unknown
# creator gets a generic pair; the auto-added entry is available:false anyway, so a
# slightly-off family/lab is a cosmetic stub until a human curates it.
CREATOR_IDENTITY = {
    "openai": ("oai", "openai"),
    "anthropic": ("claude", "anthropic"),
    "google": ("gemini", "google"),
    "deepseek": ("deepseek", "deepseek"),
    "zai": ("glm", "zai"),
    "zhipu": ("glm", "zai"),
    "moonshot": ("kimi", "moonshot"),
    "qwen": ("qwen", "alibaba"),
    "alibaba": ("qwen", "alibaba"),
    "meta": ("llama", "meta"),
    "mistral": ("mistral", "mistral"),
    "xai": ("grok", "xai"),
    "grok": ("grok", "xai"),
}

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

def _strip_variant_slug(slug):
    """Strip an effort-variant suffix from a RAW slug, so a brand-new model is registered
    by its base id ('gpt-5-6-luna-xhigh' -> 'gpt-5-6-luna'), not an effort variant.
    Unlike _split_variant this works on the punctuated slug, preserving the dashes."""
    low = (slug or "").lower()
    for suf in VARIANT_SUFFIXES:
        if low.endswith(suf) and len(slug) > len(suf):
            return slug[:-len(suf)]
    return slug

def _identity(creator):
    """(family, lab) for a datasource creator/organization string, else a generic pair.
    Substring match (longest key first) so 'Zhipu AI' hits zai, 'Moonshot AI' hits kimi."""
    key = _norm(creator)
    if key:
        for cand, pair in sorted(CREATOR_IDENTITY.items(), key=lambda kv: -len(kv[0])):
            if cand in key:
                return pair
    return "unknown", "unknown"

def _complete_price(price):
    """Schema-valid price dict: in/out/cost_per_task all present and numeric, 0.0
    placeholders for whatever the datasource didn't provide. The schema gate rejects a
    missing or non-numeric price field, and an available:false stub is never selected,
    so a 0.0 placeholder is safe until a human curates real pricing."""
    out = {}
    for f in ("in", "out", "cost_per_task"):
        v = _num((price or {}).get(f))
        out[f] = v if v is not None else 0.0
    return out

def _key_for_new(model_id, out):
    """Deterministic registry key for an auto-added model, never colliding with an
    existing key. 'kimi-k3' -> 'kimi_k3'; a clash gets a _2/_3... suffix."""
    base = "".join(ch if ch.isalnum() else "_" for ch in (model_id or "").lower()).strip("_") or "model"
    key, n = base, 2
    while key in out:
        key = "%s_%d" % (base, n)
        n += 1
    return key

def _new_entry(*, name, model_id, creator=None, provider=None, strengths=None,
               price=None, cost=None, elo=None, index=None, source):
    """Schema-complete registry entry for a model a datasource returned that the registry
    doesn't know yet. Everything the datasource can't provide is a SAFE default:
    harness 'acpx' (the default transport), available False (auto-added models are NEVER
    selectable until a user enables them and confirms the harness), repo_aware False,
    effort 'medium' across the full effort_range, family/lab from the creator else
    'unknown'. Returns an entry that satisfies tests/test-registry-schema.py."""
    family, lab = _identity(creator)
    price = _complete_price(price)
    entry = {
        "name": name or model_id,
        "harness": "acpx",
        "provider": provider or lab or "unknown",
        "model_id": model_id,
        "family": family,
        "lab": lab,
        "strengths": sorted(set(strengths or [])),
        "effort": "medium",
        "effort_range": list(EFFORT_ORDER),
        "price": price,
        "cost": cost or _cost_bucket(price.get("in")) or "cheap",
        "repo_aware": False,
        "available": False,
        "source": source,
    }
    if elo is not None:
        entry["elo"] = elo
    if index is not None:
        entry["index"] = index
    return entry

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
    new_by_base = {}
    for m in models:
        norm = _norm(m.get("slug")) or _norm(m.get("name"))
        if not norm:
            continue
        base, variant = _split_variant(norm)
        if base in reg_norm:
            by_base.setdefault(reg_norm[base], {}).setdefault(variant, m)
        elif base not in new_by_base or variant == "":
            # brand-new base slug: keep one row, preferring the unsuffixed (max-effort)
            # one so the auto-added entry is registered at its base id.
            new_by_base[base] = m
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
    new_entries = [_aa_to_new_entry(new_by_base[b]) for b in sorted(new_by_base)]
    if new_entries:
        updates[NEW] = new_entries
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
    if idx is not None:
        # Store the raw index so the auto-add cap can compare a new-model candidate
        # against this entry on the same performance scale, not just last week's elo.
        u["index"] = idx
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

def _aa_to_new_entry(m):
    """Schema-complete entry for an AA model the registry doesn't know. AA provides name,
    slug, price (in/out, and cost_per_task from the free API) and derived strengths;
    _new_entry fills the rest (harness, available:false, effort, identity)."""
    idx = _num(m.get("intelligenceIndex"))
    price_in = _num(m.get("priceInputPer1m"))
    price_out = _num(m.get("priceOutputPer1m"))
    cpt = _num(m.get("costPerTask"))
    price = {"in": price_in, "out": price_out}
    if cpt is not None:
        price["cost_per_task"] = cpt
    name = m.get("name") or m.get("slug")
    slug = m.get("slug") or name or ""
    return _new_entry(name=name, model_id=_strip_variant_slug(slug),
                      creator=m.get("creator") or m.get("organization"),
                      strengths=_strengths_from(idx, price_in, _num(m.get("latencySeconds"))) or [],
                      price=price, cost=_cost_bucket(price_in), index=idx, source="AA")

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
    """Map LMArena overall Elo rows into {registry_key: {elo}} updates (secondary confidence).
    Unmatched rows (a model LMArena rates that the registry doesn't know) are returned as
    auto-add candidates under NEW — elo + org-derived identity, price placeholders."""
    rows = fetch_lmarena()
    if not rows or not registry:
        return {}
    reg_norm = _registry_norm(registry)
    by_base = {}
    new_by_base = {}
    for r in rows:
        norm = _norm(r.get("model_name")) or _norm(r.get("organization") or "")
        base, variant = _split_variant(norm)
        if base in reg_norm:
            by_base.setdefault(reg_norm[base], {}).setdefault(variant, r)
        elif base not in new_by_base or variant == "":
            new_by_base[base] = r
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
    new_entries = []
    for b in sorted(new_by_base):
        row = new_by_base[b]
        if _num(row.get("rating")) is None:
            continue   # no Elo — nothing worth stubbing a registry entry for
        new_entries.append(_lmarena_to_new_entry(row))
    if new_entries:
        updates[NEW] = new_entries
    return updates

def _lmarena_to_new_entry(r):
    """Schema-complete entry for an LMArena row the registry doesn't know. LMArena
    provides model_name, organization and Elo; price/strengths are 0.0/[] placeholders
    (inert while available:false) until a human curates them."""
    name = r.get("model_name") or ""
    return _new_entry(name=name, model_id=_strip_variant_slug(name),
                      creator=r.get("organization"),
                      strengths=[], price=None, cost=None,
                      elo=_num(r.get("rating")), source="LMArena")

def write_registry(path, reg):
    """Atomic replace. Write to a temp then rename, so an interrupted refresh never
    truncates the user's curated registry in place."""
    tmp = "%s.tmp" % path
    with open(tmp, "w") as f:
        json.dump(reg, f, indent=2)
        f.write("\n")
    os.replace(tmp, path)

def _merge_new(a, b):
    """Union two sources' new-model candidate lists (both under the reserved NEW key),
    keyed by model_id. The earlier source's fields win; the later one fills gaps it has
    data for (LMArena's elo onto AA's stub, LMArena's org where AA had no creator)."""
    by_id = {}
    for cand in (a or []) + (b or []):
        nid = _norm(cand.get("model_id"))
        if not nid:
            continue
        if nid not in by_id:
            by_id[nid] = dict(cand)
            continue
        old, new = by_id[nid], cand
        for k, v in new.items():
            if k == "price" and isinstance(v, dict):
                # the earlier source's real price wins; a later 0.0 placeholder (a source
                # with no pricing, e.g. LMArena) never clobbers it.
                old.setdefault("price", {})
                for f, fv in v.items():
                    if _num(old["price"].get(f)) in (None, 0.0) and fv not in (None, 0.0):
                        old["price"][f] = fv
            elif k == "strengths" and v:
                old["strengths"] = sorted(set((old.get("strengths") or []) + v))
            elif k in ("provider", "family", "lab") and old.get(k) == "unknown" \
                    and v not in (None, "", "unknown"):
                old[k] = v   # LMArena's org beats AA's absence-of-creator 'unknown'
            elif old.get(k) in (None, "", [], {}) and v not in (None, "", [], {}):
                old[k] = v
    return list(by_id.values())

def _perf_metric(m):
    """Comparable performance for a model: the AA intelligence index when present, else
    the LMArena Elo. Returns (value, source) with source in ('index', 'elo'), or
    (None, None) when a model has neither. Dominance comparisons only happen within the
    same source — an index (~50) and an Elo (~1400) are different scales."""
    idx = _num(m.get("index"))
    if idx is not None:
        return idx, "index"
    elo = _num(m.get("elo"))
    if elo is not None:
        return elo, "elo"
    return None, None

def _price_metric(m):
    """Comparable price for a model: cost_per_task when the datasource gave a real
    per-task figure, else a blended in/out token price (0.3*in + 0.7*out — a typical
    agentic read/write mix). Returns None when the model has no pricing at all, so an
    LMArena-only candidate (0.0 price placeholders) is never judged on price."""
    cpt = _num((m.get("price") or {}).get("cost_per_task"))
    if cpt not in (None, 0.0):
        return cpt
    p = m.get("price") or {}
    inn, out = _num(p.get("in")), _num(p.get("out"))
    if (inn in (None, 0.0)) and (out in (None, 0.0)):
        return None
    return 0.3 * (inn or 0.0) + 0.7 * (out or 0.0)

def _fmt_perf(m):
    p, s = _perf_metric(m)
    return "-" if p is None else ("%.1f (%s)" % (p, s))

def _fmt_price(m):
    p = _price_metric(m)
    return "-" if p is None else ("$%.3g" % p)

def _cap_new(candidates, out):
    """Filter auto-add candidates down to genuine registry improvements (#31).

    A candidate is worth adding when either:
      - it DOMINATES an existing *available* model — equal-or-better performance (AA
        intelligence index, else LMArena Elo) at equal-or-lower price (cost_per_task,
        else blended in/out), with at least one strictly better; or
      - it is the strongest model from a lab the registry does not have yet (lab
        diversity — at most ONE per new lab, so a fresh lab's whole lineup doesn't flood
        the registry).

    Everything else — mid-tier duplicates of labs already present, and strict
    perf/price tradeoffs — is skipped, keeping the registry lean. 'unknown' is not a
    real lab: an unrecognized creator's model is a data stub, not a diversity win, so it
    can only get in by dominating (and usually can't, since it lacks pricing).

    `out` must already have this refresh's metric updates applied (see merge), so a
    candidate's index is compared against the registry's fresh index, not last week's.
    """
    if not candidates:
        return []
    labs = {m.get("lab") for m in out.values() if m.get("lab")}
    avail = [m for m in out.values() if m.get("available")]
    best_per_new_lab = {}
    results = []
    for cand in candidates:
        pval, psrc = _perf_metric(cand)
        price = _price_metric(cand)
        lab = cand.get("lab")
        if lab and lab != "unknown" and lab not in labs:
            cur = best_per_new_lab.get(lab)
            if cur is None:
                best_per_new_lab[lab] = cand
            else:
                cp, _ = _perf_metric(cur)
                if pval is not None and (cp is None or pval > cp):
                    best_per_new_lab[lab] = cand
        if pval is None or price is None:
            continue
        for em in avail:
            ep, esrc = _perf_metric(em)
            eprice = _price_metric(em)
            if ep is None or eprice is None or esrc != psrc:
                continue   # different performance scale — not comparable
            if pval >= ep and price <= eprice and (pval > ep or price < eprice):
                results.append(cand)
                break
    seen = {c.get("model_id") for c in results}
    for cand in best_per_new_lab.values():
        if cand.get("model_id") not in seen:
            results.append(cand)
    return results

def _apply_metrics(out, updates):
    """Apply per-key metric updates to a registry dict IN PLACE: union strengths, set
    effort/effort_range/cost/elo/index, patch price fields, record source + as_of.
    Never touches the user-owned fields (harness/provider/repo_aware/available/
    cost_per_task unless the update carries one) and never adds new-model candidates."""
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
        if u.get("index") is not None:
            m["index"] = u["index"]
        m.setdefault("price", {})
        for f in ("in", "out", "cost_per_task"):
            if u.get("price", {}).get(f) is not None:
                m["price"][f] = u["price"][f]
        m["source"] = u.get("source", "manual")
        m["as_of"] = now
    return out

def merge(registry, updates, add_new=True):
    out = copy.deepcopy(registry)   # never mutate the caller's nested dicts (F9)
    _apply_metrics(out, updates)
    # New-model candidates (the reserved NEW key) are schema-complete entries to ADD —
    # but only the ones _cap_new keeps (frontier winners + one per new lab). A model id
    # the registry already knows is skipped: the curated entry wins, always.
    if add_new:
        known = {_norm(m.get("model_id")) for m in out.values()}
        for cand in _cap_new(updates.get(NEW) or [], out):
            nid = _norm(cand.get("model_id"))
            if not nid or nid in known:
                continue
            entry = dict(cand)
            entry["as_of"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
            out[_key_for_new(cand["model_id"], out)] = entry
            known.add(nid)
    return out

def _confirm_new(would_add, apply_new=False, interactive=None):
    """Gate new-model additions (metric refreshes are NOT gated — only ADDING entries
    grows the curated registry, so it needs consent).

    - `apply_new`: accept headless (cron/CI) without prompting.
    - no candidates: trivially accept (nothing to add).
    - interactive (TTY): print the proposed models and prompt "add N new model(s)?
      [y/N]"; anything but an explicit y/yes declines.
    - non-interactive (no TTY): decline with a clear message — pass --apply-new to
      accept. Never silently adds a model a human didn't see.
    """
    if not would_add:
        return True
    if apply_new:
        return True
    print("proposed new models (arrive available:false until enabled):")
    for cand in would_add:
        print("  - %s (%s)  lab=%s  perf=%s  price=%s"
              % (cand.get("name"), cand.get("model_id"), cand.get("lab"),
                 _fmt_perf(cand), _fmt_price(cand)))
    if interactive is None:
        interactive = sys.stdin.isatty()
    if not interactive:
        print("non-interactive run: skipping %d new model addition(s) "
              "(pass --apply-new to accept them)" % len(would_add), file=sys.stderr)
        return False
    try:
        ans = input("add %d new model(s)? [y/N] " % len(would_add))
        return ans.strip().lower() in ("y", "yes")
    except EOFError:
        return False

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--registry", required=True)
    ap.add_argument("--out", default=None)
    ap.add_argument("--update-source", default="all", choices=["AA", "LMArena", "all"])
    ap.add_argument("--ttl-hours", type=float, default=24*7)
    ap.add_argument("--apply-new", action="store_true",
                    help="add new models the datasources surfaced without prompting "
                         "(headless/cron runs)")
    ap.add_argument("--dry-run", action="store_true",
                    help="print what the refresh would change (metric updates + the "
                         "new models the cap would add) and exit without writing")
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
                # New-model candidates (the NEW key) are a list, not a per-key dict:
                # union the lists by model_id so AA's stub picks up LMArena's elo.
                n_new = len(u.get(NEW) or [])
                for k, v in u.items():
                    if k == NEW:
                        updates[NEW] = _merge_new(updates.get(NEW), v)
                        continue
                    merged = dict(updates.get(k) or {})
                    if "source" in merged:
                        v = {kk: vv for kk, vv in v.items() if kk != "source"}
                    merged.update(v)
                    updates[k] = merged
                n_upd = len(u) - (1 if NEW in u else 0)
                print(f"{src}: merged {n_upd} model updates"
                      + (f", {n_new} new model(s)" if n_new else ""))
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

    # What the cap would add, evaluated against the registry WITH this refresh's metric
    # updates applied (fresh index/elo make the dominance comparison like-for-like).
    would_add = _cap_new(updates.get(NEW) or [],
                         _apply_metrics(copy.deepcopy(reg), updates))
    dst = a.out or a.registry

    if a.dry_run:
        n_upd = len(updates) - (1 if NEW in updates else 0)
        print(f"dry-run: {n_upd} model update(s)")
        if would_add:
            print(f"dry-run: would add {len(would_add)} new model(s) (available:false):")
            for cand in would_add:
                print("  - %s (%s)  lab=%s  perf=%s  price=%s"
                      % (cand.get("name"), cand.get("model_id"), cand.get("lab"),
                         _fmt_perf(cand), _fmt_price(cand)))
        else:
            print("dry-run: no new models pass the cap (frontier improvement or new lab)")
        sys.exit(0)

    add_new = _confirm_new(would_add, apply_new=a.apply_new)

    out = merge(reg, updates, add_new=add_new)
    write_registry(dst, out)
    added = sorted(k for k in out if k not in reg)
    msg = f"registry refreshed ({len(out)} entries) -> {dst}"
    if added:
        # Auto-added models are available:false — inert until a user enables them and
        # confirms the harness. Report the growth so it's visible, not silent.
        msg += f"; new models added (available:false): {', '.join(added)}"
    elif would_add:
        msg += f"; {len(would_add)} proposed new model(s) skipped (use --apply-new to accept)"
    print(msg)

if __name__ == "__main__":
    main()

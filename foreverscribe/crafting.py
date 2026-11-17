"""foreverscribe craft --profit — what each known recipe costs to craft, sells for, and earns on your auction house.

  foreverscribe craft --profit [profession] [--limit N] [--all] [--json]

The same numbers the profession window shows in game (addon 0.8):
  Cost to craft  every material at its typical AH price (today's median), or at the vendor's price where a vendor
                 sells it cheaper (threads, dyes, spices, vials ...: data/vendor-prices.json, or the price this
                 character saw at that vendor).
  Sells for      the crafted item's typical AH price x the number one craft makes.
  Profit         sells for - the AH cut - cost to craft. The cut is 5% of the sale (Forever's faction AH), or the
                 rate your own AH invoices show, or [ah] cut in config.toml.
A number that can't be calculated is left out, never guessed: a material nobody listed and no vendor sells leaves
out the cost (and the profit); a crafted item with no listings (bind on pickup, soulbound, never listed) leaves out
"sells for" (and the profit).
"""
import json
import os
import sys
import time

from . import config as C

HERE = os.path.dirname(os.path.abspath(__file__))
VENDOR_FILE = os.path.join(os.path.dirname(HERE), "data", "vendor-prices.json")
DEFAULT_CUT = 0.05
DIFFICULTY = {0: "orange", 1: "yellow", 2: "green", 3: "gray"}  # Enum.TradeskillRelativeDifficulty


# ---------- prices ----------
def shipped_vendor_prices():
    """{itemID: copper per unit} for materials ordinary vendors sell (game data shipped with ForeverScribe)."""
    try:
        with open(VENDOR_FILE, encoding="utf-8") as f:
            d = json.load(f)
    except (OSError, ValueError):
        return {}
    out = {}
    for k, v in (d.get("items") or {}).items():
        try:
            p = int(v[0] if isinstance(v, list) else v)
        except (TypeError, ValueError, IndexError):
            continue
        if str(k).isdigit() and p > 0:
            out[int(k)] = p
    return out


def captured_vendor_prices(con):
    """{itemID: copper per unit} from vendor windows the characters opened (ForeverScribe 0.3+): unlimited stock,
    plain money cost only. The cheapest vendor seen wins."""
    out = {}
    if con is None:
        return out
    try:
        rows = con.execute("SELECT json FROM sections WHERE section='vendors'").fetchall()
    except Exception:
        return out
    for (j,) in rows:
        try:
            v = json.loads(j)
        except (TypeError, ValueError):
            continue
        npcs = v.get("npcs") if isinstance(v, dict) else None
        for x in (npcs.values() if isinstance(npcs, dict) else npcs if isinstance(npcs, list) else []):
            items = x.get("items") if isinstance(x, dict) else None
            for it in (items.values() if isinstance(items, dict) else items or []):
                if not isinstance(it, dict) or it.get("limited") is not None or it.get("cost") or it.get("currencyID"):
                    continue
                iid, price, stack = it.get("itemID"), it.get("price"), it.get("stack") or 1
                if not isinstance(iid, int) or not isinstance(price, (int, float)) or price <= 0:
                    continue
                unit = -(-int(price) // max(1, int(stack)))
                out[iid] = min(out.get(iid, unit), unit)
    return out


def vendor_prices(con=None):
    """Shipped list prices, replaced by what this account actually saw at a vendor."""
    out = shipped_vendor_prices()
    out.update(captured_vendor_prices(con))
    return out


def _invoice_rates(con):
    rates = []
    if con is None:
        return rates
    try:
        rows = con.execute("SELECT json FROM section_history WHERE section='mail' UNION ALL "
                           "SELECT json FROM sections WHERE section='mail'").fetchall()
    except Exception:
        return rates
    seen = set()
    for (j,) in rows:
        try:
            m = json.loads(j)
        except (TypeError, ValueError):
            continue
        for x in (m.get("mails") or []) if isinstance(m, dict) else []:
            inv = x.get("invoice") if isinstance(x, dict) else None
            if not isinstance(inv, dict) or inv.get("type") != "seller":
                continue
            sale, fee = inv.get("buyout") or inv.get("bid"), inv.get("fee")
            if isinstance(sale, (int, float)) and isinstance(fee, (int, float)) and sale > 0 and fee >= 0:
                key = (inv.get("item"), sale, fee)
                if key not in seen:
                    seen.add(key)
                    rates.append(fee / float(sale))
    return rates


def ah_cut(cfg=None, con=None):
    """(rate, where it came from). The client has no API for the AH cut, so: [ah] cut in config.toml, else the
    median rate of the character's AH sale invoices, else 5% (Forever's faction auction houses)."""
    if cfg is not None:
        v = cfg.section("ah").get("cut") if hasattr(cfg, "section") else None
        if v not in (None, ""):
            try:
                r = float(v)
                r = r / 100.0 if r >= 1 else r
                if 0 <= r < 0.5:
                    return r, "config"
            except (TypeError, ValueError):
                pass
    rates = sorted(r for r in _invoice_rates(con) if 0 <= r < 0.5)
    if rates:
        return round(rates[len(rates) // 2], 4), "your AH invoices"
    return DEFAULT_CUT, "default"


def unit_price(iid, items, vendor):
    """(copper, 'AH' | 'vendor') for one unit of a material, the cheaper of the two; None when neither exists."""
    row = items.get(str(iid)) or items.get(iid)
    ah = row[0] if isinstance(row, list) and row and isinstance(row[0], (int, float)) and row[0] > 0 else None
    v = vendor.get(int(iid)) if vendor else None
    if v and (ah is None or v <= ah):
        return int(v), "vendor"
    if ah is not None:
        return int(ah), "AH"
    return None


def evaluate(product, qty, reagents, items, vendor, cut=DEFAULT_CUT):
    """One craft. reagents: [(itemID, n), ...]. Returns {cost, sells, cut, profit, missing, reagents} where a value
    that can't be calculated is None (never a guess)."""
    lines, cost, missing = [], 0, []
    for iid, n in reagents:
        p = unit_price(iid, items, vendor)
        if p is None:
            missing.append(int(iid))
            lines.append({"itemID": int(iid), "qty": int(n), "unit": None, "source": None})
        else:
            cost += p[0] * int(n)
            lines.append({"itemID": int(iid), "qty": int(n), "unit": p[0], "source": p[1]})
    if missing or not reagents:
        cost = None
    row = items.get(str(product)) or items.get(product) if product else None
    med = row[0] if isinstance(row, list) and row and isinstance(row[0], (int, float)) and row[0] > 0 else None
    q = max(1, int(qty or 1))
    sells = int(med) * q if med is not None else None
    fee = int(sells * cut + 0.5) if sells is not None else None  # half up, like the addon
    profit = sells - fee - cost if sells is not None and cost is not None else None
    return {"product": product, "qty": q, "cost": cost, "sells": sells, "cut": fee, "profit": profit,
            "missing": missing, "reagents": lines}


# ---------- the price file (addon 0.8 reads these; prices.render_lua writes them) ----------
def _f(v):
    return "" if v is None else str(int(v))


def price_file_rows(con, items, cfg=None):
    """(vendor {itemID: copper} for crafting materials, {recipeID: "product,qty,cost,sells;reagent:n,..."}, AH cut)
    for every recipe any character on this computer knows. Cost / sells are empty where they can't be calculated."""
    vendor = vendor_prices(con)
    cut, _ = ah_cut(cfg, con)
    crafts, mats = {}, set()
    rows = con.execute("SELECT recipe_id, output_item, output_qty, reagents_json, scanned_at FROM recipes"
                       " WHERE recipe_id IS NOT NULL ORDER BY scanned_at").fetchall()
    for r in rows:  # newest scan last, so it wins
        try:
            reag = [(int(x["itemID"]), max(1, int(x.get("qty") or 1))) for x in json.loads(r["reagents_json"] or "[]")
                    if isinstance(x, dict) and x.get("itemID")][:12]
        except (TypeError, ValueError):
            continue
        if not reag and not r["output_item"]:
            continue
        e = evaluate(r["output_item"], r["output_qty"] or 1, reag, items, vendor, cut)
        crafts[int(r["recipe_id"])] = "%s,%d,%s,%s;%s" % (_f(r["output_item"]), e["qty"], _f(e["cost"]), _f(e["sells"]),
                                                       ",".join("%d:%d" % x for x in reag))
        mats.update(i for i, _ in reag)
    try:
        from . import prices
        for v in prices.patterns(cfg).values():
            mats.update(int(a) for a, _ in (v[1] or []))
    except Exception:
        pass
    return {i: p for i, p in vendor.items() if i in mats}, crafts, cut


# ---------- the character's recipes ----------
def market_snapshot(cfg):
    from . import ah, prices
    s = ah.settings(cfg)
    if not s["market"]:
        return None
    return prices._read_json(prices.snapshot_path(cfg, s["market"]))


def known_recipes(con, ck, profession=None):
    rows = con.execute("SELECT profession, recipe_key, recipe_id, name, difficulty, skill_ups, output_item, output_qty,"
                       " reagents_json, scanned_at FROM recipes WHERE char_key=? ORDER BY profession, name", (ck,)).fetchall()
    out = []
    for r in rows:
        prof = r["profession"] or ""
        if not prof or (profession and prof.lower() != profession.lower()):
            continue
        try:
            reag = [(int(x["itemID"]), int(x.get("qty") or 1)) for x in json.loads(r["reagents_json"] or "[]")
                    if isinstance(x, dict) and x.get("itemID")]
        except (TypeError, ValueError):
            reag = []
        out.append({"profession": prof, "recipeID": r["recipe_id"], "name": r["name"], "difficulty": r["difficulty"],
                    "skill_ups": r["skill_ups"], "product": r["output_item"], "qty": r["output_qty"] or 1,
                    "reagents": reag, "scanned_at": r["scanned_at"]})
    return out


def money(c):
    if c is None:
        return None
    neg = c < 0
    c = abs(int(c))
    g, s, k = c // 10000, (c // 100) % 100, c % 100
    parts = ([("%dg" % g)] if g else []) + ([("%ds" % s)] if s else []) + ([("%dc" % k)] if k or not (g or s) else [])
    return ("-" if neg else "") + " ".join(parts)


def item_names(con):
    names = {}
    for p in (VENDOR_FILE,):
        try:
            with open(p, encoding="utf-8") as f:
                for k, v in (json.load(f).get("items") or {}).items():
                    if isinstance(v, list) and len(v) > 1:
                        names[int(k)] = v[1]
        except (OSError, ValueError):
            pass
    try:
        for r in con.execute("SELECT DISTINCT item_id, name FROM items WHERE name IS NOT NULL"):
            names[r[0]] = r[1]
    except Exception:
        pass
    return names


def bind_on_pickup(iid):
    """True when the cached Wowhead tooltip says the item binds when picked up; None when unknown (nothing fetched)."""
    if not iid:
        return None
    try:
        from . import wowhead as WH
        p = os.path.join(WH.CACHE, "item-%d.json" % int(iid))
        if not os.path.isfile(p):
            return None
        with open(p, encoding="utf-8") as f:
            tip = (json.load(f) or {}).get("tooltip") or ""
        return True if "Binds when picked up" in tip else False
    except Exception:
        return None


def profit_report(con, ck, cfg, profession=None, limit=15, include_all=False, now=None):
    snap = market_snapshot(cfg)
    if not snap or not snap.get("items"):
        return {"available": False, "note": "No AH prices yet: turn on [ah] in config.toml and run `foreverscribe prices write`."}
    items = snap["items"]
    vendor = vendor_prices(con)
    cut, cut_src = ah_cut(cfg, con)
    recs = known_recipes(con, ck, profession)
    if not recs:
        return {"available": False, "note": "No recipes captured%s. Open the profession window in game (ForeverScribe), "
                                              "then /reload." % (" for " + profession if profession else "")}
    names = item_names(con)
    priced, unpriced = [], []
    for r in recs:
        e = evaluate(r["product"], r["qty"], r["reagents"], items, vendor, cut)
        row = {"profession": r["profession"], "recipe": r["name"], "recipeID": r["recipeID"],
               "skill_up": DIFFICULTY.get(r["difficulty"], "?") if r["difficulty"] is not None else "?",
               "makes": r["qty"], "cost": e["cost"], "sells": e["sells"], "ah_cut": e["cut"], "profit": e["profit"],
               "materials": [{"item": names.get(x["itemID"], x["itemID"]), "qty": x["qty"], "unit": x["unit"],
                              "source": x["source"]} for x in e["reagents"]]}
        if e["profit"] is not None:
            priced.append(row)
        else:
            why = []
            if e["sells"] is None:
                bop = bind_on_pickup(r["product"])
                why.append("crafted item binds when picked up (can't be listed)" if bop else
                           "crafted item has no AH listings")
            if e["missing"]:
                why.append("no price for " + ", ".join(str(names.get(i, i)) for i in e["missing"]))
            row["why_no_profit"] = "; ".join(why)
            unpriced.append(row)
    priced.sort(key=lambda x: (-x["profit"], x["recipe"] or ""))
    from . import prices
    captured = prices._epoch(snap.get("capturedAt"))
    age = int((now or time.time()) - captured) if captured else None
    return {"available": True, "market": snap.get("market"), "scan": snap.get("capturedAt"), "scan_age_seconds": age,
            "ah_cut": cut, "ah_cut_source": cut_src, "recipes": len(recs),
            "best": priced if include_all else priced[:limit], "not_priced": unpriced if include_all else unpriced[:limit],
            "counts": {"priced": len(priced), "not_priced": len(unpriced)}}


def render(rep):
    if not rep.get("available"):
        return rep.get("note") or "nothing to show"
    from . import prices
    age = prices._ago(time.time() - rep["scan_age_seconds"]) if rep.get("scan_age_seconds") is not None else "?"
    lines = ["Most profitable crafts (%s, AH scan %s ago; AH cut %g%% %s)" % (
        rep.get("market"), age, rep["ah_cut"] * 100, "(default)" if rep["ah_cut_source"] == "default" else "from " + rep["ah_cut_source"])]
    for x in rep["best"]:
        lines.append("  %s%-34s %-7s cost %-12s sells %-12s profit %s" % (
            "+" if x["profit"] > 0 else " ", ("%s (%s)" % (x["recipe"], x["profession"]))[:34], x["skill_up"],
            money(x["cost"]), money(x["sells"]) + (" x%d" % x["makes"] if x["makes"] > 1 else ""), money(x["profit"])))
    if rep["not_priced"]:
        lines.append("Can't price (%d):" % rep["counts"]["not_priced"])
        for x in rep["not_priced"]:
            lines.append("  %s (%s): %s%s" % (x["recipe"], x["profession"], x["why_no_profit"],
                                             "; cost " + money(x["cost"]) if x["cost"] is not None else ""))
    lines.append("Skill-up colour: orange/yellow/green raise the skill, gray doesn't. Prices: typical (median) AH, "
                 "vendor where cheaper.")
    return "\n".join(lines)


def main(argv=None):
    a = list(sys.argv[1:] if argv is None else argv)
    if any(x in ("-h", "--help") for x in a):
        print(__doc__)
        return 0
    opt = {"limit": 15, "all": False, "json": False, "char": None}
    words = []
    while a:
        x = a.pop(0)
        if x == "--profit":
            continue
        if x == "--limit" and a:
            opt["limit"] = max(1, int(a.pop(0)))
        elif x == "--all":
            opt["all"] = True
        elif x == "--json":
            opt["json"] = True
        elif x in ("--char", "-c") and a:
            opt["char"] = a.pop(0)
        else:
            words.append(x)
    from . import queries as Q, store
    from .cli import load_config
    cfg = C.load()
    lc = load_config()
    con = store.connect(lc["db"])
    try:
        store.ingest_all(con, lc["sources"], extra=lc["extra"])
        ck = Q.resolve_char(con, opt["char"] or lc["default_character"])
        rep = profit_report(con, ck, cfg, " ".join(words) or None, opt["limit"], opt["all"])
    except KeyError as e:
        print(str(e).strip("'\""))
        return 4
    finally:
        con.close()
    print(json.dumps(rep, indent=2) if opt["json"] else render(rep))
    return 0


if __name__ == "__main__":
    sys.exit(main())

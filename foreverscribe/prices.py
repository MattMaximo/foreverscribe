"""foreverscribe prices — auction-house prices in your item tooltips (addon 0.6+). Uses the optional wow.gg source.

  foreverscribe prices write [--to local|folder|http|all] [--market M] [--force]   fetch your market, write the file
  foreverscribe prices status                      what was written, how big, how old; what the game computer fetched
  foreverscribe prices watch [--every 30]          keep it fresh (for local/folder setups; the receiver does it itself)
Options: --json

Needs [ah] enabled = true, wowgg_key and market in config.toml (see `foreverscribe ah --help`; off by default).

What it writes. One small data-only Lua file, Prices.lua: for every item seen on your market's auction house the
typical price (current median), cheapest listing, quantity listed, 7-day and 30-day typical and the other faction's
typical, plus the scan time; and for recipe items the item they make and its materials (Wowhead data). About 250 KB
for ~6,500 items; capped at MAX_BYTES. The game loads it at login and on /reload; the tooltip shows its age.

How it reaches the game (the same paths a route takes):
  local   (agent on the game computer)  written straight into Interface/AddOns/ForeverScribe_Prices/Prices.lua
  folder  (synced folder)              written to <folder>/_prices/Prices.lua; the game-side sync agent copies it in
  http    (receiver)                   kept in <data_dir>/prices/Prices.lua; the game-side sync agent asks for it every
                                       5 minutes (signed GET); when the copy is older than 30 minutes the receiver
                                       refreshes it in the background, so prices stay fresh only while you play.
wow.gg is asked politely: one page first to see whether the AH scan changed since the last file; the full market
(about 33 pages) is fetched only when it did, at most every 30 minutes.
"""
import hashlib
import json
import os
import re
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request

from . import ah, config as C

PRICE_FORMAT = 1
PER_PAGE = 200
MAX_PAGES = 80
MAX_BYTES = 600 * 1024  # measured: ~6,500 items -> ~250 KB
MAX_ITEMS = 20000  # the addon refuses bigger files too
DEFAULT_CUT = 0.05  # the AH's cut of a sale (crafting.ah_cut finds the real one)
REFRESH_SECONDS = 30 * 60
PAGE_PAUSE = 0.3
HERE = os.path.dirname(os.path.abspath(__file__))
PATTERNS_FILE = os.path.join(os.path.dirname(HERE), "data", "patterns.json")
EMPTY_LUA = ("-- ForeverScribe prices (data only; the companion rewrites it). Empty: no prices written yet.\n"
             "ForeverScribe_PriceData = nil\n")
REGIONS = {"us": "US", "eu": "EU", "kr": "KR", "tw": "TW"}

# Every line of a price file matches this (the sync agents use the same pattern: PRICE_LINE / $PriceLine).
LINE_RE = re.compile(r'^(-- [^\[].*|ForeverScribe_PriceData = (\{|nil)|\t(v|captured|written|items) = [0-9]+,|'
                     r'\t(rev|market|label|other|source) = "[A-Za-z0-9 _.-]*",|\t[dp] = \{|\t\t\[[0-9]+\] = "[0-9,:;]*",|'
                     r'\t\},|\})?$')


class Disabled(RuntimeError):
    pass


# ---------- wow.gg ----------
FETCH = {}  # tests replace "page"


def _page(s, market, page):
    """One page of the market listing (not cached: the snapshot below is the cache)."""
    if FETCH.get("page"):
        return FETCH["page"](market, page)
    qs = urllib.parse.urlencode({"market": market, "sort": "name", "dir": "asc", "page": page, "per": PER_PAGE, "locale": "en"})
    req = urllib.request.Request(ah.BASE + "?" + qs, headers=ah.headers(s["key"]))
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.load(r)


def _num(v):
    try:
        n = int(round(float(v)))
    except (TypeError, ValueError):
        return None
    return n if n >= 0 else None


def compact_row(r):
    o = r.get("other") or {}
    return [_num(r.get("median")), _num(r.get("minBuyout")), _num(r.get("quantity")), _num(r.get("median7d")),
            _num(r.get("median30d")), _num(o.get("median")), 1 if (r.get("itemClass") or "") == "Recipe" else 0]


def _epoch(iso):
    if not iso:
        return 0
    try:
        import calendar
        return calendar.timegm(time.strptime(str(iso)[:19], "%Y-%m-%dT%H:%M:%S"))
    except ValueError:
        return 0


def market_label(market, label=""):
    """'forever.pvp.alliance.us' -> ('PvP Alliance', 'Horde'). wow.gg's own label wins, minus the region."""
    parts = (market or "").split(".")
    faction = parts[2] if len(parts) > 3 else ""
    other = {"alliance": "Horde", "horde": "Alliance"}.get(faction, "")
    if label:
        lab = re.sub(r"\s+(US|EU|KR|TW)$", "", label.strip())
    else:
        rules = {"pvp": "PvP", "normal": "Normal", "pve": "PvE", "hardcore": "Hardcore"}.get(parts[1] if len(parts) > 1 else "", "")
        lab = " ".join(x for x in (rules, faction.title()) if x)
    return clean_text(lab, 40), other


def snapshot_path(cfg, market):
    return os.path.join(price_dir(cfg), "market-%s.json" % re.sub(r"[^a-z0-9.]", "_", market.lower()))


def fetch_market(s, market, cfg, force=False, log=None):
    """{capturedAt, label, items: {id: [median,min,qty,7d,30d,other,isRecipe]}}. One page decides whether the scan
    changed; the whole market is fetched only then (or with force)."""
    snap_p = snapshot_path(cfg, market)
    old = _read_json(snap_p) or {}
    first = _page(s, market, 1)
    cap = first.get("capturedAt") or first.get("lastScanAt") or ""
    if not force and old.get("capturedAt") == cap and old.get("items"):
        return old, False
    if not first.get("pricesAvailable", True):
        raise Disabled("wow.gg has no prices for market %s right now" % market)
    pages = min(int(first.get("pages") or 1), MAX_PAGES)
    items = {}
    for n in range(1, pages + 1):
        d = first if n == 1 else _page(s, market, n)
        if n > 1:
            time.sleep(PAGE_PAUSE)
        for r in d.get("rows") or []:
            iid = _num(r.get("itemId"))
            if iid:
                items[str(iid)] = compact_row(r)
    snap = {"market": market, "label": first.get("label") or "", "capturedAt": cap, "fetchedAt": int(time.time()),
            "items": items}
    os.makedirs(os.path.dirname(snap_p), exist_ok=True)
    _atomic(snap_p, json.dumps(snap, separators=(",", ":")))
    if log:
        log("prices: fetched %s (%d items, %d pages, scan %s)" % (market, len(items), pages, cap))
    return snap, True


# ---------- patterns (recipe item -> crafted item + materials) ----------
def patterns(cfg=None, ids=()):
    """{recipeItemID: [createdID, [[reagentID, n], ...]]} from the shipped data/patterns.json plus recipe items whose
    Wowhead tooltip is already in the user's cache (read only: nothing is fetched here)."""
    out = {}
    d = _read_json(PATTERNS_FILE) or {}
    for k, v in (d.get("patterns") or {}).items():
        out[str(k)] = v
    try:
        from . import wowhead as WH
    except Exception:
        return out
    for iid in ids:
        if str(iid) in out or not os.path.isfile(os.path.join(WH.CACHE, "item-%s.json" % iid)):
            continue
        t = from_wowhead(WH.item(iid, follow=False))
        if t:
            out[str(iid)] = t
    return out


def from_wowhead(it):
    """wowhead.item() of a recipe item -> [createdID, [[reagentID, n], ...]] or None."""
    t = (it or {}).get("teaches") or {}
    if not t.get("creates"):
        return None
    return [int(t["creates"]), [[int(r[0]), int(r[2])] for r in t.get("reagents") or []]]


# ---------- the price file ----------
def clean_text(s, n=60):
    s = re.sub(r"[^A-Za-z0-9 _.-]", "", str(s or ""))
    return re.sub(r"\s+", " ", s).strip()[:n]


def _field(v):
    return "" if v is None else str(int(v))


CRAFT_BASE = 100000000  # p keys >= this are profession recipes (key - CRAFT_BASE = recipeID); CRAFT_BASE itself = AH cut


def render_lua(snap, market, pats, now, max_bytes=MAX_BYTES, vendor=None, crafts=None, cut=None):
    """The data-only Lua file. Returns (text, stats). Items are dropped (fewest listed first) to stay under max_bytes.

    0.8 adds, in the same format 1 (so 0.6/0.7 sync agents and addons accept and ignore it):
      d rows: a 7th field, the vendor price of one unit, for crafting materials a vendor sells (vendor: {id: copper});
              a material no one listed gets a row with only that field (",,,,,,4").
      p rows keyed CRAFT_BASE + recipeID: "product,qty,cost,sells;reagent:n,..." (crafts: {recipeID: row}); cost or
              sells is empty when it can't be calculated. p[CRAFT_BASE] = the AH cut in basis points (500 = 5%)."""
    label, other = market_label(market, snap.get("label"))
    captured = _epoch(snap.get("capturedAt")) or int(now)
    items = snap.get("items") or {}
    vendor = {int(k): int(v) for k, v in (vendor or {}).items() if int(v) > 0}
    rows = []
    for k, r in items.items():
        if not str(k).isdigit() or not isinstance(r, list) or len(r) < 6:
            continue
        v = vendor.get(int(k))
        if all(x is None for x in r[:6]) and not v:
            continue
        body = ",".join(_field(x) for x in list(r[:6]) + [v]).rstrip(",")
        rows.append((int(k), body, (r[2] or 0) + (10 ** 9 if v else 0)))  # materials a craft needs survive a cap
    for k, v in vendor.items():
        if str(k) not in items:
            rows.append((k, ",,,,,," + str(v), 10 ** 9))
    prows = []
    for k, v in sorted(pats.items(), key=lambda kv: int(kv[0])):
        if not str(k).isdigit() or str(k) not in items:
            continue  # only recipes seen on this market
        try:
            created = int(v[0])
            reag = ",".join("%d:%d" % (int(a), int(b)) for a, b in (v[1] or [])[:12])
        except (TypeError, ValueError, IndexError):
            continue
        prows.append((int(k), "%d;%s" % (created, reag)))
    ncraft = 0
    if crafts:
        prows.append((CRAFT_BASE, str(int(round((DEFAULT_CUT if cut is None else cut) * 10000)))))
        for rid, row in sorted(crafts.items()):
            if 0 < int(rid) < CRAFT_BASE and re.match(r"^[0-9,:;]*$", row) and len(row) < 300:
                prows.append((CRAFT_BASE + int(rid), row))
                ncraft += 1
    rows.sort(key=lambda x: (-x[2], x[0]))  # most listed first: those survive a cap
    rows = rows[:MAX_ITEMS]
    rev_src = json.dumps([snap.get("capturedAt"), market, rows, prows], sort_keys=True)
    rev = "%d-%s" % (captured, hashlib.sha256(rev_src.encode()).hexdigest()[:8])

    def build(rs):
        out = ["-- ForeverScribe prices. Written by `foreverscribe prices write`; data only, the addon validates it.",
               "-- %s, %d items, scan %s. Prices: AHledger via wow.gg" % (market, len(rs), snap.get("capturedAt") or "?"),
               "ForeverScribe_PriceData = {",
               "\tv = %d," % PRICE_FORMAT,
               '\trev = "%s",' % rev,
               '\tmarket = "%s",' % clean_text(market, 60),
               '\tlabel = "%s",' % label,
               '\tother = "%s",' % clean_text(other, 20),
               '\tsource = "AHledger via wow.gg",',
               "\tcaptured = %d," % captured,
               "\twritten = %d," % int(now),
               "\titems = %d," % len(rs),
               "\td = {"]
        out += ['\t\t[%d] = "%s",' % (i, b) for i, b, _ in sorted(rs)]
        out += ["\t},", "\tp = {"]
        out += ['\t\t[%d] = "%s",' % (i, b) for i, b in prows]
        out += ["\t},", "}", ""]
        return "\n".join(out)

    text = build(rows)
    base = len(build([]).encode())
    dropped = 0
    while len(text.encode()) > max_bytes and rows:
        over = len(text.encode()) - max_bytes
        per_row = max(1.0, (len(text.encode()) - base) / float(len(rows)))
        cut = min(len(rows), int(over / per_row) + 1)
        rows, dropped = rows[:-cut], dropped + cut
        text = build(rows)
    return text, {"rev": rev, "items": len(rows), "patterns": len(prows) - ncraft - (1 if crafts else 0), "crafts": ncraft,
                  "vendor": len(vendor), "bytes": len(text.encode()), "dropped": dropped, "captured": captured,
                  "label": label, "market": market}


def craft_data(cfg, items):
    """(vendor prices of the materials, {recipeID: row}, AH cut) for every recipe the characters know (addon 0.8:
    craft cost and profit in the profession window). Read-only on the store; never fails the price write."""
    try:
        from . import crafting, store
        if not os.path.isfile(cfg.db):
            return {}, {}, None
        con = store.connect(cfg.db)
        try:
            return crafting.price_file_rows(con, items, cfg)
        finally:
            con.close()
    except Exception:
        return {}, {}, None


def valid(text):
    lines = text.split("\n")
    if not lines[0].startswith("-- ForeverScribe prices") or "ForeverScribe_PriceData = {" not in lines:
        return False
    return all(LINE_RE.match(l) for l in lines)


# ---------- storage / delivery ----------
def price_dir(cfg=None):
    cfg = cfg or C.load()
    return os.environ.get("FOREVERSCRIBE_PRICE_DIR") or cfg.path("prices")


def _read_json(p):
    try:
        with open(p, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def _atomic(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = os.path.join(os.path.dirname(path), ".%s.tmp.%d.%d" % (os.path.basename(path), os.getpid(), threading.get_ident()))
    with open(tmp, "w", encoding="utf-8", newline="\n") as f:
        f.write(text)
    os.replace(tmp, path)


ADDON = "ForeverScribe_Prices"


def targets(cfg, want="auto"):
    """[(transport, path)]: the addon folder (local), the synced folder, the receiver copy (http)."""
    mode = (cfg.get("transport") or {}).get("mode") or "local"
    folder = C._expand((cfg.get("transport") or {}).get("folder") or "")
    wd = C.wow_dir(cfg)
    out = []
    if want in ("auto", "local", "all") and wd and (mode == "local" or want != "auto"):
        out.append(("local", os.path.join(wd, "Interface", "AddOns", ADDON)))
    if want in ("auto", "folder", "all") and folder:
        out.append(("folder", os.path.join(folder, "_prices", "Prices.lua")))
    if want in ("auto", "http", "all") and (mode == "http" or want != "auto"):
        out.append(("http", os.path.join(price_dir(cfg), "Prices.lua")))
    return out


def receiver_copy(cfg):
    return os.path.join(price_dir(cfg), "Prices.lua")


def write(cfg=None, want="auto", market=None, force=False, now=None, log=None):
    cfg = cfg or C.load()
    s = ah.settings(cfg)
    if not s["enabled"]:
        raise Disabled("AH prices are off. Turn them on in config.toml: [ah] enabled = true, wowgg_key, market "
                       "(see `foreverscribe ah --help`).")
    market = market or s["market"]
    if not market:
        raise Disabled("Set [ah] market in config.toml (for example forever.pvp.alliance.us).")
    snap, fresh = fetch_market(s, market, cfg, force=force, log=log)
    now = int(now or time.time())
    ids = [k for k, r in (snap.get("items") or {}).items() if isinstance(r, list) and len(r) > 6 and r[6]]
    vendor, crafts, cut = craft_data(cfg, snap.get("items") or {})
    text, st = render_lua(snap, market, patterns(cfg, ids), now, vendor=vendor, crafts=crafts, cut=cut)
    if not valid(text):
        raise ValueError("internal: price file failed its own validation")
    prev = (_read_json(os.path.join(price_dir(cfg), "written.json")) or {})
    done, notes = [], []
    def put(path):  # unchanged data (same rev) is not rewritten: synced folders stay quiet
        if file_rev(path) != st["rev"]:
            _atomic(path, text)

    for kind, path in targets(cfg, want):
        if kind == "local":
            if os.path.isfile(os.path.join(path, ADDON + ".toc")):
                put(os.path.join(path, "Prices.lua"))
                done.append({"transport": "local", "path": os.path.join(path, "Prices.lua")})
            else:
                notes.append("%s is not installed in %s: install ForeverScribe 0.6 there and restart the game" % (ADDON, os.path.dirname(path)))
        else:
            try:
                put(path)
                done.append({"transport": kind, "path": path})
            except OSError as e:  # one unwritable target (e.g. a cloud folder a background agent may not touch)
                notes.append("%s copy not written (%s): %s" % (kind, path, e))  # must not block the others
                if log:
                    log("prices: %s copy skipped: %s" % (kind, e))
    if receiver_copy(cfg) not in [d["path"] for d in done]:
        put(receiver_copy(cfg))  # the receiver serves this copy (http mode); also `prices status`
    st.update(written_at=now, written_to=done, notes=notes, fetched=fresh, scan=snap.get("capturedAt"),
              unchanged=prev.get("rev") == st["rev"])
    _atomic(os.path.join(price_dir(cfg), "written.json"), json.dumps(st))
    if not done:
        raise ValueError("nowhere to deliver the prices: " + ("; ".join(notes) or
                         "set transport.mode (local with wow.dir, folder, or http) with `foreverscribe setup`"))
    return st


def file_rev(path):
    try:
        with open(path, "rb") as f:
            m = re.search(rb'\trev = "([\w.\-]+)"', f.read(4096))
        return m.group(1).decode() if m else ""
    except OSError:
        return ""


def pickup(cfg=None):
    return _read_json(os.path.join(price_dir(cfg), "pickup.json")) or {}


def status(cfg=None):
    cfg = cfg or C.load()
    w = _read_json(os.path.join(price_dir(cfg), "written.json")) or {}
    s = ah.settings(cfg)
    return {"enabled": s["enabled"], "market": s["market"], "written": w, "picked_up": pickup(cfg)}


def _ago(t):
    d = int(time.time() - t)
    return "%ds" % d if d < 90 else "%dm" % (d // 60) if d < 5400 else "%.1fh" % (d / 3600.0)


def render_status(st):
    if not st["enabled"]:
        return "AH prices are off ([ah] enabled = false). Nothing is written."
    w = st["written"]
    if not w.get("rev"):
        return "No price file written yet for %s (`foreverscribe prices write`)." % (st["market"] or "?")
    lines = ["%s: %d items, %d recipes, %d KB, scan %s (%s ago), written %s ago" % (
        w["market"], w["items"], w.get("patterns", 0), w["bytes"] // 1024, w.get("scan"), _ago(w["captured"]), _ago(w["written_at"]))]
    for t in w.get("written_to") or []:
        lines.append("  %s: %s" % (t["transport"], t["path"]))
    p = st["picked_up"]
    if p.get("rev"):
        lines.append("game computer fetched %s %s ago%s" % (p["rev"], _ago(p["at"]), "" if p["rev"] == w["rev"] else " (an older file)"))
    lines.append("In game the tooltip uses the file loaded at login or the last /reload.")
    return "\n".join(lines)


# ---------- background refresh (receiver) ----------
_LOCK = threading.Lock()
_STATE = {"running": False, "last_try": 0}


def refresh_async(cfg, log=None, min_age=REFRESH_SECONDS):
    """Rebuild the receiver copy in a thread when it is older than min_age. Returns True when a refresh started."""
    if not ah.settings(cfg)["enabled"]:
        return False
    w = _read_json(os.path.join(price_dir(cfg), "written.json")) or {}
    age = time.time() - (w.get("written_at") or 0) if os.path.isfile(receiver_copy(cfg)) else float("inf")
    with _LOCK:
        if _STATE["running"] or age < min_age or time.time() - _STATE["last_try"] < 300:
            return False
        _STATE["running"], _STATE["last_try"] = True, time.time()

    def run():
        try:
            st = write(cfg, want="auto", log=log)
            if log:
                log("prices: %s rev %s, %d items, %d KB" % ("refreshed" if not st["unchanged"] else "unchanged",
                                                            st["rev"], st["items"], st["bytes"] // 1024))
        except Exception as e:  # never take the receiver down
            if log:
                log("prices: refresh failed: %s" % e)
        finally:
            with _LOCK:
                _STATE["running"] = False

    threading.Thread(target=run, name="fs-prices", daemon=True).start()
    return True


# ---------- CLI ----------
def main(argv=None):
    a = list(sys.argv[1:] if argv is None else argv)
    opt = {"to": "auto", "market": None, "force": False, "json": False, "every": 30}
    words = []
    while a:
        x = a.pop(0)
        if x == "--to" and a:
            opt["to"] = a.pop(0)
        elif x == "--market" and a:
            opt["market"] = a.pop(0)
        elif x == "--every" and a:
            opt["every"] = max(10, int(a.pop(0)))
        elif x == "--force":
            opt["force"] = True
        elif x == "--json":
            opt["json"] = True
        elif x in ("-h", "--help"):
            print(__doc__)
            return 0
        else:
            words.append(x)
    cmd = words[0] if words else "status"
    cfg = C.load()
    try:
        if cmd == "write":
            st = write(cfg, opt["to"], opt["market"], opt["force"])
            if opt["json"]:
                print(json.dumps(st, indent=2))
            else:
                print("Prices for %s: %d items, %d recipes, %d KB (scan %s, rev %s%s)" % (
                    st["market"], st["items"], st["patterns"], st["bytes"] // 1024, st["scan"], st["rev"],
                    ", unchanged" if st["unchanged"] else ""))
                for t in st["written_to"]:
                    print("  %s: %s" % (t["transport"], t["path"]))
                for n in st["notes"]:
                    print("  note: " + n)
                print("In game: prices load at login or /reload; hover any item (hold Shift for details).")
        elif cmd == "status":
            st = status(cfg)
            print(json.dumps(st, indent=2) if opt["json"] else render_status(st))
        elif cmd == "watch":
            print("writing prices every %d min (Ctrl-C stops)" % opt["every"], flush=True)
            while True:
                try:
                    st = write(cfg, opt["to"], opt["market"])
                    print("%s %s rev %s, %d items" % (time.strftime("%H:%M"), "unchanged" if st["unchanged"] else "new",
                                                     st["rev"], st["items"]), flush=True)
                except (Disabled, ValueError, OSError, urllib.error.URLError) as e:
                    print("%s %s" % (time.strftime("%H:%M"), e), flush=True)
                time.sleep(opt["every"] * 60)
        else:
            print(__doc__)
            return 2
    except Disabled as e:
        print(str(e))
        return 6
    except (ValueError, urllib.error.URLError, OSError) as e:
        print(str(e))
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())

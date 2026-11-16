"""WoW: Forever auction-house prices from wow.gg (data by AHledger). Off unless you turn it on.

  foreverscribe ah <item name or id> [...]      price line per item
  foreverscribe ah --market forever.normal.alliance.us <item>
  foreverscribe ah --json <item>

Why it is off by default: wow.gg has no public API. Its website calls a backend with an API key
that ships in its own front-end bundle. Using it is your choice and your responsibility: set
[ah] enabled = true, wowgg_key = "<key from the wow.gg page>" and market = "<your realm market>"
in config.toml. Keep it personal and low-volume; answers are cached for 30 minutes.

Prices are copper. Line: min buyout, current median, 7d/30d median, qty listed, other-faction median.
Attribution: "Prices: AHledger via wow.gg".
"""
import json
import os
import re
import sys
import time
import urllib.parse
import urllib.request

from . import config as C

BASE = "https://wowbackend-production.up.railway.app/api/forever/ah"
TTL = 1800


class Disabled(RuntimeError):
    pass


def settings(cfg=None):
    cfg = cfg or C.load()
    a = cfg.section("ah")
    key = os.environ.get("WOWGG_KEY") or a.get("wowgg_key") or ""
    enabled = bool(a.get("enabled")) or bool(os.environ.get("WOWGG_KEY"))
    return {"enabled": enabled and bool(key), "key": key, "market": a.get("market") or "",
            "cache": os.path.join(cfg.data_dir, "ah-cache")}


def headers(key):
    return {"Accept": "application/json", "X-API-Key": key, "Origin": "https://wow.gg",
            "Referer": "https://wow.gg/auction-house/forever", "User-Agent": "Mozilla/5.0 (ForeverScribe personal)"}


def _get(s, params):
    os.makedirs(s["cache"], exist_ok=True)
    qs = urllib.parse.urlencode(params)
    p = os.path.join(s["cache"], re.sub(r"[^A-Za-z0-9_.=-]", "_", qs)[:180] + ".json")
    if os.path.exists(p) and time.time() - os.path.getmtime(p) < TTL:
        with open(p) as f:
            return json.load(f)
    req = urllib.request.Request(BASE + "?" + qs, headers=headers(s["key"]))
    with urllib.request.urlopen(req, timeout=20) as r:
        d = json.load(r)
    with open(p, "w") as f:
        json.dump(d, f)
    return d


def money(c):
    if c is None:
        return "-"
    c = int(c)
    g, s, cu = c // 10000, (c // 100) % 100, c % 100
    return ("%dg " % g if g else "") + ("%ds " % s if g or s else "") + "%dc" % cu


def lookup(term, market=None, s=None):
    s = s or settings()
    if not s["enabled"]:
        raise Disabled("AH prices are off. Turn them on in config.toml: [ah] enabled = true, wowgg_key, market "
                       "(see `foreverscribe ah --help`).")
    market = market or s["market"]
    if not market:
        raise Disabled("Set [ah] market in config.toml (for example forever.pvp.alliance.us).")
    d = _get(s, {"market": market, "q": str(term), "sort": "name", "dir": "asc", "page": 1, "per": 10, "locale": "en"})
    rows = d.get("rows") or []
    t = str(term).strip().lower()
    exact = [r for r in rows if str(r.get("itemId")) == t or (r.get("name") or "").lower() == t]
    return (exact or rows), d.get("capturedAt")


def line(r):
    o = r.get("other") or {}
    return "%s [%s]: min %s | median %s | 7d %s | 30d %s | qty %s | other faction median %s" % (
        r.get("name"), r.get("itemId"), money(r.get("minBuyout")), money(r.get("median")), money(r.get("median7d")),
        money(r.get("median30d")), r.get("quantity"), money(o.get("median")))


def main(a=None):
    a = list(sys.argv[1:] if a is None else a)
    market, as_json = None, False
    if "--market" in a:
        i = a.index("--market")
        market = a[i + 1]
        del a[i:i + 2]
    if "--json" in a:
        a.remove("--json")
        as_json = True
    if not a or a[0] in ("-h", "--help"):
        print(__doc__)
        return 0
    s = settings()
    out = []
    try:
        for term in a:
            rows, cap = lookup(term, market, s)
            if as_json:
                out.append({"term": term, "capturedAt": cap,
                            "rows": [{k: v for k, v in r.items() if k != "historyPoints"} for r in rows[:5]]})
                continue
            print("# %s (%s, scan %s)" % (term, market or s["market"], cap))
            for r in rows[:5]:
                print(line(r))
            if not rows:
                print("no listings found")
    except Disabled as e:
        if as_json:
            print(json.dumps({"disabled": True, "error": str(e)}))
        else:
            print(str(e))
        return 6
    if as_json:
        print(json.dumps(out, indent=1))
    else:
        print("Prices: AHledger via wow.gg")
    return 0


if __name__ == "__main__":
    sys.exit(main())

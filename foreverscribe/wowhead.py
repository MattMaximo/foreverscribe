"""Wowhead WoW: Forever lookups for the gameplay advisor. Forever data only (/forever/...). Stdlib only.

  item <id> [...]            stats, slot, level req, source; patterns -> crafted item, skill, rep, reagents
  rate <id> [...]            score items against what the character wears in that slot (spec-aware)
  gear                       equipped gear scored, weakest slots first, empty slots flagged
  vendor <npcID>             vendor list judged for the character: upgrades, known, skill/rep/currency gates
  craft <recipeItemID> [...] crafted item vs worn, skill gate, mats have/need, AH cost of mats (via ah.py)
  aca [text]                 Azeroth Commerce Authority favor vendors (from the Wowhead guide)
  page <url|path> [--rate]   rows of any Wowhead Forever list page (drops, search, filters, currency)
  npc|quest|zone|spell <id>  one-line tooltip
  weights                    detected spec and the stat weights used for scoring

Options: --for CHAR (default: most recently seen), --all, --top N, --grep TEXT, --max-req LEVEL, --refresh

Sources. nether.wowhead.com tooltips are fetched here (cached 7 days). www.wowhead.com pages are NOT fetched
here: the site challenges scripted clients, so the agent fetches the page with its own web tool and this
command parses the saved markdown. When a page is missing the command prints one NEED line (exit 3):
  Hermes: web_extract(urls=[...]) saves into ~/.hermes/cache/web, which is read automatically.
  Any other agent: fetch the URL as markdown, then `foreverscribe wowhead import-page <url> <file|->`.
Forever hides item stats on Wowhead until someone discovers them: no stats means unknown, not zero.
Scores are a heuristic (see `weights`); label them inference when answering.
"""
import glob
import html
import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.request

from . import config as _C

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
_CFG = _C.load()
_WH = _CFG.section("wowhead")
CACHE = _C._expand(_WH.get("cache_dir") or "") or os.path.join(_CFG.data_dir, "wowhead-cache")
PAGES = os.path.join(CACHE, "pages")
IMPORTED = _C._expand(_WH.get("page_dir") or "") or os.path.join(CACHE, "imported")
# Markdown copies of www.wowhead.com pages: our own import dir, the Hermes web_extract cache, any extra dirs.
WEB_CACHES = [IMPORTED] + [d for d in [os.environ.get("WOWHEAD_WEB_CACHE"), os.path.expanduser("~/.hermes/cache/web")] if d] \
    + [_C._expand(d) for d in (_WH.get("extra_page_dirs") or [])]
UA = {"User-Agent": "Mozilla/5.0 (ForeverScribe; personal use)"}
TTL = 7 * 86400
WWW = "https://www.wowhead.com/forever/"
ACA_GUIDE = WWW + "guide/azeroth-commerce-authority-reputation-professions"
OPT = {"for": None, "all": False, "top": 12, "grep": None, "max-req": None, "refresh": False, "rate": False}


# ---------- tooltip API (direct, cached, polite) ----------
def tooltip(kind, eid):
    os.makedirs(CACHE, exist_ok=True)
    p = os.path.join(CACHE, "%s-%s.json" % (kind, eid))
    if os.path.exists(p) and time.time() - os.path.getmtime(p) < TTL:
        with open(p, encoding="utf-8") as f:
            return json.load(f)
    url = "https://nether.wowhead.com/forever/tooltip/%s/%s" % (kind, eid)
    try:
        with urllib.request.urlopen(urllib.request.Request(url, headers=UA), timeout=20) as r:
            d = json.loads(r.read().decode("utf-8", "replace"))
    except urllib.error.HTTPError as e:
        return {"error": "HTTP %s" % e.code}
    except (urllib.error.URLError, OSError, ValueError) as e:
        return {"error": str(e)}
    with open(p, "w", encoding="utf-8") as f:
        json.dump(d, f)
    time.sleep(0.25)
    return d


def _lines(tip):
    t = re.sub(r"<!--.*?-->", "", tip, flags=re.S)
    t = re.sub(r"</td>\s*<th>", " | ", t)
    t = re.sub(r"<br\s*/?>|<table[^>]*>|</(tr|table|div)>|<div[^>]*>", "\n", t)
    t = html.unescape(re.sub(r"<[^>]+>", " ", t))
    return [l for l in (re.sub(r"\s+", " ", x).strip() for x in t.split("\n")) if l]


HEAL_DMG = r"healing done by up to (\d+) and damage done by up to (\d+) for all magical"
STAT = [
    (r"^\+?(\d+) Stamina", "sta"), (r"^\+?(\d+) Intellect", "int"), (r"^\+?(\d+) Spirit", "spi"),
    (r"^\+?(\d+) Agility", "agi"), (r"^\+?(\d+) Strength", "str"), (r"^(\d+) Armor", "armor"),
    (r"damage and healing done by magical spells and effects by up to (\d+)", "sp"),
    (r"damage done by (\w+) spells and effects by up to (\d+)", "school"),
    (r"healing done by spells and effects by up to (\d+)", "heal"),
    (r"Restores \+? ?(\d+) mana per 5 sec", "mp5"), (r"Restores \+? ?(\d+) health per 5 sec", "hp5"),
    (r"critical strike with spells by (\d+)%", "spellcrit"), (r"chance to hit with spells by (\d+)%", "spellhit"),
    (r"critical strike by (\d+)%", "crit"), (r"chance to hit by (\d+)%", "hit"),
    (r"\+(\d+) Attack Power", "ap"), (r"\+(\d+) Ranged Attack Power", "rap"),
    (r"Increased Defense \+(\d+)", "defense"), (r"\((\d+(?:\.\d+)?) damage per second\)", "dps"),
]
SLOTS = {"head": "head", "neck": "neck", "shoulder": "shoulder", "back": "back", "chest": "chest", "shirt": "shirt",
         "wrist": "wrist", "hands": "hands", "waist": "waist", "legs": "legs", "feet": "feet", "finger": "finger",
         "trinket": "trinket", "main hand": "mainhand", "one-hand": "mainhand", "two-hand": "twohand",
         "off hand": "offhand", "held in off-hand": "offhand", "ranged": "ranged", "thrown": "ranged",
         "relic": "ranged", "tabard": "tabard"}
RECIPE_PREFIX = ("Pattern:", "Recipe:", "Plans:", "Schematic:", "Formula:", "Manual:", "Design:")
QUALITY = ["poor", "common", "uncommon", "rare", "epic", "legendary"]


def parse_stats(lines):
    st, other = {}, []
    for l in lines:
        hit = False
        m = re.search(HEAL_DMG, l, re.I)
        if m:
            st["heal"] = st.get("heal", 0) + float(m.group(1))
            st["sp"] = st.get("sp", 0) + float(m.group(2))
            continue
        for rx, key in STAT:
            m = re.search(rx, l, re.I)
            if not m:
                continue
            if key == "school" and m.group(1).lower() == "magical":
                st["sp"] = st.get("sp", 0) + float(m.group(2))
            elif key == "school":
                st[m.group(1).lower()] = st.get(m.group(1).lower(), 0) + float(m.group(2))
            else:
                st[key] = st.get(key, 0) + float(m.group(1))
            hit = True
            break
        if not hit and re.match(r"^(Equip|Use|Chance on hit|Set):", l):
            other.append(l)
    return st, other


def item(iid, follow=True):
    d = tooltip("item", iid)
    if d.get("error"):
        return {"id": int(iid), "name": "item %s" % iid, "error": d["error"]}
    tip = d.get("tooltip", "")
    lines = _lines(tip)
    it = {"id": int(iid), "name": d.get("name"), "quality": QUALITY[d["quality"]] if d.get("quality", 9) < 6 else "?"}
    if (it["name"] or "").startswith(RECIPE_PREFIX):
        head = tip.split('<span class="q3">', 1)[0] if 'class="whtt-sellprice"' in tip else tip
        hl = _lines(tip.split("whtt-sellprice", 1)[0])
        t = {"reagents": []}
        for l in hl:
            m = re.match(r"^Requires ([A-Z][\w' ]+?) \((\d+)\)$", l)
            if m:
                t["skill"] = [m.group(1), int(m.group(2))]
            m = re.match(r"^Requires (.+) - (Neutral|Friendly|Honored|Revered|Exalted)$", l)
            if m:
                t["rep"] = [m.group(1), m.group(2)]
            m = re.match(r"^Requires (Friendly|Honored|Revered|Exalted) with this faction", l)
            if m:
                t["rep"] = ["", m.group(1)]
        m = re.search(r'</div>.*?href="/forever/item=(\d+)/', tip, re.S) or re.search(r'href="/forever/item=(\d+)/', head)
        if m:
            t["creates"] = int(m.group(1))
        rg = re.search(r'whtt-reagents.*?</div>', tip, re.S)
        if rg:
            for a in re.finditer(r'item=(\d+)/[^"]*">([^<]+)</a>(?:&nbsp;\((\d+)\))?', rg.group(0)):
                t["reagents"].append([int(a.group(1)), html.unescape(a.group(2)), int(a.group(3) or 1)])
        it["teaches"] = t
        if follow and t.get("creates"):
            it["crafted"] = item(t["creates"], follow=False)
        return it
    for l in lines[1:6]:
        parts = [x.strip() for x in l.split("|")]
        if parts[0].lower() in SLOTS:
            it["slot"], it["type"] = SLOTS[parts[0].lower()], (parts[1] if len(parts) > 1 else "")
    for l in lines:
        m = re.match(r"^Requires Level (\d+)", l)
        if m:
            it["req"] = int(m.group(1))
        m = re.match(r"^Item Level (\d+)", l)
        if m:
            it["ilvl"] = int(m.group(1))
        m = re.match(r"^Requires (.+) - (Neutral|Friendly|Honored|Revered|Exalted)$", l)
        if m:
            it["rep"] = [m.group(1), m.group(2)]
        if re.match(r"^(Dropped by|Drop Chance|Sold by|Quest|Classes|Unique)", l):
            it.setdefault("src", []).append(l)
    it["bind"] = "BoP" if "Binds when picked up" in tip else "BoE" if "Binds when equipped" in tip else ""
    it["stats"], it["effects"] = parse_stats(lines)
    it["random"] = "Random enchantment" in tip
    it["unknown"] = bool(it.get("slot")) and not it["stats"].keys() - {"armor", "dps"} and not it["effects"] and not it["random"]
    return it


def fmt_stats(st):
    order = ["sp", "frost", "fire", "arcane", "shadow", "holy", "nature", "heal", "int", "sta", "spi", "agi", "str",
             "mp5", "spellcrit", "spellhit", "crit", "hit", "ap", "armor"]
    keys = [k for k in order if k in st] + [k for k in st if k not in order and k != "dps"]
    return ", ".join("%g %s" % (st[k], k) for k in keys) or "-"


def fmt_item(it):
    if it.get("error"):
        return "%s: %s" % (it["id"], it["error"])
    if it.get("teaches"):
        t = it["teaches"]
        s = "%s [%s]" % (it["name"], it["id"])
        if t.get("skill"):
            s += " needs %s %d" % tuple(t["skill"])
        if t.get("rep"):
            s += ", %s with %s" % (t["rep"][1], t["rep"][0] or "the vendor's faction")
        if it.get("crafted"):
            s += "\n  makes " + fmt_item(it["crafted"])
        if t["reagents"]:
            s += "\n  mats " + ", ".join("%dx %s" % (q, n) for _, n, q in t["reagents"])
        return s
    s = "%s [%s] %s %s%s%s req %s: " % (it["name"], it["id"], it.get("quality", ""), it.get("slot", "non-equip"),
                                        "/" + it["type"] if it.get("type") else "", " " + it["bind"] if it.get("bind") else "",
                                        it.get("req", "-"))
    s += "RANDOM SUFFIX (stats vary)" if it.get("random") else "STATS UNKNOWN on Wowhead" if it.get("unknown") else fmt_stats(it.get("stats", {}))
    if it.get("effects"):
        s += " | " + " / ".join(e[:110 if it.get("slot") else 320] for e in it["effects"])
    if it.get("src"):
        s += " | " + "; ".join(it["src"])
    return s


# ---------- character telemetry (ForeverScribe) ----------
_SC = {}


def scribe(*args):
    key = " ".join(args)
    if key not in _SC:
        cmd = [sys.executable, "-m", "foreverscribe", "--json", "--no-ingest"] + (["--char", OPT["for"]] if OPT["for"] else []) + list(args)
        try:
            _SC[key] = json.loads(subprocess.run(cmd, capture_output=True, text=True, timeout=60, cwd=ROOT,
                                                 env=dict(os.environ, PYTHONPATH=ROOT)).stdout)
        except (ValueError, OSError, subprocess.SubprocessError):
            _SC[key] = {}
    return _SC[key]


TEL = {"stamina": "sta", "intellect": "int", "spirit": "spi", "agility": "agi", "strength": "str",
       "spell_power": "sp", "mana_regeneration": "mp5", "health_regeneration": "hp5", "resistance0_name": "armor",
       "attack_power": "ap", "damage_per_second": "dps", "crit_spell_rating": "spellcrit", "hit_spell_rating": "spellhit",
       "crit_rating": "crit", "hit_rating": "hit", "spell_healing_done": "heal"}


def worn():
    out = {}
    for e in scribe("equipment").get("equipped", []):
        st = {}
        for k, v in (e.get("stats") or {}).items():
            k = re.sub(r"^item_mod_|_short$", "", k.lower())
            m = re.match(r"^(\w+)_damage_done$", k)
            k = m.group(1) if m else TEL.get(k, k)
            if isinstance(v, (int, float)):
                st[k] = st.get(k, 0) + v
        out[e.get("slot")] = {"name": e.get("name"), "id": e.get("itemID"), "stats": st, "req": e.get("reqLevel")}
    return out


CASTER = {"MAGE": {"Frost": "frost", "Fire": "fire", "Arcane": "arcane"},
          "WARLOCK": {"Affliction": "shadow", "Demonology": "shadow", "Destruction": "shadow"},
          "PRIEST": {"Shadow": "shadow", "Holy": "heal", "Discipline": "heal"},
          "DRUID": {"Balance": "nature", "Restoration": "heal"},
          "SHAMAN": {"Elemental": "nature", "Restoration": "heal"}, "PALADIN": {"Holy": "heal"}}


def spec():
    st = scribe("state")
    cls = (st.get("class") or "").upper()
    if not cls:
        sys.exit("No telemetry for character %r. Run `scribe characters`; do not guess a spec." % (OPT.get("for") or "default"))
    pts = {}
    for tr in scribe("talents").get("trees", []):
        for t in tr.get("taken", []):
            m = re.match(r".* (\d+)/\d+ \[(.+)\]$", t)
            if m:
                pts[m.group(2)] = pts.get(m.group(2), 0) + int(m.group(1))
    tab = max(pts, key=pts.get) if pts else None
    school = CASTER.get(cls, {}).get(tab) or (list(CASTER[cls].values())[0] if cls in CASTER and not tab else None)
    if school == "heal":
        w = {"heal": 1, "sp": 1, "int": 0.6, "spi": 0.5, "mp5": 2, "sta": 0.2, "spellcrit": 4}
    elif school:
        w = {school: 1, "sp": 1, "int": 0.5, "sta": 0.3, "spi": 0.15, "mp5": 0.8, "spellcrit": 6, "spellhit": 6}
    elif cls in ("HUNTER", "ROGUE") or (cls, tab) in (("DRUID", "Feral Combat"), ("SHAMAN", "Enhancement")):
        w = {"agi": 1, "ap": 0.5, "rap": 0.5, "str": 0.5, "sta": 0.4, "crit": 10, "hit": 10, "dps": 2}
    else:
        w = {"str": 1, "ap": 0.5, "agi": 0.6, "sta": 0.5, "crit": 10, "hit": 10, "dps": 2, "armor": 0.02}
    return {"class": cls, "level": st.get("level"), "tab": tab, "points": pts, "school": school, "w": w,
            "char": st.get("character"), "at": scribe("equipment").get("captured_at")}


CLOTH_ONLY = {"MAGE", "PRIEST", "WARLOCK"}
WEAPON_OK = {"MAGE": {"Staff", "Dagger", "Sword", "Wand"}, "WARLOCK": {"Staff", "Dagger", "Sword", "Wand"},
             "PRIEST": {"Staff", "Dagger", "Mace", "Wand"}}


def unusable(it, sp):
    """Reason a class cannot equip it (Classic proficiency rules; only applied where certain), else None."""
    cls, typ = sp.get("class"), (it.get("type") or "").strip()
    for l in it.get("src", []):
        if l.startswith("Classes:") and cls.title() not in l:
            return "class-locked (%s)" % l
    if it.get("slot") in ("mainhand", "twohand", "ranged") and cls in WEAPON_OK and typ and typ not in WEAPON_OK[cls]:
        return "%s not usable by %s" % (typ, cls.title())
    if typ in ("Leather", "Mail", "Plate") and cls in CLOTH_ONLY:
        return "%s armor" % typ
    if typ == "Shield" and cls not in ("WARRIOR", "PALADIN", "SHAMAN"):
        return "shield"
    return None


def score(st, w):
    return sum(v * w.get(k, 0) for k, v in st.items())


def versus(it, sp, eq):
    """(delta, text) of an item against the worn slot; None when it cannot be compared."""
    slot = it.get("slot")
    bad = unusable(it, sp) if slot else None
    if bad:
        return None, bad
    if not slot or it.get("random") or it.get("unknown"):
        return None, "random suffix" if it.get("random") else "stats unknown" if it.get("unknown") else "not gear"
    if slot in ("finger", "trinket"):
        cur = [eq.get(slot + n) for n in "12"]
        if None in cur:
            cur = None
        else:
            cur = min(cur, key=lambda c: score(c["stats"], sp["w"]))
    elif slot == "twohand":
        a, b = eq.get("mainhand"), eq.get("offhand")
        cur = {"name": " + ".join(x["name"] for x in (a, b) if x), "stats": {}} if a or b else None
        for x in (a, b):
            for k, v in (x or {}).get("stats", {}).items():
                cur["stats"][k] = cur["stats"].get(k, 0) + v
    else:
        cur = eq.get(slot)
    new, old = score(it["stats"], sp["w"]), score(cur["stats"], sp["w"]) if cur else 0
    keys = [k for k in list(it["stats"]) + list((cur or {}).get("stats", {})) if k in sp["w"] or k in ("int", "sta", "spi")]
    diff = []
    for k in dict.fromkeys(keys):
        dv = it["stats"].get(k, 0) - (cur or {}).get("stats", {}).get(k, 0)
        if dv:
            diff.append("%+g %s" % (dv, k))
    return new - old, "vs %s: %s" % (cur["name"] if cur else "EMPTY SLOT", ", ".join(diff) or "same")


# ---------- www pages (saved by web_extract, parsed here) ----------
def page_key(url):
    u = url.split("#")[0]
    u = re.sub(r"^https?://www\.wowhead\.com/forever/", "", u)
    u = re.sub(r"(=\d+)/[a-z0-9-]+$", r"\1", u.strip("/")).lower()
    path, _, qs = u.partition("?")
    seg = path.split("/")
    return "/".join([x for x in seg if ":" not in x] + sorted(x for x in seg if ":" in x)) + ("?" + qs if qs else "")


class Missing(Exception):
    pass


def need(url):
    if OPT.get("_soft"):
        raise Missing(url)
    print('NEED web_extract(urls=["%s"], char_limit=2000) then re-run this command '
          '(no web_extract? fetch it as markdown and pipe it to `foreverscribe wowhead import-page <url> -`)' % url)
    sys.exit(3)


def try_page(arg):
    OPT["_soft"] = True
    try:
        return find_page(arg)
    except Missing:
        return None
    finally:
        OPT["_soft"] = False


def find_page(arg):
    if os.path.isfile(arg):
        return parse_md(open(arg, encoding="utf-8").read(), arg, os.path.getmtime(arg))
    url = arg if arg.startswith("http") else WWW + arg.lstrip("/")
    key = page_key(url)
    os.makedirs(PAGES, exist_ok=True)
    own = os.path.join(PAGES, re.sub(r"[^a-z0-9_.=-]", "_", key)[:150] + ".json")
    files = sorted((f for d in WEB_CACHES for f in glob.glob(os.path.join(d, "www.wowhead.com-*.md"))),
                   key=os.path.getmtime, reverse=True)
    newest = None
    for f in files:
        with open(f, encoding="utf-8", errors="replace") as fh:
            m = re.search(r"\]\((https://www\.wowhead\.com/forever/[^)#\s]+)", fh.read(600))
        if m and page_key(m.group(1)) == key:
            newest = f
            break
    if os.path.exists(own) and not OPT["refresh"]:
        age = time.time() - os.path.getmtime(own)
        if age < TTL and not (newest and os.path.getmtime(newest) > os.path.getmtime(own)):
            with open(own, encoding="utf-8") as fh:
                return json.load(fh)
    if not newest or (OPT["refresh"] and time.time() - os.path.getmtime(newest) > 600):
        need(url)
    pg = parse_md(open(newest, encoding="utf-8", errors="replace").read(), url, os.path.getmtime(newest))
    with open(own, "w", encoding="utf-8") as fh:
        json.dump(pg, fh)
    return pg


LINK = re.compile(r"\[((?:!\[[^\]]*\]\([^)]*\))?[^\]]*)\]\(https://www\.wowhead\.com/forever/(item|quest|npc|spell|object|zone)=(\d+)[^)]*\)")


def parse_md(md, url, mtime):
    rows, header, sold, seen, notes = [], None, None, set(), []
    for l in md.split("\n"):
        if not l.startswith("|") and len(notes) < 60 and re.search(r"\d[\d,]* (?:\S+ )?!?\[?Merchant's Favor|reputation", l):
            c = re.sub(r"\s+", " ", re.sub(r"\[([^\]]*)\]\([^)]*\)", r"\1", re.sub(r"!\[[^\]]*\]\([^)]*\)", "", l))).strip(" -")
            if 20 < len(c) < 400:
                notes.append(c)
        m = re.search(r"\*\*Sold by:\*\*\s*\[([^\]]+)\]\([^)]*npc=(\d+)", l)
        if m:
            sold = [int(m.group(2)), m.group(1)]
        if l.startswith("#"):
            sold = None
        if not l.startswith("|"):
            continue
        cells = [c.strip() for c in l.strip().strip("|").split("|")]
        if re.match(r"^\|[\s|:-]+\|$", l.strip()):
            continue
        m = LINK.search(l)
        if not m:
            hdr = [re.sub(r"[*_]", "", c) for c in cells]
            if any(h in ("Name", "Item") for h in hdr):
                header = hdr
            continue
        name = re.sub(r"!\[[^\]]*\]\([^)]*\)", "", m.group(1)).strip()
        r = {"type": m.group(2), "id": int(m.group(3)), "name": html.unescape(name)}
        if (r["type"], r["id"]) in seen:
            continue
        seen.add((r["type"], r["id"]))
        note = re.search(r"Requires [^|<]+", l[m.end():].split("|")[0])
        if note:
            r["note"] = note.group(0).strip().rstrip(".")
        cost = re.findall(r"\[([\d,]+)\]\(https://www\.wowhead\.com/forever/currency=(\d+)/([a-z0-9-]+)", l)
        if cost:
            r["cost"] = [[int(n.replace(",", "")), int(c), s] for n, c, s in cost]
        body = [c for c in cells if c != "~~~~"]
        if header and "Item" in header and len(cells) == len(header):
            for h, c in zip(header, cells):
                if h == "Skill Required" and c.isdigit():
                    r["skill"] = int(c)
                if h == "Cost" and c.replace(",", "").isdigit():
                    r["cost"] = [[int(c.replace(",", "")), 3402, "merchants-favor"]]
            if sold:
                r["sold_by"] = sold
        elif header:
            n = min(len(header), len(body)) if abs(len(body) - len(header)) <= 1 else 0  # align on the right edge
            for h, c in zip(header[len(header) - n:], body[len(body) - n:]):
                txt = re.sub(r"\[([^\]]*)\]\([^)]*\)", r"\1", c)
                if h in ("ILvl", "Level", "Req.", "Slot") and c and "](" not in c:
                    r[h.lower().strip(".")] = c
                elif h == "Source" and c:
                    r["source"] = " / ".join(dict.fromkeys(x.strip() for x in re.split(r"<br>", txt) if x.strip()))[:80]
                elif h in ("Type", "Category") and c:
                    r["cat"] = txt
                elif h == "Cost" and not r.get("cost") and txt.replace(",", "").isdigit():
                    r["cost"] = [[int(txt.replace(",", "")), 0, "copper"]]
                elif h == "Skill" and re.search(r"\((\d+)\)", txt):
                    r["skill"], r["prof"] = int(re.search(r"\((\d+)\)", txt).group(1)), txt.split(" (")[0].strip()
                elif h == "Changes" and txt.startswith(("New", "Updated")):
                    r["new"] = "NEW-IN-FOREVER" if txt.startswith("New") else "changed-in-Forever"
        rows.append(r)
    shown = re.search(r"\*\*(\d+)\*\* \\?- \*\*(\d+)\*\* of \*\*(\d+)\*\*", md)
    title = re.search(r"^# (.+)$", md, re.M)
    return {"url": url, "title": title.group(1).strip() if title else "", "fetched": int(mtime), "rows": rows, "notes": notes,
            "shown": [int(x) for x in shown.groups()] if shown else None}


def fmt_row(r):
    s = "%s [%s%s]" % (r["name"], r["type"][0] if r["type"] != "item" else "", r["id"])
    for k in ("ilvl", "level", "req", "slot", "cat", "prof", "skill", "source"):
        if r.get(k):
            s += " %s %s" % (k, r[k])
    if r.get("cost"):
        s += " cost " + price_txt(r["cost"])
    if r.get("note"):
        s += " (%s)" % r["note"]
    if r.get("new"):
        s += " " + str(r["new"])
    if r.get("sold_by"):
        s += " @%s" % r["sold_by"][1]
    return s


def stamp(pg):
    sh = pg.get("shown")
    part = " | PARTIAL: rows %d-%d of %d" % tuple(sh) if sh and sh[2] > sh[1] - sh[0] + 1 else ""
    return "# %s | %d rows | fetched %s%s | %s" % (pg["title"][:60], len(pg["rows"]),
                                                  time.strftime("%Y-%m-%d %H:%M", time.localtime(pg["fetched"])), part, pg["url"])


# ---------- commands ----------
def rate_items(ids, sp, eq, top=None, max_req=None, quiet_rest=True, srcs=None):
    res = []
    for i in ids:
        it = item(i)
        if it.get("crafted"):
            it = it["crafted"]
        row = (srcs or {}).get(int(i)) or {}
        if row.get("source") and not any(x.startswith("Dropped") for x in it.get("src", [])):
            it.setdefault("src", []).append("from " + row["source"])
        if "req" not in it and str(row.get("req", "")).isdigit():
            it["req"] = int(row["req"])
        d, txt = versus(it, sp, eq)
        res.append((d, it, txt))
    lvl = sp.get("level") or 0
    cap = max_req if max_req is not None else lvl + 5
    good = sorted([x for x in res if x[0] is not None and x[0] > 0 and x[1].get("req", 0) <= cap], key=lambda x: -x[0])
    for d, it, txt in good[:top] if top else good:
        flag = "" if it.get("req", 0) <= lvl else " [needs level %d]" % it["req"]
        print("%+.1f %s%s\n      %s" % (d, fmt_item(it), flag, txt))
    rest = [x for x in res if x not in good]
    unk = [x[1]["name"] + (" (random suffix)" if x[1].get("random") else "") for x in rest
           if x[0] is None and x[2] in ("stats unknown", "random suffix")]
    if rest and quiet_rest:
        print("-- %d others: not upgrades, unusable, or need level > %d%s" % (
            len(rest), cap, "; STATS UNKNOWN (check in game): " + ", ".join(dict.fromkeys(unk)) if unk else ""))
    return res


def cmd_gear(sp, eq):
    print("# %s | level %s %s %s %s | gear captured %s" % (sp["char"], sp["level"], sp["tab"] or "no-talents", sp["class"],
                                                         sp["points"], sp["at"]))
    order = ["head", "neck", "shoulder", "back", "chest", "wrist", "hands", "waist", "legs", "feet", "finger1",
             "finger2", "trinket1", "trinket2", "mainhand", "offhand", "ranged"]
    rows = [(score(eq[s]["stats"], sp["w"]) if s in eq else -1, s) for s in order]
    for sc, s in sorted(rows):
        if s not in eq:
            print("EMPTY %-9s" % s)
        else:
            print("%5.1f %-9s %s (req %s): %s" % (sc, s, eq[s]["name"], eq[s].get("req"), fmt_stats(eq[s]["stats"])))
    print("Weakest first. Score weights: %s (heuristic)" % sp["w"])


def wallet():
    cur = {re.sub(r"[^a-z0-9]", "", c["name"].lower()): c["amount"] for c in scribe("currencies").get("currencies", [])}
    rep = {f["faction"]: f for f in scribe("reputation").get("factions", [])}
    profs = {p["name"]: p for p in scribe("professions", "--recipes").get("professions", [])}
    known = {r["name"].lower() for r in scribe("professions", "--recipes").get("recipes", [])}
    ev = scribe("events", "--type", "RECIPE_LEARNED", "--since", "30d", "--limit", "5000")
    for e in ev if isinstance(ev, list) else ev.get("events", []):
        known.add(((e.get("payload") or {}).get("name") or e.get("name") or "").lower())
    bags = {i["name"].lower(): i.get("count", 1) for i in scribe("inventory").get("items", [])}
    return cur, rep, profs, known, bags


RANKS = ["Hated", "Hostile", "Unfriendly", "Neutral", "Friendly", "Honored", "Revered", "Exalted"]


def cmd_vendor(npc, sp, eq):
    npc = int(npc)
    rows, total, fetched, tried = {}, None, 0, []
    for src in ("npc=%d" % npc, ACA_GUIDE, "items/max-level:30?filter=129;0;%d" % npc,
                "items/min-level:31?filter=129;0;%d" % npc, "items?filter=129;0;%d" % npc):
        pg = try_page(src)
        if not pg:
            tried.append(src if src.startswith("http") else WWW + src)
            continue
        guide = src == ACA_GUIDE
        if src.startswith("npc=") and pg.get("shown"):
            total = pg["shown"][2]
        got = 0
        for r in pg["rows"]:
            if r["type"] != "item" or (guide and r.get("sold_by", [0])[0] != npc) or (not guide and not r.get("cost")):
                continue
            got += 1
            cur = rows.setdefault(r["id"], {})
            cur.update({k: v for k, v in r.items() if k not in cur})
        if got:
            fetched = max(fetched, pg["fetched"])
    if not rows:
        need(WWW + "npc=%d" % npc)
    total = max(total or 0, len(rows))
    nt = tooltip("npc", npc)
    cur, rep, profs, known, bags = wallet()
    lvl = sp["level"] or 0
    print("# %s <%s> | %d of %d items loaded | list fetched %s | telemetry %s" % (
        nt.get("name", npc), (_lines(nt.get("tooltip", "")) + ["", ""])[1], len(rows), total,
        time.strftime("%Y-%m-%d %H:%M", time.localtime(fetched)), sp["at"]))
    if len(rows) < total:
        print("PARTIAL LIST. web_extract one of these, then re-run: %s" % tried[:3])
    print("Have: %s | %s | %s" % (", ".join("%s %s" % kv for kv in cur.items()) or "no currencies",
                                  ", ".join("%s %s/%s" % (n, p["rank"], p["max"]) for n, p in profs.items()),
                                  ", ".join("%s %s %s" % (n, f["standing"], f["progress"]) for n, f in rep.items()
                                            if re.search("commerce|logistics", n, re.I)) or "-"))
    buy, soon, later, known_l, nongear, unknown, worse = [], [], [], [], [], [], 0
    for r in rows.values():
        it = item(r["id"])
        t, c = it.get("teaches") or {}, it.get("crafted") or it
        cost, gates = r.get("cost") or [], []
        for n, _, slug in cost:
            have = gold_copper() if slug == "copper" else cur.get(re.sub(r"[^a-z0-9]", "", slug), 0)
            if have < n:
                gates.append("%s short" % (money(n - have) if slug == "copper" else "%d %s" % (n - have, slug)))
        if t.get("skill"):
            p = profs.get(t["skill"][0])
            if not p:
                gates.append("%s not trained" % t["skill"][0])
            elif p["rank"] < t["skill"][1]:
                gates.append("%s %d (have %d%s)" % (t["skill"][0], t["skill"][1], p["rank"],
                                                    ", cap %d: train next rank" % p["max"] if p["max"] < t["skill"][1] else ""))
        rp = t.get("rep") or it.get("rep")
        if rp and not rp[0]:
            fac = [n for n in rep if re.search("commerce authority|supply (and|&) logistics", n, re.I)]
            if r.get("sold_by") and fac:
                rp = [fac[0], rp[1]]
            else:
                gates.append("%s with the vendor's faction (check scribe reputation)" % rp[1])
                rp = None
        if rp and RANKS.index(rep.get(rp[0], {}).get("standing", "Neutral")) < RANKS.index(rp[1]):
            gates.append("%s with %s (now %s %s)" % (rp[1], rp[0], rep.get(rp[0], {}).get("standing", "?"),
                                                    rep.get(rp[0], {}).get("progress", "")))
        if t and (c.get("name") or "").lower() in known:
            known_l.append(c["name"])
            continue
        d, txt = versus(c, sp, eq)
        price = price_txt(cost) or "price ?"
        if d is None:
            (unknown if txt == "stats unknown" else nongear).append("%s (%s)" % (it["name"], price))
            continue
        if d <= 0:
            worse += 1
            continue
        x = (d, it, c, txt, gates, price)
        if c.get("req", 0) > lvl + 5:
            later.append(x)
        elif gates or c.get("req", 0) > lvl:
            soon.append(x)
        else:
            buy.append(x)

    def show(x):
        d, it, c, txt, gates, price = x
        print("%+.1f %s [%s] %s -> %s\n      %s" % (d, it["name"], it["id"], price, fmt_item(c), txt))
        mats = (it.get("teaches") or {}).get("reagents") or []
        if mats:
            print("      mats (have/need): " + ", ".join("%s %d/%d" % (n, bags.get(n.lower(), 0), q) for _, n, q in mats))
        if c.get("req", 0) > lvl:
            gates = gates + ["wear at level %d" % c["req"]]
        if gates:
            print("      BLOCKED BY: " + "; ".join(gates))
    who = "%s %s" % (sp["tab"] or "", sp["class"])
    print("BUY NOW (affordable, learnable, wearable, upgrade for %s; best first):" % who)
    for x in sorted(buy, key=lambda x: -x[0]):
        show(x)
    if not buy:
        print("  none")
    print("UPGRADES AT YOUR LEVEL BUT BLOCKED:")
    for x in sorted(soon, key=lambda x: -x[0]):
        show(x)
    if not soon:
        print("  none")
    if not OPT["all"]:
        best = {}
        for x in later:
            k = (x[2].get("slot"), x[2].get("req"))
            if k not in best or x[0] > best[k][0]:
                best[k] = x
        later = list(best.values())
    later.sort(key=lambda x: (x[2].get("req", 0), -x[0]))
    lim = None if OPT["all"] else 8
    print("LATER (level %d+), best per slot, by level%s:" % (lvl + 6, "" if OPT["all"] else " (--all for every option)"))
    for d, it, c, txt, gates, price in later[:lim]:
        t = it.get("teaches") or {}
        print("  L%s %s %+.1f (%s%s%s): %s" % (c.get("req"), c["name"], d, price,
                                              ", %s %d" % tuple(t["skill"]) if t.get("skill") else "",
                                              ", %s rep" % t["rep"][1] if t.get("rep") else "", fmt_stats(c["stats"])))
    if len(later) > 8 and not OPT["all"]:
        print("  ... %d more" % (len(later) - 8))
    print("SKIP: already known: %s | %d not an upgrade for %s | stats unknown: %s | not gear: %s" % (
        ", ".join(known_l) or "-", worse, who, ", ".join(unknown[:8]) or "-", ", ".join(nongear[:8]) or "-"))
    bag_recipes(known, profs)


def bag_recipes(known, profs):
    """Unlearned / duplicate recipes sitting in bags: the free wins."""
    for i in scribe("inventory").get("items", []):
        n = i.get("name") or ""
        if not n.startswith(RECIPE_PREFIX):
            continue
        made, iid = n.split(": ", 1)[1], i.get("item_id") or i.get("itemID") or i.get("id")
        if made.lower() in known:
            print("IN BAGS: %s [%s] -> already known: sell (wowhead.py craft / ah.py for price) or mail it" % (n, iid))
            continue
        sk = (item(iid).get("teaches") or {}).get("skill") if iid else None
        gate = ""
        if sk:
            have = (profs.get(sk[0]) or {}).get("rank", 0)
            gate = " (needs %s %d, have %d%s)" % (sk[0], sk[1], have, "" if have >= sk[1] else ": NOT YET")
        print("IN BAGS: %s [%s] -> not learned%s" % (n, iid, gate))


def gold_copper():
    g = re.findall(r"(\d+)([gsc])", str(scribe("state").get("money") or ""))
    return sum(int(n) * {"g": 10000, "s": 100, "c": 1}[u] for n, u in g)


def price_txt(cost):
    return " + ".join(money(n) if slug == "copper" else "%d %s" % (n, slug) for n, _, slug in cost)


def ah_prices(names):
    """name -> (median copper, min copper) from companion/ah.py (wow.gg / AHledger, 30 min cache). {} when unavailable."""
    try:
        p = subprocess.run([sys.executable, "-m", "foreverscribe", "ah", "--json"] + list(names), capture_output=True,
                           text=True, timeout=90, cwd=ROOT, env=dict(os.environ, PYTHONPATH=ROOT))
        if p.stdout.strip().startswith("{"):
            return {}  # AH prices disabled
        out = {}
        for blk in json.loads(p.stdout):
            for r in blk.get("rows", []):
                if r.get("name", "").lower() == blk.get("term", "").lower():
                    out[r["name"].lower()] = (r.get("median") or r.get("minBuyout") or 0, r.get("minBuyout") or 0)
        return out
    except (OSError, ValueError, subprocess.SubprocessError):
        return {}


def money(c):
    c = int(round(c))
    return ("%dg " % (c // 10000) if c >= 10000 else "") + ("%ds " % (c // 100 % 100) if c >= 100 else "") + "%dc" % (c % 100)


def cmd_craft(ids, sp, eq):
    """Is this recipe worth making: delta vs worn, skill gate, mats have/need, AH cost of the missing mats."""
    cur, rep_, profs, known, bags = wallet()
    gold = gold_copper()
    for i in ids:
        it = item(i)
        t, c = it.get("teaches"), it.get("crafted")
        if not t or not c:
            print("%s [%s]: not a recipe item (pass the Pattern/Recipe/Plans id; `page 'search?q=NAME'` finds it)" % (it["name"], i))
            continue
        d, txt = versus(c, sp, eq)
        sk = t.get("skill")
        have = (profs.get(sk[0]) or {}).get("rank", 0) if sk else 0
        print("%s [%s] -> %s" % (it["name"], it["id"], fmt_item(c)))
        print("  %s%s | recipe %s%s" % ("%+.1f " % d if d is not None else "", txt,
                                        "KNOWN" if c["name"].lower() in known else "not known",
                                        " | needs %s %d (have %d%s)" % (sk[0], sk[1], have, "" if have >= sk[1] else ": NOT YET") if sk else ""))
        mats = t.get("reagents") or []
        px = ah_prices([n for _, n, _ in mats] + [it["name"]])
        tot = miss = 0
        parts = []
        for _, n, q in mats:
            h = bags.get(n.lower(), 0)
            m = px.get(n.lower(), (0, 0))[0]
            tot += q * m
            miss += max(0, q - h) * m
            parts.append("%dx %s (have %d) @ %s" % (q, n, h, money(m) if m else "no AH price"))
        print("  mats: " + "; ".join(parts))
        print("  AH cost (median): all mats %s, still to buy %s | you have %s%s" % (
            money(tot), money(miss), money(gold), "" if all(px.get(n.lower()) for _, n, _ in mats) else " | SOME MATS UNPRICED"))
        if px.get(it["name"].lower()):
            print("  the recipe item itself lists for %s median / %s min on the AH" % tuple(money(x) for x in px[it["name"].lower()]))
    print("Prices: AHledger via wow.gg (median, 30 min cache; vendor-sold threads/dyes may be cheaper at a vendor)")


RECIPE_PREFIX_L = tuple(p.lower() for p in RECIPE_PREFIX)


def cmd_aca(text):
    pg = find_page(ACA_GUIDE)
    vend = {}
    for r in pg["rows"]:
        if r.get("sold_by"):
            vend.setdefault(tuple(r["sold_by"]), []).append(r)
    print(stamp(pg))
    profs = {p["name"]: p for p in scribe("professions").get("professions", [])}
    for (nid, name), rs in vend.items():
        hit = [r for r in rs if not text or text.lower() in (r["name"] + " " + name).lower()]
        if text and not hit:
            continue
        prof = ((item(rs[0]["id"]).get("teaches") or {}).get("skill") or ["?"])[0]
        mine = "YOURS: %s %s/%s" % (prof, profs[prof]["rank"], profs[prof]["max"]) if prof in profs else "%s: not one of your professions" % prof
        print("%s [npc %s] %s | %d recipes, favor %d-%d" % (name, nid, mine, len(rs), min(r["cost"][0][0] for r in rs if r.get("cost")),
                                                          max(r["cost"][0][0] for r in rs if r.get("cost"))))
        if text:
            for r in hit[:40]:
                print("   %s [%s] skill %s, %s favor" % (r["name"], r["id"], r.get("skill", "?"), r["cost"][0][0] if r.get("cost") else "?"))
    if not text:
        print("Next: `vendor <npc>` for a vendor of one of your professions; `aca <vendor|recipe|word>` for recipes and rules (kodo, tabard, receipt).")
    if text:  # rewards and prose (mount, pet, tabard, receipts) are not in the vendor tables
        for l in pg.get("notes", []):
            if text.lower() in l.lower():
                print("   note: " + l[:300])


def quests_done():
    """Quest ids this character has completed (read-only look at the telemetry db)."""
    import sqlite3
    try:
        con = sqlite3.connect("file:%s?mode=ro" % _CFG.db, uri=True)
        ck = scribe("state").get("character")
        return {q for (q,) in con.execute("select quest_id from quests_completed where char_key = ?", (ck,))}
    except sqlite3.Error:
        return set()


def cmd_page(arg, sp_eq):
    pg = find_page(arg)
    rows = [r for r in pg["rows"] if not OPT["grep"] or OPT["grep"].lower() in json.dumps(r).lower()]
    print(stamp(pg))
    if any(r["type"] == "quest" for r in rows):  # never suggest a finished quest; too-high quests are noise
        done = quests_done()
        cap = OPT["max-req"]
        keep = [r for r in rows if r["type"] != "quest" or (r["id"] not in done and (
            cap is None or not str(r.get("req", "")).isdigit() or int(r["req"]) <= cap))]
        print("quests: %d already completed by this character hidden%s (telemetry; check `scribe quest <id>` before recommending)" % (
            sum(1 for r in rows if r["type"] == "quest" and r["id"] in done), ", req > %d hidden" % cap if cap is not None else ""))
        rows = keep
    if any(r.get("prof") for r in rows):  # trainer page: what can be learned now
        _, _, profs, known, _ = wallet()
        now, nxt = [], []
        for r in rows:
            p = profs.get(r.get("prof") or "")
            if not p or r["name"].lower() in known or r["name"] == r["prof"]:
                continue
            (now if r["skill"] <= p["rank"] else nxt).append(r)
        print("TRAINER (telemetry: %s). Known recipes hidden." % ", ".join("%s %s/%s" % (n, p["rank"], p["max"]) for n, p in profs.items()))
        print("LEARN NOW (%d, highest skill first): " % len(now) + (", ".join("%s (%d)" % (r["name"], r["skill"]) for r in sorted(now, key=lambda r: -r["skill"])[:OPT["top"]]) or "nothing new"))
        print("NEXT: " + (", ".join("%s (%d)" % (r["name"], r["skill"]) for r in sorted(nxt, key=lambda r: r["skill"])[:8]) or "nothing listed"))
        if pg.get("shown") and pg["shown"][1] < pg["shown"][2]:
            print("(page shows %d of %d rows)" % (pg["shown"][1], pg["shown"][2]))
        return
    if OPT["rate"]:
        sp, eq = sp_eq()
        rate_items([r["id"] for r in rows if r["type"] == "item"][:60], sp, eq, top=OPT["top"], max_req=OPT["max-req"],
                   srcs={r["id"]: r for r in rows})
        return
    for r in rows if OPT["all"] else rows[:OPT["top"] * 4]:
        print(fmt_row(r))
    if not OPT["all"] and len(rows) > OPT["top"] * 4:
        print("-- %d more (--all or --grep)" % (len(rows) - OPT["top"] * 4))


def import_page(rest):
    """Save an agent-fetched markdown copy of a www.wowhead.com/forever page where `page` finds it."""
    if len(rest) < 2:
        print("usage: foreverscribe wowhead import-page <url> <markdown file | ->")
        return 2
    url, src = rest[0], rest[1]
    if not url.startswith("http"):
        url = WWW + url.lstrip("/")
    if not url.startswith(WWW):
        print("only www.wowhead.com/forever/ pages")
        return 2
    md = sys.stdin.read() if src == "-" else open(src, encoding="utf-8", errors="replace").read()
    os.makedirs(IMPORTED, exist_ok=True)
    name = "www.wowhead.com-%s.md" % re.sub(r"[^A-Za-z0-9_.=-]", "_", page_key(url))[:150]
    path = os.path.join(IMPORTED, name)
    with open(path, "w", encoding="utf-8") as fh:
        fh.write("[source](%s)\n\n%s" % (url, md))
    print("saved %s (%d chars); re-run the command that asked for it" % (path, len(md)))
    return 0


def main(a=None):
    a = list(sys.argv[1:] if a is None else a)
    args = []
    while a:
        x = a.pop(0)
        if x.startswith("--") and x[2:] in OPT:
            k = x[2:]
            OPT[k] = True if isinstance(OPT[k], bool) else (int(a.pop(0)) if k in ("top", "max-req") else a.pop(0))
        else:
            args.append(x)
    if not args:
        print(__doc__)
        return
    cmd, rest = args[0], args[1:]
    sp_eq = lambda: (spec(), worn())
    if cmd == "item":
        for i in rest:
            print(fmt_item(item(i)))
    elif cmd == "rate":
        sp, eq = sp_eq()
        rate_items(rest, sp, eq, max_req=OPT["max-req"] if OPT["max-req"] is not None else 99)
    elif cmd in ("gear", "equipped"):
        if rest:
            OPT["for"] = rest[0]
        cmd_gear(*sp_eq())
    elif cmd == "weights":
        sp = spec()
        print("%s level %s %s, talents %s -> %s\nweights: %s" % (sp["char"], sp["level"], sp["class"], sp["points"],
                                                                 sp["school"] or "physical", sp["w"]))
    elif cmd in ("vendor", "npc-sells"):
        cmd_vendor(rest[0], *sp_eq())
    elif cmd == "craft":
        cmd_craft(rest, *sp_eq())
    elif cmd == "aca":
        cmd_aca(" ".join(rest))
    elif cmd == "page":
        cmd_page(rest[0], sp_eq)
    elif cmd == "import-page":
        return import_page(rest)
    elif cmd in ("npc", "quest", "zone", "spell"):
        for i in rest:
            d = tooltip(cmd, i)
            print("%s [%s %s]: %s%s" % (d.get("name", "?"), cmd, i, "; ".join(_lines(d.get("tooltip", ""))[1:8])[:500] or d.get("error", ""),
                                        " | map %s" % json.dumps(d["map"]) if d.get("map") else ""))
    else:
        print(__doc__)
        sys.exit(2)


if __name__ == "__main__":
    sys.exit(main())

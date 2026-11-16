"""foreverscribe way — where an NPC, object or spot is, plus the one chat command that pins it on the map with an arrow.

  foreverscribe way <npc or object name> [zone words]   e.g.  way first aid trainer stormwind
  foreverscribe way npc=<id> | object=<id>
  foreverscribe way <x> <y> <zone>   |   way <zone> <x> <y>
Options: --for CHAR, --addon scribe|native|tomtom|polestar|mappin (force a command style), --json, --all

Where locations come from, best first (resolve.py):
  1. your own characters' NPC sightings (addon 0.5+: where you stood when you talked to it) — "confirmed in game"
  2. data/npc-locations.json, sightings other ForeverScribe users shared (no personal data)
  3. forever-db, Polestar's open database (spawn points; fetched once at runtime, foreverdb.py)
  4. Wowhead Forever tooltips (nether.wowhead.com/forever, cached 7 days) and its name search.
The best two sources with a position are compared: more than 25 yards apart is "⚠ uncertain" (both spots shown,
which one the command uses, and how to help fix it). Coordinates are never guessed: no position, no command.

Forever redrew four maps (Mulgore, Eastern Plaguelands, Redridge Mountains, Stormwind City). Wowhead Forever
still carries the old Classic-frame points there next to the new ones, so on those maps every point that is
also in Wowhead Classic is converted to Forever's frame with the client's own map bounds (gamedata/maps.json,
tools/build_maps.py) and merged with the Forever-recorded ones.

The paste command follows the character's loaded addons (cold tier `cold addons`, plus the snapshot's
ForeverScribe version). Verified syntaxes (docs/WAYPOINTS.md):
  ForeverScribe 0.4+  /scribe way <x> <y> <zone|mapID> <title>     native pin + arrow (forwards to Polestar/TomTom)
  TomTom              /way #<mapID> <x> <y> <title>
  Polestar            /run Polestar.Nav.API.Navigate("ForeverScribe",<mapID>,<x 0-1>,<y 0-1>,"<title>")
  none of those       /run C_Map.SetUserWaypoint(UiMapPoint.CreateFromCoordinates(<mapID>,<x>,<y>)) C_SuperTrack...
  extra with Questie  /questie tomap npc <id>   (Questie's own map pins for that NPC; no arrow)
"""
import json
import math
import os
import re
import sys
import time
import urllib.parse
import urllib.request

from . import resolve as R

HERE = os.path.dirname(os.path.abspath(__file__))
_MAPS = None
TYPES = {1: "npc", 2: "object"}
SCRIBE_MIN = (0, 4, 0)
CLUSTER = 2.5  # map percent: points closer than this are one spot


# ---------- map data ----------
def maps():
    global _MAPS
    if _MAPS is None:
        with open(os.path.join(HERE, "gamedata", "maps.json"), encoding="utf-8") as f:
            _MAPS = {int(k): v for k, v in json.load(f)["maps"].items()}
    return _MAPS


def fold(s):
    return re.sub(r"[^a-z0-9]", "", (s or "").lower())


def name_unique(mid):
    n = fold(maps()[mid]["name"])
    return sum(1 for v in maps().values() if fold(v["name"]) == n) == 1


def resolve_zone(text):
    """Zone/city name -> uiMapID: exact name, else the one zone it begins. (id, None) or (None, why)."""
    key = fold(text)
    if not key:
        return None, "no zone given"
    if key.lstrip("#").isdigit() and int(key.lstrip("#")) in maps():
        return int(key.lstrip("#")), None
    rank = lambda mid: (0 if maps()[mid]["type"] == 3 else 1, mid)
    exact = sorted((m for m, v in maps().items() if fold(v["name"]) == key), key=rank)
    if exact:
        return exact[0], None
    pre = sorted({m for m, v in maps().items() if len(key) >= 4 and fold(v["name"]).startswith(key) and v["type"] in (2, 3)},
                 key=rank)
    names = sorted({maps()[m]["name"] for m in pre})
    if len(names) == 1:
        return pre[0], None
    if names:
        return None, "%s could be %s" % (text, ", ".join(names))
    return None, "no Forever map called %s" % text


def zone_in_query(words):
    """Longest run of words that names a zone -> (mapID, remaining words); (None, words) if none."""
    for n in range(min(4, len(words)), 0, -1):
        for i in range(len(words) - n + 1):
            mid, _ = resolve_zone(" ".join(words[i:i + n]))
            if mid and maps()[mid]["type"] == 3:
                return mid, words[:i] + words[i + n:]
    return None, words


def area_map(area, zone_name=None):
    hits = sorted((m for m, v in maps().items() if v["area"] == area), key=lambda m: (maps()[m]["type"] != 3, m))
    if hits:
        return hits[0]
    if zone_name:
        return resolve_zone(zone_name)[0]
    return None


def to_world(mid, x, y, era=False):
    v = maps().get(mid)
    b = v and (v.get("era_bounds") if era else v["bounds"])
    if not b:
        return None
    min_x, min_y, max_x, max_y = b
    return v["continent_map"], max_x - y / 100.0 * (max_x - min_x), max_y - x / 100.0 * (max_y - min_y)


def from_world(mid, wx, wy):
    min_x, min_y, max_x, max_y = maps()[mid]["bounds"]
    return (max_y - wy) / (max_y - min_y) * 100.0, (max_x - wx) / (max_x - min_x) * 100.0


def era_to_forever(mid, x, y):
    w = to_world(mid, x, y, era=True)
    if not w:
        return x, y
    fx, fy = from_world(mid, w[1], w[2])
    return round(fx, 1), round(fy, 1)


# ---------- Wowhead ----------
def _tooltip(kind, eid, flavor="forever"):
    from . import wowhead
    return wowhead.tooltip(kind, eid, flavor)


def _search(q):
    """Wowhead Forever name search (JSON suggestions endpoint), cached 7 days. [] on any failure."""
    from . import wowhead
    os.makedirs(wowhead.CACHE, exist_ok=True)
    p = os.path.join(wowhead.CACHE, "search-%s.json" % re.sub(r"[^a-z0-9]+", "-", q.lower()).strip("-")[:80])
    if os.path.exists(p) and time.time() - os.path.getmtime(p) < wowhead.TTL:
        with open(p, encoding="utf-8") as f:
            return json.load(f)
    url = "https://www.wowhead.com/forever/search/suggestions-template?q=" + urllib.parse.quote(q)
    try:
        with urllib.request.urlopen(urllib.request.Request(url, headers=wowhead.UA), timeout=20) as r:
            res = json.loads(r.read().decode("utf-8", "replace")).get("results") or []
    except (OSError, ValueError):
        return None
    with open(p, "w", encoding="utf-8") as f:
        json.dump(res, f)
    return res


FETCH = {"tooltip": _tooltip, "search": _search}  # tests swap these


def subtitle(tip):
    m = re.findall(r"<td>([^<]+)</td>", tip.get("tooltip") or "")
    return m[0].strip() if m and not m[0].startswith("Level ") else ""


def locate(kind, eid):
    """Where Wowhead Forever puts an NPC/object: name, zone, map, clustered spots with frame labels."""
    t = FETCH["tooltip"](kind, eid)
    if t.get("error") or not t.get("name"):
        return {"error": "Wowhead Forever has no %s %s (%s)" % (kind, eid, t.get("error") or "no data")}
    r = {"kind": kind, "id": int(eid), "name": t["name"], "subtitle": subtitle(t), "source": "Wowhead Forever %s=%s" % (kind, eid),
         "url": "https://www.wowhead.com/forever/%s=%s" % (kind, eid), "notes": []}
    m = t.get("map") or {}
    coords = m.get("coords") or {}
    pts = [(float(p[0]), float(p[1]), k) for k in sorted(coords) for p in coords[k] if len(p) >= 2]
    zone_name = None
    if m.get("zone"):
        zt = FETCH["tooltip"]("zone", m["zone"])
        zone_name = zt.get("name") if not zt.get("error") else None
    mid = area_map(m.get("zone"), zone_name) if m.get("zone") else None
    r["zone"] = maps()[mid]["name"] if mid else zone_name
    r["mapID"] = mid
    if not pts:
        r["notes"].append("Wowhead Forever lists no position for it (location unknown there). No coordinates given: "
                          "check the in-game map or another source.")
        r["spots"] = []
        return r
    marked = []
    if mid and maps()[mid].get("era_bounds"):
        ct = FETCH["tooltip"](kind, eid, "classic")
        if ct.get("error"):
            r["notes"].append("UNVERIFIED: %s is a map Forever redrew and the Classic lookup failed, so old Classic-frame "
                              "points could not be told apart; the pin may be off." % r["zone"])
            marked = [(x, y, k, "unverified") for x, y, k in pts]
        else:
            cset = {(float(p[0]), float(p[1])) for p in ((ct.get("map") or {}).get("coords") or {}).get("0", [])}
            n_era = 0
            for x, y, k in pts:
                if (x, y) in cset:
                    cx, cy = era_to_forever(mid, x, y)
                    marked.append((cx, cy, k, "converted from Classic frame"))
                    n_era += 1
                else:
                    marked.append((x, y, k, "recorded in Forever"))
            if n_era:
                r["notes"].append("%d of Wowhead's %d points are old Classic-frame coordinates (Forever redrew %s); converted "
                                  "to Forever's map with the client's map bounds." % (n_era, len(pts), r["zone"]))
    else:
        marked = [(x, y, k, "Wowhead Forever") for x, y, k in pts]
    # native (recorded in Forever) points lead their cluster
    marked.sort(key=lambda p: 0 if p[3] == "recorded in Forever" else 1)
    spots = []
    for x, y, k, frame in marked:
        for s in spots:
            if s["floor"] == k and math.hypot(s["x"] - x, s["y"] - y) <= CLUSTER:
                s["points"] += 1
                if frame not in s["frames"]:
                    s["frames"].append(frame)
                break
        else:
            spots.append({"x": round(x, 1), "y": round(y, 1), "floor": k, "points": 1, "frames": [frame]})
    r["spots"] = spots
    if any(s["floor"] != "0" for s in spots):
        r["notes"].append("Some points are on another floor/level of the map (Wowhead floor key).")
    return r


def search(query, near_map=None):
    """Name -> (best {kind,id}, other candidates, zone mapID used). Filters by a zone named in the query."""
    words = query.split()
    zone, rest = zone_in_query(words)
    # The whole query first (an NPC name may contain a zone word: "Stormwind Guard"), then without the zone words.
    tries = [(" ".join(words), words)] + ([(" ".join(rest), rest)] if zone and rest else [])
    cands, seen, any_results = [], set(), False
    for q, qwords in tries:
        results = FETCH["search"](q)
        if results is None:
            return None, [], zone, "Wowhead search unavailable (network?)"
        want = fold(" ".join(qwords))
        for x in [x for x in results if x.get("type") in TYPES][:8]:
            any_results = True
            if (x["type"], x["id"]) in seen:
                continue
            seen.add((x["type"], x["id"]))
            t = FETCH["tooltip"](TYPES[x["type"]], x["id"])
            if t.get("error"):
                continue
            m = t.get("map") or {}
            mid = area_map(m.get("zone")) if m.get("zone") else None
            name, sub = t.get("name") or x.get("name"), subtitle(t)
            score = (0 if zone and mid == zone else 1 if not zone else 3,
                     0 if fold(name) == want else 1 if want in fold(name + sub) else 2,
                     0 if m.get("coords") else 1,
                     0 if near_map and mid == near_map else 1)
            cands.append({"kind": TYPES[x["type"]], "id": x["id"], "name": name, "subtitle": sub,
                          "zone": maps()[mid]["name"] if mid else None, "mapID": mid, "score": score})
        if cands and (not zone or any(c["mapID"] == zone for c in cands)):
            break
    if not any_results:
        return None, [], zone, "Wowhead Forever finds no NPC or object named %r" % " ".join(rest or words)
    if not cands:
        return None, [], zone, "no Wowhead tooltip for the matches"
    cands.sort(key=lambda c: c["score"])
    if zone and cands[0]["mapID"] != zone:
        return None, cands, zone, "no match in %s; nearest matches listed" % maps()[zone]["name"]
    return cands[0], cands[1:], zone, None


# ---------- the player's own NPC sightings (npcs.py) ----------
def _npcs():
    from . import npcs
    return npcs


NPCS = {"names": lambda words, zone, char: _npcs().name_matches(words, zone, char),
        "evidence": lambda nid, char: _npcs().evidence(nid, char)}  # tests swap these


# ---------- character context ----------
def _ver(s):
    return tuple(int(x) for x in re.findall(r"\d+", s or "")[:3]) or (0,)


def character(char=None):
    """{char, mapID, x, y, addons{lower name: version}, addons_at, scribe_version} from telemetry; {} if none."""
    try:
        from . import cli, queries as Q, store
        cfg = cli.load_config()
        if not os.path.exists(cfg["db"]) and not cfg["sources"]:
            return {}
        con = store.connect(cfg["db"])
        try:
            store.ingest_all(con, cfg["sources"], extra=cfg["extra"])
            if not Q.characters(con):
                return {}
            ck = Q.resolve_char(con, char or cfg["default_character"])
            st = Q.state(con, ck)
            snap, _ = Q.latest_snapshot(con, ck)
            ad = Q.cold(con, ck, "addons")
        finally:
            con.close()
    except Exception as e:  # telemetry is optional context; never block a location answer
        return {"error": str(e)}
    out = {"char": ck, "mapID": st.get("mapID"), "zone": st.get("zone"), "scribe_version": snap.get("addonVersion")}
    if st.get("coords"):
        out["x"], out["y"] = [float(v) for v in st["coords"].split(",")]
    if ad.get("addons"):
        out["addons"] = {(a["name"] or "").lower(): a.get("version") or "" for a in ad["addons"] if a.get("loaded")}
        out["addons_at"] = ad.get("captured_at")
    return out


def order_spots(spots, mid, ch):
    """Nearest first when we know where the character is; else most-recorded first."""
    here = ch.get("mapID") and ch.get("x") is not None and to_world(ch["mapID"], ch["x"], ch["y"])

    def key(s):
        if here and mid:
            w = to_world(mid, s["x"], s["y"])
            if w and w[0] == here[0]:
                d = math.hypot(w[1] - here[1], w[2] - here[2])
                s["yards"] = int(round(d))
                return (0 if ch["mapID"] == mid else 1, d)
        return (2, -s["points"])
    return sorted(spots, key=key)


# ---------- commands ----------
def clean_title(t):
    return re.sub(r"\s+", " ", re.sub(r"[|\"\\\n\r]", "", t or "")).strip()[:60]


def num(v):
    return ("%.1f" % v).rstrip("0").rstrip(".") if v % 1 else "%d" % v


def frac(v):
    return ("%.4f" % (v / 100.0)).rstrip("0").rstrip(".")


def commands(mid, x, y, title, ch, force=None, entity=None):
    """(primary {style, cmd, why}, alternatives [...]) for the character's addons."""
    title = clean_title(title)
    zone = maps()[mid]["name"] if mid in maps() and name_unique(mid) else str(mid)
    c = {
        "scribe": "/scribe way %s %s %s%s" % (num(x), num(y), zone, " " + title if title else ""),
        "tomtom": "/way #%d %s %s%s" % (mid, num(x), num(y), " " + title if title else ""),
        "polestar": '/run Polestar.Nav.API.Navigate("ForeverScribe",%d,%s,%s,"%s")' % (mid, frac(x), frac(y), title or "Waypoint"),
        "native": "/run C_Map.SetUserWaypoint(UiMapPoint.CreateFromCoordinates(%d,%s,%s)) "
                  "C_SuperTrack.SetSuperTrackedUserWaypoint(true)" % (mid, frac(x), frac(y)),
        "mappin": "/mappin %d %s %s" % (mid, num(x), num(y)),
    }
    why = {
        "scribe": "ForeverScribe 0.4+ is loaded: native map pin + arrow, handed to Polestar/TomTom if loaded",
        "tomtom": "TomTom is loaded: its waypoint and Crazy Arrow",
        "polestar": "Polestar is loaded (no ForeverScribe 0.4 yet): Polestar's arrow via its public Nav API",
        "native": "Forever's own map pin + tracking arrow (works with no addons; first /run may ask to allow scripts)",
        "mappin": "Blizzard's /mappin: map pin only, no arrow",
    }
    ad = ch.get("addons")
    if force:
        style = force
    elif _ver(ch.get("scribe_version")) >= SCRIBE_MIN and (ad is None or "foreverscribe" in ad):
        style = "scribe"
    elif ad and "tomtom" in ad:
        style = "tomtom"
    elif ad and "polestar" in ad:
        style = "polestar"
    else:
        style = "native"
    if style not in c:
        raise ValueError("--addon must be one of: %s" % ", ".join(sorted(c)))
    if ad is None and not force:
        why[style] += "; addon list unknown (no cold-tier capture yet)"
    alts = [{"style": s, "cmd": c[s], "why": why[s]} for s in ("native", "mappin") if s != style]
    if ad and "questie" in ad and entity and entity.get("kind") in ("npc", "object"):
        alts.insert(0, {"style": "questie", "cmd": "/questie tomap %s %d" % (entity["kind"], entity["id"]),
                        "why": "Questie is loaded: shows Questie's own map pins for it (no arrow)"})
    return {"style": style, "cmd": c[style], "why": why[style]}, alts


def parse_coords(words):
    """'x y zone...' or 'zone... x y' -> (mapID|None, x, y, why) or None when the words are no coordinates."""
    # "45.2, 61.8" / "45, 61": a separator followed by a space splits x and y; "45,2" alone is a decimal comma
    s = re.sub(r"(\d)[.,;]\s+(\d)", r"\1 \2", " ".join(words))
    toks = re.sub(r"(\d),(\d)", r"\1.\2", s).split()
    isnum = lambda t: re.match(r"^\d{1,3}(\.\d+)?$", t) is not None
    for i in range(len(toks) - 1):
        if isnum(toks[i]) and isnum(toks[i + 1]):
            x, y = float(toks[i]), float(toks[i + 1])
            zone = " ".join(toks[:i] + toks[i + 2:])
            if not (0 <= x <= 100 and 0 <= y <= 100):
                return None, x, y, "coordinates must be 0-100"
            if not zone:
                return None, x, y, "which zone? add the zone name"
            mid, why = resolve_zone(zone)
            return mid, x, y, why
    return None


def answer(query, char=None, force=None, show_all=False):
    words = query.split()
    ch = character(char)
    out = {"query": query, "character": ch.get("char"), "addons_captured_at": ch.get("addons_at")}
    pc = parse_coords(words)
    m = re.match(r"^(npc|object)\s*[=:#]?\s*(\d+)$", query.strip(), re.I)
    if pc is not None and not m:
        mid, x, y, why = pc
        if not mid:
            out["error"] = why
            return out
        out.update({"name": "Spot", "zone": maps()[mid]["name"], "mapID": mid,
                    "spots": [{"x": x, "y": y, "points": 1, "frames": ["as given"]}], "source": "coordinates you gave",
                    "notes": []})
        entity = None
    else:
        others = []
        if m:
            entity = {"kind": m.group(1).lower(), "id": int(m.group(2))}
        else:
            entity = None
            # an NPC this player has met in game, by exact name or <subtitle>, needs no Wowhead search
            zone, rest = zone_in_query(words)
            local = NPCS["names"](rest or words, zone, char)
            if local and local[0]["rank"] <= 1:
                entity = {"kind": "npc", "id": local[0]["id"]}
            if not entity:
                entity, others, _, why = search(query, near_map=ch.get("mapID"))
                if not entity and not others:
                    # Wowhead has nothing (or is unreachable): forever-db's names (exact name or <subtitle>)
                    try:
                        hits = R.FDB["find"](rest or words)
                    except Exception:
                        hits = []
                    if zone:
                        hits = [h for h in hits if (R.FDB["locate"](h["kind"], h["id"], zone) or {}).get("mapID") == zone] or hits
                    if hits:
                        entity = {"kind": hits[0]["kind"], "id": hits[0]["id"]}
                        others = [{"kind": h["kind"], "id": h["id"], "name": h["name"], "subtitle": h["subtitle"],
                                   "zone": None} for h in hits[1:]]
                if not entity:
                    out["error"] = why
                    out["candidates"] = [{k: c[k] for k in ("kind", "id", "name", "subtitle", "zone")} for c in others[:6]]
                    return out
        ev = NPCS["evidence"](entity["id"], char) if entity["kind"] == "npc" else {}
        loc = locate(entity["kind"], entity["id"])
        sources, wh, fd, own_row = R.gather(entity["kind"], entity["id"], ch, char, ev, loc)
        if not sources:
            out["error"] = loc.get("error") or "no source has a position for %s %s" % (entity["kind"], entity["id"])
            if not loc.get("error"):
                out.update({k: loc[k] for k in ("name", "subtitle", "zone", "url") if loc.get(k)})
                out["notes"] = list(loc.get("notes") or []) + list((fd or {}).get("notes") or [])
                out.pop("error")
                out.update(kind=entity["kind"], id=entity["id"], spots=[], source="none", mapID=None)
            return out
        first = sources[0]
        name = (wh.get("name") if not wh.get("error") else None) or (fd or {}).get("name") or (own_row or {}).get("name") \
            or "%s %d" % (entity["kind"].upper(), entity["id"])
        sub = (wh.get("subtitle") if not wh.get("error") else None) or (fd or {}).get("subtitle") or (own_row or {}).get("subtitle") or ""
        out.update({"kind": entity["kind"], "id": entity["id"], "name": name, "subtitle": sub, "source": first["label"],
                    "url": "https://www.wowhead.com/forever/%s=%d" % (entity["kind"], entity["id"]), "notes": [],
                    "zone": first["zone"], "mapID": first["mapID"], "spots": [dict(x) for x in first["spots"]],
                    "confirmed": first["key"] == "sighting", "sources": [
                        {"key": x["key"], "label": x["label"], "zone": x.get("zone"), "mapID": x["mapID"],
                         "spots": [{"x": p["x"], "y": p["y"]} for p in x["spots"][:6]]} for x in sources]})
        if first["key"] != "wowhead":
            if wh.get("error"):
                out["notes"].append("Wowhead lookup failed (%s)." % wh["error"])
            elif not wh.get("spots"):
                out["notes"].append("Wowhead Forever has no position for it.")
        else:
            out["notes"] += wh.get("notes") or []
        if fd and fd.get("notes"):
            out["notes"] += fd["notes"]
        out["_sources"] = sources
        out["other_matches"] = [{k: c[k] for k in ("kind", "id", "name", "subtitle", "zone")} for c in others[:5]]
    if not out.get("spots") or not out.get("mapID"):
        out.pop("_sources", None)
        if out.get("spots"):
            out["notes"].append("Zone %r is not a Forever map ForeverScribe knows; no command (coordinates above are "
                                "Wowhead's)." % out.get("zone"))
        return out
    spots = order_spots(out["spots"], out["mapID"], ch)
    out["spots"] = spots if show_all else spots[:6]
    out["more_spots"] = max(0, len(spots) - len(out["spots"]))
    best = spots[0]
    srcs = out.pop("_sources", None)
    if srcs:
        ag = R.agreement(srcs, best)
        out["agreement"] = ag
        if ag["status"] == "uncertain":
            out["uncertain"] = True
        hint = R.fix_hint(ag, out.get("name"), out["id"], out.get("kind"))
        if hint:
            out["help_fix"] = hint
        for o in ag.get("others") or []:
            if o["key"] == "wowhead" and not o["agrees"]:
                if o["yards"] is not None:
                    out["wowhead_off_yards"] = o["yards"]
                    out["notes"].append("Wowhead's pin is ~%d yd off (Wowhead Forever: %s %s, %s). Using %s." % (
                        o["yards"], o.get("zone") or "?", num(o["x"]), num(o["y"]),
                        "where it was actually met" if ag["using"] == "sighting" else R.LABEL[ag["using"]]))
                else:
                    out["notes"].append("Wowhead Forever puts it in %s; %s has it in %s." % (
                        o.get("zone") or "another zone", R.LABEL[ag["using"]], out.get("zone")))
    title = out["name"] if entity else ""
    out["paste"], out["alternatives"] = commands(out["mapID"], best["x"], best["y"], title, ch, force, entity)
    out["fetched_at"] = time.strftime("%Y-%m-%d %H:%M")
    return out


def render(r):
    if r.get("error"):
        lines = ["Not found: " + r["error"]]
        for c in r.get("candidates") or []:
            lines.append("  candidate: %s%s (%s) — `foreverscribe way %s=%s`" % (
                c["name"], " <%s>" % c["subtitle"] if c.get("subtitle") else "", c.get("zone") or "zone unknown", c["kind"], c["id"]))
        return "\n".join(lines)
    head = "%s%s — %s" % (r["name"], " <%s>" % r["subtitle"] if r.get("subtitle") else "", r.get("zone") or "zone unknown")
    lines = [head]
    spots = r.get("spots") or []
    if spots:
        s = spots[0]
        lines[0] += " %s, %s" % (num(s["x"]), num(s["y"]))
        lines.append("source: %s (%s)%s" % (r["source"], "; ".join(s["frames"]),
                                            ", %d yd from you" % s["yards"] if s.get("yards") is not None else ""))
    lines += R.describe(r.get("agreement"))
    if r.get("help_fix"):
        lines.append(r["help_fix"])
    if r.get("paste"):
        lines += ["paste in chat:", "  " + r["paste"]["cmd"], "  (%s)" % r["paste"]["why"]]
        if r.get("addons_captured_at"):
            lines.append("  addon list captured %s" % r["addons_captured_at"])
        for a in r.get("alternatives") or []:
            lines.append("  alt %s: %s   — %s" % (a["style"], a["cmd"], a["why"]))
    if len(spots) > 1:
        lines.append("other spots: " + "; ".join("%s, %s%s" % (num(s["x"]), num(s["y"]), " (%d yd)" % s["yards"] if s.get("yards") is not None else "")
                                                 for s in spots[1:]) + (" (+%d more, --all)" % r["more_spots"] if r.get("more_spots") else ""))
    for n in r.get("notes") or []:
        lines.append("note: " + n)
    for c in r.get("other_matches") or []:
        lines.append("other match: %s%s (%s) — `foreverscribe way %s=%s`" % (
            c["name"], " <%s>" % c["subtitle"] if c.get("subtitle") else "", c.get("zone") or "zone unknown", c["kind"], c["id"]))
    return "\n".join(lines)


def main(argv=None):
    a = list(sys.argv[1:] if argv is None else argv)
    opt = {"for": None, "addon": None, "json": False, "all": False}
    words = []
    while a:
        x = a.pop(0)
        if x in ("--for", "--char", "-c") and a:
            opt["for"] = a.pop(0)
        elif x == "--addon" and a:
            opt["addon"] = a.pop(0).lower()
        elif x in ("--json", "--all"):
            opt[x[2:]] = True
        else:
            words.append(x)
    if not words:
        print(__doc__)
        return 2
    try:
        r = answer(" ".join(words), opt["for"], opt["addon"], opt["all"])
    except ValueError as e:
        print(str(e))
        return 2
    print(json.dumps(r, indent=2, ensure_ascii=False) if opt["json"] else render(r))
    return 3 if r.get("error") else 0


if __name__ == "__main__":
    sys.exit(main())

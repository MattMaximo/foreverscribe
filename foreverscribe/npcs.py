"""foreverscribe npcs — where NPCs really stand, from your own characters' visits (addon 0.5+).

  foreverscribe npcs [words]               NPCs your characters talked to: where, when, how often
  foreverscribe npcs --disagree            only the ones whose Wowhead Forever pin is off (looks each up, cached 7 days)
  foreverscribe npcs --export-shared [FILE]   sanitized copy for data/npc-locations.json (default ./npc-locations.json)
  foreverscribe npcs --merge FILE          merge an export into FILE (maintainers: data/npc-locations.json)
Options: --for CHAR (default: every character), --yards N (disagreement threshold, default 25), --limit N, --json

Where it comes from: whenever you open an NPC's window (talk, vendor, trainer, quest, flight master, bank, auction
house) or target a friendly NPC within 10 yards, the addon notes the NPC's id and YOUR position, in Forever's own map
frame. You stand within a few yards of it, so this beats a Classic-era pin. `way` and the waypoint tool prefer these
sightings, then the shared file (data/npc-locations.json, contributed by users), then Wowhead.

The shared export holds only npcID, NPC name, mapID, x, y, sightings count and the date last seen. No character,
realm, account, time of day or anything about you.
"""
import json
import math
import os
import re
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
SHARED = os.path.join(os.path.dirname(HERE), "data", "npc-locations.json")
DISAGREE_YARDS = 25.0
MERGE_YARDS = 5.0
_SHARED = None


# ---------- geometry (Forever map frame, gamedata/maps.json) ----------
def yards(map_a, xa, ya, map_b, xb, yb):
    """Distance in yards between two map points, or None when the maps can't be compared."""
    from . import waypoints as WP
    a, b = WP.to_world(map_a, xa, ya), WP.to_world(map_b, xb, yb)
    if not a or not b or a[0] != b[0]:
        return None
    return math.hypot(a[1] - b[1], a[2] - b[2])


def _close(map_a, xa, ya, map_b, xb, yb, limit=MERGE_YARDS):
    if map_a != map_b:
        return False
    d = yards(map_a, xa, ya, map_b, xb, yb)
    if d is None:  # map without bounds: 0.5 map percent
        return math.hypot(xa - xb, ya - yb) <= 0.5
    return d <= limit


def day(ts):
    return time.strftime("%Y-%m-%d", time.localtime(int(ts))) if ts else None


def fold(s):
    return re.sub(r"[^a-z0-9]", "", (s or "").lower())


# ---------- store ----------
def _open(char=None):
    from . import cli, queries as Q, store
    cfg = cli.load_config()
    con = store.connect(cfg["db"])
    store.ingest_all(con, cfg["sources"], extra=cfg["extra"])
    ck = None
    if Q.characters(con):
        ck = Q.resolve_char(con, char or cfg["default_character"]) if (char or cfg["default_character"]) else None
    return con, ck


def _rows(con, where="", params=()):
    return [dict(r) for r in con.execute("SELECT * FROM npc_sightings %s ORDER BY last_seen DESC" % where, params)]


def _spots(row):
    try:
        sp = json.loads(row.get("spots") or "[]")
    except ValueError:
        sp = []
    return [s for s in sp if isinstance(s, dict) and s.get("x") is not None] or [
        {"x": row["x"], "y": row["y"], "n": row["count"], "t": row["last_seen"]}]


def shared(path=None):
    """npcID -> [entries] from data/npc-locations.json (empty when missing or malformed)."""
    global _SHARED
    if _SHARED is not None and path is None:
        return _SHARED
    out = {}
    try:
        with open(path or SHARED, encoding="utf-8") as f:
            d = json.load(f)
        for e in d.get("npcs") or []:
            if isinstance(e, dict) and isinstance(e.get("npcID"), int) and isinstance(e.get("mapID"), int):
                out.setdefault(e["npcID"], []).append(e)
    except (OSError, ValueError, AttributeError):
        pass
    if path is None:
        _SHARED = out
    return out


def evidence(npc_id, char=None):
    """{'personal': [rows, the character's own first], 'shared': [entries]} for one NPC."""
    try:
        con, ck = _open(char)
    except Exception as e:  # telemetry is optional; never block a location answer
        return {"personal": [], "shared": shared().get(int(npc_id), []), "error": str(e)}
    try:
        rows = _rows(con, "WHERE npc_id=?", (int(npc_id),))
    finally:
        con.close()
    rows.sort(key=lambda r: (0 if ck and r["char_key"] == ck else 1, -(r["count"] or 0), -(r["last_seen"] or 0)))
    return {"personal": rows, "shared": shared().get(int(npc_id), []), "char": ck}


def name_matches(words, zone=None, char=None):
    """NPCs seen in game whose name (or <subtitle>) matches the words: [{id, name, subtitle, mapID}]."""
    want = fold(" ".join(words))
    if not want:
        return []
    try:
        con, _ = _open(char)
    except Exception:
        return []
    try:
        rows = _rows(con)
    finally:
        con.close()
    hits, seen = [], set()
    for r in rows:
        name, sub = fold(r.get("name")), fold(r.get("subtitle"))
        if not name and not sub:
            continue
        if want == name:
            rank = 0
        elif sub and want == sub:
            rank = 1
        elif len(want) >= 4 and (want in name or (sub and want in sub)):
            rank = 2
        else:
            continue
        if zone and r["map_id"] != zone:
            rank += 10
        if r["npc_id"] in seen:
            continue
        seen.add(r["npc_id"])
        hits.append({"id": r["npc_id"], "name": r.get("name"), "subtitle": r.get("subtitle") or "", "mapID": r["map_id"],
                     "rank": rank, "count": r.get("count") or 1})
    hits.sort(key=lambda h: (h["rank"], -h["count"]))
    return [h for h in hits if not zone or h["rank"] < 10] or ([] if zone else hits)


def spots_from(ev):
    """Location spots for `way`: (mapID, spots, source, notes) from personal sightings, else the shared file."""
    from . import waypoints as WP
    rows = ev.get("personal") or []
    if rows:
        best = rows[0]
        mid = best["map_id"]
        same = [r for r in rows if r["map_id"] == mid]
        spots = []
        for r in same:
            for s in _spots(r):
                spots.append({"x": round(float(s["x"]), 1), "y": round(float(s["y"]), 1), "floor": "0",
                              "points": int(s.get("n") or 1), "frames": ["confirmed in game"], "seen": s.get("t")})
        spots.sort(key=lambda s: (-s["points"], -(s.get("seen") or 0)))
        who = best["char_key"].split(":")[-1] if best.get("char_key") else "you"
        own = ev.get("char") and best["char_key"] == ev["char"]
        src = "confirmed in game by %s, %s (%d visit%s)" % ("this character" if own else who, day(best["last_seen"]),
                                                          best["count"] or 1, "" if (best["count"] or 1) == 1 else "s")
        return mid, spots, src, best
    sh = ev.get("shared") or []
    if sh:
        by_map = {}
        for e in sh:
            by_map.setdefault(e["mapID"], []).append(e)
        mid = max(by_map, key=lambda m: sum(e.get("count") or 1 for e in by_map[m]))
        es = sorted(by_map[mid], key=lambda e: -(e.get("count") or 1))
        spots = [{"x": round(float(e["x"]), 1), "y": round(float(e["y"]), 1), "floor": "0", "points": int(e.get("count") or 1),
                  "frames": ["shared ForeverScribe sightings"]} for e in es]
        n = sum(e.get("count") or 1 for e in es)
        last = max((e.get("lastSeen") or "") for e in es)
        return mid, spots, "ForeverScribe shared sightings (%d, last %s)" % (n, last), es[0]
    return None, [], None, None


def compare(mid, x, y, wh_spots, wh_map, limit=DISAGREE_YARDS):
    """(yards to Wowhead's nearest pin or None, that pin) for our spot."""
    best = None
    for s in wh_spots or []:
        d = yards(mid, x, y, wh_map, s["x"], s["y"]) if wh_map else None
        if d is not None and (best is None or d < best[0]):
            best = (d, s)
    return best if best else (None, None)


# ---------- listing ----------
def listing(char=None, words=None, disagree=False, limit_yards=DISAGREE_YARDS, limit=200):
    from . import waypoints as WP
    con, ck = _open(char)
    try:
        if char and not ck:
            return {"error": "no character matches %r" % char}
        rows = _rows(con, "WHERE char_key=?", (ck,)) if char else _rows(con)
    finally:
        con.close()
    want = fold(" ".join(words or []))
    if want:
        rows = [r for r in rows if want in fold(r.get("name")) or want in fold(r.get("subtitle")) or str(r["npc_id"]) == want]
    out = []
    for r in rows[: max(limit, 1) * (5 if disagree else 1)]:
        m = WP.maps().get(r["map_id"])
        item = {"npcID": r["npc_id"], "name": r.get("name"), "subtitle": r.get("subtitle"), "mapID": r["map_id"],
                "zone": (m or {}).get("name") or r.get("zone"), "subzone": r.get("subzone"), "x": round(r["x"], 1),
                "y": round(r["y"], 1), "visits": r.get("count"), "last_seen": day(r.get("last_seen")),
                "character": r["char_key"].split(":")[-1], "how": r.get("kind")}
        if disagree:
            loc = WP.locate("npc", r["npc_id"])
            if loc.get("error"):
                item["wowhead"] = "lookup failed: " + loc["error"]
                continue
            d, pin = compare(r["map_id"], r["x"], r["y"], loc.get("spots"), loc.get("mapID"))
            if d is None:
                item["wowhead"] = ("no position on Wowhead Forever" if not loc.get("spots")
                                   else "Wowhead puts it in %s" % (loc.get("zone") or "another zone"))
                if loc.get("spots") and loc.get("mapID") == r["map_id"]:
                    continue
            elif d <= limit_yards:
                continue
            else:
                pin = pin or {}
                item["wowhead"] = "pin ~%d yd off (Wowhead: %s, %s)" % (round(d), WP.num(pin.get("x", 0)), WP.num(pin.get("y", 0)))
                item["off_yards"] = int(round(d))
        out.append(item)
        if len(out) >= limit:
            break
    return {"character": ck if char else "all", "count": len(out), "npcs": out}


def render(r, disagree=False):
    from . import waypoints as WP
    if r.get("error"):
        return r["error"]
    if not r["npcs"]:
        return ("No disagreements with Wowhead Forever above the threshold." if disagree else
                "No NPC sightings yet. With ForeverScribe 0.5 in game, talk to NPCs (or target friendly ones up close), "
                "then /reload.")
    lines = ["%d NPC%s %s" % (r["count"], "" if r["count"] == 1 else "s",
                              "where Wowhead's pin disagrees with where you met them:" if disagree else "met in game:")]
    for n in r["npcs"]:
        lines.append("  %s%s (npc=%s) — %s %s, %s; %s visit%s, last %s by %s%s" % (
            n["name"] or "?", " <%s>" % n["subtitle"] if n.get("subtitle") else "", n["npcID"], n["zone"] or n["mapID"],
            WP.num(n["x"]), WP.num(n["y"]), n["visits"], "" if n["visits"] == 1 else "s", n["last_seen"], n["character"],
            "; " + n["wowhead"] if n.get("wowhead") else ""))
    return "\n".join(lines)


# ---------- shared export ----------
_SAFE = re.compile(r"[^\w '\-.,:()&!?/]", re.U)


def _clean_name(s):
    s = _SAFE.sub("", s or "").strip()
    return s[:60] or None


def export_shared(char=None):
    """The user's sightings as a shared-file document: npcID, name, mapID, x, y, count, lastSeen (date). Nothing else."""
    con, ck = _open(char)
    try:
        rows = _rows(con, "WHERE char_key=?", (ck,)) if char and ck else _rows(con)
    finally:
        con.close()
    entries = []
    for r in rows:
        for s in _spots(r):
            entries.append({"npcID": int(r["npc_id"]), "name": _clean_name(r.get("name")), "mapID": int(r["map_id"]),
                            "x": round(float(s["x"]), 1), "y": round(float(s["y"]), 1), "count": int(s.get("n") or 1),
                            "lastSeen": day(s.get("t") or r.get("last_seen"))})
    return document(merge([], entries))


def merge(base, new):
    """Merge entries: the same NPC on the same map within 5 yards is one spot (counts add, newest date wins)."""
    out = [dict(e) for e in base]
    for e in new:
        for o in out:
            if o["npcID"] == e["npcID"] and _close(o["mapID"], o["x"], o["y"], e["mapID"], e["x"], e["y"]):
                n1, n2 = o.get("count") or 1, e.get("count") or 1
                o["x"] = round((o["x"] * n1 + e["x"] * n2) / (n1 + n2), 1)
                o["y"] = round((o["y"] * n1 + e["y"] * n2) / (n1 + n2), 1)
                o["count"] = min(n1 + n2, 100000)
                o["lastSeen"] = max(o.get("lastSeen") or "", e.get("lastSeen") or "") or None
                o["name"] = o.get("name") or e.get("name")
                break
        else:
            out.append({k: e.get(k) for k in ("npcID", "name", "mapID", "x", "y", "count", "lastSeen")})
    out.sort(key=lambda e: (e["npcID"], e["mapID"], e["x"], e["y"]))
    return out


ABOUT = ("Where NPCs really stand in WoW: Forever, seen in game by ForeverScribe users (Forever map frame: uiMapID, "
         "x/y 0-100). No character, realm or account data. Add yours: foreverscribe npcs --export-shared, then open a "
         "pull request with the file merged here (foreverscribe npcs --merge data/npc-locations.json --from <file>).")


def document(entries):
    return {"format": 1, "about": ABOUT, "npcs": entries}


def write_json(path, doc):
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(doc, f, indent=1, ensure_ascii=False, sort_keys=True)
        f.write("\n")
    os.replace(tmp, path)


def main(argv=None):
    a = list(sys.argv[1:] if argv is None else argv)
    opt = {"for": None, "json": False, "disagree": False, "yards": DISAGREE_YARDS, "limit": 200, "export": None,
           "merge": None, "from": None}
    words = []
    while a:
        x = a.pop(0)
        if x in ("--for", "--char", "-c") and a:
            opt["for"] = a.pop(0)
        elif x == "--json":
            opt["json"] = True
        elif x == "--disagree":
            opt["disagree"] = True
        elif x == "--yards" and a:
            opt["yards"] = float(a.pop(0))
        elif x == "--limit" and a:
            opt["limit"] = int(a.pop(0))
        elif x == "--export-shared":
            opt["export"] = a.pop(0) if a and not a[0].startswith("-") else "npc-locations.json"
        elif x == "--merge" and a:
            opt["merge"] = a.pop(0)
        elif x == "--from" and a:
            opt["from"] = a.pop(0)
        elif x in ("-h", "--help"):
            print(__doc__)
            return 0
        else:
            words.append(x)
    if opt["merge"]:
        try:
            with open(opt["merge"], encoding="utf-8") as f:
                base = json.load(f).get("npcs") or []
        except (OSError, ValueError):
            base = []
        if opt["from"]:
            with open(opt["from"], encoding="utf-8") as f:
                new = json.load(f).get("npcs") or []
        else:
            new = export_shared(opt["for"])["npcs"]
        new = [{"npcID": e["npcID"], "name": _clean_name(e.get("name")), "mapID": e["mapID"], "x": float(e["x"]),
                "y": float(e["y"]), "count": int(e.get("count") or 1), "lastSeen": e.get("lastSeen")}
               for e in new if isinstance(e, dict) and isinstance(e.get("npcID"), int) and isinstance(e.get("mapID"), int)
               and 0 <= float(e.get("x", -1)) <= 100 and 0 <= float(e.get("y", -1)) <= 100
               and re.match(r"^\d{4}-\d\d-\d\d$", str(e.get("lastSeen") or "0000-00-00"))]
        doc = document(merge(base, new))
        write_json(opt["merge"], doc)
        print("merged %d entries into %s (%d total)" % (len(new), opt["merge"], len(doc["npcs"])))
        return 0
    if opt["export"]:
        doc = export_shared(opt["for"])
        write_json(opt["export"], doc)
        print("wrote %d NPC spots to %s (npcID, name, mapID, x, y, count, date last seen; nothing about you). "
              "To share them: open a pull request on the ForeverScribe repo adding them to data/npc-locations.json "
              "(`foreverscribe npcs --merge data/npc-locations.json --from %s`)." % (len(doc["npcs"]), opt["export"], opt["export"]))
        return 0
    r = listing(opt["for"], words, opt["disagree"], opt["yards"], opt["limit"])
    print(json.dumps(r, indent=2, ensure_ascii=False) if opt["json"] else render(r, opt["disagree"]))
    return 3 if r.get("error") else 0


if __name__ == "__main__":
    sys.exit(main())

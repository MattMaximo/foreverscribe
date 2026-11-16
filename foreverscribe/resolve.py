"""Where an NPC or object is, from every source ForeverScribe knows, and how much they agree.

Sources, most trusted first (the answer uses the first one that has a position):
  1. sighting   your own characters met it in game (addon 0.5+): where you stood while talking to it
  2. shared     data/npc-locations.json: sightings other ForeverScribe users shared ("shared corrections")
  3. forever-db Polestar's open database (spawn points in world yards, turned into Forever map percent)
  4. wowhead    Wowhead Forever's tooltip map (Classic-frame points converted where Forever redrew a map)

Agreement: the best two sources that have a position are compared at the spot the answer uses (nearest to the
character when we know where they are). More than DISAGREE_YARDS apart, or on different continents, is flagged:
"uncertain" when the answer does not rest on your own sighting, "own sighting disagrees" when it does (then the
other source is probably wrong and `foreverscribe correction draft <id>` writes the fix to send upstream).
"""
import math
import os

DISAGREE_YARDS = float(os.environ.get("FOREVERSCRIBE_DISAGREE_YARDS") or 25)
ORDER = ("sighting", "shared", "foreverdb", "wowhead")
LABEL = {"sighting": "your sighting", "shared": "shared ForeverScribe sightings", "foreverdb": "forever-db",
         "wowhead": "Wowhead Forever"}


def _wp():
    from . import waypoints
    return waypoints


def _fdb_locate(kind, eid, prefer=None):
    from . import foreverdb
    return foreverdb.locate(kind, eid, prefer=prefer)


def _fdb_find(words, kind=None):
    from . import foreverdb
    return foreverdb.find(words, kind=kind)


FDB = {"locate": _fdb_locate, "find": _fdb_find}  # tests swap these


def _world(mid, x, y):
    return _wp().to_world(mid, x, y)


def _spot_list(src):
    """Every (mapID, spot) of a source: all maps for forever-db, else its one map."""
    if src.get("maps"):
        return [(m, s) for m, spots in src["maps"].items() for s in spots]
    return [(src["mapID"], s) for s in src.get("spots") or []]


def distance(mid, x, y, src):
    """(yards to the source's nearest spot, (mapID, spot)) or (None, None) when no spot shares the continent."""
    a = _world(mid, x, y)
    best = (None, None)
    if not a:
        return best
    for m, s in _spot_list(src):
        b = _world(m, s["x"], s["y"])
        if not b or b[0] != a[0]:
            continue
        d = math.hypot(a[1] - b[1], a[2] - b[2])
        if best[0] is None or d < best[0]:
            best = (d, (m, s))
    return best


def gather(kind, eid, ch, char=None, ev=None, wh=None):
    """Every source with a position for one NPC/object: [{key, label, mapID, zone, spots, ...}] in trust order,
    plus the Wowhead lookup (for names/urls) and the sighting row. Missing sources are simply absent."""
    WP = _wp()
    out = []
    own_row = None
    if kind == "npc":
        if ev is None:
            ev = WP.NPCS["evidence"](eid, char)
        if ev.get("personal"):
            mid, spots, label, own_row = WP._npcs().spots_from({"personal": ev["personal"], "char": ev.get("char")})
            if spots and mid in WP.maps():
                out.append({"key": "sighting", "label": label, "mapID": mid, "zone": WP.maps()[mid]["name"],
                            "spots": spots, "row": own_row})
        if ev.get("shared"):
            mid, spots, label, row = WP._npcs().spots_from({"shared": ev["shared"]})
            if spots and mid in WP.maps():
                out.append({"key": "shared", "label": label, "mapID": mid, "zone": WP.maps()[mid]["name"], "spots": spots})
    if wh is None:
        wh = WP.locate(kind, eid)
    hint = (out[0]["mapID"] if out else None) or (wh.get("mapID") if not wh.get("error") else None)
    try:
        fd = FDB["locate"](kind, eid, hint)
    except Exception:  # an optional source must never break an answer
        fd = None
    if fd and fd.get("spots") and fd.get("mapID"):
        out.append({"key": "foreverdb", "label": "forever-db %s (%d spawn point%s)" % (
            __import__("foreverscribe.foreverdb", fromlist=["RELEASE"]).RELEASE, fd["spawn_count"],
            "" if fd["spawn_count"] == 1 else "s"), "mapID": fd["mapID"], "zone": fd.get("zone"), "spots": fd["spots"],
            "maps": fd.get("maps"), "name": fd.get("name"), "subtitle": fd.get("subtitle"), "notes": fd.get("notes") or []})
    if not wh.get("error") and wh.get("spots") and wh.get("mapID"):
        out.append({"key": "wowhead", "label": wh["source"], "mapID": wh["mapID"], "zone": wh.get("zone"),
                    "spots": wh["spots"], "url": wh.get("url")})
    return out, wh, fd, own_row


def agreement(sources, used_spot, yards=DISAGREE_YARDS):
    """Compare the source the answer uses (sources[0], at used_spot) with the next best one and all others."""
    WP = _wp()
    if not sources:
        return None
    first = sources[0]
    mid, x, y = first["mapID"], used_spot["x"], used_spot["y"]
    others = []
    for s in sources[1:]:
        d, hit = distance(mid, x, y, s)
        o = {"key": s["key"], "label": LABEL[s["key"]], "yards": None if d is None else int(round(d))}
        if hit:
            o.update(mapID=hit[0], zone=WP.maps()[hit[0]]["name"], x=hit[1]["x"], y=hit[1]["y"])
        else:
            o.update(mapID=s["mapID"], zone=s.get("zone"), x=s["spots"][0]["x"], y=s["spots"][0]["y"])
        o["agrees"] = d is not None and d <= yards
        others.append(o)
    res = {"using": first["key"], "using_label": LABEL[first["key"]], "threshold_yards": int(yards), "others": others}
    if not others:
        res["status"] = "single-source"
        return res
    runner = others[0]
    if runner["agrees"]:
        res["status"] = "agree"
    elif first["key"] == "sighting":
        res["status"] = "own-sighting-disagrees"
    else:
        res["status"] = "uncertain"
    res["runner_up"] = runner
    return res


def fix_hint(ag, name, eid, kind="npc"):
    """The plain 'help fix' line for an answer."""
    if not ag or kind != "npc":
        return None
    off = [o for o in ag.get("others") or [] if not o["agrees"]]
    if ag["status"] == "uncertain":
        return ("help fix: talk to %s once (opening its window records a sighting), then `foreverscribe correction "
                "draft %d` drafts a forever-db correction for you to send" % (name or "the NPC", eid))
    if ag["using"] == "sighting" and any(o["key"] in ("foreverdb", "wowhead") for o in off):
        return ("help fix: your sighting shows %s is wrong here; `foreverscribe correction draft %d` writes the fix "
                "(nothing is sent)" % (" and ".join(o["label"] for o in off if o["key"] in ("foreverdb", "wowhead")), eid))
    return None


def describe(ag):
    """One or two plain lines about agreement, or [] when it is unremarkable."""
    WP = _wp()
    if not ag or ag["status"] in ("agree", "single-source"):
        lines = []
    else:
        r = ag["runner_up"]
        apart = ("%d yd apart" % r["yards"]) if r["yards"] is not None else "on different maps"
        where = "%s %s, %s" % (r.get("zone") or "?", WP.num(r["x"]), WP.num(r["y"]))
        if ag["status"] == "uncertain":
            lines = ["⚠ uncertain: %s and %s disagree (%s). %s puts it at %s. This command uses %s's spot "
                     "(trust order: your sighting > shared > forever-db > Wowhead)." % (
                         ag["using_label"], r["label"], apart, r["label"], where, ag["using_label"])]
        elif r["key"] == "wowhead":
            lines = []  # the Wowhead note says it
        else:
            lines = ["⚠ sources disagree: %s is %s from where you met it (%s says %s). Using your sighting." % (
                r["label"], "%d yd off" % r["yards"] if r["yards"] is not None else "on another map", r["label"], where)]
    if ag:
        for o in ag.get("others", [])[1:]:
            if not o["agrees"] and o["key"] != "wowhead":
                lines.append("%s is %s off (%s %s, %s)." % (
                    o["label"], ("~%d yd" % o["yards"]) if o["yards"] is not None else "on another map",
                    o.get("zone") or "?", WP.num(o["x"]), WP.num(o["y"])))
    return lines

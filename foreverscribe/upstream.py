"""Correction drafts for the shared NPC databases, from where you really met an NPC in game. Nothing is ever sent.

  foreverscribe correction draft <npc id | name words> [--for CHAR] [--json]
  foreverscribe correction list
  foreverscribe npcs --disagree      (lists every disagreement and drafts the forever-db ones)

A draft needs one of your own sightings (ForeverScribe 0.5+ records one when you open an NPC's window). It writes,
under <data_dir>/upstream/:
  forever-db/npc-<id>.json    one entry in forever-db's corrections/npcs.json format: addSpawns on the Forever map
                              frame ("f": "l"), an in-game-check source with the date and client build, a note
  forever-db/npcs.json        every draft so far merged into one object, ready to paste into corrections/npcs.json
  wowhead/npc-<id>.txt        a short plain comment for the NPC's Wowhead Forever page
  README.md                   how a person submits them (a pull request to Polestar's `next` branch; Wowhead by hand)
Drafts are only files: no pull request, issue, comment or upload is made, ever.
"""
import json
import math
import os
import re
import sys
import time

from . import resolve as R

YARDS = R.DISAGREE_YARDS
KEEP_YARDS = 60  # a multi-spawn NPC's other forever-db points farther than this from the sighting are kept


def _wp():
    from . import waypoints
    return waypoints


def _npcs():
    from . import npcs
    return npcs


def out_dir():
    from . import config as C
    return os.environ.get("FOREVERSCRIBE_UPSTREAM_DIR") or os.path.join(C.load().data_dir, "upstream")


def _client_build(char_key):
    """The game build the character last played on, from its snapshot (e.g. "1.60.1.70938")."""
    try:
        from . import cli, queries as Q, store
        cfg = cli.load_config()
        con = store.connect(cfg["db"])
        try:
            snap, _ = Q.latest_snapshot(con, char_key)
        finally:
            con.close()
        c = (snap.get("identity") or {}).get("client") or {}
        v, b = c.get("version"), c.get("build")
        if v and b:
            return "%s.%s" % (v, b) if not str(v).endswith(str(b)) else str(v)
        return str(v or b or "") or None
    except Exception:
        return None


def _day(ts):
    return time.strftime("%Y-%m-%d", time.localtime(ts)) if ts else "unknown date"


def compare_sighting(row, fd=None, wh=None):
    """How forever-db and Wowhead compare with one sighting row. -> {foreverdb: {...}|None, wowhead: {...}|None}."""
    WP = _wp()
    mid, x, y = row["map_id"], float(row["x"]), float(row["y"])
    res = {}
    if fd is None:
        try:
            fd = R.FDB["locate"]("npc", row["npc_id"], mid)
        except Exception:
            fd = None
    if wh is None:
        wh = WP.locate("npc", row["npc_id"])
    for key, src in (("foreverdb", fd), ("wowhead", wh)):
        if not src or src.get("error") or not src.get("spots") or not src.get("mapID"):
            res[key] = {"status": "no position"} if src is not None else None
            continue
        d, hit = R.distance(mid, x, y, src)
        if d is None:
            res[key] = {"status": "other map", "zone": src.get("zone"), "mapID": src["mapID"],
                        "x": src["spots"][0]["x"], "y": src["spots"][0]["y"]}
        else:
            res[key] = {"status": "agrees" if d <= YARDS else "off", "yards": int(round(d)), "mapID": hit[0],
                        "zone": WP.maps()[hit[0]]["name"], "x": hit[1]["x"], "y": hit[1]["y"]}
    return res, fd, wh


def fdb_entry(row, fd, cmp_fd, build):
    """One forever-db corrections/npcs.json entry {id: {...}} for a sighting, or None when forever-db agrees."""
    WP = _wp()
    if not cmp_fd or cmp_fd.get("status") == "agrees":
        return None
    mid, x, y = row["map_id"], round(float(row["x"]), 1), round(float(row["y"]), 1)
    zone = WP.maps().get(mid, {}).get("name") or row.get("zone") or str(mid)
    name = row.get("name") or (fd or {}).get("name") or "NPC %d" % row["npc_id"]
    pts = [[x, y]]
    kept = 0
    same_map = ((fd or {}).get("maps") or {}).get(mid) or []
    if len(same_map) > 1:
        # several spawns on this map: keep the far ones (other spawns), replace only the one the sighting corrects
        near = None
        for s in same_map:
            d = R.distance(mid, x, y, {"mapID": mid, "spots": [s]})[0]
            if d is not None and (near is None or d < near[0]):
                near = (d, s)
        for s in same_map:
            if near and s is near[1]:
                continue
            d = R.distance(mid, x, y, {"mapID": mid, "spots": [s]})[0]
            if d is not None and d > KEEP_YARDS:
                pts.append([s["x"], s["y"]])
                kept += 1
    visits = int(row.get("count") or 1)
    when = _day(row.get("last_seen"))
    how = {"gossip": "talking to", "vendor": "at the vendor window of", "trainer": "at the trainer window of",
           "quest": "taking a quest from", "flightmaster": "at the flight map of", "banker": "at the bank window of",
           "auctioneer": "at the auction window of", "innkeeper": "talking to", "target": "within 10 yards of"}.get(
        row.get("kind") or "", "next to")
    if cmp_fd.get("status") == "off":
        was = "forever-db has %s %s,%s (map %d), %d yd away" % (cmp_fd["zone"], WP.num(cmp_fd["x"]), WP.num(cmp_fd["y"]),
                                                                cmp_fd["mapID"], cmp_fd["yards"])
    elif cmp_fd.get("status") == "other map":
        was = "forever-db has it on %s (map %s) at %s,%s" % (cmp_fd.get("zone") or "another map", cmp_fd.get("mapID"),
                                                            WP.num(cmp_fd["x"]), WP.num(cmp_fd["y"]))
    else:
        was = "forever-db has no position for it"
    note = ("%s (npc %d) stands at %s %s,%s (map %d, Forever's map frame): a player stood there %s them in game on %s "
            "(%d visit%s, client %s); %s. Replaces the map's points%s." % (
                name, row["npc_id"], zone, WP.num(x), WP.num(y), mid, how, when, visits, "" if visits == 1 else "s",
                build or "unknown", was, (", keeping its %d other spawn point%s" % (kept, "" if kept == 1 else "s"))
                if kept else ""))
    entry = {"addSpawns": {str(mid): {"f": "l", "pts": pts}},
             "source": {"kind": "in-game-check", "ref": "player in-game check %s, client %s" % (when, build or "unknown")},
             "note": note}
    return {str(row["npc_id"]): entry}


def wowhead_text(row, cmp_wh, build):
    WP = _wp()
    if not cmp_wh or cmp_wh.get("status") == "agrees":
        return None
    zone = WP.maps().get(row["map_id"], {}).get("name") or row.get("zone") or str(row["map_id"])
    name = row.get("name") or "This NPC"
    lines = ["%s's location in WoW: Forever (checked in game %s, client %s): %s %s, %s." % (
        name, _day(row.get("last_seen")), build or "unknown", zone, WP.num(row["x"]), WP.num(row["y"]))]
    if cmp_wh.get("status") == "off":
        lines.append("The map on this page shows %s, %s, about %d yards away." % (
            WP.num(cmp_wh["x"]), WP.num(cmp_wh["y"]), cmp_wh["yards"]))
    elif cmp_wh.get("status") == "other map":
        lines.append("The map on this page puts it in %s." % (cmp_wh.get("zone") or "another zone"))
    else:
        lines.append("This page has no map location for it yet.")
    return " ".join(lines)


def _write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(text)
    os.replace(tmp, path)
    return path


README = """# Correction drafts (not sent)

ForeverScribe wrote these from where you actually met NPCs in game. Nothing here has been sent anywhere.

- `forever-db/npcs.json`: every forever-db draft merged, in the format of Polestar's
  `forever-db/corrections/npcs.json`. To submit: fork https://github.com/fitzforge/polestar, branch from `next`,
  merge these entries into `forever-db/corrections/npcs.json` (keep its key order), run
  `forge data check-corrections`, and open a pull request to `next` following its CONTRIBUTING.md.
- `forever-db/npc-<id>.json`: the same, one file per NPC.
- `wowhead/npc-<id>.txt`: a comment for that NPC's page on wowhead.com/forever, if you want to post one yourself.

Check each spot in game before sending: a sighting is where *you* stood (within interaction range, ~5 yards).
"""


def draft_row(row, write=True, fd=None, wh=None):
    """Drafts for one sighting row. -> {npcID, name, foreverdb: entry|None, wowhead: text|None, compare, paths}."""
    build = _client_build(row.get("char_key")) if row.get("char_key") else None
    cmp_, fd, wh = compare_sighting(row, fd, wh)
    entry = fdb_entry(row, fd, cmp_.get("foreverdb"), build)
    text = wowhead_text(row, cmp_.get("wowhead"), build)
    res = {"npcID": row["npc_id"], "name": row.get("name"), "compare": cmp_, "foreverdb": entry, "wowhead": text,
           "client": build, "paths": []}
    if write and (entry or text):
        d = out_dir()
        if entry:
            res["paths"].append(_write(os.path.join(d, "forever-db", "npc-%d.json" % row["npc_id"]),
                                       json.dumps(entry, indent=1, ensure_ascii=False) + "\n"))
            res["paths"].append(_merge_batch(d, entry))
        if text:
            res["paths"].append(_write(os.path.join(d, "wowhead", "npc-%d.txt" % row["npc_id"]), text + "\n"))
        _write(os.path.join(d, "README.md"), README)
    return res


def _merge_batch(d, entry):
    p = os.path.join(d, "forever-db", "npcs.json")
    try:
        with open(p, encoding="utf-8") as f:
            doc = json.load(f)
    except (OSError, ValueError):
        doc = {}
    doc.update(entry)
    doc = {k: doc[k] for k in sorted(doc, key=lambda k: int(k) if k.isdigit() else 0)}
    return _write(p, json.dumps(doc, indent="\t", ensure_ascii=False) + "\n")


def _rows_for(target, char=None):
    N = _npcs()
    con, ck = N._open(char)
    try:
        if str(target).isdigit():
            rows = N._rows(con, "WHERE npc_id=?", (int(target),))
        else:
            want = N.fold(target)
            rows = [r for r in N._rows(con) if want and (N.fold(r.get("name")) == want or N.fold(r.get("subtitle")) == want
                                                         or (len(want) >= 4 and want in N.fold(r.get("name"))))]
    finally:
        con.close()
    rows.sort(key=lambda r: (0 if ck and r["char_key"] == ck else 1, -(r["count"] or 0), -(r["last_seen"] or 0)))
    return rows, ck


def draft(target, char=None, write=True):
    rows, ck = _rows_for(target, char)
    if not rows:
        return {"error": "no sighting of %s yet: talk to the NPC once in game (opening its window records a "
                         "sighting), /reload, then run this again" % target}
    row = rows[0]
    r = draft_row(row, write)
    r["character"] = row["char_key"].split(":")[-1]
    return r


def render(r):
    WP = _wp()
    if r.get("error"):
        return r["error"]
    c = r["compare"]
    lines = ["%s (npc=%d): your sighting vs the databases" % (r.get("name") or "?", r["npcID"])]
    for key, label in (("foreverdb", "forever-db"), ("wowhead", "Wowhead Forever")):
        v = c.get(key)
        if v is None:
            lines.append("  %s: not checked (offline?)" % label)
        elif v["status"] == "agrees":
            lines.append("  %s: agrees (%d yd)" % (label, v["yards"]))
        elif v["status"] == "off":
            lines.append("  %s: %d yd off (%s %s, %s)" % (label, v["yards"], v["zone"], WP.num(v["x"]), WP.num(v["y"])))
        elif v["status"] == "other map":
            lines.append("  %s: puts it in %s" % (label, v.get("zone") or "another zone"))
        else:
            lines.append("  %s: has no position" % label)
    if not r["foreverdb"] and not r["wowhead"]:
        lines.append("Nothing to correct: both agree with where you met it.")
    for p in r.get("paths") or []:
        lines.append("draft: " + p)
    if r.get("paths"):
        lines.append("Nothing was sent. Review, then submit by hand (see %s)." % os.path.join(out_dir(), "README.md"))
    return "\n".join(lines)


def listing():
    d = out_dir()
    out = []
    for sub in ("forever-db", "wowhead"):
        p = os.path.join(d, sub)
        if os.path.isdir(p):
            out += [os.path.join(p, f) for f in sorted(os.listdir(p)) if not f.startswith(".")]
    return out


def main(argv=None):
    a = list(sys.argv[1:] if argv is None else argv)
    opt = {"for": None, "json": False}
    words = []
    while a:
        x = a.pop(0)
        if x in ("--for", "--char", "-c") and a:
            opt["for"] = a.pop(0)
        elif x == "--json":
            opt["json"] = True
        elif x in ("-h", "--help"):
            print(__doc__)
            return 0
        else:
            words.append(x)
    cmd = words.pop(0) if words else ""
    if cmd == "list":
        files = listing()
        print(json.dumps(files, indent=2) if opt["json"] else ("\n".join(files) or "no drafts yet"))
        return 0
    if cmd == "draft" and words:
        target = " ".join(words)
        m = re.match(r"^npc\s*[=:#]?\s*(\d+)$", target, re.I)
        r = draft(m.group(1) if m else target, opt["for"])
        print(json.dumps(r, indent=2, ensure_ascii=False) if opt["json"] else render(r))
        return 3 if r.get("error") else 0
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main())

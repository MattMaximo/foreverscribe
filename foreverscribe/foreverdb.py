"""forever-db: Polestar's open World of Warcraft: Forever database, used as one location source.

forever-db (https://github.com/fitzforge/polestar/tree/next/forever-db) publishes spawn points for every NPC and
object in world yards (`spawn.jsonl`) and the client's map frames (`ui_map.jsonl`). ForeverScribe turns those into
map percentages on Forever's own map frame, the frame `/scribe way` and the game's map pins use.

Licence: the tables used here (npc, object, spawn, ui_map) are GPL-3.0-only (its datapackage.json; the CC BY 4.0 part
is the step/mechanic/note layer, not used here). So nothing of forever-db is committed to this MIT repository: the
tables are fetched at runtime from one pinned release, checked against the release's sha256, and cached under
<data_dir>/forever-db/<version>/ on the user's own computer. Credits: README "Data sources" and NOTICE.md.

  foreverscribe foreverdb status | fetch | npc <id> | object <id> | find <name words>
"""
import hashlib
import json
import math
import os
import re
import sqlite3
import sys
import time
import urllib.request

RELEASE = "2026.11.1"
TAG = "data-v" + RELEASE
CLIENT_BUILD = "1.60.1.70532"
BASE = "https://raw.githubusercontent.com/fitzforge/polestar/%s/forever-db/data/" % TAG
SOURCE_URL = "https://github.com/fitzforge/polestar/tree/%s/forever-db" % TAG
# sha256 of each table in that release (its datapackage.json); a download that doesn't match is refused.
TABLES = {
    "ui_map": "f821be399a88e49b6891a251c71578aabd894bb63283b07aa0aa2e8025f26bb7",
    "npc": "5d4fed605cb3204f48fc7dc305a5c5b297d4396ec48b981d9b305beb7da521b5",
    "object": "09d1bd6e02e581eca0f716ab56e3e29c78c82ccdc23914f21ca608bafa04e307",
    "spawn": "2ecaa55108a163145e731e6ea24edf57417522a430bada8c93898274b11e9851",
}
# forever-db's own corrections (corrections/npcs.json, objects.json: `addSpawns` replace a map's points), which
# Polestar applies when it builds; pinned to one commit of its `next` branch, newer than the release's tables.
CORRECTIONS_COMMIT = "f93a8ee442f50f97dc805baafe6dda7d823d6ba1"
CORRECTIONS_BASE = "https://raw.githubusercontent.com/fitzforge/polestar/%s/forever-db/corrections/" % CORRECTIONS_COMMIT
CORRECTIONS = {
    "npcs": "2f5506dca1fc71dcd9e2ecb431ac0eb5a493a46674d0475c0a65c184af497c7d",
    "objects": "43941b6f6da716bcd311e48d7586ba55a8b2e5127412dc88b220ba622999e428",
}
INDEX_VERSION = 2
CLUSTER = 2.5  # map percent: spawn points closer than this are one spot
MIN_EDGE = 3.0  # map percent: a preferred map must hold a point at least this far inside its frame
RETRY_AFTER = 6 * 3600  # after a failed download, don't try again for this long
ATTRIBUTION = ("forever-db %s (Polestar, GPL-3.0; github.com/fitzforge/polestar)" % RELEASE)

_STATE = {"path": None}


def _download(url, timeout=60):
    req = urllib.request.Request(url, headers={"User-Agent": "ForeverScribe"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.read()


FETCH = {"get": _download}  # tests swap this


def cache_dir(data_dir=None):
    env = os.environ.get("FOREVERSCRIBE_FOREVERDB_DIR")
    if env:
        return env
    if data_dir is None:
        from . import config as C
        data_dir = C.load().data_dir
    return os.path.join(data_dir, "forever-db", RELEASE)


def index_path(data_dir=None):
    return os.path.join(cache_dir(data_dir), "index.sqlite")


def _build(d, raw):
    """raw: table -> bytes (verified). Writes index.sqlite atomically."""
    tmp = os.path.join(d, ".index.sqlite.tmp.%d" % os.getpid())
    if os.path.exists(tmp):
        os.remove(tmp)
    con = sqlite3.connect(tmp)
    con.executescript("""
        CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT);
        CREATE TABLE names (kind TEXT, id INTEGER, name TEXT, sub TEXT, fold TEXT, subfold TEXT, PRIMARY KEY (kind, id));
        CREATE TABLE spawns (kind TEXT, id INTEGER, map INTEGER, n INTEGER, x REAL, y REAL, z REAL);
        CREATE TABLE frames (ui_map INTEGER PRIMARY KEY, map INTEGER, bottom REAL, top REAL, left REAL, right REAL);
        CREATE TABLE fixes (kind TEXT, id INTEGER, ui_map INTEGER, frame TEXT, pts TEXT, note TEXT, PRIMARY KEY (kind, id, ui_map));
    """)
    for fname, kind in (("npcs", "npc"), ("objects", "object")):
        doc = json.loads(raw.get("corrections/" + fname, b"{}").decode("utf-8"))
        rows = []
        for k, v in doc.items():
            if not k.isdigit() or not isinstance(v, dict):
                continue
            for m, a in (v.get("addSpawns") or {}).items():
                if str(m).isdigit() and isinstance(a, dict) and isinstance(a.get("pts"), list):
                    pts = [[float(p[0]), float(p[1])] for p in a["pts"] if isinstance(p, list) and len(p) >= 2]
                    if pts:
                        rows.append((kind, int(k), int(m), a.get("f") or "l", json.dumps(pts), (v.get("note") or "")[:400]))
        con.executemany("INSERT OR REPLACE INTO fixes VALUES (?,?,?,?,?,?)", rows)
    for kind in ("npc", "object"):
        rows = []
        for line in raw[kind].decode("utf-8").splitlines():
            if not line.strip():
                continue
            r = json.loads(line)
            name, sub = r.get("name") or "", r.get("subname") or ""
            rows.append((kind, int(r["id"]), name, sub, fold(name), fold(sub)))
        con.executemany("INSERT OR REPLACE INTO names VALUES (?,?,?,?,?,?)", rows)
    rows = []
    for line in raw["spawn"].decode("utf-8").splitlines():
        if line.strip():
            r = json.loads(line)
            rows.append((r["kind"], int(r["id"]), int(r["map"]), int(r.get("n") or 0), float(r["x"]), float(r["y"]),
                         r.get("z")))
    con.executemany("INSERT INTO spawns VALUES (?,?,?,?,?,?,?)", rows)
    rows = []
    for line in raw["ui_map"].decode("utf-8").splitlines():
        if line.strip():
            r = json.loads(line)
            rows.append((int(r["ui_map"]), int(r["map"]), float(r["bottom"]), float(r["top"]), float(r["left"]), float(r["right"])))
    con.executemany("INSERT INTO frames VALUES (?,?,?,?,?,?)", rows)
    con.execute("CREATE INDEX spawns_id ON spawns (kind, id)")
    con.execute("CREATE INDEX names_fold ON names (fold)")
    con.executemany("INSERT INTO meta VALUES (?,?)", [("release", RELEASE), ("index_version", str(INDEX_VERSION)),
                                                      ("built_at", str(int(time.time()))), ("client_build", CLIENT_BUILD)])
    con.commit()
    con.close()
    os.replace(tmp, os.path.join(d, "index.sqlite"))


def ensure(data_dir=None, fetch=True):
    """Path to the local index, downloading the pinned release once if needed. None when unavailable (offline,
    hash mismatch, disabled with FOREVERSCRIBE_FOREVERDB=off). Never raises."""
    if os.environ.get("FOREVERSCRIBE_FOREVERDB", "").lower() in ("off", "0", "no"):
        return None
    try:
        d = cache_dir(data_dir)
        p = os.path.join(d, "index.sqlite")
        if os.path.exists(p) and _index_version(p) == INDEX_VERSION:
            return p
        if not fetch:
            return None
        os.makedirs(d, exist_ok=True)
        fail = os.path.join(d, "last-failure.txt")
        if os.path.exists(fail) and time.time() - os.path.getmtime(fail) < RETRY_AFTER:
            return None
        raw = {}
        for t, sha in TABLES.items():
            data = FETCH["get"](BASE + t + ".jsonl")
            got = hashlib.sha256(data).hexdigest()
            if got != sha:
                raise ValueError("%s.jsonl sha256 %s is not release %s's %s" % (t, got[:12], RELEASE, sha[:12]))
            raw[t] = data
        for t, sha in CORRECTIONS.items():
            data = FETCH["get"](CORRECTIONS_BASE + t + ".json")
            got = hashlib.sha256(data).hexdigest()
            if got != sha:
                raise ValueError("corrections/%s.json sha256 %s is not the pinned %s" % (t, got[:12], sha[:12]))
            raw["corrections/" + t] = data
        _build(d, raw)
        if os.path.exists(fail):
            os.remove(fail)
        return p
    except Exception as e:  # a location source is optional; never block an answer
        try:
            with open(os.path.join(cache_dir(data_dir), "last-failure.txt"), "w") as f:
                f.write("%s %s\n" % (time.strftime("%Y-%m-%d %H:%M"), e))
        except OSError:
            pass
        return None


def _index_version(p):
    try:
        con = sqlite3.connect(p)
        try:
            row = con.execute("SELECT value FROM meta WHERE key='index_version'").fetchone()
        finally:
            con.close()
        return int(row[0]) if row else 0
    except (sqlite3.Error, ValueError):
        return 0


def _con(data_dir=None, fetch=True):
    p = ensure(data_dir, fetch)
    if not p:
        return None
    con = sqlite3.connect(p)
    con.row_factory = sqlite3.Row
    return con


def fold(s):
    return re.sub(r"[^a-z0-9]", "", (s or "").lower())


# ---------- world yards -> Forever map percent ----------
def _maps():
    from . import waypoints as WP
    return WP.maps()


def frame_point(ui_map, wx, wy):
    """World yards -> (x%, y%) on ui_map's Forever frame, or None when the map has no frame."""
    v = _maps().get(ui_map)
    if not v or not v.get("bounds"):
        return None
    min_x, min_y, max_x, max_y = v["bounds"]
    return (max_y - wy) / (max_y - min_y) * 100.0, (max_x - wx) / (max_x - min_x) * 100.0


def to_ui(world_map, wx, wy, prefer=None):
    """(uiMapID, x%, y%) for a spawn, or None when no frame holds it (inside an instance).

    Zone frames are rectangles and overlap a lot at their edges (Raene Wolfrunner in Astranaar also lies at the top
    edge of Stonetalon's frame; Auberdine inside Felwood's), so "the smallest frame" is often the wrong zone. The
    zone/city frame that holds the point most centrally wins (largest distance to its nearest edge, in percent);
    `prefer` (a map another source names, e.g. Wowhead's) wins when it holds the point at least MIN_EDGE in."""
    inside = []
    for mid, v in _maps().items():
        if v.get("continent_map") != world_map or not v.get("bounds"):
            continue
        p = frame_point(mid, wx, wy)
        if p and 0 <= p[0] <= 100 and 0 <= p[1] <= 100:
            edge = min(p[0], 100 - p[0], p[1], 100 - p[1])
            inside.append((mid, p, edge, v.get("type")))
    if not inside:
        return None
    if prefer is not None:
        for mid, p, edge, _ in inside:
            if mid == prefer and edge >= MIN_EDGE:
                return mid, round(p[0], 1), round(p[1], 1)
    zones = [t for t in inside if t[3] in (3, 4, 5, 6)] or inside
    zones.sort(key=lambda t: -t[2])
    mid, p = zones[0][0], zones[0][1]
    return mid, round(p[0], 1), round(p[1], 1)


# ---------- lookups ----------
def record(kind, eid, data_dir=None, fetch=True):
    """{kind, id, name, subtitle, spawns: [{map, x, y, z}]} or None (unknown id or no index)."""
    con = _con(data_dir, fetch)
    if con is None:
        return None
    try:
        n = con.execute("SELECT * FROM names WHERE kind=? AND id=?", (kind, int(eid))).fetchone()
        sp = [dict(r) for r in con.execute("SELECT map, x, y, z FROM spawns WHERE kind=? AND id=? ORDER BY map, n",
                                           (kind, int(eid)))]
        fx = [dict(r) for r in con.execute("SELECT ui_map, frame, pts, note FROM fixes WHERE kind=? AND id=?",
                                           (kind, int(eid)))]
    finally:
        con.close()
    if not n and not sp and not fx:
        return None
    for f in fx:
        f["pts"] = json.loads(f["pts"])
    return {"kind": kind, "id": int(eid), "name": n["name"] if n else None, "subtitle": n["sub"] if n else "",
            "spawns": sp, "fixes": fx}


def locate(kind, eid, prefer=None, data_dir=None, fetch=True):
    """Where forever-db puts an NPC/object, on Forever's map: {name, subtitle, maps: {uiMapID: [spots]}, mapID (the
    preferred map if it has spots there, else the one with most spawns), spots, source, notes}. None if unknown."""
    rec = record(kind, eid, data_dir, fetch)
    if rec is None:
        return None
    by_map, instanced = {}, 0
    for s in rec["spawns"]:
        u = to_ui(s["map"], s["x"], s["y"], prefer)
        if not u:
            instanced += 1
            continue
        by_map.setdefault(u[0], []).append((u[1], u[2]))
    from . import waypoints as WP
    fixed = {}
    for f in rec.get("fixes") or []:
        if f["ui_map"] not in _maps():
            continue
        pts = [WP.era_to_forever(f["ui_map"], p[0], p[1]) if f["frame"] == "e" else (p[0], p[1]) for p in f["pts"]]
        fixed[f["ui_map"]] = [(round(x, 1), round(y, 1)) for x, y in pts]
    if fixed and len(rec["spawns"]) <= 1:
        by_map, instanced = {}, 0  # one spawn, corrected elsewhere: the corrected spot is where it stands
    for mid, pts in fixed.items():
        by_map[mid] = pts  # a correction replaces that map's points
    out = {"kind": kind, "id": rec["id"], "name": rec["name"], "subtitle": rec["subtitle"], "source": ATTRIBUTION,
           "spawn_count": len(rec["spawns"]), "notes": [], "maps": {}, "corrected": sorted(fixed)}
    for mid, pts in by_map.items():
        spots = []
        for x, y in pts:
            for c in spots:
                if math.hypot(c["x"] - x, c["y"] - y) <= CLUSTER:
                    n = c["points"]
                    c["x"], c["y"] = round((c["x"] * n + x) / (n + 1), 1), round((c["y"] * n + y) / (n + 1), 1)
                    c["points"] += 1
                    break
            else:
                spots.append({"x": x, "y": y, "floor": "0", "points": 1,
                              "frames": ["forever-db correction" if mid in fixed else "forever-db spawn"]})
        spots.sort(key=lambda c: -c["points"])
        out["maps"][mid] = spots
    if instanced and not by_map:
        out["notes"].append("forever-db has %d spawn point%s for it, all inside an instance (no map frame)." % (
            instanced, "" if instanced == 1 else "s"))
    if out["maps"]:
        clusters = out["maps"]
        mid = prefer if prefer in clusters else max(clusters, key=lambda m: (m in fixed, sum(c["points"] for c in clusters[m])))
        out["mapID"], out["spots"] = mid, clusters[mid]
        out["zone"] = _maps()[mid]["name"]
    else:
        out["mapID"], out["spots"], out["zone"] = None, [], None
    return out


def find(words, kind=None, data_dir=None, fetch=True, limit=10):
    """Exact (folded) name or subtitle matches: [{kind, id, name, subtitle, spawns}] most spawns first."""
    want = fold(" ".join(words) if isinstance(words, (list, tuple)) else words)
    if not want:
        return []
    con = _con(data_dir, fetch)
    if con is None:
        return []
    try:
        q = ("SELECT n.kind, n.id, n.name, n.sub, n.fold = ? AS exact, (SELECT COUNT(*) FROM spawns s WHERE s.kind=n.kind"
             " AND s.id=n.id) AS spawns FROM names n WHERE (n.fold = ? OR n.subfold = ?)")
        args = [want, want, want]
        if kind:
            q += " AND n.kind = ?"
            args.append(kind)
        rows = [dict(r) for r in con.execute(q + " ORDER BY exact DESC, spawns DESC LIMIT ?", args + [limit])]
    finally:
        con.close()
    return [{"kind": r["kind"], "id": r["id"], "name": r["name"], "subtitle": r["sub"], "spawns": r["spawns"],
             "exact_name": bool(r["exact"])} for r in rows if r["spawns"]]


def status(data_dir=None):
    d = cache_dir(data_dir)
    p = os.path.join(d, "index.sqlite")
    out = {"release": RELEASE, "tag": TAG, "cache": d, "ready": os.path.exists(p), "source": SOURCE_URL,
           "licence": "GPL-3.0-only (npc, object, spawn, ui_map tables); fetched at runtime, never committed"}
    if out["ready"]:
        con = sqlite3.connect(p)
        try:
            out["spawns"] = con.execute("SELECT COUNT(*) FROM spawns").fetchone()[0]
            out["names"] = con.execute("SELECT COUNT(*) FROM names").fetchone()[0]
        finally:
            con.close()
        out["size_bytes"] = os.path.getsize(p)
    fail = os.path.join(d, "last-failure.txt")
    if os.path.exists(fail):
        with open(fail) as f:
            out["last_failure"] = f.read().strip()
    return out


def main(argv=None):
    a = list(sys.argv[1:] if argv is None else argv)
    cmd = a.pop(0) if a else "status"
    if cmd == "status":
        print(json.dumps(status(), indent=2))
        return 0
    if cmd == "fetch":
        fail = os.path.join(cache_dir(), "last-failure.txt")
        if os.path.exists(fail):
            os.remove(fail)
        p = ensure()
        print(("forever-db %s ready: %s" % (RELEASE, p)) if p else ("could not fetch forever-db: %s" % status().get("last_failure")))
        return 0 if p else 1
    if cmd in ("npc", "object") and a and a[0].isdigit():
        print(json.dumps(locate(cmd, int(a[0])), indent=2, ensure_ascii=False))
        return 0
    if cmd == "find" and a:
        print(json.dumps(find(a), indent=2, ensure_ascii=False))
        return 0
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main())

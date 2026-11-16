"""SQLite store and idempotent ingest for ForeverScribe data.

Sources:
  * SavedVariables files (ForeverScribe.lua) — full snapshots + event log.
  * Live JSONL lines from live_capture.py — events only, low latency.

Every event carries a globally unique id ("<session>:<seq>"), so re-ingesting
the same file, a later file that still contains old events, or a live line
that later also arrives via SavedVariables never duplicates anything.
"""

import fnmatch
import glob
import hashlib
import json
import os
import sqlite3
import time

from .svparse import SVParseError, parse_file

SCHEMA_VERSION = 1

SCHEMA = """
CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT);
CREATE TABLE IF NOT EXISTS characters (
    char_key TEXT PRIMARY KEY, realm TEXT, name TEXT, class TEXT, race TEXT, faction TEXT,
    level INTEGER, last_captured_at INTEGER, last_event_at INTEGER, last_live_at INTEGER,
    last_ingest_at INTEGER, source_path TEXT, source_mtime INTEGER, account TEXT
);
CREATE TABLE IF NOT EXISTS snapshots (
    id INTEGER PRIMARY KEY, char_key TEXT NOT NULL, captured_at INTEGER NOT NULL, session TEXT,
    sha256 TEXT NOT NULL, json TEXT NOT NULL, ingested_at INTEGER NOT NULL, source_path TEXT,
    UNIQUE (char_key, sha256)
);
CREATE INDEX IF NOT EXISTS snapshots_char_time ON snapshots (char_key, captured_at);
CREATE TABLE IF NOT EXISTS events (
    event_id TEXT PRIMARY KEY, char_key TEXT NOT NULL, session TEXT, seq INTEGER, type TEXT NOT NULL,
    t INTEGER, payload_json TEXT, source TEXT, confidence TEXT, schema INTEGER, ctx_json TEXT,
    origin TEXT, ingested_at INTEGER
);
CREATE INDEX IF NOT EXISTS events_char_time ON events (char_key, t);
CREATE INDEX IF NOT EXISTS events_type ON events (char_key, type);
CREATE TABLE IF NOT EXISTS sessions (
    session_id TEXT PRIMARY KEY, char_key TEXT NOT NULL, start INTEGER, last INTEGER, ended INTEGER,
    level INTEGER, level_end INTEGER, xp INTEGER, xp_end INTEGER, money INTEGER, money_end INTEGER, events INTEGER
);
CREATE TABLE IF NOT EXISTS quests_completed (
    char_key TEXT NOT NULL, quest_id INTEGER NOT NULL, title TEXT, completed_at INTEGER,
    first_seen_at INTEGER, source TEXT, PRIMARY KEY (char_key, quest_id)
);
CREATE TABLE IF NOT EXISTS quest_titles (quest_id INTEGER PRIMARY KEY, title TEXT, level INTEGER, zone TEXT);
CREATE TABLE IF NOT EXISTS items (
    char_key TEXT NOT NULL, location TEXT NOT NULL, item_id INTEGER NOT NULL, name TEXT, count INTEGER,
    quality INTEGER, ilvl INTEGER, req_level INTEGER, equip_loc TEXT, slot TEXT, link TEXT, json TEXT,
    captured_at INTEGER, PRIMARY KEY (char_key, location, item_id, slot)
);
CREATE TABLE IF NOT EXISTS professions (
    char_key TEXT NOT NULL, skill_name TEXT NOT NULL, skill_id INTEGER, rank INTEGER, max_rank INTEGER,
    grp TEXT, updated_at INTEGER, PRIMARY KEY (char_key, skill_name)
);
CREATE TABLE IF NOT EXISTS recipes (
    char_key TEXT NOT NULL, profession TEXT NOT NULL, recipe_key TEXT NOT NULL, recipe_id INTEGER, name TEXT,
    difficulty INTEGER, skill_ups INTEGER, output_item INTEGER, reagents_json TEXT, scanned_at INTEGER,
    PRIMARY KEY (char_key, profession, recipe_key)
);
CREATE TABLE IF NOT EXISTS flight_paths (
    char_key TEXT NOT NULL, name TEXT NOT NULL, node_id INTEGER, continent INTEGER, first_seen INTEGER,
    baseline INTEGER, PRIMARY KEY (char_key, name)
);
CREATE TABLE IF NOT EXISTS ingest_runs (
    id INTEGER PRIMARY KEY, started_at INTEGER, finished_at INTEGER, source_path TEXT, kind TEXT,
    sha256 TEXT, size INTEGER, status TEXT, chars INTEGER, events_new INTEGER, events_dup INTEGER, error TEXT
);
CREATE INDEX IF NOT EXISTS ingest_runs_sha ON ingest_runs (sha256, status);
CREATE TABLE IF NOT EXISTS live_offsets (path TEXT PRIMARY KEY, offset INTEGER, inode INTEGER);
CREATE TABLE IF NOT EXISTS sections (
    char_key TEXT NOT NULL, section TEXT NOT NULL, captured_at INTEGER, sha256 TEXT, json TEXT NOT NULL,
    ingested_at INTEGER, PRIMARY KEY (char_key, section)
);
CREATE TABLE IF NOT EXISTS raw_files (
    path TEXT PRIMARY KEY, account TEXT, name TEXT, sha256 TEXT, size INTEGER, mtime INTEGER, ingested_at INTEGER,
    parser TEXT, status TEXT
);
CREATE TABLE IF NOT EXISTS npc_sightings (
    char_key TEXT NOT NULL, npc_id INTEGER NOT NULL, map_id INTEGER NOT NULL, name TEXT, subtitle TEXT,
    x REAL, y REAL, count INTEGER, first_seen INTEGER, last_seen INTEGER, kind TEXT, zone TEXT, subzone TEXT,
    radius INTEGER, spots TEXT, ingested_at INTEGER, PRIMARY KEY (char_key, npc_id, map_id)
);
CREATE INDEX IF NOT EXISTS npc_sightings_npc ON npc_sightings (npc_id);
CREATE TABLE IF NOT EXISTS section_history (
    char_key TEXT NOT NULL, section TEXT NOT NULL, captured_at INTEGER, sha256 TEXT NOT NULL, json TEXT NOT NULL,
    ingested_at INTEGER, PRIMARY KEY (char_key, section, sha256)
);
"""

# Character-level sections added in addon v0.2 (stored outside the snapshot table).
SECTIONS = ("reputation", "legacy", "achievements", "statistics", "explored", "titles", "collections", "currencies",
            "equipmentSets", "lockouts", "mail",
            # v0.3: warm tier
            "mailPending", "auctions", "vendors",
            # v0.3: cold tier (only exposed through `cold ...`)
            "addons", "bindings", "actionbars", "macros")
COLD_SECTIONS = ("addons", "bindings", "actionbars", "macros")
# Small sections whose every distinct version is kept (big ones change every session; their events cover history).
HISTORY_SECTIONS = ("reputation", "legacy", "titles", "currencies", "lockouts", "equipmentSets", "auctions", "mailPending")


def _section_size(name, v):
    """How much real data a section holds; 0 means an empty (teardown / not loaded) read."""
    if not isinstance(v, dict):
        return 0
    if name == "reputation":
        return len(_as_list(v.get("factions")))
    if name == "legacy":
        return len(_as_list(v.get("trees"))) + (1 if v.get("track") else 0)
    if name == "achievements":
        return v.get("total") or len(_as_dict(v.get("list")))
    if name == "statistics":
        return v.get("count") or len(_as_dict(v.get("values")))
    if name == "explored":
        return len(_as_dict(v.get("zones")))
    if name == "titles":
        return v.get("count") or len(_as_dict(v.get("known")))
    if name == "collections":
        return (v.get("numMounts") or 0) + (v.get("numPets") or 0) + (v.get("numToys") or 0)
    if name in ("currencies", "lockouts"):
        return len(_as_list(v.get("list"))) or (1 if v.get("scannedAt") else 0)
    if name == "equipmentSets":
        return len(_as_list(v.get("sets"))) or (1 if v.get("scannedAt") else 0)
    if name in ("mail", "mailPending", "auctions", "addons", "bindings", "actionbars", "macros"):
        return 1 if (v.get("capturedAt") or v.get("scannedAt")) else 0
    if name == "vendors":
        return len(_as_dict(v.get("npcs")))
    return len(v)


def _section_time(v, fallback):
    if isinstance(v, dict):
        for k in ("scannedAt", "capturedAt"):
            if isinstance(v.get(k), (int, float)):
                return int(v[k])
    return fallback


def _store_sections(con, char_key, c, fallback_at, now):
    for name in SECTIONS:
        v = c.get(name)
        size = _section_size(name, v)
        if size == 0:
            continue  # an empty read never replaces stored data
        at = _section_time(v, fallback_at)
        js = _j(v)
        sha = hashlib.sha256(js.encode("utf-8")).hexdigest()
        row = con.execute("SELECT captured_at, json FROM sections WHERE char_key=? AND section=?", (char_key, name)).fetchone()
        if row:
            if (row["captured_at"] or 0) > (at or 0):
                continue  # an older file arriving late
            old = json.loads(row["json"])
            # A much smaller read of a growing section is a partial/teardown read; keep the fuller one.
            if name in ("achievements", "explored", "collections", "titles") and size * 2 < _section_size(name, old):
                continue
        con.execute("INSERT INTO sections (char_key, section, captured_at, sha256, json, ingested_at) VALUES (?,?,?,?,?,?)"
                    " ON CONFLICT(char_key, section) DO UPDATE SET captured_at=excluded.captured_at,"
                    " sha256=excluded.sha256, json=excluded.json, ingested_at=excluded.ingested_at",
                    (char_key, name, at, sha, js, now))
        if name in HISTORY_SECTIONS:
            con.execute("INSERT OR IGNORE INTO section_history (char_key, section, captured_at, sha256, json, ingested_at)"
                        " VALUES (?,?,?,?,?,?)", (char_key, name, at, sha, js, now))


def _num(v, lo=None, hi=None):
    if isinstance(v, bool) or not isinstance(v, (int, float)):
        return None
    if (lo is not None and v < lo) or (hi is not None and v > hi):
        return None
    return v


def _store_npcs(con, char_key, npcs, now):
    """Addon 0.5 NPC sightings (chars[key].npcs["<npcID>:<mapID>"]). The newer sighting of an NPC on a map wins;
    an older file arriving late never rolls a newer one back."""
    for e in _as_dict(npcs).values():
        if not isinstance(e, dict):
            continue
        nid, mid = _num(e.get("id"), 1), _num(e.get("map"), 1)
        x, y = _num(e.get("x"), 0, 100), _num(e.get("y"), 0, 100)
        if not (isinstance(nid, int) and isinstance(mid, int) and x is not None and y is not None):
            continue
        spots = [{"x": s.get("x"), "y": s.get("y"), "n": s.get("n"), "t": s.get("t")} for s in _as_list(e.get("spots"))
                 if isinstance(s, dict) and _num(s.get("x"), 0, 100) is not None and _num(s.get("y"), 0, 100) is not None]
        last = _num(e.get("t")) or 0
        row = con.execute("SELECT last_seen, count FROM npc_sightings WHERE char_key=? AND npc_id=? AND map_id=?",
                          (char_key, nid, mid)).fetchone()
        if row and (row["last_seen"] or 0) > last:
            continue
        name = e.get("name") if isinstance(e.get("name"), str) else None
        sub = e.get("sub") if isinstance(e.get("sub"), str) else None
        con.execute(
            "INSERT INTO npc_sightings (char_key, npc_id, map_id, name, subtitle, x, y, count, first_seen, last_seen, kind,"
            " zone, subzone, radius, spots, ingested_at) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)"
            " ON CONFLICT(char_key, npc_id, map_id) DO UPDATE SET name=COALESCE(excluded.name, npc_sightings.name),"
            " subtitle=COALESCE(excluded.subtitle, npc_sightings.subtitle), x=excluded.x, y=excluded.y,"
            " count=MAX(excluded.count, npc_sightings.count), first_seen=MIN(COALESCE(npc_sightings.first_seen, excluded.first_seen),"
            " COALESCE(excluded.first_seen, npc_sightings.first_seen)), last_seen=excluded.last_seen, kind=excluded.kind,"
            " zone=COALESCE(excluded.zone, npc_sightings.zone), subzone=COALESCE(excluded.subzone, npc_sightings.subzone),"
            " radius=excluded.radius, spots=excluded.spots, ingested_at=excluded.ingested_at",
            (char_key, nid, mid, name, sub, float(x), float(y), int(_num(e.get("n"), 0) or 1), _num(e.get("first")), last,
             e.get("kind") if isinstance(e.get("kind"), str) else None,
             e.get("zone") if isinstance(e.get("zone"), str) else None,
             e.get("subzone") if isinstance(e.get("subzone"), str) else None,
             int(_num(e.get("r"), 1, 200) or 5), _j(spots), now))


def connect(path):
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    con = sqlite3.connect(path, timeout=30)
    con.row_factory = sqlite3.Row
    con.execute("PRAGMA journal_mode=WAL")
    con.execute("PRAGMA foreign_keys=ON")
    con.executescript(SCHEMA)
    con.execute("INSERT OR IGNORE INTO meta (key, value) VALUES ('schema', ?)", (str(SCHEMA_VERSION),))
    con.commit()
    return con


def _j(v):
    return json.dumps(v, ensure_ascii=False, sort_keys=True, separators=(",", ":"))


def _as_list(v):
    if v is None:
        return []
    if isinstance(v, list):
        return v
    if isinstance(v, dict):
        return [v[k] for k in sorted(v, key=lambda x: (not isinstance(x, int), str(x)))]
    return []


def _as_dict(v):
    if isinstance(v, dict):
        return v
    if isinstance(v, list):
        return {i + 1: x for i, x in enumerate(v)}
    return {}


def _account_from_path(path):
    parts = os.path.abspath(path).split(os.sep)
    for marker in ("Account", "sv", "inbox"):
        if marker in parts:
            i = parts.index(marker)
            if i + 1 < len(parts) - 1:
                return parts[i + 1]
    return None


def _split_id(eid):
    if ":" in eid:
        s, _, q = eid.rpartition(":")
        try:
            return s, int(q)
        except ValueError:
            return s, None
    return eid, None


def _insert_event(con, char_key, ev, origin, now):
    eid = ev.get("id")
    if not eid or not ev.get("type"):
        return None
    session, seq = _split_id(str(eid))
    cur = con.execute(
        "INSERT OR IGNORE INTO events (event_id, char_key, session, seq, type, t, payload_json, source,"
        " confidence, schema, ctx_json, origin, ingested_at) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)",
        (str(eid), char_key, session, seq, ev.get("type"), ev.get("t"), _j(ev.get("payload") or {}),
         ev.get("source"), ev.get("confidence"), ev.get("schema"), _j(ev.get("ctx") or {}), origin, now))
    new = cur.rowcount == 1
    if ev.get("type") == "QUEST_COMPLETED":
        p = ev.get("payload") or {}
        qid = p.get("questID")
        if isinstance(qid, int):
            con.execute(
                "INSERT INTO quests_completed (char_key, quest_id, title, completed_at, first_seen_at, source)"
                " VALUES (?,?,?,?,?, 'event') ON CONFLICT(char_key, quest_id) DO UPDATE SET"
                " title=COALESCE(quests_completed.title, excluded.title),"
                " completed_at=COALESCE(quests_completed.completed_at, excluded.completed_at)",
                (char_key, qid, p.get("title"), ev.get("t"), ev.get("t")))
            if p.get("title"):
                con.execute("INSERT INTO quest_titles (quest_id, title) VALUES (?,?) ON CONFLICT(quest_id)"
                            " DO UPDATE SET title=excluded.title", (qid, p.get("title")))
    if ev.get("type") in ("QUEST_ACCEPTED", "QUEST_ABANDONED", "QUEST_PROGRESS"):
        p = ev.get("payload") or {}
        if isinstance(p.get("questID"), int) and p.get("title"):
            con.execute("INSERT INTO quest_titles (quest_id, title) VALUES (?,?) ON CONFLICT(quest_id)"
                        " DO UPDATE SET title=excluded.title", (p["questID"], p["title"]))
    return new


def _ensure_char(con, char_key, now):
    con.execute("INSERT OR IGNORE INTO characters (char_key, last_ingest_at) VALUES (?, ?)", (char_key, now))


def _degraded(snap):
    """A snapshot taken while the client tears down the UI (logout / leaving world):
    bags read as 0 slots, no equipment, xpMax 0. Keep it in history, never as current state."""
    bags = snap.get("bags") if isinstance(snap.get("bags"), dict) else {}
    return (not bags.get("slots")) and not _as_dict(snap.get("equipment")) and not snap.get("xpMax")


def _apply_current(con, char_key, c, snap, captured_at, now):
    """Replace the 'current state' tables from the newest snapshot."""
    ident = snap.get("identity") or {}
    realm, _, name = char_key.partition(":")
    con.execute(
        "UPDATE characters SET realm=?, name=?, class=COALESCE(?, class), race=COALESCE(?, race),"
        " faction=COALESCE(?, faction), level=?, last_captured_at=? WHERE char_key=?",
        (realm, name, ident.get("class"), ident.get("race"), ident.get("faction"), snap.get("level"),
         captured_at, char_key))

    con.execute("DELETE FROM items WHERE char_key=? AND location IN ('bags','equipped')", (char_key,))
    for slot, it in _as_dict(snap.get("equipment")).items():
        if not isinstance(it, dict) or not it.get("itemID"):
            continue
        con.execute(
            "INSERT OR REPLACE INTO items (char_key, location, item_id, name, count, quality, ilvl, req_level,"
            " equip_loc, slot, link, json, captured_at) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)",
            (char_key, "equipped", it.get("itemID"), it.get("name"), 1, it.get("quality"), it.get("ilvl"),
             it.get("reqLevel"), it.get("equipLoc"), str(slot), it.get("link"), _j(it), captured_at))
    bags = snap.get("bags") or {}
    for iid, it in _as_dict(bags.get("items")).items():
        if not isinstance(it, dict):
            continue
        con.execute(
            "INSERT OR REPLACE INTO items (char_key, location, item_id, name, count, quality, ilvl, req_level,"
            " equip_loc, slot, link, json, captured_at) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)",
            (char_key, "bags", it.get("itemID") or iid, it.get("name"), it.get("count"), it.get("quality"),
             it.get("ilvl"), it.get("reqLevel"), it.get("equipLoc"), "", it.get("link"), _j(it), captured_at))
    bank = c.get("bank")
    if isinstance(bank, dict) and bank.get("items") is not None:
        con.execute("DELETE FROM items WHERE char_key=? AND location='bank'", (char_key,))
        for iid, it in _as_dict(bank.get("items")).items():
            if isinstance(it, dict):
                con.execute(
                    "INSERT OR REPLACE INTO items (char_key, location, item_id, name, count, quality, ilvl,"
                    " req_level, equip_loc, slot, link, json, captured_at) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)",
                    (char_key, "bank", it.get("itemID") or iid, it.get("name"), it.get("count"), it.get("quality"),
                     it.get("ilvl"), it.get("reqLevel"), it.get("equipLoc"), "", it.get("link"), _j(it),
                     bank.get("scannedAt")))

    skills = _as_list(snap.get("skills"))
    if skills:
        con.execute("DELETE FROM professions WHERE char_key=?", (char_key,))
        for s in skills:
            if isinstance(s, dict) and s.get("name"):
                con.execute(
                    "INSERT OR REPLACE INTO professions (char_key, skill_name, skill_id, rank, max_rank, grp,"
                    " updated_at) VALUES (?,?,?,?,?,?,?)",
                    (char_key, s["name"], s.get("skillID"), s.get("rank"), s.get("max"), s.get("group"),
                     captured_at))

    for prof, pr in _as_dict(c.get("recipes")).items():
        if not isinstance(pr, dict):
            continue
        con.execute("DELETE FROM recipes WHERE char_key=? AND profession=?", (char_key, prof))
        for rk, r in _as_dict(pr.get("recipes")).items():
            if not isinstance(r, dict):
                continue
            con.execute(
                "INSERT OR REPLACE INTO recipes (char_key, profession, recipe_key, recipe_id, name, difficulty,"
                " skill_ups, output_item, reagents_json, scanned_at) VALUES (?,?,?,?,?,?,?,?,?,?)",
                (char_key, prof, str(rk), rk if isinstance(rk, int) else None, r.get("name"), r.get("difficulty"),
                 r.get("skillUps"), r.get("output"), _j(_as_list(r.get("reagents"))), pr.get("scannedAt")))

    for fname, fp in _as_dict(c.get("taxi")).items():
        if isinstance(fp, dict):
            con.execute(
                "INSERT INTO flight_paths (char_key, name, node_id, continent, first_seen, baseline)"
                " VALUES (?,?,?,?,?,?) ON CONFLICT(char_key, name) DO UPDATE SET"
                " node_id=COALESCE(excluded.node_id, flight_paths.node_id)",
                (char_key, str(fname), fp.get("nodeID"), fp.get("continent"), fp.get("firstSeen"),
                 1 if fp.get("baseline") else 0))

    for q in _as_list(snap.get("quests")):
        if isinstance(q, dict) and isinstance(q.get("questID"), int) and q.get("title"):
            con.execute(
                "INSERT INTO quest_titles (quest_id, title, level, zone) VALUES (?,?,?,?) ON CONFLICT(quest_id)"
                " DO UPDATE SET title=excluded.title, level=COALESCE(excluded.level, quest_titles.level),"
                " zone=COALESCE(excluded.zone, quest_titles.zone)",
                (q["questID"], q["title"], q.get("level"), q.get("zone")))
    for qid, title in _as_dict(c.get("questTitles")).items():
        if isinstance(qid, int) and title:
            con.execute("INSERT OR IGNORE INTO quest_titles (quest_id, title) VALUES (?,?)", (qid, title))


def ingest_sv_file(con, path, now=None):
    """Ingest one SavedVariables file. Returns a result dict; never raises on bad data."""
    now = int(now or time.time())
    res = {"path": path, "status": "ok", "chars": 0, "events_new": 0, "events_dup": 0, "error": None}
    try:
        with open(path, "rb") as fh:
            data = fh.read()
    except OSError as e:
        res.update(status="error", error=str(e))
        return res
    sha = hashlib.sha256(data).hexdigest()
    res["sha256"] = sha
    if con.execute("SELECT 1 FROM ingest_runs WHERE sha256=? AND status='ok'", (sha,)).fetchone():
        res["status"] = "skipped"
        return res
    started = int(time.time())
    try:
        parsed, _ = parse_file(path)
        root = parsed.get("ForeverScribeDB")
        if not isinstance(root, dict) or not isinstance(root.get("chars"), dict):
            raise SVParseError("no ForeverScribeDB.chars table")
    except (SVParseError, RecursionError, ValueError) as e:
        res.update(status="error", error=str(e)[:500])
        con.execute(
            "INSERT INTO ingest_runs (started_at, finished_at, source_path, kind, sha256, size, status, chars,"
            " events_new, events_dup, error) VALUES (?,?,?,?,?,?,?,?,?,?,?)",
            (started, int(time.time()), path, "sv", sha, len(data), "error", 0, 0, 0, res["error"]))
        con.commit()
        return res

    mtime = int(os.path.getmtime(path))
    account = _account_from_path(path)
    try:
        with con:
            for char_key, c in root["chars"].items():
                if not isinstance(c, dict):
                    continue
                res["chars"] += 1
                _ensure_char(con, char_key, now)
                snap = c.get("snapshot") if isinstance(c.get("snapshot"), dict) else {}
                captured = snap.get("capturedAt")
                if isinstance(captured, (int, float)):
                    captured = int(captured)
                    snap_json = _j(snap)
                    ssha = hashlib.sha256(snap_json.encode("utf-8")).hexdigest()
                    con.execute(
                        "INSERT OR IGNORE INTO snapshots (char_key, captured_at, session, sha256, json, ingested_at,"
                        " source_path) VALUES (?,?,?,?,?,?,?)",
                        (char_key, captured, snap.get("session"), ssha, snap_json, now, path))
                    row = con.execute("SELECT last_captured_at FROM characters WHERE char_key=?", (char_key,)).fetchone()
                    if (row["last_captured_at"] is None or captured >= row["last_captured_at"]) and not _degraded(snap):
                        _apply_current(con, char_key, c, snap, captured, now)
                        con.execute("UPDATE characters SET source_path=?, source_mtime=?, account=COALESCE(?, account)"
                                    " WHERE char_key=?", (path, mtime, account, char_key))
                    for qid in _as_list(snap.get("questsCompleted")):
                        if isinstance(qid, int):
                            con.execute(
                                "INSERT OR IGNORE INTO quests_completed (char_key, quest_id, first_seen_at, source)"
                                " VALUES (?,?,?, 'snapshot')", (char_key, qid, captured))
                _store_sections(con, char_key, c, captured if isinstance(captured, int) else None, now)
                _store_npcs(con, char_key, c.get("npcs"), now)
                for qid, title in _as_dict(c.get("questTitles")).items():
                    if isinstance(qid, int) and title:
                        con.execute("INSERT OR IGNORE INTO quest_titles (quest_id, title) VALUES (?,?)", (qid, title))
                        con.execute("UPDATE quests_completed SET title=? WHERE char_key=? AND quest_id=? AND title IS NULL",
                                    (title, char_key, qid))
                for ev in _as_list(c.get("events")):
                    if isinstance(ev, dict):
                        new = _insert_event(con, char_key, ev, "sv", now)
                        if new:
                            res["events_new"] += 1
                        elif new is False:
                            res["events_dup"] += 1
                for s in _as_list(c.get("sessions")):
                    if isinstance(s, dict) and s.get("id"):
                        con.execute(
                            "INSERT INTO sessions (session_id, char_key, start, last, ended, level, level_end, xp, xp_end,"
                            " money, money_end, events) VALUES (?,?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT(session_id) DO UPDATE SET"
                            " last=MAX(COALESCE(sessions.last,0), COALESCE(excluded.last,0)),"
                            " ended=COALESCE(excluded.ended, sessions.ended), level_end=COALESCE(excluded.level_end, sessions.level_end),"
                            " xp_end=COALESCE(excluded.xp_end, sessions.xp_end), money_end=COALESCE(excluded.money_end, sessions.money_end),"
                            " events=MAX(COALESCE(sessions.events,0), COALESCE(excluded.events,0))",
                            (s["id"], char_key, s.get("start"), s.get("last"), s.get("ended"), s.get("level"),
                             s.get("levelEnd"), s.get("xp"), s.get("xpEnd"), s.get("money"), s.get("moneyEnd"),
                             s.get("events")))
                _touch_char(con, char_key, now)
            con.execute(
                "INSERT INTO ingest_runs (started_at, finished_at, source_path, kind, sha256, size, status, chars,"
                " events_new, events_dup, error) VALUES (?,?,?,?,?,?,?,?,?,?,?)",
                (started, int(time.time()), path, "sv", sha, len(data), "ok", res["chars"], res["events_new"],
                 res["events_dup"], None))
    except sqlite3.DatabaseError as e:
        res.update(status="error", error="database: %s" % e)
    return res


def _touch_char(con, char_key, now):
    row = con.execute("SELECT MAX(t) AS t FROM events WHERE char_key=?", (char_key,)).fetchone()
    con.execute("UPDATE characters SET last_event_at=?, last_ingest_at=? WHERE char_key=?", (row["t"], now, char_key))


def ingest_live_file(con, path, now=None):
    """Ingest new lines of a live JSONL file (one event per line, with char_key)."""
    now = int(now or time.time())
    res = {"path": path, "status": "ok", "events_new": 0, "events_dup": 0, "bad_lines": 0}
    try:
        st = os.stat(path)
    except OSError as e:
        res.update(status="error", error=str(e))
        return res
    row = con.execute("SELECT offset, inode FROM live_offsets WHERE path=?", (path,)).fetchone()
    offset = row["offset"] if row and row["inode"] == st.st_ino and row["offset"] <= st.st_size else 0
    with open(path, "rb") as fh:
        fh.seek(offset)
        chunk = fh.read()
    # Only consume complete lines; a partially-written last line waits for next time.
    end = chunk.rfind(b"\n")
    if end < 0:
        return res
    lines = chunk[:end + 1].splitlines()
    touched = set()
    with con:
        for raw in lines:
            if not raw.strip():
                continue
            try:
                ev = json.loads(raw.decode("utf-8"))
            except (ValueError, UnicodeDecodeError):
                res["bad_lines"] += 1
                continue
            ck = ev.get("char_key")
            if not ck or not isinstance(ev, dict):
                res["bad_lines"] += 1
                continue
            _ensure_char(con, ck, now)
            new = _insert_event(con, ck, ev, "live", now)
            if new:
                res["events_new"] += 1
            elif new is False:
                res["events_dup"] += 1
            touched.add(ck)
            captured = ev.get("captured_at")
            if captured:
                con.execute("UPDATE characters SET last_live_at=MAX(COALESCE(last_live_at,0), ?) WHERE char_key=?",
                            (int(captured), ck))
        for ck in touched:
            _touch_char(con, ck, now)
        con.execute("INSERT OR REPLACE INTO live_offsets (path, offset, inode) VALUES (?,?,?)",
                    (path, offset + end + 1, st.st_ino))
        con.execute(
            "INSERT INTO ingest_runs (started_at, finished_at, source_path, kind, sha256, size, status, chars,"
            " events_new, events_dup, error) VALUES (?,?,?,?,?,?,?,?,?,?,?)",
            (now, int(time.time()), path, "live", None, end + 1, "ok", len(touched), res["events_new"],
             res["events_dup"], None))
    return res


DEFAULT_EXTRA = ("ForeverForge*.lua",)


def _kind(base, extra):
    if base.startswith(".") or base.endswith(".icloud") or base.endswith(".bak"):
        return None
    if base.endswith(".jsonl"):
        return "live"
    if base == "ForeverScribe.lua" or (base.startswith("ForeverScribe") and base.endswith(".lua")
                                       and not base.startswith("ForeverScribe_")):
        return "sv"
    if base.endswith(".lua") and any(fnmatch.fnmatch(base, p) for p in extra):
        return "raw"
    return None


def discover(sources, extra=DEFAULT_EXTRA):
    """Expand source dirs/files into (kind, path) pairs, oldest first.
    kind: sv (ForeverScribe.lua), live (JSONL), raw (other addons' SavedVariables listed in
    sync.extra_saved_variables, stored unparsed)."""
    found = []
    for src in sources:
        if not src:
            continue
        src = os.path.expanduser(src)
        if os.path.isfile(src):
            k = _kind(os.path.basename(src), extra) or ("sv" if src.endswith(".lua") else None)
            if k:
                found.append((k, src))
            continue
        paths = glob.glob(os.path.join(src, "**", "*"), recursive=True)
        for p in paths:
            k = _kind(os.path.basename(p), extra)
            if k and os.path.isfile(p):
                found.append((k, p))
    found.sort(key=lambda kp: (os.path.getmtime(kp[1]), kp[1]))
    seen, out = set(), []
    for kp in found:
        if kp[1] not in seen:
            seen.add(kp[1])
            out.append(kp)
    return out


def ingest_raw_file(con, path, now=None, parser=None):
    """Keep another addon's SavedVariables (e.g. Forever Forge) as a raw file until a parser exists."""
    now = int(now or time.time())
    res = {"path": path, "status": "ok", "kind": "raw", "events_new": 0}
    try:
        st = os.stat(path)
        with open(path, "rb") as fh:
            sha = hashlib.sha256(fh.read()).hexdigest()
    except OSError as e:
        res.update(status="error", error=str(e))
        return res
    row = con.execute("SELECT sha256 FROM raw_files WHERE path=?", (path,)).fetchone()
    if row and row["sha256"] == sha:
        res["status"] = "skipped"
        return res
    with con:
        con.execute("INSERT OR REPLACE INTO raw_files (path, account, name, sha256, size, mtime, ingested_at, parser, status)"
                    " VALUES (?,?,?,?,?,?,?,?,?)", (path, _account_from_path(path), os.path.basename(path), sha,
                                                     st.st_size, int(st.st_mtime), now, parser, "unparsed"))
    return res


def ingest_all(con, sources, now=None, extra=DEFAULT_EXTRA):
    results = []
    for kind, path in discover(sources, extra):
        if kind == "sv":
            results.append(ingest_sv_file(con, path, now))
        elif kind == "raw":
            results.append(ingest_raw_file(con, path, now))
        else:
            results.append(ingest_live_file(con, path, now))
    return results

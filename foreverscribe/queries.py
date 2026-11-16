"""Read-side queries over the ForeverScribe SQLite store. All return plain dicts/lists."""

import datetime as _dt
import json
import re
import time

try:
    from zoneinfo import ZoneInfo
    TZ = ZoneInfo("America/New_York")
except Exception:  # pragma: no cover
    TZ = None

FRESH_SECS = 15 * 60
RECENT_SECS = 6 * 3600

SLOT_ORDER = ["head", "neck", "shoulder", "back", "chest", "shirt", "tabard", "wrist", "hands", "waist", "legs",
              "feet", "finger1", "finger2", "trinket1", "trinket2", "mainhand", "offhand", "ranged", "ammo"]
EQUIP_LOC_SLOTS = {
    "INVTYPE_HEAD": ["head"], "INVTYPE_NECK": ["neck"], "INVTYPE_SHOULDER": ["shoulder"], "INVTYPE_CLOAK": ["back"],
    "INVTYPE_CHEST": ["chest"], "INVTYPE_ROBE": ["chest"], "INVTYPE_BODY": ["shirt"], "INVTYPE_TABARD": ["tabard"],
    "INVTYPE_WRIST": ["wrist"], "INVTYPE_HAND": ["hands"], "INVTYPE_WAIST": ["waist"], "INVTYPE_LEGS": ["legs"],
    "INVTYPE_FEET": ["feet"], "INVTYPE_FINGER": ["finger1", "finger2"], "INVTYPE_TRINKET": ["trinket1", "trinket2"],
    "INVTYPE_WEAPON": ["mainhand", "offhand"], "INVTYPE_2HWEAPON": ["mainhand"], "INVTYPE_WEAPONMAINHAND": ["mainhand"],
    "INVTYPE_WEAPONOFFHAND": ["offhand"], "INVTYPE_SHIELD": ["offhand"], "INVTYPE_HOLDABLE": ["offhand"],
    "INVTYPE_RANGED": ["ranged"], "INVTYPE_RANGEDRIGHT": ["ranged"], "INVTYPE_THROWN": ["ranged"],
    "INVTYPE_RELIC": ["ranged"], "INVTYPE_AMMO": ["ammo"],
}
DIFFICULTY = {0: "orange (always skill-up)", 1: "yellow (likely skill-up)", 2: "green (sometimes)", 3: "gray (no skill-up)"}
QUALITY = {0: "poor", 1: "common", 2: "uncommon", 3: "rare", 4: "epic", 5: "legendary"}
STANDING = {1: "Hated", 2: "Hostile", 3: "Unfriendly", 4: "Neutral", 5: "Friendly", 6: "Honored", 7: "Revered", 8: "Exalted"}


def now_ts():
    return int(time.time())


def fmt_time(ts):
    if ts is None:
        return None
    d = _dt.datetime.fromtimestamp(int(ts), TZ) if TZ else _dt.datetime.fromtimestamp(int(ts))
    return d.strftime("%Y-%m-%d %H:%M %Z")


def fmt_age(secs):
    if secs is None:
        return "never"
    secs = int(secs)
    if secs < 90:
        return "%ds" % secs
    if secs < 5400:
        return "%dm" % (secs // 60)
    if secs < 172800:
        return "%.1fh" % (secs / 3600.0)
    return "%.1fd" % (secs / 86400.0)


def money(c):
    if c is None:
        return None
    neg = c < 0
    c = abs(int(c))
    g, s, cp = c // 10000, (c // 100) % 100, c % 100
    out = ("%dg %ds %dc" % (g, s, cp)) if g else (("%ds %dc" % (s, cp)) if s else "%dc" % cp)
    return ("-" if neg else "") + out


def characters(con):
    return [dict(r) for r in con.execute(
        "SELECT * FROM characters ORDER BY COALESCE(MAX(COALESCE(last_captured_at,0), COALESCE(last_live_at,0)), 0) DESC")]


def resolve_char(con, wanted=None):
    rows = characters(con)
    if not rows:
        return None
    if not wanted:
        return rows[0]["char_key"]
    w = wanted.lower()
    for r in rows:
        if r["char_key"].lower() == w:
            return r["char_key"]
    for r in rows:
        if (r["name"] or r["char_key"].split(":")[-1]).lower() == w:
            return r["char_key"]
    for r in rows:
        if w in r["char_key"].lower() or w == (r["class"] or "").lower():
            return r["char_key"]
    raise KeyError("no character matching %r (known: %s)" % (wanted, ", ".join(r["char_key"] for r in rows)))


def latest_snapshot(con, ck):
    """Newest snapshot that isn't a logout/teardown read (empty bags+gear, xpMax 0)."""
    from .store import _degraded
    rows = con.execute("SELECT json, captured_at FROM snapshots WHERE char_key=? ORDER BY captured_at DESC, id DESC LIMIT 20",
                       (ck,)).fetchall()
    for r in rows:
        snap = json.loads(r["json"])
        if not _degraded(snap):
            return snap, r["captured_at"]
    return (json.loads(rows[0]["json"]), rows[0]["captured_at"]) if rows else ({}, None)


def freshness(con, ck, now=None):
    now = now or now_ts()
    c = con.execute("SELECT * FROM characters WHERE char_key=?", (ck,)).fetchone()
    if not c:
        return {"char": ck, "status": "unknown"}
    snap_at = c["last_captured_at"]
    live_at = c["last_live_at"]
    ev_at = c["last_event_at"]
    newest = max([x for x in (snap_at, live_at, ev_at) if x] or [0]) or None
    age = (now - newest) if newest else None
    status = "fresh" if age is not None and age <= FRESH_SECS else (
        "recent" if age is not None and age <= RECENT_SECS else "stale")
    last_run = con.execute("SELECT * FROM ingest_runs ORDER BY id DESC LIMIT 1").fetchone()
    last_err = con.execute("SELECT finished_at, error, source_path FROM ingest_runs WHERE status='error'"
                           " ORDER BY id DESC LIMIT 1").fetchone()
    out = {
        "char": ck, "status": status, "stale": status == "stale",
        "snapshot_at": fmt_time(snap_at), "snapshot_age": fmt_age(now - snap_at) if snap_at else "never",
        "last_event_at": fmt_time(ev_at), "live_at": fmt_time(live_at),
        "live_age": fmt_age(now - live_at) if live_at else None,
        "source": c["source_path"], "last_ingest": fmt_time(last_run["finished_at"]) if last_run else None,
        "note": ("Snapshot reflects the last /reload, logout or disconnect. Anything after that is unknown"
                 + (" except live events." if live_at else ".")),
    }
    if last_err:
        out["last_ingest_error"] = {"at": fmt_time(last_err["finished_at"]), "error": last_err["error"]}
    return out


def _event_row(r):
    d = dict(r)
    d["payload"] = json.loads(d.pop("payload_json") or "{}")
    ctx = d.pop("ctx_json", None)
    d["ctx"] = json.loads(ctx) if ctx else {}
    d["when"] = fmt_time(d["t"])
    return d


def events(con, ck, since=None, until=None, limit=50, types=None):
    q = "SELECT * FROM events WHERE char_key=?"
    args = [ck]
    if since is not None:
        q += " AND t >= ?"
        args.append(int(since))
    if until is not None:
        q += " AND t < ?"
        args.append(int(until))
    if types:
        q += " AND type IN (%s)" % ",".join("?" * len(types))
        args += list(types)
    q += " ORDER BY t DESC, session DESC, seq DESC LIMIT ?"
    args.append(int(limit))
    rows = [_event_row(r) for r in con.execute(q, args)]
    rows.reverse()
    return collapse_zone_bounces(rows)


ZONE_SETTLE = 20


def collapse_zone_bounces(rows):
    """Older addon versions (<0.2.2) logged every border crossing. Merge zone changes that happen
    within ZONE_SETTLE seconds of the next one, and drop round trips that end where they started."""
    out, run = [], []

    def flush():
        if not run:
            return
        first, last = run[0], run[-1]
        p0, p1 = first.get("payload") or {}, last.get("payload") or {}
        if p1.get("zone") != p0.get("from"):
            if len(run) > 1:
                last = dict(last, payload=dict(p1, **{"from": p0.get("from"), "fromMapID": p0.get("fromMapID"),
                                                    "collapsed": len(run)}))
            out.append(last)
        run.clear()

    for e in rows:
        if e.get("type") == "ZONE_CHANGED":
            if run and (e.get("t") or 0) - (run[-1].get("t") or 0) > ZONE_SETTLE:
                flush()
            run.append(e)
        else:
            if run and (e.get("t") or 0) - (run[-1].get("t") or 0) > ZONE_SETTLE:
                flush()
            out.append(e)
    flush()
    out.sort(key=lambda e: (e.get("t") or 0))
    return out


def describe_event(e):
    p = e.get("payload") or {}
    t = e["type"]
    if t == "LEVEL_UP":
        return "Reached level %s" % p.get("level")
    if t in ("ITEM_ACQUIRED", "LOOT"):
        return "%s %sx %s%s" % ("Looted" if t == "LOOT" else "+", p.get("qty"), p.get("name") or p.get("itemID"),
                                 " (%s)" % p["reason"] if p.get("reason") and t != "LOOT" else "")
    if t == "ITEM_REMOVED":
        return "- %sx %s%s" % (p.get("qty"), p.get("name") or p.get("itemID"), " (%s)" % p["reason"] if p.get("reason") else "")
    if t == "EQUIPMENT_CHANGED":
        new, old = p.get("new") or {}, p.get("old") or {}
        return "Equipped %s in %s (was %s)" % (new.get("name") or "nothing", p.get("slot"), old.get("name") or "empty")
    if t.startswith("QUEST_"):
        verb = {"QUEST_ACCEPTED": "Accepted", "QUEST_COMPLETED": "Turned in", "QUEST_ABANDONED": "Abandoned",
                "QUEST_PROGRESS": "Progress", "QUEST_OBJECTIVES_COMPLETE": "Ready to turn in"}.get(t, t)
        extra = " — %s %s/%s" % (p.get("objective"), p.get("have"), p.get("need")) if t == "QUEST_PROGRESS" else ""
        return "%s: %s [%s]%s" % (verb, p.get("title") or "?", p.get("questID"), extra)
    if t == "PROFESSION_SKILL_UP":
        return "%s %s -> %s" % (p.get("skill"), p.get("from"), p.get("to"))
    if t == "ZONE_CHANGED":
        return "Entered %s" % p.get("zone")
    if t == "BOSS_KILLED":
        return "Killed %s (%s)" % (p.get("name"), p.get("instance") or "?")
    if t in ("INSTANCE_ENTERED", "INSTANCE_EXITED"):
        return "%s %s" % ("Entered" if t.endswith("ENTERED") else "Left", p.get("name"))
    if t == "DEATH":
        return "Died in %s%s" % (p.get("subzone") or p.get("zone"), " (%s)" % p["instance"] if p.get("instance") else "")
    if t == "GOLD_CHANGED":
        return "Gold %s%s" % ("+" if (p.get("delta") or 0) > 0 else "", money(p.get("delta")))
    if t in ("RECIPE_LEARNED", "SPELL_LEARNED", "FLIGHT_PATH_LEARNED", "SKILL_LEARNED"):
        return "Learned %s" % (p.get("name") or p.get("skill") or p.get("recipeID") or p.get("spellID"))
    if t == "SESSION_START":
        return "Logged in / reloaded (level %s, %s)" % (p.get("level"), p.get("zone"))
    if t == "LOOT_WINDOW":
        return "Loot window: " + ", ".join("%sx %s" % (i.get("qty"), i.get("name")) for i in (p.get("items") or [])[:6])
    if t == "REPUTATION_CHANGED":
        if p.get("discovered"):
            return "Discovered faction %s (%s)" % (p.get("name"), STANDING.get(p.get("standingTo"), "?"))
        s = "%s %s%s rep" % (p.get("name"), "+" if (p.get("delta") or 0) >= 0 else "", p.get("delta"))
        if p.get("standingTo"):
            s += " — now %s" % STANDING.get(p.get("standingTo"), p.get("standingTo"))
        return s
    if t == "FACTION_AT_WAR":
        return "%s %s" % ("At war with" if p.get("atWar") else "Made peace with", p.get("name"))
    if t == "TALENT_CHANGED":
        ch = p.get("changes") or []
        return "Talents: " + ", ".join("%s%s %s->%s" % ("[Legacy] " if c.get("legacy") else "", c.get("name") or c.get("key"),
                                                     c.get("from"), c.get("to")) for c in ch[:6])
    if t == "RENOWN_CHANGED":
        return "%s rank %s -> %s" % (p.get("name") or "Renown %s" % p.get("factionID"), p.get("from"), p.get("to"))
    if t == "EXPLORATION_DISCOVERED":
        return "Discovered %s in %s" % (", ".join(p.get("areas") or ["?"]), p.get("zone") or p.get("mapID"))
    if t == "ACHIEVEMENT_EARNED":
        lp = " (+%s Legacy Points)" % p["legacyPoints"] if p.get("legacyPoints") else ""
        return "Completed challenge: %s%s" % (p.get("name") or p.get("achievementID"), lp)
    if t == "TITLE_EARNED":
        return "New title: %s" % (p.get("name") or "").replace("%s", "<name>").strip()
    if t in ("MOUNT_LEARNED", "PET_LEARNED", "TOY_LEARNED"):
        return "New %s: %s" % (t.split("_")[0].lower(), p.get("name") or p.get("id") or p.get("speciesID"))
    if t == "CURRENCY_CHANGED":
        return "%s %s%s (now %s)" % (p.get("name"), "+" if (p.get("delta") or 0) >= 0 else "", p.get("delta"), p.get("to"))
    if t in AUCTION_VERBS:
        price = p.get("buyout") or p.get("bid")
        return "%s: %s%s%s" % (AUCTION_VERBS[t], "%sx " % p["qty"] if p.get("qty") else "", p.get("item") or p.get("itemID") or "?",
                               " (listed at %s)" % money(price) if price and t == "AUCTION_SOLD" else "")
    if t == "MAIL_PENDING":
        return "New mail%s" % (" from " + ", ".join(p.get("senders") or []) if p.get("senders") else "")
    return "%s %s" % (t, json.dumps(p, sort_keys=True)[:120])


def _quest_title(con, qid):
    r = con.execute("SELECT title, level, zone FROM quest_titles WHERE quest_id=?", (qid,)).fetchone()
    return dict(r) if r else {}


def quest(con, ck, term):
    term = str(term).strip()
    snap, _ = latest_snapshot(con, ck)
    ids = []
    if re.fullmatch(r"\d+", term):
        ids = [int(term)]
    else:
        like = "%" + term.lower() + "%"
        ids = [r["quest_id"] for r in con.execute("SELECT quest_id FROM quest_titles WHERE lower(title) LIKE ?", (like,))]
        for q in snap.get("quests") or []:
            if term.lower() in (q.get("title") or "").lower() and q.get("questID") not in ids:
                ids.append(q.get("questID"))
    results = []
    for qid in ids:
        r = {"questID": qid}
        r.update(_quest_title(con, qid))
        done = con.execute("SELECT * FROM quests_completed WHERE char_key=? AND quest_id=?", (ck, qid)).fetchone()
        inlog = next((q for q in (snap.get("quests") or []) if q.get("questID") == qid), None)
        hist = events(con, ck, types=["QUEST_ACCEPTED", "QUEST_COMPLETED", "QUEST_ABANDONED", "QUEST_OBJECTIVES_COMPLETE"],
                      limit=1000)
        hist = [describe_event(e) + " @ " + (e["when"] or "?") for e in hist if (e["payload"] or {}).get("questID") == qid]
        if done:
            r["status"] = "completed"
            r["completed_at"] = fmt_time(done["completed_at"]) if done["completed_at"] else "before tracking began"
            r["title"] = r.get("title") or done["title"]
        elif inlog:
            r["status"] = "in quest log" + (" (objectives complete — turn it in)" if inlog.get("complete") else "")
            r["objectives"] = inlog.get("obj")
            r["title"] = r.get("title") or inlog.get("title")
        else:
            r["status"] = "not completed and not in quest log"
        r["history"] = hist[-10:]
        results.append(r)
    return {"query": term, "matches": results,
            "note": None if results else "No quest by that name in telemetry. Titles are only known for quests seen in "
                                         "the log or turned in since ForeverScribe was installed; ask by quest ID for "
                                         "older ones."}


def equipment(con, ck):
    snap, at = latest_snapshot(con, ck)
    eq = snap.get("equipment") or {}
    out = []
    for slot in SLOT_ORDER:
        it = eq.get(slot)
        if isinstance(it, dict):
            out.append({"slot": slot, "name": it.get("name"), "itemID": it.get("itemID"), "ilvl": it.get("ilvl"),
                        "quality": QUALITY.get(it.get("quality"), it.get("quality")), "reqLevel": it.get("reqLevel"),
                        "type": it.get("subType"), "enchant": it.get("enchant"),
                        "durability": ("%s/%s" % (it.get("dur"), it.get("durMax"))) if it.get("durMax") else None,
                        "stats": it.get("stats") or {}})
    return {"captured_at": fmt_time(at), "equipped": out}


def inventory(con, ck, search=None):
    q = "SELECT location, item_id, name, count, quality, ilvl, equip_loc, captured_at FROM items WHERE char_key=? AND location IN ('bags','bank')"
    args = [ck]
    if search:
        q += " AND lower(name) LIKE ?"
        args.append("%" + search.lower() + "%")
    q += " ORDER BY location, quality DESC, name"
    rows = [dict(r) for r in con.execute(q, args)]
    snap, at = latest_snapshot(con, ck)
    bags = snap.get("bags") or {}
    bank_at = con.execute("SELECT MAX(captured_at) AS t FROM items WHERE char_key=? AND location='bank'", (ck,)).fetchone()["t"]
    for r in rows:
        r["quality"] = QUALITY.get(r["quality"], r["quality"])
        r.pop("captured_at", None)
    return {"bags_captured_at": fmt_time(at), "bank_captured_at": fmt_time(bank_at) or "bank never opened",
            "free_bag_slots": bags.get("free"), "bag_slots": bags.get("slots"), "items": rows}


def _counts(con, ck):
    c = {}
    for r in con.execute("SELECT item_id, SUM(count) AS n FROM items WHERE char_key=? AND location IN ('bags','bank') GROUP BY item_id", (ck,)):
        c[r["item_id"]] = r["n"]
    return c


def professions(con, ck, recipes=False):
    rows = [dict(r) for r in con.execute("SELECT skill_name, rank, max_rank, grp, updated_at FROM professions WHERE char_key=?"
                                         " ORDER BY grp, skill_name", (ck,))]
    profs = [r for r in rows if (r["grp"] or "").lower() in ("professions", "secondary skills")]
    out = {"professions": [{"name": r["skill_name"], "rank": r["rank"], "max": r["max_rank"], "group": r["grp"]} for r in profs],
           "other_skills": [{"name": r["skill_name"], "rank": r["rank"], "max": r["max_rank"]} for r in rows if r not in profs]}
    scans = [dict(r) for r in con.execute("SELECT profession, COUNT(*) AS n, MAX(scanned_at) AS at FROM recipes WHERE char_key=? GROUP BY profession", (ck,))]
    out["recipe_scans"] = [{"profession": s["profession"], "known_recipes": s["n"], "scanned_at": fmt_time(s["at"])} for s in scans]
    if recipes:
        have = _counts(con, ck)
        lst = []
        for r in con.execute("SELECT * FROM recipes WHERE char_key=? ORDER BY profession, COALESCE(difficulty, 9), name", (ck,)):
            reagents = json.loads(r["reagents_json"] or "[]")
            craftable = None
            if reagents:
                craftable = min((have.get(x.get("itemID"), 0) // max(1, x.get("qty") or 1)) for x in reagents)
            lst.append({"profession": r["profession"], "name": r["name"], "recipeID": r["recipe_id"],
                        "color": DIFFICULTY.get(r["difficulty"], "unknown"), "craftable_now": craftable,
                        "reagents": reagents})
        out["recipes"] = lst
    out["note"] = ("Recipe lists only update when that profession window is opened in game." if recipes or scans else
                   "No recipe scan yet: open each profession window once in game, then /reload.")
    return out


def flightpaths(con, ck):
    rows = [dict(r) for r in con.execute("SELECT name, continent, first_seen, baseline FROM flight_paths WHERE char_key=? ORDER BY continent, name", (ck,))]
    for r in rows:
        r["learned"] = "before tracking" if r.pop("baseline") else fmt_time(r["first_seen"])
        r.pop("first_seen")
    return {"known": rows, "note": "Updated when a flight master map is opened; a continent you never opened a flight map on is unknown."}


def dungeons(con, ck, limit=200):
    evs = events(con, ck, types=["INSTANCE_ENTERED", "INSTANCE_EXITED", "BOSS_KILLED", "BOSS_WIPE", "LOOT", "DEATH"], limit=5000)
    runs, cur = [], None
    for e in evs:
        p = e["payload"]
        if e["type"] == "INSTANCE_ENTERED":
            cur = {"instance": p.get("name"), "type": p.get("type"), "difficulty": p.get("difficulty"),
                   "entered": e["when"], "bosses": [], "wipes": 0, "deaths": 0, "loot": []}
            runs.append(cur)
        elif cur is None:
            continue
        elif e["type"] == "INSTANCE_EXITED":
            cur["exited"] = e["when"]
            cur = None
        elif e["type"] == "BOSS_KILLED":
            cur["bosses"].append(p.get("name"))
        elif e["type"] == "BOSS_WIPE":
            cur["wipes"] += 1
        elif e["type"] == "DEATH":
            cur["deaths"] += 1
        elif e["type"] == "LOOT" and (p.get("quality") or 0) >= 2:
            cur["loot"].append(p.get("name"))
    return {"runs": runs[-limit:]}


def parse_timeframe(tf, con=None, ck=None, now=None):
    """Return (since, until, label). Accepts: today, yesterday, last-session, session, 24h, 7d, 90m, week, all."""
    now = now or now_ts()
    tf = (tf or "last-session").strip().lower()
    local = _dt.datetime.fromtimestamp(now, TZ) if TZ else _dt.datetime.fromtimestamp(now)
    midnight = local.replace(hour=0, minute=0, second=0, microsecond=0)
    if tf in ("today",):
        return int(midnight.timestamp()), None, "today (since %s)" % midnight.strftime("%Y-%m-%d 00:00 %Z")
    if tf == "yesterday":
        y = midnight - _dt.timedelta(days=1)
        return int(y.timestamp()), int(midnight.timestamp()), "yesterday (%s)" % y.strftime("%Y-%m-%d")
    if tf in ("week", "this-week"):
        return now - 7 * 86400, None, "last 7 days"
    if tf == "all":
        return None, None, "all time"
    m = re.fullmatch(r"(\d+)\s*(m|min|h|d|w)", tf)
    if m:
        n, u = int(m.group(1)), m.group(2)
        secs = n * {"m": 60, "min": 60, "h": 3600, "d": 86400, "w": 604800}[u]
        return now - secs, None, "last %s" % tf
    if tf in ("last-session", "session", "last", "lastsession"):
        if con is not None and ck:
            rows = con.execute("SELECT session_id, start, COALESCE(ended, last) AS stop FROM sessions WHERE char_key=?"
                               " ORDER BY start DESC LIMIT 20", (ck,)).fetchall()
            # A play session spans /reloads: merge sessions separated by < 10 minutes.
            if rows:
                start, stop = rows[0]["start"], rows[0]["stop"]
                for r in rows[1:]:
                    if r["stop"] and start - r["stop"] < 600:
                        start = r["start"]
                    else:
                        break
                return start, None, "last play session (from %s)" % fmt_time(start)
        return now - 86400, None, "last 24h (no session data)"
    raise ValueError("unknown timeframe %r (try today, yesterday, last-session, 24h, 7d, all)" % tf)


def history(con, ck, timeframe="last-session", now=None):
    since, until, label = parse_timeframe(timeframe, con, ck, now)
    evs = events(con, ck, since=since, until=until, limit=100000)
    agg = {"levels": [], "quests_completed": [], "quests_accepted": [], "quests_abandoned": [], "skill_ups": {},
           "items_gained": {}, "notable_loot": [], "equipment": [], "zones": [], "bosses": [], "deaths": 0,
           "gold_delta": 0, "learned": [], "flight_paths": [], "reputation": {}, "explored": [], "challenges": [],
           "new_collections": [], "talents": []}
    for e in evs:
        p, t = e["payload"], e["type"]
        if t == "LEVEL_UP":
            agg["levels"].append(p.get("level"))
        elif t == "QUEST_COMPLETED":
            agg["quests_completed"].append("%s [%s]" % (p.get("title") or "?", p.get("questID")))
        elif t == "QUEST_ACCEPTED":
            agg["quests_accepted"].append("%s [%s]" % (p.get("title") or "?", p.get("questID")))
        elif t == "QUEST_ABANDONED":
            agg["quests_abandoned"].append("%s [%s]" % (p.get("title") or "?", p.get("questID")))
        elif t == "PROFESSION_SKILL_UP":
            s = agg["skill_ups"].setdefault(p.get("skill"), [p.get("from"), p.get("to")])
            s[1] = p.get("to")
        elif t == "ITEM_ACQUIRED":
            k = p.get("name") or str(p.get("itemID"))
            agg["items_gained"][k] = agg["items_gained"].get(k, 0) + (p.get("qty") or 0)
            if (p.get("quality") or 0) >= 2:
                agg["notable_loot"].append(k)
        elif t == "EQUIPMENT_CHANGED":
            agg["equipment"].append(describe_event(e))
        elif t == "ZONE_CHANGED":
            if not agg["zones"] or agg["zones"][-1] != p.get("zone"):
                agg["zones"].append(p.get("zone"))
        elif t == "BOSS_KILLED":
            agg["bosses"].append("%s (%s)" % (p.get("name"), p.get("instance")))
        elif t == "DEATH":
            agg["deaths"] += 1
        elif t == "GOLD_CHANGED":
            agg["gold_delta"] += p.get("delta") or 0
        elif t in ("RECIPE_LEARNED", "SPELL_LEARNED"):
            agg["learned"].append(p.get("name") or str(p.get("recipeID") or p.get("spellID")))
        elif t == "FLIGHT_PATH_LEARNED":
            agg["flight_paths"].append(p.get("name"))
        elif t == "REPUTATION_CHANGED" and not p.get("discovered"):
            agg["reputation"][p.get("name")] = agg["reputation"].get(p.get("name"), 0) + (p.get("delta") or 0)
        elif t == "EXPLORATION_DISCOVERED":
            agg["explored"].extend(p.get("areas") or [])
        elif t == "ACHIEVEMENT_EARNED":
            agg["challenges"].append(p.get("name"))
        elif t in ("MOUNT_LEARNED", "PET_LEARNED", "TOY_LEARNED", "TITLE_EARNED"):
            agg["new_collections"].append(describe_event(e))
        elif t == "TALENT_CHANGED":
            agg["talents"].append(describe_event(e))
    agg["skill_ups"] = {k: "%s -> %s" % tuple(v) for k, v in agg["skill_ups"].items()}
    agg["reputation"] = {k: ("+%d" % v if v >= 0 else "%d" % v) for k, v in agg["reputation"].items()}
    agg["gold_delta"] = money(agg["gold_delta"])
    top = sorted(agg["items_gained"].items(), key=lambda kv: -kv[1])[:15]
    agg["items_gained"] = ["%dx %s" % (n, k) for k, n in top]
    agg = {k: v for k, v in agg.items() if v not in ([], {}, 0, "0c", None)}
    return {"timeframe": label, "events": len(evs), "summary": agg}


def state(con, ck, now=None):
    snap, at = latest_snapshot(con, ck)
    c = dict(con.execute("SELECT * FROM characters WHERE char_key=?", (ck,)).fetchone())
    loc = snap.get("location") or {}
    xp, xpmax = snap.get("xp"), snap.get("xpMax")
    played = snap.get("played") or {}
    qc = con.execute("SELECT COUNT(*) AS n FROM quests_completed WHERE char_key=?", (ck,)).fetchone()["n"]
    return {
        "character": ck, "class": c.get("class"), "race": c.get("race"), "faction": c.get("faction"),
        "level": snap.get("level"), "xp": "%s/%s (%.0f%%)" % (xp, xpmax, 100.0 * xp / xpmax) if xp is not None and xpmax else None,
        "rested_xp": snap.get("rested"), "money": money(snap.get("money")),
        "zone": loc.get("zone"), "subzone": loc.get("subzone"),
        "coords": "%.1f, %.1f" % (loc["x"], loc["y"]) if loc.get("x") is not None else None,
        "mapID": loc.get("mapID"), "instance": (loc.get("instance") or {}).get("name") if loc.get("inInstance") else None,
        "hearth": snap.get("hearth"),
        "talent_points_unspent": (snap.get("talents") or {}).get("unspent", snap.get("talentPointsUnspent")),
        "guild": (snap.get("guild") or {}).get("name") or (snap.get("identity") or {}).get("guild"),
        "played": fmt_age(played.get("total")) if played.get("total") else None,
        "quests_in_log": len(snap.get("quests") or []), "quests_completed_total": qc,
        "client": (snap.get("identity") or {}).get("client"), "freshness": freshness(con, ck, now),
    }


AUCTION_VERBS = {"AUCTION_SOLD": "Auction sold", "AUCTION_EXPIRED": "Auction expired", "AUCTION_OUTBID": "Outbid on",
                 "AUCTION_WON": "Won auction", "AUCTION_REMOVED": "Auction cancelled"}
# What "new since your last answer" reports in the hot tier.
NEWS_TYPES = ("AUCTION_SOLD", "AUCTION_EXPIRED", "AUCTION_OUTBID", "AUCTION_WON", "AUCTION_REMOVED", "MAIL_PENDING", "LEVEL_UP",
              "ACHIEVEMENT_EARNED", "BOSS_KILLED", "DEATH", "MOUNT_LEARNED", "PET_LEARNED", "TOY_LEARNED", "TITLE_EARNED",
              "RECIPE_LEARNED", "QUEST_COMPLETED")


def _marks(con):
    con.execute("CREATE TABLE IF NOT EXISTS answer_marks (char_key TEXT, consumer TEXT, last_t INTEGER, at INTEGER,"
                " PRIMARY KEY (char_key, consumer))")


def news(con, ck, consumer="default", mark=True, now=None, limit=12):
    """Events of interest since the last time this consumer asked (sales, mail, levels, drops...)."""
    _marks(con)
    r = con.execute("SELECT last_t FROM answer_marks WHERE char_key=? AND consumer=?", (ck, consumer)).fetchone()
    since = r["last_t"] if r else None
    newest = con.execute("SELECT MAX(t) AS t FROM events WHERE char_key=?", (ck,)).fetchone()["t"]
    if since is None:  # first answer: last 24h of play
        since = (newest or now_ts()) - 86400
    rows = events(con, ck, since=since + 1, limit=100000, types=list(NEWS_TYPES))
    loot = [e for e in events(con, ck, since=since + 1, limit=100000, types=["ITEM_ACQUIRED"])
            if ((e.get("payload") or {}).get("quality") or 0) >= 3]
    rows = sorted(rows + loot, key=lambda e: e["t"])
    if mark and newest:
        with con:
            con.execute("INSERT OR REPLACE INTO answer_marks (char_key, consumer, last_t, at) VALUES (?,?,?,?)",
                        (ck, consumer, max(newest, since), now or now_ts()))
    counted = {"QUEST_COMPLETED": "quests turned in", "RECIPE_LEARNED": "recipes learned"}
    tally = {}
    items = []
    for e in rows:
        if e["type"] in counted:
            tally[e["type"]] = tally.get(e["type"], 0) + 1
        else:
            items.append(describe_event(e))
    if len(items) > limit:
        n = len(items) - limit
        items = ["(%d earlier)" % n] + items[-limit:]
    items += ["%d %s" % (n, counted[t]) for t, n in tally.items()]
    return {"since": fmt_time(since), "count": len(rows), "items": items}


def summary(con, ck, now=None, consumer="default", mark=True):
    """HOT tier: compact, context-cheap text block for an agent prompt (target: under ~40 lines)."""
    s = state(con, ck, now)
    f = s["freshness"]
    lines = ["%s — level %s %s %s (%s)" % (ck, s["level"], s.get("race") or "", s.get("class") or "", s.get("faction") or ""),
             "Data: %s, snapshot %s ago (%s)%s" % (f["status"].upper(), f["snapshot_age"], f["snapshot_at"],
                                                   "; live events %s ago" % f["live_age"] if f.get("live_age") else ""),
             "XP %s, rested %s; money %s" % (s["xp"], s["rested_xp"], s["money"]),
             "Location: %s%s%s; hearth %s" % (s["zone"], " / " + s["subzone"] if s.get("subzone") else "",
                                               " @ " + s["coords"] if s.get("coords") else "", s["hearth"])]
    prof = professions(con, ck)
    if prof["professions"]:
        lines.append("Professions: " + ", ".join("%s %s/%s" % (p["name"], p["rank"], p["max"]) for p in prof["professions"]))
    eq = equipment(con, ck)["equipped"]
    if eq:
        lines.append("Gear: " + "; ".join("%s=%s(%s)" % (e["slot"], e["name"], e["ilvl"]) for e in eq if e["slot"] not in ("shirt", "tabard", "ammo")))
    snap, _ = latest_snapshot(con, ck)
    ql = snap.get("quests") or []
    if ql:
        lines.append("Quest log (%d): %s" % (len(ql), "; ".join(
            "%s[%s]%s" % (q.get("title"), q.get("questID"), " DONE" if q.get("complete") else "") for q in ql[:25])))
    lines.append("Completed quests tracked: %d (use `foreverscribe quest <id|name>` to check one)" % s["quests_completed_total"])
    h = history(con, ck, "last-session", now)
    if h["summary"]:
        bits = []
        for k in ("levels", "quests_completed", "skill_ups", "notable_loot", "bosses", "zones", "gold_delta", "deaths",
                  "reputation", "explored", "challenges", "new_collections"):
            v = h["summary"].get(k)
            if v:
                bits.append("%s: %s" % (k.replace("_", " "), v if not isinstance(v, (list, dict)) else (
                    ", ".join(map(str, v[:8])) if isinstance(v, list) else ", ".join("%s %s" % kv for kv in v.items()))))
        lines.append("Last session (%s): %s" % (h["timeframe"], " | ".join(bits)))
    lines.extend(_v2_summary_lines(con, ck))
    lines.extend(_v3_summary_lines(con, ck))
    nw = news(con, ck, consumer=consumer, mark=mark, now=now)
    lines.append("New since last check (%s): %s" % (nw["since"], "; ".join(nw["items"]) if nw["items"] else "nothing"))
    lines.append("More (warm): equipment | inventory | professions | reputation | talents | quest | mail | auctions | vendor | "
                 "currencies | history | gear/rate/craft. Rarely (cold): cold addons|keybinds|actionbars|macros")
    return "\n".join(lines)


def _v3_summary_lines(con, ck):
    lines = []
    mp, _ = section(con, ck, "mailPending")
    m, mat = section(con, ck, "mail")
    if mp and mp.get("hasNew"):
        lines.append("Mail: NEW mail waiting%s" % (" from " + ", ".join(mp.get("senders") or []) if mp.get("senders") else ""))
    elif m:
        pend = [x for x in _l(m.get("mails")) if x.get("money") or x.get("items")]
        if pend:
            lines.append("Mail: %d letters with money/items at last mailbox visit (%s)" % (len(pend), fmt_time(mat)))
    a, aat = section(con, ck, "auctions")
    if a:
        act = [x for x in _l(a.get("list")) if x.get("status") == "active"]
        sold = [x for x in _l(a.get("list")) if x.get("status") == "sold"]
        lines.append("Auctions (as of %s): %d active, %d sold awaiting mail" % (fmt_time(aat), len(act), len(sold)))
    return lines


def compare(con, ck, term):
    """Show the equipped item(s) in the slot a bag/bank item (or named item) would use."""
    eq = {e["slot"]: e for e in equipment(con, ck)["equipped"]}
    cands = []
    if re.fullmatch(r"\d+", str(term)):
        rows = con.execute("SELECT * FROM items WHERE char_key=? AND item_id=? AND location!='equipped'", (ck, int(term))).fetchall()
    else:
        rows = con.execute("SELECT * FROM items WHERE char_key=? AND lower(name) LIKE ? AND location!='equipped'",
                           (ck, "%" + str(term).lower() + "%")).fetchall()
    for r in rows:
        it = json.loads(r["json"] or "{}")
        slots = EQUIP_LOC_SLOTS.get(r["equip_loc"] or "", [])
        cands.append({"candidate": {"name": r["name"], "itemID": r["item_id"], "where": r["location"], "ilvl": r["ilvl"],
                                    "reqLevel": r["req_level"], "type": it.get("subType"),
                                    "quality": QUALITY.get(r["quality"], r["quality"]), "stats": it.get("stats") or {}},
                      "equipped_in_slot": [eq.get(s) or {"slot": s, "name": "(empty)"} for s in slots]})
    return {"query": term, "comparisons": cands,
            "note": "Telemetry has stats only for items in your bags/bank/equipped. For an item you don't own, "
                    "compare against `equipped_in_slot` from `foreverscribe equipment` using game-reference data, and label it as such."}


# --- v0.2 sections ------------------------------------------------------------

def section(con, ck, name):
    """Newest non-empty copy of a character section (reputation, legacy, achievements, ...)."""
    r = con.execute("SELECT json, captured_at FROM sections WHERE char_key=? AND section=?", (ck, name)).fetchone()
    if not r:
        return None, None
    return json.loads(r["json"]), r["captured_at"]


def _l(v):
    if isinstance(v, list):
        return v
    if isinstance(v, dict):
        return [v[k] for k in sorted(v, key=lambda x: (not isinstance(x, int), str(x)))]
    return []


def _missing(what, how):
    return {"available": False, "note": "No %s captured yet. %s" % (what, how)}


NEEDS_V2 = "Needs ForeverScribe 0.2+ in game, then a /reload or logout."


def reputation(con, ck, search=None):
    rep, at = section(con, ck, "reputation")
    if not rep:
        return _missing("reputation", NEEDS_V2)
    out = []
    for f in _l(rep.get("factions")):
        if search and search.lower() not in (f.get("name") or "").lower():
            continue
        lo, hi, v = f.get("min"), f.get("max"), f.get("value")
        prog = ("%s/%s" % (v - lo, hi - lo)) if None not in (lo, hi, v) and hi > lo else None
        out.append({"faction": f.get("name"), "standing": STANDING.get(f.get("standing"), f.get("standing")),
                    "progress": prog, "value": v, "group": f.get("group"),
                    "at_war": bool(f.get("atWar")), "watched": bool(f.get("watched")) or None,
                    "account_wide": f.get("accountWide") or None})
    out.sort(key=lambda x: (-(x["value"] or 0)))
    snap, _ = latest_snapshot(con, ck)
    legacy, _ = section(con, ck, "legacy")
    res = {"captured_at": fmt_time(at), "count": len(out), "factions": out}
    if legacy and legacy.get("track"):
        res["legacy_reward_track"] = legacy["track"]
    if (snap.get("pvp") or {}).get("rank"):
        res["pvp_rank"] = snap["pvp"]["rank"]
    if rep.get("collapsedHeaders"):
        res["note"] = ("Some reputation headers were collapsed in game (%s); factions under them only appear once "
                       "seen expanded." % ", ".join(rep["collapsedHeaders"]))
    return res


def _tree_view(tree, show_untaken=True):
    taken = [n for n in _l(tree.get("talents")) if (n.get("rank") or 0) > 0]
    untaken = [n for n in _l(tree.get("talents")) if not (n.get("rank") or 0)]
    pts = tree.get("points")
    if pts is None:
        pts = sum((n.get("rank") or 0) for n in taken)
    v = {"tree": tree.get("name") or ("class tree %s" % tree.get("treeID") if tree.get("treeID") else "talents"), "points_spent": pts,
         "taken": ["%s %s/%s" % (n.get("name") or n.get("nodeID"), n.get("rank"), n.get("max") or "?") + (
             " [%s]" % n["group"] if n.get("group") else "") for n in taken]}
    if tree.get("currency"):
        v["currency"] = tree["currency"]
    if tree.get("groups"):
        v["groups"] = {g.get("name"): g.get("spent") for g in _l(tree["groups"])}
    if show_untaken:
        v["not_taken"] = ["%s 0/%s%s" % (n.get("name") or n.get("nodeID"), n.get("max") or "?",
                                         " (available now)" if n.get("canBuy") else "") for n in untaken]
    return v


def talents(con, ck, untaken=True):
    snap, at = latest_snapshot(con, ck)
    t = snap.get("talents") or {}
    out = {"captured_at": fmt_time(at), "system": t.get("system"), "unspent_points": t.get("unspent"),
           "loadout": t.get("loadout"), "trees": [_tree_view(x, untaken) for x in _l(t.get("trees"))]}
    if t.get("specGroups"):
        out["dual_spec"] = t["specGroups"]
    legacy, lat = section(con, ck, "legacy")
    if legacy:
        pts = legacy.get("points") or {}
        out["legacy"] = {"captured_at": fmt_time(lat), "unlocked": legacy.get("unlocked"),
                         "points_unspent": pts.get("unspent"), "points_spent": pts.get("spent"),
                         "points_max_available": pts.get("maxAvailable"), "reward_track": legacy.get("track"),
                         "trees": [_tree_view(x, untaken) for x in _l(legacy.get("trees"))]}
    else:
        out["legacy"] = _missing("Legacy data", NEEDS_V2)
    if t.get("system") == "traits" and not any(x.get("not_taken") for x in out["trees"]) and untaken:
        out["note"] = "Untaken nodes need ForeverScribe 0.2+ (0.1 stored only taken talents)."
    return out


def explored(con, ck, zone=None):
    ex, at = section(con, ck, "explored")
    if not ex:
        return _missing("exploration", NEEDS_V2)
    zones = []
    for mid, z in _as_items(ex.get("zones")):
        if zone and zone.lower() not in (z.get("name") or "").lower():
            continue
        zones.append({"zone": z.get("name"), "mapID": mid, "continent": z.get("continent"),
                      "explored_overlays": z.get("n"), "areas": z.get("areas") or []})
    zones.sort(key=lambda z: (z["continent"] or "", z["zone"] or ""))
    return {"captured_at": fmt_time(at), "zones_with_exploration": ex.get("zonesWithExploration"),
            "zones_scanned": ex.get("zonesScanned"), "zones": zones,
            "note": "explored_overlays counts revealed map sections; Forever doesn't expose a zone's total, so "
                    "'fully explored' can't be told apart from 'mostly'."}


def _as_items(d):
    if isinstance(d, dict):
        return sorted(d.items(), key=lambda kv: str(kv[0]))
    return list(enumerate(_l(d)))


def achievements(con, ck, which="all", search=None, limit=200):
    a, at = section(con, ck, "achievements")
    if not a:
        return _missing("Legacy Challenges / achievements", NEEDS_V2)
    cats = {str(k): v for k, v in (a.get("categories") or {}).items()}
    rows = []
    for aid, x in _as_items(a.get("list")):
        done = bool(x.get("done"))
        if which == "done" and not done or which == "todo" and done:
            continue
        if search and search.lower() not in (x.get("n") or "").lower():
            continue
        r = {"id": aid, "name": x.get("n"), "category": (cats.get(str(x.get("c"))) or {}).get("name"),
             "status": "done" if done else ("earned on another character" if x.get("account") else "not done")}
        if x.get("lp"):
            r["legacy_points"] = x["lp"]
        if x.get("p"):
            r["points"] = x["p"]
        if done and x.get("d"):
            r["completed"] = x["d"]
        if not done:
            if x.get("q"):
                r["criteria"] = x["q"]
            if x.get("qty"):
                r["progress"] = x["qty"]
            if x.get("todo"):
                r["remaining"] = x["todo"]
        rows.append(r)
    rows.sort(key=lambda r: (r["status"] != "done", r.get("completed") or "", r["name"] or ""), reverse=False)
    by_cat = {}
    for c in cats.values():
        if c.get("n"):
            by_cat[c.get("name") or "?"] = "%s/%s" % (c.get("done"), c.get("n"))
    stats, _ = section(con, ck, "statistics")
    out = {"captured_at": fmt_time(at), "total": a.get("total"), "done": a.get("earned"),
           "done_on_account": a.get("earnedAccount"), "achievement_points": a.get("points"),
           "by_category": by_cat, "matches": len(rows), "list": rows[:limit]}
    if stats:
        out["statistics"] = {(v.get("n") or k): v.get("v") for k, v in _as_items(stats.get("values"))}
    out["note"] = ("Forever shows achievements as Legacy Challenges; completing them earns Legacy Points for the "
                   "Legacy trees (see `foreverscribe talents`).")
    return out


def collections(con, ck):
    c, at = section(con, ck, "collections")
    titles, tat = section(con, ck, "titles")
    out = {"captured_at": fmt_time(at)}
    if c:
        out["mounts"] = sorted((m.get("n") or str(k)) for k, m in _as_items(c.get("mounts")))
        out["pets"] = sorted("%s%s" % (p.get("n") or p.get("s"), " (%s)" % p["c"] if p.get("c") else "") for p in _l(c.get("pets")))
        out["toys"] = sorted((v if isinstance(v, str) else str(k)) for k, v in _as_items(c.get("toys")))
        out["counts"] = {"mounts": c.get("numMounts") or 0, "pets": c.get("numPets") or 0, "toys": c.get("numToys") or 0}
    if titles:
        out["titles"] = sorted((v or "").replace("%s", "<name>").strip() for _, v in _as_items(titles.get("known")))
        out["current_title"] = (titles.get("currentName") or "").replace("%s", "<name>").strip() or None
    if not c and not titles:
        return _missing("collections", NEEDS_V2)
    out["note"] = "Toys come from the Toy Box's current filter (ForeverScribe never changes your filters)."
    return out


def stats(con, ck):
    snap, at = latest_snapshot(con, ck)
    st = snap.get("stats")
    if not st:
        return _missing("character stats", NEEDS_V2)
    prim = {k: v.get("eff") for k, v in (st.get("primary") or {}).items()}
    out = {"captured_at": fmt_time(st.get("capturedAt") or at), "health": st.get("health"), "mana_or_power": st.get("power"),
           "primary": prim, "armor": st.get("armor"), "resistances": st.get("resist") or {},
           "spell": {"power_by_school": st.get("spellPower"), "best": st.get("spellPowerMax"), "healing": st.get("healing"),
                     "crit_pct": st.get("spellCrit"), "hit_pct": st.get("spellHit"), "haste_pct": st.get("spellHaste"),
                     "penetration": st.get("spellPen")},
           "melee": {"attack_power": st.get("attackPower"), "crit_pct": st.get("meleeCrit"), "hit_pct": st.get("meleeHit"),
                     "damage": st.get("meleeDamage"), "speed": st.get("meleeSpeed")},
           "ranged": {"attack_power": st.get("rangedAttackPower"), "crit_pct": st.get("rangedCrit")},
           "defense": {"defense": st.get("defense"), "dodge_pct": st.get("dodge"), "parry_pct": st.get("parry"),
                       "block_pct": st.get("block")},
           "mana_regen_per_5s": st.get("manaRegen"), "avg_item_level": st.get("itemLevel"),
           "durability": snap.get("durability"), "buffs": [b.get("n") for b in _l(snap.get("buffs"))],
           "pvp": snap.get("pvp"), "guild": snap.get("guild"), "game_mode": snap.get("mode")}
    sk = [s for s in _l(snap.get("skills")) if (s.get("group") or "") in ("Weapon Skills", "Armor Proficiencies")]
    if sk:
        out["weapon_armor_skills"] = {s.get("name"): "%s/%s" % (s.get("rank"), s.get("max")) for s in sk}
    out["note"] = "Stats are refreshed after gear changes, level-ups and buffs; buffs reflect the moment of the snapshot."
    return out


def currencies(con, ck):
    c, at = section(con, ck, "currencies")
    if not c:
        return _missing("currencies", NEEDS_V2)
    rows = []
    for x in _l(c.get("list")):
        r = {"name": x.get("name"), "amount": x.get("qty"), "group": x.get("group")}
        if x.get("max"):
            r["max"] = x["max"]
        if x.get("weekMax"):
            r["this_week"] = "%s/%s" % (x.get("week"), x.get("weekMax"))
        rows.append(r)
    snap, _ = latest_snapshot(con, ck)
    return {"captured_at": fmt_time(at), "money": money(snap.get("money")), "currencies": rows}


def lockouts(con, ck, now=None):
    now = now or now_ts()
    l, at = section(con, ck, "lockouts")
    if not l:
        return _missing("instance lockouts", NEEDS_V2)
    rows = []
    for x in _l(l.get("list")):
        reset = x.get("resetAt")
        if reset and reset < now:
            continue
        rows.append({"instance": x.get("name"), "difficulty": x.get("difficulty"), "bosses": x.get("bosses"),
                     "resets": fmt_time(reset), "resets_in": fmt_age(reset - now) if reset else None,
                     "raid": bool(x.get("raid")), "world_boss": bool(x.get("worldBoss")) or None})
    return {"captured_at": fmt_time(at), "active": rows,
            "note": "Lockouts whose reset time has passed are hidden." if l.get("list") else None}


def mail(con, ck):
    m, at = section(con, ck, "mail")
    if not m:
        return _missing("mailbox summary", "Open a mailbox in game with ForeverScribe 0.2+, then /reload.")
    rows = []
    for x in _l(m.get("mails")):
        rows.append({"from": x.get("from"), "subject": x.get("subject"), "money": money(x.get("money")) if x.get("money") else None,
                     "cod": money(x.get("cod")) if x.get("cod") else None, "days_left": x.get("days"),
                     "items": ["%sx %s" % (i.get("count") or 1, i.get("name") or i.get("itemID")) for i in _l(x.get("items"))]})
    return {"captured_at": fmt_time(at), "count": m.get("count"), "mail": rows,
            "note": "Player-to-player mail shows only money/items; sender and text are never recorded."}


def mail_v3(con, ck):
    """Mailbox from the last visit + the new-mail flag, which is read without opening the mailbox."""
    res = mail(con, ck)
    m, _ = section(con, ck, "mail")
    if m and res.get("mail"):
        for row, x in zip(res["mail"], _l(m.get("mails"))):
            inv = x.get("invoice")
            if inv:
                row["auction_invoice"] = {"type": inv.get("type"), "item": inv.get("item"), "count": inv.get("count"),
                                          "sale": money(inv.get("buyout") or inv.get("bid")) if (inv.get("buyout") or inv.get("bid")) else None,
                                          "deposit": money(inv.get("deposit")) if inv.get("deposit") else None,
                                          "ah_cut": money(inv.get("fee")) if inv.get("fee") else None}
    mp, at = section(con, ck, "mailPending")
    if mp:
        res["new_mail"] = {"waiting": bool(mp.get("hasNew")), "from": mp.get("senders") or [], "checked_at": fmt_time(at),
                           "note": "Senders come from the minimap mail flag (up to 3); players show as 'player'."}
    return res


def auctions(con, ck, now=None):
    a, at = section(con, ck, "auctions")
    newest = con.execute("SELECT MAX(t) AS t FROM events WHERE char_key=?", (ck,)).fetchone()["t"] or now or now_ts()
    evs = events(con, ck, since=newest - 14 * 86400, limit=200, types=list(AUCTION_VERBS))  # last 14 days of play
    out = {"outcomes_14d": [{"at": e["when"], "what": describe_event(e)} for e in evs]}  # type: dict
    if not a:
        out.update(_missing("owned auctions", "Open the auction house in game (ForeverScribe 0.3+), then /reload."))
        return out
    rows = []
    for x in _l(a.get("list")):
        tl = x.get("timeLeft")
        rows.append({"item": x.get("name") or x.get("itemID"), "itemID": x.get("itemID"), "qty": x.get("qty"),
                     "status": x.get("status"), "buyout": money(x.get("buyout")) if x.get("buyout") else None,
                     "bid": money(x.get("bid")) if x.get("bid") else None, "has_bid": x.get("hasBidder") or None,
                     "time_left_at_capture": fmt_age(tl) if tl else None})
    out.update({"captured_at": fmt_time(at), "count": a.get("count"), "complete": a.get("full"), "auctions": rows,
                "note": "Owned auctions as the client showed them the last time the AH was open. Outcomes since then "
                        "come from Blizzard's auction system messages."})
    return out


def vendor(con, ck, npc=None):
    v, at = section(con, ck, "vendors")
    if not v:
        return _missing("vendor lists", "Talk to a vendor in game (ForeverScribe 0.3+), then /reload.")
    npcs = v.get("npcs") or {}
    if npc is None:
        return {"captured_at": fmt_time(at), "last": v.get("last"),
                "vendors": sorted(({"npcID": x.get("npcID"), "name": x.get("name"), "items": len(_l(x.get("items"))),
                                    "seen_at": fmt_time(x.get("seenAt"))} for x in npcs.values()),
                                  key=lambda r: r["seen_at"] or "", reverse=True)}
    want = str(npc).lower()
    hit = None
    for k, x in npcs.items():
        if str(k) == want or str(x.get("npcID")) == want or want in (x.get("name") or "").lower():
            hit = x
            break
    if not hit:
        return {"available": False, "note": "No captured vendor matches %r. `vendor` lists the ones seen." % npc}
    items = []
    for it in _l(hit.get("items")):
        cost = []
        if it.get("price"):
            cost.append(money(it["price"]))
        for c in _l(it.get("cost")):
            cost.append("%s %s" % (c.get("qty"), c.get("name") or c.get("currencyID") or c.get("itemID")))
        items.append({"item": it.get("name"), "itemID": it.get("itemID"), "cost": " + ".join(cost) or "free",
                      "stack": it.get("stack") if (it.get("stack") or 1) > 1 else None,
                      "limited_stock": it.get("limited"), "usable": it.get("usable"), "known": it.get("known") or None,
                      "purchasable": it.get("purchasable")})
    return {"npcID": hit.get("npcID"), "name": hit.get("name"), "seen_at": fmt_time(hit.get("seenAt")), "items": items,
            "note": "Exactly what the vendor showed this character. usable=false means the client marked it red "
                    "(level/skill/class); known=true = 'Already known'."}


COLD_KINDS = {"addons": "addons", "keybinds": "bindings", "bindings": "bindings", "actionbars": "actionbars", "macros": "macros"}


def cold(con, ck, kind):
    name = COLD_KINDS.get(kind)
    if not name:
        return {"error": "unknown cold section %r; use addons | keybinds | actionbars | macros" % kind}
    d, at = section(con, ck, name)
    if not d:
        return _missing(kind, "Needs ForeverScribe 0.3+ in game, then /reload.")
    if name == "addons":
        rows = [{"name": a.get("name"), "title": a.get("title"), "version": a.get("version"),
                 "enabled": bool(a.get("enabled")), "loaded": bool(a.get("loaded")), "reason": a.get("reason")}
                for a in _l(d.get("list"))]
        return {"captured_at": fmt_time(at), "count": len(rows), "addons": rows}
    if name == "bindings":
        return {"captured_at": fmt_time(at), "count": len(_l(d.get("list"))),
                "keybinds": [{"action": b.get("action"), "keys": [k for k in (b.get("key1"), b.get("key2")) if k],
                              "category": b.get("cat")} for b in _l(d.get("list"))]}
    if name == "actionbars":
        slots = d.get("slots") or {}
        pairs = enumerate(slots, 1) if isinstance(slots, list) else slots.items()
        rows = [{"slot": int(k), "type": v.get("type"), "id": v.get("id"), "name": v.get("name")}
                for k, v in pairs if str(k).isdigit() and isinstance(v, dict)]
        rows.sort(key=lambda r: r["slot"])
        return {"captured_at": fmt_time(at), "count": len(rows), "slots": rows,
                "note": "Slots 1-12 = main bar page 1; 13-24 page 2; 25-72 extra bars; higher = bonus/stance bars."}
    return {"captured_at": fmt_time(at), "account": _l(d.get("account")), "character": _l(d.get("character")),
            "note": "Macro names only; macro text is never recorded."}


def raw_files(con):
    try:
        rows = con.execute("SELECT * FROM raw_files ORDER BY name").fetchall()
    except Exception:
        return []
    return [{"file": r["name"], "account": r["account"], "size": r["size"], "updated": fmt_time(r["mtime"]),
             "status": r["status"]} for r in rows]


def everything(con, ck, now=None):
    """Every section in one JSON document (large; prefer the focused commands)."""
    snap, at = latest_snapshot(con, ck)
    out = {"state": state(con, ck, now), "equipment": equipment(con, ck), "inventory": inventory(con, ck),
           "professions": professions(con, ck, recipes=True), "flight_paths": flightpaths(con, ck),
           "talents": talents(con, ck), "reputation": reputation(con, ck), "explored": explored(con, ck),
           "achievements": achievements(con, ck, limit=100000), "collections": collections(con, ck),
           "stats": stats(con, ck), "currencies": currencies(con, ck), "lockouts": lockouts(con, ck, now),
           "mail": mail_v3(con, ck), "auctions": auctions(con, ck, now), "vendors": vendor(con, ck),
           "spellbook": snap.get("spells"), "quest_log": snap.get("quests"),
           "quests_completed": [dict(r) for r in con.execute(
               "SELECT q.quest_id, COALESCE(q.title, t.title) AS title, q.completed_at FROM quests_completed q"
               " LEFT JOIN quest_titles t ON t.quest_id=q.quest_id WHERE q.char_key=? ORDER BY q.quest_id", (ck,))],
           "dungeons": dungeons(con, ck)}
    return out


def _v2_summary_lines(con, ck):
    lines = []
    snap, _ = latest_snapshot(con, ck)
    t = snap.get("talents") or {}
    trees = _l(t.get("trees"))
    if trees:
        bits = []
        for tr in trees:
            groups = _l(tr.get("groups"))
            if groups:
                bits.append("/".join("%s %s" % (g.get("name"), g.get("spent") or 0) for g in groups))
            else:
                taken = [n for n in _l(tr.get("talents")) if (n.get("rank") or 0) > 0]
                pts = tr.get("points") if tr.get("points") is not None else sum(n.get("rank") or 0 for n in taken)
                bits.append("%s points (%s)" % (pts, ", ".join("%s %s" % (n.get("name"), n.get("rank")) for n in taken[:8])))
        unspent = t.get("unspent")
        lines.append("Talents: %s%s" % ("; ".join(bits), "; unspent %s" % unspent if unspent is not None else ""))
    legacy, _ = section(con, ck, "legacy")
    if legacy:
        pts = legacy.get("points") or {}
        track = legacy.get("track") or {}
        lines.append("Legacy: track rank %s, points unspent %s, trees %s" % (
            track.get("level"), pts.get("unspent"),
            ", ".join("%s %s" % ((x.get("name") or "").replace("Legacy ", ""), x.get("points")) for x in _l(legacy.get("trees"))) or "none"))
    rep, _ = section(con, ck, "reputation")
    if rep:
        top = sorted(_l(rep.get("factions")), key=lambda f: -(f.get("value") or 0))[:5]
        lines.append("Reputation (%d): %s" % (len(_l(rep.get("factions"))), ", ".join(
            "%s %s" % (f.get("name"), STANDING.get(f.get("standing"), "?")) for f in top)))
    a, _ = section(con, ck, "achievements")
    if a:
        lines.append("Legacy Challenges: %s/%s done" % (a.get("earned"), a.get("total")))
    ex, _ = section(con, ck, "explored")
    if ex:
        lines.append("Explored: map sections revealed in %s zones" % ex.get("zonesWithExploration"))
    c, _ = section(con, ck, "collections")
    if c:
        lines.append("Collections: %s mounts, %s pets, %s toys" % (c.get("numMounts") or 0, c.get("numPets") or 0, c.get("numToys") or 0))
    st = snap.get("stats")
    if st:
        prim = st.get("primary") or {}
        lines.append("Stats: HP %s, mana %s, int %s, spell power %s, spell crit %s%%, armor %s" % (
            st.get("health"), st.get("power"), (prim.get("int") or {}).get("eff"), st.get("spellPowerMax"),
            st.get("spellCrit"), st.get("armor")))
    return lines

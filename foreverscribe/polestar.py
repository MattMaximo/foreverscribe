"""Polestar (the leveling-guide addon) as your agent sees it: current guide, step, progress, travel target.

Two sources, merged:
  1. ForeverScribe's own snapshot (addon 0.7+, Guide.lua): what Polestar's guide window shows right now, read through
     Polestar's public calls: guide title, step N of M, the step's open goals with progress, the arrow's target and
     its next leg (a flight, a boat). This is the only place step *titles* and *goal text* come from: Polestar saves
     ids and ticks, and works the live step out from the quest log each session.
  2. Polestar's own SavedVariables, synced like ForeverScribe's (`[sync] extra_saved_variables` has "Polestar.lua"):
       WTF/Account/<acct>/SavedVariables/Polestar.lua                       PolestarDB (account: packs, imports)
       WTF/Account/<acct>/<realm>/<character>/SavedVariables/Polestar.lua   PolestarCharDB (this character)
     PolestarCharDB gives the open tabs and active guide, ticks and skips per guide, finished guides, a step the
     player pinned, the chosen route branches and the flight in progress. Every field we don't know is kept raw.
     A format change never fails ingestion: the file is stored, and what can be read is read.

  foreverscribe guide [--for CHAR] [--json]
"""
import json
import os
import re
import time

KNOWN_CHAR = ("schema", "guide", "tabs", "activeTab", "absentAt", "closedTabs", "manual", "skipped", "pins", "offers",
              "skippedQuests", "shapes", "stepKeys", "guideDone", "guideEnds", "flags", "dungeons", "welcomeSeen",
              "routes", "flightNow", "pause", "hidden", "profile", "pinnedQuests", "groupQuests", "when")
RAW_CAP = 200_000  # bytes of raw JSON kept per file (the big tables, like stepKeys, are summarized instead)


def _d(v) -> dict:
    """Lua tables come back as dict or list; give a dict view."""
    if isinstance(v, dict):
        return v
    if isinstance(v, list):
        return {i + 1: x for i, x in enumerate(v)}
    return {}


def _ids(v):
    if isinstance(v, list):
        return [x for x in v if isinstance(x, str)]
    if isinstance(v, dict):
        return [v[k] for k in sorted(k for k in v if isinstance(k, int)) if isinstance(v[k], str)]
    return []


def pretty(gid):
    """forever/alliance/02-westfall -> Westfall."""
    if not gid:
        return None
    last = str(gid).rsplit("/", 1)[-1]
    last = re.sub(r"^\d+-", "", last)
    return " ".join(w.capitalize() if w not in ("of", "the", "and") else w for w in last.replace("_", "-").split("-")) or gid


def parse_char(db):
    """PolestarCharDB -> summary dict. Never raises; unknown shapes become None/[]."""
    if not isinstance(db, (dict, list)):
        return {"error": "PolestarCharDB is not a table"}
    db = _d(db)
    out = {"schema": db.get("schema"), "guide": db.get("guide") if isinstance(db.get("guide"), str) else None}
    tabs = _ids(db.get("tabs"))
    out["tabs"] = tabs
    at = db.get("activeTab")
    out["active_tab"] = at if isinstance(at, int) else None
    if not out["guide"] and out["active_tab"] and 0 < out["active_tab"] <= len(tabs):
        out["guide"] = tabs[out["active_tab"] - 1]
    per = {}
    for gid in set(tabs) | ({out["guide"]} if out["guide"] else set()):
        man = _d(_d(db.get("manual")).get(gid))
        sk = _d(_d(db.get("skipped")).get(gid))
        pin = _d(_d(db.get("pins")).get(gid))
        per[gid] = {
            "title": pretty(gid),
            "ticked_goals": sum(1 for v in man.values() if v),
            "skipped_steps": sorted(k for k, v in sk.items() if isinstance(k, int) and v),
            "skipped_goals": sum(1 for k, v in sk.items() if isinstance(k, str) and v),
            "viewing_step": pin.get("step") if isinstance(pin.get("step"), int) else None,
            "done": bool(_d(db.get("guideDone")).get(gid)),
        }
    out["guides"] = per
    out["finished_guides"] = sorted(k for k, v in _d(db.get("guideDone")).items() if v and isinstance(k, str))
    out["routes_chosen"] = {k: v for k, v in _d(db.get("routes")).items() if isinstance(k, str) and isinstance(v, str)}
    fl = _d(db.get("flightNow"))
    out["flight"] = {"from": fl.get("fromName") or fl.get("from"), "to": fl.get("toName") or fl.get("to"),
                     "started": fl.get("started")} if fl else None
    out["pinned_quests"] = sorted(k for k, v in _d(db.get("pinnedQuests")).items() if v and isinstance(k, int))
    out["skipped_quests"] = sorted(k for k, v in _d(db.get("skippedQuests")).items() if v and isinstance(k, int))
    out["flight_paths_known"] = len(_d(_d(db.get("flags")).get("fp")))
    p = _d(db.get("pause"))
    out["paused"] = p.get("state") if p else None
    out["hidden"] = bool(db.get("hidden"))
    out["unknown_fields"] = sorted(str(k) for k in db if str(k) not in KNOWN_CHAR)
    return out


def parse_account(db):
    if not isinstance(db, (dict, list)):
        return {"error": "PolestarDB is not a table"}
    db = _d(db)
    packs = _d(db.get("packs"))
    return {"schema": db.get("schema"), "packs_off": sorted(k for k, v in packs.items() if _d(v).get("off")),
            "imported_guides": sorted(str(k) for k in _d(db.get("imports"))),
            "whats_new_seen": db.get("whatsNewSeen"),
            "fields": sorted(str(k) for k in db)}


def char_from_path(path, per_character=None):
    """(account, realm, character) for a per-character file, else (account, None, None).
    Layouts: .../Account/<acct>/<realm>/<char>/SavedVariables/<f>  (WTF, push)
             <synced folder>/<acct>/<realm>/<char>/<f>                (folder transport)
    per_character: the file's content says (PolestarCharDB); None = decide by the path's markers alone."""
    parts = os.path.abspath(path).split(os.sep)[:-1]
    if parts and parts[-1] == "SavedVariables":
        parts = parts[:-1]
    if "Account" in parts:
        i = len(parts) - 1 - parts[::-1].index("Account")
        rest = parts[i + 1:]
        if len(rest) == 3:
            return rest[0], rest[1], rest[2]
        if len(rest) == 1:
            return rest[0], None, None
    if per_character and len(parts) >= 3:
        return parts[-3], parts[-2], parts[-1]
    if per_character is None and len(parts) >= 3 and parts[-4:-3] in (["sv"], ["inbox"]):
        return parts[-3], parts[-2], parts[-1]
    return (parts[-1] if parts else None), None, None


def _fold(s):
    return re.sub(r"[^a-z0-9]", "", (s or "").lower())


def match_char(con, realm, name):
    """The ForeverScribe char_key for a WTF realm/character folder (folder names can drop spaces)."""
    rows = [r[0] for r in con.execute("SELECT char_key FROM characters").fetchall()]
    for ck in rows:
        r, _, n = ck.rpartition(":")
        if _fold(n) == _fold(name) and _fold(r) == _fold(realm):
            return ck
    for ck in rows:
        if _fold(ck.rpartition(":")[2]) == _fold(name):
            return ck
    return "%s:%s" % (realm, name)


SCHEMA = """
CREATE TABLE IF NOT EXISTS polestar_state (
    path TEXT PRIMARY KEY, scope TEXT NOT NULL, account TEXT, char_key TEXT, sha256 TEXT, mtime INTEGER,
    ingested_at INTEGER, status TEXT, error TEXT, summary TEXT, raw TEXT
);
"""


def ingest(con, path, data, sha, mtime, now=None):
    """Parse one Polestar.lua (account or per-character) into polestar_state. Returns a status string."""
    from . import svparse
    now = int(now or time.time())
    con.executescript(SCHEMA)
    status, err, summary, raw = "ok", None, None, None
    text = data.decode("latin-1")
    per_char = "PolestarCharDB" in text[:4096] or ("PolestarCharDB" in text and "PolestarDB =" not in text)
    acct, realm, char = char_from_path(path, per_char)
    scope = "char" if char else "account"
    ck = match_char(con, realm, char) if char else None
    try:
        g = svparse.parse_saved_variables(text)
        if scope == "char":
            v = g.get("PolestarCharDB")
            summary = parse_char(v) if v is not None else {"error": "no PolestarCharDB in the file"}
        else:
            v = g.get("PolestarDB")
            summary = parse_account(v) if v is not None else {"error": "no PolestarDB in the file"}
        if isinstance(v, dict):
            slim = {k: v[k] for k in v if str(k) not in ("stepKeys", "shapes", "ownShapes", "imports", "gearAdjust")}
            raw = json.dumps(slim, default=str, ensure_ascii=False)
            if len(raw) > RAW_CAP:
                raw = None
        if summary.get("error"):
            status, err = "partial", summary["error"]
    except Exception as e:  # never fail ingestion on a format change
        status, err = "unparsed", "%s: %s" % (type(e).__name__, e)
    with con:
        con.execute("INSERT OR REPLACE INTO polestar_state (path, scope, account, char_key, sha256, mtime, ingested_at,"
                    " status, error, summary, raw) VALUES (?,?,?,?,?,?,?,?,?,?,?)",
                    (path, scope, acct, ck, sha, int(mtime), now, status, err,
                     json.dumps(summary, default=str, ensure_ascii=False) if summary else None, raw))
    return status


def _saved(con, ck):
    con.executescript(SCHEMA)
    row = con.execute("SELECT * FROM polestar_state WHERE scope='char' AND char_key=? ORDER BY mtime DESC LIMIT 1",
                      (ck,)).fetchone()
    return dict(row) if row else None


def state(con, ck, now=None):
    """The merged view for one character, or {'none': reason}."""
    from . import queries as Q
    now = int(now or time.time())
    snap, at = Q.latest_snapshot(con, ck)
    live = snap.get("polestar") if isinstance(snap.get("polestar"), dict) else None
    sv = _saved(con, ck)
    sv_sum = json.loads(sv["summary"]) if sv and sv.get("summary") else None
    if not live and not sv_sum:
        return {"none": "no Polestar data for %s yet (needs ForeverScribe 0.7 in game, or Polestar.lua in "
                        "[sync] extra_saved_variables)" % ck, "character": ck}
    out = {"character": ck, "sources": []}
    if live and not live.get("none"):
        out["sources"].append("ForeverScribe snapshot, %s ago" % Q.fmt_age(max(0, now - (live.get("at") or at or now))))
        tabs = _d(live.get("tabs"))
        tl = [tabs[k] for k in sorted(k for k in tabs if isinstance(k, int))] if isinstance(live.get("tabs"), dict) else (live.get("tabs") or [])
        act = live.get("active")
        cur = tl[act - 1] if isinstance(act, int) and 0 < act <= len(tl) else (tl[0] if tl else None)
        out["polestar_version"] = live.get("version")
        out["captured_at"] = live.get("at")
        if cur:
            out["guide"] = {"id": cur.get("id"), "title": cur.get("title") or pretty(cur.get("id")),
                            "category": cur.get("category"),
                            "step": cur.get("number") or cur.get("step"), "steps": cur.get("total") or cur.get("steps"),
                            "step_index": cur.get("step"), "done_steps": cur.get("done"), "all_steps": cur.get("all"),
                            "complete": bool(cur.get("complete"))}
        out["tabs"] = [{"id": t.get("id"), "title": t.get("title") or pretty(t.get("id")),
                        "step": t.get("number") or t.get("step"), "steps": t.get("total") or t.get("steps")} for t in tl]
        st = live.get("step")
        if isinstance(st, dict):
            goals = _d(st.get("goals"))
            gl = [goals[k] for k in sorted(k for k in goals if isinstance(k, int))]
            out["current_step"] = {"title": st.get("title"), "status": st.get("status"), "goals": [
                {"kind": g.get("t"), "text": g.get("text"), "status": g.get("status"),
                 "progress": ("%s/%s" % (g["cur"], g["max"])) if g.get("max") else None,
                 "optional": bool(g.get("optional"))} for g in gl]}
        tg = live.get("target")
        if isinstance(tg, dict):
            out["travel"] = {"to": tg.get("title"), "kind": tg.get("kind"), "mapID": tg.get("map"), "x": tg.get("x"),
                             "y": tg.get("y"), "set_by": tg.get("owner") or "Polestar's guide",
                             "next_leg": tg.get("next") if isinstance(tg.get("next"), dict) else None}
    elif live and live.get("none"):
        out["sources"].append("ForeverScribe snapshot: Polestar loaded, no guide open")
    if sv_sum:
        out["sources"].append("Polestar.lua (%s, %s)" % (sv["status"], time.strftime("%Y-%m-%d %H:%M", time.localtime(sv["mtime"]))))
        out["saved"] = sv_sum
        if "guide" not in out and sv_sum.get("guide"):
            g = sv_sum["guide"]
            pg = (sv_sum.get("guides") or {}).get(g) or {}
            out["guide"] = {"id": g, "title": pretty(g), "step": pg.get("viewing_step"), "steps": None,
                            "note": "step titles need ForeverScribe 0.7 in game (Polestar saves ids only)"}
        if sv_sum.get("flight") and "travel" not in out:
            out["travel"] = {"flight": sv_sum["flight"]}
        if sv.get("error"):
            out["saved_error"] = sv["error"]
    return out


def hot_line(con, ck):
    """'Polestar: Westfall step 11/70 — next: Hand in X; Kill Defias Trappers 3/15' or None."""
    try:
        s = state(con, ck)
    except Exception:
        return None
    if s.get("none") or not s.get("guide"):
        return None
    g = s["guide"]
    line = "Polestar: %s step %s/%s" % (g.get("title") or g.get("id"), g.get("step") or "?", g.get("steps") or "?")
    if g.get("complete"):
        line += " (guide done)"
    st = s.get("current_step")
    if st:
        todo = [x for x in st.get("goals") or [] if x.get("status") not in ("done", "skipped")]
        bits = ["%s%s" % (x.get("text") or x.get("kind"), (" " + x["progress"]) if x.get("progress") and
                          x["progress"] not in (x.get("text") or "") else "") for x in todo[:2]]
        line += " — %s%s" % (st.get("title") or "", (": " + "; ".join(bits)) if bits else "")
    tr = s.get("travel") or {}
    if tr.get("to") and tr.get("set_by") != "ForeverScribe":
        line += " → arrow: %s" % tr["to"]
    return line[:240]


def render(s):
    if s.get("none"):
        return s["none"]
    lines = ["%s — Polestar%s" % (s["character"], (" " + s["polestar_version"]) if s.get("polestar_version") else "")]
    g = s.get("guide")
    if g:
        lines.append("guide: %s (%s) — step %s of %s%s" % (g.get("title"), g.get("id"), g.get("step") or "?",
                                                         g.get("steps") or "?", ", finished" if g.get("complete") else ""))
        if g.get("note"):
            lines.append("  " + g["note"])
    st = s.get("current_step")
    if st:
        lines.append("this step: %s" % (st.get("title") or "?"))
        for x in st.get("goals") or []:
            mark = {"done": "✓", "skipped": "–"}.get(x.get("status"), "•")
            lines.append("  %s %s%s%s" % (mark, x.get("text") or x.get("kind"),
                                          (" (%s)" % x["progress"]) if x.get("progress") else "",
                                          " (optional)" if x.get("optional") else ""))
    tr = s.get("travel")
    if tr:
        if tr.get("to"):
            lines.append("arrow: %s (map %s %s, %s), set by %s" % (tr["to"], tr.get("mapID"), tr.get("x"), tr.get("y"),
                                                                  tr.get("set_by")))
            if tr.get("next_leg"):
                n = tr["next_leg"]
                lines.append("  next leg: %s (%s)" % (n.get("title") or "?", n.get("kind") or "?"))
        elif tr.get("flight"):
            lines.append("flying: %s → %s" % (tr["flight"].get("from"), tr["flight"].get("to")))
    if len(s.get("tabs") or []) > 1:
        lines.append("other tabs: " + ", ".join("%s %s/%s" % (t["title"], t.get("step") or "?", t.get("steps") or "?")
                                                for t in s["tabs"] if not g or t["id"] != g.get("id")))
    sv = s.get("saved")
    if sv:
        gg = (sv.get("guides") or {}).get((g or {}).get("id")) or {}
        bits = []
        if gg.get("ticked_goals"):
            bits.append("%d goal%s ticked by hand" % (gg["ticked_goals"], "" if gg["ticked_goals"] == 1 else "s"))
        if gg.get("skipped_steps"):
            n = len(gg["skipped_steps"])
            bits.append("%d step%s skipped" % (n, "" if n == 1 else "s"))
        if sv.get("finished_guides"):
            bits.append("finished guides: %s" % ", ".join(pretty(x) for x in sv["finished_guides"][-5:]))
        if sv.get("paused"):
            bits.append("guide paused (%s)" % sv["paused"])
        if bits:
            lines.append("saved: " + "; ".join(bits))
    lines.append("from: " + "; ".join(s.get("sources") or []))
    return "\n".join(lines)

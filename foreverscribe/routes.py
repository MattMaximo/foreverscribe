"""foreverscribe route — a multi-stop route your agent builds, walked in game with /fs go (addon 0.5+).

  foreverscribe route add <npc | object | x y zone> [--title T] [--radius YARDS]   add a stop (same lookup as `way`)
  foreverscribe route add-json '[{"title":..,"mapID":..,"x":..,"y":..}, ...]'     add stops you already resolved
  foreverscribe route show | remove <n> | move <n> <to> | clear | name <text>
  foreverscribe route write [--to local|folder|http|all] [--name T]   send it to the game computer
  foreverscribe route status                                     where it was written and whether it was picked up
Options: --for CHAR, --json

In game: press /fs go (bind it: Esc > Options > Keybindings > AddOns > ForeverScribe). The first stop gets a
waypoint + arrow; arriving within the stop's radius (default 15 yd) sets the next one; /fs next skips, /fs back
goes back, /fs route lists, /fs route clear stops.

How the route reaches the game. WoW reads addon files only when they load, so the kit installs three small
load-on-demand "route slot" addons (ForeverScribe_Route01-03, "ForeverScribe · Route 1-3" in the AddOns list; 0.5-0.9
shipped ten). `route write` rewrites Route.lua in every installed slot; /fs go loads the next slot not used yet this
session, which reads the file fresh. A slot loads once per session: three new routes, then /reload frees them (your
place on the route is kept in SavedVariables, and /fs go on the same route carries on without a slot).
  local   (agent on the game computer)   written straight into Interface/AddOns/ForeverScribe_RouteNN/Route.lua
  folder  (synced folder)               written to <folder>/_route/Route.lua; the game-side sync agent copies it
                                        into the slots when it appears (seconds after the folder syncs)
  http    (receiver)                    kept in <data_dir>/route/Route.lua; the game-side sync agent asks the
                                        receiver for it every 30 s, signed with its pairing key, and copies it in
The game is never touched any other way: no keypresses, no /reload, no addon code from the agent (the file is
plain data the addon validates).
"""
import hashlib
import json
import os
import re
import sys
import time

from . import config as C

SLOTS = 10  # slot folders looked for (0.10 kits install 01-03; older installs may still have 04-10)
MAX_STOPS = 50
DEFAULT_RADIUS = 15
ROUTE_FORMAT = 1


# ---------- storage ----------
def _cfg():
    return C.load()


def route_dir(cfg=None):
    cfg = cfg or _cfg()
    return os.environ.get("FOREVERSCRIBE_ROUTE_DIR") or cfg.path("route")


def _draft_path(cfg=None):
    return os.path.join(route_dir(cfg), "route.json")


def load(cfg=None):
    try:
        with open(_draft_path(cfg), encoding="utf-8") as f:
            d = json.load(f)
        if isinstance(d, dict) and isinstance(d.get("stops"), list):
            return d
    except (OSError, ValueError):
        pass
    return {"name": "Route", "stops": []}


def save(d, cfg=None):
    p = _draft_path(cfg)
    os.makedirs(os.path.dirname(p), exist_ok=True)
    tmp = p + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(d, f, indent=1, ensure_ascii=False)
    os.replace(tmp, p)


# ---------- stops ----------
def clean_text(s, n=60):
    s = re.sub(r"[\x00-\x1f\x7f|\\\"]", "", str(s or ""))
    return re.sub(r"\s+", " ", s).strip()[:n]


def make_stop(title, mid, x, y, radius=None, source=None):
    from . import waypoints as WP
    try:
        mid, x, y = int(mid), float(x), float(y)
    except (TypeError, ValueError):
        raise ValueError("a stop needs a numeric mapID, x and y")
    if mid not in WP.maps():
        raise ValueError("mapID %s is not a Forever map ForeverScribe knows" % mid)
    if not (0 <= x <= 100 and 0 <= y <= 100):
        raise ValueError("x and y are map percent, 0-100")
    r = int(radius) if radius else DEFAULT_RADIUS
    r = max(3, min(200, r))
    st = {"title": clean_text(title) or "Stop", "mapID": mid, "x": round(x, 2), "y": round(y, 2), "r": r,
          "zone": WP.maps()[mid]["name"]}
    if source:
        st["source"] = clean_text(source, 120)
    return st


def resolve(query, char=None, title=None, radius=None):
    """A stop from the same lookup as `way` (own sightings > shared > Wowhead). Raises ValueError when not found."""
    from . import waypoints as WP
    r = WP.answer(query, char)
    if r.get("error"):
        raise ValueError("%s: %s" % (query, r["error"]))
    if not r.get("spots") or not r.get("mapID"):
        raise ValueError("%s: no position known (no Forever map, or Wowhead lists none); give coordinates" % query)
    s = r["spots"][0]
    name = title or (r.get("name") if r.get("name") != "Spot" else None) or query
    stop = make_stop(name, r["mapID"], s["x"], s["y"], radius, r.get("source"))
    if r.get("wowhead_off_yards"):
        stop["note"] = "Wowhead's pin is ~%d yd off; using the in-game sighting" % r["wowhead_off_yards"]
    return stop


# ---------- the slot file ----------
def _lua_str(s):
    s = clean_text(s, 120)
    return '"' + s.replace("\\", "").replace('"', "") + '"'


def _lua_num(v):
    return ("%.2f" % v).rstrip("0").rstrip(".") if isinstance(v, float) else str(int(v))


def render_lua(d, rev, created):
    """The data-only Lua file a slot holds. Strings are cleaned to text without quotes/escapes/pipes."""
    if not d["stops"]:
        raise ValueError("the route has no stops (route add ...)")
    if len(d["stops"]) > MAX_STOPS:
        raise ValueError("at most %d stops" % MAX_STOPS)
    lines = ["-- ForeverScribe route slot. Written by `foreverscribe route write`; data only, the addon validates it.",
             "-- rev %s, %d stops" % (rev, len(d["stops"])),
             "ForeverScribe_RouteData = {",
             "\tv = %d," % ROUTE_FORMAT,
             "\trev = %s," % _lua_str(rev),
             "\tname = %s," % _lua_str(d.get("name") or "Route"),
             "\tcreated = %d," % int(created),
             "\tstops = {"]
    for s in d["stops"]:
        lines.append("\t\t{ map = %d, x = %s, y = %s, r = %d, title = %s }," % (
            int(s["mapID"]), _lua_num(float(s["x"])), _lua_num(float(s["y"])), int(s.get("r") or DEFAULT_RADIUS),
            _lua_str(s.get("title") or "Stop")))
    lines += ["\t},", "}", ""]
    return "\n".join(lines)


EMPTY_LUA = "-- ForeverScribe route slot (data only; the companion rewrites it). Empty: no route written yet.\nForeverScribe_RouteData = nil\n"


def _atomic(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = os.path.join(os.path.dirname(path), ".%s.tmp.%d" % (os.path.basename(path), os.getpid()))
    with open(tmp, "w", encoding="utf-8", newline="\n") as f:
        f.write(text)
    os.replace(tmp, path)


def slot_dirs(addons):
    return [os.path.join(addons, "ForeverScribe_Route%02d" % i) for i in range(1, SLOTS + 1)]


def write_slots(addons, text):
    """Rewrite Route.lua in every installed slot under an AddOns folder. Returns how many slots were written."""
    n = 0
    for d in slot_dirs(addons):
        if os.path.isfile(os.path.join(d, os.path.basename(d) + ".toc")):
            _atomic(os.path.join(d, "Route.lua"), text)
            n += 1
    return n


def targets(cfg, want="auto"):
    """[(transport, path)] the route goes to: local slots, synced folder, http receiver copy."""
    mode = (cfg.get("transport") or {}).get("mode") or "local"
    folder = C._expand((cfg.get("transport") or {}).get("folder") or "")
    wd = C.wow_dir(cfg)
    out = []
    if want in ("auto", "local", "all") and wd and (mode == "local" or want != "auto"):
        out.append(("local", os.path.join(wd, "Interface", "AddOns")))
    if want in ("auto", "folder", "all") and folder:
        out.append(("folder", os.path.join(folder, "_route", "Route.lua")))
    if want in ("auto", "http", "all") and (mode == "http" or want != "auto"):
        out.append(("http", os.path.join(route_dir(cfg), "Route.lua")))
    if want in ("auto", "relay") and mode == "relay":
        out.append(("relay", os.path.join(route_dir(cfg), "Route.lua")))
    return out


def write(cfg=None, want="auto", name=None, now=None):
    cfg = cfg or _cfg()
    d = load(cfg)
    if name:
        d["name"] = clean_text(name, 40) or d.get("name")
    now = int(now or time.time())
    body = json.dumps(d["stops"], sort_keys=True)
    rev = "%d-%s" % (now, hashlib.sha256((body + str(now)).encode()).hexdigest()[:8])
    text = render_lua(d, rev, now)
    done, notes = [], []
    for kind, path in targets(cfg, want):
        if kind == "local":
            n = write_slots(path, text)
            if n:
                done.append({"transport": "local", "path": path, "slots": n})
            else:
                notes.append("no route slots in %s: install ForeverScribe 0.5 there and restart the game" % path)
        else:
            _atomic(path, text)
            done.append({"transport": kind, "path": path})
    if not done:
        raise ValueError("nowhere to write the route: " + ("; ".join(notes) or
                         "set transport.mode (local with wow.dir, folder, or http) with `foreverscribe setup`"))
    _atomic(os.path.join(route_dir(cfg), "Route.lua"), text)  # the receiver serves this copy (http mode)
    d.update(rev=rev, written_at=now, written_to=done)
    save(d, cfg)
    if any(w["transport"] == "relay" for w in done):
        notes += _relay_send(cfg)
    return {"rev": rev, "name": d.get("name"), "stops": len(d["stops"]), "written": done, "notes": notes}


def _relay_send(cfg):
    """Relay mode: encrypt and upload now (the running `relay sync` would do it within ~25 s anyway)."""
    try:
        from . import relay
        relay.push_down(cfg)
        return []
    except Exception as e:  # relay down or not paired: `relay sync` retries
        return ["not uploaded to the relay yet (%s); `foreverscribe relay sync` sends it when it can" % e]


def pickup(cfg=None):
    try:
        with open(os.path.join(route_dir(cfg), "pickup.json"), encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


def in_game(char=None):
    """The route the addon reported (SavedVariables: route_start / route_done events), newest first."""
    try:
        from . import cli, queries as Q, store
        lc = cli.load_config()
        con = store.connect(lc["db"])
        try:
            store.ingest_all(con, lc["sources"], extra=lc["extra"])
            ck = Q.resolve_char(con, char or lc["default_character"])
            if not ck:
                return {}
            r = con.execute("SELECT type, t, payload FROM events WHERE char_key=? AND type IN ('route_start','route_done')"
                            " ORDER BY t DESC LIMIT 1", (ck,)).fetchone()
        finally:
            con.close()
    except Exception:
        return {}
    if not r:
        return {}
    p = json.loads(r["payload"] or "{}")
    return {"event": r["type"], "t": r["t"], "rev": p.get("rev"), "name": p.get("name")}


# ---------- rendering ----------
def render(d):
    if not d["stops"]:
        return "No stops yet. `foreverscribe route add <npc | x y zone>`."
    lines = ["%s — %d stop%s%s" % (d.get("name") or "Route", len(d["stops"]), "" if len(d["stops"]) == 1 else "s",
                                   " (written %s, rev %s)" % (time.strftime("%Y-%m-%d %H:%M", time.localtime(d["written_at"])), d["rev"])
                                   if d.get("written_at") else " (not written yet: `foreverscribe route write`)")]
    for i, s in enumerate(d["stops"], 1):
        lines.append("  %d. %s — %s %s, %s (arrive within %d yd)%s%s" % (
            i, s["title"], s.get("zone") or s["mapID"], _lua_num(float(s["x"])), _lua_num(float(s["y"])), s.get("r") or DEFAULT_RADIUS,
            "; " + s["source"] if s.get("source") else "", "; " + s["note"] if s.get("note") else ""))
    return "\n".join(lines)


def how_to_play(res):
    kinds = {w["transport"] for w in res["written"]}
    lines = ["Route %r (%d stops, rev %s) written:" % (res["name"], res["stops"], res["rev"])]
    for w in res["written"]:
        if w["transport"] == "local":
            lines.append("  game folder: %d route slots in %s" % (w["slots"], w["path"]))
        elif w["transport"] == "folder":
            lines.append("  synced folder: %s (the game computer's sync agent copies it in once it syncs)" % w["path"])
        elif w["transport"] == "relay":
            lines.append("  relay: encrypted and uploaded (the game computer's sync agent picks it up within ~30 s)")
        else:
            lines.append("  receiver: %s (the game computer's sync agent fetches it within ~30 s)" % w["path"])
    for n in res.get("notes") or []:
        lines.append("  note: " + n)
    lines.append("In game: /fs go (or its key binding) loads it; arrival sets the next stop, /fs next skips.")
    if kinds - {"local"}:
        lines.append("If /fs go says the file is empty or shows the old route, wait a few seconds and press it again "
                     "(10 presses per session; /reload frees them).")
    return "\n".join(lines)


def status(cfg=None, char=None):
    d = load(cfg)
    out = {"name": d.get("name"), "stops": len(d["stops"]), "rev": d.get("rev"), "written_at": d.get("written_at"),
           "written_to": d.get("written_to"), "picked_up": pickup(cfg), "in_game": in_game(char)}
    return out


def render_status(s):
    if not s.get("rev"):
        return "No route written yet."
    lines = ["Route %r, %d stops, rev %s, written %s" % (s["name"], s["stops"], s["rev"],
                                                        time.strftime("%Y-%m-%d %H:%M", time.localtime(s["written_at"])))]
    p = s.get("picked_up") or {}
    if p.get("rev"):
        lines.append("game computer fetched rev %s at %s%s" % (p["rev"], time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(p["at"])),
                                                              "" if p["rev"] == s["rev"] else " (an older route; not this one yet)"))
    elif any(w["transport"] in ("http", "relay") for w in s.get("written_to") or []):
        lines.append("game computer has not fetched a route yet (is its sync agent installed and running?)")
    g = s.get("in_game") or {}
    if g.get("rev"):
        lines.append("in game (as of the last /reload): %s %s, rev %s" % (
            "started" if g["event"] == "route_start" else "finished", g.get("name"), g["rev"]))
    return "\n".join(lines)


# ---------- CLI ----------
def main(argv=None):
    a = list(sys.argv[1:] if argv is None else argv)
    opt = {"for": None, "json": False, "title": None, "radius": None, "to": "auto", "name": None}
    words = []
    while a:
        x = a.pop(0)
        if x in ("--for", "--char", "-c") and a:
            opt["for"] = a.pop(0)
        elif x == "--json":
            opt["json"] = True
        elif x == "--title" and a:
            opt["title"] = a.pop(0)
        elif x == "--radius" and a:
            opt["radius"] = int(a.pop(0))
        elif x == "--to" and a:
            opt["to"] = a.pop(0)
        elif x == "--name" and a:
            opt["name"] = a.pop(0)
        elif x in ("-h", "--help"):
            print(__doc__)
            return 0
        else:
            words.append(x)
    cmd, rest = (words[0], words[1:]) if words else ("show", [])
    cfg = _cfg()
    d = load(cfg)
    emit = lambda obj, text: print(json.dumps(obj, indent=2, ensure_ascii=False) if opt["json"] else text)
    try:
        if cmd == "add":
            if not rest:
                raise ValueError("route add <npc | object | x y zone>")
            if len(d["stops"]) >= MAX_STOPS:
                raise ValueError("at most %d stops" % MAX_STOPS)
            st = resolve(" ".join(rest), opt["for"], opt["title"], opt["radius"])
            d["stops"].append(st)
            save(d, cfg)
            emit({"added": st, "stops": len(d["stops"])}, "added stop %d: %s — %s %s, %s%s" % (
                len(d["stops"]), st["title"], st["zone"], _lua_num(st["x"]), _lua_num(st["y"]),
                " (%s)" % st["note"] if st.get("note") else ""))
        elif cmd == "add-json":
            items = json.loads(" ".join(rest))
            if isinstance(items, dict):
                items = [items]
            new = [make_stop(i.get("title"), i.get("mapID", i.get("map")), i.get("x"), i.get("y"), i.get("radius", i.get("r")),
                             i.get("source")) for i in items]
            if len(d["stops"]) + len(new) > MAX_STOPS:
                raise ValueError("at most %d stops" % MAX_STOPS)
            d["stops"] += new
            save(d, cfg)
            emit({"stops": d["stops"]}, render(d))
        elif cmd in ("remove", "rm", "del"):
            i = int(rest[0]) - 1
            if not 0 <= i < len(d["stops"]):
                raise ValueError("no stop %s" % rest[0])
            gone = d["stops"].pop(i)
            save(d, cfg)
            emit({"removed": gone}, "removed %s\n%s" % (gone["title"], render(d)))
        elif cmd == "move":
            i, j = int(rest[0]) - 1, int(rest[1]) - 1
            if not (0 <= i < len(d["stops"]) and 0 <= j < len(d["stops"])):
                raise ValueError("stop numbers are 1-%d" % len(d["stops"]))
            d["stops"].insert(j, d["stops"].pop(i))
            save(d, cfg)
            emit({"stops": d["stops"]}, render(d))
        elif cmd == "clear":
            d = {"name": "Route", "stops": []}
            save(d, cfg)
            emit({"stops": []}, "route draft cleared (the game keeps the last written route until /fs route clear)")
        elif cmd == "name":
            d["name"] = clean_text(" ".join(rest), 40) or "Route"
            save(d, cfg)
            emit({"name": d["name"]}, "route name: " + d["name"])
        elif cmd == "write":
            res = write(cfg, opt["to"], opt["name"])
            emit(res, how_to_play(res))
        elif cmd == "status":
            s = status(cfg, opt["for"])
            emit(s, render_status(s))
        elif cmd in ("show", "list"):
            emit(d, render(d))
        else:
            print(__doc__)
            return 2
    except (ValueError, IndexError) as e:
        print(str(e) or "bad arguments (see `foreverscribe route --help`)")
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())

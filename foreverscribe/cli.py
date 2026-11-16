"""foreverscribe — your WoW: Forever character, for your AI agent (read-only telemetry).

Every query first ingests any new SavedVariables / live files (cheap: unchanged
files are skipped by hash), then answers from the local SQLite store. Output is
compact text by default; --json gives machine output.

Info tiers: HOT = `summary` (always first). WARM = focused commands. COLD = `cold ...` (only when asked).
Setup: `setup`, `pair`, `receiver`, `doctor`, `config`. Agents: `mcp` (stdio MCP server).
"""

import argparse
import json
import os
import shlex
import subprocess
import sys

from . import __version__
from . import config as C
from . import queries as Q
from . import store


def load_config():
    """The per-user config (config.toml outside the repo) flattened into what the commands use."""
    cfg = C.load()
    pull = cfg.section("pull")
    return {
        "cfg": cfg,
        "db": cfg.db,
        "sources": cfg.sources,
        "extra": C.extra_sv_patterns(cfg),
        "default_character": os.environ.get("FOREVERSCRIBE_CHAR") or cfg.get("default_character") or None,
        "ssh_host": pull.get("ssh_host") or "",
        "ssh_command": pull.get("ssh_command") or "ssh -o BatchMode=yes -o ConnectTimeout=8",
        "remote_account_dir": pull.get("remote_account_dir") or "/Applications/World of Warcraft/_forever_/WTF/Account",
        "pull_dir": cfg.path("pull"),
        "export_dir": cfg.path("export"),
    }


def out(args, data, text=None):
    if args.json or text is None:
        print(json.dumps(data, indent=None if args.compact else 2, ensure_ascii=False, default=str))
    else:
        print(text)


def _kv(d, skip=()):
    return "\n".join("%s: %s" % (k, json.dumps(v, ensure_ascii=False) if isinstance(v, (dict, list)) else v)
                     for k, v in d.items() if v not in (None, [], {}) and k not in skip)


def cmd_ingest(args, con, cfg):
    res = store.ingest_all(con, cfg["sources"], extra=cfg["extra"])
    shown = [r for r in res if r["status"] != "skipped"] if not args.verbose else res
    data = {"files": len(res), "results": shown}
    text = "\n".join("%s %s: chars=%s new=%s dup=%s%s" % (r["status"], r["path"], r.get("chars", "-"), r.get("events_new"),
                                                         r.get("events_dup"), (" error=" + r["error"]) if r.get("error") else "")
                     for r in shown) or "nothing new (%d files checked)" % len(res)
    out(args, data, text)


def cmd_pull(args, con, cfg):
    """Copy ForeverScribe.lua for every account from the game computer over SSH (read-only on the remote)."""
    ssh = shlex.split(os.environ.get("FOREVERSCRIBE_SSH") or cfg["ssh_command"])
    host = args.host or cfg["ssh_host"]
    if not host:
        out(args, {"status": "error", "error": "no [pull] ssh_host in config"},
            "pull needs [pull] ssh_host = \"user@game-pc\" in config.toml (optional; the sync agent is the normal path)")
        return 2
    remote_dir = cfg["remote_account_dir"]
    dest = os.path.join(cfg["pull_dir"], "Account")
    os.makedirs(dest, exist_ok=True)
    remote = "cd %s && tar cf - */SavedVariables/ForeverScribe.lua" % shlex.quote(remote_dir)
    try:
        p = subprocess.run(ssh + [host, remote], capture_output=True, timeout=60)
    except (OSError, subprocess.TimeoutExpired) as e:
        out(args, {"status": "error", "error": str(e)}, "pull failed: %s" % e)
        return 2
    if p.returncode != 0 or not p.stdout:
        err = p.stderr.decode("utf-8", "replace").strip()[-400:]
        out(args, {"status": "error", "error": err, "code": p.returncode},
            "pull failed (%s): %s\nIs the game computer awake, reachable, with Remote Login/SSH on?" % (p.returncode, err))
        return 2
    t = subprocess.run(["tar", "xf", "-", "-C", dest], input=p.stdout, capture_output=True)
    if t.returncode != 0:
        out(args, {"status": "error", "error": t.stderr.decode()}, "untar failed: %s" % t.stderr.decode())
        return 2
    res = store.ingest_all(con, [cfg["pull_dir"]], extra=cfg["extra"])
    out(args, {"status": "ok", "bytes": len(p.stdout), "ingest": res},
        "pulled %d bytes; %s" % (len(p.stdout), "; ".join("%s new=%s" % (r["status"], r.get("events_new")) for r in res)))
    return 0


def _char(args, con):
    return Q.resolve_char(con, args.char or args._default_char)


def cmd_characters(args, con, cfg):
    rows = Q.characters(con)
    now = Q.now_ts()
    data = [{"char": r["char_key"], "level": r["level"], "class": r["class"],
             "freshness": Q.freshness(con, r["char_key"], now)["status"],
             "snapshot_at": Q.fmt_time(r["last_captured_at"])} for r in rows]
    out(args, data, "\n".join("%-32s lvl %-3s %-8s %-6s snapshot %s" % (d["char"], d["level"], d["class"], d["freshness"], d["snapshot_at"]) for d in data) or "no characters yet")


def cmd_state(args, con, cfg):
    s = Q.state(con, _char(args, con))
    f = s.pop("freshness")
    out(args, dict(s, freshness=f), _kv(s) + "\n-- data %s: snapshot %s ago (%s)" % (f["status"].upper(), f["snapshot_age"], f["snapshot_at"]))


def cmd_summary(args, con, cfg):
    ck = _char(args, con)
    text = Q.summary(con, ck, consumer=args.consumer, mark=not args.peek)
    out(args, {"summary": text}, text)


def cmd_freshness(args, con, cfg):
    f = Q.freshness(con, _char(args, con))
    out(args, f, _kv(f))


def _since(v):
    if v is None:
        return None
    try:
        return int(v)
    except ValueError:
        s, _, _ = Q.parse_timeframe(v)
        return s


def cmd_events(args, con, cfg):
    ck = _char(args, con)
    evs = Q.events(con, ck, since=_since(args.since), limit=args.limit, types=args.type)
    out(args, evs, "\n".join("%s  %-20s %s" % (e["when"], e["type"], Q.describe_event(e)) for e in evs) or "no events")


def cmd_quest(args, con, cfg):
    r = Q.quest(con, _char(args, con), " ".join(args.term))
    lines = []
    for m in r["matches"]:
        lines.append("[%s] %s — %s%s" % (m["questID"], m.get("title") or "(title unknown)", m["status"],
                                         (" (%s)" % m["completed_at"]) if m.get("completed_at") else ""))
        for o in m.get("objectives") or []:
            lines.append("    %s %s/%s%s" % (o.get("text"), o.get("have"), o.get("need"), " done" if o.get("done") else ""))
        for h in m.get("history") or []:
            lines.append("    " + h)
    out(args, r, "\n".join(lines) or r["note"])


def cmd_equipment(args, con, cfg):
    r = Q.equipment(con, _char(args, con))
    lines = ["captured %s" % r["captured_at"]]
    for e in r["equipped"]:
        stats = ", ".join("%s %s" % (k.replace("ITEM_MOD_", "").replace("_SHORT", "").lower(), v) for k, v in sorted(e["stats"].items()))
        lines.append("%-9s %s (ilvl %s, %s%s)%s%s" % (e["slot"], e["name"], e["ilvl"], e["quality"],
                                                    ", " + e["type"] if e.get("type") else "",
                                                    "  [" + stats + "]" if stats else "",
                                                    "  dur " + e["durability"] if e.get("durability") else ""))
    out(args, r, "\n".join(lines))


def cmd_inventory(args, con, cfg):
    r = Q.inventory(con, _char(args, con), args.search)
    lines = ["bags captured %s; bank %s; free bag slots %s/%s" % (r["bags_captured_at"], r["bank_captured_at"], r["free_bag_slots"], r["bag_slots"])]
    for it in r["items"]:
        lines.append("%-5s %4sx %s (%s%s)" % (it["location"], it["count"], it["name"], it["quality"], ", ilvl %s" % it["ilvl"] if it.get("equip_loc") else ""))
    out(args, r, "\n".join(lines))


def cmd_professions(args, con, cfg):
    r = Q.professions(con, _char(args, con), recipes=args.recipes)
    lines = ["%s %s/%s" % (p["name"], p["rank"], p["max"]) for p in r["professions"]]
    for s in r["recipe_scans"]:
        lines.append("  %s: %d known recipes (scanned %s)" % (s["profession"], s["known_recipes"], s["scanned_at"]))
    for x in r.get("recipes") or []:
        lines.append("  [%s] %s — %s%s" % (x["profession"], x["name"], x["color"],
                                           ", can craft %s now" % x["craftable_now"] if x["craftable_now"] is not None else ""))
    lines.append(r["note"])
    out(args, r, "\n".join(lines))


def cmd_flightpaths(args, con, cfg):
    r = Q.flightpaths(con, _char(args, con))
    out(args, r, "\n".join("%s (learned %s)" % (f["name"], f["learned"]) for f in r["known"]) + "\n" + r["note"])


def cmd_dungeons(args, con, cfg):
    r = Q.dungeons(con, _char(args, con))
    lines = []
    for run in r["runs"]:
        lines.append("%s %s: bosses %s; wipes %d; deaths %d; loot %s" % (run["entered"], run["instance"], ", ".join(run["bosses"]) or "none",
                                                                       run["wipes"], run["deaths"], ", ".join(run["loot"]) or "-"))
    out(args, r, "\n".join(lines) or "no dungeon runs recorded")


def cmd_history(args, con, cfg):
    r = Q.history(con, _char(args, con), args.timeframe)
    lines = ["%s — %d events" % (r["timeframe"], r["events"])]
    for k, v in r["summary"].items():
        if isinstance(v, dict):
            v = ", ".join("%s %s" % kv for kv in v.items())
        elif isinstance(v, list):
            v = ", ".join(map(str, v))
        lines.append("  %s: %s" % (k.replace("_", " "), v))
    out(args, r, "\n".join(lines))


def cmd_compare(args, con, cfg):
    r = Q.compare(con, _char(args, con), " ".join(args.term))
    out(args, r, json.dumps(r, indent=2, ensure_ascii=False))


def cmd_export(args, con, cfg):
    ck = _char(args, con)
    data = {"exported_at": Q.fmt_time(Q.now_ts())}
    data.update(Q.everything(con, ck))
    data["last_session"] = Q.history(con, ck, "last-session")
    data["recent_events"] = Q.events(con, ck, limit=200)
    # Keep the v0.1 export contract: quests_completed is a list of IDs; titles live alongside.
    data["quests_completed_detail"] = data.pop("quests_completed")
    data["quests_completed"] = [q["quest_id"] for q in data["quests_completed_detail"]]
    data["flightpaths"] = data["flight_paths"]
    path = args.out or os.path.join(cfg["export_dir"], ck.replace(":", "_").replace("/", "_") + ".json")
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w") as fh:
        json.dump(data, fh, indent=2, ensure_ascii=False, default=str)
    os.replace(tmp, path)
    out(args, {"path": path}, path)


def _unavailable(args, r):
    if isinstance(r, dict) and r.get("available") is False:
        out(args, r, r["note"])
        return True
    return False


def cmd_reputation(args, con, cfg):
    r = Q.reputation(con, _char(args, con), args.search)
    if _unavailable(args, r):
        return
    lines = ["captured %s — %d factions" % (r["captured_at"], r["count"])]
    for f in r["factions"]:
        lines.append("%-28s %-10s %-11s%s%s" % (f["faction"], f["standing"], f["progress"] or "",
                                                "  AT WAR" if f["at_war"] else "", "  (watched)" if f.get("watched") else ""))
    for k in ("legacy_reward_track", "pvp_rank"):
        if r.get(k):
            lines.append("%s: rank %s (%s/%s)" % (k.replace("_", " "), r[k].get("level"), r[k].get("earned"), r[k].get("threshold")))
    if r.get("note"):
        lines.append(r["note"])
    out(args, r, "\n".join(lines))


def _tree_lines(tr, untaken):
    head = "%s: %s points%s" % (tr["tree"], tr["points_spent"], (" (%s)" % ", ".join("%s %s" % kv for kv in tr["groups"].items())) if tr.get("groups") else "")
    lines = [head, "  taken: " + (", ".join(tr["taken"]) or "none")]
    if untaken and tr.get("not_taken"):
        lines.append("  not taken: " + ", ".join(tr["not_taken"]))
    return lines


def cmd_talents(args, con, cfg):
    r = Q.talents(con, _char(args, con), untaken=not args.taken_only)
    lines = ["captured %s — %s talents, unspent %s%s" % (r["captured_at"], r["system"], r["unspent_points"],
                                                          ", loadout %s" % r["loadout"] if r.get("loadout") else "")]
    for tr in r["trees"]:
        lines += _tree_lines(tr, not args.taken_only)
    lg = r.get("legacy") or {}
    if lg.get("available") is False:
        lines.append("Legacy: " + lg["note"])
    else:
        track = lg.get("reward_track") or {}
        lines.append("Legacy: reward track rank %s; points unspent %s of %s" % (track.get("level"), lg.get("points_unspent"),
                                                                                 lg.get("points_max_available")))
        for tr in lg.get("trees") or []:
            lines += _tree_lines(tr, not args.taken_only)
    if r.get("note"):
        lines.append(r["note"])
    out(args, r, "\n".join(lines))


def cmd_explored(args, con, cfg):
    r = Q.explored(con, _char(args, con), args.zone)
    if _unavailable(args, r):
        return
    lines = ["captured %s — map sections revealed in %s of %s zones" % (r["captured_at"], r["zones_with_exploration"], r["zones_scanned"])]
    for z in r["zones"]:
        if z["explored_overlays"] or args.zone:
            lines.append("%-24s %-18s %2s sections%s" % (z["zone"], z["continent"] or "", z["explored_overlays"],
                                                          ": " + ", ".join(z["areas"]) if z["areas"] else ""))
    unexplored = [z["zone"] for z in r["zones"] if not z["explored_overlays"]]
    if unexplored and not args.zone:
        lines.append("Not explored at all: " + ", ".join(unexplored))
    lines.append(r["note"])
    out(args, r, "\n".join(lines))


def cmd_achievements(args, con, cfg):
    r = Q.achievements(con, _char(args, con), which=args.which, search=args.search, limit=args.limit)
    if _unavailable(args, r):
        return
    lines = ["captured %s — %s/%s Legacy Challenges done here (%s on the account)" % (r["captured_at"], r["done"], r["total"], r["done_on_account"])]
    if r.get("by_category"):
        lines.append("by category: " + ", ".join("%s %s" % kv for kv in r["by_category"].items()))
    for a in r["list"]:
        extra = ""
        if a["status"] == "done":
            extra = " (%s)" % a.get("completed", "")
        else:
            extra = " %s%s" % (a.get("criteria") or "", (" — needs: " + "; ".join(a["remaining"])) if a.get("remaining") else "")
        lines.append("[%s] %s%s%s" % ("x" if a["status"] == "done" else " ", a["name"],
                                     " +%s LP" % a["legacy_points"] if a.get("legacy_points") else "", extra))
    if r.get("statistics") and args.which == "all" and not args.search:
        lines.append("statistics: " + ", ".join("%s %s" % kv for kv in list(r["statistics"].items())[:30]))
    out(args, r, "\n".join(lines))


def cmd_collections(args, con, cfg):
    r = Q.collections(con, _char(args, con))
    if _unavailable(args, r):
        return
    lines = ["captured %s" % r["captured_at"]]
    for k in ("mounts", "pets", "toys", "titles"):
        if r.get(k) is not None:
            lines.append("%s (%d): %s" % (k, len(r[k]), ", ".join(r[k]) or "none"))
    if r.get("current_title"):
        lines.append("current title: " + r["current_title"])
    out(args, r, "\n".join(lines))


def cmd_stats(args, con, cfg):
    r = Q.stats(con, _char(args, con))
    if _unavailable(args, r):
        return
    out(args, r, json.dumps(r, indent=2, ensure_ascii=False) if not args.json else None)


def cmd_currencies(args, con, cfg):
    r = Q.currencies(con, _char(args, con))
    if _unavailable(args, r):
        return
    lines = ["captured %s — money %s" % (r["captured_at"], r["money"])]
    for c in r["currencies"]:
        lines.append("%-28s %s%s%s" % (c["name"], c["amount"], "/%s" % c["max"] if c.get("max") else "",
                                       "  (week %s)" % c["this_week"] if c.get("this_week") else ""))
    out(args, r, "\n".join(lines))


def cmd_lockouts(args, con, cfg):
    r = Q.lockouts(con, _char(args, con))
    if _unavailable(args, r):
        return
    lines = ["captured %s" % r["captured_at"]] + ["%s %s bosses %s — resets %s (in %s)" % (
        x["instance"], x.get("difficulty") or "", x.get("bosses") or "?", x["resets"], x["resets_in"]) for x in r["active"]]
    if not r["active"]:
        lines.append("no active lockouts")
    out(args, r, "\n".join(lines))


def cmd_mail(args, con, cfg):
    r = Q.mail_v3(con, _char(args, con))
    lines = []
    nm = r.get("new_mail")
    if nm:
        lines.append("New mail waiting: %s%s (checked %s)" % ("yes" if nm["waiting"] else "no",
                                                         " from " + ", ".join(nm["from"]) if nm["from"] else "", nm["checked_at"]))
    if r.get("available") is False:
        lines.append(r["note"])
        out(args, r, "\n".join(lines))
        return
    lines.append("mailbox as of %s — %s letters" % (r["captured_at"], r["count"]))
    for m in r["mail"]:
        inv = m.get("auction_invoice")
        lines.append("%s%s%s%s%s" % (m["from"], ": " + m["subject"] if m.get("subject") else "",
                                     "  " + m["money"] if m.get("money") else "", "  [" + ", ".join(m["items"]) + "]" if m["items"] else "",
                                     "  (AH %s: %s%s, cut %s)" % (inv["type"], inv.get("item"), " x%s" % inv["count"] if inv.get("count") else "",
                                                                  inv.get("ah_cut")) if inv else ""))
    lines.append(r["note"])
    out(args, r, "\n".join(lines))


def cmd_auctions(args, con, cfg):
    r = Q.auctions(con, _char(args, con))
    lines = []
    if r.get("available") is False:
        lines.append(r["note"])
    else:
        lines.append("owned auctions as of %s: %s%s" % (r["captured_at"], r["count"], "" if r.get("complete") else " (list may be partial)"))
        for a in r["auctions"]:
            lines.append("  %-7s %sx %s  buyout %s%s%s" % (a["status"], a.get("qty") or 1, a["item"], a.get("buyout") or "-",
                                                         "  bid " + a["bid"] if a.get("bid") else "",
                                                         "  ~" + a["time_left_at_capture"] + " left then" if a.get("time_left_at_capture") else ""))
    if r["outcomes_14d"]:
        lines.append("outcomes (14 days, from Blizzard auction messages):")
        lines += ["  %s  %s" % (o["at"], o["what"]) for o in r["outcomes_14d"]]
    out(args, r, "\n".join(lines))


def cmd_vendor(args, con, cfg):
    r = Q.vendor(con, _char(args, con), " ".join(args.npc) if args.npc else None)
    if _unavailable(args, r):
        return
    if "vendors" in r:
        lines = ["vendors this character has opened (newest first):"]
        lines += ["  [%s] %s — %s items, seen %s" % (v["npcID"], v["name"], v["items"], v["seen_at"]) for v in r["vendors"]]
        lines.append("`vendor <npcID|name>` for one list; `wowhead vendor <npcID>` judges it against your gear/skills.")
    else:
        lines = ["%s [%s] seen %s" % (r["name"], r["npcID"], r["seen_at"])]
        for it in r["items"]:
            flags = [f for f, on in (("KNOWN", it.get("known")), ("can't use", it.get("usable") is False),
                                     ("stock %s" % it.get("limited_stock"), it.get("limited_stock") is not None)) if on]
            lines.append("  %s [%s]: %s%s%s" % (it["item"], it["itemID"], it["cost"], " (stack %s)" % it["stack"] if it.get("stack") else "",
                                                "  " + ", ".join(flags) if flags else ""))
        lines.append(r["note"])
    out(args, r, "\n".join(lines))


def cmd_cold(args, con, cfg):
    r = Q.cold(con, _char(args, con), args.kind)
    if r.get("error"):
        out(args, r, r["error"])
        return 2
    if _unavailable(args, r):
        return
    if args.kind == "addons":
        lines = ["addons as of %s (%d):" % (r["captured_at"], r["count"])]
        lines += ["  %-28s %-10s %s%s" % (a["name"], a.get("version") or "", "loaded" if a["loaded"] else ("enabled" if a["enabled"] else "disabled"),
                                         " (%s)" % a["reason"] if a.get("reason") else "") for a in r["addons"]]
    elif args.kind in ("keybinds", "bindings"):
        lines = ["keybinds as of %s (%d bound):" % (r["captured_at"], r["count"])]
        lines += ["  %-30s %s" % (b["action"], " / ".join(b["keys"])) for b in r["keybinds"]]
    elif args.kind == "actionbars":
        lines = ["action bars as of %s (%d slots used):" % (r["captured_at"], r["count"])]
        lines += ["  %3d  %-8s %s" % (s["slot"], s["type"] or "", s.get("name") or s.get("id") or "") for s in r["slots"]]
        lines.append(r["note"])
    else:
        lines = ["macros as of %s" % r["captured_at"], "  account: " + (", ".join(r["account"]) or "none"),
                 "  character: " + (", ".join(r["character"]) or "none"), r["note"]]
    out(args, r, "\n".join(lines))


def cmd_files(args, con, cfg):
    """Other addons' SavedVariables kept alongside (e.g. Forever Forge): stored raw until a parser exists."""
    rows = Q.raw_files(con)
    out(args, {"files": rows, "note": "Stored unparsed: no real sample has been inspected yet."},
        "\n".join("%s (%s): %s bytes, updated %s, %s" % (r["file"], r["account"], r["size"], r["updated"], r["status"]) for r in rows)
        or "no extra SavedVariables files synced (config [sync] extra_saved_variables)")


def cmd_everything(args, con, cfg):
    ck = _char(args, con)
    data = Q.everything(con, ck)
    if args.out:
        os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
        with open(args.out + ".tmp", "w") as fh:
            json.dump(data, fh, indent=2, ensure_ascii=False, default=str)
        os.replace(args.out + ".tmp", args.out)
        out(args, {"path": args.out}, args.out)
        return
    print(json.dumps(data, indent=None if args.compact else 2, ensure_ascii=False, default=str))


COMMANDS = {
    "ingest": cmd_ingest, "pull": cmd_pull, "characters": cmd_characters, "state": cmd_state, "summary": cmd_summary,
    "freshness": cmd_freshness, "events": cmd_events, "quest": cmd_quest, "equipment": cmd_equipment,
    "inventory": cmd_inventory, "professions": cmd_professions, "flightpaths": cmd_flightpaths,
    "dungeons": cmd_dungeons, "history": cmd_history, "compare": cmd_compare, "export": cmd_export,
    "reputation": cmd_reputation, "talents": cmd_talents, "explored": cmd_explored, "achievements": cmd_achievements,
    "collections": cmd_collections, "stats": cmd_stats, "currencies": cmd_currencies, "lockouts": cmd_lockouts,
    "mail": cmd_mail, "everything": cmd_everything, "dump": cmd_everything,
    "auctions": cmd_auctions, "vendor": cmd_vendor, "cold": cmd_cold, "files": cmd_files,
}

# Commands that don't read the telemetry store (setup, transport, agent integrations, game data).
TOOLS = ("setup", "pair", "receiver", "doctor", "config", "mcp", "ah", "wowhead", "gear", "rate", "craft", "aca", "page", "version",
         "way")
WOWHEAD_ALIASES = ("gear", "rate", "craft", "aca", "page")


EPILOG = """more commands:
  setup | pair | receiver [run|health|launchagent] | doctor | config [path|show]   setup and transport
  mcp                                   stdio MCP server for Claude / Codex / Hermes / any MCP client
  way <npc|object|x y zone>             where it is + the chat command that pins it with an arrow
  gear | rate <ids> | craft <ids> | aca | page <path>   Wowhead Forever, judged for the character
  wowhead <item|npc|quest|zone|spell|vendor|import-page|weights> ...   (see `foreverscribe wowhead`)
  ah <item> [...]                       auction-house prices (off unless enabled in config)
  version"""


def build_parser():
    p = argparse.ArgumentParser(prog="foreverscribe", description=__doc__.split("\n")[0], epilog=EPILOG,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--char", "-c", help="character (name, Realm:Name, or class); default = most recently seen")
    p.add_argument("--json", action="store_true", help="JSON output")
    p.add_argument("--compact", action="store_true", help="single-line JSON")
    p.add_argument("--no-ingest", action="store_true", help="skip the automatic ingest before querying")
    p.add_argument("--db", help="SQLite path (default <data_dir>/forever.db)")
    sub = p.add_subparsers(dest="cmd")
    sub.add_parser("ingest", help="ingest new SavedVariables/live files").add_argument("--verbose", "-v", action="store_true")
    sub.add_parser("pull", help="copy SavedVariables from the game computer over SSH, then ingest").add_argument("--host")
    sub.add_parser("characters", help="list known characters")
    sub.add_parser("state", help="level, xp, gold, location, hearth")
    s = sub.add_parser("summary", help="HOT tier: compact context block for an agent (run first)")
    s.add_argument("--peek", action="store_true", help="don't advance the 'new since last check' marker")
    s.add_argument("--consumer", default="default", help="separate 'new since last check' marker per agent")
    sub.add_parser("freshness", help="how old the data is")
    e = sub.add_parser("events", help="event log")
    e.add_argument("--since", help="epoch or timeframe (today, 24h, last-session)")
    e.add_argument("--limit", type=int, default=30)
    e.add_argument("--type", action="append", help="filter by event type (repeatable)")
    sub.add_parser("quest", help="quest status by id or name").add_argument("term", nargs="+")
    sub.add_parser("equipment", help="equipped gear with stats")
    sub.add_parser("inventory", help="bags + bank").add_argument("search", nargs="?")
    sub.add_parser("professions", help="profession skills").add_argument("--recipes", action="store_true")
    sub.add_parser("flightpaths", help="known flight paths")
    sub.add_parser("dungeons", help="dungeon runs, bosses, loot")
    sub.add_parser("history", help="what happened in a timeframe").add_argument("timeframe", nargs="?", default="last-session")
    sub.add_parser("compare", help="owned item vs what is equipped in its slot").add_argument("term", nargs="+")
    sub.add_parser("export", help="write a JSON export").add_argument("--out")
    sub.add_parser("reputation", help="every faction: standing, progress, at war").add_argument("search", nargs="?")
    sub.add_parser("talents", help="class talents (taken + not taken) and Legacy trees").add_argument(
        "--taken-only", action="store_true")
    sub.add_parser("explored", help="explored zones/areas").add_argument("zone", nargs="?")
    a = sub.add_parser("achievements", help="Legacy Challenges (achievements) + statistics")
    a.add_argument("which", nargs="?", choices=["all", "done", "todo"], default="all")
    a.add_argument("--search")
    a.add_argument("--limit", type=int, default=200)
    sub.add_parser("collections", help="mounts, pets, toys, titles")
    sub.add_parser("stats", help="character sheet stats, durability, buffs, PvP, guild")
    sub.add_parser("currencies", help="currencies and tokens")
    sub.add_parser("lockouts", help="saved instances / raid lockouts")
    sub.add_parser("mail", help="new-mail flag + mailbox (incl. AH invoices) from the last visit")
    sub.add_parser("auctions", help="owned auctions (last AH visit) + sold/expired/outbid/won since")
    sub.add_parser("vendor", help="vendor lists this character has seen").add_argument("npc", nargs="*")
    sub.add_parser("cold", help="COLD tier: addons | keybinds | actionbars | macros").add_argument(
        "kind", choices=["addons", "keybinds", "bindings", "actionbars", "macros"])
    sub.add_parser("files", help="other addons' SavedVariables synced alongside (raw)")
    for name in ("everything", "dump"):
        sub.add_parser(name, help="every section as one JSON document").add_argument("--out")
    return p


def run_tool(argv):
    cmd, rest = argv[0], argv[1:]
    if cmd == "version":
        print("foreverscribe " + __version__)
        return 0
    if cmd == "ah":
        from . import ah
        return ah.main(rest)
    if cmd in ("wowhead",) + WOWHEAD_ALIASES:
        from . import wowhead
        return wowhead.main(rest if cmd == "wowhead" else [cmd] + rest) or 0
    if cmd == "way":
        from . import waypoints
        return waypoints.main(rest)
    if cmd == "mcp":
        from . import mcp_server
        return mcp_server.main(rest)
    from . import admin
    return admin.main(cmd, rest)


def main(argv=None):
    argv = list(sys.argv[1:] if argv is None else argv)
    first = next((a for a in argv if not a.startswith("-")), None)
    if first in TOOLS and argv and argv[0] == first:
        return run_tool(argv)
    args = build_parser().parse_args(argv)
    if not args.cmd:
        args.cmd = "summary"
    cfg = load_config()
    args._default_char = cfg["default_character"]
    if args.db:
        cfg["db"] = args.db
    os.makedirs(os.path.dirname(os.path.abspath(cfg["db"])), exist_ok=True)
    con = store.connect(cfg["db"])
    try:
        if args.cmd not in ("ingest", "pull") and not args.no_ingest:
            store.ingest_all(con, cfg["sources"], extra=cfg["extra"])
        if args.cmd not in ("ingest", "pull", "characters", "files") and not Q.characters(con):
            print("No ForeverScribe data yet. Install the addon in WoW: Forever, log in once and /reload, then check "
                  "`foreverscribe doctor` (it shows which folders are read: %s)." % (", ".join(cfg["sources"]) or "none"))
            return 3
        rc = COMMANDS[args.cmd](args, con, cfg)
        return rc or 0
    except KeyError as e:
        print(str(e).strip("'\""))
        return 4
    except ValueError as e:
        print(str(e))
        return 5
    finally:
        con.close()


if __name__ == "__main__":
    sys.exit(main())

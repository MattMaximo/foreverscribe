"""ForeverScribe MCP server (stdio, JSON-RPC 2.0, one message per line). Standard library only.

  foreverscribe mcp            (or: python -m foreverscribe mcp)

Every tool runs the matching CLI command in-process and returns its text. Tools mirror the CLI:
start with `summary` (HOT tier), then focused tools (WARM), and `cold` only when asked.
Read-only: nothing here changes the game, the addon or the user's files (other than the local
cache/database the CLI already maintains).
"""

import contextlib
import io
import json
import sys
import traceback

from . import __version__

PROTOCOL = "2025-06-18"
SUPPORTED = ("2025-06-18", "2025-03-26", "2024-11-05")

CHAR = {"type": "string", "description": "character name or Realm:Name (default: the configured or most recent one)"}


def _obj(props=None, required=None):
    p = dict(props or {})
    p["character"] = CHAR
    return {"type": "object", "properties": p, "required": list(required or []), "additionalProperties": False}


def _s(desc):
    return {"type": "string", "description": desc}


# name -> (description, input schema, argv builder)
TOOLS = {
    "summary": ("HOT tier. Run first for any WoW: Forever question: who/level/gold/where, data freshness, gear one-liner, "
                "quest log, and what is new since the last check (sales, mail, levels, drops).",
                _obj({"peek": {"type": "boolean", "description": "don't advance the 'new since last check' marker"}}),
                lambda a: ["summary"] + (["--peek"] if a.get("peek") else []) + ["--consumer", "mcp"]),
    "freshness": ("How old the telemetry is (snapshot and live events).", _obj(), lambda a: ["freshness"]),
    "characters": ("Characters with telemetry.", _obj(), lambda a: ["characters"]),
    "quest": ("Quest status by id or name (in log with objectives, completed, or never seen).",
              _obj({"term": _s("quest id or part of the title")}, ["term"]), lambda a: ["quest", str(a["term"])]),
    "equipment": ("Equipped gear with item level, stats and durability.", _obj(), lambda a: ["equipment"]),
    "inventory": ("Bags and bank contents, optionally filtered.", _obj({"search": _s("item name filter")}),
                  lambda a: ["inventory"] + ([a["search"]] if a.get("search") else [])),
    "professions": ("Profession skill levels; with recipes=true, known recipes with difficulty and craftable count.",
                    _obj({"recipes": {"type": "boolean"}}), lambda a: ["professions"] + (["--recipes"] if a.get("recipes") else [])),
    "reputation": ("Every faction: standing, progress, at war; Legacy reward track.", _obj({"search": _s("faction filter")}),
                   lambda a: ["reputation"] + ([a["search"]] if a.get("search") else [])),
    "talents": ("Class talents taken and not taken (available now marked), Legacy trees.", _obj(), lambda a: ["talents"]),
    "explored": ("Explored zones and areas.", _obj({"zone": _s("zone filter")}),
                 lambda a: ["explored"] + ([a["zone"]] if a.get("zone") else [])),
    "achievements": ("Legacy Challenges (achievements) done/todo with criteria, plus statistics.",
                     _obj({"which": {"type": "string", "enum": ["all", "done", "todo"]}, "search": _s("name filter")}),
                     lambda a: ["achievements", a.get("which") or "all"] + (["--search", a["search"]] if a.get("search") else [])),
    "collections": ("Mounts, pets, toys, titles.", _obj(), lambda a: ["collections"]),
    "stats": ("Character sheet stats, durability, buffs, PvP, guild.", _obj(), lambda a: ["stats"]),
    "currencies": ("Currencies and tokens with caps.", _obj(), lambda a: ["currencies"]),
    "lockouts": ("Saved instances and reset times.", _obj(), lambda a: ["lockouts"]),
    "mail": ("New-mail flag (read without opening the mailbox) and the mailbox from the last visit, incl. AH invoices.",
             _obj(), lambda a: ["mail"]),
    "auctions": ("Owned auctions from the last AH visit plus sold/expired/outbid/won outcomes since.", _obj(),
                 lambda a: ["auctions"]),
    "vendor": ("Vendor lists this character has opened (exact prices, currency costs, known/usable). No npc = list vendors.",
               _obj({"npc": _s("NPC id or name")}), lambda a: ["vendor"] + ([str(a["npc"])] if a.get("npc") else [])),
    "events": ("Raw event log.", _obj({"since": _s("epoch or timeframe: today, 24h, 7d, last-session"),
                                      "type": {"type": "array", "items": {"type": "string"}}, "limit": {"type": "integer"}}),
               lambda a: ["events"] + (["--since", a["since"]] if a.get("since") else [])
               + sum([["--type", t] for t in (a.get("type") or [])], []) + (["--limit", str(a["limit"])] if a.get("limit") else [])),
    "history": ("What happened in a timeframe: levels, quests, skill-ups, loot, gold, reputation.",
                _obj({"timeframe": _s("last-session (default), today, yesterday, 24h, 7d")}),
                lambda a: ["history", a.get("timeframe") or "last-session"]),
    "compare": ("Owned item vs what is equipped in its slot.", _obj({"term": _s("item name or id")}, ["term"]),
                lambda a: ["compare", str(a["term"])]),
    "dungeons": ("Dungeon runs, bosses, wipes, loot.", _obj(), lambda a: ["dungeons"]),
    "cold": ("COLD tier, only when the user asks: installed addons, keybinds, action bars, macro names.",
             _obj({"kind": {"type": "string", "enum": ["addons", "keybinds", "actionbars", "macros"]}}, ["kind"]),
             lambda a: ["cold", a["kind"]]),
    "gear": ("Equipped gear scored for the detected spec, weakest slots first, empty slots flagged (Wowhead Forever data).",
             _obj(), lambda a: ["gear"]),
    "rate": ("Score items (ids) against what the character wears in that slot.",
             _obj({"items": {"type": "array", "items": {"type": ["string", "integer"]}}}, ["items"]),
             lambda a: ["rate"] + [str(x) for x in a["items"]]),
    "craft": ("Crafted item vs worn, skill gate, mats have/need, AH cost (recipe item ids).",
              _obj({"items": {"type": "array", "items": {"type": ["string", "integer"]}}}, ["items"]),
              lambda a: ["craft"] + [str(x) for x in a["items"]]),
    "wowhead": ("Wowhead Forever lookup: item|npc|quest|zone|spell <id>, vendor <npcID>, aca, page <path> [--rate]. "
                "If it prints NEED, fetch that URL as markdown and pass it to import_page.",
                _obj({"args": {"type": "array", "items": {"type": "string"}}}, ["args"]), lambda a: ["wowhead"] + list(a["args"])),
    "import_page": ("Store a markdown copy of a www.wowhead.com/forever page that a wowhead tool asked for (NEED line).",
                    _obj({"url": _s("the URL from the NEED line"), "markdown": _s("the page as markdown")}, ["url", "markdown"]),
                    None),
    "ah_price": ("Auction-house prices (median, 7d/30d) for items. Off unless the user enabled [ah] in config.",
                 _obj({"items": {"type": "array", "items": {"type": "string"}}}, ["items"]), lambda a: ["ah"] + list(a["items"])),
    "waypoint": ("Where an NPC, object or spot is in WoW: Forever, plus ONE chat command to paste that puts a map pin and "
                 "an arrow on it (chosen for the character's loaded addons: ForeverScribe /scribe way, TomTom, Polestar, or "
                 "Forever's native pin). Query: a name with optional zone words ('first aid trainer stormwind'), npc=<id>, "
                 "object=<id>, or 'x y zone'. Never invent coordinates: if it says not found or unknown, say so.",
                 _obj({"query": _s("name [+ zone words], npc=<id>, object=<id>, or 'x y zone'"),
                       "addon": {"type": "string", "enum": ["scribe", "native", "tomtom", "polestar", "mappin"],
                                 "description": "force a command style (default: by the character's loaded addons)"}},
                      ["query"]),
                 lambda a: ["way"] + (["--addon", a["addon"]] if a.get("addon") else []) + str(a["query"]).split()),
    "doctor": ("Check the ForeverScribe setup (config, sources, receiver).", {"type": "object", "properties": {}}, lambda a: ["doctor"]),
}
NO_CHAR = ("gear", "rate", "craft", "wowhead", "ah_price", "doctor", "import_page", "waypoint")


def run_cli(argv, stdin_text=None):
    from . import cli
    buf = io.StringIO()
    old_stdin = sys.stdin
    try:
        if stdin_text is not None:
            sys.stdin = io.StringIO(stdin_text)
        with contextlib.redirect_stdout(buf), contextlib.redirect_stderr(buf):
            try:
                rc = cli.main(argv)
            except SystemExit as e:
                rc = e.code if isinstance(e.code, int) else (0 if e.code is None else 1)
                if not isinstance(e.code, int) and e.code:
                    print(e.code)
    finally:
        sys.stdin = old_stdin
    return rc or 0, buf.getvalue()


def call_tool(name, args):
    if name not in TOOLS:
        raise KeyError(name)
    args = args or {}
    if name == "import_page":
        rc, text = run_cli(["wowhead", "import-page", args["url"], "-"], stdin_text=args["markdown"])
    else:
        argv = TOOLS[name][2](args)
        if args.get("character") and name in ("gear", "rate", "craft", "wowhead", "waypoint"):
            argv = argv[:1] + ["--for", args["character"]] + argv[1:]
        elif args.get("character") and name not in NO_CHAR:
            argv = ["--char", args["character"]] + argv
        rc, text = run_cli(argv)
    text = text.strip() or "(no output)"
    is_error = rc not in (0, 3) and not text.startswith("NEED ")
    return {"content": [{"type": "text", "text": text}], "isError": bool(is_error)}


def tool_list():
    return [{"name": n, "description": d, "inputSchema": s} for n, (d, s, _) in TOOLS.items()]


def handle(msg):
    mid = msg.get("id")
    method = msg.get("method")
    params = msg.get("params") or {}
    if method is None:
        return None  # a response to something we never sent
    if mid is None:
        return None  # notification (initialized, cancelled, ...)
    try:
        if method == "initialize":
            want = params.get("protocolVersion")
            res = {"protocolVersion": want if want in SUPPORTED else PROTOCOL,
                   "capabilities": {"tools": {"listChanged": False}},
                   "serverInfo": {"name": "foreverscribe", "version": __version__},
                   "instructions": "WoW: Forever character telemetry (read-only). Call `summary` first; use focused tools "
                                   "for details; `cold` only when asked. Never guess game state that a tool can answer."}
        elif method == "ping":
            res = {}
        elif method == "tools/list":
            res = {"tools": tool_list()}
        elif method == "tools/call":
            try:
                res = call_tool(params.get("name"), params.get("arguments"))
            except KeyError:
                return {"jsonrpc": "2.0", "id": mid, "error": {"code": -32602, "message": "unknown tool %r" % params.get("name")}}
        elif method in ("resources/list", "prompts/list"):
            res = {method.split("/")[0]: []}
        else:
            return {"jsonrpc": "2.0", "id": mid, "error": {"code": -32601, "message": "method not found: %s" % method}}
        return {"jsonrpc": "2.0", "id": mid, "result": res}
    except Exception as e:  # never crash the server on one bad call
        return {"jsonrpc": "2.0", "id": mid, "error": {"code": -32603, "message": "%s: %s" % (type(e).__name__, e),
                                                         "data": traceback.format_exc()[-800:]}}


def serve(inp=None, outp=None):
    inp = inp or sys.stdin
    outp = outp or sys.stdout
    for line in inp:
        line = line.strip()
        if not line:
            continue
        try:
            msg = json.loads(line)
        except ValueError:
            resp = {"jsonrpc": "2.0", "id": None, "error": {"code": -32700, "message": "parse error"}}
        else:
            if isinstance(msg, list):
                resp = [r for r in (handle(m) for m in msg) if r is not None] or None
            else:
                resp = handle(msg)
        if resp is not None:
            outp.write(json.dumps(resp, ensure_ascii=False) + "\n")
            outp.flush()


def main(argv=None):
    real_out = sys.stdout
    sys.stdout = sys.stderr  # stray prints must never corrupt the protocol stream
    try:
        serve(sys.stdin, real_out)
    finally:
        sys.stdout = real_out
    return 0

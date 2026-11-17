# ForeverScribe

Your World of Warcraft: Forever character, readable by your AI agent.

A small **read-only addon** records what your character is doing (level, gear, bags, quests, professions,
reputation, talents, mail, auctions, vendors you visit, where you actually met each NPC, and more) into the game's
normal SavedVariables file.
A **companion** (Python 3.8+, standard library only) turns that file into answers for any agent:
a CLI (`foreverscribe summary`) and an **MCP server** (`foreverscribe mcp`) for Claude Desktop, Claude Code,
Codex, Hermes, or anything else that speaks MCP. No account, and nothing leaves your machines unless you set up a
transport between your own computers. The optional hosted relay (0.9) only ever holds end-to-end encrypted files.

> **Install:** tell your AI agent `install https://github.com/MattMaximo/foreverscribe`.
> **Agents:** follow [`SETUP-FOR-AGENTS.md`](SETUP-FOR-AGENTS.md).

## How it fits together

```
 game computer                                   agent computer (can be the same one)
 ┌──────────────────────────────┐                ┌───────────────────────────────────────┐
 │ WoW: Forever                 │                │ foreverscribe (CLI + MCP server)      │
 │  └ ForeverScribe addon       │   transport    │  └ SQLite store in your data dir       │
 │     writes SavedVariables on │ ─────────────▶ │                                       │
 │     /reload, logout, exit    │ local | folder │ your agent: Claude / Codex / Hermes … │
 │  └ sync agent (optional)     │ | http | relay │                                       │
 └──────────────────────────────┘                └───────────────────────────────────────┘
```

Four ways to run it (all first-class, pick in `config.toml`):

| Mode | When | What you install |
|---|---|---|
| `local` | WoW and your agent on the **same computer** | the addon; the companion reads `WTF/Account/*/SavedVariables` directly |
| `folder` | different computers, **no networking**: iCloud Drive, Dropbox, OneDrive, Google Drive, Syncthing | addon + game-side sync agent that copies into the synced folder |
| `http` | different computers on any route you control: LAN, Tailscale/WireGuard, or your own tunnel (e.g. Cloudflare Tunnel) | addon + sync agent that pushes each save, signed with a per-install **pairing key** |
| `relay` | different computers on **different networks**, nothing to open: both connect out to a small hosted relay ([`docs/RELAY.md`](docs/RELAY.md), ~$5/month on DigitalOcean) | addon + sync agent that uploads each save **end-to-end encrypted**; `foreverscribe relay sync` on the agent side |

Details and trade-offs: [`docs/TRANSPORTS.md`](docs/TRANSPORTS.md).

## Quick start

Agent side (any OS with Python 3.8+):

```sh
git clone <this repo> foreverscribe && cd foreverscribe
bin/foreverscribe setup            # writes ~/.config/foreverscribe/config.toml (Windows: %APPDATA%\foreverscribe)
bin/foreverscribe doctor           # shows what it reads and whether anything is missing
```

Game side: unzip the kit for your OS from `dist/` (build with `tools/build_dist.sh`), then

```sh
./install.sh --addon-only                    # macOS, same computer
./install.sh --pair fs1.…                    # macOS, push to the agent computer (code from `foreverscribe pair`)
./install.sh --pair fs2.…                    # macOS, through a hosted relay (code from `foreverscribe relay pair`)
./install.sh --folder ~/Dropbox/ForeverScribe   # macOS, synced folder
```
```powershell
powershell -ExecutionPolicy Bypass -File .\install.ps1 -AddonOnly        # Windows, same PC
powershell -ExecutionPolicy Bypass -File .\install.ps1 -Pair fs1.…       # Windows, push
powershell -ExecutionPolicy Bypass -File .\install.ps1 -Pair fs2.…       # Windows, through a relay
```

Restart WoW, enable **ForeverScribe** at character select, log in, `/reload`. Then:

```sh
bin/foreverscribe summary
```

Connect your agent with MCP: [`docs/AGENT-SETUP.md`](docs/AGENT-SETUP.md) has copy-paste config for Claude Desktop,
Claude Code, Codex, Hermes, and notes for ChatGPT / claude.ai.

## What your agent gets (information tiers)

- **HOT** — `summary`: who/level/gold/where, data freshness, gear one-liner, quest log, and *what is new since the
  last check* (auction sales, new mail, level-ups, rare drops). Under ~40 lines. Agents call it first.
- **WARM** — focused commands on demand: `equipment`, `inventory`, `professions --recipes`, `reputation`, `talents`,
  `quest <id|name>`, `mail`, `auctions`, `vendor [npc]`, `currencies`, `history <timeframe>`, `achievements`,
  `explored`, `collections`, `stats`, `lockouts`, `dungeons`, `compare <item>`, plus Wowhead-backed `gear`, `rate`,
  `craft`, `wowhead …`, `way <npc|place>` (where it is + a paste-in-chat waypoint), `npcs [--disagree]` (NPCs you
  met and where Wowhead is wrong), `route …` (multi-stop routes for `/fs go`), and optional AH prices `ah <item>`.
- **COLD** — `cold addons | keybinds | actionbars | macros`: only when the user asks.

## Safety (read-only by design)

The addon never sends chat, whispers, mail, or network traffic, never buys/sells/posts/bids, never sends AH queries
(it only reads what Blizzard's own AH window already loaded), never calls protected functions, never automates input,
and never calls `ReloadUI`. The **only** chat event it listens to is `CHAT_MSG_SYSTEM`, and only lines matching the
client's own auction-outcome format strings (`ERR_AUCTION_SOLD_S` and friends, in your client's language) are kept
as *kind + item name*; every other line is dropped unread. Player names from mail, auctions or invoices are never
stored, and macro bodies are never read; NPC sightings skip players, pets and anything secret. The only thing the
companion ever puts into the game folder are the data-only route file (`route write`), which you load with `/fs go`, and
the data-only AH price file (`prices write`) the tooltip reads. See [`docs/CAPTURE-MATRIX.md`](docs/CAPTURE-MATRIX.md) for every API used.

## Waypoints ("where is the Stormwind First Aid trainer?")

`foreverscribe way first aid trainer stormwind` (MCP `waypoint`) finds it (your own sightings, then shared ones, then
[forever-db](#data-sources), then Wowhead Forever) and prints one command
to paste in chat, matched to your addons: `/scribe way 52.8 44.8 Stormwind City Shaina Fuller` sets Forever's own map
pin and arrow (and hands it to Polestar's or TomTom's arrow if you use one). Without ForeverScribe 0.4 in game it
prints the TomTom, Polestar or plain-Forever `/run` equivalent. The only thing the addon does here is set the map pin
you asked for. Sources and the Stormwind/Mulgore map-redraw fix: [`docs/WAYPOINTS.md`](docs/WAYPOINTS.md).

## Polestar and forever-db (0.7)

- **Where things are, and how sure we are.** `way` now checks forever-db (Polestar's open database of spawn points)
  next to Wowhead Forever and your own sightings. When the best two sources are more than 25 yards apart the answer
  starts with **⚠ uncertain**: both spots, the distance, which one the command uses (your sighting > shared sightings
  > forever-db > Wowhead), and how to help: talk to the NPC once and `foreverscribe correction draft <npc>` writes a
  forever-db correction (its `corrections/npcs.json` format, with your in-game evidence) plus a Wowhead comment, as
  files under `<data_dir>/upstream/`. Nothing is ever sent; you review and submit them yourself.
- **Your Polestar guide.** With Polestar loaded, the addon reads (never changes) the guide it shows: guide, step N of
  M, the step's open goals with progress, and its arrow's target and next leg. The sync agent also ships Polestar's
  own SavedVariables (account `Polestar.lua` and each character's
  `WTF/Account/<acct>/<realm>/<character>/SavedVariables/Polestar.lua`). `foreverscribe guide` (MCP `guide`) and one
  line in `summary` give your agent "Polestar: Westfall step 11/70 — Sentinel Hill: Hand in …".
- **Routes on Polestar's arrow.** `/fs go` hands each stop to Polestar's arrow (`Polestar.Nav.API.Navigate`, which
  plans flights and boats) when Polestar is loaded, else Forever's own pin and arrow. Polestar's API takes one target,
  so stops go one at a time; if its guide takes the arrow back, ForeverScribe says so once and `/fs go` re-points it.

## Craft cost & profit in the profession window (0.8)

Open a profession and select a recipe: under the **Reagents:** list in the recipe pane, in the window's own fonts,
you see **Cost to craft** (materials at their typical AH price, or the vendor's price where a vendor sells them cheaper:
threads, dyes, spices, vials), **Sells for** (the crafted item's typical price × how many one craft makes) and
**Profit** after the 5% AH cut (green or red). A number that can't be calculated is left out, never guessed (a
bind-on-pickup result shows the cost only). If the window opens empty because the profession didn't load (you're dead
or a ghost, in combat, or the cast was interrupted), it says so in the middle of the window. `/scribe craftprices
on|off`. Your agent gets the same list ranked: `foreverscribe craft --profit [profession]` (MCP tool `craft_profit`).
Details: [`docs/PRICES.md`](docs/PRICES.md).

## AH prices in your tooltips (0.6)

With AH prices on (`[ah]`, off by default), hover any item: an **Auction House** section shows the typical price on
your market and what your stack is worth; hold **Shift** for cheapest listing, supply, 7/30-day trend, the other
faction, sell-here-or-vendor and the recipes of yours that use it. Patterns show what the crafted item sells for and
what the materials cost. The agent writes a small data-only price file (`foreverscribe prices write`, ~300 KB); the
sync agent brings a fresh one about every 30 minutes and the game reads it at login or `/reload`. Details:
[`docs/PRICES.md`](docs/PRICES.md).

## Real NPC locations and routes (0.5)

Wowhead Forever still has many NPCs at their Classic pins. When you talk to an NPC (or target a friendly one up
close) the addon notes its id and where you stood, so `way` answers "confirmed in game" and flags "Wowhead's pin is
~X yd off". `foreverscribe npcs --export-shared` makes a sanitized file (id, map, x, y, count, date) you can add to
[`data/npc-locations.json`](data/npc-locations.json) by pull request; everyone's lookups use it next.

Ask your agent for a route ("vendor, then the trainer, then the flight master") and press **`/fs go`** (bindable):
an arrow to each stop, the next one set as you arrive. The agent writes the route into small load-on-demand
"route slot" addons; one keypress loads it, ten per session (`/reload` frees them). Details, transports and limits:
[`docs/ROUTES-AND-NPCS.md`](docs/ROUTES-AND-NPCS.md).

## Optional extras

- **Save reminder**: WoW writes SavedVariables only on `/reload`, logout or exit. `/scribe remind 30` (or installer
  `--remind 30`) prints one chat line after 30 minutes without a save. Off by default.
- **Auction-house prices** (`ah`): off by default; see `[ah]` in [`config.example.toml`](config.example.toml) for why.
  With them on, `prices write` puts them into the game's item tooltips (next section).
- **Other addons' SavedVariables** (e.g. Forever Forge, Polestar): listed in `[sync] extra_saved_variables` (matched
  in the account folder and every character's folder), shipped alongside; Polestar's is parsed, others kept raw until
  a parser exists (`foreverscribe files`).
- **Live strip** (macOS, advanced): `ForeverScribe_Live` + `foreverscribe/live_capture.py` stream events between saves.

## Data sources

- **forever-db** by Polestar (https://github.com/fitzforge/polestar, `forever-db/`), release 2026.11.1: NPC and object
  spawn points. GPL-3.0 tables (with a CC BY 4.0 layer) — fetched at runtime and cached on your computer, never
  bundled in this repository. Credits and licences: [`NOTICE.md`](NOTICE.md).
- **Wowhead Forever** tooltips and map pins (cached 7 days); which crafting materials vendors sell.
- **Forever's client item table** (ItemSparse, via wago.tools): vendor list prices in
  [`data/vendor-prices.json`](data/vendor-prices.json).
- **Your own sightings** and the shared [`data/npc-locations.json`](data/npc-locations.json).

## Repository layout

```
addon/            ForeverScribe (+ ForeverScribe_Live, ForeverScribe_Prices, ForeverScribe_Route01-10 route slots) — the WoW addon
data/             npc-locations.json: shared NPC sightings (contributions by pull request)
foreverscribe/    Python package: store, queries, CLI, MCP server, receiver, auth, config, wowhead, waypoints, npcs, routes, ah, prices, live capture
bin/              foreverscribe (POSIX) and foreverscribe.cmd (Windows) launchers
installers/       macos/ (install.sh, uninstall.sh, sync agent)  windows/ (install.ps1, sync agent)
relay/            the optional hosted relay (FastAPI; Dockerfile at the root, .do/app.yaml for DigitalOcean)
skills/           agent instructions: generic + Hermes skill source
docs/             transports, relay, agent setup, game-PC guide, capture matrix, development
tests/            Lua addon tests (simulated client) + Python tests
tools/            build_dist.sh, pii_check.py, API checkers, get_lua.sh
```

Development and tests: [`docs/DEVELOPMENT.md`](docs/DEVELOPMENT.md). License: MIT ([`LICENSE`](LICENSE)); the
live-strip pixel codec is adapted from chelinho139/wow-ai (MIT, [`addon/ForeverScribe_Live/LICENSE-wow-ai.txt`](addon/ForeverScribe_Live/LICENSE-wow-ai.txt)).

Not affiliated with Blizzard Entertainment. World of Warcraft is a trademark of Blizzard Entertainment, Inc.

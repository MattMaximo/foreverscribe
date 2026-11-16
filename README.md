# ForeverScribe

Your World of Warcraft: Forever character, readable by your AI agent.

A small **read-only addon** records what your character is doing (level, gear, bags, quests, professions,
reputation, talents, mail, auctions, vendors you visit, and more) into the game's normal SavedVariables file.
A **companion** (Python 3.8+, standard library only) turns that file into answers for any agent:
a CLI (`foreverscribe summary`) and an **MCP server** (`foreverscribe mcp`) for Claude Desktop, Claude Code,
Codex, Hermes, or anything else that speaks MCP. No hosted service, no account, nothing leaves your machines
unless you set up a transport between your own computers.

> **Agents:** follow [`SETUP-FOR-AGENTS.md`](SETUP-FOR-AGENTS.md). It is a step-by-step setup script you can run for your user.

## How it fits together

```
 game computer                                   agent computer (can be the same one)
 ┌──────────────────────────────┐                ┌───────────────────────────────────────┐
 │ WoW: Forever                 │                │ foreverscribe (CLI + MCP server)      │
 │  └ ForeverScribe addon       │   transport    │  └ SQLite store in your data dir       │
 │     writes SavedVariables on │ ─────────────▶ │                                       │
 │     /reload, logout, exit    │ local | folder │ your agent: Claude / Codex / Hermes … │
 │  └ sync agent (optional)     │ | http         │                                       │
 └──────────────────────────────┘                └───────────────────────────────────────┘
```

Three ways to run it (all first-class, pick in `config.toml`):

| Mode | When | What you install |
|---|---|---|
| `local` | WoW and your agent on the **same computer** | the addon; the companion reads `WTF/Account/*/SavedVariables` directly |
| `folder` | different computers, **no networking**: iCloud Drive, Dropbox, OneDrive, Google Drive, Syncthing | addon + game-side sync agent that copies into the synced folder |
| `http` | different computers on any route you control: LAN, Tailscale/WireGuard, or your own tunnel (e.g. Cloudflare Tunnel) | addon + sync agent that pushes each save, signed with a per-install **pairing key** |

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
./install.sh --folder ~/Dropbox/ForeverScribe   # macOS, synced folder
```
```powershell
powershell -ExecutionPolicy Bypass -File .\install.ps1 -AddonOnly        # Windows, same PC
powershell -ExecutionPolicy Bypass -File .\install.ps1 -Pair fs1.…       # Windows, push
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
  `craft`, `wowhead …`, and optional AH prices `ah <item>`.
- **COLD** — `cold addons | keybinds | actionbars | macros`: only when the user asks.

## Safety (read-only by design)

The addon never sends chat, whispers, mail, or network traffic, never buys/sells/posts/bids, never sends AH queries
(it only reads what Blizzard's own AH window already loaded), never calls protected functions, never automates input,
and never calls `ReloadUI`. The **only** chat event it listens to is `CHAT_MSG_SYSTEM`, and only lines matching the
client's own auction-outcome format strings (`ERR_AUCTION_SOLD_S` and friends, in your client's language) are kept
as *kind + item name*; every other line is dropped unread. Player names from mail, auctions or invoices are never
stored, and macro bodies are never read. See [`docs/CAPTURE-MATRIX.md`](docs/CAPTURE-MATRIX.md) for every API used.

## Optional extras

- **Save reminder**: WoW writes SavedVariables only on `/reload`, logout or exit. `/scribe remind 30` (or installer
  `--remind 30`) prints one chat line after 30 minutes without a save. Off by default.
- **Auction-house prices** (`ah`): off by default; see `[ah]` in [`config.example.toml`](config.example.toml) for why.
- **Other addons' SavedVariables** (e.g. Forever Forge): listed in `[sync] extra_saved_variables`, shipped alongside
  and kept raw until a parser exists (`foreverscribe files`).
- **Live strip** (macOS, advanced): `ForeverScribe_Live` + `foreverscribe/live_capture.py` stream events between saves.

## Repository layout

```
addon/            ForeverScribe (+ ForeverScribe_Live) — the WoW addon
foreverscribe/    Python package: store, queries, CLI, MCP server, receiver, auth, config, wowhead, ah, live capture
bin/              foreverscribe (POSIX) and foreverscribe.cmd (Windows) launchers
installers/       macos/ (install.sh, uninstall.sh, sync agent)  windows/ (install.ps1, sync agent)
skills/           agent instructions: generic + Hermes skill source
docs/             transports, agent setup, game-PC guide, capture matrix, development
tests/            Lua addon tests (simulated client) + Python tests
tools/            build_dist.sh, pii_check.py, API checkers, get_lua.sh
```

Development and tests: [`docs/DEVELOPMENT.md`](docs/DEVELOPMENT.md). License: MIT ([`LICENSE`](LICENSE)); the
live-strip pixel codec is adapted from chelinho139/wow-ai (MIT, [`addon/ForeverScribe_Live/LICENSE-wow-ai.txt`](addon/ForeverScribe_Live/LICENSE-wow-ai.txt)).

Not affiliated with Blizzard Entertainment. World of Warcraft is a trademark of Blizzard Entertainment, Inc.

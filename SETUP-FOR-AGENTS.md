# Setup for agents — install and use ForeverScribe for your user

You are an AI agent (Claude, Codex, ChatGPT, Hermes, …) helping a WoW: Forever player. Follow these steps in
order. Ask the user only where marked **ASK**. Everything here is read-only towards the game, except the data-only
route file `route write` puts into the ForeverScribe route slots (loaded only when the player presses `/fs go`).

## 0. What you need

- Python 3.8+ on the agent computer (`python3 --version`; Windows: `py -3 --version`). Standard library only.
- Where WoW runs. **ASK**: "Does World of Warcraft: Forever run on this computer, or on a different one?"

## 1. Get the code (agent computer)

```sh
git clone <repo url> ~/foreverscribe        # Windows: git clone <repo url> %USERPROFILE%\foreverscribe
cd ~/foreverscribe
bin/foreverscribe version                    # Windows: bin\foreverscribe.cmd version
```

Below, `FS` means `~/foreverscribe/bin/foreverscribe` (Windows `%USERPROFILE%\foreverscribe\bin\foreverscribe.cmd`).

## 2. Configure (agent computer)

Pick ONE mode:

**A. Same computer (`local`)**
```sh
FS setup --mode local                       # finds the _forever_ folder; else add --wow-dir "<...>/World of Warcraft/_forever_"
```
Then install the addon on this same computer: `installers/macos/install.sh --addon-only`
(Windows: `powershell -ExecutionPolicy Bypass -File installers\windows\install.ps1 -AddonOnly`).

**B. Different computers, synced folder (`folder`)** — no networking. **ASK** which synced folder service they use
(iCloud Drive, Dropbox, OneDrive, Google Drive, Syncthing) and the folder path on *both* computers.
```sh
FS setup --mode folder --folder "<synced folder as seen on this computer>"
```

**C. Different computers, push over HTTP (`http`)** — fastest. Needs an address the game computer can reach:
a LAN IP, a Tailscale/WireGuard IP, or the user's own tunnel URL (see `docs/TRANSPORTS.md`). **ASK** which.
```sh
FS setup --mode http --bind <this computer's LAN/Tailscale IP, or 127.0.0.1 behind a tunnel> [--public-url https://…]
FS receiver                       # keep it running (macOS autostart: FS receiver launchagent --write, then load it)
FS pair --name "<game PC name>"   # prints a one-line pairing code: a secret, give it only to the user
```

Optional: `--character "<Name>"` (default character), `--market forever.<normal|pvp|hardcore>.<alliance|horde>.<us|eu>`.
AH prices stay off unless the user opts in (`config.example.toml` → `[ah]` explains why). If they do, run
`FS prices write` once: item tooltips in game then show AH prices after the next login or `/reload` (http: the
receiver keeps them fresh while the game computer's sync agent runs; local: run `FS prices watch` or schedule
`FS prices write` every 30 min). Details: `docs/PRICES.md`.

## 3. Install on the game computer (modes B and C)

Build or download the kit (`tools/build_dist.sh` → `dist/ForeverScribe-<ver>-macos.zip` / `-windows.zip`) and give
the user the matching zip plus this one line:

| Game computer | Mode B (folder) | Mode C (http) |
|---|---|---|
| macOS | `./install.sh --folder "<synced folder there>"` | `./install.sh --pair <code>` |
| Windows | `.\install.ps1 -Folder "<synced folder there>"` | `.\install.ps1 -Pair <code>` |

Windows: run from PowerShell with `powershell -ExecutionPolicy Bypass -File .\install.ps1 …`. Add `-DryRun`/`--dry-run`
to preview. Uninstall: `./uninstall.sh` or `.\install.ps1 -Uninstall`. Optional: `--remind 30` / `-Remind 30`.

## 4. First data

Tell the user: "Fully quit and restart WoW, make sure ForeverScribe is enabled at character select, log in, type
`/reload`." Then:

```sh
FS doctor      # every check OK?
FS summary     # should show their character
```

No character yet? `FS doctor` lists the folders it reads. Mode C: check `FS receiver health` and the game-side log
(`~/Library/Application Support/ForeverScribe/sync.log` or `%LOCALAPPDATA%\ForeverScribe\sync.log`).

## 5. Connect yourself (MCP)

Add the stdio MCP server to your own configuration. Exact snippets for Claude Desktop, Claude Code, Codex and
Hermes: `docs/AGENT-SETUP.md`. The command is always:

```
<python3> -m foreverscribe mcp      with PYTHONPATH=<repo>     (or: <repo>/bin/foreverscribe mcp)
```

Verify by calling the `summary` tool. No MCP support? Use the CLI directly; every MCP tool is a CLI command.

## 6. Using it (every answer)

1. Call `summary` first, even for casual questions. It ingests new data, tells you how fresh it is, and lists
   what happened since your last check. If data is STALE, say so and suggest a `/reload`.
2. Use one focused (WARM) tool for the question: `quest`, `equipment`, `inventory`, `professions --recipes`,
   `reputation`, `talents`, `mail`, `auctions`, `vendor`, `currencies`, `history`, `achievements`, `compare`, and
   for "is this an upgrade / what to buy / what to craft": `gear`, `rate`, `craft`, `wowhead vendor <npcID>`.
3. `cold` (addons, keybinds, action bars, macro names) only when the user asks about their UI setup.
4. Never guess game state a tool can answer. Never recommend a quest without checking `quest <id>` first.
5. A `wowhead` tool that prints `NEED web_extract(...)` wants one page: fetch that URL as markdown with your web
   tool and pass it to `import_page` (CLI: `FS wowhead import-page <url> -` with the markdown on stdin), then retry.
6. "Where is <NPC / object / place>?": call `waypoint` (CLI: `FS way <name> [zone words]`, `FS way npc=<id>`,
   `FS way <x> <y> <zone>`). Answer with the zone and coordinates, the source and its freshness in one line, and the
   **paste command in a code block** — exactly as the tool printed it (it already matches their addons:
   `/scribe way …`, TomTom `/way …`, Polestar or Forever's native `/run …`). List other spawn spots or other matches
   briefly. If it says not found or "no position", say so: never invent or estimate coordinates, and never take
   coordinates from Classic/Retail sites yourself (Forever redrew Stormwind, Mulgore, Redridge and Eastern
   Plaguelands; the tool converts Wowhead's old points). Details: `docs/WAYPOINTS.md`.
   When the tool says "confirmed in game" (the player met that NPC; addon 0.5+) trust it over Wowhead and say so;
   when it says "Wowhead's pin is ~X yd off", tell the user Wowhead is wrong there.
7. "Which NPCs did I meet / where is Wowhead wrong?": `npcs` (`FS npcs`, `FS npcs --disagree`). The user wants to
   share corrections: `FS npcs --export-shared` (no personal data) and help them open a pull request that merges it
   into `data/npc-locations.json` (`FS npcs --merge data/npc-locations.json --from <file>`). Never upload anything
   to Wowhead or elsewhere yourself.
8. "Take me to A, then B, then C" (errands, trainers, a quest hub run): build a route, then write it once.
   MCP `route`: `action=add` with `query` per stop (same lookup as `waypoint`; it refuses unknown positions), or
   `action=add_stops` with stops you already resolved; `action=show` to check the order; `action=write`. CLI: `FS route
   add <query>`, `FS route show`, `FS route write`. Then tell the user, in one line: "Press /fs go (or its key) in game;
   the arrow moves to the next stop as you arrive, /fs next skips." Start a fresh route with `action=clear`. If they
   say nothing happened: `FS route status` (http: shows whether the game computer fetched it; folder: wait for the
   sync), and remind them `/fs go` loads at most 10 times per session (`/reload` resets; progress is kept). Never
   press keys or `/reload` for them. Details and limits: `docs/ROUTES-AND-NPCS.md`.

## 9. Rules you must keep

- Read-only. Don't edit the addon to add automation, chat, network or protected calls; don't call `ReloadUI`.
- The only writes towards the game are `route write` and `prices write`. Never hand-edit the route slot or price
  files: the sync agent rejects anything that isn't exactly what the companion writes.
- The pairing code and `receiver-keys.json` are secrets. Don't post them anywhere.
- Don't commit the user's `config.toml`, data dir, SavedVariables or logs to any repository.

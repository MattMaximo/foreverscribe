# NPC locations from the game, and multi-stop routes (0.5)

## Why

Wowhead Forever (and any chatbot trained on it) still places many NPCs at their Classic-era pins. On the four
redrawn maps (Mulgore, Eastern Plaguelands, Redridge Mountains, Stormwind City) that can be hundreds of yards off,
and some Forever-only NPCs have no position at all. Your character knows better: when you talk to an NPC you are
standing next to it.

## NPC sightings (addon, read-only)

`addon/ForeverScribe/Npcs.lua` records an NPC when you open one of its windows:

| Event | kind |
|---|---|
| `GOSSIP_SHOW` | gossip |
| `MERCHANT_SHOW` | vendor |
| `TRAINER_SHOW` | trainer |
| `QUEST_DETAIL`, `QUEST_GREETING`, `QUEST_PROGRESS`, `QUEST_COMPLETE` | quest |
| `TAXIMAP_OPENED` | flightmaster |
| `BANKFRAME_OPENED` | banker |
| `AUCTION_HOUSE_SHOW` | auctioneer |
| `PLAYER_INTERACTION_MANAGER_FRAME_SHOW` (gossip, quest, merchant, taxi, trainer, banker, binder, auctioneer, stable, battlemaster; not mail) | as named |
| `PLAYER_TARGET_CHANGED`: a friendly NPC targeted out of combat within ~10 yards (`CheckInteractDistance(unit, 3)`); `/scribe npcs target off` turns this off | target |

Each sighting is `{npcID, name, subtitle, uiMapID, x, y, zone, subzone, t, kind}`:

- **npcID** from `UnitGUID("npc")` (`Creature-0-<server>-<instance>-<zone>-<npcID>-<spawn>`). Only `Creature` GUIDs:
  players, pets, vehicles and game objects are skipped, and so is any unit that `UnitIsPlayer` or
  `UnitPlayerControlled` (minions carry player names in their titles). A **secret** GUID, name, range answer or
  position is skipped, never stored or compared (`issecretvalue`, `UnitGUID` is `SecretWhenUnitIdentityRestricted`).
- **position** is the player's own, `C_Map.GetPlayerMapPosition(C_Map.GetBestMapForUnit("player"), "player")`, in
  Forever's map frame. Interaction range is a few yards, so the radius is 5 yd for windows and 10 yd for targeting.
- **subtitle** is the second line of `C_TooltipInfo.GetUnit` when it is not a "Level …" line.

Storage: `ForeverScribeDB.chars[<realm:name>].npcs["<npcID>:<mapID>"]`. Sightings within 5 yards are one spot
(running mean); one conversation that fires several windows within 30 s counts once; up to 4 spots per NPC and map
(several spawns, wanderers); at most 1000 NPC+map entries per character (oldest dropped). `/scribe npcs` shows the
count. Nothing about other players is ever read.

## Companion: who wins

`foreverscribe way`, the MCP `waypoint` tool and `foreverscribe wowhead npc <id>` look in this order:

1. **Your own sightings** (`npc_sightings` table, filled on ingest): "confirmed in game by this character, 2026-11-16 (2 visits)".
   A name or `<subtitle>` you have met (`way quartermaster vell`) resolves without Wowhead.
2. **`data/npc-locations.json`** in the repo, sightings other users shared (empty to start).
3. **forever-db** (0.7, `foreverscribe/foreverdb.py`): Polestar's open database. Spawn points are world yards on the
   continent; ForeverScribe converts them with the client's map frames (`gamedata/maps.json`, identical to forever-db's
   `ui_map` table) into Forever map percent, applies forever-db's own `corrections/npcs.json` (`addSpawns`, `f: e`
   points converted from the Classic frame), and clusters points within 2.5 %. Downloaded once from release
   `data-v2026.11.1` (sha256-checked), cached in `<data_dir>/forever-db/`; `foreverscribe foreverdb status|fetch`.
   Offline: skipped, never an error. Name search falls back to it when Wowhead finds nothing.
4. **Wowhead Forever**, as in 0.4 (with the Classic→Forever frame fix on the redrawn maps).

**Agreement** (`foreverscribe/resolve.py`): the spot the answer uses (nearest to you) is compared with the next
source's nearest spot on the same continent. More than 25 yards (`FOREVERSCRIBE_DISAGREE_YARDS`) or another
continent:

- no sighting: `⚠ uncertain: forever-db and Wowhead Forever disagree (132 yd apart). Wowhead Forever puts it at
  Tirisfal Glades 61.4, 53.4. This command uses forever-db's spot …` plus `help fix: talk to <NPC> once …`
- your sighting: `Wowhead's pin is ~X yd off` / `forever-db is X yd off from where you met it`, and the correction
  command. The command always uses the most trusted source.

`foreverscribe npcs` lists what you have met; `foreverscribe npcs --disagree [--yards N]` lists only the NPCs where
forever-db or Wowhead is off, and writes a correction draft for each (below).

## Correction drafts (0.7, never sent)

`foreverscribe correction draft <npc id|name>` (MCP `correction_draft`) compares your newest sighting with forever-db
and Wowhead and writes, under `<data_dir>/upstream/`:

- `forever-db/npc-<id>.json` and the merged `forever-db/npcs.json`: entries in forever-db's `corrections/npcs.json`
  format: `{"<npcID>": {"addSpawns": {"<uiMapID>": {"f": "l", "pts": [[x, y]]}}, "source": {"kind": "in-game-check",
  "ref": "player in-game check <date>, client <build>"}, "note": "…"}}`. `addSpawns` replaces that map's points, so a
  multi-spawn NPC keeps its other points more than 60 yd from yours. The note says what forever-db had and how it was
  checked, in our words, and never cites a website (forever-db's rule).
- `wowhead/npc-<id>.txt`: a short comment for its Wowhead Forever page.
- `README.md`: how a person submits them (a Polestar pull request to `next`; Wowhead by hand).

ForeverScribe never opens a pull request, issue or comment, and never uploads anything.

## Sharing corrections

`foreverscribe npcs --export-shared [file]` writes only `npcID, name, mapID, x, y, count, lastSeen (YYYY-MM-DD)` per
spot. No character, realm, account, subzone, interaction kind or time of day. To contribute: merge it into the repo
copy with `foreverscribe npcs --merge data/npc-locations.json --from <file>` (spots within 5 yd add up) and open a
pull request. Nothing is uploaded anywhere by ForeverScribe; there is no Wowhead uploader. (The official Wowhead
Client is the way to help Wowhead itself.)

## Routes: `/fs go`

The agent builds a list of stops and writes it; you press one key in game.

```
foreverscribe route add first aid trainer stormwind      # same lookup as `way`: your sightings first
foreverscribe route add --title Bank --radius 25 60 50 Stormwind City
foreverscribe route add-json '[{"title":"Flight master","mapID":1453,"x":70.9,"y":72.5}]'
foreverscribe route show | move 3 1 | remove 2 | name Errands | clear
foreverscribe route write                                 # sends it to the game computer
foreverscribe route status                                # written / fetched by the game computer / started in game
```

MCP tool `route` (actions add, add_stops, show, remove, clear, write, status).

In game:

```
/fs go          load the route the agent wrote (or carry on with the current one)  — bindable: Keybindings > AddOns > ForeverScribe
/fs next        skip to the next stop (also bindable)     /fs back   previous stop
/fs route       list stops (x done, > current)            /fs route clear    stop the route
/fs route slots how many of this session's 10 loads are used
```

The current stop gets the same waypoint as `/scribe way` (Forever's pin + arrow, or Polestar's/TomTom's arrow
when loaded). A 1-second ticker, running only while a route is active, measures the distance from the player to the
stop (`C_Map.GetPlayerMapPosition(stop map)` and `C_Map.GetMapWorldSize`); inside the stop's radius (default 15 yd)
the next stop is set, and after the last one the pin is cleared. The route and the current stop live in
SavedVariables, so progress survives `/reload` and logout, and the stop is put back on the map after login.

### How a route gets into a running game

WoW reads addon files only when an addon loads, and only discovers addon folders at launch
(research: chelinho139/wow-ai `docs/ARCHITECTURE.md`, measured on a live Forever client by 0xInuarashi/wow-forever-codex:
files must exist at launch; a not-yet-loaded file is read fresh on first use; each load-on-demand addon loads once
per UI session; `/reload` unloads them all). So 0.5 installs ten tiny **route slot** addons,
`ForeverScribe_Route01` … `ForeverScribe_Route10` (`## LoadOnDemand: 1`, one `Route.lua`, shipped empty). The
companion rewrites `Route.lua` in all of them; `/fs go` calls `C_AddOns.LoadAddOn` on the next slot not yet loaded
this session, which reads the new file. The file is data only (`ForeverScribe_RouteData = {v=1, rev, name, created, stops={...}}`);
the addon validates it (format version, rev charset, map ids, 0–100 coordinates, ≤50 stops, titles stripped of
`|`, quotes and control characters).

| Your setup | What `route write` does | How it reaches the slots |
|---|---|---|
| `local` (agent and WoW on one computer) | rewrites `Interface/AddOns/ForeverScribe_RouteNN/Route.lua` directly | immediate |
| `folder` (synced folder) | writes `<folder>/_route/Route.lua` | the game-side sync agent (launchd watches `_route`, plus every 30 s) copies it into the slots once the folder has synced |
| `http` (receiver) | keeps `<data_dir>/route/Route.lua` | the game-side sync agent asks `POST /v1/route` every 30 s, **signed with its pairing key** (unsigned/legacy is refused), and copies it in; `route status` shows when it was fetched |

Before copying, the sync agent checks every line of the file against the exact shapes the companion writes (no
code can pass: strings may not contain quotes or backslashes), so a damaged or hostile file never reaches the game.
That is the only thing the sync agent writes inside the WoW folder.

### Limits (honest)

- **One keypress per route.** The addon cannot notice a new file on its own; `/fs go` (or its key) is required.
  Pressing it before the file arrived says "same route as before" or "the route file is empty"; wait a few seconds and press again.
- **10 loads per UI session.** Every `/fs go` uses one slot, even a press that found nothing new. After ten, `/fs go`
  says so and keeps the current route; `/reload` frees all ten (and saves your place).
- **First install needs a full game restart** (new addon folders are only discovered at launch) and the ten slots must
  stay enabled in the AddOns list (they are grouped under ForeverScribe).
- Distance-based arrival needs a position: inside instances (no map position) use `/fs next`.
- Delivery latency: local = instant; http ≈ up to 30 s; folder = your sync service's delay + up to 30 s.

## Verified vs. needs an in-game check

Verified offline: API names and events against Forever's generated docs (`tools/check_api.py`, all `doc`), Lua
tests in the simulated client (sightings, dedup, secret GUIDs/positions, players/pets skipped, caps, slot loading
in-session, slot exhaustion and `/reload`, arrival advancing, bad files), Python tests (ingest, `way` preference and
disagreement, shared export without personal data, local/folder/http delivery through the real sync script and
receiver, the validator rejecting code).

Needs a live check on the game computer: `LoadAddOn` of a rewritten slot picking up the new file mid-session (the
documented behaviour wow-ai depends on), the key bindings showing under AddOns, the tooltip subtitle line, and
arrival distances feeling right.

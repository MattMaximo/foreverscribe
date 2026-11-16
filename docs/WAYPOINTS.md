# Waypoints: "where is X?" → one paste command

`foreverscribe way <npc | object | x y zone>` (MCP tool `waypoint`) answers where something is and gives **one
chat command** to paste in game that puts a pin on the map and an arrow on screen. The command style follows the
character's loaded addons (cold tier `cold addons`, plus the snapshot's ForeverScribe version).

| Character has | Paste command | What it does |
|---|---|---|
| ForeverScribe 0.4+ | `/scribe way 52.8 44.8 Stormwind City Shaina Fuller` (also `/fs way`) | Forever's map pin + tracking arrow; hands the spot to Polestar's or TomTom's arrow when one is loaded (`/scribe way addon native` to keep the game's arrow) |
| TomTom (no ForeverScribe 0.4) | `/way #1453 52.8 44.8 Shaina Fuller` | TomTom waypoint + Crazy Arrow |
| Polestar (no ForeverScribe 0.4, no TomTom) | `/run Polestar.Nav.API.Navigate("ForeverScribe",1453,0.528,0.448,"Shaina Fuller")` | Polestar's arrow and route planner |
| nothing known | `/run C_Map.SetUserWaypoint(UiMapPoint.CreateFromCoordinates(1453,0.528,0.448)) C_SuperTrack.SetSuperTrackedUserWaypoint(true)` | Forever's own map pin + tracking arrow |
| Questie (extra line) | `/questie tomap npc 2327` | Questie's own map markers for that NPC (no arrow) |
| any (alternative) | `/mappin 1453 52.8 44.8` | Blizzard's built-in map pin command, opens the map at the pin; no arrow |

The first `/run` in a session can show the game's "allow scripts?" prompt; that is the client's, not ours.

## In game: `/scribe way`

```
/scribe way <x> <y> [zone name | mapID] [title]     /scribe way Elwynn Forest 42.1 65.3 Marshal Dughan
/scribe way #1453 52.8 44.8                         /scribe way 45,5 61,5 barrens        (decimal commas, partial names)
/scribe way clear        /scribe way              (help + which arrow addons are loaded)
/scribe way addon auto | native                   (auto: Polestar/TomTom arrow when loaded; native: the game's)
```

x and y must be 0–100. Zone names are resolved against the client's own map tree (`C_Map.GetMapChildrenInfo`
from Azeroth and from the player's root map, all descendants; a zone wins over a same-named micro map). No zone:
the player's current map. Waypoint.lua makes no protected call, no movement, no click; it only runs when typed.

## Evidence (verified from source)

### Forever's native API — Gethe/wow-ui-source branch `forever`, build 1.60.1.70938 (commit bebcb6bf)

| Fact | File:line |
|---|---|
| `C_Map.SetUserWaypoint(point: UiMapPoint) -> wasSet` | `Blizzard_APIDocumentationGenerated/MapDocumentation.lua:599` |
| `C_Map.CanSetUserWaypointOnMap(uiMapID) -> canSet` | `MapDocumentation.lua:11` |
| `C_Map.ClearUserWaypoint()` | `MapDocumentation.lua:26` |
| `C_Map.GetMapChildrenInfo(uiMapID, mapType?, allDescendants?)` | `MapDocumentation.lua:198` |
| `C_SuperTrack.SetSuperTrackedUserWaypoint(superTracked: bool)` | `SuperTrackManagerDocumentation.lua:169` |
| `UiMapPoint.CreateFromCoordinates(mapID, x, y, z)` (x, y are 0–1) | `Blizzard_ObjectAPI/Mainline/UiMapPoint.lua:3`; loaded by `Blizzard_ObjectAPI.toc:14` |
| Blizzard's own "set pin + track it" sequence | `Blizzard_PlunderstormPrematchUI/Blizzard_PlunderstormPrematchUI.lua:152-154` |
| Pin + arrow data providers are loaded on Forever's world map | `Blizzard_WorldMap/Blizzard_WorldMap.lua:222,224`; `Blizzard_SharedMapDataProviders_Mainline.toc:48-52` |
| Forever (game type `camelot`) loads the mainline map files: the same TOCs carry `[ExcludeLoadGameType camelot]` / `[AllowLoadGameType camelot]` overrides | `Blizzard_WorldMap_Mainline.toc:5-21`, `Blizzard_SharedMapDataProviders_Mainline.toc:29` |
| Game rule that can turn pins off (checked before setting) | `Blizzard_SharedMapDataProviders/WaypointLocationDataProvider.lua:113` |
| **No `/way` in Forever.** The only built-in waypoint command is `/mappin <mapID> <x> <y>` (`SLASH_COMMAND.MAPPIN`, category MAP) | `Blizzard_ChatFrameBase/Shared/SlashCommands.lua:172`; handler `WaypointLocationDataProvider.lua:213-230`; text `SLASH_MAPPIN1 = "/mappin"` in GlobalStrings (wago.tools build 1.60.1.70938, id 59938). No GlobalString maps to `/way`. `/mappin` sets the pin and opens the map; it does not super-track. |
| `/run` (`SLASH_COMMAND.SCRIPT`) is registered for game mode Standard (all categories) | `SlashCommands.lua:235-237, 1224-1236` |

`tools/check_api.py` lists every call in `Waypoint.lua` as `doc` (in the generated API docs).

### Polestar — github.com/fitzforge/polestar, branch `next`, commit 1778266 (2026-11-16), addon 0.4.0, Interface 16001

- Slash: `/polestar`, `/pole`, `/ps` (`addon/Polestar/Core/Init.lua:1385-1388`). `/polestar way <x> <y> [label]` points
  the arrow on the **current** map only (`Nav/Nav.lua:865-883`), so it cannot target another zone.
- `/way [zone] x y [title]` exists only when the "Let other addons set waypoints" setting (`nav.answerTomTom`) is on
  — **off by default** — and no other addon owns `/way` (`Nav/Journey.lua:70, 858-896`). Not used by default.
- Public, versioned arrow API: `Polestar.Nav.API.version == 1`; `Navigate(owner, map, x, y, title) -> bool` with
  x, y as 0–1 fractions; `Cancel(owner)` (`Nav/Journey.lua:352-397`; `docs/ARCHITECTURE.md` "Nav API"). Global
  `Polestar` is the addon namespace (`Core/Init.lua:11`), `Polestar.Nav` at `Nav/Nav.lua:25`. This is what both
  `/scribe way` (auto mode) and the Polestar paste command call. Polestar itself sets the native pin the same way
  (`Nav/Bridges.lua:281-289`), and its own QA notes use `/run` in Forever (`docs/NAV_QA.md:144`).
- Polestar can put a TomTom-shaped stand-in in the `TomTom` global when TomTom is absent; ForeverScribe only treats
  TomTom as present when the TomTom addon itself is loaded.

### TomTom — CurseForge `tomtom` v4.4.1-release (file 9493883), Interface lists 16001 (Forever)

- `/way`, `/tway`, `/tomtomway` (`modules/slash.lua:139-141`); `/way <zone> <x> <y> [desc]` and `#<mapID>` as the zone
  for a literal map id (`modules/slash.lua` ResolveZone at line 158, zone branch 279-330, `AddWaypoint(mapId, x/100, y/100, …)` at 326).
- `TomTom:AddWaypoint(m, x, y, opts)` with x, y 0–1 (`core/waypoints.lua:415`), `TomTom:RemoveWaypoint(uid)`.

### Questie — github.com/Questie/Questie `master`, commit d0fe921, v12.9.0, has `Questie_Forever.toc` (Interface 16001)

- Slash: `/questie`, `/q`, `/questieclassic` (`Modules/QuestieSlash.lua:37-39`).
- `/questie tomap npc|object <id|name>` adds Questie's map markers (`Modules/QuestieSlash.lua:133-224`).
- **No public waypoint or arrow API** (its arrow shortcut drives TomTom). So with Questie only, the paste command is
  the native one and `/questie tomap` is offered as an extra line.

## Where coordinates come from (and the Stormwind trap)

Wowhead Forever tooltips (`nether.wowhead.com/forever/tooltip/npc/<id>`: zone AreaID + 0–100 points per floor) and
the name search (`www.wowhead.com/forever/search/suggestions-template?q=`). Nothing is guessed: no Wowhead
position → no command, and the answer says so.

Forever **redrew four maps** versus Classic: Mulgore, Eastern Plaguelands, Redridge Mountains, Stormwind City
(client UiMapAssignment bounds differ; `tools/build_maps.py` → `foreverscribe/gamedata/maps.json`). Wowhead Forever still
lists the old Classic-frame points there beside new Forever-recorded ones — e.g. Shaina Fuller (npc 2327) has
`42.4,26.8` (Classic frame) and `52.8,44.8` (Forever). `way` fetches the same NPC from Wowhead Classic, converts every
point found in both through world coordinates with the client's own bounds, and merges. Checked on 16 NPCs in the
four maps: converted points land within 0.3 of the Forever-recorded ones. If the Classic lookup fails on one of those
maps, the answer is labelled UNVERIFIED.

Multiple spawns: points within 2.5 map-% are one spot; spots are ordered nearest to the character's last known
position (same continent), else by how many points Wowhead recorded.

## Not done yet

- Multi-stop routes (`/fs go`) — planned; would feed Polestar's API or chain native pins.
- Live in-game check of `/scribe way` on the MacBook (code is tested in the Lua client stub against the documented API
  shapes only).

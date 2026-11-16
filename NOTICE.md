# NOTICE

ForeverScribe is MIT-licensed (LICENSE). It uses, but does not contain, the data below.

## forever-db (Polestar)

NPC and object spawn points come from **forever-db**, the open World of Warcraft: Forever database built by Polestar's
`forge` (https://github.com/fitzforge/polestar/tree/next/forever-db), release 2026.11.1 (tag `data-v2026.11.1`), and
its `corrections/npcs.json` / `objects.json` at commit f93a8ee.

- The tables used (`npc`, `object`, `spawn`, `ui_map`) are licensed **GPL-3.0-only**; forever-db's own layer
  (steps, mechanics, notes, schemas, the corrections' notes and sources, its documentation) is **CC BY 4.0**. Credits
  for its sources (EG Link / Efficient Games, CMaNGOS, VMaNGOS, Factoruide, ForeverTDB, QuestieDB, pfQuest, the
  game client) are in forever-db's NOTICE.md.
- ForeverScribe never commits or redistributes those files. `foreverscribe/foreverdb.py` downloads them at runtime
  from that pinned release, checks each file's sha256 against the release's `datapackage.json`, and keeps a local
  index under your own data folder (`<data_dir>/forever-db/2026.11.1/`).
- Names and titles in the data are the game's own words, which stay Blizzard's.

## Wowhead Forever

Tooltips and map pins are read from Wowhead's public tooltip service for WoW: Forever (cached 7 days). Wowhead is a
trademark of its owner; ForeverScribe is not affiliated with it.

## World of Warcraft

World of Warcraft and Blizzard Entertainment are trademarks or registered trademarks of Blizzard Entertainment, Inc.
ForeverScribe is not made, endorsed or supported by Blizzard Entertainment. No game assets are included.

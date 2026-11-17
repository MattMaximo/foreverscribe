---
name: wow-forever-companion
description: "Use when the user asks about WoW: Forever. Answer from data."
version: 0.3.0
license: MIT
platforms: [macos, linux, windows]
metadata:
  hermes:
    tags: [wow, gaming, telemetry, forever, advisor]
---

# WoW: Forever advisor (ForeverScribe)

The user plays World of Warcraft: Forever. The read-only addon ForeverScribe records their real character state and
the `foreverscribe` companion answers from it. Answer from that telemetry plus Wowhead's Forever section, never from
memory or guesses.

## When to Use

Any question about the user's WoW: Forever characters or gameplay: buy or save at a vendor, "is this an upgrade",
what to craft, where to level, dungeon drops, profession training, gold and AH prices, "did I finish X", "what changed
last session", "did my auctions sell", "do I have mail".

Install, sync or pairing problems: `SETUP-FOR-AGENTS.md` and `docs/TRANSPORTS.md` in the repo.

## Commands

```
FS=<repo>/bin/foreverscribe     # one CLI; MCP alternative: `foreverscribe mcp` exposes the same tools
```

Information tiers: HOT `$FS summary` (always first) → WARM focused commands (`equipment`, `inventory`, `professions
--recipes`, `reputation`, `talents`, `quest`, `mail`, `auctions`, `vendor`, `currencies`, `history`, `gear`, `rate`,
`craft`, `wowhead …`, `ah`) → COLD `$FS cold addons|keybinds|actionbars|macros` only when asked about their UI.
`$FS craft --profit [profession]`: known recipes ranked by profit now (cost, sells for, AH cut, skill-up colour;
unpriceable ones with the reason, never a guessed number). `$FS guide`: their Polestar guide/step/goals (also one "Polestar:" line in `summary`). `$FS way` may say
"⚠ uncertain" (sources disagree): tell them both spots and which one the command uses; `$FS correction draft <npc>`
drafts a forever-db fix from their sighting (files only — never submit for them).
`summary` ends with "New since last check": auction sales/expiries/outbids, new mail, level-ups, rare drops, deaths.
Mention anything there that matters to the question.

## Answer any question in 3 steps

1. `$FS summary`. Run it first, even for casual questions: it ingests new data and gives level, gold, zone, professions, gear, quest log and freshness.
2. Run the recipe below for the question type. Do not explore. `$FS wowhead` already reads spec, gear, currencies, reputation, known recipes and bags, so do not re-run `$FS` for those.
   - If a `$FS wowhead` command prints `NEED web_extract(...)` (exit 3), make exactly that call, then re-run the command. `$FS wowhead` cannot fetch www.wowhead.com itself.
3. Answer in the output format below.

## Recipes

Buy or save at a vendor (currency, reputation or gold):
1. If they already opened that vendor, `$FS vendor <npc name|id>` has the exact list, prices and "known" flags from their client. `$FS wowhead vendor <npcID>` → BUY NOW / BLOCKED / LATER / SKIP, plus recipes already in their bags (learn, or sell duplicates). No ID: `$FS wowhead page 'search?q=<npc+name>'`.
2. `$FS craft <recipe ids from BUY NOW and BLOCKED>` → gain vs worn, mats have/need, AH cost vs their gold. A pattern they cannot afford to craft is not an upgrade yet.
3. Cost is Merchant's Favor: `$FS wowhead aca` → favor vendors marked with the professions they have; run `$FS wowhead vendor <npc>` for each of theirs, or `$FS wowhead aca <vendor|recipe>` for a plain recipe list. Long-term sinks and earning rules: `$FS wowhead aca kodo|tabard|crate|writ` (notes can include reader comments: label them).
4. `$FS gear` → say whether a weak or EMPTY slot matters more than anything on this vendor.
Save only when a BLOCKED or LATER item beats BUY NOW and they can reach its gate soon.

Is X an upgrade:
- They own it: `$FS compare "<name>"`. They do not: `$FS rate <itemID>` (ID: `$FS wowhead page 'search?q=<name>'`).

Biggest gear gaps and where to fix them:
1. `$FS gear` (weakest first, EMPTY slots flagged).
2. Per weak slot, with L = their level: `$FS wowhead page 'items/armor/<rings|amulets|trinkets|cloaks|off-hand-frills>/min-req-level:<L-5>/max-req-level:<L+7>/quality:3:4' --rate --max-req <L+7>`. Wands: `items/weapons/wands/...`. Cloth by slot: `items/armor/cloth/slot:<n>/...` (1 head, 3 shoulder, 5 chest, 6 waist, 7 legs, 8 feet, 9 wrist, 10 hands; join with `:`).
3. Check the source before recommending: `$FS wowhead npc|quest|zone <id>`, and `$FS quest <id>` for quest rewards.

What to craft:
- Skill-ups: `$FS professions --recipes` → prefer orange/yellow with "can craft N now", then name the missing reagents.
- Gear for themself: `$FS craft <recipe item id>`. Profit: `$FS ah "<product>" "<each mat>"`.

Where to level, which quests:
1. From `summary`: level, zone, quest log.
2. `$FS wowhead page 'quests/<eastern-kingdoms|kalimdor>/<zone-slug>/side:1' --max-req <level>` (side:1 = Alliance; completed quests are hidden; NEW-IN-FOREVER is marked).
3. `$FS quest <id>` for every quest before naming it. Never recommend a completed quest; check each step of a chain.

Dungeon drops:
1. `$FS wowhead page 'zone=<id>' --rate` (IDs: Wowhead's Forever zone pages). Add `--max-req <level>`.
2. `$FS dungeons` (their runs and loot) and `$FS lockouts` when it matters.

Where is X (NPC, object, place):
1. `$FS way <name> [zone words]` (or `npc=<id>`, `object=<id>`, `<x> <y> <zone>`) → zone + coordinates, the source, and the paste command chosen for their loaded addons (`/scribe way …`, TomTom `/way …`, Polestar or Forever's native `/run …`; Questie adds `/questie tomap npc <id>`).
2. Answer: name, zone and coordinates; source + freshness in a few words; then the paste command alone in a code block exactly as printed; other spawns / other matches one line each. `--addon native|tomtom|polestar|mappin` forces a style if they ask.
3. "No position" or "Not found" → say so and stop. Never invent, estimate or copy coordinates from Classic/Retail sources (Forever redrew Stormwind, Mulgore, Redridge, Eastern Plaguelands; `way` converts Wowhead's old points). Evidence: `docs/WAYPOINTS.md`.
4. Addon 0.5+: an NPC they talked to answers "confirmed in game by <char>, <date>" from their own sighting; that beats Wowhead. "Wowhead's pin is ~X yd off" means Wowhead is wrong there: say so.

NPCs met / where Wowhead is wrong: `$FS npcs [name]`, `$FS npcs --disagree`. Sharing: `$FS npcs --export-shared <file>` (no personal data) and a pull request merging it into `data/npc-locations.json`. Never upload anywhere yourself.

Routes ("take me to A, then B, then C"):
1. `$FS route clear`, then `$FS route add <query>` per stop (same lookup as `way`), or `$FS route add-json '[{"title":..,"mapID":..,"x":..,"y":..}]'`; `$FS route show`.
2. `$FS route write`, then one line to the user: "Press /fs go in game (or its key); the arrow moves on as you arrive, /fs next skips."
3. Nothing happened? `$FS route status`; `/fs go` loads 10 times per session (`/reload` resets, progress kept). Never press keys or /reload for them. Details: `docs/ROUTES-AND-NPCS.md`.

Profession training:
1. `$FS wowhead page 'npc=<trainerID>'` → LEARN NOW / NEXT, known recipes hidden. Find a trainer: `$FS wowhead page 'search?q=expert+tailor'`.
2. Rank at or near its cap (124/150): tell them to train the next rank first.

Gold and AH:
- Their own auctions: `$FS auctions` (owned list from the last AH visit + sold/expired/outbid/won since). Mail and AH payouts: `$FS mail`.
- Prices: `$FS ah "<item>" ["<item>" ...]` (off unless the user enabled `[ah]` in config; say so if it prints "AH prices are off") → use the median, not min buyout; current vs 30-day median says sell now or hold. Gold on hand is in `summary`.

Talents: `$FS talents` → "what next" comes from not-taken nodes marked "(available now)".
History and "did I finish X": `$FS history last-session|today|7d`, `$FS quest <id|name>`.
Everything else `$FS` can do (reputation, explored, achievements, collections, stats, mail, bank): `foreverscribe --help` and `skills/AGENT-INSTRUCTIONS.md`.

## Stat priorities

Never hardcode a spec. `$FS wowhead weights` reads the talent tab with the most points from `$FS talents` and prints the weights every `$FS wowhead` score uses. Scores are a heuristic: label them inference. Explain a recommendation with the stat changes, not the score. Respecced or another character: `$FS wowhead --for <name> ...` and `$FS -c <name> ...`.

## Rules

- Freshness in every answer, one clause: "as of your last /reload at 21:40, 2h ago". If `$FS freshness` says STALE (over 6 hours) or the answer depends on something recent, say the data may be out of date and ask for a `/reload` (the game only saves on /reload, logout or quit), or run `$FS pull` if SSH pull is configured. Quote a section's own captured time when it differs (bank, mail, recipes update only when that window was opened).
- Keep sources visibly separate. Telemetry = facts about their character. Wowhead Forever and AH = facts about the game. Anything from Classic/Era/Retail sources or your own memory: "Classic-only, may differ on Forever". Forever runs a retail-lineage 1.60 client (TOC 16001) with its own changes.
- Only `https://www.wowhead.com/forever/...` counts. Forever hides item stats until discovered and random-suffix items have none: no stats means unknown, never zero. Say "stats unknown, check in game".
- Arrive fully contextualized: their spec, currency on hand, what they already know or owns, weakest slots, mat costs and other uses of the currency (other professions too). Gather it all before answering; never answer partially and ask.
- Check what they did since the question was asked: `vendor` and `craft` read learned recipes and current currency. If they already bought it, say so first.
- Verify an addon or slash command before giving it. ForeverScribe's real commands (`/scribe` or `/fs`): `/scribe` alone opens its options (Esc → Options → AddOns → ForeverScribe: price tooltip, craft profit, save reminder, arrow) | `help | status | last [n] | snapshot | errors | played on|off | remind <min>|off | tooltip on|off|shift | craftprices on|off | way <x> <y> [zone] [title] | go | next | back | route [clear|slots] | npcs` (`live on|off` only with the opt-in Live addon). `/fs go` takes 3 new routes per session before a /reload. For other addons, say you haven't verified their syntax unless you checked their files.
- Read-only. Never automate the game, post, buy or sell. The one write towards the game is `route write` (data-only route slots the player loads with /fs go).

## Output format

- 8 lines or fewer, plain English, verdict first ("Buy X" / "Save" / "Yes, upgrade" / "Skip").
- Line 1: the verdict and the one reason. Then: the stat change vs what they wear, the cost and what blocks it, free wins in their bags, the bigger gap elsewhere, and what only they can decide.
- End with one freshness clause and the source labels used: telemetry, Wowhead Forever, AH (AHledger via wow.gg), Classic-only, inference.
- Give item names, not IDs. Give prices as gold/silver.

## Pitfalls

- `NEED web_extract(...)` is the normal path for an uncached page, not an error. `curl` on www.wowhead.com returns an empty 202: do not try it or a browser.
- `PARTIAL` in a header means the page holds more rows than were read: narrow the filter (level range, quality) or extract the page named there.
- A list page shows 50 rows at most. Use level and quality filters in the path instead of paging.
- `$FS wowhead` reads telemetry without ingesting. Step 1 (`$FS summary`) is what makes it fresh.
- `No telemetry for character` means the name is wrong: `$FS characters`.
- If `$FS` prints "No ForeverScribe data yet": `SETUP-FOR-AGENTS.md` in the repo.
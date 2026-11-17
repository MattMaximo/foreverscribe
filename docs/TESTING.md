# Tester checklist (Mac or Windows)

About 15 minutes. You need WoW: Forever and an AI agent (Claude Desktop/Code, Codex, Hermes, ChatGPT…).

## Setup
1. Give your agent this repo URL and say: "Set up ForeverScribe for me by following SETUP-FOR-AGENTS.md."
   Pick a mode when it asks: same computer (simplest), synced folder, direct push, or a relay (computers on different
   networks; your agent will ask for the relay URL and invite code).
2. Fully quit and relaunch WoW. At character select → AddOns, tick **ForeverScribe** (scroll icon; its dropdown holds
   "ForeverScribe · AH prices" and "ForeverScribe · Agent waypoints 1–3 of 3", leave those ticked).
3. Log in, type `/scribe status` (should show the version and `errors 0`), then `/reload`.

## In-game checks (do any you can, `/reload` at the end)
- [ ] Loot something, move an item between bags, equip an item.
- [ ] Turn in a quest; gain a profession skill point; open each profession window once.
- [ ] 0.8.2: open each profession while alive (once with only ForeverScribe enabled): recipes load and the recipe pane
      shows Cost to craft / Sells for / Profit under Reagents. As a ghost, click a profession tab: the empty window
      says you can't use professions while dead.
- [ ] Open your Reputation and Talents windows; open a flight master map.
- [ ] Walk into a new zone (stay 20 s) and back across a border.
- [ ] Open a vendor; open the auction house (and the mailbox if you have mail).
- [ ] Post or sell something on the AH if convenient.
- [ ] 0.5: talk to three NPCs (a vendor, a trainer, a quest giver); `/scribe npcs` should count them.
- [ ] 0.5 routes: ask your agent "make me a route: <NPC A>, then <NPC B>" (it writes the route), then press `/fs go`.
      An arrow should point at stop 1; walk there and it should switch to stop 2 by itself. Try `/fs next`, `/fs route`,
      `/fs route clear`. Bind `/fs go` under Esc > Options > Keybindings > AddOns > ForeverScribe and use the key.
- [ ] 0.5 routes, second route in the same session: ask for a new route and press `/fs go` again (no `/reload`):
      it should show the new route. (After a `/reload` your place on the current route should come back.)

- [ ] 0.9 relay (game and agent computers on different networks): after `/reload`, your agent sees the new state
      within a few seconds (`foreverscribe relay status` says when the game computer last connected). Ask for a
      route: it should arrive in game within about 30 s (`/fs go`). Turn the agent computer off for a while, play,
      `/reload`, turn it back on: everything should still arrive.

- [ ] 0.10 options: Esc → Options → AddOns → ForeverScribe opens a page (also `/scribe` alone, and the minimap
      button). Untick "AH prices in tooltips": hovering an item shows no prices; tick it and "Only with Shift":
      prices only with Shift. Untick "Craft profit": the profession window shows none. `/scribe tooltip on` while
      the page is open flips its box back. One status line: "v0.10.1 · saved … · prices … old". "Save (/reload)"
      does a /reload. No label ends in "…".
- [ ] 0.10.1 minimap button: a round scroll button on the minimap edge. Hover shows the status line, click opens
      the options, drag moves it around the edge (stays there after /reload). "Minimap button" in the options or
      `/scribe minimap` hides it.
- [ ] 0.10 addon list: ForeverScribe shows a scroll icon (no "?"), its dropdown lists "AH prices" and
      "Agent waypoints 1/2/3 of 3".
- [ ] 0.10.1 reinstall keeps prices: re-run the installer, restart WoW, hover an item: prices are there at once.

## Ask your agent
- "What level am I, where am I, and how fresh is your data?"
- "What changed in the last hour?" (should list your loot, quest, skill-up, zone)
- "Is anything in my bags an upgrade?" / "What should I craft?"
- "Which addons do I have running?" (cold tier, only when asked)
- "Where is <an NPC you talked to>?" (should say "confirmed in game"), and "Which NPCs is Wowhead wrong about?"

## Send back
- OS + which mode you chose, and anything your agent got stuck on.
- Output of `/scribe status` and `/scribe errors`.
- Anything wrong or missing in the answers above.
- Whether your other addons still work normally.
- 0.5: did `/fs go` pick up a route written while the game was running, and how long did it take to arrive?
- 0.9 relay: how long from `/reload` to your agent seeing it, and any "relay refused" lines in the game-side `sync.log`.

# Tester checklist (Mac or Windows)

About 15 minutes. You need WoW: Forever and an AI agent (Claude Desktop/Code, Codex, Hermes, ChatGPT…).

## Setup
1. Give your agent this repo URL and say: "Set up ForeverScribe for me by following SETUP-FOR-AGENTS.md."
   Pick a mode when it asks: same computer (simplest), synced folder, or direct push.
2. Fully quit and relaunch WoW. At character select → AddOns, tick **ForeverScribe** (leave ForeverScribe Live off).
3. Log in, type `/scribe status` (should show the version and `errors 0`), then `/reload`.

## In-game checks (do any you can, `/reload` at the end)
- [ ] Loot something, move an item between bags, equip an item.
- [ ] Turn in a quest; gain a profession skill point; open each profession window once.
- [ ] Open your Reputation and Talents windows; open a flight master map.
- [ ] Walk into a new zone (stay 20 s) and back across a border.
- [ ] Open a vendor; open the auction house (and the mailbox if you have mail).
- [ ] Post or sell something on the AH if convenient.

## Ask your agent
- "What level am I, where am I, and how fresh is your data?"
- "What changed in the last hour?" (should list your loot, quest, skill-up, zone)
- "Is anything in my bags an upgrade?" / "What should I craft?"
- "Which addons do I have running?" (cold tier, only when asked)

## Send back
- OS + which mode you chose, and anything your agent got stuck on.
- Output of `/scribe status` and `/scribe errors`.
- Anything wrong or missing in the answers above.
- Whether your other addons still work normally.

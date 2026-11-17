# AH prices in item tooltips (0.6)

Hover any item in game and ForeverScribe adds an **Auction House** section to its tooltip, from prices your agent
fetched for your realm's market. It never queries the auction house itself and never buys, bids, posts or cancels.

## What you see

Default (always):

| Line | Meaning |
|---|---|
| **Auction House** · `PvP Alliance · 14m ago` | your market and the age of the AH scan the prices come from |
| **Typical price** | today's median buyout (larger font) |
| **Your 12 are worth** | bags + bank count × typical price (only when you own some) |
| Hold Shift for details | |

Holding **Shift** adds: cheapest listing, listed right now, 7-day typical, 30-day typical with a green ▲ / red ▼
percentage (today vs the 30-day typical), the other faction's typical price, **Sell here or vendor?** (the AH typical
vs the vendor price, as a percentage), and **Used in** (up to two of your own recipes that use it, from your last
profession-window scan, then "…").

Patterns, recipes, plans: typical price of the pattern, **Crafted item sells for**, **Materials cost** (typical prices
of the reagents; "+ 2 not on AH" when some have no listings). Shift adds the pattern's own supply and trend.

Soulbound, bind-on-pickup, quest and account-bound items show `Typical price —` and the reason ("Soulbound · can't be
listed"); items nobody listed show "No recent listings". The tooltip never shows the vendor price line, whether you
know a recipe, or upgrade advice.

`/scribe tooltip on|off|shift` — `shift` shows the section only while Shift is held. `/scribe tooltip` alone tells you
which prices are loaded and how old they are.

## Craft cost & profit in the profession window (0.8)

Select a recipe in the profession window and a panel in the same style appears beside it:

| Line | Meaning |
|---|---|
| **Auction House** · `PvP Alliance · 14m ago` | market and scan age, as in the tooltip |
| **Cost to craft** | every material at its typical AH price, or the vendor's price where a vendor sells it cheaper |
| **Sells for** (makes N) | the crafted item's typical AH price × how many one craft makes |
| **Profit** | sells for − the AH cut − cost; green when positive, red when negative (larger font) |
| After the 5% AH cut · Hold Shift for materials | |

**Shift** lists each material: have/need (bags + bank; green when you have enough), the price of one, and where that
price comes from (AH or vendor), then the AH cut in copper. Hovering a recipe in the list adds the same numbers,
compactly, to its tooltip. `/scribe craftprices on|off`.

Rules:
- A line that can't be calculated is left out, never guessed. A material with no AH listings that no vendor sells
  leaves out **Cost** and **Profit** ("1 material has no price"); a crafted item that binds when picked up, or that
  nobody listed, leaves out **Sells for** and **Profit** (BoP: "Binds when picked up · can't be sold").
- Vendor prices: the price your characters saw at a vendor (merchant capture, unlimited stock, money only) wins;
  otherwise `data/vendor-prices.json` (game data: the client's list price for materials 50+ vendors sell). Limited-stock
  sellers don't count.
- The AH cut: the client has no API for it. The companion uses `[ah] cut` in `config.toml` if set, else the median rate
  of your own AH sale invoices (captured when you open the mailbox), else 5% (Forever's faction auction houses).
- Only the basic materials count (not optional or finishing reagents).
- For recipes your characters know, the companion works the numbers out when it writes the price file
  (`p[100000000 + recipeID]`), so selecting a recipe is one table lookup; a recipe learned since then is worked out in
  game from the client's own recipe data, with the same rules. About 50 bytes per recipe (51 known recipes: +2.7 KB on
  a 300 KB file).

For your agent: `foreverscribe craft --profit [profession] [--limit N] [--all] [--json]` (MCP tool `craft_profit`)
ranks the character's known recipes by profit right now, with the skill-up colour (orange/yellow/green raise the skill,
gray doesn't) and why any recipe can't be priced.

## How the prices get there

1. Your agent turns prices on (`[ah]` in `config.toml`: off by default, see `config.example.toml` for why) and runs
   `foreverscribe prices write`. It asks wow.gg for one page; only when the AH scan changed does it fetch the whole
   market (~33 pages of 200 items) and write a small data-only file:
   `Interface/AddOns/ForeverScribe_Prices/Prices.lua` — about 300 KB for ~6,500 items (median, cheapest, listed,
   7-day, 30-day, other faction; recipe → crafted item + materials), capped at 600 KB (least-listed items dropped
   first; the addon refuses more than 20,000 items).
2. Delivery uses your normal transport, in reverse:
   - **local** (agent on the game computer): written straight into the AddOns folder. Keep it fresh with
     `foreverscribe prices watch` (every 30 min) or a scheduled `prices write`.
   - **folder**: written to `<folder>/_prices/Prices.lua`; the game-side sync agent copies it in when it syncs.
   - **http**: the receiver keeps it; the game-side sync agent asks for it every 5 minutes (signed `POST /v1/prices`
     with the pairing key, `X-FS-Have` = the rev it has → `304` when unchanged). When the receiver's copy is older
     than 30 minutes, an ask also refreshes it in the background. So prices stay fresh while the game computer is
     on, and nothing is fetched while it is off.
3. Both sync agents check the file line by line (plain data only, at most 1 MB) before writing it; a damaged or
   tampered file is ignored and logged.
4. The game reads the file at login and on `/reload` (it is a normal addon, not load-on-demand). The tooltip always
   shows the age of the scan, turning amber after 6 hours.

`foreverscribe prices status` shows what was written, how old the scan is and (http) when the game computer fetched it.

## For developers

- Writer and format: `foreverscribe/prices.py` (`render_lua`, `LINE_RE`). The sync agents carry the same line rule
  (`PRICE_LINE` in `foreverscribe-sync.sh`, `$PriceLine` in `foreverscribe-sync.ps1`): change all three together.
- `data/patterns.json` (recipe item → crafted item + reagents) is game data from Wowhead's Forever tooltips, rebuilt
  with `python3 tools/build_patterns.py <data_dir>/prices/market-*.json`.
- Tooltip: `addon/ForeverScribe/Tooltip.lua`. `TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item)`
  (Forever UI source: `Blizzard_SharedXMLGame/Tooltip/TooltipDataHandler.lua:199`), `OnTooltipSetItem` only as a
  fallback; GameTooltip and ItemRefTooltip only. Every call is pcall'd and every game value goes through `Clean`
  (secret values dropped). Lookups are one table index per hover (rows are parsed once and memoised). Shift: bag, bank,
  merchant, AH and character tooltips rebuild themselves every 0.2 s; only an unowned tooltip (a chat link) is asked
  to `RefreshData`, never in combat.
- Tests: `tests/lua/test_addon.lua` (`v6 …`: default, Shift, pattern, soulbound/quest, no data, loader and size cap,
  fallback hook, secret values), `tests/test_prices.py` (writer, cap, local/folder/http delivery, both agents' line
  rules and paths, the addon loading a written file).

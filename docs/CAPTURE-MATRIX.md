# ForeverScribe capture matrix (v0.6.0)

What the addon records about a character, which Forever API it reads, when, and how sure we are.
Sources: Forever client 1.60.1.70938 UI source (`research/wow-ui-source-forever`, Gethe/wow-ui-source branch `forever`;
Forever's game UI is the "Camelot" project, `WOW_PROJECT_ID = 18`).

Status key:
- **doc**: the function/event is in Forever's generated API docs (`Blizzard_APIDocumentationGenerated`).
- **ui**: not in the docs but Forever's own UI code calls it (so it exists in this client).
- **seen**: confirmed in a real player's SavedVariables (2026-11-15).
- **unverified**: shape known from docs/UI; real values not seen yet (needs an in-game /reload with 0.2/0.3).
- **unsupported**: Forever doesn't expose it, or it isn't part of this game; not captured.

`tools/check_api.py` checks every call in `Collect.lua`, `Core.lua`, `Waypoint.lua`, `Npcs.lua`, `Route.lua` and `Live.lua` (all are doc or ui, except
pcall-guarded Classic fallbacks). `tools/api_lookup.py` / `tools/api_probe.py` print signatures and status for any name.

## What "Legacy" is in Forever

Forever has its own account progression called **Legacy** (`Blizzard_LegacySystem`, Camelot-only):
- **Legacy Challenges** are Forever's achievements. The Achievements panel is replaced by the Legacy Challenges
  window (`Blizzard_AchievementUI/Camelot`). Each challenge awards **Legacy Points**
  (`C_Traits.GetTraitCurrencyForAchievement(4225, achievementID)`), shown instead of achievement points.
  Class-specific challenge categories exist (Mage = 15579).
- **Legacy trees**: three trait trees bought with Legacy Points: Professions (1187), Adventure (1188),
  Progression (1189). Read with `C_Traits.GetConfigIDByTreeID` + the normal node APIs.
- **Legacy reward track**: a renown-style track on major faction 2802 (`C_MajorFactions`). The Legacy UI only opens
  once its renown level is > 0.
- **PvP rank** is also renown-style (major faction 2800, `PVPRankFrame.lua`), with seasons
  (`GetCurrentArenaSeason`, `C_SeasonInfo.GetTimeUntilCurrentPVPSeasonEnd`).
- No runes/engravings (`C_Engraving` absent), no seasonal/timerunning system in the UI (`PlayerGetTimerunningSeasonID`
  exists and is recorded if non-zero). Game rules expose hardcore/self-found/standard flags and the
  Classic vs Enhanced **experience preset** (`C_GameRules.GetForeverExperiencePreset`).

## Matrix

| What | API (Forever) | When captured | Status |
|---|---|---|---|
| Identity, level, XP, rested, money, played, location, hearth | UnitName/UnitClass/…, GetBindLocation, RequestTimePlayed | login, /reload, logout, events | doc, seen |
| Equipment (item, enchant, stats, durability) | GetInventoryItemLink/ID, C_Item.GetItemStats, GetInventoryItemDurability | login + PLAYER_EQUIPMENT_CHANGED | doc/ui, seen |
| Bags, reagent bag, keyring, bank tabs | C_Container.* | BAG_UPDATE_DELAYED; bank on BANKFRAME_OPENED | doc, seen (bags) |
| Quest log + objectives | C_QuestLog.GetInfo/GetQuestObjectives | QUEST_LOG_UPDATE (throttled) | doc, seen |
| Completed quests (IDs) | C_QuestLog.GetAllCompletedQuestIDs | login, turn-in | doc, seen (187) |
| Completed-quest titles (pre-install backfill) | C_QuestLog.GetTitleForQuestID (client cache only, 150/s, cap 3000) | 20 s after login | doc, unverified (cache hit-rate unknown) |
| Skills incl. weapon/armor skills, languages | C_SkillInfo / GetSkillLineInfo | SKILL_LINES_CHANGED | doc, seen |
| Spellbook with ranks | C_SpellBook.GetSpellBookItemInfo / GetSpellBookItemName | SPELLS_CHANGED, LEARNED_SPELL_IN_SKILL_LINE | doc, seen (56 spells) |
| Talents: all nodes incl. untaken, max rank, per-tab (group) points, unspent, loadout name, dual spec | C_ClassTalents.GetActiveConfigID, C_Traits.GetConfigInfo/GetTreeNodes/GetNodeInfo/GetEntryInfo/GetDefinitionInfo/GetTreeCurrencyInfo/GetGroupDisplayInfoByTreeID/GetGroupCurrencyInfo, C_SpecializationInfo.GetCombatConfigIDForSpecGroup, GetNumSpecGroups | login; TRAIT_CONFIG_UPDATED, PLAYER_TALENT_UPDATE, CHARACTER_POINTS_CHANGED, ACTIVE_TALENT_GROUP_CHANGED → TALENT_CHANGED (names, from→to, max) | doc/ui; taken nodes seen, untaken/groups unverified |
| Legacy trees (nodes, points spent/unspent, max available) | C_Traits.GetConfigIDByTreeID(1187/1188/1189), GetMaxAvailableTraitCurrency(4225) | login; TRAIT_TREE_CURRENCY_INFO_UPDATED → TALENT_CHANGED (legacy=true) | doc, unverified |
| Legacy reward track rank | C_MajorFactions.GetMajorFactionProgressionInfo/GetMajorFactionData(2802) | login; MAJOR_FACTION_RENOWN_LEVEL_CHANGED → RENOWN_CHANGED | doc, unverified |
| Legacy Challenges (achievements): every challenge, done/not, date, Legacy Points, criteria progress + what's left | GetCategoryList, GetCategoryInfo, GetCategoryNumAchievements, GetAchievementInfo, GetAchievementNumCriteria, GetAchievementCriteriaInfo, GetTotalAchievementPoints | 12 s after login; ACHIEVEMENT_EARNED event (+ Legacy Points) | ui, unverified |
| Statistics (deaths, kills, …) | GetStatisticsCategoryList, GetStatistic | with achievements | ui, unverified |
| Reputation: all factions, standing, value, progress in band, at-war, watched, account-wide, group header | C_Reputation.GetNumFactions/GetFactionDataByIndex/GetFactionDataByID/GetWatchedFactionData | login; UPDATE_FACTION → REPUTATION_CHANGED (deltas aggregated per faction ≤120 s; standing changes emit at once), FACTION_AT_WAR | doc, unverified |
| PvP: rank (renown 2800) + title, lifetime/session/yesterday HKs, honor, flag, season | GetPVPLifetimeStats, GetPVPSessionStats, GetPVPYesterdayStats, UnitHonor*, UnitIsPVP, GetPVPDesired, C_MajorFactions(2800), GetCurrentArenaSeason | login; PLAYER_PVP_KILLS_CHANGED, HONOR_XP_UPDATE | doc/ui, unverified |
| Explored zones/areas | C_Map.GetMapChildrenInfo (world 947 → continents → zones), C_MapExplorationInfo.GetExploredMapTextures, GetExploredAreaIDsAtPosition, C_Map.GetAreaInfo | full scan 5 s after login; MAP_EXPLORATION_UPDATED → EXPLORATION_DISCOVERED (area names) | doc, unverified |
| Titles (known, current) | GetNumTitles, IsTitleKnown, GetTitleName, GetCurrentTitle | login; KNOWN_TITLES_UPDATE → TITLE_EARNED | doc, unverified |
| Mounts | C_MountJournal.GetMountIDs/GetMountInfoByID | login; NEW_MOUNT_ADDED → MOUNT_LEARNED | doc, unverified |
| Companion pets | C_PetJournal.GetOwnedPetIDs + GetPetInfoByPetID (fallback GetNumPets/GetPetInfoByIndex) | login; NEW_PET_ADDED / COMPANION_LEARNED → PET_LEARNED | doc/ui, unverified |
| Toys | C_ToyBox.GetNumFilteredToys/GetToyFromIndex/GetToyInfo, PlayerHasToy (current Toy Box filter only) | login; NEW_TOY_ADDED → TOY_LEARNED | ui, unverified |
| Currencies/tokens | C_CurrencyInfo.GetCurrencyListSize/GetCurrencyListInfo/GetCurrencyInfo | login; CURRENCY_DISPLAY_UPDATE → CURRENCY_CHANGED (aggregated) | doc, unverified |
| Character sheet: HP, mana, 5 stats (base/effective/buff), armor, resistances, spell power per school, healing, spell crit/hit/haste/pen, melee/ranged AP + crit/hit, damage, speed, dodge/parry/block, defense, mana regen, avg ilvl | UnitStat, UnitArmor, UnitResistance, GetSpellBonusDamage/Healing, GetSpellCritChance, GetSpellHitModifier, UnitSpellHaste, GetSpellPenetration, GetCritChance, GetRangedCritChance, GetHitModifier, GetMeleeHaste, UnitAttackPower, UnitRangedAttackPower, UnitDamage, UnitAttackSpeed, GetManaRegen, GetDodge/Parry/BlockChance, UnitDefenseSkill, GetAverageItemLevel | login, gear change (+2 s), level-up, durability change | doc/ui, unverified |
| Buffs (player, helpful only) | C_UnitAuras.GetAuraDataByIndex("player", i, "HELPFUL") | login, UNIT_AURA (throttled 3 s) | doc, unverified (may be secret in combat; secret values are dropped) |
| Durability (per slot, min/avg, broken) | GetInventoryItemDurability | login, UPDATE_INVENTORY_DURABILITY | ui, unverified |
| Equipment sets | C_EquipmentSet.GetEquipmentSetIDs/GetEquipmentSetInfo/GetItemIDs | login, EQUIPMENT_SETS_CHANGED | doc, unverified |
| Instance lockouts / world bosses | RequestRaidInfo, GetNumSavedInstances, GetSavedInstanceInfo, GetNumSavedWorldBosses, GetSavedWorldBossInfo | login, boss kill (+5 s), UPDATE_INSTANCE_INFO | ui, unverified |
| Guild name/rank (no roster, no chat) | IsInGuild, GetGuildInfo("player") | login, PLAYER_GUILD_UPDATE | doc/ui, seen (name via identity) |
| Flight paths | NumTaxiNodes, TaxiNodeName, TaxiNodeGetType | taxi map open | ui, unverified |
| Mailbox summary (NPC/AH sender+subject, money, COD, items, days left; player mail = money/items only) | GetInboxNumItems, GetInboxHeaderInfo, GetInboxItem | mailbox open, MAIL_INBOX_UPDATE | ui, unverified |
| Profession recipes + recipe cooldowns | C_TradeSkillUI.GetFilteredRecipeIDs/GetRecipeInfo/GetRecipeCooldown | profession window open | ui, seen (Cooking) |
| Game mode: hardcore, self-found, standard, mode record, experience preset (Classic/Enhanced), timerunning season, XP disabled | C_GameRules.*, PlayerGetTimerunningSeasonID, IsXPUserDisabled | login | doc, unverified |
| Dungeons: enter/exit, boss kill/wipe, deaths, loot | ENCOUNTER_START/END, GetInstanceInfo, loot events | events | doc, seen (zone) |

## Not captured (and why)

| What | Reason |
|---|---|
| Heirlooms | `C_Heirloom` isn't in Forever's API docs (only Mainline UI calls it). |
| Transmog/appearances | Not character progression; would be large. Can be added if wanted. |
| Hunter pet details, stable | Not Matt's class; can be added (`C_StableInfo` exists). |
| Guild roster, other players, chat/whispers, player mail text/senders | Privacy rule: no other players' private data, no chat capture. |
| Unrevealed map areas / zone totals | Forever only returns *explored* overlays, so "% explored" can't be computed; we store count of revealed sections + area names. |
| Toys outside the Toy Box's current filter | Reading them would require changing Matt's filters; the addon never mutates UI state. |
| Factions under collapsed headers on first scan | Same rule (no expanding headers); once seen they are refreshed by ID even when collapsed. |

## Teardown rule

During logout / leaving the world the client returns empty or zeroed data. Every collector follows:
**an empty read never replaces a non-empty one.** Implementation: `state.leaving` skips all v0.2 scans after
PLAYER_LEAVING_WORLD/PLAYER_LOGOUT; each collector returns nil on an empty read; reputation, achievements,
exploration (per zone), titles, collections, Legacy trees, lockouts (unexpired kept), stats (health 0 = skip),
buffs and recipes keep their last good value. On the companion side `store._store_sections` ignores empty
sections, older files and much-smaller partial reads; `latest_snapshot` still skips degraded snapshots.

## Size

Bounded by `ForeverScribe.Collect.CAP` (factions 400, nodes 700/tree, achievements 1500, statistics 500,
zones 250, mounts/pets/toys 1000 each, currencies 200, quest titles 3000, mail 50). Measured in the simulated client:
- A real level-25 character's v0.1.1 file: 41,215 bytes.
- Same character, v0.2 estimate (35 factions, ~350 Legacy Challenges, 55 zones, 190 quests): ~130 KB in the stub
  (stub snapshot is ~30 KB smaller than the real one), so roughly 160–200 KB real. Legacy Challenges are about half.
- Stress test at every cap: ~1.06 MB (test asserts < 2 MB). The receiver accepts up to 32 MB.

## v0.3 additions (all read-only; all **unverified** in game until a 0.3 /reload)

| What | API (status) | When | Stored as |
|---|---|---|---|
| New mail without opening the mailbox | `HasNewMail`, `GetLatestThreeSenders` (ui: Minimap), `UPDATE_PENDING_MAIL` (doc) | login, every UPDATE_PENDING_MAIL | `mailPending {hasNew, senders}`; event MAIL_PENDING when it changes. A sender without a space (could be a player) is stored as "player". |
| Full mailbox + AH invoices | `GetInboxHeaderInfo`, `GetInboxItem`, `GetInboxInvoiceInfo` (ui: MailFrame) | mailbox open | `mail.mails[i].invoice {type, item, bid, buyout, deposit, fee, count}`; buyer/seller name never read into storage |
| Auction outcomes | `AUCTION_HOUSE_SHOW_NOTIFICATION`, `AUCTION_HOUSE_SHOW_FORMATTED_NOTIFICATION` (doc, `Enum.AuctionHouseNotification`), `CHAT_MSG_SYSTEM` (doc) matched against the client's own `ERR_AUCTION_SOLD_S`, `ERR_AUCTION_EXPIRED_S`, `ERR_AUCTION_OUTBID_S`, `ERR_AUCTION_WON_S`, `ERR_AUCTION_COMMODITY_WON_S`, `ERR_AUCTION_REMOVED(_S)` | as they happen, AH open or not | events AUCTION_SOLD / EXPIRED / OUTBID / WON / REMOVED `{item, qty, itemID, buyout}` (enriched from the owned list). Both sources de-duplicate within 5 s. Every other system line returns before anything is stored; no other chat event is registered. |
| Owned auctions | `C_AuctionHouse.GetNumOwnedAuctions`, `GetOwnedAuctionInfo`, `HasFullOwnedAuctionResults` (doc), `OWNED_AUCTIONS_UPDATED` (doc) | AH open; reads what Blizzard's own AH UI already queried. ForeverScribe never calls `QueryOwnedAuctions`. | `auctions.list[] {auctionID, itemID, name, qty, status, timeLeft, bid, buyout, hasBidder}`; bidder name never stored |
| Vendor lists | `C_MerchantFrame.GetItemInfo` (doc) with `GetMerchantItemInfo` fallback, `GetMerchantNumItems`, `GetMerchantItemID`, `GetMerchantItemLink`, `GetMerchantItemCostInfo`, `GetMerchantItemCostItem` (ui: MerchantFrame), `C_TooltipInfo.GetMerchantItem` (doc) for "Already known", `UnitGUID("npc")` (doc) | MERCHANT_SHOW / MERCHANT_UPDATE | `vendors.npcs[npcID] {name, items[] {itemID, price, stack, cost[] (currency/item), limited, usable, purchasable, known}}`, newest 40 vendors |
| Installed addons | `C_AddOns.GetNumAddOns`, `GetAddOnInfo`, `IsAddOnLoaded`, `GetAddOnMetadata(...,"Version")`, `GetAddOnEnableState` (doc) | login + ADDON_LOADED; stored only when changed | cold `addons.list[]` |
| Keybinds | `GetNumBindings`, `GetBinding` (ui: Keybindings) | login + UPDATE_BINDINGS, only when changed | cold `bindings.list[] {action, cat, key1, key2}` (bound actions only) |
| Action bars | `HasAction`/`C_ActionBar.HasAction` (doc), `GetActionInfo` (ui) | login + ACTIONBAR_SLOT_CHANGED, only when changed | cold `actionbars.slots[slot] {type, id, name}` (slots 1-180) |
| Macro names | `GetNumMacros`, `GetMacroInfo` (ui: MacroUI) — name only | login + UPDATE_MACROS, only when changed | cold `macros {account[], character[]}`; macro text is never stored |
| Save reminder | `C_Timer.After`, `InCombatLockdown` | every 60 s check, off by default | prints one chat-frame line after N minutes without a save; never calls ReloadUI |
| Other addons' SavedVariables | (sync agent, not the addon) | every save | files matching `[sync] extra_saved_variables` (default `ForeverForge*.lua`, `Polestar.lua`), in the account folder and every `WTF/Account/<acct>/<realm>/<char>/SavedVariables` folder, are shipped; `Polestar.lua` is parsed (`polestar.py`: PolestarDB / PolestarCharDB, unknown fields kept), others kept raw ("unparsed") until a real sample is inspected |
| Polestar guide state (0.7, `Guide.lua`) | `Polestar.On` messages, `Polestar.Engine.GetTabs/GetStepView(i, true)/GetProgress/GetGuide/GetLiveStep`, `Polestar.Nav.API.Target/Active` (Polestar's documented API v1) | login + 2 s after a Polestar step/tab/guide change | `snapshot.polestar`: tabs (id, title, step N/M, done), active tab, current step title + open goals with progress, arrow target + next leg. Only when the real Polestar addon is loaded; read-only |

## v0.4: waypoints (an action the player types, not capture)

| What | API (status) | When | Stored |
|---|---|---|---|
| `/scribe way` / `/fs way` map pin + arrow | `C_Map.SetUserWaypoint`, `ClearUserWaypoint`, `CanSetUserWaypointOnMap`, `GetMapInfo`, `GetMapChildrenInfo`, `GetBestMapForUnit`, `C_SuperTrack.SetSuperTrackedUserWaypoint`, `C_GameRules.IsGameRuleActive`, `C_AddOns.IsAddOnLoaded` (all doc); `UiMapPoint.CreateFromCoordinates` (ui: Blizzard_ObjectAPI) | only when the player types the command | nothing except the setting `settings.wayAddon` (`/scribe way addon native`) |
| Hand-off to other arrows | Polestar `Polestar.Nav.API.Navigate/Cancel` (version 1), TomTom `TomTom:AddWaypoint/RemoveWaypoint` — only when that addon is loaded | same | nothing |

Evidence and paste-command syntaxes: [`WAYPOINTS.md`](WAYPOINTS.md).

## v0.5: NPC sightings (read-only) and routes (an action the player triggers)

| What | API (Forever) | When | Stored | Status |
|---|---|---|---|---|
| NPC sightings: npcID, name, subtitle, uiMapID, player x/y, zone/subzone, kind, count | `UnitGUID("npc")` (doc, SecretWhenUnitIdentityRestricted: secret → skipped), `UnitName`, `UnitIsPlayer`, `UnitPlayerControlled` (doc), `C_TooltipInfo.GetUnit` (doc, subtitle line), `C_Map.GetBestMapForUnit` + `C_Map.GetPlayerMapPosition` (doc), `C_Map.GetMapWorldSize` (doc, yards) | GOSSIP_SHOW, MERCHANT_SHOW, TRAINER_SHOW, QUEST_DETAIL/GREETING/PROGRESS/COMPLETE, TAXIMAP_OPENED, BANKFRAME_OPENED, AUCTION_HOUSE_SHOW, PLAYER_INTERACTION_MANAGER_FRAME_SHOW (all doc) | `chars[k].npcs["<npcID>:<mapID>"] {id, name, sub, map, x, y, n, first, t, kind, zone, subzone, r, spots[≤4]}`; ≤1000 entries; 5 yd merge | doc; unverified in game |
| Friendly NPC targeted up close | `PLAYER_TARGET_CHANGED` (doc), `InCombatLockdown`, `UnitExists`, `UnitIsFriend`, `CheckInteractDistance(unit, 3)` (doc; secret → skipped) | out of combat, within ~10 yd; `/scribe npcs target off` | same table, kind `target`, r = 10 | doc; unverified |
| Route progress | `C_AddOns.LoadAddOn("ForeverScribe_RouteNN")` (doc), `C_AddOns.IsAddOnLoaded`, `C_Timer.NewTicker` (doc), `C_Map.GetPlayerMapPosition`, waypoint calls as in v0.4 | `/fs go`, `/fs next`, `/fs back`, key bindings (Bindings.xml); 1 s ticker only while a route runs | `ForeverScribeDB.route {rev, name, stops[], i, started, done}`; events `route_start`, `route_done` | doc; unverified |

Never: players, pets, other players' names or GUIDs, objects, secret values; no input automation, no `ReloadUI`.
The route slot addons (`ForeverScribe_Route01-10`) contain only data the companion wrote; see `docs/ROUTES-AND-NPCS.md`.

## AH price tooltip (0.6, `Tooltip.lua`) — reads only, stores nothing

| API | Why | Evidence (Forever UI source) |
|---|---|---|
| `TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, fn)` | add lines after an item tooltip is built | `Blizzard_SharedXMLGame/Tooltip/TooltipDataHandler.lua:199`; `TooltipDataType.Item = 0` in `TooltipInfoSharedDocumentation.lua` |
| `GameTooltip:HookScript("OnTooltipSetItem")` | fallback when the processor is missing | — |
| `OnTooltipCleared` / `OnHide` hooks | forget our lines, restore fonts | — |
| tooltip data `lines[].type == ItemBinding (20)`, `bonding` | soulbound / quest / account-bound reason | `TooltipInfoSharedDocumentation.lua` (`TooltipDataItemBinding`) |
| `C_Item.GetItemInfo` (sell price, class, bind type) | sell-or-vendor verdict, quest items | `ItemDocumentation.lua:626` |
| `C_Item.GetItemCount(id, true)` | "Your N are worth" (bags + bank) | `ItemDocumentation.lua:451` |
| `IsShiftKeyDown`, `MODIFIER_STATE_CHANGED`, `InCombatLockdown` | Shift details; refresh a chat-link tooltip outside combat | `InputDocumentation.lua`, `RestrictedActionsDocumentation.lua` |
| `GetMoneyString`, `GetCoinTextureString`, `BreakUpLargeNumbers` | native coin formatting | `Blizzard_SharedXML/FormattingUtil.lua:72`, `CurrencyInfoDocumentation.lua`, `LocalizationDocumentation.lua` |
| `tooltip:RefreshData()` | rebuild an unowned tooltip when Shift changes | `Blizzard_GameTooltip/Mainline/GameTooltip.lua:958` |

## Craft cost & profit (0.8, `Craft.lua`) — reads only, stores one setting (`craftprices`)

| API | Why | Evidence (Forever UI source) |
|---|---|---|
| `hooksecurefunc(ProfessionsFrame.CraftingPage.SchematicForm, "Init", fn)` | post-hook: the selected recipe (`recipeInfo.recipeID`) | `Blizzard_Professions/Blizzard_ProfessionsCrafting.xml:143`, `Blizzard_ProfessionsTemplates/Blizzard_ProfessionsRecipeSchematicForm.lua:361` |
| `SchematicForm:GetRecipeInfo()` | the recipe already shown when the hook lands late | `Blizzard_ProfessionsRecipeSchematicForm.lua:1530` |
| `EventRegistry:RegisterCallback("Professions.RecipeListOnEnter", fn, owner)` | compact numbers when hovering a recipe in the list | `Blizzard_ProfessionsTemplates/Blizzard_ProfessionsRecipeList.lua:395` |
| `ADDON_LOADED("Blizzard_Professions")`, `TRADE_SKILL_SHOW` | the profession UI is load-on-demand: hook when it exists | `Blizzard_Professions.toc` (`LoadOnDemand: 1`), `TradeSkillUIDocumentation.lua` |
| `C_TradeSkillUI.GetRecipeSchematic(recipeID, false)` | materials + product for a recipe the price file doesn't have yet | `TradeSkillUIDocumentation.lua:753`, `CraftingRecipeSchematic` in `TradeSkillUITypesDocumentation.lua:281` |
| `C_Item.GetItemInfo` (bind type 1), `C_Item.GetItemNameByID`, `C_Item.GetItemCount(id, true, false, true)` | bind-on-pickup reason, material names, have/need | `ItemDocumentation.lua:846`, `:451`, `:626` |
| `CreateFrame("GameTooltip", "ForeverScribeCraftTip", UIParent, "GameTooltipTemplate")` | our own panel beside the window; no Blizzard frame is changed | — |

Never: `C_TradeSkillUI.CraftRecipe`, the Create / Create All buttons, buying materials, posting the result.

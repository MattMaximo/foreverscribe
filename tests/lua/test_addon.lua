-- ForeverScribe addon tests. Run: tools/lua/bin/lua tests/lua/test_addon.lua [fixtureDir]
-- Each test boots a fresh simulated client (tests/lua/wow_stub.lua).

local ROOT = (arg and arg[0] or ""):match("^(.*)tests/lua/[^/]+$") or "./"
dofile(ROOT .. "tests/lua/wow_stub.lua")
W.ROOT = ROOT
local FIXTURES = arg and arg[1]

local passed, failed = 0, {}
local function test(name, fn)
	dofile(ROOT .. "tests/lua/wow_stub.lua") -- fresh API tables (some tests delete APIs)
	W.Reset()
	W.ROOT = ROOT
	local ok, err = pcall(fn)
	if ok then passed = passed + 1; io.write(".") else failed[#failed + 1] = name .. ": " .. tostring(err); io.write("F") end
end
local function eq(a, b, msg) if a ~= b then error((msg or "") .. " expected " .. tostring(b) .. " got " .. tostring(a), 2) end end
local function truthy(v, msg) if not v then error(msg or "expected truthy", 2) end end

local function C() return ForeverScribeDB.chars[ForeverScribe.charKey] end
local function events(kind)
	local out = {}
	for _, e in ipairs(C().events) do if not kind or e.type == kind then out[#out + 1] = e end end
	return out
end
local function bagUpdate() W.Fire("BAG_UPDATE_DELAYED"); W.Advance(1) end

test("boot creates character, baseline is silent", function()
	W.Boot()
	eq(ForeverScribe.charKey, "Forever-Test:Pixelpop")
	local s = C().snapshot
	eq(s.level, 23); eq(s.money, 123456); eq(s.location.zone, "Loch Modan"); eq(s.location.x, 35.12)
	eq(s.equipment.wrist.itemID, 6268); eq(s.equipment.wrist.name, "Pioneer Bracers"); eq(s.equipment.wrist.dur, 30)
	eq(s.bags.items[2589].count, 7)
	eq(#s.questsCompleted, 3); eq(s.questsCompleted[1], 7)
	eq(s.quests[1].title, "Filthy Paws"); eq(s.quests[1].zone, "Loch Modan")
	eq(s.skills[2].name, "First Aid"); eq(s.skills[2].group, "Secondary Skills")
	eq(s.spells[133].name, "Fireball"); eq(s.talents.trees[2].points, 5)
	eq(s.played.total, 360000); eq(s.hearth, "Thelsamar")
	eq(s.identity.class, "MAGE"); eq(s.identity.client.toc, 16001)
	local evs = events()
	eq(#evs, 1, "only SESSION_START"); eq(evs[1].type, "SESSION_START")
	truthy(evs[1].id:match("^%d+%-%x+%-%d+:1$"), "id format session:seq")
end)

test("1 level-up event", function()
	W.Boot()
	W.player.level = 24
	W.Fire("PLAYER_LEVEL_UP", 24, 0, 0)
	local e = events("LEVEL_UP")
	eq(#e, 1); eq(e[1].payload.level, 24); eq(e[1].payload.from, 23)
end)

test("2 loot quantity", function()
	W.Boot()
	W.loot = { { itemID = 2589, count = 5 } }
	W.Fire("LOOT_OPENED")
	W.bags[0][2].count = 12
	W.Fire("BAG_UPDATE_DELAYED")
	W.Fire("LOOT_CLOSED")
	W.Advance(1)
	local a = events("ITEM_ACQUIRED")
	eq(#a, 1); eq(a[1].payload.itemID, 2589); eq(a[1].payload.qty, 5); eq(a[1].payload.reason, "loot"); eq(a[1].payload.total, 12, "bank unknown until opened")
	eq(#events("LOOT"), 1)
	eq(events("LOOT_WINDOW")[1].payload.items[1].qty, 5)
end)

test("3 bag move is not an acquisition", function()
	W.Boot()
	W.bags[2][3] = W.bags[0][2]; W.bags[0][2] = nil
	bagUpdate()
	-- split a stack across bags too
	W.bags[2][3].count = 4; W.bags[0][5] = { itemID = 2589, count = 3 }
	bagUpdate()
	eq(#events("ITEM_ACQUIRED"), 0); eq(#events("ITEM_REMOVED"), 0)
end)

test("4 equip from bag: EQUIPMENT_CHANGED, no false acquire/remove", function()
	W.Boot()
	W.bags[1][1] = { itemID = 6268, count = 1 }
	W.equip[9] = 3647
	W.Fire("PLAYER_EQUIPMENT_CHANGED", 9, true)
	bagUpdate()
	local e = events("EQUIPMENT_CHANGED")
	eq(#e, 1); eq(e[1].payload.slot, "wrist"); eq(e[1].payload.new.name, "Bright Bracers"); eq(e[1].payload.new.ilvl, 26); eq(e[1].payload.old.itemID, 6268)
	eq(#events("ITEM_ACQUIRED"), 0); eq(#events("ITEM_REMOVED"), 0)
	eq(C().snapshot.equipment.wrist.stats.ITEM_MOD_INTELLECT_SHORT, 5)
	eq(C().snapshot.bags.items[6268].equipLoc, "INVTYPE_WRIST", "bag gear carries comparison data")
end)

test("5 quest accept, progress, complete, abandon", function()
	W.Boot()
	table.insert(W.quests, { title = "Ironband's Excavation", questID = 436, level = 15, objectives = { { text = "Find Ironband", numFulfilled = 0, numRequired = 1, finished = false } } })
	W.Fire("QUEST_ACCEPTED", 436); W.Advance(1)
	eq(events("QUEST_ACCEPTED")[1].payload.title, "Ironband's Excavation")
	W.quests[2].objectives[1].numFulfilled = 2
	W.Fire("QUEST_LOG_UPDATE"); W.Advance(1)
	local p = events("QUEST_PROGRESS")
	eq(#p, 1); eq(p[1].payload.have, 2); eq(p[1].payload.need, 4)
	-- turn in 307
	W.Fire("QUEST_TURNED_IN", 307, 1450, 1500)
	table.remove(W.quests, 2); W.completed[307] = true
	W.Fire("QUEST_REMOVED", 307); W.Advance(5)
	local c = events("QUEST_COMPLETED")
	eq(#c, 1); eq(c[1].payload.questID, 307); eq(c[1].payload.title, "Filthy Paws"); eq(c[1].payload.xp, 1450)
	eq(#events("QUEST_ABANDONED"), 0)
	local found = false
	for _, q in ipairs(C().snapshot.questsCompleted) do if q == 307 then found = true end end
	truthy(found, "completed set refreshed")
	-- abandon 436
	table.remove(W.quests, 2)
	W.Fire("QUEST_REMOVED", 436); W.Advance(3)
	local ab = events("QUEST_ABANDONED")
	eq(#ab, 1); eq(ab[1].payload.questID, 436); eq(ab[1].confidence, "medium")
end)

test("6 First Aid skill-up", function()
	W.Boot()
	W.skills[4].rank = 81
	W.Fire("SKILL_LINES_CHANGED"); W.Advance(1)
	local e = events("PROFESSION_SKILL_UP")
	eq(#e, 1); eq(e[1].payload.skill, "First Aid"); eq(e[1].payload.from, 80); eq(e[1].payload.to, 81)
end)

test("7 zone change", function()
	W.Boot()
	W.zone.zone, W.zone.subzone, W.zone.mapID = "Dun Morogh", "Kharanos", 1426
	W.Fire("ZONE_CHANGED_NEW_AREA")
	eq(C().snapshot.location.mapID, 1426) -- location updates immediately
	eq(#events("ZONE_CHANGED"), 0)        -- event waits for the zone to settle
	W.Advance(21)
	local e = events("ZONE_CHANGED")
	eq(#e, 1); eq(e[1].payload.zone, "Dun Morogh"); eq(e[1].payload.from, "Loch Modan")
end)

test("7b zone border bouncing collapses", function()
	W.Boot(); W.Advance(1)
	local function go(z, m) W.zone.zone, W.zone.mapID = z, m; W.Fire("ZONE_CHANGED_NEW_AREA"); W.Advance(3) end
	-- Loch Modan -> Dun Morogh -> Loch Modan -> Dun Morogh -> Wetlands within seconds
	go("Dun Morogh", 1426); go("Loch Modan", 1432); go("Dun Morogh", 1426); go("Wetlands", 1437)
	W.Advance(25)
	local e = events("ZONE_CHANGED")
	eq(#e, 1); eq(e[1].payload.from, "Loch Modan"); eq(e[1].payload.zone, "Wetlands")
	-- step over the border and straight back: no event at all
	go("Arathi Highlands", 1417); go("Wetlands", 1437); W.Advance(25)
	eq(#events("ZONE_CHANGED"), 1)
end)

test("8 /reload keeps history, no duplicate events, new session ids", function()
	W.Boot()
	W.player.level = 24; W.Fire("PLAYER_LEVEL_UP", 24)
	local before = #events()
	local s1 = ForeverScribe.session
	W.Relog(true)
	local s2 = ForeverScribe.session
	truthy(s1 ~= s2, "new session")
	local ids, types = {}, {}
	for _, e in ipairs(events()) do
		truthy(not ids[e.id], "duplicate id " .. e.id); ids[e.id] = true
		types[e.type] = (types[e.type] or 0) + 1
	end
	eq(#events(), before + 1, "only the new SESSION_START")
	eq(types.LEVEL_UP, 1); eq(types.SESSION_START, 2)
	eq(#C().sessions, 2)
	eq(C().sessions[1].levelEnd, 24)
end)

test("9 relog with Forever SavedVariables load bug: no crash, fresh but valid", function()
	W.Boot()
	W.Relog(false, { svLoadBug = true })
	eq(#events(), 1); eq(events()[1].type, "SESSION_START")
	truthy(C().snapshot.capturedAt)
end)

test("two characters share one account file without mixing", function()
	W.Boot()
	W.player.level = 24; W.Fire("PLAYER_LEVEL_UP", 24)
	W.Relog(false, { beforeBoot = function() W.player.name, W.player.class, W.player.level = "Coilbyte", "WARLOCK", 20 end })
	eq(ForeverScribe.charKey, "Forever-Test:Coilbyte")
	local mage = ForeverScribeDB.chars["Forever-Test:Pixelpop"]
	eq(mage.snapshot.level, 24); eq(mage.snapshot.identity.class, "MAGE")
	eq(C().snapshot.level, 20); eq(C().snapshot.identity.class, "WARLOCK")
	eq(#C().events, 1)
end)

test("secret identity is never stored", function()
	W.secretIdentity = true
	W.Boot()
	eq(ForeverScribe.charKey, "Forever-Test:UnknownCharacter")
	eq(C().snapshot.identity.name, nil); eq(C().snapshot.identity.class, nil)
	eq(C().snapshot.identity.identitySecret, true)
	local text = W.SerializeSV("ForeverScribeDB", ForeverScribeDB) -- would error on a secret table
	truthy(not text:find("<secret>"))
end)

test("missing APIs degrade without errors", function()
	C_TradeSkillUI, C_TaxiMap, C_SpellBook, C_QuestLog = nil, nil, nil, nil
	GetNumTalentTabs = nil
	W.Boot()
	W.Fire("TRADE_SKILL_SHOW"); W.Fire("TAXIMAP_OPENED"); W.Fire("QUEST_LOG_UPDATE"); W.Advance(3)
	truthy(C().snapshot.level == 23)
	eq(ForeverScribe.registered.TRAIT_CONFIG_UPDATED, nil, "unknown event skipped")
end)

test("only CHAT_MSG_SYSTEM is registered; no other chat or whisper event", function()
	W.Boot()
	for ev in pairs(W.Registered()) do
		truthy(not ev:find("^CHAT_MSG") or ev == "CHAT_MSG_SYSTEM", "registered " .. ev)
		truthy(not ev:find("WHISPER"), "registered " .. ev)
	end
	truthy(W.Registered().CHAT_MSG_SYSTEM, "system channel for auction outcomes")
end)

test("merchant sale, gold throttled into one event", function()
	W.Boot()
	W.Fire("MERCHANT_SHOW")
	W.bags[0][2] = nil; bagUpdate()
	for i = 1, 5 do W.player.money = W.player.money + 10; W.Fire("PLAYER_MONEY"); W.Advance(1) end
	W.Fire("MERCHANT_CLOSED"); W.Advance(15)
	local r = events("ITEM_REMOVED")
	eq(#r, 1); eq(r[1].payload.reason, "merchant"); eq(r[1].payload.qty, 7)
	local g = events("GOLD_CHANGED")
	eq(#g, 1); eq(g[1].payload.delta, 50)
end)

test("bank open does not count as acquisition; deposit is a move", function()
	W.Boot()
	W.Fire("BANKFRAME_OPENED"); W.Advance(1)
	W.bags[-1][2] = W.bags[0][2]; W.bags[0][2] = nil; bagUpdate()
	W.Fire("BANKFRAME_CLOSED"); W.Advance(1)
	eq(#events("ITEM_ACQUIRED"), 0); eq(#events("ITEM_REMOVED"), 0)
	eq(C().bank.items[2589].count, 27)
end)

test("Forever bag layout: keyring -1, reagent bag 5, bank tabs 6+", function()
	KEYRING_CONTAINER = -1; BANK_CONTAINER = nil; NUM_BANKBAGSLOTS = nil
	Enum.BagIndex = { Backpack = 0, Keyring = -1, ReagentBag = 5, CharacterBankTab_1 = 6, CharacterBankTab_2 = 7 }
	W.bagSize[5], W.bags[5] = 4, { { itemID = 2589, count = 2 } }  -- reagent bag
	W.bagSize[6], W.bags[6] = 8, { { itemID = 2070, count = 10 } } -- bank tab
	W.bags[-1] = { { itemID = 6948, count = 1 } }                   -- keyring slot
	W.Boot()
	eq(C().snapshot.bags.items[2589].count, 9, "backpack 7 + reagent bag 2")
	W.Fire("BANKFRAME_OPENED"); W.Advance(1)
	eq(C().bank.items[2070].count, 10)
	eq(C().bank.items[2589], nil, "reagent bag not counted as bank")
	W.Fire("BANKFRAME_CLOSED"); W.Advance(1)
	eq(#events("ITEM_ACQUIRED"), 0)
end)

test("recipes and RECIPE_LEARNED", function()
	W.Boot()
	W.trade = { name = "Tailoring", level = 75, max = 150, recipes = {
		[2387] = { name = "Linen Cloak", learned = true, relativeDifficulty = 2, output = 2570 },
		[3915] = { name = "Brown Linen Shirt", learned = true, relativeDifficulty = 1, output = 4344 },
		[2389] = { name = "Red Linen Robe", learned = false } } }
	W.Fire("TRADE_SKILL_SHOW"); W.Advance(2)
	local r = C().recipes.Tailoring
	eq(r.count, 2); eq(r.recipes[3915].difficulty, 1); eq(r.recipes[3915].reagents[1].itemID, 2589)
	W.trade.recipes[2389].learned = true
	W.Fire("NEW_RECIPE_LEARNED", 2389)
	W.Fire("TRADE_SKILL_LIST_UPDATE"); W.Advance(2)
	local e = events("RECIPE_LEARNED")
	eq(#e, 1, "event once, not again from the diff"); eq(e[1].payload.name, "Red Linen Robe")
end)

test("flight paths: first scan is baseline, new node emits", function()
	W.Boot()
	W.Fire("TAXIMAP_OPENED"); W.Advance(1)
	eq(#events("FLIGHT_PATH_LEARNED"), 0)
	eq(C().taxi["Ironforge, Dun Morogh"].baseline, true)
	eq(C().taxi["Menethil Harbor, Wetlands"], nil)
	W.taxi[3].state = 1
	W.Fire("TAXIMAP_OPENED"); W.Advance(1)
	local e = events("FLIGHT_PATH_LEARNED")
	eq(#e, 1); eq(e[1].payload.name, "Menethil Harbor, Wetlands")
end)

test("dungeon: instance enter/exit, boss kill, death", function()
	W.Boot()
	W.zone = { zone = "The Deadmines", subzone = "", mapID = 291, instance = { "The Deadmines", "party", 1, "Normal", 5, 0, false, 36 } }
	W.Fire("PLAYER_ENTERING_WORLD", false, false)
	W.Fire("ENCOUNTER_START", 1144, "Rhahk'Zor", 1, 5)
	W.Advance(30)
	W.Fire("ENCOUNTER_END", 1144, "Rhahk'Zor", 1, 5, 1)
	W.Fire("PLAYER_DEAD")
	W.zone = { zone = "Westfall", subzone = "Moonbrook", mapID = 1436, x = 0.4, y = 0.7, instance = { "Westfall", "none", 0, "", 5, 0, false, 0 } }
	W.Fire("PLAYER_ENTERING_WORLD", false, false)
	eq(events("INSTANCE_ENTERED")[1].payload.name, "The Deadmines")
	local b = events("BOSS_KILLED")[1]
	eq(b.payload.name, "Rhahk'Zor"); eq(b.payload.instance, "The Deadmines"); eq(b.payload.duration, 30)
	eq(#events("DEATH"), 1)
	eq(events("INSTANCE_EXITED")[1].payload.name, "The Deadmines")
end)

test("spell learned (event + spellbook diff do not double count)", function()
	W.Boot()
	table.insert(W.spells, { spellID = 2136, name = "Fire Blast", subName = "Rank 3" })
	W.Fire("LEARNED_SPELL_IN_SKILL_LINE", 2136, 1)
	W.Fire("SPELLS_CHANGED"); W.Advance(3)
	eq(#events("SPELL_LEARNED"), 1)
end)

test("talent change", function()
	W.Boot()
	W.talents[2].talents[2].rank = 1
	W.Fire("CHARACTER_POINTS_CHANGED", -1); W.Advance(2)
	local e = events("TALENT_CHANGED")
	eq(#e, 1); eq(e[1].payload.changes[1].to, 1)
end)

test("event ring buffer is bounded", function()
	W.Boot()
	ForeverScribe.EVENT_CAP = 50
	for i = 1, 200 do W.Fire("PLAYER_DEAD") end
	truthy(#C().events <= 56, "bounded: " .. #C().events)
	truthy((C().dropped or 0) >= 140)
	local last = C().events[#C().events]
	truthy(last.id:match(":201$"), "newest kept " .. last.id)
end)

test("slash status and last", function()
	W.Boot()
	SlashCmdList.FOREVERSCRIBE("status")
	truthy(W.chat[#W.chat - 1]:find("Forever%-Test:Pixelpop"))
	SlashCmdList.FOREVERSCRIBE("last 3")
	truthy(W.chat[#W.chat]:find("SESSION_START"))
end)

test("14 live off: module not loaded, nothing drawn; on: strip encodes events", function()
	W.Boot()
	eq(ForeverScribe.Live, nil, "LOD module not loaded while off")
	eq(_G.ForeverScribeLiveStrip, nil)
	SlashCmdList.FOREVERSCRIBE("live on")
	truthy(ForeverScribe.Live and ForeverScribe.Live.IsEnabled())
	W.player.level = 24; W.Fire("PLAYER_LEVEL_UP", 24); W.Advance(0.2)
	local p = ForeverScribe.Live.lastPayload
	truthy(p and p:find("LEVEL_UP"), "payload has event")
	truthy(_G.ForeverScribeLiveStrip.shown)
	SlashCmdList.FOREVERSCRIBE("live off")
	eq(_G.ForeverScribeLiveStrip.shown, false)
	local frames = ForeverScribe.Live.frames
	W.Fire("PLAYER_DEAD"); W.Advance(1)
	eq(ForeverScribe.Live.frames, frames, "no redraw while off")
	eq(#events("DEATH"), 1, "base addon unaffected")
end)

test("live on with module missing: base addon keeps working", function()
	W.liveMissing = true
	W.Boot()
	SlashCmdList.FOREVERSCRIBE("live on")
	eq(ForeverScribeDB.settings.live, false)
	W.Fire("PLAYER_DEAD")
	eq(#events("DEATH"), 1)
end)


-- v0.2: everything about the character --------------------------------------
local function settle() W.Advance(30) end
local FS = function() return ForeverScribe end

test("v2 baseline captures every section silently and without errors", function()
	W.Boot(); settle()
	local c = C()
	eq(FS().errors or 0, 0, "collector errors: " .. tostring(FS().lastError))
	eq(#events(), 1, "baseline is silent")
	-- reputation
	eq(c.reputation.count, 4); eq(c.reputation.watched, 72)
	local byId = {}; for _, f in ipairs(c.reputation.factions) do byId[f.id] = f end
	eq(byId[72].standing, 5); eq(byId[72].value, 4000); eq(byId[72].group, "Alliance"); eq(byId[15].atWar, true)
	-- Legacy
	eq(c.legacy.trees[1].key, "adventure"); eq(c.legacy.points.unspent, 2); eq(c.legacy.points.maxAvailable, 10)
	eq(c.legacy.track.level, 3); eq(c.legacy.unlocked, true)
	eq(#c.legacy.trees[1].talents, 3, "untaken Legacy nodes included")
	-- achievements / Legacy Challenges + statistics
	local a = c.achievements
	eq(a.total, 3); eq(a.earned, 1); eq(a.earnedAccount, 2); eq(a.points, 15)
	eq(a.list[50001].done, true); eq(a.list[50001].d, "2026-11-12"); eq(a.list[50001].lp, 5)
	eq(a.list[50002].q, "1/2"); eq(a.list[50002].todo[1], "Polymorph a humanoid"); eq(a.list[50002].lp, 10)
	eq(a.list[50003].account, true, "earned by another character counts as not done here")
	eq(c.statistics.values[60001].v, 12); eq(c.statistics.values[60002], nil, "'--' skipped"); eq(c.statistics.count, 2)
	-- exploration
	eq(c.explored.zones[1432].n, 2); eq(c.explored.zones[1432].areas[1], "Thelsamar"); eq(c.explored.zones[1432].continent, "Eastern Kingdoms")
	eq(c.explored.zones[1426].n, 0); eq(c.explored.zonesWithExploration, 1)
	-- titles, collections, currencies
	eq(c.titles.count, 1); eq(c.titles.currentName, "Private %s")
	eq(c.collections.numMounts, 1); eq(c.collections.mounts[11].n, "Black Ram"); eq(c.collections.numPets, 1); eq(c.collections.numToys, 1)
	eq(#c.currencies.list, 2); eq(c.currencies.list[1].name, "Honor Points"); eq(c.currencies.list[1].group, "Player vs. Player")
	-- character sheet + misc
	local s = c.snapshot
	eq(s.stats.health, 640); eq(s.stats.power, 910); eq(s.stats.primary.int.eff, 78); eq(s.stats.spellPowerMax, 28)
	eq(s.stats.resist.frost, 10); eq(s.stats.armor, 230); eq(s.stats.manaRegen.base, 12); eq(s.stats.defense, 115)
	eq(s.buffs[1].n, "Arcane Intellect"); eq(s.buffs[1].self, true)
	eq(s.durability.min, 86); eq(s.guild.name, "Muffin Mafia"); eq(s.guild.rank, "Member")
	eq(s.mode.experiencePreset, "enhanced"); eq(s.pvp.lifetimeHK, 12); eq(s.pvp.flagged, true)
	eq(c.lockouts.list[1].name, "The Deadmines"); eq(c.lockouts.list[1].bosses, "2/6")
	eq(c.questTitles[33], "Collecting Kelp"); eq(c.questTitles[783], "A Threat Within"); eq(c.questTitles[7], nil)
end)

test("v2 talents: every node incl. untaken, groups, unspent; changes carry names", function()
	W.useTraits = true
	W.Boot(); settle()
	local t = C().snapshot.talents
	eq(t.system, "traits"); eq(t.loadout, "Frost leveling"); eq(t.unspent, 1)
	local tree = t.trees[1]
	eq(#tree.talents, 4, "untaken node included")
	eq(tree.talents[3].name, "Permafrost"); eq(tree.talents[3].rank, 0); eq(tree.talents[3].max, 2); eq(tree.talents[3].group, "Frost")
	eq(tree.groups[3].name, "Frost"); eq(tree.groups[3].spent, 8); eq(tree.points, 9)
	W.traitTrees[1112].nodes[3].rank = 1
	W.Fire("CHARACTER_POINTS_CHANGED", -1); W.Advance(2)
	local e = events("TALENT_CHANGED")
	eq(#e, 1); eq(e[1].payload.changes[1].name, "Permafrost"); eq(e[1].payload.changes[1].to, 1); eq(e[1].payload.changes[1].max, 2)
	W.traitTrees[1188].nodes[3].rank = 1
	W.Fire("TRAIT_TREE_CURRENCY_INFO_UPDATED", 1188); W.Advance(2)
	e = events("TALENT_CHANGED")
	eq(#e, 2); eq(e[2].payload.changes[1].legacy, true); eq(e[2].payload.changes[1].tree, "Legacy Adventure")
	eq(e[2].payload.changes[1].name, "Hearty Appetite")
	-- a tree that fails to read is not a refund
	local saved = W.traitTrees[1188]; W.traitTrees[1188] = nil
	W.Fire("CHARACTER_POINTS_CHANGED"); W.Advance(2)
	eq(#events("TALENT_CHANGED"), 2)
	W.traitTrees[1188] = saved
end)

test("v2 reputation: changes aggregate, standing change emits at once, deltas exact", function()
	W.Boot(); settle()
	W.factions[3].currentStanding = 2900; W.Fire("UPDATE_FACTION"); W.Advance(3)
	eq(#events("REPUTATION_CHANGED"), 0, "held in the aggregate window")
	W.factions[3].currentStanding = 3100; W.factions[3].reaction = 5; W.Fire("UPDATE_FACTION"); W.Advance(3)
	local e = events("REPUTATION_CHANGED")
	eq(#e, 1); eq(e[1].payload.name, "Ironforge"); eq(e[1].payload.delta, 600); eq(e[1].payload.standingFrom, 4); eq(e[1].payload.standingTo, 5)
	W.factions[2].currentStanding = 4100; W.Fire("UPDATE_FACTION"); W.Advance(40)
	e = events("REPUTATION_CHANGED")
	eq(#e, 2); eq(e[2].payload.name, "Stormwind"); eq(e[2].payload.delta, 100)
	eq(C().reputation.factions[1].value, 4100)
end)

test("v2 exploration: new area emits EXPLORATION_DISCOVERED with its name", function()
	W.Boot(); settle()
	table.insert(W.explored[1432], { file = 7003, rect = { 400, 500, 0, 100 }, area = 146 })
	W.Fire("MAP_EXPLORATION_UPDATED"); W.Advance(2)
	local e = events("EXPLORATION_DISCOVERED")
	eq(#e, 1); eq(e[1].payload.zone, "Loch Modan"); eq(e[1].payload.areas[1], "Stonewrought Dam"); eq(e[1].payload.explored, 3)
	eq(C().explored.zones[1432].n, 3)
	W.Fire("MAP_EXPLORATION_UPDATED"); W.Advance(2)
	eq(#events("EXPLORATION_DISCOVERED"), 1, "no repeat")
end)

test("v2 achievements, titles, mounts, pets, toys: one event each", function()
	W.Boot(); settle()
	W.achievements[2].done, W.achievements[2].mine = true, true
	W.Fire("ACHIEVEMENT_EARNED", 50002, false); W.Advance(3)
	local a = events("ACHIEVEMENT_EARNED")
	eq(#a, 1); eq(a[1].payload.name, "Polymorph Master"); eq(a[1].payload.legacyPoints, 10)
	eq(C().achievements.list[50002].done, true); eq(C().achievements.list[50002].todo, nil)
	W.titles[2][2] = true; W.Fire("KNOWN_TITLES_UPDATE", "player"); W.Advance(2)
	eq(events("TITLE_EARNED")[1].payload.name, "%s the Explorer")
	W.mounts[12][3] = true; W.Fire("NEW_MOUNT_ADDED", 12); W.Advance(3)
	eq(#events("MOUNT_LEARNED"), 1); eq(events("MOUNT_LEARNED")[1].payload.name, "Swift Mechanostrider")
	W.pets["BattlePet-0-2"] = { 55, "Sprocket", 1, "Lil' Smoky" }; W.Fire("NEW_PET_ADDED", "BattlePet-0-2"); W.Advance(3)
	eq(#events("PET_LEARNED"), 1); eq(events("PET_LEARNED")[1].payload.name, "Lil' Smoky")
	W.toys[17712][2] = true; W.Fire("COMPANION_LEARNED"); W.Advance(3)
	eq(#events("TOY_LEARNED"), 1, "toy found by diff"); eq(events("TOY_LEARNED")[1].payload.name, "Winter Veil Disguise Kit")
	eq(C().collections.numMounts, 2); eq(C().collections.numPets, 2); eq(C().collections.numToys, 2)
end)

test("v2 currency change aggregates into CURRENCY_CHANGED", function()
	W.Boot(); settle()
	W.currencies[2].quantity = 180; W.Fire("CURRENCY_DISPLAY_UPDATE", 1901, 180, 30); W.Advance(4)
	W.currencies[2].quantity = 200; W.Fire("CURRENCY_DISPLAY_UPDATE", 1901, 200, 20); W.Advance(200)
	local e = events("CURRENCY_CHANGED")
	eq(#e, 1); eq(e[1].payload.name, "Honor Points"); eq(e[1].payload.delta, 50); eq(e[1].payload.to, 200)
end)

test("v2 stats refresh after a gear change; durability; buffs", function()
	W.Boot(); settle()
	W.equip[9] = 3647; W.auras = {}
	W.Fire("PLAYER_EQUIPMENT_CHANGED", 9, true); W.Fire("UNIT_AURA", "player"); W.Advance(4)
	truthy(C().snapshot.stats.capturedAt >= W.time - 4)
	eq(#C().snapshot.buffs, 0, "buffs cleared while in world")
end)

test("v2 teardown: an empty read never replaces good data, and relog stays silent", function()
	W.useTraits = true
	W.Boot(); settle()
	local before = {}
	-- 1) reads while leaving the world are skipped outright
	W.teardown = true
	W.Fire("PLAYER_LEAVING_WORLD")
	FS().ScanAll(false); FS().ScanTalents(); FS().SnapshotFull(); W.Advance(30)
	-- 2) a teardown-shaped read that arrives while not flagged is still rejected by each collector's guard
	FS().state.leaving = false
	FS().ScanAll(false); FS().ScanTalents(); FS().ScanStats(); FS().ScanBuffs(); FS().ScanLockouts(); FS().SnapshotFull(); W.Advance(30)
	local c = C()
	eq(c.reputation.count, 4); eq(c.explored.zones[1432].n, 2); eq(c.achievements.total, 3); eq(c.titles.count, 1)
	eq(c.collections.numMounts, 1); eq(#c.currencies.list, 2); eq(c.snapshot.stats.health, 640); eq(#c.snapshot.buffs, 1)
	eq(c.snapshot.talents.system, "traits"); eq(#c.snapshot.talents.trees[1].talents, 4); eq(#c.legacy.trees, 1)
	eq(c.lockouts.list[1].name, "The Deadmines", "unexpired lockout kept"); eq(c.snapshot.guild.name, "Muffin Mafia")
	eq(c.snapshot.durability.min, 86)
	local n = #events()
	local text = W.Relog(false, { beforeBoot = function() W.teardown = false end }); settle()
	truthy(text:find("Defias Brotherhood"), "sections survive the SavedVariables round trip")
	local after = {}
	for i = n + 1, #events() do after[#after + 1] = events()[i].type end
	eq(#after, 1, "only SESSION_START after relog: " .. table.concat(after, ","))
	eq(C().reputation.count, 4); eq(C().achievements.total, 3)
end)

test("v2 mail summary keeps no player-to-player text", function()
	W.Boot(); settle()
	W.Fire("PLAYER_INTERACTION_MANAGER_FRAME_SHOW", 17); W.Advance(2)
	local m = C().mail
	eq(m.count, 2); eq(m.mails[1].from, "Thomas Miller"); eq(m.mails[1].subject, "Your auction sold"); eq(m.mails[1].money, 5000)
	eq(m.mails[2].from, "player"); eq(m.mails[2].subject, nil); eq(m.mails[2].items[1].itemID, 2589); eq(m.mails[2].items[1].count, 20)
	local text = W.SerializeSV("ForeverScribeDB", ForeverScribeDB)
	truthy(not text:find("Fizzwick"), "player sender not stored"); truthy(not text:find("secret plans"), "player subject not stored")
end)

test("v2 recipe cooldowns ride along with the recipe scan", function()
	W.Boot(); settle()
	W.trade = { name = "Tailoring", level = 250, max = 300, recipes = { [18560] = { name = "Mooncloth", learned = true, relativeDifficulty = 1 } } }
	W.recipeCooldowns[18560] = 3600
	W.Fire("TRADE_SKILL_SHOW"); W.Advance(2)
	local cd = C().recipes.Tailoring.cooldowns[18560]
	eq(cd.name, "Mooncloth"); eq(cd.daily, true); truthy(cd.readyAt >= W.time + 3500)
end)

test("v2 missing APIs degrade without errors", function()
	C_Reputation, C_Traits, C_MajorFactions, C_MapExplorationInfo, C_MountJournal, C_PetJournal, C_ToyBox = nil, nil, nil, nil, nil, nil, nil
	C_CurrencyInfo, C_UnitAuras, C_EquipmentSet, C_GameRules, C_ClassTalents = nil, nil, nil, nil, nil
	GetCategoryList, GetStatisticsCategoryList, GetNumTitles, GetNumSavedInstances, UnitStat, UnitHealthMax = nil, nil, nil, nil, nil, nil
	W.Boot(); settle()
	eq(FS().errors or 0, 0, tostring(FS().lastError)); eq(C().snapshot.level, 23)
	eq(C().reputation, nil); eq(C().achievements, nil)
end)

-- v0.3 ----------------------------------------------------------------------

local function sv() return W.SerializeSV("ForeverScribeDB", ForeverScribeDB) end

test("v3 pending mail without opening the mailbox; player senders never stored", function()
	W.Boot(); settle()
	eq(C().mailPending.hasNew, false)
	W.newMail = true; W.mailSenders = { "Stormwind Auction House", "Fizzwick" }
	W.Fire("UPDATE_PENDING_MAIL"); W.Advance(2)
	local m = C().mailPending
	eq(m.hasNew, true); eq(m.senders[1], "Stormwind Auction House"); eq(m.senders[2], "player")
	local e = events("MAIL_PENDING"); eq(#e, 1); eq(e[1].payload.senders[1], "Stormwind Auction House")
	W.Fire("UPDATE_PENDING_MAIL"); W.Advance(2)
	eq(#events("MAIL_PENDING"), 1, "unchanged state does not re-emit")
	truthy(not sv():find("Fizzwick"), "player sender never stored")
end)

test("v3 auction outcomes from the client's format strings (system lines)", function()
	W.Boot(); settle()
	W.Fire("CHAT_MSG_SYSTEM", "A buyer has been found for your auction of Linen Cloth.")
	W.Fire("CHAT_MSG_SYSTEM", "Your auction of Pattern: Silky Gown has expired.")
	W.Fire("CHAT_MSG_SYSTEM", "You have been outbid on Bright Bracers.")
	W.Fire("CHAT_MSG_SYSTEM", "You won an auction for Heavy Linen Bandage")
	W.Fire("CHAT_MSG_SYSTEM", "Auction cancelled.")
	eq(events("AUCTION_SOLD")[1].payload.item, "Linen Cloth"); eq(events("AUCTION_SOLD")[1].source, "system")
	eq(events("AUCTION_EXPIRED")[1].payload.item, "Pattern: Silky Gown")
	eq(events("AUCTION_OUTBID")[1].payload.item, "Bright Bracers")
	eq(events("AUCTION_WON")[1].payload.item, "Heavy Linen Bandage")
	eq(#events("AUCTION_REMOVED"), 1)
end)

test("v3 every other system or chat line is dropped unread", function()
	W.Boot(); settle()
	local before = #C().events
	for _, line in ipairs({ "Fizzwick has come online.", "You are now AFK: secret plans", "Quest accepted: Filthy Paws",
		"A buyer has been found for your auction", "[Trade] Fizzwick: WTS stuff" }) do
		W.Fire("CHAT_MSG_SYSTEM", line, "Fizzwick")
	end
	eq(#C().events, before, "no event from non-auction lines")
	local text = sv()
	truthy(not text:find("Fizzwick"), "no sender kept"); truthy(not text:find("secret plans"), "no text kept")
	truthy(not text:find("online"), "no line kept")
end)

test("v3 auction lines match a non-English client (format strings, not English)", function()
	W.SetStrings({ ERR_AUCTION_SOLD_S = "Ein Käufer für Eure Auktion von %s wurde gefunden." })
	W.Boot(); settle()
	FS().Collect.ResetAuctionPatterns()
	W.Fire("CHAT_MSG_SYSTEM", "A buyer has been found for your auction of Linen Cloth.")
	eq(#events("AUCTION_SOLD"), 0, "English line ignored on a German client")
	W.Fire("CHAT_MSG_SYSTEM", "Ein Käufer für Eure Auktion von Leinenstoff wurde gefunden.")
	eq(events("AUCTION_SOLD")[1].payload.item, "Leinenstoff")
	local pat = FS().Collect.FormatToPattern("Sold %1$s (x%2$d) for 50%%.")
	eq(("Sold Bolt (x3) for 50%."):match(pat), "Bolt")
end)

test("v3 owned auctions (read when the AH is open, never queried) + structured notifications", function()
	W.Boot(); settle()
	W.owned = {
		{ auctionID = 77, itemKey = { itemID = 2589, itemLevel = 1, itemSuffix = 0, battlePetSpeciesID = 0 },
		  itemLink = W.Link(2589), status = 0, quantity = 20, timeLeftSeconds = 40000, timeLeft = 3, bidAmount = nil, buyoutAmount = 9000, bidder = nil },
		{ auctionID = 78, itemKey = { itemID = 6268 }, itemLink = W.Link(6268), status = 1, quantity = 1, buyoutAmount = 12000, bidder = "Fizzwick" },
	}
	W.Fire("AUCTION_HOUSE_SHOW"); W.Advance(3)
	local a = C().auctions
	eq(a.count, 2); eq(a.list[1].itemID, 2589); eq(a.list[1].buyout, 9000); eq(a.list[1].status, "active")
	eq(a.list[2].status, "sold"); eq(a.list[2].hasBidder, true)
	truthy(not sv():find("Fizzwick"), "bidder name never stored")
	-- an empty, not-yet-loaded list never replaces good data
	W.owned, W.ownedFull = {}, false; W.Fire("OWNED_AUCTIONS_UPDATED"); W.Advance(1)
	eq(C().auctions.count, 2)
	W.Fire("AUCTION_HOUSE_CLOSED")
	-- the server notification and the chat line for the same sale give one event, enriched from the owned list
	W.Fire("AUCTION_HOUSE_SHOW_FORMATTED_NOTIFICATION", 4, "Linen Cloth", 77)
	W.Fire("CHAT_MSG_SYSTEM", "A buyer has been found for your auction of Linen Cloth.")
	local s = events("AUCTION_SOLD"); eq(#s, 1); eq(s[1].payload.itemID, 2589); eq(s[1].payload.buyout, 9000); eq(s[1].payload.qty, 20)
	eq(s[1].source, "notification")
	W.Fire("AUCTION_HOUSE_SHOW_NOTIFICATION", 0) -- BidPlaced: not an outcome
	eq(#events("AUCTION_REMOVED") + #events("AUCTION_WON"), 0)
end)

test("v3 auction invoice mail: payout kept, buyer name never stored", function()
	W.Boot(); settle()
	W.invoices[1] = { type = "seller", item = "Linen Cloth", buyer = "Fizzwick", bid = 0, buyout = 9000, deposit = 60, fee = 450, count = 20 }
	W.Fire("PLAYER_INTERACTION_MANAGER_FRAME_SHOW", 17); W.Advance(2)
	local inv = C().mail.mails[1].invoice
	eq(inv.type, "seller"); eq(inv.item, "Linen Cloth"); eq(inv.buyout, 9000); eq(inv.fee, 450); eq(inv.count, 20)
	eq(C().mail.mails[2].invoice, nil, "player mail has no invoice read")
	truthy(not sv():find("Fizzwick"), "buyer never stored")
end)

test("v3 vendor capture on MERCHANT_SHOW: prices, currency costs, stock, usable, known", function()
	W.Boot(); settle()
	W.merchant = { guid = "Creature-0-1-0-1-256735-0000ABCD", name = "Mivin Shadowweave", items = {
		{ id = 253964, name = "Pattern: Silky Gown", price = 0, cost = { { currencyID = 3402, name = "Merchant's Favor", qty = 30 } }, known = true },
		{ id = 2320, name = "Coarse Thread", price = 10, stack = 1 },
		{ id = 6270, name = "Pattern: Blue Linen Vest", price = 200, avail = 1, usable = false },
		{ id = 9999, name = "Barter Thing", price = 500, cost = { { itemID = 2589, name = "Linen Cloth", qty = 5 } } },
	} }
	W.Fire("MERCHANT_SHOW"); W.Advance(1)
	local v = C().vendors.npcs[256735]
	eq(v.name, "Mivin Shadowweave"); eq(v.npcID, 256735); eq(#v.items, 4); eq(C().vendors.last, 256735)
	eq(v.items[1].cost[1].currencyID, 3402); eq(v.items[1].cost[1].qty, 30); eq(v.items[1].known, true)
	eq(v.items[2].price, 10); eq(v.items[2].limited, nil, "unlimited stock")
	eq(v.items[3].limited, 1); eq(v.items[3].usable, false)
	eq(v.items[4].cost[1].itemID, 2589); eq(v.items[4].price, 500)
	W.Fire("MERCHANT_CLOSED")
	W.Fire("MERCHANT_UPDATE"); W.Advance(2) -- closed: no rescan
	eq(#C().vendors.npcs[256735].items, 4)
end)

test("v3 cold tier: addons, keybinds, action bars, macro names (never bodies); stored only on change", function()
	W.Boot(); settle()
	local c = C()
	eq(#c.addons.list, 3); eq(c.addons.list[2].name, "Polestar"); eq(c.addons.list[2].title, "Polestar"); eq(c.addons.list[2].version, "1.4.2")
	eq(c.addons.list[3].enabled, nil); eq(c.addons.list[3].loaded, false)
	eq(#c.bindings.list, 2); eq(c.bindings.list[1].key1, "W"); eq(c.bindings.list[1].key2, "UP")
	eq(c.actionbars.slots[1].name, "Fireball"); eq(c.actionbars.slots[2].name, "Linen Cloth"); eq(c.actionbars.slots[3].name, "Sheep")
	eq(c.macros.account[1], "Mount"); eq(c.macros.character[1], "Sheep")
	local text = sv()
	truthy(not text:find("@focus", 1, true), "macro body never stored"); truthy(not text:find("secret note"), "macro body never stored")
	local at = c.bindings.capturedAt
	W.time = W.time + 100
	W.Fire("UPDATE_BINDINGS"); W.Advance(4)
	eq(C().bindings.capturedAt, at, "unchanged: not rewritten")
	W.bindings[3] = { "TOGGLEBAG", "BINDING_HEADER_INTERFACE", "B" }
	W.Fire("UPDATE_BINDINGS"); W.Advance(4)
	eq(#C().bindings.list, 3); truthy(C().bindings.capturedAt > at)
	W.actions[4] = { "spell", 133 }; W.Fire("ACTIONBAR_SLOT_CHANGED", 4); W.Advance(4)
	eq(C().actionbars.slots[4].type, "spell")
end)

test("v3 save reminder: off by default, one line every N minutes, never calls ReloadUI", function()
	W.Boot(); settle()
	W.time = W.time + 7200; W.Advance(120)
	for _, m in ipairs(W.chat) do truthy(not m:find("no save"), "reminder off by default") end
	ForeverScribe.Slash("remind 30")
	local n0 = #W.chat
	W.combat = true; W.time = W.time + 60; W.Advance(61)
	local hits = 0; for i = n0 + 1, #W.chat do if W.chat[i]:find("no save") then hits = hits + 1 end end
	eq(hits, 0, "quiet in combat")
	W.combat = false; W.time = W.time + 60; W.Advance(61)
	hits = 0; for i = n0 + 1, #W.chat do if W.chat[i]:find("no save") then hits = hits + 1 end end
	eq(hits, 1)
	W.time = W.time + 600; W.Advance(600)
	hits = 0; for i = n0 + 1, #W.chat do if W.chat[i]:find("no save") then hits = hits + 1 end end
	eq(hits, 1, "not again within 30 minutes")
	eq(W.reloads, 0, "ReloadUI never called")
	ForeverScribe.Slash("remind off"); eq(ForeverScribe.ReminderMinutes(), 0)
end)

test("v3 reminder default comes from the installer's Defaults.lua", function()
	ForeverScribe_Defaults = nil
	W.Boot()
	eq(ForeverScribe.ReminderMinutes(), 0)
	ForeverScribe_Defaults = { saveReminderMinutes = 30 }
	eq(ForeverScribe.ReminderMinutes(), 30)
	ForeverScribe.Slash("remind off"); eq(ForeverScribe.ReminderMinutes(), 0, "in-game choice wins")
	ForeverScribe_Defaults = nil
end)

test("v3 addon source never calls ReloadUI, protected AH or buy/sell functions", function()
	for _, f in ipairs({ "Util.lua", "Defaults.lua", "Collect.lua", "Core.lua" }) do
		local fh = assert(io.open(ROOT .. "addon/ForeverScribe/" .. f)); local src = fh:read("*a"); fh:close()
		src = src:gsub("%-%-[^\n]*", "") -- comments may mention them
		for _, bad in ipairs({ "ReloadUI", "QueryOwnedAuctions", "PostItem", "PostCommodity", "PlaceBid", "BuyMerchantItem",
			"UseContainerItem", "SendMail", "SendChatMessage", "CancelAuction", "StartAuction", "TakeInboxMoney", "RunMacro" }) do
			truthy(not src:find(bad, 1, true), f .. " uses " .. bad)
		end
	end
end)

test("v3 missing APIs degrade without errors", function()
	HasNewMail, GetLatestThreeSenders, C_AuctionHouse, GetMerchantNumItems, C_MerchantFrame, C_TooltipInfo = nil, nil, nil, nil, nil, nil
	GetNumBindings, HasAction, GetActionInfo, GetNumMacros, GetInboxInvoiceInfo = nil, nil, nil, nil, nil
	C_AddOns.GetNumAddOns = nil
	W.Boot(); settle()
	W.Fire("UPDATE_PENDING_MAIL"); W.Fire("AUCTION_HOUSE_SHOW"); W.Fire("MERCHANT_SHOW"); W.Fire("UPDATE_BINDINGS"); W.Advance(5)
	W.Fire("PLAYER_INTERACTION_MANAGER_FRAME_SHOW", 17); W.Advance(2)
	eq(FS().errors or 0, 0, tostring(FS().lastError)); eq(C().snapshot.level, 23)
	eq(C().auctions, nil); eq(C().vendors, nil); eq(C().bindings, nil)
end)

local function bigWorld(scale)
	W.factions = {}
	for i = 1, scale.factions do
		if i % 10 == 1 then W.factions[#W.factions + 1] = { name = "Header " .. i, isHeader = true, factionID = 90000 + i } end
		W.factions[#W.factions + 1] = { name = "Faction number " .. i, factionID = 1000 + i, reaction = 4, currentStanding = i * 10, currentReactionThreshold = 0, nextReactionThreshold = 3000 }
	end
	W.achievements, W.achCats = {}, {}
	for c = 1, 30 do W.achCats[c] = 20000 + c; W.achCatInfo[20000 + c] = { "Category " .. c, -1 } end
	for i = 1, scale.achievements do
		local done = i % 3 == 0
		W.achievements[i] = { id = 70000 + i, cat = 20000 + (i % 30) + 1, name = "Legacy challenge with a long name " .. i, points = 10, done = done, mine = done,
			date = done and { 11, 1, 26 } or nil, legacy = 5,
			criteria = (not done) and { { "Defeat the thing number " .. i, i % 2 == 0, 1, 1 }, { "Collect 10 widgets", false, 3, 10 } } or nil }
	end
	W.stats = { [130] = {} }
	for i = 1, scale.stats do W.stats[130][i] = { tostring(i * 7), false, 80000 + i, "Statistic name " .. i } end
	W.zoneTree[1415] = {}
	for z = 1, scale.zones do
		local id = 3000 + z
		W.zoneTree[1415][z] = { mapID = id, name = "Zone " .. z }
		W.explored[id] = {}
		for k = 1, 12 do W.explored[id][k] = { file = id * 100 + k, rect = { k * 50, k * 50 + 40, 0, 40 }, area = id * 100 + k } ; W.areas[id * 100 + k] = "Area " .. z .. "-" .. k end
	end
	W.mounts, W.toys, W.pets = {}, {}, {}
	for i = 1, scale.collect do W.mounts[i] = { "Mount " .. i, 100 + i, true }; W.toys[50000 + i] = { "Toy " .. i, true }; W.pets["BattlePet-" .. i] = { 200 + i, nil, 1, "Pet " .. i } end
	W.completed = {}
	W.questCache = {}
	for q = 1, scale.quests do W.completed[q] = true; W.questCache[q] = "A quest title of average length " .. q end
end

test("v2 size bound: SavedVariables stays bounded at the caps", function()
	local base
	do
		W.Boot(); settle()
		base = #W.SerializeSV("ForeverScribeDB", ForeverScribeDB)
	end
	dofile(ROOT .. "tests/lua/wow_stub.lua"); W.Reset(); W.ROOT = ROOT
	bigWorld({ factions = 60, achievements = 800, stats = 150, zones = 80, collect = 40, quests = 900 })
	W.Boot(); settle(); W.Advance(30)
	local realistic = #W.SerializeSV("ForeverScribeDB", ForeverScribeDB)
	if os.getenv("FS_SIZE_DETAIL") then
		for k, v in pairs(C()) do io.write(string.format("\n  %-14s %7d", k, #W.SerializeSV("x", v))) end
		for k, v in pairs(C().snapshot) do io.write(string.format("\n  snap.%-9s %7d", k, #W.SerializeSV("x", v))) end
	end
	dofile(ROOT .. "tests/lua/wow_stub.lua"); W.Reset(); W.ROOT = ROOT
	bigWorld({ factions = 1000, achievements = 6000, stats = 2000, zones = 400, collect = 3000, quests = 5000 })
	W.Boot(); settle(); W.Advance(60) -- quest-title backfill is paced at 150/s
	local c = C()
	eq(c.reputation.count, 400, "faction cap"); eq(c.achievements.total, 1500, "achievement cap"); eq(c.statistics.count, 500)
	local zones = 0; for _ in pairs(c.explored.zones) do zones = zones + 1 end
	eq(zones, 250, "zone cap"); eq(c.collections.numMounts, 1000)
	local qt = 0; for _ in pairs(c.questTitles) do qt = qt + 1 end
	eq(qt, 3000, "quest title cap")
	local worst = #W.SerializeSV("ForeverScribeDB", ForeverScribeDB)
	print(string.format("\nSV size: v0.1-shaped stub %d B; realistic v0.2 %d B; worst case at caps %d B", base, realistic, worst))
	local f = io.open((os.getenv("TMPDIR") or "/tmp") .. "/foreverscribe-size.txt", "w")
	if f then f:write(string.format("base=%d realistic=%d worst=%d\n", base, realistic, worst)); f:close() end
	truthy(realistic < 400 * 1024, "realistic size " .. realistic)
	truthy(worst < 2048 * 1024, "worst case size " .. worst)
end)

-- Fixture generation for the Python companion tests --------------------------
if FIXTURES then
	dofile(ROOT .. "tests/lua/wow_stub.lua")
	W.Reset(); W.ROOT = ROOT
	W.Boot(); W.Advance(30)
	W.player.level = 24; W.Fire("PLAYER_LEVEL_UP", 24)
	W.loot = { { itemID = 2589, count = 5 } }; W.Fire("LOOT_OPENED"); W.bags[0][2].count = 12; W.Fire("BAG_UPDATE_DELAYED"); W.Fire("LOOT_CLOSED"); W.Advance(1)
	W.skills[4].rank = 81; W.Fire("SKILL_LINES_CHANGED"); W.Advance(1)
	W.Fire("QUEST_TURNED_IN", 307, 1450, 1500); table.remove(W.quests, 2); W.completed[307] = true; W.Fire("QUEST_REMOVED", 307); W.Advance(5)
	W.WriteSV(FIXTURES .. "/sv_v1.lua") -- first /reload
	W.Relog(true)
	W.zone.zone, W.zone.subzone, W.zone.mapID = "Dun Morogh", "Kharanos", 1426; W.Fire("ZONE_CHANGED_NEW_AREA")
	W.bags[1][1] = { itemID = 6268, count = 1 }; W.equip[9] = 3647; W.Fire("PLAYER_EQUIPMENT_CHANGED", 9, true); W.Fire("BAG_UPDATE_DELAYED"); W.Advance(1)
	W.Advance(30) -- v0.2 baseline scans after the reload
	W.factions[3].currentStanding, W.factions[3].reaction = 3100, 5
	W.factions[3].currentReactionThreshold, W.factions[3].nextReactionThreshold = 3000, 9000
	W.Fire("UPDATE_FACTION"); W.Advance(3)
	W.areas[147] = "Kharanos" -- now in Dun Morogh: only the current zone is rescanned
	table.insert(W.explored[1426], { file = 7101, rect = { 0, 100, 0, 100 }, area = 147 }); W.Fire("MAP_EXPLORATION_UPDATED"); W.Advance(2)
	W.Fire("PLAYER_INTERACTION_MANAGER_FRAME_SHOW", 17); W.Advance(2); W.Fire("PLAYER_INTERACTION_MANAGER_FRAME_HIDE", 17)
	-- second character (the Warlock) on the same account
	W.Relog(false, { beforeBoot = function()
		W.player.name, W.player.class, W.player.level = "Coilbyte", "WARLOCK", 20
		W.skills = { { name = "Professions", isHeader = true }, { name = "Mining", skillID = 186, rank = 140, maxRank = 150 }, { name = "Engineering", skillID = 202, rank = 150, maxRank = 150 } }
	end })
	W.skills[2].rank = 141; W.Fire("SKILL_LINES_CHANGED"); W.Advance(1)
	W.WriteSV(FIXTURES .. "/sv_v2.lua")
	-- v0.3 fixture: one character that saw the mailbox flag, the AH, a vendor and the cold tier
	dofile(ROOT .. "tests/lua/wow_stub.lua")
	W.Reset(); W.ROOT = ROOT
	W.Boot(); W.Advance(30)
	W.owned = { { auctionID = 77, itemKey = { itemID = 2589 }, itemLink = W.Link(2589), status = 0, quantity = 20, timeLeftSeconds = 40000, buyoutAmount = 9000 } }
	W.Fire("AUCTION_HOUSE_SHOW"); W.Advance(3); W.Fire("AUCTION_HOUSE_CLOSED")
	W.merchant = { guid = "Creature-0-1-0-1-256735-0000ABCD", name = "Mivin Shadowweave", items = {
		{ id = 253964, name = "Pattern: Silky Gown", price = 0, cost = { { currencyID = 3402, name = "Merchant's Favor", qty = 30 } }, known = true },
		{ id = 2320, name = "Coarse Thread", price = 10 } } }
	W.Fire("MERCHANT_SHOW"); W.Advance(1); W.Fire("MERCHANT_CLOSED")
	W.time = W.time + 600
	W.Fire("AUCTION_HOUSE_SHOW_FORMATTED_NOTIFICATION", 4, "Linen Cloth", 77)
	W.newMail = true; W.mailSenders = { "Stormwind Auction House" }; W.Fire("UPDATE_PENDING_MAIL"); W.Advance(2)
	W.invoices[1] = { type = "seller", item = "Linen Cloth", buyer = "Someone", bid = 0, buyout = 9000, deposit = 60, fee = 450, count = 20 }
	W.Fire("PLAYER_INTERACTION_MANAGER_FRAME_SHOW", 17); W.Advance(2)
	W.WriteSV(FIXTURES .. "/sv_v3.lua")
	print("\nfixtures written to " .. FIXTURES)
end

print(string.format("\n%d passed, %d failed", passed, #failed))
for _, f in ipairs(failed) do print("FAIL " .. f) end
os.exit(#failed == 0 and 0 or 1)

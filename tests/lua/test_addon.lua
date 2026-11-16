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
	for _, f in ipairs({ "Util.lua", "Defaults.lua", "Collect.lua", "Core.lua", "Waypoint.lua", "Npcs.lua", "Route.lua", "Tooltip.lua" }) do
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
-- v0.4 waypoints -------------------------------------------------------------
local function lastChat() return W.chat[#W.chat] or "" end
local function near(a, b, msg) if math.abs(a - b) > 1e-9 then error((msg or "") .. " expected " .. b .. " got " .. tostring(a), 2) end end

test("way: native pin + arrow from x y zone title, case kept", function()
	W.Boot()
	ForeverScribe.Slash("way 52.8 44.8 Stormwind City Shaina Fuller")
	eq(W.waypoint.map, 1453, "zone resolved to the zone, not the same-named micro map"); near(W.waypoint.x, 0.528); near(W.waypoint.y, 0.448)
	eq(W.superTracked, true, "arrow on")
	truthy(lastChat():find("Stormwind City 52.8, 44.8 (Shaina Fuller)", 1, true), lastChat())
	eq(FS and 0 or 0, 0); eq(ForeverScribe.errors or 0, 0, tostring(ForeverScribe.lastError))
end)

test("way: /fs alias, map id, TomTom order, #id, comma coords, current map", function()
	W.Boot()
	eq(SLASH_FOREVERSCRIBE3, "/fs")
	SlashCmdList.FOREVERSCRIBE("way 42.1 65.3 1429 Marshal Dughan"); eq(W.waypoint.map, 1429); near(W.waypoint.x, 0.421)
	SlashCmdList.FOREVERSCRIBE("way Elwynn Forest 30 40 Goldshire"); eq(W.waypoint.map, 1429); near(W.waypoint.y, 0.40)
	SlashCmdList.FOREVERSCRIBE("way #1437 10.5 20.5"); eq(W.waypoint.map, 1437)
	SlashCmdList.FOREVERSCRIBE("way 1436 50 60"); eq(W.waypoint.map, 1436, "bare map id first")
	SlashCmdList.FOREVERSCRIBE("way 45,5 61,5 barrens"); eq(W.waypoint.map, 1413, "prefix + decimal commas"); near(W.waypoint.x, 0.455)
	SlashCmdList.FOREVERSCRIBE("way 45.2, 61.8 wetl"); eq(W.waypoint.map, 1437); near(W.waypoint.y, 0.618)
	SlashCmdList.FOREVERSCRIBE("way 12 34"); eq(W.waypoint.map, 1432, "no zone: the player's map")
	SlashCmdList.FOREVERSCRIBE("WAY 12 34 Loch Modan"); eq(W.waypoint.map, 1432)
end)

test("way: validation refuses bad input and sets nothing", function()
	W.Boot()
	for _, bad in ipairs({ "way 101 20 Elwynn Forest", "way -5 20 Elwynn Forest", "way abc def", "way 50", "way Narnia 10 10", "way 10 10 1" }) do
		W.waypoint = nil
		ForeverScribe.Slash(bad)
		if bad ~= "way 10 10 1" then eq(W.waypoint, nil, bad) end
	end
	W.waypoint = nil
	ForeverScribe.Slash("way stormwind 10 10"); eq(W.waypoint.map, 1453, "unique prefix wins")
	W.waypoint = nil
	ForeverScribe.Slash("way Stormw 10 10"); eq(W.waypoint.map, 1453)
	W.noPins[1458] = true; W.waypoint = nil
	ForeverScribe.Slash("way 50 50 Undercity"); eq(W.waypoint, nil, "map without pins"); truthy(lastChat():find("does not take map pins", 1, true))
	W.pinRule = true
	ForeverScribe.Slash("way 50 50 Elwynn Forest"); eq(W.waypoint, nil, "game rule off"); truthy(lastChat():find("turned off", 1, true), lastChat())
	eq(ForeverScribe.errors or 0, 0, tostring(ForeverScribe.lastError))
end)

test("way: clear, help, status of arrow addons", function()
	W.Boot()
	ForeverScribe.Slash("way 50 50 Westfall"); truthy(W.waypoint)
	ForeverScribe.Slash("way clear"); eq(W.waypoint, nil); eq(W.superTracked, false)
	ForeverScribe.Slash("way"); truthy(lastChat():find("game's own arrow", 1, true), lastChat())
end)

test("way: Polestar loaded -> its Nav API arrow, game pin kept without a second arrow", function()
	W.Boot(); W.FakePolestar()
	ForeverScribe.Slash("way 52.8 44.8 Stormwind City Shaina Fuller")
	local t = W.polestar.target
	eq(t.owner, "ForeverScribe"); eq(t.map, 1453); near(t.x, 0.528); near(t.y, 0.448); eq(t.title, "Shaina Fuller")
	eq(W.waypoint.map, 1453, "map pin still set"); eq(W.superTracked, false, "one arrow: Polestar's")
	truthy(lastChat():find("arrow: Polestar", 1, true), lastChat())
	ForeverScribe.Slash("way clear"); eq(W.polestar.target, nil, "Polestar target released")
	-- a Polestar table without the loaded addon (or a different API version) is ignored
	W.loadedByName.Polestar = false
	ForeverScribe.Slash("way 10 10 Westfall"); eq(W.polestar.target, nil); eq(W.superTracked, true)
	W.loadedByName.Polestar = true; Polestar.Nav.API.version = 2
	ForeverScribe.Slash("way 10 10 Westfall"); eq(W.polestar.target, nil, "unknown API version not called")
end)

test("way: TomTom loaded -> one TomTom waypoint, replaced each time; native mode skips it", function()
	W.Boot(); W.FakeTomTom()
	ForeverScribe.Slash("way 30 40 Elwynn Forest Goldshire")
	eq(W.TomTomCount(), 1); local uid = next(W.tomtom.list)
	eq(uid[1], 1429); near(uid[2], 0.30); near(uid[3], 0.40); eq(uid.title, "Goldshire"); eq(uid.from, "ForeverScribe")
	ForeverScribe.Slash("way 31 41 Elwynn Forest"); eq(W.TomTomCount(), 1, "previous ForeverScribe waypoint removed")
	eq(W.superTracked, false)
	ForeverScribe.Slash("way addon native"); eq(ForeverScribeDB.settings.wayAddon, "native")
	ForeverScribe.Slash("way 32 42 Elwynn Forest"); eq(W.tomtom.n, 2, "native mode: TomTom not called"); eq(W.superTracked, true)
	ForeverScribe.Slash("way addon auto"); eq(ForeverScribeDB.settings.wayAddon, nil)
	-- Polestar's TomTom stand-in (global without the TomTom addon loaded) is not treated as TomTom
	W.loadedByName.TomTom = false
	ForeverScribe.Slash("way 33 43 Elwynn Forest"); eq(W.tomtom.n, 2)
end)

test("way: missing APIs degrade to a message, never an error", function()
	W.Boot()
	C_SuperTrack, UiMapPoint, C_Map.GetMapChildrenInfo, C_Map.CanSetUserWaypointOnMap = nil, nil, nil, nil
	ForeverScribe.Way = ForeverScribe.Way -- module already loaded
	ForeverScribe.Slash("way 50 50 1429")
	eq(W.waypoint.map, 1429, "falls back to a plain UiMapPoint table")
	C_Map.SetUserWaypoint = nil
	ForeverScribe.Slash("way 50 50 1429"); truthy(lastChat():find("could not set", 1, true), lastChat())
	eq(ForeverScribe.errors or 0, 0, tostring(ForeverScribe.lastError))
end)

test("way: source makes no protected or movement calls", function()
	local fh = assert(io.open(ROOT .. "addon/ForeverScribe/Waypoint.lua")); local src = fh:read("*a"); fh:close()
	src = src:gsub("%-%-[^\n]*", "")
	for _, bad in ipairs({ "MoveForward", "TurnLeft", "InteractUnit", "CastSpell", "RunScript", "loadstring", "TargetUnit",
		"SetCVar", "ClickPosition", "CameraOrSelectOrMove", "SendChatMessage", "ReloadUI" }) do
		truthy(not src:find(bad, 1, true), "Waypoint.lua uses " .. bad)
	end
end)


-- v0.5 NPC sightings --------------------------------------------------------
local function npcs() return C().npcs or {} end
local function nkeys() local n = 0 for _ in pairs(npcs()) do n = n + 1 end return n end
local function talk(ev, guid, name, x, y, extra)
	W.zone.x, W.zone.y = x or W.zone.x, y or W.zone.y
	W.units.npc = { guid = guid, name = name, sub = extra and extra.sub, player = extra and extra.player }
	W.Fire(ev, extra and extra.arg)
	W.units.npc = nil
end
local SHAINA = "Creature-0-5250-0-12-2327-00004A3F1C"

test("npcs: gossip records id, name, subtitle, map and the player's spot", function()
	W.Boot()
	W.zone.zone, W.zone.subzone, W.zone.mapID = "Stormwind City", "Cathedral Square", 1453
	talk("GOSSIP_SHOW", SHAINA, "Shaina Fuller", 0.528, 0.448, { sub = "First Aid Trainer" })
	local e = npcs()["2327:1453"]
	truthy(e, "sighting stored under npcID:mapID")
	eq(e.id, 2327); eq(e.name, "Shaina Fuller"); eq(e.sub, "First Aid Trainer"); eq(e.map, 1453)
	near(e.x, 52.8); near(e.y, 44.8); eq(e.n, 1); eq(e.kind, "gossip"); eq(e.zone, "Stormwind City"); eq(e.subzone, "Cathedral Square")
	eq(e.r, 5)
	eq(ForeverScribe.errors or 0, 0, tostring(ForeverScribe.lastError))
end)

test("npcs: one conversation counts once; a later visit within 5 yd merges; a far spot is its own", function()
	W.Boot()
	W.zone.mapID = 1453
	talk("GOSSIP_SHOW", SHAINA, "Shaina Fuller", 0.528, 0.448)
	talk("TRAINER_SHOW", SHAINA, "Shaina Fuller", 0.5281, 0.4481) -- same conversation, next window
	W.Fire("PLAYER_INTERACTION_MANAGER_FRAME_SHOW", 7) -- (no npc unit any more: ignored)
	local e = npcs()["2327:1453"]
	eq(e.n, 1, "several windows of one conversation")
	W.Advance(120)
	talk("GOSSIP_SHOW", SHAINA, "Shaina Fuller", 0.5300, 0.4500) -- ~4 yd away (1737 x 1158 yd map)
	eq(#e.spots, 1); eq(e.n, 2); truthy(e.x > 52.8 and e.x < 53.0, "running mean " .. e.x)
	W.Advance(120)
	talk("GOSSIP_SHOW", SHAINA, "Shaina Fuller", 0.60, 0.50)
	eq(#e.spots, 2, "far spot kept separately"); eq(e.n, 3)
	near(e.x, e.spots[1].x, "best spot = most sightings")
	eq(nkeys(), 1)
end)

test("npcs: secret GUIDs, players, pets and objects are never stored", function()
	W.Boot()
	talk("GOSSIP_SHOW", W.Secret(), "Hidden")
	talk("GOSSIP_SHOW", "Player-5250-0A1B2C3D", "Someone", nil, nil, { player = true })
	talk("GOSSIP_SHOW", "Player-5250-0A1B2C3D", "Someone")
	talk("GOSSIP_SHOW", "Pet-0-5250-0-12-416-0100000001", "Imp")
	W.units.target = { guid = "Creature-0-1-0-1-31216-00000001", name = "Mirror Image", sub = "Someone's Minion", friend = true, dist = 3, controlled = true }
	W.Fire("PLAYER_TARGET_CHANGED"); W.units.target = nil
	talk("GOSSIP_SHOW", "GameObject-0-5250-0-12-1731-0000000001", "Copper Vein")
	eq(nkeys(), 0)
	truthy(ForeverScribe.Npcs.skipped.secret >= 1, "secret counted")
	eq(ForeverScribe.Npcs.ParseGUID("Creature-0-1-0-1-2327-00000000"), 2327)
	eq(ForeverScribe.Npcs.ParseGUID("Vehicle-0-1-0-1-2327-00000000"), nil)
	W.zone.x = nil -- no position (instance): skip
	talk("GOSSIP_SHOW", SHAINA, "Shaina Fuller")
	eq(nkeys(), 0, "no position, no sighting")
	eq(ForeverScribe.errors or 0, 0, tostring(ForeverScribe.lastError))
end)

test("npcs: secret name or position values are dropped", function()
	W.Boot()
	W.units.npc = { guid = SHAINA, name = W.Secret() }
	W.Fire("MERCHANT_SHOW")
	local e = npcs()["2327:1432"]
	truthy(e, "id and spot are enough"); eq(e.name, nil)
	W.units.npc = nil
	local pos = C_Map.GetPlayerMapPosition
	C_Map.GetPlayerMapPosition = function() return { x = W.Secret(), y = W.Secret() } end
	W.units.npc = { guid = "Creature-0-1-0-1-240-00000000", name = "Marshal Dughan" }
	W.Fire("QUEST_DETAIL")
	C_Map.GetPlayerMapPosition = pos
	eq(npcs()["240:1432"], nil, "secret position: skipped")
	-- the whole record survives a /reload as plain SavedVariables data
	W.Relog(true)
	truthy(C().npcs["2327:1432"], "kept across /reload")
end)

test("npcs: every NPC window event and the interaction manager record", function()
	W.Boot()
	local evs = { "GOSSIP_SHOW", "MERCHANT_SHOW", "TRAINER_SHOW", "QUEST_DETAIL", "QUEST_GREETING", "QUEST_PROGRESS",
		"QUEST_COMPLETE", "TAXIMAP_OPENED", "BANKFRAME_OPENED", "AUCTION_HOUSE_SHOW" }
	for i, ev in ipairs(evs) do talk(ev, "Creature-0-1-0-1-" .. (1000 + i) .. "-00000000", "N" .. i) end
	talk("PLAYER_INTERACTION_MANAGER_FRAME_SHOW", "Creature-0-1-0-1-2000-00000000", "Innkeeper", nil, nil, { arg = 20 })
	talk("PLAYER_INTERACTION_MANAGER_FRAME_SHOW", "Creature-0-1-0-1-2001-00000000", "Mailbox?", nil, nil, { arg = 17 })
	eq(nkeys(), #evs + 1, "mail interaction ignored")
	eq(npcs()["1008:1432"].kind, "flightmaster"); eq(npcs()["2000:1432"].kind, "innkeeper")
	local reg = W.Registered()
	for _, ev in ipairs(evs) do truthy(reg[ev], ev .. " registered") end
	truthy(reg.PLAYER_TARGET_CHANGED)
end)

test("npcs: friendly NPC targeted within 10 yd, out of combat; never far, hostile, players or secret ranges", function()
	W.Boot()
	local function target(u) W.units.target = u; W.Fire("PLAYER_TARGET_CHANGED"); W.units.target = nil end
	target({ guid = "Creature-0-1-0-1-300-00000000", name = "Guard", friend = true, dist = 30 })
	target({ guid = "Creature-0-1-0-1-301-00000000", name = "Wolf", friend = false, dist = 5 })
	target({ guid = "Player-1-00000001", name = "Ally", friend = true, player = true, dist = 5 })
	target({ guid = "Creature-0-1-0-1-302-00000000", name = "Guard", friend = true, secretDist = true })
	W.combat = true
	target({ guid = "Creature-0-1-0-1-303-00000000", name = "Guard", friend = true, dist = 5 })
	W.combat = false
	eq(nkeys(), 0)
	target({ guid = "Creature-0-1-0-1-304-00000000", name = "Guard", friend = true, dist = 5 })
	eq(npcs()["304:1432"].kind, "target"); eq(npcs()["304:1432"].r, 10)
	-- a later window conversation upgrades the kind and radius
	W.Advance(60)
	talk("GOSSIP_SHOW", "Creature-0-1-0-1-304-00000000", "Guard")
	eq(npcs()["304:1432"].kind, "gossip"); eq(npcs()["304:1432"].r, 5)
	ForeverScribe.Slash("npcs target off")
	target({ guid = "Creature-0-1-0-1-305-00000000", name = "Guard", friend = true, dist = 5 })
	eq(npcs()["305:1432"], nil, "targeting off")
	truthy(lastChat():find("1 NPC sightings", 1, true), lastChat())
end)

test("npcs: the table is capped, oldest sightings dropped; spots per NPC capped", function()
	W.Boot()
	local N = ForeverScribe.Npcs
	local store = {}
	local flat = function() return 0 end
	for i = 1, 30 do N.Merge(store, { id = i, map = 1, x = 1, y = 1, kind = "gossip" }, 1000 + i, flat) end
	eq(N.Trim(store, 20), 10); truthy(store[30 .. ":1"] and not store["1:1"], "newest kept")
	local far = function(_, x1, y1, x2, y2) return math.abs(x1 - x2) * 100 end
	for i = 1, 8 do N.Merge(store, { id = 99, map = 1, x = i * 10, y = 1, kind = "gossip" }, 5000 + i * 60, far) end
	eq(#store["99:1"].spots, N.MAX_SPOTS); eq(store["99:1"].n, 8)
end)

-- v0.5 routes ---------------------------------------------------------------
local function slotDir()
	local d = os.tmpname() .. "_slots"
	os.remove(d:gsub("_slots$", ""))
	for i = 1, 10 do os.execute(string.format("mkdir -p '%s/ForeverScribe_Route%02d'", d, i)) end
	return d
end
local function writeSlots(d, body, only)
	for i = 1, 10 do
		if not only or only == i then
			local f = assert(io.open(string.format("%s/ForeverScribe_Route%02d/Route.lua", d, i), "w")); f:write(body); f:close()
		end
	end
end
local function routeLua(rev, stops)
	local out = { "-- ForeverScribe route (written by the companion; data only). rev=" .. rev, "ForeverScribe_RouteData = {",
		"v = 1,", 'rev = "' .. rev .. '",', 'name = "Errands",', "created = 1763250000,", "stops = {" }
	for _, s in ipairs(stops) do
		out[#out + 1] = string.format('{ map = %d, x = %s, y = %s, r = %d, title = "%s" },', s[1], s[2], s[3], s[5] or 15, s[4])
	end
	out[#out + 1] = "},"; out[#out + 1] = "}"
	return table.concat(out, "\n") .. "\n"
end
local STOPS = { { 1453, 52.8, 44.8, "Shaina Fuller" }, { 1453, 60, 50, "Bank" }, { 1453, 40, 70, "Flight master" } }

test("route: /fs go with nothing written says so; the empty slot is used up", function()
	local d = slotDir(); W.slotDir = d
	writeSlots(d, "-- empty\nForeverScribe_RouteData = nil\n")
	W.Boot()
	ForeverScribe.Slash("go")
	truthy(lastChat():find("route file is empty", 1, true), lastChat())
	eq(W.slotsLoaded.ForeverScribe_Route01, true)
	eq(ForeverScribe.errors or 0, 0, tostring(ForeverScribe.lastError))
end)

test("route: a rewritten slot loads in-session; stops advance on arrival, /fs next, done clears", function()
	local d = slotDir(); W.slotDir = d
	writeSlots(d, "ForeverScribe_RouteData = nil\n")
	W.Boot()
	W.zone.mapID, W.zone.x, W.zone.y = 1453, 0.10, 0.10
	ForeverScribe.Slash("go") -- slot 1: empty
	writeSlots(d, routeLua("r1", STOPS)) -- the companion writes while the game runs
	ForeverScribe.Slash("go") -- slot 2 reads the new file
	local r = ForeverScribeDB.route
	truthy(r and r.rev == "r1", "route stored in SavedVariables"); eq(#r.stops, 3); eq(r.i, 1)
	eq(W.waypoint.map, 1453); near(W.waypoint.x, 0.528); eq(W.superTracked, true)
	eq(W.ActiveTickers(), 1, "one distance ticker")
	W.Advance(3); eq(r.i, 1, "far away: still stop 1")
	W.zone.x, W.zone.y = 0.5285, 0.4485 -- ~1 yd from stop 1
	W.Advance(1.5)
	eq(r.i, 2, "arrived at stop 1 -> stop 2"); near(W.waypoint.x, 0.60)
	ForeverScribe.Slash("next"); eq(r.i, 3); near(W.waypoint.y, 0.70)
	ForeverScribe.Slash("back"); eq(r.i, 2); ForeverScribe.Slash("next")
	W.zone.x, W.zone.y = 0.40, 0.70
	W.Advance(1.5)
	truthy(r.done, "last stop reached"); eq(W.waypoint, nil, "pin cleared"); eq(W.ActiveTickers(), 0, "ticker stopped")
	truthy(table.concat(W.chat, "\n"):find("route Errands done", 1, true))
	ForeverScribe.Slash("route")
	truthy(lastChat():find("x 3. Flight master", 1, true), lastChat())
	eq(ForeverScribe.errors or 0, 0, tostring(ForeverScribe.lastError))
end)

test("route: same rev keeps progress; slots run out until /reload; progress survives /reload", function()
	local d = slotDir(); W.slotDir = d
	writeSlots(d, routeLua("r2", STOPS))
	W.Boot()
	W.zone.mapID, W.zone.x, W.zone.y = 1453, 0.10, 0.10
	ForeverScribe.Slash("go"); ForeverScribe.Slash("next")
	eq(ForeverScribeDB.route.i, 2)
	ForeverScribe.Slash("go")
	truthy(lastChat():find("stop 2/3", 1, true) or table.concat(W.chat, "\n"):find("same route as before; stop 2/3", 1, true))
	eq(ForeverScribeDB.route.i, 2, "same route: progress kept")
	for _ = 3, 10 do ForeverScribe.Slash("go") end
	ForeverScribe.Slash("go")
	truthy(table.concat(W.chat, "\n"):find("all 10 route slots were used this session; /reload frees them", 1, true))
	eq(ForeverScribeDB.route.i, 2)
	W.Relog(true)
	eq(ForeverScribeDB.route.i, 2, "saved across /reload")
	W.Advance(5)
	eq(W.waypoint and W.waypoint.map, 1453, "current stop back on the map after /reload"); near(W.waypoint.x, 0.60)
	writeSlots(d, routeLua("r3", { { 1429, 42.2, 65.8, "Marshal Dughan" } }))
	ForeverScribe.Slash("go")
	eq(ForeverScribeDB.route.rev, "r3", "slots free again after /reload"); eq(ForeverScribeDB.route.i, 1)
	ForeverScribe.Slash("route clear"); eq(ForeverScribeDB.route, nil); eq(W.waypoint, nil)
end)

test("route: bad data, missing slots and other maps", function()
	local d = slotDir(); W.slotDir = d
	writeSlots(d, routeLua("bad", { { 1453, 150, 20, "Nowhere" } }))
	W.Boot()
	ForeverScribe.Slash("go")
	truthy(lastChat():find("stop 1 is not a valid map position", 1, true), lastChat())
	eq(ForeverScribeDB.route, nil)
	local R = ForeverScribe.Route
	eq(R.Validate({ v = 2, rev = "x", stops = {} }), nil)
	eq(R.Validate({ v = 1, rev = "x y", stops = { { map = 1, x = 1, y = 1 } } }), nil, "rev charset")
	local ok = R.Validate({ v = 1, rev = "x", name = 'a|cffff0000"b', stops = { { map = 1453, x = 1, y = 2, r = 1, title = "T|r" } } })
	eq(ok.name, "acffff0000b"); eq(ok.stops[1].r, 3); eq(ok.stops[1].title, "Tr")
	-- player on another map: no distance, no advance
	writeSlots(d, routeLua("r4", { { 1429, 50, 50, "Goldshire" }, { 1429, 10, 10, "B" } }))
	W.zone.mapID, W.zone.strictMap = 1453, true
	ForeverScribe.Slash("go")
	W.Advance(5); eq(ForeverScribeDB.route.i, 1)
	W.zone.posOn = { [1429] = { 0.5, 0.5 } }
	W.Advance(1.5); eq(ForeverScribeDB.route.i, 2, "arrives via the stop's own map position")
	-- slots not installed
	W.slotCount = 0
	W.Relog(true)
	ForeverScribe.Slash("go")
	truthy(table.concat(W.chat, "\n"):find("route slots are missing or disabled", 1, true))
	eq(ForeverScribe.errors or 0, 0, tostring(ForeverScribe.lastError))
end)

test("route + npcs: read-only source (no input automation, reload, chat sends or protected calls)", function()
	for _, f in ipairs({ "Npcs.lua", "Route.lua", "Bindings.xml" }) do
		local src = assert(io.open(ROOT .. "addon/ForeverScribe/" .. f)):read("*a"):gsub("%-%-[^\n]*", "")
		for _, bad in ipairs({ "MoveForward", "TurnLeft", "InteractUnit", "CastSpell", "RunScript", "loadstring", "TargetUnit",
			"SetCVar", "ClickPosition", "CameraOrSelectOrMove", "SendChatMessage", "ReloadUI", "BuyMerchantItem", "PlaceBid" }) do
			truthy(not src:find(bad, 1, true), f .. " uses " .. bad)
		end
	end
	for i = 1, 10 do
		local n = string.format("ForeverScribe_Route%02d", i)
		local toc = assert(io.open(ROOT .. "addon/" .. n .. "/" .. n .. ".toc")):read("*a")
		truthy(toc:find("## LoadOnDemand: 1", 1, true) and toc:find("## Dependencies: ForeverScribe", 1, true), n)
		truthy(toc:find("## Interface: 16001", 1, true), n .. " interface")
		local body = assert(io.open(ROOT .. "addon/" .. n .. "/Route.lua")):read("*a")
		truthy(body:find("ForeverScribe_RouteData = nil", 1, true), n .. " ships empty")
	end
end)



---------------------------------------------------------------------------
-- v0.6 AH price tooltip (tests/lua/wow_stub_tip.lua simulates the item tooltip)
---------------------------------------------------------------------------
local function FS() return ForeverScribe end
local function tip(iid, opts) W.Hover(iid, opts); return W.TipText(opts and opts.tip) end
local function has(lines, s) for _, l in ipairs(lines) do if l == s then return true end end return false end
local function show(lines) return "\n  " .. table.concat(lines, "\n  ") end
local function withRecipes()
	C().recipes = { Tailoring = { count = 3, scannedAt = W.time, recipes = {
		[1] = { name = "Silky Gown", reagents = { { itemID = 4305, qty = 12 } } },
		[2] = { name = "Silky Leggings", reagents = { { itemID = 4305, qty = 14 }, { itemID = 4291, qty = 2 } } },
		[3] = { name = "Azure Silk Hood", reagents = { { itemID = 4305, qty = 2 } } } } } }
end

test("v6 tooltip default: header with market + age, typical price, stack worth, shift hint; nothing else", function()
	W.Prices(); W.Boot()
	eq(FS().Tooltip.hooked, "TooltipDataProcessor")
	local l = tip(4305)
	local want = { "Auction House | PvP Alliance · 14m ago", "Typical price | 8s 68c", "Your 12 are worth | 1g 4s 16c", "Hold Shift for details" }
	eq(#l, #want, show(l))
	for i, w in ipairs(want) do eq(l[i], w, show(l)) end
	eq(FS().errors or 0, 0, tostring(FS().lastError))
end)

test("v6 tooltip with Shift: listings, 7/30-day with trend, other faction, sell-or-vendor, used in", function()
	W.Prices(); W.Boot(); withRecipes(); W.shift = true
	local l = tip(4305)
	for _, w in ipairs({ "Typical price | 8s 68c", "Your 12 are worth | 1g 4s 16c", "Cheapest listing | 8s 49c", "Listed right now | 585",
		"7-day typical | 8s 79c", "30-day typical | 9s 32c  ▼ 7%", "Horde side | 8s 30c", "Sell here or vendor? | AH +45% vs vendor",
		"Used in | Azure Silk Hood (2) · Silky Gown (12) · …" }) do
		truthy(has(l, w), "missing '" .. w .. "'" .. show(l))
	end
	truthy(not has(l, "Hold Shift for details"), show(l))
	-- rising price: green up arrow; a single owned item reads "Yours is worth"
	W.bags[0][6] = { itemID = 5000, count = 1 }
	l = tip(5000)
	truthy(has(l, "30-day typical | 77s 46c  ▲ 27%"), show(l)); truthy(has(l, "Yours is worth | 98s"), show(l))
	eq(FS().errors or 0, 0, tostring(FS().lastError))
end)

test("v6 tooltip never shows a vendor price line, known/unknown recipe or an upgrade verdict", function()
	W.Prices(); W.Boot(); withRecipes()
	for _, shift in ipairs({ false, true }) do
		W.shift = shift
		for _, iid in ipairs({ 4305, 10302, 10303, 5000 }) do
			for _, line in ipairs(tip(iid)) do
				local low = line:lower()
				truthy(not low:find("vendor price", 1, true) and not low:find("sell price", 1, true) and not low:find("sells to vendor", 1, true), line)
				truthy(not low:find("known", 1, true) and not low:find("upgrade", 1, true) and not low:find("for you", 1, true), line)
			end
		end
	end
end)

test("v6 tooltip on a pattern: typical, crafted item sells for, materials cost", function()
	W.Prices(); W.Boot()
	local l = tip(10302)
	local want = { "Auction House | PvP Alliance · 14m ago", "Typical price | 1g 25s", "Crafted item sells for | 2g 10s",
		"Materials cost | 27s 4c + 1 not on AH", "Hold Shift for trend & supply" }
	eq(#l, #want, show(l))
	for i, w in ipairs(want) do eq(l[i], w, show(l)) end
	W.shift = true
	l = tip(10302)
	truthy(has(l, "Listed right now | 3"), show(l)); truthy(has(l, "30-day typical | 1g 18s  ▲ 6%"), show(l))
	truthy(not has(l, "Hold Shift for trend & supply"), show(l))
end)

test("v6 tooltip on soulbound / quest items and items without data: a dash and the reason", function()
	W.Prices(); W.Boot()
	local l = tip(2804, { soulbound = true })
	eq(#l, 3, show(l)); eq(l[1], "Auction House | PvP Alliance"); eq(l[2], "Typical price | —"); eq(l[3], "Soulbound · can't be listed")
	l = tip(7000)
	eq(l[2], "Typical price | —", show(l)); eq(l[3], "Quest item · can't be listed")
	W.items[5001] = { name = "Unlisted Thing", quality = 1, sell = 10 }
	l = tip(5001)
	eq(#l, 3, show(l)); eq(l[1], "Auction House | PvP Alliance · 14m ago"); eq(l[2], "Typical price | —"); eq(l[3], "No recent listings")
	eq(FS().errors or 0, 0, tostring(FS().lastError))
end)

test("v6 typical price uses the large font; the tooltip's fonts are restored when it clears", function()
	W.Prices(); W.Boot()
	tip(4305)
	local n
	for i, line in ipairs(GameTooltip.lines) do if line.left == "Typical price" then n = i end end
	eq(_G["GameTooltipTextLeft" .. n].font, "GameTooltipHeaderText"); eq(_G["GameTooltipTextRight" .. n].font, "GameTooltipHeaderText")
	eq(_G["GameTooltipTextLeft" .. (n + 1)].font, "GameTooltipText")
	GameTooltip:ClearLines()
	eq(_G["GameTooltipTextLeft" .. n].font, "GameTooltipText")
end)

test("v6 tooltip lines go in once per tooltip build; Shift re-asks only tooltips nobody refreshes", function()
	W.Prices(); W.Boot()
	tip(4305)
	local n = GameTooltip:NumLines()
	for _, pc in ipairs(W.postCalls) do pc[2](GameTooltip, { type = 0, id = 4305, lines = {} }) end
	eq(GameTooltip:NumLines(), n, "second post-call in the same build adds nothing")
	W.shift = true; W.Fire("MODIFIER_STATE_CHANGED", "LSHIFT", 1)
	eq(W.refreshes, 1); truthy(has(W.TipText(), "Cheapest listing | 8s 49c"))
	W.shift = false; W.Fire("MODIFIER_STATE_CHANGED", "LSHIFT", 0)
	eq(W.refreshes, 2); truthy(has(W.TipText(), "Hold Shift for details"))
	-- a bag slot refreshes its own tooltip every 0.2 s: we leave it alone
	tip(4305, { owner = { UpdateTooltip = function() end } })
	W.shift = true; W.Fire("MODIFIER_STATE_CHANGED", "LSHIFT", 1)
	eq(W.refreshes, 2)
	-- other keys and combat: never
	W.Fire("MODIFIER_STATE_CHANGED", "LCTRL", 1); eq(W.refreshes, 2)
	W.combat = true; tip(4305); W.shift = false; W.Fire("MODIFIER_STATE_CHANGED", "LSHIFT", 0); eq(W.refreshes, 2)
	-- a hidden or cleared tooltip is never touched
	W.combat = false; GameTooltip:Hide(); W.shift = true; W.Fire("MODIFIER_STATE_CHANGED", "LSHIFT", 1); eq(W.refreshes, 2)
end)

test("v6 /scribe tooltip on|off|shift is saved and respected", function()
	W.Prices(); W.Boot()
	SlashCmdList.FOREVERSCRIBE("tooltip off")
	eq(ForeverScribeDB.settings.tooltip, "off"); eq(#tip(4305), 0)
	truthy(W.chat[#W.chat - 1]:find("AH price tooltip off", 1, true), W.chat[#W.chat - 1])
	SlashCmdList.FOREVERSCRIBE("tooltip shift")
	eq(#tip(4305), 0, "shift mode: nothing without Shift")
	W.shift = true; truthy(has(tip(4305), "Cheapest listing | 8s 49c"))
	SlashCmdList.FOREVERSCRIBE("tooltip on"); W.shift = false
	truthy(has(tip(4305), "Hold Shift for details"))
	SlashCmdList.FOREVERSCRIBE("tooltip")
	truthy(W.chat[#W.chat]:find("PvP Alliance, 6 items, scan 14m ago", 1, true), W.chat[#W.chat])
end)

test("v6 price file loader: missing, wrong format, too big, bad rows are refused without errors", function()
	W.Boot()
	eq(#tip(4305), 0, "no price file: tooltip untouched")
	eq(FS().Tooltip.loadError, "no price file")
	SlashCmdList.FOREVERSCRIBE("tooltip")
	truthy(W.chat[#W.chat]:find("no prices loaded", 1, true), W.chat[#W.chat])
	local T = FS().Tooltip
	eq(T.Load({ v = 2, captured = 1, d = {} }), false); truthy(T.loadError:find("format 2", 1, true))
	eq(T.Load({ v = 1, d = {} }), false); eq(T.loadError, "price file without a scan time")
	eq(T.Load("x"), false); eq(T.loadError, "bad price file")
	local big = { v = 1, captured = 1, d = {} }
	for i = 1, T.MAX_ITEMS + 1 do big.d[i] = "1" end
	eq(T.Load(big), false); truthy(T.loadError:find("too big", 1, true))
	big.d[T.MAX_ITEMS + 1] = nil
	eq(T.Load(big), true, tostring(T.loadError))
	-- damaged rows are skipped, not fatal
	eq(T.Load({ v = 1, captured = 1, d = { [1] = "", [2] = ",,,", [3] = string.rep("9", 200), [4] = "5" }, p = { [4] = "garbage" } }), true)
	eq(T.Row(1), nil); eq(T.Row(2), nil); eq(T.Row(3), nil); eq(T.Row(4).median, 5); eq(T.Recipe(4), nil)
	eq(FS().errors or 0, 0, tostring(FS().lastError))
end)

test("v6 OnTooltipSetItem fallback when the client has no TooltipDataProcessor", function()
	W.tipAPI = "script"; W.Prices(); W.Boot()
	eq(FS().Tooltip.hooked, "OnTooltipSetItem")
	truthy(has(tip(4305), "Typical price | 8s 68c"))
	truthy(has(tip(4305, { tip = ItemRefTooltip }), "Typical price | 8s 68c"))
end)

test("v6 tooltip: secret or missing pieces degrade silently", function()
	W.Prices(); W.Boot()
	for _, pc in ipairs(W.postCalls) do pc[2](GameTooltip, { type = 0, id = W.Secret(), lines = { W.Secret() } }) end
	C_Item.GetItemCount, GetMoneyString = nil, nil
	local l = tip(4305)
	truthy(has(l, "Typical price | 8s 68c"), show(l)) -- plain g/s/c fallback reads the same after stripping
	truthy(not has(l, "Your 12 are worth | 1g 4s 16c"))
	eq(FS().errors or 0, 0, tostring(FS().lastError))
	-- a client with neither hook nor tooltip
	dofile(ROOT .. "tests/lua/wow_stub.lua"); W.Reset(); W.ROOT = ROOT
	TooltipDataProcessor, GameTooltip, ItemRefTooltip = nil, nil, nil
	W.Prices(); W.Boot()
	eq(FS().errors or 0, 0, tostring(FS().lastError)); eq(C().snapshot.level, 23)
end)

-- v0.7 Polestar guide reader --------------------------------------------------
local function pol() return C().snapshot.polestar end

test("guide: Polestar loaded -> current guide, step N/M, open goals and travel target kept for the agent", function()
	W.FakePolestarGuide() -- an OptionalDep: loaded before ForeverScribe
	W.polestar.liveTarget = { map = 1436, x = 0.565, y = 0.329, title = "Gryan Stoutmantle", kind = "turnin",
		next = { map = 1436, x = 0.5, y = 0.4, title = "Fly to Sentinel Hill", kind = "taxi" } }
	W.Boot(); W.Advance(5)
	local p = pol()
	truthy(p, "captured after login"); eq(p.v, 1); eq(p.version, "0.4.0.1")
	eq(p.active, 1); eq(p.tabs[1].id, "forever/alliance/02-westfall"); eq(p.tabs[1].title, "Westfall")
	eq(p.tabs[1].number, 11); eq(p.tabs[1].total, 70); eq(p.tabs[1].step, 12); eq(p.tabs[1].done, 10)
	eq(p.step.title, "Sentinel Hill"); eq(#p.step.goals, 2, "a goal that is not for this character is left out")
	eq(p.step.goals[1].text, "Hand in The People's Militia", "colour codes stripped")
	eq(p.step.goals[2].cur, 3); eq(p.step.goals[2].max, 15)
	eq(p.target.map, 1436); eq(p.target.x, 56.5); eq(p.target.title, "Gryan Stoutmantle"); eq(p.target.next.kind, "taxi")
	truthy(table.concat(W.polestar.calls, ","):find("GetStepView:true", 1, true), "the shared read-only view")
	-- a step change: Polestar's message, read once after it settles
	W.polestar.tabs[1].stepIndex, W.polestar.tabs[1].stepNumber = 13, 12
	W.polestar.views[13] = { index = 13, title = "The Jangolode Mine", goals = { { t = "collect", text = "Collect 10 Ore", status = "open" } } }
	W.PolestarFire("TABS_CHANGED", W.polestar.tabs, 1); W.PolestarFire("STEP_CHANGED", 13)
	W.Advance(3)
	eq(pol().step.title, "The Jangolode Mine"); eq(pol().tabs[1].number, 12)
	ForeverScribe.Slash("guide")
	truthy(lastChat():find("Westfall step 12/70", 1, true), lastChat())
	eq(ForeverScribe.errors or 0, 0, tostring(ForeverScribe.lastError))
end)

test("guide: without Polestar (or another API version) nothing is read and nothing breaks", function()
	W.Boot(); W.Advance(12)
	eq(pol(), nil)
	ForeverScribe.Slash("guide"); truthy(lastChat():find("Polestar isn't loaded", 1, true), lastChat())
	W.FakePolestarGuide(); Polestar.API.version = 2
	eq(ForeverScribe.Guide.Capture(), nil, "unknown API version not read")
	Polestar.API.version = 1; Polestar.Engine.GetStepView = function() error("changed shape") end
	local p = ForeverScribe.Guide.Capture()
	truthy(p and p.tabs[1].title == "Westfall" and p.step == nil, "a failing call only leaves its part out")
	W.polestar.tabs = {}
	Polestar.Engine.GetGuide = function() return nil end
	Polestar.Engine.GetLiveStep = function() return nil end
	truthy(ForeverScribe.Guide.Capture().none, "no guide open")
end)

test("guide: secret values from Polestar are dropped, never stored", function()
	W.Boot(); W.FakePolestarGuide()
	W.polestar.views[12].title = W.Secret("Secret step")
	W.polestar.tabs[1].title = W.Secret("Secret guide")
	local p = ForeverScribe.Guide.Capture()
	eq(p.step.title, nil); eq(p.tabs[1].title, nil); eq(p.tabs[1].id, "forever/alliance/02-westfall")
end)

test("guide: source only reads Polestar (no SetGuide, ticks, skips or arrow calls)", function()
	local f = assert(io.open(W.ROOT .. "addon/ForeverScribe/Guide.lua")); local src = f:read("*a"); f:close()
	local code = src:gsub("%-%-[^\n]*", "")
	for _, bad in ipairs({ "SetGuide", "ReplaceSteps", "ToggleGoal", "SkipGoal", "SkipStep", "Navigate", "Cancel", "Dismiss",
		"RegisterGuide", "PinQuest", "hooksecurefunc", "ReloadUI", "SendChatMessage" }) do
		truthy(not code:find(bad, 1, true), "Guide.lua must not call " .. bad)
	end
end)

test("route + Polestar: each stop goes to Polestar's arrow; its guide taking the arrow is said once, never fought", function()
	local d = slotDir(); W.slotDir = d
	writeSlots(d, routeLua("rp", STOPS))
	W.Boot(); W.FakePolestar()
	W.zone.mapID, W.zone.x, W.zone.y = 1453, 0.10, 0.10
	ForeverScribe.Slash("go")
	eq(W.polestar.target.owner, "ForeverScribe"); near(W.polestar.target.x, 0.528)
	truthy(W.polestar.target.title:find("Errands 1/3: Shaina Fuller", 1, true), W.polestar.target.title)
	eq(W.superTracked, false, "one arrow: Polestar's")
	W.zone.x, W.zone.y = 0.5285, 0.4485; W.Advance(1.5)
	near(W.polestar.target.x, 0.60, "stop 2 handed to Polestar")
	W.polestar.target = { owner = nil, map = 1436, x = 0.5, y = 0.5, title = "Polestar step" } -- its guide moved on
	local before = #W.chat
	W.Advance(3)
	eq(#W.chat - before, 1, "said once"); truthy(lastChat():find("Polestar's arrow moved on", 1, true), lastChat())
	eq(W.polestar.target.title, "Polestar step", "never taken back on its own")
	ForeverScribe.Slash("go")
	eq(W.polestar.target.owner, "ForeverScribe", "/fs go points it back")
end)

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
	-- v0.5 fixture: NPC sightings (one agrees with Wowhead, one is far off it, one Wowhead has no position for)
	dofile(ROOT .. "tests/lua/wow_stub.lua")
	W.Reset(); W.ROOT = ROOT
	W.Boot(); W.Advance(30)
	local function meet(ev, guid, name, sub, zone, map, x, y)
		W.zone.zone, W.zone.subzone, W.zone.mapID, W.zone.x, W.zone.y = zone, "", map, x, y
		W.units.npc = { guid = guid, name = name, sub = sub }
		W.Fire(ev); W.units.npc = nil; W.Advance(60)
	end
	meet("GOSSIP_SHOW", "Creature-0-1-0-1-2327-00000001", "Shaina Fuller", "First Aid Trainer", "Stormwind City", 1453, 0.5262, 0.4491)
	meet("TRAINER_SHOW", "Creature-0-1-0-1-2327-00000001", "Shaina Fuller", "First Aid Trainer", "Stormwind City", 1453, 0.5266, 0.4489)
	meet("GOSSIP_SHOW", "Creature-0-1-0-1-5150-00000001", "Nissa Firestone", "First Aid Trainer", "Ironforge", 1455, 0.5010, 0.5020)
	meet("MERCHANT_SHOW", "Creature-0-1-0-1-990001-00000001", "Quartermaster Vell", "Supplies", "Elwynn Forest", 1429, 0.4400, 0.6600)
	W.WriteSV(FIXTURES .. "/sv_v5.lua")
	-- v0.7 fixture: the same character with Polestar loaded (what Guide.lua keeps for the agent)
	dofile(ROOT .. "tests/lua/wow_stub.lua")
	W.Reset(); W.ROOT = ROOT
	W.FakePolestarGuide()
	W.polestar.liveTarget = { map = 1436, x = 0.565, y = 0.329, title = "Gryan Stoutmantle", kind = "turnin",
		next = { map = 1436, x = 0.5, y = 0.4, title = "Fly to Sentinel Hill", kind = "taxi" } }
	W.Boot(); W.Advance(30)
	W.WriteSV(FIXTURES .. "/sv_v7.lua")
	print("\nfixtures written to " .. FIXTURES)
end

print(string.format("\n%d passed, %d failed", passed, #failed))
for _, f in ipairs(failed) do print("FAIL " .. f) end
os.exit(#failed == 0 and 0 or 1)

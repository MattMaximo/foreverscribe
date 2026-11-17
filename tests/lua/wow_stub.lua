-- Minimal simulated WoW: Forever client for ForeverScribe unit tests (Lua 5.1).
-- Only what the addon calls is modelled. API names/shapes follow the Forever
-- branch of Gethe/wow-ui-source (Blizzard_APIDocumentationGenerated).

local W = {}
_G.W = W

local SecretMT = { __tostring = function() return "<secret>" end }
function W.Secret() return setmetatable({}, SecretMT) end
function issecretvalue(v) return getmetatable(v) == SecretMT end

function W.Reset()
	W.time, W.clock = 1763250000, 1000
	W.timers = {}
	W.frames = {}
	W.unknownEvents = { TRAIT_CONFIG_UPDATED = true, MAIL_SHOW = true, MAIL_CLOSED = true } -- like a client lacking them
	W.chat = {}
	W.items = {
		[2589] = { name = "Linen Cloth", quality = 1, stack = 20 },
		[2581] = { name = "Heavy Linen Bandage", quality = 1, stack = 20 },
		[6268] = { name = "Pioneer Bracers", quality = 2, ilvl = 18, reqLevel = 13, equipLoc = "INVTYPE_WRIST", subType = "Cloth", stats = { ITEM_MOD_INTELLECT_SHORT = 3 } },
		[3647] = { name = "Bright Bracers", quality = 2, ilvl = 26, reqLevel = 21, equipLoc = "INVTYPE_WRIST", subType = "Cloth", stats = { ITEM_MOD_INTELLECT_SHORT = 5, ITEM_MOD_SPIRIT_SHORT = 2 } },
		[6948] = { name = "Hearthstone", quality = 1 },
		[2070] = { name = "Darnassian Bleu", quality = 1, stack = 20 },
	}
	W.player = { name = "Pixelpop", realm = "Forever-Test", level = 23, xp = 1200, xpMax = 13000, money = 123456,
		class = "MAGE", race = "Gnome", faction = "Alliance", hearth = "Thelsamar", rested = 500 }
	W.zone = { zone = "Loch Modan", subzone = "Thelsamar", mapID = 1432, x = 0.3512, y = 0.4721, instance = { "Loch Modan", "none", 0, "", 5, 0, false, 0 } }
	W.maps = {
		[1432] = { mapID = 1432, name = "Loch Modan", mapType = 3, parentMapID = 1415 },
		[1426] = { mapID = 1426, name = "Dun Morogh", mapType = 3, parentMapID = 1415 },
		[1415] = { mapID = 1415, name = "Eastern Kingdoms", mapType = 2, parentMapID = 947 },
		[947] = { mapID = 947, name = "Azeroth", mapType = 1 },
	}
	W.bagSize = { [0] = 16, [1] = 6, [2] = 6, [3] = 0, [4] = 0, [-1] = 24 }
	W.bags = { [0] = {}, [1] = {}, [2] = {}, [3] = {}, [4] = {}, [-1] = {} }
	W.bags[0][1] = { itemID = 6948, count = 1 }
	W.bags[0][2] = { itemID = 2589, count = 7 }
	W.bags[1][1] = { itemID = 3647, count = 1 }
	W.bags[-1][1] = { itemID = 2589, count = 20 }
	W.equip = { [9] = 6268 }
	W.quests = {
		{ title = "Loch Modan", isHeader = true },
		{ title = "Filthy Paws", questID = 307, level = 20, objectives = { { text = "Miners' League Crates", numFulfilled = 1, numRequired = 4, finished = false } } },
	}
	W.completed = { [33] = true, [783] = true, [7] = true }
	W.skills = {
		{ name = "Professions", isHeader = true },
		{ name = "Tailoring", skillID = 197, rank = 75, maxRank = 150 },
		{ name = "Secondary Skills", isHeader = true },
		{ name = "First Aid", skillID = 129, rank = 80, maxRank = 150 },
	}
	W.spells = { { spellID = 133, name = "Fireball", subName = "Rank 4" }, { spellID = 116, name = "Frostbolt", subName = "Rank 3" } }
	W.talents = { { name = "Arcane", talents = { { name = "Arcane Subtlety", rank = 2, maxRank = 2 } } }, { name = "Fire", talents = { { name = "Improved Fireball", rank = 5, maxRank = 5 }, { name = "Impact", rank = 0, maxRank = 5 } } } }
	W.taxi = { { name = "Ironforge, Dun Morogh", nodeID = 6, state = 1 }, { name = "Thelsamar, Loch Modan", nodeID = 8, state = 0 }, { name = "Menethil Harbor, Wetlands", nodeID = 7, state = 2 } }
	W.trade = nil -- open profession {name, level, max, recipes = { [id] = {name, learned, relativeDifficulty, numSkillUps} } }
	W.loot = {}
	W.addonsLoaded = {}
	W.secretIdentity = false
	W.ResetV2()
	if W.ResetV3 then W.ResetV3() end
	ForeverScribe, ForeverScribe_Codec, ForeverScribeDB = nil, nil, nil
	W.liveMissing = nil
	SlashCmdList = {}
	DEFAULT_CHAT_FRAME = { AddMessage = function(_, m) W.chat[#W.chat + 1] = m end }
end

local function linkFor(id)
	local it = W.items[id]
	return string.format("|cff1eff00|Hitem:%d:0:0:0:0:0:0:0:%d|h[%s]|h|r", id, W.player.level, it and it.name or "?")
end
W.Link = linkFor

-- Frames ---------------------------------------------------------------
local FrameMT = {}
FrameMT.__index = FrameMT
function FrameMT:RegisterEvent(ev)
	if W.unknownEvents[ev] then error("Attempt to register unknown event \"" .. ev .. "\"") end
	self.events[ev] = true
end
function FrameMT:UnregisterEvent(ev) self.events[ev] = nil end
function FrameMT:SetScript(name, fn)
	self.scripts[name] = fn
	if name == "OnUpdate" and fn then W.updaters = W.updaters or {}; table.insert(W.updaters, self) end
end
function FrameMT:Show() self.shown = true end
function FrameMT:Hide() self.shown = false end
function FrameMT:IsShown() return self.shown end
function FrameMT:CreateTexture() local t = setmetatable({ events = {}, scripts = {} }, FrameMT); self.textures[#self.textures + 1] = t; return t end
function FrameMT:SetColorTexture(r, g, b) self.color = { r, g, b } end
for _, m in ipairs({ "SetFrameStrata", "SetFrameLevel", "SetIgnoreParentScale", "SetScale", "SetPoint", "SetSize" }) do
	FrameMT[m] = function() end
end
function CreateFrame(kind, name)
	local f = setmetatable({ kind = kind, name = name, events = {}, scripts = {}, textures = {}, shown = true }, FrameMT)
	W.frames[#W.frames + 1] = f
	if name then _G[name] = f end
	return f
end
UIParent = setmetatable({ events = {}, scripts = {}, textures = {} }, FrameMT)

function W.Fire(ev, ...)
	for _, f in ipairs(W.frames) do
		if f.events[ev] and f.scripts.OnEvent then f.scripts.OnEvent(f, ev, ...) end
	end
end

function W.Registered()
	local out = {}
	for _, f in ipairs(W.frames) do for ev in pairs(f.events) do out[ev] = true end end
	return out
end

-- Time ----------------------------------------------------------------
function time() return W.time end
function GetTime() return W.clock end
C_Timer = { After = function(d, fn) W.timers[#W.timers + 1] = { at = W.clock + d, fn = fn } end }
function W.Advance(sec)
	local start, epoch0 = W.clock, W.time
	local target = W.clock + sec
	while true do
		table.sort(W.timers, function(a, b) return a.at < b.at end)
		local t = W.timers[1]
		if not t or t.at > target then break end
		table.remove(W.timers, 1)
		W.clock = math.max(W.clock, t.at)
		W.time = epoch0 + math.floor(W.clock - start)
		t.fn()
	end
	W.clock = target
	W.time = epoch0 + math.floor(sec)
end

-- Identity / progress ----------------------------------------------------
local function id(v) if W.secretIdentity then return W.Secret() end return v end
function UnitName() return id(W.player.name), nil end
function GetRealmName() return W.player.realm end
function UnitClass() return id("Mage"), id(W.player.class), 8 end
function UnitRace() return id("Gnome"), id(W.player.race), 7 end
function UnitFactionGroup() return W.player.faction, W.player.faction end
function UnitSex() return 2 end
function GetBuildInfo() return "1.60.1", "70532", "Nov 2026", 16001 end
function UnitLevel() return W.player.level end
function UnitXP() return W.player.xp end
function UnitXPMax() return W.player.xpMax end
function GetXPExhaustion() return W.player.rested end
function GetMaxPlayerLevel() return 60 end
function GetMoney() return W.player.money end
function GetBindLocation() return W.player.hearth end
function IsResting() return false end
function UnitCharacterPoints() return 1 end
C_Secrets = { ShouldUnitIdentityBeSecret = function() return W.secretIdentity end }
function RequestTimePlayed() W.Fire("TIME_PLAYED_MSG", 360000, 3600) end

-- Location -------------------------------------------------------------
function GetRealZoneText() return W.zone.zone end
function GetZoneText() return W.zone.zone end
function GetSubZoneText() return W.zone.subzone end
function GetMinimapZoneText() return W.zone.subzone end
function GetInstanceInfo() return unpack(W.zone.instance) end
C_Map = {
	GetBestMapForUnit = function() return W.zone.mapID end,
	GetMapInfo = function(m) return W.maps[m] end,
	GetPlayerMapPosition = function()
		if W.zone.x == nil then return nil end
		return { x = W.zone.x, y = W.zone.y, GetXY = function(self) return self.x, self.y end }
	end,
}

-- Items -----------------------------------------------------------------
C_Item = {
	GetItemInfo = function(x)
		local iid = type(x) == "number" and x or tonumber(tostring(x):match("item:(%d+)"))
		local it = W.items[iid]
		if not it then return nil end
		return it.name, linkFor(iid), it.quality, it.ilvl or 1, it.reqLevel or 0, "Armor", it.subType or "", it.stack or 1, it.equipLoc or ""
	end,
	GetItemStats = function(link)
		local iid = tonumber(tostring(link):match("item:(%d+)"))
		return W.items[iid] and W.items[iid].stats or {}
	end,
}
function GetInventoryItemLink(_, slot) local i = W.equip[slot]; return i and linkFor(i) or nil end
function GetInventoryItemID(_, slot) return W.equip[slot] end
function GetInventoryItemDurability(slot) if W.equip[slot] then return 30, 35 end end
NUM_BAG_SLOTS = 4
KEYRING_CONTAINER = nil -- classic-style layout by default; tests opt into Forever's
BANK_CONTAINER = -1
NUM_BANKBAGSLOTS = 0
C_Container = {
	GetContainerNumSlots = function(bag) return W.bagSize[bag] or 0 end,
	GetContainerItemInfo = function(bag, slot)
		local it = W.bags[bag] and W.bags[bag][slot]
		if not it then return nil end
		return { itemID = it.itemID, stackCount = it.count, hyperlink = linkFor(it.itemID), quality = (W.items[it.itemID] or {}).quality }
	end,
}
function W.FreeSlot(bag)
	for s = 1, W.bagSize[bag] do if not W.bags[bag][s] then return s end end
end

-- Quests ----------------------------------------------------------------
C_QuestLog = {
	GetNumQuestLogEntries = function() return #W.quests end,
	GetInfo = function(i) local q = W.quests[i]; if not q then return nil end
		return { title = q.title, questID = q.questID, level = q.level, isHeader = q.isHeader or false, isComplete = q.complete and 1 or nil } end,
	GetQuestObjectives = function(qid) for _, q in ipairs(W.quests) do if q.questID == qid then return q.objectives end end end,
	IsComplete = function(qid) for _, q in ipairs(W.quests) do if q.questID == qid then return q.complete or false end end return false end,
	IsFailed = function() return false end,
	GetAllCompletedQuestIDs = function() local t = {} for k in pairs(W.completed) do t[#t + 1] = k end return t end,
	IsQuestFlaggedCompleted = function(qid) return W.completed[qid] or false end,
	GetTitleForQuestID = function(qid) for _, q in ipairs(W.quests) do if q.questID == qid then return q.title end end return W.questCache and W.questCache[qid] end,
}

-- Skills / spells / talents ----------------------------------------------
C_SkillInfo = {
	GetNumSkillLines = function() return #W.skills end,
	GetSkillLineInfo = function(i) local s = W.skills[i]; if not s then return nil end
		return { name = s.name, isHeader = s.isHeader or false, skillID = s.skillID, rank = s.rank, maxRank = s.maxRank } end,
}
Enum = { SpellBookSpellBank = { Player = 0 }, BagIndex = { Backpack = 0 } }
C_SpellBook = {
	GetNumSpellBookSkillLines = function() return 1 end,
	GetSpellBookSkillLineInfo = function() return { name = "Mage", itemIndexOffset = 0, numSpellBookItems = #W.spells } end,
	GetSpellBookItemInfo = function(i) local s = W.spells[i]; if not s then return nil end
		return { spellID = s.spellID, name = s.name, subName = s.subName, isPassive = false } end,
}
C_Spell = { GetSpellName = function(id) for _, s in ipairs(W.spells) do if s.spellID == id then return s.name end end return "Spell " .. id end }
function GetNumTalentTabs() return #W.talents end
function GetTalentTabInfo(t) local tr = W.talents[t]; local p = 0; for _, x in ipairs(tr.talents) do p = p + x.rank end; return tr.name, "icon", p end
function GetNumTalents(t) return #W.talents[t].talents end
function GetTalentInfo(t, i) local x = W.talents[t].talents[i]; return x.name, "icon", 1, i, x.rank, x.maxRank end
-- Forever itself has no classic talent tabs (talents are C_Traits); tests opt in with W.useTraits.
local classicTabs = GetNumTalentTabs
function GetNumTalentTabs() if W.useTraits then return 0 end return classicTabs() end

-- Taxi / tradeskill / loot -------------------------------------------------
C_TaxiMap = { GetAllTaxiNodes = function() local t = {} for i, n in ipairs(W.taxi) do t[i] = { name = n.name, nodeID = n.nodeID, state = n.state } end return t end }
C_TradeSkillUI = {
	GetBaseProfessionInfo = function() if not W.trade then return nil end return { professionName = W.trade.name, skillLevel = W.trade.level, maxSkillLevel = W.trade.max } end,
	GetAllRecipeIDs = function() local t = {} for rid in pairs(W.trade and W.trade.recipes or {}) do t[#t + 1] = rid end table.sort(t) return t end,
	GetRecipeInfo = function(rid) local r = W.trade and W.trade.recipes[rid]; if not r then return nil end
		return { recipeID = rid, name = r.name, learned = r.learned, relativeDifficulty = r.relativeDifficulty, numSkillUps = r.numSkillUps or 1, canSkillUp = true, maxTrivialLevel = 100 } end,
	GetRecipeSchematic = function(rid) local r = W.trade and W.trade.recipes[rid]; if not r then return nil end
		return { outputItemID = r.output, quantityMin = 1, reagentSlotSchematics = { { quantityRequired = 2, reagents = { { itemID = 2589 } } } } } end,
}
function GetNumLootItems() return #W.loot end
function GetLootSlotInfo(i) local l = W.loot[i]; return "icon", W.items[l.itemID].name, l.count, nil, W.items[l.itemID].quality end
function GetLootSlotLink(i) return linkFor(W.loot[i].itemID) end


-- v0.2 surfaces ---------------------------------------------------------------
-- W.teardown = true makes every reader return what the client returns while it
-- tears the UI down at logout: zero counts, nil tables, 0 health.
local function td() return W.teardown end

function W.ResetV2()
	W.teardown = false
	W.useTraits = false
	W.factions = {
		{ name = "Alliance", isHeader = true, factionID = 469 },
		{ name = "Stormwind", factionID = 72, reaction = 5, currentStanding = 4000, currentReactionThreshold = 3000, nextReactionThreshold = 9000, isWatched = true },
		{ name = "Ironforge", factionID = 47, reaction = 4, currentStanding = 2500, currentReactionThreshold = 0, nextReactionThreshold = 3000 },
		{ name = "Gnomeregan", factionID = 54, reaction = 6, currentStanding = 9500, currentReactionThreshold = 9000, nextReactionThreshold = 21000 },
		{ name = "Other", isHeader = true, factionID = 1169 },
		{ name = "Defias Brotherhood", factionID = 15, reaction = 1, currentStanding = -42000, currentReactionThreshold = -42000, nextReactionThreshold = -6000, atWarWith = true, canToggleAtWar = false },
	}
	W.renown = {
		[2802] = { renownLevel = 3, renownReputationEarned = 120, renownLevelThreshold = 500, maxLevel = 20, name = "Legacy" },
		[2800] = { renownLevel = 0, renownReputationEarned = 0, renownLevelThreshold = 100, maxLevel = 14 },
	}
	-- Trait trees: class tree 1112 (config 50) and Legacy trees 1187-1189 (configs 61-63).
	W.traitEntries = {
		[9001] = { def = 8001, maxRanks = 1 }, [9002] = { def = 8002, maxRanks = 3 }, [9003] = { def = 8003, maxRanks = 2 },
		[9004] = { def = 8004, maxRanks = 5 }, [9101] = { def = 8101, maxRanks = 1 }, [9102] = { def = 8102, maxRanks = 3 },
		[9103] = { def = 8103, maxRanks = 1 },
	}
	W.traitDefs = { [8001] = 1312002, [8002] = 11071, [8003] = 11175, [8004] = 11070, [8101] = 1400001, [8102] = 1400002, [8103] = 1400003 }
	W.spellNames = { [1312002] = "Ice Lance", [11071] = "Frostbite", [11175] = "Permafrost", [11070] = "Improved Frostbolt",
		[1400001] = "Swift Travels", [1400002] = "Gatherer's Fortune", [1400003] = "Hearty Appetite" }
	W.traitTrees = {
		[1112] = { config = 50, currency = { traitCurrencyID = 100, quantity = 1, maxQuantity = 21, spent = 20, spentInTree = 20 }, nodes = {
			{ ID = 105767, entries = { 9001 }, rank = 1, max = 1, group = 701 },
			{ ID = 105774, entries = { 9002 }, rank = 3, max = 3, group = 703 },
			{ ID = 105776, entries = { 9003 }, rank = 0, max = 2, group = 703 },
			{ ID = 105779, entries = { 9004 }, rank = 5, max = 5, group = 703 },
		} },
		[1188] = { config = 62, currency = { traitCurrencyID = 4225, quantity = 2, maxQuantity = 10, spent = 3, spentInTree = 3 }, nodes = {
			{ ID = 110298, entries = { 9101 }, rank = 1, max = 1 },
			{ ID = 110299, entries = { 9102 }, rank = 2, max = 3 },
			{ ID = 110300, entries = { 9103 }, rank = 0, max = 1 },
		} },
	}
	W.traitGroups = { [1112] = { { groupID = 701, displayName = "Arcane", orderIndex = 1 }, { groupID = 702, displayName = "Fire", orderIndex = 2 }, { groupID = 703, displayName = "Frost", orderIndex = 3 } } }
	W.achCats = { 15579, 15600 }
	W.achCatInfo = { [15579] = { "Mage Challenges", -1 }, [15600] = { "Exploration", -1 }, [130] = { "Character", -1 } }
	W.achievements = {
		{ id = 50001, cat = 15579, name = "Frost Adept", points = 10, done = true, mine = true, date = { 11, 12, 26 }, legacy = 5 },
		{ id = 50002, cat = 15579, name = "Polymorph Master", points = 10, done = false, legacy = 10,
			criteria = { { "Polymorph a beast", true, 1, 1 }, { "Polymorph a humanoid", false, 0, 1 } } },
		{ id = 50003, cat = 15600, name = "Explore Loch Modan", points = 5, done = true, mine = false, date = { 10, 1, 26 } },
	}
	W.statCats = { 130 }
	W.stats = { [130] = { { "12", false, 60001, "Total deaths" }, { "--", false, 60002, "Never" }, { "347", false, 60003, "Creatures killed" } } }
	W.zoneTree = { [947] = { { mapID = 1415, name = "Eastern Kingdoms" } }, [1415] = { { mapID = 1432, name = "Loch Modan" }, { mapID = 1426, name = "Dun Morogh" } } }
	W.explored = {
		[1432] = { { file = 7001, rect = { 0, 100, 0, 100 }, area = 144 }, { file = 7002, rect = { 200, 300, 0, 100 }, area = 145 } },
		[1426] = {},
	}
	W.areas = { [144] = "Thelsamar", [145] = "Silver Stream Mine", [146] = "Stonewrought Dam" }
	W.titles = { [1] = { "Private %s", true }, [2] = { "%s the Explorer", false } }
	W.currentTitle = 1
	W.mounts = { [11] = { "Black Ram", 6896, true }, [12] = { "Swift Mechanostrider", 23223, false } }
	W.pets = { ["BattlePet-0-1"] = { 40, nil, 1, "Mechanical Squirrel" } }
	W.toys = { [1973] = { "Orb of Deception", true }, [17712] = { "Winter Veil Disguise Kit", false } }
	W.currencies = { { name = "Player vs. Player", isHeader = true }, { name = "Honor Points", currencyID = 1901, quantity = 150, maxQuantity = 75000 },
		{ name = "Legacy", isHeader = true }, { name = "Legacy Marks", currencyID = 4300, quantity = 3, maxQuantity = 0 } }
	W.auras = { { spellId = 1459, name = "Arcane Intellect", applications = 0, expirationTime = W.clock + 1500, duration = 1800, isFromPlayerOrPlayerPet = true } }
	W.eqsets = {}
	W.saved = { { "The Deadmines", 36, 86400, 1, true, false, 0, false, 5, "Normal", 6, 2 } }
	W.guild = { "Muffin Mafia", "Member", 3 }
	W.mail = { { sender = "Thomas Miller", subject = "Your auction sold", money = 5000, canReply = false, items = {} },
		{ sender = "Fizzwick", subject = "secret plans", money = 0, canReply = true, items = { { "Linen Cloth", 2589, 20 } } } }
	W.recipeCooldowns = {}
	W.questCache = { [33] = "Collecting Kelp", [783] = "A Threat Within" } -- client quest cache (7 is not cached)
end

C_Spell.GetSpellName = function(id)
	if W.spellNames and W.spellNames[id] then return W.spellNames[id] end
	for _, s in ipairs(W.spells) do if s.spellID == id then return s.name end end
	return "Spell " .. id
end

C_Reputation = {
	GetNumFactions = function() if td() then return 0 end return #W.factions end,
	GetFactionDataByIndex = function(i)
		local f = W.factions[i]; if not f or td() then return nil end
		local out = {}; for k, v in pairs(f) do out[k] = v end
		out.isHeader = f.isHeader or false; out.isChild = false; out.isCollapsed = false
		return out
	end,
	GetFactionDataByID = function(id) for i, f in ipairs(W.factions) do if f.factionID == id and not td() then return C_Reputation.GetFactionDataByIndex(i) end end end,
	GetWatchedFactionData = function() for _, f in ipairs(W.factions) do if f.isWatched then return f end end end,
}
C_MajorFactions = {
	GetMajorFactionProgressionInfo = function(id) local r = W.renown[id]; if not r or td() then return nil end
		return { renownLevel = r.renownLevel, renownReputationEarned = r.renownReputationEarned, renownLevelThreshold = r.renownLevelThreshold, maxLevel = r.maxLevel, weekNumber = 3 } end,
	GetMajorFactionData = function(id) local r = W.renown[id]; if not r then return nil end return { name = r.name, factionID = id, isUnlocked = r.renownLevel > 0, renownLevel = r.renownLevel } end,
	GetCurrentRenownLevel = function(id) return W.renown[id] and W.renown[id].renownLevel or 0 end,
}

local function traitTreeOfConfig(configID)
	for tid, t in pairs(W.traitTrees) do if t.config == configID then return tid, t end end
end
local function nodeByID(t, id) for _, n in ipairs(t.nodes) do if n.ID == id then return n end end end
C_ClassTalents = { GetActiveConfigID = function() if td() then return nil end return W.traitTrees[1112] and 50 or nil end }
C_SpecializationInfo = {
	GetActiveSpecGroup = function() return 1 end,
	GetCombatConfigIDForSpecGroup = function(g) if g == 1 then return 50 end return nil end,
}
function GetNumSpecGroups() return 1 end
C_Traits = {
	GetConfigInfo = function(cid) local tid = traitTreeOfConfig(cid); if not tid then return nil end return { ID = cid, name = cid == 50 and "Frost leveling" or "Legacy", treeIDs = { tid } } end,
	GetConfigIDByTreeID = function(tid) return W.traitTrees[tid] and W.traitTrees[tid].config or nil end,
	GetTreeNodes = function(tid) local t = W.traitTrees[tid]; if not t or td() then return {} end local o = {} for i, n in ipairs(t.nodes) do o[i] = n.ID end return o end,
	GetNodeInfo = function(cid, nodeID)
		local _, t = traitTreeOfConfig(cid); local n = t and nodeByID(t, nodeID)
		if not n then return { ID = 0 } end
		return { ID = n.ID, entryIDs = n.entries, activeRank = n.rank, currentRank = n.rank, maxRanks = n.max, isVisible = true,
			activeEntry = n.rank > 0 and { entryID = n.entries[1], rank = n.rank } or nil, groupIDs = { n.group }, canPurchaseRank = n.rank < n.max, type = 0 }
	end,
	GetEntryInfo = function(_, eid) local e = W.traitEntries[eid]; if not e then return nil end return { definitionID = e.def, maxRanks = e.maxRanks } end,
	GetDefinitionInfo = function(did) local sid = W.traitDefs[did]; if not sid then return nil end return { spellID = sid } end,
	GetTreeCurrencyInfo = function(cid, tid) local t = W.traitTrees[tid]; if not t then return {} end return { t.currency } end,
	GetGroupDisplayInfoByTreeID = function(tid) return W.traitGroups[tid] or {} end,
	GetGroupCurrencyInfo = function(cid, gids)
		local out = {}
		for _, g in ipairs(gids) do
			local spent = 0
			for _, n in ipairs(W.traitTrees[1112].nodes) do if n.group == g then spent = spent + n.rank end end
			out[#out + 1] = { traitNodeGroupID = g, currencyInfos = { { spent = spent } } }
		end
		return out
	end,
	GetMaxAvailableTraitCurrency = function() return 10 end,
	GetTraitCurrencyForAchievement = function(_, aid) for _, a in ipairs(W.achievements) do if a.id == aid then return a.legacy or 0 end end return 0 end,
}

-- Achievements / Legacy Challenges / statistics
local function achByID(id) for _, a in ipairs(W.achievements) do if a.id == id then return a end end end
local function achInCat(cat) local o = {} for _, a in ipairs(W.achievements) do if a.cat == cat then o[#o + 1] = a end end return o end
function GetCategoryList() if td() then return {} end return W.achCats end
function GetStatisticsCategoryList() return W.statCats end
function GetCategoryInfo(cat) local c = W.achCatInfo[cat]; if c then return c[1], c[2] end end
function GetCategoryNumAchievements(cat) if W.stats[cat] then return #W.stats[cat] end return #achInCat(cat) end
function GetAchievementInfo(a, b)
	local x = b and achInCat(a)[b] or achByID(a)
	if not x then
		for _, list in pairs(W.stats) do for _, st in ipairs(list) do if st[3] == a then return a, st[4] end end end
		return nil
	end
	local d = x.date or {}
	return x.id, x.name, x.points, x.done, d[1], d[2], d[3], "desc", 0, "icon", "", false, x.mine or false
end
function GetAchievementNumCriteria(id) local a = achByID(id); return a and a.criteria and #a.criteria or 0 end
function GetAchievementCriteriaInfo(id, j) local c = achByID(id).criteria[j]; return c[1], 0, c[2], c[3], c[4] end
function GetTotalAchievementPoints() return 15 end
function GetStatistic(cat, i) local st = W.stats[cat][i]; return st[1], st[2], st[3] end

-- Maps / exploration
C_Map.GetMapChildrenInfo = function(parent, mapType) if td() then return {} end return W.zoneTree[parent] or {} end
C_Map.GetMapArtLayers = function() return { { layerWidth = 1000, layerHeight = 1000, tileWidth = 256, tileHeight = 256 } } end
C_Map.GetAreaInfo = function(id) return W.areas[id] end
function CreateVector2D(x, y) return { x = x, y = y } end
C_MapExplorationInfo = {
	GetExploredMapTextures = function(mapID)
		if td() then return nil end
		local o = {}
		for _, e in ipairs(W.explored[mapID] or {}) do
			o[#o + 1] = { textureWidth = 100, textureHeight = 100, offsetX = e.rect[1], offsetY = e.rect[3], fileDataIDs = { e.file },
				hitRect = { left = e.rect[1], right = e.rect[2], top = e.rect[3], bottom = e.rect[4] } }
		end
		return o
	end,
	GetExploredAreaIDsAtPosition = function(mapID, v)
		for _, e in ipairs(W.explored[mapID] or {}) do
			local x, y = v.x * 1000, v.y * 1000
			if x >= e.rect[1] and x <= e.rect[2] and y >= e.rect[3] and y <= e.rect[4] then return { e.area } end
		end
	end,
}

-- Titles / collections / currencies
function GetNumTitles() if td() then return 0 end return #W.titles end
function IsTitleKnown(i) return W.titles[i] and W.titles[i][2] or false end
function GetTitleName(i) return W.titles[i] and W.titles[i][1] end
function GetCurrentTitle() return W.currentTitle end
C_MountJournal = {
	GetMountIDs = function() if td() then return {} end local o = {} for id in pairs(W.mounts) do o[#o + 1] = id end table.sort(o) return o end,
	GetMountInfoByID = function(id) local m = W.mounts[id]; if not m then return nil end return m[1], m[2], 0, false, true, 0, false, false, nil, false, m[3], id end,
}
C_PetJournal = {
	GetOwnedPetIDs = function() if td() then return {} end local o = {} for g in pairs(W.pets) do o[#o + 1] = g end table.sort(o) return o end,
	GetPetInfoByPetID = function(g) local p = W.pets[g]; if not p then return nil end return p[1], p[2], p[3], 0, 0, 0, false, p[4] end,
}
C_ToyBox = {
	GetNumFilteredToys = function() if td() then return 0 end local n = 0 for _ in pairs(W.toys) do n = n + 1 end return n end,
	GetToyFromIndex = function(i) local o = {} for id in pairs(W.toys) do o[#o + 1] = id end table.sort(o) return o[i] or -1 end,
	GetToyInfo = function(id) local t = W.toys[id]; if t then return id, t[1] end end,
}
function PlayerHasToy(id) return W.toys[id] and W.toys[id][2] or false end
C_CurrencyInfo = {
	GetCurrencyListSize = function() if td() then return 0 end return #W.currencies end,
	GetCurrencyListInfo = function(i) local c = W.currencies[i]; if not c then return nil end local o = {} for k, v in pairs(c) do o[k] = v end o.isHeader = c.isHeader or false return o end,
	GetCurrencyInfo = function(id) for _, c in ipairs(W.currencies) do if c.currencyID == id then return c end end end,
}

-- Character sheet
function UnitHealthMax() if td() then return 0 end return 640 end
function UnitPowerType() return 0, "MANA" end
function UnitPowerMax() if td() then return 0 end return 910 end
local STATS = { { 20, 22 }, { 25, 25 }, { 38, 40 }, { 70, 78 }, { 60, 62 } }
function UnitStat(_, i) local s = STATS[i]; return s[1], s[2], s[2] - s[1], 0 end
function UnitArmor() return 210, 230, 230, 20 end
function UnitResistance(_, i) if i == 4 then return 0, 10, 10, 10 end return 0, 0, 0, 0 end
function GetSpellBonusDamage(school) if school == 5 then return 28 end return 12 end
function GetSpellBonusHealing() return 12 end
function GetSpellCritChance() return 4.5 end
function GetSpellHitModifier() return 3 end
function UnitSpellHaste() return 0 end
function GetSpellPenetration() return 0 end
function GetCritChance() return 5.1 end
function GetRangedCritChance() return 5.1 end
function GetHitModifier() return 0 end
function GetMeleeHaste() return 0 end
function UnitAttackPower() return 30, 0, 0 end
function UnitRangedAttackPower() return 10, 0, 0 end
function UnitDamage() return 20, 31, 0, 0, 0, 0, 1 end
function UnitAttackSpeed() return 2.9 end
function GetManaRegen() return 2.4, 0.4 end
function GetDodgeChance() return 3.2 end
function GetParryChance() return 0 end
function GetBlockChance() return 0 end
function UnitDefenseSkill() return 115, 0 end
function GetAverageItemLevel() return 18.4, 17.9 end
C_UnitAuras = { GetAuraDataByIndex = function(_, i) if td() then return nil end return W.auras[i] end }

-- Sets / lockouts / guild / mail / PvP / mode
C_EquipmentSet = {
	GetEquipmentSetIDs = function() local o = {} for id in pairs(W.eqsets) do o[#o + 1] = id end return o end,
	GetEquipmentSetInfo = function(id) local s = W.eqsets[id]; return s.name, 0, id, s.equipped, 2 end,
	GetItemIDs = function(id) return W.eqsets[id].items end,
}
function GetNumSavedInstances() if td() then return 0 end return #W.saved end
function GetSavedInstanceInfo(i) return unpack(W.saved[i]) end
function GetNumSavedWorldBosses() return 0 end
function RequestRaidInfo() C_Timer.After(0.5, function() W.Fire("UPDATE_INSTANCE_INFO") end) end
function IsInGuild() return W.guild ~= nil end
function GetGuildInfo() if td() or not W.guild then return nil end return unpack(W.guild) end
function GetInboxNumItems() return #W.mail, #W.mail end
function GetInboxHeaderInfo(i) local m = W.mail[i]
	return "pkg", "stat", m.sender, m.subject, m.money, 0, 29.5, #m.items, false, false, true, m.canReply, false end
function GetInboxItem(i, j) local it = W.mail[i].items[j]; return it[1], it[2], "tex", it[3] end
function GetPVPLifetimeStats() return 12, 0 end
function GetPVPSessionStats() return 1, 0 end
function GetPVPYesterdayStats() return 3, 0 end
function UnitHonor() return 150 end
function UnitHonorMax() return 0 end
function UnitHonorLevel() return 0 end
function UnitIsPVP() return true end
function GetPVPDesired() return false end
function GetCurrentArenaSeason() return 1 end
C_SeasonInfo = { GetTimeUntilCurrentPVPSeasonEnd = function() return 86400 * 20 end }
C_GameRules = {
	IsHardcoreActive = function() return false end, IsSelfFoundAllowed = function() return false end, IsStandard = function() return false end,
	GetActiveGameMode = function() return 0 end, GetCurrentGameModeRecordID = function() return 18 end, GetForeverExperiencePreset = function() return 1 end,
}
function PlayerGetTimerunningSeasonID() return 0 end
function IsXPUserDisabled() return false end
C_TradeSkillUI.GetRecipeCooldown = function(rid) local c = W.recipeCooldowns[rid]; if c then return c, true, 0, 0 end return 0 end

-- Addon loading -----------------------------------------------------------
W.ROOT = W.ROOT or "./"
-- file lists come from the TOCs, like the client
local function tocFiles(name)
	local f = io.open(W.ROOT .. "addon/" .. name .. "/" .. name .. ".toc")
	if not f then return nil end
	local out = {}
	for line in f:lines() do
		line = line:gsub("%s+$", "")
		if line ~= "" and not line:match("^#") then out[#out + 1] = line end
	end
	f:close()
	return out
end
W.ADDONS = setmetatable({}, { __index = function(t, name)
	if name ~= "ForeverScribe" and name ~= "ForeverScribe_Live" then return nil end
	local files = tocFiles(name)
	rawset(t, name, files)
	return files
end })
function W.LoadAddonFiles(name)
	for _, f in ipairs(W.ADDONS[name]) do
		if f:match("%.lua$") then -- XML templates (Options.xml) are only declarations; the tests build frames by hand
			local chunk, err = loadfile(W.ROOT .. "addon/" .. name .. "/" .. f)
			if not chunk then error(err) end
			chunk()
		end
	end
	W.addonsLoaded[name] = true
end
C_AddOns = { LoadAddOn = function(name)
	if W.ADDONS[name] and not W.liveMissing then
		if not W.addonsLoaded[name] then W.LoadAddonFiles(name) end
		return true
	end
	return false, "MISSING"
end }

-- Full client boot: load base addon, fire login sequence.
function W.Boot(isReload)
	W.LoadAddonFiles("ForeverScribe")
	W.Fire("ADDON_LOADED", "ForeverScribe")
	W.Fire("PLAYER_LOGIN")
	W.Fire("PLAYER_ENTERING_WORLD", not isReload, isReload and true or false)
	W.Advance(10)
end

-- SavedVariables round trip in the client's on-disk format -----------------
local function sortedKeys(t)
	local keys = {}
	for k in pairs(t) do keys[#keys + 1] = k end
	table.sort(keys, function(a, b)
		local ta, tb = type(a), type(b)
		if ta ~= tb then return ta == "number" end
		return a < b
	end)
	return keys
end

local function q(s) return string.format("%q", s):gsub("\\\n", "\\n") end

local function ser(v, indent, out)
	local t = type(v)
	if t == "string" then out[#out + 1] = q(v)
	elseif t == "number" then
		if v % 1 == 0 then out[#out + 1] = string.format("%d", v) else out[#out + 1] = string.format("%.14g", v) end
	elseif t == "boolean" then out[#out + 1] = tostring(v)
	elseif t == "table" then
		out[#out + 1] = "{\n"
		local n = #v
		for i = 1, n do
			out[#out + 1] = indent .. "\t"
			ser(v[i], indent .. "\t", out)
			out[#out + 1] = ", -- [" .. i .. "]\n"
		end
		for _, k in ipairs(sortedKeys(v)) do
			if not (type(k) == "number" and k >= 1 and k <= n and k % 1 == 0) then
				out[#out + 1] = indent .. "\t[" .. (type(k) == "string" and q(k) or tostring(k)) .. "] = "
				ser(v[k], indent .. "\t", out)
				out[#out + 1] = ",\n"
			end
		end
		out[#out + 1] = indent .. "}"
	else
		error("cannot save value of type " .. t)
	end
end

function W.SerializeSV(name, value)
	local out = { "\n", name, " = " }
	ser(value, "", out)
	out[#out + 1] = "\n"
	return table.concat(out)
end

-- /reload or relog: logout, write SV, wipe Lua state, boot again from the file.
function W.Relog(isReload, opts)
	opts = opts or {}
	W.Fire("PLAYER_LEAVING_WORLD")
	W.Fire("PLAYER_LOGOUT")
	local text = W.SerializeSV("ForeverScribeDB", ForeverScribeDB)
	if opts.svPath then local f = assert(io.open(opts.svPath, "w")); f:write(text); f:close() end
	W.frames, W.timers, W.addonsLoaded = {}, {}, {}
	if W.slotsLoaded then -- /reload unloads load-on-demand addons; the next load reads the file again
		for k in pairs(W.slotsLoaded) do W.loadedByName[k] = nil end
		W.slotsLoaded, W.tickers = {}, {}
	end
	ForeverScribe_RouteData = nil
	ForeverScribe, ForeverScribe_Codec, ForeverScribeDB = nil, nil, nil
	if not opts.svLoadBug then
		local chunk = assert(loadstring(text))
		chunk()
	end
	W.time = W.time + (opts.offline or 5)
	if opts.beforeBoot then opts.beforeBoot() end
	W.Boot(isReload)
	return text
end

function W.WriteSV(path)
	local text = W.SerializeSV("ForeverScribeDB", ForeverScribeDB)
	local f = assert(io.open(path, "w")); f:write(text); f:close()
	return text
end

do -- v0.3 additions live next to this file
	local here = (debug.getinfo(1, "S").source or ""):match("^@(.*/)") or "tests/lua/"
	dofile(here .. "wow_stub_v3.lua")
	dofile(here .. "wow_stub_way.lua")
	dofile(here .. "wow_stub_npc.lua")
	dofile(here .. "wow_stub_tip.lua")
	dofile(here .. "wow_stub_craft.lua")
	dofile(here .. "wow_stub_settings.lua")
end

return W

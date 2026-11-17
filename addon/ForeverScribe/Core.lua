-- ForeverScribe: read-only character telemetry for World of Warcraft: Forever.
-- Records a per-character snapshot and an append-only event log into the
-- ForeverScribeDB SavedVariable. No network, no file I/O, no protected calls,
-- no input automation, never ReloadUI. The only chat event registered is
-- CHAT_MSG_SYSTEM, and only lines that match the client's own auction-outcome
-- format strings are kept (as kind + item name); every other line is dropped unread. Every game API call is pcall'd and
-- every stored value passes the secret-value filter in Util.lua.

local FS = ForeverScribe
local U = FS.Util
local Try, Call, Clean, Sanitize = U.Try, U.Call, U.Clean, U.Sanitize

FS.VERSION = "0.8.0"
FS.SCHEMA = 1
FS.EVENT_CAP = 4000
FS.SESSION_CAP = 200

local db, char -- ForeverScribeDB and the active character record
local session, seq = nil, 0
local listeners = {}
local pending = {} -- events raised before the character is known
local state = {
	bagTotals = nil, -- live totals of bags + equipped + bank cache, for diffing
	bankOpen = false,
	interaction = {}, -- open interaction frames -> true (merchant, mail, ...)
	lootUntil = 0,
	turnedIn = {},
	questLog = nil, -- [questID] = {title=, obj={ {have,need,done}... }}
	skills = nil, -- [name] = rank
	spells = nil, -- [spellID] = true
	talents = nil, -- [key] = rank
	gold = { delta = 0, first = nil, from = nil },
	instance = nil,
	encounter = nil,
	ready = false,
	leaving = false, -- PLAYER_LEAVING_WORLD / LOGOUT: every read may be a teardown read
	accum = {}, -- throttled REPUTATION_CHANGED / CURRENCY_CHANGED aggregation
	emitted = {}, -- [kind][id] = true for things already announced by a direct event
}
FS.state = state

local function now() return (Try(time)) or 0 end
local function clock() return (Try(GetTime)) or 0 end

local function Print(msg)
	local f = DEFAULT_CHAT_FRAME
	local text = "|cff8fd3ffForeverScribe|r: " .. tostring(msg)
	if f and f.AddMessage then pcall(f.AddMessage, f, text) elseif print then print(text) end
end
FS.Print = Print

---------------------------------------------------------------------------
-- Scheduling
---------------------------------------------------------------------------

local tokens = {}
function FS.Schedule(key, delay, fn)
	tokens[key] = (tokens[key] or 0) + 1
	local mine = tokens[key]
	local after = U.Fn("C_Timer.After")
	local run = function()
		if tokens[key] ~= mine then return end
		local ok, err = pcall(fn)
		if not ok then FS.errors = (FS.errors or 0) + 1; FS.lastError = tostring(err) end
	end
	if after then
		Try(after, delay, run)
	else
		run()
	end
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------

function FS.AddListener(fn)
	listeners[#listeners + 1] = fn
end

local function context()
	local snap = char and char.snapshot
	return {
		lvl = snap and snap.level,
		map = snap and snap.location and snap.location.mapID,
		zone = snap and snap.location and snap.location.zone,
	}
end

function FS.Emit(etype, payload, opts)
	opts = opts or {}
	if not session then
		pending[#pending + 1] = { etype, payload, opts }
		return
	end
	seq = seq + 1
	local ev = {
		id = session .. ":" .. seq,
		type = etype,
		t = now(),
		payload = Sanitize(payload) or {},
		source = opts.source or "event",
		confidence = opts.confidence or "high",
		schema = FS.SCHEMA,
		ctx = context(),
	}
	if not char then
		pending[#pending + 1] = { etype, payload, opts }
		seq = seq - 1
		return
	end
	U.RingPush(char.events, ev, FS.EVENT_CAP, char)
	char.lastSeq = seq
	if char.sessions and char.sessions[#char.sessions] then
		char.sessions[#char.sessions].last = ev.t
		char.sessions[#char.sessions].events = seq
	end
	for i = 1, #listeners do pcall(listeners[i], ev) end
	return ev
end
local Emit = FS.Emit

---------------------------------------------------------------------------
-- Collectors (each returns plain data; never raises)
---------------------------------------------------------------------------

local SLOT_NAMES = {
	[0] = "ammo", "head", "neck", "shoulder", "shirt", "chest", "waist", "legs", "feet", "wrist",
	"hands", "finger1", "finger2", "trinket1", "trinket2", "back", "mainhand", "offhand", "ranged", "tabard",
}
FS.SLOT_NAMES = SLOT_NAMES

local itemInfoCache = {}
local function ItemInfo(linkOrID)
	if linkOrID == nil then return {} end
	local key = linkOrID
	if itemInfoCache[key] then return itemInfoCache[key] end
	local fn = U.Fn("C_Item.GetItemInfo") or U.Fn("GetItemInfo")
	local name, _, quality, ilvl, reqLevel, itype, subType, stack, equipLoc = Try(fn, linkOrID)
	local info = {
		name = Clean(name), quality = Clean(quality), ilvl = Clean(ilvl), reqLevel = Clean(reqLevel),
		itemType = Clean(itype), subType = Clean(subType), stack = Clean(stack), equipLoc = Clean(equipLoc),
	}
	local dil = Call("C_Item.GetDetailedItemLevelInfo", linkOrID)
	if Clean(dil) then info.ilvl = Clean(dil) end
	if info.name then itemInfoCache[key] = info end
	return info
end

local statsCache = {}
local function ItemStats(link)
	if not link then return nil end
	if statsCache[link] then return statsCache[link] end
	local fn = U.Fn("C_Item.GetItemStats") or U.Fn("GetItemStats")
	local stats = Sanitize((Try(fn, link)))
	if stats and next(stats) then statsCache[link] = stats end
	return stats
end

local function Identity()
	local id = {}
	local secret = Call("C_Secrets.ShouldUnitIdentityBeSecret", "player")
	id.identitySecret = Clean(secret) or false
	id.name = Clean((Call("UnitName", "player")))
	id.realm = Clean((Call("GetRealmName"))) or Clean((Call("GetNormalizedRealmName")))
	local _, classFile, classID = Call("UnitClass", "player")
	id.class, id.classID = Clean(classFile), Clean(classID)
	local _, raceEn, raceID = Call("UnitRace", "player")
	id.race, id.raceID = Clean(raceEn), Clean(raceID)
	id.faction = Clean((Call("UnitFactionGroup", "player")))
	id.sex = Clean((Call("UnitSex", "player")))
	id.guild = Clean((Call("GetGuildInfo", "player")))
	local version, build, _, toc = Call("GetBuildInfo")
	id.client = { version = Clean(version), build = Clean(build), toc = Clean(toc) }
	return id
end

local function CharKey(id)
	local realm = id.realm or "UnknownRealm"
	local name = id.name
	if not name then
		local guid = Clean((Call("UnitGUID", "player")))
		name = guid and ("GUID-" .. guid) or "UnknownCharacter"
	end
	return realm .. ":" .. name, (id.name == nil)
end

local function Progress()
	local p = {}
	p.level = Clean((Call("UnitLevel", "player")))
	p.xp = Clean((Call("UnitXP", "player")))
	p.xpMax = Clean((Call("UnitXPMax", "player")))
	p.rested = Clean((Call("GetXPExhaustion")))
	p.maxLevel = Clean((Call("GetMaxPlayerLevel")))
	p.money = Clean((Call("GetMoney")))
	p.hearth = Clean((Call("GetBindLocation")))
	p.resting = Clean((Call("IsResting")))
	p.talentPointsUnspent = Clean((Call("UnitCharacterPoints", "player")))
	return p
end

local function MapPosition(mapID)
	if not mapID then return nil end
	local pos = Call("C_Map.GetPlayerMapPosition", mapID, "player")
	if type(pos) ~= "table" and type(pos) ~= "userdata" then return nil end
	local x, y
	if type(pos) == "table" and pos.GetXY then
		x, y = Try(pos.GetXY, pos)
	end
	if x == nil then
		local ok, px, py = pcall(function() return pos.x, pos.y end)
		if ok then x, y = px, py end
	end
	x, y = Clean(x), Clean(y)
	if type(x) ~= "number" or type(y) ~= "number" then return nil end
	return math.floor(x * 10000 + 0.5) / 100, math.floor(y * 10000 + 0.5) / 100
end

local function Location()
	local l = {}
	l.zone = Clean((Call("GetRealZoneText"))) or Clean((Call("GetZoneText")))
	l.subzone = Clean((Call("GetSubZoneText")))
	l.minimap = Clean((Call("GetMinimapZoneText")))
	l.mapID = Clean((Call("C_Map.GetBestMapForUnit", "player")))
	if l.mapID then
		local info = Call("C_Map.GetMapInfo", l.mapID)
		if type(info) == "table" then l.mapName = Clean(info.name) end
		l.x, l.y = MapPosition(l.mapID)
	end
	local name, itype, difficultyID, difficultyName, maxPlayers, _, _, instanceID = Call("GetInstanceInfo")
	l.instance = {
		name = Clean(name), type = Clean(itype), difficultyID = Clean(difficultyID),
		difficulty = Clean(difficultyName), maxPlayers = Clean(maxPlayers), instanceID = Clean(instanceID),
	}
	l.inInstance = (l.instance.type ~= nil and l.instance.type ~= "none")
	return l
end
FS.MapPosition, FS.Location = MapPosition, Location

local function Equipment()
	local eq, totals = {}, {}
	for slot = 0, 19 do
		local link = Clean((Call("GetInventoryItemLink", "player", slot)))
		if link then
			local itemID, enchant, lname = U.ParseItemLink(link)
			itemID = itemID or Clean((Call("GetInventoryItemID", "player", slot)))
			local info = ItemInfo(link)
			local cur, max = Call("GetInventoryItemDurability", slot)
			eq[SLOT_NAMES[slot] or tostring(slot)] = {
				slot = slot, itemID = itemID, link = link, name = info.name or lname, ilvl = info.ilvl,
				quality = info.quality, reqLevel = info.reqLevel, subType = info.subType, equipLoc = info.equipLoc,
				enchant = enchant, dur = Clean(cur), durMax = Clean(max), stats = ItemStats(link),
			}
			if itemID and slot ~= 0 then totals[itemID] = (totals[itemID] or 0) + 1 end
		end
	end
	return eq, totals
end

local function ContainerSlots(bag)
	return Clean((Call("C_Container.GetContainerNumSlots", bag))) or Clean((Call("GetContainerNumSlots", bag))) or 0
end

local function ContainerItem(bag, slot)
	local info = Call("C_Container.GetContainerItemInfo", bag, slot)
	if type(info) == "table" then
		return Clean(info.itemID), Clean(info.stackCount) or 1, Clean(info.hyperlink), Clean(info.quality)
	end
	local fn = U.Fn("GetContainerItemInfo")
	if fn then
		local _, count, _, quality, _, _, link, _, _, itemID = Try(fn, bag, slot)
		return Clean(itemID), Clean(count) or 1, Clean(link), Clean(quality)
	end
	return nil
end

local function BagIDs()
	local ids = {}
	local n = Clean(NUM_BAG_SLOTS) or 4
	for b = 0, n do ids[#ids + 1] = b end
	local reagent = Enum and Enum.BagIndex and Enum.BagIndex.ReagentBag
	if reagent and reagent > n then ids[#ids + 1] = reagent end
	local keyring = Clean(KEYRING_CONTAINER)
	if keyring then ids[#ids + 1] = keyring end
	return ids
end

-- Forever (retail-lineage 12.x) uses character bank tabs (Enum.BagIndex.CharacterBankTab_1..9);
-- Classic-era clients use BANK_CONTAINER (-1) + NUM_BANKBAGSLOTS bags. Never mix
-- them: on Forever -1 is the keyring and 5 the reagent bag.
local function BankIDs()
	local ids, seen = {}, {}
	for _, b in ipairs(BagIDs()) do seen[b] = true end
	local function add(b) if b ~= nil and not seen[b] then seen[b] = true; ids[#ids + 1] = b end end
	local E = Enum and Enum.BagIndex
	if E and E.CharacterBankTab_1 then
		local tabs = Call("C_Bank.FetchPurchasedBankTabIDs", Enum.BankType and Enum.BankType.Character or 0)
		if type(tabs) == "table" and #tabs > 0 then
			for _, b in ipairs(tabs) do add(Clean(b)) end
		else
			for i = 1, 9 do add(E["CharacterBankTab_" .. i]) end
		end
		return ids
	end
	add(Clean(BANK_CONTAINER))
	local nb = Clean(NUM_BAG_SLOTS) or 4
	local nbank = Clean(NUM_BANKBAGSLOTS)
	if nbank then for i = 1, nbank do add(nb + i) end end
	return ids
end

-- Scan a list of containers into { [itemID] = {count, link, name, quality, ...} }
local function ScanContainers(ids)
	local items, totals = {}, {}
	local free, slotsTotal = 0, 0
	for _, bag in ipairs(ids) do
		local n = ContainerSlots(bag)
		for slot = 1, n do
			slotsTotal = slotsTotal + 1
			local itemID, count, link, quality = ContainerItem(bag, slot)
			if itemID then
				totals[itemID] = (totals[itemID] or 0) + (count or 1)
				local it = items[itemID]
				if not it then
					local info = ItemInfo(link or itemID)
					it = { itemID = itemID, count = 0, link = link, name = info.name, quality = quality or info.quality }
					if info.equipLoc and info.equipLoc ~= "" and info.equipLoc ~= "INVTYPE_NON_EQUIP_IGNORE" then
						it.equipLoc, it.ilvl, it.reqLevel, it.subType = info.equipLoc, info.ilvl, info.reqLevel, info.subType
						if link then it.stats = ItemStats(link) end
					end
					items[itemID] = it
				end
				it.count = it.count + (count or 1)
			else
				free = free + 1
			end
		end
	end
	return items, totals, free, slotsTotal
end

local function QuestLog()
	local quests = {}
	local n = Clean((Call("C_QuestLog.GetNumQuestLogEntries"))) or 0
	local header
	for i = 1, n do
		local info = Call("C_QuestLog.GetInfo", i)
		if type(info) == "table" then
			if Clean(info.isHeader) then
				header = Clean(info.title)
			else
				local qid = Clean(info.questID)
				if qid then
					local q = {
						questID = qid, title = Clean(info.title), level = Clean(info.level), zone = header,
						suggestedGroup = Clean(info.suggestedGroup), frequency = Clean(info.frequency),
						complete = (Clean((Call("C_QuestLog.IsComplete", qid))) and true) or (Clean(info.isComplete) == 1 or Clean(info.isComplete) == true),
						failed = Clean((Call("C_QuestLog.IsFailed", qid))) and true or nil,
						obj = {},
					}
					local objs = Call("C_QuestLog.GetQuestObjectives", qid)
					if type(objs) == "table" then
						for j, o in ipairs(objs) do
							if type(o) == "table" then
								q.obj[j] = { text = Clean(o.text), have = Clean(o.numFulfilled), need = Clean(o.numRequired), done = Clean(o.finished) and true or false, type = Clean(o.type) }
							end
						end
					end
					quests[#quests + 1] = q
				end
			end
		end
	end
	return quests
end

local function CompletedQuests()
	local ids = Call("C_QuestLog.GetAllCompletedQuestIDs")
	if type(ids) ~= "table" then
		local legacy = Call("GetQuestsCompleted") -- Classic-era: { [questID] = true }
		if type(legacy) ~= "table" then return nil end
		ids = {}
		for k, v in pairs(legacy) do if v then ids[#ids + 1] = k end end
	end
	local out = {}
	for _, q in ipairs(ids) do
		q = Clean(q)
		if type(q) == "number" then out[#out + 1] = q end
	end
	table.sort(out)
	return out
end

local function Skills()
	local list, ranks = {}, {}
	local n = Clean((Call("C_SkillInfo.GetNumSkillLines")))
	local header
	if n then
		for i = 1, n do
			local s = Call("C_SkillInfo.GetSkillLineInfo", i)
			if type(s) == "table" then
				local name = Clean(s.name)
				if Clean(s.isHeader) then
					header = name
				elseif name then
					list[#list + 1] = { name = name, skillID = Clean(s.skillID), rank = Clean(s.rank) or Clean(s.skillRank),
						max = Clean(s.maxRank) or Clean(s.skillMaxRank), mod = Clean(s.modifier), group = header }
					ranks[name] = list[#list].rank or 0
				end
			end
		end
	else
		n = Clean((Call("GetNumSkillLines"))) or 0
		for i = 1, n do
			local name, isHeader, _, rank, _, mod, max = Call("GetSkillLineInfo", i)
			name = Clean(name)
			if Clean(isHeader) then
				header = name
			elseif name then
				list[#list + 1] = { name = name, rank = Clean(rank), max = Clean(max), mod = Clean(mod), group = header }
				ranks[name] = Clean(rank) or 0
			end
		end
	end
	return list, ranks
end

local function Spells()
	local spells = {}
	local bank = (Enum and Enum.SpellBookSpellBank and Enum.SpellBookSpellBank.Player) or 0
	local lines = Clean((Call("C_SpellBook.GetNumSpellBookSkillLines")))
	if lines then
		for l = 1, lines do
			local li = Call("C_SpellBook.GetSpellBookSkillLineInfo", l)
			if type(li) == "table" and not Clean(li.offSpecID) then
				local off, num, tab = Clean(li.itemIndexOffset) or 0, Clean(li.numSpellBookItems) or 0, Clean(li.name)
				for idx = off + 1, off + num do
					local si = Call("C_SpellBook.GetSpellBookItemInfo", idx, bank)
					if type(si) == "table" then
						local sid = Clean(si.spellID) or Clean(si.actionID)
						if sid and not Clean(si.isOffSpec) then
							spells[sid] = { name = Clean(si.name), sub = Clean(si.subName), tab = tab, passive = Clean(si.isPassive) or nil }
						end
					end
				end
			end
		end
	else
		local tabs = Clean((Call("GetNumSpellTabs"))) or 0
		for t = 1, tabs do
			local tab, _, off, num = Call("GetSpellTabInfo", t)
			off, num = Clean(off) or 0, Clean(num) or 0
			for idx = off + 1, off + num do
				local stype, sid = Call("GetSpellBookItemInfo", idx, "spell")
				sid = Clean(sid)
				if sid and Clean(stype) ~= "FUTURESPELL" then
					local name, sub = Call("GetSpellBookItemName", idx, "spell")
					spells[sid] = { name = Clean(name), sub = Clean(sub), tab = Clean(tab) }
				end
			end
		end
	end
	return spells
end

-- Talents (all trees, every visible node incl. untaken, unspent points, dual
-- spec) plus Forever's Legacy trees. Ranks are keyed "n<nodeID>" (class tree)
-- and "L<nodeID>" (Legacy trees) so one diff covers both.
-- Legacy merge: a read where the trees came back empty keeps the last good trees/points.
local function MergeLegacy(new)
	if not new or not char then return end
	local old = char.legacy
	if old and #new.trees == 0 and old.trees and #old.trees > 0 then
		new.trees = old.trees
		new.points = new.points and new.points.unspent and new.points or old.points
	end
	if old and not new.track then new.track = old.track end
	char.legacy = new
end
FS.MergeLegacy = MergeLegacy

local function Talents()
	local Col = FS.Collect
	local t, ranks, meta = Col.Talents()
	ranks, meta = ranks or {}, meta or {}
	local legacy = Col.Legacy(ranks, meta)
	if not t and not legacy then return nil end
	return t, ranks, meta, legacy
end

---------------------------------------------------------------------------
-- Snapshot
---------------------------------------------------------------------------

local function Totals(bagTotals, eqTotals, bankTotals)
	local t = {}
	for _, src in ipairs({ bagTotals or {}, eqTotals or {}, bankTotals or {} }) do
		for k, v in pairs(src) do t[k] = (t[k] or 0) + v end
	end
	return t
end

function FS.SnapshotFast()
	if not char then return end
	local s = char.snapshot
	local p = Progress()
	-- During logout / leaving world the client returns 0 for xpMax and money; keep the last good values.
	if not p.xpMax or p.xpMax == 0 then return end
	for k, v in pairs(p) do s[k] = v end
	s.location = Location()
	s.capturedAt = now()
	s.addonVersion = FS.VERSION
	s.session = session
end

function FS.SnapshotFull()
	if not char then return end
	local s = char.snapshot
	s.identity = Identity()
	FS.SnapshotFast()
	local eq = Equipment()
	local items, _, free, slots = ScanContainers(BagIDs())
	-- Never replace good gear/bags with an empty read (UI teardown at logout).
	if next(eq) ~= nil or not s.equipment then s.equipment = eq end
	if (slots and slots > 0) or not s.bags then s.bags = { items = items, free = free, slots = slots } end
	local q = QuestLog()
	if (q and #q > 0) or not s.quests then s.quests = q end
	local completed = CompletedQuests()
	if completed then s.questsCompleted = completed; s.questsCompletedAt = now() end
	-- Same rule for every other section: an empty read never replaces a non-empty one.
	local skills = Skills()
	if #skills > 0 or not s.skills then s.skills = skills end
	local spells = Spells()
	if next(spells) ~= nil or not s.spells then s.spells = spells end
	local t, _, _, legacy = Talents()
	if t then s.talents = t end
	if legacy then MergeLegacy(legacy) end
	FS.ScanSmall()
	s.capturedAt = now()
end

local function MarkDirty()
	FS.Schedule("snapshot", 5, FS.SnapshotFast)
end

---------------------------------------------------------------------------
-- Diff-driven event producers
---------------------------------------------------------------------------

local function InteractionReason()
	if clock() <= state.lootUntil or state.interaction.loot then return "loot" end
	for _, k in ipairs({ "merchant", "mail", "trade", "auction", "craft", "quest", "bank" }) do
		if state.interaction[k] then return k end
	end
	return nil
end

function FS.ScanInventory(silent)
	if not char then return end
	local eq, eqTotals = Equipment()
	local items, bagTotals, free, slots = ScanContainers(BagIDs())
	if state.bankOpen then
		local bitems, btotals = ScanContainers(BankIDs())
		char.bank = { items = bitems, totals = btotals, scannedAt = now() }
	end
	local bankTotals = char.bank and char.bank.totals or {}
	local totals = Totals(bagTotals, eqTotals, bankTotals)
	if (not slots or slots == 0) and next(eq) == nil then return end -- UI teardown read; keep last good state
	char.snapshot.bags = { items = items, free = free, slots = slots }
	char.snapshot.equipment = eq
	if state.bagTotals and not silent then
		local reason = InteractionReason()
		for _, d in ipairs(U.DiffCounts(state.bagTotals, totals)) do
			local itemID = d.key
			local it = items[itemID] or (char.bank and char.bank.items and char.bank.items[itemID]) or {}
			local info = ItemInfo(it.link or itemID)
			local payload = { itemID = itemID, name = it.name or info.name, qty = math.abs(d.delta), total = d.new, reason = reason, quality = it.quality or info.quality }
			if d.delta > 0 then
				Emit("ITEM_ACQUIRED", payload, { source = "bag_diff", confidence = reason and "high" or "medium" })
				if reason == "loot" then
					Emit("LOOT", payload, { source = "bag_diff" })
				end
			else
				Emit("ITEM_REMOVED", payload, { source = "bag_diff", confidence = reason and "high" or "medium" })
			end
		end
	end
	state.bagTotals = totals
end

function FS.ScanEquipmentSlot(slot)
	if not char then return end
	local old = char.equipSlots or {}
	local link = Clean((Call("GetInventoryItemLink", "player", slot)))
	local prev = old[slot]
	if link ~= prev then
		local newID, enchant, newName = U.ParseItemLink(link)
		local oldID, _, oldName = U.ParseItemLink(prev)
		local ni = link and ItemInfo(link) or {}
		local oi = prev and ItemInfo(prev) or {}
		Emit("EQUIPMENT_CHANGED", {
			slot = SLOT_NAMES[slot] or slot,
			new = newID and { itemID = newID, name = ni.name or newName, ilvl = ni.ilvl, quality = ni.quality, enchant = enchant } or nil,
			old = oldID and { itemID = oldID, name = oi.name or oldName, ilvl = oi.ilvl, quality = oi.quality } or nil,
		})
		old[slot] = link
		char.equipSlots = old
	end
end

local function RememberEquipSlots()
	local m = {}
	for slot = 0, 19 do m[slot] = Clean((Call("GetInventoryItemLink", "player", slot))) end
	char.equipSlots = m
end

function FS.ScanQuests(silent)
	if not char then return end
	local quests = QuestLog()
	char.snapshot.quests = quests
	local cur = {}
	for _, q in ipairs(quests) do cur[q.questID] = q end
	if state.questLog and not silent then
		for qid, q in pairs(cur) do
			local old = state.questLog[qid]
			if old then
				for j, o in ipairs(q.obj) do
					local oo = old.obj[j]
					if oo and (((o.have or 0) > (oo.have or 0)) or (o.done and not oo.done)) then
						Emit("QUEST_PROGRESS", { questID = qid, title = q.title, objective = o.text, have = o.have, need = o.need, done = o.done })
					end
				end
				if q.complete and not old.complete then
					Emit("QUEST_OBJECTIVES_COMPLETE", { questID = qid, title = q.title })
				end
			end
		end
	end
	state.questLog = cur
end

function FS.ScanSkills(silent)
	if not char then return end
	local list, ranks = Skills()
	if #list == 0 then return end
	char.snapshot.skills = list
	if state.skills and not silent then
		for _, s in ipairs(list) do
			local old = state.skills[s.name]
			if old == nil then
				Emit("SKILL_LEARNED", { skill = s.name, rank = s.rank, max = s.max, group = s.group })
			elseif (s.rank or 0) > old then
				Emit("PROFESSION_SKILL_UP", { skill = s.name, from = old, to = s.rank, max = s.max, group = s.group })
			end
		end
	end
	state.skills = ranks
end

function FS.ScanSpells(silent)
	if not char then return end
	local spells = Spells()
	if next(spells) == nil then return end -- teardown / not loaded: keep the last good spellbook
	char.snapshot.spells = spells
	local known = {}
	for sid in pairs(spells) do known[sid] = true end
	if state.spells and not silent then
		for _, sid in ipairs(U.NewKeys(state.spells, known)) do
			if not state.spellsEmitted or not state.spellsEmitted[sid] then
				Emit("SPELL_LEARNED", { spellID = sid, name = spells[sid].name, rank = spells[sid].sub }, { source = "spellbook_diff" })
			end
		end
	end
	state.spells = known
end

function FS.ScanTalents(silent)
	if not char or state.leaving then return end
	local t, ranks, meta, legacy = Talents()
	if not t and not legacy then return end
	if t then char.snapshot.talents = t end
	if legacy then MergeLegacy(legacy) end
	if state.talents and not silent then
		local diffs = U.DiffCounts(state.talents, ranks)
		-- A tree that failed to read this time is not a refund: only diff keys present in both reads,
		-- plus brand-new keys with a rank > 0.
		local changes = {}
		for _, d in ipairs(diffs) do
			if #changes >= 30 then break end
			local inNew = ranks[d.key] ~= nil
			if inNew and (state.talents[d.key] ~= nil or d.new > 0) then
				local m = meta[d.key] or {}
				changes[#changes + 1] = { key = d.key, name = m.name, tree = m.tree, from = d.old, to = d.new, max = m.max,
					legacy = (tostring(d.key):sub(1, 1) == "L") or nil }
			end
		end
		if #changes > 0 then
			Emit("TALENT_CHANGED", { changes = changes, unspent = t and t.unspent,
				legacyUnspent = legacy and legacy.points and legacy.points.unspent })
		end
	end
	for k, v in pairs(ranks) do state.talents = state.talents or {}; state.talents[k] = v end
	if not state.talents then state.talents = ranks end
end

local function ContinentOf(mapID)
	local guard = 0
	while mapID and guard < 8 do
		guard = guard + 1
		local info = Call("C_Map.GetMapInfo", mapID)
		if type(info) ~= "table" then return nil end
		if Clean(info.mapType) == 2 then return mapID end
		mapID = Clean(info.parentMapID)
	end
	return nil
end

function FS.ScanTaxi()
	if not char then return end
	char.taxi = char.taxi or {}
	char.taxiScanned = char.taxiScanned or {}
	local here = Clean((Call("C_Map.GetBestMapForUnit", "player")))
	local continent = ContinentOf(here) or here or 0
	local found = {}
	local nodes = Call("C_TaxiMap.GetAllTaxiNodes", continent)
	if type(nodes) == "table" then
		for _, n in ipairs(nodes) do
			local st = Clean(n.state)
			local name = Clean(n.name)
			if name and (st == 0 or st == 1) then found[name] = { nodeID = Clean(n.nodeID), current = (st == 0) or nil } end
		end
	end
	local num = Clean((Call("NumTaxiNodes")))
	if num then
		for i = 1, num do
			local name = Clean((Call("TaxiNodeName", i)))
			local ty = Clean((Call("TaxiNodeGetType", i)))
			if name and (ty == "CURRENT" or ty == "REACHABLE") then
				found[name] = found[name] or {}
				if ty == "CURRENT" then found[name].current = true end
			end
		end
	end
	local baseline = not char.taxiScanned[continent]
	for name, n in pairs(found) do
		if not char.taxi[name] then
			char.taxi[name] = { nodeID = n.nodeID, continent = continent, firstSeen = now(), baseline = baseline or nil }
			if not baseline then
				Emit("FLIGHT_PATH_LEARNED", { name = name, nodeID = n.nodeID, continent = continent })
			end
		end
	end
	char.taxiScanned[continent] = now()
end

function FS.ScanRecipes()
	if not char then return end
	char.recipes = char.recipes or {}
	local prof = Call("C_TradeSkillUI.GetBaseProfessionInfo")
	local pname, plevel, pmax
	if type(prof) == "table" then
		pname, plevel, pmax = Clean(prof.professionName), Clean(prof.skillLevel), Clean(prof.maxSkillLevel)
	end
	local recipes, count, cooldowns = {}, 0, nil
	local ids = Call("C_TradeSkillUI.GetAllRecipeIDs")
	if type(ids) ~= "table" then ids = Call("C_TradeSkillUI.GetFilteredRecipeIDs") end
	if type(ids) == "table" then
		for _, rid in ipairs(ids) do
			rid = Clean(rid)
			local r = rid and Call("C_TradeSkillUI.GetRecipeInfo", rid)
			if type(r) == "table" and Clean(r.learned) and count < 600 then
				count = count + 1
				local rec = { name = Clean(r.name), difficulty = Clean(r.relativeDifficulty), skillUps = Clean(r.numSkillUps),
					canSkillUp = Clean(r.canSkillUp), maxTrivial = Clean(r.maxTrivialLevel) }
				local sch = Call("C_TradeSkillUI.GetRecipeSchematic", rid, false)
				if type(sch) == "table" then
					rec.output = Clean(sch.outputItemID)
					rec.qty = Clean(sch.quantityMin)
					local reagents = {}
					for _, slot in ipairs(type(sch.reagentSlotSchematics) == "table" and sch.reagentSlotSchematics or {}) do
						local need = Clean(slot.quantityRequired)
						local first = type(slot.reagents) == "table" and slot.reagents[1]
						local iid = type(first) == "table" and Clean(first.itemID)
						if iid then reagents[#reagents + 1] = { itemID = iid, qty = need } end
					end
					if #reagents > 0 then rec.reagents = reagents end
				end
				recipes[rid] = rec
				local cd = FS.Collect.RecipeCooldown(rid)
				if cd then cd.name = rec.name; cooldowns = cooldowns or {}; cooldowns[rid] = cd end
			end
		end
	end
	-- Classic-era fallback (GetNumTradeSkills / GetTradeSkillInfo)
	if count == 0 and U.Fn("GetNumTradeSkills") then
		local lname, lrank, lmax = Call("GetTradeSkillLine")
		pname, plevel, pmax = pname or Clean(lname), plevel or Clean(lrank), pmax or Clean(lmax)
		local n = Clean((Call("GetNumTradeSkills"))) or 0
		local diffMap = { optimal = 0, medium = 1, easy = 2, trivial = 3 }
		for i = 1, n do
			local name, ty, avail = Call("GetTradeSkillInfo", i)
			name, ty = Clean(name), Clean(ty)
			if name and ty ~= "header" and ty ~= "subheader" then
				local link = Clean((Call("GetTradeSkillItemLink", i)))
				local iid = U.ParseItemLink(link)
				recipes["n:" .. name] = { name = name, difficulty = diffMap[ty or ""], available = Clean(avail), output = iid }
				count = count + 1
			end
		end
	end
	if not pname then return end
	local old = char.recipes[pname]
	if count == 0 and old and (old.count or 0) > 0 then return end -- empty read (window closing): keep
	char.recipes[pname] = { skill = plevel, max = pmax, scannedAt = now(), count = count, recipes = recipes, cooldowns = cooldowns }
	if old and old.recipes then
		for rid, rec in pairs(recipes) do
			if not old.recipes[rid] and not (state.recipesEmitted and state.recipesEmitted[rid]) then
				Emit("RECIPE_LEARNED", { recipeID = type(rid) == "number" and rid or nil, name = rec.name, profession = pname }, { source = "tradeskill_diff" })
			end
		end
	end
end

---------------------------------------------------------------------------
-- v0.2 collectors: reputation, currencies, titles, collections, exploration,
-- achievements / Legacy Challenges, statistics, stats, buffs, durability,
-- equipment sets, lockouts, guild, mail, PvP, game mode, quest-title backfill.
-- Rules: skip while leaving the world; an empty read never replaces a
-- non-empty one; heavy scans run once after login and then on their events.
---------------------------------------------------------------------------

local Col = FS.Collect
FS.ACCUM_WINDOW = 120 -- seconds a REPUTATION_CHANGED / CURRENCY_CHANGED aggregate stays open

local function Announced(kind, id)
	local e = state.emitted[kind]
	return e and e[id]
end
local function MarkAnnounced(kind, id)
	state.emitted[kind] = state.emitted[kind] or {}
	state.emitted[kind][id] = true
end

-- Throttled aggregate events: one event per faction/currency per window.
local function FlushAccum(kind)
	local a = state.accum[kind]
	if not a then return end
	state.accum[kind] = nil
	local list = {}
	for _, v in pairs(a.items) do list[#list + 1] = v end
	table.sort(list, function(x, y) return math.abs(x.delta or 0) > math.abs(y.delta or 0) end)
	for i, v in ipairs(list) do
		if i > 25 then break end
		if v.delta ~= 0 or v.standingTo then
			Emit(kind, v, { source = kind == "REPUTATION_CHANGED" and "faction_diff" or "currency_diff" })
		end
	end
end
FS.FlushAccum = FlushAccum

local function Accumulate(kind, id, entry, immediate)
	local a = state.accum[kind]
	if not a then a = { first = clock(), items = {} }; state.accum[kind] = a end
	local cur = a.items[id]
	if cur then
		cur.delta = (cur.delta or 0) + (entry.delta or 0)
		cur.to = entry.to
		if entry.standingTo then cur.standingFrom = cur.standingFrom or entry.standingFrom; cur.standingTo = entry.standingTo end
	else
		a.items[id] = entry
	end
	if immediate or clock() - a.first > FS.ACCUM_WINDOW then
		FlushAccum(kind)
	else
		FS.Schedule("accum" .. kind, 30, function() FlushAccum(kind) end)
	end
end

function FS.ScanReputation(silent)
	if not char or state.leaving then return end
	local rep = Col.Reputation(char.reputation)
	if not rep then return end
	local old = state.rep
	local cur = {}
	for _, f in ipairs(rep.factions) do cur[f.id] = f end
	if old and not silent then
		for id, f in pairs(cur) do
			local o = old[id]
			if o and (o.value ~= f.value or o.standing ~= f.standing) then
				local changedStanding = (o.standing ~= f.standing) and f.standing or nil
				Accumulate("REPUTATION_CHANGED", id, { factionID = id, name = f.name, delta = (f.value or 0) - (o.value or 0),
					to = f.value, standingFrom = changedStanding and o.standing, standingTo = changedStanding,
					max = f.max }, changedStanding ~= nil)
			elseif not o and not f.hidden then
				Accumulate("REPUTATION_CHANGED", id, { factionID = id, name = f.name, delta = 0, to = f.value,
					standingTo = f.standing, discovered = true }, true)
			end
			if o and o.atWar ~= f.atWar then
				Emit("FACTION_AT_WAR", { factionID = id, name = f.name, atWar = f.atWar or false })
			end
		end
	end
	state.rep = cur
	char.reputation = rep
end

function FS.ScanCurrencies(silent)
	if not char or state.leaving then return end
	local known = {}
	for _, c in ipairs(char.currencies and char.currencies.list or {}) do if c.id then known[c.id] = true end end
	local list = Col.Currencies(known)
	if not list then return end
	local cur = {}
	for _, c in ipairs(list) do cur[c.id] = c end
	if state.cur and not silent then
		for id, c in pairs(cur) do
			local o = state.cur[id]
			local before = o and o.qty or 0
			if (c.qty or 0) ~= before then
				Accumulate("CURRENCY_CHANGED", id, { currencyID = id, name = c.name, delta = (c.qty or 0) - before, to = c.qty, max = c.max })
			end
		end
	end
	state.cur = cur
	char.currencies = { list = list, scannedAt = now() }
end

function FS.ScanTitles(silent)
	if not char or state.leaving then return end
	local t = Col.Titles()
	if not t then return end
	if t.count == 0 and char.titles and (char.titles.count or 0) > 0 then return end
	local old = char.titles and char.titles.known
	if old and not silent then
		for _, id in ipairs(U.NewKeys(old, t.known)) do
			Emit("TITLE_EARNED", { titleID = id, name = t.known[id] })
		end
	end
	t.scannedAt = now()
	char.titles = t
end

local function DiffCollection(kind, old, new, label)
	if not old then return end
	for _, id in ipairs(U.NewKeys(old, new)) do
		if not Announced(kind, id) then
			local v = new[id]
			Emit(kind, { id = id, name = type(v) == "table" and v.n or (type(v) == "string" and v or nil) }, { source = label })
		end
	end
end

function FS.ScanCollections(silent)
	if not char or state.leaving then return end
	local c = char.collections or {}
	local mounts, nm = Col.Mounts()
	if mounts and nm > 0 then
		if not silent then DiffCollection("MOUNT_LEARNED", c.mounts, mounts, "mount_diff") end
		c.mounts, c.numMounts = mounts, nm
	end
	local pets, np = Col.Pets()
	if pets and np > 0 then
		local byKey, oldKeys = {}, {}
		for _, pt in ipairs(pets) do byKey[pt.s .. ":" .. (pt.c or "")] = pt end
		for _, pt in ipairs(c.pets or {}) do oldKeys[pt.s .. ":" .. (pt.c or "")] = true end
		if c.pets and not silent then
			for _, k in ipairs(U.NewKeys(oldKeys, byKey)) do
				local pt = byKey[k]
				if not Announced("PET_LEARNED", pt.s) then Emit("PET_LEARNED", { speciesID = pt.s, name = pt.n }, { source = "pet_diff" }) end
			end
		end
		c.pets, c.numPets = pets, np
	end
	local toys, nt = Col.Toys()
	if toys and nt > 0 then
		if not silent then DiffCollection("TOY_LEARNED", c.toys, toys, "toy_diff") end
		c.toys, c.numToys = toys, nt
	end
	if next(c) ~= nil then c.scannedAt = now(); char.collections = c end
end

-- Exploration. Full scan of every zone on the world map once per login,
-- then only the current zone on MAP_EXPLORATION_UPDATED.
local function ExploreZone(z, silent)
	local e = Col.ExploredZone(z.id)
	if not e then return end
	char.explored = char.explored or { zones = {} }
	local zones = char.explored.zones
	local prev = zones[z.id]
	state.exploredKeys = state.exploredKeys or {}
	local oldKeys = state.exploredKeys[z.id]
	local keys = {}
	for _, k in ipairs(e.ov) do keys[k] = true end
	-- An empty read for a zone we already know is explored is a teardown/not-loaded read.
	if e.n == 0 and prev and (prev.n or 0) > 0 then return end
	if not silent and oldKeys then
		local newAreas = {}
		for _, k in ipairs(U.NewKeys(oldKeys, keys)) do newAreas[#newAreas + 1] = e.keyAreas[k] or "?" end
		if #newAreas > 0 then
			Emit("EXPLORATION_DISCOVERED", { mapID = z.id, zone = z.name or (prev and prev.name), areas = newAreas, explored = e.n })
		end
	end
	state.exploredKeys[z.id] = keys
	zones[z.id] = { name = z.name or (prev and prev.name), continent = z.continent or (prev and prev.continent), n = e.n,
		areas = e.areas or (prev and prev.areas), at = now() }
end

function FS.ScanExplored(silent)
	if not char or state.leaving then return end
	local here = Clean((Call("C_Map.GetBestMapForUnit", "player")))
	local zones = Col.ZoneList(here)
	if #zones == 0 then return end
	for _, z in ipairs(zones) do ExploreZone(z, silent) end
	if not char.explored then return end
	char.explored.scannedAt = now()
	local n, total = 0, 0
	for _, z in pairs(char.explored.zones) do total = total + 1; if (z.n or 0) > 0 then n = n + 1 end end
	char.explored.zonesWithExploration, char.explored.zonesScanned = n, total
end

function FS.ScanExploredHere()
	if not char or state.leaving then return end
	local here = Clean((Call("C_Map.GetBestMapForUnit", "player")))
	local zid = Col.ZoneOf(here)
	if not zid then return end
	local info = Call("C_Map.GetMapInfo", zid)
	local parent = type(info) == "table" and Clean(info.parentMapID)
	local pinfo = parent and Call("C_Map.GetMapInfo", parent)
	ExploreZone({ id = zid, name = type(info) == "table" and Clean(info.name) or nil,
		continent = type(pinfo) == "table" and Clean(pinfo.name) or nil }, false)
end

function FS.ScanAchievements()
	if not char or state.leaving then return end
	local a = Col.Achievements()
	if not a then return end
	if a.total < ((char.achievements and char.achievements.total) or 0) / 2 then return end -- partial read
	char.achievements = a
	local s = Col.Statistics()
	if s and (s.count > 0 or not char.statistics) then char.statistics = s end
end

function FS.ScanSmall()
	if not char or state.leaving then return end
	local s = char.snapshot
	local st = Col.Stats()
	if st then s.stats = st end
	local d = Col.Durability(SLOT_NAMES)
	if d then s.durability = d end
	local hp = Clean((Call("UnitHealthMax", "player")))
	if hp and hp > 0 then s.buffs = Col.Buffs() end
	local g = Col.Guild()
	if g then s.guild = g end
	local m = Col.Mode()
	if m then s.mode = m end
	local pvp = Col.PvP()
	if pvp then s.pvp = pvp end
	s.hearth = Clean((Call("GetBindLocation"))) or s.hearth
end

function FS.ScanStats()
	if not char or state.leaving then return end
	local st = Col.Stats()
	if st then char.snapshot.stats = st end
	local d = Col.Durability(SLOT_NAMES)
	if d then char.snapshot.durability = d end
end

function FS.ScanBuffs()
	if not char or state.leaving then return end
	local hp = Clean((Call("UnitHealthMax", "player")))
	if hp and hp > 0 then char.snapshot.buffs = Col.Buffs() end
end

function FS.ScanEquipmentSets()
	if not char or state.leaving then return end
	local sets = Col.EquipmentSets()
	if sets and (#sets > 0 or not char.equipmentSets) then char.equipmentSets = { sets = sets, scannedAt = now() } end
end

function FS.ScanLockouts()
	if not char or state.leaving then return end
	local l = Col.Lockouts()
	if not l then return end
	if #l == 0 and char.lockouts and #(char.lockouts.list or {}) > 0 then
		-- Empty read: keep only lockouts that have not reset yet (they cannot have vanished early).
		local t, keep = now(), {}
		for _, x in ipairs(char.lockouts.list) do if x.resetAt and x.resetAt > t then keep[#keep + 1] = x end end
		l = keep
	end
	char.lockouts = { list = l, scannedAt = now() }
end

function FS.ScanMail()
	if not char or state.leaving or not state.interaction.mail then return end
	local m = Col.Mail()
	if m then char.mail = m end
end

-- v0.3 -------------------------------------------------------------------

local function sameSenders(a, b)
	a, b = a or {}, b or {}
	if #a ~= #b then return false end
	for i = 1, #a do if a[i] ~= b[i] then return false end end
	return true
end

function FS.ScanMailPending(silent)
	if not char or state.leaving then return end
	local m = Col.MailPending()
	if not m then return end
	local old = char.mailPending
	char.mailPending = m
	if m.hasNew and not silent and (not old or not old.hasNew or not sameSenders(old.senders, m.senders)) then
		Emit("MAIL_PENDING", { senders = m.senders, n = #m.senders })
	end
end

local function FindOwned(auctionID, item)
	local a = char and char.auctions
	if not a or type(a.list) ~= "table" then return nil end
	for _, x in ipairs(a.list) do if auctionID and x.auctionID == auctionID then return x end end
	if item then
		for _, x in ipairs(a.list) do if x.name == item and x.status == "active" then return x end end
	end
	return nil
end

function FS.AuctionOutcome(kind, item, qty, auctionID, source)
	if not char or not kind then return end
	state.ahRecent = state.ahRecent or {}
	local key = kind .. ":" .. tostring(item or auctionID or "")
	local t = clock()
	if state.ahRecent[key] and t - state.ahRecent[key] < 5 then return end -- same outcome from both sources
	state.ahRecent[key] = t
	local owned = FindOwned(auctionID, item)
	Emit(kind, { item = item or (owned and owned.name), itemID = owned and owned.itemID, qty = qty or (owned and owned.qty),
		auctionID = auctionID, buyout = owned and owned.buyout, bid = owned and owned.bid }, { source = source })
end

function FS.ScanAuctions()
	if not char or state.leaving or not state.interaction.auction then return end
	local a = Col.OwnedAuctions()
	if not a then return end
	if a.count == 0 and not a.full then return end -- results not loaded yet; keep the last good list
	char.auctions = a
end

function FS.ScanMerchant()
	if not char or state.leaving or not state.interaction.merchant then return end
	local v = Col.Merchant()
	if not v then return end
	char.vendors = char.vendors or { npcs = {} }
	local npcs = char.vendors.npcs
	local key = v.npcID or v.name or "unknown"
	npcs[key] = v
	local keys = {}
	for k, x in pairs(npcs) do keys[#keys + 1] = { k = k, t = (type(x) == "table" and x.seenAt) or 0 } end
	if #keys > Col.CAP.vendors then
		table.sort(keys, function(a, b) return a.t < b.t end)
		for i = 1, #keys - Col.CAP.vendors do npcs[keys[i].k] = nil end
	end
	char.vendors.last = key
	char.vendors.capturedAt = now()
end

-- Cold tier: stored only when the content changed, so the file and the companion stay quiet.
local COLD = { addons = "Addons", bindings = "Bindings", actionbars = "ActionBars", macros = "Macros" }
FS.COLD = COLD
function FS.ScanCold(which)
	if not char or state.leaving then return end
	for k, fn in pairs(COLD) do
		if not which or which == k then
			local ok, data = pcall(Col[fn])
			if ok and data then
				local old = char[k]
				local oldAt = old and old.capturedAt
				data.capturedAt = oldAt
				if not old or U.JSON(old) ~= U.JSON(data) then
					data.capturedAt = now()
					char[k] = data
				end
			elseif not ok then
				FS.errors = (FS.errors or 0) + 1; FS.lastError = "cold " .. k .. ": " .. tostring(data)
			end
		end
	end
end

-- Optional save reminder. The game writes SavedVariables only on /reload, logout or quit; this prints one
-- chat-frame line when the current UI session is older than N minutes. It never reloads anything itself.
function FS.ReminderMinutes()
	local s = db and db.settings and db.settings.remind
	if s ~= nil then return tonumber(s) or 0 end
	local d = type(ForeverScribe_Defaults) == "table" and tonumber(ForeverScribe_Defaults.saveReminderMinutes) or 0
	return d or 0
end

function FS.ReminderTick()
	local mins = FS.ReminderMinutes()
	if mins > 0 and char and not state.leaving and state.loadedAt then
		local t = now()
		local due = mins * 60
		if t - state.loadedAt >= due and t - (state.remindedAt or 0) >= due and not Clean((Call("InCombatLockdown"))) then
			state.remindedAt = t
			Print(string.format("no save for %d min. /reload when convenient so your agent sees the latest (/scribe remind off to stop).",
				math.floor((t - state.loadedAt) / 60)))
		end
	end
	FS.Schedule("remind", 60, FS.ReminderTick)
end

function FS.ScanPvP()
	if not char or state.leaving then return end
	local pvp = Col.PvP()
	if pvp then char.snapshot.pvp = pvp end
end

-- Completed quests from before install have IDs only. C_QuestLog.GetTitleForQuestID
-- answers from the client cache, so this fills in whatever titles are cheap now,
-- 150 per tick, and never asks the server.
function FS.BackfillQuestTitles()
	if not char or state.leaving then return end
	local ids = char.snapshot.questsCompleted
	if type(ids) ~= "table" then return end
	char.questTitles = char.questTitles or {}
	local titles, n = char.questTitles, U.Count(char.questTitles)
	state.qtCursor = state.qtCursor or 1
	local stop = math.min(#ids, state.qtCursor + 149)
	for i = state.qtCursor, stop do
		local q = ids[i]
		if n >= Col.CAP.questTitles then break end
		if q and not titles[q] then
			local t = Col.QuestTitle(q)
			if t then titles[q] = t; n = n + 1 end
		end
	end
	state.qtCursor = stop + 1
	if state.qtCursor <= #ids and n < Col.CAP.questTitles then FS.Schedule("questtitles", 1, FS.BackfillQuestTitles) end
end

-- Runs a few seconds after login so it never slows the loading screen.
-- Each step is isolated: one failing collector (an API not ready yet at login) must not
-- stop the others or the follow-up scans from being scheduled.
local function Safe(fn, ...)
	local ok, err = pcall(fn, ...)
	if not ok then FS.errors = (FS.errors or 0) + 1; FS.lastError = tostring(err) end
end

function FS.ScanAll(silent)
	Safe(FS.ScanReputation, silent)
	Safe(FS.ScanCurrencies, silent)
	Safe(FS.ScanTitles, silent)
	Safe(FS.ScanCollections, silent)
	Safe(FS.ScanEquipmentSets)
	Safe(FS.ScanSmall)
	Safe(FS.ScanMailPending, silent)
	Safe(FS.ScanCold)
	Call("RequestRaidInfo")
	FS.Schedule("explored", 5, function() FS.ScanExplored(silent) end)
	FS.Schedule("achievements", 12, FS.ScanAchievements)
	state.qtCursor = 1
	FS.Schedule("questtitles", 20, FS.BackfillQuestTitles)
end

local function CheckInstance()
	local l = Location()
	if char then char.snapshot.location = l end
	local key = l.inInstance and ((l.instance.instanceID or "?") .. ":" .. (l.instance.difficultyID or 0)) or nil
	if key ~= state.instance then
		if state.instance and state.instanceInfo then
			Emit("INSTANCE_EXITED", state.instanceInfo)
		end
		if key then
			state.instanceInfo = { name = l.instance.name, type = l.instance.type, difficulty = l.instance.difficulty, instanceID = l.instance.instanceID, maxPlayers = l.instance.maxPlayers }
			Emit("INSTANCE_ENTERED", state.instanceInfo)
		else
			state.instanceInfo = nil
		end
		state.instance = key
	end
end

local function FlushGold()
	local g = state.gold
	if g.delta ~= 0 then
		Emit("GOLD_CHANGED", { delta = g.delta, from = g.from, to = (Clean((Call("GetMoney")))), reason = InteractionReason() }, { source = "money_diff" })
	end
	g.delta, g.first, g.from = 0, nil, nil
end

---------------------------------------------------------------------------
-- Character / session setup
---------------------------------------------------------------------------

local function NewSessionID()
	local r = math.random and math.random(0, 65535) or 0
	db.sessionCounter = (db.sessionCounter or 0) + 1
	return string.format("%d-%04x-%d", now(), r, db.sessionCounter)
end

local function StartCharacter()
	local id = Identity()
	local key, anonymous = CharKey(id)
	db.chars[key] = db.chars[key] or {}
	char = db.chars[key]
	char.key = key
	char.events = char.events or {}
	char.sessions = char.sessions or {}
	char.snapshot = char.snapshot or {}
	char.anonymous = anonymous or nil
	FS.charKey = key
	session = NewSessionID()
	seq = 0
	FS.session = session
	local p = Progress()
	U.RingPush(char.sessions, { id = session, start = now(), last = now(), level = p.level, xp = p.xp, money = p.money }, FS.SESSION_CAP)
	db.lastChar = key
	for _, pe in ipairs(pending) do Emit(pe[1], pe[2], pe[3]) end
	pending = {}
end

local function Baseline()
	FS.SnapshotFull()
	RememberEquipSlots()
	FS.ScanInventory(true)
	FS.ScanQuests(true)
	FS.ScanSkills(true)
	FS.ScanSpells(true)
	FS.ScanTalents(true)
	CheckInstance()
	state.money = char.snapshot.money
	state.ready = true
	state.loadedAt = now() -- the client wrote SavedVariables right before this UI session began
	FS.Schedule("remind", 60, FS.ReminderTick)
	FS.Schedule("scanall", 3, function() FS.ScanAll(true) end)
	-- Some data (reputation list, exploration) isn't ready a few seconds after login; rescan once.
	FS.Schedule("scanall2", 30, function() FS.ScanAll(true) end)
	Emit("SESSION_START", { level = char.snapshot.level, zone = char.snapshot.location and char.snapshot.location.zone, money = char.snapshot.money, version = FS.VERSION }, { source = "addon" })
end

---------------------------------------------------------------------------
-- Event handlers
---------------------------------------------------------------------------

local H = {}
local function ready() return char and state.ready and not state.leaving end
FS.handlers = H

local INTERACTION = { -- Enum.PlayerInteractionType values (Forever API docs)
	[5] = "merchant", [12] = "merchant", [17] = "mail", [1] = "trade", [21] = "auction", [8] = "bank", [4] = "quest",
}

function H.ADDON_LOADED(name)
	if name ~= "ForeverScribe" then
		if char and state.ready and not state.leaving then FS.Schedule("cold_addons", 5, function() FS.ScanCold("addons") end) end
		return
	end
	ForeverScribeDB = ForeverScribeDB or {}
	db = ForeverScribeDB
	db.schema = FS.SCHEMA
	db.addonVersion = FS.VERSION
	db.chars = db.chars or {}
	db.settings = db.settings or {}
	FS.db = db
end

function H.PLAYER_LOGIN()
	if not db then H.ADDON_LOADED("ForeverScribe") end
	StartCharacter()
	if db.settings.live then FS.SetLive(true, true) end
end

function H.PLAYER_ENTERING_WORLD(isLogin, isReload)
	if not char then return end
	state.leaving = false
	if not state.ready then
		Baseline()
		if isLogin and db.settings.played ~= false then -- once per login, not on every /reload
			FS.Schedule("played", 8, function() Call("RequestTimePlayed") end)
		end
	else
		CheckInstance()
		FS.SnapshotFast()
	end
	if FS.Guide and not state.guideStarted then
		state.guideStarted = true
		FS.Schedule("guide_login", 10, function() FS.Guide.OnLogin() end)
	end
	if FS.Route and not state.routeResumed then
		state.routeResumed = true
		FS.Schedule("route_resume", 3, function() FS.Route.Resume() end)
	end
end

function H.PLAYER_LEAVING_WORLD()
	if not char then return end
	FS.FlushZone()
	FlushGold()
	FS.FlushAccum("REPUTATION_CHANGED"); FS.FlushAccum("CURRENCY_CHANGED")
	state.leaving = true
	FS.SnapshotFast()
end

function H.PLAYER_LOGOUT()
	if not char then return end
	FlushGold()
	FS.FlushAccum("REPUTATION_CHANGED"); FS.FlushAccum("CURRENCY_CHANGED")
	state.leaving = true
	pcall(FS.SnapshotFast)
	local s = char.sessions[#char.sessions]
	if s and s.id == session then
		s.ended = now()
		s.levelEnd = char.snapshot.level
		s.xpEnd = char.snapshot.xp
		s.moneyEnd = char.snapshot.money
	end
end

function H.PLAYER_LEVEL_UP(level)
	local prev = char and char.snapshot.level
	Emit("LEVEL_UP", { level = Clean(level), from = prev })
	if char then char.snapshot.level = Clean(level) end
	MarkDirty()
	FS.Schedule("spells", 2, FS.ScanSpells)
	FS.Schedule("stats", 3, FS.ScanStats)
end

function H.PLAYER_XP_UPDATE() MarkDirty() end

function H.BAG_UPDATE_DELAYED()
	if not state.ready then return end
	FS.Schedule("inventory", 0.3, FS.ScanInventory)
end
H.PLAYERBANKSLOTS_CHANGED = H.BAG_UPDATE_DELAYED

function H.PLAYER_EQUIPMENT_CHANGED(slot)
	if not state.ready then return end
	slot = Clean(slot)
	if slot then FS.ScanEquipmentSlot(slot) end
	FS.Schedule("inventory", 0.3, FS.ScanInventory)
	FS.Schedule("stats", 2, FS.ScanStats) -- character sheet after a gear change
end

function H.BANKFRAME_OPENED()
	state.bankOpen = true
	state.interaction.bank = true
	FS.Schedule("bankopen", 0.5, function()
		local bitems, btotals = ScanContainers(BankIDs())
		char.bank = { items = bitems, totals = btotals, scannedAt = now() }
		FS.ScanInventory(true) -- rebaseline: opening the bank is not an acquisition
	end)
end

function H.BANKFRAME_CLOSED()
	if state.bankOpen then FS.ScanInventory() end
	state.bankOpen = false
	state.interaction.bank = nil
end

function H.LOOT_OPENED()
	state.interaction.loot = true
	local n = Clean((Call("GetNumLootItems"))) or 0
	local items = {}
	for i = 1, n do
		local _, name, qty, _, quality = Call("GetLootSlotInfo", i)
		local link = Clean((Call("GetLootSlotLink", i)))
		local iid = U.ParseItemLink(link)
		if Clean(name) then items[#items + 1] = { itemID = iid, name = Clean(name), qty = Clean(qty), quality = Clean(quality) } end
	end
	if #items > 0 then
		Emit("LOOT_WINDOW", { items = items, instance = state.instanceInfo and state.instanceInfo.name }, { source = "loot_window", confidence = "medium" })
	end
end

function H.LOOT_CLOSED()
	state.interaction.loot = nil
	state.lootUntil = clock() + 2
end

local function open(k) return function() state.interaction[k] = true end end
local function close(k) return function()
	state.interaction[k] = nil
	FS.Schedule("inventory", 0.3, FS.ScanInventory)
end end
H.MERCHANT_CLOSED = close("merchant")
function H.MERCHANT_SHOW()
	state.interaction.merchant = true
	FS.Schedule("merchant", 0.5, FS.ScanMerchant)
end
function H.MERCHANT_UPDATE()
	if state.interaction.merchant then FS.Schedule("merchant", 1.5, FS.ScanMerchant) end
end
function H.UPDATE_PENDING_MAIL()
	if ready() then FS.Schedule("mailpending", 1, FS.ScanMailPending) end
end
H.MAIL_CLOSED = close("mail")
function H.MAIL_SHOW()
	state.interaction.mail = true
	FS.Schedule("mail", 1, FS.ScanMail)
end
function H.MAIL_INBOX_UPDATE()
	if state.interaction.mail then FS.Schedule("mail", 1, FS.ScanMail) end
end
H.TRADE_SHOW, H.TRADE_CLOSED = open("trade"), close("trade")
H.AUCTION_HOUSE_CLOSED = close("auction")
function H.AUCTION_HOUSE_SHOW()
	state.interaction.auction = true
	FS.Schedule("auctions", 2, FS.ScanAuctions) -- reads what the client already has; never sends a query
end
function H.OWNED_AUCTIONS_UPDATED()
	if state.interaction.auction then FS.Schedule("auctions", 0.5, FS.ScanAuctions) end
end
function H.AUCTION_HOUSE_SHOW_NOTIFICATION(notification)
	FS.AuctionOutcome(Col.AH_NOTIFICATION[Clean(notification) or -1], nil, nil, nil, "notification")
end
function H.AUCTION_HOUSE_SHOW_FORMATTED_NOTIFICATION(notification, text, auctionID)
	local item = Clean(text)
	if type(item) == "string" then item = item:match("%[(.-)%]") or item; if #item > 120 then item = item:sub(1, 120) end else item = nil end
	FS.AuctionOutcome(Col.AH_NOTIFICATION[Clean(notification) or -1], item, nil, Clean(auctionID), "notification")
end
-- The only chat event ForeverScribe listens to. Non-auction lines return before anything is stored.
function H.CHAT_MSG_SYSTEM(text)
	local kind, item, qty = Col.MatchAuctionLine(text)
	if kind then FS.AuctionOutcome(kind, item, qty, nil, "system") end
end
function H.UPDATE_BINDINGS() if ready() then FS.Schedule("cold_bindings", 3, function() FS.ScanCold("bindings") end) end end
function H.ACTIONBAR_SLOT_CHANGED() if ready() then FS.Schedule("cold_actionbars", 3, function() FS.ScanCold("actionbars") end) end end
function H.UPDATE_MACROS() if ready() then FS.Schedule("cold_macros", 3, function() FS.ScanCold("macros") end) end end
H.QUEST_DETAIL, H.QUEST_FINISHED = open("quest"), close("quest")
H.QUEST_COMPLETE = open("quest")

function H.PLAYER_INTERACTION_MANAGER_FRAME_SHOW(kind)
	local k = INTERACTION[Clean(kind) or -1]
	if k == "bank" then return H.BANKFRAME_OPENED() end
	if k == "mail" then return H.MAIL_SHOW() end
	if k == "merchant" then return H.MERCHANT_SHOW() end
	if k == "auction" then return H.AUCTION_HOUSE_SHOW() end
	if k then state.interaction[k] = true end
	if Clean(kind) == 6 then FS.Schedule("taxi", 0.3, FS.ScanTaxi) end
end

function H.PLAYER_INTERACTION_MANAGER_FRAME_HIDE(kind)
	local k = INTERACTION[Clean(kind) or -1]
	if k == "bank" then return H.BANKFRAME_CLOSED() end
	if k then close(k)() end
end

function H.TRADE_SKILL_SHOW()
	state.interaction.craft = true
	FS.Schedule("recipes", 1, FS.ScanRecipes)
end
function H.TRADE_SKILL_LIST_UPDATE()
	FS.Schedule("recipes", 1, FS.ScanRecipes)
end
function H.TRADE_SKILL_CLOSE()
	state.interaction.craft = nil
	FS.Schedule("inventory", 0.3, FS.ScanInventory)
end

local function QuestTitle(qid)
	if state.questLog and state.questLog[qid] then return state.questLog[qid].title end
	return Clean((Call("C_QuestLog.GetTitleForQuestID", qid)))
end

function H.QUEST_ACCEPTED(a, b)
	local qid = Clean(b) or Clean(a)
	if type(qid) ~= "number" then return end
	FS.Schedule("questaccept" .. qid, 0.5, function()
		Emit("QUEST_ACCEPTED", { questID = qid, title = QuestTitle(qid) })
		FS.ScanQuests(true)
	end)
end

function H.QUEST_TURNED_IN(qid, xp, money)
	qid = Clean(qid)
	if not qid then return end
	state.turnedIn[qid] = true
	Emit("QUEST_COMPLETED", { questID = qid, title = QuestTitle(qid), xp = Clean(xp), money = Clean(money) })
	if char then
		local list = char.snapshot.questsCompleted
		if type(list) == "table" then list[#list + 1] = qid end
		char.questTitles = char.questTitles or {}
		local title = QuestTitle(qid)
		if title then char.questTitles[qid] = title end
	end
	FS.Schedule("completed", 3, function()
		local c = CompletedQuests()
		if c then char.snapshot.questsCompleted = c; char.snapshot.questsCompletedAt = now() end
	end)
end

function H.QUEST_REMOVED(qid)
	qid = Clean(qid)
	if not qid then return end
	local title = QuestTitle(qid)
	FS.Schedule("questremoved" .. qid, 1.5, function()
		if state.turnedIn[qid] then return end
		if Clean((Call("C_QuestLog.IsQuestFlaggedCompleted", qid))) then return end
		Emit("QUEST_ABANDONED", { questID = qid, title = title }, { confidence = "medium" })
		FS.ScanQuests(true)
	end)
end

function H.QUEST_LOG_UPDATE()
	if not state.ready then return end
	FS.Schedule("questlog", 0.5, FS.ScanQuests)
end
H.UNIT_QUEST_LOG_CHANGED = function(unit) if unit == "player" then H.QUEST_LOG_UPDATE() end end

function H.SKILL_LINES_CHANGED()
	if not state.ready then return end
	FS.Schedule("skills", 0.5, FS.ScanSkills)
end

function H.NEW_RECIPE_LEARNED(recipeID)
	recipeID = Clean(recipeID)
	local name
	local r = recipeID and Call("C_TradeSkillUI.GetRecipeInfo", recipeID)
	if type(r) == "table" then name = Clean(r.name) end
	name = name or (recipeID and Clean((Call("C_Spell.GetSpellName", recipeID))))
	state.recipesEmitted = state.recipesEmitted or {}
	if recipeID then state.recipesEmitted[recipeID] = true end
	Emit("RECIPE_LEARNED", { recipeID = recipeID, name = name })
end

function H.LEARNED_SPELL_IN_SKILL_LINE(spellID)
	spellID = Clean(spellID)
	if not spellID then return end
	state.spellsEmitted = state.spellsEmitted or {}
	if state.spellsEmitted[spellID] or (state.spells and state.spells[spellID]) then return end
	state.spellsEmitted[spellID] = true
	Emit("SPELL_LEARNED", { spellID = spellID, name = Clean((Call("C_Spell.GetSpellName", spellID))) })
end

function H.SPELLS_CHANGED()
	if not state.ready then return end
	FS.Schedule("spells", 2, FS.ScanSpells)
end

function H.CHARACTER_POINTS_CHANGED()
	if not state.ready then return end
	FS.Schedule("talents", 1, FS.ScanTalents)
end
H.PLAYER_TALENT_UPDATE = H.CHARACTER_POINTS_CHANGED
H.TRAIT_CONFIG_UPDATED = H.CHARACTER_POINTS_CHANGED
H.TRAIT_TREE_CURRENCY_INFO_UPDATED = H.CHARACTER_POINTS_CHANGED -- Legacy Points gained/spent
H.ACTIVE_TALENT_GROUP_CHANGED = H.CHARACTER_POINTS_CHANGED


function H.UPDATE_FACTION()
	if ready() then FS.Schedule("rep", 2, FS.ScanReputation) end
end

function H.MAJOR_FACTION_RENOWN_LEVEL_CHANGED(factionID, newLevel, oldLevel)
	factionID = Clean(factionID)
	local name = (factionID == FS.Collect.LEGACY_TRACK_FACTION and "Legacy reward track")
		or (factionID == FS.Collect.PVP_RANK_FACTION and "PvP rank") or nil
	Emit("RENOWN_CHANGED", { factionID = factionID, name = name, from = Clean(oldLevel), to = Clean(newLevel) })
	if ready() then
		FS.Schedule("talents", 1, FS.ScanTalents)
		FS.Schedule("pvp", 2, FS.ScanPvP)
	end
end

function H.CURRENCY_DISPLAY_UPDATE()
	if ready() then FS.Schedule("currency", 3, FS.ScanCurrencies) end
end

function H.KNOWN_TITLES_UPDATE(unit)
	if ready() and (unit == nil or Clean(unit) == "player") then FS.Schedule("titles", 1, FS.ScanTitles) end
end

function H.NEW_MOUNT_ADDED(mountID)
	mountID = Clean(mountID)
	if mountID then
		MarkAnnounced("MOUNT_LEARNED", mountID)
		Emit("MOUNT_LEARNED", { id = mountID, name = Clean((Call("C_MountJournal.GetMountInfoByID", mountID))) })
	end
	if ready() then FS.Schedule("collections", 2, FS.ScanCollections) end
end

function H.NEW_PET_ADDED(guid)
	local species, _, _, _, _, _, _, name = Call("C_PetJournal.GetPetInfoByPetID", Clean(guid))
	species = Clean(species)
	if species then
		MarkAnnounced("PET_LEARNED", species)
		Emit("PET_LEARNED", { speciesID = species, name = Clean(name) })
	end
	if ready() then FS.Schedule("collections", 2, FS.ScanCollections) end
end

function H.COMPANION_LEARNED()
	if ready() then FS.Schedule("collections", 2, FS.ScanCollections) end
end

function H.NEW_TOY_ADDED(itemID)
	itemID = Clean(itemID)
	if itemID then
		MarkAnnounced("TOY_LEARNED", itemID)
		local _, name = Call("C_ToyBox.GetToyInfo", itemID)
		Emit("TOY_LEARNED", { id = itemID, name = Clean(name) })
	end
	if ready() then FS.Schedule("collections", 2, FS.ScanCollections) end
end

function H.MAP_EXPLORATION_UPDATED()
	if ready() then FS.Schedule("explorehere", 1, FS.ScanExploredHere) end
end

function H.ACHIEVEMENT_EARNED(achievementID, alreadyEarned)
	achievementID = Clean(achievementID)
	if not achievementID then return end
	local _, name, points = Call("GetAchievementInfo", achievementID)
	local lp = Clean((Call("C_Traits.GetTraitCurrencyForAchievement", FS.Collect.LEGACY_POINTS_CURRENCY, achievementID)))
	Emit("ACHIEVEMENT_EARNED", { achievementID = achievementID, name = Clean(name), points = Clean(points),
		legacyPoints = (lp and lp > 0) and lp or nil, alreadyEarnedOnAccount = Clean(alreadyEarned) or nil })
	if char and char.achievements and char.achievements.list then
		local a = char.achievements.list[achievementID] or { n = Clean(name), p = Clean(points), lp = (lp and lp > 0) and lp or nil }
		if not a.done then
			a.done, a.q, a.todo, a.qty, a.account = true, nil, nil, nil, nil
			a.d = date and Try(date, "%Y-%m-%d") or nil
			char.achievements.earned = (char.achievements.earned or 0) + 1
		end
		char.achievements.list[achievementID] = a
	end
	if ready() then
		FS.Schedule("titles", 2, FS.ScanTitles)
		FS.Schedule("talents", 2, FS.ScanTalents)
	end
end

function H.UNIT_AURA(unit)
	if ready() and Clean(unit) == "player" then FS.Schedule("buffs", 3, FS.ScanBuffs) end
end

function H.UPDATE_INVENTORY_DURABILITY()
	if ready() then FS.Schedule("stats", 2, FS.ScanStats) end
end

function H.EQUIPMENT_SETS_CHANGED()
	if ready() then FS.Schedule("eqsets", 1, FS.ScanEquipmentSets) end
end

function H.UPDATE_INSTANCE_INFO()
	if ready() then FS.Schedule("lockouts", 1, FS.ScanLockouts) end
end

function H.PLAYER_GUILD_UPDATE(unit)
	if ready() then FS.Schedule("small", 2, FS.ScanSmall) end
end

function H.PLAYER_PVP_KILLS_CHANGED(unit)
	if ready() then FS.Schedule("pvp", 5, FS.ScanPvP) end
end
H.HONOR_XP_UPDATE = H.PLAYER_PVP_KILLS_CHANGED

function H.TAXIMAP_OPENED()
	FS.Schedule("taxi", 0.3, FS.ScanTaxi)
end

-- Zone changes settle for ZONE_SETTLE seconds before they're recorded, so walking back and
-- forth along a zone border yields one event (or none, if you end up where you started).
local ZONE_SETTLE = 20
function FS.FlushZone()
	if not char or not state.zoneFrom then return end
	local l = char.snapshot.location or {}
	local from = state.zoneFrom
	state.zoneFrom = nil
	if l.zone and (l.zone ~= from.zone or l.mapID ~= from.mapID) then
		Emit("ZONE_CHANGED", { zone = l.zone, subzone = l.subzone, mapID = l.mapID, from = from.zone, fromMapID = from.mapID })
	end
end

function H.ZONE_CHANGED_NEW_AREA()
	if not char then return end
	local before = char.snapshot.location or {}
	local l = Location()
	char.snapshot.location = l
	if l.zone ~= before.zone or l.mapID ~= before.mapID then
		if not state.zoneFrom then state.zoneFrom = { zone = before.zone, mapID = before.mapID } end
		FS.Schedule("zone", ZONE_SETTLE, FS.FlushZone)
	end
	CheckInstance()
	MarkDirty()
end
function H.ZONE_CHANGED() MarkDirty() end
H.ZONE_CHANGED_INDOORS = H.ZONE_CHANGED

function H.ENCOUNTER_START(encounterID, name, difficultyID, size)
	state.encounter = { encounterID = Clean(encounterID), name = Clean(name), started = now() }
end

function H.ENCOUNTER_END(encounterID, name, difficultyID, size, success)
	local p = { encounterID = Clean(encounterID), name = Clean(name), difficultyID = Clean(difficultyID), groupSize = Clean(size),
		instance = state.instanceInfo and state.instanceInfo.name }
	if state.encounter and state.encounter.started then p.duration = now() - state.encounter.started end
	state.encounter = nil
	if Clean(success) == 1 or Clean(success) == true then
		Emit("BOSS_KILLED", p)
		FS.Schedule("raidinfo", 5, function() Call("RequestRaidInfo") end)
	else
		Emit("BOSS_WIPE", p)
	end
end

function H.PLAYER_DEAD()
	local l = Location()
	Emit("DEATH", { zone = l.zone, subzone = l.subzone, mapID = l.mapID, x = l.x, y = l.y, instance = l.inInstance and l.instance.name or nil, level = char and char.snapshot.level })
end

function H.PLAYER_MONEY()
	if not char or not state.ready then return end
	local m = Clean((Call("GetMoney")))
	if not m then return end
	local last = state.money or m
	local g = state.gold
	if not g.first then g.first = clock(); g.from = last end
	g.delta = g.delta + (m - last)
	state.money = m
	char.snapshot.money = m
	if clock() - g.first > 60 then FlushGold() else FS.Schedule("gold", 10, FlushGold) end
end

function H.HEARTHSTONE_BOUND()
	local loc = Clean((Call("GetBindLocation")))
	if char then char.snapshot.hearth = loc end
	Emit("HEARTH_BOUND", { location = loc })
end

function H.TIME_PLAYED_MSG(total, level)
	if not char then return end
	char.snapshot.played = { total = Clean(total), level = Clean(level), at = now() }
end

FS.EVENTS = {}
for k in pairs(H) do FS.EVENTS[#FS.EVENTS + 1] = k end
table.sort(FS.EVENTS)

---------------------------------------------------------------------------
-- Frame
---------------------------------------------------------------------------

local frame = CreateFrame("Frame", "ForeverScribeFrame")
FS.frame = frame
FS.registered = {}
for _, ev in ipairs(FS.EVENTS) do
	if pcall(frame.RegisterEvent, frame, ev) then FS.registered[ev] = true end
end
frame:SetScript("OnEvent", function(_, event, ...)
	local h = H[event]
	if not h then return end
	local ok, err = pcall(h, ...)
	if not ok then
		FS.errors = (FS.errors or 0) + 1
		FS.lastError = event .. ": " .. tostring(err)
	end
end)

---------------------------------------------------------------------------
-- Live bridge hook (module is a separate load-on-demand addon)
---------------------------------------------------------------------------

function FS.SetLive(on, quiet)
	db.settings.live = on and true or false
	if on then
		if not FS.Live then
			local load = U.Fn("C_AddOns.LoadAddOn") or U.Fn("LoadAddOn")
			local loaded, reason = Try(load, "ForeverScribe_Live")
			if not FS.Live then
				db.settings.live = false
				if not quiet then Print("live module not available (" .. tostring(reason or loaded) .. "). Is ForeverScribe_Live installed and enabled?") end
				return false
			end
		end
		FS.Live.Enable()
		if not quiet then Print("live strip ON (top-left corner). /scribe live off to stop.") end
	else
		if FS.Live then FS.Live.Disable() end
		if not quiet then Print("live strip OFF.") end
	end
	return true
end

---------------------------------------------------------------------------
-- Slash command
---------------------------------------------------------------------------

local function fmtAge(t)
	if not t then return "never" end
	local d = now() - t
	if d < 90 then return d .. "s ago" end
	if d < 5400 then return math.floor(d / 60) .. "m ago" end
	return math.floor(d / 3600) .. "h ago"
end

local function describe(ev)
	local p = ev.payload or {}
	local bits = {}
	for _, k in ipairs({ "name", "title", "skill", "zone", "level", "qty", "to", "delta", "slot" }) do
		if p[k] ~= nil then bits[#bits + 1] = k .. "=" .. tostring(p[k]) end
	end
	return ev.type .. " " .. table.concat(bits, " ")
end

function FS.Slash(msg)
	local raw = tostring(msg or ""):gsub("^%s+", "")
	if raw:lower():match("^way%s") or raw:lower():match("^way$") then
		if FS.Way then FS.Way.Command(raw:sub(4)) else Print("waypoints need Waypoint.lua (restart the game after updating)") end
		return
	end
	msg = (msg or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
	local cmd, arg = msg:match("^(%S*)%s*(.-)$")
	if cmd == "" or cmd == "status" then
		if not char then Print("not ready yet") return end
		Print(string.format("v%s  %s  session %s  events %d (dropped %d)  snapshot %s  errors %d  live %s",
			FS.VERSION, FS.charKey or "?", tostring(session), #char.events, char.dropped or 0,
			fmtAge(char.snapshot.capturedAt), FS.errors or 0, db.settings.live and "on" or "off"))
		Print("Data reaches your agent after /reload or logout. /scribe help for commands.")
	elseif cmd == "last" or cmd == "events" then
		if not char then return end
		local n = tonumber(arg) or 10
		local evs = char.events
		for i = math.max(1, #evs - n + 1), #evs do Print(evs[i].id .. "  " .. describe(evs[i])) end
	elseif cmd == "live" then
		if arg == "on" then FS.SetLive(true) elseif arg == "off" then FS.SetLive(false)
		else Print("live is " .. (db.settings.live and "on" or "off") .. " (use /scribe live on|off)") end
	elseif cmd == "snapshot" then
		FS.SnapshotFull(); FS.ScanInventory(true); FS.ScanAll(false)
		Print("snapshot refreshed; /reload to hand it to your agent")
	elseif cmd == "error" or cmd == "errors" then
		Print("errors: " .. tostring(FS.errors or 0) .. " last: " .. tostring(FS.lastError))
	elseif cmd == "remind" then
		if arg == "off" or arg == "0" then db.settings.remind = 0
		elseif tonumber(arg) then db.settings.remind = math.max(5, math.floor(tonumber(arg)))
		elseif arg == "default" then db.settings.remind = nil end
		local m = FS.ReminderMinutes()
		Print(m > 0 and ("save reminder every " .. m .. " min without a /reload (/scribe remind off)") or "save reminder off (/scribe remind 30 to turn on)")
	elseif cmd == "go" then
		if FS.Route then FS.Route.Go() else Print("routes need ForeverScribe 0.5 (restart the game after updating)") end
	elseif cmd == "next" or cmd == "skip" then
		if FS.Route then FS.Route.Advance(1) end
	elseif cmd == "back" or cmd == "prev" then
		if FS.Route then FS.Route.Advance(-1) end
	elseif cmd == "route" then
		if FS.Route then FS.Route.Command(arg) end
	elseif cmd == "npcs" or cmd == "npc" then
		if FS.Npcs then FS.Npcs.Command(arg) end
	elseif cmd == "tooltip" or cmd == "prices" then
		if FS.Tooltip then FS.Tooltip.Command(arg) else Print("the price tooltip needs ForeverScribe 0.6 (restart the game after updating)") end
	elseif cmd == "craftprices" or cmd == "craft" then
		if FS.Craft then FS.Craft.Command(arg) else Print("craft prices need ForeverScribe 0.8 (restart the game after updating)") end
	elseif cmd == "guide" or cmd == "polestar" then
		if FS.Guide then FS.Guide.Command() else Print("reading Polestar needs ForeverScribe 0.7 (restart the game after updating)") end
	elseif cmd == "played" then
		db.settings.played = (arg ~= "off")
		Print("/played request at login " .. (db.settings.played and "on" or "off"))
	else
		Print("/scribe status | last [n] | live on|off | snapshot | errors | played on|off | remind <min>|off | way <x> <y> [zone] [title] | go | next | back | route [clear] | npcs | tooltip on|off|shift | craftprices on|off | guide")
	end
end

SLASH_FOREVERSCRIBE1 = "/scribe"
SLASH_FOREVERSCRIBE2 = "/fscribe"
SLASH_FOREVERSCRIBE3 = "/fs"
-- Never reassign the SlashCmdList global itself (that would taint it); only add our key.
SlashCmdList["FOREVERSCRIBE"] = FS.Slash

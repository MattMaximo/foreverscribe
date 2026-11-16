-- ForeverScribe v0.2 collectors: read-only readers for everything Forever
-- exposes about the character. Each reader returns plain data, or nil when the
-- read came back empty (UI teardown, API missing, data not loaded yet) so the
-- caller never overwrites good data with an empty read. No reader mutates game
-- or UI state: no header expanding, no filter changes, no protected calls.
-- Every API name used here exists in Forever's generated API docs or in
-- Forever's own UI code (checked by tools/check_api.py).

local FS = ForeverScribe
local U = FS.Util
local Try, Call, Clean = U.Try, U.Call, U.Clean

local C = {}
FS.Collect = C

-- Forever constants (Blizzard_APIDocumentationGenerated: LegacyConstants, MajorFactionsConstants)
C.LEGACY_TRACK_FACTION = 2802
C.LEGACY_POINTS_CURRENCY = 4225
C.LEGACY_TREES = { { id = 1187, key = "professions", name = "Professions" },
	{ id = 1188, key = "adventure", name = "Adventure" }, { id = 1189, key = "progression", name = "Progression" } }
C.PVP_RANK_FACTION = 2800

-- Budgets that keep ForeverScribe.lua small (see tests "size bound").
C.CAP = {
	factions = 400, nodes = 700, achievements = 1500, criteriaText = 1500, stats = 500, zones = 250,
	mounts = 1000, pets = 1000, toys = 1000, currencies = 200, buffs = 40, mail = 50, mailItems = 12,
	questTitles = 3000, lockouts = 60,
}

local function now() return (Try(time)) or 0 end
local function num(v) v = Clean(v); return type(v) == "number" and v or nil end
local function str(v, max)
	v = Clean(v)
	if type(v) ~= "string" or v == "" then return nil end
	if max and #v > max then v = v:sub(1, max) end
	return v
end
local function bool(v) v = Clean(v); if v == nil then return nil end return (v and v ~= 0) and true or nil end
local function list(t) return type(t) == "table" and t or {} end

local spellNames = {}
local function SpellName(id)
	if not id then return nil end
	if spellNames[id] == nil then
		spellNames[id] = str((Call("C_Spell.GetSpellName", id))) or false
	end
	return spellNames[id] or nil
end
C.SpellName = SpellName

---------------------------------------------------------------------------
-- Reputation
---------------------------------------------------------------------------

local function FactionEntry(f, group)
	if type(f) ~= "table" then return nil end
	local id, name = num(f.factionID), str(f.name)
	if not id or not name then return nil end
	return {
		id = id, name = name, standing = num(f.reaction), value = num(f.currentStanding),
		min = num(f.currentReactionThreshold), max = num(f.nextReactionThreshold),
		atWar = bool(f.atWarWith), canWar = bool(f.canToggleAtWar), watched = bool(f.isWatched),
		accountWide = bool(f.isAccountWide), group = group,
	}
end

-- known: previous reputation section (to refresh factions hidden under collapsed headers).
function C.Reputation(known)
	local n = num((Call("C_Reputation.GetNumFactions"))) or 0
	local factions, seen, collapsed = {}, {}, {}
	local top, group
	for i = 1, math.min(n, C.CAP.factions * 2) do
		if #factions >= C.CAP.factions then break end
		local f = Call("C_Reputation.GetFactionDataByIndex", i)
		if type(f) == "table" then
			local name = str(f.name)
			if Clean(f.isHeader) then
				if Clean(f.isChild) then group = name else top, group = name, name end
				if Clean(f.isCollapsed) and name then collapsed[#collapsed + 1] = name end
			end
			if not Clean(f.isHeader) or Clean(f.isHeaderWithRep) then
				local e = FactionEntry(f, (Clean(f.isHeader) and top) or group)
				if e and not seen[e.id] then seen[e.id] = true; factions[#factions + 1] = e end
			end
		end
	end
	if #factions == 0 then return nil end
	-- Factions we saw before but that are now inside a collapsed header: refresh by ID.
	for _, old in ipairs(list(known and known.factions)) do
		if type(old) == "table" and old.id and not seen[old.id] and #factions < C.CAP.factions then
			local e = FactionEntry(Call("C_Reputation.GetFactionDataByID", old.id), old.group)
			if e then e.hidden = true; seen[e.id] = true; factions[#factions + 1] = e end
		end
	end
	local w = Call("C_Reputation.GetWatchedFactionData")
	return {
		factions = factions, count = #factions, watched = type(w) == "table" and num(w.factionID) or nil,
		collapsedHeaders = #collapsed > 0 and collapsed or nil, scannedAt = now(),
	}
end

-- Renown-style "major faction" progress (Forever uses it for PvP rank and the Legacy reward track).
function C.MajorFaction(id)
	local p = Call("C_MajorFactions.GetMajorFactionProgressionInfo", id)
	local out
	if type(p) == "table" then
		out = { level = num(p.renownLevel), earned = num(p.renownReputationEarned), threshold = num(p.renownLevelThreshold),
			maxLevel = num(p.maxLevel), weekMax = num(p.currentWeekProgressiveMaxLevel),
			prevWeekMax = num(p.previousWeekProgressiveMaxLevel), week = num(p.weekNumber) }
	end
	local d = Call("C_MajorFactions.GetMajorFactionData", id)
	if type(d) == "table" then
		out = out or {}
		out.name = str(d.name)
		out.level = out.level or num(d.renownLevel)
		out.maxLevel = out.maxLevel or num(d.maxLevel)
		out.earned = out.earned or num(d.renownReputationEarned)
		out.threshold = out.threshold or num(d.renownLevelThreshold)
		out.unlocked = bool(d.isUnlocked)
	end
	if not out then
		local lvl = num((Call("C_MajorFactions.GetCurrentRenownLevel", id)))
		if lvl then out = { level = lvl } end
	end
	return out
end

---------------------------------------------------------------------------
-- Talents (C_Traits on Forever; classic GetTalentInfo fallback)
---------------------------------------------------------------------------

local function TreeCurrency(configID, treeID)
	local t = Call("C_Traits.GetTreeCurrencyInfo", configID, treeID, false)
	local c = type(t) == "table" and t[1]
	if type(c) ~= "table" then return nil end
	return { currencyID = num(c.traitCurrencyID), unspent = num(c.quantity), max = num(c.maxQuantity),
		spent = num(c.spent), spentInTree = num(c.spentInTree) }
end

local function EntrySpell(configID, entryID)
	if not entryID then return nil end
	local ei = Call("C_Traits.GetEntryInfo", configID, entryID)
	local defID = type(ei) == "table" and num(ei.definitionID)
	local def = defID and Call("C_Traits.GetDefinitionInfo", defID)
	if type(def) ~= "table" then return nil, nil, type(ei) == "table" and num(ei.maxRanks) or nil end
	local sid = num(def.spellID)
	return sid, str(def.overrideName) or SpellName(sid), num(ei.maxRanks)
end

-- Read one trait tree for a config. ranks/meta are filled with "<prefix><nodeID>" keys.
local function TraitTree(configID, treeID, prefix, ranks, meta, treeName, groupNames)
	local nodes = Call("C_Traits.GetTreeNodes", treeID)
	if type(nodes) ~= "table" or #nodes == 0 then return nil end
	local tree = { treeID = treeID, configID = configID, name = treeName, currency = TreeCurrency(configID, treeID), talents = {} }
	local taken = 0
	for k, nodeID in ipairs(nodes) do
		if k > C.CAP.nodes then break end
		nodeID = num(nodeID)
		local ni = nodeID and Call("C_Traits.GetNodeInfo", configID, nodeID)
		if type(ni) == "table" and num(ni.ID) ~= 0 then
			local rank = num(ni.activeRank) or num(ni.currentRank) or 0
			local visible = Clean(ni.isVisible)
			if rank > 0 or visible ~= false then
				local active = type(ni.activeEntry) == "table" and num(ni.activeEntry.entryID) or nil
				local entries = list(ni.entryIDs)
				local sid, name, emax = EntrySpell(configID, active or num(entries[1]))
				local node = { nodeID = nodeID, rank = rank, max = num(ni.maxRanks) or emax, spellID = sid, name = name,
					type = num(ni.type) }
				if #entries > 1 then
					local opts = {}
					for j = 1, math.min(#entries, 4) do
						local _, oname = EntrySpell(configID, num(entries[j]))
						opts[#opts + 1] = oname or "?"
					end
					node.options = opts
				end
				if groupNames then
					for _, g in ipairs(list(ni.groupIDs)) do
						if groupNames[num(g) or -1] then node.group = groupNames[num(g)]; break end
					end
				end
				if Clean(ni.canPurchaseRank) and rank < (node.max or 1) then node.canBuy = true end
				tree.talents[#tree.talents + 1] = node
				if rank > 0 then taken = taken + rank end
				if ranks then
					ranks[prefix .. nodeID] = rank
					if meta then meta[prefix .. nodeID] = { name = name, tree = treeName, max = node.max } end
				end
			end
		end
	end
	tree.points = taken
	if #tree.talents == 0 then return nil end
	return tree
end
C.TraitTree = TraitTree

local function ClassicTalents()
	local tabs = num((Call("GetNumTalentTabs")))
	if not tabs or tabs == 0 then return nil end
	local out, ranks, meta = { system = "classic", trees = {} }, {}, {}
	for t = 1, tabs do
		local a, b, c, d, e = Call("GetTalentTabInfo", t)
		local tname, points = Clean(a), nil
		if type(tname) == "number" then tname, points = Clean(b), Clean(e) else points = Clean(c) end
		local tree = { name = tname, points = points, talents = {} }
		local n = num((Call("GetNumTalents", t))) or 0
		for i = 1, n do
			local name, _, tier, col, rank, maxRank = Call("GetTalentInfo", t, i)
			rank = num(rank) or 0
			tree.talents[#tree.talents + 1] = { name = str(name), tier = num(tier), col = num(col), rank = rank, max = num(maxRank) }
			ranks[t .. ":" .. i] = rank
			meta[t .. ":" .. i] = { name = str(name), tree = tname, max = num(maxRank) }
		end
		out.trees[t] = tree
	end
	out.unspent = num((Call("UnitCharacterPoints", "player")))
	return out, ranks, meta
end

-- Returns talents, ranks, meta. Talents include every visible node (rank 0 = not taken).
function C.Talents()
	local cl, cr, cm = ClassicTalents()
	if cl then return cl, cr, cm end
	local configID = num((Call("C_ClassTalents.GetActiveConfigID")))
	if not configID then return nil end
	local out, ranks, meta = { system = "traits", configID = configID, trees = {} }, {}, {}
	out.activeGroup = num((Call("C_SpecializationInfo.GetActiveSpecGroup", false, false)))
	out.numGroups = num((Call("GetNumSpecGroups")))
	local cfg = Call("C_Traits.GetConfigInfo", configID)
	if type(cfg) == "table" then out.loadout = str(cfg.name) end
	for _, treeID in ipairs(type(cfg) == "table" and list(cfg.treeIDs) or {}) do
		treeID = num(treeID)
		if treeID then
			-- Forever's class tree is split into groups (the old Arcane/Fire/Frost tabs).
			local groupNames, groups = {}, {}
			local disp = Call("C_Traits.GetGroupDisplayInfoByTreeID", treeID)
			local gids = {}
			for _, g in ipairs(list(disp)) do
				local gid = type(g) == "table" and num(g.groupID)
				if gid then
					groupNames[gid] = str(g.displayName) or ("group " .. gid)
					gids[#gids + 1] = gid
					groups[#groups + 1] = { groupID = gid, name = groupNames[gid], order = num(g.orderIndex) }
				end
			end
			if #gids > 0 then
				local gc = Call("C_Traits.GetGroupCurrencyInfo", configID, gids)
				for _, info in ipairs(list(gc)) do
					local ci = type(info) == "table" and list(info.currencyInfos)[1]
					for _, g in ipairs(groups) do
						if type(info) == "table" and num(info.traitNodeGroupID) == g.groupID and type(ci) == "table" then
							g.spent = num(ci.spent)
						end
					end
				end
			end
			local tree = TraitTree(configID, treeID, "n", ranks, meta, nil, groupNames)
			if tree then
				if #groups > 0 then tree.groups = groups end
				out.trees[#out.trees + 1] = tree
				if tree.currency and out.unspent == nil then out.unspent = tree.currency.unspent end
			end
		end
	end
	-- Dual spec: the other group's config, taken nodes only.
	if (out.numGroups or 1) > 1 then
		out.specGroups = {}
		for g = 1, out.numGroups do
			local cid = num((Call("C_SpecializationInfo.GetCombatConfigIDForSpecGroup", g)))
			if cid then
				local entry = { group = g, configID = cid, active = (cid == configID) or nil }
				if cid ~= configID then
					local cfg2 = Call("C_Traits.GetConfigInfo", cid)
					entry.taken = {}
					for _, treeID in ipairs(type(cfg2) == "table" and list(cfg2.treeIDs) or {}) do
						local t2 = TraitTree(cid, num(treeID))
						for _, node in ipairs(t2 and t2.talents or {}) do
							if node.rank > 0 then entry.taken[#entry.taken + 1] = { nodeID = node.nodeID, rank = node.rank, name = node.name } end
						end
					end
				end
				out.specGroups[#out.specGroups + 1] = entry
			end
		end
	end
	if out.unspent == nil then out.unspent = num((Call("UnitCharacterPoints", "player"))) end
	if #out.trees == 0 then return nil end
	return out, ranks, meta
end

---------------------------------------------------------------------------
-- Legacy (Forever's progression system: Legacy Points from Legacy Challenges,
-- spent in three Legacy trait trees, plus the Legacy reward track)
---------------------------------------------------------------------------

function C.Legacy(ranks, meta)
	local out = { trees = {} }
	for _, t in ipairs(C.LEGACY_TREES) do
		local cid = num((Call("C_Traits.GetConfigIDByTreeID", t.id)))
		if cid then
			local tree = TraitTree(cid, t.id, "L", ranks, meta, "Legacy " .. t.name)
			if tree then tree.key = t.key; out.trees[#out.trees + 1] = tree end
			if tree and tree.currency and not out.points then out.points = tree.currency end
		end
	end
	local maxAvail = num((Call("C_Traits.GetMaxAvailableTraitCurrency", C.LEGACY_POINTS_CURRENCY, false)))
	if maxAvail then out.points = out.points or {}; out.points.maxAvailable = maxAvail end
	out.track = C.MajorFaction(C.LEGACY_TRACK_FACTION)
	if #out.trees == 0 and not out.track and not out.points then return nil end
	out.unlocked = (out.track and (out.track.level or 0) > 0) or nil
	return out
end

---------------------------------------------------------------------------
-- Achievements / Legacy Challenges and statistics
---------------------------------------------------------------------------

local function AchDate(month, day, year)
	month, day, year = num(month), num(day), num(year)
	if not (month and day and year) then return nil end
	if year < 100 then year = year + 2000 end
	return string.format("%04d-%02d-%02d", year, month, day)
end

local function Criteria(id, budget)
	local n = num((Call("GetAchievementNumCriteria", id))) or 0
	if n == 0 then return nil end
	local done, todo, qty = 0, {}, nil
	for j = 1, math.min(n, 40) do
		local text, _, completed, quantity, req = Call("GetAchievementCriteriaInfo", id, j)
		if Clean(completed) then
			done = done + 1
		else
			text = str(text, 48)
			if text and budget.left > 0 and #todo < 6 then todo[#todo + 1] = text; budget.left = budget.left - 1 end
		end
		if n == 1 and num(req) and num(req) > 1 then qty = (num(quantity) or 0) .. "/" .. num(req) end
	end
	return done .. "/" .. n, (#todo > 0) and todo or nil, qty
end

function C.Achievements()
	local cats = Call("GetCategoryList")
	if type(cats) ~= "table" or #cats == 0 then return nil end
	local out = { categories = {}, list = {}, total = 0, earned = 0, earnedAccount = 0 }
	local budget = { left = C.CAP.criteriaText }
	out.points = num((Call("GetTotalAchievementPoints")))
	for _, cat in ipairs(cats) do
		cat = num(cat)
		if cat and out.total < C.CAP.achievements then
			local cname, parent = Call("GetCategoryInfo", cat)
			local n = num((Call("GetCategoryNumAchievements", cat, true))) or num((Call("GetCategoryNumAchievements", cat))) or 0
			local ce = { name = str(cname), parent = num(parent), n = 0, done = 0 }
			for i = 1, n do
				if out.total >= C.CAP.achievements then break end
				local id, name, points, completed, month, day, year, _, _, _, _, _, mine = Call("GetAchievementInfo", cat, i)
				id = num(id)
				if id and not out.list[id] then
					local a = { n = str(name, 80), c = cat }
					-- Forever shows Legacy Points on challenges instead of achievement points.
					a.lp = num((Call("C_Traits.GetTraitCurrencyForAchievement", C.LEGACY_POINTS_CURRENCY, id)))
					if a.lp == 0 then a.lp = nil end
					if not a.lp and num(points) and num(points) > 0 then a.p = num(points) end
					local accDone, mineDone = Clean(completed) and true or false, Clean(mine) and true or false
					if accDone then
						out.earnedAccount = out.earnedAccount + 1
						a.d = AchDate(month, day, year)
					end
					if accDone and (mineDone or Clean(mine) == nil) then
						a.done = true; out.earned = out.earned + 1; ce.done = ce.done + 1
					else
						if accDone then a.account = true end -- earned by another character on the account
						a.q, a.todo, a.qty = Criteria(id, budget)
					end
					out.list[id] = a
					out.total = out.total + 1
					ce.n = ce.n + 1
				end
			end
			out.categories[cat] = ce
		end
	end
	if out.total == 0 then return nil end
	out.scannedAt = now()
	return out
end

function C.Statistics()
	local cats = Call("GetStatisticsCategoryList")
	if type(cats) ~= "table" or #cats == 0 then return nil end
	local out, count = { values = {} }, 0
	for _, cat in ipairs(cats) do
		cat = num(cat)
		local cname = cat and str((Call("GetCategoryInfo", cat)))
		local n = cat and num((Call("GetCategoryNumAchievements", cat))) or 0
		for i = 1, n do
			if count >= C.CAP.stats then break end
			local quantity, skip, statID = Call("GetStatistic", cat, i)
			statID = num(statID)
			local v = Clean(quantity)
			if statID and not Clean(skip) and v ~= nil and v ~= "--" and v ~= "0" and v ~= 0 then
				local _, name = Call("GetAchievementInfo", statID)
				out.values[statID] = { n = str(name, 80), v = (type(v) == "string" and tonumber(v)) or v, c = cname }
				count = count + 1
			end
		end
	end
	out.count = count
	out.scannedAt = now()
	return out
end

---------------------------------------------------------------------------
-- Exploration
---------------------------------------------------------------------------

local function MapInfo(id) local i = Call("C_Map.GetMapInfo", id); return type(i) == "table" and i or nil end

-- Walk up to the zone-level map (mapType 3) for a player map.
function C.ZoneOf(mapID)
	local guard = 0
	while mapID and guard < 8 do
		guard = guard + 1
		local info = MapInfo(mapID)
		if not info then return nil end
		local mt = num(info.mapType)
		if mt == 3 then return mapID end
		if mt and mt <= 2 then return nil end
		mapID = num(info.parentMapID)
	end
end

function C.ZoneList(currentMapID)
	local zones, seen = {}, {}
	local function addChildren(parent, mapType)
		local kids = Call("C_Map.GetMapChildrenInfo", parent, mapType, false)
		local out = {}
		for _, k in ipairs(list(kids)) do
			local id = type(k) == "table" and num(k.mapID)
			if id and not seen[id] then seen[id] = true; out[#out + 1] = { id = id, name = str(k.name), parent = parent } end
		end
		return out
	end
	local continents = addChildren(947, 2)
	if #continents == 0 and currentMapID then
		local m, guard = currentMapID, 0
		while m and guard < 8 do
			guard = guard + 1
			local info = MapInfo(m)
			if not info then break end
			if num(info.mapType) == 2 then continents = { { id = m, name = str(info.name) } } break end
			m = num(info.parentMapID)
		end
	end
	for _, cont in ipairs(continents) do
		for _, z in ipairs(addChildren(cont.id, 3)) do
			if #zones < C.CAP.zones then z.continent = cont.name; zones[#zones + 1] = z end
		end
	end
	return zones
end

-- Explored overlays for one zone map: { n, ov = {key...}, areas = {name...} }
function C.ExploredZone(mapID)
	local ov = Call("C_MapExplorationInfo.GetExploredMapTextures", mapID)
	if type(ov) ~= "table" then return nil end
	local layers = Call("C_Map.GetMapArtLayers", mapID)
	local layer = type(layers) == "table" and layers[1]
	local lw = type(layer) == "table" and num(layer.layerWidth)
	local lh = type(layer) == "table" and num(layer.layerHeight)
	local makeVec = U.Fn("CreateVector2D")
	local out = { n = 0, ov = {}, areas = {}, keyAreas = {} }
	local seenArea = {}
	for _, o in ipairs(ov) do
		if type(o) == "table" then
			local ids = list(o.fileDataIDs)
			local key = num(ids[1]) or ((num(o.offsetX) or 0) * 10000 + (num(o.offsetY) or 0))
			out.n = out.n + 1
			out.ov[#out.ov + 1] = key
			local r = type(o.hitRect) == "table" and o.hitRect
			if r and lw and lh and lw > 0 and lh > 0 and makeVec then
				local cx = ((num(r.left) or 0) + (num(r.right) or 0)) / 2 / lw
				local cy = ((num(r.top) or 0) + (num(r.bottom) or 0)) / 2 / lh
				local vec = Try(makeVec, cx, cy)
				local areaIDs = vec and Call("C_MapExplorationInfo.GetExploredAreaIDsAtPosition", mapID, vec)
				for _, aid in ipairs(list(areaIDs)) do
					local name = str((Call("C_Map.GetAreaInfo", num(aid) or 0)))
					if name then
						out.keyAreas[key] = out.keyAreas[key] or name
						if not seenArea[name] then seenArea[name] = true; out.areas[#out.areas + 1] = name end
					end
				end
			end
		end
	end
	if #out.areas == 0 then out.areas = nil end
	return out
end

---------------------------------------------------------------------------
-- Titles, collections
---------------------------------------------------------------------------

function C.Titles()
	local n = num((Call("GetNumTitles")))
	if not n or n == 0 then return nil end
	local known, count = {}, 0
	for i = 1, math.min(n, 1000) do
		if Clean((Call("IsTitleKnown", i))) then
			local name = str((Call("GetTitleName", i)))
			if name then known[i] = name:gsub("^%s+", ""):gsub("%s+$", ""); count = count + 1 end
		end
	end
	local cur = num((Call("GetCurrentTitle")))
	return { known = known, count = count, current = (cur and cur > 0) and cur or nil,
		currentName = cur and known[cur] or nil }
end

function C.Mounts()
	local ids = Call("C_MountJournal.GetMountIDs")
	if type(ids) ~= "table" or #ids == 0 then return nil end
	local out, count = {}, 0
	for _, id in ipairs(ids) do
		id = num(id)
		if id and count < C.CAP.mounts then
			local name, spellID, _, _, _, _, _, _, _, hide, collected = Call("C_MountJournal.GetMountInfoByID", id)
			if Clean(collected) then out[id] = { n = str(name), s = num(spellID) }; count = count + 1 end
		end
	end
	return out, count
end

function C.Pets()
	local out, count = {}, 0
	local ids = Call("C_PetJournal.GetOwnedPetIDs")
	if type(ids) == "table" then
		for _, petID in ipairs(ids) do
			if count >= C.CAP.pets then break end
			petID = Clean(petID)
			if petID then
				local species, custom, level, _, _, _, _, name = Call("C_PetJournal.GetPetInfoByPetID", petID)
				species = num(species)
				if species then out[#out + 1] = { s = species, n = str(name), c = str(custom), l = num(level) }; count = count + 1 end
			end
		end
	end
	if count == 0 then
		local n = num((Call("C_PetJournal.GetNumPets"))) or 0
		for i = 1, math.min(n, C.CAP.pets) do
			local _, species, owned, custom, level, _, _, name = Call("C_PetJournal.GetPetInfoByIndex", i)
			if Clean(owned) and num(species) then out[#out + 1] = { s = num(species), n = str(name), c = str(custom), l = num(level) }; count = count + 1 end
		end
	end
	if count == 0 then return nil end
	return out, count
end

-- Toy Box: only the toys the Toy Box's current filter shows (we never change its filters).
function C.Toys()
	local n = num((Call("C_ToyBox.GetNumFilteredToys")))
	if not n or n == 0 then return nil end
	local out, count = {}, 0
	for i = 1, math.min(n, C.CAP.toys) do
		local itemID = num((Call("C_ToyBox.GetToyFromIndex", i)))
		if itemID and itemID > 0 and Clean((Call("PlayerHasToy", itemID))) then
			local _, name = Call("C_ToyBox.GetToyInfo", itemID)
			out[itemID] = str(name) or true
			count = count + 1
		end
	end
	if count == 0 then return nil end
	return out, count
end

---------------------------------------------------------------------------
-- Currencies
---------------------------------------------------------------------------

local function CurrencyEntry(info, id, header)
	if type(info) ~= "table" then return nil end
	id = num(info.currencyID) or id
	local name = str(info.name)
	if not id or not name or Clean(info.isHeader) then return nil end
	local e = { id = id, name = name, qty = num(info.quantity) or 0, max = num(info.maxQuantity), group = header }
	if e.max == 0 then e.max = nil end
	if Clean(info.canEarnPerWeek) then e.week, e.weekMax = num(info.quantityEarnedThisWeek), num(info.maxWeeklyQuantity) end
	if num(info.totalEarned) and num(info.totalEarned) > 0 then e.total = num(info.totalEarned) end
	return e
end

function C.Currencies(knownIDs)
	local n = num((Call("C_CurrencyInfo.GetCurrencyListSize"))) or 0
	local out, seen, header = {}, {}, nil
	for i = 1, math.min(n, C.CAP.currencies) do
		local info = Call("C_CurrencyInfo.GetCurrencyListInfo", i)
		if type(info) == "table" then
			if Clean(info.isHeader) then header = str(info.name) end
			local e = CurrencyEntry(info, nil, header)
			if e and not seen[e.id] then seen[e.id] = true; out[#out + 1] = e end
		end
	end
	for id in pairs(knownIDs or {}) do
		if not seen[id] and #out < C.CAP.currencies then
			local e = CurrencyEntry(Call("C_CurrencyInfo.GetCurrencyInfo", id), id, nil)
			if e then seen[id] = true; out[#out + 1] = e end
		end
	end
	if #out == 0 then return nil end
	return out
end

---------------------------------------------------------------------------
-- Character sheet stats, buffs, durability
---------------------------------------------------------------------------

local STAT_NAMES = { "str", "agi", "sta", "int", "spi" }
local RESIST = { [1] = "holy", [2] = "fire", [3] = "nature", [4] = "frost", [5] = "shadow", [6] = "arcane" }
local SCHOOLS = { [2] = "holy", [3] = "fire", [4] = "nature", [5] = "frost", [6] = "shadow", [7] = "arcane" }
local function round(v, p) if not v then return nil end local m = 10 ^ (p or 2); return math.floor(v * m + 0.5) / m end

function C.Stats()
	local hp = num((Call("UnitHealthMax", "player")))
	if not hp or hp <= 0 then return nil end -- teardown / not in world
	local s = { health = hp }
	local ptype = num((Call("UnitPowerType", "player")))
	s.power = num((Call("UnitPowerMax", "player", ptype)))
	s.powerType = ptype
	local primary = {}
	for i, k in ipairs(STAT_NAMES) do
		local base, eff, pos, neg = Call("UnitStat", "player", i)
		if num(eff) then primary[k] = { base = num(base), eff = num(eff), buff = (num(pos) or 0) + (num(neg) or 0) } end
	end
	s.primary = primary
	local abase, aeff = Call("UnitArmor", "player")
	s.armor = num(aeff) or num(abase)
	local res = {}
	for i, k in pairs(RESIST) do
		local _, _, eff = Call("UnitResistance", "player", i)
		if num(eff) and num(eff) ~= 0 then res[k] = num(eff) end
	end
	if next(res) then s.resist = res end
	local sp, best = {}, 0
	for i, k in pairs(SCHOOLS) do
		local v = num((Call("GetSpellBonusDamage", i)))
		if v then sp[k] = v; if v > best then best = v end end
	end
	s.spellPower = sp
	s.spellPowerMax = best
	s.healing = num((Call("GetSpellBonusHealing")))
	s.spellCrit = round(num((Call("GetSpellCritChance"))))
	s.spellHit = round(num((Call("GetSpellHitModifier"))))
	s.spellHaste = round(num((Call("UnitSpellHaste", "player"))))
	s.spellPen = num((Call("GetSpellPenetration")))
	s.meleeCrit = round(num((Call("GetCritChance"))))
	s.rangedCrit = round(num((Call("GetRangedCritChance"))))
	s.meleeHit = round(num((Call("GetHitModifier"))))
	s.meleeHaste = round(num((Call("GetMeleeHaste"))))
	local ap, apPos, apNeg = Call("UnitAttackPower", "player")
	if num(ap) then s.attackPower = num(ap) + (num(apPos) or 0) + (num(apNeg) or 0) end
	local rap, rPos, rNeg = Call("UnitRangedAttackPower", "player")
	if num(rap) then s.rangedAttackPower = num(rap) + (num(rPos) or 0) + (num(rNeg) or 0) end
	local mn, mx = Call("UnitDamage", "player")
	if num(mn) then s.meleeDamage = { round(num(mn), 1), round(num(mx), 1) } end
	local mh = Call("UnitAttackSpeed", "player")
	s.meleeSpeed = round(num(mh))
	local base, casting = Call("GetManaRegen")
	if num(base) then s.manaRegen = { base = round(num(base) * 5, 1), casting = round((num(casting) or 0) * 5, 1), per = "5s" } end
	s.dodge = round(num((Call("GetDodgeChance"))))
	s.parry = round(num((Call("GetParryChance"))))
	s.block = round(num((Call("GetBlockChance"))))
	local dbase, dmod = Call("UnitDefenseSkill", "player")
	if num(dbase) then s.defense = num(dbase) + (num(dmod) or 0) end
	local avg, avgEq = Call("GetAverageItemLevel")
	s.itemLevel = round(num(avgEq) or num(avg), 1)
	s.capturedAt = now()
	return s
end

function C.Buffs()
	local out = {}
	local t = num((Call("GetTime"))) or 0
	for i = 1, C.CAP.buffs do
		-- Forever makes auras secret in some states and the call raises instead of returning;
		-- that is expected, so stop quietly instead of counting an addon error.
		local fn = U.Fn("C_UnitAuras.GetAuraDataByIndex")
		if not fn then break end
		local ok, a = pcall(fn, "player", i, "HELPFUL")
		if not ok or type(a) ~= "table" or U.IsSecret(a) then break end
		local sid, name = num(a.spellId), str(a.name)
		if sid or name then
			local exp, dur = num(a.expirationTime), num(a.duration)
			out[#out + 1] = { s = sid, n = name, st = (num(a.applications) or 0) > 1 and num(a.applications) or nil,
				rem = (exp and exp > 0) and math.floor(exp - t) or nil, dur = (dur and dur > 0) and dur or nil,
				self = bool(a.isFromPlayerOrPlayerPet) }
		end
	end
	return out
end

function C.Durability(slotNames)
	local slots, minPct, sum, n, broken = {}, nil, 0, 0, 0
	for slot = 1, 19 do
		local cur, max = Call("GetInventoryItemDurability", slot)
		cur, max = num(cur), num(max)
		if cur and max and max > 0 then
			local pct = math.floor(cur * 100 / max + 0.5)
			n = n + 1; sum = sum + pct
			if not minPct or pct < minPct then minPct = pct end
			if cur == 0 then broken = broken + 1 end
			if pct < 100 then slots[slotNames and slotNames[slot] or tostring(slot)] = pct end
		end
	end
	if n == 0 then return nil end
	return { min = minPct, avg = math.floor(sum / n + 0.5), items = n, broken = broken, damaged = next(slots) and slots or nil, capturedAt = now() }
end

---------------------------------------------------------------------------
-- Equipment sets, lockouts, guild, mail, PvP, game mode
---------------------------------------------------------------------------

-- Returns a list (possibly empty when the player has no sets) or nil when the API is missing.
function C.EquipmentSets()
	local ids = Call("C_EquipmentSet.GetEquipmentSetIDs")
	if type(ids) ~= "table" then return nil end
	local out = {}
	for _, id in ipairs(ids) do
		id = num(id)
		if id then
			local name, _, _, equipped, numItems = Call("C_EquipmentSet.GetEquipmentSetInfo", id)
			local items = {}
			for slot, iid in pairs(list(Call("C_EquipmentSet.GetItemIDs", id))) do
				if num(iid) and num(iid) > 0 then items[(FS.SLOT_NAMES and FS.SLOT_NAMES[slot]) or tostring(slot)] = num(iid) end
			end
			out[#out + 1] = { id = id, name = str(name), equipped = bool(equipped), n = num(numItems), items = items }
		end
	end
	return out
end

function C.Lockouts()
	local n = num((Call("GetNumSavedInstances")))
	if n == nil then return nil end
	local out, t = {}, now()
	for i = 1, math.min(n, C.CAP.lockouts) do
		local name, instanceID, reset, _, locked, extended, _, isRaid, maxPlayers, diffName, numEnc, encProgress = Call("GetSavedInstanceInfo", i)
		name = str(name)
		if name then
			out[#out + 1] = { name = name, instanceID = num(instanceID), resetAt = num(reset) and (t + num(reset)) or nil,
				locked = bool(locked), extended = bool(extended), raid = bool(isRaid), size = num(maxPlayers),
				difficulty = str(diffName), bosses = num(numEnc) and ((num(encProgress) or 0) .. "/" .. num(numEnc)) or nil }
		end
	end
	local wb = num((Call("GetNumSavedWorldBosses"))) or 0
	for i = 1, math.min(wb, 20) do
		local name, _, reset = Call("GetSavedWorldBossInfo", i)
		if str(name) then out[#out + 1] = { name = str(name), worldBoss = true, resetAt = num(reset) and (t + num(reset)) or nil } end
	end
	return out
end

function C.Guild()
	if Clean((Call("IsInGuild"))) == false then return { none = true } end
	local name, rank, rankIndex = Call("GetGuildInfo", "player")
	name = str(name)
	if not name then return nil end -- not loaded yet (GetGuildInfo is empty for a few seconds after login)
	return { name = name, rank = str(rank), rankIndex = num(rankIndex) }
end

-- Mailbox summary while the mailbox is open. Player-to-player mail keeps only
-- money/items/expiry: no sender name, no subject, no body text.
function C.Mail()
	local n = num((Call("GetInboxNumItems")))
	if n == nil then return nil end
	local out = { count = n, mails = {}, capturedAt = now() }
	for i = 1, math.min(n, C.CAP.mail) do
		local _, _, sender, subject, money, cod, daysLeft, itemCount, wasRead, wasReturned, _, canReply, isGM = Call("GetInboxHeaderInfo", i)
		-- Privacy first: unless the client says the letter can't be replied to (NPC / auction house / system),
		-- treat it as player mail and keep no sender or subject.
		local fromPlayer = Clean(canReply) ~= false
		local m = { money = num(money), cod = (num(cod) or 0) > 0 and num(cod) or nil, days = round(num(daysLeft), 1),
			read = bool(wasRead), returned = bool(wasReturned), gm = bool(isGM) }
		if fromPlayer then
			m.from = "player"
		else
			m.from = str(sender, 60) or "system"
			m.subject = str(subject, 80)
			m.invoice = C.Invoice and C.Invoice(i) or nil -- auction-house payout / receipt (v0.3)
		end
		local items = {}
		for j = 1, math.min(num(itemCount) or 0, C.CAP.mailItems) do
			local iname, iid, _, count = Call("GetInboxItem", i, j)
			if num(iid) or str(iname) then items[#items + 1] = { itemID = num(iid), name = str(iname), count = num(count) } end
		end
		if #items > 0 then m.items = items end
		out.mails[#out.mails + 1] = m
	end
	return out
end

function C.PvP()
	local out = {}
	local hk, maxRank = Call("GetPVPLifetimeStats")
	out.lifetimeHK, out.lifetimeMaxRank = num(hk), num(maxRank)
	local shk, sdk = Call("GetPVPSessionStats")
	out.sessionHK, out.sessionDK = num(shk), num(sdk)
	local yhk, ydk = Call("GetPVPYesterdayStats")
	out.yesterdayHK, out.yesterdayDK = num(yhk), num(ydk)
	out.honor = num((Call("UnitHonor", "player")))
	out.honorMax = num((Call("UnitHonorMax", "player")))
	out.honorLevel = num((Call("UnitHonorLevel", "player")))
	out.flagged = bool((Call("UnitIsPVP", "player")))
	out.desired = bool((Call("GetPVPDesired")))
	out.rank = C.MajorFaction(C.PVP_RANK_FACTION)
	if out.rank and (out.rank.level or 0) > 0 and Enum and Enum.PvPRanks and Enum.PvPRanks.Rank_1 then
		local faction01 = (Clean((Call("UnitFactionGroup", "player"))) == "Alliance") and 1 or 0
		out.rank.title = str((Call("GetText", "PVP_RANK_" .. (Enum.PvPRanks.Rank_1 + out.rank.level - 1) .. "_" .. faction01, Clean((Call("UnitSex", "player"))))))
	end
	out.season = num((Call("GetCurrentArenaSeason")))
	local ends = num((Call("C_SeasonInfo.GetTimeUntilCurrentPVPSeasonEnd")))
	if ends and ends > 0 then out.seasonEndsAt = now() + ends end
	if next(out) == nil then return nil end
	return out
end

function C.Mode()
	local m = {}
	m.hardcore = bool((Call("C_GameRules.IsHardcoreActive")))
	m.selfFound = bool((Call("C_GameRules.IsSelfFoundAllowed")))
	m.standard = bool((Call("C_GameRules.IsStandard")))
	m.gameMode = num((Call("C_GameRules.GetActiveGameMode")))
	m.gameModeRecordID = num((Call("C_GameRules.GetCurrentGameModeRecordID")))
	local preset = num((Call("C_GameRules.GetForeverExperiencePreset")))
	if preset then m.experiencePreset = (preset == 0 and "classic") or (preset == 1 and "enhanced") or preset end
	m.timerunningSeason = num((Call("PlayerGetTimerunningSeasonID")))
	if m.timerunningSeason == 0 then m.timerunningSeason = nil end
	m.xpDisabled = bool((Call("IsXPUserDisabled")))
	if next(m) == nil then return nil end
	return m
end

---------------------------------------------------------------------------
-- Quest titles for completed quests (cache-only lookups, batched by Core)
---------------------------------------------------------------------------

function C.QuestTitle(qid)
	return str((Call("C_QuestLog.GetTitleForQuestID", qid)), 120)
end

function C.RecipeCooldown(recipeID)
	local cd, isDay, charges, maxCharges = Call("C_TradeSkillUI.GetRecipeCooldown", recipeID)
	cd = num(cd)
	if cd and cd > 0 then
		return { readyAt = now() + math.floor(cd), daily = bool(isDay), charges = num(charges), maxCharges = num(maxCharges) }
	end
	return nil
end

---------------------------------------------------------------------------
-- v0.3: mail without opening, auction outcomes, owned auctions, vendors,
-- cold tier (addons, keybinds, action bars, macro names). All read-only.
---------------------------------------------------------------------------

C.CAP.vendors, C.CAP.vendorItems, C.CAP.auctions = 40, 150, 200
C.CAP.addons, C.CAP.bindings, C.CAP.actionSlots, C.CAP.macros = 300, 400, 180, 160

-- Player names never contain a space; NPC and system senders ("Stormwind Auction House",
-- "Thomas Miller") do. Anything that might be a player is stored only as "player".
function C.SafeSender(name)
	name = str(name, 60)
	if not name then return nil end
	if name:find(" ", 1, true) then return name end
	return "player"
end

function C.MailPending()
	local hasNew = Call("HasNewMail")
	hasNew = Clean(hasNew)
	if hasNew == nil then return nil end
	local out = { hasNew = hasNew and true or false, senders = {}, capturedAt = now() }
	if hasNew then
		local s = { Call("GetLatestThreeSenders") }
		for i = 1, 3 do
			local v = C.SafeSender(s[i])
			if v then out.senders[#out.senders + 1] = v end
		end
	end
	return out
end

-- Auction outcome text: the client's own localized format strings (GlobalStrings), never hardcoded English.
C.AUCTION_FORMATS = {
	{ g = "ERR_AUCTION_SOLD_S", kind = "AUCTION_SOLD" },
	{ g = "ERR_AUCTION_EXPIRED_S", kind = "AUCTION_EXPIRED" },
	{ g = "ERR_AUCTION_OUTBID_S", kind = "AUCTION_OUTBID" },
	{ g = "ERR_AUCTION_WON_S", kind = "AUCTION_WON" },
	{ g = "ERR_AUCTION_COMMODITY_WON_S", kind = "AUCTION_WON" },
	{ g = "ERR_AUCTION_REMOVED_S", kind = "AUCTION_REMOVED" },
	{ g = "ERR_AUCTION_REMOVED", kind = "AUCTION_REMOVED" },
}

-- Turn a printf-style format ("A buyer has been found for your auction of %s.") into an anchored Lua pattern.
function C.FormatToPattern(fmt)
	if type(fmt) ~= "string" or fmt == "" then return nil end
	local out, caps, i = { "^" }, {}, 1
	while i <= #fmt do
		local c = fmt:sub(i, i)
		if c == "%" then
			local pos, conv = fmt:match("^%%(%d*)%$?([sdif])", i)
			if conv then
				local len = #fmt:match("^%%%d*%$?[sdif]", i)
				out[#out + 1] = (conv == "s") and "(.+)" or "([%d%.,]+)"
				caps[#caps + 1] = { pos = tonumber(pos) or (#caps + 1), conv = conv }
				i = i + len
			elseif fmt:sub(i + 1, i + 1) == "%" then
				out[#out + 1] = "%%"; i = i + 2
			else
				out[#out + 1] = "%%"; i = i + 1
			end
		else
			if c:find("[%^%$%(%)%.%[%]%*%+%-%?]") then out[#out + 1] = "%" .. c else out[#out + 1] = c end
			i = i + 1
		end
	end
	out[#out + 1] = "$"
	return table.concat(out), caps
end

local auctionPatterns
function C.AuctionPatterns()
	if auctionPatterns then return auctionPatterns end
	auctionPatterns = {}
	for _, f in ipairs(C.AUCTION_FORMATS) do
		local fmt = Clean(_G[f.g])
		local pat, caps = C.FormatToPattern(fmt)
		if pat then auctionPatterns[#auctionPatterns + 1] = { pat = pat, caps = caps, kind = f.kind, g = f.g } end
	end
	return auctionPatterns
end
function C.ResetAuctionPatterns() auctionPatterns = nil end

-- Returns kind, itemName, qty for an auction system line; nil for every other line (nothing is kept).
function C.MatchAuctionLine(text)
	if type(text) ~= "string" or U.IsSecret(text) or #text > 400 then return nil end
	text = text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
	for _, p in ipairs(C.AuctionPatterns()) do
		local m = { text:match(p.pat) }
		if m[1] ~= nil or (#p.caps == 0 and text:match(p.pat)) then
			local item, qty
			for k, cap in ipairs(p.caps) do
				local v = m[k]
				if cap.conv == "s" and cap.pos == 1 then item = v
				elseif cap.conv == "s" and not item then item = v
				elseif cap.conv ~= "s" then qty = tonumber((v or ""):gsub(",", ""), 10) end
			end
			if item then item = item:match("%[(.-)%]") or item end
			return p.kind, str(item, 120), qty
		end
	end
	return nil
end

-- Enum.AuctionHouseNotification (Forever API docs): the structured source of the same system lines.
C.AH_NOTIFICATION = { [1] = "AUCTION_REMOVED", [2] = "AUCTION_WON", [3] = "AUCTION_OUTBID", [4] = "AUCTION_SOLD", [5] = "AUCTION_EXPIRED" }

local function money64(v)
	v = Clean(v)
	if type(v) == "number" then return v end
	if type(v) == "string" then return tonumber(v) end
	return nil
end

function C.OwnedAuctions()
	local n = num((Call("C_AuctionHouse.GetNumOwnedAuctions")))
	if n == nil then return nil end
	local out = { count = n, list = {}, capturedAt = now(),
		full = bool((Call("C_AuctionHouse.HasFullOwnedAuctionResults"))) }
	for i = 1, math.min(n, C.CAP.auctions) do
		local a = Call("C_AuctionHouse.GetOwnedAuctionInfo", i)
		if type(a) == "table" then
			local key = type(a.itemKey) == "table" and a.itemKey or {}
			local itemID, _, lname = U.ParseItemLink(Clean(a.itemLink))
			itemID = itemID or num(key.itemID)
			out.list[#out.list + 1] = {
				auctionID = num(a.auctionID), itemID = itemID, name = lname, qty = num(a.quantity),
				status = num(a.status) == 1 and "sold" or "active", timeLeft = num(a.timeLeftSeconds), band = num(a.timeLeft),
				bid = money64(a.bidAmount), buyout = money64(a.buyoutAmount),
				hasBidder = (Clean(a.bidder) and Clean(a.bidder) ~= "") and true or nil, -- bidder name never stored
				petSpecies = num(key.battlePetSpeciesID),
			}
		end
	end
	return out
end

-- Auction-house invoice attached to a mail (seller payout / buyer receipt). The counterparty's name is never stored.
function C.Invoice(i)
	local invoiceType, itemName, _, bid, buyout, deposit, consignment, moneyDelay, etaHour, etaMin, count = Call("GetInboxInvoiceInfo", i)
	invoiceType = str(invoiceType, 30)
	if not invoiceType then return nil end
	return { type = invoiceType, item = str(itemName, 120), bid = num(bid), buyout = num(buyout), deposit = num(deposit),
		fee = num(consignment), delay = num(moneyDelay), eta = num(etaHour) and string.format("%02d:%02d", num(etaHour), num(etaMin) or 0) or nil,
		count = num(count) }
end

-- Vendors -----------------------------------------------------------------

function C.NpcID(unit)
	local guid = Clean((Call("UnitGUID", unit or "npc")))
	if type(guid) ~= "string" then return nil end
	local kind, id = guid:match("^(%a+)%-%d+%-%d+%-%d+%-%d+%-(%d+)%-")
	if kind == "Creature" or kind == "Vehicle" or kind == "GameObject" then return tonumber(id) end
	return nil
end

local function CostEntries(index)
	local n = num((Call("GetMerchantItemCostInfo", index))) or 0
	local out = {}
	for j = 1, math.min(n, 5) do
		local _, value, link, currencyName = Call("GetMerchantItemCostItem", index, j)
		link = Clean(link)
		local e = { qty = num(value) }
		if type(link) == "string" then
			e.itemID = (U.ParseItemLink(link))
			e.currencyID = tonumber(link:match("|Hcurrency:(%d+)") or "")
			e.name = link:match("|h%[(.-)%]|h")
		end
		e.name = e.name or str(currencyName, 80)
		if e.qty or e.name then out[#out + 1] = e end
	end
	return #out > 0 and out or nil
end

local function KnownFromTooltip(index)
	local known = Clean(_G.ITEM_SPELL_KNOWN)
	if not known then return nil end
	local data = Call("C_TooltipInfo.GetMerchantItem", index)
	if type(data) ~= "table" or type(data.lines) ~= "table" then return nil end
	for _, line in ipairs(data.lines) do
		if type(line) == "table" and Clean(line.leftText) == known then return true end
	end
	return nil
end

function C.Merchant()
	local n = num((Call("GetMerchantNumItems")))
	if not n or n == 0 then return nil end
	local out = { npcID = C.NpcID("npc"), name = str((Call("UnitName", "npc")), 80), items = {}, count = n, seenAt = now() }
	for i = 1, math.min(n, C.CAP.vendorItems) do
		local info = Call("C_MerchantFrame.GetItemInfo", i)
		local name, price, stack, avail, purchasable, usable, extended, currencyID
		if type(info) == "table" then
			name, price, stack, avail = info.name, info.price, info.stackCount, info.numAvailable
			purchasable, usable, extended, currencyID = info.isPurchasable, info.isUsable, info.hasExtendedCost, info.currencyID
		else
			local _
			name, _, price, stack, avail, purchasable, usable, extended, currencyID = Call("GetMerchantItemInfo", i)
		end
		local link = Clean((Call("GetMerchantItemLink", i)))
		local it = {
			i = i, itemID = num((Call("GetMerchantItemID", i))) or (U.ParseItemLink(link)), name = str(name, 120),
			price = num(price), stack = num(stack), currencyID = num(currencyID),
			usable = bool(usable) or false, purchasable = bool(purchasable) or false,
		}
		local a = num(avail)
		if a and a >= 0 then it.limited = a end -- -1 = unlimited
		if bool(extended) then it.cost = CostEntries(i) end
		it.known = KnownFromTooltip(i)
		out.items[#out.items + 1] = it
	end
	return out
end

-- Cold tier ----------------------------------------------------------------

local function AddonIndexInfo(i, me)
	local name, title, _, loadable, reason = Call("C_AddOns.GetAddOnInfo", i)
	if not name then name, title, _, loadable, reason = Call("GetAddOnInfo", i) end
	name = str(name, 80)
	if not name then return nil end
	local _, loaded = Call("C_AddOns.IsAddOnLoaded", i)
	local state = num((Call("C_AddOns.GetAddOnEnableState", i, me)))
	return { name = name, title = str(title and tostring(title):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""), 80),
		version = str((Call("C_AddOns.GetAddOnMetadata", i, "Version")), 40),
		enabled = state and state > 0 or nil, loaded = bool(loaded) or false,
		loadable = bool(loadable) or false, reason = str(reason, 40) }
end

function C.Addons()
	local n = num((Call("C_AddOns.GetNumAddOns"))) or num((Call("GetNumAddOns")))
	if not n or n == 0 then return nil end
	local me = str((Call("UnitName", "player")))
	local out = { list = {}, count = n }
	for i = 1, math.min(n, C.CAP.addons) do
		local a = AddonIndexInfo(i, me)
		if a then out.list[#out.list + 1] = a end
	end
	return #out.list > 0 and out or nil
end

function C.Bindings()
	local n = num((Call("GetNumBindings")))
	if not n or n == 0 then return nil end
	local out = { list = {} }
	for i = 1, n do
		local action, category, k1, k2 = Call("GetBinding", i)
		k1, k2 = str(k1, 40), str(k2, 40)
		if (k1 or k2) and str(action) then
			out.list[#out.list + 1] = { action = str(action, 80), cat = str(category, 60), key1 = k1, key2 = k2 }
			if #out.list >= C.CAP.bindings then break end
		end
	end
	return out
end

local function MacroName(id)
	local name = Call("GetMacroInfo", id)
	return str(name, 40)
end
C.MacroName = MacroName

function C.ActionBars()
	local out = { slots = {} }
	local any = false
	for slot = 1, C.CAP.actionSlots do
		local has = Clean((Call("HasAction", slot)))
		if has == nil then has = Clean((Call("C_ActionBar.HasAction", slot))) end
		if has then
			local kind, id, sub = Call("GetActionInfo", slot)
			kind, id = str(kind, 20), Clean(id)
			local e = { type = kind, id = type(id) == "number" and id or nil, sub = str(sub, 20) }
			if kind == "spell" then e.name = SpellName(e.id)
			elseif kind == "item" then e.name = str((Call("C_Item.GetItemNameByID", e.id)), 80)
			elseif kind == "macro" then e.name = e.id and MacroName(e.id) or nil
			elseif kind == "companion" or kind == "summonmount" then e.name = nil end
			out.slots[slot] = e
			any = true
		end
	end
	return any and out or nil
end

-- Names only. A macro's body is never read into storage.
function C.Macros()
	local acct, chr = Call("GetNumMacros")
	acct, chr = num(acct), num(chr)
	if not acct then return nil end
	local consts = type(Constants) == "table" and type(Constants.MacroConsts) == "table" and Constants.MacroConsts or {}
	local base = num(consts.MAX_ACCOUNT_MACROS) or 120
	local out = { account = {}, character = {}, numAccount = acct, numCharacter = chr or 0 }
	for i = 1, math.min(acct, C.CAP.macros) do out.account[#out.account + 1] = MacroName(i) or "?" end
	for i = 1, math.min(chr or 0, C.CAP.macros) do out.character[#out.character + 1] = MacroName(base + i) or "?" end
	return out
end

return C

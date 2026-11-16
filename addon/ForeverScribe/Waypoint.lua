-- ForeverScribe waypoints: /scribe way <x> <y> [zone|mapID] [title]  (also /fs way, and TomTom's order:
-- /scribe way <zone> <x> <y> [title]). Sets Forever's own map pin (C_Map.SetUserWaypoint) and tracks it
-- (C_SuperTrack: the in-world arrow), and hands the spot to Polestar or TomTom when one is loaded.
-- Every API used here is in Forever's UI source (docs/WAYPOINTS.md has file/line evidence):
--   C_Map.SetUserWaypoint / ClearUserWaypoint / CanSetUserWaypointOnMap / GetMapInfo / GetMapChildrenInfo,
--   C_SuperTrack.SetSuperTrackedUserWaypoint, UiMapPoint.CreateFromCoordinates,
--   Polestar.Nav.API.Navigate / Cancel (version 1), TomTom:AddWaypoint / RemoveWaypoint.
-- Nothing protected, no clicks, no movement. Only runs when the player types the command.

local FS = ForeverScribe
local U = FS.Util
local Try, Call, Clean = U.Try, U.Call, U.Clean

local Way = {}
FS.Way = Way

local OWNER = "ForeverScribe"
local function Print(m) FS.Print(m) end

local function fold(s) return (tostring(s or ""):lower():gsub("[^%w]", "")) end

-- 0-100 map percent from a token ("42.1", "42,1", ".5"); nil otherwise.
local function percent(tok)
	if type(tok) ~= "string" then return nil end
	tok = tok:gsub(",", ".")
	if not (tok:match("^%d+%.?%d*$") or tok:match("^%.%d+$")) then return nil end
	local v = tonumber(tok)
	if v and v >= 0 and v <= 100 then return v end
	return nil
end

local function isNumberToken(tok)
	if type(tok) ~= "string" then return false end
	local t = tok:gsub(",", ".")
	return t:match("^%-?%d*%.?%d+$") ~= nil
end

local function settings()
	local db = ForeverScribeDB
	if type(db) ~= "table" then return {} end
	db.settings = db.settings or {}
	return db.settings
end

---------------------------------------------------------------------------
-- Map names -> uiMapID (built once from the client's own map tree)
---------------------------------------------------------------------------

local index -- fold(name) -> { info, ... }

local function addInfo(info)
	if type(info) ~= "table" then return end
	local id, name = Clean(info.mapID), Clean(info.name)
	if not id or not name then return end
	local k = fold(name)
	if k == "" then return end
	index[k] = index[k] or {}
	for _, have in ipairs(index[k]) do if have.mapID == id then return end end
	table.insert(index[k], { mapID = id, name = name, mapType = Clean(info.mapType) })
end

local function buildIndex()
	if index then return index end
	index = {}
	local roots, seen = {}, {}
	local function root(m) if m and not seen[m] then seen[m] = true; roots[#roots + 1] = m end end
	root(947) -- Azeroth (the world map)
	local m = Clean((Call("C_Map.GetBestMapForUnit", "player")))
	for _ = 1, 12 do -- climb from the player's map to the top of its tree
		local info = m and Call("C_Map.GetMapInfo", m)
		if type(info) ~= "table" then break end
		local parent = Clean(info.parentMapID)
		if not parent or parent == 0 or parent == m then root(m) break end
		m = parent
	end
	for _, r in ipairs(roots) do
		addInfo(Call("C_Map.GetMapInfo", r))
		local kids = Call("C_Map.GetMapChildrenInfo", r, nil, true)
		if type(kids) == "table" then
			for _, info in ipairs(kids) do addInfo(info) end
		end
	end
	return index
end

local function best(list)
	table.sort(list, function(a, b)
		local za, zb = a.mapType == 3, b.mapType == 3 -- Enum.UIMapType.Zone first
		if za ~= zb then return za end
		return a.mapID < b.mapID
	end)
	return list[1]
end

-- Zone name or map id -> mapID, name | nil, why
function Way.ResolveZone(text)
	text = tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", "")
	local id = tonumber(text:match("^#?(%d+)$") or "")
	if id then
		local info = Call("C_Map.GetMapInfo", id)
		if type(info) == "table" then return id, Clean(info.name) or tostring(id) end
		return nil, "no map " .. id
	end
	local key = fold(text)
	if key == "" then return nil, "no zone given" end
	local idx = buildIndex()
	if idx[key] then local b = best(idx[key]); return b.mapID, b.name end
	if #key >= 4 then
		local hits, names = {}, {}
		for k, list in pairs(idx) do
			if k:find(key, 1, true) then -- "stormw", "barrens" (The Barrens), "plaguelands" is ambiguous
				for _, info in ipairs(list) do
					if info.mapType == 2 or info.mapType == 3 then
						hits[#hits + 1] = info
						names[info.name] = true
					end
				end
			end
		end
		local n, only = 0, nil
		for name in pairs(names) do n = n + 1; only = name end
		if n == 1 then local b = best(hits); return b.mapID, b.name end
		if n > 1 then
			local l = {}
			for name in pairs(names) do l[#l + 1] = name end
			table.sort(l)
			return nil, text .. " could be " .. table.concat(l, ", ")
		end
	end
	return nil, "no map called " .. text
end

local function playerMap()
	local m = Clean((Call("C_Map.GetBestMapForUnit", "player")))
	if not m then return nil end
	local info = Call("C_Map.GetMapInfo", m)
	return m, type(info) == "table" and Clean(info.name) or tostring(m)
end

---------------------------------------------------------------------------
-- Parsing
---------------------------------------------------------------------------

local USAGE = "/scribe way <x> <y> [zone|mapID] [title]  (or <zone> <x> <y> [title]); /scribe way clear; /scribe way addon auto|native"

-- message -> { map, mapName, x, y, title } | nil, why
function Way.Parse(msg)
	msg = tostring(msg or ""):gsub("(%d)[%.,]%s+(%d)", "%1 %2") -- "42.1, 65.3" and "42, 65"
	local t = {}
	for tok in msg:gmatch("%S+") do t[#t + 1] = tok end
	local at
	for i = 1, #t - 1 do
		if isNumberToken(t[i]) and isNumberToken(t[i + 1]) and not t[i]:match("^#") then
			-- skip a leading map id ("1453 52.8 44.8"): it is not a 0-100 coordinate
			if not (i == 1 and #t >= 3 and isNumberToken(t[3]) and not percent(t[1])) then
				at = i
				break
			end
		end
	end
	if not at then
		-- "#1453 52.8 44.8 ..." / "1453 52.8 44.8 ..."
		if t[1] and isNumberToken(t[2]) and isNumberToken(t[3]) then at = 2 else return nil, USAGE end
	end
	local x, y = percent(t[at]), percent(t[at + 1])
	if not (x and y) then return nil, "x and y must be numbers from 0 to 100. " .. USAGE end
	local r = { x = x, y = y }
	local after = {}
	for i = at + 2, #t do after[#after + 1] = t[i] end
	if at > 1 then -- zone (or map id) before the coordinates, TomTom style
		local map, name = Way.ResolveZone(table.concat(t, " ", 1, at - 1))
		if not map then return nil, name end
		r.map, r.mapName, r.title = map, name, table.concat(after, " ")
	else
		-- after the coordinates: a map id, else the longest run of words naming a zone, else the player's map
		local first = after[1]
		local fid = first and tonumber(first:match("^#?(%d+)$") or "")
		local finfo = fid and Call("C_Map.GetMapInfo", fid)
		if type(finfo) == "table" then
			r.map, r.mapName = Way.ResolveZone(first)
			table.remove(after, 1)
		else
			for n = math.min(#after, 6), 1, -1 do
				local map, name = Way.ResolveZone(table.concat(after, " ", 1, n))
				if map then
					r.map, r.mapName = map, name
					for _ = 1, n do table.remove(after, 1) end
					break
				end
			end
		end
		if not r.map then
			r.map, r.mapName = playerMap()
			if not r.map then return nil, "no zone given and the game gives no map here (instance?)" end
		end
		r.title = table.concat(after, " ")
	end
	r.title = (r.title or ""):gsub("|", ""):sub(1, 80)
	if r.title == "" then r.title = nil end
	return r
end

---------------------------------------------------------------------------
-- Other addons' arrows (only their verified, public calls)
---------------------------------------------------------------------------

local function loaded(name)
	local _, isLoaded = Call("C_AddOns.IsAddOnLoaded", name)
	if isLoaded == nil then isLoaded = Call("IsAddOnLoaded", name) end
	return isLoaded and true or false
end

local function polestarAPI()
	if not loaded("Polestar") then return nil end
	local api = type(Polestar) == "table" and type(Polestar.Nav) == "table" and Polestar.Nav.API
	if type(api) == "table" and api.version == 1 and type(api.Navigate) == "function" then return api end
	return nil
end

local function tomtom()
	-- the real TomTom only: Polestar can stand in a TomTom-shaped global when TomTom is absent
	if not loaded("TomTom") then return nil end
	if type(TomTom) == "table" and type(TomTom.AddWaypoint) == "function" then return TomTom end
	return nil
end

function Way.Addons()
	local found = {}
	if polestarAPI() then found[#found + 1] = "Polestar" end
	if tomtom() then found[#found + 1] = "TomTom" end
	if loaded("Questie") then found[#found + 1] = "Questie (no waypoint API: native arrow used)" end
	return found
end

local tomtomUid

local function forward(r)
	local api = polestarAPI()
	if api then
		local ok = Try(api.Navigate, OWNER, r.map, r.x / 100, r.y / 100, r.title)
		if ok then return "Polestar" end
	end
	local tt = tomtom()
	if tt then
		if tomtomUid and type(tt.RemoveWaypoint) == "function" then Try(tt.RemoveWaypoint, tt, tomtomUid) end
		local uid = Try(tt.AddWaypoint, tt, r.map, r.x / 100, r.y / 100, { title = r.title or "ForeverScribe", from = OWNER })
		if uid then tomtomUid = uid; return "TomTom" end
	end
	return nil
end

---------------------------------------------------------------------------
-- Set / clear
---------------------------------------------------------------------------

local function pinsDisabled()
	local rule = type(Enum) == "table" and type(Enum.GameRule) == "table" and Enum.GameRule.WorldMapTrackingPinDisabled
	return rule and Call("C_GameRules.IsGameRuleActive", rule) and true or false
end

local function mapPoint(map, x, y)
	local create = U.Fn("UiMapPoint.CreateFromCoordinates")
	local p = create and Try(create, map, x, y)
	if p then return p end
	local vec = U.Fn("CreateVector2D")
	return { uiMapID = map, position = vec and Try(vec, x, y) or { x = x, y = y } }
end

local function fmt(v) return (string.format("%.1f", v):gsub("%.0$", "")) end

-- r = parsed waypoint. Returns true when a pin or another addon's arrow was set.
function Way.Set(r)
	local mode = settings().wayAddon or "auto"
	local native, why = false, nil
	if pinsDisabled() then
		why = "map pins are turned off here (game rule)"
	elseif Call("C_Map.CanSetUserWaypointOnMap", r.map) == false then
		why = r.mapName .. " does not take map pins; try the zone it is in"
	else
		native = Call("C_Map.SetUserWaypoint", mapPoint(r.map, r.x / 100, r.y / 100)) and true or false
	end
	local via = mode == "auto" and forward(r) or nil
	if native then
		-- one arrow: the addon's when one took it, else the game's own tracking arrow
		Call("C_SuperTrack.SetSuperTrackedUserWaypoint", via == nil)
	end
	if not native and not via then
		Print(why or ("could not set a waypoint (" .. r.mapName .. " " .. fmt(r.x) .. ", " .. fmt(r.y) .. ")"))
		return false
	end
	Print(string.format("waypoint %s %s, %s%s — %s", r.mapName, fmt(r.x), fmt(r.y), r.title and (" (" .. r.title .. ")") or "",
		via and ("arrow: " .. via .. (native and ", map pin set" or "")) or "map pin + arrow"))
	return true
end

function Way.Clear()
	Call("C_Map.ClearUserWaypoint")
	Call("C_SuperTrack.SetSuperTrackedUserWaypoint", false)
	local api = polestarAPI()
	if api and type(api.Cancel) == "function" then Try(api.Cancel, OWNER) end
	local tt = tomtom()
	if tt and tomtomUid and type(tt.RemoveWaypoint) == "function" then Try(tt.RemoveWaypoint, tt, tomtomUid) end
	tomtomUid = nil
	Print("waypoint cleared")
end

-- /scribe way ... (rawArgs keeps the title's case)
function Way.Command(rawArgs)
	local args = tostring(rawArgs or ""):gsub("^%s+", ""):gsub("%s+$", "")
	local word, rest = args:match("^(%S*)%s*(.-)$")
	word = (word or ""):lower()
	if word == "" or word == "help" then
		local found = Way.Addons()
		Print(USAGE)
		Print("arrow mode " .. (settings().wayAddon or "auto") .. "; arrow addons: " .. (#found > 0 and table.concat(found, ", ") or "none (game's own arrow)"))
		return
	end
	if word == "clear" or word == "reset" then Way.Clear() return end
	if word == "addon" then
		local m = rest:lower()
		if m == "native" or m == "auto" then settings().wayAddon = (m ~= "auto") and m or nil end
		Print("arrow mode " .. (settings().wayAddon or "auto") .. " (auto = Polestar or TomTom arrow when loaded, else the game's; native = the game's own)")
		return
	end
	local r, why = Way.Parse(args)
	if not r then Print(why) return end
	Way.Set(r)
end

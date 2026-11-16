-- v0.4 additions to the simulated client: Forever's user waypoint + super-track APIs (shapes from
-- Blizzard_APIDocumentationGenerated/MapDocumentation.lua and SuperTrackManagerDocumentation.lua,
-- UiMapPoint from Blizzard_ObjectAPI/Mainline/UiMapPoint.lua), the map tree, and fake Polestar / TomTom
-- exposing only the calls their sources document (Polestar docs/ARCHITECTURE.md "Nav API"; TomTom core/waypoints.lua).

local W = _G.W
local baseReset = W.Reset

function W.Reset()
	baseReset()
	W.waypoint, W.superTracked, W.calls = nil, false, {}
	W.noPins = {} -- [mapID] = true: CanSetUserWaypointOnMap false
	W.pinRule = false
	for id, m in pairs({
		[1453] = { mapID = 1453, name = "Stormwind City", mapType = 3, parentMapID = 1415 },
		[1429] = { mapID = 1429, name = "Elwynn Forest", mapType = 3, parentMapID = 1415 },
		[1437] = { mapID = 1437, name = "Wetlands", mapType = 3, parentMapID = 1415 },
		[1436] = { mapID = 1436, name = "Westfall", mapType = 3, parentMapID = 1415 },
		[1414] = { mapID = 1414, name = "Kalimdor", mapType = 2, parentMapID = 947 },
		[1413] = { mapID = 1413, name = "The Barrens", mapType = 3, parentMapID = 1414 },
		[1458] = { mapID = 1458, name = "Undercity", mapType = 3, parentMapID = 1415 },
		[9999] = { mapID = 9999, name = "Stormwind City", mapType = 5, parentMapID = 1453 }, -- a same-named micro map
	}) do W.maps[id] = m end
	W.loadedByName = {}
	Polestar, TomTom = nil, nil
end

local function children(root, all)
	local out = {}
	for _, m in pairs(W.maps) do
		local p, ok = m.parentMapID, false
		while p do
			if p == root then ok = true break end
			if not all then break end
			p = W.maps[p] and W.maps[p].parentMapID
		end
		if ok then out[#out + 1] = m end
	end
	table.sort(out, function(a, b) return a.mapID < b.mapID end)
	return out
end

-- allDescendants = true (the waypoint zone index) walks W.maps; the v2 explored-zones collector keeps its zoneTree
local directChildren = C_Map.GetMapChildrenInfo
C_Map.GetMapChildrenInfo = function(id, mapType, all)
	if not all then return directChildren(id, mapType) end
	W.calls[#W.calls + 1] = "GetMapChildrenInfo"
	return children(id, all)
end
C_Map.CanSetUserWaypointOnMap = function(id) return W.maps[id] ~= nil and not W.noPins[id] end
C_Map.SetUserWaypoint = function(p)
	assert(type(p) == "table" and p.uiMapID and p.position, "SetUserWaypoint takes a UiMapPoint")
	if not W.maps[p.uiMapID] or W.noPins[p.uiMapID] then return false end
	W.waypoint = { map = p.uiMapID, x = p.position.x, y = p.position.y }
	return true
end
C_Map.ClearUserWaypoint = function() W.waypoint = nil end
C_Map.HasUserWaypoint = function() return W.waypoint ~= nil end
C_SuperTrack = { SetSuperTrackedUserWaypoint = function(on)
	assert(type(on) == "boolean", "superTracked is a bool")
	W.superTracked = on
end }
function CreateVector2D(x, y) return { x = x, y = y, GetXY = function(s) return s.x, s.y end } end
UiMapPoint = { CreateFromCoordinates = function(mapID, x, y, z) return { uiMapID = mapID, position = CreateVector2D(x, y), z = z } end }
Enum = Enum or {}
Enum.GameRule = Enum.GameRule or { WorldMapTrackingPinDisabled = 123 }
C_GameRules = C_GameRules or {}
C_GameRules.IsGameRuleActive = function(rule) return rule == Enum.GameRule.WorldMapTrackingPinDisabled and W.pinRule end

-- IsAddOnLoaded by name as well as by index (the v3 stub only answers indexes)
local byIndex = C_AddOns.IsAddOnLoaded
C_AddOns.IsAddOnLoaded = function(x)
	if type(x) == "string" then local l = W.loadedByName[x] and true or false; return l, l end
	return byIndex(x)
end

function W.FakePolestar()
	W.loadedByName.Polestar = true
	W.polestar = {}
	Polestar = { Nav = { API = { version = 1, minor = 1,
		Navigate = function(owner, map, x, y, title)
			if type(owner) ~= "string" or x < 0 or x > 1 or y < 0 or y > 1 then return false end
			W.polestar.target = { owner = owner, map = map, x = x, y = y, title = title }
			return true
		end,
		Cancel = function(owner) if W.polestar.target and W.polestar.target.owner == owner then W.polestar.target = nil return true end return false end,
		Active = function() local t = W.polestar.target; if not t then return false end return true, t.owner end,
	} } }
end

-- A fuller Polestar for the guide reader: only the calls its docs list (docs/API.md, docs/ARCHITECTURE.md "Engine",
-- Nav API minor 1), with the shapes its Engine.lua returns. W.polestar.tabs / .views / .liveTarget drive it.
function W.FakePolestarGuide()
	W.FakePolestar()
	local P = Polestar
	P.version = "0.4.0.1"
	P.API = { version = 1 }
	W.polestar.handlers = {}
	W.polestar.tabs = { { guideId = "forever/alliance/02-westfall", title = "Westfall", category = "Leveling", stepIndex = 12,
		stepCount = 74, stepNumber = 11, stepTotal = 70, done = 10, total = 74, complete = false } }
	W.polestar.views = { [12] = { index = 12, title = "Sentinel Hill", status = "current", goals = {
		{ t = "turnin", text = "Hand in |cffffd100The People's Militia|r", status = "open" },
		{ t = "kill", text = "Kill Defias Trappers", status = "open", progress = { cur = 3, max = 15 } },
		{ t = "accept", text = "hidden for this class", status = "na" },
	} } }
	W.polestar.calls = {}
	P.On = function(msg, fn) W.polestar.handlers[msg] = W.polestar.handlers[msg] or {}; table.insert(W.polestar.handlers[msg], fn); return #W.polestar.handlers[msg] end
	P.Engine = {
		GetTabs = function(counts) W.polestar.calls[#W.polestar.calls + 1] = "GetTabs"; return W.polestar.tabs, 1 end,
		GetStepView = function(i, shared) W.polestar.calls[#W.polestar.calls + 1] = "GetStepView:" .. tostring(shared); return W.polestar.views[i] end,
		GetProgress = function() return 10, 74 end,
		GetGuide = function() return { id = W.polestar.tabs[1].guideId } end,
		GetLiveStep = function() return W.polestar.tabs[1].stepIndex end,
	}
	P.Nav.API.Target = function()
		local t = W.polestar.liveTarget
		if not t then return nil end
		return { map = t.map, x = t.x, y = t.y, title = t.title, kind = t.kind, next = t.next }
	end
end

function W.PolestarFire(msg, ...)
	for _, fn in ipairs((W.polestar.handlers or {})[msg] or {}) do fn(...) end
end

function W.FakeTomTom()
	W.loadedByName.TomTom = true
	W.tomtom = { list = {}, n = 0 }
	TomTom = {
		AddWaypoint = function(self, m, x, y, opts)
			W.tomtom.n = W.tomtom.n + 1
			local uid = { m, x, y, title = opts and opts.title, from = opts and opts.from }
			W.tomtom.list[uid] = true
			return uid
		end,
		RemoveWaypoint = function(self, uid) W.tomtom.list[uid] = nil end,
	}
end

function W.TomTomCount() local n = 0 for _ in pairs(W.tomtom.list) do n = n + 1 end return n end

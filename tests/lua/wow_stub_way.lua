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
	} } }
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

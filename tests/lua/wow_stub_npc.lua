-- v0.5 additions to the simulated client: units the player talks to or targets (UnitPlayerControlled too), map sizes, tickers, and the
-- load-on-demand route slots. Shapes from Blizzard_APIDocumentationGenerated (UnitDocumentation.lua: UnitGUID,
-- UnitIsPlayer, UnitIsFriend, UnitExists; PlayerScriptDocumentation.lua: CheckInteractDistance;
-- MapDocumentation.lua: GetMapWorldSize; AddOnsDocumentation.lua: LoadAddOn -> loaded, reason).
-- Slot loading follows the rules measured on a live Forever client (research/wow-ai docs/ARCHITECTURE.md):
-- a load-on-demand addon reads its file from disk when first loaded, and only once per UI session.

local W = _G.W
local baseReset = W.Reset

function W.Reset()
	baseReset()
	W.units = {} -- [unit] = { guid=, name=, player=, friend=, dist= (yards), sub= }
	W.combat = false
	W.worldSize = { [1453] = { 1737.5, 1158.3 }, [1429] = { 3470.8, 2314.6 }, [1432] = { 2758.3, 1839.6 } }
	W.slotDir = nil -- folder holding ForeverScribe_RouteNN/Route.lua (default: the repo's addon/)
	W.slotCount = 3
	W.slotsLoaded = {}
	W.tickers = {}
end

local function unit(u) return W.units[u] end

local guidV3 = UnitGUID
function UnitGUID(u)
	local x = unit(u)
	if x then return x.guid end
	return guidV3(u)
end
local nameV3 = UnitName
function UnitName(u)
	local x = unit(u)
	if x then return x.name end
	return nameV3(u)
end
function UnitIsPlayer(u) local x = unit(u); return x and x.player or false end
function UnitPlayerControlled(u) local x = unit(u); return x and (x.player or x.controlled) or false end
function UnitExists(u) return unit(u) ~= nil or u == "player" end
function UnitIsFriend(_, u) local x = unit(u); return x and x.friend or false end
function CheckInteractDistance(u, idx)
	local x = unit(u)
	if not x then return false end
	if x.secretDist then return W.Secret() end
	local limit = ({ 28, 11.11, 9.9, 28 })[idx] or 10
	return (x.dist or 99) <= limit
end
function InCombatLockdown() return W.combat end
C_TooltipInfo = C_TooltipInfo or {}
C_TooltipInfo.GetUnit = function(u)
	local x = unit(u)
	if not x then return nil end
	return { lines = { { leftText = x.name }, { leftText = x.sub and ("<" .. x.sub .. ">") or "Level 30" } } }
end

C_Map.GetMapWorldSize = function(m) local s = W.worldSize[m]; if s then return s[1], s[2] end return 0, 0 end
local posV2 = C_Map.GetPlayerMapPosition
C_Map.GetPlayerMapPosition = function(m, u)
	if W.zone.posOn and W.zone.posOn[m] then
		local p = W.zone.posOn[m]
		return { x = p[1], y = p[2], GetXY = function(self) return self.x, self.y end }
	end
	if W.zone.strictMap and m ~= W.zone.mapID then return nil end
	return posV2(m, u)
end

C_Timer.NewTicker = function(d, fn)
	local t = { cancelled = false }
	function t.Cancel(self) self.cancelled = true end
	local function again()
		if t.cancelled then return end
		fn()
		if not t.cancelled then W.timers[#W.timers + 1] = { at = W.clock + d, fn = again } end
	end
	W.timers[#W.timers + 1] = { at = W.clock + d, fn = again }
	W.tickers[#W.tickers + 1] = t
	return t
end
function W.ActiveTickers() local n = 0 for _, t in ipairs(W.tickers) do if not t.cancelled then n = n + 1 end end return n end

-- Route slots: ForeverScribe_RouteNN are load-on-demand; the first load reads Route.lua from disk.
local loadV1 = C_AddOns.LoadAddOn
C_AddOns.LoadAddOn = function(name)
	local i = tonumber(tostring(name):match("^ForeverScribe_Route(%d%d)$"))
	if not i then return loadV1(name) end
	if i > W.slotCount then return false, "MISSING" end
	if W.slotsLoaded[name] then return true end -- already loaded: the file is not read again
	local dir = W.slotDir or (W.ROOT .. "addon")
	local chunk, err = loadfile(dir .. "/" .. name .. "/Route.lua")
	if not chunk then return false, "CORRUPT" end
	chunk()
	W.slotsLoaded[name] = true
	W.loadedByName[name] = true
	return true
end

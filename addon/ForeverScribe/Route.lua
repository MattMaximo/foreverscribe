-- ForeverScribe routes: a list of stops your agent wrote, walked one waypoint at a time.
--
-- How a route reaches the game (no network, no file I/O from Lua): the companion rewrites
-- Interface/AddOns/ForeverScribe_RouteNN/Route.lua, small load-on-demand addons that were installed before the game
-- started. `/fs go` (or its key binding) loads the next not-yet-loaded slot with C_AddOns.LoadAddOn, which reads the
-- file from disk at that moment. A slot can be loaded once per UI session, so there are SLOTS of them; /reload
-- frees them all. The route and the current stop are kept in SavedVariables, so progress survives /reload and logout.
--
-- On a route: the current stop gets a waypoint (Waypoint.lua: native pin + arrow, or Polestar/TomTom). A 1-second
-- timer checks the distance to it; within the stop's radius the next stop is set. /fs next skips ahead.

local FS = ForeverScribe
local U = FS.Util
local Try, Call, Clean = U.Try, U.Call, U.Clean

local R = {}
FS.Route = R
R.SLOTS = 10
R.MAX_STOPS = 50
R.DEFAULT_RADIUS = 15 -- yards
R.TICK = 1
R.loadedSlots = {} -- this UI session

local function Print(m) FS.Print(m) end

function R.SlotName(i) return string.format("ForeverScribe_Route%02d", i) end

local function db()
	local d = FS.db
	if type(d) ~= "table" then return nil end
	return d
end

local function fmt(v) return (string.format("%.1f", v):gsub("%.0$", "")) end

local function cleanText(s, max)
	if type(s) ~= "string" or U.IsSecret(s) then return nil end
	s = s:gsub("[%c|\\\"]", ""):gsub("^%s+", ""):gsub("%s+$", "")
	if s == "" then return nil end
	return s:sub(1, max or 60)
end

-- Validate what a slot file defined. Pure (unit-tested). Returns route or nil, why.
function R.Validate(data)
	if type(data) ~= "table" then return nil, "the route file is empty (write a route first: foreverscribe route write)" end
	if data.v ~= 1 then return nil, "route file format " .. tostring(data.v) .. " is newer than this addon; update ForeverScribe" end
	if type(data.rev) ~= "string" or not data.rev:match("^[%w_%.%-]+$") or #data.rev > 40 then return nil, "route file has no valid rev" end
	if type(data.stops) ~= "table" then return nil, "route has no stops" end
	local out = { rev = data.rev, name = cleanText(data.name) or "Route", created = tonumber(data.created), stops = {} }
	for i, s in ipairs(data.stops) do
		if i > R.MAX_STOPS then break end
		local map, x, y = tonumber(type(s) == "table" and s.map), tonumber(type(s) == "table" and s.x), tonumber(type(s) == "table" and s.y)
		if not (map and x and y) or map < 1 or map % 1 ~= 0 or x < 0 or x > 100 or y < 0 or y > 100 then
			return nil, "stop " .. i .. " is not a valid map position"
		end
		local r = tonumber(s.r) or R.DEFAULT_RADIUS
		if r < 3 then r = 3 elseif r > 200 then r = 200 end
		out.stops[#out.stops + 1] = { map = map, x = x, y = y, r = r, title = cleanText(s.title) or ("Stop " .. i) }
	end
	if #out.stops == 0 then return nil, "route has no stops" end
	return out
end

---------------------------------------------------------------------------
-- Slots
---------------------------------------------------------------------------

local function isLoaded(name)
	local _, l = Call("C_AddOns.IsAddOnLoaded", name)
	return (Clean(l) or R.loadedSlots[name]) and true or false
end

-- Load the next unused slot: true, the table its file defined (nil when empty) | false, why.
function R.LoadSlot()
	local load = U.Fn("C_AddOns.LoadAddOn")
	if not load then return false, "this client has no C_AddOns.LoadAddOn" end
	local missing = 0
	for i = 1, R.SLOTS do
		local name = R.SlotName(i)
		if not isLoaded(name) then
			ForeverScribe_RouteData = nil
			local ok, loaded, reason = pcall(load, name)
			R.loadedSlots[name] = true -- even a failed load can't be retried this session
			if ok and loaded then
				local data = ForeverScribe_RouteData
				ForeverScribe_RouteData = nil
				R.lastSlot = i
				return true, data
			end
			reason = ok and Clean(reason) or "error"
			if reason == "MISSING" or reason == "DISABLED" then
				missing = missing + 1
			else
				return false, "route slot " .. i .. " did not load (" .. tostring(reason) .. ")"
			end
		end
	end
	if missing > 0 then
		return false, "route slots are missing or disabled: install ForeverScribe 0.5 (it adds ForeverScribe_Route01-" ..
			string.format("%02d", R.SLOTS) .. "), restart the game, and leave them ticked under ForeverScribe in the AddOns list"
	end
	return false, "all " .. R.SLOTS .. " route slots were used this session; /reload frees them (your place on the route is kept)"
end

---------------------------------------------------------------------------
-- Walking a route
---------------------------------------------------------------------------

local function current()
	local d = db()
	local r = d and d.route
	if type(r) ~= "table" or type(r.stops) ~= "table" or r.done then return nil end
	return r
end
R.Current = current

local function mapName(map)
	local info = Call("C_Map.GetMapInfo", map)
	return type(info) == "table" and Clean(info.name) or tostring(map)
end

local ticker
local function stopTicker()
	if ticker and ticker.Cancel then Try(ticker.Cancel, ticker) end
	ticker = nil
end

function R.SetStop(quiet)
	local r = current()
	if not r then stopTicker() return false end
	local s = r.stops[r.i]
	if not s then return false end
	local label = string.format("%s %d/%d: %s", r.name, r.i, #r.stops, s.title)
	if FS.Way and FS.Way.Set then
		FS.Way.Set({ map = s.map, x = s.x, y = s.y, title = label, mapName = mapName(s.map) })
	elseif not quiet then
		Print(label .. " (" .. fmt(s.x) .. ", " .. fmt(s.y) .. ")")
	end
	R.StartTicker()
	return true
end

local function finish()
	local r = current()
	if not r then return end
	r.done = Try(time) or 0
	stopTicker()
	if FS.Way and FS.Way.Clear then FS.Way.Clear(true) end
	Print(string.format("route %s done (%d stops). /fs go loads the next one your agent writes.", r.name, #r.stops))
	if FS.Emit then FS.Emit("route_done", { rev = r.rev, name = r.name, stops = #r.stops }) end
end

function R.Advance(step)
	local r = current()
	if not r then Print("no route running. Ask your agent for one, then /fs go") return end
	local i = r.i + (step or 1)
	if i < 1 then i = 1 end
	if i > #r.stops then finish() return end
	r.i = i
	R.SetStop()
end

-- Yards from the player to a stop, or nil when the player isn't on/near that map.
function R.Distance(s)
	if not FS.MapPosition then return nil end
	local x, y = FS.MapPosition(s.map)
	if not x or not y then return nil end
	if x < -50 or x > 150 or y < -50 or y > 150 then return nil end
	if FS.Npcs and FS.Npcs.Yards then return FS.Npcs.Yards(s.map, x, y, s.x, s.y) end
	return nil
end

function R.Tick()
	local r = current()
	if not r then stopTicker() return end
	local s = r.stops[r.i]
	if not s then return end
	local d = R.Distance(s)
	if d and d <= (s.r or R.DEFAULT_RADIUS) then
		if r.i >= #r.stops then
			Print("arrived: " .. s.title)
			finish()
		else
			Print(string.format("arrived: %s — next stop", s.title))
			R.Advance(1)
		end
	end
end

function R.StartTicker()
	if ticker then return end
	local nt = U.Fn("C_Timer.NewTicker")
	if not nt then return end
	ticker = Try(nt, R.TICK, function()
		local ok, err = pcall(R.Tick)
		if not ok then FS.errors = (FS.errors or 0) + 1; FS.lastError = "route: " .. tostring(err) end
	end)
end

-- /fs go: pick up the route the agent wrote (or carry on with the current one).
function R.Go()
	local d = db()
	if not d then return end
	local loaded, data = R.LoadSlot()
	local r = current()
	if not loaded then
		local why = data
		if r then
			Print(why .. ". Carrying on with " .. r.name .. ".")
			R.SetStop()
		else
			Print(why)
		end
		return
	end
	local route, bad = R.Validate(data)
	if not route then
		Print(bad)
		if r then R.SetStop() end
		return
	end
	if d.route and d.route.rev == route.rev then
		if d.route.done then
			Print(route.name .. " is already done. Ask your agent for a new route, then /fs go.")
			return
		end
		Print(string.format("same route as before; stop %d/%d", d.route.i, #d.route.stops))
		R.SetStop()
		return
	end
	route.i = 1
	route.started = Try(time) or 0
	d.route = route
	Print(string.format("route %s: %d stops (/fs route lists them, /fs next skips one)", route.name, #route.stops))
	if FS.Emit then FS.Emit("route_start", { rev = route.rev, name = route.name, stops = #route.stops }) end
	R.SetStop()
end

function R.List()
	local d = db()
	local r = d and d.route
	if type(r) ~= "table" or type(r.stops) ~= "table" then Print("no route yet. Ask your agent for one, then /fs go") return end
	Print(string.format("%s (%s): %d stops", r.name, r.done and "done" or ("at stop " .. r.i), #r.stops))
	for i, s in ipairs(r.stops) do
		local mark = (not r.done and i == r.i) and ">" or (r.done or i < r.i) and "x" or " "
		Print(string.format(" %s %d. %s — %s %s, %s", mark, i, s.title, mapName(s.map), fmt(s.x), fmt(s.y)))
	end
end

function R.Clear()
	local d = db()
	if d then d.route = nil end
	stopTicker()
	if FS.Way and FS.Way.Clear then FS.Way.Clear() end
	Print("route cleared")
end

function R.Command(arg)
	arg = tostring(arg or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
	if arg == "" or arg == "list" or arg == "show" then R.List()
	elseif arg == "clear" or arg == "stop" then R.Clear()
	elseif arg == "slots" then
		local used = 0
		for i = 1, R.SLOTS do if isLoaded(R.SlotName(i)) then used = used + 1 end end
		Print(string.format("route slots used this session: %d of %d (/reload frees them)", used, R.SLOTS))
	else Print("/fs go | /fs next | /fs back | /fs route [clear|slots]") end
end

-- After login or /reload: put the current stop back on the map.
function R.Resume()
	local r = current()
	if not r then return end
	Print(string.format("route %s: stop %d/%d — %s (/fs next skips)", r.name, r.i, #r.stops, r.stops[r.i] and r.stops[r.i].title or "?"))
	R.SetStop(true)
end

-- Key binding labels (Bindings.xml)
BINDING_HEADER_FOREVERSCRIBE = "ForeverScribe"
BINDING_NAME_FOREVERSCRIBE_GO = "Load route / go (/fs go)"
BINDING_NAME_FOREVERSCRIBE_NEXT = "Next route stop (/fs next)"

return R

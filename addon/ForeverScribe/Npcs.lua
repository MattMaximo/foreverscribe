-- ForeverScribe NPC sightings: where this character actually met an NPC, in Forever's own map frame.
-- Read-only. When the player opens an NPC's window (gossip, vendor, trainer, quest, flight master, bank,
-- auction house) the NPC's id comes from its GUID (Creature-0-<server>-<instance>-<zone>-<npcID>-<spawn>) and the
-- position is the player's own (they are standing next to it: interaction range is a few yards). Optionally a
-- friendly NPC the player targets from within ~10 yards (CheckInteractDistance index 3) counts too.
-- Never players, pets or objects; a secret GUID/position is skipped, never stored. Bounded table.
-- Stored per character in ForeverScribeDB.chars[<key>].npcs["<npcID>:<mapID>"] = {
--   id, name, sub, map, x, y (best spot, 0-100), n (sightings), t (last), first, kind, zone, subzone,
--   spots = { {x, y, n, t}, ... up to MAX_SPOTS }, r (yards the spot can be off: 5 interaction, 10 target) }

local FS = ForeverScribe
local U = FS.Util
local Try, Call, Clean = U.Try, U.Call, U.Clean

local N = {}
FS.Npcs = N
N.CAP = 1000        -- NPC+map entries kept per character (oldest dropped first)
N.MAX_SPOTS = 4     -- distinct spots kept per NPC and map (wanderers, several spawns)
N.MERGE_YARDS = 5   -- sightings this close are the same spot
N.REPEAT_SECONDS = 30 -- one conversation fires several events (GOSSIP_SHOW, QUEST_GREETING ...): count it once
N.skipped = { secret = 0, player = 0, noPos = 0, notCreature = 0, far = 0 }

local function now() return (Try(time)) or 0 end

-- "Creature-0-1-0-1-2327-0000ABCD" -> 2327; players, pets, objects, vehicles and secrets -> nil, why
function N.ParseGUID(guid)
	if guid == nil then return nil, "none" end
	if U.IsSecret(guid) then return nil, "secret" end
	if type(guid) ~= "string" then return nil, "none" end
	local kind, id = guid:match("^(%a+)%-%d+%-%d+%-%d+%-%d+%-(%d+)%-")
	if kind == "Creature" then return tonumber(id) end
	if guid:match("^Player%-") then return nil, "player" end
	return nil, "notCreature"
end

-- Yards between two 0-100 points on one map. C_Map.GetMapWorldSize gives the map's size in yards; without it
-- (or for a map it doesn't know) 1 map percent is taken as 10 yards, about a mid-sized zone.
local sizeCache = {}
function N.Yards(map, x1, y1, x2, y2)
	local s = sizeCache[map]
	if s == nil then
		local w, h = Call("C_Map.GetMapWorldSize", map)
		w, h = Clean(w), Clean(h)
		if type(w) == "number" and type(h) == "number" and w > 0 and h > 0 then s = { w, h } else s = false end
		sizeCache[map] = s
	end
	local w, h = 1000, 1000
	if s then w, h = s[1], s[2] end
	local dx, dy = (x1 - x2) / 100 * w, (y1 - y2) / 100 * h
	return math.sqrt(dx * dx + dy * dy)
end

local function bestSpot(e)
	local b
	for _, s in ipairs(e.spots) do
		if not b or s.n > b.n or (s.n == b.n and (s.t or 0) > (b.t or 0)) then b = s end
	end
	return b
end

local function round2(v) return math.floor(v * 100 + 0.5) / 100 end

-- Pure merge (unit-tested): rec = {id, map, x, y, name?, sub?, kind, zone?, subzone?, r?}. Returns the entry.
function N.Merge(store, rec, t, yards)
	yards = yards or N.Yards
	local key = rec.id .. ":" .. rec.map
	local e = store[key]
	local fresh = false
	if not e then
		e = { id = rec.id, map = rec.map, n = 0, first = t, spots = {} }
		store[key] = e
		fresh = true
	end
	if rec.name then e.name = rec.name end
	if rec.sub then e.sub = rec.sub end
	if rec.zone then e.zone = rec.zone end
	if rec.subzone then e.subzone = rec.subzone end
	-- an interaction sighting is more precise than a target sighting: never let the latter overwrite the kind
	if not e.kind or e.kind == "target" then e.kind = rec.kind end
	e.r = math.min(e.r or 99, rec.r or 5)
	local near
	for _, s in ipairs(e.spots) do
		if yards(rec.map, s.x, s.y, rec.x, rec.y) <= N.MERGE_YARDS then near = s break end
	end
	if near then
		if t - (near.t or 0) >= N.REPEAT_SECONDS then
			-- running mean keeps a spot centred on where the player usually stands
			near.x = round2((near.x * near.n + rec.x) / (near.n + 1))
			near.y = round2((near.y * near.n + rec.y) / (near.n + 1))
			near.n = near.n + 1
			e.n = e.n + 1
		end
		near.t = t
	else
		e.spots[#e.spots + 1] = { x = round2(rec.x), y = round2(rec.y), n = 1, t = t }
		e.n = e.n + 1
		if #e.spots > N.MAX_SPOTS then
			-- drop the weakest (fewest sightings, then oldest) spot
			local wi
			for i, s in ipairs(e.spots) do
				local w = wi and e.spots[wi]
				if not w or s.n < w.n or (s.n == w.n and (s.t or 0) < (w.t or 0)) then wi = i end
			end
			table.remove(e.spots, wi)
		end
	end
	e.t = t
	local b = bestSpot(e)
	e.x, e.y = b.x, b.y
	if fresh then N.Trim(store) end
	return e
end

function N.Trim(store, cap)
	cap = cap or N.CAP
	local keys = {}
	for k in pairs(store) do keys[#keys + 1] = k end
	if #keys <= cap then return 0 end
	table.sort(keys, function(a, b) return (store[a].t or 0) < (store[b].t or 0) end)
	local drop = #keys - cap
	for i = 1, drop do store[keys[i]] = nil end
	return drop
end

---------------------------------------------------------------------------
-- Reading the game
---------------------------------------------------------------------------

local function charRecord()
	local db = FS.db
	local ck = FS.charKey
	if type(db) ~= "table" or not ck or type(db.chars) ~= "table" then return nil end
	return db.chars[ck]
end

local function settings()
	local db = FS.db
	return type(db) == "table" and type(db.settings) == "table" and db.settings or {}
end

-- NPC title line ("<First Aid Trainer>") from the unit tooltip data, if the client gives it.
local function subtitleOf(unit, name)
	local info = Call("C_TooltipInfo.GetUnit", unit)
	if type(info) ~= "table" or type(info.lines) ~= "table" then return nil end
	local line = info.lines[2]
	local text = type(line) == "table" and Clean(line.leftText)
	if type(text) ~= "string" or text == "" or text == name then return nil end
	if text:match("^Level ") or text:match("^Niveau ") or #text > 60 then return nil end
	return (text:gsub("^<", ""):gsub(">$", ""))
end

local function playerSpot()
	local map = Clean((Call("C_Map.GetBestMapForUnit", "player")))
	if type(map) ~= "number" then return nil end
	local x, y = FS.MapPosition(map)
	if not x then return nil end
	return map, x, y
end

local function skip(why) N.skipped[why] = (N.skipped[why] or 0) + 1 end

-- Record the NPC behind `unit` ("npc" for an open window, "target" for a targeted one).
function N.Sight(unit, kind, radius)
	local c = charRecord()
	if not c then return nil end
	if Clean((Call("UnitIsPlayer", unit))) then skip("player") return nil end
	-- players' pets, guardians and totems can carry a player's name in their title: never recorded
	if Clean((Call("UnitPlayerControlled", unit))) then skip("player") return nil end
	local id, why = N.ParseGUID((Call("UnitGUID", unit)))
	if not id then if why ~= "none" then skip(why) end return nil end
	local map, x, y = playerSpot()
	if not map then skip("noPos") return nil end
	local name = Clean((Call("UnitName", unit)))
	if type(name) ~= "string" then name = nil end
	c.npcs = c.npcs or {}
	local l = FS.Location and FS.Location() or {}
	local e = N.Merge(c.npcs, { id = id, map = map, x = x, y = y, name = name, sub = name and subtitleOf(unit, name),
		kind = kind, zone = l.zone ~= "" and l.zone or nil, subzone = l.subzone ~= "" and l.subzone or nil, r = radius or 5 }, now())
	N.last = e
	return e
end

local function onWindow(kind) return function() N.Sight("npc", kind, 5) end end

local H = {}
H.GOSSIP_SHOW = onWindow("gossip")
H.MERCHANT_SHOW = onWindow("vendor")
H.TRAINER_SHOW = onWindow("trainer")
H.QUEST_DETAIL = onWindow("quest")
H.QUEST_GREETING = onWindow("quest")
H.QUEST_PROGRESS = onWindow("quest")
H.QUEST_COMPLETE = onWindow("quest")
H.TAXIMAP_OPENED = onWindow("flightmaster")
H.BANKFRAME_OPENED = onWindow("banker")
H.AUCTION_HOUSE_SHOW = onWindow("auctioneer")

-- Enum.PlayerInteractionType (PlayerInteractionManagerConstantsDocumentation.lua): the interaction manager
-- event covers the windows whose legacy event a client may not fire.
local INTERACT = { [3] = "gossip", [4] = "quest", [5] = "vendor", [6] = "flightmaster", [7] = "trainer", [8] = "banker",
	[12] = "vendor", [20] = "innkeeper", [21] = "auctioneer", [22] = "stablemaster", [23] = "battlemaster" }
function H.PLAYER_INTERACTION_MANAGER_FRAME_SHOW(kind)
	local k = INTERACT[Clean(kind) or -1]
	if k then N.Sight("npc", k, 5) end
end

-- A friendly NPC targeted within ~10 yards (duel distance). Out of combat only; any secret answer = skip.
function H.PLAYER_TARGET_CHANGED()
	if settings().npcTarget == false then return end
	if Clean((Call("InCombatLockdown"))) then return end
	if not Clean((Call("UnitExists", "target"))) then return end
	if Clean((Call("UnitIsPlayer", "target"))) then return end
	if Clean((Call("UnitIsFriend", "player", "target"))) ~= true then return end
	local close = Call("CheckInteractDistance", "target", 3)
	if U.IsSecret(close) then skip("secret") return end
	if close ~= true then skip("far") return end
	N.Sight("target", "target", 10)
end

N.handlers = H
local frame = CreateFrame("Frame", "ForeverScribeNpcFrame")
N.frame = frame
for ev in pairs(H) do pcall(frame.RegisterEvent, frame, ev) end
frame:SetScript("OnEvent", function(_, event, ...)
	local h = H[event]
	if not h or not FS.charKey then return end
	local ok, err = pcall(h, ...)
	if not ok then FS.errors = (FS.errors or 0) + 1; FS.lastError = event .. ": " .. tostring(err) end
end)

-- /scribe npcs [target on|off]
function N.Command(arg)
	arg = tostring(arg or ""):lower()
	local s = settings()
	if arg == "target off" then s.npcTarget = false elseif arg == "target on" then s.npcTarget = nil end
	local c = charRecord()
	local n = c and c.npcs and U.Count(c.npcs) or 0
	local last = N.last and string.format("; last: %s (%d) %.1f, %.1f", N.last.name or "?", N.last.id, N.last.x, N.last.y) or ""
	FS.Print(string.format("%d NPC sightings on this character (targeting within 10 yd %s)%s. /reload to hand them to your agent.",
		n, s.npcTarget == false and "off" or "on", last))
end

return N

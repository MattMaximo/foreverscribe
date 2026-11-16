-- ForeverScribe: what Polestar's guide shows right now, kept for your agent. Read-only.
-- Polestar keeps only ids and ticks in its own SavedVariables (the live step is worked out from the quest log each
-- session), so the agent could not tell "step 12 of 74: hand in X" from those alone. When Polestar is loaded this
-- reads it through calls Polestar documents (docs/API.md, docs/ARCHITECTURE.md): its messages TABS_CHANGED,
-- STEP_CHANGED and GUIDE_CHANGED (Polestar.On), Polestar.Engine.GetTabs, Polestar.Engine.GetStepView(i, true) (the
-- shared read-only view), Polestar.Engine.GetProgress and Polestar.Nav.API.Target. Nothing is ever set, ticked or
-- skipped in Polestar. Every call is pcall'd and every value cleaned; a Polestar update that changes a shape only
-- leaves fields out.
-- Stored as ForeverScribeDB.chars[<key>].snapshot.polestar = {
--   v, at, version, tabs = { {id, title, category, step, steps, number, total, done, all, complete}, ... },
--   active (tab index), step = { index, title, status, goals = { {t, text, status, cur, max}, ... } },
--   target = { map, x, y, title, kind, quest, next = { map, x, y, title, kind } } }

local FS = ForeverScribe
local U = FS.Util
local Try, Clean = U.Try, U.Clean

local G = {}
FS.Guide = G
G.FORMAT = 1
G.MAX_TABS = 12
G.MAX_GOALS = 12
G.DELAY = 2 -- seconds: Polestar fires several messages per step change; read once after they settle

local function str(v, max)
	v = Clean(v)
	if type(v) ~= "string" then return nil end
	v = v:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("|T.-|t", ""):gsub("|H.-|h(.-)|h", "%1"):gsub("[%c]", " ")
	v = v:gsub("^%s+", ""):gsub("%s+$", "")
	if v == "" then return nil end
	return v:sub(1, max or 120)
end

local function num(v)
	v = Clean(v)
	if type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge then return v end
	return nil
end

local function loaded()
	local _, l = U.Call("C_AddOns.IsAddOnLoaded", "Polestar")
	if l == nil then l = U.Call("IsAddOnLoaded", "Polestar") end
	return Clean(l) and true or false
end

-- The Polestar table, when the real addon is loaded and speaks API version 1.
function G.Polestar()
	if not loaded() then return nil end
	local P = Polestar
	if type(P) ~= "table" then return nil end
	if type(P.API) == "table" and P.API.version ~= nil and P.API.version ~= 1 then return nil end
	return P
end

local function fn(t, k) return type(t) == "table" and type(t[k]) == "function" and t[k] or nil end

local function tabsOf(P, list)
	local E = P.Engine
	local active
	if fn(E, "GetTabs") then
		local l, a = Try(E.GetTabs, true)
		if type(l) == "table" then list, active = l, num(a) end
	end
	if type(list) ~= "table" then return nil end
	local out = {}
	for i, t in ipairs(list) do
		if i > G.MAX_TABS then break end
		if type(t) == "table" then
			out[#out + 1] = {
				id = str(t.guideId, 80), title = str(t.title, 80), category = str(t.category, 30),
				step = num(t.stepIndex), steps = num(t.stepCount), number = num(t.stepNumber), total = num(t.stepTotal),
				done = num(t.done), all = num(t.total), complete = Clean(t.complete) == true or nil,
			}
		end
	end
	return out, active
end

local function stepOf(P, index)
	local E = P.Engine
	if not (index and fn(E, "GetStepView")) then return nil end
	local v = Try(E.GetStepView, index, true)
	if type(v) ~= "table" then return nil end
	local s = { index = num(v.index) or index, title = str(v.title, 100), status = str(v.status, 20), goals = {} }
	if type(v.goals) == "table" then
		for _, g in ipairs(v.goals) do
			if #s.goals >= G.MAX_GOALS then break end
			if type(g) == "table" and g.status ~= "na" then
				local p = type(g.progress) == "table" and g.progress or {}
				s.goals[#s.goals + 1] = { t = str(g.t, 20), text = str(g.text, 140), status = str(g.status, 20),
					cur = num(p.cur), max = num(p.max), optional = Clean(g.optional) == true or nil }
			end
		end
	end
	return s
end

local function point(t)
	if type(t) ~= "table" then return nil end
	local map, x, y = num(t.map), num(t.x), num(t.y)
	if not (map and x and y) then return nil end
	return { map = map, x = math.floor(x * 1000 + 0.5) / 10, y = math.floor(y * 1000 + 0.5) / 10,
		title = str(t.title, 80), kind = str(t.kind, 20), quest = num(t.quest) }
end

local function targetOf(P)
	local api = type(P.Nav) == "table" and P.Nav.API
	if not (type(api) == "table" and api.version == 1 and fn(api, "Target")) then return nil end
	local t = Try(api.Target)
	local p = point(t)
	if p and type(t) == "table" then
		p.next = point(t.next)
		p.handedOff = Clean(t.handedOff) and true or nil
		if fn(api, "Active") then
			local _, owner = Try(api.Active)
			p.owner = str(owner, 40)
		end
	end
	return p
end

local function charRecord()
	local db, ck = FS.db, FS.charKey
	if type(db) ~= "table" or not ck or type(db.chars) ~= "table" then return nil end
	return db.chars[ck]
end

G.lastTabs = nil -- the list the last TABS_CHANGED carried (a fallback when GetTabs is missing)

-- Reads Polestar now. Returns the stored table, or nil (Polestar not loaded, or nothing readable).
function G.Capture()
	local P = G.Polestar()
	local c = charRecord()
	if not (P and c and c.snapshot) or (FS.state and FS.state.leaving) then return nil end
	local tabs, active = tabsOf(P, G.lastTabs)
	local out = { v = G.FORMAT, at = (Try(time)) or 0, version = str(P.version, 30), tabs = tabs or {} }
	if not active and fn(P.Engine, "GetGuide") then
		local g = Try(P.Engine.GetGuide)
		local id = type(g) == "table" and str(g.id, 80)
		for i, t in ipairs(out.tabs) do if id and t.id == id then active = i end end
	end
	out.active = active
	local cur = active and out.tabs[active]
	local live = cur and cur.step
	if not live and fn(P.Engine, "GetLiveStep") then live = num((Try(P.Engine.GetLiveStep))) end
	out.step = stepOf(P, live)
	if cur and not cur.done and fn(P.Engine, "GetProgress") then
		local d, n = Try(P.Engine.GetProgress)
		cur.done, cur.all = num(d), num(n)
	end
	out.target = targetOf(P)
	if not (cur or out.step or out.target) and #out.tabs == 0 then
		c.snapshot.polestar = { v = G.FORMAT, at = out.at, version = out.version, tabs = {}, none = true }
		return c.snapshot.polestar
	end
	c.snapshot.polestar = U.Sanitize(out)
	G.last = c.snapshot.polestar
	return c.snapshot.polestar
end

local function later()
	if FS.Schedule then FS.Schedule("polestar", G.DELAY, function() Try(G.Capture) end) else Try(G.Capture) end
end

-- Subscribe to Polestar's public messages once it is there (after both addons loaded; any order).
G.subscribed = false
function G.Subscribe()
	if G.subscribed then return true end
	local P = G.Polestar()
	if not (P and fn(P, "On")) then return false end
	Try(P.On, "TABS_CHANGED", function(list)
		if type(list) == "table" then G.lastTabs = list end
		later()
	end)
	Try(P.On, "STEP_CHANGED", later)
	Try(P.On, "GUIDE_CHANGED", later)
	G.subscribed = true
	return true
end

function G.OnLogin()
	if G.Subscribe() then later() end
end

-- /scribe guide: what the agent will see.
function G.Command()
	local P = G.Polestar()
	if not P then FS.Print("Polestar isn't loaded: nothing to read (ForeverScribe never needs it).") return end
	G.Subscribe()
	local s = G.Capture()
	if not s or s.none then FS.Print("Polestar is loaded but no guide is open.") return end
	local cur = s.active and s.tabs[s.active]
	FS.Print(string.format("Polestar %s: %s step %s/%s%s. /reload hands it to your agent.", s.version or "?",
		cur and (cur.title or cur.id) or "no guide", tostring(cur and (cur.number or cur.step) or "?"),
		tostring(cur and (cur.total or cur.steps) or "?"), s.step and s.step.title and (" — " .. s.step.title) or ""))
end

return G

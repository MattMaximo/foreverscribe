-- ForeverScribe Live: optional low-latency outbound channel.
-- While enabled, the newest ForeverScribe events are drawn as a small strip of
-- pure-colour squares in the top-left corner. companion/live_capture.py on the
-- same Mac screen-captures that corner and decodes it. Nothing is drawn, and no
-- listener does any work, while it is off. Read-only: no input, no network.

local FS = ForeverScribe
local C = ForeverScribe_Codec
local L = {}
FS.Live = L

L.CELL, L.PER_ROW, L.MAX_ROWS = 4, 120, 24
L.MAX_PAYLOAD = C.MAX_PAYLOAD
L.IDLE_HIDE = 120 -- seconds without new events before the strip hides
L.BUFFER = 40
local RS, US = "\30", "\31"

local buf = {}
local enabled = false
local strip, pool = nil, {}
L.frames = 0

-- Pure: build the strip payload from the newest events that fit.
-- Format: "FS1" US charKey RS record RS record ... ; record = id US type US t US json(payload)
function L.BuildPayload(charKey, events, limit)
	limit = limit or L.MAX_PAYLOAD
	local head = "FS1" .. US .. tostring(charKey or "?")
	local parts, size = {}, #head
	for i = #events, 1, -1 do
		local ev = events[i]
		local rec = table.concat({ ev.id, ev.type, tostring(ev.t), FS.Util.JSON(ev.payload or {}) }, US)
		if size + #rec + 1 > limit then
			if #parts == 0 then -- a single oversized event: send it without payload
				rec = table.concat({ ev.id, ev.type, tostring(ev.t), "{\"truncated\":true}" }, US)
				if size + #rec + 1 > limit then break end
			else
				break
			end
		end
		table.insert(parts, 1, rec)
		size = size + #rec + 1
	end
	return head .. (#parts > 0 and (RS .. table.concat(parts, RS)) or ""), #parts
end

local function EnsureStrip()
	if strip then return strip end
	strip = CreateFrame("Frame", "ForeverScribeLiveStrip", UIParent)
	strip:SetFrameStrata("TOOLTIP")
	strip:SetFrameLevel(10000)
	local physH = 1080
	if GetPhysicalScreenSize then
		local ok, _, h = pcall(GetPhysicalScreenSize)
		if ok and h then physH = h end
	end
	if strip.SetIgnoreParentScale then strip:SetIgnoreParentScale(true) end
	strip:SetScale(768 / physH) -- one UI unit = one physical pixel
	strip:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 0, 0)
	strip:SetSize(L.PER_ROW * L.CELL, L.MAX_ROWS * L.CELL)
	strip:Hide()
	return strip
end

local function Hide()
	if strip then strip:Hide() end
	L.shown = false
end

local function Draw(id, payload)
	local cells = C.Encode(id % 65536, payload)
	local s = EnsureStrip()
	local total = math.ceil(#cells / L.PER_ROW) * L.PER_ROW
	for i = 1, total do
		local t = pool[i]
		if not t then
			t = s:CreateTexture(nil, "OVERLAY")
			t:SetSize(L.CELL, L.CELL)
			local c = (i - 1) % L.PER_ROW
			local r = math.floor((i - 1) / L.PER_ROW)
			t:SetPoint("TOPLEFT", s, "TOPLEFT", c * L.CELL, -r * L.CELL)
			pool[i] = t
		end
		t:SetColorTexture(C.CellColor(cells[i] or 0))
		t:Show()
	end
	for i = total + 1, #pool do pool[i]:Hide() end
	s:Show()
	L.shown = true
	L.frames = L.frames + 1
	L.lastPayload = payload
end

function L.Redraw()
	if not enabled or #buf == 0 then return Hide() end
	local payload = L.BuildPayload(FS.charKey, buf)
	local last = buf[#buf]
	local n = tonumber((tostring(last.id):match(":(%d+)$"))) or 0
	Draw(n, payload)
	FS.Schedule("live_idle", L.IDLE_HIDE, Hide)
end

function L.OnEvent(ev)
	if not enabled then return end
	buf[#buf + 1] = ev
	if #buf > L.BUFFER then table.remove(buf, 1) end
	FS.Schedule("live_redraw", 0.05, L.Redraw)
end

function L.Enable()
	enabled = true
	if not L.hooked then FS.AddListener(L.OnEvent); L.hooked = true end
	-- seed with the last few stored events so the capture side can sync at once
	local evs = FS.db and FS.charKey and FS.db.chars[FS.charKey] and FS.db.chars[FS.charKey].events or {}
	buf = {}
	for i = math.max(1, #evs - 5), #evs do buf[#buf + 1] = evs[i] end
	L.Redraw()
end

function L.Disable()
	enabled = false
	buf = {}
	Hide()
end

function L.IsEnabled() return enabled end

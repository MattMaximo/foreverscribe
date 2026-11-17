-- ForeverScribe minimap button: our own small round button on the minimap edge (scroll icon). Left-click opens the
-- options, hover shows the status line, drag moves it around the edge. Position and on/off live in
-- ForeverScribeDB.settings (minimapAngle in degrees, minimap = false when hidden); `/scribe minimap [on|off]` and the
-- options checkbox toggle it. The minimap's addon compartment entry (TOC AddonCompartmentFunc*) stays as well.
--
-- Our own code in the usual minimap-button shape (a Button parented to Minimap with the stock tracking-border ring,
-- background disc and highlight textures; the offset from the minimap centre follows the drag angle). It only creates
-- and moves its own frame and reads Minimap's size and centre: no Blizzard frame is changed, nothing is protected.

local FS = ForeverScribe
local U = FS.Util
local Try, Clean = U.Try, U.Clean

local M = {}
FS.Minimap = M
M.ICON = "Interface\\ICONS\\INV_Scroll_04"
M.DEFAULT_ANGLE = 210 -- lower left, clear of the zoom buttons, clock and mail icon
M.NAME = "ForeverScribeMinimapButton"

local function settings()
	local db = FS.db or ForeverScribeDB
	if type(db) ~= "table" then return {} end
	if type(db.settings) ~= "table" then db.settings = {} end
	return db.settings
end

function M.Enabled() return settings().minimap ~= false end

function M.Angle()
	local a = tonumber(settings().minimapAngle)
	if not a or a ~= a then return M.DEFAULT_ANGLE end
	return a % 360
end

local atan2 = math.atan2 or function(y, x) return math.atan(y, x) end

-- Offset of the button centre from the minimap centre for an angle (degrees, 0 = right, counter-clockwise).
-- Round minimap: on a circle just outside the edge. A square minimap (an addon's GetMinimapShape() says "SQUARE"):
-- the same direction pushed out to the square's edge.
function M.Offset(angle, width, height, shape)
	local r = math.rad(tonumber(angle) or M.DEFAULT_ANGLE)
	local x, y = math.cos(r), math.sin(r)
	local rx, ry = (tonumber(width) or 140) / 2 + 5, (tonumber(height) or 140) / 2 + 5
	if shape == "SQUARE" then
		local m = math.max(math.abs(x), math.abs(y))
		if m > 0 then x, y = x / m, y / m end
	end
	return x * rx, y * ry
end

-- Angle (degrees) from the minimap centre to a point, both in the same coordinates.
function M.AngleTo(cx, cy, px, py)
	return math.deg(atan2(py - cy, px - cx)) % 360
end

local function shape()
	if type(GetMinimapShape) == "function" then
		local ok, s = pcall(GetMinimapShape)
		if ok and type(s) == "string" then return s end
	end
	return "ROUND"
end

function M.Place(b)
	b = b or M.button
	if not (b and Minimap) then return end
	local w = Clean((Try(Minimap.GetWidth, Minimap)))
	local h = Clean((Try(Minimap.GetHeight, Minimap)))
	local x, y = M.Offset(M.Angle(), w, h, shape())
	pcall(b.ClearAllPoints, b)
	pcall(b.SetPoint, b, "CENTER", Minimap, "CENTER", x, y)
end

local function cursorAngle()
	if not (Minimap and type(GetCursorPosition) == "function") then return nil end
	local cx, cy = Try(Minimap.GetCenter, Minimap)
	cx, cy = Clean(cx), Clean(cy)
	local px, py = Try(GetCursorPosition)
	px, py = Clean(px), Clean(py)
	local scale = Clean((Try(Minimap.GetEffectiveScale, Minimap))) or 1
	if not (cx and cy and px and py) or scale == 0 then return nil end
	return M.AngleTo(cx, cy, px / scale, py / scale)
end

local function onDragUpdate(self)
	local a = cursorAngle()
	if a then
		settings().minimapAngle = math.floor(a * 10 + 0.5) / 10
		M.Place(self)
	end
end

local function onEnter(self)
	if self.dragging then return end
	local tt = GameTooltip
	if not (tt and tt.SetOwner and FS.Options and FS.Options.FillTooltip) then return end
	pcall(function()
		tt:SetOwner(self, "ANCHOR_LEFT")
		FS.Options.FillTooltip(tt, "Click: options · Drag: move")
		tt:Show()
	end)
end

local function onLeave()
	if GameTooltip and GameTooltip.Hide then pcall(GameTooltip.Hide, GameTooltip) end
end

local function texture(b, layer, file, size, x, y)
	local t = b:CreateTexture(nil, layer)
	pcall(t.SetSize, t, size, size)
	pcall(t.SetTexture, t, file)
	pcall(t.SetPoint, t, "TOPLEFT", b, "TOPLEFT", x or 0, y or 0)
	return t
end

function M.Create()
	if M.button then return M.button end
	if not (type(CreateFrame) == "function" and Minimap) then return nil end
	local b = CreateFrame("Button", M.NAME, Minimap)
	M.button = b
	pcall(b.SetSize, b, 31, 31)
	pcall(b.SetFrameStrata, b, "MEDIUM")
	pcall(b.SetFrameLevel, b, 8)
	pcall(b.RegisterForClicks, b, "AnyUp")
	pcall(b.RegisterForDrag, b, "LeftButton")
	pcall(b.SetHighlightTexture, b, "Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
	texture(b, "BACKGROUND", "Interface\\Minimap\\UI-Minimap-Background", 20, 7, -5)
	b.icon = texture(b, "ARTWORK", M.ICON, 17, 7, -6)
	pcall(b.icon.SetTexCoord, b.icon, 0.05, 0.95, 0.05, 0.95)
	texture(b, "OVERLAY", "Interface\\Minimap\\MiniMap-TrackingBorder", 53, 0, 0)
	b:SetScript("OnClick", function() if FS.Options then FS.Options.Open() end end)
	b:SetScript("OnEnter", onEnter)
	b:SetScript("OnLeave", onLeave)
	b:SetScript("OnDragStart", function(self)
		self.dragging = true
		onLeave()
		if self.LockHighlight then pcall(self.LockHighlight, self) end
		self:SetScript("OnUpdate", onDragUpdate)
	end)
	b:SetScript("OnDragStop", function(self)
		self:SetScript("OnUpdate", nil)
		self.dragging = nil
		if self.UnlockHighlight then pcall(self.UnlockHighlight, self) end
		M.Place(self)
	end)
	M.Place(b)
	return b
end

-- Show or hide per the setting (creates the button the first time it is shown).
function M.Apply()
	if M.Enabled() then
		local b = M.Create()
		if b then M.Place(b); pcall(b.Show, b) end
	elseif M.button then
		pcall(M.button.Hide, M.button)
	end
end

function M.Set(on)
	if on then settings().minimap = nil else settings().minimap = false end
	local ok, err = pcall(M.Apply)
	if not ok then FS.errors = (FS.errors or 0) + 1; FS.lastError = "minimap button: " .. tostring(err) end
end

-- /scribe minimap [on|off]: no argument toggles.
function M.Command(arg)
	if arg == "on" then M.Set(true) elseif arg == "off" then M.Set(false) else M.Set(not M.Enabled()) end
	FS.Print("minimap button " .. (M.Enabled() and "on (drag it to move)" or "off (/scribe minimap brings it back)"))
	if FS.Options and FS.Options.Refresh then FS.Options.Refresh() end
end

if CreateFrame then
	local f = CreateFrame("Frame")
	f:RegisterEvent("PLAYER_LOGIN")
	f:SetScript("OnEvent", function()
		local ok, err = pcall(M.Apply)
		if not ok then FS.errors = (FS.errors or 0) + 1; FS.lastError = "minimap button: " .. tostring(err) end
	end)
end

return M

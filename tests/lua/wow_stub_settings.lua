-- v0.10 additions to the simulated client: the Settings API (Esc > Options > AddOns) and the minimap addon compartment.
-- Opt-in per test (W.FakeSettings()) so every other test also covers "no Settings API". Shapes follow Forever's
-- Blizzard_Settings_Shared: RegisterVerticalLayoutCategory(name) -> category, layout; RegisterProxySetting(category,
-- variable, varType, name, default, get, set) -> setting (GetValue/SetValue/NotifyUpdate, values pass through get/set);
-- CreateCheckbox/CreateDropdown(category, setting, ...) -> initializer added to the layout; RegisterAddOnCategory;
-- OpenToCategory(id). Blizzard_Minimap/Mainline/AddonCompartment.lua reads the TOC's AddonCompartmentFunc* and calls
-- _G[name](addonName, ...) on click / enter / leave.

local W = _G.W
local baseReset = W.Reset

-- v0.10.1: the minimap (a 140x140 round frame centred at 900,600 at scale 1) and the few Button/Texture methods the
-- minimap button uses. Frame methods are added to the shared frame metatable (the one UIParent uses).
local FrameMT = getmetatable(UIParent)
for _, m in ipairs({ "RegisterForClicks", "RegisterForDrag", "SetHighlightTexture", "SetTexture", "SetTexCoord",
	"LockHighlight", "UnlockHighlight" }) do
	FrameMT[m] = FrameMT[m] or function() end
end
function FrameMT:ClearAllPoints() self.points = {} end
function FrameMT:SetPoint(...) self.points = self.points or {}; self.points[#self.points + 1] = { ... } end

function W.Reset()
	baseReset()
	W.settings = nil -- set by W.FakeSettings()
	Settings, SettingsPanel, CreateSettingsListSectionHeaderInitializer, CreateSettingsButtonInitializer = nil, nil, nil, nil
	W.cursor = { 900, 600 }
	GetMinimapShape = nil
	Minimap = setmetatable({ events = {}, scripts = {}, textures = {}, shown = true, w = 140, h = 140, cx = 900, cy = 600, scale = 1 }, FrameMT)
	function Minimap:GetWidth() return self.w end
	function Minimap:GetHeight() return self.h end
	function Minimap:GetCenter() return self.cx, self.cy end
	function Minimap:GetEffectiveScale() return self.scale end
	GetCursorPosition = function() return W.cursor[1], W.cursor[2] end
	ForeverScribeMinimapButton = nil
end

-- Drag the minimap button so the cursor ends at (x, y) in screen pixels: OnDragStart, OnUpdate ticks, OnDragStop.
function W.DragMinimapButton(x, y)
	local b = ForeverScribeMinimapButton
	b.scripts.OnDragStart(b)
	W.cursor = { x, y }
	if b.scripts.OnUpdate then b.scripts.OnUpdate(b, 0.016) end
	b.scripts.OnDragStop(b)
	return b
end

function W.FakeSettings()
	local S = { categories = {}, addOnCategories = {}, settings = {}, opened = {}, notified = {}, panelShown = false }
	W.settings = S
	local nextID = 100
	local function initializer(kind, data)
		local init = { kind = kind, data = data or {} }
		function init:SetParentInitializer(parent, pred) self.parent, self.modify = parent, pred end
		return init
	end
	local function layoutFor(cat) return cat.layout end
	Settings = {
		VarType = { Boolean = "boolean", String = "string", Number = "number" },
		RegisterVerticalLayoutCategory = function(name)
			nextID = nextID + 1
			local layout = { initializers = {} }
			function layout:AddInitializer(i) self.initializers[#self.initializers + 1] = i end
			local cat = { name = name, ID = nextID, layout = layout }
			function cat:GetID() return self.ID end
			S.categories[#S.categories + 1] = cat
			return cat, layout
		end,
		RegisterAddOnCategory = function(cat) S.addOnCategories[#S.addOnCategories + 1] = cat end,
		RegisterProxySetting = function(cat, variable, varType, name, default, get, set)
			assert(type(variable) == "string" and type(name) == "string" and type(varType) == "string", "bad proxy args")
			assert(type(get) == "function" and type(set) == "function", "proxy needs get/set")
			local s = { variable = variable, varType = varType, name = name, default = default, get = get, set = set, cat = cat }
			function s:GetValue() return self.get() end
			function s:SetValue(v)
				assert(type(v) == self.varType, variable .. ": " .. type(v) .. " for a " .. self.varType .. " setting")
				if self.get() ~= v then self.set(v) end
			end
			function s:NotifyUpdate() S.notified[self.variable] = (S.notified[self.variable] or 0) + 1 end
			S.settings[variable] = s
			return s
		end,
		CreateCheckbox = function(cat, setting, tooltip)
			local i = initializer("checkbox", { setting = setting, tooltip = tooltip }); layoutFor(cat):AddInitializer(i); return i
		end,
		CreateDropdown = function(cat, setting, options, tooltip)
			local i = initializer("dropdown", { setting = setting, options = options, tooltip = tooltip }); layoutFor(cat):AddInitializer(i); return i
		end,
		CreateControlTextContainer = function()
			local c = { data = {} }
			function c:Add(value, label) self.data[#self.data + 1] = { value = value, label = label } end
			function c:GetData() return self.data end
			return c
		end,
		CreateElementInitializer = function(template, data) return initializer(template, data) end,
		OpenToCategory = function(id) S.opened[#S.opened + 1] = id; S.panelShown = true end,
	}
	CreateSettingsListSectionHeaderInitializer = function(name, tooltip) return initializer("header", { name = name, tooltip = tooltip }) end
	CreateSettingsButtonInitializer = function(name, text, click, tooltip, addSearchTags)
		assert(addSearchTags ~= nil, "the real CreateSettingsButtonInitializer asserts addSearchTags ~= nil")
		return initializer("button", { name = name, text = text, click = click, tooltip = tooltip })
	end
	SettingsPanel = { IsShown = function() return S.panelShown end }
	return S
end

-- What the panel would show: the initializers of our category, in order.
function W.SettingsRows()
	local S = W.settings
	local cat = S and S.categories[1]
	return cat and cat.layout.initializers or {}
end

-- The ForeverScribeStatusLineTemplate rows, rendered the way the settings list would (frame:Init(initializer)).
function W.RenderStatusRows()
	local out = {}
	for _, i in ipairs(W.SettingsRows()) do
		if i.kind == "ForeverScribeStatusLineTemplate" then
			local frame = setmetatable({ Text = { SetText = function(self, t) self.t = t end } }, { __index = ForeverScribeStatusLineMixin })
			frame:Init(i)
			out[#out + 1] = frame.Text.t
		end
	end
	return out
end

-- TOC field lookup like C_AddOns.GetAddOnMetadata(name, field).
function W.TocField(name, field)
	local f = assert(io.open(W.ROOT .. "addon/" .. name .. "/" .. name .. ".toc"))
	local body = f:read("*a"); f:close()
	return body:match("\n## " .. field .. ": ([^\r\n]+)") or body:match("^## " .. field .. ": ([^\r\n]+)")
end

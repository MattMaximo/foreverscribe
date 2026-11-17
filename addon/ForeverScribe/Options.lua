-- ForeverScribe options: Esc > Options > AddOns > ForeverScribe, `/scribe` with no arguments, and the minimap's
-- addon-compartment button (TOC AddonCompartmentFunc*).
--
-- Every control is a proxy setting over ForeverScribeDB.settings, the same keys the slash commands write, so the two
-- always agree: the panel reads the table whenever it is drawn, and a slash command refreshes an open panel.
-- Read-only like the rest of the addon: no protected calls, nothing reloads by itself. The one button,
-- "Save (/reload)", runs /reload only when the player clicks it (the same thing typing /reload does).
-- Settings API shapes: Forever's Blizzard_Settings_Shared (Blizzard_Settings.lua RegisterVerticalLayoutCategory,
-- RegisterProxySetting, CreateCheckbox, CreateDropdown, CreateControlTextContainer, RegisterAddOnCategory,
-- OpenToCategory; Blizzard_SettingControls.lua CreateSettingsListSectionHeaderInitializer,
-- CreateSettingsButtonInitializer). Every call is pcall-guarded: without the API there is no panel and
-- `/scribe` prints the command list instead.

local FS = ForeverScribe
local U = FS.Util
local Try, Call, Clean = U.Try, U.Call, U.Clean

local O = {}
FS.Options = O
O.NAME = "ForeverScribe"
O.REMIND_CHOICES = { 0, 15, 30, 60 }
O.vars = {} -- variable -> proxy setting object (when the Settings API took it)

local function settings()
	local db = FS.db or ForeverScribeDB
	if type(db) ~= "table" then return {} end
	if type(db.settings) ~= "table" then db.settings = {} end
	return db.settings
end

---------------------------------------------------------------------------
-- Values (pure: the panel and the tests use these; slash commands write the same keys)
---------------------------------------------------------------------------

-- The tooltip mode is one key, tooltip = "on" | "off" | "shift" (/scribe tooltip on|off|shift); the panel shows it
-- as two checkboxes: "AH prices in tooltips" and, under it, "Only with Shift".
O.Values = {
	FOREVERSCRIBE_TOOLTIP = {
		type = "boolean", default = true,
		get = function() return settings().tooltip ~= "off" end,
		set = function(v) settings().tooltip = v and "on" or "off" end,
	},
	FOREVERSCRIBE_TOOLTIP_SHIFT = {
		type = "boolean", default = false,
		get = function() return settings().tooltip == "shift" end,
		set = function(v)
			local s = settings()
			if s.tooltip ~= "off" then s.tooltip = v and "shift" or "on" end
		end,
	},
	FOREVERSCRIBE_CRAFTPRICES = {
		type = "boolean", default = true,
		get = function() return settings().craftprices ~= "off" end,
		set = function(v)
			if FS.Craft and FS.Craft.Set then FS.Craft.Set(v) else settings().craftprices = v and "on" or "off" end
		end,
	},
	FOREVERSCRIBE_REMIND = {
		type = "number", default = 0,
		get = function() return FS.ReminderMinutes and FS.ReminderMinutes() or 0 end,
		set = function(v) settings().remind = math.max(0, math.floor(tonumber(v) or 0)) end,
	},
	FOREVERSCRIBE_WAYADDON = {
		type = "string", default = "auto",
		get = function() return settings().wayAddon == "native" and "native" or "auto" end,
		set = function(v) settings().wayAddon = (v == "native") and "native" or nil end,
	},
	FOREVERSCRIBE_MINIMAP = {
		type = "boolean", default = true,
		get = function() return settings().minimap ~= false end,
		set = function(v)
			if FS.Minimap and FS.Minimap.Set then FS.Minimap.Set(v) elseif v then settings().minimap = nil else settings().minimap = false end
		end,
	},
	-- Slash-command-only settings (not on the panel): /scribe npcs target on|off, /scribe played on|off.
	FOREVERSCRIBE_NPCTARGET = {
		type = "boolean", default = true,
		get = function() return settings().npcTarget ~= false end,
		set = function(v) if v then settings().npcTarget = nil else settings().npcTarget = false end end,
	},
	FOREVERSCRIBE_PLAYED = {
		type = "boolean", default = true,
		get = function() return settings().played ~= false end,
		set = function(v) settings().played = v and true or false end,
	},
}

function O.Get(var) local d = O.Values[var]; return d and d.get() end
function O.Set(var, v) local d = O.Values[var]; if d then d.set(v) end end

-- Reminder choices: off/15/30/60, plus the current value when a slash command set another one (/scribe remind 45).
function O.RemindChoices()
	local out, cur = {}, O.Get("FOREVERSCRIBE_REMIND") or 0
	local seen = false
	for _, m in ipairs(O.REMIND_CHOICES) do
		out[#out + 1] = m
		if m == cur then seen = true end
	end
	if not seen then out[#out + 1] = cur; table.sort(out) end
	return out
end

function O.RemindLabel(m) return (m or 0) <= 0 and "Off" or (m .. " min") end

---------------------------------------------------------------------------
-- Status line (read-only): "v0.10.1 · saved 2 min ago · prices 3 h old"
---------------------------------------------------------------------------

local function now() return (Try(time)) or 0 end

local function ago(sec)
	sec = math.max(0, math.floor(tonumber(sec) or 0))
	if sec < 90 then return "just now" end
	if sec < 5400 then return math.floor(sec / 60 + 0.5) .. " min ago" end
	if sec < 172800 then return math.floor(sec / 3600 + 0.5) .. " h ago" end
	return math.floor(sec / 86400 + 0.5) .. " days ago"
end
O.Ago = ago

local function age(sec) return (ago(sec):gsub(" ago$", " old"):gsub("^just now$", "fresh")) end

-- The game writes SavedVariables right before each UI session starts (login, /reload), so "saved" is that moment.
function O.StatusLine(t)
	t = t or now()
	local bits = { "v" .. tostring(FS.VERSION) }
	local loaded = FS.state and FS.state.loadedAt
	if loaded then bits[#bits + 1] = "saved " .. ago(t - loaded) end
	local P = FS.Tooltip and FS.Tooltip.Data and FS.Tooltip.Data()
	if P and tonumber(P.captured) then
		bits[#bits + 1] = "prices " .. age(t - P.captured)
	else
		bits[#bits + 1] = "no prices yet"
	end
	return table.concat(bits, " · ")
end

function O.StatusLines(t) return { O.StatusLine(t) } end

---------------------------------------------------------------------------
-- Panel
---------------------------------------------------------------------------

-- Template mixin for the status rows (Options.xml: ForeverScribeStatusLineTemplate). Our own template, so the
-- settings list never hands our code one of Blizzard's pooled frames.
ForeverScribeStatusLineMixin = {}
function ForeverScribeStatusLineMixin:Init(initializer)
	local data = initializer and initializer.data or {}
	local ok, text = pcall(function() return O.StatusLines()[data.line or 1] end)
	if self.Text then self.Text:SetText(ok and text or "") end
end
function ForeverScribeStatusLineMixin:Release() end

local function api(name) return type(Settings) == "table" and type(Settings[name]) == "function" and Settings[name] or nil end

function O.Available() return api("RegisterVerticalLayoutCategory") ~= nil and api("RegisterAddOnCategory") ~= nil end

local function proxy(category, var, label)
	local d = O.Values[var]
	local setting = Settings.RegisterProxySetting(category, var, d.type, label, d.default, d.get, d.set)
	O.vars[var] = setting
	return setting
end

local function header(layoutAdd, name, tooltip)
	if type(CreateSettingsListSectionHeaderInitializer) == "function" then
		layoutAdd(CreateSettingsListSectionHeaderInitializer(name, tooltip))
	end
end

local function build()
	local category, layout = Settings.RegisterVerticalLayoutCategory(O.NAME)
	O.category = category
	local function add(init)
		if not init then return end
		if layout and layout.AddInitializer then layout:AddInitializer(init)
		elseif api("RegisterInitializer") then Settings.RegisterInitializer(category, init) end
	end

	-- Short labels only (Matt: "less text"); each control's tooltip holds one short line.
	header(add, "Prices")
	local tip = proxy(category, "FOREVERSCRIBE_TOOLTIP", "AH prices in tooltips")
	local tipInit = Settings.CreateCheckbox(category, tip, "Auction prices on item tooltips.")
	local shift = proxy(category, "FOREVERSCRIBE_TOOLTIP_SHIFT", "Only with Shift")
	local shiftInit = Settings.CreateCheckbox(category, shift, "Show prices only while Shift is held.")
	if shiftInit and shiftInit.SetParentInitializer and tipInit then
		shiftInit:SetParentInitializer(tipInit, function() return O.Get("FOREVERSCRIBE_TOOLTIP") end)
	end
	local craft = proxy(category, "FOREVERSCRIBE_CRAFTPRICES", "Craft profit")
	Settings.CreateCheckbox(category, craft, "Cost and profit in the profession window.")

	header(add, "General")
	local remind = proxy(category, "FOREVERSCRIBE_REMIND", "Reload reminder")
	Settings.CreateDropdown(category, remind, function()
		local c = Settings.CreateControlTextContainer()
		for _, m in ipairs(O.RemindChoices()) do c:Add(m, O.RemindLabel(m)) end
		return c:GetData()
	end, "A chat reminder to /reload so your agent gets new data.")
	local way = proxy(category, "FOREVERSCRIBE_WAYADDON", "Waypoint arrow")
	Settings.CreateDropdown(category, way, function()
		local c = Settings.CreateControlTextContainer()
		c:Add("auto", "Auto")
		c:Add("native", "Game")
		return c:GetData()
	end, "Auto uses Polestar or TomTom when loaded.")
	local mm = proxy(category, "FOREVERSCRIBE_MINIMAP", "Minimap button")
	Settings.CreateCheckbox(category, mm, "Drag it around the minimap edge.")

	header(add, "Status")
	add(Settings.CreateElementInitializer("ForeverScribeStatusLineTemplate", { line = 1 }))
	if type(CreateSettingsButtonInitializer) == "function" and type(ReloadUI) == "function" then
		add(CreateSettingsButtonInitializer("", "Save (/reload)", function() ReloadUI() end, nil, false))
	end

	Settings.RegisterAddOnCategory(category)
	return true
end

function O.Register()
	if O.registered ~= nil then return O.registered end
	if not O.Available() then O.registered = false; return false end
	local ok, err = pcall(build)
	if not ok then
		FS.errors = (FS.errors or 0) + 1
		FS.lastError = "options panel: " .. tostring(err)
	end
	O.registered = ok and O.category ~= nil
	return O.registered
end

-- Open the panel on our page. Combat is the one time the game refuses addons this; say so instead.
function O.Open()
	if not O.Register() then return false end
	if Clean((Call("InCombatLockdown"))) then
		FS.Print("the options open after combat (/scribe help lists the commands)")
		return true
	end
	local id = O.category and O.category.GetID and Try(O.category.GetID, O.category)
	local ok = pcall(Settings.OpenToCategory, id)
	if not ok then FS.Print("could not open the options; /scribe help lists the commands") end
	return ok
end

-- After a slash command: redraw an open panel so it shows the new value. A closed panel reads the table when shown.
function O.Refresh()
	if not O.registered then return end
	local panel = SettingsPanel
	if not (panel and panel.IsShown and Clean((Try(panel.IsShown, panel)))) then return end
	for _, setting in pairs(O.vars) do
		if setting and setting.NotifyUpdate then pcall(setting.NotifyUpdate, setting) end
	end
end

---------------------------------------------------------------------------
-- Minimap addon compartment (TOC: AddonCompartmentFunc, AddonCompartmentFuncOnEnter, AddonCompartmentFuncOnLeave)
---------------------------------------------------------------------------

-- Shared by the compartment entry and the minimap button.
function O.FillTooltip(tt, extra)
	tt:AddLine("ForeverScribe", 1, 0.82, 0)
	tt:AddLine(O.StatusLine(), 1, 1, 1)
	tt:AddLine(extra or "Click: options", 0.6, 0.8, 1)
end

function ForeverScribe_OnAddonCompartmentClick(addonName, buttonName)
	O.Open()
end

function ForeverScribe_OnAddonCompartmentEnter(addonName, button)
	local tt = GameTooltip
	if not (tt and tt.SetOwner) then return end
	pcall(function()
		tt:SetOwner(button or UIParent, "ANCHOR_LEFT")
		O.FillTooltip(tt)
		tt:Show()
	end)
end

function ForeverScribe_OnAddonCompartmentLeave(addonName, button)
	if GameTooltip and GameTooltip.Hide then pcall(GameTooltip.Hide, GameTooltip) end
end

-- Register once the saved settings exist.
if CreateFrame then
	local f = CreateFrame("Frame")
	f:RegisterEvent("PLAYER_LOGIN")
	f:SetScript("OnEvent", function() O.Register() end)
end

return O

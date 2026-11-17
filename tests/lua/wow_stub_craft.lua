-- v0.8 additions to the simulated client: the profession window. Shapes from Forever's UI source:
--   ProfessionsFrame.CraftingPage.SchematicForm (Blizzard_Professions/Blizzard_ProfessionsCrafting.xml:143), 484 high
--   (Camelot SchematicFormCraftingTemplate) with .Reagents / .OptionalReagents containers (ResizeLayoutFrame: they
--   grow with their slots; basic reagents 4 per column, 50 high + 5 apart, under a 20 high "Reagents:" label;
--   Blizzard_ProfessionsRecipeSchematicForm.lua:1274-1305, Blizzard_ProfessionsRecipeReagentSlotBase.xml:7) and
--   ProfessionsRecipeSchematicFormMixin:GetRecipeInfo() (:1530);
--   a failed profession cast (dead, ghost, combat) still shows the crafting page, with nothing loaded
--   (ProfessionsFrameRightTabMixin:OnClick, Blizzard_ProfessionsTemplates.lua:983-990): professionID 0
--   (ProfessionsMixin:Refresh, Blizzard_ProfessionsFrame.lua:284), no TRADE_SKILL_SHOW;
--   C_TradeSkillUI.GetRecipeSchematic -> CraftingRecipeSchematic (TradeSkillUITypesDocumentation.lua:281);
--   Enum.CraftingReagentType.Basic = 1 (ProfessionConstantsDocumentation.lua:195); bindType 1 = bind on pickup.
--
-- Do-not-touch contract: every Blizzard profession frame is a proxy that records each write (W.blizz.writes) and each
-- method call (W.blizz.calls) made from outside the stub itself (the stub's own moves run inside W.internal).

local W = _G.W
local baseReset = W.Reset

W.blizz = { calls = {}, writes = {} }
local stubbing = 0
function W.internal(fn, ...) stubbing = stubbing + 1; local r = { pcall(fn, ...) }; stubbing = stubbing - 1
	if not r[1] then error(r[2], 2) end return unpack(r, 2) end

local function frame(name, geo)
	local o = { shown = false, name = name, geo = geo or {} }
	function o:IsShown() return self.shown end
	function o:Show() self.shown = true end
	function o:Hide() self.shown = false end
	function o:GetBottom() return self.geo.bottom end
	function o:GetTop() return self.geo.top end
	function o:GetFrameStrata() return "MEDIUM" end
	function o:GetFrameLevel() return 10 end
	local proxy = {}
	return setmetatable(proxy, {
		__index = function(_, k)
			local v = o[k]
			if type(v) ~= "function" then return v end
			return function(self, ...)
				if stubbing == 0 then table.insert(W.blizz.calls, name .. ":" .. k) end
				return v(self == proxy and o or self, ...)
			end
		end,
		__newindex = function(_, k, v)
			if stubbing == 0 then table.insert(W.blizz.writes, name .. "." .. tostring(k)) end
			o[k] = v
		end,
		__raw = o,
	})
end
local function raw(p) return getmetatable(p).__raw end

Enum = Enum or {}
Enum.CraftingReagentType = { Modifying = 0, Basic = 1, Finishing = 2, Automatic = 3 }

function UnitIsDeadOrGhost(unit) return unit == "player" and W.dead or false end

W.profID = 0
local baseBase = C_TradeSkillUI.GetBaseProfessionInfo
C_TradeSkillUI.GetBaseProfessionInfo = function()
	local t = baseBase() or {}
	t.professionID = W.profID
	return t
end
C_TradeSkillUI.GetChildProfessionInfo = function() return { professionID = W.profID } end

-- Form geometry (screen units, form 100..584): the reagent list starts under the description and grows down.
W.FORM_BOTTOM, W.FORM_TOP = 100, 584
local function layout(nReagents, nOptional)
	local pf = ProfessionsFrame
	local form = raw(pf.CraftingPage.SchematicForm)
	local reag, opt = raw(form.Reagents), raw(form.OptionalReagents)
	local top = W.FORM_TOP - 130 - (W.descExtra or 0)
	reag.shown = nReagents > 0
	local rows = math.min(nReagents, 4)
	reag.geo = { top = top, bottom = top - 20 - rows * 50 - math.max(0, rows - 1) * 5 }
	opt.shown = (nOptional or 0) > 0
	opt.geo = { top = reag.geo.bottom - 20, bottom = reag.geo.bottom - 20 - 20 - 40 * math.ceil((nOptional or 0) / 4) }
end

local function build()
	if ProfessionsFrame then return end
	W.internal(function()
		local pf = frame("ProfessionsFrame", { bottom = 60, top = 640 })
		local page = frame("CraftingPage", { bottom = 60, top = 610 })
		local form = frame("SchematicForm", { bottom = W.FORM_BOTTOM, top = W.FORM_TOP })
		form.Init = function(self, info) self.info = info; W.formInits = (W.formInits or 0) + 1 end
		form.GetRecipeInfo = function(self) return self.info end
		form.Reagents = frame("Reagents")
		form.OptionalReagents = frame("OptionalReagents")
		form.TrackRecipeCheckbox = frame("TrackRecipeCheckbox", { bottom = W.FORM_BOTTOM + 11, top = W.FORM_BOTTOM + 37 })
		page.SchematicForm = form
		pf.CraftingPage = page
		ProfessionsFrame = pf
	end)
	W.Fire("ADDON_LOADED", "Blizzard_Professions")
end

-- The profession window (Blizzard_Professions, load-on-demand) opened on a profession that loads.
function W.OpenProfessions()
	build()
	W.internal(function()
		ProfessionsFrame:Show(); ProfessionsFrame.CraftingPage:Show(); ProfessionsFrame.CraftingPage.SchematicForm:Show()
	end)
	W.profID = 197
	W.Fire("TRADE_SKILL_SHOW")
	return ProfessionsFrame
end

-- A profession tab clicked while the cast fails (dead, ghost, combat): crafting page shown, nothing loaded, no event.
function W.OpenProfessionsFailed()
	build()
	W.internal(function()
		local form = ProfessionsFrame.CraftingPage.SchematicForm
		ProfessionsFrame:Show(); ProfessionsFrame.CraftingPage:Show(); form:Show()
		-- the form keeps whatever recipe it last showed (SchematicForm:Init runs only for a new recipe)
		if not form.info then layout(0) end
	end)
	W.profID = 0
	return ProfessionsFrame
end

function W.CloseProfessions()
	W.internal(function()
		ProfessionsFrame:Hide() -- CraftingPage:Reset() clears only its professionInfo, not the form's recipe
	end)
	W.profID = 0
	W.Fire("TRADE_SKILL_CLOSE")
	W.TickUpdates(1)
end

-- Click a recipe in the list (Blizzard calls SchematicForm:Init with its recipeInfo and lays out the reagents).
function W.SelectRecipe(rid, nReagents, nOptional)
	local r = W.trade and W.trade.recipes[rid]
	if not nReagents then
		nReagents = r and r.reagents and #r.reagents or 0
		local d = ForeverScribe_PriceData
		local s = d and d.p and d.p[100000000 + rid]
		if nReagents == 0 and type(s) == "string" then
			for _ in (s:match(";(.*)$") or ""):gmatch("%d+:%d+") do nReagents = nReagents + 1 end
		end
	end
	W.internal(function()
		ProfessionsFrame.CraftingPage.SchematicForm:Init({ recipeID = rid, name = r and r.name, learned = true })
		layout(nReagents, nOptional)
	end)
	W.TickUpdates(1)
end

-- Run every frame's OnUpdate once (the craft numbers watch the profession window from our own frame).
function W.TickUpdates(e)
	for _, f in ipairs(W.updaters or {}) do
		if f.scripts and f.scripts.OnUpdate then f.scripts.OnUpdate(f, e or 1) end
	end
end

-- Our own frames: font strings, points, strata. (Added to the stub's frame metatable.)
local FrameMT = getmetatable(UIParent)
local FontMT = {}
FontMT.__index = FontMT
function FontMT:SetText(s) self.text = s end
function FontMT:GetText() return self.text end
function FontMT:Show() self.shown = true end
function FontMT:Hide() self.shown = false end
function FontMT:IsShown() return self.shown end
function FontMT:SetPoint(...) self.points[#self.points + 1] = { ... } end
function FontMT:ClearAllPoints() self.points = {} end
function FontMT:SetTextColor() end
function FontMT:GetStringWidth() return #(W.Plain(self.text or "")) * 5 end
function FrameMT:CreateFontString(name, layer, font)
	local fs = setmetatable({ font = font, layer = layer, text = "", shown = true, points = {} }, FontMT)
	self.fontStrings = self.fontStrings or {}
	table.insert(self.fontStrings, fs)
	return fs
end
function FrameMT:SetPoint(...) self.points = self.points or {}; self.points[#self.points + 1] = { ... } end
function FrameMT:ClearAllPoints() self.points = {} end
function FrameMT:SetHeight(h) self.height = h end
function FrameMT:SetSize(w, h) self.width, self.height = w, h end
function FrameMT:SetFrameStrata(s) self.strata = s end
function FrameMT:SetFrameLevel(l) self.level = l end

-- Text with coins as g/s/c and colour codes stripped.
function W.Plain(s)
	s = tostring(s or ""):gsub("|T[^|]*|t", function(m) return m:find("GOLD") and "g" or m:find("SILVER") and "s" or m:find("COPPER") and "c" or "" end)
	return (s:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""))
end

-- The craft numbers as "Label: value · note" lines (nil when not shown).
function W.PanelText()
	W.TickUpdates(1)
	local f = _G.ForeverScribeCraftNumbers
	if not f or not f.shown then return nil end
	local out = {}
	for i = 1, f.n or 0 do
		local r = f.rows[i]
		local s = W.Plain(r.label.text) .. " " .. W.Plain(r.value.text)
		if r.note.shown and (r.note.text or "") ~= "" then s = s .. " · " .. W.Plain(r.note.text) end
		out[#out + 1] = s
	end
	return out
end

-- The empty-window message (nil when not shown).
function W.NoticeText()
	local f = _G.ForeverScribeCraftNotice
	if not f or not f.shown then return nil end
	return f.title.text .. " " .. f.body.text
end

C_Item.GetItemNameByID = function(id) return W.items[id] and W.items[id].name end

local baseSchematic = C_TradeSkillUI.GetRecipeSchematic
C_TradeSkillUI.GetRecipeSchematic = function(rid, isRecraft)
	local r = W.trade and W.trade.recipes[rid]
	if not (r and r.reagents) then return baseSchematic(rid, isRecraft) end
	local slots = {}
	for i, x in ipairs(r.reagents) do
		slots[i] = { quantityRequired = x.qty, reagentType = x.type or 1, required = x.type == nil or x.type == 1,
			reagents = { { itemID = x.itemID } } }
	end
	return { recipeID = rid, outputItemID = r.output, quantityMin = r.qty or 1, quantityMax = r.qty or 1,
		reagentSlotSchematics = slots }
end

function W.Reset()
	baseReset()
	ProfessionsFrame, ForeverScribeCraftNumbers, ForeverScribeCraftNotice, ForeverScribe_PriceData = nil, nil, nil, nil
	W.formInits, W.dead, W.profID, W.descExtra = 0, false, 0, nil
	W.blizz = { calls = {}, writes = {} }
	W.items[2996] = { name = "Bolt of Linen Cloth", quality = 1, stack = 20, sell = 40, class = 7 }
	W.items[2589] = { name = "Linen Cloth", quality = 1, stack = 20, sell = 13, class = 7 }
	W.items[2320] = { name = "Coarse Thread", quality = 1, stack = 20, sell = 2, class = 7 }
	W.items[2321] = { name = "Fine Thread", quality = 1, stack = 20, sell = 25, class = 7 }
	W.items[4344] = { name = "Brown Linen Shirt", quality = 1, sell = 18, class = 4 }
	W.items[6385] = { name = "Stylish Green Shirt", quality = 2, sell = 400, class = 4 }
	W.items[2605] = { name = "Green Dye", quality = 1, stack = 20, sell = 25, class = 7 }
	W.items[253885] = { name = "Novice Arcanist's Sash", quality = 3, sell = 300, class = 4, bind = 1 }
	W.items[2455] = { name = "Minor Mana Potion", quality = 1, stack = 5, sell = 5, class = 0 }
	W.items[6888] = { name = "Herb Baked Egg", quality = 1, stack = 20, sell = 6, class = 0 }
	W.items[6889] = { name = "Small Egg", quality = 1, stack = 10, sell = 4, class = 7 }
	W.items[2678] = { name = "Mild Spices", quality = 1, stack = 20, sell = 1, class = 7 }
	W.trade = W.trade or { recipes = {} }
	W.trade.recipes = W.trade.recipes or {}
end

-- A price file with the 0.8 craft rows (what the companion writes): vendor prices as the 7th field of d rows,
-- recipes at p[100000000 + recipeID] = "product,qty,cost,sells;reagent:n,...", p[100000000] = AH cut in bp.
function W.CraftPrices(over)
	local d = W.Prices()
	d.d[2996] = "62,55,900,60,61"
	d.d[2320] = "15,12,400,15,15,,10" -- vendor 10c: cheaper than the AH
	d.d[2321] = "105,100,800,104,110,,100"
	d.d[2605] = "212,200,30,210,220,,100"
	d.d[4344] = "100,95,10,100,100"
	d.d[6385] = "7490,7000,3,7400,7300"
	d.d[2678] = ",,,,,,2" -- vendor only (nobody lists it)
	d.d[6888] = "50,45,40,50,52"
	d.d[2455] = nil
	d.d[253885] = nil -- bind on pickup: never on the AH
	local B = 100000000
	d.p[B] = "500"
	d.p[B + 3915] = "4344,1,72,100;2996:1,2320:1"
	d.p[B + 7892] = "6385,1,2730,7490;2997:4,2605:2,4340:1,2321:1"
	d.p[B + 253886] = "253885,1,,;2996:8,2321:2,2455:2" -- Minor Mana Potion has no price: cost unknown
	for k, v in pairs(over or {}) do d[k] = v end
	ForeverScribe_PriceData = d
	return d
end

return W

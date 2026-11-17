-- v0.8 additions to the simulated client: the profession window. Shapes from Forever's UI source:
--   ProfessionsFrame.CraftingPage.SchematicForm (Blizzard_Professions/Blizzard_ProfessionsCrafting.xml:143) with
--   ProfessionsRecipeSchematicFormMixin:Init(recipeInfo) / :GetRecipeInfo() (Blizzard_ProfessionsRecipeSchematicForm.lua
--   :361, :1530); EventRegistry:TriggerEvent("Professions.RecipeListOnEnter", row, elementData.data)
--   (Blizzard_ProfessionsRecipeList.lua:394); callbacks get (owner, ...) (CallbackRegistry.lua:184);
--   C_TradeSkillUI.GetRecipeSchematic -> CraftingRecipeSchematic (TradeSkillUITypesDocumentation.lua:281);
--   Enum.CraftingReagentType.Basic = 1 (ProfessionConstantsDocumentation.lua:195); bindType 1 = bind on pickup.

local W = _G.W
local baseReset = W.Reset

local function frame(name)
	local f = { shown = false, hooks = {}, name = name }
	function f:IsShown() return self.shown end
	function f:Show() self.shown = true; for _, h in ipairs(self.hooks.OnShow or {}) do h(self) end end
	function f:Hide() self.shown = false; for _, h in ipairs(self.hooks.OnHide or {}) do h(self) end end
	function f:HookScript(s, fn) self.hooks[s] = self.hooks[s] or {}; table.insert(self.hooks[s], fn) end
	return f
end

function hooksecurefunc(t, name, fn)
	if type(t) == "string" then t, name, fn = _G, t, name end
	local orig = t[name]
	t[name] = function(...) local r = { orig(...) }; fn(...); return unpack(r) end
	W.secureHooks = (W.secureHooks or 0) + 1
end

EventRegistry = {
	cb = {},
	RegisterCallback = function(self, ev, fn, owner) self.cb[ev] = self.cb[ev] or {}; table.insert(self.cb[ev], { fn, owner }) end,
	TriggerEvent = function(self, ev, ...) for _, c in ipairs(self.cb[ev] or {}) do c[1](c[2], ...) end end,
}

Enum = Enum or {}
Enum.CraftingReagentType = { Modifying = 0, Basic = 1, Finishing = 2, Automatic = 3 }

-- The profession window (Blizzard_Professions, load-on-demand): created when the player opens a profession.
function W.OpenProfessions()
	if not ProfessionsFrame then
		local pf = frame("ProfessionsFrame")
		pf.CraftingPage = frame("CraftingPage")
		local form = frame("SchematicForm")
		form.Init = function(self, info) self.info = info; W.formInits = (W.formInits or 0) + 1 end
		form.GetRecipeInfo = function(self) return self.info end
		pf.CraftingPage.SchematicForm = form
		pf.CraftingPage.shown = true
		ProfessionsFrame = pf
		W.Fire("ADDON_LOADED", "Blizzard_Professions")
	end
	ProfessionsFrame:Show()
	W.Fire("TRADE_SKILL_SHOW")
	return ProfessionsFrame
end

-- Click a recipe in the list (Blizzard calls SchematicForm:Init with its recipeInfo).
function W.SelectRecipe(rid)
	local r = W.trade and W.trade.recipes[rid]
	ProfessionsFrame.CraftingPage.SchematicForm:Init({ recipeID = rid, name = r and r.name, learned = true })
	W.TickUpdates(1)
end

function W.HoverRecipe(rid)
	local r = W.trade and W.trade.recipes[rid]
	local row = { Label = {} }
	GameTooltip.lines, GameTooltip.owner, GameTooltip.shown = {}, nil, false
	EventRegistry:TriggerEvent("Professions.RecipeListOnEnter", row, { recipeInfo = { recipeID = rid, name = r and r.name } })
	return row
end

-- Our panel's lines as plain text (coins as g/s/c, colour codes stripped)
-- Run every frame's OnUpdate once (the craft panel watches the profession window from its own frame).
function W.TickUpdates(e)
	for _, f in ipairs(W.updaters or {}) do
		if f.scripts and f.scripts.OnUpdate then f.scripts.OnUpdate(f, e or 1) end
	end
end

function W.PanelText()
	W.TickUpdates(1)
	local t = _G.ForeverScribeCraftTip
	if not t or not t.shown then return nil end
	return W.TipText(t)
end

local baseCreate = CreateFrame
function CreateFrame(kind, name, parent, template)
	if kind == "GameTooltip" then
		return W.NewTip(name)
	end
	return baseCreate(kind, name, parent, template)
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
	ProfessionsFrame, ForeverScribeCraftTip, ForeverScribe_PriceData = nil, nil, nil
	W.secureHooks, W.formInits = 0, 0
	EventRegistry.cb = {}
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

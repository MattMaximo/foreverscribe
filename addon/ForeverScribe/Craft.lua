-- ForeverScribe craft cost & profit in the profession window (0.8). Read-only: a tooltip-styled panel beside the
-- profession window for the selected recipe, plus a short line when you hover a recipe in the list. It never crafts,
-- buys or sells, never touches the Create buttons, and only post-hooks Blizzard code (hooksecurefunc / HookScript /
-- EventRegistry callbacks); every game call is pcall'd and secret values are dropped.
--   Cost to craft  materials at their typical AH price, or the vendor's price where a vendor sells them cheaper
--   Sells for      the crafted item's typical AH price x how many one craft makes
--   Profit         sells for - the AH cut - cost (green / red)
-- A line that can't be calculated is left out, never guessed (bind-on-pickup result, material with no price).
-- Prices come from the companion's price file (ForeverScribe_Prices): for the recipes your characters know, product,
-- count, cost and sells-for are precomputed there (p[100000000 + recipeID]), so selecting a recipe is a table lookup;
-- other recipes are read from the client's own recipe schematic.
-- Frame and API names: Forever UI source, Blizzard_Professions (ProfessionsFrame.CraftingPage.SchematicForm,
-- ProfessionsRecipeSchematicFormMixin:Init(recipeInfo), EventRegistry "Professions.RecipeListOnEnter"),
-- C_TradeSkillUI.GetRecipeSchematic (TradeSkillUIDocumentation.lua). /scribe craftprices on|off

local FS = ForeverScribe
local U = FS.Util
local Try, Call, Clean, Fn = U.Try, U.Call, U.Clean, U.Fn
local T = FS.Tooltip

local K = {}
FS.Craft = K

K.BASE = 100000000 -- price file: p[BASE + recipeID] = "product,qty,cost,sells;reagent:n,...", p[BASE] = AH cut (bp)
K.DEFAULT_CUT = 0.05
local MAX_MATS = 12

local CL = T and T.COLORS or {}
local GOLD, LABEL, VALUE, DIM = CL.GOLD, CL.LABEL, CL.VALUE, CL.DIM
local GOOD, BAD = CL.GOOD or "ff4fd36b", CL.BAD or "ffff5e57"
local function color(hex, s) return "|c" .. hex .. s .. "|r" end

---------------------------------------------------------------------------
-- Data
---------------------------------------------------------------------------

local memo, memoP = {}, nil
local function Data()
	local P = T and T.Data and T.Data()
	if not P and T and T.loadError == nil then T.Load(); P = T.Data() end
	if P ~= memoP then memo, memoP = {}, P end
	return P
end

-- The AH's cut of a sale, as a fraction: what the companion found (your AH invoices or config), else 5%.
function K.Cut()
	local P = Data()
	local n = P and type(P.p) == "table" and tonumber(P.p[K.BASE])
	if n and n >= 0 and n < 5000 then return n / 10000 end
	return K.DEFAULT_CUT
end

local function parseMats(list)
	local mats = {}
	for id, n in tostring(list or ""):gmatch("(%d+):(%d+)") do
		if #mats < MAX_MATS then mats[#mats + 1] = { tonumber(id), tonumber(n) } end
	end
	return mats
end

-- {product, qty, cost, sells, mats = {{itemID, n}, ...}, pre = true} from the price file, or nil.
function K.FromFile(recipeID)
	local P = Data()
	if not P or type(P.p) ~= "table" or type(recipeID) ~= "number" or recipeID <= 0 then return nil end
	local r = memo[recipeID]
	if r == nil then
		r = false
		local s = P.p[K.BASE + recipeID]
		if type(s) == "string" and #s < 300 then
			local prod, qty, cost, sells, list = s:match("^(%d*),(%d+),(%d*),(%d*);([%d:,]*)$")
			if qty then
				r = { product = tonumber(prod), qty = math.max(1, tonumber(qty) or 1), cost = tonumber(cost),
					sells = tonumber(sells), mats = parseMats(list), pre = true }
			end
		end
		memo[recipeID] = r
	end
	return r or nil
end

-- The same from the client's recipe schematic (recipes learned since the companion last wrote the file).
function K.FromSchematic(recipeID)
	local s = Call("C_TradeSkillUI.GetRecipeSchematic", recipeID, false)
	if type(s) ~= "table" then return nil end
	local basic = Enum and Enum.CraftingReagentType and Enum.CraftingReagentType.Basic or 1
	local mats = {}
	local slots = type(s.reagentSlotSchematics) == "table" and s.reagentSlotSchematics or {}
	for i = 1, math.min(#slots, 20) do
		local slot = slots[i]
		if type(slot) == "table" then
			local ty, req = Clean(slot.reagentType), Clean(slot.required)
			local first = type(slot.reagents) == "table" and slot.reagents[1]
			local id, n = type(first) == "table" and Clean(first.itemID), Clean(slot.quantityRequired)
			-- only the materials every craft uses (not optional / finishing reagents)
			if id and (ty == nil or ty == basic) and req ~= false and #mats < MAX_MATS then
				mats[#mats + 1] = { id, math.max(1, tonumber(n) or 1) }
			end
		end
	end
	local prod = Clean(s.outputItemID)
	if #mats == 0 and not prod then return nil end
	return { product = tonumber(prod), qty = math.max(1, tonumber(Clean(s.quantityMin)) or 1), mats = mats }
end

function K.Recipe(recipeID)
	recipeID = tonumber(Clean(recipeID))
	if not recipeID then return nil end
	return K.FromFile(recipeID) or K.FromSchematic(recipeID)
end

-- Numbers for one craft. ctx.bop = the crafted item binds when picked up (can't be listed).
-- Returns { cost, sells, fee, profit, mats = { {id, n, unit, src}, ... }, missing = n } with nil for anything that
-- can't be calculated.
function K.Evaluate(rec, ctx)
	ctx = ctx or {}
	local out = { mats = {}, missing = 0, qty = rec.qty or 1 }
	local sum = 0
	for _, m in ipairs(rec.mats or {}) do
		local unit, src = T.Unit(m[1])
		out.mats[#out.mats + 1] = { m[1], m[2], unit, src }
		if unit then sum = sum + unit * m[2] else out.missing = out.missing + 1 end
	end
	if rec.pre then
		out.cost, out.sells = rec.cost, rec.sells
	else
		out.cost = (#out.mats > 0 and out.missing == 0) and sum or nil
		local row = rec.product and T.Row(rec.product)
		out.sells = row and row.median * out.qty or nil
	end
	if ctx.bop then out.sells = nil end
	if out.sells then
		out.cut = K.Cut()
		out.fee = math.floor(out.sells * out.cut + 0.5)
		if out.cost then out.profit = out.sells - out.fee - out.cost end
	end
	return out
end

local function Signed(c)
	if c < 0 then return color(BAD, "-" .. T.Money(-c)) end
	if c > 0 then return color(GOOD, "+" .. T.Money(c)) end
	return T.Money(0)
end

local function pctText(cut)
	local p = cut * 100
	return (p == math.floor(p) and tostring(math.floor(p)) or string.format("%.1f", p)) .. "%"
end

-- Lines in Tooltip.lua's shape. ctx: shift, now, bop, have(itemID) -> n, name(itemID) -> text, compact.
function K.Lines(rec, ctx)
	local P = Data()
	if not P or not rec then return nil end
	ctx = ctx or {}
	local e = K.Evaluate(rec, ctx)
	local out = {}
	local function add(l, r, lc, rc, big) out[#out + 1] = { l, r, lc or LABEL, rc or VALUE, big = big } end
	local label = type(P.label) == "string" and P.label ~= "" and P.label or "Auction House"
	local age = (ctx.now or 0) - (P.captured or 0)
	local ageText = T.Age(age)
	if age > 6 * 3600 then ageText = color(CL.WARN or "ffffc46b", ageText) end
	add("Auction House", label .. " · " .. ageText, GOLD, DIM)
	if e.cost then add("Cost to craft", T.Money(e.cost)) end
	if e.sells then add(e.qty > 1 and ("Sells for (makes " .. e.qty .. ")") or "Sells for", T.Money(e.sells)) end
	if e.profit then add("Profit", Signed(e.profit), nil, nil, true) end
	-- why a line is missing (never a number)
	if not e.sells then
		if ctx.bop then out[#out + 1] = { "Binds when picked up · can't be sold", nil, DIM }
		elseif rec.product then out[#out + 1] = { "Crafted item: no recent listings", nil, DIM } end
	end
	if not e.cost and e.missing > 0 then
		out[#out + 1] = { e.missing == 1 and "1 material has no price" or (e.missing .. " materials have no price"), nil, DIM }
	end
	if ctx.compact then return out end
	if not ctx.shift then
		if e.profit then out[#out + 1] = { "After the " .. pctText(e.cut) .. " AH cut · Hold Shift for materials", nil, DIM }
		else out[#out + 1] = { "Hold Shift for materials", nil, DIM } end
		return out
	end
	for _, m in ipairs(e.mats) do
		local id, need, unit, src = m[1], m[2], m[3], m[4]
		local have = ctx.have and tonumber(ctx.have(id)) or nil
		local nm = (ctx.name and ctx.name(id)) or ("item " .. id)
		local hv = have and color(have >= need and GOOD or BAD, have .. "/" .. need) or (need .. "x")
		add(nm .. "  " .. hv, unit and (T.Money(unit) .. " each · " .. src) or "—", nil, not unit and DIM or nil)
	end
	if e.fee then add("AH cut (" .. pctText(e.cut) .. ")", T.Money(e.fee)) end
	return out
end

---------------------------------------------------------------------------
-- Game side
---------------------------------------------------------------------------

function K.Enabled()
	local db = FS.db or ForeverScribeDB
	return not (db and db.settings and db.settings.craftprices == "off")
end

local function Have(id)
	local n = Clean((Call("C_Item.GetItemCount", id, true, false, true))) -- bags + bank + reagent bank
	if n == nil then n = Clean((Call("GetItemCount", id, true))) end
	return tonumber(n) or 0
end

local function Name(id)
	local n = Clean((Call("C_Item.GetItemNameByID", id)))
	if type(n) ~= "string" then n = Clean((Call("C_Item.GetItemInfo", id))) end
	return type(n) == "string" and n or nil
end

local function BindsOnPickup(id)
	if not id then return false end
	local bindType = select(14, Call("C_Item.GetItemInfo", id))
	return Clean(bindType) == 1 -- Enum.ItemBind.OnAcquire
end

local function Ctx(rec, extra)
	local ctx = { now = (Try(time)) or 0, shift = Clean((Call("IsShiftKeyDown"))) and true or false,
		bop = BindsOnPickup(rec and rec.product), have = Have, name = Name }
	for k, v in pairs(extra or {}) do ctx[k] = v end
	return ctx
end

local panel -- our own tooltip-styled panel (never a Blizzard frame)
K.current = nil -- recipeID of the selected recipe

local function Panel()
	if panel then return panel end
	if not CreateFrame then return nil end
	local ok, f = pcall(CreateFrame, "GameTooltip", "ForeverScribeCraftTip", UIParent, "GameTooltipTemplate")
	if ok and f then panel = f end
	return panel
end
function K.Panel() return panel end

function K.Hide()
	if panel then
		if T.RestoreFonts then T.RestoreFonts(panel) end
		Try(panel.Hide, panel)
	end
end

local function craftingShown()
	local pf = _G.ProfessionsFrame
	local page = pf and pf.CraftingPage
	return pf and Try(pf.IsShown, pf) and (not page or Try(page.IsShown, page)) and true or false
end

function K.Render()
	local rid = K.current
	if not rid or not K.Enabled() or not craftingShown() then return K.Hide() end
	local rec = K.Recipe(rid)
	local lines = rec and K.Lines(rec, Ctx(rec))
	if not lines then return K.Hide() end
	local tip = Panel()
	if not tip then return end
	local pf = _G.ProfessionsFrame
	if T.RestoreFonts then T.RestoreFonts(tip) end
	Try(tip.SetOwner, tip, pf, "ANCHOR_NONE")
	Try(tip.ClearAllPoints, tip)
	Try(tip.SetPoint, tip, "BOTTOMLEFT", pf, "BOTTOMRIGHT", 2, 0)
	Try(tip.ClearLines, tip)
	local title = rec.product and Name(rec.product)
	if title then Try(tip.AddLine, tip, title, 1, 1, 1) end
	T.Draw(tip, lines)
	Try(tip.Show, tip)
end

-- SchematicForm:Init(recipeInfo) ran: a recipe was selected (or the form was reset).
function K.OnInit(recipeInfo)
	local rid = type(recipeInfo) == "table" and tonumber(Clean(recipeInfo.recipeID)) or nil
	K.current = rid
	K.Render()
end

-- Hovering a recipe in the list: a compact profit line on the game tooltip (the row's OnLeave hides it).
function K.OnListEnter(row, data)
	if not K.Enabled() then return end
	local info = type(data) == "table" and data.recipeInfo
	local rid = type(info) == "table" and tonumber(Clean(info.recipeID))
	local rec = rid and K.Recipe(rid)
	local lines = rec and K.Lines(rec, Ctx(rec, { compact = true }))
	if not lines or #lines < 2 then return end
	local tt = _G.GameTooltip
	if not tt then return end
	local owner = Try(tt.GetOwner, tt)
	local shown = Try(tt.IsShown, tt)
	if not (shown and owner and type(row) == "table" and owner == row.Label) then
		Try(tt.SetOwner, tt, row, "ANCHOR_RIGHT")
		local nm = Clean(info.name)
		if type(nm) == "string" then Try(tt.AddLine, tt, nm, 1, 1, 1) end
	end
	T.Draw(tt, lines)
	Try(tt.Show, tt)
end

-- No hooks into Blizzard_Professions at all. Forever's profession UI reads secret values that error when the
-- execution path is tainted, and an insecure post-hook / EventRegistry callback taints that path (0.8.0 left the
-- recipe list and schematic empty). Instead our own frame watches the window from outside, read-only, and
-- only while it is open.
K.hooked = false
local watcher, lastRid, acc = nil, nil, 0
local function Selected()
	local pf = _G.ProfessionsFrame
	local form = pf and pf.CraftingPage and pf.CraftingPage.SchematicForm
	if not (form and type(form.GetRecipeInfo) == "function") then return nil end
	local ok, info = pcall(form.GetRecipeInfo, form)
	if not ok or type(info) ~= "table" then return nil end
	local rid = Clean(info.recipeID)
	return tonumber(rid)
end
function K.Tick(elapsed)
	acc = acc + (elapsed or 0)
	if acc < 0.25 then return end
	acc = 0
	if not K.Enabled() or not craftingShown() then
		lastRid = nil
		return K.Hide()
	end
	local rid = Selected()
	if rid ~= lastRid then
		lastRid = rid
		K.current = rid
		pcall(K.Render)
	end
end
function K.Hook()
	if K.hooked or not CreateFrame then return K.hooked end
	watcher = CreateFrame("Frame")
	watcher:SetScript("OnUpdate", function(_, e)
		local pf = _G.ProfessionsFrame
		if not (pf and pf:IsShown()) then
			if panel and panel:IsShown() then pcall(K.Hide) end
			lastRid = nil
			return
		end
		pcall(K.Tick, e)
	end)
	K.hooked = true
	return true
end

function K.Command(arg)
	local db = FS.db or ForeverScribeDB
	arg = tostring(arg or ""):lower()
	if db and db.settings and (arg == "on" or arg == "off") then db.settings.craftprices = arg end
	if K.Enabled() then pcall(K.Render) else K.Hide() end
	FS.Print("craft cost & profit in the profession window " .. (K.Enabled() and "on" or "off") .. ". /scribe craftprices on|off")
	if K.Enabled() and not (T and T.Data and T.Data()) then
		FS.Print("no prices loaded yet: your agent writes them with `foreverscribe prices write`; then /reload.")
	end
end

if CreateFrame then
	local f = CreateFrame("Frame")
	f:RegisterEvent("ADDON_LOADED")
	f:RegisterEvent("PLAYER_LOGIN")
	f:RegisterEvent("TRADE_SKILL_SHOW")
	f:RegisterEvent("MODIFIER_STATE_CHANGED")
	f:RegisterEvent("BAG_UPDATE_DELAYED")
	f:SetScript("OnEvent", function(_, ev, a1)
		if ev == "ADDON_LOADED" then
			if a1 == "Blizzard_Professions" then pcall(K.Hook) end
		elseif ev == "PLAYER_LOGIN" or ev == "TRADE_SKILL_SHOW" then
			pcall(K.Hook)
		elseif panel and Try(panel.IsShown, panel) then
			if ev == "BAG_UPDATE_DELAYED" or a1 == "LSHIFT" or a1 == "RSHIFT" then pcall(K.Render) end
		end
	end)
end

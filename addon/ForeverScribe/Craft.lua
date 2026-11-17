-- ForeverScribe craft cost & profit in the profession window (0.8.2). Read-only. Three lines written into the recipe
-- detail pane, under Blizzard's "Reagents:" list, in Blizzard's own fonts:
--   Cost to craft  materials at their typical AH price, or the vendor's price where a vendor sells them cheaper
--   Sells for      the crafted item's typical AH price x how many one craft makes
--   Profit         sells for - the AH cut - cost (green / red), "after 5% AH cut" in small grey beside it
-- A line that can't be calculated is left out, never guessed (bind-on-pickup result, material with no price).
-- When the crafting page is shown but no profession loaded (the profession spell didn't cast: dead, ghost, combat,
-- interrupted) a short message sits in the middle of the empty window instead.
-- Never hooks Blizzard code, never writes to or calls anything on a Blizzard frame except getters (IsShown,
-- GetRecipeInfo, GetBottom, GetFrameStrata, GetFrameLevel): our own frames, parented to UIParent, are anchored to
-- the window and drawn just above it. It never crafts, buys or sells, never touches the Create buttons, never casts.
-- Prices come from the companion's price file (ForeverScribe_Prices): for the recipes your characters know, product,
-- count, cost and sells-for are precomputed there (p[100000000 + recipeID]), so selecting a recipe is a table lookup;
-- other recipes are read from the client's own recipe schematic.
-- Frame and API names: Forever UI source, Blizzard_Professions (ProfessionsFrame.CraftingPage.SchematicForm and its
-- Reagents / OptionalReagents containers, ProfessionsRecipeSchematicFormMixin:GetRecipeInfo()),
-- C_TradeSkillUI.GetRecipeSchematic / GetChildProfessionInfo / GetBaseProfessionInfo (TradeSkillUIDocumentation.lua).
-- /scribe craftprices on|off

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
-- Returns { cost, sells, fee, cut, profit, qty, missing = n } with nil for anything that can't be calculated.
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

local function pctText(cut)
	local p = cut * 100
	return (p == math.floor(p) and tostring(math.floor(p)) or string.format("%.1f", p)) .. "%"
end

local function Signed(c)
	if c < 0 then return color(BAD, "-" .. T.Money(-c)) end
	if c > 0 then return color(GOOD, "+" .. T.Money(c)) end
	return T.Money(0)
end

-- The lines for the detail pane: { {label, value, note}, ... }, only the ones that can be calculated (maybe none).
-- ctx.bop = the crafted item binds when picked up.
function K.Rows(rec, ctx)
	if not Data() or not rec then return nil end
	local e = K.Evaluate(rec, ctx)
	local out = {}
	if e.cost then out[#out + 1] = { "Cost to craft:", T.Money(e.cost) } end
	if e.sells then
		out[#out + 1] = { e.qty > 1 and ("Sells for (makes " .. e.qty .. "):") or "Sells for:", T.Money(e.sells) }
	end
	if e.profit then out[#out + 1] = { "Profit:", Signed(e.profit), "after " .. pctText(e.cut) .. " AH cut" } end
	return out
end

---------------------------------------------------------------------------
-- Game side
---------------------------------------------------------------------------

function K.Enabled()
	local db = FS.db or ForeverScribeDB
	return not (db and db.settings and db.settings.craftprices == "off")
end

local function BindsOnPickup(id)
	if not id then return false end
	local bindType = select(14, Call("C_Item.GetItemInfo", id))
	return Clean(bindType) == 1 -- Enum.ItemBind.OnAcquire
end

-- Blizzard frames are only ever read: these getters, nothing else (tests/lua/test_addon.lua "do-not-touch").
local function get(f, m, ...)
	local fn = type(f) == "table" and f[m]
	if type(fn) ~= "function" then return nil end
	local ok, a = pcall(fn, f, ...)
	if not ok then return nil end
	return Clean(a)
end
local function shown(f) return get(f, "IsShown") and true or false end

local function Window()
	local pf = _G.ProfessionsFrame
	if type(pf) ~= "table" or not shown(pf) then return nil end
	local page = type(pf.CraftingPage) == "table" and pf.CraftingPage or nil
	local form = page and type(page.SchematicForm) == "table" and page.SchematicForm or nil
	return pf, page, form
end

local function Selected(form)
	if not form or not shown(form) or type(form.GetRecipeInfo) ~= "function" then return nil end
	local ok, info = pcall(form.GetRecipeInfo, form)
	if not ok or type(info) ~= "table" then return nil end
	return tonumber(Clean(info.recipeID))
end

-- Did a profession actually open? Blizzard's own test (ProfessionsMixin:Refresh): professionID ~= 0.
K.tradeOpen = false -- TRADE_SKILL_SHOW .. TRADE_SKILL_CLOSE
local function ProfessionLoaded()
	if K.tradeOpen then return true end
	for _, info in ipairs({ Call("C_TradeSkillUI.GetChildProfessionInfo") or false,
		Call("C_TradeSkillUI.GetBaseProfessionInfo") or false }) do
		local id = type(info) == "table" and tonumber(Clean(info.professionID))
		if id and id > 0 then return true end
	end
	return false
end

-- Our frames are never parented to Blizzard's. 0.8.2/0.8.3 used the window's own strata at its level+40, but the
-- recipe pane's art (and the window raising itself when clicked) sits higher, so the numbers were drawn but hidden
-- behind it. Draw one strata above the window instead (MEDIUM -> HIGH); the frames only exist while it is open.
local STRATA_UP = { BACKGROUND = "LOW", LOW = "MEDIUM", MEDIUM = "HIGH", HIGH = "DIALOG", DIALOG = "FULLSCREEN",
	FULLSCREEN = "FULLSCREEN_DIALOG", FULLSCREEN_DIALOG = "FULLSCREEN_DIALOG" }
local function Layer(f, pf)
	local strata = get(pf, "GetFrameStrata")
	strata = type(strata) == "string" and STRATA_UP[strata] or "HIGH"
	if f.strata ~= strata then f.strata = strata; Try(f.SetFrameStrata, f, strata) end
	if f.level ~= 50 then f.level = 50; Try(f.SetFrameLevel, f, 50) end
end

local function FontString(f, font)
	local fs = Try(f.CreateFontString, f, nil, "OVERLAY", font)
	return fs
end

---------------------------------------------------------------------------
-- The three lines in the detail pane
---------------------------------------------------------------------------

local ROW_H, GAP, LABEL_GAP, NOTE_GAP = 15, 14, 8, 6
local TRACK_ROW = 40 -- Track Recipe checkbox: BOTTOMRIGHT of the form, y 11, 26 high (Camelot OverrideArt)
local box, boxFailed -- ForeverScribeCraftNumbers

local function Box()
	if box then return box end
	if boxFailed or not CreateFrame then return nil end
	boxFailed = true
	local ok, f = pcall(CreateFrame, "Frame", "ForeverScribeCraftNumbers", UIParent)
	if not ok or not f then return nil end
	f.rows = {}
	for i = 1, 3 do
		local r = { label = FontString(f, "GameFontNormalSmall"), value = FontString(f, "GameFontHighlightSmall"),
			note = FontString(f, "GameFontDisableSmall") }
		if not (r.label and r.value and r.note) then return nil end
		f.rows[i] = r
	end
	Try(f.SetSize, f, 260, ROW_H * 3)
	Try(f.Hide, f)
	box, boxFailed = f, nil
	return f
end
function K.Box() return box end

local function setText(fs, s)
	if not fs then return end
	Try(fs.SetText, fs, s or "")
	if s and s ~= "" then Try(fs.Show, fs) else Try(fs.Hide, fs) end
end

local function Fill(f, rows)
	local labelW = 0
	for i = 1, 3 do
		local r, l = f.rows[i], rows[i]
		setText(r.label, l and l[1]); setText(r.value, l and l[2]); setText(r.note, l and l[3])
		r.hasNote = l and l[3] and true or false
		if l then labelW = math.max(labelW, tonumber(Try(r.label.GetStringWidth, r.label)) or 0) end
	end
	local x = math.floor(labelW + LABEL_GAP + 0.5)
	for i, r in ipairs(f.rows) do
		local y = -(i - 1) * ROW_H
		Try(r.label.ClearAllPoints, r.label); Try(r.label.SetPoint, r.label, "TOPLEFT", f, "TOPLEFT", 0, y)
		Try(r.value.ClearAllPoints, r.value); Try(r.value.SetPoint, r.value, "TOPLEFT", f, "TOPLEFT", x, y)
		Try(r.note.ClearAllPoints, r.note); Try(r.note.SetPoint, r.note, "LEFT", r.value, "RIGHT", NOTE_GAP, 0)
	end
	f.n = #rows
	Try(f.SetHeight, f, math.max(1, #rows) * ROW_H)
end

-- Under the last reagent container; when that leaves no room above the Track Recipe row, in the bottom-left corner
-- (left of Track Recipe) without the grey note; when that would cover reagents too, not at all.
local function Place(f, form)
	-- Optional reagents only count when the container actually has slots (Forever keeps an empty one shown).
	local opt = form.OptionalReagents
	local ot, ob = tonumber(get(opt, "GetTop")), tonumber(get(opt, "GetBottom"))
	local optUsed = shown(opt) and ot and ob and (ot - ob) > 4 or false
	local below = (optUsed and opt) or (shown(form.Reagents) and form.Reagents) or nil
	local h = (f.n or 3) * ROW_H
	local fb = tonumber(get(form, "GetBottom"))
	local ab = below and tonumber(get(below, "GetBottom"))
	local mode = "below"
	if not below then mode = "corner"
	elseif fb and ab and ab - GAP - h < fb + TRACK_ROW then mode = "corner" end
	f.mode, f.dbg = mode, { below = below and (below == opt and "optional" or "reagents") or "none", fb = fb, ab = ab, h = h }
	local key = mode .. ":" .. tostring(below)
	if f.placed ~= key then
		f.placed = key
		Try(f.ClearAllPoints, f)
		if mode == "below" then Try(f.SetPoint, f, "TOPLEFT", below, "BOTTOMLEFT", 0, -GAP)
		else Try(f.SetPoint, f, "BOTTOMLEFT", form, "BOTTOMLEFT", 28, 12) end
	end
	for _, r in ipairs(f.rows) do
		if r.note then
			if mode == "below" and r.hasNote then Try(r.note.Show, r.note) else Try(r.note.Hide, r.note) end
		end
	end
	return true
end

function K.HideNumbers()
	if box then box.rid = nil; Try(box.Hide, box) end
end

-- Draw (or refresh the place of) the numbers for recipeID in the window's form.
function K.ShowNumbers(rid, pf, form)
	local f = Box()
	if not f then return end
	if f.rid ~= rid then
		local rec = K.Recipe(rid)
		local rows = rec and K.Rows(rec, { bop = BindsOnPickup(rec.product) })
		if not rows or #rows == 0 then f.rid = rid; f.empty = true; return Try(f.Hide, f) end
		f.rid, f.empty = rid, false
		Fill(f, rows)
	end
	if f.empty then return end
	Layer(f, pf)
	if Place(f, form) then Try(f.Show, f) else Try(f.Hide, f) end
end

---------------------------------------------------------------------------
-- The empty-window message
---------------------------------------------------------------------------

K.GRACE = 1.5 -- seconds the crafting page may sit empty while a profession spell is still casting
local note, noteFailed -- ForeverScribeCraftNotice
local function Notice()
	if note then return note end
	if noteFailed or not CreateFrame then return nil end
	noteFailed = true
	local ok, f = pcall(CreateFrame, "Frame", "ForeverScribeCraftNotice", UIParent)
	if not ok or not f then return nil end
	f.title = FontString(f, "GameFontNormalLarge")
	f.body = FontString(f, "GameFontHighlight")
	if f.title then Try(f.title.SetPoint, f.title, "BOTTOM", f, "CENTER", 0, 4) end
	if f.body then Try(f.body.SetPoint, f.body, "TOP", f, "CENTER", 0, -4) end
	Try(f.SetSize, f, 420, 60)
	Try(f.Hide, f)
	note, noteFailed = f, nil
	return f
end
function K.Notice() return note end

K.TEXT = {
	dead = { "You can't use professions while dead.", "Resurrect, then open it again." },
	alive = { "You're alive again.", "Close this window and open your profession again." },
	failed = { "This profession didn't open.", "Try again." },
}

function K.HideNotice()
	if note then note.kind = nil; Try(note.Hide, note) end
end

function K.ShowNotice(kind, pf, page)
	local f = Notice()
	if not f then return end
	if f.kind ~= kind then
		f.kind = kind
		local t = K.TEXT[kind] or K.TEXT.failed
		setText(f.title, t[1]); setText(f.body, t[2])
	end
	if f.anchor ~= page then
		f.anchor = page
		Try(f.ClearAllPoints, f); Try(f.SetPoint, f, "CENTER", page or pf, "CENTER", 0, 0)
	end
	Layer(f, pf)
	Try(f.Show, f)
end

---------------------------------------------------------------------------
-- Watcher: our own frame polls the window, read-only, only while it is open
---------------------------------------------------------------------------

-- No hooks into Blizzard_Professions at all, as a precaution: nothing of ours runs inside Blizzard's profession code,
-- so nothing of ours can change how it behaves.
K.hooked = false
local watcher, acc = nil, 0
K.emptyFor = 0 -- seconds the crafting page has been shown with no profession loaded
K.wasDead = false

function K.HideAll()
	K.HideNumbers(); K.HideNotice()
	K.emptyFor, K.wasDead = 0, false
end

function K.Update(dt)
	local pf, page, form = Window()
	if not pf or not K.Enabled() or (page and not shown(page)) then return K.HideAll() end
	-- Loaded first: the form keeps its last recipe after the window closes (Init only on a new recipe), so a recipe
	-- in the form doesn't mean this open worked.
	if not page or ProfessionLoaded() then
		K.HideNotice(); K.emptyFor, K.wasDead = 0, false
		local rid = Selected(form)
		if rid then return K.ShowNumbers(rid, pf, form) end
		return K.HideNumbers()
	end
	K.HideNumbers()
	K.emptyFor = K.emptyFor + (dt or 0)
	if K.emptyFor < K.GRACE then return end
	local dead = Clean((Call("UnitIsDeadOrGhost", "player"))) and true or false
	local kind = "failed"
	if dead then kind = "dead"; K.wasDead = true
	elseif K.wasDead then kind = "alive" end
	K.ShowNotice(kind, pf, page)
end

function K.Tick(elapsed)
	acc = acc + (elapsed or 0)
	if acc < 0.25 then return end
	local dt = acc
	acc = 0
	K.Update(dt)
end

function K.Hook()
	if K.hooked or not CreateFrame then return K.hooked end
	watcher = CreateFrame("Frame")
	watcher:SetScript("OnUpdate", function(_, e)
		local pf = _G.ProfessionsFrame
		if not (type(pf) == "table" and shown(pf)) then
			if (box and box.rid) or (note and note.kind) then pcall(K.HideAll) end
			acc = 0
			return
		end
		pcall(K.Tick, e)
	end)
	K.hooked = true
	return true
end

function K.Debug()
	local P = FS.Print or print
	local pf, page, form = Window()
	P(("craftdebug: window=%s page=%s form=%s formShown=%s loaded=%s tradeOpen=%s enabled=%s"):format(
		tostring(pf ~= nil), tostring(page and shown(page)), tostring(form ~= nil), tostring(form and shown(form)),
		tostring(ProfessionLoaded()), tostring(K.tradeOpen), tostring(K.Enabled())))
	local rid = form and Selected(form)
	local rec = rid and K.Recipe(rid)
	local rows = rec and K.Rows(rec, { bop = BindsOnPickup(rec.product) })
	P(("craftdebug: recipe=%s inPriceFile=%s rows=%s prices=%s"):format(tostring(rid), tostring(rec ~= nil),
		tostring(rows and #rows), tostring(Data() ~= nil)))
	local b = box
	if b then
		local d = b.dbg or {}
		P(("craftdebug: box shown=%s mode=%s anchor=%s formBottom=%s anchorBottom=%s h=%s top=%s left=%s"):format(
			tostring(shown(b)), tostring(b.mode), tostring(d.below), tostring(d.fb), tostring(d.ab), tostring(d.h),
			tostring(get(b, "GetTop")), tostring(get(b, "GetLeft"))))
		local r1 = b.rows and b.rows[1]
		P(("craftdebug: strata=%s level=%s window=%s/%s alpha=%s text1=%s"):format(tostring(get(b, "GetFrameStrata")),
			tostring(get(b, "GetFrameLevel")), tostring(get(pf, "GetFrameStrata")), tostring(get(pf, "GetFrameLevel")),
			tostring(get(b, "GetEffectiveAlpha")), tostring(r1 and get(r1.label, "GetText"))))
	else P("craftdebug: no numbers frame yet") end
	P("craftdebug: errors " .. tostring(FS.errors or 0) .. " last: " .. tostring(FS.lastError))
end

function K.Command(arg)
	local db = FS.db or ForeverScribeDB
	if tostring(arg or ""):lower() == "debug" then return K.Debug() end
	arg = tostring(arg or ""):lower()
	if db and db.settings and (arg == "on" or arg == "off") then db.settings.craftprices = arg end
	if K.Enabled() then
		if box then box.rid = nil end
		pcall(K.Update, 0)
	else K.HideAll() end
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
	f:RegisterEvent("TRADE_SKILL_CLOSE")
	f:SetScript("OnEvent", function(_, ev, a1)
		if ev == "ADDON_LOADED" then
			if a1 == "Blizzard_Professions" then pcall(K.Hook) end
		elseif ev == "TRADE_SKILL_CLOSE" then
			K.tradeOpen = false
		else -- PLAYER_LOGIN, TRADE_SKILL_SHOW
			if ev == "TRADE_SKILL_SHOW" then K.tradeOpen = true end
			pcall(K.Hook)
		end
	end)
end

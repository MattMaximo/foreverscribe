-- ForeverScribe AH price tooltip. Read-only: adds lines to item tooltips from a price file the companion wrote into
-- Interface/AddOns/ForeverScribe_Prices/Prices.lua (data only; loaded by the game at login and on /reload).
-- No AH queries, no network, no protected calls. Every game call is pcall'd; secret values are dropped.
--   default : "Auction House" header (market + data age), Typical price, Your N are worth, "Hold Shift for details"
--   Shift   : + cheapest listing, listed now, 7-day / 30-day typical (trend), other faction, sell-or-vendor, used in
--   patterns: Typical price, Crafted item sells for, Materials cost
--   unsellable / no data: "—" plus the reason
-- /scribe tooltip on|off|shift   (shift = only while Shift is held)

local FS = ForeverScribe
local U = FS.Util
local Try, Call, Clean, Fn = U.Try, U.Call, U.Clean, U.Fn

local T = {}
FS.Tooltip = T

T.FORMAT = 1
T.MAX_ITEMS = 20000 -- a bigger file is refused (the companion caps well below this)
T.MAX_PATTERNS = 5000
T.MEDIA = "Interface\\AddOns\\ForeverScribe\\Media\\"

local GOLD = { 0.83, 0.68, 0.32 } -- header (mockup #c8a24a, a touch brighter on the dark tooltip)
local LABEL = { 0.82, 0.82, 0.82 }
local VALUE = { 1, 1, 1 }
local DIM = { 0.55, 0.55, 0.55 }
local GOOD, BAD, WARN = "ff4fd36b", "ffff5e57", "ffffc46b"

local function color(hex, s) return "|c" .. hex .. s .. "|r" end
local function up() return "|T" .. T.MEDIA .. "up:0|t" end
local function down() return "|T" .. T.MEDIA .. "down:0|t" end

---------------------------------------------------------------------------
-- Price file
---------------------------------------------------------------------------

local P -- the validated price file (or nil)
local rows, recipes = {}, {} -- memo: itemID -> parsed row | false
T.loadError = nil

local function count(t, cap)
	local n = 0
	for _ in pairs(t) do
		n = n + 1
		if n > cap then return n end
	end
	return n
end

-- Validates ForeverScribe_PriceData. Returns true when usable; T.loadError says why not.
function T.Load(data)
	P, rows, recipes, T.loadError = nil, {}, {}, nil
	data = data == nil and ForeverScribe_PriceData or data
	if data == nil then T.loadError = "no price file"; return false end
	if type(data) ~= "table" or type(data.d) ~= "table" then T.loadError = "bad price file"; return false end
	if data.v ~= T.FORMAT then T.loadError = "price file format " .. tostring(data.v) .. " (update ForeverScribe)"; return false end
	if type(data.captured) ~= "number" then T.loadError = "price file without a scan time"; return false end
	if count(data.d, T.MAX_ITEMS) > T.MAX_ITEMS then T.loadError = "price file too big (more than " .. T.MAX_ITEMS .. " items)"; return false end
	if type(data.p) == "table" and count(data.p, T.MAX_PATTERNS) > T.MAX_PATTERNS then data.p = nil end
	P = data
	return true
end

function T.Data() return P end

local function nums(s)
	local out, i, pos = {}, 0, 1
	while true do
		i = i + 1
		local c = s:find(",", pos, true)
		out[i] = tonumber(s:sub(pos, (c or 0) - 1))
		if not c then break end
		pos = c + 1
	end
	return out
end

-- {median, min, qty, d7, d30, other} or nil.
function T.Row(itemID)
	if not P or type(itemID) ~= "number" then return nil end
	local r = rows[itemID]
	if r == nil then
		local s = P.d[itemID]
		if type(s) == "string" and #s < 120 then
			local n = nums(s)
			r = { median = n[1], min = n[2], qty = n[3], d7 = n[4], d30 = n[5], other = n[6] }
			if not r.median then r = false end
		else
			r = false
		end
		rows[itemID] = r
	end
	return r or nil
end

-- {creates = itemID, mats = { {itemID, n}, ... }} for a recipe item, or nil.
function T.Recipe(itemID)
	if not P or type(P.p) ~= "table" or type(itemID) ~= "number" then return nil end
	local r = recipes[itemID]
	if r == nil then
		r = false
		local s = P.p[itemID]
		if type(s) == "string" and #s < 400 then
			local created, list = s:match("^(%d+);([%d:,]*)$")
			if created then
				r = { creates = tonumber(created), mats = {} }
				for id, n in list:gmatch("(%d+):(%d+)") do r.mats[#r.mats + 1] = { tonumber(id), tonumber(n) } end
			end
		end
		recipes[itemID] = r
	end
	return r or nil
end

---------------------------------------------------------------------------
-- Formatting
---------------------------------------------------------------------------

function T.Money(c)
	c = math.floor(tonumber(c) or 0)
	local g = Fn("GetMoneyString")
	if g then
		local s = Try(g, c, true)
		if type(s) == "string" and s ~= "" then return s end
	end
	g = Fn("GetCoinTextureString")
	if g then
		local s = Try(g, c)
		if type(s) == "string" and s ~= "" then return s end
	end
	local gold, silver, copper = math.floor(c / 10000), math.floor(c / 100) % 100, c % 100
	local out = {}
	if gold > 0 then out[#out + 1] = gold .. "g" end
	if silver > 0 then out[#out + 1] = silver .. "s" end
	if copper > 0 or #out == 0 then out[#out + 1] = copper .. "c" end
	return table.concat(out, " ")
end

local function Number(n)
	local s = tostring(math.floor(n or 0))
	local f = Fn("BreakUpLargeNumbers")
	if f then local r = Try(f, n); if type(r) == "string" then return r end end
	return s
end

function T.Age(sec)
	sec = math.max(0, math.floor(sec or 0))
	if sec < 60 then return "just now" end
	if sec < 3600 then return math.floor(sec / 60) .. "m ago" end
	if sec < 48 * 3600 then return math.floor(sec / 3600) .. "h ago" end
	return math.floor(sec / 86400) .. "d ago"
end

local function pct(a, b) return (a - b) / b * 100 end

local function Trend(now, then30)
	if not now or not then30 or then30 <= 0 then return "" end
	local p = pct(now, then30)
	local r = math.floor(math.abs(p) + 0.5)
	if r < 1 then return "  " .. color("ff9a9a9a", "±0%") end
	if p > 0 then return "  " .. color(GOOD, up() .. " " .. r .. "%") end
	return "  " .. color(BAD, down() .. " " .. r .. "%")
end

function T.Verdict(median, vendor)
	if not median then return nil end
	if not vendor or vendor <= 0 then return color(GOOD, "AH · vendors won't buy it") end
	local p = math.floor(pct(median, vendor) + 0.5)
	if p >= 5 then return color(GOOD, "AH +" .. p .. "% vs vendor") end
	if p <= -5 then return color(BAD, "Vendor it · AH " .. p .. "%") end
	return color(WARN, "About the same")
end

---------------------------------------------------------------------------
-- What the character knows: recipes that use an item (from the last profession window scan)
---------------------------------------------------------------------------

local usedIndex, usedSig = nil, nil

local function charRecipes()
	local db = FS.db or ForeverScribeDB
	local c = db and db.chars and FS.charKey and db.chars[FS.charKey]
	return c and c.recipes
end

function T.UsedIn(itemID)
	local profs = charRecipes()
	if type(profs) ~= "table" then return nil end
	local sig = {}
	for name, p in pairs(profs) do
		if type(p) == "table" then sig[#sig + 1] = tostring(name) .. (p.count or 0) .. ":" .. (p.scannedAt or 0) end
	end
	table.sort(sig)
	sig = table.concat(sig, "|")
	if sig ~= usedSig then
		usedIndex, usedSig = {}, sig
		for _, p in pairs(profs) do
			for _, rec in pairs(type(p) == "table" and type(p.recipes) == "table" and p.recipes or {}) do
				if type(rec) == "table" and type(rec.reagents) == "table" and rec.name then
					for _, r in ipairs(rec.reagents) do
						if type(r) == "table" and r.itemID then
							local l = usedIndex[r.itemID] or {}
							usedIndex[r.itemID] = l
							l[#l + 1] = { name = rec.name, qty = r.qty or 1 }
						end
					end
				end
			end
		end
		for _, l in pairs(usedIndex) do table.sort(l, function(a, b) return a.name < b.name end) end
	end
	local l = usedIndex[itemID]
	if not l or #l == 0 then return nil end
	local parts = {}
	for i = 1, math.min(2, #l) do parts[i] = l[i].name .. " (" .. l[i].qty .. ")" end
	local s = table.concat(parts, " · ")
	if #l > 2 then s = s .. " · …" end
	return s
end

---------------------------------------------------------------------------
-- The lines. Pure: everything the game knows comes in through `ctx`, so tests can call it directly.
--   ctx = { shift = bool, count = n, vendor = copper, unsellable = "reason", now = epoch, usedIn = "text" }
-- Returns { {left, right, lc, rc, big = bool}, ... } or nil when there is nothing to show.
---------------------------------------------------------------------------

function T.Lines(itemID, ctx)
	if not P or type(itemID) ~= "number" then return nil end
	ctx = ctx or {}
	local out = {}
	local function add(l, r, lc, rc, big) out[#out + 1] = { l, r, lc or LABEL, rc or VALUE, big = big } end
	local label = type(P.label) == "string" and P.label ~= "" and P.label or "Auction House"
	local age = (ctx.now or 0) - P.captured
	local ageText = T.Age(age)
	if age > 6 * 3600 then ageText = color(WARN, ageText) end
	if ctx.unsellable then
		add("Auction House", label, GOLD, DIM)
		add("Typical price", "—", nil, DIM, true)
		out[#out + 1] = { ctx.unsellable, nil, DIM }
		return out
	end
	add("Auction House", label .. " · " .. ageText, GOLD, DIM)
	local row = T.Row(itemID)
	if not row then
		add("Typical price", "—", nil, DIM, true)
		out[#out + 1] = { "No recent listings", nil, DIM }
		return out
	end
	local shift = ctx.shift
	local other = (type(P.other) == "string" and P.other ~= "" and P.other or "Other faction") .. " side"
	add("Typical price", T.Money(row.median), nil, nil, true)
	local recipe = T.Recipe(itemID)
	if recipe then
		local crafted = T.Row(recipe.creates)
		add("Crafted item sells for", crafted and T.Money(crafted.median) or "—", nil, not crafted and DIM or nil)
		local sum, missing = 0, 0
		for _, m in ipairs(recipe.mats) do
			local r = T.Row(m[1])
			if r then sum = sum + r.median * m[2] else missing = missing + 1 end
		end
		if #recipe.mats > 0 then
			local txt = sum > 0 and T.Money(sum) or "—"
			if missing > 0 and sum > 0 then txt = txt .. color("ff9a9a9a", " + " .. missing .. " not on AH") end
			add("Materials cost", txt, nil, sum > 0 and VALUE or DIM)
		end
		if shift then
			if row.min then add("Cheapest listing", T.Money(row.min)) end
			if row.qty then add("Listed right now", Number(row.qty)) end
			if row.d7 then add("7-day typical", T.Money(row.d7)) end
			if row.d30 then add("30-day typical", T.Money(row.d30) .. Trend(row.median, row.d30)) end
			if row.other then add(other, T.Money(row.other)) end
		else
			out[#out + 1] = { "Hold Shift for trend & supply", nil, DIM }
		end
		return out
	end
	local n = tonumber(ctx.count) or 0
	if n > 0 then add(n == 1 and "Yours is worth" or ("Your " .. n .. " are worth"), T.Money(row.median * n)) end
	if not shift then
		out[#out + 1] = { "Hold Shift for details", nil, DIM }
		return out
	end
	if row.min then add("Cheapest listing", T.Money(row.min)) end
	if row.qty then add("Listed right now", Number(row.qty)) end
	if row.d7 then add("7-day typical", T.Money(row.d7)) end
	if row.d30 then add("30-day typical", T.Money(row.d30) .. Trend(row.median, row.d30)) end
	if row.other then add(other, T.Money(row.other)) end
	local v = T.Verdict(row.median, ctx.vendor)
	if v then add("Sell here or vendor?", v) end
	if ctx.usedIn then add("Used in", ctx.usedIn) end
	return out
end

---------------------------------------------------------------------------
-- Game side: what the hovered item is, and drawing
---------------------------------------------------------------------------

-- Enum.TooltipDataItemBinding values (Forever UI source, TooltipInfoSharedDocumentation.lua)
local BOUND = { [0] = "Quest item", [1] = "Account-bound", [2] = "Account-bound", [3] = "Soulbound",
	[4] = "Account-bound", [5] = "Account-bound", [6] = "Binds when picked up", [9] = "Account-bound", [10] = "Account-bound" }
local BOUND_TEXT = { ITEM_SOULBOUND = "Soulbound", ITEM_BIND_ON_PICKUP = "Binds when picked up", ITEM_BIND_QUEST = "Quest item",
	ITEM_ACCOUNTBOUND = "Account-bound", ITEM_BNETACCOUNTBOUND = "Account-bound", ITEM_BIND_TO_ACCOUNT = "Account-bound",
	ITEM_BIND_TO_BNETACCOUNT = "Account-bound", ITEM_CONJURED = "Conjured" }

function T.Unsellable(data, itemID)
	local lineType = Enum and Enum.TooltipDataLineType and Enum.TooltipDataLineType.ItemBinding or 20
	local lines = type(data) == "table" and Clean(data.type) == 0 and data.lines
	if type(lines) == "table" then
		for i = 1, math.min(#lines, 40) do
			local l = lines[i]
			if type(l) == "table" then
				local ty = Clean(l.type)
				local b = Clean(l.bonding)
				if ty == lineType and b ~= nil and BOUND[b] then return BOUND[b] .. " · can't be listed" end
				local txt = Clean(l.leftText)
				if txt then
					for g, why in pairs(BOUND_TEXT) do
						local s = _G[g]
						if type(s) == "string" and s ~= "" and txt == s then return why .. " · can't be listed" end
					end
				end
			end
		end
	end
	local _, _, _, _, _, _, _, _, _, _, _, classID, _, bindType = Call("C_Item.GetItemInfo", itemID)
	if Clean(bindType) == 4 or Clean(classID) == 12 then return "Quest item · can't be listed" end
	return nil
end

local function ItemCount(itemID)
	local n = Clean((Call("C_Item.GetItemCount", itemID, true)))
	if n == nil then n = Clean((Call("GetItemCount", itemID, true))) end
	return tonumber(n) or 0
end

local function VendorPrice(itemID)
	local sell = select(11, Call("C_Item.GetItemInfo", itemID))
	if sell == nil then sell = select(11, Call("GetItemInfo", itemID)) end
	return tonumber(Clean(sell))
end

function T.Mode()
	local db = FS.db or ForeverScribeDB
	local m = db and db.settings and db.settings.tooltip
	if m == "off" or m == "shift" then return m end
	return "on"
end

local function shiftDown() return Clean((Call("IsShiftKeyDown"))) and true or false end

local last = setmetatable({}, { __mode = "k" }) -- tooltip -> { id, lines } right after our lines went in
local seen = setmetatable({}, { __mode = "k" }) -- tooltip -> item id it showed last (for the Shift refresh)
local enlarged = setmetatable({}, { __mode = "k" }) -- tooltip -> { {fontString, originalFontObject}, ... }

local function restoreFonts(tt)
	local l = enlarged[tt]
	if not l then return end
	for _, e in ipairs(l) do pcall(e[1].SetFontObject, e[1], e[2]) end
	enlarged[tt] = nil
end

local function enlarge(tt, n)
	local name = tt.GetName and Try(tt.GetName, tt)
	if type(name) ~= "string" then return end
	local big = _G.GameTooltipHeaderText or _G.GameFontNormalLarge
	if not big then return end
	for _, side in ipairs({ "TextLeft", "TextRight" }) do
		local fs = _G[name .. side .. n]
		if fs and fs.GetFontObject and fs.SetFontObject then
			local orig = Try(fs.GetFontObject, fs) or _G.GameTooltipText
			enlarged[tt] = enlarged[tt] or {}
			table.insert(enlarged[tt], { fs, orig })
			pcall(fs.SetFontObject, fs, big)
		end
	end
end

local function wanted(tt)
	return tt ~= nil and (tt == _G.GameTooltip or tt == _G.ItemRefTooltip)
end

-- Adds our lines to `tt` for itemID. data = the tooltip's TooltipData (may be nil on the fallback hook).
function T.Decorate(tt, itemID, data)
	if not wanted(tt) then return end
	itemID = tonumber(Clean(itemID))
	if not itemID then return end
	seen[tt] = itemID
	local n0 = Try(tt.NumLines, tt) or 0
	local l0 = last[tt]
	if l0 and l0[1] == itemID and l0[2] == n0 then return end -- already in this build
	restoreFonts(tt)
	local mode = T.Mode()
	if mode == "off" then return end
	if not P and T.loadError == nil then T.Load() end
	if not P then return end
	local shift = shiftDown()
	if mode == "shift" and not shift then return end
	local unsellable = T.Unsellable(data, itemID)
	local ctx = { shift = shift, now = (Try(time)) or 0, unsellable = unsellable }
	if not unsellable then
		ctx.count = ItemCount(itemID)
		if shift then
			ctx.vendor = VendorPrice(itemID)
			ctx.usedIn = T.UsedIn(itemID)
		end
	end
	local lines = T.Lines(itemID, ctx)
	if not lines then return end
	local blank = Fn("GameTooltip_AddBlankLineToTooltip")
	if blank then Try(blank, tt) else Try(tt.AddLine, tt, " ") end
	for _, l in ipairs(lines) do
		local lc, rc = l[3] or LABEL, l[4] or VALUE
		if l[2] then
			Try(tt.AddDoubleLine, tt, l[1], l[2], lc[1], lc[2], lc[3], rc[1], rc[2], rc[3])
		else
			Try(tt.AddLine, tt, l[1], lc[1], lc[2], lc[3])
		end
		if l.big then
			local n = Try(tt.NumLines, tt)
			if n then enlarge(tt, n) end
		end
	end
	last[tt] = { itemID, Try(tt.NumLines, tt) or 0 }
end

local function fromLink(link)
	local id = U.ParseItemLink(Clean(link))
	return id
end

local function onTooltipData(tt, data)
	if not wanted(tt) then return end
	local id = type(data) == "table" and Clean(data.id)
	if not id and tt.GetItem then
		local _, link = Try(tt.GetItem, tt)
		id = fromLink(link)
	end
	if id then T.Decorate(tt, id, data) end
end

local function onSetItem(tt)
	if not wanted(tt) or not tt.GetItem then return end
	local _, link = Try(tt.GetItem, tt)
	local id = fromLink(link)
	if id then T.Decorate(tt, id, nil) end
end

local function onHidden(tt)
	last[tt], seen[tt] = nil, nil
	restoreFonts(tt)
end

local function onCleared(tt)
	last[tt], seen[tt] = nil, nil
	restoreFonts(tt)
end

-- Shift pressed or released over an item tooltip. Bag, bank, merchant, AH and character-slot tooltips rebuild themselves
-- every 0.2 s (their owner has UpdateTooltip), so Shift shows up there on its own. Only a tooltip nobody refreshes (a
-- chat link, ItemRefTooltip) is asked to rebuild with its own public RefreshData, and never in combat.
local lastShift = nil
function T.OnModifier(key)
	if T.Mode() == "off" or not P then return end
	if key ~= nil and key ~= "LSHIFT" and key ~= "RSHIFT" then return end
	local s = shiftDown()
	if s == lastShift then return end
	lastShift = s
	for _, tt in ipairs({ _G.GameTooltip, _G.ItemRefTooltip }) do
		if tt and seen[tt] and Try(tt.IsShown, tt) and tt.RefreshData and not Clean((Call("InCombatLockdown"))) then
			local owner = tt.GetOwner and Try(tt.GetOwner, tt)
			local selfUpdating = (type(owner) == "table" and owner.UpdateTooltip) or tt.UpdateTooltip
			if not selfUpdating then
				last[tt] = nil
				Try(tt.RefreshData, tt)
			end
		end
	end
end

T.hooked = nil
function T.Hook()
	if T.hooked then return T.hooked end
	local proc = _G.TooltipDataProcessor
	local itemType = Enum and Enum.TooltipDataType and Enum.TooltipDataType.Item
	if type(proc) == "table" and type(proc.AddTooltipPostCall) == "function" and itemType ~= nil then
		if pcall(proc.AddTooltipPostCall, itemType, function(tt, data) pcall(onTooltipData, tt, data) end) then
			T.hooked = "TooltipDataProcessor"
		end
	end
	for _, tt in ipairs({ _G.GameTooltip, _G.ItemRefTooltip }) do
		if tt and tt.HookScript then
			if T.hooked == nil then Try(tt.HookScript, tt, "OnTooltipSetItem", function(t) pcall(onSetItem, t) end) end
			Try(tt.HookScript, tt, "OnTooltipCleared", function(t) pcall(onCleared, t) end)
			Try(tt.HookScript, tt, "OnHide", function(t) pcall(onHidden, t) end)
		end
	end
	T.hooked = T.hooked or "OnTooltipSetItem"
	if CreateFrame then
		local f = CreateFrame("Frame")
		f:RegisterEvent("MODIFIER_STATE_CHANGED")
		f:RegisterEvent("PLAYER_LOGIN")
		f:SetScript("OnEvent", function(_, ev, key)
			if ev == "PLAYER_LOGIN" then pcall(T.Load) else pcall(T.OnModifier, key) end
		end)
	end
	return T.hooked
end

function T.Command(arg)
	local db = FS.db or ForeverScribeDB
	arg = tostring(arg or ""):lower()
	if db and db.settings and (arg == "on" or arg == "off" or arg == "shift") then db.settings.tooltip = arg end
	if not P and T.loadError == nil then T.Load() end
	local m = T.Mode()
	local what = m == "off" and "off" or m == "shift" and "only while Shift is held" or "on (hold Shift for details)"
	FS.Print("AH price tooltip " .. what .. ". /scribe tooltip on|off|shift")
	if P then
		FS.Print(string.format("prices: %s, %d items, scan %s; loaded at login or the last /reload", tostring(P.label or P.market),
			tonumber(P.items) or 0, T.Age(((Try(time)) or 0) - P.captured)))
	else
		FS.Print("no prices loaded (" .. tostring(T.loadError) .. "). Your agent writes them with `foreverscribe prices write`; then /reload.")
	end
end

T.Hook()

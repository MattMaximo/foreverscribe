-- v0.6 additions to the simulated client: item tooltips. Shapes from Forever's UI source:
--   TooltipDataProcessor.AddTooltipPostCall (Blizzard_SharedXMLGame/Tooltip/TooltipDataHandler.lua:199),
--   Enum.TooltipDataType.Item = 0, Enum.TooltipDataLineType.ItemBinding = 20, TooltipDataItemBinding.Soulbound = 3
--   (Blizzard_APIDocumentationGenerated/TooltipInfoSharedDocumentation.lua), GameTooltipDataMixin:RefreshData
--   (Blizzard_GameTooltip/Mainline/GameTooltip.lua:958), C_Item.GetItemInfo returns (ItemDocumentation.lua:626),
--   C_Item.GetItemCount(item, includeBank) (ItemDocumentation.lua:451).

local W = _G.W
local baseReset = W.Reset

local TipMT = {}
TipMT.__index = TipMT
function TipMT:AddLine(l, r, g, b) self.lines[#self.lines + 1] = { left = l, color = { r, g, b } } end
function TipMT:AddDoubleLine(l, rt, lr, lg, lb, rr, rg, rb) self.lines[#self.lines + 1] = { left = l, right = rt, color = { lr, lg, lb }, rcolor = { rr, rg, rb } } end
function TipMT:NumLines() return #self.lines end
function TipMT:GetName() return self.name end
function TipMT:GetOwner() return self.owner end
function TipMT:IsShown() return self.shown end
function TipMT:Show() self.shown = true end
function TipMT:Hide() self.shown = false; for _, f in ipairs(self.hooks.OnHide or {}) do f(self) end end
function TipMT:GetItem() if self.item then return W.items[self.item] and W.items[self.item].name, W.Link(self.item), self.item end end
function TipMT:HookScript(script, fn) self.hooks[script] = self.hooks[script] or {}; table.insert(self.hooks[script], fn) end
function TipMT:ClearLines()
	self.lines = {}
	for _, f in ipairs(self.hooks.OnTooltipCleared or {}) do f(self) end
end
function TipMT:RefreshData() W.refreshes = (W.refreshes or 0) + 1; W.HoverAgain(self) end

local function NewTip(name)
	local t = setmetatable({ name = name, lines = {}, hooks = {}, shown = false }, TipMT)
	_G[name] = t
	for _, side in ipairs({ "TextLeft", "TextRight" }) do
		for i = 1, 40 do
			_G[name .. side .. i] = { font = "GameTooltipText", GetFontObject = function(s) return s.font end, SetFontObject = function(s, f) s.font = f end }
		end
	end
	return t
end

function W.Reset()
	baseReset()
	W.postCalls = {}
	W.shift = false
	W.refreshes = 0
	W.combat = false
	W.tipAPI = "dataprocessor" -- or "script" (no TooltipDataProcessor: OnTooltipSetItem fallback)
	ForeverScribe_PriceData = nil
	W.items[4305] = { name = "Bolt of Silk Cloth", quality = 1, stack = 20, sell = 600, class = 7 }
	W.items[4306] = { name = "Silk Cloth", quality = 1, stack = 20, sell = 150, class = 7 }
	W.items[4291] = { name = "Silken Thread", quality = 1, stack = 20, sell = 125, class = 7 }
	W.items[10302] = { name = "Pattern: Filigreed Silky Circlet", quality = 2, sell = 500, class = 9 }
	W.items[10303] = { name = "Filigreed Silky Circlet", quality = 2, sell = 1200, class = 4 }
	W.items[2804] = { name = "Blade of Silverlaine", quality = 3, sell = 4000, class = 2, bind = 1 }
	W.items[5000] = { name = "Coral Band", quality = 2, sell = 900, class = 4 }
	W.items[7000] = { name = "Quest Crate", quality = 1, sell = 0, class = 12, bind = 4 }
	NewTip("GameTooltip")
	NewTip("ItemRefTooltip")
	GameTooltipHeaderText = "GameTooltipHeaderText"
	GameTooltipText = "GameTooltipText"
end

TooltipDataProcessor = setmetatable({ AllTypes = "ALL" }, { __index = function(_, k)
	if k == "AddTooltipPostCall" and W.tipAPI == "dataprocessor" then
		return function(ty, fn) W.postCalls[#W.postCalls + 1] = { ty, fn } end
	end
end })
Enum = Enum or {}
Enum.TooltipDataType = { Item = 0, Spell = 1, Unit = 2 }
Enum.TooltipDataLineType = { None = 0, ItemBinding = 20 }

function IsShiftKeyDown() return W.shift end
function InCombatLockdown() return W.combat end
function GetMoneyString(c)
	local g, s, k = math.floor(c / 10000), math.floor(c / 100) % 100, c % 100
	local out = {}
	if g > 0 then out[#out + 1] = g .. "|TGOLD|t" end
	if s > 0 then out[#out + 1] = s .. "|TSILVER|t" end
	if k > 0 or #out == 0 then out[#out + 1] = k .. "|TCOPPER|t" end
	return table.concat(out, " ")
end

local baseInfo = C_Item.GetItemInfo
C_Item.GetItemInfo = function(x)
	local iid = type(x) == "number" and x or tonumber(tostring(x):match("item:(%d+)"))
	local it = W.items[iid]
	if not it then return nil end
	local a, b, c, d, e, f, g, h, i = baseInfo(x)
	return a, b, c, d, e, f, g, h, i, 134400, it.sell or 0, it.class or 15, 0, it.bind or 0
end
C_Item.GetItemCount = function(iid, includeBank)
	local n = 0
	for bag, slots in pairs(W.bags) do
		if includeBank or bag >= 0 then
			for _, it in pairs(slots) do if it.itemID == iid then n = n + it.count end end
		end
	end
	return n
end

-- Hover an item: the client clears the tooltip, adds its own lines, then runs the post-calls (or OnTooltipSetItem).
function W.Hover(iid, opts)
	opts = opts or {}
	local tt = opts.tip or GameTooltip
	tt.item = iid
	tt.lastOpts = opts
	tt.owner = opts.owner
	tt:ClearLines()
	tt:AddLine(W.items[iid] and W.items[iid].name or "?")
	local lines = { { type = 0, leftText = W.items[iid] and W.items[iid].name or "?" } }
	if opts.soulbound then
		tt:AddLine("Soulbound")
		lines[#lines + 1] = { type = 20, leftText = "Soulbound", bonding = 3 }
	end
	tt.shown = true
	local data = { type = 0, id = iid, lines = lines }
	if W.tipAPI == "dataprocessor" then
		for _, pc in ipairs(W.postCalls) do if pc[1] == 0 then pc[2](tt, data) end end
	else
		for _, f in ipairs(tt.hooks.OnTooltipSetItem or {}) do f(tt) end
	end
	return tt
end
function W.HoverAgain(tt) return W.Hover(tt.item, tt.lastOpts) end

-- Our section of a tooltip as plain text lines ("Left | Right"), coin and color codes stripped.
function W.TipText(tt)
	tt = tt or GameTooltip
	local out, ours = {}, false
	for _, l in ipairs(tt.lines) do
		if l.left == "Auction House" then ours = true end
		if ours then
			local s = l.left .. (l.right and (" | " .. l.right) or "")
			s = s:gsub("|T[^|]*|t", function(m) return m:find("up") and "▲" or m:find("down") and "▼" or m:find("GOLD") and "g" or m:find("SILVER") and "s" or m:find("COPPER") and "c" or "" end)
			s = s:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
			out[#out + 1] = s
		end
	end
	return out
end

-- A price file in ForeverScribe_PriceData (what Prices.lua sets at load) and 12 Bolts of Silk Cloth in the bags.
function W.Prices(over)
	W.bags[0][5] = { itemID = 4305, count = 12 }
	local d = {
		v = 1, rev = "1763249160-abcd1234", market = "forever.pvp.alliance.us", label = "PvP Alliance", other = "Horde",
		source = "AHledger via wow.gg", captured = 1763250000 - 14 * 60, written = 1763250000, items = 6,
		d = {
			[4305] = "868,849,585,879,932,830", -- median 8s68, min 8s49, 585 listed, 7d 8s79, 30d 9s32, Horde 8s30
			[4306] = "200,150,1200,210,190",
			[4291] = "50,45,300,55,60",
			[10302] = "12500,11000,3,12000,11800",
			[10303] = "21000,19000,4,20000,18000,22000",
			[5000] = "9800,9000,2,9500,7746",
		},
		p = { [10302] = "10303;4305:3,4291:2,99999:1" },
	}
	for k, v in pairs(over or {}) do d[k] = v end
	ForeverScribe_PriceData = d
	return d
end

return W

-- v0.3 additions to the simulated client: pending mail, auction house (owned auctions + outcome
-- notifications), merchant, mail invoices, addons, keybinds, action bars, macros, ReloadUI guard.
-- Shapes follow Forever's Blizzard_APIDocumentationGenerated and its UI source (Minimap, MerchantFrame,
-- MailFrame, MacroUI, Keybindings).

local W = _G.W

-- Client format strings (GlobalStrings). Tests also swap these for a non-English client.
W.ENGLISH = {
	ERR_AUCTION_SOLD_S = "A buyer has been found for your auction of %s.",
	ERR_AUCTION_EXPIRED_S = "Your auction of %s has expired.",
	ERR_AUCTION_OUTBID_S = "You have been outbid on %s.",
	ERR_AUCTION_WON_S = "You won an auction for %s",
	ERR_AUCTION_COMMODITY_WON_S = "You won an auction for %s (x%d)",
	ERR_AUCTION_REMOVED = "Auction cancelled.",
	ITEM_SPELL_KNOWN = "Already known",
}
function W.SetStrings(t) for k, v in pairs(t) do _G[k] = v end end

function W.ResetV3()
	W.SetStrings(W.ENGLISH)
	W.newMail = false
	W.mailSenders = {}
	W.owned = {}
	W.ownedFull = true
	W.merchant = nil -- { npc = {guid, name}, items = { {name, price, ...} } }
	W.invoices = {}
	W.addonList = {
		{ name = "ForeverScribe", title = "ForeverScribe", version = "0.3.0", enabled = 2, loaded = true },
		{ name = "Polestar", title = "|cff00ff00Polestar|r", version = "1.4.2", enabled = 2, loaded = true },
		{ name = "OldThing", title = "Old Thing", version = nil, enabled = 0, loaded = false, reason = "DISABLED" },
	}
	W.bindings = {
		{ "MOVEFORWARD", "BINDING_HEADER_MOVEMENT", "W", "UP" },
		{ "JUMP", "BINDING_HEADER_MOVEMENT", "SPACE" },
		{ "TOGGLEBAG", "BINDING_HEADER_INTERFACE" }, -- unbound: not stored
	}
	W.actions = { [1] = { "spell", 133 }, [2] = { "item", 2589 }, [3] = { "macro", 121 } }
	W.macros = { account = { { "Mount", "/cast Swift Gnome" } }, character = { { "Sheep", "/cast [@focus] Polymorph -- secret note" } } }
	W.combat = false
	W.reloads = 0
end

function HasNewMail() return W.newMail end
function GetLatestThreeSenders() return unpack(W.mailSenders) end
function GetInboxInvoiceInfo(i)
	local v = W.invoices[i]
	if not v then return nil end
	return v.type, v.item, v.buyer, v.bid, v.buyout, v.deposit, v.fee, 0, 12, 30, v.count
end

C_AuctionHouse = {
	GetNumOwnedAuctions = function() return #W.owned end,
	HasFullOwnedAuctionResults = function() return W.ownedFull end,
	GetOwnedAuctionInfo = function(i) return W.owned[i] end,
	QueryOwnedAuctions = function() error("ForeverScribe must never send auction queries") end,
	PostItem = function() error("protected") end, PlaceBid = function() error("protected") end,
}

function UnitGUID(unit)
	if unit == "npc" and W.merchant then return W.merchant.guid end
	return nil
end
local unitNameV2 = UnitName
function UnitName(unit)
	if unit == "npc" then return W.merchant and W.merchant.name end
	return unitNameV2(unit)
end
function GetMerchantNumItems() return W.merchant and #W.merchant.items or 0 end
C_MerchantFrame = {
	GetItemInfo = function(i)
		local it = W.merchant.items[i]
		return { name = it.name, texture = 1, price = it.price or 0, stackCount = it.stack or 1, numAvailable = it.avail or -1,
			isPurchasable = it.purchasable ~= false, isUsable = it.usable ~= false, hasExtendedCost = it.cost ~= nil,
			currencyID = nil, spellID = nil, isQuestStartItem = false }
	end,
	IsMerchantItemRefundable = function() return false end,
}
function GetMerchantItemID(i) return W.merchant.items[i].id end
function GetMerchantItemLink(i) local it = W.merchant.items[i]; return string.format("|cff1eff00|Hitem:%d::::::::20|h[%s]|h|r", it.id, it.name) end
function GetMerchantItemCostInfo(i) local c = W.merchant.items[i].cost; return c and #c or 0 end
function GetMerchantItemCostItem(i, j)
	local c = W.merchant.items[i].cost[j]
	if c.currencyID then return 1, c.qty, string.format("|cffffffff|Hcurrency:%d:0|h[%s]|h|r", c.currencyID, c.name), c.name end
	return 1, c.qty, string.format("|cffffffff|Hitem:%d::::::::20|h[%s]|h|r", c.itemID, c.name), nil
end
C_TooltipInfo = { GetMerchantItem = function(i)
	local it = W.merchant.items[i]
	local lines = { { leftText = it.name } }
	if it.known then lines[#lines + 1] = { leftText = ITEM_SPELL_KNOWN } end
	return { lines = lines }
end }

C_AddOns.GetNumAddOns = function() return #W.addonList end
C_AddOns.GetAddOnInfo = function(i)
	local a = W.addonList[i]
	if not a then return nil end
	return a.name, a.title, "notes", a.enabled > 0, a.reason or nil, "INSECURE"
end
C_AddOns.IsAddOnLoaded = function(i) local a = W.addonList[i]; return a and a.loaded, a and a.loaded end
C_AddOns.GetAddOnMetadata = function(i, k) local a = W.addonList[i]; if k == "Version" then return a and a.version end end
C_AddOns.GetAddOnEnableState = function(i) local a = W.addonList[i]; return a and a.enabled or 0 end

function GetNumBindings() return #W.bindings end
function GetBinding(i) return unpack(W.bindings[i]) end
function HasAction(slot) return W.actions[slot] ~= nil end
function GetActionInfo(slot) local a = W.actions[slot]; if a then return a[1], a[2], a[3] end end
C_Item.GetItemNameByID = function(id) return W.items[id] and W.items[id].name end
function GetNumMacros() return #W.macros.account, #W.macros.character end
function GetMacroInfo(i)
	local m = i > 120 and W.macros.character[i - 120] or W.macros.account[i]
	if m then return m[1], 134400, m[2] end
end
function InCombatLockdown() return W.combat end
function ReloadUI() W.reloads = W.reloads + 1 end

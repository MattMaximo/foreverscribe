-- Boots the simulated client with a Prices.lua the companion wrote (like the game: the file runs at load, before
-- ForeverScribe), hovers the given items and prints {loaded, error, label, lines = {[id] = {...}}} as JSON.
--   lua tests/lua/prices_e2e.lua <Prices.lua> <itemID> [shift] ...
local ROOT = (arg and arg[0] or ""):match("^(.*)tests/lua/[^/]+$") or "./"
dofile(ROOT .. "tests/lua/wow_stub.lua")
W.Reset(); W.ROOT = ROOT
local path = arg[1]
local ok, err = pcall(dofile, path)
W.bags[0][5] = { itemID = 4305, count = 12 }
W.Boot()
local T = ForeverScribe.Tooltip
local out = { loaded = T.Data() ~= nil, error = T.loadError or (not ok and tostring(err)) or nil, label = T.Data() and T.Data().label, lines = {} }
-- r<recipeID>: open the profession window, select that recipe, record the craft numbers in its detail pane (0.8.2)
for i = 2, #arg do
	local r, id, shift = arg[i]:match("^(r?)(%d+)(s?)$")
	W.shift = shift == "s"
	id = tonumber(id)
	if r == "r" then
		W.OpenProfessions(); W.SelectRecipe(id)
		out.lines[arg[i]] = W.PanelText() or {}
	else
		W.items[id] = W.items[id] or { name = "item " .. id, quality = 1, sell = 1 }
		W.Hover(id)
		out.lines[arg[i]] = W.TipText()
	end
end
out.errors = ForeverScribe.errors or 0
print(ForeverScribe.Util.JSON(out))

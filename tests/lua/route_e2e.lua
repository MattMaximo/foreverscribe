-- End-to-end check used by tests/test_routes.py: boot the simulated client with the route slots in <addonsDir>
-- (what `foreverscribe route write` or the sync agent produced), press /fs go, print what the addon did.
-- Run: lua tests/lua/route_e2e.lua <addonsDir> [presses]
local ROOT = (arg and arg[0] or ""):match("^(.*)tests/lua/[^/]+$") or "./"
dofile(ROOT .. "tests/lua/wow_stub.lua")
W.Reset(); W.ROOT = ROOT
W.slotDir = arg[1]
W.Boot()
W.zone.mapID, W.zone.x, W.zone.y = 1453, 0.10, 0.10
for _ = 1, tonumber(arg[2] or "1") do ForeverScribe.Slash("go") end
local r = ForeverScribeDB.route
local U = ForeverScribe.Util
print(U.JSON({
	rev = r and r.rev, name = r and r.name, stops = r and #r.stops or 0, i = r and r.i,
	first = r and r.stops[1] and { map = r.stops[1].map, x = r.stops[1].x, y = r.stops[1].y, title = r.stops[1].title, r = r.stops[1].r },
	waypoint = W.waypoint, chat = W.chat[#W.chat], errors = ForeverScribe.errors or 0,
}))

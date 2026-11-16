-- Drives the real ForeverScribe + ForeverScribe_Live code in the simulated client
-- and dumps every drawn strip frame (texture colours in cell order) for the
-- Python live-capture latency test. Usage: lua live_dump.lua <n_events>
local ROOT = (arg and arg[0] or ""):match("^(.*)tests/lua/[^/]+$") or "./"
dofile(ROOT .. "tests/lua/wow_stub.lua")
W.Reset(); W.ROOT = ROOT
W.Boot()
SlashCmdList.FOREVERSCRIBE("live on")
local strip = _G.ForeverScribeLiveStrip
local function dump(tag)
	local cells = {}
	for _, t in ipairs(strip.textures) do
		if t.shown ~= false and t.color then
			local c = t.color
			cells[#cells + 1] = c[1] * 4 + c[2] * 2 + c[3]
		end
	end
	io.write("FRAME ", tag, " ", table.concat(cells, ","), "\n")
end
local n = tonumber(arg[1]) or 5
for i = 1, n do
	if i % 3 == 0 then
		W.player.level = W.player.level + 1; W.Fire("PLAYER_LEVEL_UP", W.player.level)
	elseif i % 3 == 1 then
		W.Fire("PLAYER_DEAD")
	else
		W.zone.zone = "Zone " .. i; W.zone.mapID = 2000 + i; W.Fire("ZONE_CHANGED_NEW_AREA"); W.Advance(21)
	end
	W.Advance(0.1)
	dump(ForeverScribeDB.chars[ForeverScribe.charKey].events[#ForeverScribeDB.chars[ForeverScribe.charKey].events].id)
end
-- oversized burst: many events at once must still fit in one frame (newest kept)
for i = 1, 60 do W.Fire("PLAYER_DEAD") end
W.Advance(0.1)
dump("burst")
SlashCmdList.FOREVERSCRIBE("live off")
io.write("SHOWN ", tostring(strip.shown), "\n")

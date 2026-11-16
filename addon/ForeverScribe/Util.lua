-- ForeverScribe utilities. Pure Lua 5.1: no game API is called here except the
-- optional global `issecretvalue`, so everything in this file can be unit-tested
-- outside the client.

ForeverScribe = ForeverScribe or {}
local FS = ForeverScribe
local U = {}
FS.Util = U

local type, pairs, ipairs, tostring, tonumber = type, pairs, ipairs, tostring, tonumber
local floor = math.floor

-- Secret values (Midnight-era restriction, present on Forever) may not be
-- stored, compared, concatenated or used as table keys. Anything that comes
-- from the game goes through Clean() before we keep it.
function U.IsSecret(v)
	local f = issecretvalue
	if type(f) ~= "function" then return false end
	local ok, res = pcall(f, v)
	if not ok then return true end -- cannot even ask: treat as secret
	return res and true or false
end

-- Returns v when it is a plain storable scalar, else nil.
function U.Clean(v)
	if v == nil then return nil end
	if U.IsSecret(v) then return nil end
	local t = type(v)
	if t == "string" or t == "number" or t == "boolean" then return v end
	return nil
end

-- Deep copy keeping only storable, non-secret data. Depth and size bounded.
function U.Sanitize(v, depth)
	depth = depth or 0
	if v == nil then return nil end
	if U.IsSecret(v) then return nil end
	local t = type(v)
	if t == "string" then
		if #v > 2000 then return v:sub(1, 2000) end
		return v
	elseif t == "number" then
		if v ~= v or v == math.huge or v == -math.huge then return nil end
		return v
	elseif t == "boolean" then
		return v
	elseif t == "table" then
		if depth > 6 then return nil end
		local out, n = {}, 0
		for k, val in pairs(v) do
			n = n + 1
			if n > 4000 then break end
			local ck = U.Clean(k)
			if ck ~= nil then
				local cv = U.Sanitize(val, depth + 1)
				if cv ~= nil then out[ck] = cv end
			end
		end
		return out
	end
	return nil
end

-- Call fn(...) protected; returns its results, or nothing on error/missing.
function U.Try(fn, ...)
	if type(fn) ~= "function" then return nil end
	local res = { pcall(fn, ...) }
	if not res[1] then
		FS.errors = (FS.errors or 0) + 1
		FS.lastError = tostring(res[2])
		return nil
	end
	return unpack(res, 2, table.maxn(res))
end

-- Resolve "C_QuestLog.GetInfo" style paths safely.
function U.Fn(path)
	local cur = _G
	for part in path:gmatch("[^%.]+") do
		if type(cur) ~= "table" then return nil end
		cur = cur[part]
	end
	if type(cur) == "function" then return cur end
	return nil
end

function U.Call(path, ...)
	return U.Try(U.Fn(path), ...)
end

-- Item link helpers ------------------------------------------------------

-- "|cff1eff00|Hitem:2580:15:0:...|h[Linen Bracers]|h|r" -> itemID, enchantID, name
function U.ParseItemLink(link)
	if type(link) ~= "string" or U.IsSecret(link) then return nil end
	local body = link:match("|Hitem:([%-%d:]*)|h") or link:match("^item:([%-%d:]*)")
	if not body then return nil end
	local fields = {}
	for f in (body .. ":"):gmatch("([^:]*):") do fields[#fields + 1] = f end
	local itemID = tonumber(fields[1])
	local enchant = tonumber(fields[2])
	if enchant == 0 then enchant = nil end
	local name = link:match("|h%[(.-)%]|h")
	return itemID, enchant, name
end

function U.Count(t)
	local n = 0
	for _ in pairs(t or {}) do n = n + 1 end
	return n
end

-- Diff two {[key]=number} maps. Returns { {key, old, new, delta}, ... } sorted by key.
function U.DiffCounts(old, new)
	local out = {}
	local seen = {}
	for k, v in pairs(new or {}) do
		seen[k] = true
		local o = (old or {})[k] or 0
		if o ~= v then out[#out + 1] = { key = k, old = o, new = v, delta = v - o } end
	end
	for k, o in pairs(old or {}) do
		if not seen[k] and o ~= 0 then out[#out + 1] = { key = k, old = o, new = 0, delta = -o } end
	end
	table.sort(out, function(a, b) return tostring(a.key) < tostring(b.key) end)
	return out
end

-- Set of keys present in `new` but not `old`.
function U.NewKeys(old, new)
	local out = {}
	for k in pairs(new or {}) do
		if not (old or {})[k] then out[#out + 1] = k end
	end
	table.sort(out, function(a, b) return tostring(a) < tostring(b) end)
	return out
end

-- Bounded append-only ring: keeps the newest `cap` entries. Trims in batches
-- so appends stay O(1) amortised.
function U.RingPush(list, item, cap, meta)
	list[#list + 1] = item
	local n = #list
	if n > cap + floor(cap / 10) + 1 then
		local drop = n - cap
		local keep = {}
		for i = drop + 1, n do keep[#keep + 1] = list[i] end
		for i = n, 1, -1 do list[i] = nil end
		for i = 1, #keep do list[i] = keep[i] end
		if meta then meta.dropped = (meta.dropped or 0) + drop end
	end
end

-- Minimal JSON encoder (compact, sorted keys, arrays detected) -------------

local function esc(s)
	s = s:gsub('[%c"\\]', function(c)
		if c == '"' then return '\\"' end
		if c == "\\" then return "\\\\" end
		if c == "\n" then return "\\n" end
		if c == "\t" then return "\\t" end
		if c == "\r" then return "\\r" end
		return string.format("\\u%04x", c:byte())
	end)
	return s
end

local function isArray(t)
	local n = 0
	for k in pairs(t) do
		if type(k) ~= "number" or k < 1 or k % 1 ~= 0 then return false end
		n = n + 1
	end
	for i = 1, n do if t[i] == nil then return false end end
	return true, n
end

function U.JSON(v)
	local t = type(v)
	if v == nil then return "null" end
	if t == "boolean" then return v and "true" or "false" end
	if t == "number" then
		if v % 1 == 0 and v > -1e15 and v < 1e15 then return string.format("%d", v) end
		return string.format("%.4f", v)
	end
	if t == "string" then return '"' .. esc(v) .. '"' end
	if t == "table" then
		local arr, n = isArray(v)
		local parts = {}
		if arr then
			for i = 1, n do parts[i] = U.JSON(v[i]) end
			return "[" .. table.concat(parts, ",") .. "]"
		end
		local keys = {}
		for k in pairs(v) do keys[#keys + 1] = k end
		table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
		for _, k in ipairs(keys) do
			parts[#parts + 1] = '"' .. esc(tostring(k)) .. '":' .. U.JSON(v[k])
		end
		return "{" .. table.concat(parts, ",") .. "}"
	end
	return "null"
end

return U

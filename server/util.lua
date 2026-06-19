-- Shared helpers: identifier + token collection (every type FiveM exposes),
-- player lookup by ANY identifier, and time conversions. Used by every adapter
-- and the ban store so support is consistent across frameworks.
CTQ = CTQ or {}
Util = {}

-- Every identifier prefix the Cfx platform can expose for a player.
local ID_TYPES = { 'license', 'license2', 'discord', 'steam', 'fivem', 'xbl', 'live', 'ip' }
Util.ID_TYPES = ID_TYPES

-- Returns a map { license = 'license:abc', discord = 'discord:123', … } for a src,
-- containing only the identifiers that player actually has.
function Util.identifierMap(src)
	local map = {}
	for i = 0, GetNumPlayerIdentifiers(src) - 1 do
		local id = GetPlayerIdentifier(src, i)
		local kind = id:match('^(%a+):')
		if kind then map[kind] = id end
	end
	return map
end

-- Flat list of every full identifier string for a src ("license:…", "discord:…").
function Util.identifierList(src)
	local list = {}
	for i = 0, GetNumPlayerIdentifiers(src) - 1 do
		list[#list + 1] = GetPlayerIdentifier(src, i)
	end
	return list
end

-- Best-effort hardware tokens (entitlement/hardware ids). Requires a recent
-- server artifact; returns {} when unavailable.
function Util.tokens(src)
	local out = {}
	local ok, n = pcall(GetNumPlayerTokens, src)
	if not ok or not n then return out end
	for i = 0, n - 1 do
		local tok = GetPlayerToken(src, i)
		if tok then out[#out + 1] = tok end
	end
	return out
end

-- The "primary" identifier we report to the dashboard for a player. Prefer a
-- stable hardware-backed id (license) and fall back through the list.
function Util.primaryIdentifier(src)
	local map = Util.identifierMap(src)
	return map.license or map.license2 or map.fivem or map.discord or map.steam
		or (Util.identifierList(src)[1]) or ('server:' .. src)
end

function Util.discordId(src)
	local d = Util.identifierMap(src).discord
	return d and d:gsub('^discord:', '') or nil
end

-- Find an online player's server id from ANY of their identifiers (or tokens,
-- or a literal "server:<id>"). Returns the numeric src, or nil.
function Util.findPlayer(identifier)
	if not identifier or identifier == '' then return nil end

	local sid = identifier:match('^server:(%d+)$')
	if sid then
		local n = tonumber(sid)
		return (GetPlayerName(n) ~= nil) and n or nil
	end

	-- Normalise: allow matching a bare value against any of the player's ids.
	local bare = identifier:gsub('^%a+:', '')

	for _, src in ipairs(GetPlayers()) do
		src = tonumber(src)
		for i = 0, GetNumPlayerIdentifiers(src) - 1 do
			local id = GetPlayerIdentifier(src, i)
			if id == identifier or id:gsub('^%a+:', '') == bare then return src end
		end
		for _, tok in ipairs(Util.tokens(src)) do
			if tok == identifier then return src end
		end
	end
	return nil
end

-- Time helpers. SQL ban tables store unix seconds; the dashboard wants ISO.
function Util.toIso(unix)
	if not unix or unix == 0 then return nil end
	return os.date('!%Y-%m-%dT%H:%M:%SZ', unix)
end

function Util.isoToUnix(iso)
	if not iso then return nil end
	local y, mo, d, h, mi, s = iso:match('(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)')
	if not y then return nil end
	return os.time({ year = tonumber(y), month = tonumber(mo), day = tonumber(d), hour = tonumber(h), min = tonumber(mi), sec = tonumber(s) })
end

function Util.isExpired(unix)
	return unix ~= nil and unix > 0 and unix <= os.time()
end

return Util

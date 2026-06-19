-- QBCore adapter. Handles the common QBCore forks/versions: resolves the core
-- object defensively, and builds player names from charinfo when available
-- (falling back to the account name, then the native name). Bans go through the
-- shared ban store, which reads/writes QBCore's own `bans` table when present.
CTQ = CTQ or {}
CTQ.Adapters = CTQ.Adapters or {}

local adapter = {}
local core

local function coreResource()
	if GetResourceState('qb-core') == 'started' then return 'qb-core' end
	if GetResourceState('qbcore') == 'started' then return 'qbcore' end
	return nil
end

function adapter.detect()
	return coreResource() ~= nil
end

local function getCore()
	if core then return core end
	local res = coreResource()
	if not res then return nil end
	-- Modern: exports getter. Legacy: the GetCoreObject event.
	local ok, obj = pcall(function() return exports[res]:GetCoreObject() end)
	if ok and obj then core = obj return core end
	ok, obj = pcall(function()
		local o
		TriggerEvent('QBCore:GetObject', function(c) o = c end)
		return o
	end)
	core = (ok and obj) or nil
	return core
end

local function nameOf(src, qb)
	local player = qb and qb.Functions and qb.Functions.GetPlayer and qb.Functions.GetPlayer(src) or nil
	if player and player.PlayerData then
		local ci = player.PlayerData.charinfo
		if ci and ci.firstname then
			return ('%s %s'):format(ci.firstname, ci.lastname or '')
		end
		if player.PlayerData.name then return player.PlayerData.name end
	end
	return GetPlayerName(src) or 'Unknown'
end

function adapter.getPlayers()
	local qb = getCore()
	local players = {}
	for _, src in ipairs(GetPlayers()) do
		src = tonumber(src)
		players[#players + 1] = {
			identifier = Util.primaryIdentifier(src),
			serverId = src,
			name = nameOf(src, qb),
			discordId = Util.discordId(src),
			ping = GetPlayerPing(src),
		}
	end
	return players
end

function adapter.getProfile(target)
	local qb = getCore()
	local src = Util.findPlayer(target)
	local pd
	if src and qb and qb.Functions and qb.Functions.GetPlayer then
		local p = qb.Functions.GetPlayer(src)
		pd = p and p.PlayerData or nil
	end
	return Profile.qbStyle(target, pd)
end

CTQ.Adapters.qbcore = Actions.attach(adapter)

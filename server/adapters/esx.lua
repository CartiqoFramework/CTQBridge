-- ESX adapter. Resolves the shared object across ESX versions (legacy event,
-- 1.1 export, 1.2 export) and reads character names defensively. Bans route
-- through the shared ban store, which adapts to whatever ban table the server
-- uses (esx_bans / a `bans` table / none → JSON).
CTQ = CTQ or {}
CTQ.Adapters = CTQ.Adapters or {}

local adapter = {}
local ESX

function adapter.detect()
	return GetResourceState('es_extended') == 'started'
end

local function getESX()
	if ESX then return ESX end
	-- 1.2 / 1.1 export.
	local ok, obj = pcall(function() return exports['es_extended']:getSharedObject() end)
	if ok and obj then ESX = obj return ESX end
	-- Legacy event style.
	ok, obj = pcall(function()
		local o
		TriggerEvent('esx:getSharedObject', function(c) o = c end)
		return o
	end)
	ESX = (ok and obj) or nil
	return ESX
end

local function nameOf(esx, src)
	if not esx then return GetPlayerName(src) or 'Unknown' end
	local xPlayer = (esx.GetPlayerFromId and esx.GetPlayerFromId(src)) or nil
	if xPlayer then
		if xPlayer.getName then
			local ok, n = pcall(function() return xPlayer.getName() end)
			if ok and n then return n end
		end
		if xPlayer.name then return xPlayer.name end
	end
	return GetPlayerName(src) or 'Unknown'
end

function adapter.getPlayers()
	local esx = getESX()
	local players = {}
	for _, src in ipairs(GetPlayers()) do
		src = tonumber(src)
		players[#players + 1] = {
			identifier = Util.primaryIdentifier(src),
			serverId = src,
			name = nameOf(esx, src),
			discordId = Util.discordId(src),
			ping = GetPlayerPing(src),
		}
	end
	return players
end

function adapter.getProfile(target)
	local esx = getESX()
	local src = Util.findPlayer(target)
	local xPlayer
	if src and esx and esx.GetPlayerFromId then xPlayer = esx.GetPlayerFromId(src) end
	return Profile.esx(target, xPlayer)
end

CTQ.Adapters.esx = Actions.attach(adapter)

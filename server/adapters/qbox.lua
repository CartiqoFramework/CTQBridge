-- Qbox adapter (qbx_core). Qbox is QBCore-derived; player data comes from
-- exports.qbx_core. Bans route through the shared ban store (Qbox typically uses
-- txAdmin or a `bans` table — both handled by the store's auto-detection).
CTQ = CTQ or {}
CTQ.Adapters = CTQ.Adapters or {}

local adapter = {}

local function coreResource()
	if GetResourceState('qbx_core') == 'started' then return 'qbx_core' end
	if GetResourceState('qbx-core') == 'started' then return 'qbx-core' end
	return nil
end

function adapter.detect()
	return coreResource() ~= nil
end

local function nameOf(src, res)
	local ok, player = pcall(function() return exports[res]:GetPlayer(src) end)
	if ok and player and player.PlayerData then
		local ci = player.PlayerData.charinfo
		if ci and ci.firstname then return ('%s %s'):format(ci.firstname, ci.lastname or '') end
		if player.PlayerData.name then return player.PlayerData.name end
	end
	return GetPlayerName(src) or 'Unknown'
end

function adapter.getPlayers()
	local res = coreResource()
	local players = {}
	for _, src in ipairs(GetPlayers()) do
		src = tonumber(src)
		players[#players + 1] = {
			identifier = Util.primaryIdentifier(src),
			serverId = src,
			name = res and nameOf(src, res) or (GetPlayerName(src) or 'Unknown'),
			discordId = Util.discordId(src),
			ping = GetPlayerPing(src),
		}
	end
	return players
end

function adapter.getProfile(target)
	local res = coreResource()
	local src = Util.findPlayer(target)
	local pd
	if src and res then
		local ok, p = pcall(function() return exports[res]:GetPlayer(src) end)
		pd = (ok and p) and p.PlayerData or nil
	end
	return Profile.qbStyle(target, pd)
end

CTQ.Adapters.qbox = Actions.attach(adapter)

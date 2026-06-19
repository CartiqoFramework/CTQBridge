-- Standalone adapter: no framework. Roster from native player list; all
-- moderation routes through the shared actions + ban store (SQL if a database is
-- present, else data/bans.json). This is the universal fallback and works on any
-- server, including pure/txAdmin setups.
CTQ = CTQ or {}
CTQ.Adapters = CTQ.Adapters or {}

local adapter = {}

function adapter.detect()
	return true -- always available; the guaranteed fallback
end

function adapter.getPlayers()
	local players = {}
	for _, src in ipairs(GetPlayers()) do
		src = tonumber(src)
		players[#players + 1] = {
			identifier = Util.primaryIdentifier(src),
			serverId = src,
			name = GetPlayerName(src) or 'Unknown',
			discordId = Util.discordId(src),
			ping = GetPlayerPing(src),
		}
	end
	return players
end

function adapter.getProfile(target)
	local src = Util.findPlayer(target)
	-- No framework → only natives + any owner-keyed DB tables we can match.
	return {
		identifier = target,
		name = src and GetPlayerName(src) or nil,
		note = 'No framework detected — money/job are unavailable on a standalone server.',
		vehicles = Profile.vehicles({ identifier = target }),
		properties = Profile.properties({ identifier = target }),
	}
end

CTQ.Adapters.standalone = Actions.attach(adapter)

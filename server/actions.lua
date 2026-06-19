-- Shared command implementations used by every framework adapter. The only
-- per-framework difference is how the live roster is read (adapter.getPlayers);
-- kick/ban/unban/warn/message are identical everywhere and route through the
-- universal identifier + ban-store helpers.
CTQ = CTQ or {}
Actions = {}

local function countKeys(t)
	local n = 0
	for _ in pairs(t) do n = n + 1 end
	return n
end

-- Resolve a dashboard target into (idMap, tokens, name, src). When the player is
-- online we capture EVERY identifier + token; offline we have only the one id.
local function resolveTarget(target)
	local src = Util.findPlayer(target)
	if src then
		return Util.identifierMap(src), Util.tokens(src), GetPlayerName(src), src
	end
	local kind = target:match('^(%a+):') or 'license'
	return { [kind] = target }, {}, nil, nil
end

function Actions.kick(target, reason)
	local src = Util.findPlayer(target)
	if not src then return false, 'player not online' end
	DropPlayer(src, reason or Config.DefaultKickMessage)
	return true, 'kicked'
end

function Actions.ban(target, reason, durationMs)
	local ids, tokens, name, src = resolveTarget(target)

	-- Honour BanAllIdentifiers: when off, only the clicked id is banned.
	if Config.Ban and Config.Ban.BanAllIdentifiers == false then
		local kind = target:match('^(%a+):')
		ids = kind and { [kind] = target } or { identifier = target }
	end
	if not (Config.Ban and Config.Ban.IncludeTokens) then tokens = {} end

	local expire = durationMs and (os.time() + math.floor(durationMs / 1000)) or nil
	local ok = Bans.add(ids, name, reason or Config.DefaultBanMessage, expire, 'CARTIQO Dashboard', tokens)
	if not ok then return false, 'ban store rejected the write' end

	if src then DropPlayer(src, reason or Config.DefaultBanMessage) end
	local how = src and ('online, %d ids'):format(countKeys(ids)) or 'offline'
	return true, ('banned (%s)'):format(how)
end

function Actions.unban(target)
	Bans.remove(target)
	return true, 'unbanned'
end

function Actions.warn(target, reason)
	local src = Util.findPlayer(target)
	if not src then return false, 'player not online' end
	TriggerClientEvent('chat:addMessage', src, { color = { 255, 180, 0 }, args = { '[Admin Warning]', reason or 'You have been warned.' } })
	return true, 'warned'
end

function Actions.message(target, text)
	local src = Util.findPlayer(target)
	if not src then return false, 'player not online' end
	TriggerClientEvent('chat:addMessage', src, { color = { 88, 101, 242 }, args = { '[Server]', text or '' } })
	return true, 'sent'
end

-- Shared getBans — every adapter serves the ban store's cached list.
function Actions.getBans()
	return Bans.cached()
end

-- Mix the shared actions into an adapter table (which supplies getPlayers/detect).
function Actions.attach(adapter)
	adapter.kick = Actions.kick
	adapter.ban = Actions.ban
	adapter.unban = Actions.unban
	adapter.warn = Actions.warn
	adapter.message = Actions.message
	adapter.getBans = Actions.getBans
	return adapter
end

return Actions

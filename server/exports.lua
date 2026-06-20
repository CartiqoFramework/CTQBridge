-- Public exports — the stable SDK surface other resources (CTQCore, etc.) use
-- instead of re-implementing dashboard comms. All are safe to call before the
-- bridge is ready (they no-op / return empty until CTQ.ready).
--
-- Usage from another resource:
--   exports.CTQBridge:IsReady()
--   exports.CTQBridge:CheckWhitelist(src)   -> { allowed, priority, roles, message }
--   exports.CTQBridge:GetRoles(src)         -> { '<roleId>', ... }
--   exports.CTQBridge:GetDiscordId(src)     -> '<discordId>' | nil
--   exports.CTQBridge:GetProfile(identifier)-> profile table
--   exports.CTQBridge:Kick/Ban/Unban(...)   -> ok, message
CTQ = CTQ or {}

exports('IsReady', function() return CTQ.ready == true end)
exports('GetFramework', function() return CTQ.framework end)
exports('GetDbKind', function() return Db and Db.kind or nil end)

-- Block (up to timeoutMs, default 10s) until the bridge is ready, polling every
-- 100ms. For resources that start before CTQBridge and need it immediately.
-- Returns true once ready, false if it timed out. Call inside a thread.
exports('WaitUntilReady', function(timeoutMs)
	local deadline = GetGameTimer() + (timeoutMs or 10000)
	while CTQ.ready ~= true do
		if GetGameTimer() >= deadline then return false end
		Wait(100)
	end
	return true
end)

exports('GetDiscordId', function(src) return Util.discordId(src) end)
exports('GetIdentifiers', function(src) return Util.identifierList(src) end)
exports('FindPlayer', function(identifier) return Util.findPlayer(identifier) end)

-- Per-player role cache (60s) so repeated calls (e.g. on connect + spawn) don't
-- spam the agent API.
local roleCache = {} -- [src] = { roles = {...}, at = <ms> }
local ROLE_TTL = 60000

exports('GetRoles', function(src)
	local now = GetGameTimer()
	local hit = roleCache[src]
	if hit and (now - hit.at) < ROLE_TTL then return hit.roles end
	local roles = Whitelist.getRoles(src) or {}
	roleCache[src] = { roles = roles, at = now }
	return roles
end)

-- Drop cached roles when a player leaves so their slot doesn't go stale.
AddEventHandler('playerDropped', function() roleCache[source] = nil end)

exports('CheckWhitelist', function(src) return Whitelist.check(src) end)

exports('GetProfile', function(identifier)
	if not (CTQ.adapter and CTQ.adapter.getProfile) then return nil end
	local ok, profile = pcall(CTQ.adapter.getProfile, identifier)
	return ok and profile or nil
end)

exports('Kick', function(target, reason)
	if not CTQ.adapter then return false, 'not ready' end
	return CTQ.adapter.kick(target, reason)
end)
exports('Ban', function(target, reason, durationMs)
	if not CTQ.adapter then return false, 'not ready' end
	return CTQ.adapter.ban(target, reason, durationMs)
end)
exports('Unban', function(target)
	if not CTQ.adapter then return false, 'not ready' end
	return CTQ.adapter.unban(target)
end)

-- Raw access to the current dashboard-pushed config (whitelist rules, etc.).
exports('GetConfig', function() return CTQ.config end)

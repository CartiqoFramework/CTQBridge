-- Whitelist / connect-queue client. The decision (allow/deny + queue priority) is
-- made by the dashboard from the role rules configured there; this module gathers
-- the player's live Discord id and asks the dashboard. Players must have Discord
-- running in-game — there's no link/storage layer. CTQCore consumes
-- Whitelist.check(src) to drive its connect queue.
CTQ = CTQ or {}
Whitelist = {}

-- Ask the dashboard whether `src` may connect. Synchronous — call inside a
-- thread (the connect deferral). Returns { allowed, priority, roles, message }.
function Whitelist.checkConnecting(src)
	local discord = Util.discordId(src) -- raw id (no "discord:" prefix), or nil

	-- No Discord running → deny locally without a round-trip.
	if not discord then
		local wl = CTQ.config and CTQ.config.whitelist
		local msg = (wl and wl.messages and wl.messages.noDiscord) or 'You must have Discord running to join this server.'
		return { allowed = false, priority = 0, roles = {}, reason = 'no-discord', message = msg }
	end

	local data = CTQ.postAwait('/whitelist', { discordId = discord })

	if not data then
		-- Dashboard unreachable: fail open or closed per config (default: open so a
		-- web outage doesn't lock everyone out).
		local open = not (Config.Whitelist and Config.Whitelist.FailClosed)
		return { allowed = open, priority = 0, roles = {}, message = open and nil or 'Whitelist service unavailable — try again shortly.' }
	end

	TriggerEvent('CTQBridge:whitelistChecked', src, data)
	return data
end

-- Same decision, exposed for other resources via exports.CTQBridge:CheckWhitelist.
function Whitelist.check(src)
	return Whitelist.checkConnecting(src)
end

-- A player's Discord role IDs for this guild (cached server-side ~60s). Returns
-- a table of role id strings (empty when the player has no Discord id / isn't in
-- the guild).
function Whitelist.getRoles(src)
	local discord = Util.discordId(src)
	if not discord then return {} end
	local data = CTQ.postAwait('/roles', { discordId = discord })
	if data and data.roles then
		TriggerEvent('CTQBridge:rolesResolved', src, data.roles)
		return data.roles
	end
	return {}
end

return Whitelist

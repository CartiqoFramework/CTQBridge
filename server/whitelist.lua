-- Whitelist / connect-queue client. The decision (allow/deny + queue priority) is
-- normally made by the dashboard from the role rules configured there; this module
-- gathers the player's live Discord id and asks the dashboard. Players must have
-- Discord running in-game — there's no link/storage layer. CTQCore consumes
-- Whitelist.check(src) to drive its connect queue.
--
-- Offline fallback (job 12): every /sync pushes the current whitelist rules, which
-- we cache. If the dashboard is unreachable on connect we apply those cached rules
-- locally; with no cache we honour Config.FallbackBehaviour ("allow" | "deny").
CTQ = CTQ or {}
Whitelist = {}

-- Module-level cache of the last whitelist rules pushed via /sync.
local WhitelistCache = { rules = nil, lastUpdated = 0 }

-- Called from the sync loop with the freshest whitelist config (or nil).
function Whitelist.updateCache(rules)
	if rules ~= nil then
		WhitelistCache.rules = rules
		WhitelistCache.lastUpdated = os.time()
	end
end

-- Age of the cached rules in seconds, or nil when nothing is cached yet.
function Whitelist.cacheAge()
	if not WhitelistCache.rules then return nil end
	return os.time() - WhitelistCache.lastUpdated
end

-- POST that resolves to: a table (success), false (API error), or nil (timeout).
local function postWithTimeout(path, body, timeoutMs)
	local p = promise.new()
	local settled = false
	CTQ.post(path, body, function(ok, data)
		if settled then return end
		settled = true
		p:resolve(ok and (data or {}) or false)
	end)
	SetTimeout(timeoutMs, function()
		if settled then return end
		settled = true
		p:resolve(nil)
	end)
	return Citizen.Await(p)
end

-- Apply cached rules locally when the API is unreachable. Without a Discord round
-- trip we can only verify the always-allow user list + open mode; role-gated
-- checks fall through to Config.FallbackBehaviour.
local function evalLocal(discordId, roles)
	local rules = WhitelistCache.rules
	local fbAllow = (Config.FallbackBehaviour or 'allow') ~= 'deny'

	-- No cached rules at all → pure config fallback.
	if not rules then
		return {
			allowed = fbAllow,
			priority = 0,
			roles = {},
			reason = 'fallback-no-cache',
			message = fbAllow and nil or 'Whitelist service unavailable — try again shortly.',
		}
	end

	if not rules.enabled then return { allowed = true, priority = 0, roles = roles or {}, reason = 'cache-disabled' } end

	-- Always-allow users (highest priority).
	for _, u in ipairs(rules.allowedUserIds or {}) do
		if u == discordId then return { allowed = true, priority = 100, roles = roles or {}, reason = 'cache-user' } end
	end

	if rules.mode == 'open' then return { allowed = true, priority = 0, roles = roles or {}, reason = 'cache-open' } end

	-- Role mode: match any roles we happen to have; otherwise we can't verify
	-- offline → honour the configured fallback.
	if roles and #roles > 0 then
		for _, r in ipairs(roles) do
			for _, a in ipairs(rules.allowedRoleIds or {}) do
				if r == a then return { allowed = true, priority = 10, roles = roles, reason = 'cache-role' } end
			end
		end
		return { allowed = false, priority = 0, roles = roles, reason = 'cache-no-role', message = (rules.messages and rules.messages.denied) or 'You are not whitelisted on this server.' }
	end

	return {
		allowed = fbAllow,
		priority = 0,
		roles = {},
		reason = 'fallback-role-unverifiable',
		message = fbAllow and nil or 'Whitelist could not be verified — try again shortly.',
	}
end

-- Ask the dashboard whether `src` may connect. Synchronous — call inside a
-- thread (the connect deferral). Returns { allowed, priority, roles, message }.
function Whitelist.checkConnecting(src)
	local discord = Util.discordId(src) -- raw id (no "discord:" prefix), or nil

	-- No Discord running → deny locally without a round-trip.
	if not discord then
		local wl = (CTQ.config and CTQ.config.whitelist) or WhitelistCache.rules
		local msg = (wl and wl.messages and wl.messages.noDiscord) or 'You must have Discord running to join this server.'
		return { allowed = false, priority = 0, roles = {}, reason = 'no-discord', message = msg }
	end

	local data = postWithTimeout('/whitelist', { discordId = discord }, Config.WhitelistTimeout or 3000)

	-- Success → use the authoritative dashboard decision.
	if type(data) == 'table' and data.allowed ~= nil then
		TriggerEvent('CTQBridge:whitelistChecked', src, data)
		return data
	end

	-- Timeout or error → cached rules / config fallback.
	CTQ.warn('whitelist API unreachable — applying offline fallback (' .. (Config.FallbackBehaviour or 'allow') .. ')')
	local decision = evalLocal(discord, Whitelist.getRoles and {} or {})
	TriggerEvent('CTQBridge:whitelistChecked', src, decision)
	return decision
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

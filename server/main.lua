-- CTQBridge core: initialise the DB layer + ban store, pick the framework
-- adapter, enforce bans on connect (universally, across all identifiers/tokens),
-- and run the sync loop — report roster (+ periodic ban list) to the dashboard,
-- pull queued commands, execute them via the adapter, and report results back.
CTQ = CTQ or {}

local activeAdapter
local activeName

-- Back-compat alias kept for any external callers.
function CTQ.findPlayerByIdentifier(identifier)
	return Util.findPlayer(identifier)
end

local function selectAdapter()
	local forced = Config.Framework
	if forced and forced ~= 'auto' and CTQ.Adapters[forced] then
		return forced, CTQ.Adapters[forced]
	end
	for _, name in ipairs({ 'qbcore', 'qbox', 'esx' }) do
		local a = CTQ.Adapters[name]
		if a and a.detect and a.detect() then return name, a end
	end
	return 'standalone', CTQ.Adapters.standalone
end

local function execute(cmd)
	local action = cmd.action or ''

	-- PROFILE is special: it returns structured data rather than a status, so it
	-- POSTs the built profile to /agent/profile and reports completion.
	if action == 'PROFILE' then
		if not activeAdapter.getProfile then return 'FAILED', 'profiles not supported' end
		local ok, profile = pcall(activeAdapter.getProfile, cmd.target)
		if not ok or not profile then return 'FAILED', 'could not build profile' end
		CTQ.post('/agent/profile', { identifier = cmd.target, profile = profile })
		return 'DONE', 'profile sent'
	end

	-- RESTART (scheduled restarts, job 2): broadcast then quit. A process manager
	-- (txAdmin / pterodactyl / systemd) is expected to bring the server back up.
	if action == 'RESTART' then
		TriggerClientEvent('chat:addMessage', -1, { color = { 255, 80, 80 }, args = { '[Server]', 'The server is restarting now.' } })
		CTQ.warn('scheduled restart requested by dashboard — quitting in 2s')
		SetTimeout(2000, function() ExecuteCommand('quit Scheduled restart (CARTIQO)') end)
		return 'DONE', 'restarting'
	end

	-- A MESSAGE addressed to "all"/"*" is a server-wide broadcast (used by the
	-- scheduled-restart warning) rather than a whisper to one player.
	if action == 'MESSAGE' and (cmd.target == 'all' or cmd.target == '*') then
		TriggerClientEvent('chat:addMessage', -1, { color = { 88, 101, 242 }, args = { '[Server]', cmd.reason or '' } })
		return 'DONE', 'broadcast'
	end

	local fn = activeAdapter[action:lower()]
	if not fn then return 'FAILED', 'unsupported action' end
	local ok, message = fn(cmd.target, cmd.reason, cmd.durationMs)
	return ok and 'DONE' or 'FAILED', message or (ok and 'ok' or 'failed')
end

-- Server-console diagnostics: `ctqbridge diagnostics` prints the detected
-- framework, database, ban store + column mapping, and live counts — the fast
-- way to confirm a first-run setup. Restricted to the console / ACE.
RegisterCommand('ctqbridge', function(source, args)
	if source ~= 0 then return end -- console only
	local sub = (args[1] or 'diagnostics'):lower()
	if sub ~= 'diagnostics' and sub ~= 'diag' then
		print('[CTQBridge] usage: ctqbridge diagnostics')
		return
	end
	print('================ CTQBridge diagnostics ================')
	if not activeAdapter then
		print('  status   : starting up — try again in a moment')
		print('=======================================================')
		return
	end
	print(('  framework: %s'):format(activeName))
	print(('  database : %s'):format(Db.kind or 'none (JSON file)'))
	print(('  ban store: %s'):format(Bans.mode or 'uninitialised'))
	if Bans.mode == 'sql' and Bans.schema then
		print(('  ban table: %s'):format(Bans.schema.table))
		local mapped = {}
		for field, col in pairs(Bans.schema.col) do if col then mapped[#mapped + 1] = ('%s→%s'):format(field, col) end end
		table.sort(mapped)
		print(('  columns  : %s'):format(table.concat(mapped, ', ')))
		print(('  id cols  : %s'):format(table.concat(Bans.schema.idCols, ', ')))
	end
	print(('  version  : %s'):format(GetResourceMetadata(GetCurrentResourceName(), 'version', 0) or '?'))
	print(('  endpoint : %s'):format(Config.Endpoint))
	print(('  key set  : %s'):format(Config.ApiKey ~= 'ctq_REPLACE_ME' and 'yes' or 'NO — set it from the dashboard'))
	local wl = CTQ.config and CTQ.config.whitelist
	if wl and wl.enabled then
		print(('  whitelist: ON · mode=%s · %s allowed role(s)'):format(wl.mode or 'roles', #(wl.allowedRoleIds or {})))
	else
		print(('  whitelist: %s'):format(CTQ.config and 'off' or 'off (config not synced yet)'))
	end
	-- Offline-fallback diagnostics (job 12).
	if Whitelist and Whitelist.cacheAge then
		local age = Whitelist.cacheAge()
		print(('  wl cache : %s'):format(age and (age .. 's old') or 'empty (no rules cached yet)'))
	end
	print(('  fallback : %s (when API unreachable)'):format((Config.FallbackBehaviour or 'allow')))
	local okP, players = pcall(activeAdapter.getPlayers)
	print(('  players  : %s online'):format(okP and #players or '?'))
	print(('  bans     : %s cached'):format(#(Bans.cached() or {})))
	print('=======================================================')
end, true)

local syncCount = 0

-- One long-poll sync round. The dashboard holds the request open for up to ~4s
-- (returning 204 when nothing's queued), so we reconnect promptly after each
-- response for near-real-time command delivery (job 11). `cb(promptly)` tells the
-- loop whether to reconnect immediately (success/204) or back off (error).
local function syncRound(cb)
	syncCount = syncCount + 1
	local includeBans = (syncCount % Config.BanSyncEvery) == 1 -- first sync + every Nth

	local body = {
		online = true,
		resourceVersion = GetResourceMetadata(GetCurrentResourceName(), 'version', 0),
		players = activeAdapter.getPlayers(),
	}
	if includeBans then body.bans = activeAdapter.getBans() end

	CTQ.post('/sync', body, function(ok, data)
		-- A non-2xx (or no connection) → back off so a web outage can't hammer.
		if not ok then return cb(false) end

		-- 2xx with a body: apply config + run commands. 204 (no body) → just loop.
		if data then
			CTQ.config = data.config or CTQ.config
			-- Feed the offline whitelist cache (job 12) so connect decisions survive
			-- a later web outage.
			if Whitelist and Whitelist.updateCache then Whitelist.updateCache(CTQ.config and CTQ.config.whitelist) end
			if data.commands then
				local results = {}
				for _, cmd in ipairs(data.commands) do
					CTQ.log(('executing %s on %s'):format(cmd.action, cmd.target))
					local status, message = execute(cmd)
					results[#results + 1] = { id = cmd.id, status = status, message = message }
				end
				if #results > 0 then CTQ.post('/result', { results = results }) end
			end
		end
		cb(true) -- reconnect promptly (the server already held the connection)
	end)
end

-- Single connect gate: ban enforcement (across every identifier + token) then
-- the dashboard whitelist. One handler so the deferral is resolved exactly once.
AddEventHandler('playerConnecting', function(_name, _setKick, deferrals)
	local src = source
	deferrals.defer()
	Wait(0)

	-- 1) Bans (our store, alongside the framework's own enforcement).
	if Config.Ban and Config.Ban.EnforceOnConnect ~= false then
		local ban = Bans.check(Util.identifierList(src), Util.tokens(src))
		if ban then
			local until_ = ban.expires and (' (until %s)'):format(ban.expires) or ''
			deferrals.done(('Banned: %s%s'):format(ban.reason or 'No reason', until_))
			return
		end
	end

	-- 2) Whitelist. CTQCore owns the connect QUEUE (it calls CheckWhitelist itself),
	-- so when it's running CTQBridge does not gate the connection here — it only
	-- provides the decision. Otherwise CTQBridge enforces a simple allow/deny.
	local ctqcoreRunning = GetResourceState('CTQCore') == 'started'
	local wl = CTQ.config and CTQ.config.whitelist
	if not ctqcoreRunning and Config.Whitelist and Config.Whitelist.Enforce ~= false and wl and wl.enabled then
		deferrals.update('Checking whitelist…')
		local decision = Whitelist.checkConnecting(src)
		if decision and not decision.allowed then
			deferrals.done(decision.message or 'You are not whitelisted on this server.')
			return
		end
	end

	deferrals.done()
end)

CreateThread(function()
	Wait(2000) -- let other resources (framework, mysql) start first

	Db.detect()
	Bans.init()
	Bans.refreshCache()

	activeName, activeAdapter = selectAdapter()

	-- Publish shared state so exports.lua / whitelist.lua (other files, and other
	-- resources like CTQCore) can read it.
	CTQ.framework = activeName
	CTQ.adapter = activeAdapter
	CTQ.ready = true

	print(('[CTQBridge] ready — framework: %s · db: %s'):format(activeName, Db.kind or 'none (JSON)'))
	TriggerEvent('CTQBridge:ready', { framework = activeName, db = Db.kind })

	if Config.ApiKey == 'ctq_REPLACE_ME' or Config.Endpoint:find('your%-dashboard') then
		CTQ.warn('config.lua still has placeholder Endpoint/ApiKey — set them from the dashboard.')
	end

	-- Refresh the ban-list cache on its own cadence (independent of sync).
	CreateThread(function()
		while true do
			Wait(Config.BanCacheRefresh or 15000)
			local ok, err = pcall(Bans.refreshCache)
			if not ok then CTQ.warn('ban cache refresh failed: ' .. tostring(err)) end
		end
	end)

	-- Self-scheduling long-poll driver: reconnect immediately after a held
	-- response/204, back off on errors. Replaces the old fixed-interval loop.
	local function loop()
		local ok, err = pcall(syncRound, function(promptly)
			local delay = promptly and (Config.SyncMinDelay or 250) or (Config.SyncBackoff or 3000)
			SetTimeout(delay, loop)
		end)
		if not ok then
			CTQ.warn('sync error: ' .. tostring(err))
			SetTimeout(Config.SyncBackoff or 3000, loop)
		end
	end
	loop()
end)

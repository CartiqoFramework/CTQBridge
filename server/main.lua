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
	-- PROFILE is special: it returns structured data rather than a status, so it
	-- POSTs the built profile to /agent/profile and reports completion.
	if (cmd.action or '') == 'PROFILE' then
		if not activeAdapter.getProfile then return 'FAILED', 'profiles not supported' end
		local ok, profile = pcall(activeAdapter.getProfile, cmd.target)
		if not ok or not profile then return 'FAILED', 'could not build profile' end
		CTQ.post('/agent/profile', { identifier = cmd.target, profile = profile })
		return 'DONE', 'profile sent'
	end

	local fn = activeAdapter[(cmd.action or ''):lower()]
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
	print(('  endpoint : %s'):format(Config.Endpoint))
	print(('  key set  : %s'):format(Config.ApiKey ~= 'ctq_REPLACE_ME' and 'yes' or 'NO — set it from the dashboard'))
	local okP, players = pcall(activeAdapter.getPlayers)
	print(('  players  : %s online'):format(okP and #players or '?'))
	print(('  bans     : %s cached'):format(#(Bans.cached() or {})))
	print('=======================================================')
end, true)

local syncCount = 0

local function syncOnce()
	syncCount = syncCount + 1
	local includeBans = (syncCount % Config.BanSyncEvery) == 1 -- first sync + every Nth

	local body = { online = true, players = activeAdapter.getPlayers() }
	if includeBans then body.bans = activeAdapter.getBans() end

	CTQ.post('/sync', body, function(ok, data)
		if not ok or not data or not data.commands then return end
		local results = {}
		for _, cmd in ipairs(data.commands) do
			CTQ.log(('executing %s on %s'):format(cmd.action, cmd.target))
			local status, message = execute(cmd)
			results[#results + 1] = { id = cmd.id, status = status, message = message }
		end
		if #results > 0 then CTQ.post('/result', { results = results }) end
	end)
end

-- Universal ban enforcement on connect — checks our ban store across every
-- identifier + token, regardless of framework. Runs alongside (not instead of)
-- the framework's own enforcement.
AddEventHandler('playerConnecting', function(_name, _setKick, deferrals)
	if not (Config.Ban and Config.Ban.EnforceOnConnect ~= false) then return end
	local src = source
	deferrals.defer()
	Wait(0)
	local ban = Bans.check(Util.identifierList(src), Util.tokens(src))
	if ban then
		local until_ = ban.expires and (' (until %s)'):format(ban.expires) or ''
		deferrals.done(('Banned: %s%s'):format(ban.reason or 'No reason', until_))
		return
	end
	deferrals.done()
end)

CreateThread(function()
	Wait(2000) -- let other resources (framework, mysql) start first

	Db.detect()
	Bans.init()
	Bans.refreshCache()

	activeName, activeAdapter = selectAdapter()
	print(('[CTQBridge] ready — framework: %s · db: %s'):format(activeName, Db.kind or 'none (JSON)'))

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

	while true do
		local ok, err = pcall(syncOnce)
		if not ok then CTQ.warn('sync error: ' .. tostring(err)) end
		Wait(Config.SyncInterval)
	end
end)

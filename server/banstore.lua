-- Unified ban store. Picks the best backend for the server it runs on:
--   • an existing SQL `bans` table (any common schema — columns auto-detected),
--   • a dedicated `ctqbridge_bans` table it creates when none exists, or
--   • a local JSON file (standalone / no database).
-- Bans are written across every identifier the player has, so they can't rejoin
-- on another id. The same API is used by every framework adapter.
CTQ = CTQ or {}
Bans = { mode = nil, schema = nil, _cache = {} }

local JSON_FILE = 'data/bans.json'

-- ── Column auto-detection ───────────────────────────────────────────────────
local CANDIDATES = {
	license    = { 'license' },
	discord    = { 'discord' },
	fivem      = { 'fivem' },
	steam      = { 'steam' },
	ip         = { 'ip' },
	identifier = { 'identifier' },
	name       = { 'name', 'playername', 'player_name', 'username' },
	reason     = { 'reason', 'message' },
	expire     = { 'expire', 'expires', 'expiry', 'expiration', 'until', 'expire_date', 'banned_until' },
	bannedBy   = { 'bannedby', 'banned_by', 'banner', 'admin', 'author' },
	tokens     = { 'tokens' },
	created    = { 'created', 'created_at', 'timestamp', 'time', 'date' },
}
local ID_FIELDS = { 'license', 'discord', 'fivem', 'steam', 'ip', 'identifier' }

local function pickColumn(field, present, override)
	if override and override ~= 'auto' then return override end
	for _, cand in ipairs(CANDIDATES[field] or {}) do
		if present[cand] then return present[cand] end -- returns the real-cased name
	end
	return nil
end

-- Build a schema map for a table; returns nil if it has no identifier column
-- (i.e. it isn't actually a ban table).
local function detectSchema(table)
	local cols = Db.columns(table)
	if #cols == 0 then return nil end
	local present = {}
	for _, c in ipairs(cols) do present[c:lower()] = c end

	local cfg = (Config.Ban and Config.Ban.Columns) or {}
	local schema = { table = table, col = {}, idCols = {} }
	for field in pairs(CANDIDATES) do
		schema.col[field] = pickColumn(field, present, cfg[field])
	end
	for _, f in ipairs(ID_FIELDS) do
		if schema.col[f] then schema.idCols[#schema.idCols + 1] = schema.col[f] end
	end
	if #schema.idCols == 0 then return nil end
	return schema
end

local CREATE_TABLE = [[
CREATE TABLE IF NOT EXISTS `ctqbridge_bans` (
  `id` INT NOT NULL AUTO_INCREMENT,
  `name` VARCHAR(255) NULL,
  `identifier` VARCHAR(255) NULL,
  `license` VARCHAR(255) NULL,
  `discord` VARCHAR(255) NULL,
  `fivem` VARCHAR(255) NULL,
  `steam` VARCHAR(255) NULL,
  `ip` VARCHAR(255) NULL,
  `tokens` TEXT NULL,
  `reason` TEXT NULL,
  `expire` INT NOT NULL DEFAULT 0,
  `bannedby` VARCHAR(255) NULL,
  `created` INT NULL,
  PRIMARY KEY (`id`),
  INDEX `idx_license` (`license`),
  INDEX `idx_discord` (`discord`),
  INDEX `idx_identifier` (`identifier`)
) DEFAULT CHARSET = utf8mb4;
]]

-- ── Init: choose a backend ──────────────────────────────────────────────────
function Bans.init()
	local store = (Config.Ban and Config.Ban.Store) or 'auto'
	local wantSql = store == 'sql' or store == 'framework' or store == 'auto'

	if wantSql and Db.available() then
		local forced = Config.Ban.Table
		if forced and forced ~= 'auto' then
			-- Use the explicitly configured table.
			Bans.schema = detectSchema(forced)
			if not Bans.schema then CTQ.warn(('configured ban table `%s` not found or has no id column'):format(forced)) end
		else
			-- Prefer an existing `bans` table; otherwise create/use ctqbridge_bans.
			if Db.tableExists('bans') then
				Bans.schema = detectSchema('bans')
			end
			if not Bans.schema and (Config.Ban.AutoCreate ~= false) then
				Db.execute(CREATE_TABLE)
				Wait(250)
				Bans.schema = detectSchema('ctqbridge_bans')
			end
		end
		if Bans.schema then
			Bans.mode = 'sql'
			print(('[CTQBridge] ban store: SQL table `%s`'):format(Bans.schema.table))
			return
		end
		CTQ.warn('SQL available but no usable ban table — falling back to JSON.')
	end

	Bans.mode = 'json'
	print('[CTQBridge] ban store: JSON file (data/bans.json)')
end

-- ── JSON backend ────────────────────────────────────────────────────────────
local function jsonLoad()
	local raw = LoadResourceFile(GetCurrentResourceName(), JSON_FILE)
	if not raw or #raw == 0 then return {} end
	local ok, data = pcall(json.decode, raw)
	return (ok and data) or {}
end
local function jsonSave(list)
	SaveResourceFile(GetCurrentResourceName(), JSON_FILE, json.encode(list), -1)
end

-- ── Public API ──────────────────────────────────────────────────────────────
-- ids: map of { license=, discord=, … } (full identifiers). name/reason strings.
-- expireUnix: unix seconds or nil (permanent). tokens: array.
function Bans.add(ids, name, reason, expireUnix, bannedBy, tokens)
	bannedBy = bannedBy or 'CARTIQO Dashboard'
	if Bans.mode == 'sql' then
		local s = Bans.schema
		local cols, vals, params = {}, {}, {}
		local function put(col, value)
			if col and value ~= nil then
				cols[#cols + 1] = ('`%s`'):format(col)
				vals[#vals + 1] = '?'
				params[#params + 1] = value
			end
		end
		put(s.col.identifier, ids.license or ids.identifier or ids.fivem or ids.discord)
		put(s.col.license, ids.license)
		put(s.col.discord, ids.discord)
		put(s.col.fivem, ids.fivem)
		put(s.col.steam, ids.steam)
		put(s.col.ip, ids.ip)
		put(s.col.name, name)
		put(s.col.reason, reason)
		put(s.col.expire, expireUnix or 0)
		put(s.col.bannedBy, bannedBy)
		if s.col.tokens and tokens then put(s.col.tokens, json.encode(tokens)) end
		if s.col.created then put(s.col.created, os.time()) end
		if #cols == 0 then return false end
		Db.execute(('INSERT INTO `%s` (%s) VALUES (%s)'):format(s.table, table.concat(cols, ', '), table.concat(vals, ', ')), params)
		return true
	end

	-- JSON
	local list = jsonLoad()
	local idList = {}
	for _, v in pairs(ids) do idList[#idList + 1] = v end
	list[#list + 1] = {
		identifiers = idList,
		tokens = tokens or {},
		name = name,
		reason = reason,
		expire = expireUnix or 0,
		bannedBy = bannedBy,
		created = os.time(),
	}
	jsonSave(list)
	return true
end

-- Remove every ban matching `identifier` (by full or bare value, any id column).
function Bans.remove(identifier)
	local bare = identifier:gsub('^%a+:', '')
	if Bans.mode == 'sql' then
		local s = Bans.schema
		local where, params = {}, {}
		for _, col in ipairs(s.idCols) do
			where[#where + 1] = ('`%s` = ? OR `%s` = ?'):format(col, col)
			params[#params + 1] = identifier
			params[#params + 1] = bare
		end
		Db.execute(('DELETE FROM `%s` WHERE %s'):format(s.table, table.concat(where, ' OR ')), params)
		return true
	end

	local list, kept = jsonLoad(), {}
	for _, b in ipairs(list) do
		local match = false
		for _, id in ipairs(b.identifiers or {}) do
			if id == identifier or id:gsub('^%a+:', '') == bare then match = true break end
		end
		if not match then kept[#kept + 1] = b end
	end
	jsonSave(kept)
	return true
end

local function rowToBan(s, r)
	local ident
	for _, f in ipairs(ID_FIELDS) do
		local c = s.col[f]
		if c and r[c] and r[c] ~= '' then ident = r[c] break end
	end
	local expire = s.col.expire and tonumber(r[s.col.expire]) or 0
	return {
		identifier = ident,
		playerName = s.col.name and r[s.col.name] or nil,
		reason = s.col.reason and r[s.col.reason] or nil,
		expires = Util.toIso(expire),
		bannedBy = s.col.bannedBy and r[s.col.bannedBy] or nil,
		_expireUnix = expire,
	}
end

-- All active (non-expired) bans, shaped for the dashboard. Synchronous.
function Bans.list()
	if Bans.mode == 'sql' then
		local s = Bans.schema
		local rows = Db.await(('SELECT * FROM `%s`'):format(s.table))
		local out = {}
		for _, r in ipairs(rows or {}) do
			local ban = rowToBan(s, r)
			if not Util.isExpired(ban._expireUnix) then
				ban._expireUnix = nil
				out[#out + 1] = ban
			end
		end
		return out
	end

	local out = {}
	for _, b in ipairs(jsonLoad()) do
		if not Util.isExpired(b.expire) then
			out[#out + 1] = { identifier = (b.identifiers or {})[1], playerName = b.name, reason = b.reason, expires = Util.toIso(b.expire), bannedBy = b.bannedBy }
		end
	end
	return out
end

-- Is a connecting player (identifiers + tokens) banned? Returns the ban or nil.
-- Synchronous — safe inside connect deferrals.
function Bans.check(identifiers, tokens)
	if Bans.mode == 'sql' then
		local s = Bans.schema
		-- Match any id column against any of the player's identifiers (full + bare).
		local values, seen = {}, {}
		for _, id in ipairs(identifiers) do
			for _, v in ipairs({ id, id:gsub('^%a+:', '') }) do
				if not seen[v] then seen[v] = true values[#values + 1] = v end
			end
		end
		if #values == 0 then return nil end
		local placeholders = ('?,'):rep(#values):sub(1, -2)
		local where = {}
		for _, col in ipairs(s.idCols) do
			where[#where + 1] = ('`%s` IN (%s)'):format(col, placeholders)
		end
		-- Repeat the value list once per id column.
		local params = {}
		for _ = 1, #s.idCols do for _, v in ipairs(values) do params[#params + 1] = v end end
		local rows = Db.await(('SELECT * FROM `%s` WHERE %s'):format(s.table, table.concat(where, ' OR ')), params)
		for _, r in ipairs(rows or {}) do
			local ban = rowToBan(s, r)
			if not Util.isExpired(ban._expireUnix) then return ban end
		end
		-- Token match (only when the table stores tokens).
		if s.col.tokens and tokens and #tokens > 0 then
			for _, tok in ipairs(tokens) do
				local tr = Db.await(('SELECT * FROM `%s` WHERE `%s` LIKE ? LIMIT 1'):format(s.table, s.col.tokens), { '%' .. tok .. '%' })
				if tr and tr[1] then
					local ban = rowToBan(s, tr[1])
					if not Util.isExpired(ban._expireUnix) then return ban end
				end
			end
		end
		return nil
	end

	-- JSON
	local idset = {}
	for _, id in ipairs(identifiers) do idset[id] = true idset[id:gsub('^%a+:', '')] = true end
	local tokset = {}
	for _, t in ipairs(tokens or {}) do tokset[t] = true end
	for _, b in ipairs(jsonLoad()) do
		if not Util.isExpired(b.expire) then
			for _, id in ipairs(b.identifiers or {}) do
				if idset[id] or idset[id:gsub('^%a+:', '')] then return b end
			end
			for _, t in ipairs(b.tokens or {}) do
				if tokset[t] then return b end
			end
		end
	end
	return nil
end

-- Cached list for the sync loop (refreshed periodically; avoids a query/sync).
function Bans.cached() return Bans._cache end
function Bans.refreshCache() Bans._cache = Bans.list() end

return Bans

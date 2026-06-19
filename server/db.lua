-- Database abstraction. Supports the two MySQL resources used across the FiveM
-- ecosystem — oxmysql (modern) and mysql-async / ghmattimysql (legacy) — behind
-- one API: Db.query / Db.insert (callback) and Db.await (synchronous, for use
-- inside threads such as connect deferrals). Db.available() reports if any DB is
-- usable. All calls are safe no-ops when no DB resource is running.
CTQ = CTQ or {}
Db = { kind = nil }

local function started(res)
	return GetResourceState(res) == 'started'
end

-- Detect which MySQL resource to use, honouring Config.Ban.Sql.
function Db.detect()
	local forced = Config.Ban and Config.Ban.Sql or 'auto'
	if forced == 'oxmysql' then Db.kind = started('oxmysql') and 'oxmysql' or nil
	elseif forced == 'mysql-async' then Db.kind = started('mysql-async') and 'mysql-async' or nil
	else
		if started('oxmysql') then Db.kind = 'oxmysql'
		elseif started('mysql-async') then Db.kind = 'mysql-async'
		elseif started('ghmattimysql') then Db.kind = 'mysql-async' -- exposes the mysql-async export
		else Db.kind = nil end
	end
	return Db.kind
end

function Db.available()
	return Db.kind ~= nil
end

-- Run a SELECT; cb receives an array of rows (or {} on failure).
function Db.query(sql, params, cb)
	if Db.kind == 'oxmysql' then
		exports.oxmysql:query(sql, params or {}, function(rows) cb(rows or {}) end)
	elseif Db.kind == 'mysql-async' then
		exports['mysql-async']:mysql_fetch_all(sql, params or {}, function(rows) cb(rows or {}) end)
	else
		cb({})
	end
end

-- Run an INSERT/UPDATE/DELETE; cb (optional) receives affected/insertId.
function Db.execute(sql, params, cb)
	if Db.kind == 'oxmysql' then
		exports.oxmysql:execute(sql, params or {}, function(res) if cb then cb(res) end end)
	elseif Db.kind == 'mysql-async' then
		exports['mysql-async']:mysql_execute(sql, params or {}, function(res) if cb then cb(res) end end)
	elseif cb then
		cb(nil)
	end
end

-- Synchronous query for use inside a thread/coroutine (e.g. connect deferrals).
-- Returns rows directly. Falls back to {} if no DB.
function Db.await(sql, params)
	if not Db.available() then return {} end
	local p = promise.new()
	Db.query(sql, params, function(rows) p:resolve(rows) end)
	return Citizen.Await(p)
end

-- Does a table exist in the current database?
function Db.tableExists(name)
	local rows = Db.await(
		'SELECT 1 FROM information_schema.tables WHERE table_schema = DATABASE() AND table_name = ? LIMIT 1',
		{ name }
	)
	return rows and #rows > 0
end

-- Column names of a table (lowercased), or {} if none/missing.
function Db.columns(name)
	local rows = Db.await(
		'SELECT COLUMN_NAME AS c FROM information_schema.columns WHERE table_schema = DATABASE() AND table_name = ?',
		{ name }
	)
	local out = {}
	for _, r in ipairs(rows or {}) do
		local c = r.c or r.COLUMN_NAME
		if c then out[#out + 1] = tostring(c) end
	end
	return out
end

return Db

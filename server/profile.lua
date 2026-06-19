-- Player profile builder — surfaces general info (name, money, job, vehicles,
-- properties) for a player. Reads the framework object when the player is online
-- (most reliable) and falls back to the database when offline. Vehicle/property
-- tables vary by server, so those lookups are schema-guarded best-effort and
-- simply return nothing when a table/column isn't present.
CTQ = CTQ or {}
Profile = {}

local function decode(s)
	if type(s) == 'table' then return s end
	if type(s) ~= 'string' then return nil end
	local ok, v = pcall(json.decode, s)
	return ok and v or nil
end
Profile.decode = decode

local function colSet(tbl)
	local out = {}
	for _, c in ipairs(Db.columns(tbl)) do out[c:lower()] = c end
	return out
end

-- ── Owned vehicles (QBCore: player_vehicles · ESX: owned_vehicles) ───────────
local VEH_TABLES = {
	{ table = 'player_vehicles', owner = 'citizenid', key = 'citizenid', model = 'vehicle' },
	{ table = 'owned_vehicles', owner = 'owner', key = 'identifier', model = 'type' },
}

-- keys = { citizenid = ?, identifier = ? }
function Profile.vehicles(keys)
	local out = {}
	if not Db.available() then return out end
	for _, def in ipairs(VEH_TABLES) do
		local val = keys[def.key]
		if val and Db.tableExists(def.table) then
			local cols = colSet(def.table)
			local ownerCol = cols[def.owner]
			if ownerCol then
				local rows = Db.await(('SELECT * FROM `%s` WHERE `%s` = ?'):format(def.table, ownerCol), { val })
				for _, r in ipairs(rows or {}) do
					out[#out + 1] = {
						plate = r[cols['plate']] or r.plate,
						model = (cols[def.model] and r[cols[def.model]]) or 'vehicle',
						garage = r[cols['garage']] or nil,
					}
				end
			end
		end
	end
	return out
end

-- ── Properties / houses (best-effort across common housing scripts) ──────────
function Profile.properties(keys)
	local out = {}
	if not Db.available() then return out end
	for _, tbl in ipairs({ 'player_houses', 'properties', 'owned_properties', 'player_apartments' }) do
		if Db.tableExists(tbl) then
			local cols = colSet(tbl)
			local ownerCol = (keys.citizenid and cols['citizenid']) or cols['owner'] or cols['identifier'] or cols['citizenid']
			local ownerVal = (cols['citizenid'] and keys.citizenid) or keys.identifier or keys.citizenid
			local labelCol = cols['house'] or cols['name'] or cols['label'] or cols['property_name'] or cols['property']
			if ownerCol and ownerVal then
				local rows = Db.await(('SELECT * FROM `%s` WHERE `%s` = ?'):format(tbl, ownerCol), { ownerVal })
				for _, r in ipairs(rows or {}) do
					out[#out + 1] = { label = (labelCol and r[labelCol]) or tbl }
				end
			end
		end
	end
	return out
end

-- ── QBCore / Qbox shared profile (online PlayerData or offline `players` row) ─
function Profile.qbStyle(target, pd)
	local citizenid, name, money, job, gang, phone

	if pd then
		citizenid = pd.citizenid
		local ci = pd.charinfo
		name = (ci and ci.firstname) and (ci.firstname .. ' ' .. (ci.lastname or '')) or pd.name
		money = pd.money
		if pd.job then
			job = { name = pd.job.name, label = pd.job.label, onDuty = pd.job.onduty,
				grade = pd.job.grade and (pd.job.grade.name or pd.job.grade.level) or nil }
		end
		if pd.gang then gang = { name = pd.gang.name, label = pd.gang.label } end
		phone = ci and ci.phone
	elseif Db.available() and Db.tableExists('players') then
		local bare = target:gsub('^%a+:', '')
		local rows = Db.await('SELECT * FROM `players` WHERE `license` = ? OR `license` = ? OR `citizenid` = ? LIMIT 1', { target, bare, bare })
		local r = rows and rows[1]
		if r then
			citizenid = r.citizenid
			local ci = decode(r.charinfo)
			name = (ci and ci.firstname) and (ci.firstname .. ' ' .. (ci.lastname or '')) or r.name
			money = decode(r.money)
			local j = decode(r.job)
			if j then
				job = { name = j.name, label = j.label, onDuty = j.onduty,
					grade = (type(j.grade) == 'table' and (j.grade.name or j.grade.level)) or j.grade }
			end
			phone = ci and ci.phone
		end
	end

	return {
		identifier = target,
		name = name,
		account = citizenid,
		job = job,
		gang = gang,
		phone = phone,
		money = money and { cash = money.cash, bank = money.bank, crypto = money.crypto } or nil,
		vehicles = Profile.vehicles({ citizenid = citizenid }),
		properties = Profile.properties({ citizenid = citizenid }),
	}
end

-- ── ESX profile (online xPlayer or offline `users` row) ──────────────────────
function Profile.esx(target, xPlayer)
	local identifier, name, money, job

	if xPlayer then
		identifier = (xPlayer.getIdentifier and xPlayer.getIdentifier()) or xPlayer.identifier
		name = xPlayer.getName and xPlayer.getName() or nil
		local cash = xPlayer.getMoney and xPlayer.getMoney() or 0
		local bankAcc = xPlayer.getAccount and xPlayer.getAccount('bank') or nil
		local blackAcc = xPlayer.getAccount and xPlayer.getAccount('black_money') or nil
		money = { cash = cash, bank = bankAcc and bankAcc.money or 0, blackMoney = blackAcc and blackAcc.money or nil }
		if xPlayer.job then
			job = { name = xPlayer.job.name, label = xPlayer.job.label, grade = xPlayer.job.grade_name or xPlayer.job.grade }
		end
	elseif Db.available() and Db.tableExists('users') then
		local bare = target:gsub('^%a+:', '')
		local rows = Db.await('SELECT * FROM `users` WHERE `identifier` = ? OR `identifier` = ? LIMIT 1', { target, bare })
		local r = rows and rows[1]
		if r then
			identifier = r.identifier
			local full = ((r.firstname or '') .. ' ' .. (r.lastname or '')):gsub('^%s+', ''):gsub('%s+$', '')
			name = full ~= '' and full or nil
			local acc = decode(r.accounts)
			if acc then
				money = { cash = acc.money, bank = acc.bank, blackMoney = acc.black_money }
			else
				money = { cash = r.money, bank = r.bank, blackMoney = r.black_money }
			end
			if r.job then job = { name = r.job, label = r.job, grade = r.job_grade } end
		end
	end

	identifier = identifier or target
	return {
		identifier = target,
		name = name,
		account = identifier,
		job = job,
		money = money,
		vehicles = Profile.vehicles({ identifier = identifier }),
		properties = Profile.properties({ identifier = identifier }),
	}
end

return Profile

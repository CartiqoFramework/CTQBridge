fx_version 'cerulean'
game 'gta5'

name 'CTQBridge'
author 'CARTIQO'
description 'Connects a FiveM server to the CARTIQO dashboard — moderation, player profiles, role whitelist, in-game reports, scheduled restarts, health alerts, and an SDK for CTQCore.'
version '1.3.0'

-- Server-only resource: it talks HTTP to the CARTIQO dashboard and executes
-- moderation commands against the local framework / database. No client scripts.
server_scripts {
	'config.lua',
	'server/http.lua',
	'server/util.lua',
	'server/db.lua',
	'server/banstore.lua',
	'server/actions.lua',
	'server/profile.lua',
	'server/whitelist.lua',
	'server/report.lua',
	'server/adapters/standalone.lua',
	'server/adapters/qbcore.lua',
	'server/adapters/qbox.lua',
	'server/adapters/esx.lua',
	'server/main.lua',
	'server/exports.lua',
}

-- Standalone (no-DB) ban storage lives here.
files {
	'data/bans.json',
}

-- oxmysql / mysql-async are optional — CTQBridge auto-detects whichever is
-- present and falls back to the JSON file when neither is. No hard dependency
-- so the resource starts on any server (OneSync on or off).

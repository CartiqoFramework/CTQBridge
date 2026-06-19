Config = {}

-- ── Connection ──────────────────────────────────────────────────────────────
-- Copy both of these from the CARTIQO dashboard → FiveM page.
-- Endpoint is the base agent URL (no trailing slash).
Config.Endpoint = 'https://your-dashboard.example.com/api/fivem/agent'
Config.ApiKey   = 'ctq_REPLACE_ME'

-- ── Framework ───────────────────────────────────────────────────────────────
-- 'auto' detects QBCore / Qbox / ESX from started resources, else 'standalone'.
-- Force a specific one if auto-detection guesses wrong:
--   'qbcore' | 'qbox' | 'esx' | 'standalone'
Config.Framework = 'auto'

-- ── Timing ──────────────────────────────────────────────────────────────────
Config.SyncInterval = 5000  -- ms between sync calls (roster + command pull)
Config.BanSyncEvery = 6     -- include the ban list every Nth sync (saves bandwidth)
Config.BanCacheRefresh = 15000 -- ms between ban-list refreshes from the DB

-- ── Bans ────────────────────────────────────────────────────────────────────
Config.Ban = {
	-- Where bans are stored:
	--   'auto'      → use an existing SQL `bans` table if found, else auto-create
	--                 one, else fall back to a JSON file. (recommended)
	--   'sql'       → force SQL (uses Table below; auto-created if missing).
	--   'json'      → force the local data/bans.json file.
	--   'framework' → use the framework's own ban command/event when available,
	--                 falling back to SQL/JSON for listing.
	Store = 'auto',

	-- SQL table to read/write. 'auto' picks an existing `bans` table, otherwise
	-- creates and uses `ctqbridge_bans`. Set a name to force a specific table.
	Table = 'auto',

	-- Force the MySQL resource. 'auto' detects oxmysql, then mysql-async.
	--   'auto' | 'oxmysql' | 'mysql-async'
	Sql = 'auto',

	-- Column name overrides. Leave as 'auto' to detect from the table schema.
	-- Only set these if auto-detection logs that it couldn't find a column.
	Columns = {
		identifier = 'auto', -- generic identifier column (ESX-style)
		license    = 'auto',
		discord    = 'auto',
		fivem      = 'auto',
		steam      = 'auto',
		ip         = 'auto',
		name       = 'auto',
		reason     = 'auto',
		expire     = 'auto', -- unix seconds (or 0/NULL for permanent)
		bannedBy   = 'auto',
	},

	-- Ban every identifier + hardware token of the player (not just the one the
	-- admin clicked), so they can't rejoin on another ID. Strongly recommended.
	BanAllIdentifiers = true,
	IncludeTokens     = true, -- also store hardware tokens (best-effort, requires a recent artifact)

	-- Block banned players on connect using our own check, in addition to whatever
	-- the framework already does. Safe to leave on.
	EnforceOnConnect = true,

	-- If no SQL ban table is found and Store='auto', create this one.
	AutoCreate = true,
}

-- ── Behaviour ───────────────────────────────────────────────────────────────
Config.DefaultKickMessage = 'You were removed by a server admin.'
Config.DefaultBanMessage  = 'You are banned from this server.'
Config.Debug = false -- print verbose logs to the server console

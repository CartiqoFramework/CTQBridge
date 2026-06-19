# CTQBridge

> # ⚠️ NOT PRODUCTION-READY — DO NOT USE ON A LIVE SERVER
>
> **CTQBridge is brand new and has _not_ been tested on a real FiveM server.**
> It is published for development, review and early feedback only. The framework
> and database integrations (QBCore / Qbox / ESX / standalone) are **unverified**
> and may behave unexpectedly, corrupt data, or fail to enforce bans correctly.
>
> **Do not run this on a production server.** Use it only on a throwaway test
> server, entirely at your own risk, until it has been properly tested and this
> notice is removed.

Connects a FiveM server to the **CARTIQO dashboard** so server owners can kick,
ban, unban, warn and message players remotely. Requires the **FiveM add-on** on
the guild's CARTIQO subscription.

## How it works

CTQBridge runs entirely server-side and makes **outbound** HTTP requests to the
dashboard — no inbound ports, so it works behind NAT/firewalls. Your FiveM
server stays the source of truth: bans and the player roster live in *your*
database (or `data/bans.json` in standalone mode), never on CARTIQO.

Every few seconds CTQBridge:

1. **POST `/sync`** — reports who's online (and, periodically, your ban list),
   and receives any queued moderation commands.
2. Executes each command against your framework.
3. **POST `/result`** — reports the outcome back to the dashboard.

## Install

1. Copy the `CTQBridge` folder into your server's `resources/` directory.
2. In the CARTIQO dashboard, open your server → **FiveM**, then:
   - Copy the **Endpoint** and click **Generate API key** (copy it — shown once).
3. Edit `config.lua`:
   ```lua
   Config.Endpoint = 'https://<your-dashboard>/api/fivem/agent'
   Config.ApiKey   = 'ctq_...'         -- the generated key
   Config.Framework = 'auto'           -- or 'qbcore' | 'qbox' | 'esx' | 'standalone'
   ```
4. Add `ensure CTQBridge` to your `server.cfg`.
5. Restart the server. The console prints `[CTQBridge] ready — framework: <name>`
   and the dashboard shows the server as **Online** within a few seconds.

## Frameworks & databases

CTQBridge is built to run on **any** server. It auto-detects your framework, your
MySQL resource, and your ban-table layout — and falls back gracefully when any of
them is absent.

| Framework  | Detected resource           | Roster source (with native fallback)        |
| ---------- | --------------------------- | ------------------------------------------- |
| QBCore     | `qb-core` / `qbcore`        | core object → charinfo → account → native   |
| Qbox       | `qbx_core` / `qbx-core`     | `qbx_core` player → charinfo → native       |
| ESX        | `es_extended`               | shared object (legacy/1.1/1.2) → native     |
| Standalone | — (always available)        | native player list                          |

**Database layer** — auto-detects **oxmysql**, then **mysql-async / ghmattimysql**.
No DB at all? CTQBridge stores bans in `data/bans.json` instead. Force a specific
one with `Config.Ban.Sql`.

**Ban storage** (`Config.Ban.Store`, default `auto`):

1. If a `bans` table exists, CTQBridge **reads and writes it**, auto-detecting the
   column names (`expire`/`expires`/`until`, `bannedby`/`banned_by`, `name`/
   `player_name`, etc.) — so your framework's existing bans keep working.
2. If no ban table exists, it creates a dedicated `ctqbridge_bans` table.
3. If there's no database, it uses `data/bans.json`.

Bans are written across **every identifier** the player has (license, license2,
discord, steam, fivem, xbl, live, ip) plus **hardware tokens**, so a banned player
can't rejoin on another ID. Bans are enforced on connect across all of them,
independent of the framework. Override any of this in `config.lua` → `Config.Ban`.

## Security

- The API key authenticates this server to the dashboard. Treat it like a
  password; regenerate it from the dashboard if leaked (the old key stops working
  immediately).
- CTQBridge only ever *sends* data out and *pulls* commands addressed to your
  server — the dashboard cannot reach into your server directly.

## Player profiles

From the dashboard you can open a player's profile to see their **name, money
(cash/bank/crypto/black money), job & gang, owned vehicles and properties**.
CTQBridge reads this from the framework when the player is online, or from the
database (`players` / `users`, `player_vehicles` / `owned_vehicles`, common
housing tables) when offline. Money and job are unavailable on standalone
servers; vehicle/property lookups are best-effort and depend on your tables.

## Diagnostics

Run this in the **server console** (or txAdmin live console) to confirm a setup:

```
ctqbridge diagnostics
```

It prints the detected framework, the database resource, the chosen ban store +
its auto-detected table/column mapping, whether the API key is set, and live
player/ban counts.

See [`../CTQBridge-API.md`](../CTQBridge-API.md) for the full request/response
contract.

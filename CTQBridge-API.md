# CTQBridge ↔ CARTIQO agent API

The contract between the **CTQBridge** FiveM resource and the CARTIQO dashboard.
Implemented server-side in `web/src/app/api/fivem/agent/*`.

- **Base URL:** `https://<dashboard>/api/fivem/agent`
- **Auth:** `Authorization: Bearer <apiKey>` on every request. The key is
  generated per server in the dashboard and stored only as a SHA-256 hash.
- **Transport:** polling. CTQBridge initiates everything (outbound only).
- `401` = bad/missing key, `400` = malformed body, `2xx` = ok.

---

## `POST /sync`

Heartbeat + command pull. Called every `Config.SyncInterval` ms (default 5s).

**Request body**

```jsonc
{
  "online": true,
  "players": [
    {
      "identifier": "license:abc123",  // required — used as the command target
      "serverId": 12,                   // optional — in-game id (instant kicks)
      "name": "PlayerName",
      "discordId": "1234567890",        // optional
      "ping": 42                         // optional
    }
  ],
  // Optional — send periodically (every Config.BanSyncEvery syncs) to keep the
  // dashboard ban list fresh. Omit to leave the last reported list unchanged.
  "bans": [
    {
      "identifier": "license:abc123",
      "playerName": "PlayerName",
      "reason": "Cheating",
      "expires": "2026-07-01T00:00:00Z",  // ISO 8601; omit = permanent
      "bannedBy": "CARTIQO Dashboard"
    }
  ]
}
```

The dashboard stores this as a render cache (`FivemServer.snapshot`) and marks
the server online (`lastSeenAt` now).

**Response**

```jsonc
{
  "commands": [
    {
      "id": "clx…",          // echo back in /result
      "action": "BAN",        // KICK | BAN | UNBAN | WARN | MESSAGE | PROFILE
      "target": "license:abc123",
      "reason": "Cheating",   // may be null
      "durationMs": 86400000   // BAN only; null = permanent
    }
  ]
}
```

The `/sync` **request** may also include `"resourceVersion": "1.2.0"` (the bridge
version, for dashboard health/compat). The **response** also includes a `config`
object — the dashboard-pushed bridge config, applied live each sync:

```jsonc
{
  "config": {
    "whitelist": {
      "enabled": true,
      "mode": "roles",                 // "roles" | "open"
      "allowedRoleIds": ["1234…"],
      "allowedUserIds": ["5678…"],     // always-allowed Discord users
      "priorityRoles": { "1234…": 10 },// roleId → queue weight
      "requireLink": false,
      "messages": { "denied": "…", "notLinked": "…" }
    }
  },
  "commands": [ /* … as above … */ ]
}
```

Returned commands are flipped `PENDING → ACKED` server-side, so the same command
is never handed out twice. Execute them, then report via `/result`.

---

## `POST /result`

Report command outcomes. Call once you've executed the commands from `/sync`.

**Request body**

```jsonc
{
  "results": [
    { "id": "clx…", "status": "DONE", "message": "banned" },
    { "id": "cly…", "status": "FAILED", "message": "player not online" }
  ]
}
```

`status` is `DONE` or `FAILED`; `message` (≤512 chars) is surfaced in the
dashboard's "Recent actions" list. Results are scoped to the authenticated
server — a key can only complete its own commands.

**Response:** `{ "ok": true }`

---

## `POST /profile`

Sent after executing a `PROFILE` command — reports a player's general info so the
dashboard can display it. The payload is free-form (it varies by framework) and
cached per identifier; keep it under 16 KB.

**Request body**

```jsonc
{
  "identifier": "license:abc123",
  "profile": {
    "name": "John Doe",
    "account": "ABC12345",          // citizenid (QBCore) or identifier (ESX)
    "phone": "555-0100",
    "job": { "name": "police", "label": "Police", "grade": 3, "onDuty": true },
    "gang": { "name": "ballas", "label": "Ballas" },   // QBCore only
    "money": { "cash": 1240, "bank": 58000, "crypto": 2, "blackMoney": 0 },
    "vehicles": [ { "plate": "ABC 123", "model": "adder", "garage": "legion" } ],
    "properties": [ { "label": "Apartment 4A" } ],
    "note": "…"                      // optional, e.g. standalone limitations
  }
}
```

**Response:** `{ "ok": true }`

The dashboard requests a profile by enqueuing a `PROFILE` command (returned via
`/sync`); CTQBridge builds it from the framework object (online) or the database
(offline) and posts it here.

---

## `POST /roles`

Resolve a player's Discord role IDs for the server's guild (bot token, cached
~60s). Powers `exports.CTQBridge:GetRoles`.

**Request:** `{ "discordId": "1234…" }`
**Response:** `{ "inGuild": true, "roles": ["<roleId>", …] }` — `roles` is `null`
when the user isn't in the guild.

---

## `POST /whitelist`

The connect-gate decision. CTQBridge (and CTQCore's queue, via
`exports.CTQBridge:CheckWhitelist`) sends the player's live `discord:` id; the
dashboard checks the configured roles/users and returns the verdict + queue
priority. Players must have Discord running — no `discordId` ⇒ denied.

**Request body**

```jsonc
{ "discordId": "1234…" }                 // live discord: value; omit if none
```

**Response**

```jsonc
{
  "allowed": true,
  "priority": 10,                        // queue weight (higher = sooner)
  "roles": ["<roleId>", …],
  "reason": "has-role",                  // disabled|open|has-role|no-role|no-discord
  "message": null                         // deny message when !allowed
}
```

---

## Target identifiers

`target` is whatever `identifier` CTQBridge reported for a player (typically
`license:…`, sometimes `discord:…` or `server:<id>`). Adapters resolve it back to
an online player via `CTQ.findPlayerByIdentifier`. For `UNBAN`, the target is the
identifier stored on the ban.

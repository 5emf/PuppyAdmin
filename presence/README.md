# PuppyAdmin presence server

Tells each running copy of PuppyAdmin which other players in the same Roblox
server are running it, so they can show the default tag. Free on Cloudflare's
Workers plan.

## Deploy (once)

1. Install Node.js, then in this folder run:

   ```
   npx wrangler login
   npx wrangler deploy
   ```

2. Wrangler prints the URL, e.g. `https://puppyadmin-presence.<you>.workers.dev`.
3. Put that URL in `PuppyAdmin.lua`:

   ```lua
   Presence = { url = "https://puppyadmin-presence.<you>.workers.dev", beatSeconds = 20 },
   ```

   and push it, so everyone loading the script uses the same server.

## What it stores

Only `{ Roblox server JobId -> { UserId -> last check-in time } }`, in memory,
for 60 seconds after the last check-in. Anyone who knows the URL can check in,
which at most makes a default tag appear on a player who is not really running
the script.

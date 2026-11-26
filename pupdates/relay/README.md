# Pupdates relay (the whitelist)

A free Cloudflare Worker between the Pupdates apps and your Discord channel. It keeps the
webhook URL secret, and only people on your whitelist can post, each with their own access key
that you can remove at any time.

## Set it up once (about 5 minutes)

Option A, in the browser (no tools):
1. Make a free account at dash.cloudflare.com, then **Workers & Pages > Create > Create Worker**,
   name it `pupdates-relay`, **Deploy**, then **Edit code**: replace everything with
   `worker.js` from this folder, add a second file named `mod.js` (the editor's file list > New file)
   with `mod.js` from this folder, and **Deploy** again. (Updating an older relay: replace both files.)
2. **Storage & Databases > KV > Create a namespace** named `PUPDATES`.
3. Your worker > **Settings > Bindings > Add > KV namespace**: variable name `PUPDATES`, namespace `PUPDATES`.
4. Your worker > **Settings > Variables and Secrets > Add**:
   - with your bot (recommended): `DISCORD_BOT_TOKEN` (type **Secret**) = the bot's token and
     `DISCORD_CHANNEL_ID` (plain text) = the channel's id (Discord: Settings > Advanced > Developer Mode,
     then right-click the channel > Copy Channel ID). Posts then come from the bot.
   - or with a webhook: `DISCORD_WEBHOOK_URL` (type **Secret**) = your channel's webhook URL
   - `ADMIN_KEY` (type **Secret**) = a long random password only you know
5. Copy the worker's address (like `https://pupdates-relay.<you>.workers.dev`).

Option B, with Node: `npx wrangler login`, `npx wrangler kv namespace create PUPDATES`, put the id in
`wrangler.toml`, `npx wrangler secret put DISCORD_WEBHOOK_URL`, `npx wrangler secret put ADMIN_KEY`,
`npx wrangler deploy`.

## Whitelist people

In the Pupdates desktop app, open **Whitelist**, enter the relay address and your admin key, then
**Add** a name. The app shows that person's access key once: send it to them. They open Pupdates
(desktop or Android), choose **Relay**, and enter the relay address and their key. **Remove** takes
their key away immediately. Only people you allow to ping can use @here / @everyone / role pings.

Posts show "Posted by <name> via Pupdates". At most 10 posts a minute per person.
Tests: `node --test pupdates/relay/test/worker.test.mjs pupdates/relay/test/mod.test.mjs`

## Moderation and staff (slash commands)

The relay can also answer slash commands for your bot, so your staff moderate from Discord while your PC
is off. It needs your bot (`DISCORD_BOT_TOKEN`) and one more secret.

1. Developer Portal > your app > **General Information**: copy the **Public Key**. Worker > Settings >
   Variables and Secrets > Add `DISCORD_PUBLIC_KEY` (Secret) = that key. Optional: `OWNER_IDS` (plain
   text) = user ids that always count as owner, comma separated.
2. Pupdates > **Whitelist** > **Install moderation commands** (uses your admin key).
3. Same page in the Developer Portal: **Interactions Endpoint URL** = `https://<your relay>/interactions`
   (**Copy endpoint** in Pupdates), **Save Changes**. Discord checks the address at once: if it refuses,
   the public key secret is missing or wrong.
4. Pupdates > **Bot** > **Invite the bot to a server** again and accept: the invite now asks for Kick,
   Ban, Manage Channels, Manage Messages, Manage Roles and Timeout Members, and for slash commands.
5. Server Settings > Roles: drag the bot's role **above** every role it should moderate (Discord only
   lets a bot act on members below its own highest role).
6. In Discord: `/staff add` (or `/staff role` for a whole role) to build the team, `/modsettings
   log_channel:#mod-log` for the log.

| Level | Who | Commands |
|---|---|---|
| owner | the server owner, `OWNER_IDS` | everything, can make admins |
| admin | `/staff add ... admin`, Discord's Administrator permission | `/ban`, `/unban`, `/staff add / remove / role`, `/modsettings` + below |
| moderator | staff list or role | `/kick`, `/timeout` up to 28 days, `/purge` up to 100, `/clearwarn`, `/lock`, `/unlock`, `/slowmode` + below |
| helper | staff list or role | `/warn`, `/warnings`, `/case`, `/note`, `/timeout` up to 60 minutes, `/untimeout`, `/purge` up to 25, `/staff list` |
| everyone | | `/modhelp` |

- Nobody can act on themselves, on bots, or on someone of the same or a higher level, and levels can
  only be given below your own.
- Every action gets a case number (`/case 12`, `/warnings @someone`), goes to the log channel as a card
  and into Discord's audit log with the moderator and reason, and (turn off in `/modsettings`) posts a
  short public notice in the channel and DMs the member before a kick or ban. `/note` is staff-only.
- Answers to the moderator are private (only they see them).
- `/purge` can only delete messages younger than 14 days (Discord's rule).
- Data lives in the relay's KV (`mod:<server id>:...`). Two actions at the very same moment could get
  the same case number (KV is not a database); the actions themselves still happen.

# Pupdates relay (the whitelist)

A free Cloudflare Worker between the Pupdates apps and your Discord channel. It keeps the
webhook URL secret, and only people on your whitelist can post, each with their own access key
that you can remove at any time.

## Set it up once (about 5 minutes)

Option A, in the browser (no tools):
1. Make a free account at dash.cloudflare.com, then **Workers & Pages > Create > Create Worker**,
   name it `pupdates-relay`, **Deploy**, then **Edit code**: replace everything with
   `worker.js` from this folder and **Deploy** again.
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
Tests: `node --test pupdates/relay/test/worker.test.mjs`

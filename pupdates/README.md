# Pupdates

Post any message and picture to your Discord channel, from Windows (`Pupdates.exe`) or Android
(`Pupdates.apk`). Both open like the Sword Art Online-style menu: no window frame or backdrop,
just a column of round icons beside a white card.

- **Compose**: title, message, card (embed) or plain message, colour, name, ping (none, @here,
  @everyone or a role id), the Puppy Admin loadstring, and a picture (PNG, JPG, GIF or WEBP up to
  8 MB). Ctrl+Enter posts (desktop). On Android you can also share a picture or text from any app
  into Pupdates.
- **Updates**: fill in a Puppy Admin or Puppy Companion announcement from GitHub (the newest build
  or version and the changes since your last announcement of it).
- **Whitelist**: choose who may post (see below).
- **Settings**: post straight to your webhook, or through the relay with an access key.

## Owner: your webhook
In Discord: your channel > Edit Channel > Integrations > Webhooks > New Webhook > **Copy Webhook URL**.
Paste it in **Settings > Webhook** and press **Save**. It is stored encrypted (Windows DPAPI in
`%APPDATA%\Pupdates\settings.json`, the Android Keystore on a phone) and never shown again.
Anyone with the webhook URL can post in that channel, so never give it out: use the whitelist.

## The whitelist (letting other people post)
1. Set up the relay once: `relay/README.md` (a free Cloudflare Worker that keeps the webhook secret).
2. Open **Whitelist**, enter the relay address and your admin key, then **Add** a name. Pupdates
   shows that person's access key once: send it to them. Tick **may ping** to let them use
   @here / @everyone / role pings.
3. They open Pupdates, choose **Settings > The relay**, enter the relay address and their key,
   and press **Check**.
4. **Remove** takes a person's key away at once. Their posts show "Posted by <name> via Pupdates".

Settings from Puppy Announcer (the old name) are moved over the first time Pupdates starts.

## Builds
- Windows: `.github/workflows/pupdates.yml` (tests, PyInstaller one-file exe, `--selftest`),
  artifact `Pupdates-win64`.
- Android: `.github/workflows/pupdates-android.yml` (unit tests, APK), artifact `Pupdates-android`.
  Allow "install unknown apps" for your browser or file manager to install it.

Tests: `python -m unittest discover -s tests` (from `pupdates/`), `node --test relay/test/worker.test.mjs`,
`gradle testDebugUnitTest` (from `pupdates/android/`). Art: `python3 tools/make_pupdates_art.py`.

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
- **Tags** (both apps): edit Puppy Admin's shared tags (`tags.json` on `main`, the same file
  Puppy Admin's tag sync reads): text, line under it, colour or rainbow, font, size, dark box,
  picture (avatar or an image URL) and who wears each tag (Roblox username or user id; one tag per
  person). Anyone can load them; **Save to GitHub** needs a fine-grained GitHub token for
  5emf/PuppyAdmin with Contents: read and write (stored encrypted). Puppy Admin picks changes up
  within a minute or two.
- **Games** (Android): Puppy Admin's own Game Boy and Game Boy Advance emulators (the same Luau
  modules as in Roblox, run in an embedded Luau VM) and the Doom engine (doomgeneric, compiled
  natively). Add your own ROMs / WADs (the app ships none); Freedoom is a free download. On-screen
  pad, GBA sound, Doom sound effects (no music), battery saves kept in the app.
- **Settings**: post straight to your webhook, or through the relay with an access key; the
  overlay (Windows: stay on top of other windows; Android: a bubble over every app that opens
  Pupdates on top of what you are doing); **Check for updates** (like the companion: downloads
  the newest build from GitHub, checks it and installs it).

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

## Updates
The builds publish to two GitHub releases that the Update buttons read: `pupdates-windows-latest`
(Pupdates.exe, swapped in after Pupdates closes) and `pupdates-android-latest` (Pupdates.apk,
installed through Android's installer after you confirm). Android only installs an update signed
with the same key, so the Android build publishes only when the four `PUPDATES_KEY*` secrets are
set (see `.github/workflows/pupdates-android.yml`); give "Install unknown apps" to Pupdates once.

## Builds
- Windows: `.github/workflows/pupdates.yml` (tests, PyInstaller one-file exe, `--selftest`),
  artifact `Pupdates-win64`.
- Android: `.github/workflows/pupdates-android.yml` (unit tests, APK), artifact `Pupdates-android`.
  Allow "install unknown apps" for your browser or file manager to install it.

Tests: `python -m unittest discover -s tests` (from `pupdates/`), `node --test relay/test/worker.test.mjs`,
`gradle testDebugUnitTest` (from `pupdates/android/`), and the emulator core on Linux:
`cmake -S pupdates/android/native-test -B build-native && cmake --build build-native`, then
`build-native/emu_test gb|gba|doom ...` (see its CMakeLists.txt). Art: `python3 tools/make_pupdates_art.py`.

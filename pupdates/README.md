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
  picture (avatar or an image URL) and who wears each tag. A live preview draws the tag the way
  Puppy Admin does in the game, with its pictures loaded (image links, Roblox ids, the first
  wearer's avatar), its font and the far-away view (Roblox username or user id; one tag per
  person). Anyone can load them; **Save to GitHub** needs a fine-grained GitHub token for
  5emf/PuppyAdmin with Contents: read and write (stored encrypted). Puppy Admin picks changes up
  within a minute or two.
- **Games** (Android): Puppy Admin's mini games (Snake, Stack Drop, Treat Chase, Star Pup and
  Puppy Fighter: the same rules from `PuppyAdmin.lua`, the same sprite sheets, stage pictures and
  fighter sounds, best scores kept), and Puppy Admin's own Game Boy and Game Boy Advance emulators (the same Luau
  modules as in Roblox, run in an embedded Luau VM) and the Doom engine (doomgeneric, compiled
  natively). Add your own ROMs / WADs (the app ships none); Freedoom is a free download. On-screen
  pad, GBA sound, Doom sound effects (no music), battery saves kept in the app.
- **Pet** (Android): a Tamagotchi-style pet cat drawn from the owner's original character sheet
  (`assets/pet/cat_source.jpg`, cut by `tools/make_pet_sheet.py`): it wanders, idles, eats,
  cheers, sleeps and cries. Feed, Play, Sleep / Wake up, tap to pat, rename. Food, fun and energy
  go down over time, also while the app is closed.
- **Settings**: post straight to your webhook, or through the relay with an access key; the
  webhook's picture (a picture link for each post, or set the webhook's own picture from a PNG /
  JPG / GIF, which needs your webhook or the relay's admin key); the
  overlay (Windows: stay on top of other windows; Android: a bubble over every app that opens
  Pupdates on top of what you are doing); **Check for updates** (like the companion: downloads
  the newest build from GitHub, checks it and installs it).

## Owner: your bot (recommended)
1. https://discord.com/developers/applications > **New Application** > **Bot** > **Reset Token**, copy it.
2. Pupdates > **Bot**: paste the token, **Save** (stored encrypted), then **Invite the bot to a server**
   and pick your server (the link asks for: View Channel, Send Messages, Embed Links, Attach Files,
   Read Message History, Mention Everyone).
3. Pick the **Server** and **Channel**. Posts come from the bot; in an announcement channel they can be
   published to every server that follows it. **Recent posts** can be edited (the picture stays,
   edits never ping), deleted or opened in Discord. The bot's name and picture are changed there too.
4. Settings > **Post through: My bot** (the default for new installs).
Posting does not need the bot to be online.

## Status: the bot online, and rich presence on your profile
- **The bot's status** (both apps, Status section, headphones icon): tick **Keep the bot online** and the
  bot connects to Discord's gateway and shows **Listening to Jae but mainly Claude** (type, text and the
  online / idle / dnd dot can be changed; **Apply** changes it live). Windows: while Pupdates is open.
  Android: a background service with a small notification, also while the app is closed ("Go offline"
  in the notification stops it). Bots show one line only: no second line, timer or buttons.
- **Rich presence on your own profile** (Windows app only, the Discord desktop app must be running on the
  same PC): Status > **Show it while Pupdates is open**. It talks to the Discord app's local pipe
  (`discord-ipc-N`) and sets: Listening, "May Your Heart Be" / "Your Guiding Key", a timer from
  1795676718 and the button **Join for more Pupdates** (https://discord.gg/eDC7V9bnAX); every field
  can be changed. **Application ID** = your app's id (**From my bot** fills it from the bot token).
  Discord shows "Listening to <application name>": rename the application to change that word.
  If Discord refuses the Listening type (older Discord apps), Pupdates retries as Playing and says so.
  The phone's Discord app cannot be set by other apps, so Android has the bot status only.

## Owner: your webhook (still works)
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

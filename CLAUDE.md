# Puppy Admin: notes for future sessions

## Rules from the owner
- **Every game gets its own generated images.** Each mini game in the Games window ships a sprite sheet in `assets/games/` (64 px cells, drawn in code with Pillow at 4x and downsampled). That covers the moving pieces (`actors` + `spriteCell`) and the grid tiles (`cellSprite`): walls, blocks, shields, food, and so on. Coloured squares are only the fallback while the sheet downloads. When you add a game, make its sheet in the same change.
- When a sheet changes, give it a new file name (for example `_v2`). The script caches images by URL on the player's device.
- Games are original. Genres are fine (snake, falling blocks, maze chase, fixed shooter); recreations of a specific game's name, characters or look are not.
- Commercial game files (ROMs, id Software WADs) never go in this public repo. Players put them in their executor folder (`PuppyAdmin/roms`, `PuppyAdmin/gba`, `PuppyAdmin/doom`). The same goes for Nintendo's GBA BIOS: the repo ships the free Cult-of-GBA BIOS (MIT) in `assets/gba`. Freely licensed data such as Freedoom is fine.

## How the script is put together
- `PuppyAdmin.lua` is the loadstring entry. Bump `SCRIPT_BUILD` with every change; a newer build replaces a running older one.
- Large parts are separate, version-named files that are downloaded and cached on first use: `engine/engine-<hash>.lua` (reanimation and movement), `emu/gameboy-<hash>.lua`, `emu/gba-<hash>.lua` and `emu/doom-<hash>.lua`. Their size and version are pinned in the main script.
- GBA core: hand-written Luau (ARM7TDMI interpreter, scanline video, DMA, timers, SRAM / Flash / EEPROM saves, sound: tone channels + DirectSound FIFOs mixed to 16384 Hz mono PCM). Roblox cannot stream raw audio, so `UIAPI.newPcmStream` cuts the PCM into 0.25 s files that play back to back with crossfades. It first loads a silent test file of each type side by side (WAV, FLAC, or MPEG-1 Layer II saved as `.mp3`, encoded in `gba_pcm.luau` with the ISO analysis window) and uses the first one Roblox loads. Sources live in the scratchpad (`gba/core_cpu.luau`, `core_ppu.luau`, `core_apu.luau`, `gba_zip.luau`, `gba_pcm.luau`); `gba/build_module.py` writes `emu/gba-<hash>.lua` and updates `UIAPI.GBA_MODULE`. jsmolka's gba-tests (MIT) all pass; keep them passing.
- Doom sound: the engine passes sound calls to the host (`opts.sound` in the Doom module). Freedoom Phase 1's effects (`sfx_v<N>.pak`) and music (`music_v<N>/`) are pre-rendered mp3 in `assets/doom/freedoom1`, made by the scratchpad script `make_doom_audio.py`. Bump the `_v` names in `UIAPI.DOOM_SOUND` when they change.
- The main chunk sits at Lua's 200-local limit. Put new code in functions or `do` blocks, or on tables such as `UIAPI.*`, instead of adding top-level locals.
- Check that it parses with `luac5.4 -p` (on a copy with the engine stubbed when needed), and compare free names and global writes against the previous version.

## Puppy Companion (desktop app, `companion/`)
- Windows app in Python 3 with only the standard library (Tkinter, ctypes); built into `PuppyCompanion.exe` with PyInstaller by `.github/workflows/companion.yml` (tests, build, then the built program's `--selftest`). Keep the tests passing: `python -m unittest discover -s tests` from `companion/` (window tests need Tk and a display; under Linux use `xvfb-run`).
- Login cookies: encrypted with DPAPI (`secure.py`), never logged (`redact.py`), never written to the executor workspace, and sent only to roblox.com. Do not add any other destination for them.
- Everything that depends on Roblox's launch protocol or single-window lock is in `launch.py`; the web requests are in `roblox.py`. Both are unverified against live Roblox until the owner reports back.
- Puppy Admin side: `UIAPI.companionStart` writes `PuppyAdmin/companion/<UserId>.json` every 10 s (online false on shutdown); the app writes `PuppyAdmin/companion/roster.json` (main and alt user IDs and names). Keep the field names in step with `workspace.py`.
- The icon is drawn by `companion/tools/make_icon.py` (writes the .ico and `puppy_companion/icon_data.py`).

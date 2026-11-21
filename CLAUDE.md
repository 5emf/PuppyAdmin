# Puppy Admin: notes for future sessions

## Rules from the owner
- **Every game gets its own generated images.** Each mini game in the Games window ships a sprite sheet in `assets/games/` (64 px cells, drawn in code with Pillow at 4x and downsampled). That covers the moving pieces (`actors` + `spriteCell`) and the grid tiles (`cellSprite`): walls, blocks, shields, food, and so on. Coloured squares are only the fallback while the sheet downloads. When you add a game, make its sheet in the same change.
- When a sheet changes, give it a new file name (for example `_v2`). The script caches images by URL on the player's device.
- Games are original. Genres are fine (snake, falling blocks, maze chase, fixed shooter); recreations of a specific game's name, characters or look are not.
- Commercial game files (ROMs, id Software WADs) never go in this public repo. Players put them in their executor folder (`PuppyAdmin/roms`, `PuppyAdmin/doom`). Freely licensed data such as Freedoom is fine.

## How the script is put together
- `PuppyAdmin.lua` is the loadstring entry. Bump `SCRIPT_BUILD` with every change; a newer build replaces a running older one.
- Large parts are separate, version-named files that are downloaded and cached on first use: `engine/engine-<hash>.lua` (reanimation and movement), `emu/gameboy-<hash>.lua`, and `emu/doom-<hash>.lua`. Their size and version are pinned in the main script.
- Doom sound: the engine passes sound calls to the host (`opts.sound` in the Doom module). Freedoom Phase 1's effects (`sfx_v<N>.pak`) and music (`music_v<N>/`) are pre-rendered mp3 in `assets/doom/freedoom1`, made by the scratchpad script `make_doom_audio.py`. Bump the `_v` names in `UIAPI.DOOM_SOUND` when they change.
- The main chunk sits at Lua's 200-local limit. Put new code in functions or `do` blocks, or on tables such as `UIAPI.*`, instead of adding top-level locals.
- Check that it parses with `luac5.4 -p` (on a copy with the engine stubbed when needed), and compare free names and global writes against the previous version.

# Doom engine in emu/doom-*.lua

`emu/doom-<version>.lua` contains the Doom (1993) engine, converted to Luau:

- **Engine:** [doomgeneric](https://github.com/ozkl/doomgeneric) (commit e257a09), based on id Software's Doom source release and Chocolate Doom. GPL-2.0, see `doom-src/LICENSE-GPL-2.0.txt`.
- **Changes for Puppy Admin:** `doom-src/doomgeneric_puppy.c` (platform layer) and `doom-src/i_video.c.patch` (hand the 8-bit screen and palette to the host).
- **Build:** compiled to WebAssembly with clang (wasm32-wasi, wasi-libc), then converted to Luau with [Wasynth](https://github.com/Rerumu/Wasynth). The Wasynth runtime included in the file is MPL-2.0, see `doom-src/LICENSE-Wasynth-runtime-MPL-2.0.txt`.

No game data is included. Doom needs a WAD file (DOOM1.WAD shareware, DOOM.WAD, DOOM2.WAD or Freedoom), which the script reads from the executor's `PuppyAdmin/doom` folder.

# Freedoom Phase 1 sound for the Doom window

These files are made from `assets/doom/freedoom1.wad` (Freedoom Phase 1, BSD licence, see `../FREEDOOM-COPYING.txt`). The script uses them only when that exact WAD is loaded.

- `sfx_v1.pak`: every `DS*` sound lump as an mp3, in one download. The file starts with `PUPSND1`, then one line per sound (`NAME offset length milliseconds`), a blank line, and the mp3 files back to back. Offsets count from the first mp3 byte.
- `music_v1/d_*.mp3`: every `D_*` music lump (MIDI). Each was rendered with FluidSynth using the FluidR3_GM soundfont by Frank Wen (MIT licence), with silence trimmed from the end and loudness normalised.

The Freedoom project made the sounds and music. If a sound or song changes, publish it under a new file or folder name (`_v2`), because the script caches these files by URL.

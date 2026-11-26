// Pupdates emulators: the Game Boy and Game Boy Advance cores are Puppy Admin's own Luau modules
// (emu/gameboy-*.lua, emu/gba-*.lua) running in an embedded Luau VM; Doom is doomgeneric compiled
// natively with Puppy Admin's platform layer (emu/doom-src). Frames come out as RGBA bytes.
#pragma once
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

enum { EMU_GB = 1, EMU_GBA = 2 };

// Luau cores. Returns 1 on success; on failure 0 and a message in err.
int lemu_open(int kind, const char *src, size_t srclen, const char *rom, size_t romlen, const char *bios, size_t bioslen,
              const char *save, size_t savelen, char *err, size_t errlen);
int lemu_width(void);
int lemu_height(void);
// one video frame into rgba (width * height * 4 bytes); draw = 0 runs it without drawing (frame skip)
int lemu_frame(uint8_t *rgba, int draw, char *err, size_t errlen);
// held buttons, bit set = held: 0 A, 1 B, 2 Select, 3 Start, 4 Right, 5 Left, 6 Up, 7 Down, 8 R, 9 L
void lemu_keys(int mask);
// sound since the last call (GBA: signed 16-bit mono at lemu_audio_rate()); returns the sample count
int lemu_audio(int16_t *out, int max);
int lemu_audio_rate(void);
// battery save when it changed since the last call: returns its length and *data (free() it), else 0
size_t lemu_save(uint8_t **data);
void lemu_close(void);

// Doom (once per process: Doom's state cannot be reset)
int doom_open(const char *wadpath, const char *dir, char *err, size_t errlen);
// runs Doom until its next frame (Doom paces itself); 1 running, 0 quit from the menu, -1 error
int doom_tick(uint8_t *rgba320x200);
void doom_key(int down, int code);
// stereo signed 16-bit at 22050 Hz, frames = sample pairs; returns frames written (always all, silence when idle)
int doom_audio(int16_t *out, int frames);
const char *doom_error(void);

#ifdef __cplusplus
}
#endif

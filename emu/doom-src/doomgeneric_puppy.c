// Puppy Admin platform layer for doomgeneric: the host (Luau) provides the
// clock, the screen and input; Doom is driven one tick at a time.
#include <stdint.h>
#include <string.h>
#include "doomgeneric.h"
#include "d_event.h"

#ifdef __wasm__
#define IMPORT(name) __attribute__((import_module("env"), import_name(#name)))
#define EXPORT(name) __attribute__((export_name(#name)))
#else  // native builds (Pupdates for Android): the host functions are plain C (pupdates/android/app/src/main/cpp/emu_doom.c)
#define IMPORT(name)
#define EXPORT(name)
#endif

IMPORT(host_ticks) uint32_t host_ticks(void);
IMPORT(host_sleep) void host_sleep(uint32_t ms);
IMPORT(host_draw) void host_draw(void *pixels, int w, int h);
IMPORT(host_title) void host_title(const char *title);
IMPORT(host_palette) void host_palette(void *colors);
extern unsigned char *I_VideoBuffer;

// key queue filled by the host: (pressed, doom key code)
#define KEYQ 64
static unsigned char keyq_code[KEYQ];
static unsigned char keyq_down[KEYQ];
static int keyq_head = 0, keyq_tail = 0;

EXPORT(puppy_key) void puppy_key(int pressed, int code)
{
    int next = (keyq_tail + 1) % KEYQ;
    if (next == keyq_head) return; // full: drop
    keyq_code[keyq_tail] = (unsigned char)code;
    keyq_down[keyq_tail] = pressed ? 1 : 0;
    keyq_tail = next;
}

// relative mouse movement and buttons (bit 0 left, 1 right, 2 middle)
EXPORT(puppy_mouse) void puppy_mouse(int buttons, int dx, int dy)
{
    event_t ev;
    ev.type = ev_mouse;
    ev.data1 = buttons;
    ev.data2 = dx;
    ev.data3 = dy;
    ev.data4 = 0;
    D_PostEvent(&ev);
}

static char wadarg[128] = "/doom.wad";
EXPORT(puppy_wadname) char *puppy_wadname(void) { return wadarg; }

EXPORT(puppy_start) void puppy_start(void)
{
    static char *argv[4];
    argv[0] = "doom";
    argv[1] = "-iwad";
    argv[2] = wadarg;
    argv[3] = 0;
    doomgeneric_Create(3, argv);
}

EXPORT(puppy_tick) void puppy_tick(void) { doomgeneric_Tick(); }

void DG_Init(void) {}
// 8-bit paletted screen (320 x 200); palette entries are b, g, r, a bytes
void DG_DrawFrame(void) { host_draw(I_VideoBuffer, 320, 200); }
void DG_SetPalette(void *colors) { host_palette(colors); }
void DG_SleepMs(uint32_t ms) { host_sleep(ms); }
uint32_t DG_GetTicksMs(void) { return host_ticks(); }
void DG_SetWindowTitle(const char *title) { host_title(title); }

int DG_GetKey(int *pressed, unsigned char *key)
{
    if (keyq_head == keyq_tail) return 0;
    *pressed = keyq_down[keyq_head];
    *key = keyq_code[keyq_head];
    keyq_head = (keyq_head + 1) % KEYQ;
    return 1;
}

#ifdef __wasm__
// WebAssembly cannot start programs; Doom only uses this for an optional error dialog
int system(const char *command) { (void)command; return -1; }
#endif

// ---------------------------------------------------------------------------
// Sound: Doom tells the host which sound effect to start on which channel and
// which song to play; the host plays them with Roblox Sounds.
// ---------------------------------------------------------------------------
#include <stdio.h>
#include <stdlib.h>
#include "i_sound.h"
#include "w_wad.h"
#include "z_zone.h"

IMPORT(host_sfx_start) void host_sfx_start(const char *lump, int channel, int vol, int sep);
IMPORT(host_sfx_stop) void host_sfx_stop(int channel);
IMPORT(host_sfx_params) void host_sfx_params(int channel, int vol, int sep);
// op: 1 play (data, len, looping), 2 stop, 3 pause, 4 resume, 5 volume (arg 0-127)
IMPORT(host_music) void host_music(int op, const void *data, int len, int arg);

#define PUPPY_CHANNELS 16
static uint32_t chan_end[PUPPY_CHANNELS]; // Doom clock (ms) when the sound on the channel ends
static boolean sfx_prefix;

static void SfxLumpName(sfxinfo_t *sfx, char *buf)
{
    if (sfx->link != NULL) sfx = sfx->link;
    if (sfx_prefix) snprintf(buf, 9, "ds%s", sfx->name);
    else snprintf(buf, 9, "%s", sfx->name);
}

static boolean Puppy_InitSound(boolean use_sfx_prefix)
{
    sfx_prefix = use_sfx_prefix;
    memset(chan_end, 0, sizeof(chan_end));
    return true;
}

static void Puppy_ShutdownSound(void)
{
    for (int i = 0; i < PUPPY_CHANNELS; i++) { chan_end[i] = 0; host_sfx_stop(i); }
}

static int Puppy_GetSfxLumpNum(sfxinfo_t *sfx)
{
    char name[9];
    SfxLumpName(sfx, name);
    return W_CheckNumForName(name);
}

static void Puppy_UpdateSound(void) {}

static void Puppy_UpdateSoundParams(int channel, int vol, int sep)
{
    if (channel < 0 || channel >= PUPPY_CHANNELS) return;
    host_sfx_params(channel, vol, sep);
}

// Sound lumps: u16 format (3), u16 sample rate, u32 sample count (16 padding
// bytes at each end included), then 8-bit unsigned samples.
static int Puppy_StartSound(sfxinfo_t *sfx, int channel, int vol, int sep)
{
    char name[9];
    int lump, len;
    unsigned char *d;
    uint32_t rate, samples, ms;

    if (channel < 0 || channel >= PUPPY_CHANNELS) return -1;
    SfxLumpName(sfx, name);
    lump = sfx->lumpnum >= 0 ? sfx->lumpnum : W_CheckNumForName(name);
    if (lump < 0) return -1;
    len = W_LumpLength(lump);
    if (len < 8 + 32) return -1;
    d = W_CacheLumpNum(lump, PU_STATIC);
    rate = d[2] | (d[3] << 8);
    samples = d[4] | (d[5] << 8) | (d[6] << 16) | ((uint32_t)d[7] << 24);
    if (d[0] != 3 || d[1] != 0 || rate < 4000 || samples < 32 || samples > (uint32_t)(len - 8))
    {
        W_ReleaseLumpNum(lump);
        return -1;
    }
    W_ReleaseLumpNum(lump);
    ms = (samples - 32) * 1000u / rate + 1;
    chan_end[channel] = DG_GetTicksMs() + ms;
    host_sfx_start(name, channel, vol, sep);
    return channel;
}

static void Puppy_StopSound(int channel)
{
    if (channel < 0 || channel >= PUPPY_CHANNELS) return;
    chan_end[channel] = 0;
    host_sfx_stop(channel);
}

static boolean Puppy_SoundIsPlaying(int channel)
{
    if (channel < 0 || channel >= PUPPY_CHANNELS) return false;
    return chan_end[channel] != 0 && (int32_t)(DG_GetTicksMs() - chan_end[channel]) < 0;
}

static snddevice_t puppy_sound_devices[] = {
    SNDDEVICE_SB, SNDDEVICE_PAS, SNDDEVICE_GUS, SNDDEVICE_WAVEBLASTER, SNDDEVICE_SOUNDCANVAS, SNDDEVICE_AWE32,
};

sound_module_t DG_sound_module = {
    puppy_sound_devices,
    sizeof(puppy_sound_devices) / sizeof(*puppy_sound_devices),
    Puppy_InitSound,
    Puppy_ShutdownSound,
    Puppy_GetSfxLumpNum,
    Puppy_UpdateSound,
    Puppy_UpdateSoundParams,
    Puppy_StartSound,
    Puppy_StopSound,
    Puppy_SoundIsPlaying,
    NULL,
};

typedef struct { void *data; int len; } puppy_song_t;
static boolean music_playing;

static boolean Puppy_InitMusic(void) { music_playing = false; return true; }
static void Puppy_ShutdownMusic(void) { music_playing = false; host_music(2, 0, 0, 0); }
static void Puppy_SetMusicVolume(int volume) { host_music(5, 0, 0, volume); }
static void Puppy_PauseMusic(void) { host_music(3, 0, 0, 0); }
static void Puppy_ResumeMusic(void) { host_music(4, 0, 0, 0); }

static void *Puppy_RegisterSong(void *data, int len)
{
    puppy_song_t *song = malloc(sizeof(puppy_song_t));
    if (song == NULL) return NULL;
    song->data = data;
    song->len = len;
    return song;
}

static void Puppy_UnRegisterSong(void *handle) { free(handle); }

static void Puppy_PlaySong(void *handle, boolean looping)
{
    puppy_song_t *song = handle;
    if (song == NULL) return;
    music_playing = true;
    host_music(1, song->data, song->len, looping ? 1 : 0);
}

static void Puppy_StopSong(void) { music_playing = false; host_music(2, 0, 0, 0); }
static boolean Puppy_MusicIsPlaying(void) { return music_playing; }

static snddevice_t puppy_music_devices[] = {
    SNDDEVICE_PAS, SNDDEVICE_GUS, SNDDEVICE_WAVEBLASTER, SNDDEVICE_SOUNDCANVAS, SNDDEVICE_GENMIDI, SNDDEVICE_AWE32,
};

music_module_t DG_music_module = {
    puppy_music_devices,
    sizeof(puppy_music_devices) / sizeof(*puppy_music_devices),
    Puppy_InitMusic,
    Puppy_ShutdownMusic,
    Puppy_SetMusicVolume,
    Puppy_PauseMusic,
    Puppy_ResumeMusic,
    Puppy_RegisterSong,
    Puppy_UnRegisterSong,
    Puppy_PlaySong,
    Puppy_StopSong,
    Puppy_MusicIsPlaying,
    NULL,
};

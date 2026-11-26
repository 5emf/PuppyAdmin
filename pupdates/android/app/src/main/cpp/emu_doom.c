// Host side of Puppy Admin's doomgeneric platform layer (emu/doom-src/doomgeneric_puppy.c), native:
// the clock, the screen (8-bit + palette -> RGBA), the key queue and a small sound-effect mixer.
// Music is not played (Doom's MUS songs need a synthesizer).
#define _GNU_SOURCE
#include "emu_core.h"

#include <pthread.h>
#include <setjmp.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include "doomtype.h"
#include "w_wad.h"
#include "z_zone.h"

void puppy_key(int pressed, int code);
char *puppy_wadname(void);
void puppy_start(void);
void puppy_tick(void);

static uint8_t palette[256][4];       // b, g, r, a as Doom hands it over
static const uint8_t *screen;         // last 320 x 200 frame
static int frame_ready;
static jmp_buf doom_jmp;
static int doom_jmp_set;
static int doom_state;                // 0 not started, 1 running, 2 quit, 3 error
static char doom_msg[512];
static char log_path[512];

// ------------------------------------------------------------------ the host functions Doom calls
uint32_t host_ticks(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint32_t)(ts.tv_sec * 1000u + ts.tv_nsec / 1000000u);
}

void host_sleep(uint32_t ms) { usleep(ms * 1000u); }
void host_title(const char *title) { (void)title; }
void host_palette(void *colors) { memcpy(palette, colors, sizeof(palette)); }

void host_draw(void *pixels, int w, int h) {
    if (w == 320 && h == 200) { screen = pixels; frame_ready = 1; }
}

// sound effects: 8-bit unsigned lumps, mixed to 22050 Hz stereo
#define CHANNELS 16
#define OUT_RATE 22050
typedef struct { const uint8_t *data; uint32_t len, pos, step; int left, right; } chan_t;
static chan_t chans[CHANNELS];
static pthread_mutex_t mix_lock = PTHREAD_MUTEX_INITIALIZER;

static void gains(int vol, int sep, int *l, int *r) {
    if (vol < 0) vol = 0;
    if (vol > 127) vol = 127;
    if (sep < 0) sep = 0;
    if (sep > 254) sep = 254;
    int lv = (254 - sep) * 2 > 254 ? 254 : (254 - sep) * 2;
    int rv = sep * 2 > 254 ? 254 : sep * 2;
    *l = vol * lv / 254;
    *r = vol * rv / 254;
}

void host_sfx_start(const char *lump, int channel, int vol, int sep) {
    if (channel < 0 || channel >= CHANNELS) return;
    int num = W_CheckNumForName(lump);
    if (num < 0) return;
    int len = W_LumpLength(num);
    const uint8_t *d = W_CacheLumpNum(num, PU_STATIC);
    if (len < 40 || d[0] != 3) return;
    uint32_t rate = d[2] | (d[3] << 8);
    uint32_t samples = d[4] | (d[5] << 8) | (d[6] << 16) | ((uint32_t)d[7] << 24);
    if (rate < 4000 || samples < 32 || samples > (uint32_t)(len - 8)) return;
    pthread_mutex_lock(&mix_lock);
    chan_t *c = &chans[channel];
    c->data = d + 8 + 16;
    c->len = samples - 32;
    c->pos = 0;
    c->step = (uint32_t)(((uint64_t)rate << 16) / OUT_RATE);
    gains(vol, sep, &c->left, &c->right);
    pthread_mutex_unlock(&mix_lock);
}

void host_sfx_stop(int channel) {
    if (channel < 0 || channel >= CHANNELS) return;
    pthread_mutex_lock(&mix_lock);
    chans[channel].data = NULL;
    pthread_mutex_unlock(&mix_lock);
}

void host_sfx_params(int channel, int vol, int sep) {
    if (channel < 0 || channel >= CHANNELS) return;
    pthread_mutex_lock(&mix_lock);
    gains(vol, sep, &chans[channel].left, &chans[channel].right);
    pthread_mutex_unlock(&mix_lock);
}

void host_music(int op, const void *data, int len, int arg) { (void)op; (void)data; (void)len; (void)arg; }

// Doom calls exit() for "Quit" and after I_Error: jump back to doom_open / doom_tick instead of
// ending the app (linked with -Wl,--wrap=exit).
void __real_exit(int code);
void __wrap_exit(int code) {
    if (doom_jmp_set) longjmp(doom_jmp, code == 0 ? 1 : 2);
    __real_exit(code);
}

static void read_error(void) {
    FILE *f = fopen(log_path, "r");
    doom_msg[0] = 0;
    if (!f) return;
    char line[512];
    while (fgets(line, sizeof(line), f)) {
        size_t n = strlen(line);
        while (n && (line[n - 1] == '\n' || line[n - 1] == '\r')) line[--n] = 0;
        if (n) snprintf(doom_msg, sizeof(doom_msg), "%s", line);  // keep the last non-empty line
    }
    fclose(f);
}

static void to_rgba(uint8_t *out) {
    if (!screen) return;
    for (int i = 0; i < 320 * 200; i++) {
        const uint8_t *p = palette[screen[i]];
        out[i * 4] = p[2];
        out[i * 4 + 1] = p[1];
        out[i * 4 + 2] = p[0];
        out[i * 4 + 3] = 255;
    }
}

// ------------------------------------------------------------------ API
int doom_open(const char *wadpath, const char *dir, char *err, size_t errlen) {
    if (doom_state != 0) { snprintf(err, errlen, "Doom already ran in this process"); return 0; }
    if (strlen(wadpath) >= 127) { snprintf(err, errlen, "the WAD path is too long"); return 0; }
    if (dir && *dir && chdir(dir) != 0) { snprintf(err, errlen, "cannot use the folder %s", dir); return 0; }
    snprintf(log_path, sizeof(log_path), "%s/doom_log.txt", dir && *dir ? dir : ".");
    freopen(log_path, "w", stderr);   // Doom's messages and errors
    setvbuf(stderr, NULL, _IONBF, 0);
    strcpy(puppy_wadname(), wadpath);
    int r = setjmp(doom_jmp);
    if (r == 0) {
        doom_jmp_set = 1;
        puppy_start();
        doom_jmp_set = 0;
        doom_state = 1;
        return 1;
    }
    doom_jmp_set = 0;
    doom_state = r == 1 ? 2 : 3;
    read_error();
    snprintf(err, errlen, "%s", doom_msg[0] ? doom_msg : "Doom stopped while starting");
    return 0;
}

int doom_tick(uint8_t *rgba) {
    if (doom_state != 1) return doom_state == 2 ? 0 : -1;
    frame_ready = 0;
    int r = setjmp(doom_jmp);
    if (r == 0) {
        doom_jmp_set = 1;
        // a game tick does not always draw (Doom draws when time moved on): run until a frame appears
        for (int i = 0; i < 8 && !frame_ready; i++) puppy_tick();
        doom_jmp_set = 0;
        to_rgba(rgba);
        return 1;
    }
    doom_jmp_set = 0;
    doom_state = r == 1 ? 2 : 3;
    if (doom_state == 3) read_error();
    return doom_state == 2 ? 0 : -1;
}

void doom_key(int down, int code) { if (doom_state == 1) puppy_key(down, code); }

int doom_audio(int16_t *out, int frames) {
    pthread_mutex_lock(&mix_lock);
    for (int f = 0; f < frames; f++) {
        int l = 0, r = 0;
        for (int c = 0; c < CHANNELS; c++) {
            chan_t *ch = &chans[c];
            if (!ch->data) continue;
            uint32_t idx = ch->pos >> 16;
            if (idx >= ch->len) { ch->data = NULL; continue; }
            int s = ((int)ch->data[idx] - 128) << 8;
            l += s * ch->left / 127;
            r += s * ch->right / 127;
            ch->pos += ch->step;
        }
        l /= 2;  // headroom for several sounds at once
        r /= 2;
        out[f * 2] = (int16_t)(l > 32767 ? 32767 : l < -32768 ? -32768 : l);
        out[f * 2 + 1] = (int16_t)(r > 32767 ? 32767 : r < -32768 ? -32768 : r);
    }
    pthread_mutex_unlock(&mix_lock);
    return frames;
}

const char *doom_error(void) { return doom_msg; }

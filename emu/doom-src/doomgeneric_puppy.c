// Puppy Admin platform layer for doomgeneric: the host (Luau) provides the
// clock, the screen and input; Doom is driven one tick at a time.
#include <stdint.h>
#include <string.h>
#include "doomgeneric.h"
#include "d_event.h"

#define IMPORT(name) __attribute__((import_module("env"), import_name(#name)))
#define EXPORT(name) __attribute__((export_name(#name)))

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

// WebAssembly cannot start programs; Doom only uses this for an optional error dialog
int system(const char *command) { (void)command; return -1; }

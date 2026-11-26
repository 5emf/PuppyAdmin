// Runs Puppy Admin's Game Boy / Game Boy Advance Luau modules in an embedded Luau VM.
#include "emu_core.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>

#include "Luau/Compiler.h"
#include "lua.h"
#include "lualib.h"
#include "luacode.h"
#include "luacodegen.h"

namespace {

lua_State *L = nullptr;
int apiRef = LUA_NOREF;
int kind = 0;
int heldMask = 0;
int pendingMask = 0;

// the module returns { GB = ..., Zip = ... } or { GBA = ..., Zip = ..., Pcm = ... }; this drives it
const char *DRIVER = R"LUA(
local mod, kind, rom, bios, save = ...
if rom:sub(1, 2) == "PK" and mod.Zip then
    local data, err = mod.Zip.extract(rom)
    if not data then error(err or "could not open the zip", 0) end
    rom = data
end
local emu
if kind == 1 then
    emu = mod.GB.new(rom, save)
else
    emu = mod.GBA.new(rom, bios, save)
    emu.setAudio(true)
end
local NAMES = { [0] = "a", "b", "select", "start", "right", "left", "up", "down" }
local held = 0
local api = {}
function api.keys(mask)
    if kind == 2 then emu.setKeys(mask) return end
    for bit = 0, 7 do
        local v = 2 ^ bit
        local was, now = bit32.btest(held, v), bit32.btest(mask, v)
        if was ~= now then emu.setButton(NAMES[bit], now) end
    end
    held = mask
end
function api.frame(draw)
    emu.runFrame(draw)
    return emu.fb
end
function api.audio()
    if kind == 2 then return emu.audioPull() end
    return nil, 0
end
function api.save()
    if kind == 1 then
        if emu.dirty() then emu.clearDirty() return emu.saveData() end
    elseif emu.saveDirty() then
        emu.clearSaveDirty()
        return emu.saveData()
    end
    return nil
end
return api
)LUA";

// DMG shades 0 (lightest) .. 3, as RGBA
const uint8_t SHADES[4][4] = {{224, 248, 208, 255}, {136, 192, 112, 255}, {52, 104, 86, 255}, {8, 24, 32, 255}};

void setErr(char *err, size_t errlen, const char *msg) {
    if (err && errlen) snprintf(err, errlen, "%s", msg ? msg : "unknown error");
}

bool loadChunk(const char *src, size_t len, const char *name, char *err, size_t errlen) {
    Luau::CompileOptions opts;
    opts.optimizationLevel = 2;
    std::string bc = Luau::compile(std::string(src, len), opts);
    if (luau_load(L, name, bc.data(), bc.size(), 0) != 0) {
        setErr(err, errlen, lua_tostring(L, -1));
        lua_pop(L, 1);
        return false;
    }
    if (luau_codegen_supported()) luau_codegen_compile(L, -1);
    return true;
}

bool callApi(const char *fn, int nargs, int nres, char *err, size_t errlen) {
    // stack: args...; puts api[fn] below them and calls it
    lua_rawgeti(L, LUA_REGISTRYINDEX, apiRef);
    lua_getfield(L, -1, fn);
    lua_remove(L, -2);
    lua_insert(L, -(nargs + 1));
    if (lua_pcall(L, nargs, nres, 0) != 0) {
        setErr(err, errlen, lua_tostring(L, -1));
        lua_pop(L, 1);
        return false;
    }
    return true;
}

}  // namespace

extern "C" int lemu_open(int k, const char *src, size_t srclen, const char *rom, size_t romlen, const char *bios, size_t bioslen,
                         const char *save, size_t savelen, char *err, size_t errlen) {
    lemu_close();
    if (k != EMU_GB && k != EMU_GBA) { setErr(err, errlen, "unknown emulator"); return 0; }
    L = luaL_newstate();
    if (!L) { setErr(err, errlen, "out of memory"); return 0; }
    luaL_openlibs(L);
    if (luau_codegen_supported()) luau_codegen_create(L);
    if (!loadChunk(src, srclen, k == EMU_GB ? "=gameboy" : "=gba", err, errlen)) { lemu_close(); return 0; }
    if (lua_pcall(L, 0, 1, 0) != 0 || !lua_istable(L, -1)) {
        setErr(err, errlen, lua_isstring(L, -1) ? lua_tostring(L, -1) : "the emulator module did not load");
        lemu_close();
        return 0;
    }
    // stack: mod
    if (!loadChunk(DRIVER, strlen(DRIVER), "=driver", err, errlen)) { lemu_close(); return 0; }
    lua_insert(L, -2);  // driver, mod
    lua_pushinteger(L, k);
    lua_pushlstring(L, rom, romlen);
    if (bios && bioslen) lua_pushlstring(L, bios, bioslen); else lua_pushnil(L);
    if (save && savelen) lua_pushlstring(L, save, savelen); else lua_pushnil(L);
    if (lua_pcall(L, 5, 1, 0) != 0) {
        setErr(err, errlen, lua_tostring(L, -1));
        lemu_close();
        return 0;
    }
    apiRef = lua_ref(L, -1);
    lua_pop(L, 1);
    kind = k;
    heldMask = pendingMask = 0;
    return 1;
}

extern "C" int lemu_width(void) { return kind == EMU_GBA ? 240 : 160; }
extern "C" int lemu_height(void) { return kind == EMU_GBA ? 160 : 144; }
extern "C" int lemu_audio_rate(void) { return 16384; }
extern "C" void lemu_keys(int mask) { pendingMask = mask; }

extern "C" int lemu_frame(uint8_t *rgba, int draw, char *err, size_t errlen) {
    if (!L) { setErr(err, errlen, "no game is running"); return 0; }
    int mask = pendingMask;
    if (mask != heldMask) {
        lua_pushinteger(L, mask);
        if (!callApi("keys", 1, 0, err, errlen)) return 0;
        heldMask = mask;
    }
    lua_pushboolean(L, draw != 0);
    if (!callApi("frame", 1, 1, err, errlen)) return 0;
    if (!draw) { lua_pop(L, 1); return 1; }
    const int w = lemu_width(), h = lemu_height(), n = w * h;
    if (kind == EMU_GBA) {
        size_t len = 0;
        const uint8_t *fb = static_cast<const uint8_t *>(lua_tobuffer(L, -1, &len));
        if (!fb || len < size_t(n) * 4) { lua_pop(L, 1); setErr(err, errlen, "the GBA screen buffer is missing"); return 0; }
        memcpy(rgba, fb, size_t(n) * 4);
        for (int i = 0; i < n; i++) rgba[i * 4 + 3] = 255;
    } else {
        if (!lua_istable(L, -1)) { lua_pop(L, 1); setErr(err, errlen, "the Game Boy screen is missing"); return 0; }
        for (int i = 0; i < n; i++) {
            lua_rawgeti(L, -1, i + 1);
            int s = int(lua_tointeger(L, -1)) & 3;
            lua_pop(L, 1);
            memcpy(rgba + i * 4, SHADES[s], 4);
        }
    }
    lua_pop(L, 1);
    return 1;
}

extern "C" int lemu_audio(int16_t *out, int max) {
    if (!L || kind != EMU_GBA) return 0;
    if (!callApi("audio", 0, 2, nullptr, 0)) return 0;
    size_t len = 0;
    const void *buf = lua_isbuffer(L, -2) ? lua_tobuffer(L, -2, &len) : nullptr;
    int count = int(lua_tointeger(L, -1));
    if (count > int(len / 2)) count = int(len / 2);
    if (count > max) count = max;
    if (buf && count > 0) memcpy(out, buf, size_t(count) * 2);
    lua_pop(L, 2);
    return buf ? count : 0;
}

extern "C" size_t lemu_save(uint8_t **data) {
    *data = nullptr;
    if (!L) return 0;
    if (!callApi("save", 0, 1, nullptr, 0)) return 0;
    size_t len = 0;
    const char *s = lua_isstring(L, -1) ? lua_tolstring(L, -1, &len) : nullptr;
    if (s && len) {
        *data = static_cast<uint8_t *>(malloc(len));
        if (*data) memcpy(*data, s, len); else len = 0;
    } else len = 0;
    lua_pop(L, 1);
    return len;
}

extern "C" void lemu_close(void) {
    if (L) lua_close(L);
    L = nullptr;
    apiRef = LUA_NOREF;
    kind = 0;
}

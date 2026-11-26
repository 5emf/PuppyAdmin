// Puppy Admin's mini games (the MiniGames block of PuppyAdmin.lua: Snake, Stack Drop, Treat Chase,
// Star Pup, Puppy Fighter) in their own Luau VM. The rules are unchanged plain Lua; a small driver
// turns each frame into strings the app draws (same contract as Puppy Admin's games window).
#include "emu_core.h"

#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

#include "Luau/Compiler.h"
#include "lua.h"
#include "lualib.h"
#include "luacode.h"

namespace {
lua_State *G = nullptr;
int apiRef = LUA_NOREF;

// driver: list(), select(id), new(seed), input(action, down), update(dt), release(), frame()
const char *DRIVER = R"LUA(
local MG = ...
local api, mg, state = {}, nil, nil
local function rng(n) return math.random(1, n) end
local kinds, kindIds, fresh = {}, {}, {}
local function kid(k)
    local i = kindIds[k]
    if not i then
        i = #kinds + 1
        if i > 90 then return "!" end
        kinds[i], kindIds[k] = k, i
        local c, r
        if mg.cellSprite then c, r = mg.cellSprite(k) end
        fresh[#fresh + 1] = k .. "," .. tostring(c or -1) .. "," .. tostring(r or -1)
    end
    return string.char(34 + i)
end
local function list(t) if type(t) ~= "table" then return "" end return table.concat(t, ",") end
function api.list()
    local out = {}
    for _, g in ipairs(MG.list) do
        local pads = {}
        for _, a in ipairs({ "left", "up", "down", "right", "rotate", "drop" }) do pads[#pads + 1] = (g.pads and g.pads[a]) or "" end
        local rep = {}
        for a in pairs(g.repeatKeys or {}) do rep[#rep + 1] = a end
        local sfx = g.sfx and (g.sfx.base .. "|" .. list(g.sfx.names)) or ""
        out[#out + 1] = table.concat({ g.id, g.title, g.tab or g.title, g.cols, g.rows, g.help or "", g.sheet or "",
            g.hold and 1 or 0, g.sprites and 1 or 0, g.preview and 1 or 0, list(pads), list(rep), list(g.backdrop), g.splash or "", sfx }, "\t")
    end
    return table.concat(out, "\n")
end
function api.select(id)
    for _, g in ipairs(MG.list) do if g.id == id then mg = g end end
    state, kinds, kindIds, fresh = nil, {}, {}, {}
    return mg and "ok" or "unknown game"
end
function api.new(seed)
    math.randomseed(tonumber(seed) or os.time())
    state = mg.new(rng)
    return "ok"
end
function api.input(a, down) if state then mg.input(state, a, down ~= "0") end return "ok" end
function api.release() if state and mg.releaseAll then mg.releaseAll(state) end return "ok" end
function api.update(dt)
    if not state then return "" end
    mg.update(state, math.min(tonumber(dt) or 0, 0.1))
    local ev = ""
    if state.events and #state.events > 0 then ev = table.concat(state.events, ","); table.clear(state.events) end
    return ev
end
-- cells (one char per cell: kind id + 34), new kinds "name,col,row;...", actors "col,row,x,y,scale,dying;...",
-- hud, banner, over (0/1), score, popups "text,x,y,rise;..." (rise 0..1), stage, splash seconds, preview (8 chars or "")
function api.frame(spritesOn)
    if not state then return "", "", "", mg and mg.title or "", "", "0", "0", "", "1", "0", "" end
    local cols, rows = mg.cols, mg.rows
    local cells = table.create(cols * rows, kid("empty"))
    mg.draw(state, function(x, y, k)
        if x >= 1 and x <= cols and y >= 1 and y <= rows then cells[(y - 1) * cols + x] = kid(k) end
    end, spritesOn == "1")
    local actors = {}
    if mg.actors then
        for _, a in ipairs(mg.actors(state)) do
            local c, r = 0, 0
            if mg.spriteCell then c, r = mg.spriteCell(a) else c, r = -1, -1 end
            actors[#actors + 1] = table.concat({ c or 0, r or 0, a.x or 0, a.y or 0, a.scale or 1, a.dying or 0, a.kind or "" }, ",")
        end
    end
    local pops = {}
    for _, p in ipairs(state.popups or {}) do
        local k = 1 - (p.t or 0) / math.max(p.life or 1, 0.001)
        pops[#pops + 1] = table.concat({ (tostring(p.text or ""):gsub("[,;]", " ")), p.x or 0, p.y or 0, k }, ",")
    end
    local preview = ""
    if mg.preview and not state.over then
        local pk = {}
        for i = 1, 8 do pk[i] = kid("empty") end
        mg.preview(state, function(x, y, k) if x >= 1 and x <= 4 and y >= 1 and y <= 2 then pk[(y - 1) * 4 + x] = kid(k) end end)
        preview = table.concat(pk)
    end
    local nk = table.concat(fresh, ";")
    fresh = {}
    return table.concat(cells), nk, table.concat(actors, ";"), mg.hud(state) or "", (mg.banner and mg.banner(state)) or "",
        state.over and "1" or "0", tostring(math.floor(state.score or 0)), table.concat(pops, ";"), tostring(state.stage or 1),
        tostring(state.splash or 0), preview
end
return api
)LUA";

bool load(lua_State *L, const std::string &src, const char *name, std::string &err) {
    Luau::CompileOptions opts;
    opts.optimizationLevel = 2;
    std::string bc = Luau::compile(src, opts);
    if (luau_load(L, name, bc.data(), bc.size(), 0) != 0) {
        err = lua_tostring(L, -1);
        lua_pop(L, 1);
        return false;
    }
    return true;
}
}  // namespace

int gm_open(const char *src, size_t len, char *err, size_t errlen) {
    if (G) { lua_close(G); G = nullptr; }
    G = luaL_newstate();
    luaL_openlibs(G);
    std::string e;
    if (!load(G, std::string(src, len), "=minigames", e) || lua_pcall(G, 0, 1, 0) != 0) {
        if (e.empty()) e = lua_isstring(G, -1) ? lua_tostring(G, -1) : "the mini games did not load";
        snprintf(err, errlen, "%s", e.c_str());
        lua_close(G); G = nullptr;
        return 0;
    }
    if (!load(G, DRIVER, "=gamesdriver", e)) { snprintf(err, errlen, "%s", e.c_str()); lua_close(G); G = nullptr; return 0; }
    lua_insert(G, -2);
    if (lua_pcall(G, 1, 1, 0) != 0) { snprintf(err, errlen, "%s", lua_tostring(G, -1)); lua_close(G); G = nullptr; return 0; }
    apiRef = lua_ref(G, -1);
    lua_pop(G, 1);
    return 1;
}

int gm_call(const char *fn, const char *const *args, int nargs, std::vector<std::string> &out, std::string &err) {
    out.clear();
    if (!G) { err = "the mini games are not loaded"; return 0; }
    int top = lua_gettop(G);
    lua_rawgeti(G, LUA_REGISTRYINDEX, apiRef);
    lua_getfield(G, -1, fn);
    lua_remove(G, -2);
    for (int i = 0; i < nargs; i++) lua_pushstring(G, args[i]);
    if (lua_pcall(G, nargs, LUA_MULTRET, 0) != 0) {
        err = lua_isstring(G, -1) ? lua_tostring(G, -1) : "error";
        lua_settop(G, top);
        return 0;
    }
    int n = lua_gettop(G) - top;
    for (int i = 1; i <= n; i++) {
        size_t l = 0;
        const char *s = lua_isstring(G, top + i) ? lua_tolstring(G, top + i, &l) : "";
        out.emplace_back(s, l);
    }
    lua_settop(G, top);
    return 1;
}

-- Extra commands test: lua5.4 tools/test_extras.lua PuppyAdmin.lua
-- Runs the UIAPI.Extra block with fake services: pure helpers, command registration,
-- and the time / ambient / hip height round trips.
local src = io.open(arg[1]):read("a")
local a = assert(src:find("-- Extra commands (`UIAPI.Extra`)", 1, true))
local b = assert(src:find("-- Emotes window (`UIAPI.Emotes`", a, true))
local block = src:sub(a, b - 1)

local fails = 0
local function check(c, m) print((c and "ok   " or "FAIL ") .. m) if not c then fails = fails + 1 end end

-- anything Enum.X.Y works and compares by name
local function enumTable(path)
    return setmetatable({}, { __index = function(t, k)
        local v = enumTable(path .. "." .. k)
        rawset(t, k, v)
        return v
    end, __tostring = function() return path end })
end
local Enum = enumTable("Enum")

local function signal()
    local s = { fns = {} }
    function s:Connect(fn)
        local c = { fn = fn }
        table.insert(s.fns, c)
        function c:Disconnect() for i, x in ipairs(s.fns) do if x == c then table.remove(s.fns, i) break end end end
        return c
    end
    function s:Fire(...) for _, c in ipairs({ table.unpack(s.fns) }) do c.fn(...) end end
    return s
end

-- a Lighting whose property writes fire changed signals
local function fakeLighting()
    local props = { ClockTime = 9, Ambient = "amb0", OutdoorAmbient = "out0" }
    local sigs = {}
    local L = {}
    function L:GetPropertyChangedSignal(k) sigs[k] = sigs[k] or signal(); return sigs[k] end
    return setmetatable(L, {
        __index = function(_, k) return props[k] end,
        __newindex = function(_, k, v)
            if props[k] == v then return end
            props[k] = v
            if sigs[k] then sigs[k]:Fire() end
        end,
    }), props
end
local Lighting, LP = fakeLighting()

local notes = {}
local H, cmds, cmdDocs, ALIASES, PLAYER_ARG, cleanups, conns = {}, {}, {}, {}, {}, {}, {}
local hum = { HipHeight = 2, Health = 100, Parent = true }
local char = { FindFirstChildOfClass = function(_, c) if c == "Humanoid" then return hum end end,
    FindFirstChild = function() return nil end }
local plr = { Character = char, CharacterAdded = signal(), UserId = 1, Name = "me", DisplayName = "Me" }
local Players = { GetPlayers = function() return { plr } end, PlayerAdded = signal(),
    GetPlayerByUserId = function() return plr end, GetPlayerFromCharacter = function() return nil end }
plr.Chatted = signal()
local env = setmetatable({
    UIAPI = { panels = {}, finder = { start = function(m) notes.finder = m end } },
    H = H, cmds = cmds, cmdDocs = cmdDocs, ALIASES = ALIASES, PLAYER_ARG = PLAYER_ARG, cleanups = cleanups, conns = conns,
    plr = plr, Players = Players, Enum = Enum,
    game = { GetService = function(_, n) if n == "Lighting" then return Lighting end return {} end },
    TextChatService = { ChatVersion = "legacy" },
    RunService = { Heartbeat = signal(), RenderStepped = signal(), Stepped = signal() },
    UserInputService = {}, ContextActionService = {}, CoreGui = {}, notifGui = {},
    note = function(t, text) notes[#notes + 1] = t .. ": " .. tostring(text) end,
    LIGHT = "light", RED = "red",
    parseToggle = function(v, cur)
        if v == nil then return not cur end
        v = v:lower()
        if v == "on" then return true elseif v == "off" then return false end
        return not cur
    end,
    parseColorArgs = function(args, i)
        local r, g, bb = tonumber(args[i]), tonumber(args[i + 1]), tonumber(args[i + 2])
        if r and g and bb then return r, g, bb, 3 end
        if args[i] == "red" then return 255, 0, 0, 1 end
    end,
    Color3 = { fromRGB = function(r, g, bb) return string.format("rgb(%d,%d,%d)", r, g, bb) end },
    resolveTargets = function() return { plr } end,
}, { __index = _G })
env.table = setmetatable({ clear = function(t) for k in pairs(t) do t[k] = nil end end }, { __index = table })
local fn = assert(load(block, "extras", "t", env))
fn()
local X = env.UIAPI.Extra
check(type(X) == "table", "UIAPI.Extra exists")

-- pure helpers
local cases = { { "14", 14 }, { "14.5", 14.5 }, { "2:30", 2.5 }, { "2:30pm", 14.5 }, { "12am", 0 }, { "12pm", 12 }, { "7am", 7 },
    { "day", 14 }, { "night", 0 }, { "dusk", 18 }, { "24", 24 }, { "25", nil }, { "13pm", nil }, { "2:75", nil }, { "abc", nil }, { "", nil } }
for _, c in ipairs(cases) do
    check(X.parseClock(c[1]) == c[2], string.format("parseClock(%q) = %s", c[1], tostring(c[2])))
end
check(X.formatClock(14.5) == "14:30" and X.formatClock(23.999) == "00:00" and X.formatClock(0) == "00:00", "formatClock")
check(X.clampFov("200") == 120 and X.clampFov("0") == 1 and X.clampFov("90") == 90 and X.clampFov("x") == nil, "clampFov")
check(X.clampCps("100") == 30 and X.clampCps("5.7") == 5 and X.clampCps("0") == 1 and X.clampCps(nil) == nil, "clampCps")
local x, y, z = X.moveVector({ W = true, D = true, E = true })
check(x == 1 and y == 1 and z == -1, "moveVector: W forward (-z), D right, E up")
x, y, z = X.moveVector({ W = true, S = true })
check(x == 0 and y == 0 and z == 0, "moveVector: opposite keys cancel")
local list = {}
for i = 1, 7 do X.push(list, i, 5) end
check(#list == 5 and list[1] == 3 and list[5] == 7, "push keeps the newest entries")
check(X.animNumber("rbxassetid://507771019") == "507771019" and X.animNumber("http://www.roblox.com/asset/?id=180435571") == "180435571"
    and X.animNumber("") == nil, "animNumber")

-- registration: every command has a handler and a help line
local missing = {}
for _, n in ipairs(cmds) do
    if type(H[n]) ~= "function" then missing[#missing + 1] = "handler " .. n end
    if type(cmdDocs[n]) ~= "string" or not cmdDocs[n]:find("^" .. n) then missing[#missing + 1] = "doc " .. n end
end
check(#cmds >= 30 and #missing == 0, "all " .. #cmds .. " commands have a handler and a help line " .. table.concat(missing, ", "))
for alias, target in pairs(ALIASES) do
    if not H[target] then missing[#missing + 1] = alias end
end
check(#missing == 0, "aliases point at real commands")
for _, bad in ipairs({ "facebang", "jerk", "kidnap", "crash", "bang" }) do
    check(H[bad] == nil, "not implemented: " .. bad)
end

-- time: held against the game's clock, untime restores
H.time({ "night" })
check(LP.ClockTime == 0, "time night sets 0")
Lighting.ClockTime = 5 -- the game's day cycle
check(LP.ClockTime == 0, "the game's change is undone while held")
H.untime({})
check(LP.ClockTime == 9, "untime puts the original time back")
H.time({ "18", "once" })
Lighting.ClockTime = 19
check(LP.ClockTime == 19, "time ... once does not hold")
H.untime({})
H.time({ "nonsense" })
check(notes[#notes]:find("time <0%-24") ~= nil, "a bad time gives the usage")

-- ambient
H.ambient({ "red" })
check(LP.Ambient == "rgb(255,0,0)" and LP.OutdoorAmbient == "rgb(255,0,0)", "ambient sets both colours")
Lighting.Ambient = "game"
check(LP.Ambient == "rgb(255,0,0)", "ambient is kept")
H.unambient({})
check(LP.Ambient == "amb0" and LP.OutdoorAmbient == "out0", "unambient restores")

-- hip height
H.hipheight({ "6" })
check(hum.HipHeight == 6, "hipheight 6")
H.hipheight({ "500" })
check(hum.HipHeight == 6 and notes[#notes]:find("0%-100") ~= nil, "out of range is refused")
H.unhipheight({})
check(hum.HipHeight == 2, "unhipheight restores")

-- ping hop goes through Puppy Finder's ping mode
H.pinghop({})
check(notes.finder == "ping", "pinghop asks Puppy Finder for the lowest ping")

-- chat log (legacy chat): messages are kept, capped
for i = 1, X.LOG_CAP + 20 do plr.Chatted:Fire("hello " .. i) end
check(#X.chat == X.LOG_CAP and X.chat[#X.chat].text == "hello " .. (X.LOG_CAP + 20), "chat log keeps the newest " .. X.LOG_CAP)

-- emotes block: pure helpers, favourites file, registration, the command only opens the window
do
    local ea = assert(src:find("-- Emotes window (`UIAPI.Emotes`", 1, true))
    local eb = assert(src:find('-- Optional "Kingdom Hearts" UI style', ea, true))
    local FS = {}
    local panel = { Visible = false }
    local eH, ecmds, edocs, ealias = {}, {}, {}, {}
    local played = 0
    local eenv = setmetatable({
        UIAPI = { panels = { emotes = panel }, sync = function() end }, H = eH, cmds = ecmds, cmdDocs = edocs, ALIASES = ealias,
        cleanups = {}, conns = {}, plr = plr, Enum = Enum, RunService = env.RunService,
        UserInputService = { InputBegan = signal() },
        HttpService = { JSONDecode = function(_, t) return load("return " .. t)() end,
            JSONEncode = function(_, v)
                local parts = {}
                for _, f in ipairs(v) do parts[#parts + 1] = string.format("{id=%q,name=%q,key=%q}", f.id, f.name, f.key) end
                return "{" .. table.concat(parts, ",") .. "}"
            end },
        isfile = function(n) return FS[n] ~= nil end, readfile = function(n) return FS[n] end,
        writefile = function(n, d) FS[n] = d end, isfolder = function() return true end,
    }, { __index = _G })
    FS["PuppyAdmin/emotes.json"] = '{{id="123456",name="Wave",key="F"},{id="123456",name="dup",key=""},{id="x"},{id="rbxassetid://987654",name="Spin",key="bad key"}}'
    assert(load(src:sub(ea, eb - 1), "emotes", "t", eenv))()
    local E = eenv.UIAPI.Emotes
    check(E.parseId("123456") == "123456" and E.parseId("rbxassetid://5915693") == "5915693"
        and E.parseId("https://www.roblox.com/catalog/10214311282/Sidekicks-George-Ezra") == "10214311282"
        and E.parseId("abc") == nil and E.parseId("12") == nil, "emote id from an id, asset link or catalog link")
    check(#E.favs == 2 and E.favs[1].key == "F" and E.favs[2].id == "987654" and E.favs[2].key == "",
        "favourites file: duplicates and bad ids dropped, bad keys cleared")
    local r = E.parseSearch({ data = { { id = 111, name = "A", itemType = "Asset", creatorName = "c" }, { id = 222, itemType = "Bundle" }, { name = "no id" } } })
    check(#r == 1 and r[1].id == "111" and r[1].name == "A", "catalog response parsed, bundles skipped")
    check(E.toggleFav("555", "New") == true and E.isFav("555") and FS["PuppyAdmin/emotes.json"]:find("555") ~= nil, "star adds and saves")
    check(E.toggleFav("555") == false and not E.isFav("555"), "star again removes")
    check(ecmds[1] == "emotes" and #ecmds == 1 and ealias.ugcemotes == "emotes" and ealias.emote == "emotes", "one command, emotes (aliases emote, ugcemotes)")
    eH.emotes({ "123456" })
    check(panel.Visible == true and E.track == nil, "emotes <anything> only opens the window, plays nothing")
    eH.emotes({})
    check(panel.Visible == false, "emotes again closes it")
end

-- shutdown restores without errors
H.time({ "noon" })
for _, c in ipairs(cleanups) do c() end
check(LP.ClockTime == 9, "shutdown puts the time back")

print(fails == 0 and "ALL OK" or (fails .. " FAILED"))
os.exit(fails == 0 and 0 or 1)

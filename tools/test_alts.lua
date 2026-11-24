-- Alt formations test: runs UIAPI.altsSetup from PuppyAdmin.lua under Lua 5.4 with
-- stand-ins for the Roblox types it uses (Vector3, CFrame, Random, files, players).
-- usage (repository root): lua5.4 tools/test_alts.lua PuppyAdmin.lua
local whole = assert(io.open(arg[1] or "PuppyAdmin.lua")):read("a")
local a0 = assert(whole:find("function UIAPI.altsSetup()", 1, true), "UIAPI.altsSetup not found")
local a1 = assert(whole:find("\n%-+\n%-%- Runtime\n", a0), "end of the alts block not found")
local SRC = whole:sub(a0, a1)

------------------------------------------------------------------ Vector3
local V = {}
V.__index = V
local function vec(x, y, z) return setmetatable({ X = x or 0, Y = y or 0, Z = z or 0 }, V) end
V.__add = function(a, b) return vec(a.X + b.X, a.Y + b.Y, a.Z + b.Z) end
V.__sub = function(a, b) return vec(a.X - b.X, a.Y - b.Y, a.Z - b.Z) end
V.__unm = function(a) return vec(-a.X, -a.Y, -a.Z) end
V.__mul = function(a, b)
    if type(a) == "number" then return vec(a * b.X, a * b.Y, a * b.Z) end
    if type(b) == "number" then return vec(a.X * b, a.Y * b, a.Z * b) end
    return vec(a.X * b.X, a.Y * b.Y, a.Z * b.Z)
end
V.__div = function(a, b) return vec(a.X / b, a.Y / b, a.Z / b) end
V.__eq = function(a, b) return a.X == b.X and a.Y == b.Y and a.Z == b.Z end
V.__index = function(t, k)
    if k == "Magnitude" then return math.sqrt(t.X * t.X + t.Y * t.Y + t.Z * t.Z) end
    if k == "Unit" then local m = math.sqrt(t.X * t.X + t.Y * t.Y + t.Z * t.Z); return vec(t.X / m, t.Y / m, t.Z / m) end
    return V[k]
end
function V.Cross(a, b) return vec(a.Y * b.Z - a.Z * b.Y, a.Z * b.X - a.X * b.Z, a.X * b.Y - a.Y * b.X) end
function V.Dot(a, b) return a.X * b.X + a.Y * b.Y + a.Z * b.Z end
local Vector3 = { new = vec, zero = vec(0, 0, 0) }

------------------------------------------------------------------ CFrame (columns r, u, b = right, up, back)
local C = {}
local function cf(p, r, u, b) return setmetatable({ p = p, r = r, u = u, b = b }, C) end
local function rot(m, v) return m.r * v.X + m.u * v.Y + m.b * v.Z end
C.__mul = function(a, b)
    if getmetatable(b) == V then return a.p + rot(a, b) end
    return cf(a.p + rot(a, b.p), rot(a, b.r), rot(a, b.u), rot(a, b.b))
end
C.__index = function(t, k)
    if k == "Position" then return t.p end
    if k == "LookVector" then return -t.b end
    if k == "UpVector" then return t.u end
    if k == "RightVector" then return t.r end
    if k == "Rotation" then return cf(vec(0, 0, 0), t.r, t.u, t.b) end
    return C[k]
end
local I = { r = vec(1, 0, 0), u = vec(0, 1, 0), b = vec(0, 0, 1) }
function C.Inverse(a)
    local r, u, b = a.r, a.u, a.b
    local R = cf(vec(0, 0, 0), vec(r.X, u.X, b.X), vec(r.Y, u.Y, b.Y), vec(r.Z, u.Z, b.Z))
    return cf(-rot(R, a.p), R.r, R.u, R.b)
end
function C.ToObjectSpace(a, b) return a:Inverse() * b end
local function ortho(r, u)
    r = r.Unit; u = (u - r * r:Dot(u)).Unit
    return r, u, r:Cross(u)
end
function C.Lerp(a, b, t)
    local r, u, bb = ortho(a.r + (b.r - a.r) * t, a.u + (b.u - a.u) * t)
    return cf(a.p + (b.p - a.p) * t, r, u, bb)
end
local CFrame = {}
function CFrame.new(x, y, z)
    if getmetatable(x) == V then return cf(x, I.r, I.u, I.b) end
    return cf(vec(x or 0, y or 0, z or 0), I.r, I.u, I.b)
end
local function rx(a) return cf(vec(), vec(1, 0, 0), vec(0, math.cos(a), math.sin(a)), vec(0, -math.sin(a), math.cos(a))) end
local function ry(a) return cf(vec(), vec(math.cos(a), 0, -math.sin(a)), vec(0, 1, 0), vec(math.sin(a), 0, math.cos(a))) end
local function rz(a) return cf(vec(), vec(math.cos(a), math.sin(a), 0), vec(-math.sin(a), math.cos(a), 0), vec(0, 0, 1)) end
function CFrame.Angles(x, y, z) return rx(x) * ry(y) * rz(z) end
function CFrame.fromMatrix(p, r, u, b) return cf(p, r, u, b or r:Cross(u)) end
function CFrame.lookAt(at, target, up)
    up = up or vec(0, 1, 0)
    local back = (at - target).Unit
    local r = up:Cross(back).Unit
    return cf(at, r, back:Cross(r), back)
end

------------------------------------------------------------------ Random, JSON
local Random = {}
function Random.new(seed)
    local s = math.floor(seed) % 2147483647
    if s <= 0 then s = s + 2147483646 end
    return { NextNumber = function(_, a, b)
        s = (s * 16807) % 2147483647
        return a + (b - a) * (s / 2147483647)
    end }
end

local json = {}
function json.encode(v)
    local t = type(v)
    if t == "table" then
        local n = #v
        local isArr = n > 0 or next(v) == nil
        for k in pairs(v) do if type(k) ~= "number" then isArr = false end end
        local out = {}
        if isArr then
            for i = 1, n do out[i] = json.encode(v[i]) end
            return "[" .. table.concat(out, ",") .. "]"
        end
        for k, x in pairs(v) do table.insert(out, string.format("%q:%s", tostring(k), json.encode(x))) end
        table.sort(out)
        return "{" .. table.concat(out, ",") .. "}"
    elseif t == "string" then return string.format("%q", v)
    elseif t == "number" then return (math.type(v) == "integer" or v == math.floor(v)) and string.format("%d", v) or string.format("%.17g", v)
    else return tostring(v) end
end
function json.decode(s)
    local i = 1
    local function ws() i = s:find("[^%s]", i) or #s + 1 end
    local val
    local function str()
        local j = i + 1
        local out = {}
        while true do
            local c = s:sub(j, j)
            if c == '"' then i = j + 1; return table.concat(out) end
            if c == "\\" then j = j + 1; c = s:sub(j, j); if c == "n" then c = "\n" end end
            table.insert(out, c); j = j + 1
        end
    end
    function val()
        ws()
        local c = s:sub(i, i)
        if c == "{" then
            i = i + 1; local o = {}
            ws(); if s:sub(i, i) == "}" then i = i + 1; return o end
            while true do
                ws(); local k = str(); ws(); assert(s:sub(i, i) == ":"); i = i + 1
                o[k] = val(); ws()
                local d = s:sub(i, i); i = i + 1
                if d == "}" then return o end
            end
        elseif c == "[" then
            i = i + 1; local a = {}
            ws(); if s:sub(i, i) == "]" then i = i + 1; return a end
            while true do
                table.insert(a, val()); ws()
                local d = s:sub(i, i); i = i + 1
                if d == "]" then return a end
            end
        elseif c == '"' then return str()
        elseif s:sub(i, i + 3) == "true" then i = i + 4; return true
        elseif s:sub(i, i + 4) == "false" then i = i + 5; return false
        elseif s:sub(i, i + 3) == "null" then i = i + 4; return nil
        else
            local num = s:match("^-?[%d%.eE+-]+", i); i = i + #num; return tonumber(num)
        end
    end
    return val()
end

------------------------------------------------------------------ world: files, players, clock, signals
local FS, NOW, CLOCK = {}, 1800000000, 0
local function newSignal()
    local sig = { fns = {} }
    function sig:Connect(fn)
        local c = { fn = fn, on = true }
        function c:Disconnect() self.on = false end
        table.insert(sig.fns, c)
        return c
    end
    function sig:fire(...) for _, c in ipairs(sig.fns) do if c.on then c.fn(...) end end end
    return sig
end
local Heartbeat, Stepped = newSignal(), newSignal()
local RunService = { Heartbeat = Heartbeat, Stepped = Stepped }

local function part(name)
    return { Name = name, CanCollide = true, CFrame = CFrame.new(0, 3, 0), AssemblyLinearVelocity = vec(), AssemblyAngularVelocity = vec(),
        IsA = function(self, c) return c == "BasePart" end,
        Position = nil }
end
local function character(pos)
    local root = part("HumanoidRootPart")
    root.CFrame = CFrame.new(pos)
    local parts = { root, part("Head"), part("UpperTorso") }
    local hum = { Health = 100, PlatformStand = false }
    return { root = root, hum = hum,
        FindFirstChild = function(_, n) if n == "HumanoidRootPart" then return root end end,
        FindFirstChildOfClass = function(_, c) if c == "Humanoid" then return hum end end,
        GetDescendants = function() return parts end }
end
-- Position follows CFrame
local function rootPos(p) return p.CFrame.Position end

local PLAYERS = {}
local Players = { GetPlayerByUserId = function(_, id) return PLAYERS[id] end }
local function addPlayer(id, name, pos)
    PLAYERS[id] = { UserId = id, Name = name, Character = character(pos) }
    return PLAYERS[id]
end

local tasks, delays = {}, {}
local task = {
    spawn = function(fn) local co = coroutine.create(fn); table.insert(tasks, co); assert(coroutine.resume(co)) end,
    wait = function() coroutine.yield() end,
    delay = function(_, fn) table.insert(delays, fn) end,
}
local function runTasks() for _, co in ipairs(tasks) do if coroutine.status(co) == "suspended" then assert(coroutine.resume(co)) end end end
local function runDelays() local d = delays; delays = {}; for _, fn in ipairs(d) do fn() end end

local game = { PlaceId = 1818, JobId = "job-A" }
local os2 = { time = function() return NOW end, clock = function() return CLOCK end }

------------------------------------------------------------------ one Puppy Admin copy per account
local function instance(userId)
    local notes = {}
    local tbl = {}
    for k, v in pairs(table) do tbl[k] = v end
    tbl.find = function(t, v) for i = 1, #t do if t[i] == v then return i end end end
    local function splitArgs(str)
        local a = {}
        for w in tostring(str):gmatch("%S+") do a[#a + 1] = w end
        return a
    end
    local function resolveTargets(tok)
        if not tok or tok == "" then return { PLAYERS[userId] } end
        local l = tostring(tok):lower()
        for _, p in pairs(PLAYERS) do if p.Name:lower():sub(1, #l) == l then return { p } end end
        return {}
    end
    local env = {
        UIAPI = { panels = {}, syncFns = {} }, H = {}, cleanups = {}, conns = {},
        Cfg = { altForm = {}, altLite = false, altVcAuto = false, altWhitelist = {}, prefixes = { "." } },
        cmds = {}, cmdDocs = {}, ALIASES = {}, Perf = { t0 = 0 }, VCB = { state = "idle", run = function() end },
        splitArgs = splitArgs, resolveTargets = resolveTargets, setfpscap = nil,
        gcinfo = function() return 0 end, collectgarbage = function() return 0 end,
        workspace = { GetRealPhysicsFPS = function() return 60 end },
        Enum = setmetatable({}, { __index = function() return setmetatable({}, { __index = function() return 0 end }) end }),
        Instance = { new = function() return { Destroy = function() end, Play = function() end, Stop = function() end } end },
        genv = { PuppyAdminActive = true },
        plr = PLAYERS[userId], Players = Players, RunService = RunService, game = game,
        HttpService = { JSONEncode = function(_, v) return json.encode(v) end, JSONDecode = function(_, s) return json.decode(s) end },
        isfile = function(p) return FS[p] ~= nil end, readfile = function(p) return assert(FS[p]) end,
        writefile = function(p, c) FS[p] = c end, isfolder = function() return true end, makefolder = function() end,
        note = function(t, m) table.insert(notes, t .. ": " .. m) end, cfgSave = function() end,
        LIGHT = "light", RED = "red", PAL = { GOOD = "good", DIM = "dim" }, Color3 = { fromRGB = function() return "c" end },
        Vector3 = Vector3, CFrame = CFrame, Random = Random, task = task, os = os2,
        math = math, string = string, pairs = pairs, ipairs = ipairs, type = type, tonumber = tonumber,
        tostring = tostring, pcall = pcall, setmetatable = setmetatable, next = next, error = error,
    }
    env.table = tbl
    env.UIAPI.togglePanel = function() end
    local chunk = assert(load(SRC, "alts", "t", env))
    chunk()
    env.UIAPI.altsSetup()
    env.notes = notes
    return env
end

------------------------------------------------------------------ tests
local fails = 0
local function check(ok, msg) if not ok then fails = fails + 1; print("FAIL " .. msg) end end
local function finite(v) return v == v and v > -1e6 and v < 1e6 end

-- 1. shape math: finite, orthonormal, above the floor, apart
local probe = (function()
    addPlayer(1, "Main", vec(0, 3, 0))
    FS["PuppyAdmin/companion/roster.json"] = json.encode({ main = { userId = 1, name = "Main" }, alts = {} })
    return instance(1)
end)()
local A = probe.UIAPI.Alts
local sizes = { 0.5, 1, 2, 3 }
local worstFloor, worstGap = {}, {}
for name, fn in pairs(A.SHAPES) do
    worstFloor[name], worstGap[name] = 1e9, 1e9
    for n = 1, 12 do
        for _, s in ipairs(sizes) do
            for step = 0, 40 do
                local t = step * 0.37
                local cfs = {}
                for i = 0, n - 1 do
                    local st = { rng = Random.new(1000 + i), clock = t }
                    local c = fn(i, n, t, s, st)
                    local p = c.Position
                    check(finite(p.X) and finite(p.Y) and finite(p.Z), name .. " finite")
                    local d = math.abs(c.r:Dot(c.u)) + math.abs(c.u:Dot(c.b)) + math.abs(c.r.Magnitude - 1) + math.abs(c.u.Magnitude - 1)
                    check(d < 1e-6, name .. " orthonormal " .. d)
                    -- body from feet (3 studs down its up axis) to head top (2.4 up); the main's floor is y = -3
                    local low = math.min(p.Y - 3 * c.u.Y, p.Y + 2.4 * c.u.Y)
                    if name ~= "scatter" then worstFloor[name] = math.min(worstFloor[name], low) end
                    cfs[i + 1] = p
                end
                if s >= 1 and name ~= "scatter" then
                    for a = 1, n do for b = a + 1, n do
                        worstGap[name] = math.min(worstGap[name], (cfs[a] - cfs[b]).Magnitude)
                    end end
                end
            end
        end
    end
end
local names = {}
for k in pairs(worstFloor) do table.insert(names, k) end
table.sort(names)
for _, k in ipairs(names) do
    print(string.format("%-8s lowest body point %6.2f (floor -3)   closest two alts %s", k, worstFloor[k] == 1e9 and 0 or worstFloor[k],
        worstGap[k] == 1e9 and "-" or string.format("%.2f", worstGap[k])))
    if k ~= "scatter" then check(worstFloor[k] >= -3.3, k .. " goes under the floor") end
end

-- presets and layer split
check(A.findPreset("wings").key == "wings" and A.findPreset("WINGS + HALO").key == "wingshalo", "preset lookup")
check(A.findPreset("s") == nil and A.findPreset("sp").key == "spiral", "prefix lookup")
local L = A.assign(A.findPreset("wingshalo"), { 11, 12, 13, 14, 15 })
check(#L == 2 and L[1].form == "halo" and #L[1].ids == 2 and L[2].form == "wings" and #L[2].ids == 3, "wings+halo split 5")
L = A.assign(A.findPreset("wingshalo"), { 11, 12, 13 })
check(#L == 1 and L[1].form == "wings" and #L[1].ids == 3, "wings+halo with 3 alts is all wings")

-- 2. command round trip: main + three alts in one server, one alt elsewhere
PLAYERS = {}
addPlayer(1, "Main", vec(10, 3, 20))
addPlayer(2, "AltA", vec(0, 3, 0)); addPlayer(3, "AltB", vec(5, 3, 0)); addPlayer(4, "AltC", vec(-5, 3, 0))
FS = {}
FS["PuppyAdmin/companion/roster.json"] = json.encode({ main = { userId = 1, name = "Main" },
    alts = { { userId = 2, name = "AltA" }, { userId = 3, name = "AltB" }, { userId = 4, name = "AltC" }, { userId = 5, name = "AltD" } } })
local function report(id, job) FS["PuppyAdmin/companion/" .. id .. ".json"] = json.encode({ userId = id, jobId = job or "job-A", online = true, time = NOW }) end
report(2); report(3); report(4)
tasks = {}
local main = instance(1)
local alts = { instance(2), instance(3), instance(4) }
check(main.UIAPI.Alts.role() == "main" and alts[1].UIAPI.Alts.role() == "alt", "roles")
addPlayer(6, "AltNoScript", vec(0, 3, -9))
FS["PuppyAdmin/companion/roster.json"] = json.encode({ main = { userId = 1, name = "Main" },
    alts = { { userId = 2, name = "AltA" }, { userId = 3, name = "AltB" }, { userId = 4, name = "AltC" }, { userId = 5, name = "AltD" }, { userId = 6, name = "AltNoScript" } } })
main.UIAPI.Alts.loadRoster(true)
local ids = main.UIAPI.Alts.present()
check(#ids == 3 and ids[1] == 2 and ids[3] == 4, "only alts running Puppy Admin get a place (" .. #ids .. ")")
check(select(1, main.UIAPI.Alts.describe(6)) == "here, Puppy Admin not running", "alt without the script is flagged")
report(4) -- keep AltC fresh

-- an alt cannot lead
check(alts[1].UIAPI.Alts.start("wings") == false, "alt cannot start")
check(FS["PuppyAdmin/companion/altcmd.json"] == nil, "alt wrote no command")

main.Cfg.altForm.size = 1
check(main.H.form({ "wings" }) == nil, "form command runs")
local cmd = json.decode(FS["PuppyAdmin/companion/altcmd.json"])
check(cmd.action == "cmd" and cmd.cmd == "form" and cmd.jobId == "job-A" and #cmd.layers == 1 and #cmd.layers[1].ids == 3, "command written")
runTasks() -- alts read it
for k, a in ipairs(alts) do check(a.UIAPI.Alts.state ~= nil, "alt " .. k .. " following") end

-- frames: alts glide in, then sit exactly at their places
for f = 1, 40 do CLOCK = CLOCK + 1 / 60; Stepped:fire(); Heartbeat:fire(1 / 60) end
local mroot = PLAYERS[1].Character.root
for k, a in ipairs(alts) do
    local st = a.UIAPI.Alts.state
    local want = a.UIAPI.Alts.levelFrame(mroot, 0.1) * a.UIAPI.Alts.SHAPES.wings(st.index, st.count, st.t, 1, st)
    local got = PLAYERS[k + 1].Character.root.CFrame
    check((got.Position - want.Position).Magnitude < 1e-6, "alt " .. k .. " at its place")
    check(PLAYERS[k + 1].Character.hum.PlatformStand == true, "alt " .. k .. " platform-standing")
    check(PLAYERS[k + 1].Character:GetDescendants()[2].CanCollide == false, "alt " .. k .. " noclip")
    print(string.format("alt %d (index %d): %.2f studs from the main", k, st.index, (got.Position - mroot.CFrame.Position).Magnitude))
end
-- the main moves and turns: the shape comes along
mroot.CFrame = CFrame.new(vec(40, 3, -10)) * CFrame.Angles(0, 1.2, 0)
for f = 1, 5 do Heartbeat:fire(1 / 60) end
local d = (PLAYERS[2].Character.root.CFrame.Position - mroot.CFrame.Position).Magnitude
check(d < 12, "shape follows the main (" .. d .. ")")

-- settings change reaches the alts
main.Cfg.altForm.glitch = true
main.UIAPI.Alts.settingsChanged(); runDelays(); runTasks()
check(alts[1].UIAPI.Alts.state.params.glitch == true, "glitch reached the alt")

-- general target command: circle on a player
main.H.alt({ "circle", "AltB" })  -- AltB is userId 3
runTasks()
cmd = json.decode(FS["PuppyAdmin/companion/altcmd.json"])
check(cmd.action == "cmd" and cmd.cmd == "circle" and cmd.target == 3 and cmd.center == "target", "circle command written")
check(alts[1].UIAPI.Alts.state and alts[1].UIAPI.Alts.state.cmd == "circle", "alt runs circle")
for f = 1, 10 do Heartbeat:fire(1 / 60) end
do
    local troot = PLAYERS[3].Character.root
    local a2 = PLAYERS[2].Character.root.CFrame.Position
    check((a2 - troot.CFrame.Position).Magnitude < 20, "alt circles near the target")
end

-- numbered variant keeps its style
main.H.alt({ "orbit3" })
runTasks()
cmd = json.decode(FS["PuppyAdmin/companion/altcmd.json"])
check(cmd.cmd == "orbit" and cmd.params.style == 3, "orbit3 sends style 3")

-- a one-shot command (jump) fires on the alts and does not pin them
main.H.alt({ "jump" })
runTasks()
check(PLAYERS[2].Character.hum.Jump == true, "jump reached the alt")
check(alts[1].UIAPI.Alts.state.once == true, "jump is a one-shot (no pinning job)")

-- say fires once and is NOT kept as the resending command (the "spams and never stops" bug)
main.H.alt({ "say", "hello" })
runTasks()
local sayRaw = FS["PuppyAdmin/companion/altcmd.json"]
local sayCmd = json.decode(sayRaw)
check(sayCmd.action == "cmd" and sayCmd.cmd == "say" and sayCmd.params.text == "hello", "say written once")
check(main.UIAPI.Alts.active == nil, "say does not stay the active command")
CLOCK = CLOCK + 12
runTasks(); runTasks()
check(FS["PuppyAdmin/companion/altcmd.json"] == sayRaw, "say is not rewritten (no 5s spam)")

-- a trailing space in the target no longer breaks resolution (common from the box / phone keyboards)
main.H.alt({ "circle", "AltB " })
runTasks()
check(json.decode(FS["PuppyAdmin/companion/altcmd.json"]).target == 3, "target with a trailing space still resolves")
main.H.unform()
runTasks()

-- the declined commands are absent
check(main.UIAPI.Alts.SPECS.bang == nil and main.UIAPI.Alts.resolveName("bang") == nil, "bang is not registered")
check(main.UIAPI.Alts.SPECS.fbang == nil and main.UIAPI.Alts.SPECS.mbang == nil, "fbang/mbang are not registered")

-- low-power mode: the alt still places itself (throttled), no error
do
    altsLiteMain = main  -- keep reference
    main.Cfg.altLite = true
    main.H.form({ "ring" })
    runTasks()
    alts[1].Cfg.altLite = true
    for f = 1, 20 do Heartbeat:fire(1 / 60) end
    local st = alts[1].UIAPI.Alts.state
    check(st and st.cmd == nil and st.form == "ring", "lite: alt follows the ring")
    check(PLAYERS[2].Character.hum.PlatformStand == true, "lite: alt still placed")
    main.Cfg.altLite = false
    main.H.form({ "wings" }); runTasks()  -- back to wings for the following tests
    for f = 1, 40 do Heartbeat:fire(1 / 60) end
end

-- an alt joins: everyone gets a place
addPlayer(5, "AltD", vec(0, 3, 9))
local altD = instance(5)
CLOCK = CLOCK + 3 -- the main's 2 s liveness cache runs out
report(5)
CLOCK = CLOCK + 1; runTasks() -- main loop notices (0.5 s ticks are one resume each here)
runTasks()
cmd = json.decode(FS["PuppyAdmin/companion/altcmd.json"])
check(#cmd.layers[1].ids == 4, "late alt included (" .. #cmd.layers[1].ids .. ")")
check(altD.UIAPI.Alts.state ~= nil and altD.UIAPI.Alts.state.count == 4, "late alt following")

-- the main stops: alts land beside it
main.H.unform()
runTasks()
for k, a in ipairs(alts) do
    check(a.UIAPI.Alts.state == nil, "alt " .. k .. " stopped")
    check(PLAYERS[k + 1].Character.hum.PlatformStand == false, "alt " .. k .. " standing again")
    local y = PLAYERS[k + 1].Character.root.CFrame.Position.Y
    check(math.abs(y - mroot.CFrame.Position.Y) < 1e-6, "alt " .. k .. " landed at the main's height")
end

-- a stale command (the main's game crashed) is ignored
report(2); report(3); report(4); report(5)
main.H.form({ "halo" }); runTasks()
check(alts[1].UIAPI.Alts.state ~= nil, "halo started")
NOW = NOW + 60
for f = 1, 2 do Heartbeat:fire(1 / 60) end
check(alts[1].UIAPI.Alts.state == nil, "stale command stops the alts")

-- another server's command is ignored
NOW = NOW + 1
CLOCK = CLOCK + 3; report(2); report(3); report(4); report(5)
main.Cfg.altForm.glitch = false
main.H.form({ "ring" })
local raw = FS["PuppyAdmin/companion/altcmd.json"]
FS["PuppyAdmin/companion/altcmd.json"] = raw:gsub("job%-A", "job-B")
runTasks()
check(alts[2].UIAPI.Alts.state == nil, "command for another server ignored")

-- main shutdown sends stop
FS["PuppyAdmin/companion/altcmd.json"] = raw
alts[1].UIAPI.Alts.lastRaw = nil; alts[2].UIAPI.Alts.lastRaw = nil
runTasks()
check(alts[2].UIAPI.Alts.state ~= nil, "ring started")
for i = #main.cleanups, 1, -1 do main.cleanups[i]() end
runTasks()
check(alts[2].UIAPI.Alts.state == nil, "main shutdown stops the alts")
check(json.decode(FS["PuppyAdmin/companion/altcmd.json"]).action == "stop", "stop written on shutdown")

-- 3. the Alts window builds and fills in (stand-in widgets)
do
    local made = {}
    local function obj(parent, props)
        local o = props or {}
        o.children = {}
        o.Parent = parent or true
        function o:GetChildren() return self.children end
        function o:IsA(c) return c == "GuiObject" end
        function o:Destroy() self.dead = true; self.Parent = nil end
        function o:GetPropertyChangedSignal() return { Connect = function(_, fn) o.onVisible = fn end } end
        if type(parent) == "table" and parent.children then table.insert(parent.children, o) end
        table.insert(made, o)
        return o
    end
    local E = main
    E.UDim2 = { fromOffset = function(x, y) return { x, y } end, new = function(a, b, c, d) return { a, b, c, d } end }
    E.UDim = { new = function(a, b) return { a, b } end }
    E.Enum = setmetatable({}, { __index = function(_, k) return setmetatable({}, { __index = function(_, v) return k .. "." .. v end }) end })
    E.make = function(_, props, parent) return obj(parent, props) end
    E.corner = function() end
    E.label = function(parent, props) return obj(parent, props) end
    E.uiWindow = function(_, key) local f = obj(true, { Visible = false }); E.UIAPI.panels[key] = f; return f end
    E.uiButton = function(parent, text, _, _, onClick) return obj(parent, { Text = text, click = onClick }) end
    E.uiSwitch = function(parent, text, _, _, value, onChange)
        local s = obj(parent, { Text = text, value = value, onChange = onChange })
        function s.set(v) s.value = v end
        return s
    end
    E.uiSlider = function(parent, text, _, _, o)
        local s = obj(parent, { Text = text, o = o, value = o.value })
        function s.set(v) s.value = v end
        function s.isDragging() return false end
        return s
    end
    E.uiDropdown = function(parent, prefix, _, _, options, index, onSelect)
        local d = obj(parent, { options = options, index = index, onSelect = onSelect })
        function d.set(i) d.index = i end
        function d.get() return d.index end
        return d
    end
    E.uiBox = function(parent, pos, size, ph) return obj(parent, { Text = "", placeholder = ph }) end
    report(2); report(3); report(4); report(5)
    CLOCK = CLOCK + 3
    E.UIAPI.buildAltsPanel({})
    local f = E.UIAPI.panels.alts
    check(f ~= nil, "window registered")
    f.Visible = true
    f.onVisible()
    local status, rows, startBtn, dd
    for _, o in ipairs(made) do
        if type(o.Text) == "string" and o.Text:find("You lead", 1, true) then status = o end
        if o.Text == "ready, in this server" then rows = (rows or 0) + 1 end
        if o.click and (o.Text == "Start" or o.Text == "Restart") then startBtn = o end
        if o.options then dd = o end
    end
    check(status ~= nil, "status line says you lead")
    if status then print("window status: " .. status.Text) end
    check(rows == 4, "four alts listed as ready (" .. tostring(rows) .. ")")
    check(#dd.options == 11, "eleven shapes in the list")
    -- pick Star from the list and press Start: the alts get a star
    dd.index = 4 -- the real list sets its choice, then calls back
    dd.onSelect(4)
    startBtn.click()
    runTasks()
    check(alts[1].UIAPI.Alts.state and alts[1].UIAPI.Alts.state.form == "star", "Start from the window sends the chosen shape")
    -- a slider change goes out after the short delay
    for _, o in ipairs(made) do
        if o.o and o.Text == "Size" then o.o.onChange(2) end
    end
    runDelays(); runTasks()
    check(alts[1].UIAPI.Alts.state.params.size == 2, "Size slider reaches the alts")

    -- the Commands tab lives in the same window: a target box and a circle button
    local circleBtn, targetBox, tabBtn
    for _, o in ipairs(made) do
        if o.placeholder and tostring(o.placeholder):find("Target", 1, true) then targetBox = o end
        if o.click and o.Text == "circle" then circleBtn = o end
        if o.click and o.Text == "Commands" then tabBtn = o end
    end
    check(tabBtn ~= nil, "window has a Commands tab")
    check(circleBtn ~= nil, "Commands tab has a circle button")
    check(targetBox ~= nil, "Commands tab has a target box")
    if targetBox and circleBtn then
        targetBox.Text = "AltB"
        circleBtn.click()
        runTasks()
        local c = json.decode(FS["PuppyAdmin/companion/altcmd.json"])
        check(c.cmd == "circle" and c.target == 3, "circle button uses the target box")
    end
    -- altcmds opens the same window on the Commands tab (no second panel)
    E.H.altcmds()
    check(E.UIAPI.panels.alts ~= nil and E.UIAPI.panels.altcmds == nil, "altcmds reuses the one Alts window")
end

print(fails == 0 and "ALL OK" or (fails .. " FAILED"))
os.exit(fails == 0 and 0 or 1)

-- Limb animations test: lua5.4 tools/test_limbs.lua PuppyAdmin.lua
-- Runs the Limbs block from PuppyAdmin.lua with a tiny CFrame and fake reanim engine.
local src = io.open(arg[1]):read("a")
local a = assert(src:find("-- Limb animations (`limbs`", 1, true))
local b = assert(src:find("-- Command directory tabs: every command has one category", a, true))
local block = src:sub(a, b - 1)

-- minimal CFrame / Vector3 (rotation as 3x3 rows)
local V3 = {}
V3.__index = V3
local function vec(x, y, z) return setmetatable({ X = x, Y = y, Z = z }, V3) end
V3.__add = function(p, q) return vec(p.X + q.X, p.Y + q.Y, p.Z + q.Z) end
V3.__sub = function(p, q) return vec(p.X - q.X, p.Y - q.Y, p.Z - q.Z) end
function V3:len() return math.sqrt(self.X ^ 2 + self.Y ^ 2 + self.Z ^ 2) end
local CF = {}
CF.__index = function(t, k)
    if k == "Position" then return vec(t.p[1], t.p[2], t.p[3]) end
    return CF[k]
end
local function mk(p, r) return setmetatable({ p = p, r = r }, CF) end
local I = { { 1, 0, 0 }, { 0, 1, 0 }, { 0, 0, 1 } }
local function matmul(A, B)
    local C = {}
    for i = 1, 3 do C[i] = {} for j = 1, 3 do C[i][j] = A[i][1] * B[1][j] + A[i][2] * B[2][j] + A[i][3] * B[3][j] end end
    return C
end
CF.__mul = function(A, B)
    local p = {}
    for i = 1, 3 do p[i] = A.p[i] + A.r[i][1] * B.p[1] + A.r[i][2] * B.p[2] + A.r[i][3] * B.p[3] end
    return mk(p, matmul(A.r, B.r))
end
function CF:ToOrientation() return 0, math.atan(self.r[1][3], self.r[3][3]), 0 end
local CFrame = {
    new = function(x, y, z)
        if type(x) == "table" then return mk({ x.X, x.Y, x.Z }, I) end
        return mk({ x or 0, y or 0, z or 0 }, I)
    end,
    Angles = function(rx, ry, rz)
        local cx, sx, cy, sy, cz, sz = math.cos(rx), math.sin(rx), math.cos(ry), math.sin(ry), math.cos(rz), math.sin(rz)
        local X = { { 1, 0, 0 }, { 0, cx, -sx }, { 0, sx, cx } }
        local Y = { { cy, 0, sy }, { 0, 1, 0 }, { -sy, 0, cy } }
        local Z = { { cz, -sz, 0 }, { sz, cz, 0 }, { 0, 0, 1 } }
        return mk({ 0, 0, 0 }, matmul(matmul(X, Y), Z))
    end,
}

local fails = 0
local function check(c, m) print((c and "ok   " or "FAIL ") .. m) if not c then fails = fails + 1 end end

-- fake instances
local function part(name)
    return { Name = name, Anchored = false, CanCollide = true, CFrame = CFrame.new(0, 3, 0), Parent = true,
        IsA = function(_, c) return c == "BasePart" end }
end
local function motor(name) return { Name = name, Enabled = true, Parent = true, IsA = function(_, c) return c == "Motor6D" end } end
local R15 = { "Head", "UpperTorso", "LowerTorso", "LeftUpperArm", "LeftLowerArm", "LeftHand", "RightUpperArm", "RightLowerArm",
    "RightHand", "LeftUpperLeg", "LeftLowerLeg", "LeftFoot", "RightUpperLeg", "RightLowerLeg", "RightFoot" }
local function body(withPuppet)
    local kids, desc = {}, {}
    local root = part("HumanoidRootPart")
    root.CFrame = CFrame.new(10, 3, 20)
    kids[#kids + 1] = root
    for _, n in ipairs(R15) do kids[#kids + 1] = part(n) end
    for i = 1, 15 do desc[#desc + 1] = motor("Joint" .. i) end
    if withPuppet then
        root.puppet = motor("PuppetRoot")
    end
    for _, k in ipairs(kids) do desc[#desc + 1] = k end
    return {
        root = root, kids = kids, desc = desc, Parent = true,
        GetChildren = function() return kids end, GetDescendants = function() return desc end,
        FindFirstChild = function(_, n) if n == "HumanoidRootPart" then return root end end,
    }
end
root_find = nil
local reanimated = true
local clone, real = body(false), body(false)
clone.root.FindFirstChild = function(_, n) if n == "PuppetRoot" then return clone.root.puppet end end
local api = { is_reanimated = function() return reanimated end, get_clone = function() return clone end,
    get_real_character = function() return real end }
local function signal()
    local s = { fns = {} }
    function s:Connect(f) local c = { f = f } function c.Disconnect() c.f = nil end table.insert(s.fns, c) return c end
    function s:fire(...) for _, c in ipairs(s.fns) do if c.f then c.f(...) end end end
    return s
end
local RS = signal()
local notes = {}
local env = setmetatable({
    UIAPI = {}, CFrame = CFrame, Vector3 = { new = vec }, RunService = { RenderStepped = RS },
    pupApi = function() return api end, note = function(t, m) notes[#notes + 1] = m end, LIGHT = 1, RED = 2,
    cleanups = {}, cmds = {}, cmdDocs = {}, ALIASES = {}, H = {},
    genv = { PuppyAdminActive = false }, conns = {}, cfgSave = function() end,
    task = { spawn = function(f) f() end, wait = function() end, defer = function(f) f() end },
}, { __index = _G })
env.table = setmetatable({ find = function(t, v) for i, x in ipairs(t) do if x == v then return i end end end }, { __index = table })
assert(load(block, "limbs", "t", env))()
local L = env.UIAPI.Limbs

-- shapes: every mode gives 15 distinct, finite, nearby positions
for _, mode in ipairs(L.MODES) do
    local pts, ok = {}, true
    for i = 1, 15 do
        local cf = L.offset(mode, i, 15, 1.3, 1)
        local p = cf.Position
        if not (p.X == p.X and p.Y == p.Y and p.Z == p.Z) or p:len() > 30 then ok = false end
        pts[i] = p
    end
    local minD = math.huge
    for i = 1, 15 do for j = i + 1, 15 do minD = math.min(minD, (pts[i] - pts[j]):len()) end end
    check(ok and minD > 0.3, string.format("%-8s 15 parts apart (closest %.2f studs)", mode, minD))
end

-- start on a ragdolled game (shared): the clone's 15 parts get driven, joints off
local okStart, msg = L.start("helix")
check(okStart and msg:find("everyone sees", 1, true), "start: shared when the game ragdolled you")
local motorsOff = true
for _, d in ipairs(clone.desc) do if d.Name:find("Joint") and d.Enabled then motorsOff = false end end
check(motorsOff, "clone joints switched off")
local anchored = 0
for _, k in ipairs(clone.kids) do if k.Name ~= "HumanoidRootPart" and k.Anchored then anchored = anchored + 1 end end
check(anchored == 15 and not clone.root.Anchored, "15 clone parts anchored, the root still walks")
RS:fire(1 / 60)
local head = clone.kids[2]
check((head.CFrame.Position - clone.root.CFrame.Position):len() > 1, "parts placed around the root each frame")
check(real.kids[2].Anchored == false, "the real body is left to the engine")
L.stop()
check(not L.on and clone.kids[2].Anchored == false and clone.desc[1].Enabled == true, "put back: unanchored, joints on")

-- a game that does not ragdoll you (puppet): real body moved on your screen only
clone.root.puppet = motor("PuppetRoot")
local ok2, msg2 = L.start("orbit")
check(ok2 and msg2:find("only you", 1, true) and real.kids[2].Anchored and not clone.kids[2].Anchored, "puppet: real body, only you see it")
L.stop(true)
clone.root.puppet = nil

-- not reanimated / stops by itself when reanim ends
reanimated = false
check(L.start("orbit") == false, "refuses without reanim")
reanimated = true
L.start("float")
reanimated = false
RS:fire(1 / 60)
check(not L.on and clone.kids[2].Anchored == false, "stops and restores when reanim ends")

print(fails == 0 and "ALL OK" or (fails .. " FAILED"))
os.exit(fails == 0 and 0 or 1)

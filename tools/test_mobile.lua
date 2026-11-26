-- Mobile mode test: lua5.4 tools/test_mobile.lua PuppyAdmin.lua
-- Runs the UIAPI.Mobile block with fakes: detection and modes, the scale for a screen size,
-- keeping windows on screen, window / HUD scales, and the floating show / hide button.
local src = io.open(arg[1]):read("a")
local a = assert(src:find("-- Mobile / touch (`UIAPI.Mobile`", 1, true))
local b = assert(src:find("-- Corner grip: drag the bottom-right corner", a, true))
local block = src:sub(a, b - 1)

local fails = 0
local function check(c, m) print((c and "ok   " or "FAIL ") .. m) if not c then fails = fails + 1 end end

local function sig()
    local s = { fns = {} }
    function s:Connect(f) local c = { f = f } function c:Disconnect() c.f = nil end table.insert(s.fns, c) return c end
    function s:fire(...) for _, c in ipairs(s.fns) do if c.f then c.f(...) end end end
    return s
end
local v2mt = {}
local function v2(x, y) return setmetatable({ X = x, Y = y }, v2mt) end
v2mt.__sub = function(p, q) return v2(p.X - q.X, p.Y - q.Y) end
local u2mt = {}
local function u2(sx, ox, sy, oy) return setmetatable({ X = { Scale = sx, Offset = ox }, Y = { Scale = sy, Offset = oy } }, u2mt) end
u2mt.__add = function(p, q) return u2(p.X.Scale + q.X.Scale, p.X.Offset + q.X.Offset, p.Y.Scale + q.Y.Scale, p.Y.Offset + q.Y.Offset) end

local Inst = {}
local function new(class, props)
    local o = { ClassName = class, Name = class, children = {} }
    for k, v in pairs(props or {}) do o[k] = v end
    o.InputBegan = sig()
    return setmetatable(o, { __index = Inst, __newindex = function(t, k, v)
        if k == "Parent" then rawset(t, "Parent", v); if v then table.insert(v.children, t) end else rawset(t, k, v) end
    end })
end
function Inst:FindFirstChild(n) for _, c in ipairs(self.children) do if c.Name == n then return c end end end
function Inst:FindFirstAncestorOfClass(cl) local p = self.Parent while p do if p.ClassName == cl then return p end p = p.Parent end end
function Inst:Destroy() rawset(self, "Parent", nil); self.gone = true end
local function make(class, props, parent) local o = new(class, props); if parent then o.Parent = parent end return o end

local UIS = { TouchEnabled = true, KeyboardEnabled = false, InputChanged = sig(), InputEnded = sig() }
local camSig, wsSig = sig(), sig()
local cam = { ViewportSize = v2(844, 390), GetPropertyChangedSignal = function() return camSig end }
local Cfg = { mobileMode = "auto", mobileButton = {}, windowScales = { menu = 1.5 }, barHidden = false }
local saved, hidden, bar, notes = 0, false, nil, {}
local H = {}
local delayed = {}
local env = setmetatable({
    UIAPI = { setBarVisible = function(on) bar = on end }, Cfg = Cfg, H = H, conns = {}, cleanups = {},
    UserInputService = UIS, workspace = { CurrentCamera = cam, GetPropertyChangedSignal = function() return wsSig end },
    make = make, corner = function() end, stroke = function() end,
    isPointer = function(i) return i.UserInputType == "Touch" or i.UserInputType == "MouseButton1" end,
    Instance = { new = function(c) return new(c) end }, parentGui = function(g) g.Parent = new("CoreGui") end,
    Hide = { uiHidden = false, setUI = function(h) hidden = h end }, cfgSave = function() saved = saved + 1 end,
    note = function(_, m) notes[#notes + 1] = m end, LIGHT = "l", RED = "r",
    Color3 = { fromRGB = function() return "c" end, new = function() return "c" end },
    UDim2 = { new = u2, fromOffset = function(x, y) return u2(0, x, 0, y) end }, Vector2 = { new = v2 },
    Enum = setmetatable({}, { __index = function() return setmetatable({}, { __index = function(_, k) return k end }) end }),
    task = { defer = function(f) f() end, delay = function(t, f) delayed[#delayed + 1] = f end },
    os = setmetatable({ clock = function() return 1 end }, { __index = os }),
}, { __index = _G })
assert(load(block, "mobile", "t", env))()
local M = env.UIAPI.Mobile

-- detection and modes
check(M.touchDevice() and M.on(), "auto: a touch device without a keyboard is mobile")
UIS.KeyboardEnabled = true
check(not M.on(), "auto: a keyboard means desktop")
Cfg.mobileMode = "on"
check(M.on(), "on: always")
Cfg.mobileMode = "off"; UIS.KeyboardEnabled = false
check(not M.on() and M.factor() == 1, "off: never, no scaling")
Cfg.mobileMode = "auto"

-- the scale for a screen
check(M.factorFor(1920, 1080) == 1 and M.factorFor(800, 560) == 1, "a big screen: full size")
check(math.abs(M.factorFor(844, 390) - 390 / 560) < 1e-9, "a phone in landscape: scaled to its height")
check(M.factorFor(320, 200) == M.MIN, "never smaller than the minimum")
check(math.abs(M.factor() - 390 / 560) < 1e-9, "the factor follows the camera's viewport")

-- keeping boxes on screen
local dx, dy = M.nudge(-50, 20, 200, 100, 800, 400)
check(dx == 56 and dy == 0, "off the left edge: pushed back in")
dx, dy = M.nudge(700, 350, 200, 100, 800, 400)
check(dx == -106 and dy == -56, "off the bottom right: pulled back in")
dx, dy = M.nudge(10, -30, 1000, 600, 800, 400)
check(dx == -110 and dy == 36, "bigger than the screen: centred across, top kept on screen")
local sg = new("ScreenGui", { AbsoluteSize = v2(800, 400), AbsolutePosition = v2(0, 0) })
local win = make("Frame", { AbsolutePosition = v2(-50, 20), AbsoluteSize = v2(200, 100), Position = u2(0.5, -150, 0.5, 0) }, sg)
M.clamp(win)
check(win.Position.X.Offset == -94 and win.Position.X.Scale == 0.5, "clamp moves the window by the overshoot")

-- window and HUD scales follow the factor
local uiw = new("UIScale", { Scale = 1 }); uiw.Parent = win
M.register(win, uiw, "menu")
local hud = new("Frame")
local uih = M.scaleOf(hud)
M.applyAll()
local k = 390 / 560
check(math.abs(uiw.Scale - 1.5 * k) < 1e-9, "a window: its own grip scale x the mobile factor")
check(math.abs(uih.Scale - k) < 1e-9 and M.scaleOf(hud) == uih, "a HUD: the mobile factor, one UIScale")
cam.ViewportSize = v2(1280, 720); camSig:fire()
check(uiw.Scale == 1.5 and uih.Scale == 1, "rotating / resizing the screen re-scales")
cam.ViewportSize = v2(844, 390); camSig:fire()

-- the floating button
check(M.btnGui and M.button, "mobile: the floating button is there")
local btn = M.button
btn.InputBegan:fire({ UserInputType = "Touch", Position = v2(10, 10) })
UIS.InputEnded:fire({ UserInputType = "Touch", Position = v2(10, 10) })
check(hidden == true, "a tap hides the UI")
btn.InputBegan:fire({ UserInputType = "Touch", Position = v2(10, 10) })
delayed[#delayed]()
UIS.InputEnded:fire({ UserInputType = "Touch", Position = v2(10, 10) })
check(bar ~= nil and hidden == true, "holding it shows / hides the command bar instead")
btn.InputBegan:fire({ UserInputType = "Touch", Position = v2(10, 10) })
UIS.InputChanged:fire({ UserInputType = "Touch", Position = v2(80, 60) })
UIS.InputEnded:fire({ UserInputType = "Touch", Position = v2(80, 60) })
check(Cfg.mobileButton.x == btn.Position.X.Offset and saved > 0 and hidden == true, "dragging moves it, saves where, and does not toggle")
local ok = M.set("off")
check(ok and Cfg.mobileMode == "off" and M.btnGui == nil and math.abs(uiw.Scale - 1.5) < 1e-9, "mobile off: no button, normal sizes")
H.mobile({ "on" })
check(Cfg.mobileMode == "on" and M.btnGui ~= nil, "mobile on (command)")

print(fails == 0 and "ALL OK" or (fails .. " FAILED"))
os.exit(fails == 0 and 0 or 1)

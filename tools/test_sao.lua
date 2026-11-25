-- Sword Art Online UI style test: lua5.4 tools/test_sao.lua PuppyAdmin.lua
-- Runs the UIAPI.SAOStyle block with fake instances: helpers, the look on windows (square
-- corners, orange hover, capital titles) and its undo, the icon menu, and the slanted HP bar HUD.
local src = io.open(arg[1]):read("a")
local a = assert(src:find("-- Sword Art Online-inspired UI style", 1, true))
local b = assert(src:find("-- Extra commands (`UIAPI.Extra`)", a, true))
local block = src:sub(a, b - 1)

local fails = 0
local function check(c, m) print((c and "ok   " or "FAIL ") .. m) if not c then fails = fails + 1 end end

local function sig()
    local s = { fns = {} }
    function s:Connect(f) local c = { f = f } function c:Disconnect() c.f = nil end table.insert(s.fns, c) return c end
    function s:fire(...) for _, c in ipairs(s.fns) do if c.f then c.f(...) end end end
    return s
end
local u2mt = {}
local function u2(sx, ox, sy, oy) return setmetatable({ X = { Scale = sx, Offset = ox }, Y = { Scale = sy, Offset = oy } }, u2mt) end
u2mt.__add = function(p, q) return u2(p.X.Scale + q.X.Scale, p.X.Offset + q.X.Offset, p.Y.Scale + q.Y.Scale, p.Y.Offset + q.Y.Offset) end
local UDim2 = { new = u2, fromOffset = function(x, y) return u2(0, x, 0, y) end, fromScale = function(x, y) return u2(x, 0, y, 0) end }

local Inst = {}
local function new(class, props)
    local o = { ClassName = class, Name = class, children = {}, attrs = {}, BackgroundTransparency = 0, Visible = true, Enabled = true }
    for k, v in pairs(props or {}) do o[k] = v end
    o.MouseEnter, o.MouseLeave, o.MouseButton1Click, o.DescendantAdded = sig(), sig(), sig(), sig()
    return setmetatable(o, { __index = Inst, __newindex = function(t, k, v)
        if k == "Parent" then
            rawset(t, "Parent", v)
            if v then table.insert(v.children, t) end
        else rawset(t, k, v) end
    end })
end
function Inst:IsA(c) return self.ClassName == c end
function Inst:GetAttribute(k) return self.attrs[k] end
function Inst:SetAttribute(k, v) self.attrs[k] = v end
function Inst:FindFirstChild(n) for _, c in ipairs(self.children) do if c.Name == n then return c end end end
function Inst:FindFirstChildOfClass(cl) for _, c in ipairs(self.children) do if c.ClassName == cl then return c end end end
function Inst:FindFirstAncestor() return nil end
function Inst:GetDescendants()
    local out = {}
    local function walk(o) for _, c in ipairs(o.children) do out[#out + 1] = c; walk(c) end end
    walk(self)
    return out
end
function Inst:Destroy()
    if self.Parent then for i, c in ipairs(self.Parent.children) do if c == self then table.remove(self.Parent.children, i) break end end end
    rawset(self, "Parent", nil)
end
local function make(class, props, parent) local o = new(class, props); if parent then o.Parent = parent end return o end

-- a window as Puppy Admin builds it
local screen = new("ScreenGui", { Name = "PuppyAdminGui" }); screen.Parent = new("CoreGui")
local win = make("Frame", { Name = "settings" }, screen); win.attrs.PuppyAdminWindow = true
local title = make("TextLabel", { Text = "Settings" }, win); title.attrs.PuppyAdminTitle = true
local corner = make("UICorner", { CornerRadius = { Scale = 0, Offset = 12 } }, win)
local btn = make("TextButton", { Text = "Go", BackgroundColor3 = "grey", TextColor3 = "black", BackgroundTransparency = 0.2 }, win)
make("UICorner", { CornerRadius = { Scale = 0, Offset = 8 } }, btn)

local hum = new("Humanoid", { Health = 50, MaxHealth = 100 })
local char = new("Model"); hum.Parent = char
local head = new("Part", { Name = "Head", Position = { X = 0, Y = 5, Z = 0 } }); head.Parent = char
head.Position = setmetatable(head.Position, { __add = function(p, q) return { X = p.X + q.X, Y = p.Y + q.Y, Z = p.Z + q.Z } end })
local heartbeat = sig()
local applied, sounds, opened = {}, {}, {}
local gui
local env = setmetatable({
    UIAPI = { MenuSound = { play = function(k) sounds[#sounds + 1] = k end }, Cursor = { set = function(n) applied.cursor = n end },
        Menu = { CATEGORIES = {
            { "Character", "Reanimate, move.", { { "Reanim", "reanim", "Animations." }, { "Limbs", "limbs", "Body parts." } } },
            { "Config", "Settings.", { { "General", "settings", "Prefixes." } } },
        }, open = function(t) opened[#opened + 1] = t end, total = function() return 7300 end, clockText = function() return "9:41 PM" end } },
    Theme = { roots = { screen }, usePreset = function(n) applied.preset = n return true end },
    UIFont = { set = function(n) applied.font = n end, make = function(n) return { family = n } end, attach = function() end },
    plr = { UserId = 7, DisplayName = "Pup", Character = char },
    make = make, label = function(parent, props) return make("TextLabel", props, parent) end,
    Instance = { new = function(c) local o = new(c); if c == "ScreenGui" then gui = gui or o end return o end },
    parentGui = function(g) g.Parent = new("CoreGui") end, makeDraggable = function() end,
    urlImageAsset = function(u) return "asset:" .. u end, SETTINGS = { Auras = { assetBase = "https://repo/" } },
    TweenService = { Create = function(_, obj, _, goal) return { Play = function() for k, v in pairs(goal) do obj[k] = v end end } end },
    TweenInfo = { new = function() return {} end },
    RunService = { Heartbeat = heartbeat, RenderStepped = sig() }, cleanups = {},
    Vector3 = { new = function(x, y, z) return { X = x, Y = y, Z = z } end },
    workspace = { CurrentCamera = { ViewportSize = { X = 1920, Y = 1080 },
        WorldToViewportPoint = function(_, p) return { X = 900, Y = 400 }, true end } },
    task = { defer = function(f) f() end, delay = function(_, f) f() end, spawn = function() end, wait = function() end },
    Color3 = { fromRGB = function(r, g, bb) return string.format("rgb(%d,%d,%d)", r, g, bb) end, new = function(r, g, bb) return string.format("c(%g,%g,%g)", r, g, bb) end },
    UDim = { new = function(s, o) return { Scale = s, Offset = o } end }, UDim2 = UDim2,
    Vector2 = { new = function(x, y) return { X = x, Y = y } end },
    Enum = setmetatable({}, { __index = function() return setmetatable({}, { __index = function(_, k) return k end }) end }),
}, { __index = _G })
assert(load(block, "sao", "t", env))()
local A = env.UIAPI.SAOStyle

-- helpers
check(A.iconOffset("character") == 0 and A.iconOffset("config") == 7 * 64 and A.iconOffset("close") == 8 * 64 and A.iconOffset("?") == 6 * 64, "icon cells")
local r, g = A.hpRGB(0.9)
local r2 = A.hpRGB(0.3)
local r3 = A.hpRGB(0.1)
check(g == 200 and r2 == 240 and r3 == 230, "HP bar colours: green, yellow, red")
check(A.level(0) == 1 and A.level(3599) == 1 and A.level(7300) == 3 and A.level(-5) == 1, "level = hours of PUPPYTIME + 1")
check(A.litDots(50, 100, 12) == 6 and A.litDots(100, 100, 12) == 12 and A.litDots(1, 100, 12) == 1 and A.litDots(0, 100, 12) == 0
    and A.litDots(5, 0, 12) == 0 and A.litDots(0 / 0, 100, 12) == 0, "ring dots follow HP")
check(A.dotAngle(1, 12) == 0 and A.dotAngle(4, 12) == 90, "dots go clockwise from the top")
check(A.dropDelay(1) == 0 and A.dropDelay(3) > A.dropDelay(2), "icons drop in one after another")

-- beside the head
local x, y = A.anchorFor(900, 400, 1920, 1080, 900, 600, 390, 0)
check(x + 390 == 900 + A.HEAD_GAP and y == 400 - A.HEAD_RISE, "the icon column sits just right of the head")
local cx0, cy0 = A.anchorFor(nil, nil, 1920, 1080, 900, 600, 390, 0)
check(cx0 == 510 and cy0 == 240, "no head in view: centred")
local ex = A.anchorFor(1910, 400, 1920, 1080, 900, 600, 390, 0)
check(ex + 390 <= 1920 - 40, "near the screen edge the column stays on screen")

-- the look
A.apply(true)
check(applied.preset == "Sword Art Online" and applied.font == "SAO UI" and applied.cursor == "Default", "theme, SAO UI font, normal cursor")
check(corner.CornerRadius.Offset == 0 and btn:FindFirstChildOfClass("UICorner").CornerRadius.Offset == 0, "square corners")
check(title.Text == "SETTINGS" and win:FindFirstChild("PuppySAOLine") ~= nil, "capital titles and the orange line")
btn.MouseEnter:fire()
check(btn.BackgroundColor3 == A.ORANGE and btn.TextColor3 == "c(1,1,1)" and sounds[#sounds] == "move", "hover: orange, white text, move sound")
btn.MouseLeave:fire()
check(btn.BackgroundColor3 == "grey" and btn.TextColor3 == "black", "leave: own colours back")
btn.MouseButton1Click:fire()
check(sounds[#sounds] == "select", "click: select sound")
A.apply(false)
check(corner.CornerRadius.Offset == 12 and btn:FindFirstChildOfClass("UICorner").CornerRadius.Offset == 8, "off: corners rounded again")
check(title.Text == "Settings" and win:FindFirstChild("PuppySAOLine") == nil, "off: title and line restored")
btn.MouseEnter:fire()
check(btn.BackgroundColor3 == "grey", "off: no orange hover")

-- the icon menu
A.apply(true)
check(A.toggleMenu() == true, "menu opens")
local m = A.menu
check(m.root.Position.X.Offset + 390 == 900 + A.HEAD_GAP, "the menu opens beside the head")
check(m.gui:FindFirstChild("Backdrop") == nil and m.gui:FindFirstChild("Stripe") == nil, "no backdrop or stripe: the game stays visible")
check(#m.icons == 2 and m.close and #m.dots == 12, "one round icon per category, a close icon, 12 dots")
check(#m.rows == 2 and m.icons[1].btn.BackgroundColor3 == A.ORANGE and m.icons[1].halo.Visible, "first category chosen: orange with a ring, its windows listed")
check(m.lowTitle.Text == "Character", "the card describes the chosen category")
m.icons[2].btn.MouseButton1Click:fire()
check(m.current == 2 and #m.rows == 1 and m.icons[2].btn.BackgroundColor3 == A.ORANGE and m.icons[1].btn.BackgroundColor3 ~= A.ORANGE, "choosing another category")
m.rows[1].MouseEnter:fire()
check(m.rows[1].BackgroundColor3 == A.ORANGE and m.lowText.Text == "Prefixes.", "hovering a window: orange plate, its description")
m.rows[1].MouseButton1Click:fire()
check(opened[1] == "settings" and m.gui.Enabled == false, "clicking it opens the window and closes the menu")
A.toggleMenu()
m.refresh()
local lit = 0
for _, d in ipairs(m.dots) do if d.BackgroundColor3 == A.ORANGE then lit = lit + 1 end end
check(lit == 6 and m.stats.Text:find("HP 50/100", 1, true) and m.stats.Text:find("Lv 3", 1, true), "ring dots and stats follow HP and PUPPYTIME")
m.close.btn.MouseButton1Click:fire()
check(m.gui.Enabled == false, "the close icon closes it")

-- the HUD
local hud = A.hudOn()
check(hud.clip.Size.X.Offset == 200 and hud.fill.ImageColor3 == "rgb(240,205,60)" and hud.hpText.Text == "50 / 100" and hud.lv.Text == "Lv 3",
    "slanted HP bar: half full, yellow, numbers, level")
hum.Health = 100
heartbeat:fire(0.2)
check(hud.clip.Size.X.Offset == 400 and hud.fill.ImageColor3 == "rgb(110,200,80)", "full health: full and green")
A.hudOff()
check(A.hud == nil, "HUD removed")

print(fails == 0 and "ALL OK" or (fails .. " FAILED"))
os.exit(fails == 0 and 0 or 1)

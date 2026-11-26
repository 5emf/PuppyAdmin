-- Kingdom Hearts UI style smoke test: lua5.4 tools/test_khstyle.lua PuppyAdmin.lua (fake Roblox objects)
local src = io.open(arg[1]):read("a")
local a = assert(src:find('-- Optional "Kingdom Hearts" UI style', 1, true))
local b = assert(src:find("-- Command directory tabs: every command has one category", a, true))
local block = src:sub(a, b - 1)
local function V2(x, y) return { X = x, Y = y, __v2 = true } end
local v2mt = { __add = function(p, q) return V2(p.X + q.X, p.Y + q.Y) end }
local function vec(x, y) return setmetatable(V2(x, y), v2mt) end
-- tiny instance tree
local Inst = {}
Inst.__index = Inst
local function new(class, props)
    local o = setmetatable({ ClassName = class, Name = class, children = {}, Visible = true, Enabled = true,
        BackgroundTransparency = 0, AbsoluteSize = vec(200, 30), AbsolutePosition = vec(100, 50), IgnoreGuiInset = false }, Inst)
    for k, v in pairs(props or {}) do o[k] = v end
    return o
end
function Inst:IsA(c) return self.ClassName == c or (c == "GuiObject" and self.ClassName ~= "UICorner" and self.ClassName ~= "UIGradient" and self.ClassName ~= "UIStroke") end
function Inst:GetChildren() local t = {} for i, c in ipairs(self.children) do t[i] = c end return t end
function Inst:GetAttribute(k) return self.attrs and self.attrs[k] end
function Inst:SetAttribute(k, v) self.attrs = self.attrs or {}; self.attrs[k] = v end
function Inst:FindFirstChild(n) for _, ch in ipairs(self.children) do if ch.Name == n then return ch end end end
function Inst:SetParent(p) self.Parent = p; table.insert(p.children, self) end
function Inst:GetDescendants() local out = {} local function walk(o) for _, c in ipairs(o.children) do out[#out + 1] = c; walk(c) end end walk(self) return out end
function Inst:FindFirstChildOfClass(c) for _, ch in ipairs(self.children) do if ch.ClassName == c then return ch end end end
function Inst:FindFirstAncestor(n) local p = self.Parent while p do if p.Name == n then return p end p = p.Parent end end
function Inst:FindFirstAncestorOfClass(c) local p = self.Parent while p do if p.ClassName == c then return p end p = p.Parent end end
function Inst:IsDescendantOf() return true end
function Inst:Destroy() if self.Parent then for i, c in ipairs(self.Parent.children) do if c == self then table.remove(self.Parent.children, i) break end end end self.Parent = nil end
local function sig() local s = { fns = {} } function s:Connect(f) local c = { f = f } function c.Disconnect() c.f = nil end table.insert(s.fns, c) return c end function s:fire(...) for _, c in ipairs(s.fns) do if c.f then c.f(...) end end end return s end
local mt = getmetatable(new("Frame")) 
setmetatable(Inst, { __index = function(_, k) end })
local _new = new
new = function(class, props)
    local o = _new(class, props)
    o.MouseEnter, o.MouseLeave, o.DescendantAdded, o.MouseButton1Click, o.Changed = sig(), sig(), sig(), sig(), sig()
    o.ZIndex = o.ZIndex or 1
    o.__newindexhook = true
    setmetatable(o, { __index = Inst, __newindex = function(t, k, v) if k == "Parent" and v then rawset(t, "Parent", v); table.insert(v.children, t) else rawset(t, k, v) end end })
    return o
end
local screen = new("ScreenGui", { Name = "PuppyAdminGui" }); screen.Parent = new("CoreGui")
local win = new("Frame", { AbsoluteSize = vec(300, 400) }); win.Parent = screen
win.attrs = { PuppyAdminWindow = true }
local title = new("TextLabel", { Text = "Settings" }); title.Parent = win
title.attrs = { PuppyAdminTitle = true }
new("UICorner").Parent = win
local btn = new("TextButton", { AbsoluteSize = vec(120, 28), AbsolutePosition = vec(140, 90), BackgroundColor3 = "navy", BackgroundTransparency = 0.3 }); btn.Parent = win
local small = new("Frame", { AbsoluteSize = vec(20, 20) }); small.Parent = win
-- a rounded button and a rounded panel: they take the new shapes
local rb = new("TextButton", { AbsoluteSize = vec(120, 28), BackgroundColor3 = "blue", BackgroundTransparency = 0.2, Text = "Go",
    TextTransparency = 0, TextColor3 = "white" }); rb.Parent = win
new("UICorner").Parent = rb
local rf = new("Frame", { AbsoluteSize = vec(200, 40), BackgroundColor3 = "card", BackgroundTransparency = 0.1 }); rf.Parent = win
new("UICorner").Parent = rf
local rs = sig()
-- UDim2 with Scale / Offset and +
local u2mt = {}
local function u2(sx, ox, sy, oy) return setmetatable({ X = { Scale = sx, Offset = ox }, Y = { Scale = sy, Offset = oy } }, u2mt) end
u2mt.__add = function(a, b) return u2(a.X.Scale + b.X.Scale, a.X.Offset + b.X.Offset, a.Y.Scale + b.Y.Scale, a.Y.Offset + b.Y.Offset) end
U2 = { new = u2, fromOffset = function(x, y) return u2(0, x, 0, y) end, fromScale = function(x, y) return u2(x, 0, y, 0) end }
local applied = {}
local env = setmetatable({
    UIAPI = { Cursor = { set = function(n) applied.cursor = n return true end } }, Cfg = { uiStyle = "Standard", uiFont = "Default", cursor = "Default", theme = { preset = "Midnight" } },
    Theme = { roots = { screen }, usePreset = function(n) applied.preset = n return true end, listeners = {},
        current = { bg = "bg1", surface = "surf1", accent = "acc1", text = "txt1", dim = "dim1", border = "bor1", on = "on1", elevated = "elev1" } },
    UIFont = { set = function(n) applied.font = n return true end, make = function(n) return { family = n } end, applyTo = function() end, attach = function(r) applied.fontRoot = r end },
    Rect = { new = function(...) return { ... } end }, Font = { fromEnum = function() return { family = "Gotham" } end },
    plr = { UserId = 42, DisplayName = "Pup", Character = nil }, makeDraggable = function() end,
    H = {}, cmds = {}, cmdDocs = {}, ALIASES = {}, pupApi = function() return nil end, note = function() end,
    genv = { PuppyAdminActive = false }, conns = {}, cfgSave = function() end,
    Instance = { new = function(c) return new(c) end }, make = function(c, p, parent) local o = new(c, p); if parent then o.Parent = parent end return o end,
    parentGui = function(g) g.Parent = new("CoreGui") end, RunService = { RenderStepped = rs },
    SETTINGS = { Auras = { assetBase = "https://x/" } }, urlImageAsset = function(u) return "asset:" .. u end,
    task = { spawn = function(f) f() end, defer = function(f) f() end }, game = { GetService = function() return { GetGuiInset = function() return vec(0, 36) end } end },
    ColorSequence = { new = function(a, b) return { a, b } end }, Color3 = { new = function() return {} end, fromRGB = function() return {} end },
    UDim2 = U2, Vector2 = { zero = vec(0, 0), new = function(x, y) return vec(x, y) end },
    UDim = { new = function(a, b) return { a, b } end },
    Enum = setmetatable({}, { __index = function() return setmetatable({}, { __index = function(_, k) return k end }) end }), cleanups = {}, cfgSave = function() applied.saved = (applied.saved or 0) + 1 end,
}, { __index = _G })
env.math = setmetatable({ clamp = function(x, lo, hi) return math.max(lo, math.min(hi, x)) end }, { __index = math })
assert(load(block, "kh", "t", env))()
local K = env.UIAPI.KHStyle
local ok = K.set("Kingdom Hearts")
local function check(c, m) print((c and "ok   " or "FAIL ") .. m) if not c then os.exit(1) end end
check(ok and env.Cfg.uiStyle == "Kingdom Hearts", "style on")
check(applied.preset == "Kingdom Hearts" and applied.font == "KH Menu" and applied.cursor == "Glove", "theme, font and glove cursor chosen")
check(env.Cfg.khPrev.preset == "Midnight" and env.Cfg.khPrev.font == "Default", "previous look remembered")
check(type(env.Cfg.khPrev) == "table", "kept in a table so it survives a re-execute")
check(btn:FindFirstChildOfClass("UIGradient") and win:FindFirstChildOfClass("UIGradient"), "button and window shaded")
check(not small:FindFirstChildOfClass("UIGradient"), "small frames left alone")
check(win:FindFirstChild("PuppyKHPanelFill") and win:FindFirstChild("PuppyKHPanelRim") and win:FindFirstChild("PuppyKHPill")
    and win:FindFirstChild("PuppyKHUnderline"), "windows get the ornate panel, title capsule and underline")
check(win:FindFirstChild("PuppyKHUnderline").ImageColor3 == K.UNDERLINE, "the underline stays orange whatever the theme")
check(win:FindFirstChild("PuppyKHPanelFill").ImageColor3 == "surf1" and win:FindFirstChild("PuppyKHPanelRim").ImageColor3 == "acc1", "window panel tinted by the theme")
check(title.Text == "SETTINGS" and title.FontFace and title.FontFace.family == "KH Gummi", "window titles in KH Gummi capitals")
local heard = {}
env.UIAPI.MenuSound = { play = function(kind) heard[#heard + 1] = kind end }
btn.MouseEnter:fire(); rs:fire()
btn.MouseButton1Click:fire()
check(table.concat(heard, ",") == "move,select", "menu sounds: moving onto a button, then clicking it")
check(K.glove.Visible and K.glove.Position.X.Offset < 140 and math.abs(K.glove.Position.Y.Offset - (90 + 36 + 14 - K.glove.Size.Y.Offset * 0.39)) < 1e-6, "glove points at the hovered button (inset counted)")
check(btn.BackgroundColor3 == K.SELECT and btn:FindFirstChild("PuppyKHSelect") ~= nil, "hovered button turns red with a red outline")
btn.MouseLeave:fire(); rs:fire()
check(not K.glove.Visible, "glove hides when the mouse leaves")
local face, rtext = rb:FindFirstChild("PuppyKHFace"), rb:FindFirstChild("PuppyKHText")
check(face and rb:FindFirstChild("PuppyKHButtonRim") and rtext and not rb:FindFirstChildOfClass("UIGradient"), "rounded button: new face, rim and text")
check(rb.BackgroundTransparency == 1 and rb.TextTransparency == 1 and face.ImageColor3 == "blue" and face.ImageTransparency == 0.2
    and rtext.Text == "Go" and rtext.TextColor3 == "white" and rtext.ZIndex > face.ZIndex, "the face takes the button's colour, its text sits on top")
rb.MouseEnter:fire(); rb.Changed:fire("BackgroundColor3"); rb.Changed:fire("BackgroundTransparency")
check(face.ImageColor3 == K.SELECT and rb:FindFirstChild("PuppyKHSelect") and rb.BackgroundTransparency == 1, "hover: the face turns red, red outline")
rb.MouseLeave:fire(); rb.Changed:fire("BackgroundColor3")
check(face.ImageColor3 == "blue" and face.ImageTransparency == 0.2 and rb.BackgroundTransparency == 1, "leave: its own colour back")
rb.Text = "Stop"; rb.Changed:fire("Text")
check(rtext.Text == "Stop", "text changes follow")
local box = rf:FindFirstChild("PuppyKHFace")
check(box and rf:FindFirstChild("PuppyKHBoxRim") and box.ImageColor3 == "card" and rf.BackgroundTransparency == 1, "rounded panel: the framed box")
check(btn.BackgroundColor3 ~= K.SELECT and btn:FindFirstChild("PuppyKHSelect") == nil, "leaving restores the button's own colours")
local late = new("TextButton"); late.Parent = win; screen.DescendantAdded:fire(late)
check(late:FindFirstChildOfClass("UIGradient") ~= nil, "buttons made later are styled too")
applied = {}
K.set("Standard")
check(env.Cfg.uiStyle == "Standard" and applied.preset == "Midnight" and applied.font == "Default" and applied.cursor == "Default", "off restores the previous look")
check(not btn:FindFirstChildOfClass("UIGradient") and not win:FindFirstChildOfClass("UIGradient") and K.gui == nil, "all KH decorations removed")
check(not win:FindFirstChild("PuppyKHPanelFill") and title.Text == "Settings" and not title:GetAttribute("PuppyAdminKeepFont"), "window frame removed, title restored")
check(rb.BackgroundTransparency == 0.2 and rb.TextTransparency == 0 and not rb:FindFirstChild("PuppyKHFace") and not rb:FindFirstChild("PuppyKHText")
    and rf.BackgroundTransparency == 0.1 and not rf:FindFirstChild("PuppyKHFace"), "off: rounded buttons and panels as they were")

-- self HUD
local S = env.UIAPI.SelfHud
check(S.litCount(100, 100, 36) == 36 and S.litCount(50, 100, 36) == 18 and S.litCount(1, 100, 36) == 1, "HP ring: lit segments follow health")
check(S.litCount(0, 100, 36) == 0 and S.litCount(150, 100, 36) == 36 and S.litCount(5, 0, 36) == 0 and S.litCount(0/0, 100, 36) == 0, "HP ring: odd values are safe")
local refused, why = S.set(true)
check(refused == false and why:find("Kingdom Hearts", 1, true) and S.gui == nil and not env.Cfg.selfHud, "self HUD is locked without the KH style")
env.UIAPI.SelfHud = S
K.set("Kingdom Hearts")
local hum = new("Humanoid", { Health = 25, MaxHealth = 100 })
env.plr.Character = new("Model"); hum.Parent = env.plr.Character
env.UIAPI.openForCommand = function(n) applied.opened = n end
local okHud = S.set(true)
check(okHud and env.Cfg.selfHud == true and S.gui ~= nil and #S.segs == 36, "self HUD builds with 36 segments")
-- the ring is gone: the companion's KH shapes instead (status card, square portrait, straight HP bar, slab commands)
local names = {}
for _, d in ipairs(S.gui:GetDescendants()) do names[d.Name] = true end
check(not names.PuppyKHRingFill and not names.PuppyKHRingRim and names.PuppyKHCardHead and names.PuppyKHBoxFill and names.PuppyKHBoxRim,
    "no ring: a status card with a name plate and framed boxes")
local sameRow = true
for i = 2, #S.segs do if S.segs[i].Position.Y.Offset ~= S.segs[1].Position.Y.Offset or S.segs[i].Position.X.Offset <= S.segs[i - 1].Position.X.Offset then sameRow = false end end
check(sameRow and (S.segs[1].Rotation or 0) == 0, "HP segments run in a straight bar, left to right")
local slab = S.buttons[1]
check(slab:GetAttribute("PuppyKHSlab") and slab:FindFirstChild("PuppyKHSlab") and slab.BackgroundTransparency == 1, "COMMAND entries are menu slabs")
slab.MouseEnter:fire(); rs:fire(1 / 60)
check(K.target == slab and K.glove.Visible and slab.BackgroundTransparency == 1 and slab:FindFirstChild("PuppyKHSelect") == nil,
    "hovering a slab: the glove points, no red rectangle")
check(slab:FindFirstChild("PuppyKHSlab").Image == K.img.slabHover, "the slab lights up")
slab.MouseLeave:fire(); rs:fire(1 / 60)
check(slab:FindFirstChild("PuppyKHSlab").Image == K.img.slab and not K.glove.Visible, "and goes back")
K.slabState(slab, "chosen")
check(slab:FindFirstChild("PuppyKHSlab").Image == K.img.slabSel, "the chosen entry is red")
K.restTarget = function() return slab end
rs:fire(1 / 60)
check(K.glove.Visible, "the glove rests on the chosen entry when nothing is hovered")
K.restTarget = nil
K.slabState(slab, "plain")
rs:fire(1 / 60)
S.update(30)
check(S.lit == 9 and S.hp.text.Text == "HP  25 / 100" and S.fps.text.Text == "FPS  30", "HUD shows health, segments and FPS")
check(S.fps.fill.BackgroundColor3 == "acc1" and S.hp.back.BackgroundColor3 == "bg1" and S.title.TextColor3 == "txt1"
    and S.segs[30].BackgroundColor3 == "elev1", "HUD takes its colours from the theme")
check(applied.fontRoot == S.gui, "HUD follows the chosen font and text size")
-- a theme change repaints everything, including the tinted art
env.Theme.current = { bg = "bg2", surface = "surf2", accent = "acc2", text = "txt2", dim = "dim2", border = "bor2", on = "on2", elevated = "elev2" }
for _, fn in ipairs(env.Theme.listeners) do fn() end
local fillImg
for _, d in ipairs(S.gui:GetDescendants()) do if d.Name == "PuppyKHPanelFill" then fillImg = d end end
check(S.fps.fill.BackgroundColor3 == "acc2" and S.title.TextColor3 == "txt2" and fillImg and fillImg.ImageColor3 == "surf2", "theme change repaints the HUD and its panels")
hum.Health = 90
S.update(60)
check(S.segs[1].BackgroundColor3 == "on2", "full-health segments use the theme's 'on' colour")
check(S.segs[1].BackgroundColor3 ~= S.segs[36].BackgroundColor3, "lit and unlit segments differ")
K.set("Standard")
check(S.gui == nil and env.Cfg.selfHud == true, "turning the KH style off hides the HUD but remembers it")
K.set("Kingdom Hearts")
check(S.gui ~= nil, "turning the KH style back on brings the HUD back")
S.set(false)
check(S.gui == nil and env.Cfg.selfHud == false, "self HUD removed")
K.set("Standard")
-- the menu's TIME is your local clock time
local Mn = env.UIAPI.Menu
check(Mn.formatClock(21, 41) == "9:41 PM" and Mn.formatClock(0, 5) == "12:05 AM" and Mn.formatClock(12, 0) == "12:00 PM"
    and Mn.formatClock(9, 7) == "9:07 AM", "clock: 12-hour local time")
env.DateTime = { now = function() return { ToLocalTime = function() return { Hour = 15, Minute = 4 } end } end }
check(Mn.clockText() == "3:04 PM", "TIME reads the device's local time")
env.DateTime = nil
check(Mn.clockText():match("^%d+:%d%d [AP]M$") ~= nil, "falls back to the device date when DateTime is missing")

-- PUPPYTIME: active use, only while the Roblox window is focused; the total is kept in Cfg
check(Mn.formatDuration(125) == "2:05" and Mn.formatDuration(3725) == "1:02:05" and Mn.formatDuration(-3) == "0:00",
    "durations read m:ss / h:mm:ss")
env.Cfg.puppyTime = 100
Mn.session = 0
Mn.focused = true
Mn.tick(2)
check(Mn.session == 2 and Mn.total() == 102, "counts while focused, adds to the saved total")
Mn.focused = false
Mn.tick(5)
check(Mn.session == 2 and Mn.total() == 102, "tabbed out: not counted")
Mn.focused = true
Mn.tick(600)
check(Mn.session == 2, "a long hitch (sleep, freeze) is not counted")

-- party cards: you first, the main next (when you are an alt), then the alts
check(table.concat(Mn.partyIds(5, { main = 5, alts = { 6, 7, 8, 9 } }, 4), ",") == "5,6,7,8", "party: you (the main) and three alts")
check(table.concat(Mn.partyIds(7, { main = 5, alts = { 6, 7, 8 } }, 4), ",") == "7,5,6,8", "party on an alt: you, the main, the others")
check(table.concat(Mn.partyIds(7, nil, 4), ",") == "7", "no roster: just you")

-- the menu belongs to the Kingdom Hearts style
local menuPanel = { Visible = false }
env.UIAPI.panels = setmetatable({ menu = menuPanel }, { __index = function() return nil end })
env.UIAPI.sync = function() end
env.UIAPI.menuBtn = { Visible = true }
local said
env.note = function(_, m) said = m end
env.H.menu()
check(menuPanel.Visible == false and said and said:find("Kingdom Hearts", 1, true), "standard style: menu refused with a hint")
K.set("Kingdom Hearts")
check(env.UIAPI.menuBtn.Visible == true, "KH style shows the MENU button")
env.H.menu()
check(menuPanel.Visible == true, "KH style: menu opens")
K.set("Standard")
check(menuPanel.Visible == false and env.UIAPI.menuBtn.Visible == false, "leaving the KH style closes the menu and hides MENU")
-- three styles: Standard, Kingdom Hearts, Sword Art Online (KHStyle.set switches between them)
local saoOn
env.UIAPI.SAOStyle = { apply = function(on) saoOn = on end }
env.Cfg.theme = { preset = "Forest" }; env.Cfg.uiFont = "Gotham"; env.Cfg.cursor = "Light"
applied = {}
K.set("Sword Art Online")
check(env.Cfg.uiStyle == "Sword Art Online" and saoOn == true and K.on == false and K.gui == nil, "SAO style on: the KH look is off")
check(env.Cfg.khPrev.preset == "Forest" and env.Cfg.khPrev.font == "Gotham", "the look before it is remembered")
K.set("Kingdom Hearts")
check(env.Cfg.uiStyle == "Kingdom Hearts" and saoOn == false and K.on and env.Cfg.khPrev.preset == "Forest", "SAO -> KH keeps the remembered look")
applied = {}
K.set("Standard")
check(env.Cfg.uiStyle == "Standard" and saoOn == false and applied.preset == "Forest" and applied.font == "Gotham" and applied.cursor == "Light",
    "Standard brings the remembered look back")
-- alt accounts keep the plain look (shared config, weak PC): no menu, no HUD
K.set("Sword Art Online")
env.UIAPI.plainUI = true
check(not env.UIAPI.SelfHud.allowed() and not env.UIAPI.Menu.allowed(), "plain look on an alt: no self HUD, no styled menu")
K.set("Kingdom Hearts")
check(env.UIAPI.plainUI == false and env.UIAPI.Menu.allowed(), "a style chosen by hand on the alt wins")
K.set("Standard")
K.set("nonsense")
check(env.Cfg.uiStyle == "Standard", "unknown style names fall back to Standard")
print("ALL OK")

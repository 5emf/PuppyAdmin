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
function Inst:IsA(c) return self.ClassName == c end
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
    o.MouseEnter, o.MouseLeave, o.DescendantAdded = sig(), sig(), sig()
    o.__newindexhook = true
    setmetatable(o, { __index = Inst, __newindex = function(t, k, v) if k == "Parent" and v then rawset(t, "Parent", v); table.insert(v.children, t) else rawset(t, k, v) end end })
    return o
end
local screen = new("ScreenGui", { Name = "PuppyAdminGui" }); screen.Parent = new("CoreGui")
local win = new("Frame", { AbsoluteSize = vec(300, 400) }); win.Parent = screen
new("UICorner").Parent = win
local btn = new("TextButton", { AbsoluteSize = vec(120, 28), AbsolutePosition = vec(140, 90) }); btn.Parent = win
local small = new("Frame", { AbsoluteSize = vec(20, 20) }); small.Parent = win
local rs = sig()
local applied = {}
local env = setmetatable({
    UIAPI = { Cursor = { set = function(n) applied.cursor = n return true end } }, Cfg = { uiStyle = "Standard", uiFont = "Default", cursor = "Default", theme = { preset = "Midnight" } },
    Theme = { roots = { screen }, usePreset = function(n) applied.preset = n return true end },
    UIFont = { set = function(n) applied.font = n return true end },
    Instance = { new = function(c) return new(c) end }, make = function(c, p, parent) local o = new(c, p); if parent then o.Parent = parent end return o end,
    parentGui = function(g) g.Parent = new("CoreGui") end, RunService = { RenderStepped = rs },
    SETTINGS = { Auras = { assetBase = "https://x/" } }, urlImageAsset = function(u) return "asset:" .. u end,
    task = { spawn = function(f) f() end, defer = function(f) f() end }, game = { GetService = function() return { GetGuiInset = function() return vec(0, 36) end } end },
    ColorSequence = { new = function(a, b) return { a, b } end }, Color3 = { new = function() return {} end, fromRGB = function() return {} end },
    UDim2 = { fromOffset = function(x, y) return { X = x, Y = y } end }, Vector2 = { zero = vec(0, 0) },
    Enum = { ScaleType = { Fit = 1 } }, cleanups = {}, cfgSave = function() applied.saved = (applied.saved or 0) + 1 end,
}, { __index = _G })
env.math = setmetatable({ clamp = function(x, lo, hi) return math.max(lo, math.min(hi, x)) end }, { __index = math })
assert(load(block, "kh", "t", env))()
local K = env.UIAPI.KHStyle
local ok = K.set("Kingdom Hearts")
local function check(c, m) print((c and "ok   " or "FAIL ") .. m) if not c then os.exit(1) end end
check(ok and env.Cfg.uiStyle == "Kingdom Hearts", "style on")
check(applied.preset == "Kingdom Hearts" and applied.font == "KH Menu" and applied.cursor == "Glove", "theme, font and glove cursor chosen")
check(env.Cfg.khPrev.preset == "Midnight" and env.Cfg.khPrev.font == "Default", "previous look remembered")
check(btn:FindFirstChildOfClass("UIGradient") and win:FindFirstChildOfClass("UIGradient"), "button and window shaded")
check(not small:FindFirstChildOfClass("UIGradient"), "small frames left alone")
btn.MouseEnter:fire(); rs:fire()
check(K.glove.Visible and K.glove.Position.X < 140 and math.abs(K.glove.Position.Y - (90 + 36 + 14 - K.glove.Size.Y * 0.39)) < 1e-6, "glove points at the hovered button (inset counted)")
btn.MouseLeave:fire(); rs:fire()
check(not K.glove.Visible, "glove hides when the mouse leaves")
local late = new("TextButton"); late.Parent = win; screen.DescendantAdded:fire(late)
check(late:FindFirstChildOfClass("UIGradient") ~= nil, "buttons made later are styled too")
applied = {}
K.set("Standard")
check(env.Cfg.uiStyle == "Standard" and applied.preset == "Midnight" and applied.font == "Default" and applied.cursor == "Default", "off restores the previous look")
check(not btn:FindFirstChildOfClass("UIGradient") and not win:FindFirstChildOfClass("UIGradient") and K.gui == nil, "all KH decorations removed")
print("ALL OK")

-- Text fitting test: lua5.4 tools/test_textfit.lua PuppyAdmin.lua
-- Runs UIFont.fitCheck from PuppyAdmin.lua against fake labels.
local src = io.open(arg[1]):read("a")
local a = assert(src:find("    function UIFont.fitCheck(inst)", 1, true))
local b = assert(src:find("    local fitHooked", a, true))
local UIFont = { FIT_TAG = "PuppyFitBase" }
local env = setmetatable({ UIFont = UIFont, Instance = { new = function(c) return { ClassName = c } end } }, { __index = _G })
assert(load(src:sub(a, b - 1), "fit", "t", env))()
local fails = 0
local function check(c, m) print((c and "ok   " or "FAIL ") .. m) if not c then fails = fails + 1 end end
local function lbl(h, size, fits)
    local kids, attrs = {}, {}
    local o = { Parent = true, Text = "Some long text", TextFits = fits, AbsoluteSize = { Y = h }, TextSize = size,
        TextWrapped = false, TextScaled = false }
    function o:SetAttribute(k, v) attrs[k] = v end
    function o:GetAttribute(k) return attrs[k] end
    function o:FindFirstChild(n) return kids[n] end
    setmetatable(o, { __newindex = function(t, k, v) rawset(t, k, v) end })
    o.kids = kids
    return o
end
local fit = lbl(30, 14, true)
UIFont.fitCheck(fit)
check(not fit.TextWrapped and not fit.TextScaled, "text that fits is left alone")

local tall = lbl(40, 14, false)
UIFont.fitCheck(tall)
check(tall.TextWrapped and not tall.TextScaled, "a box tall enough for two lines wraps first")

tall.TextFits = false -- still too long after wrapping
UIFont.fitCheck(tall)
check(tall.TextScaled and tall:GetAttribute("PuppyFitBase") == 14, "still too long: shrinks to fit, remembering its size")

local short = lbl(18, 14, false)
UIFont.fitCheck(short)
check(short.TextScaled and not short.TextWrapped, "a one-line box shrinks instead of wrapping")

local hidden = lbl(0, 14, false)
UIFont.fitCheck(hidden)
check(not hidden.TextScaled and not hidden.TextWrapped, "boxes with no size yet are skipped")

local empty = lbl(18, 14, false)
empty.Text = ""
UIFont.fitCheck(empty)
check(not empty.TextScaled, "empty text is skipped")
print(fails == 0 and "ALL OK" or (fails .. " FAILED"))
os.exit(fails == 0 and 0 or 1)

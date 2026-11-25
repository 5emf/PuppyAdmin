-- Command directory test: lua5.4 tools/test_commands.lua PuppyAdmin.lua
-- Every command gets a category tab, and every "off" command is folded into its "on" row.
local src = io.open(arg[1]):read("a")
local a = assert(src:find("-- Command directory tabs: every command has one category", 1, true))
local b = assert(src:find("------------------------------------------------------------------------\n-- Interface", a, true))
local block = src:sub(a, b - 1)
local env = setmetatable({ UIAPI = { panels = {} }, H = {}, task = { spawn = function(f) f() end } }, { __index = _G })
env.cmds = load("return " .. src:match("local cmds = (%b{})"), "cmds", "t", env)()
env.cmdDocs = {}
for k, v in src:gmatch('\n    ([%w_]+) = "([^"\n]*)",') do env.cmdDocs[k] = v end
for k, v in src:gmatch('cmdDocs%.([%w_]+) = "([^"\n]*)"') do env.cmdDocs[k] = v end
env.PUP_MOVE = load("return " .. src:match("local PUP_MOVE = (%b{})"), "m", "t", env)()
env.PUP_PERF = load("return " .. src:match("local PUP_PERF = (%b{})"), "p", "t", env)()
for _, c in ipairs(env.PUP_MOVE) do
    table.insert(env.cmds, c.name)
    env.cmdDocs[c.name] = env.cmdDocs[c.name] or (c.name .. (c.args ~= "" and (" " .. c.args) or "") .. " - " .. c.desc)
end
for _, c in ipairs(env.PUP_PERF) do
    table.insert(env.cmds, c.name)
    env.cmdDocs[c.name] = env.cmdDocs[c.name] or (c.name .. " - " .. c.desc)
end
for _, n in ipairs({ "cursor", "altcmds", "alt", "uistyle", "selfhud", "limbs", "menu" }) do
    table.insert(env.cmds, n)
    env.cmdDocs[n] = env.cmdDocs[n] or (n .. " - test")
end
assert(load(block, "cats", "t", env))()
local U = env.UIAPI
local fails = 0
local function check(c, m) print((c and "ok   " or "FAIL ") .. m) if not c then fails = fails + 1 end end

local other = {}
for _, c in ipairs(env.cmds) do if U.cmdCategory(c) == "Other" then other[#other + 1] = c end end
check(#other == 0, "every command has a real category (" .. table.concat(other, ", ") .. ")")

local rows = U.mergeOffDocs(env.cmds, env.cmdDocs)
local byName = {}
for _, r in ipairs(rows) do byName[r.name] = r end
for _, pair in ipairs({ { "esp", "unesp" }, { "aura", "unaura" }, { "infbaseplate", "uninfbaseplate" }, { "hide", "unhide" },
    { "mute", "unmute" }, { "antiafk", "unantiafk" }, { "antikick", "unantikick" }, { "hidetags", "showtags" }, { "form", "unform" } }) do
    local on, off = pair[1], pair[2]
    check(byName[on] and not byName[off] and byName[on].doc:find("off: " .. off, 1, true) ~= nil,
        string.format("%-12s carries %s", on, off))
end
local leftover = {}
for _, r in ipairs(rows) do
    if r.name:sub(1, 2) == "un" and env.cmdDocs[r.name:sub(3)] then leftover[#leftover + 1] = r.name end
end
check(#leftover == 0, "no 'un' command left on its own (" .. table.concat(leftover, ", ") .. ")")
check(not byName.unban and byName.ban and byName.ban.doc:find("off: unban", 1, true) ~= nil, "unban is listed with ban (it undoes it)")
print(string.format("%d commands -> %d rows", #env.cmds, #rows))
print(fails == 0 and "ALL OK" or (fails .. " FAILED"))
os.exit(fails == 0 and 0 or 1)

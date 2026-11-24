--[[
    Puppy Admin
    (formerly Tool Orbit) - orbit/tail/wings cosmetics, chat commands with
    editable prefixes, a settings window, hide/mute, auras/VFX, the built-in
    reanimation engine and Reanimate panel, movement commands,
    teleport and click-teleport, and an allowlisted nametag editor.

    Everything the script draws (auras, nametags, hidden characters) is
    client-side: only you see it. Orbiting/tail/wings tools and the reanimation
    body follow the same replication rules as the original V3.

    Quick start:  .help   .tools   .tools tail on   .fly   .esp   .anim   .taglist
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local CoreGui = game:GetService("CoreGui")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local ContextActionService = game:GetService("ContextActionService")
local HttpService = game:GetService("HttpService")
local TextChatService = game:GetService("TextChatService")

local genv = (getgenv and getgenv()) or _G
do
local SCRIPT_BUILD = "2026.11.24-56" -- changes with every update; a newer build replaces a running older one
if genv.PuppyAdminActive == true then
    if genv.PuppyAdminBuild == SCRIPT_BUILD or type(genv.PuppyAdminShutdown) ~= "function" then
        -- same version already running: executing again refreshes tags (and auras / moderation)
        if type(genv.PuppyAdminRefresh) == "function" then pcall(genv.PuppyAdminRefresh) end
        return
    end
    -- an older version is running: stop it, then start this one
    pcall(genv.PuppyAdminShutdown)
    task.wait(0.5)
end
genv.PuppyAdminActive = true
genv.PuppyAdminBuild = SCRIPT_BUILD
end

-- Timing report (`perf`): how long each start-up stage and first-time action took.
local Perf = { t0 = os.clock(), marks = {} }
function Perf.mark(name, seconds) table.insert(Perf.marks, { name = name, ms = seconds * 1000, at = os.clock() - Perf.t0 }) end
function Perf.since(name, start) Perf.mark(name, os.clock() - start) end

local plr = Players.LocalPlayer
local chr = plr.Character or plr.CharacterAdded:Wait()
local hrp = chr:WaitForChild("HumanoidRootPart")
local bp = plr:WaitForChild("Backpack")

------------------------------------------------------------------------
-- Settings and state
------------------------------------------------------------------------

local SETTINGS = {
    VelocityY = 220.290009,          -- from V3, changeable live with `netless`
    SimulationRadius = 2147483647,
    MaxOrbitDistance = 8,            -- handle farther than this from its reference part triggers a resync
    KillCharacterOnStop = true,      -- V3 behaviour of `stop` (`kill` never touches the character)
    DisableHandleCollision = true,   -- tail/wings only: handles stop pushing characters
    ConfigFile = "puppyadmin.json",
    -- Shared tags (see TagSync). Readers need the repository to be public.
    TagSync = {
        owner = "5emf", repo = "PuppyAdmin", branch = "main", path = "tags.json",
        tokenFile = "PuppyAdmin/tagsync_token.txt", -- only on the machine that may write
        pollSeconds = 20, pushDelay = 4,
    },
    -- Who is running the script (for the default tag). url: your deployed
    -- presence worker (presence/ in the repository), e.g.
    -- "https://puppyadmin-presence.<you>.workers.dev". Empty = only you see your own default tag.
    Presence = { url = "", beatSeconds = 20 },
    -- Nametags: drawn up to renderDistance studs from the camera; the full tag
    -- (text, backdrop) only while it is within fullDistance of both your camera
    -- and your character, otherwise just the profile picture.
    TagView = { renderDistance = 300, fullDistance = 30 },
    -- Shared auras: who wears which aura (auras.json, same repository and
    -- branch as tags) and where aura textures are downloaded from.
    Auras = {
        path = "auras.json",
        assetBase = "https://raw.githubusercontent.com/5emf/PuppyAdmin/ccr-3b4dfcff-nyfy0w/",
    },
}

local S = {
    offset = 8,
    speed = 1,
    mode = 1,
    rot = 0,
    toolRotSpeed = 1,
    lerpOrbit = 1,                   -- V3 default
    lerpShape = 14,                  -- uncalibrated: follow rate for tail/wings
    enabled = false,                 -- master switch: nothing touches your tools until `tools on`
    orbitOn = true,
    tailOn = false,
    wingsOn = false,
    tailCount = nil,                 -- nil = automatic split when both are on
    axis = "-z",                     -- uncalibrated: which handle axis points along feather/tail
    tail = { length = 6, baseDeg = -15, curlDeg = 70, wagSpeed = 3, wagAmp = 1.2 },
    wing = { span = 7, topDeg = 70, spreadDeg = 100, flapSpeed = 4, flapAmp = 22 },
}

local targetHRP = hrp
local slots = {}                     -- one record per tool: tool, handle, ref, constraints, role
local pendingTools = {}
local conns = {}
local addedT, removedT = {}, {}
local cleanups = {}                  -- functions run by shutdown, in reverse order
local shutdown
local ui, helpFrame, settingsFrame
local Theme                          -- filled in after the palette (theme section)
local UIAPI = {}                     -- filled by createUI (showOutput etc.)

------------------------------------------------------------------------
-- Helpers
------------------------------------------------------------------------

local function make(class, props, parent)
    local o = Instance.new(class)
    for k, v in pairs(props) do o[k] = v end
    o.Parent = parent
    return o
end

local function parentGui(gui)
    local candidates = {}
    if gethui then
        local ok, g = pcall(gethui)
        if ok and g then table.insert(candidates, g) end
    end
    if cloneref then
        local ok, g = pcall(cloneref, CoreGui)
        if ok and g then table.insert(candidates, g) end
    end
    table.insert(candidates, CoreGui)
    table.insert(candidates, plr:WaitForChild("PlayerGui"))
    for _, c in ipairs(candidates) do
        local ok = pcall(function() gui.Parent = c end)
        if ok and gui.Parent == c then return end
    end
end

-- Downloads an image URL to PuppyAdmin/<tag>_<hash>.<ext> and loads it as a
-- custom asset (needs getcustomasset/getsynasset and writefile). Cached by URL.
local function urlImageAsset(url, tag)
    local getAsset = (type(getcustomasset) == "function" and getcustomasset) or (type(getsynasset) == "function" and getsynasset)
    if not getAsset then return nil end
    local h = 0
    for i = 1, #url do h = (h * 33 + string.byte(url, i)) % 2147483647 end
    local ext = (url:gsub("[?#].*$", ""):match("%.(%w+)$") or "png"):lower()
    if not ({ png = true, jpg = true, jpeg = true, webp = true, gif = true, bmp = true, mp3 = true, ogg = true })[ext] then ext = "png" end
    local file = "PuppyAdmin/" .. tag .. "_" .. tostring(h) .. "." .. ext
    pcall(function()
        if isfolder and makefolder and not isfolder("PuppyAdmin") then makefolder("PuppyAdmin") end
    end)
    if isfile then
        local ok, exists = pcall(isfile, file)
        if ok and exists then
            local ok2, out = pcall(getAsset, file)
            if ok2 and type(out) == "string" and out ~= "" then return out end
        end
    end
    local ok, body = pcall(function() return game:HttpGet(url) end)
    if ok and type(body) == "string" and #body > 64 and writefile then
        pcall(writefile, file, body)
        local ok2, out = pcall(getAsset, file)
        if ok2 and type(out) == "string" and out ~= "" then return out end
    end
    return nil
end

-- Accepts rbxasset(s) / rbxthumb, rbxassetid://, a bare id, a roblox.com link,
-- a GitHub blob link or an image URL. Returns a content id, or nil and a reason.
-- Image URLs are downloaded, so call this off the input thread.
local function resolveImageSource(raw, tag)
    local s = tostring(raw or ""):match("^%s*(.-)%s*$") or ""
    if s == "" then return nil, "Enter an image id or URL" end
    local user, repo, rest = s:match("^https://github%.com/([^/]+)/([^/]+)/blob/(.+)$")
    if user then s = "https://raw.githubusercontent.com/" .. user .. "/" .. repo .. "/" .. rest end
    if s:find("^rbxasset") or s:find("^rbxthumb") then return s end
    if s:match("^%d+$") then return "rbxassetid://" .. s end
    if s:find("roblox%.com") then
        local id = s:match("(%d+)")
        if id then return "rbxassetid://" .. id end
        return nil, "No asset id in that link"
    end
    if s:find("^https?://") then
        local tex = urlImageAsset(s, tag)
        if tex then return tex end
        return nil, "Download failed (needs getcustomasset + writefile)"
    end
    return nil, "Not an image id, asset or image URL"
end

------------------------------------------------------------------------
-- Pure helpers (no Roblox types; checked outside the game)
------------------------------------------------------------------------
--// PURE-BEGIN

local COLOR_NAMES = {
    red = { 255, 60, 60 }, green = { 80, 220, 120 }, blue = { 70, 120, 255 },
    white = { 255, 255, 255 }, black = { 0, 0, 0 }, yellow = { 255, 225, 70 },
    orange = { 255, 150, 40 }, purple = { 160, 90, 255 }, pink = { 255, 120, 200 },
    cyan = { 80, 230, 255 }, gold = { 255, 200, 60 }, grey = { 150, 150, 150 },
}

local function clamp255(n) return math.max(0, math.min(255, math.floor(n))) end

-- One token: name, #hex / hex, or "r,g,b". Returns r, g, b or nil.
local function parseColorToken(tok)
    if not tok then return nil end
    tok = tok:lower()
    local named = COLOR_NAMES[tok]
    if named then return named[1], named[2], named[3] end
    local hex = tok:match("^#?(%x%x%x%x%x%x)$")
    if hex then
        return tonumber(hex:sub(1, 2), 16), tonumber(hex:sub(3, 4), 16), tonumber(hex:sub(5, 6), 16)
    end
    local r, g, b = tok:match("^(%d+),(%d+),(%d+)$")
    if r then return clamp255(tonumber(r)), clamp255(tonumber(g)), clamp255(tonumber(b)) end
    return nil
end

-- args[i] either "r g b" (three numbers) or one color token. Returns r, g, b, consumed.
local function parseColorArgs(args, i)
    local a, b, c = tonumber(args[i]), tonumber(args[i + 1]), tonumber(args[i + 2])
    if a and b and c then return clamp255(a), clamp255(b), clamp255(c), 3 end
    local r, g, bl = parseColorToken(args[i])
    if r then return r, g, bl, 1 end
    return nil
end

local function splitArgs(s)
    local t = {}
    for w in s:gmatch("%S+") do t[#t + 1] = w end
    return t
end

-- A prefix is 1-3 characters, no letters, digits or whitespace.
local function validatePrefix(p)
    if type(p) ~= "string" or #p == 0 or #p > 3 then return false end
    if p:find("[%w%s]") then return false end
    return true
end

-- "a, b c" -> { "a", "b", "c" } keeping only valid, unique prefixes.
local function parsePrefixList(text)
    local out, seen = {}, {}
    for tok in tostring(text):gmatch("[^,%s]+") do
        if validatePrefix(tok) and not seen[tok] then
            seen[tok] = true
            table.insert(out, tok)
        end
    end
    return out
end

-- Returns the text after the longest matching prefix, or nil.
local function matchPrefix(msg, prefixes)
    local bestLen, rest = 0, nil
    for _, p in ipairs(prefixes) do
        if #p > bestLen and msg:sub(1, #p) == p then
            bestLen, rest = #p, msg:sub(#p + 1)
        end
    end
    return rest
end

local function normalizeAnimId(raw)
    if raw == nil then return nil end
    local s = tostring(raw):lower()
    local digits = s:match("^(%d+)$") or s:match("^rbxassetid://(%d+)$") or s:match("[?&]id=(%d+)")
    if not digits then return nil end
    return "rbxassetid://" .. digits
end

-- Library entries: an animation id, otherwise a URL or file holding a keyframe table.
local function classifyAnimSource(src)
    if type(src) ~= "string" or src == "" then return nil end
    if normalizeAnimId(src) then return "id" end
    return "kf"
end

-- Part names actually used anywhere in the file (sampled: first, middle, last
-- frame - the joint set in one recording is always the same rig throughout).
local function kfPartNames(frames)
    local names = {}
    for _, idx in ipairs({ 1, math.ceil(#frames / 2), #frames }) do
        local fr = frames[idx]
        if fr then
            for partName in pairs(fr.Data) do names[partName] = true end
        end
    end
    return names
end

-- times: ascending keyframe times. Returns lower index, upper index, blend alpha.
local function kfLocate(times, t, total)
    local n = #times
    if n == 0 then return nil end
    if n == 1 then return 1, 1, 0 end
    local lo, hi = 1, n - 1
    while lo < hi do
        local mid = math.floor((lo + hi + 1) / 2)
        if times[mid] <= t then lo = mid else hi = mid - 1 end
    end
    local ta, tb = times[lo], times[lo + 1]
    local span = tb - ta
    local alpha = span > 0 and math.max(0, math.min(1, (t - ta) / span)) or 0
    return lo, lo + 1, alpha
end

-- Some animation ids posted around are not an Animation asset directly but a
-- model/rig/bundle that CONTAINS one, or a raw KeyframeSequence. Loading such an
-- id straight as AnimationId gives a track with Length == 0 (no keyframes).
-- The reanimation engine's resolveAnim does the same GetObjects + KeyframeSequenceProvider
-- dance; this is that pattern, cached by raw id.
local animIdResolveCache = {}

local function resolveAnimationId(rawId)
    local cached = animIdResolveCache[rawId]
    if cached then return cached end
    local resolved = rawId
    local ok, objs = pcall(function() return game:GetObjects(rawId) end)
    if ok and objs and objs[1] then
        local obj = objs[1]
        local anim = obj:IsA("Animation") and obj or obj:FindFirstChildWhichIsA("Animation", true)
        if anim and anim.AnimationId ~= "" then
            resolved = anim.AnimationId
        else
            local kfs = obj:IsA("KeyframeSequence") and obj or obj:FindFirstChildWhichIsA("KeyframeSequence", true)
            if kfs then
                local okReg, contentId = pcall(function()
                    return game:GetService("KeyframeSequenceProvider"):RegisterKeyframeSequence(kfs)
                end)
                if okReg and contentId and contentId ~= "" then resolved = contentId end
            end
        end
        for _, o in ipairs(objs) do pcall(function() o:Destroy() end) end
    end
    animIdResolveCache[rawId] = resolved
    return resolved
end

--// PURE-END

------------------------------------------------------------------------
-- Saved configuration
------------------------------------------------------------------------

local Cfg = {
    prefixes = { "." },
    uiKey = "RightControl",
    anims = {},        -- name -> { id, speed, loop }
    animStates = {},   -- idle / walk / jump / fall -> animation name
    binds = {},        -- KeyCode name -> animation name
    theme = {},        -- role -> {r,g,b}, plus preset name
    tags = {},         -- old format (one look per UserId); moved into tagDefs on load
    tagDefs = {},      -- named tags shared by several players (see Tags below)
    tagClickTp = true, -- clicking someone else's tag teleports you to them
    tagsHidden = false, -- hide every nametag on your own screen (others still see theirs)
    skipIntro = false, -- start without the brand intro
    uiFont = "Default", -- Settings > Font (UIFont.choices())
    uiTextScale = 1,    -- Settings > Text size (0.5 - 2)
    cursor = "Default", -- Settings > Look > Cursor: Default, Glove, Light, Keyblade or Custom
    cursorImage = "",   -- Custom cursor: image id or URL
    cursorSize = 40,    -- cursor size in pixels (16 - 128)
    games = {},        -- mini game best scores: game id -> number
    fpsCounter = { on = false }, -- Performance > FPS counter: on, x, y (pixels)
    gbVolume = 1,      -- Game Boy sound level (0 = off)
    doomVolume = 1,    -- Doom sound level (0 = off)
    gbaVolume = 1,     -- Game Boy Advance sound level (0 = off)
    floor = {},        -- infinite baseplate: { preset = name, color = { r, g, b } }
    antiAfk = false,   -- keep Roblox from disconnecting you for being idle
    windowScales = {}, -- window name -> size set with the corner grip (1 = normal)
    altForm = {},      -- alt formations window: shape, size, speed, height, glitch, spin, pulse
    altLite = true,    -- low-power alt mode (caps each alt's FPS; good for weak PCs)
    altLiteFps = 30,   -- the FPS cap alts use in low-power mode
    altVcAuto = true,  -- alts run the VC-ban bypass by themselves when voice looks unavailable
    altWhitelist = {}, -- players (name -> true) allowed to drive your alts by chat
}

local function cfgSave()
    if not writefile then return end
    pcall(function() writefile(SETTINGS.ConfigFile, HttpService:JSONEncode(Cfg)) end)
end

local function cfgLoad()
    if not (isfile and readfile) then return end
    local ok, data = pcall(function()
        if isfile(SETTINGS.ConfigFile) then
            return HttpService:JSONDecode(readfile(SETTINGS.ConfigFile))
        end
    end)
    if ok and type(data) == "table" then
        for k, default in pairs(Cfg) do
            if type(data[k]) == type(default) then Cfg[k] = data[k] end
        end
    end
    local clean = {}
    for _, p in ipairs(Cfg.prefixes) do
        if validatePrefix(p) then table.insert(clean, p) end
    end
    if #clean == 0 then clean = { "." } end
    Cfg.prefixes = clean
    if type(Cfg.uiKey) ~= "string" then Cfg.uiKey = "RightControl" end
end

cfgLoad()


------------------------------------------------------------------------
-- Notifications
------------------------------------------------------------------------

local notifGui = Instance.new("ScreenGui")
notifGui.Name = "FlatNotifGui"
notifGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
parentGui(notifGui)

local notifContainer = make("Frame", {
    Size = UDim2.new(0, 260, 1, -20),
    Position = UDim2.new(1, -270, 0, 10),
    BackgroundTransparency = 1,
}, notifGui)

make("UIListLayout", {
    VerticalAlignment = Enum.VerticalAlignment.Bottom,
    HorizontalAlignment = Enum.HorizontalAlignment.Right,
    Padding = UDim.new(0, 8),
}, notifContainer)

local GREY = Color3.fromRGB(150, 150, 150)
local LIGHT = Color3.fromRGB(200, 200, 200)

local function sendFlatNotification(title, text, color)
    local nFrame = make("Frame", {
        Size = UDim2.new(0, 0, 0, 55),
        BackgroundColor3 = Color3.fromRGB(10, 10, 10),
        BackgroundTransparency = 0.3,
        BorderSizePixel = 0,
        ClipsDescendants = true,
    }, notifContainer)

    make("UIStroke", { Color = Color3.fromRGB(60, 60, 60), Transparency = 0.5, Thickness = 1 }, nFrame)
    make("Frame", {
        Size = UDim2.new(0, 3, 1, 0),
        BackgroundColor3 = color or GREY,
        BorderSizePixel = 0,
    }, nFrame)
    make("TextLabel", {
        Text = title:upper(),
        Position = UDim2.new(0, 12, 0.15, 0),
        Size = UDim2.new(1, -20, 0, 15),
        Font = Enum.Font.Code,
        TextColor3 = Color3.fromRGB(255, 255, 255),
        TextSize = 13,
        BackgroundTransparency = 1,
        TextXAlignment = Enum.TextXAlignment.Left,
    }, nFrame)
    make("TextLabel", {
        Text = text,
        Position = UDim2.new(0, 12, 0.5, 0),
        Size = UDim2.new(1, -20, 0, 15),
        Font = Enum.Font.Code,
        TextColor3 = Color3.fromRGB(170, 170, 170),
        TextSize = 11,
        BackgroundTransparency = 1,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextWrapped = true,
    }, nFrame)

    TweenService:Create(nFrame, TweenInfo.new(0.4, Enum.EasingStyle.Quart, Enum.EasingDirection.Out),
        { Size = UDim2.new(1, 0, 0, 55) }):Play()
    task.delay(2.5, function()
        if not nFrame.Parent then return end
        local t = TweenService:Create(nFrame, TweenInfo.new(0.4, Enum.EasingStyle.Quart, Enum.EasingDirection.In),
            { Size = UDim2.new(0, 0, 0, 55) })
        t:Play()
        t.Completed:Wait()
        nFrame:Destroy()
    end)
end

task.spawn(function()
    while genv.PuppyAdminActive do
        task.wait(3)
        if #addedT > 0 or #removedT > 0 then
            local txt = ""
            if #addedT > 0 then txt = txt .. "+ " .. table.concat(addedT, ", ") .. " " end
            if #removedT > 0 then txt = txt .. "- " .. table.concat(removedT, ", ") end
            sendFlatNotification("Tool Update", txt, GREY)
            table.clear(addedT)
            table.clear(removedT)
        end
    end
end)

------------------------------------------------------------------------
-- Shape math (pure numbers, no Roblox types)
-- Space: HumanoidRootPart-local. +X right, +Y up, +Z back (front is -Z).
-- Angles in degrees in the settings tables, radians inside the math.
------------------------------------------------------------------------
--// SHAPE-BEGIN

-- Point on the tail centreline. s is measured in segments (0 .. n).
local function tailPoint(s, n, t, tl)
    local step = tl.length / n
    local y, z = 0, 0
    local whole = math.floor(s)
    for j = 1, whole do
        local th = math.rad(tl.baseDeg + tl.curlDeg * (j / n))
        y = y + step * math.sin(th)
        z = z + step * math.cos(th)
    end
    local frac = s - whole
    if frac > 0 then
        local th = math.rad(tl.baseDeg + tl.curlDeg * ((whole + 1) / n))
        y = y + step * frac * math.sin(th)
        z = z + step * frac * math.cos(th)
    end
    local x = 0
    if tl.wagSpeed ~= 0 then
        local u = s / n
        x = tl.wagAmp * u * math.sin(t * tl.wagSpeed - u * 2.2)
    end
    return x, y, z
end

-- Tool k of n on the tail: position relative to the tail root, then tangent.
local function tailSegment(k, n, t, tl)
    local s = k - 0.5
    local x0, y0, z0 = tailPoint(s - 0.25, n, t, tl)
    local x1, y1, z1 = tailPoint(s + 0.25, n, t, tl)
    local px, py, pz = tailPoint(s, n, t, tl)
    return px, py, pz, x1 - x0, y1 - y0, z1 - z0
end

-- Feather k of m on the RIGHT wing: position relative to the wing root, then
-- direction. The left wing is the same with X negated by the caller.
local function wingFeather(k, m, t, w)
    local u = (k - 0.5) / m
    local alpha = math.rad(w.topDeg - w.spreadDeg * u)
    if w.flapSpeed ~= 0 then
        alpha = alpha + math.rad(w.flapAmp) * math.sin(t * w.flapSpeed - u * 0.6)
    end
    local r = w.span * (0.55 + 0.45 * math.sin(math.pi * (u ^ 0.8)))
    local dx, dy = math.cos(alpha), math.sin(alpha)
    return dx * r, dy * r, 0, dx, dy, 0
end

-- Splits n tools among the enabled layouts (weights: orbit 1, tail 1, wings 2).
-- Minimums when enabled: wings 2 (a pair), tail 1, orbit 1, funded in the order
-- wings, tail, orbit. Returns tailCount, wingCount, orbitCount (sum = n when any is enabled).
local SPLIT_MIN = { wings = 2, tail = 1, orbit = 1 }
local SPLIT_WEIGHT = { wings = 2, tail = 1, orbit = 1 }
local SPLIT_ORDER = { "wings", "tail", "orbit" }

local function splitBase(n, on)
    local out = { wings = 0, tail = 0, orbit = 0 }
    if n <= 0 then return out end
    local funded, left = {}, n
    for _, k in ipairs(SPLIT_ORDER) do
        if on[k] and left >= SPLIT_MIN[k] then
            out[k] = SPLIT_MIN[k]
            left = left - SPLIT_MIN[k]
            table.insert(funded, k)
        end
    end
    if #funded == 0 then
        for _, k in ipairs(SPLIT_ORDER) do
            if on[k] then out[k] = n; return out end
        end
        return out
    end
    if left > 0 then
        local total = 0
        for _, k in ipairs(funded) do total = total + SPLIT_WEIGHT[k] end
        local given, rem = 0, {}
        for idx, k in ipairs(funded) do
            local share = left * SPLIT_WEIGHT[k] / total
            local whole = math.floor(share)
            out[k] = out[k] + whole
            given = given + whole
            table.insert(rem, { k = k, frac = share - whole, idx = idx })
        end
        table.sort(rem, function(x, y)
            if x.frac ~= y.frac then return x.frac > y.frac end
            return x.idx < y.idx
        end)
        local i = 1
        while given < left do
            out[rem[i].k] = out[rem[i].k] + 1
            given = given + 1
            i = i % #rem + 1
        end
    end
    return out
end

local function splitCounts(n, orbitOn, tailOn, wingsOn, tailOverride)
    if tailOn and tailOverride and (wingsOn or orbitOn) then
        local cap = n - ((wingsOn and n >= 2) and 2 or 0)
        local t = math.max(0, math.min(tailOverride, cap))
        local rest = splitBase(n - t, { wings = wingsOn, tail = false, orbit = orbitOn })
        return t, rest.wings, rest.orbit
    end
    local r = splitBase(n, { wings = wingsOn, tail = tailOn, orbit = orbitOn })
    return r.tail, r.wings, r.orbit
end

--// SHAPE-END

------------------------------------------------------------------------
-- Orbit math (V3 patterns, unchanged)
------------------------------------------------------------------------

local function orbitCFrame(base, i, n, time)
    local angle = math.rad(S.rot + (360 / n) * i)
    local mode, offset = S.mode, S.offset
    local goal = CFrame.new()

    if mode == 1 then
        goal = base * CFrame.Angles(0, angle, 0) * CFrame.new(offset, 0, 0)
    elseif mode == 2 then
        goal = base * CFrame.new(math.cos(angle) * offset, math.sin(time * 2 + i) * 2, math.sin(angle) * offset)
    elseif mode == 3 then
        goal = base * CFrame.Angles(angle, angle, 0) * CFrame.new(offset, 0, 0)
    elseif mode == 4 then
        goal = CFrame.new(base.Position) * CFrame.Angles(0, angle, 0) * CFrame.new(offset, 0, 0)
    elseif mode == 5 then
        goal = base * CFrame.new(math.cos(angle) * offset, math.sin(angle) * offset, math.sin(angle) * offset)
    elseif mode == 6 then
        goal = base * CFrame.Angles(angle, 0, angle) * CFrame.new(offset, 0, 0)
    else
        local subType = mode % 8
        local safeSpeed = time * (1 + (mode % 5) / 10)

        if subType == 0 then
            local petalCount = (mode % 5) + 3
            local wave = math.sin(angle * petalCount + safeSpeed)
            local currentOffset = offset + (wave * (offset / 3))
            goal = base * CFrame.Angles(0, angle, 0) * CFrame.new(currentOffset, 0, 0)
        elseif subType == 1 then
            local tiltX = math.rad((mode * 15) % 360) + (time * 0.5)
            local tiltZ = math.rad((mode * 45) % 360)
            goal = base * CFrame.Angles(tiltX, angle, tiltZ) * CFrame.new(offset, 0, 0)
        elseif subType == 2 then
            local height = math.sin(angle + (time * 2)) * (offset * 0.8)
            local twist = math.cos(safeSpeed + (i / 2)) * 2
            goal = base * CFrame.Angles(0, angle, 0) * CFrame.new(offset + twist, height, 0)
        elseif subType == 3 then
            local noiseX = math.sin(angle * ((mode % 3) + 1))
            local noiseY = math.cos(angle * ((mode % 2) + 1))
            goal = base * CFrame.Angles(angle, 0, angle) * CFrame.new(offset * noiseX, offset * noiseY, 0)
        elseif subType == 4 then
            local fig8X = math.cos(angle) * offset
            local fig8Z = math.sin(angle * 2) * offset
            goal = base * CFrame.new(fig8X, 0, fig8Z)
        elseif subType == 5 then
            local spikeFreq = (mode % 4) + 3
            local height = math.abs(math.sin(angle * spikeFreq)) * (offset * 0.8)
            goal = base * CFrame.Angles(0, angle, 0) * CFrame.new(offset, height - (offset / 2), 0)
        elseif subType == 6 then
            local band = (i % 3)
            local tiltAngle = math.rad(60 * band)
            goal = base * CFrame.Angles(tiltAngle, angle, 0) * CFrame.new(offset, 0, 0)
        elseif subType == 7 then
            local pulse = math.sin(safeSpeed * 2) * (offset * 0.4)
            goal = base * CFrame.Angles(0, angle, 0) * CFrame.new(offset + pulse, 0, 0)
        end

        if mode > 20 then
            local slowWobble = math.rad(math.sin(time) * 15)
            goal = goal * CFrame.Angles(slowWobble, 0, slowWobble)
        end
    end
    return goal
end

------------------------------------------------------------------------
-- Shape placement (Roblox types)
------------------------------------------------------------------------

-- Rotation that makes the chosen handle axis point along the look direction.
local AXIS_OFFSETS = {
    ["-z"] = CFrame.new(),
    ["z"] = CFrame.Angles(0, math.pi, 0),
    ["y"] = CFrame.Angles(-math.pi / 2, 0, 0),
    ["-y"] = CFrame.Angles(math.pi / 2, 0, 0),
    ["x"] = CFrame.Angles(0, math.pi / 2, 0),
    ["-x"] = CFrame.Angles(0, -math.pi / 2, 0),
}

-- Attachment points measured from the target character's own torso parts.
local anchorCache = setmetatable({}, { __mode = "k" })

local function getAnchors(char, root)
    local cached = anchorCache[char]
    if cached then return cached end

    local a = {
        wingRoot = Vector3.new(0.6, 0.6, 0.9),   -- fallback when torso parts are missing
        tailRoot = Vector3.new(0, -0.6, 0.7),
        measured = false,
    }
    local upper = char:FindFirstChild("UpperTorso") or char:FindFirstChild("Torso")
    local lower = char:FindFirstChild("LowerTorso") or char:FindFirstChild("Torso")
    if upper and lower and upper:IsA("BasePart") and lower:IsA("BasePart") then
        local up = root.CFrame:ToObjectSpace(upper.CFrame).Position
        local lp = root.CFrame:ToObjectSpace(lower.CFrame).Position
        a.wingRoot = Vector3.new(upper.Size.X * 0.3, up.Y + upper.Size.Y * 0.3, up.Z + upper.Size.Z * 0.5 + 0.4)
        a.tailRoot = Vector3.new(0, lp.Y - lower.Size.Y * 0.4, lp.Z + lower.Size.Z * 0.5 + 0.2)
        a.measured = true
    end
    anchorCache[char] = a
    return a
end

local function safeLookAt(pos, dir, upRef)
    if dir.Magnitude < 1e-4 then dir = Vector3.new(0, 0, 1) end
    return CFrame.lookAt(pos, pos + dir, upRef)
end

local function shapeGoal(base, slot, anchors, time)
    local axisOffset = AXIS_OFFSETS[S.axis] or AXIS_OFFSETS["-z"]
    if slot.role == "tail" then
        local px, py, pz, dx, dy, dz = tailSegment(slot.k, slot.m, time, S.tail)
        local pos = anchors.tailRoot + Vector3.new(px, py, pz)
        return base * safeLookAt(pos, Vector3.new(dx, dy, dz), Vector3.xAxis) * axisOffset
    end
    local side = (slot.role == "wingR") and 1 or -1
    local px, py, pz, dx, dy, dz = wingFeather(slot.k, slot.m, time, S.wing)
    local root = anchors.wingRoot
    local pos = Vector3.new(side * (root.X + px), root.Y + py, root.Z + pz)
    return base * safeLookAt(pos, Vector3.new(side * dx, dy, dz), Vector3.zAxis) * axisOffset
end

------------------------------------------------------------------------
-- Tool slots
------------------------------------------------------------------------

local function findSlotByHandle(h)
    for _, s in ipairs(slots) do
        if s.handle == h then return s end
    end
end

local function assignRoles()
    local n = #slots
    local tailN, wingN, orbitN = splitCounts(n, S.orbitOn, S.tailOn, S.wingsOn, S.tailCount)
    local rightCount = math.ceil(wingN / 2)
    local leftCount = wingN - rightCount
    local wi, ri, li, oi = 0, 0, 0, 0
    for i, slot in ipairs(slots) do
        if i <= tailN then
            slot.role, slot.k, slot.m = "tail", i, tailN
        elseif i <= tailN + wingN then
            wi = wi + 1
            if wi % 2 == 1 then
                ri = ri + 1
                slot.role, slot.k, slot.m = "wingR", ri, rightCount
            else
                li = li + 1
                slot.role, slot.k, slot.m = "wingL", li, leftCount
            end
        elseif i <= tailN + wingN + orbitN then
            oi = oi + 1
            slot.role, slot.k, slot.m = "orbit", oi, orbitN
        else
            slot.role, slot.k, slot.m = "idle", 1, 1
        end
    end
end

-- Switches a slot between spinning (orbit) and fixed orientation (tail/wings).
local function applyConstraintState(slot, shaped)
    if slot.shaped == shaped then return end
    slot.shaped = shaped
    slot.alignOri.Enabled = shaped
    if shaped then
        slot.angular.AngularVelocity = Vector3.zero
        slot.angular.MaxTorque = Vector3.zero
        if SETTINGS.DisableHandleCollision then slot.handle.CanCollide = false end
    else
        slot.angular.MaxTorque = Vector3.new(math.huge, math.huge, math.huge)
        slot.handle.CanCollide = slot.origCollide
    end
end

local function destroySlotObjects(slot)
    if slot.conn then slot.conn:Disconnect(); slot.conn = nil end
    pcall(function() slot.handle.CanCollide = slot.origCollide end)
    for _, k in ipairs({ "align", "alignOri", "angular", "a0", "a1", "ref" }) do
        if slot[k] then slot[k]:Destroy(); slot[k] = nil end
    end
end

local function removeSlot(slot)
    local i = table.find(slots, slot)
    if not i then return end
    table.insert(removedT, slot.name)
    destroySlotObjects(slot)
    table.remove(slots, i)
    assignRoles()
end

local function setupTool(tool)
    if not genv.PuppyAdminActive then return end
    if not tool or not tool:IsA("Tool") or pendingTools[tool] then return end
    local handle = tool:FindFirstChild("Handle")
    if not handle or not handle:IsA("BasePart") or findSlotByHandle(handle) then return end
    pendingTools[tool] = true

    -- Same reparent sequence as V3 to detach the handle from the hand grip.
    tool.Parent = bp
    tool.Parent = chr
    tool.Parent = bp
    tool.Parent = workspace
    tool.Parent = chr

    local ra = chr:FindFirstChild("Right Arm") or chr:FindFirstChild("RightHand")
    if ra then
        local grip = ra:FindFirstChild("RightGrip")
        if grip then
            grip:Destroy()
            tool.Parent = bp
            tool.Parent = chr
            tool.Parent = bp
            tool.Parent = workspace
            tool.Parent = chr
        end
    end

    pendingTools[tool] = nil
    if tool.Parent ~= chr or not genv.PuppyAdminActive then return end

    local slot = {
        tool = tool,
        handle = handle,
        name = tool.Name,
        origCollide = handle.CanCollide,
        shaped = false,
        role = "orbit",
        k = 1,
        m = 1,
    }

    slot.ref = make("Part", {
        Name = "OrbitReference_" .. tool.Name,
        Anchored = true,
        CanCollide = false,
        Transparency = 1,
        Size = Vector3.new(0.2, 0.2, 0.2),
        Position = targetHRP.Position,
    }, workspace)
    slot.a0 = make("Attachment", {}, handle)
    slot.a1 = make("Attachment", {}, slot.ref)
    slot.angular = make("BodyAngularVelocity", {
        MaxTorque = Vector3.new(math.huge, math.huge, math.huge),
        P = 1250,
    }, handle)
    slot.align = make("AlignPosition", {
        MaxForce = math.huge,
        MaxVelocity = math.huge,
        Responsiveness = 200,
        Attachment0 = slot.a0,
        Attachment1 = slot.a1,
    }, handle)
    slot.alignOri = make("AlignOrientation", {
        MaxTorque = math.huge,
        MaxAngularVelocity = math.huge,
        Responsiveness = 200,
        Attachment0 = slot.a0,
        Attachment1 = slot.a1,
        Enabled = false,
    }, handle)

    slot.conn = tool.AncestryChanged:Connect(function(_, parent)
        if parent ~= chr then removeSlot(slot) end
    end)

    table.insert(slots, slot)
    table.insert(addedT, tool.Name)
    assignRoles()
end


------------------------------------------------------------------------
-- Shared helpers for the new features
------------------------------------------------------------------------

local function note(title, text, color) sendFlatNotification(title, text, color or GREY) end
local RED = Color3.fromRGB(220, 70, 70)

-- "me" (default), "all", "others", or a player by name / display name.
local function resolveTargets(token)
    if not token or token == "" or token:lower() == "me" then return { plr } end
    local l = token:lower()
    local out = {}
    if l == "all" then return Players:GetPlayers() end
    if l == "others" then
        for _, p in ipairs(Players:GetPlayers()) do
            if p ~= plr then table.insert(out, p) end
        end
        return out
    end
    local exact, starts, contains
    for _, p in ipairs(Players:GetPlayers()) do
        local n, d = p.Name:lower(), p.DisplayName:lower()
        if n == l or d == l then
            exact = exact or p
        elseif n:sub(1, #l) == l or d:sub(1, #l) == l then
            starts = starts or p
        elseif n:find(l, 1, true) or d:find(l, 1, true) then
            contains = contains or p
        end
    end
    local p = exact or starts or contains
    if p then table.insert(out, p) end
    return out
end

-- Same, but a bare number is taken as a UserId (works for players who left).
local function resolveUserTargets(token)
    if token and token:match("^%d%d%d+$") then
        local id = tonumber(token)
        return { { userId = id, player = Players:GetPlayerByUserId(id) } }
    end
    local out = {}
    for _, p in ipairs(resolveTargets(token)) do
        table.insert(out, { userId = p.UserId, player = p })
    end
    return out
end

local function nameOf(entry)
    return entry.player and entry.player.DisplayName or tostring(entry.userId)
end

------------------------------------------------------------------------
-- Per-player character watcher (re-applies effects after respawns)
------------------------------------------------------------------------

local Watch = { handlers = {}, conns = {} }

function Watch.onCharacter(fn) table.insert(Watch.handlers, fn) end

local function dispatchCharacter(p, char)
    task.spawn(function()
        char:WaitForChild("HumanoidRootPart", 10)
        char:WaitForChild("Head", 10)
        if genv.PuppyAdminActive ~= true or not char.Parent or char.Name == "PuppyAdminClone" then return end
        for _, fn in ipairs(Watch.handlers) do pcall(fn, p, char) end
    end)
end

function Watch.add(p)
    if Watch.conns[p] then return end
    Watch.conns[p] = p.CharacterAdded:Connect(function(char) dispatchCharacter(p, char) end)
    if p.Character then dispatchCharacter(p, p.Character) end
end

function Watch.start()
    for _, p in ipairs(Players:GetPlayers()) do Watch.add(p) end
    table.insert(conns, Players.PlayerAdded:Connect(Watch.add))
    table.insert(conns, Players.PlayerRemoving:Connect(function(p)
        local c = Watch.conns[p]
        if c then c:Disconnect(); Watch.conns[p] = nil end
    end))
end

table.insert(cleanups, function()
    for p, c in pairs(Watch.conns) do c:Disconnect(); Watch.conns[p] = nil end
end)

local Mute

------------------------------------------------------------------------
-- Hide / unhide
-- `hide` (no argument) hides the script UI. For other players the behaviour is
-- the same as the built-in engine's: parts go invisible on your screen (re-asserted every
-- Heartbeat), their sounds and Billboard/SurfaceGuis are turned off, the name
-- display is removed and their voice is paused. You cannot hide yourself.
------------------------------------------------------------------------

local Hide = { map = {}, uiHidden = false }

local function voicePause(userId, paused)
    pcall(function() game:GetService("VoiceChatInternal"):SubscribePause(userId, paused) end)
end

local function hideDisconnect(entry)
    for _, k in ipairs({ "hbConn", "charConn", "leaveConn", "addConn" }) do
        if entry[k] then pcall(function() entry[k]:Disconnect() end); entry[k] = nil end
    end
end

local function hideRestore(userId)
    local entry = Hide.map[userId]
    if not entry then return end
    hideDisconnect(entry)
    Hide.map[userId] = nil
    if not Mute.players[userId] then voicePause(userId, false) end
    local p = entry.player
    local char = p and p.Character
    if char then
        pcall(function()
            for _, v in ipairs(char:GetDescendants()) do
                if v:IsA("BasePart") then
                    v.LocalTransparencyModifier = 0
                elseif v:IsA("Sound") then
                    if entry.savedVols[v] ~= nil then v.Volume = entry.savedVols[v] end
                elseif v:IsA("BillboardGui") or v:IsA("SurfaceGui") then
                    v.Enabled = true
                end
            end
            local hum = char:FindFirstChildOfClass("Humanoid")
            if hum then
                hum.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.Subject
                hum.NameDisplayDistance = 100
                hum.HealthDisplayDistance = 100
            end
        end)
    end
end

-- Returns true when the player was hidden / restored.
function Hide.setPlayer(p, on)
    if p == plr then return false end
    if not on then
        if not Hide.map[p.UserId] then return false end
        hideRestore(p.UserId)
        return true
    end
    if Hide.map[p.UserId] then return false end
    local entry = { player = p, savedVols = {}, parts = {} }
    Hide.map[p.UserId] = entry
    voicePause(p.UserId, true)

    local function applyOne(v)
        if v:IsA("BasePart") then
            entry.parts[v] = true
            v.LocalTransparencyModifier = 1
        elseif v:IsA("Sound") then
            if entry.savedVols[v] == nil then entry.savedVols[v] = v.Volume end
            v.Volume = 0
        elseif v:IsA("BillboardGui") or v:IsA("SurfaceGui") then
            if v.Name ~= "PuppyAdminTag" then v.Enabled = false end
        end
    end
    local function rebuild()
        table.clear(entry.parts)
        local char = p.Character
        if not char then return end
        pcall(function()
            for _, v in ipairs(char:GetDescendants()) do applyOne(v) end
            local hum = char:FindFirstChildOfClass("Humanoid")
            if hum then
                hum.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
                hum.NameDisplayDistance = 0
                hum.HealthDisplayDistance = 0
            end
        end)
        if entry.addConn then entry.addConn:Disconnect() end
        entry.addConn = char.DescendantAdded:Connect(function(v) pcall(applyOne, v) end)
    end
    rebuild()
    entry.hbConn = RunService.Heartbeat:Connect(function()
        if not Hide.map[p.UserId] then return end
        for part in pairs(entry.parts) do
            if part.Parent == nil then
                entry.parts[part] = nil
            elseif part.LocalTransparencyModifier ~= 1 then
                part.LocalTransparencyModifier = 1
            end
        end
    end)
    entry.charConn = p.CharacterAdded:Connect(function()
        entry.savedVols = {}
        voicePause(p.UserId, true)
        task.defer(rebuild)
    end)
    entry.leaveConn = Players.PlayerRemoving:Connect(function(leaving)
        if leaving ~= p then return end
        hideDisconnect(entry)
        Hide.map[p.UserId] = nil
    end)
    return true
end

function Hide.setUI(hidden)
    Hide.uiHidden = hidden
    if ui then ui.Enabled = not hidden end
end

table.insert(cleanups, function()
    for uid in pairs(Hide.map) do hideRestore(uid) end
end)

------------------------------------------------------------------------
-- Mute / unmute (their chat messages and character sounds, on your side only)
------------------------------------------------------------------------

Mute = { players = {}, sounds = {}, charConns = {}, chat = false }

local function muteApplySound(s)
    if s:IsA("Sound") and Mute.sounds[s] == nil then
        Mute.sounds[s] = s.Volume
        s.Volume = 0
    end
end

function Mute.muteChar(char)
    for _, d in ipairs(char:GetDescendants()) do muteApplySound(d) end
    if not Mute.charConns[char] then
        Mute.charConns[char] = char.DescendantAdded:Connect(muteApplySound)
    end
end

function Mute.unmuteChar(char)
    local c = Mute.charConns[char]
    if c then c:Disconnect(); Mute.charConns[char] = nil end
    for _, d in ipairs(char:GetDescendants()) do
        local v = Mute.sounds[d]
        if v ~= nil then
            pcall(function() d.Volume = v end)
            Mute.sounds[d] = nil
        end
    end
end

-- Replaces any OnIncomingMessage callback the game set (callbacks cannot be read back).
function Mute.installChat()
    if Mute.chat then return true end
    if TextChatService.ChatVersion ~= Enum.ChatVersion.TextChatService then return false end
    local ok = pcall(function()
        TextChatService.OnIncomingMessage = function(message)
            local props = Instance.new("TextChatMessageProperties")
            local src = message.TextSource
            if src and Mute.players[src.UserId] then props.Text = "" end
            return props
        end
    end)
    Mute.chat = ok
    return ok
end

function Mute.removeChat()
    if Mute.chat then
        pcall(function() TextChatService.OnIncomingMessage = nil end)
        Mute.chat = false
    end
end

-- Returns true when chat muting is active for this change (TextChatService games only).
function Mute.set(p, on)
    Mute.players[p.UserId] = on or nil
    -- voice pause is the engine's mute (SubscribePause); skipped while they are hidden
    if p ~= plr and (on or not Hide.map[p.UserId]) then voicePause(p.UserId, on and true or false) end
    if p.Character then
        if on then Mute.muteChar(p.Character) else Mute.unmuteChar(p.Character) end
    end
    if next(Mute.players) then return Mute.installChat() end
    Mute.removeChat()
    return true
end

Watch.onCharacter(function(p, char)
    if Mute.players[p.UserId] then Mute.muteChar(char) end
end)

table.insert(cleanups, function()
    for uid in pairs(Mute.players) do
        if not Hide.map[uid] then voicePause(uid, false) end
    end
    Mute.players = {}
    for char in pairs(Mute.charConns) do Mute.unmuteChar(char) end
    Mute.removeChat()
end)

------------------------------------------------------------------------
-- Auras / VFX (add your own with Aura.register). Assigned auras are shared
-- through auras.json (see AuraSync): every copy of the script draws them.
------------------------------------------------------------------------

local Aura = {
    defs = {},
    order = {},
    state = {},                      -- userId -> name -> { color, h, hrp }
    folder = nil,
    defaultColor = Color3.fromRGB(120, 200, 255),
}

function Aura.getFolder()
    if not Aura.folder or not Aura.folder.Parent then
        Aura.folder = make("Folder", { Name = "PuppyAdminAuras" }, workspace)
    end
    return Aura.folder
end

local function fxNew(class, props, parent)
    props.Name = "PuppyAdminFX"
    return make(class, props, parent)
end

local function fxPart(props)
    props.Name = "PuppyAdminFX"
    props.Anchored = true
    props.CanCollide = false
    props.CanQuery = false
    props.CanTouch = false
    props.Massless = true
    props.CastShadow = false
    return make("Part", props, Aura.getFolder())
end

-- build(ctx) -> { objs = { instances to destroy }, step = function(t, dt) or nil }
-- ctx = { char, hrp, head, color }. opts.ownColors: the aura keeps its
-- texture's colours unless a colour is given explicitly.
function Aura.register(name, desc, build, opts)
    name = name:lower()
    if not Aura.defs[name] then table.insert(Aura.order, name) end
    Aura.defs[name] = { name = name, desc = desc, build = build, ownColors = opts and opts.ownColors or false }
end

-- Aura textures live in the repository (SETTINGS.Auras.assetBase .. file);
-- each copy downloads them once and loads them with getcustomasset.
Aura.textures, Aura.loading = {}, {}
function Aura.texture(file, auraName)
    local tex = Aura.textures[file]
    if tex then return tex ~= false and tex or nil end
    if not Aura.loading[file] then
        Aura.loading[file] = true
        task.spawn(function()
            local url = SETTINGS.Auras.assetBase .. file
            local got = urlImageAsset(url, "aura")
            Aura.textures[file] = got or false
            Aura.loading[file] = nil
            if not got then
                note("Aura", "Could not load " .. file .. " (needs getcustomasset + writefile)", RED)
                return
            end
            -- build again for everyone wearing an aura that was waiting for it
            for uid, st in pairs(Aura.state) do
                if st[auraName] then
                    local p = Players:GetPlayerByUserId(uid)
                    if p and p.Character then Aura.build(p, p.Character, auraName) end
                end
            end
        end)
    end
    return nil
end

Aura.register("fire", "Flames around the body", function(c)
    return { objs = { fxNew("Fire", {
        Color = c.color,
        SecondaryColor = c.color:Lerp(Color3.new(0, 0, 0), 0.5),
        Size = 8,
        Heat = 9,
    }, c.hrp) } }
end)

Aura.register("sparkles", "Sparkles drifting off the body", function(c)
    return { objs = { fxNew("Sparkles", { SparkleColor = c.color }, c.hrp) } }
end)

Aura.register("smoke", "Slow rising smoke", function(c)
    return { objs = { fxNew("Smoke", { Color = c.color, Opacity = 0.35, RiseVelocity = 4, Size = 6 }, c.hrp) } }
end)

Aura.register("glow", "Outline highlight plus a soft light", function(c)
    return { objs = {
        fxNew("Highlight", {
            Adornee = c.char,
            FillColor = c.color,
            OutlineColor = c.color,
            FillTransparency = 0.75,
            OutlineTransparency = 0.1,
        }, c.hrp),
        fxNew("PointLight", { Color = c.color, Range = 14, Brightness = 2 }, c.hrp),
    } }
end)

Aura.register("trail", "Light trail behind the body", function(c)
    local a0 = fxNew("Attachment", { Position = Vector3.new(0, 1.2, 0) }, c.hrp)
    local a1 = fxNew("Attachment", { Position = Vector3.new(0, -1.2, 0) }, c.hrp)
    local tr = fxNew("Trail", {
        Attachment0 = a0,
        Attachment1 = a1,
        Lifetime = 0.7,
        Color = ColorSequence.new(c.color),
        Transparency = NumberSequence.new(0.2, 1),
        LightEmission = 1,
    }, c.hrp)
    return { objs = { a0, a1, tr } }
end)

Aura.register("orbs", "Four glowing orbs circling you", function(c)
    local orbs = {}
    for i = 1, 4 do
        orbs[i] = fxPart({
            Shape = Enum.PartType.Ball,
            Material = Enum.Material.Neon,
            Color = c.color,
            Size = Vector3.new(0.7, 0.7, 0.7),
        })
    end
    return {
        objs = orbs,
        step = function(t)
            local base = c.hrp.Position
            for i, o in ipairs(orbs) do
                local a = t * 2 + (i - 1) * (math.pi / 2)
                o.Position = base + Vector3.new(math.cos(a) * 3.2, math.sin(t * 3 + i) * 0.9, math.sin(a) * 3.2)
            end
        end,
    }
end)

Aura.register("ring", "Spinning ring at your feet", function(c)
    local ring = fxPart({
        Shape = Enum.PartType.Cylinder,
        Material = Enum.Material.Neon,
        Color = c.color,
        Transparency = 0.35,
        Size = Vector3.new(0.15, 6, 6),
    })
    return {
        objs = { ring },
        step = function(t)
            ring.CFrame = CFrame.new(c.hrp.Position - Vector3.new(0, 2.8, 0))
                * CFrame.Angles(0, t * 2, 0) * CFrame.Angles(0, 0, math.pi / 2)
        end,
    }
end)

Aura.register("halo", "Ring floating above the head", function(c)
    local halo = fxPart({
        Shape = Enum.PartType.Cylinder,
        Material = Enum.Material.Neon,
        Color = c.color,
        Transparency = 0.2,
        Size = Vector3.new(0.12, 2.2, 2.2),
    })
    return {
        objs = { halo },
        step = function(t)
            local p = c.head.Position + Vector3.new(0, 1.3 + math.sin(t * 2) * 0.1, 0)
            halo.CFrame = CFrame.new(p) * CFrame.Angles(0, 0, math.pi / 2)
        end,
    }
end)

Aura.register("pulse", "Breathing force-field bubble", function(c)
    local bubble = fxPart({
        Shape = Enum.PartType.Ball,
        Material = Enum.Material.ForceField,
        Color = c.color,
        Transparency = 0.4,
        Size = Vector3.new(7, 7, 7),
    })
    return {
        objs = { bubble },
        step = function(t)
            local s = 7 + math.sin(t * 3) * 1.2
            bubble.Size = Vector3.new(s, s, s)
            bubble.Position = c.hrp.Position
        end,
    }
end)

-- 8x8 flipbook (64 frames, 30 fps) on one camera-facing particle at the feet.
-- One particle lives exactly one loop and the next starts as it ends.
Aura.register("lightning", "Pink lightning charge at your feet (animated)", function(c)
    local tex = Aura.texture("assets/auras/lightning_charge_pink.png", "lightning")
    if not tex then return nil end
    local hum = c.char:FindFirstChildOfClass("Humanoid")
    local legs = (hum and hum.RigType == Enum.HumanoidRigType.R15) and hum.HipHeight or 2
    local size = 9
    local feet = -(c.hrp.Size.Y / 2 + legs)
    local att = fxNew("Attachment", { Position = Vector3.new(0, feet + size * 0.28, 0) }, c.hrp)
    local loop = 64 / 30
    local em = fxNew("ParticleEmitter", {
        Texture = tex, Color = ColorSequence.new(c.color or Color3.new(1, 1, 1)),
        Size = NumberSequence.new(size), Transparency = NumberSequence.new(0), LightEmission = 0.6,
        Lifetime = NumberRange.new(loop), Rate = 1 / loop, Speed = NumberRange.new(0),
        Rotation = NumberRange.new(0), RotSpeed = NumberRange.new(0), LockedToPart = true,
        Orientation = Enum.ParticleOrientation.FacingCamera, ZOffset = 1,
    }, att)
    pcall(function()
        em.FlipbookLayout = Enum.ParticleFlipbookLayout.Grid8x8
        em.FlipbookMode = Enum.ParticleFlipbookMode.OneShot
        em.FlipbookStartRandom = false
    end)
    em:Emit(1)
    return { objs = { att } }
end, { ownColors = true })

local function auraDestroyObjs(entry)
    if entry.h and entry.h.objs then
        for _, o in ipairs(entry.h.objs) do pcall(function() o:Destroy() end) end
    end
    entry.h = nil
end

function Aura.build(player, char, name)
    local st = Aura.state[player.UserId]
    local entry = st and st[name]
    local def = Aura.defs[name]
    if not entry or not def then return end
    auraDestroyObjs(entry)
    local root = char:FindFirstChild("HumanoidRootPart")
    if not root then return end
    local ok, h = pcall(def.build, { char = char, hrp = root, head = char:FindFirstChild("Head") or root, color = entry.color })
    if ok and h then
        entry.h, entry.hrp = h, root
    end
end

function Aura.apply(player, name, color)
    if not Aura.defs[name] then return false end
    local st = Aura.state[player.UserId]
    if not st then st = {}; Aura.state[player.UserId] = st end
    if st[name] then auraDestroyObjs(st[name]) end
    local fallback = Aura.defaultColor
    if Aura.defs[name].ownColors then fallback = nil end
    st[name] = { color = color or fallback }
    if player.Character then Aura.build(player, player.Character, name) end
    return true
end

-- name nil removes every aura from that player. Returns how many were removed.
function Aura.remove(player, name)
    local st = Aura.state[player.UserId]
    if not st then return 0 end
    local n = 0
    for k, entry in pairs(st) do
        if not name or name == k then
            auraDestroyObjs(entry)
            st[k] = nil
            n = n + 1
        end
    end
    return n
end

function Aura.step(t, dt)
    for _, st in pairs(Aura.state) do
        for _, entry in pairs(st) do
            local h = entry.h
            if h then
                if not entry.hrp or not entry.hrp:IsDescendantOf(workspace) then
                    auraDestroyObjs(entry)
                elseif h.step then
                    pcall(h.step, t, dt)
                end
            end
        end
    end
end

Watch.onCharacter(function(p, char)
    local st = Aura.state[p.UserId]
    if st then
        for name in pairs(st) do Aura.build(p, char, name) end
    end
end)

table.insert(cleanups, function()
    for _, st in pairs(Aura.state) do
        for _, entry in pairs(st) do auraDestroyObjs(entry) end
    end
    Aura.state = {}
    if Aura.folder then Aura.folder:Destroy(); Aura.folder = nil end
end)

------------------------------------------------------------------------
-- Nametags (client-side billboards; named tags with members, saved in the config)
------------------------------------------------------------------------

-- A tag is a named look shared by any number of players:
--   Cfg.tagDefs = { { name, text, sub, color = {r,g,b}, rainbow, size, offset, font,
--                     backdrop = { on, color, transparency, image, imageTransparency, round },
--                     pfp = { mode = "none" | "avatar" | "custom", image, round },
--                     members = { "<UserId>", ... } }, ... }
-- A player belongs to at most one tag. Billboards live in the script's GUI
-- container (not under the head) so they can be clicked: clicking someone
-- else's tag teleports you to them (Cfg.tagClickTp).
local Presence -- who else is running the script in this server (set up after TagSync)
local AuraSync, Moderation -- shared auras and the script blacklist (set up further down)
local Tags = { gui = {}, view = {}, rainbow = {}, watch = {}, byUser = {}, assets = {}, pending = {}, ui = { current = nil } }  -- ui.current: tag open in the panels

local TAG_DEFAULTS = {
    text = "", sub = "", color = { 255, 255, 255 }, rainbow = false, size = 22, offset = 3, font = "GothamBold",
    backdrop = { on = false, color = { 18, 18, 22 }, transparency = 0.35, image = "", imageTransparency = 0.15, round = true },
    pfp = { mode = "none", image = "", round = true },
}

local function tagColor(c)
    c = type(c) == "table" and c or { 255, 255, 255 }
    return Color3.fromRGB(tonumber(c[1]) or 255, tonumber(c[2]) or 255, tonumber(c[3]) or 255)
end

-- Fills missing fields (older saves, hand-edited config) with the defaults.
function Tags.normalize(def)
    for k, v in pairs(TAG_DEFAULTS) do
        if type(v) == "table" and k ~= "color" then
            if type(def[k]) ~= "table" then def[k] = {} end
            for k2, v2 in pairs(v) do
                if def[k][k2] == nil then def[k][k2] = type(v2) == "table" and { v2[1], v2[2], v2[3] } or v2 end
            end
        elseif def[k] == nil then
            def[k] = type(v) == "table" and { v[1], v[2], v[3] } or v
        end
    end
    if type(def.members) ~= "table" then def.members = {} end
    if type(def.name) ~= "string" or def.name == "" then def.name = def.text ~= "" and def.text or "Tag" end
    return def
end

function Tags.reindex()
    Tags.byUser = {}
    for _, def in ipairs(Cfg.tagDefs) do
        if not def.isDefault then
            for _, uid in ipairs(def.members) do Tags.byUser[tostring(uid)] = def end
        end
    end
end

-- The default tag: worn by anyone running the script right now who has no
-- custom tag (see Presence). Editable like any tag; it is stored in tagDefs
-- with isDefault = true (members are ignored) and synced with the rest.
local BUILTIN_DEFAULT = {
    isDefault = true, name = "Default", text = "Puppy Admin", sub = "", color = { 255, 170, 220 }, size = 18, offset = 3,
    font = "GothamBold", rainbow = false,
    backdrop = { on = true, color = { 18, 18, 22 }, transparency = 0.35, image = "", imageTransparency = 0.15, round = true },
    pfp = { mode = "avatar", image = "", round = true },
    members = {},
}

Tags.builtinDefault = Tags.normalize(HttpService:JSONDecode(HttpService:JSONEncode(BUILTIN_DEFAULT)))

function Tags.defaultDef()
    for _, def in ipairs(Cfg.tagDefs) do
        if def.isDefault then return def end
    end
    return nil
end

-- Creates the editable default tag from the built-in look the first time it is edited.
function Tags.ensureDefault()
    local def = Tags.defaultDef()
    if def then return def end
    def = Tags.normalize(HttpService:JSONDecode(HttpService:JSONEncode(BUILTIN_DEFAULT)))
    table.insert(Cfg.tagDefs, def)
    return def
end

-- Custom tag first; otherwise the default tag, but only while that player is
-- running the script (they stop showing it when they kill it).
function Tags.defFor(player)
    local custom = Tags.byUser[tostring(player.UserId)]
    if custom then return custom end
    if Presence and Presence.isActive(player.UserId) then
        return Tags.defaultDef() or Tags.builtinDefault
    end
    return nil
end

function Tags.findDef(name)
    local l = tostring(name or ""):lower()
    for _, def in ipairs(Cfg.tagDefs) do
        if def.name:lower() == l then return def end
    end
    return nil
end

-- One-time move from the old per-user format (Cfg.tags[UserId] = look).
do
    if type(Cfg.tagDefs) ~= "table" then Cfg.tagDefs = {} end
    local migrated = false
    for uid, d in pairs(type(Cfg.tags) == "table" and Cfg.tags or {}) do
        if type(d) == "table" then
            local def = Tags.normalize({
                name = (d.text and d.text ~= "") and d.text or ("Tag " .. tostring(uid)), text = d.text, sub = d.sub,
                color = d.color, rainbow = d.rainbow, size = d.size, offset = d.offset, font = d.font,
            })
            local same = Tags.findDef(def.name)
            if same then def.name = def.name .. " (" .. tostring(uid) .. ")" end
            def.members = { tostring(uid) }
            table.insert(Cfg.tagDefs, def)
            migrated = true
        end
    end
    Cfg.tags = {}
    for _, def in ipairs(Cfg.tagDefs) do Tags.normalize(def) end
    if migrated then cfgSave() end
    Tags.reindex()
end

-- fromRemote: the change came from the repository, so it is not pushed back.
function Tags.save(fromRemote)
    Tags.reindex()
    cfgSave()
    if not fromRemote and Tags.onChange then Tags.onChange() end
end

function Tags.destroy(userId)
    local g = Tags.gui[userId]
    if g then pcall(function() g:Destroy() end) end
    Tags.gui[userId] = nil
    Tags.view[userId] = nil
    Tags.rainbow[userId] = nil
    for _, c in ipairs(Tags.watch[userId] or {}) do pcall(function() c:Disconnect() end) end
    Tags.watch[userId] = nil
end

-- Image sources are resolved once per session (URLs download), then cached.
function Tags.asset(src, onReady)
    src = tostring(src or "")
    if src == "" then return nil end
    local tex = Tags.assets[src]
    if tex then return tex ~= false and tex or nil end
    if not Tags.pending[src] then
        Tags.pending[src] = {}
        task.spawn(function()
            local resolved = resolveImageSource(src, "tag")
            Tags.assets[src] = resolved or false
            local waiting = Tags.pending[src]
            Tags.pending[src] = nil
            if resolved then for _, fn in ipairs(waiting) do pcall(fn) end end
        end)
    end
    table.insert(Tags.pending[src], onReady)
    return nil
end

-- Same move as the `goto` command: stand up if seated, then land beside them.
function Tags.teleportTo(p)
    local myChar, theirChar = plr.Character, p.Character
    local myHum = myChar and myChar:FindFirstChildOfClass("Humanoid")
    local theirHum = theirChar and theirChar:FindFirstChildOfClass("Humanoid")
    local myRoot = (myHum and myHum.RootPart) or (myChar and myChar:FindFirstChild("HumanoidRootPart"))
    local theirRoot = (theirHum and theirHum.RootPart) or (theirChar and theirChar:FindFirstChild("HumanoidRootPart"))
    if not (myRoot and theirRoot) then note("Tags", p.DisplayName .. " has no character", RED); return end
    if myHum and myHum.SeatPart then myHum.Sit = false; task.wait(0.1) end
    myRoot.CFrame = theirRoot.CFrame + Vector3.new(3, 1, 0)
    note("Tags", "Teleported to " .. p.DisplayName, LIGHT)
end

local TextService = game:GetService("TextService")

local function textWidth(text, size, font)
    if text == "" then return 0 end
    local ok, v = pcall(function() return TextService:GetTextSize(text, size, font, Vector2.new(2000, 200)) end)
    return ok and v.X or (#text * size * 0.55)
end

-- Layout (pixels): [padding][picture][gap][text / subtitle][padding], measured
-- with TextService so the backdrop, its image and the click area fit exactly.
function Tags.build(player, char)
    Tags.destroy(player.UserId)
    local def = Tags.defFor(player)
    if not def or not char then return end
    local head = char:FindFirstChild("Head") or char:FindFirstChild("HumanoidRootPart")
    if not head then return end
    local hum = char:FindFirstChildOfClass("Humanoid")
    if hum and hum.Health <= 0 then return end

    local okFont, font = pcall(function() return Enum.Font[def.font or "GothamBold"] end)
    if not okFont or not font then font = Enum.Font.GothamBold end
    local size = math.clamp(tonumber(def.size) or 22, 8, 48)
    local subSize = math.max(12, size - 8)
    local color = tagColor(def.color)
    local bd, pf = def.backdrop, def.pfp
    local text, subText = tostring(def.text or ""), tostring(def.sub or "")
    local rebuild = function() if player.Parent and player.Character == char then Tags.build(player, char) end end

    local pfpTex
    if pf.mode == "avatar" then
        pfpTex = "rbxthumb://type=AvatarHeadShot&id=" .. tostring(player.UserId) .. "&w=150&h=150"
    elseif pf.mode == "custom" then
        pfpTex = Tags.asset(pf.image, rebuild)
    end

    -- Text boxes get a full line height (glyphs are taller than TextSize) and
    -- spare width: a billboard drops what does not fit inside its bounds, and
    -- labels sized exactly to the text were the part that vanished at range.
    local lineMain = math.ceil(size * 1.35)
    local lineSub = subText ~= "" and math.ceil(subSize * 1.35) or 0
    local textH = lineMain + lineSub
    local textW = math.ceil(math.max(textWidth(text, size, font), textWidth(subText, subSize, font))) + 10
    local pic = pfpTex and math.floor(math.max(textH, size * 1.5)) or 0
    local gap = (pfpTex and textW > 0) and 8 or 0
    local padX, padY = bd.on and 12 or 4, bd.on and 6 or 4
    local cardW = math.ceil(padX * 2 + pic + gap + textW)
    local cardH = math.ceil(padY * 2 + math.max(textH, pic))

    local g = make("BillboardGui", {
        Name = "PuppyAdminTag", Adornee = head, AlwaysOnTop = true, Active = true,
        Size = UDim2.fromOffset(cardW, cardH), StudsOffset = Vector3.new(0, tonumber(def.offset) or 3, 0),
        MaxDistance = SETTINGS.TagView.renderDistance, LightInfluence = 0, ResetOnSpawn = false,
        Enabled = not Cfg.tagsHidden and Hide.map[player.UserId] == nil,
    }, nil)
    pcall(function() g.ClipsDescendants = false end)

    local card = make("Frame", {
        Name = "Card", Size = UDim2.fromScale(1, 1), BorderSizePixel = 0, ClipsDescendants = false,
        BackgroundColor3 = tagColor(bd.color), BackgroundTransparency = bd.on and math.clamp(tonumber(bd.transparency) or 0.35, 0, 1) or 1,
    }, g)
    if bd.on then
        if bd.round then make("UICorner", { CornerRadius = UDim.new(0, math.min(14, cardH / 2)) }, card) end
        local tex = Tags.asset(bd.image, rebuild)
        if tex then
            local img = make("ImageLabel", {
                Name = "BackdropImage", Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, Image = tex,
                ImageTransparency = math.clamp(tonumber(bd.imageTransparency) or 0.15, 0, 1), ScaleType = Enum.ScaleType.Crop,
            }, card)
            if bd.round then make("UICorner", { CornerRadius = UDim.new(0, math.min(14, cardH / 2)) }, img) end
        end
    end

    local picture
    if pfpTex then
        picture = make("ImageLabel", {
            Name = "Pfp", Position = UDim2.fromOffset(padX, math.floor((cardH - pic) / 2)), Size = UDim2.fromOffset(pic, pic),
            BackgroundTransparency = 1, Image = pfpTex, ScaleType = Enum.ScaleType.Crop, ZIndex = 2,
        }, card)
        make("UICorner", { CornerRadius = pf.round and UDim.new(1, 0) or UDim.new(0, 6) }, picture)
    end

    -- Text the way the original tags did it: a scale-sized area filling the
    -- space right of the picture, labels filling it by scale, and TextScaled
    -- (capped at the chosen size) so the engine fits the text to its box
    -- instead of dropping it when the billboard is far away.
    local align = pfpTex and Enum.TextXAlignment.Left or Enum.TextXAlignment.Center
    local area = make("Frame", {
        Name = "TextArea", BackgroundTransparency = 1, ClipsDescendants = false, ZIndex = 2,
        Position = UDim2.fromOffset(padX + pic + gap, padY), Size = UDim2.new(1, -(padX * 2 + pic + gap), 1, -padY * 2),
    }, card)
    local split = subText ~= "" and (lineMain / textH) or 1
    local main = make("TextLabel", {
        Size = UDim2.fromScale(1, split), BackgroundTransparency = 1,
        Text = text, Font = font, TextSize = size, TextScaled = true, TextColor3 = color, TextStrokeTransparency = 0.3,
        TextXAlignment = align, TextYAlignment = Enum.TextYAlignment.Center, ZIndex = 2,
    }, area)
    make("UITextSizeConstraint", { MaxTextSize = size, MinTextSize = 1 }, main)
    local sub = make("TextLabel", {
        Position = UDim2.fromScale(0, split), Size = UDim2.fromScale(1, 1 - split), BackgroundTransparency = 1,
        Text = subText, Font = font, TextSize = subSize, TextScaled = true, TextColor3 = color:Lerp(Color3.new(1, 1, 1), 0.4),
        TextStrokeTransparency = 0.4, TextXAlignment = align, TextYAlignment = Enum.TextYAlignment.Center,
        Visible = subText ~= "", ZIndex = 2,
    }, area)
    make("UITextSizeConstraint", { MaxTextSize = subSize, MinTextSize = 1 }, sub)

    -- your own tag never teleports; clicks on it pass through to the world
    if player ~= plr and Cfg.tagClickTp then
        local hit = make("TextButton", {
            Name = "Teleport", Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, Text = "", ZIndex = 5,
            AutoButtonColor = false,
        }, card)
        hit.MouseButton1Click:Connect(function() task.spawn(Tags.teleportTo, player) end)
    end

    parentGui(g)
    Tags.gui[player.UserId] = g
    if def.rainbow then Tags.rainbow[player.UserId] = { main, sub } end
    -- what Tags.step needs to switch between the full tag and the picture only
    Tags.view[player.UserId] = {
        g = g, head = head, card = card, area = area, picture = picture, pic = pic,
        fullSize = g.Size, picPos = picture and picture.Position, cardTr = card.BackgroundTransparency,
        backdrop = card:FindFirstChild("BackdropImage"), compact = false,
    }

    -- the tag goes with the player: gone on death, or once the body leaves the
    -- world; the respawned character gets a fresh one from Watch
    local uid = player.UserId
    local watch = {}
    if hum then table.insert(watch, hum.Died:Connect(function() if Tags.gui[uid] == g then Tags.destroy(uid) end end)) end
    table.insert(watch, head.AncestryChanged:Connect(function()
        if Tags.gui[uid] == g and not head:IsDescendantOf(workspace) then Tags.destroy(uid) end
    end))
    Tags.watch[uid] = watch
end

function Tags.refresh(userId)
    local p = Players:GetPlayerByUserId(tonumber(userId) or 0)
    if p and p.Character then Tags.build(p, p.Character) else Tags.destroy(tonumber(userId)) end
end

function Tags.refreshAll()
    for uid in pairs(Tags.gui) do Tags.destroy(uid) end
    for _, p in ipairs(Players:GetPlayers()) do
        if p.Character then Tags.build(p, p.Character) end
    end
end

-- Full tag or picture only. With no picture, a far tag is not drawn at all.
function Tags.setCompact(v, on)
    if v.compact == on then return end
    v.compact = on
    if on then
        if v.picture then
            v.g.Size = UDim2.fromOffset(v.pic + 8, v.pic + 8)
            v.picture.Position = UDim2.fromOffset(4, 4)
            v.card.Visible = true
        else
            v.card.Visible = false
        end
        v.area.Visible = false
        v.card.BackgroundTransparency = 1
        if v.backdrop then v.backdrop.Visible = false end
    else
        v.g.Size = v.fullSize
        if v.picture then v.picture.Position = v.picPos end
        v.card.Visible = true
        v.area.Visible = true
        v.card.BackgroundTransparency = v.cardTr
        if v.backdrop then v.backdrop.Visible = true end
    end
end

function Tags.step(t)
    -- `hide <player>` hides their tag too (the billboard is not under their head any more);
    -- Cfg.tagsHidden (hidetags / Settings) hides them all, on your screen only
    local all = not Cfg.tagsHidden
    for uid, g in pairs(Tags.gui) do
        local show = all and Hide.map[uid] == nil
        if g.Enabled ~= show then g.Enabled = show end
    end
    -- far from your camera or your character: picture only (2 studs of slack so it does not flicker at the edge)
    local cam = workspace.CurrentCamera
    local camPos = cam and cam.CFrame.Position
    local myChar = plr.Character
    local myRoot = myChar and (myChar:FindFirstChild("HumanoidRootPart") or myChar:FindFirstChild("Head"))
    local myPos = myRoot and myRoot.Position
    local near = SETTINGS.TagView.fullDistance
    for uid, v in pairs(Tags.view) do
        if v.head.Parent then
            local pos = v.head.Position
            local far = 0
            if camPos then far = math.max(far, (pos - camPos).Magnitude) end
            -- your own tag only goes by the camera (zooming far out)
            if myPos and uid ~= plr.UserId then far = math.max(far, (pos - myPos).Magnitude) end
            local limit = v.compact and (near - 2) or (near + 2)
            Tags.setCompact(v, far > limit)
        end
    end
    local c = Color3.fromHSV((t * 0.25) % 1, 0.9, 1)
    for uid, pair in pairs(Tags.rainbow) do
        if pair[1].Parent then
            pair[1].TextColor3 = c
            pair[2].TextColor3 = c:Lerp(Color3.new(1, 1, 1), 0.4)
        else
            Tags.rainbow[uid] = nil
        end
    end
end

-- Members ---------------------------------------------------------------------

function Tags.newDef(name)
    local base = tostring(name or ""):sub(1, 30)
    if base == "" then base = "Tag" end
    local n, final = 1, base
    while Tags.findDef(final) do n = n + 1; final = base .. " " .. n end
    local def = Tags.normalize({ name = final, text = final })
    table.insert(Cfg.tagDefs, def)
    Tags.save()
    return def
end

function Tags.deleteDef(def)
    local idx = table.find(Cfg.tagDefs, def)
    if not idx then return end
    table.remove(Cfg.tagDefs, idx)
    Tags.save()
    if def.isDefault then Tags.refreshAll() return end -- back to the built-in default look
    for _, uid in ipairs(def.members) do Tags.refresh(uid) end
end

-- uids: UserIds (numbers or strings). Someone already in another tag moves here.
function Tags.addMembers(def, uids)
    if def.isDefault then return 0 end -- the default tag follows the script users, not a list
    local added = 0
    for _, uid in ipairs(uids) do
        local key = tostring(uid)
        local old = Tags.byUser[key]
        if old ~= def then
            if old then
                local i = table.find(old.members, key)
                if i then table.remove(old.members, i) end
            end
            table.insert(def.members, key)
            added = added + 1
        end
    end
    Tags.save()
    for _, uid in ipairs(uids) do Tags.refresh(uid) end
    return added
end

function Tags.removeMember(def, uid)
    local i = table.find(def.members, tostring(uid))
    if not i then return false end
    table.remove(def.members, i)
    Tags.save()
    Tags.refresh(uid)
    return true
end

-- Tokens: UserId, player name / display name (in server), "all", "others",
-- or the name of someone who is not here (looked up by username; yields).
function Tags.resolveUsers(tokens)
    local out, seen, missing = {}, {}, {}
    local function push(id)
        id = tonumber(id)
        if id and id > 0 and not seen[id] then seen[id] = true; table.insert(out, id) end
    end
    for _, tok in ipairs(tokens) do
        for piece in tostring(tok):gmatch("[^,%s]+") do
            if piece:match("^%d+$") then
                push(piece)
            else
                local found = resolveTargets(piece)
                if #found > 0 then
                    for _, p in ipairs(found) do push(p.UserId) end
                else
                    local ok, id = pcall(function() return Players:GetUserIdFromNameAsync(piece) end)
                    if ok and id then push(id) else table.insert(missing, piece) end
                end
            end
        end
    end
    return out, missing
end

-- Display name for a member, also when they are not in the server.
function Tags.memberName(uid)
    local p = Players:GetPlayerByUserId(tonumber(uid) or 0)
    if p then return p.DisplayName .. " (@" .. p.Name .. ")" end
    return "UserId " .. tostring(uid)
end

Watch.onCharacter(function(p, char) Tags.build(p, char) end)
table.insert(conns, Players.PlayerRemoving:Connect(function(p) Tags.destroy(p.UserId) end))

table.insert(cleanups, function()
    for uid in pairs(Tags.gui) do Tags.destroy(uid) end
end)


-- Only these accounts may open the nametag editor and change tags (Player.Name,
-- compared case-insensitively). This is a client-side gate inside the script, not
-- real security: anyone who can edit the file can change this list.
local TAG_EDITORS = { "internetpuppyboy", "toyospuppy", "enterhikari", "laluneestmagnifique" }

local function canEditTags()
    local n = plr.Name:lower()
    for _, name in ipairs(TAG_EDITORS) do
        if n == name then return true end
    end
    return false
end

------------------------------------------------------------------------
-- Tag sync: every player running the script shows the tags kept in the
-- repository (SETTINGS.TagSync.path on SETTINGS.TagSync.branch).
--   * Everyone reads it: at startup and every pollSeconds.
--   * Only someone with a GitHub token writes it: each tag change commits
--     the whole tag list (changes within a few seconds become one commit).
-- The token is read from SETTINGS.TagSync.tokenFile in the executor
-- workspace. It is never in the script or in puppyadmin.json, so sharing
-- either does not share write access. Use a fine-grained token limited to
-- this one repository with Contents: read and write.
------------------------------------------------------------------------

local TagSync = { status = "starting", lastJson = nil, pushQueued = false, warnedReadOnly = false, etag = nil, apiBlockedUntil = 0 }

do
    local CFG = SETTINGS.TagSync
    local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

    local function b64encode(data)
        local out = {}
        for i = 1, #data, 3 do
            local a, b, c = data:byte(i, i + 2)
            local n = a * 65536 + (b or 0) * 256 + (c or 0)
            local c1 = math.floor(n / 262144) % 64
            local c2 = math.floor(n / 4096) % 64
            local c3 = math.floor(n / 64) % 64
            local c4 = n % 64
            out[#out + 1] = B64:sub(c1 + 1, c1 + 1) .. B64:sub(c2 + 1, c2 + 1)
                .. (b and B64:sub(c3 + 1, c3 + 1) or "=") .. (c and B64:sub(c4 + 1, c4 + 1) or "=")
        end
        return table.concat(out)
    end

    local function b64decode(data)
        data = data:gsub("[^%w%+/=]", "")
        local map = {}
        for i = 1, 64 do map[B64:byte(i)] = i - 1 end
        local out = {}
        for i = 1, #data, 4 do
            local a, b, c, d = data:byte(i, i + 3)
            local n = (map[a] or 0) * 262144 + (map[b] or 0) * 4096 + (map[c] or 0) * 64 + (map[d] or 0)
            out[#out + 1] = string.char(math.floor(n / 65536) % 256)
            if c and c ~= 61 then out[#out + 1] = string.char(math.floor(n / 256) % 256) end
            if d and d ~= 61 then out[#out + 1] = string.char(n % 256) end
        end
        return table.concat(out)
    end

    local function httpRequest(opts)
        local fn = (type(request) == "function" and request) or (type(http_request) == "function" and http_request)
            or (type(syn) == "table" and type(syn.request) == "function" and syn.request)
            or (type(fluxus) == "table" and type(fluxus.request) == "function" and fluxus.request)
            or (type(http) == "table" and type(http.request) == "function" and http.request)
        if not fn then return nil, "executor has no request()" end
        local ok, res = pcall(fn, opts)
        if not ok then return nil, tostring(res) end
        if type(res) ~= "table" then return nil, "no response" end
        return res
    end

    TagSync.request = httpRequest

    local function apiUrl(path)
        return "https://api.github.com/repos/" .. CFG.owner .. "/" .. CFG.repo .. "/contents/" .. (path or CFG.path)
    end

    function TagSync.token()
        if not (isfile and readfile) then return nil end
        local ok, t = pcall(function() return isfile(CFG.tokenFile) and readfile(CFG.tokenFile) end)
        t = ok and type(t) == "string" and t:match("^%s*(%S+)%s*$") or nil
        return t
    end

    function TagSync.setToken(t)
        t = tostring(t or ""):match("^%s*(%S*)%s*$")
        if not writefile then return false, "executor has no writefile" end
        pcall(function()
            if isfolder and makefolder and not isfolder("PuppyAdmin") then makefolder("PuppyAdmin") end
        end)
        if t == "" then
            if delfile then pcall(delfile, CFG.tokenFile) else pcall(writefile, CFG.tokenFile, "") end
            return true, "Token removed - tag sync is read-only"
        end
        if not (t:match("^github_pat_[%w_]+$") or t:match("^gh[pousr]_[%w]+$")) then
            return false, "That does not look like a GitHub token"
        end
        local ok = pcall(writefile, CFG.tokenFile, t)
        if not ok then return false, "Could not write " .. CFG.tokenFile end
        return true, "Token saved to " .. CFG.tokenFile
    end

    local function headers(token)
        local h = {
            ["Accept"] = "application/vnd.github+json",
            ["X-GitHub-Api-Version"] = "2022-11-28",
            ["User-Agent"] = "PuppyAdmin-TagSync",
        }
        if token then h["Authorization"] = "Bearer " .. token end
        return h
    end

    local function clampStr(v, n) return type(v) == "string" and v:sub(1, n) or nil end
    local function clampNum(v, lo, hi, d) v = tonumber(v); if not v or v ~= v then return d end return math.clamp(v, lo, hi) end
    local function rgb(v, d)
        if type(v) ~= "table" then return d end
        return { clampNum(v[1], 0, 255, d[1]), clampNum(v[2], 0, 255, d[2]), clampNum(v[3], 0, 255, d[3]) }
    end

    -- The file is shown on everyone's screen, so only known fields and sane
    -- values get through; anything else is dropped.
    function TagSync.sanitize(list)
        if type(list) ~= "table" then return nil end
        local out, haveDefault = {}, false
        for i = 1, math.min(#list, 200) do
            local d = list[i]
            local isDefault = type(d) == "table" and d.isDefault == true and not haveDefault
            if isDefault then haveDefault = true end
            if type(d) == "table" and type(d.name) == "string" and (d.isDefault ~= true or isDefault) then
                local bd = type(d.backdrop) == "table" and d.backdrop or {}
                local pf = type(d.pfp) == "table" and d.pfp or {}
                local members = {}
                if type(d.members) == "table" then
                    for j = 1, math.min(#d.members, 500) do
                        local m = tostring(d.members[j])
                        if m:match("^%d+$") and #m <= 20 then members[#members + 1] = m end
                    end
                end
                out[#out + 1] = Tags.normalize({
                    isDefault = isDefault or nil,
                    name = clampStr(d.name, 30), text = clampStr(d.text, 40) or "", sub = clampStr(d.sub, 40) or "",
                    color = rgb(d.color, { 255, 255, 255 }), rainbow = d.rainbow == true,
                    size = clampNum(d.size, 8, 48, 22), offset = clampNum(d.offset, 0, 12, 3),
                    font = clampStr(d.font, 40) or "GothamBold",
                    backdrop = {
                        on = bd.on == true, color = rgb(bd.color, { 18, 18, 22 }), transparency = clampNum(bd.transparency, 0, 1, 0.35),
                        image = clampStr(bd.image, 300) or "", imageTransparency = clampNum(bd.imageTransparency, 0, 1, 0.15),
                        round = bd.round ~= false,
                    },
                    pfp = {
                        mode = (pf.mode == "avatar" or pf.mode == "custom") and pf.mode or "none",
                        image = clampStr(pf.image, 300) or "", round = pf.round ~= false,
                    },
                    members = members,
                })
            end
        end
        return out
    end

    local function encodeTags()
        return HttpService:JSONEncode(Cfg.tagDefs)
    end

    -- Replaces the local tags with the repository's (no push back).
    local function apply(text)
        local ok, decoded = pcall(function() return HttpService:JSONDecode(text) end)
        local list = ok and TagSync.sanitize(decoded)
        if not list then return false end
        local js = HttpService:JSONEncode(list)
        if js == TagSync.lastJson then return true end
        -- same content as what is already here (e.g. our own last push): nothing to redo
        if js == HttpService:JSONEncode(TagSync.sanitize(Cfg.tagDefs) or {}) then TagSync.lastJson = js; return true end
        TagSync.lastJson = js
        Cfg.tagDefs = list
        if Tags.ui.current and not table.find(Cfg.tagDefs, Tags.ui.current) then Tags.ui.current = nil end
        Tags.save(true)
        Tags.refreshAll()
        if UIAPI.syncFns.taglist then pcall(UIAPI.syncFns.taglist) end
        return true
    end

    -- executors pass headers through with whatever casing the server used ("Etag")
    local function header(res, name)
        local want = name:lower()
        for k, v in pairs(type(res.Headers) == "table" and res.Headers or {}) do
            if type(k) == "string" and k:lower() == want then return v end
        end
        return nil
    end

    -- The contents API is always current (the raw file is cached by GitHub for
    -- minutes). Each read sends the last ETag (kept in st.etag): an unchanged
    -- file answers 304, which GitHub does not count against the rate limit.
    -- Returns ok, text | "unchanged" | nil (no file), sha. Used for every
    -- shared file in the repository (tags.json, auras.json).
    function TagSync.readPath(path, st, fresh)
        local token = TagSync.token()
        local h = headers(token)
        if st.etag and not fresh then h["If-None-Match"] = st.etag end
        local res
        -- without a token GitHub allows 60 API reads an hour: once refused, read the raw file until the reset
        if token or os.time() >= TagSync.apiBlockedUntil then
            res = httpRequest({ Url = apiUrl(path) .. "?ref=" .. CFG.branch, Method = "GET", Headers = h })
        end
        if res then
            local code = tonumber(res.StatusCode) or 0
            if not token and (code == 403 or code == 429) then TagSync.blockApi(res) end
            if code == 304 then return true, "unchanged", nil end
            if code == 404 then st.etag = nil; return true, nil, nil end
            if code == 200 then
                local ok, meta = pcall(function() return HttpService:JSONDecode(res.Body) end)
                if ok and type(meta) == "table" and type(meta.content) == "string" then
                    st.etag = header(res, "ETag")
                    return true, b64decode(meta.content), meta.sha
                end
            end
            if token then return false, "GitHub said " .. tostring(code) end
            -- no token and the API refused (e.g. rate limit): fall through to the raw file
        elseif token then
            return false, "executor has no request() - cannot write to the repository"
        end
        local url = "https://raw.githubusercontent.com/" .. CFG.owner .. "/" .. CFG.repo .. "/" .. CFG.branch .. "/" .. path
        local ok, body = pcall(function() return game:HttpGet(url .. "?t=" .. tostring(os.time())) end)
        local first = type(body) == "string" and body:match("^%s*(.)")
        if not ok or (first ~= "[" and first ~= "{") then return true, nil, nil end
        return true, body, nil
    end

    function TagSync.blockApi(res)
        local reset = tonumber(header(res, "X-RateLimit-Reset"))
        local now = os.time()
        TagSync.apiBlockedUntil = (reset and reset > now and reset - now < 3600) and reset or now + 600
    end

    -- One request for the whole repository root: returns ok, { [name] = sha } |
    -- "unchanged". A 304 (nothing changed anywhere) is free with a token. ok is
    -- false when the API cannot be used right now (no request(), rate limit).
    function TagSync.listRoot(st)
        local token = TagSync.token()
        if not token and os.time() < TagSync.apiBlockedUntil then return false, "rate limited" end
        local h = headers(token)
        if st.etag then h["If-None-Match"] = st.etag end
        local res, err = httpRequest({ Url = apiUrl("") .. "?ref=" .. CFG.branch, Method = "GET", Headers = h })
        if not res then return false, err end
        local code = tonumber(res.StatusCode) or 0
        if code == 304 then return true, "unchanged" end
        if code == 200 then
            local okJ, list = pcall(function() return HttpService:JSONDecode(res.Body) end)
            if okJ and type(list) == "table" then
                local shas = {}
                for _, e in ipairs(list) do
                    if type(e) == "table" and type(e.name) == "string" and type(e.sha) == "string" then shas[e.name] = e.sha end
                end
                st.etag = header(res, "ETag")
                return true, shas
            end
            return false, "listing is not valid"
        end
        if not token and (code == 403 or code == 429) then TagSync.blockApi(res) end
        return false, "GitHub said " .. tostring(code)
    end

    -- Commits body as path (creates it when missing). Returns ok, message.
    function TagSync.writePath(path, body, message, st)
        local token = TagSync.token()
        if not token then return false, "no token - add one in Settings" end
        for attempt = 1, 2 do
            local ok, text, sha = TagSync.readPath(path, {}, true)
            if not ok then return false, "read failed: " .. tostring(text) end
            if text == body then return true, "already up to date" end
            local payload = HttpService:JSONEncode({ message = message, content = b64encode(body), branch = CFG.branch, sha = sha })
            local h = headers(token)
            h["Content-Type"] = "application/json"
            local res, err = httpRequest({ Url = apiUrl(path), Method = "PUT", Headers = h, Body = payload })
            if not res then return false, err end
            if res.StatusCode == 200 or res.StatusCode == 201 then
                if st then st.etag = nil end -- next poll reads the new version
                return true, "saved"
            end
            if res.StatusCode == 401 or res.StatusCode == 403 then
                return false, "GitHub refused the token (" .. res.StatusCode .. ") - needs Contents: read and write on " .. CFG.repo
            end
            -- 409 / 422: someone else wrote in between; read the new sha and try once more
            if attempt == 2 then return false, "GitHub said " .. tostring(res.StatusCode) end
        end
        return false, "write failed"
    end

    function TagSync.fetch(fresh)
        return TagSync.readPath(CFG.path, TagSync, fresh)
    end

    function TagSync.pull(fresh)
        local ok, text, sha = TagSync.fetch(fresh)
        if not ok then TagSync.status = "read failed: " .. tostring(text); return false, TagSync.status end
        if text == "unchanged" then TagSync.status = "up to date (" .. #Cfg.tagDefs .. " tags)"; return true, TagSync.status end
        if not text then TagSync.status = "no tags file in the repository yet"; return true, TagSync.status end
        if not apply(text) then TagSync.status = "tags file is not valid"; return false, TagSync.status end
        TagSync.status = "up to date (" .. #Cfg.tagDefs .. " tags)"
        return true, TagSync.status, sha
    end

    function TagSync.push()
        local body = encodeTags()
        local ok, msg = TagSync.writePath(CFG.path, body, "Update tags (" .. #Cfg.tagDefs .. ") from PuppyAdmin", TagSync)
        if not ok then return false, msg end
        TagSync.lastJson = body
        return true, msg == "saved" and ("pushed " .. #Cfg.tagDefs .. " tags") or msg
    end

    -- Called by Tags.save after every local change.
    function TagSync.changed()
        if not TagSync.token() then
            if not TagSync.warnedReadOnly then
                TagSync.warnedReadOnly = true
                note("Tags", "Saved on this device only - add a GitHub token in Settings to share tags", GREY)
            end
            return
        end
        if TagSync.pushQueued then return end
        TagSync.pushQueued = true
        task.delay(CFG.pushDelay, function()
            TagSync.pushQueued = false
            if genv.PuppyAdminActive ~= true then return end
            local ok, msg = TagSync.push()
            TagSync.status = msg
            note("Tag sync", msg, ok and LIGHT or RED)
        end)
    end

    function TagSync.start()
        task.spawn(function()
            -- an editor without a token keeps their local tags (they could not share edits anyway)
            local readOnlyEditor = canEditTags() and not TagSync.token()
            local fetchStart = os.clock()
            if not readOnlyEditor or #Cfg.tagDefs == 0 then TagSync.pull(true) end
            Perf.since("First tags read (background)", fetchStart)
            -- every execution draws every tag again once the repository copy is in
            Tags.refreshAll()
            -- later reads come from RepoSync (one check for every shared file)
        end)
    end

    -- false while a local change waits to be pushed, or for an editor without
    -- a token (their local tags would be replaced by the repository copy)
    function TagSync.canPull()
        return not TagSync.pushQueued and not (canEditTags() and not TagSync.token())
    end
end

Tags.onChange = TagSync.changed

-- Tag billboards left by a run that did not shut down cleanly
-- (they live in the GUI container, not under the head).
for _, container in ipairs({ (function() local ok, g = pcall(function() return gethui and gethui() end); return ok and g or nil end)(),
    CoreGui, plr:FindFirstChildOfClass("PlayerGui") }) do
    pcall(function()
        for _, d in ipairs(container:GetChildren()) do
            if d.Name == "PuppyAdminTag" and d:IsA("BillboardGui") then d:Destroy() end
        end
    end)
end

-- Re-reads tags.json (and later auras / moderation) and rebuilds every tag.
-- Runs on `tagrefresh` and whenever the script is executed again while running.
function Tags.refreshFromRepo(quiet)
    task.spawn(function()
        local ok, msg = TagSync.pull(true)
        if AuraSync and AuraSync.pull then pcall(AuraSync.pull, true) end
        if Moderation and Moderation.pull then pcall(Moderation.pull, true) end
        Tags.refreshAll()
        if not quiet then note("Tags", ok and ("Refreshed - " .. tostring(msg)) or tostring(msg), ok and LIGHT or RED) end
    end)
end
genv.PuppyAdminRefresh = function() Tags.refreshFromRepo(false) end
table.insert(cleanups, function() genv.PuppyAdminRefresh = nil end)

TagSync.start()

------------------------------------------------------------------------
-- Presence: who in this server is running the script right now, for the
-- default tag. Every copy checks in with SETTINGS.Presence.url every
-- beatSeconds and gets back the other script users in the same server
-- (game.JobId); the server forgets anyone who has not checked in for a
-- minute, and `kill` / `stop` sign out at once. Nothing a client does is
-- visible to other clients by itself, so this needs that small server.
------------------------------------------------------------------------

Presence = { online = {}, running = true, status = "off" }

do
    local CFG = SETTINGS.Presence

    function Presence.isActive(uid)
        uid = tonumber(uid)
        if uid == plr.UserId then return Presence.running end
        return Presence.online[uid] == true
    end

    local function endpoint()
        local url = tostring(CFG.url or ""):gsub("%s", ""):gsub("/+$", "")
        if not url:match("^https://") then return nil end
        return url .. "/beat"
    end

    -- active = false signs out. Returns the list of other online UserIds, or nil and a reason.
    local function beat(active)
        local url = endpoint()
        if not url then return nil, "no presence server set" end
        local res, err = TagSync.request({
            Url = url, Method = "POST", Headers = { ["Content-Type"] = "application/json" },
            Body = HttpService:JSONEncode({
                jobId = game.JobId ~= "" and game.JobId or ("studio-" .. tostring(game.PlaceId)),
                userId = plr.UserId, active = active,
            }),
        })
        if not res then return nil, err end
        if tonumber(res.StatusCode) ~= 200 then return nil, "server said " .. tostring(res.StatusCode) end
        local ok, data = pcall(function() return HttpService:JSONDecode(res.Body) end)
        if not ok or type(data) ~= "table" or type(data.online) ~= "table" then return nil, "unexpected reply" end
        return data.online
    end

    local function update(list)
        local now = {}
        for i = 1, math.min(#list, 200) do
            local id = tonumber(list[i])
            if id and id > 0 and id ~= plr.UserId then now[id] = true end
        end
        local old = Presence.online
        Presence.online = now
        local changed = {}
        for id in pairs(old) do if not now[id] then changed[id] = true end end
        for id in pairs(now) do if not old[id] then changed[id] = true end end
        for id in pairs(changed) do
            if not Tags.byUser[tostring(id)] then Tags.refresh(id) end -- custom tags never depend on presence
        end
        if next(changed) and UIAPI.syncFns.taglist then pcall(UIAPI.syncFns.taglist) end
    end

    function Presence.start()
        if not endpoint() then Presence.status = "off (SETTINGS.Presence.url is empty)"; return end
        task.spawn(function()
            while genv.PuppyAdminActive == true and Presence.running do
                local list, err = beat(true)
                if list then
                    update(list)
                    local n = 0
                    for _ in pairs(Presence.online) do n = n + 1 end
                    Presence.status = "online - " .. n .. " other script user" .. (n == 1 and "" or "s") .. " here"
                else
                    Presence.status = "check-in failed: " .. tostring(err)
                end
                task.wait(CFG.beatSeconds)
            end
        end)
    end

    -- kill / stop: hide your default tag for everyone right away (custom tags stay)
    table.insert(cleanups, function()
        Presence.running = false
        Presence.online = {}
        if endpoint() then pcall(beat, false) end
    end)
end

Presence.start()

------------------------------------------------------------------------
-- Shared auras: auras.json in the repository holds who wears which aura,
--   [ { "userId": "123", "aura": "lightning", "color": [r, g, b] }, ... ]
-- ("color" optional). Every copy of the script reads it at start and every
-- pollSeconds and draws those auras; only accounts that may edit tags change
-- it (aura / unaura), and only a device with the GitHub token writes it.
------------------------------------------------------------------------

AuraSync = { etag = nil, lastJson = nil, queued = false, status = "starting", shared = {} }

do
    local CFG = SETTINGS.Auras

    -- shared: { ["<UserId>"] = { [auraName] = {r,g,b} or false } }
    local function encode(shared)
        local list = {}
        for uid, set in pairs(shared) do
            for name, color in pairs(set) do
                list[#list + 1] = { userId = uid, aura = name, color = color or nil }
            end
        end
        table.sort(list, function(a, b) return a.userId .. a.aura < b.userId .. b.aura end)
        return HttpService:JSONEncode(list)
    end

    local function sanitize(list)
        if type(list) ~= "table" then return nil end
        local out = {}
        for i = 1, math.min(#list, 2000) do
            local e = list[i]
            local uid = type(e) == "table" and tostring(e.userId or "") or ""
            local name = type(e) == "table" and type(e.aura) == "string" and e.aura:lower():sub(1, 40) or nil
            if uid:match("^%d+$") and #uid <= 20 and name and name:match("^[%w_]+$") then
                local color = false
                if type(e.color) == "table" and tonumber(e.color[1]) and tonumber(e.color[2]) and tonumber(e.color[3]) then
                    color = { math.clamp(tonumber(e.color[1]), 0, 255), math.clamp(tonumber(e.color[2]), 0, 255), math.clamp(tonumber(e.color[3]), 0, 255) }
                end
                out[uid] = out[uid] or {}
                out[uid][name] = color
            end
        end
        return out
    end

    local function colorOf(def, c)
        if c then return Color3.fromRGB(c[1], c[2], c[3]) end
        if def and def.ownColors then return nil end
        return Aura.defaultColor
    end

    -- Makes Aura.state match the shared list (also for players not here yet:
    -- the character watcher builds from Aura.state when they spawn).
    function AuraSync.reconcile(new)
        local old = AuraSync.shared
        AuraSync.shared = new
        for uid, set in pairs(old) do
            for name in pairs(set) do
                if not (new[uid] and new[uid][name] ~= nil) then
                    local id = tonumber(uid)
                    local st = Aura.state[id]
                    local p = Players:GetPlayerByUserId(id)
                    if p then Aura.remove(p, name) elseif st then st[name] = nil end
                end
            end
        end
        for uid, set in pairs(new) do
            for name, c in pairs(set) do
                local def = Aura.defs[name]
                if def then
                    local was = old[uid] and old[uid][name]
                    local same = old[uid] and old[uid][name] ~= nil and HttpService:JSONEncode({ was }) == HttpService:JSONEncode({ c })
                    if not same then
                        local id = tonumber(uid)
                        local p = Players:GetPlayerByUserId(id)
                        if p then
                            Aura.apply(p, name, colorOf(def, c))
                        else
                            Aura.state[id] = Aura.state[id] or {}
                            Aura.state[id][name] = { color = colorOf(def, c) }
                        end
                    end
                end
            end
        end
    end

    function AuraSync.pull(fresh)
        local ok, text = TagSync.readPath(CFG.path, AuraSync, fresh)
        if not ok then AuraSync.status = "read failed: " .. tostring(text); return false, AuraSync.status end
        if text == "unchanged" then return true, AuraSync.status end
        if not text then AuraSync.status = "no auras file yet"; return true, AuraSync.status end
        local okJ, decoded = pcall(function() return HttpService:JSONDecode(text) end)
        local new = okJ and sanitize(decoded)
        if not new then AuraSync.status = "auras file is not valid"; return false, AuraSync.status end
        local js = encode(new)
        -- changes made here without a token stay until the script restarts
        if js ~= AuraSync.lastJson and not AuraSync.localOnly then
            AuraSync.lastJson = js
            AuraSync.reconcile(new)
        end
        local n = 0
        for _, set in pairs(new) do for _ in pairs(set) do n = n + 1 end end
        AuraSync.status = "up to date (" .. n .. " auras)"
        return true, AuraSync.status
    end

    local function schedulePush()
        if not TagSync.token() then
            AuraSync.localOnly = true
            note("Aura", "Applied on this device only - add the GitHub token in Settings to share auras", GREY)
            return
        end
        if AuraSync.queued then return end
        AuraSync.queued = true
        task.delay(SETTINGS.TagSync.pushDelay, function()
            AuraSync.queued = false
            if genv.PuppyAdminActive ~= true then return end
            local body = encode(AuraSync.shared)
            local ok, msg = TagSync.writePath(CFG.path, body, "Update auras from PuppyAdmin", AuraSync)
            if ok then AuraSync.lastJson = body end
            note("Aura sync", ok and "Shared with everyone using the script" or msg, ok and LIGHT or RED)
        end)
    end

    -- uids: UserIds; color: {r,g,b} or nil. Returns how many changed.
    function AuraSync.give(uids, name, color)
        local new = HttpService:JSONDecode(HttpService:JSONEncode(AuraSync.shared))
        for _, id in ipairs(uids) do
            local k = tostring(id)
            new[k] = new[k] or {}
            new[k][name] = color or false
        end
        AuraSync.reconcile(new)
        schedulePush()
        return #uids
    end

    -- name nil: every aura. Returns how many were removed.
    function AuraSync.take(uids, name)
        local new = HttpService:JSONDecode(HttpService:JSONEncode(AuraSync.shared))
        local n = 0
        for _, id in ipairs(uids) do
            local set = new[tostring(id)]
            if set then
                for k in pairs(set) do
                    if not name or k == name then set[k] = nil; n = n + 1 end
                end
                if next(set) == nil then new[tostring(id)] = nil end
            end
        end
        AuraSync.reconcile(new)
        if n > 0 then schedulePush() end
        return n
    end

    task.spawn(function()
        local fetchStart = os.clock()
        pcall(AuraSync.pull, true)
        Perf.since("First auras read (background)", fetchStart)
    end)
end



------------------------------------------------------------------------
-- Anti-kick: blocks Kick calls made on you from scripts running on your client.
-- It cannot stop a kick the server performs. The hooks stay installed after the
-- first use and simply pass everything through while the switch is off.
------------------------------------------------------------------------

local AntiKick = { on = false, installed = false, blocked = 0, allowUntil = 0 }

function AntiKick.install()
    if AntiKick.installed then return true end
    local any = false
    if hookmetamethod and getnamecallmethod then
        local old
        local ok = pcall(function()
            local fn = function(self, ...)
                if AntiKick.on and os.clock() > AntiKick.allowUntil and self == plr and tostring(getnamecallmethod()):lower() == "kick" then
                    AntiKick.blocked = AntiKick.blocked + 1
                    return
                end
                return old(self, ...)
            end
            old = hookmetamethod(game, "__namecall", newcclosure and newcclosure(fn) or fn)
        end)
        any = any or ok
    end
    if hookfunction then
        local oldKick
        local ok = pcall(function()
            local fn = function(self, ...)
                if AntiKick.on and os.clock() > AntiKick.allowUntil and self == plr then
                    AntiKick.blocked = AntiKick.blocked + 1
                    return
                end
                return oldKick(self, ...)
            end
            oldKick = hookfunction(plr.Kick, newcclosure and newcclosure(fn) or fn)
        end)
        any = any or ok
    end
    AntiKick.installed = any
    return any
end

table.insert(cleanups, function() AntiKick.on = false end)

------------------------------------------------------------------------
-- Moderation (owners only): a script blacklist and kicks, kept in
-- moderation.json next to tags.json:
--   [ { "type": "ban",  "userId": "123", "name": "user", "reason": "..." },
--     { "type": "kick", "userId": "123", "reason": "...", "id": "...", "at": 1700000000, "jobId": "..." } ]
-- Every copy of the script checks it at start and every pollSeconds: a banned
-- player is kicked whenever they run the script, in any server. A kick only
-- applies in the server it was sent from (jobId) and for ten minutes: the
-- player can join any other server. Owners (TAG_EDITORS) are never affected.
-- Like everything client-side, someone who edits the script can remove it.
------------------------------------------------------------------------

Moderation = { etag = nil, entries = {}, handled = {}, startedAt = os.time(), status = "starting", queued = false }

do
    local PATH = "moderation.json"
    local KICK_WINDOW = 600

    local function isOwnerId(uid)
        uid = tonumber(uid)
        if uid == plr.UserId then return canEditTags() end
        local p = Players:GetPlayerByUserId(uid or 0)
        if not p then return false end
        local n = p.Name:lower()
        for _, name in ipairs(TAG_EDITORS) do if n == name then return true end end
        return false
    end
    Moderation.isOwnerId = isOwnerId

    local function sanitize(list)
        if type(list) ~= "table" then return nil end
        local out = {}
        for i = 1, math.min(#list, 5000) do
            local e = list[i]
            local uid = type(e) == "table" and tostring(e.userId or "") or ""
            if uid:match("^%d+$") and #uid <= 20 and (e.type == "ban" or e.type == "kick") then
                out[#out + 1] = {
                    type = e.type, userId = uid,
                    reason = type(e.reason) == "string" and e.reason:sub(1, 120) or "",
                    id = type(e.id) == "string" and e.id:sub(1, 40) or nil,
                    at = tonumber(e.at),
                    name = type(e.name) == "string" and e.name:sub(1, 40) or nil,
                    jobId = type(e.jobId) == "string" and e.jobId:sub(1, 64) or nil,
                }
            end
        end
        return out
    end

    local function kickSelf(message)
        if genv.PuppyAdminActive ~= true then return end
        AntiKick.allowUntil = os.clock() + 10
        pcall(function() plr:Kick(message) end)
    end

    -- Acts on the entries that concern this player.
    local function enforce()
        if canEditTags() then return end
        local me = tostring(plr.UserId)
        for _, e in ipairs(Moderation.entries) do
            if e.userId == me then
                if e.type == "ban" then
                    kickSelf("You are banned from using Puppy Admin." .. (e.reason ~= "" and ("\nReason: " .. e.reason) or ""))
                    return
                elseif e.type == "kick" and e.id and not Moderation.handled[e.id] then
                    Moderation.handled[e.id] = true
                    -- only in the server the kick was sent from (older kicks without a server are ignored)
                    if e.at and os.time() - e.at <= KICK_WINDOW and e.jobId and e.jobId ~= "" and e.jobId == game.JobId then
                        kickSelf("You were kicked by a Puppy Admin owner." .. (e.reason ~= "" and ("\nReason: " .. e.reason) or ""))
                        return
                    end
                end
            end
        end
    end

    function Moderation.pull(fresh)
        local ok, text = TagSync.readPath(PATH, Moderation, fresh)
        if not ok then Moderation.status = "read failed: " .. tostring(text); return false end
        if text == "unchanged" then enforce(); return true end
        if not text then Moderation.entries = {}; Moderation.status = "no moderation file yet"; return true end
        local okJ, decoded = pcall(function() return HttpService:JSONDecode(text) end)
        local list = okJ and sanitize(decoded)
        if not list then Moderation.status = "moderation file is not valid"; return false end
        Moderation.entries = list
        local bans = 0
        for _, e in ipairs(list) do if e.type == "ban" then bans = bans + 1 end end
        Moderation.status = "up to date (" .. bans .. " banned)"
        enforce()
        if UIAPI.syncFns and UIAPI.syncFns.owner then pcall(UIAPI.syncFns.owner) end
        if UIAPI.syncFns and UIAPI.syncFns.blacklist then pcall(UIAPI.syncFns.blacklist) end
        return true
    end

    -- Owner side: change the list and commit it (needs the GitHub token).
    -- Old kicks are dropped on every write. Yields. Returns ok, message.
    local function write(mutate)
        if not canEditTags() then return false, "Owners only" end
        if not TagSync.token() then return false, "Needs the GitHub token (Settings > Tag sync)" end
        Moderation.pull(true)
        local list = {}
        for _, e in ipairs(Moderation.entries) do
            if e.type == "ban" or (e.at and os.time() - e.at <= KICK_WINDOW) then list[#list + 1] = e end
        end
        local msg = mutate(list)
        local ok, err = TagSync.writePath(PATH, HttpService:JSONEncode(list), "Update moderation from PuppyAdmin", Moderation)
        if not ok then return false, err end
        Moderation.entries = list
        if UIAPI.syncFns and UIAPI.syncFns.owner then pcall(UIAPI.syncFns.owner) end
        if UIAPI.syncFns and UIAPI.syncFns.blacklist then pcall(UIAPI.syncFns.blacklist) end
        return true, msg
    end

    function Moderation.isBanned(uid)
        for _, e in ipairs(Moderation.entries) do
            if e.type == "ban" and e.userId == tostring(uid) then return true, e.reason end
        end
        return false
    end

    -- Username for a UserId: from the server, the moderation file, or Roblox (yields; cached).
    Moderation.names = {}
    function Moderation.nameOf(uid, noYield)
        local key = tostring(uid)
        if Moderation.names[key] then return Moderation.names[key] end
        local p = Players:GetPlayerByUserId(tonumber(key) or 0)
        if p then Moderation.names[key] = p.Name; return p.Name end
        for _, e in ipairs(Moderation.entries) do
            if e.userId == key and e.name then Moderation.names[key] = e.name; return e.name end
        end
        if noYield then return nil end
        local ok, name = pcall(function() return Players:GetNameFromUserIdAsync(tonumber(key)) end)
        if ok and type(name) == "string" then Moderation.names[key] = name; return name end
        return nil
    end

    function Moderation.bans()
        local out = {}
        for _, e in ipairs(Moderation.entries) do if e.type == "ban" then out[#out + 1] = e end end
        return out
    end

    function Moderation.ban(uids, reason)
        local names = {}
        for _, uid in ipairs(uids) do names[tostring(uid)] = Moderation.nameOf(uid) end
        return write(function(list)
            local n = 0
            for _, uid in ipairs(uids) do
                local key = tostring(uid)
                if not isOwnerId(uid) and not Moderation.isBanned(key) then
                    local present = false
                    for _, e in ipairs(list) do if e.type == "ban" and e.userId == key then present = true end end
                    if not present then list[#list + 1] = { type = "ban", userId = key, name = names[key], reason = reason or "" }; n = n + 1 end
                end
            end
            return "Banned " .. n
        end)
    end

    function Moderation.unban(uids)
        return write(function(list)
            local n = 0
            for _, uid in ipairs(uids) do
                for i = #list, 1, -1 do
                    if list[i].type == "ban" and list[i].userId == tostring(uid) then table.remove(list, i); n = n + 1 end
                end
            end
            return "Unbanned " .. n
        end)
    end

    function Moderation.kick(uids, reason)
        return write(function(list)
            local n = 0
            for _, uid in ipairs(uids) do
                if not isOwnerId(uid) then
                    list[#list + 1] = {
                        type = "kick", userId = tostring(uid), reason = reason or "",
                        id = tostring(uid) .. "-" .. tostring(os.time()) .. "-" .. tostring(math.random(1000, 9999)), at = os.time(),
                        jobId = game.JobId,
                    }
                    n = n + 1
                end
            end
            return "Kick sent to " .. n .. " (this server only, within about " .. SETTINGS.TagSync.pollSeconds .. " s, if they run the script)"
        end)
    end

    task.spawn(function()
        local fetchStart = os.clock()
        pcall(Moderation.pull, true)
        Perf.since("First moderation read (background)", fetchStart)
    end)
end

------------------------------------------------------------------------
-- RepoSync: one check of the repository every pollSeconds for all shared
-- files. It lists the repository root (one request; 304 when nothing
-- changed) and pulls only the files whose sha moved. When the listing
-- cannot be used (no request(), rate limit) every file is read the old way,
-- which falls back to the raw files.
------------------------------------------------------------------------

local RepoSync = { etag = nil, shas = {}, status = "starting" }
do
    local FILES = {
        { path = SETTINGS.TagSync.path, pull = function() return TagSync.pull() end, ready = function() return TagSync.canPull() end },
        { path = SETTINGS.Auras.path, pull = function() return AuraSync.pull() end, ready = function() return not AuraSync.queued end },
        { path = "moderation.json", pull = function() return Moderation.pull() end, ready = function() return true end },
    }

    function RepoSync.tick()
        local ok, shas = TagSync.listRoot(RepoSync)
        if ok and shas == "unchanged" then RepoSync.status = "unchanged"; return end
        if not ok then
            RepoSync.status = "per-file (" .. tostring(shas) .. ")"
            for _, f in ipairs(FILES) do
                if f.ready() then pcall(f.pull) end
            end
            return
        end
        local pulled = 0
        for _, f in ipairs(FILES) do
            local sha = shas[f.path] or false
            if sha ~= RepoSync.shas[f.path] then
                -- a file that is not ready keeps its old sha, so the next tick tries again
                if f.ready() then
                    local okP, res = pcall(f.pull)
                    if okP and res ~= false then RepoSync.shas[f.path] = sha end
                    pulled = pulled + 1
                else
                    RepoSync.etag = nil
                end
            end
        end
        RepoSync.status = pulled > 0 and ("pulled " .. pulled) or "listing changed, files unchanged"
    end

    task.spawn(function()
        -- the first listing only records the shas: the startup reads already ran
        local ok, shas = TagSync.listRoot(RepoSync)
        if ok and type(shas) == "table" then
            for _, f in ipairs(FILES) do RepoSync.shas[f.path] = shas[f.path] or false end
        end
        while genv.PuppyAdminActive == true do
            task.wait(SETTINGS.TagSync.pollSeconds)
            if genv.PuppyAdminActive ~= true then break end
            local okT, err = pcall(RepoSync.tick)
            if not okT then RepoSync.status = "error: " .. tostring(err) end
        end
    end)
end


------------------------------------------------------------------------
-- Built-in engine: reanimation and movement
--
-- Pup.load runs the embedded engine bundle: the reanimation API (clone, real
-- body following it, keyframe playback, tricks, pair, mimic, blend), the
-- Reanimate panel (library, states, record, copy, live, tricks, keys,
-- transitions), the movement engines and commands (fly, superfly + Fly panel,
-- hatfly, helicopter, noclip, airwalk, swim, teleports, waypoints, follow /
-- orbit / spectate, the movement library) and the UI kit those use. The block
-- is generated, not hand-written; changes in it are marked (the panel module
-- publishes its state as _G._pup_reanimState, and its text says Puppy Admin).
--
-- Conventions it keeps: _G._reanimAPI / _G._reanimPanel globals, files under
-- the executor workspace's PuppyAdmin/ folder, and the icon pack from
-- molto.pages.dev (downloaded and run with loadstring by the engine). There
-- is no built-in animation library: only animations you import exist
-- (PuppyAdmin/custom). Another script that uses the same _G names in the same
-- session would collide with it.
------------------------------------------------------------------------

local DIGIT_NAMES = {
    ["0"] = "zero", ["1"] = "one", ["2"] = "two", ["3"] = "three", ["4"] = "four",
    ["5"] = "five", ["6"] = "six", ["7"] = "seven", ["8"] = "eight", ["9"] = "nine",
}

local function resolveKeyCode(name)
    if not name then return nil end
    local l = name:lower()
    l = DIGIT_NAMES[l] or l
    for _, kc in ipairs(Enum.KeyCode:GetEnumItems()) do
        if kc.Name:lower() == l then return kc end
    end
    return nil
end

local Pup = { booted = false, failed = nil, gui = nil, cmds = nil, pupL = nil, panelFailed = nil }

local function pupApi()
    local api = _G._reanimLoaded and _G._reanimAPI
    return type(api) == "table" and api or nil
end

local function pupModel(getter)
    local api = pupApi()
    local fn = api and api[getter]
    if type(fn) ~= "function" then return nil end
    local ok, model = pcall(fn, plr)
    if ok and typeof(model) == "Instance" then return model end
    return nil
end

-- Teleport, ESP, the floor and the respawn guard read Reanim.active / .clone /
-- .real; they are answered by the reanimation API at the moment they are read.
local Reanim = setmetatable({}, { __index = function(_, key)
    if key == "clone" then return pupModel("get_clone") end
    if key == "real" then return pupModel("get_real_character") end
    if key == "active" then return pupModel("get_clone") ~= nil end
    return nil
end })

function Reanim.isClone(model)
    return model ~= nil and pupModel("get_clone") == model
end

-- The engine is a separate file in the repository (engine/engine-<version>.lua,
-- generated by the build). It is read from PuppyAdmin/engine when cached,
-- otherwise downloaded once; the version in the name means a new engine is
-- never served from a stale cache. Size and header are checked before it runs.
do
local ENGINE_VERSION = "edc7c2355f"
local ENGINE_BYTES = 731108
local ENGINE_DIR = "PuppyAdmin/engine"
local ENGINE_NAME = "engine-" .. ENGINE_VERSION .. ".lua"
local ENGINE_URL = SETTINGS.Auras.assetBase .. "engine/" .. ENGINE_NAME

local function engineValid(src)
    return type(src) == "string" and #src == ENGINE_BYTES
        and src:sub(1, #("-- PuppyAdmin engine " .. ENGINE_VERSION)) == "-- PuppyAdmin engine " .. ENGINE_VERSION
end

local function engineCached()
    if not (isfile and readfile) then return nil end
    local path = ENGINE_DIR .. "/" .. ENGINE_NAME
    local ok, src = pcall(function() return isfile(path) and readfile(path) or nil end)
    return ok and engineValid(src) and src or nil
end

-- Downloads and caches the engine source. Yields. Returns src or nil, error.
function Pup.fetchEngine()
    if Pup.fetching then
        while Pup.fetching do task.wait(0.1) end
        return engineCached() or Pup.fetchedSrc, Pup.fetchError
    end
    Pup.fetching = true
    local start = os.clock()
    local ok, src = pcall(function() return game:HttpGet(ENGINE_URL) end)
    local result, err
    if ok and engineValid(src) then
        result = src
        Pup.fetchedSrc = src -- kept for executors without writefile
        pcall(function()
            if makefolder and isfolder and not isfolder("PuppyAdmin") then makefolder("PuppyAdmin") end
            if makefolder and isfolder and not isfolder(ENGINE_DIR) then makefolder(ENGINE_DIR) end
            if writefile then writefile(ENGINE_DIR .. "/" .. ENGINE_NAME, src) end
            -- older engine versions are no longer used
            if listfiles and delfile then
                for _, f in ipairs(listfiles(ENGINE_DIR)) do
                    local name = tostring(f):match("([^/\\]+)$")
                    if name and name:match("^engine%-.+%.lua$") and name ~= ENGINE_NAME then pcall(delfile, f) end
                end
            end
        end)
        Perf.since("Engine download", start)
    else
        err = ok and ("engine download was incomplete (" .. (type(src) == "string" and #src or 0) .. " of " .. ENGINE_BYTES .. " bytes)")
            or ("engine download failed: " .. tostring(src))
    end
    Pup.fetchError = err
    Pup.fetching = false
    return result, err
end

function Pup.load(host)
    if not Pup.chunk then
        local src = engineCached() or Pup.fetchedSrc
        if not src then
            if not coroutine.isyieldable() then
                -- called where waiting is not allowed: download in the background
                task.spawn(Pup.fetchEngine)
                Pup.transient = true
                error("engine is downloading - try again in a few seconds", 0)
            end
            local err
            src, err = Pup.fetchEngine()
            if not src then Pup.transient = true; error(err, 0) end
        end
        local compileStart = os.clock()
        local fn, cerr = (loadstring or load)(src, "=PuppyAdminEngine")
        if not fn then error("engine did not compile: " .. tostring(cerr), 0) end
        Pup.chunk = fn()
        Pup.fetchedSrc = nil
        Perf.since("Engine compile", compileStart)
    end
    return Pup.chunk(host)
end

Pup.engineCached = engineCached
end

-- One-time copy of what older versions saved under the engine's previous
-- folder name (custom animations, recordings, favourites, keybinds,
-- waypoints) into PuppyAdmin/. Files already in PuppyAdmin/ are kept.
local LEGACY_DATA_DIR = "Novoline" -- folder name only, kept so old data is found
local function migrateLegacyData()
    if not (isfolder and isfile and listfiles and readfile and writefile and makefolder) then return end
    if not pcall(isfolder, LEGACY_DATA_DIR) or not isfolder(LEGACY_DATA_DIR) then return end
    -- runs every start: files added to the old folder later are copied too
    local copied = 0
    local function copyTree(from, to, depth)
        if depth > 6 then return end
        pcall(function() if not isfolder(to) then makefolder(to) end end)
        local ok, items = pcall(listfiles, from)
        if not ok or type(items) ~= "table" then return end
        for _, path in ipairs(items) do
            local name = tostring(path):gsub("\\", "/"):match("([^/]+)$")
            if name then
                local src, dst = from .. "/" .. name, to .. "/" .. name
                if isfolder(src) then
                    copyTree(src, dst, depth + 1)
                elseif not isfile(dst) then
                    local okRead, data = pcall(readfile, src)
                    if okRead and type(data) == "string" and pcall(writefile, dst, data) then copied = copied + 1 end
                end
            end
        end
    end
    copyTree(LEGACY_DATA_DIR, "PuppyAdmin", 0)
    if copied > 0 then note("Puppy Admin", "Moved " .. copied .. " saved files (animations, recordings, binds) into PuppyAdmin/", LIGHT) end
end

-- Runs the embedded engine once (engines, UI kit, command registry).
function Pup.boot()
    if Pup.booted then return true end
    if Pup.failed then
        note("Puppy Admin", "Unavailable: " .. Pup.failed:sub(1, 60), RED)
        return false
    end
    pcall(migrateLegacyData)
    local loadStart = os.clock()
    local ok, res = pcall(Pup.load, {
        notify = function(title, text) note(tostring(title or "Puppy Admin"), tostring(text or "")) end,
        parentGui = parentGui,
    })
    if not ok and Pup.transient then
        -- download problems are retried on the next use
        Pup.transient = false
        note("Puppy Admin", tostring(res):sub(1, 90), RED)
        return false
    end
    if not ok or type(res) ~= "table" or type(res.init) ~= "function" or type(res.cmds) ~= "table" then
        Pup.failed = ok and "engine returned nothing" or tostring(res)
        note("Puppy Admin", "Engine failed: " .. Pup.failed:sub(1, 60), RED)
        return false
    end
    Perf.since("Engine start (first reanim / movement command)", loadStart)
    Pup.booted, Pup.gui, Pup.cmds, Pup.pupL, Pup.init = true, res.gui, res.cmds, res.pupL, res.init
    if UIAPI.hookSuperfly then pcall(UIAPI.hookSuperfly) end
    if Pup.gui then
        Pup.gui.Enabled = not Hide.uiHidden
        -- the engine's palette is the default theme's, so theme presets and
        -- colour roles recolour its windows like every other window. Only the
        -- windows you can see (Fly panel, lists); the hidden reanimation panel
        -- that hosts the logic is skipped - recolouring it was most of the
        -- first-open hitch.
        local function themeWindow(child)
            task.defer(function()
                if not child.Parent or child.Name == "ReanimPanel" then return end
                pcall(Theme.attach, child)
                if child:FindFirstChild("UtilitySurface") then pcall(Pup.stylePanel, child) end
            end)
        end
        for _, c in ipairs(Pup.gui:GetChildren()) do themeWindow(c) end
        table.insert(conns, Pup.gui.ChildAdded:Connect(themeWindow))
    end
    return true
end

-- Window look shared with the rest of the script: 12 px corners, flat theme
-- background (no gradient), theme stroke, 14 px bold title, and the theme's
-- background image. Re-applied each time the panel opens, because the
-- engine's tone pass repaints its surfaces on open.
function Pup.stylePanel(panel)
    if typeof(panel) ~= "Instance" then return end
    local function apply()
        local corner = panel:FindFirstChildOfClass("UICorner")
        if corner then corner.CornerRadius = UDim.new(0, 12) end
        local surface = panel:FindFirstChild("UtilitySurface")
        if surface then
            local grad = surface:FindFirstChildOfClass("UIGradient")
            if grad then grad.Enabled = false end
            local round = surface:FindFirstChildOfClass("UICorner")
            if round then round.CornerRadius = UDim.new(0, 12) end
            surface.BackgroundColor3 = Theme.current.bg
            if not Theme.backdrops[surface] then
                surface.BackgroundTransparency = 0.05
                Theme.addBackdrop(surface, 12)
            end
        end
        for _, holder in ipairs({ panel, surface }) do
            local edge = holder and holder:FindFirstChildOfClass("UIStroke")
            if edge then edge.Color, edge.Thickness, edge.Transparency = Theme.current.border, 1, 0 end
        end
        local bar = panel:FindFirstChild("TitleBar")
        local title = bar and bar:FindFirstChild("Title")
        if title and title:IsA("TextLabel") then title.Font, title.TextSize = Enum.Font.GothamBold, 14 end
    end
    pcall(apply)
    panel:GetPropertyChangedSignal("Visible"):Connect(function()
        if panel.Visible then task.defer(function() pcall(apply) end) end
    end)
    table.insert(Theme.listeners, function() pcall(apply) end)
end

-- Builds the Reanimate panel on first use.
function Pup.ensure()
    if typeof(_G._reanimPanel) == "Instance" then return true end
    if not Pup.boot() then return false end
    if Pup.panelFailed then
        note("Reanim", "Panel failed: " .. Pup.panelFailed:sub(1, 120), RED)
        return false
    end
    -- the panel builder catches its own errors and only warn()s them; keep the
    -- first such line so the failure note says what actually broke
    local captured
    local logConn
    pcall(function()
        logConn = game:GetService("LogService").MessageOut:Connect(function(msg, kind)
            if not captured and kind == Enum.MessageType.MessageWarning and tostring(msg):find("Puppy Admin", 1, true) then
                captured = tostring(msg)
            end
        end)
    end)
    local initStart = os.clock()
    local okInit, err = pcall(Pup.init)
    Perf.since("Reanimation logic start (first reanim)", initStart)
    task.wait() -- MessageOut can arrive a frame late
    if logConn then logConn:Disconnect() end
    task.delay(2, function() pcall(Pup.purgeBuiltins) end)
    pcall(Pup.hookRecordings)
    task.delay(8, function() pcall(Pup.purgeBuiltins) end)
    if captured then warn("[PuppyAdmin] reanimation panel: " .. captured) end
    if not okInit or typeof(_G._reanimPanel) ~= "Instance" then
        Pup.panelFailed = okInit and (captured or "panel was not created") or tostring(err)
        note("Reanim", "Panel failed: " .. Pup.panelFailed:sub(1, 120), RED)
        return false
    end
    return true
end

-- The engine reports why reanimation did not start (no ragdoll remote, no
-- Humanoid, already reanimated...) as a returned string or an error, and the
-- panel's power button ignores both; show them.
local function watchReanimate(api)
    if type(api) ~= "table" or api._puppyWatched or type(api.reanimate) ~= "function" then return end
    local original = api.reanimate
    api.reanimate = function(...)
        local ok, res = pcall(original, ...)
        if not ok then
            note("Reanim", "Failed: " .. tostring(res):sub(1, 90), RED)
            error(res, 0)
        end
        if type(res) == "string" then note("Reanim", res:sub(1, 90), RED) end
        return res
    end
    api._puppyWatched = true
end

local function pupLoadApi()
    if not _G._reanimLoaded and type(_G.loadReanimAPI) == "function" then
        pcall(_G.loadReanimAPI, nil)
    end
    local api = pupApi()
    watchReanimate(api)
    return api
end

-- Import from the Roblox catalog --------------------------------------------
-- Takes an animation or emote asset ID (catalog items give an Animation whose
-- AnimationId is followed), loads its KeyframeSequence, converts the poses to
-- the engine's keyframe table and saves it in PuppyAdmin/custom, where the
-- Library's "Your animations" list (and keybinds/states) can use it.
-- Poses are interpolated linearly (Roblox easing styles are not reproduced).
local function findKeyframeSequence(id)
    local function search(objs)
        local animId
        for _, o in ipairs(objs or {}) do
            if o:IsA("KeyframeSequence") then return o end
            local ks = o:FindFirstChildWhichIsA("KeyframeSequence", true)
            if ks then return ks end
            local anim = o:IsA("Animation") and o or o:FindFirstChildWhichIsA("Animation", true)
            if anim and not animId then animId = tostring(anim.AnimationId):match("%d+") end
        end
        return nil, animId
    end
    local ok, objs = pcall(function() return game:GetObjects("rbxassetid://" .. id) end)
    local seq, animId = search(ok and objs or nil)
    if seq then return seq end
    if animId and animId ~= id then
        local ok2, objs2 = pcall(function() return game:GetObjects("rbxassetid://" .. animId) end)
        seq = search(ok2 and objs2 or nil)
        if seq then return seq end
    end
    local okK, ks = pcall(function()
        return game:GetService("KeyframeSequenceProvider"):GetKeyframeSequenceAsync("rbxassetid://" .. (animId or id))
    end)
    if okK and typeof(ks) == "Instance" and ks:IsA("KeyframeSequence") then return ks end
    return nil
end

-- KeyframeSequence -> { { Time, Data = { [Part1 name] = pose CFrame } } }, every
-- frame holding every part (a part missing from a keyframe keeps its last pose).
local function sequenceFrames(seq)
    local kfs = seq:GetKeyframes()
    table.sort(kfs, function(a, b) return a.Time < b.Time end)
    local frames, last = {}, {}
    local function collect(pose, out)
        for _, sub in ipairs(pose:GetSubPoses()) do
            if sub:IsA("Pose") then
                if sub.Weight > 0 then out[sub.Name] = sub.CFrame end
                collect(sub, out)
            end
        end
    end
    for _, kf in ipairs(kfs) do
        local data = {}
        for k, v in pairs(last) do data[k] = v end
        for _, top in ipairs(kf:GetPoses()) do
            if top:IsA("Pose") then
                if top.Weight > 0 then data[top.Name] = top.CFrame end
                collect(top, data)
            end
        end
        last = data
        table.insert(frames, { Time = kf.Time, Data = data })
    end
    if #frames == 1 then table.insert(frames, { Time = 1, Data = frames[1].Data }) end
    return frames
end

local function encodeFrames(name, frames)
    local out = { "local C=CFrame.new return{[" .. string.format("%q", name) .. "]={\n" }
    for _, f in ipairs(frames) do
        local parts = {}
        for part, cf in pairs(f.Data) do
            local c = { cf:GetComponents() }
            for i = 1, 12 do c[i] = string.format("%.5f", c[i]) end
            parts[#parts + 1] = "[" .. string.format("%q", part) .. "]=C(" .. table.concat(c, ",") .. ")"
        end
        table.sort(parts)
        out[#out + 1] = "{Time=" .. string.format("%.4f", f.Time) .. ",Data={" .. table.concat(parts, ",") .. "}},\n"
    end
    out[#out + 1] = "}}"
    return table.concat(out)
end

-- A keyframe file link (a Lua table like the ones the recorder saves).
-- Yields. Returns ok, display name or reason, file path.
local function importLink(url)
    local rs = _G._pup_reanimState
    local ok, src = pcall(function() return game:HttpGet(url) end)
    if not ok or type(src) ~= "string" or #src < 10 then return false, "Could not download that link" end
    local data
    if type(rs) == "table" and type(rs.loadAnim) == "function" then
        local okL, d = pcall(rs.loadAnim, src)
        data = okL and d or nil
    end
    if type(data) ~= "table" then return false, "That link is not a keyframe animation" end
    local key = next(data)
    local list = key and data[key]
    if type(list) ~= "table" or #list < 2 then return false, "That animation has no keyframes" end
    local base = tostring(type(key) == "string" and key or url:match("([^/]+)$") or "Animation")
    base = base:gsub("%.%w+$", ""):gsub("[^%w%s%-_%.%(%)]", ""):gsub("%s+", " "):sub(1, 40)
    if base == "" then base = "Animation" end
    pcall(function()
        if not isfolder("PuppyAdmin") then makefolder("PuppyAdmin") end
        if not isfolder("PuppyAdmin/custom") then makefolder("PuppyAdmin/custom") end
    end)
    local path = "PuppyAdmin/custom/" .. base .. ".lua"
    if not pcall(writefile, path, src) then return false, "Could not write " .. path end
    if type(rs) == "table" and type(rs.reanimAddItem) == "function" and type(rs.customItems) == "table" then
        local have = false
        for _, it in ipairs(rs.customItems) do if it.url == path then have = true end end
        if not have then pcall(rs.reanimAddItem, base, path, rs.customItems, "Imported") end
        if rs.localAnimCache then rs.localAnimCache[path] = nil end
    end
    return true, base, path
end

-- Your animations from files ---------------------------------------------------
-- The engine reads PuppyAdmin/custom once at start, only its top level (plus
-- Recorded) and only lower-case .lua/.txt/.json. This re-runs that scan and
-- then adds anything it missed: files in any subfolder, any letter case.
Pup.legacyCopy = migrateLegacyData

-- Every path under PuppyAdmin/custom, sorted: equal means nothing changed.
local function customFolderSignature()
    if not (listfiles and isfolder) then return nil end
    local parts = {}
    local function walk(dir, depth)
        if depth > 4 then return end
        local ok, items = pcall(listfiles, dir)
        if not ok or type(items) ~= "table" then return end
        for _, p in ipairs(items) do
            p = tostring(p):gsub("\\", "/")
            parts[#parts + 1] = p
            local okF, isDir = pcall(isfolder, p)
            if okF and isDir then walk(p, depth + 1) end
        end
    end
    walk("PuppyAdmin/custom", 0)
    table.sort(parts)
    return table.concat(parts, "|")
end

-- force: always rebuild (Reload files). Otherwise only when the folder changed.
function Pup.reloadCustom(force)
    pcall(migrateLegacyData)
    local rsNow = _G._pup_reanimState
    local sig = customFolderSignature()
    if not force and sig and sig == Pup.customSig and type(rsNow) == "table" and type(rsNow.customItems) == "table" then
        return #rsNow.customItems, 0
    end
    Pup.customSig = sig
    local scanStart = os.clock()
    local pupL = Pup.pupL
    if type(pupL) == "table" and type(pupL.reloadCustom) == "function" then pcall(pupL.reloadCustom) end
    local rs = _G._pup_reanimState
    if type(rs) ~= "table" or type(rs.customItems) ~= "table" or type(rs.reanimAddItem) ~= "function" then return 0 end
    if not (listfiles and isfolder) then return #rs.customItems end
    local have = {}
    for _, it in ipairs(rs.customItems) do
        if type(it.url) == "string" then have[it.url:gsub("\\", "/"):lower()] = true end
    end
    local added = 0
    local function scan(dir, depth, category)
        if depth > 4 then return end
        local ok, items = pcall(listfiles, dir)
        if not ok or type(items) ~= "table" then return end
        for _, path in ipairs(items) do
            path = tostring(path)
            local norm = path:gsub("\\", "/")
            local leaf = norm:match("([^/]+)$") or norm
            local okF, isDir = pcall(isfolder, norm)
            if okF and isDir then
                scan(norm, depth + 1, category or leaf)
            else
                local ext = (leaf:match("%.(%w+)$") or ""):lower()
                if (ext == "lua" or ext == "txt" or ext == "json") and not have[norm:lower()] then
                    have[norm:lower()] = true
                    pcall(rs.reanimAddItem, (leaf:gsub("%.[^%.]+$", "")), norm, rs.customItems, category)
                    added = added + 1
                end
            end
        end
    end
    scan("PuppyAdmin/custom", 0, nil)
    Perf.since("Animation folder read (" .. #rs.customItems .. " files)", scanStart)
    return #rs.customItems, added
end

-- Recordings: the engine keeps a finished "Record motion" take only in its
-- three-slot recent list (PuppyAdmin/recorded, oldest deleted). Every take is
-- now also copied into Your animations (PuppyAdmin/custom/Recorded) and added
-- to the list right away.
local function addToYourAnimations(name, path, category)
    local rs = _G._pup_reanimState
    if type(rs) ~= "table" or type(rs.reanimAddItem) ~= "function" or type(rs.customItems) ~= "table" then return end
    for _, it in ipairs(rs.customItems) do if it.url == path then return end end
    pcall(rs.reanimAddItem, name, path, rs.customItems, category)
    if rs.localAnimCache then rs.localAnimCache[path] = nil end
end

function Pup.hookRecordings()
    local rs = _G._pup_reanimState
    if type(rs) ~= "table" or rs._puppyRecHook or type(rs.addRecordingToCustom) ~= "function" then return end
    rs._puppyRecHook, rs._puppyAdded = true, {}
    local original = rs.refreshRecordedList
    rs.refreshRecordedList = function(...)
        if type(original) == "function" then pcall(original, ...) end
        local rec = type(rs.recentRecordings) == "table" and rs.recentRecordings[1]
        if type(rec) ~= "table" or type(rec.path) ~= "string" or rs._puppyAdded[rec.path] then return end
        rs._puppyAdded[rec.path] = true -- before adding: adding refreshes the list again
        pcall(rs.addRecordingToCustom, rec)
        local dest = tostring(rs.REANIM_RECORDED_CUSTOM_DIR or "PuppyAdmin/custom/Recorded") .. "/" .. tostring(rec.name)
            .. (rec.path:match("%.%w+$") or ".json")
        if isfile and pcall(isfile, dest) and isfile(dest) then addToYourAnimations(rec.name, dest, "Recorded") end
    end
    -- takes from before this session: mark them so only new ones are copied
    for _, rec in ipairs(type(rs.recentRecordings) == "table" and rs.recentRecordings or {}) do
        if type(rec) == "table" and type(rec.path) == "string" then rs._puppyAdded[rec.path] = true end
    end
end

-- Copy another player's animation into Your animations (the original panel's
-- keyframe recorder). One recording at a time, up to a minute.
Pup.copyRec = nil
function Pup.startCopy(target)
    local K = _G._pup_keyframeRecorder
    if type(K) ~= "table" or type(K.start) ~= "function" then return false, "Recorder not ready - open the panel again in a moment" end
    if Pup.copyRec and Pup.copyRec.active then return false, "Already recording " .. Pup.copyRec.player.DisplayName end
    local s, err = K.start(target)
    if not s then return false, tostring(err or "Could not start") end
    Pup.copyRec = s
    s.onStop = function(sess)
        local okB, kfs = pcall(sess.build)
        if not okB or type(kfs) ~= "table" or #kfs < 2 then note("Reanim", "Recording of " .. sess.player.DisplayName .. " was too short", RED); return end
        local name = (sess.player.Name .. " " .. os.date("%H-%M-%S")):gsub("[^%w %-_]", "")
        local rec, why = K.save(name, kfs, { rig = sess.rig })
        if not rec or type(rec.path) ~= "string" then note("Reanim", "Could not save: " .. tostring(why), RED); return end
        local okR, src = pcall(readfile, rec.path)
        if not okR or type(src) ~= "string" then note("Reanim", "Saved to " .. rec.path .. " but could not read it back", RED); return end
        pcall(function()
            if not isfolder("PuppyAdmin/custom") then makefolder("PuppyAdmin/custom") end
            if not isfolder("PuppyAdmin/custom/Copied") then makefolder("PuppyAdmin/custom/Copied") end
        end)
        local dest = "PuppyAdmin/custom/Copied/" .. tostring(rec.name or name) .. ".lua"
        if not pcall(writefile, dest, src) then note("Reanim", "Could not write " .. dest, RED); return end
        addToYourAnimations(tostring(rec.name or name), dest, "Copied")
        note("Reanim", "Saved " .. tostring(rec.name or name) .. " - in Library > Your animations", LIGHT)
    end
    return true
end

function Pup.stopCopy()
    local s = Pup.copyRec
    if not (s and s.active) then return false end
    s.stop()
    return true
end
table.insert(cleanups, function()
    local s = Pup.copyRec
    if s and s.active then s.onStop = nil; pcall(s.stop) end
end)

-- There is no built-in library any more: favourites, idle/walk/jump picks and
-- keys that still point at old library links (http) are cleared. Imported
-- animations are local files and are never touched.
function Pup.purgeBuiltins()
    local rs, L = _G._pup_reanimState, _G._pup_reanimLayout
    if type(rs) ~= "table" then return end
    local function remote(url) return type(url) == "string" and url:match("^https?://") ~= nil end
    local changed = 0
    for i = #(rs.favsItems or {}), 1, -1 do
        local it = rs.favsItems[i]
        if type(it) == "table" and remote(it.url) then
            if type(L) == "table" and type(L.toggleFav) == "function" then
                pcall(L.toggleFav, it)
            else
                pcall(function() it.row:Destroy() end)
                table.remove(rs.favsItems, i)
            end
            changed = changed + 1
        end
    end
    if changed > 0 and type(rs.saveFavsItems) == "function" then pcall(rs.saveFavsItems) end
    local states = 0
    for slot, a in pairs(type(rs.stateAnims) == "table" and rs.stateAnims or {}) do
        if type(a) == "table" and remote(a.url) then rs.stateAnims[slot] = nil; states = states + 1 end
    end
    if states > 0 then
        if type(rs.saveStateAnims) == "function" then pcall(rs.saveStateAnims) end
        if type(rs.startStateLoop) == "function" then pcall(rs.startStateLoop) end
    end
    local keys = 0
    for k, bind in pairs(type(rs.favKeybinds) == "table" and rs.favKeybinds or {}) do
        if type(bind) == "table" and remote(bind.url) then rs.favKeybinds[k] = nil; keys = keys + 1 end
    end
    if keys > 0 and type(rs.saveReanimKeybinds) == "function" then pcall(rs.saveReanimKeybinds) end
    if changed + states + keys > 0 then
        note("Reanim", "Removed old built-in animations (" .. changed .. " favourites, " .. states .. " states, " .. keys .. " keys)", GREY)
    end
end

-- Pasted keyframes (Lua table source or the recorder's JSON), the way the
-- original panel's paste box saved them. Returns ok, display name or reason, path.
function Pup.importText(raw, wantedName)
    raw = tostring(raw or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if raw == "" then return false, "Paste keyframe data first" end
    if not (writefile and readfile) then return false, "Needs writefile/readfile" end
    local rs = _G._pup_reanimState
    local ext = "lua"
    local okJson, decoded = pcall(function() return HttpService:JSONDecode(raw) end)
    if okJson and type(decoded) == "table" then
        ext = "json"
    else
        if type(rs) ~= "table" or type(rs.loadAnim) ~= "function" then return false, "Reanimation is still starting - try again in a moment" end
        local okL, data, text = pcall(rs.loadAnim, raw)
        if not okL or type(data) ~= "table" then
            return false, "Not keyframes: " .. tostring(okL and text or data):sub(1, 60)
                .. " (" .. #raw .. " characters - if it was cut off, use a link or a file)"
        end
        raw = type(text) == "string" and text or raw
    end
    local name = tostring(wantedName or ""):gsub("[^%w %-_%.%(%)]", ""):gsub("^%s+", ""):gsub("%s+$", "")
    if name == "" then name = tostring(raw:match('%[%s*["\']([^"\']+)["\']%s*%]') or "pasted"):gsub("[^%w %-_%.%(%)]", ""):sub(1, 40) end
    if name == "" then name = "pasted" end
    pcall(function()
        if not isfolder("PuppyAdmin") then makefolder("PuppyAdmin") end
        if not isfolder("PuppyAdmin/custom") then makefolder("PuppyAdmin/custom") end
    end)
    local base, n = name, 2
    while isfile and isfile("PuppyAdmin/custom/" .. name .. "." .. ext) and n <= 50 do name = base .. " " .. n; n = n + 1 end
    local path = "PuppyAdmin/custom/" .. name .. "." .. ext
    local okW, err = pcall(writefile, path, raw)
    if not okW then return false, "Save failed: " .. tostring(err) end
    addToYourAnimations(name, path, nil)
    return true, name, path
end

-- Yields. Returns ok, display name or reason, file path.
function Pup.importCatalog(raw)
    raw = tostring(raw or ""):match("^%s*(.-)%s*$")
    if raw:match("^https?://") then return importLink(raw) end
    -- pasted keyframes rather than an ID
    if #raw > 40 and (raw:find("{", 1, true) or raw:find("Time", 1, true)) then return Pup.importText(raw) end
    local id = raw:match("%d+")
    if not id then return false, "Give an animation or emote ID, or a keyframe file link" end
    if not (writefile and readfile) then return false, "Needs writefile/readfile" end
    local seq = findKeyframeSequence(id)
    if not seq then return false, "Could not load an animation from " .. id .. " (bundles and private animations do not work)" end
    local frames = sequenceFrames(seq)
    local okFrames = #frames >= 2 and frames[#frames].Time > 0
    pcall(function() seq:Destroy() end)
    if not okFrames then return false, "That animation has no usable keyframes" end
    local title = seq.Name
    pcall(function()
        local info = game:GetService("MarketplaceService"):GetProductInfo(tonumber(id))
        if type(info) == "table" and type(info.Name) == "string" and info.Name ~= "" then title = info.Name end
    end)
    title = tostring(title or "Animation"):gsub("[^%w%s%-_%.]", ""):gsub("%s+", " "):sub(1, 40)
    if title == "" or title == "KeyframeSequence" then title = "Animation" end
    local display = title .. " (" .. id .. ")"
    pcall(function()
        if not isfolder("PuppyAdmin") then makefolder("PuppyAdmin") end
        if not isfolder("PuppyAdmin/custom") then makefolder("PuppyAdmin/custom") end
    end)
    local path = "PuppyAdmin/custom/" .. display .. ".lua"
    local okWrite = pcall(writefile, path, encodeFrames(display, frames))
    if not okWrite then return false, "Could not write " .. path end
    local rs = _G._pup_reanimState
    if type(rs) == "table" and type(rs.reanimAddItem) == "function" and type(rs.customItems) == "table" then
        local have = false
        for _, it in ipairs(rs.customItems) do if it.url == path then have = true end end
        if not have then pcall(rs.reanimAddItem, display, path, rs.customItems, "Imported") end
        if rs.localAnimCache then rs.localAnimCache[path] = nil end
    end
    return true, display, path
end

-- open: true / false, or nil to toggle. Shows the script's Reanimation window;
-- the engine's own panel is built (it hosts the logic) but kept hidden.
function Pup.setOpen(open)
    local panel = UIAPI.panels.reanim
    if not panel then return end
    if open == nil then open = not panel.Visible end
    panel.Visible = open
    if UIAPI.sync then UIAPI.sync() end
end

-- Goes through the panel's power button logic (3 s cooldown, R6 warning,
-- trick preferences, status line), so the panel and the command agree.
function Pup.panelState()
    if not Pup.ensure() then return nil end
    pupLoadApi()
    local rs = _G._pup_reanimState
    if type(rs) ~= "table" or type(rs.toggleReanim) ~= "function" then
        note("Reanim", "Panel is not ready yet", RED)
        return nil
    end
    return rs
end

function Pup.setActive(on)
    local rs = Pup.panelState()
    if not rs then return end
    if on == nil then on = not rs.reanimActive end
    if (rs.reanimActive == true) ~= on then rs.toggleReanim() end
    -- Noclip while reanimated defaults OFF: turn it off once the reanim is live (you can
    -- still switch it back on in the Reanim panel). The engine ships it on, so force it here.
    if on then
        task.spawn(function()
            for _ = 1, 20 do
                local r = Pup.panelState()
                if r and r.reanimActive and type(r.setNoclip) == "function" then
                    pcall(r.setNoclip, false)
                    return
                end
                task.wait(0.1)
            end
        end)
    end
end

-- Reset button: while reanimated, reset ends reanimation first and then kills
-- your real body normally (the clone cannot die, so Roblox's own reset left
-- you stuck). Roblox's reset comes back on kill / stop.
do
    local StarterGui = game:GetService("StarterGui")
    local resetEvent = Instance.new("BindableEvent")
    local function endReanimation()
        if not Reanim.active then return end
        local rs = _G._pup_reanimState
        if type(rs) == "table" and rs.reanimActive and type(rs.toggleReanim) == "function" then
            rs.reanimLastUsed = 0
            pcall(rs.toggleReanim)
        else
            local api = pupApi()
            if api then pcall(api.reanimate, false) end
        end
        local t0 = os.clock()
        while Reanim.active and os.clock() - t0 < 4 do task.wait(0.1) end
        task.wait(0.2)
    end
    Pup.endReanimation = endReanimation
    table.insert(conns, resetEvent.Event:Connect(function()
        task.spawn(function()
            endReanimation()
            local hum = plr.Character and plr.Character:FindFirstChildOfClass("Humanoid")
            if hum then
                pcall(function() hum:SetStateEnabled(Enum.HumanoidStateType.Dead, true) end)
                hum.Health = 0
            end
        end)
    end))
    task.spawn(function()
        for _ = 1, 20 do
            if genv.PuppyAdminActive ~= true then return end
            if pcall(function() StarterGui:SetCore("ResetButtonCallback", resetEvent) end) then return end
            task.wait(0.5)
        end
    end)
    table.insert(cleanups, function()
        pcall(function() StarterGui:SetCore("ResetButtonCallback", true) end)
        pcall(function() resetEvent:Destroy() end)
    end)
end

do
    local setUI = Hide.setUI
    function Hide.setUI(hidden)
        setUI(hidden)
        if Pup.gui then Pup.gui.Enabled = not hidden end
    end
end

table.insert(cleanups, function()
    local rs = _G._pup_reanimState
    if type(rs) == "table" and rs.reanimActive and type(rs.toggleReanim) == "function" then
        rs.reanimLastUsed = 0
        pcall(rs.toggleReanim)
    elseif Reanim.active then
        local api = pupApi()
        if api then pcall(api.reanimate, false) end
    end
    for _, key in ipairs({ "_reanimPanel", "_reanimSpeedPanel" }) do
        local p = _G[key]
        if typeof(p) == "Instance" then pcall(function() p:Destroy() end) end
        _G[key] = nil
    end
    if Pup.gui then pcall(function() Pup.gui:Destroy() end) end
    -- a later run of the script must register a fresh API, not find this one
    _G._reanimAPI, _G._reanimLoaded, _G._pup_reanimState = nil, nil, nil
end)


-- Generated from the engine's registry: every command in its "movement" group,
-- plus the fly / noclip / swim / hatfly / helicopter family. Each runs the
-- engine's own handler (Pup.run); this table only feeds help, aliases and autocomplete.
-- Generated from the engine's registry: its graphics / FPS commands. Each runs
-- the engine's own handler (Pup.run); this table feeds help and the Performance panel.
local PUP_PERF = {
    { name = "antilag", args = "", desc = "Lower graphics for more FPS, undo with unantilag", aliases = { "boostfps", "lowgraphics" } },
    { name = "fps", args = "", desc = "Show current framerate", aliases = {} },
    { name = "fullbright", args = "", desc = "Maximize all light ranges", aliases = {} },
    { name = "globalshadows", args = "", desc = "Enable global shadows", aliases = { "gs" } },
    { name = "lights", args = "", desc = "Restore removed lights", aliases = {} },
    { name = "loopnoeffect", args = "", desc = "Keep post-processing effects disabled", aliases = {} },
    { name = "loopnofog", args = "", desc = "Keep fog removed", aliases = {} },
    { name = "noeffect", args = "", desc = "Disable all post-processing effects", aliases = { "nfx" } },
    { name = "nofog", args = "", desc = "Remove all fog from the game", aliases = { "nf" } },
    { name = "nofullbright", args = "", desc = "Restore original lighting", aliases = {} },
    { name = "nolights", args = "", desc = "Remove all in-world lights", aliases = {} },
    { name = "norender", args = "", desc = "Turn 3D rendering off to save FPS", aliases = {} },
    { name = "plastic", args = "", desc = "Set all parts to Plastic (FPS boost)", aliases = { "plas" } },
    { name = "removeterrain", args = "", desc = "Clear the terrain on your screen", aliases = { "noterrain" } },
    { name = "render", args = "", desc = "Turn 3D rendering back on", aliases = {} },
    { name = "texturebp", args = "", desc = "Restore textures removed by untexturebp", aliases = {} },
    { name = "unantilag", args = "", desc = "Restore graphics after antilag", aliases = { "uantilag" } },
    { name = "unglobalshadows", args = "", desc = "Disable global shadows", aliases = { "ugs" } },
    { name = "unloopnoeffect", args = "", desc = "Stop loop disabling effects", aliases = {} },
    { name = "unloopnofog", args = "", desc = "Restore fog", aliases = {} },
    { name = "unplastic", args = "", desc = "Restore original materials", aliases = { "uplas" } },
    { name = "untexturebp", args = "", desc = "Remove all textures/decals from workspace parts", aliases = {} },
}

local PUP_MOVE = {
    { name = "airwalk", args = "", desc = "Walk on air (Space to go up)", aliases = { "aw" } },
    { name = "autoflashback", args = "", desc = "Go back to where you died every time you respawn", aliases = { "autofb" } },
    { name = "balloonfloat", args = "", desc = "Float up slowly holding a balloon", aliases = { "balloon" } },
    { name = "cframefly", args = "<speed>", desc = "Fly by moving your position directly, gets past some anticheats", aliases = { "cfly" } },
    { name = "clearwaypoints", args = "", desc = "Delete all saved waypoints", aliases = { "cwp" } },
    { name = "clicktp", args = "", desc = "Click anywhere to teleport there", aliases = { "ctp", "clickteleport" } },
    { name = "climb", args = "", desc = "Climb any wall you walk into", aliases = { "wallclimb" } },
    { name = "clip", args = "", desc = "Disable noclip", aliases = {} },
    { name = "dash", args = "<power>", desc = "Press X to dash forward", aliases = { "dashkey" } },
    { name = "deletewaypoint", args = "<n>", desc = "Delete a named waypoint", aliases = { "dwp" } },
    { name = "edgejump", args = "", desc = "Jump by itself when you walk off an edge", aliases = { "ej" } },
    { name = "farthest", args = "", desc = "Teleport to the farthest player", aliases = { "furthest" } },
    { name = "flashback", args = "", desc = "Teleport to where you last died", aliases = { "lastdeath" } },
    { name = "float", args = "", desc = "Spawn a platform beneath you (Q=down, E=up)", aliases = { "plat", "platform" } },
    { name = "fly", args = "<s>", desc = "Start flying; optional speed", aliases = { "f" } },
    { name = "flyjump", args = "", desc = "Hold jump to keep rising", aliases = { "fj" } },
    { name = "flyspeed", args = "<s>", desc = "Set fly speed (default 1)", aliases = { "fs", "flysp" } },
    { name = "ftp", args = "", desc = "Teleport to mouse (F key)", aliases = { "mousetp" } },
    { name = "glide", args = "", desc = "Hold jump in the air to glide down slowly", aliases = { "glider" } },
    { name = "goto", args = "<p>", desc = "Teleport to player", aliases = { "tp", "to" } },
    { name = "gotofolder", args = "<name> <secs>", desc = "Visit every part in a folder or model, one after another", aliases = { "tourfolder" } },
    { name = "gotomodel", args = "<name>", desc = "Teleport to a model by name", aliases = { "tomodel" } },
    { name = "gotopart", args = "<name>", desc = "Teleport to a part by name", aliases = { "topart" } },
    { name = "gotopartnext", args = "<name>", desc = "Teleport to the next part with a name, one each time you run it", aliases = { "nextpart" } },
    { name = "gotowaypoint", args = "<n>", desc = "Teleport to a saved waypoint", aliases = { "gwp", "wp" } },
    { name = "groundpound", args = "", desc = "Slam down hard from the air", aliases = { "slam" } },
    { name = "hatfly", args = "", desc = "Fly your hat while body is parked under map", aliases = { "hf" } },
    { name = "helicopter", args = "", desc = "Fly while spinning like a helicopter", aliases = { "heli" } },
    { name = "join", args = "<s>", desc = "Join server by Job ID", aliases = {} },
    { name = "jumpboost", args = "<n>", desc = "Add extra height to every jump", aliases = { "jb" } },
    { name = "loopgoto", args = "<p>", desc = "Keep teleporting behind a player", aliases = { "lgoto", "looptp" } },
    { name = "lunge", args = "<power>", desc = "Burst forward", aliases = {} },
    { name = "moonwalk", args = "", desc = "Walk backwards while facing forward", aliases = { "mj" } },
    { name = "nearest", args = "", desc = "Teleport to the closest player", aliases = { "closest" } },
    { name = "noclip", args = "", desc = "Walk through walls", aliases = { "nc" } },
    { name = "nojumpcooldown", args = "", desc = "Remove jump cooldown in games", aliases = { "njc" } },
    { name = "offset", args = "<x> <y> <z>", desc = "Move yourself by x y z studs", aliases = {} },
    { name = "orbit", args = "<p>", desc = "Orbit around player", aliases = { "orb" } },
    { name = "pathfind", args = "<x,y,z | CFrame.new(...)>", desc = "Pathfind to xyz or CFrame", aliases = { "pf", "pathto" } },
    { name = "pulsetp", args = "<p> <secs>", desc = "Teleport to a player for a moment, then come back", aliases = { "ptp" } },
    { name = "rejoin", args = "", desc = "Rejoin this server", aliases = { "rj" } },
    { name = "rocketjump", args = "<power>", desc = "Blast up and forward", aliases = {} },
    { name = "serverhop", args = "", desc = "Hop to a random server", aliases = { "shop", "sh" } },
    { name = "setwaypoint", args = "<n>", desc = "Save current position as a named waypoint", aliases = { "swp", "savepos" } },
    { name = "spectate", args = "<p>", desc = "Spectate player camera", aliases = { "spec", "view" } },
    { name = "sprint", args = "<times>", desc = "Hold Shift to run faster", aliases = {} },
    { name = "superfly", args = "<s>", desc = "Open Superfly panel (mouse/touch flight)", aliases = { "sfly", "sflymode" } },
    { name = "swim", args = "", desc = "Float in zero-gravity swim", aliases = { "sw" } },
    { name = "thru", args = "<n>", desc = "Teleport forward through a wall", aliases = { "through" } },
    { name = "togglefly", args = "", desc = "Toggle fly on/off", aliases = { "tf" } },
    { name = "togglenoclip", args = "", desc = "Toggle noclip on/off", aliases = { "tnc" } },
    { name = "torandom", args = "", desc = "Teleport to a random player", aliases = { "tprandom" } },
    { name = "tpdown", args = "<n>", desc = "Teleport straight down", aliases = {} },
    { name = "tppos", args = "<x> <y> <z>", desc = "Teleport to x y z coordinates", aliases = { "tpcoords" } },
    { name = "tptool", args = "", desc = "Equip click-to-teleport tool", aliases = { "tpt" } },
    { name = "tpup", args = "<n>", desc = "Teleport straight up", aliases = {} },
    { name = "tweengoto", args = "<p>", desc = "Glide to a player", aliases = { "tweento", "tgoto" } },
    { name = "tweenpos", args = "<x> <y> <z> <speed>", desc = "Glide smoothly to x y z coordinates", aliases = {} },
    { name = "tweenspeed", args = "<n>", desc = "Set tweengoto speed in studs per second", aliases = {} },
    { name = "unairwalk", args = "", desc = "Disable airwalk", aliases = { "uaw" } },
    { name = "unautoflashback", args = "", desc = "Turn off auto flashback", aliases = {} },
    { name = "unballoonfloat", args = "", desc = "Turn off balloon", aliases = {} },
    { name = "uncframefly", args = "", desc = "Turn off cframe fly", aliases = {} },
    { name = "unclicktp", args = "", desc = "Stop click teleport", aliases = { "unctp" } },
    { name = "unclimb", args = "", desc = "Turn off climb", aliases = {} },
    { name = "undash", args = "", desc = "Turn off dash", aliases = {} },
    { name = "unedgejump", args = "", desc = "Turn off edge jump", aliases = {} },
    { name = "unfloat", args = "", desc = "Remove the float platform", aliases = { "uplat", "nofloat" } },
    { name = "unfly", args = "", desc = "Stop flying", aliases = { "uf", "nofly" } },
    { name = "unflyjump", args = "", desc = "Turn off fly jump", aliases = {} },
    { name = "unfollow", args = "", desc = "Stop following player", aliases = {} },
    { name = "unftp", args = "", desc = "Disable FTP", aliases = {} },
    { name = "unglide", args = "", desc = "Turn off glide", aliases = {} },
    { name = "ungotofolder", args = "", desc = "Turn off folder tour", aliases = {} },
    { name = "unhatfly", args = "", desc = "Stop hatfly and restore your character", aliases = { "uhf", "nohatfly" } },
    { name = "unhelicopter", args = "", desc = "Stop helicopter fly + anim", aliases = { "unheli", "noheli" } },
    { name = "unjumpboost", args = "", desc = "Turn off jump boost", aliases = {} },
    { name = "unloopgoto", args = "", desc = "Turn off loop goto", aliases = {} },
    { name = "unmoonwalk", args = "", desc = "Turn off moonwalk", aliases = {} },
    { name = "unnoclip", args = "", desc = "Restore collision", aliases = { "unc", "clip" } },
    { name = "unnojumpcooldown", args = "", desc = "Disable nojumpcooldown", aliases = {} },
    { name = "unorbit", args = "", desc = "Stop orbiting", aliases = { "uorb" } },
    { name = "unpathfind", args = "", desc = "Stop current pathfinding route", aliases = { "upf", "stoppf" } },
    { name = "unspectate", args = "", desc = "Stop spectating", aliases = { "uspec", "unview" } },
    { name = "unsprint", args = "", desc = "Turn off sprint", aliases = {} },
    { name = "unsuperfly", args = "", desc = "Disable superfly mode", aliases = { "usfly", "nosuperfly" } },
    { name = "unswim", args = "", desc = "Stop swimming", aliases = { "usw", "noswim" } },
    { name = "untptool", args = "", desc = "Remove the teleport tool", aliases = { "utpt" } },
    { name = "unvehiclespeed", args = "", desc = "Turn off vehicle speed", aliases = {} },
    { name = "unvfly", args = "", desc = "Turn off vehicle fly", aliases = {} },
    { name = "unwalkonwalls", args = "", desc = "Turn off walk on walls", aliases = {} },
    { name = "unwalkto", args = "", desc = "Stop walking to player", aliases = { "uwt" } },
    { name = "unwallrun", args = "", desc = "Turn off wall run", aliases = {} },
    { name = "unwiggle", args = "", desc = "Turn off wiggle", aliases = {} },
    { name = "vehiclespeed", args = "<n>", desc = "Raise the top speed of the car you drive", aliases = { "vspeed", "carspeed" } },
    { name = "velocity", args = "<x> <y> <z>", desc = "Push yourself with a velocity of x y z", aliases = { "vel" } },
    { name = "vfly", args = "<speed>", desc = "Fly the vehicle you are sitting in", aliases = { "vehiclefly", "carfly" } },
    { name = "walkonwalls", args = "", desc = "Walk on walls and ceilings. Walk into a wall to climb it, right drag to look, scroll to zoom", aliases = { "wallwalk" } },
    { name = "walkto", args = "<p>", desc = "Walk toward player", aliases = { "wt" } },
    { name = "wallrun", args = "", desc = "Run along walls for a moment when you jump next to them", aliases = { "wr" } },
    { name = "waypoints", args = "", desc = "List all saved waypoints", aliases = {} },
    { name = "waypointtool", args = "", desc = "Equip a tool ,  click anywhere to place a waypoint there", aliases = {} },
    { name = "wiggle", args = "", desc = "Wiggle side to side", aliases = { "shimmy" } },
}

------------------------------------------------------------------------
-- Movement: the engine's movement commands, run through its own registry
--
-- The handlers are the engine's code (embedded above in Pup.load): fly and
-- its speed/keys, superfly and its panel, hatfly, helicopter, noclip holds,
-- airwalk, swim, every teleport / waypoint / follow command, and the
-- movement library (cframefly, vfly, dash, glide, wallrun, ...). They are
-- called the way the engine's command bar calls them: exec({ name, args... }).
------------------------------------------------------------------------

Pup.active = {}   -- commands with an "un..." counterpart that are on right now

function Pup.find(name)
    if not Pup.boot() then return nil end
    for _, c in ipairs(Pup.cmds) do
        if c.name == name then return c end
    end
    return nil
end

-- a: PuppyAdmin args (without the command name). Runs on its own thread
-- because the handlers wait (fly restarts, tweens, teleports).
function Pup.run(name, a)
    local c = Pup.find(name)
    if not c or type(c.exec) ~= "function" then
        note("Movement", "Not available: " .. tostring(name), RED)
        return
    end
    local packed = { name }
    for _, v in ipairs(a or {}) do table.insert(packed, v) end
    if name:sub(1, 2) == "un" then
        Pup.active[name:sub(3)] = nil
    elseif Pup.find("un" .. name) then
        Pup.active[name] = true
    end
    task.spawn(function()
        local ok, err = pcall(c.exec, packed)
        if not ok then note("Movement", name .. ": " .. tostring(err):sub(1, 70), RED) end
        if UIAPI.sync then UIAPI.sync() end
    end)
end

-- State the Movement panel shows. Fly, superfly, noclip, swim and the fly
-- speed are the engine's own fields; helicopter, hatfly and airwalk keep their
-- state in module locals, so those follow the commands sent from here.
Pup.state = {}
function Pup.state.flying() return type(_G._pupMove) == "table" and _G._pupMove.FLYING == true end
function Pup.state.superfly() return type(_G._pupSuperfly) == "table" and _G._pupSuperfly.enabled == true end
function Pup.state.noclip() return type(_G._pupMove) == "table" and type(_G._pupMove.noclipHold) == "table" and _G._pupMove.noclipHold.user == true end
function Pup.state.swimming() return Pup.pupL ~= nil and Pup.pupL.swimming == true end
function Pup.state.flySpeed() return type(_G._pupMove) == "table" and tonumber(_G._pupMove.iyflyspeed) or 1 end
function Pup.state.setFlySpeed(v)
    if Pup.boot() and type(Pup.pupL.setFlySpeed) == "function" then pcall(Pup.pupL.setFlySpeed, v) end
end
function Pup.state.on(name)
    if name == "helicopter" and not Pup.state.flying() then Pup.active.helicopter = nil end
    return Pup.active[name] == true
end

table.insert(cleanups, function()
    if not Pup.booted then return end
    local off = {}
    for name in pairs(Pup.active) do off["un" .. name] = true end
    off.unfly, off.unnoclip, off.unswim, off.unsuperfly = true, true, true, true
    for name in pairs(off) do
        local c = Pup.find(name)
        if c and type(c.exec) == "function" then pcall(c.exec, { name }) end
    end
    Pup.active = {}
end)

------------------------------------------------------------------------
-- World and visuals: infinite baseplate, ESP (chams, hitboxes, tracers).
-- Movement is the built-in engine's code (see Pup / PUP_MOVE above).
------------------------------------------------------------------------

local Baseplate, BASEPLATE_PRESETS, bpApplyAll, Esp, isMobile
do
local function getRootPart(char)
    return char and (char:FindFirstChild("HumanoidRootPart") or char:FindFirstChild("Torso")
        or char:FindFirstChild("UpperTorso"))
end

isMobile = UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled

local function guiRoot()
    return notifGui.Parent or CoreGui
end

local function disconnect(c)
    if c then pcall(function() c:Disconnect() end) end
    return nil
end

------------------------------------------------------------------------
-- Infinite baseplate: 2000x2000 tiles spawned around you at floor height
------------------------------------------------------------------------

-- default look: leafy grass in a bright lawn green (picked by eye to match the
-- grass in Mic Up; change it with the colour box in the panel)
local GRASS_GREEN = Color3.fromRGB(83, 160, 61)
local LEAFY = (function() local ok, m = pcall(function() return Enum.Material.LeafyGrass end); return ok and m or Enum.Material.Grass end)()
Baseplate = {
    enabled = false, folder = nil, grid = {}, gen = 0, top = nil,
    kind = "material", material = LEAFY, color = GRASS_GREEN, textureId = "", studs = 8, presetIndex = 1,
}

BASEPLATE_PRESETS = {
    { name = "Grass (default)", material = LEAFY, color = GRASS_GREEN },
    { name = "Dark glass" },
    { name = "Studs", texture = "rbxasset://textures/studs.png" },
    { name = "Inlet", texture = "rbxasset://textures/inlet.png" },
    { name = "Universal", texture = "rbxasset://textures/universal.png" },
    { name = "Glue", texture = "rbxasset://textures/glue.png" },
    { name = "Weld", texture = "rbxasset://textures/weld.png" },
    { name = "Grid", texture = "rbxasset://textures/grid.png" },
}
for _, m in ipairs({
    "Grass", "LeafyGrass", "Ground", "Mud", "Sand", "Sandstone", "Brick", "Granite", "Marble", "Slate",
    "Cobblestone", "Rock", "Concrete", "Wood", "WoodPlanks", "Fabric", "Ice", "Glacier", "Snow", "Metal",
    "DiamondPlate", "CorrodedMetal", "Foil", "Pebble", "Asphalt", "Basalt", "CrackedLava", "Limestone",
    "Pavement", "Salt", "Plastic", "SmoothPlastic",
}) do
    local ok, mat = pcall(function() return Enum.Material[m] end)
    if ok and mat then table.insert(BASEPLATE_PRESETS, { name = m, material = mat }) end
end

local function bpApply(part)
    for _, ch in ipairs(part:GetChildren()) do
        if ch:IsA("Texture") or ch:IsA("Decal") then ch:Destroy() end
    end
    if Baseplate.kind == "material" then
        part.Material, part.Color, part.Transparency = Baseplate.material, Baseplate.color or Color3.new(1, 1, 1), 0
    elseif Baseplate.kind == "texture" and Baseplate.textureId ~= "" then
        part.Material, part.Color, part.Transparency = Enum.Material.SmoothPlastic, Color3.new(1, 1, 1), 0
        for _, face in ipairs({ Enum.NormalId.Top, Enum.NormalId.Bottom }) do
            make("Texture", {
                Name = "PuppyAdminFloorTexture", Texture = Baseplate.textureId, Face = face,
                StudsPerTileU = Baseplate.studs, StudsPerTileV = Baseplate.studs,
            }, part)
        end
    else
        part.Material, part.Color, part.Transparency = Enum.Material.SmoothPlastic, Color3.fromRGB(40, 40, 50), 0.5
    end
end

function bpApplyAll()
    for _, tile in pairs(Baseplate.grid) do
        if tile.Parent then pcall(bpApply, tile) end
    end
end

local function bpFloorY(root)
    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    pcall(function() params.RespectCanCollide = true end)
    local skip = { Baseplate.folder }
    for _, p in ipairs(Players:GetPlayers()) do
        if p.Character then table.insert(skip, p.Character) end
    end
    if Reanim.real then table.insert(skip, Reanim.real) end
    local origin, first = root.Position, nil
    for _ = 1, 6 do
        params.FilterDescendantsInstances = skip
        local hit = workspace:Raycast(origin, Vector3.new(0, -2000, 0), params)
        if not hit then break end
        first = first or hit.Position.Y
        local part = hit.Instance
        if part:IsA("Terrain") or (part.Size.X >= 40 and part.Size.Z >= 40) then return hit.Position.Y end
        table.insert(skip, part)
        origin = hit.Position
    end
    if first then return first end
    local hum = root.Parent and root.Parent:FindFirstChildOfClass("Humanoid")
    local hip = hum and hum.HipHeight > 0 and hum.HipHeight or 2
    return root.Position.Y - root.Size.Y / 2 - hip
end

local function bpSpawnTiles()
    local root = getRootPart(plr.Character)
    if not (Baseplate.folder and Baseplate.folder.Parent and root) then return end
    if not Baseplate.top then
        local ok, y = pcall(bpFloorY, root)
        Baseplate.top = (ok and type(y) == "number") and y - 0.05 or -1
    end
    local pos, sz = root.Position, 2000
    for x = -1, 1 do
        for z = -1, 1 do
            local gx = math.floor(pos.X / sz) * sz + x * sz
            local gz = math.floor(pos.Z / sz) * sz + z * sz
            local key = gx .. "," .. gz
            if not Baseplate.grid[key] then
                local tile = make("Part", {
                    Name = "PuppyAdminBaseplate", Size = Vector3.new(sz, 4, sz), Anchored = true, CanCollide = true,
                    Position = Vector3.new(gx, Baseplate.top - 2, gz),
                }, Baseplate.folder)
                Baseplate.grid[key] = tile
                pcall(bpApply, tile)
            end
        end
    end
end

function Baseplate.stop()
    Baseplate.gen = Baseplate.gen + 1
    Baseplate.enabled = false
    if Baseplate.folder then pcall(function() Baseplate.folder:Destroy() end) end
    Baseplate.folder, Baseplate.grid, Baseplate.top = nil, {}, nil
end

function Baseplate.start()
    if Baseplate.enabled then return end
    Baseplate.folder = make("Folder", { Name = "PuppyAdminBaseplates" }, workspace)
    Baseplate.grid = {}
    Baseplate.enabled = true
    Baseplate.gen = Baseplate.gen + 1
    local my = Baseplate.gen
    task.spawn(function()
        while my == Baseplate.gen and Baseplate.folder and Baseplate.folder.Parent do
            pcall(bpSpawnTiles)
            task.wait(2)
        end
    end)
end

function Baseplate.usePreset(i)
    local p = BASEPLATE_PRESETS[i]
    if not p then return end
    Baseplate.presetIndex = i
    if p.material then
        Baseplate.kind, Baseplate.material = "material", p.material
        Baseplate.color = p.color or Color3.new(1, 1, 1)
    elseif p.texture then
        Baseplate.kind, Baseplate.textureId, Baseplate.studs = "texture", p.texture, 8
    else
        Baseplate.kind = "default"
    end
    bpApplyAll()
    Baseplate.save()
end

-- remembered between sessions (Cfg.floor)
function Baseplate.save()
    local p = BASEPLATE_PRESETS[Baseplate.presetIndex]
    local c = Baseplate.color or Color3.new(1, 1, 1)
    Cfg.floor = { preset = p and p.name or nil, color = { math.floor(c.R * 255 + 0.5), math.floor(c.G * 255 + 0.5), math.floor(c.B * 255 + 0.5) } }
    cfgSave()
end
function Baseplate.setColor(c)
    Baseplate.color = c
    bpApplyAll()
    Baseplate.save()
end
function Baseplate.load()
    local saved = type(Cfg.floor) == "table" and Cfg.floor or {}
    for i, p in ipairs(BASEPLATE_PRESETS) do
        if p.name == saved.preset then
            Baseplate.presetIndex = i
            if p.material then Baseplate.kind, Baseplate.material = "material", p.material
            elseif p.texture then Baseplate.kind, Baseplate.textureId = "texture", p.texture
            else Baseplate.kind = "default" end
        end
    end
    local c = saved.color
    if type(c) == "table" and tonumber(c[1]) and tonumber(c[2]) and tonumber(c[3]) then
        Baseplate.color = Color3.fromRGB(c[1], c[2], c[3])
    end
end

-- Accepts rbxasset(s), rbxassetid://, a bare id, a roblox.com link, or an image URL.
function Baseplate.useCustom(raw)
    local tex, err = resolveImageSource(raw, "floor")
    if not tex then return false, err end
    Baseplate.kind, Baseplate.textureId = "texture", tex
    bpApplyAll()
    return true
end
Baseplate.load()

------------------------------------------------------------------------
-- ESP (highlight + name/health/distance pill, chams,
-- hitboxes, tracers, team colors, per-team hiding). Your screen only.
------------------------------------------------------------------------

Esp = { mode = "off", hitboxes = false, tracers = false, teamColor = false, hidden = {}, entries = {}, conns = {}, layer = nil }
local ESP_FONT = "rbxasset://fonts/families/Montserrat.json"
local ESP_DEFAULT = Color3.fromRGB(226, 226, 226)

local function espHidden(p)
    local t = p.Team
    return Esp.hidden[t and t.Name or "__none"] == true
end

local function espColor(p)
    if Esp.teamColor then
        local ok, col = pcall(function() return p.TeamColor.Color end)
        if ok and typeof(col) == "Color3" then return col end
    end
    return ESP_DEFAULT
end

local function espDrop(entry, key)
    if entry[key] then pcall(function() entry[key]:Destroy() end); entry[key] = nil end
end

local function espDestroy(p)
    local e = Esp.entries[p]
    if not e then return end
    for _, k in ipairs({ "hl", "bb", "box", "line" }) do espDrop(e, k) end
    Esp.entries[p] = nil
end

local function espLabel(e, p, adornee)
    if e.bb then e.bb.Adornee = adornee; return end
    local bb = make("BillboardGui", {
        Name = "PuppyAdminESP_" .. p.UserId, AlwaysOnTop = true, LightInfluence = 0,
        Size = UDim2.fromOffset(280, 50), StudsOffsetWorldSpace = Vector3.new(0, 4.2, 0), Adornee = adornee,
    }, guiRoot())
    local pill = make("Frame", {
        Name = "Pill", AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, 0, 1, -2),
        Size = UDim2.fromOffset(130, 44), BackgroundColor3 = Color3.new(1, 1, 1), BackgroundTransparency = 0.12, BorderSizePixel = 0,
    }, bb)
    make("UICorner", { CornerRadius = UDim.new(1, 0) }, pill)
    make("UIGradient", { Rotation = 90, Color = ColorSequence.new(Color3.fromRGB(8, 8, 9), Color3.fromRGB(26, 26, 28)) }, pill)
    e.rim = make("UIStroke", { Color = Color3.new(1, 1, 1), Thickness = 1, Transparency = 0.86 }, pill)
    e.scale = make("UIScale", {}, pill)
    e.avatar = make("ImageLabel", {
        Name = "Avatar", AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, 5, 0.5, 0), Size = UDim2.fromOffset(30, 30),
        BackgroundColor3 = Color3.fromRGB(40, 40, 44), BorderSizePixel = 0,
        Image = "rbxthumb://type=AvatarHeadShot&id=" .. p.UserId .. "&w=48&h=48",
    }, pill)
    make("UICorner", { CornerRadius = UDim.new(1, 0) }, e.avatar)
    e.ring = make("UIStroke", { Color = espColor(p), Thickness = 1.25 }, e.avatar)
    e.name = make("TextLabel", {
        BackgroundTransparency = 1, Position = UDim2.fromOffset(43, 5), Size = UDim2.new(1, -55, 0, 16),
        FontFace = Font.new(ESP_FONT, Enum.FontWeight.Bold), TextSize = 13, TextColor3 = Color3.fromRGB(242, 242, 244),
        TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd,
    }, pill)
    e.sub = make("TextLabel", {
        BackgroundTransparency = 1, Position = UDim2.fromOffset(43, 20), Size = UDim2.new(1, -55, 0, 13),
        FontFace = Font.new(ESP_FONT, Enum.FontWeight.Medium), TextSize = 11, TextColor3 = Color3.fromRGB(154, 154, 162),
        TextXAlignment = Enum.TextXAlignment.Left,
    }, pill)
    e.track = make("Frame", {
        Position = UDim2.fromOffset(43, 35), Size = UDim2.new(1, -57, 0, 2), BackgroundColor3 = Color3.new(1, 1, 1),
        BackgroundTransparency = 0.86, BorderSizePixel = 0,
    }, pill)
    make("UICorner", { CornerRadius = UDim.new(1, 0) }, e.track)
    e.fill = make("Frame", { Size = UDim2.fromScale(1, 1), BackgroundColor3 = Color3.fromRGB(78, 229, 154), BorderSizePixel = 0 }, e.track)
    make("UICorner", { CornerRadius = UDim.new(1, 0) }, e.fill)
    e.bb, e.pill = bb, pill
end

local function espPaint(e, p, char, dist, col)
    local hum = char:FindFirstChildOfClass("Humanoid")
    local hp = 1
    if hum and hum.MaxHealth > 0 then hp = math.clamp(hum.Health / hum.MaxHealth, 0, 1) end
    e.name.Text = p.DisplayName
    e.sub.Text = dist > 0 and (dist .. " studs") or "nearby"
    e.pill.Size = UDim2.fromOffset(math.min(270, math.max(62, #p.DisplayName * 7.5) + 57), 44)
    e.ring.Color = col
    e.fill.Size = UDim2.fromScale(hp, 1)
    e.fill.BackgroundColor3 = hp > 0.6 and Color3.fromRGB(78, 229, 154) or (hp > 0.3 and Color3.fromRGB(255, 170, 64) or Color3.fromRGB(255, 92, 92))
    e.scale.Scale = math.clamp(1 - (dist - 40) / 400, 0.62, 1)
    local fade = math.clamp((dist - 80) / 500, 0, 0.45)
    e.pill.BackgroundTransparency = 0.12 + fade
    e.rim.Transparency = 0.86 + fade * 0.3
    e.name.TextTransparency, e.sub.TextTransparency = fade, fade
    e.avatar.ImageTransparency, e.avatar.BackgroundTransparency, e.ring.Transparency = fade, fade, fade
    e.track.BackgroundTransparency = 0.86 + fade * 0.2
    e.fill.BackgroundTransparency = fade
end

local function espEnsure(p)
    if p == plr then return end
    if espHidden(p) then espDestroy(p); return end
    local char = p.Character
    local root = getRootPart(char)
    local head = char and (char:FindFirstChild("Head") or root)
    if not (char and root and head) then espDestroy(p); return end
    local e = Esp.entries[p]
    if not e then e = {}; Esp.entries[p] = e end
    local col = espColor(p)
    if Esp.mode ~= "off" then
        if not e.hl then
            e.hl = make("Highlight", { Name = "PuppyAdminESP_HL_" .. p.UserId, DepthMode = Enum.HighlightDepthMode.AlwaysOnTop }, guiRoot())
        end
        e.hl.Adornee = char
        if Esp.mode == "chams" then
            e.hl.FillColor, e.hl.OutlineColor = col, col:Lerp(Color3.new(1, 1, 1), 0.55)
            e.hl.FillTransparency, e.hl.OutlineTransparency = 0.68, 0
        else
            e.hl.FillColor, e.hl.OutlineColor = col, col
            e.hl.FillTransparency, e.hl.OutlineTransparency = 0.92, 0.3
        end
    else
        espDrop(e, "hl")
    end
    if Esp.mode == "esp" then
        espLabel(e, p, head)
        local myRoot = getRootPart(plr.Character)
        local dist = myRoot and math.floor((myRoot.Position - root.Position).Magnitude + 0.5) or 0
        pcall(espPaint, e, p, char, dist, col)
    else
        espDrop(e, "bb")
    end
    if Esp.hitboxes then
        if not e.box then
            e.box = make("BoxHandleAdornment", {
                Name = "PuppyAdminHitbox_" .. p.UserId, AlwaysOnTop = true, ZIndex = 10, Transparency = 0.52,
            }, guiRoot())
        end
        e.box.Adornee, e.box.Color3 = root, col
        e.box.Size, e.box.CFrame = Vector3.new(4.5, 6.5, 3.2), CFrame.new()
    else
        espDrop(e, "box")
    end
end

local function espRefresh()
    local alive = {}
    for _, p in ipairs(Players:GetPlayers()) do
        if p ~= plr then alive[p] = true; pcall(espEnsure, p) end
    end
    for p in pairs(Esp.entries) do
        if not alive[p] then espDestroy(p) end
    end
end

local function espStart()
    if Esp.conns.hb then return end
    Esp.conns.added = Players.PlayerAdded:Connect(function(p) task.defer(espEnsure, p) end)
    Esp.conns.removing = Players.PlayerRemoving:Connect(espDestroy)
    local acc = 0
    Esp.conns.hb = RunService.Heartbeat:Connect(function(dt)
        acc = acc + dt
        if acc < 0.18 then return end
        acc = 0
        espRefresh()
    end)
    espRefresh()
end

local function espStopIfIdle()
    if Esp.mode ~= "off" or Esp.hitboxes or Esp.tracers then return end
    for k, c in pairs(Esp.conns) do disconnect(c); Esp.conns[k] = nil end
    for p in pairs(Esp.entries) do espDestroy(p) end
    if Esp.layer then pcall(function() Esp.layer:Destroy() end); Esp.layer = nil end
end

local function espTracers()
    local cam = workspace.CurrentCamera
    if not Esp.layer or not Esp.layer.Parent then
        Esp.layer = make("ScreenGui", { Name = "PuppyAdminTracers", IgnoreGuiInset = true, ResetOnSpawn = false, DisplayOrder = 1 }, guiRoot())
    end
    if not cam then return end
    local vp = cam.ViewportSize
    local origin = Vector2.new(vp.X / 2, vp.Y - 6)
    for p, e in pairs(Esp.entries) do
        local root = getRootPart(p.Character)
        if not e.line or not e.line.Parent then
            e.line = make("Frame", { Name = "Tracer", AnchorPoint = Vector2.new(0.5, 0.5), BorderSizePixel = 0, BackgroundTransparency = 0.3 }, Esp.layer)
        end
        local show = false
        if root then
            local s2, onScreen = cam:WorldToViewportPoint(root.Position)
            if onScreen and s2.Z > 0 then
                local d = Vector2.new(s2.X, s2.Y) - origin
                if d.Magnitude > 2 then
                    show = true
                    local mid = origin + d / 2
                    e.line.Position = UDim2.fromOffset(mid.X, mid.Y)
                    e.line.Size = UDim2.fromOffset(d.Magnitude, 1.5)
                    e.line.Rotation = math.deg(math.atan2(d.Y, d.X))
                    e.line.BackgroundColor3 = espColor(p)
                end
            end
        end
        e.line.Visible = show
    end
end

function Esp.setMode(mode)
    Esp.mode = mode
    if mode ~= "off" then
        espStart()
        espRefresh()
    else
        for _, e in pairs(Esp.entries) do espDrop(e, "hl"); espDrop(e, "bb") end
        espStopIfIdle()
    end
end

function Esp.setHitboxes(on)
    Esp.hitboxes = on and true or false
    if Esp.hitboxes then
        espStart()
        espRefresh()
    else
        for _, e in pairs(Esp.entries) do espDrop(e, "box") end
        espStopIfIdle()
    end
end

function Esp.setTracers(on)
    Esp.tracers = on and true or false
    if Esp.tracers then
        espStart()
        espRefresh()
        if not Esp.conns.tracers then
            Esp.conns.tracers = RunService.RenderStepped:Connect(function() pcall(espTracers) end)
        end
    else
        Esp.conns.tracers = disconnect(Esp.conns.tracers)
        for _, e in pairs(Esp.entries) do espDrop(e, "line") end
        espStopIfIdle()
    end
end

function Esp.refresh() if Esp.conns.hb then espRefresh() end end

------------------------------------------------------------------------
-- Cleanup for everything above (runs on stop / kill)
------------------------------------------------------------------------

table.insert(cleanups, function()
    pcall(Baseplate.stop)
    Esp.mode, Esp.hitboxes, Esp.tracers = "off", false, false
    pcall(espStopIfIdle)
end)
end

------------------------------------------------------------------------
-- Anti VC ban (opened with `antivcban`): the voice-chat bypass, one method
-- (formerly "Bypass V2"). The panel is built with the rest of the panels;
-- this is the logic, with no UI of its own except the replacement mic
-- button it places over the top bar's mic once the bypass is active.
------------------------------------------------------------------------

local VCB = { state = "idle", muted = true, controller = nil, conns = {}, listeners = {} }

do
    local MUTED_ICON = "rbxasset://textures/ui/VoiceChat/MicLight/Muted.png"
    local HIT_OFFSET_X, HIT_OFFSET_Y, HIT_SIZE = 14, 13, 35
    local clonerefFn = (type(cloneref) == "function") and cloneref or function(i) return i end

    local function softService(name)
        local ok, svc = pcall(function() return game:GetService(name) end)
        return ok and svc and clonerefFn(svc) or nil
    end

    local function changed()
        for _, fn in ipairs(VCB.listeners) do pcall(fn) end
    end

    local function setState(s)
        VCB.state = s
        changed()
    end

    -- Mutes or unmutes your published voice and keeps the replacement button in step.
    function VCB.setMuted(value)
        VCB.muted = value and true or false
        if VCB.applyPaused then VCB.applyPaused(VCB.muted) end
        changed()
    end

    function VCB.run()
        if VCB.state ~= "idle" then
            note("Anti VC Ban", VCB.state == "active" and "Already bypassed" or "Already running")
            return
        end
        setState("running")
        task.spawn(function()
            local ok, err = pcall(function()
                local voiceService = softService("VoiceChatService")
                local voiceInternal = softService("VoiceChatInternal")
                local coreGui = softService("CoreGui")
                if not (voiceService and voiceInternal and coreGui) then
                    error("voice chat services are not accessible here")
                end
                local talkingIcon = "rbxasset://textures/ui/VoiceChat/MicLight/Talking0.png"
                local micToggle, iconHolder, redDot

                local function findMicNodes()
                    for _, node in ipairs(coreGui:GetDescendants()) do
                        if node.Name == "toggle_mic_mute" then
                            micToggle = node
                        elseif node.Name == "RedVoiceDot" and node:IsA("GuiObject") then
                            redDot = node
                        end
                    end
                    local frame = micToggle and micToggle:FindFirstChild("IntegrationIconFrame", true)
                    iconHolder = frame and frame:FindFirstChild("IntegrationIcon", true) or nil
                end

                findMicNodes()
                if not micToggle then
                    task.spawn(function() pcall(function() voiceService:joinVoice() end) end)
                    task.wait(1.5)
                    findMicNodes()
                end

                note("Anti VC Ban", "Unmute your mic to continue")
                local function iconImage()
                    local img = iconHolder and iconHolder:FindFirstChild("1")
                    return img and img.Image or nil
                end
                local waited = 0
                while true do
                    local image = iconImage()
                    if image and image ~= MUTED_ICON and image ~= "" then
                        talkingIcon = image
                        break
                    end
                    if waited >= 60 then error("timed out waiting for your mic to unmute") end
                    task.wait(0.5)
                    waited = waited + 0.5
                end
                task.wait(1)

                task.spawn(function() pcall(function() voiceService:leaveVoice() end) end)
                task.wait(2)
                if type(getconnections) == "function" then
                    pcall(function()
                        for index, connection in ipairs(getconnections(voiceInternal.StateChanged)) do
                            if index >= 7 and connection then pcall(function() connection:Disable() end) end
                        end
                    end)
                end
                task.wait(2)
                task.spawn(function() pcall(function() voiceService:joinVoice() end) end)
                task.wait(1)
                findMicNodes()

                -- the top bar's own mic no longer reflects the real state; hide it
                if micToggle then
                    for _, d in ipairs(micToggle:GetDescendants()) do
                        if d:IsA("ImageLabel") or d:IsA("ImageButton") then d.ImageTransparency = 1
                        elseif d:IsA("TextLabel") or d:IsA("TextButton") then d.TextTransparency = 1 end
                    end
                end

                local controller = Instance.new("ScreenGui")
                controller.Name = "CustomVoiceController"
                controller.ResetOnSpawn = false
                controller.IgnoreGuiInset = true
                controller.DisplayOrder = 999999
                controller.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
                parentGui(controller)
                VCB.controller = controller

                local hitArea = make("TextButton", {
                    Name = "MicHitArea", Size = UDim2.fromOffset(HIT_SIZE, HIT_SIZE),
                    Position = UDim2.new(0, 150 + HIT_OFFSET_X, 0, 4 + HIT_OFFSET_Y),
                    BackgroundTransparency = 1, Text = "", Active = true, ZIndex = 10000,
                }, controller)
                local micIcon = make("ImageLabel", {
                    Name = "MicIcon", Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1,
                    Image = MUTED_ICON, ScaleType = Enum.ScaleType.Fit, ZIndex = 10001,
                }, hitArea)

                function VCB.applyPaused(value)
                    micIcon.Image = value and MUTED_ICON or talkingIcon
                    if redDot and redDot.Parent then redDot.Visible = not value end
                    task.spawn(function() pcall(function() voiceInternal:PublishPause(value) end) end)
                end
                hitArea.MouseButton1Click:Connect(function() VCB.setMuted(not VCB.muted) end)

                local anchor = (iconHolder and iconHolder.AbsolutePosition.X > 50 and iconHolder.AbsolutePosition)
                    or (micToggle and micToggle.AbsolutePosition.X > 50 and micToggle.AbsolutePosition)
                if anchor and anchor.Y >= 0 then
                    hitArea.Position = UDim2.new(0, anchor.X + HIT_OFFSET_X, 0, anchor.Y + HIT_OFFSET_Y)
                end
                table.insert(VCB.conns, voiceInternal.StateChanged:Connect(function()
                    local okPaused, paused = pcall(function() return voiceInternal:IsPublishPaused() end)
                    if okPaused and redDot and redDot.Parent then redDot.Visible = not paused end
                end))
                VCB.setMuted(true)
            end)
            if ok then
                setState("active")
                note("Anti VC Ban", "Bypassed - use the mic button to mute and unmute", LIGHT)
            else
                setState("idle")
                note("Anti VC Ban", "Bypass failed: " .. tostring(err):sub(1, 70), RED)
            end
        end)
    end

    -- An active bypass keeps its mic button after the script stops: the
    -- disabled StateChanged handlers cannot be restored, so it is the only
    -- way left to mute.
    table.insert(cleanups, function()
        if VCB.state ~= "active" then
            for _, c in ipairs(VCB.conns) do pcall(function() c:Disconnect() end) end
            table.clear(VCB.conns)
            if VCB.controller then pcall(function() VCB.controller:Destroy() end) end
        end
        VCB.listeners = {}
    end)
end



------------------------------------------------------------------------
-- Commands (terminal and chat share this table)
------------------------------------------------------------------------

local cmds = {
    "tools",
    "moveui", "infbaseplate", "uninfbaseplate", "esp", "unesp",
    "hide", "unhide", "mute", "unmute",
    "tp",
    "aura", "unaura", "auras",
    "tagui", "taglist", "tagsync", "tagrefresh", "hidetags", "showtags", "toggletags", "perf", "performance", "games", "gameboy", "gba", "doom", "finder", "shmost", "shlowest", "antiafk", "unantiafk", "owner", "kick", "ban", "unban", "bans", "blacklist", "antikick", "unantikick", "antivcban",
    "reanim", "alts", "form", "unform",
    "prefix", "uikey", "settings", "theme", "kill", "stop", "help",
}

-- Movement aliases come from the engine's own registrations (PUP_MOVE).
local ALIASES = {
    anim = "reanim", reanimui = "reanim", boost = "performance", fpsboost = "performance", minigames = "games", arcade = "games", gb = "gameboy", emulator = "gameboy", notags = "hidetags", tagsoff = "hidetags", tagson = "showtags", tags = "toggletags", gameboyadvance = "gba", advance = "gba", servers = "finder", serverbrowser = "finder", puppyfinder = "finder", bl = "blacklist", banlist = "blacklist",
    wh = "esp", wallhack = "esp", unwh = "unesp", noesp = "unesp", ibp = "infbaseplate",
    altui = "alts", formation = "form", altform = "form", altstop = "unform", unformation = "unform",
}

local cmdDocs = {
    tools = "tools [on|off|sub] [value] - Orbit/tail/wings with your tools; starts off ('tools on'). No sub opens the panel, 'tools help' lists subs",
    moveui = "moveui - Movement panel (fly modes, speed, noclip, airwalk, swim)",
    infbaseplate = "infbaseplate - Endless floor under you (opens its panel)",
    uninfbaseplate = "uninfbaseplate - Remove the endless floor",
    esp = "esp - Names, health and distance through walls (opens its panel)",
    unesp = "unesp - Turn ESP, chams, hitboxes and tracers off",
    tp = "tp [name] or tp [x] [y] [z] - Teleport to a player (goto) or a point (tppos)",
    hide = "hide [ui|me|all|others|name] - Hide the script UI or a character (your screen)",
    unhide = "unhide [ui|me|all|others|name] - Undo hide",
    mute = "mute [name|all|others] - Silence a player's chat and sounds (your side)",
    unmute = "unmute [name|all|others] - Undo mute",
    tagui = "tagui - Nametag editor: text, colors, backdrop, profile picture (allowlisted users only)",
    owner = "owner - Owner panel: kick, ban, auras, tag tools (owners only)",
    kick = "kick <players> [reason] - Kick players who run the script from this server only; they can join others (owners only)",
    ban = "ban <players> [reason] - Ban players from using the script; they are kicked when they run it (owners only)",
    unban = "unban <players or UserIds> - Lift a script ban (owners only)",
    bans = "bans - List players banned from the script (owners only)",
    blacklist = "blacklist - Owners: blacklist menu (everyone banned from the script, unban, add) (also: bl, banlist)",
    doom = "doom - Doom (1993): plays your WAD from the PuppyAdmin/doom folder",
    antiafk = "antiafk [on|off] - Keep Roblox from disconnecting you for being idle (also in Settings)",
    unantiafk = "unantiafk - Turn anti-AFK off",
    finder = "finder - Puppy Finder: browse this game's servers and join one (also: servers, serverbrowser)",
    serverhop = "serverhop - Join another server, picked at random (Puppy Finder; also: shop, sh)",
    shmost = "shmost - Join the fullest server (Puppy Finder)",
    shlowest = "shlowest - Join the emptiest server (Puppy Finder)",
    gameboy = "gameboy - Game Boy emulator: plays .gb / .zip games from your PuppyAdmin/roms folder (also: gb, emulator)",
    gba = "gba - Game Boy Advance emulator: plays .gba / .zip games from your PuppyAdmin/gba folder (also: gameboyadvance, advance)",
    games = "games - Mini games: Snake, Stack Drop, Treat Chase, Star Pup, Puppy Fighter, plus Game Boy, GBA and Doom (also: minigames, arcade)",
    performance = "performance - Performance panel: FPS unlock, anti-lag, low graphics, no fog / shadows / effects (also: boost)",
    perf = "perf - How long start-up and first-time actions took (for tuning the script)",
    tagrefresh = "tagrefresh - Load tags, auras and bans from the repository again and redraw every tag (running the script again does the same)",
    hidetags = "hidetags - Hide every nametag, only on your screen; showtags brings them back (also: notags, tagsoff)",
    showtags = "showtags - Show nametags again after hidetags (also: tagson)",
    toggletags = "toggletags - Hide or show every nametag on your screen (also: tags)",
    tagsync = "tagsync [pull|push] - Shared tags in the repository (token goes in Settings, never in chat)",
    taglist = "taglist [add|remove <tag> <users...>] [new|delete <name>] - All tags and their members; add many players at once",
    antikick = "antikick - Block client-side Kick calls on you",
    unantikick = "unantikick - Turn antikick off",
    antivcban = "antivcban [close] - Voice chat bypass panel (execute, then mute/unmute)",
    aura = "aura [name] [players] [color] - Give an aura everyone using the script sees (tag managers only)",
    unaura = "unaura [name|all] [players] - Take auras away (tag managers only)",
    auras = "auras - List auras and who has them",
    alts = "alts - Alt formations: your alts (from Puppy Companion) take a shape around you that everyone sees (also: altui)",
    form = "form [wings|halo|ring|star|spiral|tower|wall|trail|scatter|wingshalo|starring] [size] - Main account: your alts in this server form that shape around you (also: formation)",
    unform = "unform - Your alts leave the formation and land beside you (also: altstop)",
    reanim = "reanim [on|off | import <ID or keyframe link>] - Reanimation panel for your own imported animations; on/off toggles reanimation. Also: anim, reanimui",
    prefix = "prefix [add|remove|set] [chars] - Chat command prefixes",
    uikey = "uikey [key] - Key that shows/hides the script UI",
    settings = "settings - Toggles the settings window",
    theme = "theme [preset | role color | reset | image <id|url|off> [0-100]] - Script UI colours and background image (also in Settings)",
    kill = "kill - Terminates the script and removes everything",
    stop = "stop - Terminates the script (also resets your character)",
    help = "help - Toggles the command list menu",
}

-- Which argument (after the command) is a player name, for autocomplete.
local PLAYER_ARG = {
    hide = 1, unhide = 1, mute = 1, unmute = 1,
    aura = 2, unaura = 2, tp = 1, ["goto"] = 1,
}

local function playerArgIndex(cmd, args)
    if cmd == "tools" then
        return (args[2] and args[2]:lower() == "target") and 2 or nil
    end
    return PLAYER_ARG[cmd]
end

local function getPartialMatch(input)
    if not input or input == "" then return nil end
    if table.find(cmds, input) then return input end
    for _, c in ipairs(cmds) do
        if c:sub(1, #input) == input then return c end
    end
    return nil
end

local function parseToggle(val, current)
    if val == nil then return not current end
    val = val:lower()
    if val == "on" or val == "1" or val == "true" then return true end
    if val == "off" or val == "0" or val == "false" then return false end
    return not current
end

local function firstPrefix() return Cfg.prefixes[1] or "." end

local H = {}

-- Orbit / shapes (V4 behaviour) -----------------------------------------

function H.offset(a)
    S.offset = tonumber(a[1]) or S.offset
    note("Settings", "Distance: " .. S.offset)
end

function H.speed(a)
    local s = tonumber(a[1]) or S.speed
    S.speed = (s < 0.5 and s > -0.5) and ((s >= 0) and 0.5 or -0.5) or s
    note("Settings", "Orbit Speed: " .. S.speed)
end

function H.rot(a)
    S.toolRotSpeed = tonumber(a[1]) or S.toolRotSpeed
    note("Settings", "Tool Spin: " .. S.toolRotSpeed)
end

function H.mode(a)
    local m = tonumber(a[1])
    if m then S.mode = math.floor(m) end
    note("Settings", "Pattern Mode: " .. S.mode)
end

function H.lerp(a)
    local v = tonumber(a[1])
    if S.tailOn or S.wingsOn then
        S.lerpShape = v or S.lerpShape
        note("Settings", "Tail/Wings Follow: " .. S.lerpShape)
    else
        S.lerpOrbit = v or S.lerpOrbit
        note("Settings", "Tween Speed: " .. S.lerpOrbit)
    end
end

function H.target(a)
    local val = a[1]
    if not val then return end
    for _, p in ipairs(Players:GetPlayers()) do
        if p.Name:lower():find(val:lower(), 1, true) or (p.DisplayName and p.DisplayName:lower():find(val:lower(), 1, true)) then
            targetHRP = p.Character and p.Character:FindFirstChild("HumanoidRootPart") or targetHRP
            note("Targeting", "Locked: " .. p.DisplayName, LIGHT)
            break
        end
    end
end

function H.unorbit()
    targetHRP = hrp
    note("Targeting", "Returned to self", LIGHT)
end

function H.equip()
    for _, tool in ipairs(plr.Backpack:GetChildren()) do
        if tool:IsA("Tool") then tool.Parent = chr end
    end
    note("Command", "Equipped All")
end

function H.unequip()
    for _, tool in ipairs(chr:GetChildren()) do
        if tool:IsA("Tool") then tool.Parent = plr.Backpack end
    end
    note("Command", "Unequipped All")
end

-- Each layout has its own switch; tools are split among the enabled ones.
-- Turning a layout on equips your tools if none are set up; turning the last one
-- off puts the tools back in your backpack.
local function setLayout(which, on)
    local key = (which == "orbit") and "orbitOn" or ((which == "tail") and "tailOn" or "wingsOn")
    S[key] = on and true or false
    if not S.enabled then
        local title = which:sub(1, 1):upper() .. which:sub(2)
        note(title, (S[key] and "On" or "Off") .. " - takes effect when the tools system is on (tools on)")
        return
    end
    if S[key] and #slots == 0 then H.equip() end
    assignRoles()
    if not (S.orbitOn or S.tailOn or S.wingsOn) then
        task.defer(function() H.unequip() end)
    end
    local title = which:sub(1, 1):upper() .. which:sub(2)
    note(title, S[key] and "Enabled" or "Disabled", LIGHT)
end
function H.orbit(a) setLayout("orbit", parseToggle(a[1], S.orbitOn)) end
function H.tail(a) setLayout("tail", parseToggle(a[1], S.tailOn)) end
function H.wings(a) setLayout("wings", parseToggle(a[1], S.wingsOn)) end

function H.split(a)
    local v = tonumber(a[1])
    S.tailCount = v and math.max(0, math.floor(v)) or nil
    assignRoles()
    note("Settings", "Tail Tools: " .. (S.tailCount and tostring(S.tailCount) or "auto"))
end

function H.taillen(a)
    local v = tonumber(a[1])
    if v and v > 0 then S.tail.length = v end
    note("Settings", "Tail Length: " .. S.tail.length)
end

function H.curl(a)
    S.tail.curlDeg = tonumber(a[1]) or S.tail.curlDeg
    note("Settings", "Tail Curl: " .. S.tail.curlDeg)
end

function H.wag(a)
    S.tail.wagSpeed = tonumber(a[1]) or S.tail.wagSpeed
    note("Settings", "Tail Wag: " .. S.tail.wagSpeed)
end

function H.wingspan(a)
    local v = tonumber(a[1])
    if v and v > 0 then S.wing.span = v end
    note("Settings", "Wing Span: " .. S.wing.span)
end

function H.spread(a)
    S.wing.spreadDeg = tonumber(a[1]) or S.wing.spreadDeg
    note("Settings", "Wing Spread: " .. S.wing.spreadDeg)
end

function H.flap(a)
    S.wing.flapSpeed = tonumber(a[1]) or S.wing.flapSpeed
    note("Settings", "Wing Flap: " .. S.wing.flapSpeed)
end

function H.flapamp(a)
    S.wing.flapAmp = tonumber(a[1]) or S.wing.flapAmp
    note("Settings", "Flap Range: " .. S.wing.flapAmp)
end

function H.axis(a)
    local v = a[1] and a[1]:lower()
    if v and AXIS_OFFSETS[v] then
        S.axis = v
        note("Settings", "Handle Axis: " .. v)
    else
        note("Settings", "Axis must be x, -x, y, -y, z or -z")
    end
end

function H.netless(a)
    SETTINGS.VelocityY = tonumber(a[1]) or SETTINGS.VelocityY
    note("Settings", "Velocity Y: " .. SETTINGS.VelocityY)
end

-- Hide / mute ---------------------------------------------------------------

local function hideCmd(a, on)
    local t = a[1] and a[1]:lower()
    if not t or t == "ui" then
        Hide.setUI(on)
        note("UI", on and ("Hidden - use " .. firstPrefix() .. "unhide or " .. Cfg.uiKey) or "Visible", LIGHT)
        return
    end
    local list = resolveTargets(a[1])
    local n, last = 0, nil
    for _, p in ipairs(list) do
        if Hide.setPlayer(p, on) then n = n + 1; last = p end
    end
    local verb = on and "Hidden" or "Unhidden"
    if n == 0 then
        note("Hide", on and "Nobody to hide (not found, already hidden, or you)" or "Nobody was hidden")
    else
        note("Hide", n == 1 and (verb .. " " .. last.DisplayName) or (verb .. " " .. n .. " players"))
    end
end
function H.hide(a) hideCmd(a, true) end
function H.unhide(a) hideCmd(a, false) end

local function muteCmd(a, on)
    if not a[1] then note("Mute", "Usage: " .. (on and "mute" or "unmute") .. " [name|all|others]"); return end
    local list = resolveTargets(a[1])
    if #list == 0 then note("Mute", "No matching player"); return end
    local chatOk = true
    for _, p in ipairs(list) do
        if not Mute.set(p, on) then chatOk = false end
    end
    note("Mute", (on and "Muted " or "Unmuted ") .. (#list == 1 and list[1].DisplayName or (#list .. " players")))
    if on and not chatOk then note("Mute", "Chat muting needs TextChatService - sounds only") end
end
function H.mute(a) muteCmd(a, true) end
function H.unmute(a) muteCmd(a, false) end

-- Auras -------------------------------------------------------------------------

-- Owner commands (the TAG_EDITORS accounts) -------------------------------------

local function ownerOnly()
    if canEditTags() then return true end
    note("Owner", "Owners only", RED)
    return false
end

-- players: names, display names, UserIds, all, others (comma separated). Yields.
local function ownerTargets(token)
    local uids, missing = Tags.resolveUsers({ token })
    local out, skipped = {}, 0
    for _, id in ipairs(uids) do
        if Moderation.isOwnerId(id) then skipped = skipped + 1 else out[#out + 1] = id end
    end
    return out, missing, skipped
end

local function ownerAction(label, a, fn)
    if not ownerOnly() then return end
    local who = a[1]
    if not who then note("Owner", "Usage: " .. label .. " <players> [reason]"); return end
    local reason = table.concat(a, " ", 2)
    task.spawn(function()
        local uids, missing, skipped = ownerTargets(who)
        if #uids == 0 then
            note("Owner", skipped > 0 and "Owners cannot be targeted" or ("No matching player" .. (#missing > 0 and (": " .. table.concat(missing, ", ")) or "")), RED)
            return
        end
        local ok, msg = fn(uids, reason)
        note("Owner", tostring(msg), ok and LIGHT or RED)
    end)
end

function H.kick(a) ownerAction("kick", a, Moderation.kick) end
function H.ban(a) ownerAction("ban", a, Moderation.ban) end
function H.unban(a)
    if not ownerOnly() then return end
    if not a[1] then note("Owner", "Usage: unban <players or UserIds>"); return end
    task.spawn(function()
        local uids = Tags.resolveUsers({ a[1] })
        local ok, msg = Moderation.unban(uids)
        note("Owner", tostring(msg), ok and LIGHT or RED)
    end)
end
function H.bans()
    if not ownerOnly() then return end
    local lines = {}
    for _, e in ipairs(Moderation.entries) do
        if e.type == "ban" then table.insert(lines, Tags.memberName(e.userId) .. (e.reason ~= "" and ("  -  " .. e.reason) or "")) end
    end
    if #lines == 0 then lines[1] = "Nobody is banned" end
    table.insert(lines, "")
    table.insert(lines, "Moderation: " .. tostring(Moderation.status))
    UIAPI.showOutput("BANNED FROM THE SCRIPT", lines)
end
function H.owner()
    if not ownerOnly() then return end
    UIAPI.togglePanel("owner")
end
-- Puppy Finder (server browser) and its quick commands
function H.finder() UIAPI.togglePanel("finder") end
function H.serverhop() UIAPI.finder.start("random"); note("Puppy Finder", "Looking for another server...", LIGHT) end
function H.shmost() UIAPI.finder.start("most"); note("Puppy Finder", "Looking for the fullest server...", LIGHT) end
function H.shlowest() UIAPI.finder.start("lowest"); note("Puppy Finder", "Looking for the emptiest server...", LIGHT) end

-- antiafk [on|off] (no argument: switch)
function H.antiafk(a)
    local l = a and a[1] and a[1]:lower()
    local on
    if l == "on" or l == "1" or l == "true" then on = true elseif l == "off" or l == "0" or l == "false" then on = false else on = not UIAPI.antiAfk.on end
    UIAPI.antiAfk.set(on)
    note("Anti-AFK", on and "On - you will not be disconnected for being idle" or "Off", on and LIGHT or GREY)
end
function H.unantiafk() H.antiafk({ "off" }) end

function H.blacklist()
    if not ownerOnly() then return end
    UIAPI.togglePanel("blacklist")
end

-- aura <name> [players] [color]   give an aura to players (names, UserIds, all, others; default: you)
-- unaura <name|all> [players]     take it away
-- Allowlisted (same accounts as the tag editor); shared with everyone using the script.
function H.aura(a)
    if not canEditTags() then note("Aura", "Only tag managers can give out auras", RED); return end
    local name = a[1] and a[1]:lower()
    if not name then note("Aura", "Usage: aura [name] [players] [color] - see 'auras'"); return end
    if not Aura.defs[name] then note("Aura", "Unknown aura '" .. name .. "' - see 'auras'", RED); return end
    local r, g, b = parseColorArgs(a, 3)
    local color = r and { r, g, b } or nil
    local who = a[2] or "me"
    task.spawn(function()
        local uids, missing = Tags.resolveUsers({ who })
        if #uids == 0 then note("Aura", "No matching player" .. (#missing > 0 and (": " .. table.concat(missing, ", ")) or ""), RED); return end
        AuraSync.give(uids, name, color)
        note("Aura", name .. " -> " .. (#uids == 1 and Tags.memberName(uids[1]) or (#uids .. " players")), LIGHT)
    end)
end

function H.unaura(a)
    if not canEditTags() then note("Aura", "Only tag managers can remove auras", RED); return end
    local name = a[1] and a[1]:lower()
    if not name then note("Aura", "Usage: unaura [name|all] [players]"); return end
    if name == "all" then name = nil end
    local who = a[2] or "me"
    task.spawn(function()
        local uids = Tags.resolveUsers({ who })
        note("Aura", "Removed " .. AuraSync.take(uids, name))
    end)
end

function H.auras()
    local lines = {}
    for _, name in ipairs(Aura.order) do
        table.insert(lines, name .. " - " .. Aura.defs[name].desc)
    end
    table.insert(lines, "")
    table.insert(lines, "Given out (shared, " .. tostring(AuraSync.status) .. "):")
    local any = false
    for uid, set in pairs(AuraSync.shared) do
        for name in pairs(set) do
            any = true
            table.insert(lines, "  " .. Tags.memberName(uid) .. "  -  " .. name)
        end
    end
    if not any then table.insert(lines, "  nobody yet") end
    table.insert(lines, "")
    table.insert(lines, "color: name, #hex or r,g,b - lightning keeps its own colours unless you give one")
    UIAPI.showOutput("AURAS", lines)
end

-- Reanimation / animations ---------------------------------------------------------

-- reanim: the Reanimation panel (power, library, states, recording, copy,
-- live, tricks, speed and transitions all live there). `reanim on` / `reanim off`
-- press its power button. anim / reanimui are aliases of it.
function H.reanim(a)
    local l = a[1] and a[1]:lower()
    if l == "on" or l == "off" then
        Pup.setActive(l == "on")
    elseif l == "import" then
        if not Pup.ensure() then return end
        task.spawn(function()
            note("Reanim", "Importing " .. tostring(a[2]) .. "...")
            local ok, name, path = Pup.importCatalog(a[2])
            if not ok then note("Reanim", name, RED); return end
            note("Reanim", "Imported " .. name .. " - in Library > Your animations", LIGHT)
            local rs = _G._pup_reanimState
            if Reanim.active and type(rs) == "table" and type(rs.playAnim) == "function" then pcall(rs.playAnim, name, path) end
            if UIAPI.syncFns.reanim then pcall(UIAPI.syncFns.reanim) end
        end)
    else
        Pup.setOpen()
    end
end

-- Panels and teleport -------------------------------------------------------------



function H.antikick()
    if AntiKick.on then note("AntiKick", "Already active"); return end
    if not AntiKick.install() then
        note("AntiKick", "Your executor has no hookmetamethod/hookfunction", RED)
        return
    end
    AntiKick.on = true
    note("AntiKick", "Enabled (client-side Kick calls only)", LIGHT)
end

function H.unantikick()
    AntiKick.on = false
    note("AntiKick", "Disabled (" .. AntiKick.blocked .. " blocked this session)")
end

function H.antivcban(a)
    local sub = a[1] and a[1]:lower()
    local p = UIAPI.panels.vcb
    if not p then return end
    p.Visible = sub ~= "close"
    if UIAPI.sync then UIAPI.sync() end
end

function H.performance() UIAPI.togglePanel("performance") end
function H.games() UIAPI.togglePanel("games") end
function H.gameboy() UIAPI.togglePanel("gameboy") end
function H.gba() UIAPI.togglePanel("gba") end
-- superfly [speed]: the Superfly window (the engine's own panel needs UI kits it does not ship)
function H.superfly(a)
    if not Pup.boot() then return end
    UIAPI.hookSuperfly()
    local v = tonumber(a and a[1])
    if v then Pup.state.setFlySpeed(v) end
    UIAPI.togglePanel("superfly")
end
function H.doom() UIAPI.togglePanel("doom") end


function H.perf()
    local lines = { "Times in milliseconds (ms). Background reads do not hold up the UI.", "" }
    for _, m in ipairs(Perf.marks) do
        table.insert(lines, string.format("%7.1f ms   %s   (at %.1f s)", m.ms, m.name, m.at))
    end
    if #Perf.marks == 0 then lines[#lines + 1] = "Nothing measured yet" end
    table.insert(lines, "")
    table.insert(lines, "Not measurable from inside: downloading + compiling the script. To see it, run:")
    table.insert(lines, "local t=os.clock() local f=loadstring(game:HttpGet(URL)) print(os.clock()-t) f()")
    UIAPI.showOutput("PERFORMANCE", lines)
end

function H.tagrefresh()
    Tags.refreshFromRepo(false)
end

-- Nametag visibility on your own screen (the tags stay as they are for everyone else)
function UIAPI.setTagsHidden(on, quiet)
    Cfg.tagsHidden = on and true or false
    cfgSave()
    Tags.step(os.clock())
    if UIAPI.tagsVisChanged then pcall(UIAPI.tagsVisChanged) end
    if not quiet then note("Nametags", Cfg.tagsHidden and "Hidden on your screen" or "Shown", LIGHT) end
end
function H.hidetags() UIAPI.setTagsHidden(true) end
function H.showtags() UIAPI.setTagsHidden(false) end
function H.toggletags() UIAPI.setTagsHidden(not Cfg.tagsHidden) end

-- tagsync          status
-- tagsync pull     load the repository's tags now
-- tagsync push     write your tags to the repository now (needs the token in Settings)
function H.tagsync(a)
    local sub = a[1] and a[1]:lower()
    if sub == "pull" then
        task.spawn(function()
            local ok, msg = TagSync.pull(true)
            note("Tag sync", msg, ok and LIGHT or RED)
        end)
    elseif sub == "push" then
        if not canEditTags() then note("Tags", "Not authorized to edit nametags", RED); return end
        task.spawn(function()
            local ok, msg = TagSync.push()
            note("Tag sync", msg, ok and LIGHT or RED)
        end)
    else
        local c = SETTINGS.TagSync
        note("Tag sync", (TagSync.token() and "read + write" or "read only") .. " - " .. c.owner .. "/" .. c.repo .. ":" .. c.path .. " - " .. tostring(TagSync.status))
        note("Presence", tostring(Presence.status))
        note("Repo check", "every " .. SETTINGS.TagSync.pollSeconds .. " s - " .. tostring(RepoSync.status))
    end
end

function H.tagui()
    if not canEditTags() then
        note("Tags", "Not authorized to edit nametags", RED)
        return
    end
    UIAPI.togglePanel("tags")
end

-- taglist                          open the tag list (all tags, members, add players)
-- taglist add <tag> <users...>     add any number of players (names, UserIds, all, others)
-- taglist remove <tag> <users...>  take players off a tag
-- taglist new <name> / delete <name>
function H.taglist(a)
    if not canEditTags() then note("Tags", "Not authorized to edit nametags", RED); return end
    local sub = a[1] and a[1]:lower()
    if not sub then
        local dflt = Tags.defaultDef() or Tags.builtinDefault
        local lines = { "Default  \"" .. (dflt.text or "") .. "\"  -  everyone running the script without a custom tag" }
        for _, def in ipairs(Cfg.tagDefs) do
            if not def.isDefault then
                local names = {}
                for _, uid in ipairs(def.members) do table.insert(names, Tags.memberName(uid)) end
                table.insert(lines, def.name .. "  \"" .. (def.text or "") .. "\"  -  " .. (#names > 0 and table.concat(names, ", ") or "no members"))
            end
        end
        if #lines == 1 then lines[2] = "No custom tags yet - taglist new <name>, or use the panel" end
        UIAPI.showOutput("TAGS", lines)
        local p = UIAPI.panels.taglist
        if p then p.Visible = true; if UIAPI.syncFns.taglist then UIAPI.syncFns.taglist() end end
        return
    end
    if sub == "new" then
        local name = table.concat(a, " ", 2)
        if name == "" then note("Tags", "taglist new <name>", RED); return end
        if Tags.findDef(name) then note("Tags", "That tag already exists", RED); return end
        local def = Tags.newDef(name)
        Tags.ui.current = def
        note("Tags", "Created '" .. def.name .. "' - edit its look with tagui", LIGHT)
    elseif sub == "delete" then
        local def = Tags.findDef(table.concat(a, " ", 2))
        if not def then note("Tags", "No tag with that name", RED); return end
        Tags.deleteDef(def)
        note("Tags", "Deleted '" .. def.name .. "'")
    elseif sub == "add" or sub == "remove" then
        -- the tag name may contain spaces: take the longest run of words that names a tag
        local def, last
        for k = #a, 2, -1 do
            def = Tags.findDef(table.concat(a, " ", 2, k))
            if def then last = k; break end
        end
        if not def then note("Tags", "No tag named '" .. tostring(a[2]) .. "'", RED); return end
        local tokens = { table.unpack(a, last + 1) }
        if #tokens == 0 then note("Tags", "taglist " .. sub .. " <tag> <names or UserIds>", RED); return end
        task.spawn(function()
            local uids, missing = Tags.resolveUsers(tokens)
            local n = 0
            if sub == "add" then
                n = Tags.addMembers(def, uids)
            else
                for _, uid in ipairs(uids) do if Tags.removeMember(def, uid) then n = n + 1 end end
            end
            note("Tags", (sub == "add" and "Added " or "Removed ") .. n .. (sub == "add" and " to '" or " from '") .. def.name .. "'"
                .. (#missing > 0 and ("; not found: " .. table.concat(missing, ", ")) or ""), n > 0 and LIGHT or RED)
            if UIAPI.syncFns.taglist then UIAPI.syncFns.taglist() end
        end)
    else
        note("Tags", "taglist [add|remove <tag> <users>] [new|delete <name>]")
    end
    if UIAPI.syncFns.taglist then UIAPI.syncFns.taglist() end
end


-- Script settings ---------------------------------------------------------------

function H.prefix(a)
    local mode = a[1] and a[1]:lower()
    local rest = {}
    for i = (mode == "add" or mode == "remove" or mode == "set") and 2 or 1, #a do table.insert(rest, a[i]) end
    if not a[1] then
        note("Prefix", table.concat(Cfg.prefixes, "  "), LIGHT)
        return
    end
    local given = parsePrefixList(table.concat(rest, " "))
    if #given == 0 then
        note("Prefix", "1-3 symbols, no letters/digits/spaces", RED)
        return
    end
    if mode == "add" then
        for _, p in ipairs(given) do
            if not table.find(Cfg.prefixes, p) then table.insert(Cfg.prefixes, p) end
        end
    elseif mode == "remove" then
        for _, p in ipairs(given) do
            local i = table.find(Cfg.prefixes, p)
            if i and #Cfg.prefixes > 1 then table.remove(Cfg.prefixes, i) end
        end
    else
        Cfg.prefixes = given
    end
    cfgSave()
    note("Prefix", table.concat(Cfg.prefixes, "  "), LIGHT)
end

function H.uikey(a)
    local kc = resolveKeyCode(a[1])
    if not a[1] then note("UI Key", Cfg.uiKey); return end
    if not kc then note("UI Key", "Unknown key", RED); return end
    Cfg.uiKey = kc.Name
    cfgSave()
    note("UI Key", kc.Name, LIGHT)
end

function H.theme(a)
    local first = a[1]
    if not first then
        if UIAPI.settingsTab then UIAPI.settingsTab("Look") elseif settingsFrame then settingsFrame.Visible = true end
        local names = {}
        for _, p in ipairs(Theme.presets) do table.insert(names, p.name) end
        note("Theme", "Presets: " .. table.concat(names, ", "))
        return
    end
    local firstL = first:lower()
    if firstL == "image" or firstL == "wallpaper" then
        local rest = { table.unpack(a, 2) }
        task.spawn(function()
            local ok, msg = Theme.applyImageArgs(rest)
            note("Theme", msg, ok and LIGHT or RED)
        end)
        return
    end
    if firstL == "reset" then first = "Default" end
    if Theme.usePreset(first) then note("Theme", first, LIGHT); return end
    local role = Theme.resolveRole(first)
    if not role then
        note("Theme", "Unknown preset or role '" .. first .. "'", RED)
        return
    end
    local r, g, b = parseColorArgs(a, 2)
    if not r then note("Theme", "Usage: theme " .. role .. " #ff88cc  (or r g b, or a name)", RED); return end
    Theme.setRole(role, Color3.fromRGB(r, g, b))
    note("Theme", Theme.labels[role] .. " " .. Theme.hex(Theme.current[role]), LIGHT)
end

function H.settings()
    if settingsFrame then settingsFrame.Visible = not settingsFrame.Visible end
end

-- cursor [default|glove|light|keyblade|<image id or URL>] [size]
function H.cursor(a)
    local C = UIAPI.Cursor
    local first = a[1]
    if not first then
        if UIAPI.settingsTab then UIAPI.settingsTab("Look") end
        note("Cursor", "Now: " .. tostring(Cfg.cursor) .. " - choices: default, glove, light, keyblade, or an image id/URL", LIGHT)
        return
    end
    local size = tonumber(a[2])
    if tonumber(first) and not a[2] and tonumber(first) <= 128 then -- "cursor 48" = size only
        C.setSize(first); note("Cursor", "Size " .. Cfg.cursorSize .. " px", LIGHT); return
    end
    if size then C.setSize(size) end
    local name
    for _, n in ipairs(C.CHOICES) do if n:lower() == first:lower() then name = n end end
    if not name then Cfg.cursorImage = first; name = "Custom" end
    task.spawn(function()
        local ok, msg = C.set(name)
        note("Cursor", msg, ok and LIGHT or RED)
    end)
end
table.insert(cmds, "cursor")
cmdDocs.cursor = "cursor [default|glove|light|keyblade|image id/URL] [size] - Mouse cursor image (also in Settings > Look)"

function H.help()
    if helpFrame then helpFrame.Visible = not helpFrame.Visible end
end

function H.kill() shutdown(false) end
function H.stop() shutdown(SETTINGS.KillCharacterOnStop) end

do
-- Tools: every orbit / tail / wings command lives under `tools` ---------------------

local TOOL_SUBS = {
    { "on", "", "Turn the tools system on (it starts off; nothing touches your tools until then)" },
    { "off", "", "Turn it off and give your tools back" },
    { "orbit", "[on|off]", "Orbit layout" },
    { "tail", "[on|off]", "Tail layout" },
    { "wings", "[on|off]", "Wings layout" },
    { "equip", "", "Equip every tool in your backpack" },
    { "unequip", "", "Put your tools back in the backpack" },
    { "speed", "[num]", "Orbit speed" },
    { "offset", "[num]", "Orbit radius" },
    { "mode", "[num]", "Orbit pattern (1-30)" },
    { "rot", "[num]", "Tool spin while orbiting" },
    { "lerp", "[num]", "Follow smoothness of the active layout" },
    { "target", "[name]", "Wear the layout on another player" },
    { "unorbit", "", "Back to yourself" },
    { "split", "[num|auto]", "Tail tools when layouts are combined" },
    { "taillen", "[num]", "Tail length in studs" },
    { "curl", "[deg]", "Tail curl" },
    { "wag", "[num]", "Tail wag speed (0 = still)" },
    { "wingspan", "[num]", "Wing length in studs" },
    { "spread", "[deg]", "Wing fan angle" },
    { "flap", "[num]", "Wing flap speed (0 = still)" },
    { "flapamp", "[deg]", "Wing flap range" },
    { "axis", "[x|-x|y|-y|z|-z]", "Handle axis along the feather/tail" },
    { "netless", "[num]", "Vertical velocity applied to tools" },
}
local TOOL_SUB_SET = {}
for _, s in ipairs(TOOL_SUBS) do TOOL_SUB_SET[s[1]] = true end

function H.tools(a)
    local sub = a[1] and a[1]:lower()
    if not sub then UIAPI.togglePanel("tools"); return end
    if sub == "help" or sub == "list" then
        local lines = { "Usage: tools [sub] [value] - no sub opens the panel", "" }
        for _, s in ipairs(TOOL_SUBS) do
            table.insert(lines, "tools " .. s[1] .. (s[2] ~= "" and (" " .. s[2]) or "") .. " - " .. s[3])
        end
        UIAPI.showOutput("TOOLS", lines)
        return
    end
    if sub == "on" or sub == "off" then S.setEnabled(sub == "on"); return end
    if not TOOL_SUB_SET[sub] or not H[sub] then
        note("Tools", "Unknown '" .. sub .. "' - try tools help", RED)
        return
    end
    table.remove(a, 1)
    H[sub](a)
end

-- Movement -------------------------------------------------------------------------

local function showPanel(key)
    local p = UIAPI.panels[key]
    if p then p.Visible = true; UIAPI.sync() end
end

do
    local docsTaken = {}
    local all = {}
    for _, c in ipairs(PUP_MOVE) do all[#all + 1] = c end
    for _, c in ipairs(PUP_PERF) do all[#all + 1] = c end
    for _, c in ipairs(all) do
        local name = c.name
        if not H[name] then
            H[name] = function(a) Pup.run(name, a) end
        end
        if not table.find(cmds, name) then table.insert(cmds, name) end
        if not cmdDocs[name] then cmdDocs[name] = name .. (c.args ~= "" and (" " .. c.args) or "") .. " - " .. c.desc end
        if c.args:find("<p>", 1, true) then PLAYER_ARG[name] = 1 end
        for _, al in ipairs(c.aliases) do
            if not ALIASES[al] and not table.find(cmds, al) and not docsTaken[al] then
                ALIASES[al] = name
                docsTaken[al] = true
            end
        end
    end
end

-- tp keeps its two forms: a player (goto) or x y z (tppos).
function H.tp(a)
    if tonumber(a[1]) and tonumber(a[2]) and tonumber(a[3]) then
        Pup.run("tppos", a)
    elseif a[1] then
        Pup.run("goto", a)
    else
        note("Teleport", "Usage: tp [name] or tp [x] [y] [z]")
    end
end

-- clicktp [on|off]: click anywhere to teleport there.
function H.clicktp(a)
    local l = a[1] and a[1]:lower()
    if l == "off" or l == "0" or l == "false" then Pup.run("unclicktp", {}) else Pup.run("clicktp", {}) end
end

-- rejoin kicks you first on a solo server; let antikick pass it.
function H.rejoin(a)
    AntiKick.allowUntil = os.clock() + 3
    Pup.run("rejoin", a)
end

function H.moveui() UIAPI.togglePanel("move") end


-- World / visuals --------------------------------------------------------------------

function H.infbaseplate(a)
    local quiet = a[1] == "quiet"
    if not Baseplate.enabled then
        Baseplate.start()
        note("Baseplate", "Enabled", LIGHT)
    end
    if not quiet then showPanel("floor") end
end

function H.uninfbaseplate()
    Baseplate.stop()
    note("Baseplate", "Removed")
end

function H.esp()
    if Esp.mode ~= "esp" then Esp.setMode("esp") end
    note("ESP", "Enabled", LIGHT)
    showPanel("esp")
end

function H.unesp()
    Esp.setMode("off")
    Esp.setHitboxes(false)
    Esp.setTracers(false)
    note("ESP", "Disabled")
end

end

local function processCommandString(input)
    input = input:gsub("^%s+", "")
    local rest = matchPrefix(input, Cfg.prefixes)
    if rest then input = rest end
    local args = splitArgs(input)
    if #args == 0 then return end
    local c = table.remove(args, 1):lower()
    c = ALIASES[c] or c
    local fn = H[c]
    if not fn or not table.find(cmds, c) then return end
    local ok, err = pcall(fn, args)
    if UIAPI.sync then UIAPI.sync() end
    if not ok then note("Error", c .. ": " .. tostring(err):sub(1, 70), RED) end
end

------------------------------------------------------------------------
-- Chat commands
------------------------------------------------------------------------

local Chat = { last = "", lastT = 0 }

function Chat.handle(msg)
    if type(msg) ~= "string" then return end
    if not matchPrefix(msg, Cfg.prefixes) then return end
    local now = os.clock()
    if msg == Chat.last and now - Chat.lastT < 0.5 then return end
    Chat.last, Chat.lastT = msg, now
    processCommandString(msg)
end

function Chat.start()
    table.insert(conns, plr.Chatted:Connect(Chat.handle))
    pcall(function()
        table.insert(conns, TextChatService.MessageReceived:Connect(function(m)
            local src = m.TextSource
            if src and src.UserId == plr.UserId then Chat.handle(m.Text) end
        end))
    end)
end

------------------------------------------------------------------------
-- Panels: orbit / tail / wings (palette shared with the Reanimate panel)
------------------------------------------------------------------------

local PAL = {
    PANEL = Color3.fromRGB(23, 23, 23), STROKE = Color3.fromRGB(55, 55, 55),
    ACCENT = Color3.fromRGB(226, 226, 226), TEXT = Color3.fromRGB(244, 244, 244),
    DIM = Color3.fromRGB(160, 160, 160), DANGER = Color3.fromRGB(239, 68, 68),
    CARD = Color3.fromRGB(30, 30, 30), ELEVATED = Color3.fromRGB(40, 40, 40),
    DIV = Color3.fromRGB(44, 44, 44), SHINE = Color3.fromRGB(255, 255, 255),
    GOOD = Color3.fromRGB(80, 210, 100),
}

------------------------------------------------------------------------
-- Fonts: one choice for the whole script (Settings > Font), and custom
-- .ttf fonts shipped in the repository (assets/fonts). A custom font is
-- downloaded once into PuppyAdmin/fonts, then used through a font family
-- file and getcustomasset (executor). Every text object keeps its own
-- weight and style; only the family changes. "Default" restores the
-- fonts each widget was built with.
------------------------------------------------------------------------

local UIFont = { custom = {}, families = {}, original = setmetatable({}, { __mode = "k" }) }
do
    -- label -> repository file
    -- label -> one file, or a family of faces { file, weight, style } (weights / italics
    -- of one typeface, so bold and italic text keeps its look)
    UIFont.CUSTOM = {
        ["Kingdom Hearts"] = "KingdomHearts.ttf",
        ["KH Menu"] = {
            { file = "KHMenu.ttf", weight = 400, style = "normal" },
            { file = "KHMenuBold.ttf", weight = 700, style = "normal" },
            { file = "KHMenuItalic.ttf", weight = 400, style = "italic" },
            { file = "KHMenuBoldItalic.ttf", weight = 700, style = "italic" },
        },
        ["KH Gummi"] = "KHGummi.ttf",
        ["KH Data"] = "KHData.ttf",
        ["KH Title"] = "KHTitle.ttf",
        ["KH Scala"] = "KHScala.ttf",
        ["KH Scala Script"] = "KHScalaScript.ttf",
    }
    local DIR = "PuppyAdmin/fonts"
    local ROBLOX = {
        "Gotham", "BuilderSans", "SourceSans", "Arial", "Roboto", "Ubuntu", "Nunito", "Montserrat", "FredokaOne",
        "Cartoon", "Arcade", "Code", "RobotoMono", "Highway", "SciFi", "Bangers", "Creepster", "LuckiestGuy",
        "PermanentMarker", "IndieFlower", "Merriweather", "Garamond", "Michroma", "Oswald", "TitilliumWeb", "SpecialElite",
    }

    -- choices shown in Settings: Default, custom fonts, then Roblox fonts this client has
    function UIFont.choices()
        if UIFont.list then return UIFont.list end
        local l = { "Default" }
        local names = {}
        for name in pairs(UIFont.CUSTOM) do names[#names + 1] = name end
        table.sort(names)
        for _, n in ipairs(names) do l[#l + 1] = n end
        for _, n in ipairs(ROBLOX) do
            local ok, e = pcall(function() return Enum.Font[n] end)
            if ok and e then
                local okF, f = pcall(Font.fromEnum, e)
                if okF and f then UIFont.families[n] = f.Family; l[#l + 1] = n end
            end
        end
        UIFont.list = l
        return l
    end

    -- Font family id for a custom font, or nil when the executor cannot load it. Yields on first download.
    function UIFont.customFamily(label)
        if UIFont.custom[label] ~= nil then return UIFont.custom[label] or nil end
        local spec = UIFont.CUSTOM[label]
        if not spec or not (writefile and readfile and isfile and getcustomasset) then UIFont.custom[label] = false; return nil end
        local faces = type(spec) == "string" and { { file = spec, weight = 400, style = "normal" } } or spec
        local ok, family = pcall(function()
            if makefolder and isfolder and not isfolder("PuppyAdmin") then makefolder("PuppyAdmin") end
            if makefolder and isfolder and not isfolder(DIR) then makefolder(DIR) end
            local out = {}
            for _, face in ipairs(faces) do
                local ttf = DIR .. "/" .. face.file
                if not isfile(ttf) then
                    local body = game:HttpGet(SETTINGS.Auras.assetBase .. "assets/fonts/" .. face.file)
                    -- a real TrueType file starts with 00 01 00 00 or "true"
                    if type(body) ~= "string" or #body < 1000 or not (body:sub(1, 4) == "\0\1\0\0" or body:sub(1, 4) == "true") then
                        error(face.file .. " download is not a TrueType font")
                    end
                    writefile(ttf, body)
                end
                out[#out + 1] = { name = (face.weight >= 700 and "Bold" or "Regular") .. (face.style == "italic" and " Italic" or ""),
                    weight = face.weight, style = face.style, assetId = getcustomasset(ttf) }
            end
            local json = DIR .. "/" .. label:gsub("[^%w]", "") .. ".json"
            writefile(json, HttpService:JSONEncode({ name = label, faces = out }))
            return getcustomasset(json)
        end)
        if not ok then warn("[PuppyAdmin] font " .. label .. ": " .. tostring(family)) end
        UIFont.custom[label] = ok and family or false
        return ok and family or nil
    end

    -- Font object for a label, keeping weight / style of the given font
    function UIFont.make(label, weight, style)
        local family = UIFont.CUSTOM[label] and UIFont.customFamily(label) or UIFont.families[label]
        if not family then return nil end
        local ok, f = pcall(Font.new, family, weight or Enum.FontWeight.Regular, style or Enum.FontStyle.Normal)
        return ok and f or nil
    end

    local current -- family id in use, nil = Default

    local function isText(inst)
        return inst:IsA("TextLabel") or inst:IsA("TextButton") or inst:IsA("TextBox")
    end

    -- Text size scale (Settings > Text size): every text object keeps the size
    -- it was built with (UIFont.size) and shows base * scale. When the
    -- script itself later sets a new size, that becomes the new base.
    -- TextScaled text already fits its box and is left alone.
    UIFont.scale = 1
    UIFont.size = setmetatable({}, { __mode = "k" })
    local sizeSet = setmetatable({}, { __mode = "k" }) -- last size written here (signals may arrive deferred)
    local function applySize(inst)
        if inst.TextScaled then return end
        local base = UIFont.size[inst]
        if not base then
            if UIFont.scale == 1 then return end
            base = inst.TextSize
            UIFont.size[inst] = base
            inst:GetPropertyChangedSignal("TextSize"):Connect(function()
                if inst.TextSize == sizeSet[inst] then return end
                UIFont.size[inst] = inst.TextSize
                applySize(inst)
            end)
        end
        local want = math.clamp(math.floor(base * UIFont.scale + 0.5), 6, 100)
        sizeSet[inst] = want
        if inst.TextSize ~= want then pcall(function() inst.TextSize = want end) end
    end

    local function applyFont(inst)
        if inst:GetAttribute("PuppyAdminKeepFont") then return end
        local orig = UIFont.original[inst]
        if not orig then
            if not current then return end
            orig = inst.FontFace
            UIFont.original[inst] = orig
        end
        pcall(function()
            if current then
                inst.FontFace = Font.new(current, orig.Weight, orig.Style)
            else
                inst.FontFace = orig
            end
        end)
    end

    function UIFont.applyTo(inst)
        if not isText(inst) then return end
        applyFont(inst)
        pcall(applySize, inst)
    end

    local function active() return current ~= nil or UIFont.scale ~= 1 end

    function UIFont.applyTree(root)
        UIFont.applyTo(root)
        for _, d in ipairs(root:GetDescendants()) do UIFont.applyTo(d) end
    end

    UIFont.roots = {}
    function UIFont.attach(root)
        table.insert(UIFont.roots, root)
        table.insert(conns, root.DescendantAdded:Connect(function(d)
            if active() then task.defer(function() if d.Parent then UIFont.applyTo(d) end end) end
        end))
        if active() then UIFont.applyTree(root) end
    end

    -- label from UIFont.choices(); returns ok, message. Yields for a first download.
    function UIFont.set(label, quiet)
        local family
        if label ~= "Default" then
            UIFont.choices()
            family = UIFont.CUSTOM[label] and UIFont.customFamily(label) or UIFont.families[label]
            if not family then return false, label .. " is not available on this executor" end
        end
        current = family
        Cfg.uiFont = label
        if not quiet then cfgSave() end
        for i = #UIFont.roots, 1, -1 do
            local r = UIFont.roots[i]
            if r.Parent then UIFont.applyTree(r) else table.remove(UIFont.roots, i) end
        end
        return true, "Font: " .. label
    end

    local function applyAll()
        for i = #UIFont.roots, 1, -1 do
            local r = UIFont.roots[i]
            if r.Parent then UIFont.applyTree(r) else table.remove(UIFont.roots, i) end
        end
    end

    -- v: 0.5 .. 2 (1 = sizes as built)
    function UIFont.setScale(v, quiet)
        v = tonumber(v)
        if not v or v ~= v then return false, "Text size: a number like 120 (percent)" end
        v = math.clamp(math.floor(v * 20 + 0.5) / 20, 0.5, 2)
        UIFont.scale = v
        Cfg.uiTextScale = v
        if not quiet then cfgSave() end
        applyAll()
        return true, "Text size " .. math.floor(v * 100 + 0.5) .. "%"
    end

    function UIFont.load()
        if type(Cfg.uiTextScale) == "number" and Cfg.uiTextScale ~= 1 then UIFont.setScale(Cfg.uiTextScale, true) end
        if type(Cfg.uiFont) == "string" and Cfg.uiFont ~= "Default" then
            local ok = UIFont.set(Cfg.uiFont, true)
            if not ok then current = nil end
        end
    end
end


------------------------------------------------------------------------
-- Theme: recolours the script's own UI (terminal, notifications, every panel).
-- Panels read PAL when they paint; older widgets were built with fixed colour
-- literals, so those are mapped to a role by their current colour instead.
------------------------------------------------------------------------

do
    local function clamp8(n) return math.max(0, math.min(255, math.floor(n + 0.5))) end
    local function rgb(c) return clamp8(c.R * 255), clamp8(c.G * 255), clamp8(c.B * 255) end
    local function key(c) local r, g, b = rgb(c); return r * 65536 + g * 256 + b end

    local ROLES = { "bg", "surface", "accent", "text", "dim", "border", "on" }
    local LABELS = {
        bg = "Background", surface = "Surface", accent = "Accent", text = "Text",
        dim = "Muted text", border = "Border", on = "Toggle on",
    }
    local PRESETS = {
        { name = "Default", bg = { 23, 23, 23 }, surface = { 30, 30, 30 }, accent = { 226, 226, 226 }, text = { 244, 244, 244 }, dim = { 160, 160, 160 }, border = { 55, 55, 55 }, on = { 80, 210, 100 } },
        { name = "Midnight", bg = { 14, 18, 32 }, surface = { 22, 28, 48 }, accent = { 110, 150, 255 }, text = { 230, 236, 255 }, dim = { 140, 152, 190 }, border = { 48, 58, 92 }, on = { 90, 140, 255 } },
        { name = "Puppy", bg = { 30, 18, 26 }, surface = { 44, 26, 38 }, accent = { 255, 130, 190 }, text = { 255, 236, 246 }, dim = { 210, 160, 190 }, border = { 92, 52, 78 }, on = { 255, 105, 180 } },
        { name = "Forest", bg = { 16, 24, 18 }, surface = { 24, 36, 27 }, accent = { 120, 210, 140 }, text = { 232, 245, 234 }, dim = { 150, 180, 155 }, border = { 52, 78, 58 }, on = { 80, 200, 110 } },
        { name = "Crimson", bg = { 24, 12, 14 }, surface = { 38, 18, 22 }, accent = { 235, 80, 90 }, text = { 250, 234, 236 }, dim = { 190, 150, 155 }, border = { 86, 40, 46 }, on = { 230, 70, 80 } },
        { name = "Light", bg = { 240, 240, 244 }, surface = { 226, 226, 232 }, accent = { 60, 110, 230 }, text = { 24, 24, 28 }, dim = { 100, 100, 110 }, border = { 190, 190, 200 }, on = { 60, 170, 90 } },
    }

    -- Which roles each colour property may hold, in match order.
    local PROP_ROLES = {
        BackgroundColor3 = { "bg", "surface", "elevated", "div", "border", "on", "accent", "dim" },
        TextColor3 = { "text", "dim", "accent" },
        PlaceholderColor3 = { "dim" },
        ScrollBarImageColor3 = { "dim" },
        Color = { "border", "div" },
    }
    -- Fixed colours the older widgets are built with, and the role each stands for.
    local LITERALS = {
        BackgroundColor3 = { bg = { 0x0F0F0F, 0x0A0A0A }, surface = { 0x050505, 0x141414, 0x1E1E26 }, accent = { 0x969696, 0xC8C8C8 } },
        TextColor3 = { text = { 0xFFFFFF, 0xC8C8C8 }, dim = { 0xAAAAAA, 0x969696, 0x646464 } },
        PlaceholderColor3 = { dim = { 0x505050, 0x646464 } },
        ScrollBarImageColor3 = { dim = { 0x646464 } },
        Color = { border = { 0x3C3C3C, 0x505050, 0x646464 } },
    }

    local function fromRGB(t) return Color3.fromRGB(t[1], t[2], t[3]) end

    -- elevated (switch tracks, active tabs) and div (dividers) are derived, not edited
    local function derive(t)
        local r, g, b = rgb(t.surface)
        local d = (0.299 * r + 0.587 * g + 0.114 * b) / 255 > 0.5 and -12 or 10
        t.elevated = Color3.fromRGB(clamp8(r + d), clamp8(g + d), clamp8(b + d))
        t.div = t.border:Lerp(t.bg, 0.35)
        return t
    end

    local function fromPreset(p)
        local t = {}
        for _, role in ipairs(ROLES) do t[role] = fromRGB(p[role]) end
        return derive(t)
    end

    local DEFAULT = fromPreset(PRESETS[1])

    local function roleOf(prop, color, from, useLiterals)
        local k = key(color)
        for _, role in ipairs(PROP_ROLES[prop]) do
            local c = from[role]
            if c and key(c) == k then return role end
        end
        if useLiterals and LITERALS[prop] then
            for role, list in pairs(LITERALS[prop]) do
                for _, v in ipairs(list) do
                    if v == k then return role end
                end
            end
        end
        return nil
    end

    local function propsOf(inst)
        if inst:IsA("UIStroke") then return { "Color" } end
        if not inst:IsA("GuiObject") then return nil end
        local p = { "BackgroundColor3" }
        if inst:IsA("TextLabel") or inst:IsA("TextButton") or inst:IsA("TextBox") then table.insert(p, "TextColor3") end
        if inst:IsA("TextBox") then table.insert(p, "PlaceholderColor3") end
        if inst:IsA("ScrollingFrame") then table.insert(p, "ScrollBarImageColor3") end
        return p
    end

    local function recolor(inst, from, to)
        if inst.Name == "PuppyAdminSwatch" or (inst.Parent and inst.Parent.Name == "PuppyAdminSwatch") then return end
        if inst:FindFirstAncestor("PuppyAdminGameBoard") then return end -- game cells repaint themselves
        local props = propsOf(inst)
        if not props then return end
        for _, prop in ipairs(props) do
            local ok, cur = pcall(function() return inst[prop] end)
            if ok and typeof(cur) == "Color3" then
                local role = roleOf(prop, cur, from, true)
                if role and to[role] then pcall(function() inst[prop] = to[role] end) end
            end
        end
    end

    Theme = { roles = ROLES, labels = LABELS, presets = PRESETS, current = DEFAULT, listeners = {}, roots = {} }

    function Theme.applyPAL()
        local t = Theme.current
        PAL.PANEL, PAL.CARD, PAL.ELEVATED = t.bg, t.surface, t.elevated
        PAL.STROKE, PAL.DIV = t.border, t.div
        PAL.TEXT, PAL.DIM, PAL.ACCENT, PAL.GOOD = t.text, t.dim, t.accent, t.on
    end

    local function recolorTree(root, from, to)
        recolor(root, from, to)
        for _, d in ipairs(root:GetDescendants()) do recolor(d, from, to) end
    end

    -- New widgets: built either from PAL (already themed) or from the default literals.
    function Theme.attach(root)
        UIFont.attach(root)
        table.insert(Theme.roots, root)
        table.insert(conns, root.DescendantAdded:Connect(function(d)
            task.defer(function()
                if d.Parent and Theme.current ~= DEFAULT then recolor(d, DEFAULT, Theme.current) end
            end)
        end))
        if Theme.current ~= DEFAULT then recolorTree(root, DEFAULT, Theme.current) end
    end

    local function save(presetName)
        local out = { preset = presetName }
        for _, role in ipairs(ROLES) do out[role] = { rgb(Theme.current[role]) } end
        if type(Cfg.theme) == "table" and type(Cfg.theme.image) == "table" then out.image = Cfg.theme.image end
        Cfg.theme = out
        cfgSave()
    end

    function Theme.set(t, presetName)
        local old = Theme.current
        Theme.current = derive(t)
        Theme.applyPAL()
        for i = #Theme.roots, 1, -1 do
            local r = Theme.roots[i]
            if r.Parent then recolorTree(r, old, Theme.current) else table.remove(Theme.roots, i) end
        end
        save(presetName)
        for _, fn in ipairs(Theme.listeners) do pcall(fn) end
        if UIAPI.sync then UIAPI.sync() end
    end

    function Theme.copy()
        local t = {}
        for _, role in ipairs(ROLES) do t[role] = Theme.current[role] end
        return t
    end

    function Theme.usePreset(name)
        local l = tostring(name):lower()
        for _, p in ipairs(PRESETS) do
            if p.name:lower() == l then Theme.set(fromPreset(p), p.name); return true end
        end
        return false
    end

    function Theme.setRole(role, color)
        local t = Theme.copy()
        t[role] = color
        Theme.set(t, nil)
    end

    local ROLE_ALIASES = {
        bg = "bg", background = "bg", surface = "surface", card = "surface", accent = "accent", text = "text",
        dim = "dim", muted = "dim", border = "border", stroke = "border", on = "on", toggle = "on",
    }
    function Theme.resolveRole(s) return s and ROLE_ALIASES[s:lower()] end

    function Theme.hex(c)
        local r, g, b = rgb(c)
        return string.format("#%02x%02x%02x", r, g, b)
    end

    -- Saved theme from the config file (missing roles fall back to the default).
    function Theme.load()
        local saved = Cfg.theme
        if type(saved) ~= "table" then return end
        local t, any = {}, false
        for _, role in ipairs(ROLES) do
            local v = saved[role]
            if type(v) == "table" and type(v[1]) == "number" and type(v[2]) == "number" and type(v[3]) == "number" then
                t[role] = Color3.fromRGB(clamp8(v[1]), clamp8(v[2]), clamp8(v[3]))
                any = true
            else
                t[role] = DEFAULT[role]
            end
        end
        if any then Theme.current = derive(t) end
    end

    -- Background image: every window gets a backdrop layer under its contents.
    -- The layer carries the window's own background colour and transparency
    -- (so theme colours and presets still apply), with the image drawn on top
    -- at `visibility` (0 = hidden, 1 = fully opaque image).
    Theme.backdrops = setmetatable({}, { __mode = "k" }) -- window frame -> record
    Theme.image = nil                                     -- { src, tex, visibility }
    local DEFAULT_VISIBILITY = 0.35

    local function paintBackdrop(frame, rec)
        local img = Theme.image
        if img and img.tex and frame.Parent then
            if not (rec.layer and rec.layer.Parent == frame) then
                local layer = Instance.new("ImageLabel")
                layer.Name = "PuppyAdminBackdrop"
                layer.Size = UDim2.fromScale(1, 1)
                layer.BorderSizePixel = 0
                layer.ScaleType = Enum.ScaleType.Crop
                layer.Active = false
                pcall(function() layer.ZIndex = 0 end)
                pcall(function() layer.Interactable = false end)
                make("UICorner", { CornerRadius = UDim.new(0, rec.radius) }, layer)
                layer.Parent = frame
                rec.layer = layer
            end
            rec.layer.Image = img.tex
            rec.layer.ImageTransparency = 1 - img.visibility
            rec.layer.BackgroundColor3 = frame.BackgroundColor3
            rec.layer.BackgroundTransparency = rec.transparency
            frame.BackgroundTransparency = 1
        else
            if rec.layer then pcall(function() rec.layer:Destroy() end); rec.layer = nil end
            if frame.Parent then frame.BackgroundTransparency = rec.transparency end
        end
    end

    local function paintAllBackdrops()
        for frame, rec in pairs(Theme.backdrops) do pcall(paintBackdrop, frame, rec) end
    end

    -- radius: the window's UICorner radius, so the image keeps its rounded corners.
    function Theme.addBackdrop(frame, radius)
        local rec = { radius = radius or 8, transparency = frame.BackgroundTransparency, layer = nil }
        Theme.backdrops[frame] = rec
        pcall(paintBackdrop, frame, rec)
    end

    local function saveImage()
        if type(Cfg.theme) ~= "table" then Cfg.theme = {} end
        Cfg.theme.image = Theme.image and { src = Theme.image.src, visibility = Theme.image.visibility } or nil
        cfgSave()
    end

    -- raw: anything resolveImageSource accepts. visibility: 0..1, nil keeps the
    -- current value. Downloads image URLs, so it yields. Returns ok, message.
    function Theme.setImage(raw, visibility)
        local tex, err = resolveImageSource(raw, "theme")
        if not tex then return false, err end
        local keep = Theme.image and Theme.image.visibility or DEFAULT_VISIBILITY
        local v = tonumber(visibility)
        Theme.image = { src = tostring(raw), tex = tex, visibility = math.clamp(v or keep, 0, 1) }
        paintAllBackdrops()
        saveImage()
        return true, "Background image set"
    end

    function Theme.setImageVisibility(visibility)
        if not Theme.image then return false, "No background image set" end
        Theme.image.visibility = math.clamp(tonumber(visibility) or Theme.image.visibility, 0, 1)
        paintAllBackdrops()
        saveImage()
        return true, "Image visibility " .. math.floor(Theme.image.visibility * 100 + 0.5) .. "%"
    end

    function Theme.clearImage()
        Theme.image = nil
        paintAllBackdrops()
        saveImage()
    end

    -- Saved image: resolved in the background (URLs download), then painted.
    function Theme.loadImage()
        local saved = type(Cfg.theme) == "table" and Cfg.theme.image
        if type(saved) ~= "table" or type(saved.src) ~= "string" or saved.src == "" then return end
        task.spawn(function()
            local tex = resolveImageSource(saved.src, "theme")
            if not tex or genv.PuppyAdminActive ~= true then return end
            local v = tonumber(saved.visibility) or DEFAULT_VISIBILITY
            Theme.image = { src = saved.src, tex = tex, visibility = math.clamp(v, 0, 1) }
            paintAllBackdrops()
        end)
    end

    -- Shared by `theme image ...` and the Settings field. args: { "off" } |
    -- { percent } | { source, [percent] } with percent 0-100. Yields on URLs.
    function Theme.applyImageArgs(args)
        local first = args[1]
        if not first or first == "" then
            return false, "theme image <id | rbxassetid | image URL | off> [visibility 0-100]"
        end
        local l = first:lower()
        if l == "off" or l == "none" or l == "clear" then
            Theme.clearImage()
            return true, "Background image removed"
        end
        local pct = tonumber(args[2])
        if tonumber(first) and #first <= 3 and not args[2] then
            return Theme.setImageVisibility(tonumber(first) / 100)
        end
        if args[2] and not pct then return false, "Visibility must be a number 0-100" end
        return Theme.setImage(first, pct and pct / 100 or nil)
    end

    Theme.load()
    Theme.applyPAL()
    UIFont.load()
    Theme.attach(notifGui)
    Theme.loadImage()
end

-- Panels are built the first time anything asks for them (opening one,
-- a command, a button that shows it) instead of all at start-up.
UIAPI.panels = {}
UIAPI.builders = {}
setmetatable(UIAPI.panels, { __index = function(t, key)
    local build = UIAPI.builders[key]
    if not build then return nil end
    UIAPI.builders[key] = nil
    local start = os.clock()
    local ok, err = pcall(build)
    if not ok then warn("[PuppyAdmin] panel " .. tostring(key) .. ": " .. tostring(err)) end
    local built = rawget(t, key)
    if built then pcall(UIAPI.fitWindow, built, 40) end
    Perf.since("Panel '" .. tostring(key) .. "' built on first open", start)
    return rawget(t, key)
end })
UIAPI.syncFns = {}

function UIAPI.sync()
    for _, fn in pairs(UIAPI.syncFns) do pcall(fn) end
end

function UIAPI.togglePanel(key)
    if key == "reanim" then Pup.setOpen(); return end
    local f = UIAPI.panels[key]
    if f then
        f.Visible = not f.Visible
        UIAPI.sync()
    end
end

local function corner(o, r) return make("UICorner", { CornerRadius = UDim.new(0, r) }, o) end
local function stroke(o, color, th, tr)
    return make("UIStroke", { Color = color or PAL.STROKE, Thickness = th or 1, Transparency = tr or 0 }, o)
end

local function label(parent, props)
    props.BackgroundTransparency = 1
    props.Font = props.Font or Enum.Font.GothamSemibold
    props.TextSize = props.TextSize or 13
    props.TextColor3 = props.TextColor3 or PAL.TEXT
    props.TextXAlignment = props.TextXAlignment or Enum.TextXAlignment.Left
    return make("TextLabel", props, parent)
end

local function isPointer(input)
    return input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch
end

local function makeDraggable(handle, target)
    local dragging, dragStart, startPos = false, nil, nil
    handle.InputBegan:Connect(function(input)
        if isPointer(input) then
            dragging, dragStart, startPos = true, input.Position, target.Position
        end
    end)
    table.insert(conns, UserInputService.InputChanged:Connect(function(input)
        if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement
            or input.UserInputType == Enum.UserInputType.Touch) then
            local d = input.Position - dragStart
            target.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X, startPos.Y.Scale, startPos.Y.Offset + d.Y)
        end
    end))
    table.insert(conns, UserInputService.InputEnded:Connect(function(input)
        if isPointer(input) then dragging = false end
    end))
end

-- Windows taller than WINDOW_MAX_H (or the screen) keep their layout and
-- scroll instead: the window shrinks, and everything below the title bar
-- moves into a scrolling area as tall as the original window. Windows built
-- around scrollBody only shrink (their body already scrolls).
do
local WINDOW_MAX_H = 480
local windowChrome = setmetatable({}, { __mode = "k" }) -- window -> { child = true } that stay fixed (title, close, backdrop)
function UIAPI.fitWindow(f, topY)
    if not f or f:GetAttribute("PuppyAdminFitted") then return end
    f:SetAttribute("PuppyAdminFitted", true)
    local designH = f.Size.Y.Offset
    local maxH = WINDOW_MAX_H
    local cam = workspace.CurrentCamera
    if cam and cam.ViewportSize.Y > 0 then maxH = math.min(maxH, math.max(260, cam.ViewportSize.Y - 100)) end
    if designH <= maxH then return end
    f.Size = UDim2.new(f.Size.X.Scale, f.Size.X.Offset, 0, maxH)
    -- windows placed by their top edge move down to stay centred where they were
    if f.AnchorPoint.Y == 0 then f.Position = f.Position + UDim2.fromOffset(0, math.floor((designH - maxH) / 2)) end
    if f:GetAttribute("PuppyAdminScrollBody") then return end
    local chrome = windowChrome[f] or {}
    local scroll = make("ScrollingFrame", {
        Name = "PuppyAdminWindowScroll", Position = UDim2.fromOffset(0, topY), Size = UDim2.new(1, 0, 1, -(topY + 6)),
        BackgroundTransparency = 1, BorderSizePixel = 0, ScrollBarThickness = 3, ScrollBarImageColor3 = PAL.DIM,
        ScrollingDirection = Enum.ScrollingDirection.Y, CanvasSize = UDim2.fromOffset(0, designH - topY + 6),
    }, f)
    local content = make("Frame", {
        Name = "Content", Position = UDim2.fromOffset(0, -topY), Size = UDim2.new(1, 0, 0, designH), BackgroundTransparency = 1,
    }, scroll)
    for _, ch in ipairs(f:GetChildren()) do
        if ch ~= scroll and not chrome[ch] and not ch:IsA("UIComponent") then ch.Parent = content end
    end
end

function UIAPI.markChrome(f)
    local set = {}
    for _, ch in ipairs(f:GetChildren()) do set[ch] = true end
    windowChrome[f] = set
end
end

-- Corner grip: drag the bottom-right corner to scale a window and everything
-- in it (most windows are laid out at fixed positions, so scaling is what
-- makes them bigger). Remembered per window; right-click the grip to reset.
do
    local MIN_SCALE, MAX_SCALE = 0.6, 2.2
    function UIAPI.makeResizable(f, key)
        if type(Cfg.windowScales) ~= "table" then Cfg.windowScales = {} end
        local uiScale = make("UIScale", { Scale = math.clamp(tonumber(Cfg.windowScales[key]) or 1, MIN_SCALE, MAX_SCALE) }, f)
        local grip = make("TextButton", {
            Name = "ResizeGrip", Size = UDim2.fromOffset(18, 18), Position = UDim2.new(1, -18, 1, -18),
            BackgroundTransparency = 1, Text = "\226\151\162", TextColor3 = PAL.DIM, Font = Enum.Font.GothamBold,
            TextSize = 14, AutoButtonColor = false, ZIndex = 60,
        }, f)
        local dragging, startMouse, startScale, startW = false, nil, 1, 1
        grip.InputBegan:Connect(function(input)
            if isPointer(input) then
                dragging, startMouse, startScale = true, input.Position, uiScale.Scale
                startW = math.max(1, f.AbsoluteSize.X)
            end
        end)
        table.insert(conns, UserInputService.InputChanged:Connect(function(input)
            if not dragging then return end
            if input.UserInputType ~= Enum.UserInputType.MouseMovement and input.UserInputType ~= Enum.UserInputType.Touch then return end
            -- follow the corner: the new on-screen width decides the scale (diagonal drag uses the larger change)
            local d = input.Position - startMouse
            local grow = math.max(d.X, d.Y * (f.AbsoluteSize.X / math.max(1, f.AbsoluteSize.Y)))
            uiScale.Scale = math.clamp(startScale * (startW + grow) / startW, MIN_SCALE, MAX_SCALE)
        end))
        table.insert(conns, UserInputService.InputEnded:Connect(function(input)
            if dragging and isPointer(input) then
                dragging = false
                Cfg.windowScales[key] = math.floor(uiScale.Scale * 100 + 0.5) / 100
                cfgSave()
            end
        end))
        grip.MouseButton2Click:Connect(function()
            uiScale.Scale = 1
            Cfg.windowScales[key] = nil
            cfgSave()
        end)
        grip.MouseEnter:Connect(function() grip.TextColor3 = PAL.TEXT end)
        grip.MouseLeave:Connect(function() grip.TextColor3 = PAL.DIM end)
        return uiScale
    end
end

local function uiWindow(screenGui, key, title, size, pos)
    local f = make("Frame", {
        Name = key, Size = size, Position = pos, BackgroundColor3 = PAL.PANEL,
        BackgroundTransparency = 0.05, BorderSizePixel = 0, Visible = false, Active = true,
    }, screenGui)
    corner(f, 12)
    stroke(f, PAL.STROKE, 1, 0)
    Theme.addBackdrop(f, 12)
    local shine = make("Frame", {
        Size = UDim2.fromScale(1, 1), BackgroundColor3 = PAL.SHINE, BackgroundTransparency = 0.88,
        BorderSizePixel = 0, Active = false,
    }, f)
    corner(shine, 12)
    make("UIGradient", {
        Rotation = 90,
        Transparency = NumberSequence.new({
            NumberSequenceKeypoint.new(0, 0.22), NumberSequenceKeypoint.new(0.42, 0.58),
            NumberSequenceKeypoint.new(0.78, 0.92), NumberSequenceKeypoint.new(1, 1),
        }),
    }, shine)
    pcall(function() shine.Interactable = false end)

    local bar = make("Frame", { Size = UDim2.new(1, 0, 0, 40), BackgroundTransparency = 1, Active = true }, f)
    label(bar, { Size = UDim2.new(1, -56, 1, 0), Position = UDim2.fromOffset(16, 0), Text = title, Font = Enum.Font.GothamBold, TextSize = 14 })
    local x = make("TextButton", {
        Size = UDim2.fromOffset(28, 28), Position = UDim2.new(1, -36, 0, 6), BackgroundTransparency = 1,
        Text = "X", TextColor3 = PAL.DIM, Font = Enum.Font.GothamBold, TextSize = 14, AutoButtonColor = false,
    }, bar)
    x.MouseButton1Click:Connect(function() f.Visible = false end)
    makeDraggable(bar, f)
    UIAPI.makeResizable(f, key)
    UIAPI.markChrome(f)
    UIAPI.panels[key] = f
    return f
end

local function uiButton(parent, text, size, pos, onClick, danger)
    local b = make("TextButton", {
        Size = size, Position = pos, BackgroundColor3 = danger and Color3.fromRGB(110, 35, 35) or PAL.CARD,
        BackgroundTransparency = 0.2, BorderSizePixel = 0, AutoButtonColor = false,
        Text = text, TextColor3 = PAL.TEXT, Font = Enum.Font.GothamBold, TextSize = 12,
    }, parent)
    corner(b, 8)
    b.MouseEnter:Connect(function() TweenService:Create(b, TweenInfo.new(0.15), { BackgroundTransparency = 0 }):Play() end)
    b.MouseLeave:Connect(function() TweenService:Create(b, TweenInfo.new(0.2), { BackgroundTransparency = 0.2 }):Play() end)
    b.MouseButton1Click:Connect(onClick)
    return b
end

local function uiSwitch(parent, text, pos, width, value, onChange)
    local row = make("Frame", { Size = UDim2.fromOffset(width, 26), Position = pos, BackgroundTransparency = 1 }, parent)
    label(row, { Size = UDim2.new(1, -54, 1, 0), Text = text })
    local pill = make("TextButton", {
        Size = UDim2.fromOffset(44, 22), AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, 0, 0.5, 0),
        BackgroundColor3 = PAL.ELEVATED, BorderSizePixel = 0, AutoButtonColor = false, Text = "",
    }, row)
    corner(pill, 11)
    local knob = make("Frame", {
        Size = UDim2.fromOffset(16, 16), AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, 3, 0.5, 0),
        BackgroundColor3 = PAL.DIM, BorderSizePixel = 0,
    }, pill)
    corner(knob, 8)
    local state = value and true or false
    local obj = {}
    local function paint()
        TweenService:Create(pill, TweenInfo.new(0.15), { BackgroundColor3 = state and PAL.GOOD or PAL.ELEVATED }):Play()
        TweenService:Create(knob, TweenInfo.new(0.15), {
            Position = state and UDim2.new(1, -19, 0.5, 0) or UDim2.new(0, 3, 0.5, 0),
            BackgroundColor3 = state and Color3.new(1, 1, 1) or PAL.DIM,
        }):Play()
    end
    function obj.set(v) state = v and true or false; paint() end
    function obj.get() return state end
    pill.MouseButton1Click:Connect(function()
        state = not state
        paint()
        if onChange then onChange(state) end
    end)
    paint()
    return obj
end

-- o = { min, max, step, value, format(v), onChange(v) }
local function uiSlider(parent, text, pos, width, o)
    local holder = make("Frame", { Size = UDim2.fromOffset(width, 44), Position = pos, BackgroundTransparency = 1 }, parent)
    label(holder, { Size = UDim2.new(1, -70, 0, 18), Text = text })
    local valueLbl = label(holder, {
        Size = UDim2.fromOffset(64, 18), Position = UDim2.new(1, -64, 0, 0),
        TextXAlignment = Enum.TextXAlignment.Right, TextColor3 = PAL.DIM,
    })
    local track = make("Frame", {
        Size = UDim2.new(1, 0, 0, 6), Position = UDim2.fromOffset(0, 28), BackgroundColor3 = PAL.ELEVATED, BorderSizePixel = 0,
    }, holder)
    corner(track, 3)
    local fill = make("Frame", { Size = UDim2.new(0, 0, 1, 0), BackgroundColor3 = PAL.ACCENT, BorderSizePixel = 0 }, track)
    corner(fill, 3)
    local knob = make("Frame", {
        Size = UDim2.fromOffset(14, 14), AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.new(0, 0, 0.5, 0),
        BackgroundColor3 = Color3.new(1, 1, 1), BorderSizePixel = 0, ZIndex = 3,
    }, track)
    corner(knob, 7)
    local hit = make("TextButton", {
        Size = UDim2.new(1, 0, 0, 26), Position = UDim2.fromOffset(0, 18), BackgroundTransparency = 1,
        Text = "", AutoButtonColor = false, ZIndex = 4,
    }, holder)

    local value = o.value
    local obj = {}
    local function show()
        local span = o.max - o.min
        local a = span > 0 and (value - o.min) / span or 0
        a = math.max(0, math.min(1, a))
        fill.Size = UDim2.new(a, 0, 1, 0)
        knob.Position = UDim2.new(a, 0, 0.5, 0)
        valueLbl.Text = o.format and o.format(value) or string.format("%.1f", value)
    end
    local function setValue(v, fire)
        v = math.max(o.min, math.min(o.max, v))
        v = math.floor(v / o.step + 0.5) * o.step
        v = math.max(o.min, math.min(o.max, v))
        value = v
        show()
        if fire and o.onChange then o.onChange(v) end
    end
    function obj.set(v) setValue(v, false) end
    function obj.get() return value end
    function obj.setRange(min, max) o.min, o.max = min, max; setValue(value, false) end

    local dragging = false
    local function fromX(x)
        local w = track.AbsoluteSize.X
        if w <= 0 then return end
        local a = math.max(0, math.min(1, (x - track.AbsolutePosition.X) / w))
        setValue(o.min + (o.max - o.min) * a, true)
    end
    hit.InputBegan:Connect(function(input)
        if isPointer(input) then dragging = true; fromX(input.Position.X) end
    end)
    table.insert(conns, UserInputService.InputChanged:Connect(function(input)
        if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement
            or input.UserInputType == Enum.UserInputType.Touch) then
            fromX(input.Position.X)
        end
    end))
    table.insert(conns, UserInputService.InputEnded:Connect(function(input)
        if isPointer(input) then dragging = false end
    end))
    obj.isDragging = function() return dragging end
    setValue(value, false)
    return obj
end

local function uiBox(parent, pos, size, placeholder, text)
    local c = make("Frame", { Size = size, Position = pos, BackgroundColor3 = PAL.CARD, BackgroundTransparency = 0.2, BorderSizePixel = 0 }, parent)
    corner(c, 8)
    stroke(c, PAL.DIV, 1, 0.3)
    return make("TextBox", {
        Size = UDim2.new(1, -16, 1, 0), Position = UDim2.fromOffset(8, 0), BackgroundTransparency = 1,
        TextColor3 = PAL.TEXT, PlaceholderText = placeholder, PlaceholderColor3 = PAL.DIM,
        Font = Enum.Font.Gotham, TextSize = 12, TextXAlignment = Enum.TextXAlignment.Left,
        Text = text or "", ClearTextOnFocus = false,
    }, c)
end

-- Dropdown: a button showing the current choice; clicking opens a list
-- under it. options is a list of labels or a function returning one (for
-- lists that change). onSelect(index, label) runs when the user picks.
-- The list lives in the ScreenGui so scrolling frames do not clip it.
local openDropdown -- the one list open right now { owner, frame }
local function uiDropdown(parent, prefix, size, pos, options, index, onSelect)
    local obj = { index = index or 1 }
    local function list() return type(options) == "function" and options() or options end
    local b = uiButton(parent, "", size, pos, function() end)
    b.TextXAlignment = Enum.TextXAlignment.Left
    make("UIPadding", { PaddingLeft = UDim.new(0, 10), PaddingRight = UDim.new(0, 22) }, b)
    local arrow = label(b, { Size = UDim2.fromOffset(16, 16), AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, 16, 0.5, 0),
        Text = "▾", TextXAlignment = Enum.TextXAlignment.Center, TextColor3 = PAL.DIM, TextSize = 12 })
    local function show()
        local l = list()
        b.Text = (prefix or "") .. tostring(l[obj.index] or "-")
    end
    function obj.set(i) obj.index = i or 1; show() end
    function obj.get() return obj.index end
    function obj.value() return list()[obj.index] end
    obj.refresh = show
    obj.button = b

    local function close()
        if openDropdown and openDropdown.owner == obj then
            openDropdown.frame:Destroy()
            openDropdown = nil
        end
    end
    obj.close = close

    b.MouseButton1Click:Connect(function()
        if openDropdown then
            local same = openDropdown.owner == obj
            openDropdown.frame:Destroy()
            openDropdown = nil
            if same then return end
        end
        local sg = b:FindFirstAncestorOfClass("ScreenGui")
        if not sg then return end
        local l = list()
        local rowH, maxRows = 26, 7
        local h = math.min(#l, maxRows) * rowH + 6
        local abs, base = b.AbsolutePosition, sg.AbsolutePosition
        local below = abs.Y + b.AbsoluteSize.Y + 4
        local y = below - base.Y
        if below + h > sg.AbsoluteSize.Y + base.Y then y = abs.Y - h - 4 - base.Y end -- not enough room: open upwards
        -- a click anywhere outside the list lands on this and closes it (mouse and touch)
        local holder = make("Frame", { Name = "PuppyAdminDropdown", Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, ZIndex = 199 }, sg)
        local catcher = make("TextButton", {
            Size = UDim2.new(1, 0, 1, 120), Position = UDim2.fromOffset(0, -60), BackgroundTransparency = 1,
            Text = "", AutoButtonColor = false, ZIndex = 199,
        }, holder)
        local frame = make("ScrollingFrame", {
            Name = "List", Size = UDim2.fromOffset(math.max(120, b.AbsoluteSize.X), h),
            Position = UDim2.fromOffset(abs.X - base.X, y), BackgroundColor3 = PAL.PANEL, BackgroundTransparency = 0.02,
            BorderSizePixel = 0, ZIndex = 200, ScrollBarThickness = 3, ScrollBarImageColor3 = PAL.DIM,
            CanvasSize = UDim2.fromOffset(0, #l * rowH + 6), Active = true,
        }, holder)
        corner(frame, 8)
        stroke(frame, PAL.STROKE, 1, 0)
        make("UIPadding", { PaddingTop = UDim.new(0, 3), PaddingLeft = UDim.new(0, 3), PaddingRight = UDim.new(0, 3) }, frame)
        make("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder }, frame)
        for i, text in ipairs(l) do
            local item = make("TextButton", {
                Size = UDim2.new(1, -4, 0, rowH), BackgroundColor3 = i == obj.index and PAL.ELEVATED or PAL.CARD,
                BackgroundTransparency = i == obj.index and 0 or 1, BorderSizePixel = 0, AutoButtonColor = false, ZIndex = 201,
                Text = tostring(text), TextColor3 = i == obj.index and PAL.TEXT or PAL.DIM, Font = Enum.Font.GothamSemibold,
                TextSize = 12, TextXAlignment = Enum.TextXAlignment.Left, LayoutOrder = i,
            }, frame)
            corner(item, 6)
            make("UIPadding", { PaddingLeft = UDim.new(0, 8) }, item)
            item.MouseEnter:Connect(function() item.BackgroundTransparency = 0; item.TextColor3 = PAL.TEXT end)
            item.MouseLeave:Connect(function()
                if i ~= obj.index then item.BackgroundTransparency = 1; item.TextColor3 = PAL.DIM end
            end)
            item.MouseButton1Click:Connect(function()
                obj.index = i
                show()
                close()
                if onSelect then onSelect(i, text) end
            end)
        end
        if obj.index > maxRows then frame.CanvasPosition = Vector2.new(0, (obj.index - maxRows) * rowH) end
        openDropdown = { owner = obj, frame = holder }
        catcher.MouseButton1Click:Connect(close)
        catcher.MouseButton2Click:Connect(close)
    end)
    -- the list closes when its button disappears (window closed, tab switched)
    b:GetPropertyChangedSignal("AbsolutePosition"):Connect(close)
    b.AncestryChanged:Connect(close)
    show()
    return obj
end

-- Escape closes the open list
table.insert(conns, UserInputService.InputBegan:Connect(function(input)
    if openDropdown and input.KeyCode == Enum.KeyCode.Escape then
        openDropdown.frame:Destroy()
        openDropdown = nil
    end
end))

------------------------------------------------------------------------
-- Orbit / tail / wings panels
------------------------------------------------------------------------

local buildToolsPanel, buildMovementPanel, buildEspPanel, buildFloorPanel, scrollBody, sectionTitle
do
------------------------------------------------------------------------
-- Tools panel: orbit, tail and wings in one window (opened with `tools`)
------------------------------------------------------------------------

local function countRole(match)
    local n = 0
    for _, s in ipairs(slots) do
        if match[s.role] then n = n + 1 end
    end
    return n
end

local AXIS_ORDER = { "-z", "z", "y", "-y", "x", "-x" }

-- Scrolling body under a window's title bar; returns the frame and an add(height) helper.
function scrollBody(f, topY)
    f:SetAttribute("PuppyAdminScrollBody", true)
    local body = make("ScrollingFrame", {
        Size = UDim2.new(1, -8, 1, -(topY + 8)), Position = UDim2.fromOffset(4, topY), BackgroundTransparency = 1,
        BorderSizePixel = 0, ScrollBarThickness = 3, ScrollBarImageColor3 = PAL.DIM, CanvasSize = UDim2.new(0, 0, 0, 0),
    }, f)
    local y = 4
    local function add(h)
        local at = y
        y = y + h
        body.CanvasSize = UDim2.fromOffset(0, y + 8)
        return at
    end
    return body, add
end

function sectionTitle(parent, add, text)
    local y = add(28)
    label(parent, { Position = UDim2.fromOffset(12, y + 6), Size = UDim2.new(1, -24, 0, 18), Text = text, Font = Enum.Font.GothamBold, TextSize = 14 })
    make("Frame", { Position = UDim2.fromOffset(12, y + 26), Size = UDim2.new(1, -24, 0, 1), BackgroundColor3 = PAL.DIV, BorderSizePixel = 0 }, parent)
end

function buildToolsPanel(screenGui)
    local W, HGT = 340, 560
    local f = uiWindow(screenGui, "tools", "Tools", UDim2.fromOffset(W, HGT), UDim2.new(0, 20, 0.5, -HGT / 2))
    local body, add = scrollBody(f, 42)
    local IW = W - 40
    local syncers = {}
    local function slider(text, o, get)
        local s = uiSlider(body, text, UDim2.fromOffset(12, add(48)), IW, o)
        table.insert(syncers, function() if not s.isDragging() then s.set(get()) end end)
        return s
    end
    local function switch(text, get, onChange)
        local s = uiSwitch(body, text, UDim2.fromOffset(12, add(32)), IW, get(), onChange)
        table.insert(syncers, function() s.set(get()) end)
        return s
    end
    local function fmt1(v) return string.format("%.1f", v) end
    local function fmtStill(v) return v == 0 and "still" or string.format("%.1f", v) end

    switch("Tools system (lets orbit/tail/wings move your tools)", function() return S.enabled end, function(on) S.setEnabled(on) end)
    local status = label(body, { Position = UDim2.fromOffset(12, add(22)), Size = UDim2.new(1, -24, 0, 18), TextColor3 = PAL.DIM, TextSize = 11 })
    local by = add(36)
    uiButton(body, "Equip all", UDim2.new(0.5, -18, 0, 28), UDim2.fromOffset(12, by), function() H.equip(); UIAPI.sync() end)
    uiButton(body, "Unequip all", UDim2.new(0.5, -18, 0, 28), UDim2.new(0.5, 6, 0, by), function() H.unequip(); UIAPI.sync() end)

    sectionTitle(body, add, "Orbit")
    switch("Enabled", function() return S.orbitOn end, function(on) setLayout("orbit", on) end)
    slider("Speed", { min = -15, max = 15, step = 0.5, value = S.speed, format = fmt1,
        onChange = function(v) S.speed = (v < 0.5 and v > -0.5) and ((v >= 0) and 0.5 or -0.5) or v end },
        function() return S.speed end)
    slider("Radius", { min = 1, max = 30, step = 0.5, value = S.offset, format = fmt1,
        onChange = function(v) S.offset = v end }, function() return S.offset end)
    slider("Pattern", { min = 1, max = 30, step = 1, value = S.mode, format = function(v) return tostring(math.floor(v)) end,
        onChange = function(v) S.mode = math.floor(v) end }, function() return S.mode end)
    slider("Tool spin", { min = 0, max = 10, step = 0.5, value = S.toolRotSpeed, format = fmt1,
        onChange = function(v) S.toolRotSpeed = v end }, function() return S.toolRotSpeed end)
    slider("Smoothness", { min = 0.5, max = 30, step = 0.5, value = S.lerpOrbit, format = fmt1,
        onChange = function(v) S.lerpOrbit = v end }, function() return S.lerpOrbit end)

    sectionTitle(body, add, "Tail")
    switch("Enabled", function() return S.tailOn end, function(on) setLayout("tail", on) end)
    slider("Wag speed", { min = 0, max = 12, step = 0.5, value = S.tail.wagSpeed, format = fmtStill,
        onChange = function(v) S.tail.wagSpeed = v end }, function() return S.tail.wagSpeed end)
    slider("Length", { min = 1, max = 20, step = 0.5, value = S.tail.length, format = fmt1,
        onChange = function(v) S.tail.length = v end }, function() return S.tail.length end)
    slider("Curl", { min = -90, max = 180, step = 5, value = S.tail.curlDeg, format = function(v) return string.format("%d deg", v) end,
        onChange = function(v) S.tail.curlDeg = v end }, function() return S.tail.curlDeg end)
    local sy = add(36)
    -- auto, then 1 .. number of tools
    local function tailChoices()
        local l = { "auto" }
        for i = 1, math.max(1, #slots) do l[#l + 1] = tostring(i) end
        return l
    end
    local splitDd = uiDropdown(body, "Tail tools when combined: ", UDim2.new(1, -24, 0, 28), UDim2.fromOffset(12, sy), tailChoices, 1, function(i)
        S.tailCount = i > 1 and (i - 1) or nil
        assignRoles()
        UIAPI.sync()
    end)
    table.insert(syncers, function() splitDd.set(S.tailCount and (S.tailCount + 1) or 1) end)

    sectionTitle(body, add, "Wings")
    switch("Enabled", function() return S.wingsOn end, function(on) setLayout("wings", on) end)
    slider("Flap speed", { min = 0, max = 12, step = 0.5, value = S.wing.flapSpeed, format = fmtStill,
        onChange = function(v) S.wing.flapSpeed = v end }, function() return S.wing.flapSpeed end)
    slider("Span", { min = 1, max = 20, step = 0.5, value = S.wing.span, format = fmt1,
        onChange = function(v) S.wing.span = v end }, function() return S.wing.span end)
    slider("Spread", { min = 10, max = 180, step = 5, value = S.wing.spreadDeg, format = function(v) return string.format("%d deg", v) end,
        onChange = function(v) S.wing.spreadDeg = v end }, function() return S.wing.spreadDeg end)
    slider("Flap range", { min = 0, max = 60, step = 1, value = S.wing.flapAmp, format = function(v) return string.format("%d deg", v) end,
        onChange = function(v) S.wing.flapAmp = v end }, function() return S.wing.flapAmp end)

    sectionTitle(body, add, "Shared")
    slider("Tail/wings smoothness", { min = 1, max = 40, step = 1, value = S.lerpShape, format = fmt1,
        onChange = function(v) S.lerpShape = v end }, function() return S.lerpShape end)
    slider("Netless velocity", { min = 0, max = 400, step = 5, value = SETTINGS.VelocityY, format = function(v) return string.format("%d", v) end,
        onChange = function(v) SETTINGS.VelocityY = v end }, function() return SETTINGS.VelocityY end)
    local ay = add(36)
    local axisDd = uiDropdown(body, "Handle axis: ", UDim2.new(1, -24, 0, 28), UDim2.fromOffset(12, ay), AXIS_ORDER,
        table.find(AXIS_ORDER, S.axis) or 1, function(i)
            S.axis = AXIS_ORDER[i]
            UIAPI.sync()
        end)
    table.insert(syncers, function() axisDd.set(table.find(AXIS_ORDER, S.axis) or 1) end)
    local ty = add(36)
    local targetBox = uiBox(body, UDim2.fromOffset(12, ty), UDim2.new(1, -170, 0, 28), "Player to wear them on")
    uiButton(body, "Target", UDim2.fromOffset(66, 28), UDim2.new(1, -152, 0, ty), function()
        if targetBox.Text ~= "" then H.target({ targetBox.Text }) end
    end)
    uiButton(body, "Self", UDim2.fromOffset(66, 28), UDim2.new(1, -80, 0, ty), function() H.unorbit() end)

    UIAPI.syncFns.tools = function()
        if not f.Visible then return end
        status.Text = string.format("Tools: %d   orbit %d   tail %d   wings %d", #slots,
            countRole({ orbit = true }), countRole({ tail = true }), countRole({ wingR = true, wingL = true }))
        for _, fn in ipairs(syncers) do pcall(fn) end
    end
    f:GetPropertyChangedSignal("Visible"):Connect(function() if f.Visible then UIAPI.syncFns.tools() end end)
end

------------------------------------------------------------------------
-- Movement panel (fly modes, speed, noclip, airwalk, swim)
------------------------------------------------------------------------

function buildMovementPanel(screenGui)
    local W, HGT = 300, 360
    local f = uiWindow(screenGui, "move", "Movement", UDim2.fromOffset(W, HGT), UDim2.new(0.5, -W - 20, 0.5, -HGT / 2))
    local body, add = scrollBody(f, 42)
    local IW = W - 40
    local syncers = {}
    local function switch(text, get, onChange)
        local s = uiSwitch(body, text, UDim2.fromOffset(12, add(32)), IW, get(), onChange)
        table.insert(syncers, function() s.set(get()) end)
    end
    sectionTitle(body, add, "Flight")
    local S = Pup.state
    switch("Fly", function() return S.flying() and not S.superfly() and not S.on("helicopter") end, function(on) H[on and "fly" or "unfly"]({}) end)
    switch("Superfly (hold the mouse to fly)", function() return S.superfly() end, function(on) UIAPI.superflySet(on) end)
    switch("Helicopter", function() return S.on("helicopter") end, function(on) H[on and "helicopter" or "unhelicopter"]({}) end)
    switch("HatFly", function() return S.on("hatfly") end, function(on) H[on and "hatfly" or "unhatfly"]({}) end)
    local sp = uiSlider(body, "Fly speed", UDim2.fromOffset(12, add(48)), IW, {
        min = 0.5, max = 20, step = 0.5, value = S.flySpeed(), format = function(v) return string.format("%.1f", v) end,
        onChange = function(v) S.setFlySpeed(v) end,
    })
    table.insert(syncers, function() if not sp.isDragging() then sp.set(S.flySpeed()) end end)
    sectionTitle(body, add, "Body")
    switch("Noclip", function() return S.noclip() end, function(on) H[on and "noclip" or "unnoclip"]({}) end)
    switch("Airwalk (Space to rise)", function() return S.on("airwalk") end, function(on) H[on and "airwalk" or "unairwalk"]({}) end)
    switch("Swim", function() return S.swimming() end, function(on) H[on and "swim" or "unswim"]({}) end)
    UIAPI.syncFns.move = function()
        if not f.Visible then return end
        for _, fn in ipairs(syncers) do pcall(fn) end
    end
    f:GetPropertyChangedSignal("Visible"):Connect(function() if f.Visible then UIAPI.syncFns.move() end end)
end

------------------------------------------------------------------------
-- Superfly window (`superfly`). The flight is the engine's (sFLY with its
-- superfly mode: hold the left mouse button / the screen to fly where the
-- camera looks); this window replaces the engine's own Superfly panel, which
-- is built with UI kits the engine does not include. The engine finds it
-- through the same hooks it used for its panel (_G._flyPanel,
-- _G._flyToggleSet, _G._flySlider, _G._pupPanelEnable.superfly).
------------------------------------------------------------------------

function UIAPI.superflySet(on)
    if not Pup.boot() then return end
    UIAPI.hookSuperfly()
    if not on then
        Pup.run("unsuperfly", {})
        return
    end
    Pup.active.superfly = true
    task.spawn(function()
        local L = Pup.pupL
        local ok, err = pcall(function()
            L.NOFLY()
            task.wait()
            L.sFLY()
            if _G._pupSuperflyStart then _G._pupSuperflyStart() end
        end)
        if ok then
            note("Superfly", UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled
                and "On: hold the screen to fly" or "On: hold the left mouse button to fly")
        else
            note("Superfly", tostring(err):sub(1, 80), RED)
        end
        if _G._pupMarkCmdToggle then pcall(_G._pupMarkCmdToggle, "superfly", ok) end
        UIAPI.sync()
    end)
end

function UIAPI.hookSuperfly()
    if not Pup.booted then return end
    local function panel() return UIAPI.panels.superfly end
    _G._initFlyPanel = function() _G._flyPanel = panel() end
    -- a half-built engine panel (from an earlier failed open) goes away
    local ours = rawget(UIAPI.panels, "superfly")
    if _G._flyPanel and _G._flyPanel ~= ours then
        pcall(function() if _G._flyPanel.Name == "SuperflyPanel" then _G._flyPanel:Destroy() end end)
    end
    _G._flyPanel = ours
    -- the engine calls this when superfly stops (unsuperfly, unfly, death): only show it
    _G._flyToggleSet = function(on, fire)
        if UIAPI.superflySwitch then UIAPI.superflySwitch.set(on) end
        if fire and on and not Pup.state.superfly() then UIAPI.superflySet(true) end
        if not on then Pup.active.superfly = nil end
    end
    _G._flySlider = { setValue = function(v)
        local sl = UIAPI.superflySlider
        if sl and not sl.isDragging() then sl.set(tonumber(v) or 1) end
    end }
    _G._pupPanelEnable = _G._pupPanelEnable or {}
    _G._pupPanelEnable.superfly = {
        ensure = function()
            local p = panel()
            _G._flyPanel = p
            if p then p.Visible = true; UIAPI.sync() end
        end,
        setOn = function(on, fire) _G._flyToggleSet(on, fire ~= false) end,
    }
end

function UIAPI.buildSuperflyPanel(screenGui)
    local W, HGT = 300, 214
    local f = uiWindow(screenGui, "superfly", "Superfly", UDim2.fromOffset(W, HGT), UDim2.new(0.5, 30, 0.5, -HGT / 2))
    local touch = UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled
    label(f, {
        Position = UDim2.fromOffset(16, 44), Size = UDim2.fromOffset(W - 32, 58), TextWrapped = true, TextSize = 12,
        TextYAlignment = Enum.TextYAlignment.Top, TextColor3 = PAL.DIM,
        Text = touch and "Turn it on, then hold the screen to fly where the camera looks. Let go to hover."
            or "Turn it on, then hold the left mouse button to fly where the camera looks. W A S D, Space and Ctrl steer too; let go to hover.",
    })
    local S = Pup.state
    UIAPI.superflySwitch = uiSwitch(f, "Superfly", UDim2.fromOffset(16, 106), W - 32, S.superfly(), function(on)
        UIAPI.superflySet(on)
    end)
    UIAPI.superflySlider = uiSlider(f, "Speed", UDim2.fromOffset(16, 144), W - 32, {
        min = 0.5, max = 20, step = 0.5, value = S.flySpeed(), format = function(v) return string.format("%.1f", v) end,
        onChange = function(v) S.setFlySpeed(v) end,
    })
    UIAPI.syncFns.superfly = function()
        if not f.Visible then return end
        UIAPI.superflySwitch.set(S.superfly())
        if not UIAPI.superflySlider.isDragging() then UIAPI.superflySlider.set(S.flySpeed()) end
    end
    f:GetPropertyChangedSignal("Visible"):Connect(function() if f.Visible then UIAPI.syncFns.superfly() end end)
    _G._flyPanel = f
end

------------------------------------------------------------------------
-- ESP panel
------------------------------------------------------------------------

function buildEspPanel(screenGui)
    local W, HGT = 300, 420
    local f = uiWindow(screenGui, "esp", "ESP", UDim2.fromOffset(W, HGT), UDim2.new(0, 380, 0.5, -HGT / 2))
    local body, add = scrollBody(f, 42)
    local IW = W - 40
    local syncers = {}
    local function switch(text, get, onChange)
        local s = uiSwitch(body, text, UDim2.fromOffset(12, add(32)), IW, get(), onChange)
        table.insert(syncers, function() s.set(get()) end)
    end
    switch("ESP (names, health, distance)", function() return Esp.mode == "esp" end, function(on)
        Esp.setMode(on and "esp" or (Esp.mode == "esp" and "off" or Esp.mode)); UIAPI.sync()
    end)
    switch("Chams", function() return Esp.mode == "chams" end, function(on)
        Esp.setMode(on and "chams" or (Esp.mode == "chams" and "off" or Esp.mode)); UIAPI.sync()
    end)
    switch("Hitboxes", function() return Esp.hitboxes end, function(on) Esp.setHitboxes(on) end)
    switch("Tracers", function() return Esp.tracers end, function(on) Esp.setTracers(on) end)
    switch("Team colors", function() return Esp.teamColor end, function(on) Esp.teamColor = on; Esp.refresh() end)
    sectionTitle(body, add, "Hide teams")
    local teamY = add(0)
    local teamHolder = make("Frame", { Position = UDim2.fromOffset(0, teamY), Size = UDim2.new(1, 0, 0, 0), BackgroundTransparency = 1 }, body)
    local function rebuildTeams()
        for _, c in ipairs(teamHolder:GetChildren()) do pcall(function() c:Destroy() end) end
        local names = {}
        local ok, teams = pcall(function() return game:GetService("Teams"):GetTeams() end)
        if ok then for _, t in ipairs(teams) do table.insert(names, { t.Name, t.Name }) end end
        table.insert(names, { "__none", "No team" })
        local y = 0
        for _, pair in ipairs(names) do
            local key = pair[1]
            uiSwitch(teamHolder, pair[2], UDim2.fromOffset(12, y), IW, Esp.hidden[key] == true, function(on)
                Esp.hidden[key] = on or nil
                Esp.refresh()
            end)
            y = y + 32
        end
        teamHolder.Size = UDim2.new(1, 0, 0, y)
        body.CanvasSize = UDim2.fromOffset(0, teamY + y + 8)
    end
    UIAPI.syncFns.esp = function()
        if not f.Visible then return end
        for _, fn in ipairs(syncers) do pcall(fn) end
    end
    f:GetPropertyChangedSignal("Visible"):Connect(function()
        if f.Visible then rebuildTeams(); UIAPI.syncFns.esp() end
    end)
end

------------------------------------------------------------------------
-- Infinite baseplate panel
------------------------------------------------------------------------

function buildFloorPanel(screenGui)
    local W, HGT = 300, 316
    local f = uiWindow(screenGui, "floor", "Infinite baseplate", UDim2.fromOffset(W, HGT), UDim2.new(0.5, 20, 0.5, -HGT / 2))
    local IW = W - 32
    local sw = uiSwitch(f, "Enabled", UDim2.fromOffset(16, 48), IW, Baseplate.enabled, function(on)
        H[on and "infbaseplate" or "uninfbaseplate"]({ "quiet" })
    end)
    local presetNames = {}
    for i, p in ipairs(BASEPLATE_PRESETS) do presetNames[i] = p.name end
    local presetDd = uiDropdown(f, "Look: ", UDim2.fromOffset(IW, 28), UDim2.fromOffset(16, 86), function()
        local l = {}
        for i, n in ipairs(presetNames) do l[i] = n end
        if Baseplate.kind == "texture" and not (BASEPLATE_PRESETS[Baseplate.presetIndex] or {}).texture then l[Baseplate.presetIndex] = "Custom texture" end
        return l
    end, Baseplate.presetIndex, function(i)
        Baseplate.usePreset(i)
        UIAPI.sync()
    end)
    local studs = uiSlider(f, "Texture tile size", UDim2.fromOffset(16, 124), IW, {
        min = 2, max = 64, step = 1, value = Baseplate.studs, format = function(v) return string.format("%d studs", v) end,
        onChange = function(v) Baseplate.studs = v; if Baseplate.kind == "texture" then bpApplyAll() end end,
    })
    local box = uiBox(f, UDim2.fromOffset(16, 180), UDim2.new(1, -112, 0, 28), "Texture id, rbxasset or image URL")
    uiButton(f, "Apply", UDim2.fromOffset(72, 28), UDim2.new(1, -88, 0, 180), function()
        local ok, err = Baseplate.useCustom(box.Text)
        note("Baseplate", ok and "Custom texture applied" or tostring(err), ok and LIGHT or RED)
        UIAPI.sync()
    end)
    local colorBox = uiBox(f, UDim2.fromOffset(16, 216), UDim2.new(1, -112, 0, 28), "Colour (material looks): name, #hex or r,g,b")
    uiButton(f, "Colour", UDim2.fromOffset(72, 28), UDim2.new(1, -88, 0, 216), function()
        local r, g, b = parseColorArgs(splitArgs((colorBox.Text:gsub(",%s+", ","))), 1)
        if not r then note("Baseplate", "Colour: a name, #hex or r,g,b", RED); return end
        Baseplate.setColor(Color3.fromRGB(r, g, b))
        note("Baseplate", "Floor colour set", LIGHT)
    end)
    label(f, { Position = UDim2.fromOffset(16, 254), Size = UDim2.new(1, -32, 0, 48), TextWrapped = true, TextSize = 11, TextColor3 = PAL.DIM,
        TextYAlignment = Enum.TextYAlignment.Top,
        Text = "Tiles spawn around you at the height of the floor you stood on when it was enabled. Only you see them. The colour tints grass, wood, metal and the other materials." })
    UIAPI.syncFns.floor = function()
        if not f.Visible then return end
        sw.set(Baseplate.enabled)
        presetDd.set(Baseplate.presetIndex)
        local c = Baseplate.color or Color3.new(1, 1, 1)
        if not colorBox:IsFocused() then colorBox.Text = string.format("%d,%d,%d", math.floor(c.R * 255 + 0.5), math.floor(c.G * 255 + 0.5), math.floor(c.B * 255 + 0.5)) end
        if not studs.isDragging() then studs.set(Baseplate.studs) end
    end
    f:GetPropertyChangedSignal("Visible"):Connect(function() if f.Visible then UIAPI.syncFns.floor() end end)
end
end


------------------------------------------------------------------------
-- Nametag editor (`tagui`) and tag list (`taglist`); allowlisted accounts only
------------------------------------------------------------------------

local TAG_FONTS = { "GothamBold", "Gotham", "GothamSemibold", "Code", "Arcade", "SourceSansBold", "FredokaOne", "Bangers", "SciFi", "Fantasy" }
local PFP_MODES = { { "none", "No picture" }, { "avatar", "Their avatar" }, { "custom", "Custom image" } }

local function tagGuard()
    if canEditTags() then return true end
    note("Tags", "Not authorized to edit nametags", RED)
    return false
end

local function rgbText(c)
    c = type(c) == "table" and c or { 255, 255, 255 }
    return string.format("%d,%d,%d", c[1] or 255, c[2] or 255, c[3] or 255)
end

local function parseRGB(text)
    local r, g, b = parseColorArgs(splitArgs((tostring(text):gsub(",%s+", ","))), 1)
    if r then return { r, g, b } end
    return nil
end

local function buildTagPanel(screenGui)
    local W, HGT = 380, 600
    local f = uiWindow(screenGui, "tags", "Nametag editor", UDim2.fromOffset(W, HGT), UDim2.new(0.5, -W / 2, 0.5, -HGT / 2))
    local body, add = scrollBody(f, 42)
    local IW = W - 40
    local fontIdx, pfpIdx = 1, 1

    local tagLbl = label(body, { Position = UDim2.fromOffset(12, add(24)), Size = UDim2.new(1, -24, 0, 20), Text = "Tag: new", TextColor3 = PAL.DIM })
    local nameBox = uiBox(body, UDim2.fromOffset(12, add(34)), UDim2.fromOffset(IW, 28), "Tag name (shown in taglist)")
    local textBox = uiBox(body, UDim2.fromOffset(12, add(34)), UDim2.fromOffset(IW, 28), "Tag text (max 40)")
    local subBox = uiBox(body, UDim2.fromOffset(12, add(34)), UDim2.fromOffset(IW, 28), "Subtitle (optional)")
    local colorBox = uiBox(body, UDim2.fromOffset(12, add(34)), UDim2.fromOffset(IW, 28), "Text color: name, #hex, r,g,b", "255,255,255")
    local rainbowSw = uiSwitch(body, "Rainbow text", UDim2.fromOffset(12, add(32)), IW, false, function() end)
    local sizeSl = uiSlider(body, "Text size", UDim2.fromOffset(12, add(48)), IW, {
        min = 8, max = 48, step = 1, value = 22, format = function(v) return string.format("%d", v) end,
    })
    local offSl = uiSlider(body, "Height above head", UDim2.fromOffset(12, add(48)), IW, {
        min = 0, max = 12, step = 0.5, value = 3, format = function(v) return string.format("%.1f", v) end,
    })
    local fontDd = uiDropdown(body, "Font: ", UDim2.fromOffset(IW, 28), UDim2.fromOffset(12, add(36)), TAG_FONTS, 1, function(i)
        fontIdx = i
    end)

    sectionTitle(body, add, "Backdrop")
    local bdSw = uiSwitch(body, "Show backdrop", UDim2.fromOffset(12, add(32)), IW, false, function() end)
    local bdColorBox = uiBox(body, UDim2.fromOffset(12, add(34)), UDim2.fromOffset(IW, 28), "Backdrop color: name, #hex, r,g,b", "18,18,22")
    local bdAlphaSl = uiSlider(body, "Backdrop transparency", UDim2.fromOffset(12, add(48)), IW, {
        min = 0, max = 1, step = 0.05, value = 0.35, format = function(v) return string.format("%.2f", v) end,
    })
    local bdImageBox = uiBox(body, UDim2.fromOffset(12, add(34)), UDim2.fromOffset(IW, 28), "Backdrop image: id, rbxassetid or image URL (optional)")
    local bdImgAlphaSl = uiSlider(body, "Image transparency", UDim2.fromOffset(12, add(48)), IW, {
        min = 0, max = 1, step = 0.05, value = 0.15, format = function(v) return string.format("%.2f", v) end,
    })
    local bdRoundSw = uiSwitch(body, "Rounded corners", UDim2.fromOffset(12, add(32)), IW, true, function() end)

    sectionTitle(body, add, "Profile picture")
    local pfpLabels = {}
    for i, m in ipairs(PFP_MODES) do pfpLabels[i] = m[2] end
    local pfpDd = uiDropdown(body, "Picture: ", UDim2.fromOffset(IW, 28), UDim2.fromOffset(12, add(36)), pfpLabels, 1, function(i)
        pfpIdx = i
    end)
    local pfpImageBox = uiBox(body, UDim2.fromOffset(12, add(34)), UDim2.fromOffset(IW, 28), "Custom picture: id, rbxassetid or image URL")
    local pfpRoundSw = uiSwitch(body, "Round picture", UDim2.fromOffset(12, add(32)), IW, true, function() end)

    sectionTitle(body, add, "Clicking")
    local clickSw = uiSwitch(body, "Click a tag to teleport (not your own)", UDim2.fromOffset(12, add(32)), IW, Cfg.tagClickTp, function(on)
        Cfg.tagClickTp = on
        cfgSave()
        Tags.refreshAll()
    end)

    local function load(def)
        Tags.ui.current = def
        local d = def or Tags.normalize({ name = "" })
        tagLbl.Text = (def and def.isDefault and "Default tag: script users without a custom tag")
            or (def and ("Tag: " .. def.name .. "  (" .. #def.members .. " members)")) or "Tag: new (Save creates it)"
        nameBox.Text = def and def.name or ""
        textBox.Text = d.text or ""
        subBox.Text = d.sub or ""
        colorBox.Text = rgbText(d.color)
        rainbowSw.set(d.rainbow == true)
        sizeSl.set(tonumber(d.size) or 22)
        offSl.set(tonumber(d.offset) or 3)
        fontIdx = table.find(TAG_FONTS, d.font) or 1
        fontDd.set(fontIdx)
        bdSw.set(d.backdrop.on == true)
        bdColorBox.Text = rgbText(d.backdrop.color)
        bdAlphaSl.set(tonumber(d.backdrop.transparency) or 0.35)
        bdImageBox.Text = d.backdrop.image or ""
        bdImgAlphaSl.set(tonumber(d.backdrop.imageTransparency) or 0.15)
        bdRoundSw.set(d.backdrop.round ~= false)
        pfpIdx = 1
        for i, m in ipairs(PFP_MODES) do if m[1] == d.pfp.mode then pfpIdx = i end end
        pfpDd.set(pfpIdx)
        pfpImageBox.Text = d.pfp.image or ""
        pfpRoundSw.set(d.pfp.round ~= false)
        clickSw.set(Cfg.tagClickTp == true)
    end
    UIAPI.tagEditorLoad = load

    local y = add(44)
    uiButton(body, "Save tag", UDim2.fromOffset((IW - 8) / 2, 32), UDim2.fromOffset(12, y), function()
        if not tagGuard() then return end
        local text = textBox.Text:sub(1, 40)
        if text == "" then note("Tags", "Enter the tag text", RED); return end
        local color, bdColor = parseRGB(colorBox.Text), parseRGB(bdColorBox.Text)
        if not color then note("Tags", "Text color: name, #hex, r,g,b", RED); return end
        if not bdColor then note("Tags", "Backdrop color: name, #hex, r,g,b", RED); return end
        local mode = PFP_MODES[pfpIdx][1]
        if mode == "custom" and pfpImageBox.Text:match("^%s*$") then note("Tags", "Enter a custom picture or pick another mode", RED); return end
        local def = Tags.ui.current
        local wanted = nameBox.Text:match("^%s*(.-)%s*$"):sub(1, 30)
        if def and def.isDefault then
            def, wanted = Tags.ensureDefault(), "Default"
        else
            if wanted == "" then wanted = text end
            local clash = Tags.findDef(wanted)
            if clash and clash ~= def then note("Tags", "Another tag is already called '" .. wanted .. "'", RED); return end
            if not def then def = Tags.newDef(wanted) end
        end
        def.name, def.text, def.sub = wanted, text, subBox.Text:sub(1, 40)
        def.color, def.rainbow, def.size, def.offset, def.font = color, rainbowSw.get(), sizeSl.get(), offSl.get(), TAG_FONTS[fontIdx]
        def.backdrop = {
            on = bdSw.get(), color = bdColor, transparency = bdAlphaSl.get(), image = bdImageBox.Text:match("^%s*(.-)%s*$"),
            imageTransparency = bdImgAlphaSl.get(), round = bdRoundSw.get(),
        }
        def.pfp = { mode = mode, image = pfpImageBox.Text:match("^%s*(.-)%s*$"), round = pfpRoundSw.get() }
        Tags.save()
        if def.isDefault then Tags.refreshAll() else for _, uid in ipairs(def.members) do Tags.refresh(uid) end end
        load(def)
        if UIAPI.syncFns.taglist then UIAPI.syncFns.taglist() end
        note("Tags", "Saved '" .. def.name .. "'" .. ((not def.isDefault and #def.members == 0) and " - add players in taglist" or ""), LIGHT)
    end)
    uiButton(body, "Members...", UDim2.fromOffset((IW - 8) / 2, 32), UDim2.fromOffset(12 + (IW + 8) / 2, y), function()
        local p = UIAPI.panels.taglist -- builds it if needed (sets tagListSelect)
        if UIAPI.tagListSelect then UIAPI.tagListSelect(Tags.ui.current) end
        if p then p.Visible = true end
    end)
    y = add(40)
    uiButton(body, "New tag", UDim2.fromOffset((IW - 8) / 2, 32), UDim2.fromOffset(12, y), function() load(nil) end)
    uiButton(body, "Delete tag", UDim2.fromOffset((IW - 8) / 2, 32), UDim2.fromOffset(12 + (IW + 8) / 2, y), function()
        if not tagGuard() then return end
        local def = Tags.ui.current
        if not def then note("Tags", "Nothing saved yet"); return end
        Tags.deleteDef(def)
        load(nil)
        if UIAPI.syncFns.taglist then UIAPI.syncFns.taglist() end
        note("Tags", def.isDefault and "Default tag reset to the built-in look" or ("Deleted '" .. def.name .. "'"))
    end, true)

    f:GetPropertyChangedSignal("Visible"):Connect(function()
        if f.Visible then
            if not canEditTags() then f.Visible = false; return end
            local cur = Tags.ui.current
            if cur and cur ~= Tags.builtinDefault and not table.find(Cfg.tagDefs, cur) then load(nil) end
        end
    end)
    load(nil)
end

local function buildTagListPanel(screenGui)
    local W, HGT = 400, 600
    local f = uiWindow(screenGui, "taglist", "Tags", UDim2.fromOffset(W, HGT), UDim2.new(0.5, 30, 0.5, -HGT / 2))
    local IW = W - 32
    local picked = {}   -- UserId -> true, players ticked in the server list

    local function list(y, h)
        local s = make("ScrollingFrame", {
            Size = UDim2.fromOffset(IW, h), Position = UDim2.fromOffset(16, y), BackgroundColor3 = PAL.CARD,
            BackgroundTransparency = 0.4, BorderSizePixel = 0, ScrollBarThickness = 2, ScrollBarImageColor3 = PAL.DIM,
            CanvasSize = UDim2.new(0, 0, 0, 0), AutomaticCanvasSize = Enum.AutomaticSize.Y,
        }, f)
        corner(s, 8)
        make("UIListLayout", { Padding = UDim.new(0, 3), SortOrder = Enum.SortOrder.LayoutOrder }, s)
        make("UIPadding", { PaddingTop = UDim.new(0, 3), PaddingLeft = UDim.new(0, 3) }, s)
        return s
    end
    local function clear(s)
        for _, c in ipairs(s:GetChildren()) do
            if c:IsA("GuiObject") then c:Destroy() end
        end
    end
    local function row(parent, text, order, selected, onClick, side)
        local b = make("TextButton", {
            Size = UDim2.new(1, -6, 0, 26), BackgroundColor3 = selected and PAL.ELEVATED or PAL.CARD,
            BackgroundTransparency = 0.2, BorderSizePixel = 0, AutoButtonColor = false, LayoutOrder = order,
            Text = text, TextColor3 = PAL.TEXT, Font = Enum.Font.Gotham, TextSize = 12,
            TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd,
        }, parent)
        corner(b, 6)
        make("UIPadding", { PaddingLeft = UDim.new(0, 8), PaddingRight = UDim.new(0, side and 34 or 8) }, b)
        if onClick then b.MouseButton1Click:Connect(onClick) end
        if side then
            local x = make("TextButton", {
                Size = UDim2.fromOffset(26, 22), AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, 30, 0.5, 0),
                BackgroundTransparency = 1, Text = side.text, TextColor3 = side.color or PAL.DIM,
                Font = Enum.Font.GothamBold, TextSize = 13, AutoButtonColor = false,
            }, b)
            x.MouseButton1Click:Connect(side.fn)
        end
        return b
    end

    label(f, { Position = UDim2.fromOffset(16, 44), Size = UDim2.new(1, -32, 0, 16), Text = "All tags", TextColor3 = PAL.DIM })
    local tagsList = list(62, 120)
    local selLbl = label(f, { Position = UDim2.fromOffset(16, 188), Size = UDim2.new(1, -32, 0, 16), Text = "Members", TextColor3 = PAL.DIM })
    local memberList = list(206, 120)
    label(f, { Position = UDim2.fromOffset(16, 332), Size = UDim2.new(1, -32, 0, 16), Text = "Players in this server (tick, then Add ticked)", TextColor3 = PAL.DIM })
    local playerList = list(350, 120)
    local userBox = uiBox(f, UDim2.fromOffset(16, 478), UDim2.fromOffset(IW - 78, 28), "Names or UserIds, comma separated")

    local refresh
    local function select(def)
        Tags.ui.current = def
        refresh()
    end
    UIAPI.tagListSelect = select

    refresh = function()
        local cur = Tags.ui.current
        if cur and cur ~= Tags.builtinDefault and not table.find(Cfg.tagDefs, cur) then cur = nil; Tags.ui.current = nil end
        clear(tagsList)
        local dflt = Tags.defaultDef() or Tags.builtinDefault
        row(tagsList, "* Default tag   \"" .. (dflt.text or "") .. "\"   script users without a custom tag", 0, cur == dflt,
            function() select(dflt) end)
        local custom = 0
        for i, def in ipairs(Cfg.tagDefs) do
            if not def.isDefault then
                custom = custom + 1
                row(tagsList, def.name .. "   \"" .. (def.text or "") .. "\"   " .. #def.members .. " member" .. (#def.members == 1 and "" or "s"),
                    i, def == cur, function() select(def) end)
            end
        end
        if custom == 0 then row(tagsList, "No custom tags yet - press New tag", 1000, false, nil) end
        clear(memberList)
        selLbl.Text = cur and ("Members of '" .. cur.name .. "'") or "Members (pick a tag above)"
        if cur and cur.isDefault then
            local n = 0
            for _, p in ipairs(Players:GetPlayers()) do
                if not Tags.byUser[tostring(p.UserId)] and Presence and Presence.isActive(p.UserId) then
                    n = n + 1
                    row(memberList, Tags.memberName(p.UserId) .. "   (running the script)", n, false, nil)
                end
            end
            if n == 0 then row(memberList, "Shown on script users here without a custom tag", 1, false, nil) end
        elseif cur then
            if #cur.members == 0 then row(memberList, "Nobody yet - add players below", 1, false, nil) end
            for i, uid in ipairs(cur.members) do
                row(memberList, Tags.memberName(uid), i, false, nil, {
                    text = "X", color = RED, fn = function()
                        if not tagGuard() then return end
                        Tags.removeMember(cur, uid)
                        refresh()
                    end,
                })
            end
        end
        clear(playerList)
        for i, p in ipairs(Players:GetPlayers()) do
            local other = Tags.byUser[tostring(p.UserId)]
            local text = (picked[p.UserId] and "[x]  " or "[  ]  ") .. p.DisplayName .. "  (@" .. p.Name .. ")"
                .. (other and ("   - " .. other.name) or "")
            row(playerList, text, i, picked[p.UserId] == true, function()
                picked[p.UserId] = not picked[p.UserId] or nil
                refresh()
            end)
        end
    end

    local function addTo(uids, missing)
        local cur = Tags.ui.current
        if not cur then note("Tags", "Pick a tag first", RED); return end
        if cur.isDefault then note("Tags", "The default tag goes on script users by itself - pick a custom tag", RED); return end
        if #uids == 0 then note("Tags", "Nobody to add" .. (#missing > 0 and (": not found " .. table.concat(missing, ", ")) or ""), RED); return end
        local n = Tags.addMembers(cur, uids)
        note("Tags", "Added " .. n .. " to '" .. cur.name .. "'" .. (#missing > 0 and ("; not found: " .. table.concat(missing, ", ")) or ""), LIGHT)
        refresh()
    end

    uiButton(f, "Add", UDim2.fromOffset(70, 28), UDim2.fromOffset(16 + IW - 70, 478), function()
        if not tagGuard() then return end
        local text = userBox.Text
        task.spawn(function()
            local uids, missing = Tags.resolveUsers({ text })
            addTo(uids, missing)
            if #uids > 0 then userBox.Text = "" end
        end)
    end)
    local half = (IW - 8) / 2
    uiButton(f, "Add ticked players", UDim2.fromOffset(half, 30), UDim2.fromOffset(16, 514), function()
        if not tagGuard() then return end
        local uids = {}
        for uid in pairs(picked) do table.insert(uids, uid) end
        addTo(uids, {})
        if #uids > 0 then picked = {}; refresh() end
    end)
    uiButton(f, "Edit look...", UDim2.fromOffset(half, 30), UDim2.fromOffset(16 + half + 8, 514), function()
        local p = UIAPI.panels.tags -- builds it if needed (sets tagEditorLoad)
        if UIAPI.tagEditorLoad then UIAPI.tagEditorLoad(Tags.ui.current) end
        if p then p.Visible = true end
    end)
    uiButton(f, "New tag", UDim2.fromOffset(half, 30), UDim2.fromOffset(16, 552), function()
        if not tagGuard() then return end
        select(Tags.newDef("New tag"))
        local p = UIAPI.panels.tags -- builds it if needed (sets tagEditorLoad)
        if UIAPI.tagEditorLoad then UIAPI.tagEditorLoad(Tags.ui.current) end
        if p then p.Visible = true end
    end)
    uiButton(f, "Delete tag", UDim2.fromOffset(half, 30), UDim2.fromOffset(16 + half + 8, 552), function()
        if not tagGuard() then return end
        local cur = Tags.ui.current
        if not cur then note("Tags", "Pick a tag first"); return end
        Tags.deleteDef(cur)
        Tags.ui.current = nil
        refresh()
        note("Tags", cur.isDefault and "Default tag reset to the built-in look" or ("Deleted '" .. cur.name .. "'"))
    end, true)

    UIAPI.syncFns.taglist = function() if f.Visible then refresh() end end
    f:GetPropertyChangedSignal("Visible"):Connect(function()
        if f.Visible then
            if not canEditTags() then f.Visible = false; return end
            refresh()
        end
    end)
    table.insert(conns, Players.PlayerAdded:Connect(function() UIAPI.syncFns.taglist() end))
    table.insert(conns, Players.PlayerRemoving:Connect(function(p) picked[p.UserId] = nil; task.defer(UIAPI.syncFns.taglist) end))
    refresh()
end

------------------------------------------------------------------------
-- Anti VC ban panel (opened with `antivcban`)
------------------------------------------------------------------------

local function buildVcbPanel(screenGui)
    local W, HGT = 300, 236
    local f = uiWindow(screenGui, "vcb", "Anti VC ban", UDim2.fromOffset(W, HGT), UDim2.new(0.5, -W / 2, 0, 80))
    local IW = W - 32
    local status = label(f, { Position = UDim2.fromOffset(16, 46), Size = UDim2.new(1, -32, 0, 18), Text = "", TextColor3 = PAL.DIM })
    label(f, {
        Position = UDim2.fromOffset(16, 68), Size = UDim2.new(1, -32, 0, 44), TextWrapped = true,
        TextYAlignment = Enum.TextYAlignment.Top, TextSize = 12, TextColor3 = PAL.DIM,
        Text = "Unmute your mic and talk into it for about 5 seconds, then press Execute.",
    })
    local exec = uiButton(f, "Execute bypass", UDim2.fromOffset(IW, 34), UDim2.fromOffset(16, 120), function() VCB.run() end)
    local muteSw
    muteSw = uiSwitch(f, "Mute mic", UDim2.fromOffset(16, 166), IW, true, function(on)
        if VCB.state ~= "active" then
            note("Anti VC Ban", "Execute the bypass first")
            task.defer(function() muteSw.set(VCB.muted) end)
            return
        end
        VCB.setMuted(on)
    end)
    label(f, {
        Position = UDim2.fromOffset(16, 198), Size = UDim2.new(1, -32, 0, 28), TextWrapped = true, TextSize = 11,
        TextColor3 = PAL.DIM, Text = "After it is active, the mic button in the top bar also mutes and unmutes.",
    })

    local function sync()
        local s = VCB.state
        status.Text = s == "active" and "Status: bypassed" or (s == "running" and "Status: bypassing..." or "Status: not active")
        exec.Text = s == "active" and "Bypassed" or (s == "running" and "Bypassing..." or "Execute bypass")
        muteSw.set(VCB.muted)
    end
    table.insert(VCB.listeners, sync)
    UIAPI.syncFns.vcb = function() if f.Visible then sync() end end
    sync()
end

------------------------------------------------------------------------
-- Reanimation panel (opened with `reanim`). Built with the script's own UI
-- pieces, so it follows the theme in Settings like every other window. It
-- drives the reanimation engine's state (_G._pup_reanimState): the engine's
-- original panel is still created, hidden, because its logic (library
-- loader, idle/walk/jump loop, recorder, live mode, sync, tricks) runs there.
------------------------------------------------------------------------

local function buildReanimPanel(screenGui)
    local W, HGT = 380, 580
    local f = uiWindow(screenGui, "reanim", "Reanimation", UDim2.fromOffset(W, HGT), UDim2.new(0.5, 30, 0.5, -HGT / 2))
    local IW = W - 40
    local function RS() return _G._pup_reanimState end
    local function call(name, ...)
        local rs = RS()
        local fn = type(rs) == "table" and rs[name]
        if type(fn) ~= "function" then note("Reanim", "Not ready yet - open again in a moment", RED); return nil end
        local ok, res = pcall(fn, ...)
        if not ok then note("Reanim", tostring(res):sub(1, 80), RED) end
        return res
    end
    local function ready() return type(RS()) == "table" end

    local statusLbl = label(f, { Position = UDim2.fromOffset(16, 44), Size = UDim2.new(1, -160, 0, 18), Text = "Starting...", TextColor3 = PAL.DIM })
    local playingLbl = label(f, { Position = UDim2.fromOffset(16, 62), Size = UDim2.new(1, -160, 0, 16), Text = "", TextColor3 = PAL.DIM, TextSize = 11 })
    local power = uiButton(f, "Reanimate", UDim2.fromOffset(128, 30), UDim2.new(1, -144, 0, 44), function()
        if not ready() then note("Reanim", "Not ready yet - open again in a moment", RED); return end
        local rs = RS()
        Pup.setActive(not rs.reanimActive)
    end)

    -- tabs ------------------------------------------------------------------
    local TABS = { "Main", "Library", "States", "Tricks", "Copy" }
    local pages, tabBtns, current = {}, {}, nil
    local tabW = math.floor((W - 32 - 4 * (#TABS - 1)) / #TABS)
    local function showTab(name)
        current = name
        for n, pg in pairs(pages) do pg.Visible = n == name end
        for n, b in pairs(tabBtns) do b.BackgroundColor3 = n == name and PAL.ELEVATED or PAL.CARD end
    end
    for i, name in ipairs(TABS) do
        tabBtns[name] = uiButton(f, name, UDim2.fromOffset(tabW, 26), UDim2.fromOffset(16 + (i - 1) * (tabW + 4), 86), function() showTab(name) end)
        tabBtns[name].TextSize = 11
        pages[name] = make("Frame", {
            Name = name, Position = UDim2.fromOffset(0, 118), Size = UDim2.new(1, 0, 1, -118),
            BackgroundTransparency = 1, Visible = false,
        }, f)
    end
    local syncers = {}
    local function switch(body, add, text, get, set)
        local s = uiSwitch(body, text, UDim2.fromOffset(12, add(32)), IW, false, function(on) if ready() then set(on) end end)
        table.insert(syncers, function() local ok, v = pcall(get); if ok then s.set(v == true) end end)
        return s
    end

    -- Main --------------------------------------------------------------------
    do
        local body, add = scrollBody(pages.Main, 0)
        sectionTitle(body, add, "Playback")
        local y = add(38)
        uiButton(body, "Stop animation", UDim2.fromOffset((IW - 8) / 2, 30), UDim2.fromOffset(12, y), function() call("stopCurrent") end)
        local recBtn = uiButton(body, "Record motion", UDim2.fromOffset((IW - 8) / 2, 30), UDim2.fromOffset(12 + (IW + 8) / 2, y), function() call("toggleRecording") end)
        table.insert(syncers, function() local rs = RS(); recBtn.Text = (rs and rs.recordActive) and "Stop recording" or "Record motion" end)
        switch(body, add, "Pause", function() return RS().reanimPaused end, function(on) call("setPause", on) end)
        switch(body, add, "Reverse", function() return RS().reanimDir == -1 end, function(on) call("setRewind", on) end)
        local speed = uiSlider(body, "Speed", UDim2.fromOffset(12, add(48)), IW, {
            min = 0.1, max = 3, step = 0.1, value = 1, format = function(v) return string.format("%.1fx", v) end,
            onChange = function(v) if ready() then call("setReanimSpeedStep", math.floor(v * 10 + 0.5)) end end,
        })
        table.insert(syncers, function() local rs = RS(); if rs and not speed.isDragging() then speed.set(tonumber(rs.reanimSpeed) or 1) end end)
        switch(body, add, "Smooth transitions", function() return RS().blendOn end, function(on) call("setBlend", on, nil) end)
        sectionTitle(body, add, "Body")
        switch(body, add, "Noclip while reanimated", function() return RS().noclipOn end, function(on) call("setNoclip", on) end)
        switch(body, add, "Live mode (move limbs with the mouse)", function() return RS().liveActive end, function(on)
            local rs = RS()
            if (rs.liveActive == true) ~= on then call("toggleLive") end
        end)
        sectionTitle(body, add, "Play from a link")
        local urlBox = uiBox(body, UDim2.fromOffset(12, add(34)), UDim2.fromOffset(IW - 78, 28), "Keyframe animation URL")
        uiButton(body, "Play", UDim2.fromOffset(70, 28), UDim2.fromOffset(12 + IW - 70, add(0) - 34), function()
            local url = urlBox.Text:match("^%s*(.-)%s*$")
            if not url:match("^https?://") then note("Reanim", "Enter an http(s) link", RED); return end
            local api = pupApi()
            if not (api and Reanim.active) then note("Reanim", "Reanimate first", RED); return end
            task.spawn(function()
                local ok, err = pcall(api.play_animation, url, tonumber(RS() and RS().reanimSpeed) or 1)
                if not ok then note("Reanim", tostring(err):sub(1, 80), RED)
                elseif type(err) == "string" then note("Reanim", err:sub(1, 80), RED) end
            end)
        end)
    end

    -- Library -----------------------------------------------------------------
    local refreshLibrary
    do
        local page = pages.Library
        local source = 1
        local SOURCES = { { "customItems", "Your animations" }, { "favsItems", "Favorites" } }
        local search = uiBox(page, UDim2.fromOffset(16, 0), UDim2.fromOffset(IW - 188, 28), "Search")
        uiButton(page, "Reload files", UDim2.fromOffset(64, 28), UDim2.fromOffset(16 + IW - 180, 0), function()
            task.spawn(function()
                local total, added = Pup.reloadCustom(true)
                note("Reanim", tostring(total or 0) .. " animations in PuppyAdmin/custom" .. ((added or 0) > 0 and (" (" .. added .. " from subfolders)") or ""), LIGHT)
                if refreshLibrary then refreshLibrary(true) end
            end)
        end).TextSize = 10
        local srcLabels = {}
        for i, src in ipairs(SOURCES) do srcLabels[i] = src[2] end
        local srcDd = uiDropdown(page, "", UDim2.fromOffset(112, 28), UDim2.fromOffset(16 + IW - 112, 0), srcLabels, 1, function(i)
            source = i
            refreshLibrary()
        end)
        srcDd.button.TextSize = 11
        local importBox = uiBox(page, UDim2.fromOffset(16, 34), UDim2.fromOffset(IW - 142, 28), "Import: animation/emote ID or keyframe link")
        -- after an import: show Your animations, searched to the new entry
        local function showImported(name)
            source = 1
            srcDd.set(1)
            search.Text = name or ""
            if refreshLibrary then refreshLibrary(true) end
        end
        local function runImport(fn, ...)
            local args = { ... }
            task.spawn(function()
                if not Pup.ensure() then return end
                note("Reanim", "Importing...")
                local ok, name, path = fn(table.unpack(args))
                if not ok then note("Reanim", tostring(name), RED); return end
                note("Reanim", "Imported " .. name .. " - in Your animations", LIGHT)
                local rs = _G._pup_reanimState
                if Reanim.active and type(rs) == "table" and type(rs.playAnim) == "function" then pcall(rs.playAnim, name, path) end
                showImported(name)
            end)
        end
        uiButton(page, "Import", UDim2.fromOffset(62, 28), UDim2.fromOffset(16 + IW - 134, 34), function()
            local raw = importBox.Text
            importBox.Text = ""
            runImport(Pup.importCatalog, raw)
        end)

        -- Paste window: a multi-line box keeps the line breaks of pasted
        -- keyframes (a one-line box joins them, which breaks Lua comments).
        local paste = make("Frame", {
            Name = "PasteKeyframes", Position = UDim2.fromOffset(16, 0), Size = UDim2.new(1, -32, 1, -8),
            BackgroundColor3 = PAL.PANEL, BorderSizePixel = 0, Visible = false, ZIndex = 20,
        }, page)
        corner(paste, 10)
        stroke(paste, PAL.STROKE, 1, 0)
        label(paste, { Position = UDim2.fromOffset(12, 8), Size = UDim2.new(1, -24, 0, 18), Text = "Paste keyframes (Lua table or recorder JSON)",
            Font = Enum.Font.GothamBold, ZIndex = 21 })
        local pasteName = uiBox(paste, UDim2.fromOffset(12, 32), UDim2.new(1, -24, 0, 28), "Name (optional)")
        pasteName.Parent.ZIndex, pasteName.ZIndex = 21, 22
        local scroller = make("ScrollingFrame", {
            Position = UDim2.fromOffset(12, 66), Size = UDim2.new(1, -24, 1, -142), BackgroundColor3 = PAL.CARD,
            BackgroundTransparency = 0.2, BorderSizePixel = 0, ScrollBarThickness = 3, ScrollBarImageColor3 = PAL.DIM,
            CanvasSize = UDim2.new(0, 0, 0, 0), AutomaticCanvasSize = Enum.AutomaticSize.Y, ZIndex = 21,
        }, paste)
        corner(scroller, 8)
        local pasteBox = make("TextBox", {
            Size = UDim2.new(1, -12, 0, 0), Position = UDim2.fromOffset(6, 4), AutomaticSize = Enum.AutomaticSize.Y,
            BackgroundTransparency = 1, MultiLine = true, TextWrapped = true, ClearTextOnFocus = false,
            Text = "", PlaceholderText = "Click here and paste (Ctrl+V)", PlaceholderColor3 = PAL.DIM, TextColor3 = PAL.TEXT,
            Font = Enum.Font.Code, TextSize = 11, TextXAlignment = Enum.TextXAlignment.Left,
            TextYAlignment = Enum.TextYAlignment.Top, ZIndex = 22,
        }, scroller)
        local count = label(paste, { Position = UDim2.new(0, 12, 1, -72), Size = UDim2.new(1, -24, 0, 30), TextWrapped = true,
            Text = "", TextColor3 = PAL.DIM, TextSize = 10, ZIndex = 21, TextYAlignment = Enum.TextYAlignment.Top })
        pasteBox:GetPropertyChangedSignal("Text"):Connect(function()
            count.Text = #pasteBox.Text .. " characters. If a long paste gets cut off, use a link in Import or put the file in PuppyAdmin/custom and press Reload files."
        end)
        local saveB = uiButton(paste, "Save to Your animations", UDim2.new(0.6, -16, 0, 30), UDim2.new(0, 12, 1, -38), function()
            local raw, nm = pasteBox.Text, pasteName.Text
            runImport(function()
                local ok, name, path = Pup.importText(raw, nm)
                if ok then
                    paste.Visible = false
                    pasteBox.Text, pasteName.Text = "", ""
                end
                return ok, name, path
            end)
        end)
        local cancelB = uiButton(paste, "Cancel", UDim2.new(0.4, -12, 0, 30), UDim2.new(0.6, 0, 1, -38), function() paste.Visible = false end)
        for _, b in ipairs({ saveB, cancelB }) do b.ZIndex = 22 end
        uiButton(page, "Paste", UDim2.fromOffset(64, 28), UDim2.fromOffset(16 + IW - 64, 34), function()
            paste.Visible = true
            count.Text = "Paste Lua keyframes (like recorder files) or recorder JSON, then Save."
        end)
        local hint = label(page, { Position = UDim2.fromOffset(16, 66), Size = UDim2.new(1, -32, 0, 14), TextSize = 10, TextColor3 = PAL.DIM,
            Text = "Click to play.  Right-click or ... for more." })
        local list = make("ScrollingFrame", {
            Position = UDim2.fromOffset(16, 84), Size = UDim2.new(1, -32, 1, -92), BackgroundColor3 = PAL.CARD,
            BackgroundTransparency = 0.4, BorderSizePixel = 0, ScrollBarThickness = 2, ScrollBarImageColor3 = PAL.DIM,
            CanvasSize = UDim2.new(0, 0, 0, 0), AutomaticCanvasSize = Enum.AutomaticSize.Y,
        }, page)
        corner(list, 8)
        make("UIListLayout", { Padding = UDim.new(0, 3), SortOrder = Enum.SortOrder.LayoutOrder }, list)
        make("UIPadding", { PaddingTop = UDim.new(0, 3), PaddingLeft = UDim.new(0, 3) }, list)
        local MAX_ROWS = 150
        local lastSig
        local function LAYOUT() local L = _G._pup_reanimLayout; return type(L) == "table" and L or nil end
        local function titleOf(name)
            local L = LAYOUT()
            if L and type(L.title) == "function" then
                local ok, t = pcall(L.title, name)
                if ok and type(t) == "string" and t ~= "" then return t end
            end
            return name
        end
        local function inList(list, item)
            for _, it in ipairs(list or {}) do if it == item or (it.url == item.url and it.name == item.name) then return true end end
            return false
        end
        local function favSlotOf(name)
            local rs = RS()
            for k, b in pairs(rs and rs.favKeybinds or {}) do
                if type(b) == "table" and b.name == name then return k end
            end
            return nil
        end
        local function setState(slot, item)
            local L, rs = LAYOUT(), RS()
            if L and type(L.assignState) == "function" then
                pcall(L.assignState, slot, item)
            elseif rs and type(rs.stateAnims) == "table" then
                local prev = rs.stateAnims[slot]
                rs.stateAnims[slot] = (prev and prev.name == item.name) and nil or { name = item.name, url = item.url }
                call("saveStateAnims")
                call("startStateLoop")
            end
            for _, fn in ipairs(syncers) do pcall(fn) end
        end

        -- Right-click menu (and the ... button): the same actions as the
        -- original panel's - play/stop, favourites, key, rename, reset name,
        -- use for idle/walk/jump, delete file.
        local catcher = make("TextButton", {
            Name = "MenuCatcher", Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, Text = "",
            AutoButtonColor = false, Visible = false, ZIndex = 60,
        }, f)
        local menu = make("Frame", {
            Name = "RowMenu", Size = UDim2.fromOffset(220, 0), BackgroundColor3 = PAL.PANEL, BorderSizePixel = 0,
            Visible = false, ZIndex = 61, AutomaticSize = Enum.AutomaticSize.Y,
        }, f)
        corner(menu, 10)
        stroke(menu, PAL.STROKE, 1, 0)
        make("UIListLayout", { Padding = UDim.new(0, 2), SortOrder = Enum.SortOrder.LayoutOrder }, menu)
        make("UIPadding", { PaddingTop = UDim.new(0, 6), PaddingBottom = UDim.new(0, 6), PaddingLeft = UDim.new(0, 6), PaddingRight = UDim.new(0, 6) }, menu)
        local keyConn
        local function closeMenu()
            if keyConn then keyConn:Disconnect(); keyConn = nil end
            menu.Visible, catcher.Visible = false, false
        end
        catcher.MouseButton1Click:Connect(closeMenu)
        catcher.MouseButton2Click:Connect(closeMenu)
        local function menuRow(order, text, right, danger, onClick)
            local b = make("TextButton", {
                Size = UDim2.new(1, 0, 0, 28), BackgroundColor3 = danger and Color3.fromRGB(110, 35, 35) or PAL.CARD,
                BackgroundTransparency = danger and 0.3 or 1, BorderSizePixel = 0, AutoButtonColor = false, LayoutOrder = order,
                Text = text, TextColor3 = PAL.TEXT, Font = Enum.Font.GothamSemibold, TextSize = 12,
                TextXAlignment = Enum.TextXAlignment.Left, ZIndex = 62,
            }, menu)
            corner(b, 6)
            make("UIPadding", { PaddingLeft = UDim.new(0, 10), PaddingRight = UDim.new(0, 10) }, b)
            local r
            if right then
                r = label(b, { Size = UDim2.fromScale(1, 1), Text = right, TextColor3 = PAL.DIM, TextSize = 11,
                    TextXAlignment = Enum.TextXAlignment.Right, ZIndex = 63 })
            end
            b.MouseEnter:Connect(function() if not danger then b.BackgroundTransparency = 0.2 end end)
            b.MouseLeave:Connect(function() if not danger then b.BackgroundTransparency = 1 end end)
            b.MouseButton1Click:Connect(function() onClick(b, r) end)
            return b
        end
        local function rule(order)
            make("Frame", { Size = UDim2.new(1, 0, 0, 1), BackgroundColor3 = PAL.DIV, BorderSizePixel = 0, LayoutOrder = order, ZIndex = 62 }, menu)
        end
        local function placeMenu(anchor)
            local fp, fs = f.AbsolutePosition, f.AbsoluteSize
            local mouse = UserInputService:GetMouseLocation() - game:GetService("GuiService"):GetGuiInset()
            local x = math.clamp(mouse.X - fp.X, 8, math.max(8, fs.X - 228))
            local y = math.clamp(mouse.Y - fp.Y, 40, math.max(40, fs.Y - menu.AbsoluteSize.Y - 8))
            if anchor and (mouse.X < fp.X or mouse.X > fp.X + fs.X) then
                x = math.clamp(anchor.AbsolutePosition.X - fp.X + anchor.AbsoluteSize.X - 220, 8, fs.X - 228)
            end
            menu.Position = UDim2.fromOffset(x, y)
        end
        local function openMenu(item, anchor)
            local rs, L = RS(), LAYOUT()
            if not rs then return end
            for _, c in ipairs(menu:GetChildren()) do if c:IsA("GuiObject") then c:Destroy() end end
            local playing = rs.reanimCurrentName == item.name
            local o = 0
            local function nextO() o = o + 1; return o end
            menuRow(nextO(), playing and "Stop" or "Play", nil, false, function()
                closeMenu()
                if playing then call("stopCurrent") else call("playAnim", item.name, item.url) end
                task.delay(0.3, function() refreshLibrary(true) end)
            end)
            if L and type(L.toggleFav) == "function" then
                local fav = type(L.isFav) == "function" and L.isFav(item.name)
                menuRow(nextO(), fav and "Remove from favorites" or "Add to favorites", nil, false, function()
                    closeMenu()
                    pcall(L.toggleFav, item)
                    task.delay(0.1, function() refreshLibrary(true) end)
                end)
            end
            local slot = favSlotOf(item.name)
            menuRow(nextO(), "Set key", slot or "None", false, function(_, r)
                if r then r.Text = "Press a key"; r.TextColor3 = PAL.TEXT end
                if keyConn then keyConn:Disconnect() end
                keyConn = UserInputService.InputBegan:Connect(function(inp, gp)
                    if gp or inp.UserInputType ~= Enum.UserInputType.Keyboard then return end
                    local kc = inp.KeyCode
                    if kc == Enum.KeyCode.Unknown then return end
                    local binds = rs.favKeybinds
                    if type(binds) ~= "table" then closeMenu(); return end
                    if kc == Enum.KeyCode.Escape then closeMenu(); return end
                    local prev = favSlotOf(item.name)
                    if kc == Enum.KeyCode.Backspace or kc == Enum.KeyCode.Delete then
                        if prev then binds[prev] = nil end
                        call("saveReanimKeybinds")
                        note("Reanim", titleOf(item.name):sub(1, 24) .. " unbound")
                        closeMenu()
                        return
                    end
                    local owner = L and type(L.speedOwner) == "function" and L.speedOwner(kc.Name)
                    if owner then note("Reanim", kc.Name .. " is already used by " .. tostring(owner) .. ". Pick another key.", RED); return end
                    if prev then binds[prev] = nil end
                    local was = binds[kc.Name]
                    binds[kc.Name] = { name = item.name, url = item.url }
                    call("saveReanimKeybinds")
                    note("Reanim", titleOf(item.name):sub(1, 24) .. " - " .. kc.Name
                        .. ((was and was.name ~= item.name) and (" (was " .. titleOf(was.name):sub(1, 18) .. ")") or ""), LIGHT)
                    closeMenu()
                end)
            end)
            if L and type(L.setTitle) == "function" then
                menuRow(nextO(), "Rename", nil, false, function(b)
                    for _, c in ipairs(b:GetChildren()) do if c:IsA("GuiObject") then c:Destroy() end end
                    b.Text = ""
                    local box = make("TextBox", {
                        Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, Text = titleOf(item.name),
                        PlaceholderText = item.name, ClearTextOnFocus = false, TextColor3 = PAL.TEXT, PlaceholderColor3 = PAL.DIM,
                        Font = Enum.Font.GothamSemibold, TextSize = 12, TextXAlignment = Enum.TextXAlignment.Left, ZIndex = 63,
                    }, b)
                    box.FocusLost:Connect(function(enter)
                        if enter then
                            local text = box.Text:sub(1, 40)
                            pcall(L.setTitle, item.name, text ~= "" and text or nil)
                            note("Reanim", "Renamed to " .. titleOf(item.name):sub(1, 24), LIGHT)
                            refreshLibrary(true)
                        end
                        closeMenu()
                    end)
                    task.defer(function() box:CaptureFocus() end)
                end)
                if type(L.titles) == "table" and L.titles[item.name] then
                    menuRow(nextO(), "Reset name", nil, false, function()
                        closeMenu()
                        pcall(L.setTitle, item.name, nil)
                        note("Reanim", "Name reset to " .. item.name:sub(1, 24))
                        refreshLibrary(true)
                    end)
                end
            end
            rule(nextO())
            for _, slotName in ipairs({ "idle", "walk", "jump" }) do
                local cur = rs.stateAnims and rs.stateAnims[slotName]
                local on = cur ~= nil and cur.name == item.name
                menuRow(nextO(), (on and "Stop using for " or "Use for ") .. slotName, nil, false, function()
                    closeMenu()
                    setState(slotName, item)
                end)
            end
            if inList(rs.customItems, item) and L and type(L.deleteCustom) == "function" then
                rule(nextO())
                menuRow(nextO(), "Delete file", nil, true, function()
                    closeMenu()
                    pcall(L.deleteCustom, item)
                    task.delay(0.1, function() refreshLibrary(true) end)
                end)
            end
            catcher.Visible, menu.Visible = true, true
            task.defer(function() placeMenu(anchor) end)
        end

        refreshLibrary = function(force)
            local rs = RS()
            local items = type(rs) == "table" and rs[SOURCES[source][1]] or {}
            local q = search.Text:lower()
            local sig = SOURCES[source][1] .. "|" .. q .. "|" .. #items .. "|" .. tostring(rs and rs.reanimCurrentName)
            if sig == lastSig and not force then return end
            lastSig = sig
            for _, c in ipairs(list:GetChildren()) do if c:IsA("GuiObject") then c:Destroy() end end
            local shown = 0
            for _, item in ipairs(items) do
                local shownName = (type(item) == "table" and type(item.name) == "string") and titleOf(item.name) or nil
                if shownName and not item.isHeader
                    and (q == "" or item.name:lower():find(q, 1, true) or shownName:lower():find(q, 1, true)) then
                    shown = shown + 1
                    if shown > MAX_ROWS then break end
                    local playing = rs.reanimCurrentName == item.name
                    local key = favSlotOf(item.name)
                    local row = make("TextButton", {
                        Size = UDim2.new(1, -6, 0, 26), BackgroundColor3 = playing and PAL.ELEVATED or PAL.CARD,
                        BackgroundTransparency = 0.2, BorderSizePixel = 0, AutoButtonColor = false, LayoutOrder = shown,
                        Text = shownName, TextColor3 = playing and PAL.ACCENT or PAL.TEXT, Font = Enum.Font.Gotham, TextSize = 12,
                        TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd,
                    }, list)
                    corner(row, 6)
                    make("UIPadding", { PaddingLeft = UDim.new(0, 8), PaddingRight = UDim.new(0, key and 74 or 36) }, row)
                    row.MouseButton1Click:Connect(function()
                        if rs.reanimCurrentName == item.name then call("stopCurrent") else call("playAnim", item.name, item.url) end
                        task.delay(0.3, function() refreshLibrary(true) end)
                    end)
                    row.MouseButton2Click:Connect(function() openMenu(item, row) end)
                    if key then
                        label(row, { Size = UDim2.new(0, 36, 1, 0), Position = UDim2.new(1, 4, 0, 0), Text = key,
                            TextColor3 = PAL.ACCENT, TextSize = 10, TextXAlignment = Enum.TextXAlignment.Right })
                    end
                    local more = make("TextButton", {
                        Size = UDim2.fromOffset(26, 20), AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, 32, 0.5, 0),
                        BackgroundColor3 = PAL.ELEVATED, BackgroundTransparency = 0.2, BorderSizePixel = 0, AutoButtonColor = false,
                        Text = "...", TextColor3 = PAL.DIM, Font = Enum.Font.GothamBold, TextSize = 12,
                    }, row)
                    corner(more, 5)
                    more.MouseButton1Click:Connect(function() openMenu(item, more) end)
                end
            end
            if shown == 0 then
                label(list, { Size = UDim2.new(1, -6, 0, 40), TextWrapped = true, TextSize = 12, LayoutOrder = 1, TextColor3 = PAL.DIM,
                    Text = (#items == 0 and (source == 1 and "No animations yet. Import an ID or link above, or put .lua / .txt / .json keyframe files in your executor's workspace/PuppyAdmin/custom and press Reload files."
                        or "No favourites yet. Right-click one of your animations > Add to favorites.") or "Nothing matches") })
            end
            hint.Text = (shown > MAX_ROWS and ("Showing the first " .. MAX_ROWS .. " - search to narrow.  ") or "")
                .. "Click to play.  Right-click or ... for more."
        end
        search:GetPropertyChangedSignal("Text"):Connect(function() refreshLibrary() end)
        table.insert(syncers, function() refreshLibrary() end)
    end

    -- States ------------------------------------------------------------------
    do
        local body, add = scrollBody(pages.States, 0)
        sectionTitle(body, add, "Played by themselves while reanimated")
        for _, slot in ipairs({ "idle", "walk", "jump" }) do
            local y = add(36)
            local lbl = label(body, { Position = UDim2.fromOffset(12, y), Size = UDim2.fromOffset(IW - 80, 28), Text = "" })
            uiButton(body, "Clear", UDim2.fromOffset(70, 28), UDim2.fromOffset(12 + IW - 70, y), function()
                local rs = RS()
                if not rs then return end
                rs.stateAnims[slot] = nil
                call("saveStateAnims")
                call("startStateLoop")
            end)
            table.insert(syncers, function()
                local rs = RS()
                local a = rs and rs.stateAnims and rs.stateAnims[slot]
                lbl.Text = slot:sub(1, 1):upper() .. slot:sub(2) .. ":  " .. (a and a.name or "none")
            end)
        end
        label(body, { Position = UDim2.fromOffset(12, add(40)), Size = UDim2.fromOffset(IW, 36), TextWrapped = true, TextSize = 11,
            TextColor3 = PAL.DIM, Text = "Pick them in Library: right-click an animation (or ...) > Use for idle / walk / jump. Anything you play yourself takes over until you stop it." })
    end

    -- Tricks ------------------------------------------------------------------
    do
        local body, add = scrollBody(pages.Tricks, 0)
        local held = {}
        local function trick(text, field, setter)
            switch(body, add, text, function() local v = RS()[field]; if v == nil then return held[setter] end return v end,
                function(on) held[setter] = on; call(setter, on) end)
        end
        sectionTitle(body, add, "Body tricks (reanimated)")
        trick("Lean torso with the camera", "torsoOn", "setTorso")
        trick("Free head (looks where you look)", "headFree", "setHeadFree")
        trick("Flying limbs", "flyOn", "setFly")
        trick("Long legs", "legsOn", "setLegs")
        trick("Spider", "spiderOn", "setSpider")
    end

    -- Copy --------------------------------------------------------------------
    do
        local body, add = scrollBody(pages.Copy, 0)
        sectionTitle(body, add, "Copy another player")
        local who = uiBox(body, UDim2.fromOffset(12, add(36)), UDim2.fromOffset(IW, 28), "Player name or display name")
        local function target()
            for _, p in ipairs(resolveTargets(who.Text)) do
                if p ~= plr then return p end
            end
            note("Reanim", "No player matches", RED)
            return nil
        end
        local y = add(38)
        uiButton(body, "Sync to them", UDim2.fromOffset((IW - 8) / 2, 30), UDim2.fromOffset(12, y), function()
            local p = target()
            if p then call("setSyncTarget", p); call("startSync") end
        end)
        uiButton(body, "Stop sync", UDim2.fromOffset((IW - 8) / 2, 30), UDim2.fromOffset(12 + (IW + 8) / 2, y), function()
            call("stopSync", "Sync off")
        end)
        y = add(38)
        uiButton(body, "Mimic them", UDim2.fromOffset((IW - 8) / 2, 30), UDim2.fromOffset(12, y), function()
            local p, api = target(), pupApi()
            if p and api and api.mimic_start then local ok, err = pcall(api.mimic_start, p); if not ok then note("Reanim", tostring(err):sub(1, 80), RED) end end
        end)
        uiButton(body, "Stop mimic", UDim2.fromOffset((IW - 8) / 2, 30), UDim2.fromOffset(12 + (IW + 8) / 2, y), function()
            local api = pupApi()
            if api and api.mimic_stop then pcall(api.mimic_stop, "Mimic off") end
        end)
        local copyLbl = label(body, { Position = UDim2.fromOffset(12, add(24)), Size = UDim2.fromOffset(IW, 20), Text = "", TextColor3 = PAL.DIM, TextSize = 11 })
        sectionTitle(body, add, "Record their animation")
        y = add(38)
        uiButton(body, "Record them", UDim2.fromOffset((IW - 8) / 2, 30), UDim2.fromOffset(12, y), function()
            local p = target()
            if not p then return end
            local ok, err = Pup.startCopy(p)
            if ok then note("Reanim", "Recording " .. p.DisplayName .. " (up to 1 minute)", LIGHT) else note("Reanim", err, RED) end
        end)
        uiButton(body, "Stop & save", UDim2.fromOffset((IW - 8) / 2, 30), UDim2.fromOffset(12 + (IW + 8) / 2, y), function()
            if not Pup.stopCopy() then note("Reanim", "Not recording anyone") end
        end)
        local recLbl = label(body, { Position = UDim2.fromOffset(12, add(24)), Size = UDim2.fromOffset(IW, 20), Text = "", TextColor3 = PAL.DIM, TextSize = 11 })
        table.insert(syncers, function()
            local s = Pup.copyRec
            recLbl.Text = (s and s.active) and string.format("Recording %s - %ds", s.player.DisplayName, math.floor(s.elapsed or 0))
                or "Saved recordings go to Library > Your animations"
        end)
        label(body, { Position = UDim2.fromOffset(12, add(44)), Size = UDim2.fromOffset(IW, 40), TextWrapped = true, TextSize = 11,
            TextColor3 = PAL.DIM, Text = "Sync plays their current moves on your reanimated body. Mimic follows their movement and pose." })
        table.insert(syncers, function()
            local rs, api = RS(), pupApi()
            local syncing = rs and type(rs.isSyncing) == "function" and rs.isSyncing()
            local mimic = api and api.mimic_active and api.mimic_active()
            copyLbl.Text = "Sync: " .. (syncing and ("on" .. (rs.syncTarget and (" - " .. rs.syncTarget.DisplayName) or "")) or "off")
                .. "    Mimic: " .. (mimic and "on" or "off")
        end)
    end

    -- status ------------------------------------------------------------------
    local function sync()
        local rs = RS()
        if type(rs) ~= "table" then
            statusLbl.Text = Pup.failed and ("Unavailable: " .. Pup.failed:sub(1, 40)) or "Starting..."
            return
        end
        local active = rs.reanimActive == true
        statusLbl.Text = active and "Status: reanimated" or "Status: not reanimated"
        playingLbl.Text = rs.reanimCurrentName and ("Playing: " .. tostring(rs.reanimCurrentName)) or ""
        power.Text = active and "Stop reanim" or "Reanimate"
        for _, fn in ipairs(syncers) do pcall(fn) end
    end
    UIAPI.syncFns.reanim = function() if f.Visible then sync() end end
    f:GetPropertyChangedSignal("Visible"):Connect(function()
        if not f.Visible then return end
        task.spawn(function()
            Pup.ensure()
            if typeof(_G._reanimPanel) == "Instance" then _G._reanimPanel.Visible = false end
            pupLoadApi()
            pcall(Pup.reloadCustom)
            if refreshLibrary then pcall(refreshLibrary, true) end
            while f.Visible and genv.PuppyAdminActive do
                pcall(sync)
                task.wait(0.5)
            end
        end)
    end)
    showTab("Main")
end

------------------------------------------------------------------------
-- Owner panel (`owner`): moderation, auras and the tag tools in one window
------------------------------------------------------------------------

local function buildOwnerPanel(screenGui)
    local W, HGT = 380, 600
    local f = uiWindow(screenGui, "owner", "Owner", UDim2.fromOffset(W, HGT), UDim2.new(0.5, -W / 2, 0.5, -HGT / 2))
    local body, add = scrollBody(f, 42)
    local IW = W - 40
    local half = (IW - 8) / 2

    sectionTitle(body, add, "Players")
    local who = uiBox(body, UDim2.fromOffset(12, add(34)), UDim2.fromOffset(IW, 28), "Players: names, UserIds, all, others (commas)")
    local reason = uiBox(body, UDim2.fromOffset(12, add(34)), UDim2.fromOffset(IW, 28), "Reason (optional)")

    sectionTitle(body, add, "Moderation")
    local y = add(38)
    uiButton(body, "Kick", UDim2.fromOffset(half, 30), UDim2.fromOffset(12, y), function()
        H.kick({ who.Text, reason.Text ~= "" and reason.Text or nil })
    end)
    uiButton(body, "Ban from script", UDim2.fromOffset(half, 30), UDim2.fromOffset(12 + half + 8, y), function()
        H.ban({ who.Text, reason.Text ~= "" and reason.Text or nil })
    end, true)
    y = add(38)
    uiButton(body, "Unban", UDim2.fromOffset(half, 30), UDim2.fromOffset(12, y), function() H.unban({ who.Text }) end)
    uiButton(body, "Refresh", UDim2.fromOffset(half, 30), UDim2.fromOffset(12 + half + 8, y), function()
        task.spawn(function() Moderation.pull(true) end)
    end)
    y = add(38)
    uiButton(body, "Blacklist menu", UDim2.fromOffset(IW, 30), UDim2.fromOffset(12, y), function() H.blacklist() end)
    local status = label(body, { Position = UDim2.fromOffset(12, add(22)), Size = UDim2.fromOffset(IW, 18), Text = "", TextColor3 = PAL.DIM, TextSize = 11 })
    local banList = make("ScrollingFrame", {
        Position = UDim2.fromOffset(12, add(128)), Size = UDim2.fromOffset(IW, 120), BackgroundColor3 = PAL.CARD,
        BackgroundTransparency = 0.4, BorderSizePixel = 0, ScrollBarThickness = 2, ScrollBarImageColor3 = PAL.DIM,
        CanvasSize = UDim2.new(0, 0, 0, 0), AutomaticCanvasSize = Enum.AutomaticSize.Y,
    }, body)
    corner(banList, 8)
    make("UIListLayout", { Padding = UDim.new(0, 3), SortOrder = Enum.SortOrder.LayoutOrder }, banList)
    make("UIPadding", { PaddingTop = UDim.new(0, 3), PaddingLeft = UDim.new(0, 3) }, banList)

    sectionTitle(body, add, "Auras")
    local auraIdx = 1
    uiDropdown(body, "Aura: ", UDim2.fromOffset(IW, 28), UDim2.fromOffset(12, add(36)), function() return Aura.order end, 1, function(i)
        auraIdx = i
    end)
    y = add(38)
    uiButton(body, "Give aura", UDim2.fromOffset(half, 30), UDim2.fromOffset(12, y), function()
        H.aura({ Aura.order[auraIdx], who.Text ~= "" and who.Text or "me" })
    end)
    uiButton(body, "Take aura", UDim2.fromOffset(half, 30), UDim2.fromOffset(12 + half + 8, y), function()
        H.unaura({ Aura.order[auraIdx], who.Text ~= "" and who.Text or "me" })
    end)

    sectionTitle(body, add, "Tags")
    y = add(38)
    uiButton(body, "Tag editor", UDim2.fromOffset(half, 30), UDim2.fromOffset(12, y), function() UIAPI.togglePanel("tags") end)
    uiButton(body, "Tag list", UDim2.fromOffset(half, 30), UDim2.fromOffset(12 + half + 8, y), function() H.taglist({}) end)
    local syncLbl = label(body, { Position = UDim2.fromOffset(12, add(36)), Size = UDim2.fromOffset(IW, 32), Text = "", TextWrapped = true,
        TextColor3 = PAL.DIM, TextSize = 11, TextYAlignment = Enum.TextYAlignment.Top })

    local function refresh()
        status.Text = "Moderation: " .. tostring(Moderation.status)
        syncLbl.Text = "Repo writes: " .. (TagSync.token() and "token saved" or "no token (Settings > Tag sync)")
            .. "   Tags: " .. tostring(TagSync.status) .. "   Auras: " .. tostring(AuraSync.status)
        for _, c in ipairs(banList:GetChildren()) do if c:IsA("GuiObject") then c:Destroy() end end
        local n = 0
        for _, e in ipairs(Moderation.entries) do
            if e.type == "ban" then
                n = n + 1
                local row = make("TextButton", {
                    Size = UDim2.new(1, -6, 0, 26), BackgroundColor3 = PAL.CARD, BackgroundTransparency = 0.2, BorderSizePixel = 0,
                    AutoButtonColor = false, LayoutOrder = n, Text = Tags.memberName(e.userId) .. (e.reason ~= "" and ("  -  " .. e.reason) or ""),
                    TextColor3 = PAL.TEXT, Font = Enum.Font.Gotham, TextSize = 12, TextXAlignment = Enum.TextXAlignment.Left,
                    TextTruncate = Enum.TextTruncate.AtEnd,
                }, banList)
                corner(row, 6)
                make("UIPadding", { PaddingLeft = UDim.new(0, 8), PaddingRight = UDim.new(0, 70) }, row)
                local un = make("TextButton", {
                    Size = UDim2.fromOffset(60, 20), AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, 66, 0.5, 0),
                    BackgroundColor3 = PAL.ELEVATED, BorderSizePixel = 0, AutoButtonColor = false, Text = "Unban",
                    TextColor3 = PAL.TEXT, Font = Enum.Font.GothamBold, TextSize = 11,
                }, row)
                corner(un, 5)
                local uid = e.userId
                un.MouseButton1Click:Connect(function() H.unban({ uid }) end)
            end
        end
        if n == 0 then label(banList, { Size = UDim2.new(1, -6, 0, 24), Text = "Nobody is banned", TextColor3 = PAL.DIM, TextSize = 12 }) end
    end
    UIAPI.syncFns.owner = function() if f.Visible then refresh() end end
    f:GetPropertyChangedSignal("Visible"):Connect(function()
        if not f.Visible then return end
        if not canEditTags() then f.Visible = false; return end
        refresh()
    end)
end

------------------------------------------------------------------------
-- Blacklist panel (`blacklist`, owners only): everyone banned from the
-- script in a dropdown, with their reason, unban, and adding new bans.
------------------------------------------------------------------------

local function buildBlacklistPanel(screenGui)
    local W, HGT = 360, 470
    local f = uiWindow(screenGui, "blacklist", "Blacklist", UDim2.fromOffset(W, HGT), UDim2.new(0.5, -W / 2, 0.5, -HGT / 2))
    local body, add = scrollBody(f, 42)
    local IW = W - 40
    local half = (IW - 8) / 2

    local bans = {}      -- snapshot shown in the dropdown
    local selected = 1
    local function entryLabel(e)
        local name = Moderation.nameOf(e.userId, true)
        return (name and ("@" .. name) or ("UserId " .. e.userId)) .. (name and ("  (" .. e.userId .. ")") or "")
    end

    sectionTitle(body, add, "Blacklisted users")
    local countLbl = label(body, { Position = UDim2.fromOffset(12, add(20)), Size = UDim2.fromOffset(IW, 18), Text = "", TextColor3 = PAL.DIM, TextSize = 11 })
    local dd = uiDropdown(body, "", UDim2.fromOffset(IW, 28), UDim2.fromOffset(12, add(36)), function()
        if #bans == 0 then return { "Nobody is blacklisted" } end
        local l = {}
        for i, e in ipairs(bans) do l[i] = entryLabel(e) end
        return l
    end, 1, function(i)
        selected = i
        UIAPI.syncFns.blacklist()
    end)
    local info = label(body, { Position = UDim2.fromOffset(12, add(56)), Size = UDim2.fromOffset(IW, 52), TextWrapped = true,
        TextYAlignment = Enum.TextYAlignment.Top, TextSize = 12, Text = "" })
    local y = add(38)
    uiButton(body, "Unban selected", UDim2.fromOffset(half, 30), UDim2.fromOffset(12, y), function()
        local e = bans[selected]
        if not e then return end
        local id = e.userId
        task.spawn(function()
            local ok, msg = Moderation.unban({ id })
            note("Blacklist", tostring(msg), ok and LIGHT or RED)
        end)
    end, true)
    uiButton(body, "Refresh", UDim2.fromOffset(half, 30), UDim2.fromOffset(12 + half + 8, y), function()
        task.spawn(function() Moderation.pull(true) end)
    end)

    sectionTitle(body, add, "Add to blacklist")
    local who = uiBox(body, UDim2.fromOffset(12, add(34)), UDim2.fromOffset(IW, 28), "Players: names, UserIds (commas)")
    local reason = uiBox(body, UDim2.fromOffset(12, add(34)), UDim2.fromOffset(IW, 28), "Reason (optional)")
    y = add(38)
    uiButton(body, "Blacklist", UDim2.fromOffset(IW, 30), UDim2.fromOffset(12, y), function()
        if who.Text == "" then note("Blacklist", "Type a player name or UserId", RED); return end
        H.ban({ who.Text, reason.Text ~= "" and reason.Text or nil })
        who.Text, reason.Text = "", ""
    end, true)
    label(body, { Position = UDim2.fromOffset(12, add(48)), Size = UDim2.fromOffset(IW, 44), TextWrapped = true, TextSize = 11,
        TextColor3 = PAL.DIM, TextYAlignment = Enum.TextYAlignment.Top,
        Text = "Blacklisted players are kicked whenever they run the script, in any server. Kicks (Owner panel) only apply in the server they were sent from. Needs the GitHub token in Settings." })

    local resolving = false
    UIAPI.syncFns.blacklist = function()
        if not f.Visible then return end
        bans = Moderation.bans()
        if selected > #bans then selected = math.max(1, #bans) end
        dd.set(selected)
        countLbl.Text = #bans .. " blacklisted  -  " .. tostring(Moderation.status)
        local e = bans[selected]
        if e then
            info.Text = "User: " .. entryLabel(e) .. "\nReason: " .. (e.reason ~= "" and e.reason or "(none)")
        else
            info.Text = "Nobody is blacklisted."
        end
        -- names of bans made before names were saved: look them up once, then redraw
        if not resolving then
            local missing = {}
            for _, b in ipairs(bans) do if not Moderation.nameOf(b.userId, true) then missing[#missing + 1] = b.userId end end
            if #missing > 0 then
                resolving = true
                task.spawn(function()
                    for _, id in ipairs(missing) do Moderation.nameOf(id) end
                    resolving = false
                    if f.Visible then UIAPI.syncFns.blacklist() end
                end)
            end
        end
    end
    f:GetPropertyChangedSignal("Visible"):Connect(function()
        if not f.Visible then return end
        if not canEditTags() then f.Visible = false; return end
        UIAPI.syncFns.blacklist()
    end)
end

------------------------------------------------------------------------
-- Performance panel (`performance`): the engine's graphics / FPS commands
------------------------------------------------------------------------

-- Graphics switches: name shown, the command that turns it on, the one that
-- turns it back off. State is kept here so kill can undo what you turned on.
local PERF_TOGGLES = {
    { "Plastic materials", "plastic", "unplastic" },
    { "Remove textures and decals", "untexturebp", "texturebp" },
    { "No post effects (bloom, blur, colour)", "loopnoeffect", "unloopnoeffect" },
    { "No fog", "loopnofog", "unloopnofog" },
    { "No lights", "nolights", "lights" },
    { "No shadows", "unglobalshadows", "globalshadows" },
    { "Fullbright", "fullbright", "nofullbright" },
}
local perfOn = {}

local function perfSet(onCmd, offCmd, on)
    perfOn[onCmd] = on and offCmd or nil
    Pup.run(on and onCmd or offCmd, {})
end

local function fpsSwitch(fnName, on)
    task.spawn(function()
        if not Pup.boot() then return end
        local fn = _G[fnName]
        if type(fn) == "function" then
            pcall(fn, on)
        else
            note("Performance", "Your executor cannot change the FPS cap (no setfpscap)", RED)
        end
    end)
end

table.insert(cleanups, function()
    for onCmd, offCmd in pairs(perfOn) do
        local c = Pup.booted and Pup.find(offCmd)
        if c and type(c.exec) == "function" then pcall(c.exec, { offCmd }) end
    end
    perfOn = {}
    for _, fnName in ipairs({ "_pup_applyUnlockFps", "_pup_applyBgFpsCap" }) do
        if type(_G[fnName]) == "function" then pcall(_G[fnName], false) end
    end
end)

-- FPS counter (Performance > FPS counter): a small box that keeps measuring
-- your frame rate. Drag it anywhere; the spot and on/off are saved.
do
    local Fps = {}
    UIAPI.fps = Fps

    local function cfg()
        if type(Cfg.fpsCounter) ~= "table" then Cfg.fpsCounter = { on = false } end
        return Cfg.fpsCounter
    end

    function Fps.hide()
        if Fps.conn then Fps.conn:Disconnect(); Fps.conn = nil end
        for _, c in ipairs(Fps.inputConns or {}) do c:Disconnect() end
        Fps.inputConns = nil
        if Fps.gui then Fps.gui:Destroy(); Fps.gui = nil end
    end

    function Fps.show()
        if Fps.gui then return end
        local c = cfg()
        local g = Instance.new("ScreenGui")
        g.Name = "PuppyAdminFPS"
        g.ResetOnSpawn = false
        g.IgnoreGuiInset = true
        g.DisplayOrder = 999990
        parentGui(g)
        if not g.Parent then return end
        Fps.gui = g
        local box = make("TextButton", {
            Size = UDim2.fromOffset(118, 26), Position = UDim2.fromOffset(tonumber(c.x) or 12, tonumber(c.y) or 60),
            BackgroundColor3 = PAL.PANEL, BackgroundTransparency = 0.15, BorderSizePixel = 0, AutoButtonColor = false,
            Text = "-- FPS", Font = Enum.Font.GothamBold, TextSize = 13, TextColor3 = PAL.TEXT,
        }, g)
        corner(box, 8)
        stroke(box, PAL.STROKE, 1, 0)
        pcall(Theme.attach, g)

        -- drag to place; kept inside the screen and saved when you let go
        local dragging, startPos, startMouse = false, nil, nil
        box.InputBegan:Connect(function(input)
            if isPointer(input) then dragging, startPos, startMouse = true, box.Position, input.Position end
        end)
        Fps.inputConns = {
            UserInputService.InputChanged:Connect(function(input)
                if not dragging then return end
                if input.UserInputType ~= Enum.UserInputType.MouseMovement and input.UserInputType ~= Enum.UserInputType.Touch then return end
                local d = input.Position - startMouse
                local vp = g.AbsoluteSize
                local x = math.clamp(startPos.X.Offset + d.X, 0, math.max(0, vp.X - box.AbsoluteSize.X))
                local y = math.clamp(startPos.Y.Offset + d.Y, 0, math.max(0, vp.Y - box.AbsoluteSize.Y))
                box.Position = UDim2.fromOffset(x, y)
            end),
            UserInputService.InputEnded:Connect(function(input)
                if dragging and isPointer(input) then
                    dragging = false
                    c.x, c.y = box.Position.X.Offset, box.Position.Y.Offset
                    cfgSave()
                end
            end),
        }

        -- frames counted over half a second
        local frames, t0 = 0, os.clock()
        Fps.conn = RunService.RenderStepped:Connect(function()
            frames = frames + 1
            local now = os.clock()
            local span = now - t0
            if span >= 0.5 then
                local fps = frames / span
                box.Text = string.format("%d FPS  %d ms", math.floor(fps + 0.5), math.floor(1000 / math.max(fps, 1) + 0.5))
                box.TextColor3 = fps >= 55 and Color3.fromRGB(120, 230, 140) or (fps >= 30 and Color3.fromRGB(255, 210, 110) or Color3.fromRGB(255, 110, 110))
                frames, t0 = 0, now
            end
        end)
    end

    function Fps.set(on)
        cfg().on = on and true or false
        cfgSave()
        if on then Fps.show() else Fps.hide() end
    end
    function Fps.isOn() return cfg().on == true end

    table.insert(cleanups, Fps.hide)
end

local function buildPerformancePanel(screenGui)
    local W, HGT = 340, 560
    local f = uiWindow(screenGui, "performance", "Performance", UDim2.fromOffset(W, HGT), UDim2.new(0, 380, 0.5, -HGT / 2))
    local body, add = scrollBody(f, 42)
    local IW = W - 40
    local half = (IW - 8) / 2
    local syncers = {}
    local function switch(text, get, onChange)
        local s = uiSwitch(body, text, UDim2.fromOffset(12, add(32)), IW, get(), onChange)
        table.insert(syncers, function() s.set(get()) end)
        return s
    end

    sectionTitle(body, add, "FPS")
    switch("Unlock FPS", function() return Pup.pupL ~= nil and Pup.pupL.unlockFpsEnabled == true end,
        function(on) fpsSwitch("_pup_applyUnlockFps", on) end)
    switch("Low FPS when tabbed out (24)", function() return Pup.pupL ~= nil and Pup.pupL.bgFpsCapEnabled == true end,
        function(on) fpsSwitch("_pup_applyBgFpsCap", on) end)
    switch("FPS counter (drag it where you want it)", function() return UIAPI.fps.isOn() end, function(on) UIAPI.fps.set(on) end)
    local y = add(38)
    uiButton(body, "Timing report", UDim2.fromOffset(IW, 30), UDim2.fromOffset(12, y), function() H.perf() end)

    sectionTitle(body, add, "Quick boost")
    switch("Anti-lag (lower graphics)", function() return Pup.active.antilag == true end, function(on)
        Pup.run(on and "antilag" or "unantilag", {})
    end)

    sectionTitle(body, add, "Graphics")
    for _, t in ipairs(PERF_TOGGLES) do
        local onCmd, offCmd = t[2], t[3]
        switch(t[1], function() return perfOn[onCmd] ~= nil end, function(on) perfSet(onCmd, offCmd, on) end)
    end

    sectionTitle(body, add, "Heavy")
    switch("Stop 3D rendering (UI only, max FPS)", function() return perfOn.norender ~= nil end, function(on)
        perfSet("norender", "render", on)
        if on then note("Performance", "3D rendering is off - switch it back here or run render", LIGHT) end
    end)
    y = add(38)
    uiButton(body, "Remove terrain (until rejoin)", UDim2.fromOffset(IW, 30), UDim2.fromOffset(12, y), function()
        Pup.run("removeterrain", {})
    end, true)
    label(body, { Position = UDim2.fromOffset(12, add(40)), Size = UDim2.fromOffset(IW, 36), TextWrapped = true, TextSize = 11,
        TextColor3 = PAL.DIM, Text = "Everything here is on your screen only. Kill / stop turns off what you switched on." })

    UIAPI.syncFns.performance = function()
        if not f.Visible then return end
        for _, fn in ipairs(syncers) do pcall(fn) end
    end
    f:GetPropertyChangedSignal("Visible"):Connect(function() if f.Visible then UIAPI.syncFns.performance() end end)
end

------------------------------------------------------------------------
-- Mini games (`games`): Snake, Stack Drop (falling blocks) and Treat Chase
-- (maze chase). The game rules below are plain Lua with no Roblox calls:
-- each game has new(rng), input(g, action), update(g, dt), draw(g, put)
-- and hud(g). The panel only feeds input and paints a grid of cells.
-- rng(n) returns a whole number from 1 to n.
------------------------------------------------------------------------

-- built inside a function: it has its own local-variable budget (the main chunk is near Lua's 200 limit)
local MiniGames = (function()
local MiniGames = {}
do
    local DIRS = { left = { -1, 0 }, right = { 1, 0 }, up = { 0, -1 }, down = { 0, 1 } }
    local DIR_ORDER = { "up", "left", "down", "right" }
    local OPP = { left = "right", right = "left", up = "down", down = "up" }
    MiniGames.DIRS, MiniGames.OPP = DIRS, OPP

    -- Snake -------------------------------------------------------------
    local Snake = {
        id = "snake", title = "Snake", cols = 20, rows = 20,
        help = "Arrows / WASD steer. Eat the treats; walls and your own tail end the run.",
    }
    MiniGames.snake = Snake

    function Snake.occupied(g, x, y, skipTail)
        local n = #g.body - (skipTail and 1 or 0)
        for i = 1, n do
            local s = g.body[i]
            if s.x == x and s.y == y then return true end
        end
        return false
    end

    function Snake.placeFood(g)
        local free = {}
        for y = 1, Snake.rows do
            for x = 1, Snake.cols do
                if not Snake.occupied(g, x, y) then free[#free + 1] = { x = x, y = y } end
            end
        end
        if #free == 0 then g.food = nil; g.over = true; g.won = true; return end
        g.food = free[g.rng(#free)]
    end

    function Snake.new(rng)
        local g = { rng = rng, score = 0, over = false, dir = "right", queue = {}, timer = 0 }
        g.body = { { x = 6, y = 10 }, { x = 5, y = 10 }, { x = 4, y = 10 } }
        Snake.placeFood(g)
        return g
    end

    function Snake.input(g, a)
        if not DIRS[a] then return end
        local last = g.queue[#g.queue] or g.dir
        if a == last or a == OPP[last] or #g.queue >= 2 then return end
        g.queue[#g.queue + 1] = a
    end

    function Snake.interval(g) return math.max(0.065, 0.13 - #g.body * 0.0015) end

    function Snake.step(g)
        if g.over then return end
        if #g.queue > 0 then g.dir = table.remove(g.queue, 1) end
        local d = DIRS[g.dir]
        local h = g.body[1]
        local nx, ny = h.x + d[1], h.y + d[2]
        local eating = g.food ~= nil and nx == g.food.x and ny == g.food.y
        -- the tail moves away this step unless the snake grows
        if nx < 1 or ny < 1 or nx > Snake.cols or ny > Snake.rows or Snake.occupied(g, nx, ny, not eating) then
            g.over = true
            return
        end
        table.insert(g.body, 1, { x = nx, y = ny })
        if eating then
            g.score = g.score + 1
            Snake.placeFood(g)
        else
            table.remove(g.body)
        end
    end

    function Snake.update(g, dt)
        g.timer = g.timer + dt
        local iv = Snake.interval(g)
        while g.timer >= iv and not g.over do
            g.timer = g.timer - iv
            Snake.step(g)
        end
    end

    -- which side a neighbouring segment is on: r / l / u / d
    local function side(a, b)
        if b.x > a.x then return "r" elseif b.x < a.x then return "l" elseif b.y < a.y then return "u" end
        return "d"
    end
    local CORNER = { ur = "ur", ru = "ur", rd = "rd", dr = "rd", dl = "dl", ld = "dl", lu = "lu", ul = "lu" }
    -- kinds: head_<facing>, tail_<tip>, body_h / body_v, corner_ur / rd / dl / lu, food
    function Snake.draw(g, put)
        if g.food then put(g.food.x, g.food.y, "food") end
        local b, n = g.body, #g.body
        for i = n, 1, -1 do
            local s = b[i]
            local kind
            if i == 1 then
                kind = "head_" .. (n > 1 and side(b[2], s) or "r")
            elseif i == n then
                kind = "tail_" .. side(b[i - 1], s)
            else
                local a, c = side(s, b[i - 1]), side(s, b[i + 1])
                if (a == "l" or a == "r") and (c == "l" or c == "r") then kind = "body_h"
                elseif (a == "u" or a == "d") and (c == "u" or c == "d") then kind = "body_v"
                else kind = "corner_" .. CORNER[a .. c] end
            end
            put(s.x, s.y, kind)
        end
    end
    Snake.sheet = "assets/games/snake.png"
    local SNAKE_TILES = {
        head_r = { 0, 0 }, head_l = { 1, 0 }, head_u = { 2, 0 }, head_d = { 3, 0 },
        tail_r = { 4, 0 }, tail_l = { 5, 0 }, tail_u = { 6, 0 }, tail_d = { 7, 0 },
        body_h = { 0, 1 }, body_v = { 1, 1 }, corner_ur = { 2, 1 }, corner_rd = { 3, 1 }, corner_dl = { 4, 1 }, corner_lu = { 5, 1 },
        food = { 6, 1 },
    }
    function Snake.cellSprite(kind) local t = SNAKE_TILES[kind]; if t then return t[1], t[2] end end

    function Snake.hud(g) return "Score " .. g.score .. "   Length " .. #g.body end

    -- Stack Drop --------------------------------------------------------
    local Stack = {
        id = "stack", title = "Stack Drop", tab = "Stack", cols = 10, rows = 20, repeatKeys = { left = true, right = true, down = true },
        help = "Left / right move, R or Up rotates, Down drops faster, Space drops. Fill a row to clear it.",
    }
    MiniGames.stack = Stack
    local SHAPES = {
        { { 0, 0 }, { 1, 0 }, { 2, 0 }, { 3, 0 } },
        { { 0, 0 }, { 1, 0 }, { 0, 1 }, { 1, 1 } },
        { { 0, 0 }, { 1, 0 }, { 2, 0 }, { 1, 1 } },
        { { 0, 0 }, { 1, 0 }, { 2, 0 }, { 0, 1 } },
        { { 0, 0 }, { 1, 0 }, { 2, 0 }, { 2, 1 } },
        { { 1, 0 }, { 2, 0 }, { 0, 1 }, { 1, 1 } },
        { { 0, 0 }, { 1, 0 }, { 1, 1 }, { 2, 1 } },
    }
    Stack.SHAPES = SHAPES
    local LINE_POINTS = { 100, 300, 500, 800 }

    local function width(cells)
        local m = 0
        for _, c in ipairs(cells) do if c[1] > m then m = c[1] end end
        return m + 1
    end

    local function rotateCells(cells)
        local out, minx, miny = {}, math.huge, math.huge
        for i, c in ipairs(cells) do
            local x, y = -c[2], c[1]
            out[i] = { x, y }
            if x < minx then minx = x end
            if y < miny then miny = y end
        end
        for _, c in ipairs(out) do c[1] = c[1] - minx; c[2] = c[2] - miny end
        return out
    end
    Stack.rotateCells = rotateCells

    function Stack.nextFromBag(g)
        if #g.bag == 0 then
            for i = 1, #SHAPES do g.bag[i] = i end
            for i = #g.bag, 2, -1 do
                local j = g.rng(i)
                g.bag[i], g.bag[j] = g.bag[j], g.bag[i]
            end
        end
        return table.remove(g.bag)
    end

    function Stack.fits(g, cells, px, py)
        for _, c in ipairs(cells) do
            local x, y = px + c[1], py + c[2]
            if x < 1 or x > Stack.cols or y < 1 or y > Stack.rows then return false end
            if g.board[y][x] then return false end
        end
        return true
    end

    function Stack.spawn(g)
        local kind = g.nextKind
        g.nextKind = Stack.nextFromBag(g)
        local cells = {}
        for i, c in ipairs(SHAPES[kind]) do cells[i] = { c[1], c[2] } end
        g.piece = { kind = kind, cells = cells, x = math.floor((Stack.cols - width(cells)) / 2) + 1, y = 1 }
        if not Stack.fits(g, cells, g.piece.x, g.piece.y) then g.over = true end
    end

    function Stack.new(rng)
        local g = { rng = rng, score = 0, lines = 0, level = 1, over = false, timer = 0, bag = {}, board = {} }
        for y = 1, Stack.rows do g.board[y] = {} end
        g.nextKind = Stack.nextFromBag(g)
        Stack.spawn(g)
        return g
    end

    function Stack.lock(g)
        local p = g.piece
        for _, c in ipairs(p.cells) do g.board[p.y + c[2]][p.x + c[1]] = p.kind end
        local cleared, y = 0, Stack.rows
        while y >= 1 do
            local full = true
            for x = 1, Stack.cols do
                if not g.board[y][x] then full = false; break end
            end
            if full then
                table.remove(g.board, y)
                table.insert(g.board, 1, {})
                cleared = cleared + 1
            else
                y = y - 1
            end
        end
        if cleared > 0 then
            g.score = g.score + LINE_POINTS[math.min(cleared, 4)] * g.level
            g.lines = g.lines + cleared
            g.level = 1 + math.floor(g.lines / 10)
        end
        g.timer = 0
        Stack.spawn(g)
    end

    function Stack.input(g, a)
        if g.over then return end
        local p = g.piece
        if a == "left" or a == "right" then
            local dx = a == "left" and -1 or 1
            if Stack.fits(g, p.cells, p.x + dx, p.y) then p.x = p.x + dx end
        elseif a == "up" or a == "rotate" then
            if p.kind == 2 then return end
            local r = rotateCells(p.cells)
            local base = p.x + math.floor((width(p.cells) - width(r)) / 2)
            for _, k in ipairs({ 0, -1, 1, -2, 2 }) do
                if Stack.fits(g, r, base + k, p.y) then p.cells = r; p.x = base + k; return end
            end
        elseif a == "down" then
            if Stack.fits(g, p.cells, p.x, p.y + 1) then
                p.y = p.y + 1
                g.score = g.score + 1
                g.timer = 0
            else
                Stack.lock(g)
            end
        elseif a == "drop" then
            local n = 0
            while Stack.fits(g, p.cells, p.x, p.y + 1) do p.y = p.y + 1; n = n + 1 end
            g.score = g.score + n * 2
            Stack.lock(g)
        end
    end

    function Stack.interval(g) return math.max(0.08, 0.8 * 0.85 ^ (g.level - 1)) end

    function Stack.update(g, dt)
        if g.over then return end
        g.timer = g.timer + dt
        local iv = Stack.interval(g)
        while g.timer >= iv and not g.over do
            g.timer = g.timer - iv
            local p = g.piece
            if Stack.fits(g, p.cells, p.x, p.y + 1) then p.y = p.y + 1 else Stack.lock(g) end
        end
    end

    function Stack.draw(g, put)
        for y = 1, Stack.rows do
            for x = 1, Stack.cols do
                local k = g.board[y][x]
                if k then put(x, y, "p" .. k) end
            end
        end
        if g.over then return end
        local p = g.piece
        local gy = p.y
        while Stack.fits(g, p.cells, p.x, gy + 1) do gy = gy + 1 end
        for _, c in ipairs(p.cells) do put(p.x + c[1], gy + c[2], "ghost") end
        for _, c in ipairs(p.cells) do put(p.x + c[1], p.y + c[2], "p" .. p.kind) end
    end

    -- the next piece, for the small preview grid (4 x 2)
    function Stack.preview(g, put)
        for _, c in ipairs(SHAPES[g.nextKind]) do put(c[1] + 1, c[2] + 1, "p" .. g.nextKind) end
    end

    Stack.sheet = "assets/games/stack_drop.png"
    function Stack.cellSprite(kind)
        if kind == "ghost" then return 7, 0 end
        local n = tonumber(kind:match("^p(%d)$"))
        if n then return n - 1, 0 end
    end

    function Stack.hud(g) return "Score " .. g.score .. "   Lines " .. g.lines .. "   Level " .. g.level end

    -- Treat Chase -------------------------------------------------------
    -- # wall, . treat, o power bone, P puppy start, C cat pen, - pen door
    local MAZE = {
        "###################",
        "#o.......#.......o#",
        "#.##.###.#.###.##.#",
        "#.................#",
        "#.##.#.#####.#.##.#",
        "#....#...#...#....#",
        "####.###...###.####",
        "#......##-##......#",
        "#.##.#.#CCC#.#.##.#",
        "#.##.#.#####.#.##.#",
        "#....#.......#....#",
        "##.#.###.#.###.#.##",
        "#..#.....P.....#..#",
        "#.####.#####.####.#",
        "#o.....#...#.....o#",
        "#.###.##.#.##.###.#",
        "#.................#",
        "###################",
    }
    local Chase = {
        id = "chase", title = "Treat Chase", tab = "Chase", cols = #MAZE[1], rows = #MAZE, sprites = true,
        sheet = "assets/games/treat_chase_v2.png",
        help = "Arrows / WASD steer the puppy. Eat every treat; a bone turns the cats blue so you can chase them. Grab the drumstick for bonus points.",
    }
    MiniGames.chase = Chase
    Chase.MAZE = MAZE

    -- Cats take turns heading for their own corner (calm) and hunting the puppy;
    -- seconds per phase, the last one lasts for the rest of the level.
    -- BONUS_AT: treats eaten when a drumstick appears
    local K = {
        PHASES = { 7, 20, 7, 20, 5 }, CORNERS = { { 19, 0 }, { 1, 0 }, { 1, 19 } },
        DEATH_TIME = 1.4, CLEAR_TIME = 1.8, READY_TIME = 1.6, BONUS_AT = { [50] = true, [110] = true },
    }

    local function key(x, y) return y * 64 + x end

    local function popup(g, x, y, text)
        g.popups[#g.popups + 1] = { x = x, y = y, text = text, t = 1, life = 1 }
    end

    local function addScore(g, n, x, y)
        g.score = g.score + n
        if x then popup(g, x, y, tostring(n)) end
        if g.score >= g.nextLife then
            g.nextLife = g.nextLife + 10000
            g.lives = g.lives + 1
            popup(g, g.player.x, g.player.y, "1UP")
        end
    end

    function Chase.loadLevel(g)
        g.walls, g.treats, g.left, g.pen, g.eaten = {}, {}, 0, {}, 0
        for y, row in ipairs(MAZE) do
            g.walls[y], g.treats[y] = {}, {}
            for x = 1, #row do
                local ch = row:sub(x, x)
                if ch == "#" or ch == "-" or ch == "C" then g.walls[y][x] = ch end
                if ch == "C" then g.pen[#g.pen + 1] = { x = x, y = y } end
                if ch == "-" then g.door = { x = x, y = y } end
                if ch == "P" then g.start = { x = x, y = y } end
                if ch == "." or ch == "o" then g.treats[y][x] = ch; g.left = g.left + 1 end
            end
        end
        g.bonus = nil
        Chase.resetActors(g)
    end

    function Chase.resetActors(g)
        g.player = { x = g.start.x, y = g.start.y, ox = g.start.x, oy = g.start.y, dir = nil, want = nil, timer = 0, face = "left", moving = false }
        g.power, g.combo = 0, 0
        g.phase, g.phaseT = 1, K.PHASES[1]
        g.cats = {}
        for i = 1, 3 do
            local p = g.pen[((i - 1) % #g.pen) + 1]
            g.cats[i] = { id = i, x = p.x, y = p.y, ox = p.x, oy = p.y, dir = "up", state = "pen", wait = (i - 1) * 3 + 1, timer = 0 }
        end
        g.freeze = K.READY_TIME
    end

    function Chase.new(rng)
        local g = { rng = rng, score = 0, lives = 3, level = 1, over = false, popups = {}, nextLife = 10000, clock = 0 }
        Chase.loadLevel(g)
        return g
    end

    function Chase.playerOpen(g, x, y)
        local row = g.walls[y]
        return row ~= nil and x >= 1 and x <= Chase.cols and row[x] == nil
    end

    -- cats leaving or going home may use the pen and its door
    function Chase.catOpen(g, c, x, y)
        local row = g.walls[y]
        if row == nil or x < 1 or x > Chase.cols then return false end
        local w = row[x]
        if w == nil then return true end
        if w == "#" then return false end
        return c.state == "leave" or c.state == "eaten"
    end

    -- first direction of a shortest path from the cat to (tx, ty)
    local function pathDir(g, c, tx, ty)
        local first, q, head = { [key(c.x, c.y)] = "start" }, { { c.x, c.y } }, 1
        while head <= #q do
            local cur = q[head]
            head = head + 1
            for _, dn in ipairs(DIR_ORDER) do
                local d = DIRS[dn]
                local nx, ny = cur[1] + d[1], cur[2] + d[2]
                local k = key(nx, ny)
                if first[k] == nil and Chase.catOpen(g, c, nx, ny) then
                    local f = first[key(cur[1], cur[2])]
                    first[k] = f == "start" and dn or f
                    if nx == tx and ny == ty then return first[k] end
                    q[#q + 1] = { nx, ny }
                end
            end
        end
        return nil
    end
    Chase.pathDir = pathDir

    local function chooseDir(g, c, tx, ty, flee)
        local opts = {}
        for _, dn in ipairs(DIR_ORDER) do
            local d = DIRS[dn]
            if dn ~= OPP[c.dir] and Chase.catOpen(g, c, c.x + d[1], c.y + d[2]) then opts[#opts + 1] = dn end
        end
        if #opts == 0 then
            local back = OPP[c.dir]
            local d = DIRS[back]
            return Chase.catOpen(g, c, c.x + d[1], c.y + d[2]) and back or nil
        end
        if flee or (c.id > 1 and g.rng(100) <= 10) then return opts[g.rng(#opts)] end
        local best, bestD
        for _, dn in ipairs(opts) do
            local d = DIRS[dn]
            local dx, dy = c.x + d[1] - tx, c.y + d[2] - ty
            local dist = dx * dx + dy * dy
            if bestD == nil or dist < bestD then best, bestD = dn, dist end
        end
        return best
    end

    function Chase.calm(g) return g.phase <= #K.PHASES and g.phase % 2 == 1 end

    local function catTarget(g, c)
        if Chase.calm(g) then return K.CORNERS[c.id][1], K.CORNERS[c.id][2] end
        local p = g.player
        if c.id == 2 and p.dir then
            local d = DIRS[p.dir]
            return p.x + d[1] * 4, p.y + d[2] * 4
        elseif c.id == 3 then
            local dx, dy = c.x - p.x, c.y - p.y
            if dx * dx + dy * dy < 49 then return K.CORNERS[3][1], K.CORNERS[3][2] end
        end
        return p.x, p.y
    end

    local function playerInterval(g) return math.max(0.1, 0.15 * 0.96 ^ (g.level - 1)) end
    local function catInterval(g, c)
        if c.state == "eaten" then return 0.06 end
        if c.state == "scared" then return 0.3 end
        return math.max(0.11, 0.17 * 0.95 ^ (g.level - 1))
    end

    function Chase.moveCat(g, c)
        c.ox, c.oy = c.x, c.y
        local dn
        if c.state == "leave" then
            local tx, ty = g.door.x, g.door.y - 1
            if c.x == tx and c.y == ty then
                c.state = g.power > 0 and "scared" or "hunt"
            else
                dn = pathDir(g, c, tx, ty)
            end
        elseif c.state == "eaten" then
            local home = g.pen[1]
            if c.x == home.x and c.y == home.y then
                c.state = "leave"
            else
                dn = pathDir(g, c, home.x, home.y)
            end
        end
        if c.state == "hunt" or c.state == "scared" then
            if c.reverse then
                c.reverse = nil
                local back = OPP[c.dir]
                local d = DIRS[back]
                if Chase.catOpen(g, c, c.x + d[1], c.y + d[2]) then dn = back end
            end
            if not dn then
                local tx, ty = catTarget(g, c)
                dn = chooseDir(g, c, tx, ty, c.state == "scared")
            end
        end
        if dn then
            local d = DIRS[dn]
            c.x, c.y, c.dir = c.x + d[1], c.y + d[2], dn
        end
    end

    -- true when the round stopped (the puppy was caught)
    local function collide(g)
        local p = g.player
        for _, c in ipairs(g.cats) do
            if c.x == p.x and c.y == p.y then
                if c.state == "scared" then
                    g.combo = g.combo + 1
                    addScore(g, 100 * math.floor(2 ^ g.combo), c.x, c.y)
                    c.state = "eaten"
                elseif c.state == "hunt" then
                    g.dying = K.DEATH_TIME
                    p.ox, p.oy, p.timer = p.x, p.y, 0
                    return true
                end
            end
        end
        return false
    end
    Chase.collide = collide

    function Chase.movePlayer(g)
        local p = g.player
        p.ox, p.oy = p.x, p.y
        if p.want then
            local d = DIRS[p.want]
            if Chase.playerOpen(g, p.x + d[1], p.y + d[2]) then p.dir = p.want end
        end
        p.moving = false
        if not p.dir then return end
        local d = DIRS[p.dir]
        if not Chase.playerOpen(g, p.x + d[1], p.y + d[2]) then return end
        p.x, p.y, p.face, p.moving = p.x + d[1], p.y + d[2], p.dir, true
        local t = g.treats[p.y][p.x]
        if t then
            g.treats[p.y][p.x] = nil
            g.left = g.left - 1
            g.eaten = g.eaten + 1
            if t == "o" then
                addScore(g, 50)
                g.power = math.max(3, 7 - (g.level - 1) * 0.5)
                g.combo = 0
                for _, c in ipairs(g.cats) do
                    if c.state == "hunt" then c.state = "scared"; c.reverse = true end
                end
            else
                addScore(g, 10)
            end
            if K.BONUS_AT[g.eaten] then g.bonus = { x = g.start.x, y = g.start.y, t = 9 } end
        end
        if g.bonus and g.bonus.x == p.x and g.bonus.y == p.y then
            addScore(g, 100 * (g.level + 1), p.x, p.y)
            g.bonus = nil
        end
        if g.left <= 0 then g.clearing = K.CLEAR_TIME end
    end

    function Chase.input(g, a)
        if DIRS[a] then g.player.want = a end
    end

    function Chase.update(g, dt)
        g.clock = g.clock + dt
        for i = #g.popups, 1, -1 do
            local pp = g.popups[i]
            pp.t = pp.t - dt
            if pp.t <= 0 then table.remove(g.popups, i) end
        end
        if g.over then return end
        if g.dying then
            g.dying = g.dying - dt
            if g.dying <= 0 then
                g.dying = nil
                g.lives = g.lives - 1
                if g.lives <= 0 then g.over = true else Chase.resetActors(g) end
            end
            return
        end
        if g.clearing then
            g.clearing = g.clearing - dt
            if g.clearing <= 0 then
                g.clearing = nil
                g.level = g.level + 1
                addScore(g, 500)
                Chase.loadLevel(g)
            end
            return
        end
        if g.freeze > 0 then g.freeze = g.freeze - dt; return end

        if g.power > 0 then
            g.power = g.power - dt
            if g.power <= 0 then
                g.power = 0
                for _, c in ipairs(g.cats) do if c.state == "scared" then c.state = "hunt" end end
            end
        elseif g.phase <= #K.PHASES then
            -- the phase clock pauses while the cats are scared
            g.phaseT = g.phaseT - dt
            if g.phaseT <= 0 then
                g.phase = g.phase + 1
                g.phaseT = K.PHASES[g.phase] or math.huge
                for _, c in ipairs(g.cats) do if c.state == "hunt" then c.reverse = true end end
            end
        end
        if g.bonus then
            g.bonus.t = g.bonus.t - dt
            if g.bonus.t <= 0 then g.bonus = nil end
        end

        local p = g.player
        p.timer = p.timer + dt
        local piv = playerInterval(g)
        while p.timer >= piv do
            p.timer = p.timer - piv
            Chase.movePlayer(g)
            if g.clearing or collide(g) then return end
        end
        for _, c in ipairs(g.cats) do
            if c.state == "pen" then
                c.wait = c.wait - dt
                if c.wait <= 0 then c.state = "leave" end
            else
                c.timer = c.timer + dt
                local iv = catInterval(g, c)
                while c.timer >= iv do
                    c.timer = c.timer - iv
                    Chase.moveCat(g, c)
                    if collide(g) then return end
                    iv = catInterval(g, c)
                end
            end
        end
    end

    local function catKind(g, c)
        if c.state == "eaten" then return "eyes" end
        if c.state == "scared" then
            local blink = g.power < 1.5 and math.floor(g.power * 6) % 2 == 0
            return blink and "scared2" or "scared"
        end
        return "cat" .. c.id
    end

    -- Static cells (walls, door, treats). With sprites off, actors are drawn as cells too.
    function Chase.draw(g, put, sprites)
        local flash = g.clearing and math.floor(g.clearing * 6) % 2 == 0
        for y = 1, Chase.rows do
            for x = 1, Chase.cols do
                local w = g.walls[y][x]
                if w == "#" then
                    put(x, y, flash and "wallflash" or "wall")
                elseif w == "-" then
                    put(x, y, "door")
                else
                    local t = g.treats[y][x]
                    if t == "." then put(x, y, "treat")
                    elseif t == "o" and not sprites then put(x, y, "bone") end
                end
            end
        end
        if sprites then return end
        if g.bonus then put(g.bonus.x, g.bonus.y, "snack") end
        for _, c in ipairs(g.cats) do put(c.x, c.y, catKind(g, c)) end
        put(g.player.x, g.player.y, "puppy")
    end

    -- Moving pieces for the sprite layer: kind, x / y in cells (fractional while
    -- moving), facing ("right" / "left" / "up" / "down"), frame (0 / 1), and for the
    -- puppy `dying` (0..1, how far the caught animation is). Drawn bottom to top.
    function Chase.actors(g)
        local list = {}
        for y = 1, Chase.rows do
            for x = 1, Chase.cols do
                if g.treats[y][x] == "o" then
                    -- power bones pulse
                    list[#list + 1] = { kind = "bone", x = x, y = y, scale = 0.9 + 0.15 * math.sin(g.clock * 6) }
                end
            end
        end
        if g.bonus then list[#list + 1] = { kind = "snack", x = g.bonus.x, y = g.bonus.y, scale = 1.1 } end
        local hidden = g.dying ~= nil or g.clearing ~= nil
        if not hidden then
            for _, c in ipairs(g.cats) do
                local f = c.state == "pen" and 0 or math.min(1, c.timer / catInterval(g, c))
                local bob = c.state == "pen" and math.sin(g.clock * 5 + c.id) * 0.15 or 0
                list[#list + 1] = {
                    kind = catKind(g, c), dir = c.dir,
                    x = c.ox + (c.x - c.ox) * f, y = c.oy + (c.y - c.oy) * f + bob,
                }
            end
        end
        local p = g.player
        local f = (p.moving and not g.dying) and math.min(1, p.timer / playerInterval(g)) or 1
        list[#list + 1] = {
            kind = "puppy", dir = p.face,
            x = p.ox + (p.x - p.ox) * f, y = p.oy + (p.y - p.oy) * f,
            frame = (p.moving and g.freeze <= 0 and not g.dying) and (math.floor(g.clock * 10) % 2) or 0,
            dying = g.dying and (1 - g.dying / K.DEATH_TIME) or nil,
        }
        return list
    end

    function Chase.banner(g)
        if g.over then return nil end
        if g.clearing then return "Level " .. g.level .. " clear!" end
        if g.freeze > 0 and not g.dying then return g.level > 1 and ("Level " .. g.level .. " - Ready!") or "Ready!" end
        return nil
    end

    -- the flashing walls of a cleared level stay plain colour, so the flash shows
    local CHASE_TILES = { wall = { 2, 3 }, door = { 3, 3 }, treat = { 0, 3 } }
    function Chase.cellSprite(kind) local t = CHASE_TILES[kind]; if t then return t[1], t[2] end end

    function Chase.hud(g) return "Score " .. g.score .. "   Lives " .. g.lives .. "   Level " .. g.level end


    -- Star StarPup (fixed shooter) ----------------------------------------------
    -- A puppy in a rocket at the bottom; a fleet of space fleas marches side
    -- to side, steps down at each edge, speeds up as it shrinks and shoots
    -- back. Doghouse shields wear away; a flea queen saucer crosses the top.
    -- Positions are in cells (fractional); shields are cells of the grid.
    local StarPup = {
        id = "starpup", title = "Star StarPup", tab = "Star StarPup", cols = 24, rows = 22, sprites = true, hold = true,
        help = "Left / right move (hold), Space or Up fires. Shoot the flea fleet before it lands; the saucer is a bonus.",
        sheet = "assets/games/star_pup_v2.png",
    }
    MiniGames.starpup = StarPup
    local P = {
        playerY = 20.6, playerSpeed = 11, shotSpeed = 26, bombSpeed = 9,
        fleetCols = 8, fleetRows = 5, gapX = 2.2, gapY = 1.6, top = 3, stepDown = 0.8,
        shieldRow = 17, rowPoints = { 30, 20, 20, 10, 10 }, extraLifeAt = 1500,
    }
    StarPup.P = P
    local SHIELD = { "01110", "11111", "11011" } -- doghouse shape (5 wide), four of them

    function StarPup.wave(g)
        g.fleet = {}
        local startX = (StarPup.cols - (P.fleetCols - 1) * P.gapX) / 2
        local dropBy = math.min(g.waveNo - 1, 4) * 0.8
        for r = 1, P.fleetRows do
            for c = 1, P.fleetCols do
                g.fleet[#g.fleet + 1] = {
                    x = startX + (c - 1) * P.gapX, y = P.top + (r - 1) * P.gapY + dropBy,
                    kind = r == 1 and 3 or (r <= 3 and 2 or 1), row = r, alive = true,
                }
            end
        end
        g.fleetDir, g.fleetTimer, g.frame = 1, 0, 0
        g.bombs, g.shot, g.saucer = {}, nil, nil
        g.saucerTimer = 12 + g.rng(10)
        g.bombTimer = 1
        g.pause = 1.2
    end

    function StarPup.new(rng)
        local g = { rng = rng, score = 0, lives = 3, over = false, waveNo = 1, popups = {}, clock = 0, nextLife = P.extraLifeAt }
        g.player = { x = StarPup.cols / 2, left = false, right = false, dead = 0 }
        -- shields: grid cells
        g.shield = {}
        for i = 1, 4 do
            local sx = math.floor((i - 0.5) * StarPup.cols / 4 - 2.5)
            for dy, row in ipairs(SHIELD) do
                for dx = 1, #row do
                    if row:sub(dx, dx) == "1" then g.shield[(P.shieldRow + dy - 1) * 64 + sx + dx] = true end
                end
            end
        end
        StarPup.wave(g)
        return g
    end

    local function addScore(g, n, x, y)
        g.score = g.score + n
        if x then g.popups[#g.popups + 1] = { x = x, y = y, text = tostring(n), t = 0.8, life = 0.8 } end
        if g.score >= g.nextLife then
            g.nextLife = g.nextLife + P.extraLifeAt
            g.lives = g.lives + 1
            g.popups[#g.popups + 1] = { x = g.player.x, y = P.playerY - 1, text = "1UP", t = 1, life = 1 }
        end
    end

    function StarPup.input(g, a, down)
        if down == nil then down = true end
        local p = g.player
        if a == "left" then p.left = down
        elseif a == "right" then p.right = down
        elseif (a == "drop" or a == "up" or a == "rotate") and down then
            if not g.shot and p.dead <= 0 and g.pause <= 0 then g.shot = { x = p.x, y = P.playerY - 0.8 } end
        end
    end
    function StarPup.releaseAll(g) g.player.left, g.player.right = false, false end

    local function aliveCount(g)
        local n = 0
        for _, f in ipairs(g.fleet) do if f.alive then n = n + 1 end end
        return n
    end

    -- a shot or bomb hitting a shield cell removes it (and the shot)
    local function hitShield(g, x, y)
        local k = math.floor(y) * 64 + math.floor(x) + 1
        if g.shield[k] then g.shield[k] = nil; return true end
        return false
    end

    function StarPup.update(g, dt)
        g.clock = g.clock + dt
        for i = #g.popups, 1, -1 do
            local pp = g.popups[i]
            pp.t = pp.t - dt
            if pp.t <= 0 then table.remove(g.popups, i) end
        end
        if g.over then return end
        local p = g.player
        if p.dead > 0 then
            p.dead = p.dead - dt
            if p.dead <= 0 then
                if g.lives <= 0 then g.over = true return end
                g.bombs = {}
                g.pause = 1
            end
            return
        end
        if g.pause > 0 then g.pause = g.pause - dt; return end

        -- player
        local dir = (p.right and 1 or 0) - (p.left and 1 or 0)
        p.x = math.clamp(p.x + dir * P.playerSpeed * dt, 1, StarPup.cols - 1)

        -- player shot
        local s = g.shot
        if s then
            s.y = s.y - P.shotSpeed * dt
            if s.y < 0.5 then g.shot = nil
            elseif hitShield(g, s.x, s.y) then g.shot = nil
            else
                for _, f in ipairs(g.fleet) do
                    if f.alive and math.abs(f.x - s.x) < 0.8 and math.abs(f.y - s.y) < 0.6 then
                        f.alive = false
                        f.boom = 0.25
                        addScore(g, P.rowPoints[f.row], f.x, f.y)
                        g.shot = nil
                        break
                    end
                end
                local u = g.saucer
                if g.shot and u and math.abs(u.x - s.x) < 1.2 and math.abs(u.y - s.y) < 0.7 then
                    local pts = ({ 50, 100, 150, 300 })[g.rng(4)]
                    addScore(g, pts, u.x, u.y)
                    g.saucer = nil
                    g.shot = nil
                end
            end
        end

        -- fleet: one step every interval, faster as it shrinks and on later waves
        local left = aliveCount(g)
        if left == 0 then
            g.waveNo = g.waveNo + 1
            addScore(g, 100 * (g.waveNo - 1))
            StarPup.wave(g)
            return
        end
        local interval = math.max(0.05, (0.08 + 0.55 * left / (P.fleetCols * P.fleetRows)) * 0.92 ^ (g.waveNo - 1))
        g.fleetTimer = g.fleetTimer + dt
        if g.fleetTimer >= interval then
            g.fleetTimer = 0
            g.frame = 1 - g.frame
            local minX, maxX = math.huge, -math.huge
            for _, f in ipairs(g.fleet) do
                if f.alive then minX = math.min(minX, f.x); maxX = math.max(maxX, f.x) end
            end
            local step = 0.5 * g.fleetDir
            if (g.fleetDir > 0 and maxX + step > StarPup.cols - 1) or (g.fleetDir < 0 and minX + step < 1) then
                g.fleetDir = -g.fleetDir
                for _, f in ipairs(g.fleet) do f.y = f.y + P.stepDown end
            else
                for _, f in ipairs(g.fleet) do f.x = f.x + step end
            end
            -- a flea reaching the shields eats them; reaching the puppy ends the game
            for _, f in ipairs(g.fleet) do
                if f.alive then
                    for dx = -1, 1 do g.shield[math.floor(f.y) * 64 + math.floor(f.x) + 1 + dx] = nil end
                    if f.y >= P.playerY - 0.5 then g.over = true; p.dead = 1 return end
                end
            end
        end
        for _, f in ipairs(g.fleet) do
            if f.boom then f.boom = f.boom - dt; if f.boom <= 0 then f.boom = nil end end
        end

        -- bombs from the lowest flea of a random column
        g.bombTimer = g.bombTimer - dt
        if g.bombTimer <= 0 then
            g.bombTimer = math.max(0.35, 1.3 - g.waveNo * 0.1) * (0.6 + g.rng(80) / 100)
            local cols = {}
            for _, f in ipairs(g.fleet) do
                if f.alive then
                    local key = math.floor(f.x * 10 + 0.5)
                    if not cols[key] or cols[key].y < f.y then cols[key] = f end
                end
            end
            local list = {}
            for _, f in pairs(cols) do list[#list + 1] = f end
            if #list > 0 and #g.bombs < 3 + g.waveNo then
                -- favour the column above the puppy now and then
                local pick = list[g.rng(#list)]
                if g.rng(3) == 1 then
                    for _, f in ipairs(list) do if math.abs(f.x - p.x) < math.abs(pick.x - p.x) then pick = f end end
                end
                g.bombs[#g.bombs + 1] = { x = pick.x, y = pick.y + 0.6 }
            end
        end
        for i = #g.bombs, 1, -1 do
            local b = g.bombs[i]
            b.y = b.y + P.bombSpeed * (1 + (g.waveNo - 1) * 0.08) * dt
            if b.y > StarPup.rows then table.remove(g.bombs, i)
            elseif hitShield(g, b.x, b.y) then table.remove(g.bombs, i)
            elseif math.abs(b.x - p.x) < 0.8 and math.abs(b.y - P.playerY) < 0.6 then
                table.remove(g.bombs, i)
                g.lives = g.lives - 1
                p.dead = 1.4
                g.shot = nil
                return
            elseif g.shot and math.abs(b.x - g.shot.x) < 0.4 and math.abs(b.y - g.shot.y) < 0.6 then
                table.remove(g.bombs, i)
                g.shot = nil
            end
        end

        -- saucer
        if g.saucer then
            local u = g.saucer
            u.x = u.x + u.dir * 5 * dt
            if u.x < -1 or u.x > StarPup.cols + 1 then g.saucer = nil end
        else
            g.saucerTimer = g.saucerTimer - dt
            if g.saucerTimer <= 0 and left > 6 then
                g.saucerTimer = 15 + g.rng(12)
                local fromLeft = g.rng(2) == 1
                g.saucer = { x = fromLeft and -1 or StarPup.cols + 1, y = 1.4, dir = fromLeft and 1 or -1 }
            end
        end
    end

    -- grid: shields and the ground line; without sprites, the pieces as cells too
    function StarPup.draw(g, put, sprites)
        for k in pairs(g.shield) do
            local y = math.floor(k / 64)
            local x = k - y * 64
            put(x, y + 1, "shield")
        end
        for x = 1, StarPup.cols do put(x, StarPup.rows, "ground") end
        if sprites then return end
        for _, f in ipairs(g.fleet) do
            if f.alive then put(math.floor(f.x) + 1, math.floor(f.y) + 1, "flea" .. f.kind) end
        end
        if g.player.dead <= 0 then put(math.floor(g.player.x) + 1, math.floor(P.playerY) + 1, "pup") end
        if g.shot then put(math.floor(g.shot.x) + 1, math.floor(g.shot.y) + 1, "shot") end
        for _, b in ipairs(g.bombs) do put(math.floor(b.x) + 1, math.floor(b.y) + 1, "bomb") end
        if g.saucer and g.saucer.x >= 0 and g.saucer.x < StarPup.cols then put(math.floor(g.saucer.x) + 1, math.floor(g.saucer.y) + 1, "saucer") end
    end

    -- sprite list: kind, x / y in cells (centre, already +0.5 like the cell renderer), frame, scale
    function StarPup.actors(g)
        local list = {}
        for _, f in ipairs(g.fleet) do
            if f.alive then
                list[#list + 1] = { kind = "flea" .. f.kind, x = f.x + 0.5, y = f.y + 0.5, frame = g.frame, scale = 1.25 }
            elseif f.boom then
                list[#list + 1] = { kind = "boom", x = f.x + 0.5, y = f.y + 0.5, scale = 1.3 }
            end
        end
        if g.saucer then list[#list + 1] = { kind = "saucer", x = g.saucer.x + 0.5, y = g.saucer.y + 0.5, scale = 1.6 } end
        if g.shot then list[#list + 1] = { kind = "shot", x = g.shot.x + 0.5, y = g.shot.y + 0.5, scale = 0.9 } end
        for _, b in ipairs(g.bombs) do list[#list + 1] = { kind = "bomb", x = b.x + 0.5, y = b.y + 0.5, frame = math.floor(g.clock * 8) % 2, scale = 0.9 } end
        local p = g.player
        if p.dead > 0 then
            list[#list + 1] = { kind = "pupboom", x = p.x + 0.5, y = P.playerY + 0.5, scale = 1.5, frame = math.floor(g.clock * 8) % 2 }
        else
            list[#list + 1] = { kind = "pup", x = p.x + 0.5, y = P.playerY + 0.5, scale = 1.5 }
        end
        return list
    end

    -- sheet layout (64 px cells, assets/games/star_pup.png):
    -- row 0: flea1 a/b, flea2 a/b, flea3 a/b, saucer, pup;  row 1: shot, bomb a/b, boom, pupboom a/b
    local PUP_CELLS = {
        flea1 = { 0, 0 }, flea2 = { 2, 0 }, flea3 = { 4, 0 }, saucer = { 6, 0 }, pup = { 7, 0 },
        shot = { 0, 1 }, bomb = { 1, 1 }, boom = { 3, 1 }, pupboom = { 4, 1 },
    }
    function StarPup.spriteCell(a)
        local c = PUP_CELLS[a.kind] or PUP_CELLS.boom
        local animated = a.kind == "flea1" or a.kind == "flea2" or a.kind == "flea3" or a.kind == "bomb" or a.kind == "pupboom"
        return c[1] + (animated and (a.frame or 0) or 0), c[2]
    end

    function StarPup.banner(g)
        if g.over then return nil end
        if g.player.dead > 0 and g.lives > 0 then return nil end
        if g.pause > 0 then return "Wave " .. g.waveNo end
        return nil
    end

    local PUP_TILES = { shield = { 6, 1 }, ground = { 7, 1 } }
    function StarPup.cellSprite(kind) local t = PUP_TILES[kind]; if t then return t[1], t[2] end end

    function StarPup.hud(g) return "Score " .. g.score .. "   Lives " .. g.lives .. "   Wave " .. g.waveNo end



    -- Puppy Fighter (one-on-one fighting) ------------------------------------
    -- Biscuit (you) against Shadow (computer): best of three 60 s rounds.
    -- Normals chain (punch > punch > kick) and cancel into specials when they
    -- connect; air punch > air kick; Moon Flip launches and cancels into air
    -- attacks for juggles (3 max).
    -- Attack heights: high (crouching ducks it), mid, low (crouch-block only),
    -- overhead (standing block only). Blocking drains the guard meter; at zero
    -- the guard breaks (dizzy). Hitting an attack's startup is a counter hit.
    -- Each match won makes Shadow sharper and moves to the next stage; losing a
    -- match ends the run. Positions are in cells; y is the feet, growing down.
    local Fighter = {
        id = "fighter", title = "Puppy Fighter", tab = "Fighter", cols = 26, rows = 18, sprites = true, hold = true,
        sheet = "assets/games/puppy_fighter_v2.png",
        -- painted stages behind rows 2..18 (one per level, in turn), and the VS card before each match
        backdrop = { "assets/games/puppy_fighter_stage.png", "assets/games/puppy_fighter_stage_beach.png", "assets/games/puppy_fighter_stage_snow.png" },
        splash = "assets/games/puppy_fighter_vs.png",
        -- original synthesised effects in assets/sfx/fighter (.ogg, .mp3 fallback)
        sfx = { base = "assets/sfx/fighter/", names = { "punch", "kick", "swing", "block", "jump", "bark", "zap", "ko", "round", "fight", "win", "lose",
            "counter", "guardbreak", "dash", "knockdown" } },
        pads = { up = "Jump", down = "Crouch", rotate = "Kick", drop = "Punch" },
        help = "Move left / right, Up jumps, Down crouches, hold back to block. Space/J punch, R/K kick. Down+punch Bark Blast, "
            .. "Down+kick Tail Sweep, Forward+punch Pounce Dash, Forward+kick Moon Flip, air Down+kick Dive. Chain punch, punch, kick.",
    }
    MiniGames.fighter = Fighter
    local FK = { floor = 15, left = 2, right = 24, walk = 6.5, jump = 17, gravity = 46, roundTime = 60, guardMax = 100, guardRegen = 25 }
    Fighter.FK = FK
    -- startup / active / recover (s), range (cells), dmg, stun (s), push (cells/s), guard (taken when blocked)
    local MOVES = {
        punch = { startup = 0.07, active = 0.09, recover = 0.16, range = 2.7, dmg = 6, stun = 0.30, push = 4, guard = 16, level = "high", normal = true, pose = 6, chain = { punch2 = true, kick = true } },
        punch2 = { startup = 0.06, active = 0.08, recover = 0.18, range = 2.8, dmg = 5, stun = 0.32, push = 4, guard = 14, level = "high", normal = true, pose = 16, chain = { kick = true } },
        kick = { startup = 0.13, active = 0.10, recover = 0.26, range = 3.3, dmg = 9, stun = 0.38, push = 7, guard = 22, level = "mid", normal = true, pose = 7 },
        airpunch = { startup = 0.05, active = 0.16, recover = 0.08, range = 2.6, dmg = 6, stun = 0.36, push = 3, guard = 14, level = "overhead", air = true, normal = true, pose = 17, chain = { airkick = true } },
        airkick = { startup = 0.08, active = 0.22, recover = 0.08, range = 3.0, dmg = 8, stun = 0.40, push = 4, guard = 18, level = "overhead", air = true, normal = true, pose = 14 },
        bark = { startup = 0.22, active = 0, recover = 0.35, dmg = 10, stun = 0.40, push = 6, guard = 30, level = "mid", special = true, pose = 11, speed = 12, cooldown = 1.6 },
        dash = { startup = 0.10, active = 0.22, recover = 0.30, range = 2.4, dmg = 11, stun = 0.45, push = 8, guard = 26, level = "mid", special = true, pose = 16, vx = 14 },
        flip = { startup = 0.04, active = 0.24, recover = 0.42, range = 2.6, dmg = 12, stun = 0.50, push = 3, guard = 24, level = "mid", special = true, pose = 13, rise = 15, invuln = 0.22, launch = true, tall = true,
            chain = { airpunch = true, airkick = true } }, -- on hit, carry on in the air
        sweep = { startup = 0.12, active = 0.14, recover = 0.36, range = 3.4, dmg = 9, stun = 0.50, push = 4, guard = 22, level = "low", special = true, pose = 12, vx = 6, knockdown = true },
        dive = { startup = 0.06, active = 1.0, recover = 0.18, range = 2.2, dmg = 9, stun = 0.42, push = 5, guard = 20, level = "overhead", special = true, pose = 14, air = true, dive = true },
    }
    Fighter.MOVES = MOVES
    local NOCMD = { move = 0 }
    -- sounds for the window to play (g.events, emptied by the window every frame)
    local function sfx(g, name) g.events[#g.events + 1] = name end
    local function popup(g, x, y, text, life)
        g.popups[#g.popups + 1] = { x = x, y = y, text = text, t = life or 0.9, life = life or 0.9 }
    end

    local function newFighter(x, facing, index)
        return { x = x, y = FK.floor, vx = 0, vy = 0, facing = facing, hp = 100, guard = FK.guardMax, guardIdle = 9, state = "idle", t = 0, stun = 0,
            move = nil, hitDone = false, connected = false, fired = false, cool = 0, index = index, inv = 0, combo = 0, juggles = 0,
            blockHigh = false, blockLow = false, buffer = nil, bufferT = 0 }
    end

    local function startRound(g)
        g.p = newFighter(8, 1, 1)
        g.c = newFighter(18, -1, 2)
        g.shots, g.sparks = {}, {}
        g.timer = FK.roundTime
        g.pause = 1.6
        g.roundEnd, g.roundMsg = nil, nil
        g.cpuPlan, g.cpuT = { move = 0 }, 0.5
        g.wantJump, g.wantAttack = false, nil
        if g.events then sfx(g, "round") end
    end

    function Fighter.new(rng)
        local g = { rng = rng, score = 0, over = false, level = 1, stage = 1, round = 1, pWins = 0, cWins = 0, clock = 0, popups = {},
            inp = { left = false, right = false, up = false, down = false }, events = {}, splash = 2.4 }
        startRound(g)
        return g
    end

    function Fighter.input(g, a, down)
        if down == nil then down = true end
        if a == "left" or a == "right" or a == "up" or a == "down" then
            g.inp[a] = down
            if a == "up" and down then g.wantJump = true end
        elseif down and (a == "drop" or a == "rotate") then
            g.wantAttack = a == "drop" and "punch" or "kick"
        end
    end
    function Fighter.releaseAll(g) for k in pairs(g.inp) do g.inp[k] = false end end

    local function grounded(f) return f.y >= FK.floor - 0.001 end
    local function spark(g, x, y, kind) g.sparks[#g.sparks + 1] = { x = x, y = y, kind = kind, t = 0.2 } end

    local function endRound(g, msg)
        if g.roundEnd then return end
        g.roundEnd = 2.6
        g.roundMsg = msg
    end

    -- which move a button press means, from the direction held and whether the fighter is in the air
    local function resolve(f, raw, cmd, onGround)
        if not onGround then
            if raw == "kick" and cmd.crouch then return "dive" end
            return raw == "punch" and "airpunch" or "airkick"
        end
        if cmd.crouch then return raw == "punch" and "bark" or "sweep" end
        if (cmd.move or 0) == f.facing then return raw == "punch" and "dash" or "flip" end
        return raw
    end

    local function startMove(g, f, name)
        local m = MOVES[name]
        f.move, f.state, f.t = name, name, 0
        f.hitDone, f.connected, f.fired, f.rose, f.dove, f.landT = false, false, false, false, false, nil
        f.buffer, f.bufferT = nil, 0
        if m.invuln then f.inv = m.invuln end
        if name == "bark" then f.cool = m.cooldown end
        if grounded(f) and not m.vx then f.vx = 0 end
        if name == "dash" or name == "flip" then sfx(g, "dash")
        elseif name ~= "bark" then sfx(g, "swing") end
    end

    -- hitbox heights by attack level (relative to the attacker's feet)
    local function hitBand(f, m)
        if m.tall then return f.y - 8, f.y end
        if m.level == "high" then return f.y - 5.2, f.y - 3.4 end
        if m.level == "low" then return f.y - 1.6, f.y end
        if m.level == "overhead" then return f.y - 4.2, f.y + 0.8 end
        return f.y - 4.6, f.y - 1.2
    end
    local function hurtTop(o)
        local low = o.state == "crouch" or o.state == "sweep" or (o.state == "blockstun" and o.blockKind == "low")
        return o.y - (low and 3 or 5.2)
    end

    local function applyHit(g, o, a, dir, m, sx, sy)
        if o.state == "ko" then return end
        local blocked = (o.blockHigh and m.level ~= "low") or (o.blockLow and m.level ~= "overhead" and m.level ~= "high")
        if blocked then
            o.guard, o.guardIdle = o.guard - m.guard, 0
            o.hp = o.hp - math.max(1, math.floor(m.dmg / 5))
            if a then a.combo = 0 end
            if o.guard <= 0 then
                o.guard = 50
                o.state, o.t, o.stun, o.move = "dizzy", 0, 1.0, nil
                o.vx = dir * 2
                spark(g, sx, sy, "bigspark")
                popup(g, o.x, o.y - 6.5, "GUARD BREAK!", 1.2)
                sfx(g, "guardbreak")
            else
                o.blockKind = o.blockLow and "low" or "high"
                o.state, o.t, o.stun, o.move = "blockstun", 0, 0.18, nil
                o.vx = dir * 3
                spark(g, sx, sy, "blockspark")
                sfx(g, "block")
            end
        else
            local om = o.move and MOVES[o.move]
            local counter = om ~= nil and o.t <= om.startup + om.active
            local wasHurt = o.state == "hit" or o.state == "juggle" or o.state == "dizzy"
            local combo = 1
            if a then
                a.combo = wasHurt and (a.combo + 1) or 1
                combo = a.combo
            end
            local dmg = m.dmg * math.max(0.5, 1 - 0.12 * (combo - 1))
            local stun = m.stun
            if counter then
                dmg, stun = dmg * 1.4, stun + 0.15
                popup(g, o.x, o.y - 6.5, "COUNTER!", 0.9)
                sfx(g, "counter")
            end
            dmg = math.max(1, math.floor(dmg + 0.5))
            o.hp = o.hp - dmg
            o.move = nil
            if a and a.index == 1 then g.score = g.score + dmg * 10 + (combo - 1) * 50 end
            if combo >= 2 then
                for i = #g.popups, 1, -1 do if g.popups[i].combo then table.remove(g.popups, i) end end
                g.popups[#g.popups + 1] = { x = a.index == 1 and 5 or 21, y = 4, text = combo .. " HITS", t = 1.1, life = 1.1, combo = true }
            end
            if m.launch then
                o.state, o.vy, o.vx, o.juggles = "juggle", -16, dir * 2, 1
            elseif o.state == "juggle" or not grounded(o) then
                o.state, o.vy, o.vx = "juggle", -7, dir * 2.5
                o.juggles = (o.juggles or 0) + 1
            elseif m.knockdown then
                o.state, o.t, o.stun, o.vx = "down", 0, 0.8, dir * 3
                sfx(g, "knockdown")
            else
                o.state, o.t, o.stun, o.vx = "hit", 0, stun, dir * m.push
            end
            spark(g, sx, sy, counter and "bigspark" or "spark")
            if m == MOVES.bark then sfx(g, "zap") elseif m.level == "high" or m == MOVES.punch2 or m == MOVES.airpunch then sfx(g, "punch") else sfx(g, "kick") end
        end
        if o.hp <= 0 then
            o.hp = 0
            o.state, o.move = "ko", nil
            o.vx, o.vy = dir * 8, -12
            sfx(g, "ko")
            endRound(g, "K.O.!")
        end
    end

    local function tryHit(g, f, o, m)
        if o.state == "ko" or o.state == "down" or o.inv > 0 then return end
        if o.state == "juggle" and (o.juggles or 0) >= 4 then return end -- after three juggle hits they drop
        local reach = f.x + f.facing * m.range
        local x1, x2 = math.min(f.x, reach), math.max(f.x, reach)
        if o.x < x1 - 0.6 or o.x > x2 + 0.6 then return end
        local top, bottom = hitBand(f, m)
        if bottom < hurtTop(o) or top > o.y then return end
        f.hitDone, f.connected = true, true
        local sy = math.max(top, hurtTop(o)) + 0.8
        applyHit(g, o, f, f.facing, m, o.x - f.facing * 0.5, sy)
    end

    -- one fighter's turn: cmd = { move = -1/0/1, jump, crouch, attack = "punch" | "kick" (the button) }
    local function act(g, f, o, cmd, dt)
        f.cool = math.max(0, f.cool - dt)
        f.inv = math.max(0, f.inv - dt)
        f.t = f.t + dt
        f.guardIdle = f.guardIdle + dt
        if f.guardIdle > 1 and f.state ~= "dizzy" then f.guard = math.min(FK.guardMax, f.guard + FK.guardRegen * dt) end
        if f.bufferT > 0 then f.bufferT = f.bufferT - dt; if f.bufferT <= 0 then f.buffer = nil end end
        local onGround = grounded(f)
        if cmd.attack then f.buffer, f.bufferT = resolve(f, cmd.attack, cmd, onGround), 0.25 end
        if f.state == "ko" or f.state == "juggle" then return end
        if f.state == "down" then
            if f.t >= f.stun then f.state, f.inv = "idle", 0.3 end
            return
        end
        if f.state == "hit" or f.state == "blockstun" or f.state == "dizzy" then
            if f.t >= f.stun then f.state = onGround and "idle" or "jump" end
            f.blockHigh = f.state == "blockstun" and f.blockKind == "high"
            f.blockLow = f.state == "blockstun" and f.blockKind == "low"
            return
        end
        if f.move then
            local m = MOVES[f.move]
            local activeEnd = m.startup + m.active
            if m.vx then
                if f.t >= m.startup and f.t <= activeEnd then f.vx = f.facing * m.vx elseif onGround then f.vx = 0 end
            end
            if m.rise and not f.rose and f.t >= m.startup then f.rose, f.vy, f.vx = true, -m.rise, f.facing * 2 end
            if m.dive and not f.dove and f.t >= m.startup then f.dove, f.vx, f.vy = true, f.facing * 10, 12 end
            if f.move == "bark" then
                if not f.fired and f.t >= m.startup then
                    f.fired = true
                    g.shots[#g.shots + 1] = { x = f.x + f.facing * 1.4, y = f.y - 3.2, dir = f.facing, owner = f }
                    sfx(g, "bark")
                end
            elseif not f.hitDone and f.t >= m.startup and (f.t <= activeEnd or (m.dive and not onGround)) then
                tryHit(g, f, o, m)
            end
            -- chains and special cancels, only after the move connected
            local nxt = f.buffer
            if nxt and f.connected then
                if f.move == "punch" and nxt == "punch" then nxt = "punch2" end
                local nm = MOVES[nxt]
                if nm and ((m.chain and m.chain[nxt]) or (m.normal and nm.special and (nm.air == true) == not onGround)) then
                    if nxt ~= "bark" or f.cool <= 0 then startMove(g, f, nxt); return end
                end
            end
            local done
            if m.dive then
                if onGround and f.dove then
                    f.landT = f.landT or f.t
                    done = f.t - f.landT >= m.recover
                    f.vx = 0
                end
            else
                done = f.t >= activeEnd + m.recover
            end
            if done then
                f.move = nil
                f.state = onGround and "idle" or "jump"
            end
        else
            if onGround then f.facing = (o.x >= f.x) and 1 or -1 end
            local want = f.buffer
            if want and (MOVES[want].air == true) == not onGround and (want ~= "bark" or f.cool <= 0) then
                startMove(g, f, want)
            elseif onGround then
                if cmd.jump then
                    f.vy, f.vx, f.state = -FK.jump, (cmd.move or 0) * FK.walk, "jump"
                    if f.index == 1 then sfx(g, "jump") end
                elseif cmd.crouch then
                    f.state, f.vx = "crouch", 0
                elseif (cmd.move or 0) ~= 0 then
                    f.vx = cmd.move * FK.walk
                    f.state = (cmd.move == -f.facing) and "back" or "walk"
                else
                    f.vx, f.state = 0, "idle"
                end
            end
        end
        -- holding away from the opponent on the ground blocks: standing (high / mid / overhead) or crouching (low / mid)
        local free = onGround and not f.move
        f.blockHigh = free and f.state == "back"
        f.blockLow = free and f.state == "crouch" and (cmd.move or 0) == -f.facing
    end

    local function physics(g, f, dt)
        local wasAir = not grounded(f)
        if f.state == "hit" or f.state == "blockstun" or f.state == "ko" or f.state == "dizzy" or f.state == "down" then
            f.vx = f.vx * math.max(0, 1 - 5 * dt)
        end
        f.vy = f.vy + FK.gravity * dt
        f.y = f.y + f.vy * dt
        if f.y >= FK.floor then
            f.y, f.vy = FK.floor, 0
            if wasAir then
                if f.state == "juggle" then
                    f.state, f.t, f.stun, f.juggles = "down", 0, 0.6, 0
                    sfx(g, "knockdown")
                elseif f.state == "jump" then
                    f.state, f.vx = "idle", 0
                elseif f.move and MOVES[f.move].air and not MOVES[f.move].dive then
                    f.move, f.state, f.vx = nil, "idle", 0 -- landing ends air attacks
                end
            end
        end
        f.x = math.clamp(f.x + f.vx * dt, FK.left, FK.right)
    end

    local function playerCmd(g)
        local inp = g.inp
        local cmd = { move = (inp.right and 1 or 0) - (inp.left and 1 or 0), jump = g.wantJump, crouch = inp.down, attack = g.wantAttack }
        g.wantJump, g.wantAttack = false, nil
        return cmd
    end

    -- the computer: a new plan every so often; sharper with each level
    local function cpuThink(g, c, p)
        local dist = math.abs(p.x - c.x)
        local toward = (p.x >= c.x) and 1 or -1
        local lvl = g.level
        local r = g.rng(100)
        local cmd = { move = 0 }
        local cAir, pAir = not grounded(c), not grounded(p)
        -- keep a combo going
        if c.move and c.connected and r <= 30 + lvl * 12 then
            cmd.attack = (c.move == "punch" or c.move == "punch2") and (g.rng(2) == 1 and "punch" or "kick") or "punch"
            if c.move == "kick" and g.rng(2) == 1 then cmd.attack, cmd.crouch = "kick", true end
            return cmd
        end
        if cAir then
            if dist < 3.6 then cmd.attack = g.rng(3) == 1 and "punch" or "kick" end
            if dist < 5 and r <= 20 then cmd.attack, cmd.crouch = "kick", true end
            return cmd
        end
        local threat = p.move and MOVES[p.move] and not MOVES[p.move].special and p.t < 0.2 and dist < 4.2
        local lowThreat = threat and MOVES[p.move].level == "low"
        for _, s in ipairs(g.shots) do
            if s.owner == p and (c.x - s.x) * s.dir > 0 and math.abs(s.x - c.x) < 7 then threat = "shot" end
        end
        if pAir and dist < 5 and r <= 25 + lvl * 10 then
            cmd.move, cmd.attack = toward, "kick" -- Moon Flip against the jump-in
        elseif threat and r <= 20 + lvl * 12 then
            if threat == "shot" and g.rng(2) == 1 then cmd.jump, cmd.move = true, toward
            else
                cmd.move = -toward -- block; crouching against lows
                if lowThreat or g.rng(3) == 1 then cmd.crouch = true end
            end
        elseif dist > 9 then
            if c.cool <= 0 and r <= 25 + lvl * 5 then cmd.attack, cmd.crouch = "punch", true else cmd.move = toward end
        elseif dist > 3.2 then
            if r <= 12 then cmd.jump, cmd.move = true, toward
            elseif r <= 24 then cmd.move, cmd.attack = toward, "punch" -- Pounce Dash
            elseif r <= 32 and c.cool <= 0 then cmd.attack, cmd.crouch = "punch", true
            else cmd.move = toward end
        else
            if r <= 34 then cmd.attack = "punch"
            elseif r <= 54 then cmd.attack = "kick"
            elseif r <= 64 then cmd.attack, cmd.crouch = "kick", true -- Tail Sweep
            elseif r <= 76 then cmd.move, cmd.crouch = -toward, true -- crouch block
            else cmd.move = -toward end
        end
        return cmd
    end

    local function nextRound(g)
        local p, c = g.p, g.c
        local pWon = p.hp > c.hp
        local draw = p.hp == c.hp
        if pWon then
            g.pWins = g.pWins + 1
            g.score = g.score + 1000 + p.hp * 10
        elseif not draw then
            g.cWins = g.cWins + 1
        end
        if g.pWins >= 2 then
            sfx(g, "win")
            g.level = g.level + 1
            g.stage = (g.level - 1) % #Fighter.backdrop + 1
            g.score = g.score + 2000
            g.pWins, g.cWins, g.round = 0, 0, 1
            g.splash = 2.4 -- VS card before the next match
            popup(g, 13, 8, "Shadow gets tougher!", 1.6)
        elseif g.cWins >= 2 then
            sfx(g, "lose")
            g.over = true
            return
        else
            g.round = g.round + 1
        end
        startRound(g)
    end

    function Fighter.update(g, dt)
        g.clock = g.clock + dt
        for i = #g.popups, 1, -1 do
            local pp = g.popups[i]
            pp.t = pp.t - dt
            if pp.t <= 0 then table.remove(g.popups, i) end
        end
        for i = #g.sparks, 1, -1 do
            local s = g.sparks[i]
            s.t = s.t - dt
            if s.t <= 0 then table.remove(g.sparks, i) end
        end
        if g.over then return end
        local p, c = g.p, g.c
        if (g.splash or 0) > 0 then g.splash = g.splash - dt; g.wantJump, g.wantAttack = false, nil; return end
        if g.pause > 0 then
            g.pause = g.pause - dt
            g.wantJump, g.wantAttack = false, nil
            if g.pause <= 0 then sfx(g, "fight") end
            return
        end
        local pcmd, ccmd = NOCMD, NOCMD
        if not g.roundEnd then
            pcmd = playerCmd(g)
            g.cpuT = g.cpuT - dt
            if g.cpuT <= 0 then
                g.cpuPlan = cpuThink(g, c, p)
                g.cpuT = math.max(0.1, 0.36 - g.level * 0.04) * (0.7 + g.rng(60) / 100)
            end
            ccmd = g.cpuPlan
        end
        act(g, p, c, pcmd, dt)
        act(g, c, p, ccmd, dt)
        if g.cpuPlan then g.cpuPlan.attack, g.cpuPlan.jump = nil, nil end
        physics(g, p, dt)
        physics(g, c, dt)
        -- bodies do not overlap (except someone on the floor)
        local solid = function(f) return f.state ~= "ko" and f.state ~= "down" end
        if solid(p) and solid(c) and math.abs(p.y - c.y) < 3 then
            local gap = c.x - p.x
            if math.abs(gap) < 1.8 then
                local push = (1.8 - math.abs(gap)) / 2 * (gap >= 0 and 1 or -1)
                p.x = math.clamp(p.x - push, FK.left, FK.right)
                c.x = math.clamp(c.x + push, FK.left, FK.right)
            end
        end
        -- Bark Blasts
        local bm = MOVES.bark
        for i = #g.shots, 1, -1 do
            local s = g.shots[i]
            s.x = s.x + s.dir * bm.speed * dt
            local target = s.owner == p and c or p
            local gone = s.x < 0 or s.x > Fighter.cols
            if not gone and math.abs(target.x - s.x) < 1.1 and s.y >= hurtTop(target) - 0.5 and s.y <= target.y
                and target.state ~= "ko" and target.state ~= "down" and target.inv <= 0 then
                applyHit(g, target, s.owner, s.dir, bm, s.x, s.y)
                gone = true
            end
            for j = #g.shots, 1, -1 do
                local o = g.shots[j]
                if j ~= i and o.owner ~= s.owner and math.abs(o.x - s.x) < 0.8 then
                    spark(g, s.x, s.y, "spark")
                    o.x = -99 -- removed on its own turn
                    gone = true
                end
            end
            if gone then table.remove(g.shots, i) end
        end
        if not g.roundEnd then
            g.timer = g.timer - dt
            if g.timer <= 0 then g.timer = 0; endRound(g, "Time!") end
        else
            g.roundEnd = g.roundEnd - dt
            if g.roundEnd <= 0 then nextRound(g) end
        end
    end

    -- HUD in the grid: health (row 1), guard (row 2, over the stage); the stage itself is a picture
    function Fighter.draw(g, put, sprites)
        local cols = Fighter.cols
        local pBar = math.ceil(g.p.hp / 100 * 11)
        local cBar = math.ceil(g.c.hp / 100 * 11)
        for x = 1, 11 do put(x, 1, x <= pBar and "hp1" or "hpEmpty") end
        for x = 1, 11 do put(cols + 1 - x, 1, x <= cBar and "hp2" or "hpEmpty") end
        put(12, 1, g.pWins >= 1 and "winOn" or "winOff")
        put(13, 1, g.pWins >= 2 and "winOn" or "winOff")
        put(14, 1, g.cWins >= 2 and "winOn" or "winOff")
        put(15, 1, g.cWins >= 1 and "winOn" or "winOff")
        local pG = math.ceil(g.p.guard / FK.guardMax * 8)
        local cG = math.ceil(g.c.guard / FK.guardMax * 8)
        local flashP = g.p.state == "dizzy" and math.floor(g.clock * 8) % 2 == 0
        local flashC = g.c.state == "dizzy" and math.floor(g.clock * 8) % 2 == 0
        for x = 1, 8 do put(x, 2, (x <= pG and not flashP) and "gd" or "gdEmpty") end
        for x = 1, 8 do put(cols + 1 - x, 2, (x <= cG and not flashC) and "gd" or "gdEmpty") end
        if g.backdropShown then return end -- the painted stage is behind the board
        for y = 2, Fighter.rows do
            local kind = y <= 5 and "sky1" or (y <= 9 and "sky2" or (y <= 11 and "sky3" or (y <= 15 and "fence" or (y == 16 and "groundTop" or "dirt"))))
            for x = 1, cols do
                if not (y == 2 and (x <= 8 or x > cols - 8)) then put(x, y, kind) end
            end
        end
        if sprites then return end
        for _, f in ipairs({ g.p, g.c }) do
            put(math.floor(f.x) + 1, math.max(1, math.floor(f.y - 1) + 1), "f" .. f.index)
            put(math.floor(f.x) + 1, math.max(1, math.floor(f.y - 3) + 1), "f" .. f.index)
        end
        for _, s in ipairs(g.shots) do
            if s.x >= 0 and s.x < cols then put(math.floor(s.x) + 1, math.floor(s.y) + 1, "bark") end
        end
    end

    -- poses: 0 idle, 1 idle, 2 walk, 3 walk, 4 jump, 5 crouch, 6 punch, 7 kick, 8 block, 9 hit, 10 down / KO,
    -- 11 bark, 12 sweep, 13 flip, 14 air kick / dive, 15 dizzy, 16 lunge (punch 2, dash), 17 air punch
    local STATE_POSE = { idle = 0, walk = 2, back = 2, jump = 4, crouch = 5, hit = 9, juggle = 9, down = 10, ko = 10, dizzy = 15 }
    local FIGHTER_SCALE = 4.6 -- sprite height about 6.2 cells
    function Fighter.actors(g)
        local list = {}
        local half = 1.35 * FIGHTER_SCALE / 2
        for _, f in ipairs({ g.p, g.c }) do
            list[#list + 1] = { kind = "shadow", x = f.x + 0.5, y = FK.floor + 0.3, scale = 1.8 }
        end
        for _, f in ipairs({ g.p, g.c }) do
            local pose
            if f.move then pose = MOVES[f.move].pose
            elseif f.state == "blockstun" then pose = f.blockKind == "low" and 5 or 8
            else pose = STATE_POSE[f.state] or 0 end
            if f.state == "idle" then pose = math.floor(g.clock * 3) % 2
            elseif f.state == "walk" or (f.state == "back" and not f.blockHigh) then pose = 2 + math.floor(g.clock * 8) % 2
            elseif f.state == "back" then pose = 8 end
            local blink = f.inv > 0 and f.state ~= "down" and math.floor(g.clock * 20) % 2 == 0
            if not blink then
                list[#list + 1] = { kind = "f" .. f.index, frame = pose, dir = f.facing, x = f.x + 0.5, y = f.y - half + 0.5, scale = FIGHTER_SCALE }
            end
            if f.state == "dizzy" then
                list[#list + 1] = { kind = "stars", x = f.x + 0.5, y = f.y - 6.2 + 0.5, scale = 1.6 }
            end
        end
        for _, s in ipairs(g.shots) do
            -- (a shot cancelled by another one waits off-screen for its removal)
            if s.x >= 0 and s.x <= Fighter.cols then
                list[#list + 1] = { kind = s.dir > 0 and "barkR" or "barkL", x = s.x + 0.5, y = s.y + 0.5, scale = 1.7 }
            end
        end
        for _, s in ipairs(g.sparks) do
            list[#list + 1] = { kind = s.kind, x = s.x + 0.5, y = s.y + 0.5, scale = (s.kind == "bigspark" and 2.2 or 1.4) + (0.2 - s.t) * 4 }
        end
        return list
    end

    -- sheet (64 px cells, 8 columns): fighter i, facing (right / left) -> 18 poses from cell ((i - 1) * 2 + facing) * 18;
    -- effects on row 9, stage / HUD tiles on rows 10-11
    local POSES_PER = 18
    local FX = { barkR = { 0, 9 }, barkL = { 1, 9 }, spark = { 2, 9 }, blockspark = { 3, 9 }, shadow = { 4, 9 }, bigspark = { 5, 9 }, stars = { 6, 9 } }
    function Fighter.spriteCell(a)
        if a.kind == "f1" or a.kind == "f2" then
            local i = a.kind == "f1" and 0 or 1
            local idx = (i * 2 + (a.dir == -1 and 1 or 0)) * POSES_PER + (a.frame or 0)
            return idx % 8, math.floor(idx / 8)
        end
        local c = FX[a.kind] or FX.spark
        return c[1], c[2]
    end
    local FIGHT_TILES = {
        sky1 = { 0, 10 }, sky2 = { 1, 10 }, sky3 = { 2, 10 }, fence = { 3, 10 }, groundTop = { 4, 10 }, dirt = { 5, 10 },
        hp1 = { 6, 10 }, hp2 = { 7, 10 }, hpEmpty = { 0, 11 }, winOn = { 1, 11 }, winOff = { 2, 11 }, gd = { 3, 11 }, gdEmpty = { 4, 11 },
    }
    function Fighter.cellSprite(kind) local t = FIGHT_TILES[kind]; if t then return t[1], t[2] end end

    function Fighter.banner(g)
        if g.over or (g.splash or 0) > 0 then return nil end
        if g.pause > 0 then return g.pause > 0.6 and ("Round " .. g.round) or "Fight!" end
        if g.roundEnd then
            if g.roundEnd > 1.3 then return g.roundMsg end
            if g.p.hp == g.c.hp then return "Draw" end
            return g.p.hp > g.c.hp and "Biscuit wins the round" or "Shadow wins the round"
        end
        return nil
    end

    function Fighter.hud(g)
        return string.format("Biscuit %d   %02d   Shadow %d   Lv %d   Score %d", g.p.hp, math.ceil(g.timer), g.c.hp, g.level, g.score)
    end

    MiniGames.list = { Snake, Stack, Chase, StarPup, Fighter }
end
return MiniGames
end)()

-- Mini games window: tabs, a cell grid per game, keyboard (arrows / WASD,
-- Space drops, P pauses) and on-screen buttons for touch.
local function buildGamesPanel(screenGui)
    local W, HGT = 360, 574
    local f = uiWindow(screenGui, "games", "Mini games", UDim2.fromOffset(W, HGT), UDim2.new(0.5, -W / 2, 0.5, -HGT / 2))
    local rngObj = Random.new()
    local function rng(n) return rngObj:NextInteger(1, n) end
    if type(Cfg.games) ~= "table" then Cfg.games = {} end

    local mg, state, status = MiniGames.list[1], nil, "idle" -- idle | play | pause | over
    local cells, cur, nextK, cols, rows = {}, {}, {}, 0, 0
    local pcells, pcur = {}, {}
    local held = {}
    -- sprite layer (games with actors, e.g. Treat Chase): pooled images over the board
    local sheets, spriteLayer, cellSize = {}, nil, 1 -- game id -> sprite sheet content id
    local backdrops, splashes = {}, {}                 -- game id -> background pictures (by stage) / intro card
    local backdropImg, splashImg
    local function backdropPic()
        local set = backdrops[mg.id]
        if not set then return nil end
        return set[(state and state.stage) or 1] or set[1]
    end
    local sprites, popLbls = {}, {}

    local PIECE = {
        Color3.fromRGB(255, 140, 200), Color3.fromRGB(255, 214, 110), Color3.fromRGB(190, 140, 255),
        Color3.fromRGB(120, 200, 255), Color3.fromRGB(255, 160, 110), Color3.fromRGB(130, 230, 170),
        Color3.fromRGB(255, 120, 140),
    }
    -- kind -> colour, transparency, dot size (nil = whole cell)
    local function style(kind)
        -- maze paths stay faint so the walls and pieces stand out
        if kind == "empty" then
            if mg.backdrop and backdropPic() then return PAL.ELEVATED, 1 end -- the painted stage shows through
            return PAL.ELEVATED, mg.sprites and 0.88 or 0.55
        end
        if kind:sub(1, 5) == "head_" then return PAL.ACCENT, 0 end
        if kind:sub(1, 5) == "body_" or kind:sub(1, 5) == "tail_" or kind:sub(1, 7) == "corner_" then return PAL.GOOD, 0.1 end
        if kind == "food" then return Color3.fromRGB(255, 120, 180), 0, 0.7 end
        if kind == "ghost" then return PAL.DIM, 0.75 end
        if kind == "wall" then return PAL.ACCENT, 0.45 end
        if kind == "wallflash" then return Color3.fromRGB(255, 255, 255), 0.15 end
        if kind == "shield" then return Color3.fromRGB(150, 210, 120), 0.05 end
        if kind == "ground" then return Color3.fromRGB(120, 200, 110), 0.5 end
        if kind == "flea1" then return Color3.fromRGB(120, 220, 110), 0 end
        if kind == "flea2" then return Color3.fromRGB(230, 110, 210), 0 end
        if kind == "flea3" then return Color3.fromRGB(110, 210, 240), 0 end
        if kind == "pup" then return Color3.fromRGB(230, 70, 80), 0 end
        if kind == "shot" then return Color3.fromRGB(255, 250, 200), 0, 0.4 end
        if kind == "bomb" then return Color3.fromRGB(255, 120, 60), 0, 0.4 end
        if kind == "saucer" then return Color3.fromRGB(240, 90, 160), 0 end
        if kind == "snack" then return Color3.fromRGB(230, 140, 60), 0, 0.7 end
        if kind == "door" then return Color3.fromRGB(255, 200, 230), 0.3, 0.35 end
        if kind == "treat" then return Color3.fromRGB(255, 230, 180), 0, 0.25 end
        if kind == "bone" then return Color3.fromRGB(255, 255, 255), 0, 0.6 end
        if kind == "puppy" then return Color3.fromRGB(255, 176, 90), 0 end
        if kind == "cat1" then return Color3.fromRGB(180, 120, 255), 0 end
        if kind == "cat2" then return Color3.fromRGB(90, 200, 255), 0 end
        if kind == "cat3" then return Color3.fromRGB(255, 110, 120), 0 end
        if kind == "scared" then return Color3.fromRGB(70, 90, 210), 0 end
        if kind == "scared2" then return Color3.fromRGB(235, 235, 255), 0 end
        if kind == "eyes" then return Color3.fromRGB(255, 255, 255), 0, 0.4 end
        local n = tonumber(kind:match("^p(%d)$"))
        if n then return PIECE[n] or PAL.ACCENT, 0 end
        return PAL.ELEVATED, 0.55
    end

    local tabs = {}
    local tabW = (W - 32 - (#MiniGames.list - 1) * 6) / #MiniGames.list
    local hud = label(f, { Position = UDim2.fromOffset(16, 82), Size = UDim2.fromOffset(W - 32, 18), TextSize = 12, Text = "" })
    local bestLbl = label(f, { Position = UDim2.fromOffset(16, 82), Size = UDim2.fromOffset(W - 32, 18), TextSize = 12,
        TextXAlignment = Enum.TextXAlignment.Right, TextColor3 = PAL.DIM, Text = "" })
    local holder = make("Frame", { Name = "PuppyAdminGameBoard", Position = UDim2.fromOffset(16, 106), Size = UDim2.fromOffset(W - 32, 306),
        BackgroundTransparency = 1 }, f)
    local board = make("Frame", { BackgroundColor3 = Color3.fromRGB(8, 8, 8), BackgroundTransparency = 0.35, BorderSizePixel = 0 }, holder)
    corner(board, 6)
    local preview = make("Frame", { BackgroundTransparency = 1, Visible = false }, holder)
    local msg = label(holder, { Size = UDim2.new(1, 0, 0, 40), Position = UDim2.new(0, 0, 0.5, -20), ZIndex = 5,
        TextXAlignment = Enum.TextXAlignment.Center, Font = Enum.Font.GothamBold, TextSize = 16, TextStrokeTransparency = 0.4, Text = "" })

    local function newCell(parent, cs, x, y)
        -- layers (explicit, so they hold whether the ScreenGui sorts ZIndex globally or per sibling):
        -- board 1, stage picture 1 (child of the board), cells 2, cell tile / dot 3, sprites 7
        local c = make("Frame", { Size = UDim2.fromOffset(cs - 1, cs - 1), Position = UDim2.fromOffset((x - 1) * cs, (y - 1) * cs),
            BorderSizePixel = 0, BackgroundColor3 = PAL.ELEVATED, BackgroundTransparency = 0.55, ZIndex = 2 }, parent)
        corner(c, math.max(2, math.floor(cs / 4)))
        local d = make("Frame", { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromScale(0.3, 0.3),
            BorderSizePixel = 0, Visible = false, ZIndex = 3 }, c)
        corner(d, 50)
        local img = make("ImageLabel", { Size = UDim2.new(1, 1, 1, 1), BackgroundTransparency = 1, Visible = false,
            ImageRectSize = Vector2.new(64, 64), ZIndex = 3 }, c)
        return { frame = c, dot = d, img = img }
    end

    local function paint(cell, kind)
        local sheet = sheets[mg.id]
        local col, row
        if sheet and mg.cellSprite then col, row = mg.cellSprite(kind) end
        if col then
            local ec, et = style("empty")
            cell.frame.BackgroundColor3, cell.frame.BackgroundTransparency = ec, et
            cell.dot.Visible = false
            cell.img.Image = sheet
            cell.img.ImageRectOffset = Vector2.new(col * 64, row * 64)
            cell.img.Visible = true
            return
        end
        cell.img.Visible = false
        local color, tr, dot = style(kind)
        if dot then
            local ec, et = style("empty")
            cell.frame.BackgroundColor3, cell.frame.BackgroundTransparency = ec, et
            cell.dot.Visible = true
            cell.dot.BackgroundColor3, cell.dot.BackgroundTransparency = color, tr
            cell.dot.Size = UDim2.fromScale(dot, dot)
        else
            cell.frame.BackgroundColor3, cell.frame.BackgroundTransparency = color, tr
            cell.dot.Visible = false
        end
    end

    local function buildBoard()
        if spriteLayer then spriteLayer:Destroy(); spriteLayer = nil end
        if backdropImg then backdropImg:Destroy(); backdropImg = nil end
        if splashImg then splashImg:Destroy(); splashImg = nil end
        sprites, popLbls = {}, {}
        for _, c in ipairs(cells) do c.frame:Destroy() end
        for _, ch in ipairs(preview:GetChildren()) do ch:Destroy() end
        cells, cur, pcells, pcur = {}, {}, {}, {}
        cols, rows = mg.cols, mg.rows
        local hasPreview = mg.preview ~= nil
        local availW = W - 32 - (hasPreview and 70 or 0)
        local cs = math.floor(math.min(availW / cols, 306 / rows))
        local bw, bh = cs * cols, cs * rows
        local left = math.floor((availW - bw) / 2)
        board.Size = UDim2.fromOffset(bw + 2, bh + 2)
        board.Position = UDim2.fromOffset(left - 1, 0)
        cellSize = cs
        for y = 1, rows do
            for x = 1, cols do
                local c = newCell(board, cs, x, y)
                c.frame.Position = c.frame.Position + UDim2.fromOffset(1, 1)
                cells[#cells + 1] = c
            end
        end
        if mg.backdrop then
            -- the picture covers rows 2 .. last (row 1 is the HUD)
            backdropImg = make("ImageLabel", { Name = "Backdrop", Position = UDim2.fromOffset(1, 1 + cs), Size = UDim2.fromOffset(cs * cols, cs * (rows - 1)),
                BackgroundTransparency = 1, ScaleType = Enum.ScaleType.Stretch, ZIndex = 1, Visible = false }, board)
        end
        if mg.splash then
            splashImg = make("ImageLabel", { Name = "Splash", Position = UDim2.fromOffset(0, 0), Size = UDim2.new(1, 0, 1, 0),
                BackgroundTransparency = 1, ScaleType = Enum.ScaleType.Fit, ZIndex = 20, Visible = false }, board)
        end
        if mg.actors then
            spriteLayer = make("Frame", { Name = "Sprites", Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, ZIndex = 6 }, board)
        end
        preview.Visible = hasPreview
        if hasPreview then
            local ps = 14
            preview.Position = UDim2.fromOffset(left + bw + 14, 4)
            preview.Size = UDim2.fromOffset(ps * 4, ps * 2 + 20)
            label(preview, { Name = "Title", Size = UDim2.fromOffset(ps * 4, 16), Text = "Next", TextSize = 11, TextColor3 = PAL.DIM })
            for y = 1, 2 do
                for x = 1, 4 do
                    local c = newCell(preview, ps, x, y)
                    c.frame.Position = c.frame.Position + UDim2.fromOffset(0, 20)
                    pcells[#pcells + 1] = c
                end
            end
        end
    end

    -- sheet cell (column, row) of an actor; layout in assets/games/treat_chase.png (64 px cells)
    local DIR_INDEX = { right = 0, left = 1, up = 2, down = 3 }
    local FIXED = { scared = { 4, 2 }, scared2 = { 5, 2 }, eyes = { 6, 2 }, snack = { 7, 2 }, treat = { 0, 3 }, bone = { 1, 3 } }
    local function spriteCell(a)
        if mg.spriteCell then return mg.spriteCell(a) end
        local d = DIR_INDEX[a.dir or "right"] or 0
        if a.kind == "puppy" then return d * 2 + (a.frame or 0), 0 end
        local n = tonumber(a.kind:match("^cat(%d)$"))
        if n then
            local idx = (n - 1) * 4 + d
            return idx % 8, 1 + math.floor(idx / 8)
        end
        local fx = FIXED[a.kind] or FIXED.treat
        return fx[1], fx[2]
    end

    local function drawActors()
        if not spriteLayer then return end
        local list = (state and sheets[mg.id]) and mg.actors(state) or {}
        for i, a in ipairs(list) do
            local img = sprites[i]
            if not img then
                img = make("ImageLabel", {
                    BackgroundTransparency = 1, AnchorPoint = Vector2.new(0.5, 0.5), ImageRectSize = Vector2.new(64, 64), ZIndex = 7,
                }, spriteLayer)
                sprites[i] = img
            end
            local col, row = spriteCell(a)
            local size = cellSize * 1.35 * (a.scale or 1)
            local rot = 0
            if a.dying then size = size * math.max(0, 1 - a.dying); rot = a.dying * 720 end
            img.Image = sheets[mg.id]
            img.ImageRectOffset = Vector2.new(col * 64, row * 64)
            img.Size = UDim2.fromOffset(size, size)
            img.Rotation = rot
            img.Position = UDim2.fromOffset(1 + (a.x - 0.5) * cellSize, 1 + (a.y - 0.5) * cellSize)
            img.Visible = true
        end
        for i = #list + 1, #sprites do sprites[i].Visible = false end
        -- score pop-ups rise and fade
        local pops = state and state.popups or {}
        for i, pp in ipairs(pops) do
            local l = popLbls[i]
            if not l then
                l = label(spriteLayer, { AnchorPoint = Vector2.new(0.5, 0.5), Size = UDim2.fromOffset(60, 16), ZIndex = 8,
                    TextXAlignment = Enum.TextXAlignment.Center, Font = Enum.Font.GothamBold, TextSize = 12,
                    TextColor3 = Color3.fromRGB(255, 221, 150), TextStrokeTransparency = 0.3 })
                popLbls[i] = l
            end
            local k = 1 - pp.t / pp.life
            l.Text = pp.text
            l.Position = UDim2.fromOffset(1 + (pp.x - 0.5) * cellSize, 1 + (pp.y - 0.5 - k) * cellSize)
            l.TextTransparency = math.max(0, k * 1.2 - 0.2)
            l.Visible = true
        end
        for i = #pops + 1, #popLbls do popLbls[i].Visible = false end
    end

    local function render()
        local n = cols * rows
        for i = 1, n do nextK[i] = "empty" end
        local pic = backdropPic()
        if backdropImg then
            backdropImg.Visible = pic ~= nil
            if pic and backdropImg.Image ~= pic then backdropImg.Image = pic end
        end
        if splashImg then
            local card, t = splashes[mg.id], state and state.splash or 0
            splashImg.Visible = card ~= nil and t > 0
            if card and t > 0 then
                if splashImg.Image ~= card then splashImg.Image = card end
                splashImg.ImageTransparency = t < 0.4 and (1 - t / 0.4) or 0 -- fades out at the end
            end
        end
        if state then
            if state.backdropShown ~= (pic ~= nil) then cur = {} end -- the stage picture appeared / changed: repaint the grid
            state.backdropShown = pic ~= nil
        end
        if state then
            mg.draw(state, function(x, y, k)
                if x >= 1 and x <= cols and y >= 1 and y <= rows then nextK[(y - 1) * cols + x] = k end
            end, mg.sprites == true and sheets[mg.id] ~= nil)
        end
        drawActors()
        if status == "play" then msg.Text = (state and mg.banner and mg.banner(state)) or "" end
        for i = 1, n do
            if nextK[i] ~= cur[i] and cells[i] then paint(cells[i], nextK[i]); cur[i] = nextK[i] end
        end
        if #pcells > 0 then
            local pk = {}
            for i = 1, 8 do pk[i] = "empty" end
            if state and not state.over then
                mg.preview(state, function(x, y, k) if x >= 1 and x <= 4 and y >= 1 and y <= 2 then pk[(y - 1) * 4 + x] = k end end)
            end
            for i = 1, 8 do
                if pk[i] ~= pcur[i] then paint(pcells[i], pk[i]); pcur[i] = pk[i] end
            end
        end
        hud.Text = state and mg.hud(state) or mg.title
        bestLbl.Text = "Best " .. tostring(tonumber(Cfg.games[mg.id]) or 0)
    end

    local startBtn
    local function setStatus(s)
        status = s
        for k in pairs(held) do held[k] = nil end
        if state and mg.releaseAll then mg.releaseAll(state) end
        if s == "idle" then msg.Text = "Press Start"
        elseif s == "pause" then msg.Text = "Paused"
        elseif s == "over" then
            local best = tonumber(Cfg.games[mg.id]) or 0
            local score = state and math.floor(state.score) or 0
            if score > best then
                Cfg.games[mg.id] = score
                cfgSave()
                msg.Text = (state.won and "Board full! " or "Game over - ") .. "new best " .. score
            else
                msg.Text = (state and state.won and "Board full! " or "Game over - ") .. "score " .. score
            end
        else msg.Text = "" end
        if startBtn then startBtn.Text = s == "play" and "Pause" or (s == "pause" and "Resume" or "Start") end
    end

    local function newGame()
        state = mg.new(rng)
        setStatus("play")
        render()
    end

    local function paintTabs()
        for _, t in ipairs(tabs) do
            t.btn.BackgroundColor3 = t.mg == mg and PAL.ELEVATED or PAL.CARD
            t.btn.TextColor3 = t.mg == mg and PAL.TEXT or PAL.DIM
        end
    end

    local loadSfxFor -- set once the sound loader exists
    local function selectGame(g)
        mg = g
        state = nil
        paintTabs()
        if loadSfxFor then loadSfxFor(g) end
        if UIAPI.gamesRelabel then UIAPI.gamesRelabel() end
        buildBoard()
        setStatus("idle")
        render()
    end

    local helpLbl
    for i, g in ipairs(MiniGames.list) do
        local b = uiButton(f, g.tab or g.title, UDim2.fromOffset(tabW, 28), UDim2.fromOffset(16 + (i - 1) * (tabW + 6), 46), function()
            selectGame(g)
            helpLbl.Text = g.help
        end)
        b.TextSize = 11
        tabs[i] = { btn = b, mg = g }
    end


    -- down = false only for games with hold = true (key / button released)
    local function act(a, down)
        if status ~= "play" or not state then return end
        mg.input(state, a, down ~= false)
        render()
    end

    local bw = (W - 32 - 4 * 6) / 5
    startBtn = uiButton(f, "Start", UDim2.fromOffset(bw, 30), UDim2.fromOffset(16, 420), function()
        if status == "play" then setStatus("pause")
        elseif status == "pause" then setStatus("play")
        else newGame() end
    end)
    uiButton(f, "Restart", UDim2.fromOffset(bw, 30), UDim2.fromOffset(16 + (bw + 6), 420), newGame)
    uiButton(f, "Game Boy", UDim2.fromOffset(bw, 30), UDim2.fromOffset(16 + (bw + 6) * 2, 420), function() H.gameboy() end).TextSize = 11
    uiButton(f, "GBA", UDim2.fromOffset(bw, 30), UDim2.fromOffset(16 + (bw + 6) * 3, 420), function() H.gba() end)
    uiButton(f, "Doom", UDim2.fromOffset(bw, 30), UDim2.fromOffset(16 + (bw + 6) * 4, 420), function() H.doom() end)
    local pads = { { "Left", "left" }, { "Up", "up" }, { "Down", "down" }, { "Right", "right" }, { "Rotate", "rotate" }, { "Drop", "drop" } }
    local pw = (W - 32 - (#pads - 1) * 6) / #pads
    local padButtons = {}
    for i, p in ipairs(pads) do
        local b = uiButton(f, p[1], UDim2.fromOffset(pw, 30), UDim2.fromOffset(16 + (i - 1) * (pw + 6), 458), function()
            if not mg.hold then act(p[2]) end
        end)
        -- hold games: pressed while the finger / button is down
        b.InputBegan:Connect(function(input) if mg.hold and isPointer(input) then act(p[2], true) end end)
        b.InputEnded:Connect(function(input) if mg.hold and isPointer(input) then act(p[2], false) end end)
        b.TextSize = 11
        padButtons[i] = { btn = b, action = p[2], default = p[1] }
    end
    -- a game can rename the buttons (Puppy Fighter: Jump / Crouch / Kick / Punch)
    UIAPI.gamesRelabel = function()
        for _, pb in ipairs(padButtons) do pb.btn.Text = (mg.pads and mg.pads[pb.action]) or pb.default end
    end
    UIAPI.gamesRelabel()
    helpLbl = label(f, { Position = UDim2.fromOffset(16, 496), Size = UDim2.fromOffset(W - 32, 34), TextWrapped = true, TextSize = 11,
        TextColor3 = PAL.DIM, TextYAlignment = Enum.TextYAlignment.Top, Text = mg.help })
    label(f, { Position = UDim2.fromOffset(16, 532), Size = UDim2.fromOffset(W - 32, 30), TextWrapped = true, TextSize = 10,
        TextColor3 = PAL.DIM, TextYAlignment = Enum.TextYAlignment.Top,
        Text = "While a game runs, arrows / WASD / Space / R / J / K go to the game, not your character. P pauses." })

    -- keyboard: only while this window is open; keys pass through to the
    -- character unless a game is being played
    local KEYMAP = {
        [Enum.KeyCode.Left] = "left", [Enum.KeyCode.A] = "left", [Enum.KeyCode.Right] = "right", [Enum.KeyCode.D] = "right",
        [Enum.KeyCode.Up] = "up", [Enum.KeyCode.W] = "up", [Enum.KeyCode.Down] = "down", [Enum.KeyCode.S] = "down",
        [Enum.KeyCode.Space] = "drop", [Enum.KeyCode.R] = "rotate", [Enum.KeyCode.J] = "drop", [Enum.KeyCode.K] = "rotate",
    }
    local ACTION = "PuppyAdminGames"
    local bound = false
    local function onKey(_, inputState, input)
        local kc = input.KeyCode
        if kc == Enum.KeyCode.P then
            if inputState ~= Enum.UserInputState.Begin then return Enum.ContextActionResult.Sink end
            if status == "play" then setStatus("pause"); return Enum.ContextActionResult.Sink end
            if status == "pause" then setStatus("play"); return Enum.ContextActionResult.Sink end
            return Enum.ContextActionResult.Pass
        end
        if status ~= "play" then return Enum.ContextActionResult.Pass end
        local a = KEYMAP[kc]
        if not a then return Enum.ContextActionResult.Pass end
        if inputState == Enum.UserInputState.Begin then
            act(a)
            if mg.repeatKeys and mg.repeatKeys[a] then held[a] = os.clock() + 0.17 end
        elseif inputState == Enum.UserInputState.End or inputState == Enum.UserInputState.Cancel then
            held[a] = nil
            if mg.hold then act(a, false) end
        end
        return Enum.ContextActionResult.Sink
    end
    local keys = { Enum.KeyCode.P }
    for kc in pairs(KEYMAP) do keys[#keys + 1] = kc end
    local function bind(on)
        if on == bound then return end
        bound = on
        if on then
            pcall(function() ContextActionService:BindActionAtPriority(ACTION, onKey, false, 3000, table.unpack(keys)) end)
        else
            pcall(function() ContextActionService:UnbindAction(ACTION) end)
        end
    end

    local playSfx -- game sound effects (defined with their loader below)
    local loop
    local function stopLoop()
        if loop then loop:Disconnect(); loop = nil end
    end
    local function startLoop()
        if loop then return end
        loop = RunService.Heartbeat:Connect(function(dt)
            if status ~= "play" or not state then return end
            dt = math.min(dt, 0.1)
            local now = os.clock()
            for a, t in pairs(held) do
                if now >= t then held[a] = now + 0.05; mg.input(state, a) end
            end
            mg.update(state, dt)
            if state.events and #state.events > 0 then
                for _, name in ipairs(state.events) do playSfx(name) end
                table.clear(state.events)
            end
            if state.over then setStatus("over") end
            render()
        end)
        table.insert(conns, loop)
    end

    f:GetPropertyChangedSignal("Visible"):Connect(function()
        if f.Visible then
            bind(true)
            startLoop()
            render()
        else
            if status == "play" then setStatus("pause") end
            bind(false)
            stopLoop()
        end
    end)
    table.insert(conns, UserInputService.WindowFocusReleased:Connect(function()
        if status == "play" then setStatus("pause") end
    end))
    table.insert(Theme.listeners, function()
        cur, pcur = {}, {}
        paintTabs()
        render()
    end)
    table.insert(cleanups, function() bind(false); stopLoop() end)

    -- Sound effects for games that have them (mg.sfx): loaded once per game,
    -- .ogg first and .mp3 if Roblox does not load those; two copies of each
    -- sound so quick hits can overlap. The level follows the sound setting in
    -- the Game Boy window (Cfg.gbVolume).
    local sfxSets = {} -- game id -> { name -> { pool, next } } | "loading" | false
    local function loadSfx(g)
        if not g.sfx or sfxSets[g.id] ~= nil then return end
        sfxSets[g.id] = "loading"
        task.spawn(function()
            local service = game:GetService("SoundService")
            for _, ext in ipairs({ "ogg", "mp3" }) do
                local set, made, ok = {}, {}, true
                for _, name in ipairs(g.sfx.names) do
                    local id = urlImageAsset(SETTINGS.Auras.assetBase .. g.sfx.base .. name .. "." .. ext, "gamesfx")
                    if not id then ok = false; break end
                    local pool = {}
                    for k = 1, 2 do
                        local snd = Instance.new("Sound")
                        snd.Name = "PuppyAdminSfx_" .. name
                        snd.SoundId = id
                        snd.Volume = 0
                        snd.Parent = service
                        pool[k] = snd
                        made[#made + 1] = snd
                    end
                    set[name] = { pool = pool, next = 1 }
                end
                if ok then
                    local t0, loaded = os.clock(), false
                    while os.clock() - t0 < 6 do
                        loaded = true
                        for _, snd in ipairs(made) do if not snd.IsLoaded then loaded = false; break end end
                        if loaded then break end
                        task.wait(0.2)
                    end
                    if loaded then sfxSets[g.id] = set; return end
                end
                for _, snd in ipairs(made) do pcall(function() snd:Destroy() end) end
            end
            sfxSets[g.id] = false
        end)
    end
    playSfx = function(name)
        local set = sfxSets[mg.id]
        local e = type(set) == "table" and set[name]
        if not e then return end
        local level = type(Cfg.gbVolume) == "number" and Cfg.gbVolume or 1
        if level <= 0 then return end
        local snd = e.pool[e.next]
        e.next = e.next % #e.pool + 1
        pcall(function()
            snd.Volume = 0.6 * level
            snd.TimePosition = 0
            snd:Play()
        end)
    end
    table.insert(cleanups, function()
        for _, set in pairs(sfxSets) do
            if type(set) == "table" then
                for _, e in pairs(set) do for _, snd in ipairs(e.pool) do pcall(function() snd:Destroy() end) end end
            end
        end
    end)

    -- sprite sheets (downloaded once; until then the pieces are coloured cells)
    task.spawn(function()
        for _, g in ipairs(MiniGames.list) do
            if g.sheet then
                local a = urlImageAsset(SETTINGS.Auras.assetBase .. g.sheet, "games")
                if a then
                    sheets[g.id] = a
                    if mg == g then cur, pcur = {}, {}; render() end
                end
            end
            if g.backdrop then
                local list = type(g.backdrop) == "table" and g.backdrop or { g.backdrop }
                local got = {}
                local missing = {}
                for k, path in ipairs(list) do
                    got[k] = urlImageAsset(SETTINGS.Auras.assetBase .. path, "games")
                    if not got[k] then missing[#missing + 1] = path:match("([^/]+)$") end
                end
                if #missing > 0 then note("Games", g.title .. ": stage picture did not download (" .. table.concat(missing, ", ") .. ")", RED) end
                backdrops[g.id] = got
                if mg == g then cur = {}; render() end
            end
            if g.splash then
                local a = urlImageAsset(SETTINGS.Auras.assetBase .. g.splash, "games")
                if a then splashes[g.id] = a end
            end
        end
    end)

    loadSfxFor = loadSfx
    loadSfx(mg)
    selectGame(mg)
end

------------------------------------------------------------------------
-- Game Boy window (`gameboy`): runs original Game Boy games from the
-- executor folder PuppyAdmin/roms (.gb or .zip). The emulator itself is a
-- separate file in the repository (emu/gameboy-<version>.lua), downloaded
-- once into PuppyAdmin/engine. Battery saves go next to the game as .sav.
-- The games are never part of the script or the repository.
------------------------------------------------------------------------

-- Reads a game file, trying each path; on failure explains why (yields).
function UIAPI.gbReadFile(name, paths)
    local lastErr, sawNil = nil, false
    for _, p in ipairs(paths) do
        if p then
            local ok, d = pcall(readfile, p)
            if ok and typeof(d) == "buffer" then d = buffer.tostring(d) end
            if ok and type(d) == "string" and #d > 0 then return d end
            if not ok then lastErr = tostring(d) else sawNil = true end
        end
    end
    -- why: does the file exist, and can this executor read binary data at all?
    local exists = false
    for _, p in ipairs(paths) do
        if p and pcall(function() exists = exists or isfile(p) end) and exists then break end
    end
    local test = "PuppyAdmin/roms/_readtest.bin"
    local sample = "PK\3\4\0\1\2\255\128\10\13"
    local verdict
    local okW = pcall(writefile, test, sample)
    if not okW then
        verdict = "this executor cannot write files there"
    else
        local okR, back = pcall(readfile, test)
        if okR and typeof(back) == "buffer" then back = buffer.tostring(back) end
        if not okR or back == nil then verdict = "this executor returns nothing for binary files"
        elseif back ~= sample then verdict = "this executor changes binary data when reading (" .. #tostring(back) .. " of " .. #sample .. " bytes came back)"
        else verdict = "binary reading works, so the file name or type is the problem" end
        pcall(delfile, test)
    end
    local simple = name:gsub("[^%w%.%-_]", "")
    error("Could not read " .. name .. " (" .. (lastErr or (sawNil and "the executor returned nothing" or "no path worked")) .. "; file found: "
        .. (exists and "yes" or "no") .. "). Test: " .. verdict .. ". Try renaming it to a short name without spaces, commas, "
        .. "apostrophes or brackets, e.g. " .. (simple ~= "" and simple or "game.zip") .. ", or unzip it and use the .gb file.", 0)
end

UIAPI.GB_MODULE = { version = "d487644496", bytes = 73898 }

function UIAPI.buildGameBoyPanel(screenGui)
    local W, HGT = 360, 470
    local f = uiWindow(screenGui, "gameboy", "Game Boy", UDim2.fromOffset(W, HGT), UDim2.new(0.5, -W / 2, 0.5, -HGT / 2))
    local ROM_DIR, CACHE_DIR = "PuppyAdmin/roms", "PuppyAdmin/engine"
    local GBM = UIAPI.GB_MODULE
    local MOD_NAME = "gameboy-" .. GBM.version .. ".lua"
    local FRAME = 1 / 59.73
    -- shade 0..3 -> RGBA as a little-endian u32 (classic green screen)
    local SHADES = { { 224, 248, 208 }, { 136, 192, 112 }, { 52, 104, 86 }, { 8, 24, 32 } }
    local COLOR = {}
    for i, c in ipairs(SHADES) do COLOR[i - 1] = c[1] + c[2] * 256 + c[3] * 65536 + 255 * 16777216 end

    local emu, romPath, running, fast = nil, nil, false, false
    local acc, framesThisSecond, secondStart, speedPct = 0, 0, os.clock(), 0
    local frameCost = 0.012 -- running average of seconds per emulated frame
    local lastSave = os.clock()

    pcall(function()
        if makefolder and isfolder and not isfolder("PuppyAdmin") then makefolder("PuppyAdmin") end
        if makefolder and isfolder and not isfolder(ROM_DIR) then makefolder(ROM_DIR) end
    end)

    local fullPath = {} -- file name -> the path listfiles gave for it
    local function romList()
        local out = {}
        pcall(function()
            for _, p in ipairs(listfiles(ROM_DIR)) do
                local name = tostring(p):match("([^/\\]+)$")
                local low = name and name:lower() or ""
                if low:match("%.gb$") or low:match("%.gbc$") or low:match("%.zip$") then
                    out[#out + 1] = name
                    fullPath[name] = tostring(p)
                end
            end
        end)
        table.sort(out, function(a, b) return a:lower() < b:lower() end)
        return out
    end
    local listed = {}

    -- screen ---------------------------------------------------------------
    local screenW, screenH = 280, 252
    local bezel = make("Frame", {
        Position = UDim2.fromOffset((W - screenW) / 2 - 4, 76), Size = UDim2.fromOffset(screenW + 8, screenH + 8),
        BackgroundColor3 = Color3.fromRGB(10, 12, 16), BorderSizePixel = 0,
    }, f)
    corner(bezel, 8)
    local screen = make("ImageLabel", {
        Position = UDim2.fromOffset(4, 4), Size = UDim2.fromOffset(screenW, screenH), BackgroundColor3 = Color3.fromRGB(224, 248, 208),
        BorderSizePixel = 0, ScaleType = Enum.ScaleType.Stretch,
    }, bezel)
    pcall(function() screen.ResampleMode = Enum.ResamplerMode.Pixelated end)
    local overlay = label(bezel, {
        Position = UDim2.fromOffset(14, 4), Size = UDim2.fromOffset(screenW - 20, screenH), TextWrapped = true, ZIndex = 3,
        TextXAlignment = Enum.TextXAlignment.Center, TextColor3 = Color3.fromRGB(30, 50, 40), TextSize = 13,
        Text = "Put .gb or .zip games in your executor's workspace/PuppyAdmin/roms folder, then pick one above.\n\n"
            .. "Keys: arrows / WASD move, X = A, Z = B, Enter = Start, Backspace = Select.",
    })
    local status = label(f, { Position = UDim2.fromOffset(16, 338), Size = UDim2.fromOffset(W - 32 - 112, 16), TextSize = 11, TextTruncate = Enum.TextTruncate.AtEnd,
        TextColor3 = PAL.DIM, Text = "No game loaded" })

    -- Sound: the emulator reports each channel's pitch and volume every frame;
    -- these looping tones (assets/gb, downloaded once) are re-pitched to match.
    -- Low / high register files keep the pitch change within 0.25x - 4x.
    local SND = { sounds = {}, ready = false, loading = false }
    local VOLUMES = { 1, 0.75, 0.5, 0.25, 0 }
    local VOLUME_LABELS = { "Sound 100%", "Sound 75%", "Sound 50%", "Sound 25%", "Sound off" }
    if type(Cfg.gbVolume) ~= "number" then Cfg.gbVolume = 1 end
    local BASE_HZ = { lo = 110.25, hi = 1764 }
    local CHANNEL_GAIN = 0.5
    local function soundKey(n, c)
        if n <= 3 then
            local bank = c.freq < 441 and "lo" or "hi"
            local name
            if n <= 2 then name = "sq" .. c.duty .. "_" .. bank
            else name = (c.shape == "tri" and "tri" or (c.shape == "saw" and "saw" or "sq2")) .. "_" .. bank end
            local speed = c.freq / BASE_HZ[bank]
            if speed < 0.25 or speed > 4 then return nil end
            return name, speed
        end
        local name = c.short and "noise7" or "noise"
        return name, math.clamp(c.freq / (c.short and 22050 or 44100), 0.1, 4)
    end
    -- Downloads the tones and makes the Sounds. Tries .ogg, then .mp3 (the
    -- start-up sound is an mp3, so that format is known to play); a format
    -- counts only once Roblox reports every Sound loaded. SND.state says why
    -- there is no sound.
    local function loadSounds(onReady)
        if SND.ready then if onReady then onReady() end return end
        if SND.loading then return end
        SND.loading = true
        SND.state = "sound: loading"
        task.spawn(function()
            local files = { "noise", "noise7", "saw_hi", "saw_lo", "tri_hi", "tri_lo" }
            for d = 0, 3 do files[#files + 1] = "sq" .. d .. "_lo"; files[#files + 1] = "sq" .. d .. "_hi" end
            local sets = {
                { "sq0_lo", "sq1_lo", "sq2_lo", "sq3_lo", "sq0_hi", "sq1_hi", "sq2_hi", "sq3_hi" },
                { "sq0_lo", "sq1_lo", "sq2_lo", "sq3_lo", "sq0_hi", "sq1_hi", "sq2_hi", "sq3_hi" },
                { "tri_lo", "saw_lo", "sq2_lo", "tri_hi", "saw_hi", "sq2_hi" },
                { "noise", "noise7" },
            }
            local service = game:GetService("SoundService")
            local why = "unknown"
            for _, ext in ipairs({ "ogg", "mp3" }) do
                local ids, ok = {}, true
                for _, name in ipairs(files) do
                    ids[name] = urlImageAsset(SETTINGS.Auras.assetBase .. "assets/gb/v2/" .. name .. "." .. ext, "gbsnd")
                    if not ids[name] then ok = false; why = name .. "." .. ext .. " did not download"; break end
                end
                if ok then
                    local made = {}
                    for n, list in ipairs(sets) do
                        SND.sounds[n] = {}
                        for _, name in ipairs(list) do
                            local snd = Instance.new("Sound")
                            snd.Name = "PuppyAdminGB" .. n .. name
                            snd.SoundId = ids[name]
                            snd.Looped = true
                            snd.Volume = 0
                            snd.Parent = service
                            SND.sounds[n][name] = snd
                            made[#made + 1] = snd
                        end
                    end
                    local t0, loaded = os.clock(), false
                    while os.clock() - t0 < 6 do
                        loaded = true
                        for _, snd in ipairs(made) do
                            if not snd.IsLoaded then loaded = false; break end
                        end
                        if loaded then break end
                        task.wait(0.2)
                    end
                    if loaded then
                        for _, snd in ipairs(made) do snd:Play() end
                        SND.ready, SND.loading, SND.state, SND.format = true, false, nil, ext
                        if onReady then onReady() end
                        return
                    end
                    why = "Roblox did not load the ." .. ext .. " tones"
                    for _, snd in ipairs(made) do pcall(function() snd:Destroy() end) end
                    SND.sounds = {}
                end
            end
            SND.loading = false
            SND.state = "no sound: " .. why
            note("Game Boy", "No sound: " .. why, RED)
        end)
    end
    -- Some executors play custom audio once even when Looped is set: restart a
    -- tone that stopped, and jump back before the end (the files are whole
    -- wave cycles, so the jump lands on the same point of the wave).
    local function keepPlaying(snd)
        local len = snd.TimeLength
        if not snd.IsPlaying then
            -- a finished custom sound does not always restart from the top by itself
            snd.TimePosition = 0
            snd:Play()
        elseif len > 1 and snd.TimePosition > len - 0.25 then
            snd.TimePosition = 0
        end
    end
    -- every tone, silent or not, so none of them runs out while unused (twice a second is plenty for 8 s files)
    local lastSweep = 0
    local function keepAllPlaying()
        if not SND.ready then return end
        local now = os.clock()
        if now - lastSweep < 0.5 then return end
        lastSweep = now
        for _, set in ipairs(SND.sounds) do
            for _, snd in pairs(set) do keepPlaying(snd) end
        end
    end
    -- Roblox property writes are costly: only write what changed
    local lastVol, lastSpeed = {}, {}
    local function setTone(snd, vol, speed)
        if lastVol[snd] ~= vol then snd.Volume = vol; lastVol[snd] = vol end
        if speed and lastSpeed[snd] ~= speed then snd.PlaybackSpeed = speed; lastSpeed[snd] = speed end
    end

    local function muteSound()
        if not SND.ready then return end
        for _, set in ipairs(SND.sounds) do
            for _, snd in pairs(set) do setTone(snd, 0) end
        end
    end
    local function updateSound(a)
        if not SND.ready then return end
        local level = Cfg.gbVolume
        for n = 1, 4 do
            local c = a.c[n]
            local key, speed
            if a.power and c.on and level > 0 then key, speed = soundKey(n, c) end
            for name, snd in pairs(SND.sounds[n]) do
                if name == key then
                    keepPlaying(snd)
                    -- small steps are inaudible; rounding saves property writes
                    setTone(snd, math.floor(c.vol * a.master * level * CHANNEL_GAIN * 100 + 0.5) / 100, math.floor(speed * 1000 + 0.5) / 1000)
                else
                    setTone(snd, 0)
                end
            end
        end
        keepAllPlaying()
    end
    local volDd = uiDropdown(f, "", UDim2.fromOffset(108, 22), UDim2.fromOffset(W - 16 - 108, 335), VOLUME_LABELS,
        table.find(VOLUMES, Cfg.gbVolume) or 1, function(i)
            Cfg.gbVolume = VOLUMES[i]
            cfgSave()
            if Cfg.gbVolume == 0 then muteSound(); return end
            loadSounds(function()
                if running then return end
                local beep = SND.sounds[1] and SND.sounds[1].sq2_lo
                if not beep then return end
                keepPlaying(beep)
                setTone(beep, Cfg.gbVolume * CHANNEL_GAIN, 4) -- 441 Hz
                task.delay(0.35, function() if not running then setTone(beep, 0) end end)
                note("Game Boy", "Sound test beep (" .. tostring(SND.format) .. " tones)", LIGHT)
            end)
        end)
    volDd.button.TextSize = 11
    table.insert(cleanups, function()
        for _, set in ipairs(SND.sounds) do for _, snd in pairs(set) do pcall(function() snd:Destroy() end) end end
    end)

    local image, pixels
    local function makeImage()
        if image then return true end
        local ok, ei = pcall(function()
            return game:GetService("AssetService"):CreateEditableImage({ Size = Vector2.new(160, 144) })
        end)
        if not ok or not ei then return false, "EditableImage is not available: " .. tostring(ei) end
        local shown = pcall(function() screen.ImageContent = Content.fromObject(ei) end)
        if not shown then
            shown = pcall(function() ei.Parent = screen end)
        end
        if not shown then return false, "could not show the screen" end
        image = ei
        pixels = buffer.create(160 * 144 * 4)
        return true
    end

    local function present()
        if not (emu and image) then return end
        local fb = emu.fb
        local writeu32 = buffer.writeu32
        for i = 1, 23040 do writeu32(pixels, i * 4 - 4, COLOR[fb[i]]) end
        pcall(function() image:WritePixelsBuffer(Vector2.zero, Vector2.new(160, 144), pixels) end)
    end

    -- emulator module (downloaded once per version) ----------------------------
    local function loadModule()
        if UIAPI.gbModuleLoaded then return UIAPI.gbModuleLoaded end
        local function valid(src)
            return type(src) == "string" and #src == GBM.bytes and src:sub(1, 30) == ("-- PuppyAdmin gameboy " .. GBM.version):sub(1, 30)
        end
        local path = CACHE_DIR .. "/" .. MOD_NAME
        local src
        pcall(function() if isfile(path) then src = readfile(path) end end)
        if not valid(src) then
            local ok, body = pcall(function() return game:HttpGet(SETTINGS.Auras.assetBase .. "emu/" .. MOD_NAME) end)
            if not ok or not valid(body) then error("emulator download failed or was incomplete", 0) end
            src = body
            pcall(function()
                if makefolder and isfolder and not isfolder(CACHE_DIR) then makefolder(CACHE_DIR) end
                writefile(path, src)
            end)
        end
        local fn, err = (loadstring or load)(src, "=PuppyAdminGameBoy")
        if not fn then error("emulator did not compile: " .. tostring(err), 0) end
        UIAPI.gbModuleLoaded = fn()
        return UIAPI.gbModuleLoaded
    end

    local function savePath(path) return (path:gsub("%.[^.]+$", "")) .. ".sav" end

    local function saveNow()
        if not (emu and romPath and emu.battery and emu.dirty()) then return end
        local data = emu.saveData()
        if data and writefile then
            local ok = pcall(writefile, savePath(romPath), data)
            if ok then emu.clearDirty() end
        end
        lastSave = os.clock()
    end

    local releaseAll -- set below (input)

    local function setRunning(on)
        running = on and emu ~= nil
        if not running and releaseAll then releaseAll() end
        if running then loadSounds() else muteSound() end
        UIAPI.gbButtons.pause.Text = running and "Pause" or "Play"
    end

    local function loadGame(name)
        task.spawn(function()
            saveNow()
            muteSound()
            emu, running = nil, false
            overlay.Visible = true
            overlay.Text = "Loading " .. name .. "..."
            local ok, err = pcall(function()
                local okImg, why = makeImage()
                if not okImg then error(why, 0) end
                local mod = loadModule()
                local path = ROM_DIR .. "/" .. name
                local data = UIAPI.gbReadFile(name, { fullPath[name], path, ROM_DIR .. "\\" .. name })
                -- zip by content, whatever the file is called
                if data:find("PK\3\4", 1, true) or name:lower():match("%.zip$") then
                    local rom, inner = mod.Zip.extract(data)
                    if not rom then error(inner, 0) end
                    data = rom
                end
                -- every Game Boy cartridge carries the same logo bytes at 0x104
                if #data < 0x150 or data:sub(0x105, 0x108) ~= "\206\237\102\102" then
                    error((mod.Zip.describe and mod.Zip.describe(data) or "not a Game Boy game") .. " - not a valid Game Boy game file", 0)
                end
                local save
                pcall(function() if isfile(savePath(path)) then save = readfile(savePath(path)) end end)
                emu = mod.GB.new(data, save)
                romPath = path
            end)
            if not ok then
                emu = nil
                overlay.Text = "Could not start " .. name .. ":\n" .. tostring(err)
                status.Text = "No game loaded"
                return
            end
            overlay.Visible = false
            acc = 0
            setRunning(true)
            status.Text = (emu.title ~= "" and emu.title or name) .. (emu.battery and "  -  saves to " .. savePath(name) or "")
        end)
    end

    -- top row: game picker and controls -------------------------------------------
    local dd = uiDropdown(f, "", UDim2.fromOffset(160, 28), UDim2.fromOffset(16, 42), function()
        listed = romList()
        if #listed == 0 then return { "No games in PuppyAdmin/roms" } end
        return listed
    end, 1, function(i)
        local name = listed[i]
        if name then loadGame(name) end
    end)
    dd.button.TextSize = 11
    UIAPI.gbButtons = {}
    UIAPI.gbButtons.pause = uiButton(f, "Play", UDim2.fromOffset(52, 28), UDim2.fromOffset(180, 42), function()
        if emu then setRunning(not running) end
    end)
    local fastBtn
    fastBtn = uiButton(f, "Fast", UDim2.fromOffset(52, 28), UDim2.fromOffset(236, 42), function()
        fast = not fast
        fastBtn.BackgroundColor3 = fast and PAL.ELEVATED or PAL.CARD
        fastBtn.Text = fast and "Fast x3" or "Fast"
    end)
    uiButton(f, "Reset", UDim2.fromOffset(52, 28), UDim2.fromOffset(292, 42), function()
        if romPath then loadGame(romPath:match("([^/\\]+)$")) end
    end)

    -- input -------------------------------------------------------------------------
    local held = {}
    local function press(name, down)
        held[name] = down or nil
        if emu then emu.setButton(name, down) end
    end
    releaseAll = function()
        for name in pairs(held) do if emu then emu.setButton(name, false) end end
        held = {}
    end

    -- on-screen pad (hold to press)
    local function padButton(text, name, x, y, w, h, round)
        local b = make("TextButton", {
            Position = UDim2.fromOffset(x, y), Size = UDim2.fromOffset(w, h), BackgroundColor3 = PAL.CARD, BackgroundTransparency = 0.1,
            BorderSizePixel = 0, AutoButtonColor = false, Text = text, TextColor3 = PAL.TEXT, Font = Enum.Font.GothamBold, TextSize = 12,
        }, f)
        corner(b, round and math.floor(w / 2) or 6)
        b.InputBegan:Connect(function(input) if isPointer(input) then press(name, true); b.BackgroundColor3 = PAL.ELEVATED end end)
        b.InputEnded:Connect(function(input) if isPointer(input) then press(name, false); b.BackgroundColor3 = PAL.CARD end end)
        b.MouseLeave:Connect(function() if held[name] then press(name, false); b.BackgroundColor3 = PAL.CARD end end)
        return b
    end
    local py = 360
    padButton("^", "up", 58, py, 32, 32)
    padButton("<", "left", 24, py + 34, 32, 32)
    padButton(">", "right", 92, py + 34, 32, 32)
    padButton("v", "down", 58, py + 68, 32, 32)
    padButton("Select", "select", 140, py + 74, 52, 22)
    padButton("Start", "start", 198, py + 74, 52, 22)
    padButton("B", "b", 258, py + 26, 40, 40, true)
    padButton("A", "a", 304, py + 6, 40, 40, true)

    local KEYS = {
        [Enum.KeyCode.Up] = "up", [Enum.KeyCode.W] = "up", [Enum.KeyCode.Down] = "down", [Enum.KeyCode.S] = "down",
        [Enum.KeyCode.Left] = "left", [Enum.KeyCode.A] = "left", [Enum.KeyCode.Right] = "right", [Enum.KeyCode.D] = "right",
        [Enum.KeyCode.X] = "a", [Enum.KeyCode.K] = "a", [Enum.KeyCode.Z] = "b", [Enum.KeyCode.J] = "b",
        [Enum.KeyCode.Return] = "start", [Enum.KeyCode.Backspace] = "select", [Enum.KeyCode.RightShift] = "select",
    }
    local keyList = {}
    for kc in pairs(KEYS) do keyList[#keyList + 1] = kc end
    local ACTION = "PuppyAdminGameBoy"
    local bound = false
    local function onKey(_, state, input)
        if not (running and emu) then return Enum.ContextActionResult.Pass end
        local name = KEYS[input.KeyCode]
        if not name then return Enum.ContextActionResult.Pass end
        press(name, state == Enum.UserInputState.Begin)
        return Enum.ContextActionResult.Sink
    end
    local function bind(on)
        if on == bound then return end
        bound = on
        if on then
            pcall(function() ContextActionService:BindActionAtPriority(ACTION, onKey, false, 3000, table.unpack(keyList)) end)
        else
            pcall(function() ContextActionService:UnbindAction(ACTION) end)
            releaseAll()
        end
    end

    -- main loop: real-time pacing, at most 2 frames per heartbeat (3 when fast)
    local loop
    local function startLoop()
        if loop then return end
        loop = RunService.Heartbeat:Connect(function(dt)
            if not (running and emu) then keepAllPlaying(); return end
            local start = os.clock()
            local ran = 0
            -- How many frames this heartbeat: fast = as many as fit in ~35 ms (up to 3),
            -- normal = what real time asks for (up to 2). Only the last one is drawn.
            local want
            if fast then
                want = math.clamp(math.floor(0.035 / math.max(frameCost, 0.001)), 1, 3)
                acc = 0
            else
                acc = math.min(acc + dt, 0.25)
                want = math.min(2, math.floor(acc / FRAME))
                acc = acc - want * FRAME
                if acc > 0.1 then acc = 0 end -- falling behind: run slower instead of piling up
            end
            for i = 1, want do
                local t = os.clock()
                emu.runFrame(i == want)
                ran = ran + 1
                frameCost = frameCost * 0.9 + (os.clock() - t) * 0.1
            end
            if ran > 0 then
                present()
                -- fast-forward plays too (the music simply runs faster)
                if emu.audio then updateSound(emu.audio()) else muteSound() end
            end
            framesThisSecond = framesThisSecond + ran
            local now = os.clock()
            if now - secondStart >= 1 then
                speedPct = math.floor(framesThisSecond / (now - secondStart) / 59.73 * 100 + 0.5)
                framesThisSecond, secondStart = 0, now
                local base = status.Text:gsub("  %[%d+%%%].*$", "")
                status.Text = base .. "  [" .. speedPct .. "%]" .. (SND.state and ("  " .. SND.state) or "")
            end
            if now - lastSave > 5 then saveNow() end
        end)
        table.insert(conns, loop)
    end
    local function stopLoop()
        if loop then loop:Disconnect(); loop = nil end
    end

    f:GetPropertyChangedSignal("Visible"):Connect(function()
        if f.Visible then
            bind(true)
            startLoop()
        else
            if running then setRunning(false) end
            saveNow()
            bind(false)
            stopLoop()
        end
    end)
    table.insert(conns, UserInputService.WindowFocusReleased:Connect(function() releaseAll() end))
    table.insert(cleanups, function() saveNow(); bind(false); stopLoop() end)
end

------------------------------------------------------------------------
-- Game Boy Advance window (`gba`): runs Game Boy Advance games from the
-- executor folder PuppyAdmin/gba (.gba or .zip). The emulator is a separate
-- file in the repository (emu/gba-<version>.lua), downloaded once into
-- PuppyAdmin/engine. It needs a GBA BIOS: the free Cult-of-GBA BIOS (MIT,
-- assets/gba) is downloaded once, or PuppyAdmin/gba/gba_bios.bin is used
-- when you have your own. Saves go next to the game as .sav. Sound: see
-- UIAPI.newPcmStream.
------------------------------------------------------------------------

UIAPI.GBA_MODULE = { version = "d1e61327b1", bytes = 129455 }
UIAPI.GBA_BIOS = { path = "assets/gba/cult_bios_v1.bin", bytes = 16384 }

-- Generated sound. Roblox has no raw-audio stream, so the emulator's samples
-- are cut into 0.25 s files that play back to back, each faded into the next
-- over 32 ms; the sound runs about 0.35 s behind the picture. Which file type
-- Roblox loads depends on the executor, so at the start one short silent file
-- of each type is loaded side by side: WAV, FLAC, or MPEG audio saved as .mp3
-- (the type executors load most reliably). Pcm is the encoder table from the
-- emulator module.
--   stream.push(buf, n)  signed 16-bit mono samples;  stream.update(dt) every frame
--   stream.reset(), stream.setVolume(v), stream.destroy(), stream.state, stream.failed
function UIAPI.newPcmStream(Pcm, rate, tag)
    local N = math.floor(rate / 4)
    local O = math.floor(rate * 0.016)
    local LEAD = 0.35
    local CAP = rate * 4
    local DIR = "PuppyAdmin/" .. tag .. "_sound"
    local getAsset = (type(getcustomasset) == "function" and getcustomasset) or (type(getsynasset) == "function" and getsynasset)
    local folder = Instance.new("Folder")
    folder.Name = "PuppyAdmin_" .. tag .. "_sound"
    folder.Parent = game:GetService("SoundService")
    local S = { state = "sound: checking", failed = false, volume = 1 }
    local ring = buffer.create(CAP * 2)
    local written, nextChunk, t0 = 0, 0, nil
    local clock = 0 -- seconds, moved on by update(dt)
    local chunks = {}
    local session = tostring(math.random(100000, 999999))
    local dead, errors = false, 0
    local FORMATS = {
        { ext = "wav", enc = Pcm.wav, delay = 0 },
        { ext = "flac", enc = Pcm.flac, delay = 0 },
        { ext = "mp3", enc = Pcm.mp2, delay = Pcm.mp2Delay or 0 },
    }
    local fmt, probes, probeStart = nil, {}, nil
    pcall(function()
        if makefolder and isfolder and not isfolder(DIR) then makefolder(DIR) end
    end)

    local function soundFor(file, body)
        if not pcall(writefile, file, body) then return nil, "could not write the file" end
        local okA, id = pcall(getAsset, file)
        if not (okA and type(id) == "string" and id ~= "") then
            if delfile then pcall(delfile, file) end
            return nil, "getcustomasset refused it"
        end
        local snd = Instance.new("Sound")
        snd.SoundId = id
        snd.Volume = S.volume
        snd.Parent = folder
        return snd
    end
    local function dropChunk(c)
        if c.snd then pcall(function() c.snd:Destroy() end) end
        if delfile and c.file then pcall(delfile, c.file) end
    end
    local function fail(why)
        if S.failed then return end
        S.failed = true
        S.state = "no sound"
        for _, c in ipairs(chunks) do dropChunk(c) end
        for _, pr in ipairs(probes) do dropChunk(pr) end
        chunks, probes = {}, {}
        note("Sound", "No sound: " .. why, RED)
    end

    -- one short silent file per type, loaded side by side
    if not getAsset then
        fail("this executor has no getcustomasset")
    else
        local n = math.floor(rate / 5)
        local silent = buffer.create(n * 2)
        for i, f in ipairs(FORMATS) do
            local okE, body = pcall(f.enc, silent, n, rate)
            local file = DIR .. "/" .. session .. "_check." .. f.ext
            local snd, why
            if okE then snd, why = soundFor(file, body) else why = "could not be made" end
            probes[i] = { f = f, snd = snd, file = snd and file or nil, why = why }
        end
        probeStart = 0
    end

    local function checkFormats()
        local age = clock - probeStart
        local pick
        for _, pr in ipairs(probes) do
            if pr.snd and pr.snd.IsLoaded then pick = pr; break end
        end
        -- prefer WAV / FLAC, but take whatever loaded after a second; give up after 8 s
        if pick and (pick.f.ext == "wav" or age > 1) then
            fmt = pick.f
            for _, pr in ipairs(probes) do dropChunk(pr) end
            probes = {}
            S.state = "sound: starting (" .. fmt.ext .. ")"
            nextChunk = math.max(0, math.floor(written / N) - 1)
            t0 = nil
        elseif age > 8 then
            local parts = {}
            for _, pr in ipairs(probes) do
                parts[#parts + 1] = pr.f.ext .. ": " .. (pr.why or (pr.snd and "Roblox did not load it" or "failed"))
            end
            fail("no generated sound file played on this executor (" .. table.concat(parts, ", ") .. ")")
        end
    end

    function S.push(buf, n)
        if dead or S.failed or n <= 0 then return end
        local pos = written % CAP
        local first = math.min(n, CAP - pos)
        buffer.copy(ring, pos * 2, buf, 0, first * 2)
        if n > first then buffer.copy(ring, 0, buf, first * 2, (n - first) * 2) end
        written = written + n
        -- the ring is about to overwrite samples not yet cut: skip ahead
        if written - nextChunk * N > CAP - 2 * N then
            nextChunk = math.floor(written / N) - 1
            t0 = nil
        end
    end
    local function makeChunk(k)
        local from = k * N - O
        local n = N + 2 * O
        if t0 and t0 + from / rate - fmt.delay < clock + 0.05 then t0 = nil end -- fell behind: start again a little later
        local data = Pcm.chunk(ring, CAP, from, n, 2 * O)
        local okE, body = pcall(fmt.enc, data, n, rate)
        if not okE then return nil, "the ." .. fmt.ext .. " encoder failed: " .. tostring(body) end
        local file = DIR .. "/" .. session .. "_" .. k .. "." .. fmt.ext
        local snd, why = soundFor(file, body)
        if not snd then return nil, "." .. fmt.ext .. ": " .. why end
        if not t0 then t0 = clock + LEAD - from / rate end
        return { snd = snd, start = t0 + from / rate - fmt.delay, len = n / rate + fmt.delay, file = file }
    end
    function S.update(dt)
        if dead or S.failed then return end
        clock = clock + math.min(dt or (1 / 60), 0.25)
        if not fmt then checkFormats(); return end
        local now = clock
        local made = 0
        while written >= (nextChunk + 1) * N + O and made < 2 do
            local c, why = makeChunk(nextChunk)
            nextChunk = nextChunk + 1
            made = made + 1
            if c then
                chunks[#chunks + 1] = c
                errors = 0
            else
                errors = errors + 1
                if errors >= 4 then fail(why); return end
            end
        end
        local i = 1
        while i <= #chunks do
            local c = chunks[i]
            local drop = false
            if not c.played then
                if now >= c.start - 0.008 then
                    if c.snd.IsLoaded then
                        pcall(function()
                            c.snd.TimePosition = math.max(0, now - c.start)
                            c.snd:Play()
                        end)
                        c.played = true
                        S.state = "sound on (" .. fmt.ext .. ")"
                    elseif now > c.start + 0.12 then
                        drop = true -- not loaded in time
                    end
                end
            elseif now > c.start + c.len + 0.25 then
                drop = true
            end
            if drop then dropChunk(c); table.remove(chunks, i) else i = i + 1 end
        end
    end
    function S.reset()
        for _, c in ipairs(chunks) do dropChunk(c) end
        chunks = {}
        written, nextChunk, t0 = 0, 0, nil
    end
    function S.setVolume(v)
        S.volume = v
        for _, c in ipairs(chunks) do pcall(function() c.snd.Volume = v end) end
    end
    function S.destroy()
        dead = true
        for _, c in ipairs(chunks) do dropChunk(c) end
        for _, pr in ipairs(probes) do dropChunk(pr) end
        chunks, probes = {}, {}
        pcall(function() folder:Destroy() end)
    end
    return S
end

function UIAPI.buildGbaPanel(screenGui)
    local W, HGT = 392, 478
    local f = uiWindow(screenGui, "gba", "Game Boy Advance", UDim2.fromOffset(W, HGT), UDim2.new(0.5, -W / 2, 0.5, -HGT / 2))
    local ROM_DIR, CACHE_DIR = "PuppyAdmin/gba", "PuppyAdmin/engine"
    local GM = UIAPI.GBA_MODULE
    local MOD_NAME = "gba-" .. GM.version .. ".lua"
    local FRAME = 1 / 59.73
    local KEYBIT = { a = 1, b = 2, select = 4, start = 8, right = 16, left = 32, up = 64, down = 128, r = 256, l = 512 }

    local S = {
        emu = nil, romPath = nil, running = false, fast = false,
        acc = 0, frames = 0, secondStart = os.clock(), lastSave = os.clock(),
        frameCost = 0.02, renderEvery = 1, skipCount = 0, keys = 0,
    }

    pcall(function()
        if makefolder and isfolder and not isfolder("PuppyAdmin") then makefolder("PuppyAdmin") end
        if makefolder and isfolder and not isfolder(ROM_DIR) then makefolder(ROM_DIR) end
    end)

    local fullPath = {}
    local function romList()
        local out = {}
        pcall(function()
            for _, p in ipairs(listfiles(ROM_DIR)) do
                local name = tostring(p):match("([^/\\]+)$")
                local low = name and name:lower() or ""
                if low:match("%.gba$") or low:match("%.agb$") or low:match("%.zip$") then
                    out[#out + 1] = name
                    fullPath[name] = tostring(p)
                end
            end
        end)
        table.sort(out, function(a, b) return a:lower() < b:lower() end)
        return out
    end
    local listed = {}

    -- screen: 240 x 160 at 1.5x
    local screenW, screenH = 360, 240
    local bezel = make("Frame", {
        Position = UDim2.fromOffset((W - screenW) / 2 - 4, 76), Size = UDim2.fromOffset(screenW + 8, screenH + 8),
        BackgroundColor3 = Color3.fromRGB(10, 12, 16), BorderSizePixel = 0,
    }, f)
    corner(bezel, 8)
    local screen = make("ImageLabel", {
        Position = UDim2.fromOffset(4, 4), Size = UDim2.fromOffset(screenW, screenH), BackgroundColor3 = Color3.fromRGB(0, 0, 0),
        BorderSizePixel = 0, ScaleType = Enum.ScaleType.Stretch,
    }, bezel)
    pcall(function() screen.ResampleMode = Enum.ResamplerMode.Pixelated end)
    local overlay = label(bezel, {
        Position = UDim2.fromOffset(14, 4), Size = UDim2.fromOffset(screenW - 20, screenH), TextWrapped = true, ZIndex = 3,
        TextXAlignment = Enum.TextXAlignment.Center, TextColor3 = Color3.fromRGB(230, 230, 230), TextSize = 13,
        Text = "Put .gba or .zip games in your executor's workspace/PuppyAdmin/gba folder, then pick one above.\n\n"
            .. "Keys: arrows / WASD move, X = A, Z = B, Q = L, E = R, Enter = Start, Backspace = Select.\n\n"
            .. "Uses the free Cult-of-GBA BIOS; put your own as PuppyAdmin/gba/gba_bios.bin to use it instead.",
    })
    local status = label(f, { Position = UDim2.fromOffset(16, 332), Size = UDim2.fromOffset(W - 32 - 114, 16), TextSize = 11,
        TextTruncate = Enum.TextTruncate.AtEnd, TextColor3 = PAL.DIM, Text = "No game loaded" })
    local statusBase = "No game loaded"
    if type(Cfg.gbaVolume) ~= "number" then Cfg.gbaVolume = 1 end
    local function stopSound()
        if S.stream then S.stream.destroy(); S.stream = nil end
        if S.emu then S.emu.setAudio(false) end
    end
    local function startSound()
        if S.stream then S.stream.destroy(); S.stream = nil end
        local mod = UIAPI.gbaModuleLoaded
        if not (S.emu and mod and mod.Pcm and S.emu.setAudio) then return end
        if Cfg.gbaVolume <= 0 then S.emu.setAudio(false); return end
        S.stream = UIAPI.newPcmStream(mod.Pcm, S.emu.audioRate, "gba")
        S.stream.setVolume(Cfg.gbaVolume)
        S.emu.setAudio(true)
    end

    local image
    local function makeImage()
        if image then return true end
        local ok, ei = pcall(function()
            return game:GetService("AssetService"):CreateEditableImage({ Size = Vector2.new(240, 160) })
        end)
        if not ok or not ei then return false, "EditableImage is not available: " .. tostring(ei) end
        local shown = pcall(function() screen.ImageContent = Content.fromObject(ei) end)
        if not shown then shown = pcall(function() ei.Parent = screen end) end
        if not shown then return false, "could not show the screen" end
        image = ei
        return true
    end
    local function present()
        if S.emu and image then
            pcall(function() image:WritePixelsBuffer(Vector2.zero, Vector2.new(240, 160), S.emu.fb) end)
        end
    end

    local function readBinary(path)
        local ok, d = pcall(readfile, path)
        if ok and typeof(d) == "buffer" then d = buffer.tostring(d) end
        if ok and type(d) == "string" then return d end
        return nil
    end
    -- emulator module and BIOS (each downloaded once)
    local function loadModule()
        if UIAPI.gbaModuleLoaded then return UIAPI.gbaModuleLoaded end
        local head = "-- PuppyAdmin gba " .. GM.version
        local function valid(src) return type(src) == "string" and #src == GM.bytes and src:sub(1, #head) == head end
        local path = CACHE_DIR .. "/" .. MOD_NAME
        local src = readBinary(path)
        if not valid(src) then
            local ok, body = pcall(function() return game:HttpGet(SETTINGS.Auras.assetBase .. "emu/" .. MOD_NAME) end)
            if not ok or not valid(body) then error("emulator download failed or was incomplete", 0) end
            src = body
            pcall(function()
                if makefolder and isfolder and not isfolder(CACHE_DIR) then makefolder(CACHE_DIR) end
                writefile(path, src)
            end)
        end
        local fn, err = (loadstring or load)(src, "=PuppyAdminGBA")
        if not fn then error("emulator did not compile: " .. tostring(err), 0) end
        UIAPI.gbaModuleLoaded = fn()
        return UIAPI.gbaModuleLoaded
    end
    local function loadBios()
        local own = readBinary(ROM_DIR .. "/gba_bios.bin")
        if own and #own == 16384 then return own, "your BIOS" end
        local B = UIAPI.GBA_BIOS
        local path = CACHE_DIR .. "/gba_" .. B.path:match("([^/]+)$")
        local bios = readBinary(path)
        if not bios or #bios ~= B.bytes then
            local ok, body = pcall(function() return game:HttpGet(SETTINGS.Auras.assetBase .. B.path) end)
            if not ok or type(body) ~= "string" or #body ~= B.bytes then error("BIOS download failed or was incomplete", 0) end
            bios = body
            pcall(writefile, path, bios)
        end
        return bios, "Cult-of-GBA BIOS"
    end

    local function savePath(path) return (path:gsub("%.[^.]+$", "")) .. ".sav" end
    local function saveNow()
        local emu = S.emu
        if not (emu and S.romPath and emu.saveDirty()) then return end
        local data = emu.saveData()
        if data and writefile and pcall(writefile, savePath(S.romPath), data) then emu.clearSaveDirty() end
        S.lastSave = os.clock()
    end

    local releaseAll
    local pauseBtn
    local function setRunning(on)
        S.running = on and S.emu ~= nil
        if not S.running and releaseAll then releaseAll() end
        if pauseBtn then pauseBtn.Text = S.running and "Pause" or "Play" end
        -- paused: stop the sound; resumed: drop what was made before the pause
        if S.stream then S.stream.reset() end
        if S.running and S.emu and S.emu.audioPull then S.emu.audioPull() end
    end

    local function loadGame(name)
        task.spawn(function()
            saveNow()
            stopSound()
            S.emu, S.running = nil, false
            overlay.Visible = true
            overlay.Text = "Loading " .. name .. "..."
            local ok, err = pcall(function()
                local okImg, why = makeImage()
                if not okImg then error(why, 0) end
                local mod = loadModule()
                local bios, biosName = loadBios()
                local path = ROM_DIR .. "/" .. name
                local data = UIAPI.gbReadFile(name, { fullPath[name], path, ROM_DIR .. "\\" .. name })
                if data:find("PK\3\4", 1, true) == 1 or name:lower():match("%.zip$") then
                    overlay.Text = "Unpacking " .. name .. "..."
                    local rom, inner = mod.Zip.extract(data, function() task.wait() end)
                    if not rom then error(inner, 0) end
                    data = rom
                end
                -- every GBA cartridge header has 0x96 at 0xB2
                if #data < 0xC0 or data:byte(0xB3) ~= 0x96 then
                    error((mod.Zip.describe and mod.Zip.describe(data) or "not a GBA game") .. " - not a valid Game Boy Advance game file", 0)
                end
                local save = readBinary(savePath(path))
                S.emu = mod.GBA.new(data, bios, save)
                S.romPath = path
                local title = S.emu.title ~= "" and S.emu.title or name
                statusBase = title .. "  (" .. biosName .. ", save: " .. S.emu.saveType .. ")"
            end)
            if not ok then
                S.emu = nil
                overlay.Text = "Could not start " .. name .. ":\n" .. tostring(err)
                status.Text = "No game loaded"
                return
            end
            overlay.Visible = false
            S.acc, S.renderEvery, S.skipCount, S.frameCost = 0, 1, 0, 0.02
            S.emu.setKeys(S.keys)
            startSound()
            setRunning(true)
            status.Text = statusBase
        end)
    end

    -- top row ------------------------------------------------------------------------
    local dd = uiDropdown(f, "", UDim2.fromOffset(170, 28), UDim2.fromOffset(16, 42), function()
        listed = romList()
        if #listed == 0 then return { "No games in PuppyAdmin/gba" } end
        return listed
    end, 1, function(i)
        local name = listed[i]
        if name then loadGame(name) end
    end)
    dd.button.TextSize = 11
    pauseBtn = uiButton(f, "Play", UDim2.fromOffset(60, 28), UDim2.fromOffset(190, 42), function()
        if S.emu then setRunning(not S.running) end
    end)
    local fastBtn
    fastBtn = uiButton(f, "Fast", UDim2.fromOffset(60, 28), UDim2.fromOffset(254, 42), function()
        S.fast = not S.fast
        fastBtn.BackgroundColor3 = S.fast and PAL.ELEVATED or PAL.CARD
        fastBtn.Text = S.fast and "Fast on" or "Fast"
    end)
    uiButton(f, "Reset", UDim2.fromOffset(60, 28), UDim2.fromOffset(318, 42), function()
        if S.romPath then loadGame(S.romPath:match("([^/\\]+)$")) end
    end)
    do
        local VOLUMES = { 1, 0.75, 0.5, 0.25, 0 }
        local volDd = uiDropdown(f, "", UDim2.fromOffset(108, 22), UDim2.fromOffset(W - 16 - 108, 328),
            { "Sound 100%", "Sound 75%", "Sound 50%", "Sound 25%", "Sound off" },
            table.find(VOLUMES, Cfg.gbaVolume) or 1, function(i)
                Cfg.gbaVolume = VOLUMES[i]
                cfgSave()
                if Cfg.gbaVolume <= 0 then stopSound()
                elseif S.stream and not S.stream.failed then S.stream.setVolume(Cfg.gbaVolume)
                else startSound() end
            end)
        volDd.button.TextSize = 11
    end

    -- input ----------------------------------------------------------------------------
    local held = {}
    local function press(name, down)
        held[name] = down or nil
        local mask = 0
        for k in pairs(held) do mask = mask + KEYBIT[k] end
        S.keys = mask
        if S.emu then S.emu.setKeys(mask) end
    end
    releaseAll = function()
        held = {}
        S.keys = 0
        if S.emu then S.emu.setKeys(0) end
    end
    local function padButton(text, name, x, y, w, h, round)
        local b = make("TextButton", {
            Position = UDim2.fromOffset(x, y), Size = UDim2.fromOffset(w, h), BackgroundColor3 = PAL.CARD, BackgroundTransparency = 0.1,
            BorderSizePixel = 0, AutoButtonColor = false, Text = text, TextColor3 = PAL.TEXT, Font = Enum.Font.GothamBold, TextSize = 12,
        }, f)
        corner(b, round and math.floor(w / 2) or 6)
        b.InputBegan:Connect(function(input) if isPointer(input) then press(name, true); b.BackgroundColor3 = PAL.ELEVATED end end)
        b.InputEnded:Connect(function(input) if isPointer(input) then press(name, false); b.BackgroundColor3 = PAL.CARD end end)
        b.MouseLeave:Connect(function() if held[name] then press(name, false); b.BackgroundColor3 = PAL.CARD end end)
        return b
    end
    local py = 356
    padButton("L", "l", 16, py, 70, 24)
    padButton("R", "r", W - 86, py, 70, 24)
    padButton("^", "up", 58, py + 30, 32, 32)
    padButton("<", "left", 24, py + 64, 32, 32)
    padButton(">", "right", 92, py + 64, 32, 32)
    padButton("v", "down", 58, py + 98, 32, 32)
    padButton("Select", "select", 146, py + 92, 52, 22)
    padButton("Start", "start", 204, py + 92, 52, 22)
    padButton("B", "b", W - 108, py + 56, 40, 40, true)
    padButton("A", "a", W - 60, py + 36, 40, 40, true)

    local KC = Enum.KeyCode
    local KEYS = {
        [KC.Up] = "up", [KC.W] = "up", [KC.Down] = "down", [KC.S] = "down",
        [KC.Left] = "left", [KC.A] = "left", [KC.Right] = "right", [KC.D] = "right",
        [KC.X] = "a", [KC.K] = "a", [KC.Z] = "b", [KC.J] = "b", [KC.Q] = "l", [KC.E] = "r",
        [KC.Return] = "start", [KC.Backspace] = "select", [KC.RightShift] = "select",
    }
    local keyList = {}
    for kc in pairs(KEYS) do keyList[#keyList + 1] = kc end
    local ACTION = "PuppyAdminGBA"
    local bound = false
    local function onKey(_, state, input)
        if not (S.running and S.emu) then return Enum.ContextActionResult.Pass end
        local name = KEYS[input.KeyCode]
        if not name then return Enum.ContextActionResult.Pass end
        press(name, state == Enum.UserInputState.Begin)
        return Enum.ContextActionResult.Sink
    end
    local function bind(on)
        if on == bound then return end
        bound = on
        if on then
            pcall(function() ContextActionService:BindActionAtPriority(ACTION, onKey, false, 3000, table.unpack(keyList)) end)
        else
            pcall(function() ContextActionService:UnbindAction(ACTION) end)
            releaseAll()
        end
    end

    -- main loop: real-time pacing. When frames cost more than the time they stand for,
    -- only every 2nd or 3rd one is drawn (the game keeps its speed for longer).
    local loop
    local function startLoop()
        if loop then return end
        loop = RunService.Heartbeat:Connect(function(dt)
            local emu = S.emu
            if not (S.running and emu) then return end
            local want
            if S.fast then
                want = math.clamp(math.floor(0.03 / math.max(S.frameCost, 0.002)), 1, 4)
                S.acc = 0
            else
                S.acc = math.min(S.acc + dt, 0.25)
                want = math.min(3, math.floor(S.acc / FRAME))
                S.acc = S.acc - want * FRAME
                if S.acc > 0.1 then S.acc = 0 end
            end
            local budget = os.clock() + 0.03
            local drew = false
            for i = 1, want do
                local t = os.clock()
                S.skipCount = S.skipCount + 1
                local render = (i == want) and S.skipCount >= S.renderEvery
                if render then S.skipCount = 0 end
                local ok, err = pcall(emu.runFrame, render)
                if not ok then
                    setRunning(false)
                    overlay.Visible = true
                    overlay.Text = "The emulator stopped:\n" .. tostring(err)
                    return
                end
                drew = drew or render
                S.frames = S.frames + 1
                S.frameCost = S.frameCost * 0.9 + (os.clock() - t) * 0.1
                if os.clock() > budget then break end
            end
            if drew then present() end
            local stream = S.stream
            if stream then
                local buf, n = emu.audioPull()
                if S.fast then stream.reset() else stream.push(buf, n) end
                stream.update(dt)
                if stream.failed then emu.setAudio(false) end
            end
            -- draw less often when a frame costs more than real time allows
            if S.frameCost > FRAME * 1.15 then S.renderEvery = math.min(3, S.renderEvery + 1)
            elseif S.frameCost < FRAME * 0.6 then S.renderEvery = math.max(1, S.renderEvery - 1) end
            local now = os.clock()
            if now - S.secondStart >= 1 then
                local pct = math.floor(S.frames / (now - S.secondStart) / 59.73 * 100 + 0.5)
                S.frames, S.secondStart = 0, now
                status.Text = statusBase .. "  [" .. pct .. "%" .. (S.renderEvery > 1 and (", drawing 1 in " .. S.renderEvery) or "")
                    .. (S.stream and (", " .. S.stream.state) or "") .. "]"
            end
            if now - S.lastSave > 5 then saveNow() end
        end)
        table.insert(conns, loop)
    end
    local function stopLoop()
        if loop then loop:Disconnect(); loop = nil end
    end

    f:GetPropertyChangedSignal("Visible"):Connect(function()
        if f.Visible then
            bind(true)
            startLoop()
        else
            if S.running then setRunning(false) end
            saveNow()
            bind(false)
            stopLoop()
        end
    end)
    table.insert(conns, UserInputService.WindowFocusReleased:Connect(function() releaseAll() end))
    table.insert(cleanups, function() saveNow(); bind(false); stopLoop(); stopSound() end)
end

------------------------------------------------------------------------
-- Doom window (`doom`): the 1993 Doom engine (doomgeneric, GPL-2.0)
-- converted to Luau, in emu/doom-<version>.lua (downloaded once into
-- PuppyAdmin/engine). The game data is your own WAD in the executor folder
-- PuppyAdmin/doom (DOOM1.WAD shareware, DOOM.WAD, DOOM2.WAD or Freedoom);
-- saves and Doom's settings are written there too. Sound: see
-- UIAPI.newDoomSound.
------------------------------------------------------------------------

UIAPI.DOOM_MODULE = { version = "8b7cd116e5", bytes = 3089460 }

-- Doom's sound. The engine reports each sound effect (lump name, channel,
-- volume) and each song (its data); this plays them with Roblox Sounds.
-- Freedoom Phase 1 (the exact WAD in the repository) uses the sound effects
-- and music pre-rendered in assets/doom/freedoom1 as mp3, a format Roblox
-- plays here. Other WADs get their sound effects as WAV files made from the
-- WAD (if the executor plays WAV); their music is not played, because that
-- would need a MIDI synthesiser. Stereo separation is not used (2D Sounds).
UIAPI.DOOM_SOUND = { wadBytes = 28795076, pack = "assets/doom/freedoom1/sfx_v1.pak",
    music = "assets/doom/freedoom1/music_v1/" }

function UIAPI.newDoomSound(Doom, wad)
    local DS = UIAPI.DOOM_SOUND
    local DIR = "PuppyAdmin/doom/sound"
    local SFX_GAIN, MUSIC_GAIN, POOL = 2, 1.2, 4
    local getAsset = (type(getcustomasset) == "function" and getcustomasset) or (type(getsynasset) == "function" and getsynasset)
    local folder = Instance.new("Folder")
    folder.Name = "PuppyAdminDoomSound"
    folder.Parent = game:GetService("SoundService")
    local byName, list = Doom.lumps(wad)
    local freedoom = #wad == DS.wadBytes and Doom.identify(wad) == "freedoom1.wad"
    local S = { state = "sound off", level = 1 }
    local dead, loadStarted = false, false
    local sfx = {}        -- lump name -> { id = content id, len = seconds, pool = { Sound } }
    local chanSound = {}  -- Doom channel -> Sound playing on it
    local busyUntil = {}  -- Sound -> os.clock() when it ends
    local lastVol = {}
    local userPaused = false
    -- music: Doom wants it on (musicOn), it is loaded (musicReady), paused by Doom or by the window
    local music, musicOn, musicReady, musicLoop, musicPaused, musicHeld, musicStarted = nil, false, false, false, false, false, false
    local musicVol, musicToken, musicIds, musicStartAt = 64, 0, {}, 0
    local musicBySize = {}
    for _, l in ipairs(list) do
        if l.name:sub(1, 2) == "D_" then
            musicBySize[l.size] = musicBySize[l.size] or {}
            table.insert(musicBySize[l.size], l)
        end
    end

    local function setVol(snd, v)
        v = math.floor(v * 100 + 0.5) / 100
        if lastVol[snd] ~= v then lastVol[snd] = v; snd.Volume = v end
    end
    local function newSound(id, name)
        local snd = Instance.new("Sound")
        snd.Name = name or "Sfx"
        snd.SoundId = id
        snd.Volume = 0
        snd.Parent = folder
        return snd
    end
    local function readCached(file)
        local ok, exists = pcall(isfile, file)
        if not (ok and exists) then return nil end
        local ok2, d = pcall(readfile, file)
        if ok2 and typeof(d) == "buffer" then d = buffer.tostring(d) end
        return ok2 and type(d) == "string" and d or nil
    end
    local function fileAsset(file, body)
        local ok, exists = pcall(isfile, file)
        if not (ok and exists) then pcall(writefile, file, body) end
        local ok2, id = pcall(getAsset, file)
        if ok2 and type(id) == "string" and id ~= "" then return id end
        return nil
    end
    -- "PUPSND1", one line per sound ("NAME offset length ms"), a blank line, then the mp3 files
    local function parsePack(pak)
        if type(pak) ~= "string" or pak:sub(1, 8) ~= "PUPSND1\n" then return nil end
        local headEnd = pak:find("\n\n", 9, true)
        if not headEnd then return nil end
        local base, out = headEnd + 2, {}
        for name, o, l, ms in pak:sub(9, headEnd):gmatch("(%w+) (%d+) (%d+) (%d+)") do
            o, l = tonumber(o), tonumber(l)
            if base + o + l - 1 > #pak then return nil end
            out[#out + 1] = { name = name:upper(), data = pak:sub(base + o, base + o + l - 1), len = tonumber(ms) / 1000, ext = "mp3" }
        end
        return #out > 0 and out or nil
    end

    function S.load()
        if loadStarted then return end
        loadStarted = true
        S.state = "sound loading"
        task.spawn(function()
            local ok, err = pcall(function()
                if not getAsset then error("this executor has no getcustomasset", 0) end
                pcall(function()
                    if makefolder and isfolder then
                        for _, d in ipairs({ "PuppyAdmin", "PuppyAdmin/doom", DIR }) do
                            if not isfolder(d) then makefolder(d) end
                        end
                    end
                end)
                local entries, prefix
                if freedoom then
                    local cache = DIR .. "/freedoom1_" .. DS.pack:match("([^/]+)$")
                    local pak = readCached(cache)
                    entries = parsePack(pak)
                    if not entries then
                        local okDl, body = pcall(function() return game:HttpGet(SETTINGS.Auras.assetBase .. DS.pack) end)
                        entries = okDl and parsePack(body)
                        if not entries then error("the Freedoom sound pack did not download", 0) end
                        pcall(writefile, cache, body)
                    end
                    prefix = "fd1" .. DS.pack:match("_(v%d+)") .. "_"
                else
                    entries = {}
                    for _, l in ipairs(list) do
                        if l.name:sub(1, 2) == "DS" then
                            local data, len = Doom.sfxWav(wad, l)
                            if data then entries[#entries + 1] = { name = l.name, data = data, len = len, ext = "wav" } end
                        end
                    end
                    if #entries == 0 then error("this WAD has no sound effects", 0) end
                    prefix = "w" .. #wad .. "_"
                end
                local made = {}
                for i, e in ipairs(entries) do
                    if dead then return end
                    local id = fileAsset(DIR .. "/" .. prefix .. e.name:lower() .. "." .. e.ext, e.data)
                    if id then
                        local snd = newSound(id, e.name)
                        sfx[e.name] = { id = id, len = e.len, pool = { snd } }
                        made[#made + 1] = snd
                    end
                    if i % 16 == 0 then task.wait() end
                end
                if #made == 0 then error("the sound files could not be made", 0) end
                local t0, loaded = os.clock(), 0
                repeat
                    task.wait(0.25)
                    loaded = 0
                    for _, snd in ipairs(made) do if snd.IsLoaded then loaded = loaded + 1 end end
                until dead or loaded == #made or os.clock() - t0 > 8
                if dead then return end
                if loaded == 0 then
                    error("Roblox did not load the ." .. entries[1].ext .. " sound files", 0)
                end
                S.state = freedoom and "sound on" or "effects only (music is for Freedoom)"
            end)
            if not ok and not dead then
                sfx = {}
                S.state = "no sound"
                note("Doom", "No sound: " .. tostring(err), RED)
            end
        end)
    end

    -- Doom's calls ---------------------------------------------------------------------
    function S.stop(channel)
        local snd = chanSound[channel]
        if not snd then return end
        chanSound[channel] = nil
        busyUntil[snd] = 0
        pcall(function() snd:Stop() end)
    end
    function S.start(name, channel, vol)
        S.stop(channel)
        local e = sfx[name]
        if not e or userPaused or S.level <= 0 then return end
        local now = os.clock()
        local snd
        for _, s in ipairs(e.pool) do
            if (busyUntil[s] or 0) <= now then snd = s; break end
        end
        if not snd then
            if #e.pool < POOL then
                snd = newSound(e.id, name)
                e.pool[#e.pool + 1] = snd
            else
                -- every copy is busy: take the oldest one
                snd = table.remove(e.pool, 1)
                e.pool[#e.pool + 1] = snd
                for c, s in pairs(chanSound) do if s == snd then chanSound[c] = nil end end
            end
        end
        setVol(snd, vol / 127 * SFX_GAIN * S.level)
        snd.TimePosition = 0
        snd:Play()
        busyUntil[snd] = now + e.len + 0.05
        chanSound[channel] = snd
    end
    function S.params(channel, vol)
        local snd = chanSound[channel]
        if snd then setVol(snd, vol / 127 * SFX_GAIN * S.level) end
    end

    local function syncMusic()
        if not music then return end
        setVol(music, musicVol / 127 * MUSIC_GAIN * S.level)
        local want = musicOn and musicReady and not musicPaused and not userPaused and S.level > 0
        if want then
            if musicHeld then
                musicHeld = false
                musicStartAt = os.clock()
                music:Resume()
            elseif not musicStarted or (not music.IsPlaying and os.clock() - musicStartAt > 1) then
                -- custom sounds do not always loop by themselves: start again from the top
                if musicLoop or not musicStarted then
                    musicStarted = true
                    musicStartAt = os.clock()
                    music.TimePosition = 0
                    music:Play()
                else
                    musicOn = false
                end
            end
        elseif music.IsPlaying then
            musicHeld = true
            music:Pause()
        end
    end
    function S.musicStop()
        musicToken = musicToken + 1
        musicOn, musicReady, musicHeld, musicStarted = false, false, false, false
        if music then pcall(function() music:Stop() end) end
    end
    function S.musicPlay(data, looping)
        S.musicStop()
        local name
        for _, l in ipairs(musicBySize[#data] or {}) do
            if wad:sub(l.pos + 1, l.pos + l.size) == data then name = l.name; break end
        end
        if not name or not freedoom then return end
        musicOn, musicLoop = true, looping
        local token = musicToken
        task.spawn(function()
            local id = musicIds[name]
            if not id then
                id = urlImageAsset(SETTINGS.Auras.assetBase .. DS.music .. name:lower() .. ".mp3", "doommusic")
                if not id then
                    if token == musicToken then note("Doom", "Music " .. name .. " did not download", RED) end
                    return
                end
                musicIds[name] = id
            end
            if dead or token ~= musicToken then return end
            if music then music:Destroy() end
            music = newSound(id, "Music")
            music.Looped = looping
            lastVol[music] = nil
            local t0 = os.clock()
            while not music.IsLoaded and os.clock() - t0 < 15 do
                task.wait(0.1)
                if dead or token ~= musicToken then return end
            end
            musicReady = true
            syncMusic()
        end)
    end
    function S.musicPause() musicPaused = true; syncMusic() end
    function S.musicResume() musicPaused = false; syncMusic() end
    function S.musicVolume(v) musicVol = v; syncMusic() end

    -- the Doom window's calls ------------------------------------------------------------
    local lastUpdate = 0
    function S.update()
        local now = os.clock()
        if now - lastUpdate < 0.25 then return end
        lastUpdate = now
        syncMusic()
    end
    local function stopAll()
        for c in pairs(chanSound) do S.stop(c) end
    end
    function S.setPaused(on)
        userPaused = on
        if on then stopAll() end
        syncMusic()
    end
    function S.setVolume(level)
        S.level = level
        if level <= 0 then stopAll() end
        syncMusic()
    end
    function S.destroy()
        dead = true
        musicToken = musicToken + 1
        pcall(function() folder:Destroy() end)
    end
    return S
end

function UIAPI.buildDoomPanel(screenGui)
    local W, HGT = 380, 452
    local f = uiWindow(screenGui, "doom", "Doom", UDim2.fromOffset(W, HGT), UDim2.new(0.5, -W / 2, 0.5, -HGT / 2))
    local DIR, CACHE_DIR = "PuppyAdmin/doom", "PuppyAdmin/engine"
    local DM = UIAPI.DOOM_MODULE
    local FREEDOOM = { label = "Freedoom Phase 1 (download)", file = "freedoom1.wad", bytes = 28795076,
        url = SETTINGS.Auras.assetBase .. "assets/doom/freedoom1.wad" }
    local MOD_NAME = "doom-" .. DM.version .. ".lua"
    local TIC = 1 / 35

    local doom, running, starting = nil, false, false
    local doomSound
    local function dropSound()
        if doomSound then doomSound.destroy(); doomSound = nil end
    end
    local acc, frames, secondStart, fpsShown = 0, 0, os.clock(), 0
    local statusBase = "No game loaded"

    pcall(function()
        if makefolder and isfolder and not isfolder("PuppyAdmin") then makefolder("PuppyAdmin") end
        if makefolder and isfolder and not isfolder(DIR) then makefolder(DIR) end
    end)

    local function wadList()
        local out = {}
        pcall(function()
            for _, p in ipairs(listfiles(DIR)) do
                local name = tostring(p):match("([^/\\]+)$")
                if name and name:lower():match("%.wad$") then out[#out + 1] = name end
            end
        end)
        table.sort(out, function(a, b) return a:lower() < b:lower() end)
        -- Freedoom Phase 1 (free, BSD) is in the repository: offered until it is downloaded
        local have = false
        for _, n in ipairs(out) do if n:lower() == "freedoom1.wad" then have = true end end
        if not have then table.insert(out, 1, FREEDOOM.label) end
        return out
    end
    local listed = {}

    -- screen: 320 x 200, shown at 4:3 like the original monitors
    local sw, sh = 344, 258
    local bezel = make("Frame", {
        Position = UDim2.fromOffset((W - sw) / 2 - 4, 76), Size = UDim2.fromOffset(sw + 8, sh + 8),
        BackgroundColor3 = Color3.fromRGB(0, 0, 0), BorderSizePixel = 0,
    }, f)
    corner(bezel, 8)
    local screen = make("ImageLabel", {
        Position = UDim2.fromOffset(4, 4), Size = UDim2.fromOffset(sw, sh), BackgroundColor3 = Color3.fromRGB(0, 0, 0),
        BorderSizePixel = 0, ScaleType = Enum.ScaleType.Stretch,
    }, bezel)
    pcall(function() screen.ResampleMode = Enum.ResamplerMode.Pixelated end)
    local overlay = label(bezel, {
        Position = UDim2.fromOffset(16, 4), Size = UDim2.fromOffset(sw - 24, sh), TextWrapped = true, ZIndex = 3,
        TextXAlignment = Enum.TextXAlignment.Center, TextColor3 = Color3.fromRGB(230, 230, 230), TextSize = 13,
        Text = "Pick \"Freedoom Phase 1\" above to play right away (free, downloaded once), or put your own WAD "
            .. "(DOOM1.WAD, DOOM.WAD, DOOM2.WAD) in your executor's workspace/PuppyAdmin/doom folder and pick it.",
    })
    local status = label(f, { Position = UDim2.fromOffset(16, 340), Size = UDim2.fromOffset(W - 32 - 114, 16), TextSize = 11,
        TextColor3 = PAL.DIM, TextTruncate = Enum.TextTruncate.AtEnd, Text = statusBase })
    label(f, { Position = UDim2.fromOffset(16, 360), Size = UDim2.fromOffset(W - 32, 84), TextSize = 11, TextWrapped = true,
        TextYAlignment = Enum.TextYAlignment.Top, TextColor3 = PAL.DIM,
        Text = "Arrows or W/S move, A/D strafe, Left/Right turn, Ctrl or F fire, Space or E use, Shift run, 1-7 weapons, "
            .. "Tab map, P menu (Esc is Roblox's), Enter select, Y/N answer. Mouse: click 'Mouse' to turn with the mouse "
            .. "and fire with the left button (click it again or press P to get the cursor back)." })

    local image, pixels
    local function makeImage()
        if image then return true end
        local ok, ei = pcall(function()
            return game:GetService("AssetService"):CreateEditableImage({ Size = Vector2.new(320, 200) })
        end)
        if not ok or not ei then return false, "EditableImage is not available: " .. tostring(ei) end
        local shown = pcall(function() screen.ImageContent = Content.fromObject(ei) end)
        if not shown then shown = pcall(function() ei.Parent = screen end) end
        if not shown then return false, "could not show the screen" end
        image, pixels = ei, buffer.create(320 * 200 * 4)
        return true
    end

    local function loadModule()
        if UIAPI.doomModuleLoaded then return UIAPI.doomModuleLoaded end
        local head = "-- PuppyAdmin doom " .. DM.version
        local function valid(src) return type(src) == "string" and #src == DM.bytes and src:sub(1, #head) == head end
        local path = CACHE_DIR .. "/" .. MOD_NAME
        local src
        pcall(function() if isfile(path) then src = readfile(path) end end)
        if typeof(src) == "buffer" then src = buffer.tostring(src) end
        if not valid(src) then
            local ok, body = pcall(function() return game:HttpGet(SETTINGS.Auras.assetBase .. "emu/" .. MOD_NAME) end)
            if not ok or not valid(body) then error("Doom download failed or was incomplete", 0) end
            src = body
            pcall(function()
                if makefolder and isfolder and not isfolder(CACHE_DIR) then makefolder(CACHE_DIR) end
                writefile(path, src)
            end)
        end
        local fn, err = (loadstring or load)(src, "=PuppyAdminDoom")
        if not fn then error("Doom did not compile: " .. tostring(err), 0) end
        UIAPI.doomModuleLoaded = fn()
        return UIAPI.doomModuleLoaded
    end

    -- Doom's own files (saves, settings) live next to the WAD; "/" in a name becomes "_"
    local function diskName(name) return DIR .. "/" .. name:gsub("[/\\]", "_") end
    local function readBinary(path)
        local ok, d = pcall(readfile, path)
        if ok and typeof(d) == "buffer" then d = buffer.tostring(d) end
        if ok and type(d) == "string" then return d end
        return nil
    end

    local releaseAll
    local pauseBtn
    local function setRunning(on)
        running = on and doom ~= nil
        if doomSound then doomSound.setPaused(not running) end
        if releaseAll then releaseAll() end
        if pauseBtn then pauseBtn.Text = running and "Pause" or "Play" end
    end

    local function startGame(name)
        if starting then return end
        starting = true
        task.spawn(function()
            doom, running = nil, false
            dropSound()
            overlay.Visible = true
            overlay.Text = "Loading Doom and " .. name .. "...\n(the first time downloads the engine, about 3 MB)"
            local ok, err = pcall(function()
                local okImg, why = makeImage()
                if not okImg then error(why, 0) end
                local Doom = loadModule()
                local downloaded
                if name == FREEDOOM.label then
                    -- one download (28 MB), then it is a normal file in PuppyAdmin/doom
                    overlay.Text = "Downloading Freedoom Phase 1 (28 MB)...\nThis happens once."
                    local okDl, body = pcall(function() return game:HttpGet(FREEDOOM.url) end)
                    if not okDl or type(body) ~= "string" or #body ~= FREEDOOM.bytes or not Doom.identify(body) then
                        error("Freedoom download failed or was incomplete (" .. (type(body) == "string" and #body or 0) .. " of " .. FREEDOOM.bytes .. " bytes)", 0)
                    end
                    pcall(writefile, DIR .. "/" .. FREEDOOM.file, body)
                    downloaded = body
                    name = FREEDOOM.file
                    overlay.Text = "Starting Freedoom..."
                end
                local wad = downloaded or (UIAPI.gbReadFile and UIAPI.gbReadFile(name, { DIR .. "/" .. name }) or readBinary(DIR .. "/" .. name))
                if not wad then error("could not read " .. name, 0) end
                if not Doom.identify(wad) then error(name .. " is not a Doom WAD this engine knows (DOOM1, DOOM, DOOM2 or Freedoom)", 0) end
                if Doom.lumps then
                    doomSound = UIAPI.newDoomSound(Doom, wad)
                    doomSound.setVolume(Cfg.doomVolume)
                    doomSound.setPaused(true)
                    if Cfg.doomVolume > 0 then doomSound.load() end
                end
                local d = Doom.new(Doom.makeWasm, {
                    sound = doomSound,
                    wadData = wad,
                    clock = os.clock,
                    readFile = function(n) return readBinary(diskName(n)) end,
                    writeFile = function(n, data) pcall(writefile, diskName(n), data) end,
                    deleteFile = function(n) if delfile then pcall(delfile, diskName(n)) end end,
                    yield = function() task.wait() end,
                })
                local gameName = d.start()
                doom = d
                statusBase = name .. "  (" .. gameName .. ")"
            end)
            starting = false
            if not ok then
                doom = nil
                dropSound()
                overlay.Text = "Could not start Doom:\n" .. tostring(err)
                status.Text = "No game loaded"
                return
            end
            overlay.Visible = false
            acc = 0
            status.Text = statusBase
            setRunning(true)
        end)
    end

    -- top row ----------------------------------------------------------------------------
    local dd = uiDropdown(f, "", UDim2.fromOffset(180, 28), UDim2.fromOffset(16, 42), function()
        listed = wadList()
        if #listed == 0 then return { "No WADs in PuppyAdmin/doom" } end
        return listed
    end, 1, function(i)
        local name = listed[i]
        if name then startGame(name) end
    end)
    dd.button.TextSize = 11
    pauseBtn = uiButton(f, "Play", UDim2.fromOffset(56, 28), UDim2.fromOffset(200, 42), function()
        if doom then setRunning(not running) end
    end)
    local mouseOn = false
    local mouseBtn
    local function setMouse(on)
        mouseOn = on and running
        mouseBtn.BackgroundColor3 = mouseOn and PAL.ELEVATED or PAL.CARD
        mouseBtn.Text = mouseOn and "Mouse on" or "Mouse"
        if not mouseOn then pcall(function() UserInputService.MouseBehavior = Enum.MouseBehavior.Default end) end
    end
    mouseBtn = uiButton(f, "Mouse", UDim2.fromOffset(104, 28), UDim2.fromOffset(260, 42), function() setMouse(not mouseOn) end)
    do
        local VOLUMES = { 1, 0.75, 0.5, 0.25, 0 }
        if type(Cfg.doomVolume) ~= "number" then Cfg.doomVolume = 1 end
        local volDd = uiDropdown(f, "", UDim2.fromOffset(108, 22), UDim2.fromOffset(W - 16 - 108, 336),
            { "Sound 100%", "Sound 75%", "Sound 50%", "Sound 25%", "Sound off" },
            table.find(VOLUMES, Cfg.doomVolume) or 1, function(i)
                Cfg.doomVolume = VOLUMES[i]
                cfgSave()
                if doomSound then
                    doomSound.setVolume(Cfg.doomVolume)
                    -- sound was off when the game started: load it now (load() runs once)
                    if Cfg.doomVolume > 0 then doomSound.load() end
                end
            end)
        volDd.button.TextSize = 11
    end

    -- input ----------------------------------------------------------------------------------
    local K = Enum.KeyCode
    local KEYS = {
        [K.Up] = 0xad, [K.W] = 0xad, [K.Down] = 0xaf, [K.S] = 0xaf, [K.Left] = 0xac, [K.Right] = 0xae,
        [K.A] = 0xa0, [K.D] = 0xa1, [K.LeftControl] = 0xa3, [K.RightControl] = 0xa3, [K.F] = 0xa3,
        [K.Space] = 0xa2, [K.E] = 0xa2, [K.LeftShift] = 0xb6, [K.RightShift] = 0xb6, [K.LeftAlt] = 0xb8,
        [K.P] = 27, [K.Escape] = 27, [K.Return] = 13, [K.Tab] = 9, [K.Backspace] = 0x7f,
        [K.Minus] = 0x2d, [K.Equals] = 0x3d, [K.Y] = string.byte("y"), [K.N] = string.byte("n"),
        [K.F2] = 0xbc, [K.F3] = 0xbd, [K.F6] = 0xc0, [K.F9] = 0xc3,
    }
    for i = 1, 7 do KEYS[K[({ "One", "Two", "Three", "Four", "Five", "Six", "Seven" })[i]]] = string.byte(tostring(i)) end
    local held = {}
    local mouseButtons, mouseDx = 0, 0
    releaseAll = function()
        for code in pairs(held) do if doom then pcall(doom.key, false, code) end end
        held = {}
        if mouseButtons ~= 0 and doom then pcall(doom.mouse, 0, 0, 0) end
        mouseButtons, mouseDx = 0, 0
    end
    local keyList = {}
    for kc in pairs(KEYS) do keyList[#keyList + 1] = kc end
    local ACTION, MOUSE_ACTION = "PuppyAdminDoom", "PuppyAdminDoomMouse"
    local bound = false
    local function onKey(_, state, input)
        if not (running and doom) then return Enum.ContextActionResult.Pass end
        local code = KEYS[input.KeyCode]
        if not code then return Enum.ContextActionResult.Pass end
        local down = state == Enum.UserInputState.Begin
        if code == 27 and down and mouseOn then setMouse(false) end -- P / menu gives the cursor back
        if down then held[code] = true else held[code] = nil end
        pcall(doom.key, down, code)
        return Enum.ContextActionResult.Sink
    end
    -- with Mouse on: movement turns (and is kept from the Roblox camera), left button fires
    local function onMouse(_, state, input)
        if not (running and doom and mouseOn) then return Enum.ContextActionResult.Pass end
        if input.UserInputType == Enum.UserInputType.MouseMovement then
            mouseDx = mouseDx + input.Delta.X
        elseif input.UserInputType == Enum.UserInputType.MouseButton1 then
            mouseButtons = state == Enum.UserInputState.Begin and 1 or 0
            pcall(doom.mouse, mouseButtons, 0, 0)
        end
        return Enum.ContextActionResult.Sink
    end
    local function bind(on)
        if on == bound then return end
        bound = on
        if on then
            pcall(function() ContextActionService:BindActionAtPriority(ACTION, onKey, false, 3000, table.unpack(keyList)) end)
            pcall(function()
                ContextActionService:BindActionAtPriority(MOUSE_ACTION, onMouse, false, 3000,
                    Enum.UserInputType.MouseMovement, Enum.UserInputType.MouseButton1)
            end)
        else
            pcall(function() ContextActionService:UnbindAction(ACTION) end)
            pcall(function() ContextActionService:UnbindAction(MOUSE_ACTION) end)
            releaseAll()
            setMouse(false)
        end
    end

    -- main loop: Doom's clock moves 1/35 s per tic of real time (up to 4 tics per frame when
    -- the device is slow, so the game keeps its speed and only the frame rate drops)
    local loop
    local function startLoop()
        if loop then return end
        loop = RunService.Heartbeat:Connect(function(dt)
            if mouseOn then
                pcall(function() UserInputService.MouseBehavior = Enum.MouseBehavior.LockCenter end)
            end
            if not (running and doom) then return end
            acc = math.min(acc + dt, 0.25)
            local due = math.floor(acc / TIC)
            if due < 1 then return end
            due = math.min(due, 4)
            acc = acc - due * TIC
            if mouseDx ~= 0 then
                pcall(doom.mouse, mouseButtons, math.floor(mouseDx * 4 + 0.5), 0)
                mouseDx = 0
            end
            doom.advance(due * 1000 / 35)
            local ok, err = pcall(doom.tick)
            if not ok then
                setRunning(false)
                setMouse(false)
                doom = nil
                dropSound()
                overlay.Visible = true
                overlay.Text = tostring(err):find("DOOM_EXIT") and "Doom closed. Pick a WAD above to play again."
                    or ("Doom stopped:\n" .. tostring(err))
                status.Text = "No game loaded"
                return
            end
            if doomSound then doomSound.update() end
            if doom.blit(pixels) then
                pcall(function() image:WritePixelsBuffer(Vector2.zero, Vector2.new(320, 200), pixels) end)
                frames = frames + 1
            end
            local now = os.clock()
            if now - secondStart >= 1 then
                fpsShown = math.floor(frames / (now - secondStart) + 0.5)
                frames, secondStart = 0, now
                status.Text = statusBase .. "  [" .. fpsShown .. " fps" .. (doomSound and (", " .. doomSound.state) or "") .. "]"
            end
        end)
        table.insert(conns, loop)
    end
    local function stopLoop()
        if loop then loop:Disconnect(); loop = nil end
    end

    f:GetPropertyChangedSignal("Visible"):Connect(function()
        if f.Visible then
            bind(true)
            startLoop()
        else
            if running then setRunning(false) end
            bind(false)
            stopLoop()
        end
    end)
    table.insert(conns, UserInputService.WindowFocusReleased:Connect(function()
        releaseAll()
        if mouseOn then setMouse(false) end
    end))
    table.insert(cleanups, function() bind(false); stopLoop(); dropSound() end)
end

------------------------------------------------------------------------
-- Puppy Finder (`finder`): browse this game's public servers and join one,
-- or let it pick (most players / random / fewest players). The picking
-- follows the engine's serverhop: up to 8 pages scanned, servers visited in
-- the last hour avoided, up to 15 retries when a teleport fails. Visited
-- servers are kept in PuppyAdmin/ServerHistory/<PlaceId>.json.
------------------------------------------------------------------------

-- Anti-AFK: Roblox disconnects idle players after 20 minutes. Its idle
-- handler is switched off where the executor allows it (getconnections), and
-- whenever Roblox still reports you idle (after 2 minutes) a harmless virtual
-- right-click resets the timer. On / off is saved (Settings or `antiafk`).
UIAPI.antiAfk = { on = false }
do
    local A = UIAPI.antiAfk
    local paused = {}
    local function apply(on)
        if on == A.on then return end
        A.on = on
        if on then
            if type(getconnections) == "function" then
                pcall(function()
                    for _, c in ipairs(getconnections(plr.Idled)) do
                        if c.Disable then c:Disable(); paused[#paused + 1] = c end
                    end
                end)
            end
            A.conn = plr.Idled:Connect(function()
                pcall(function()
                    local vu = game:GetService("VirtualUser")
                    vu:CaptureController()
                    vu:ClickButton2(Vector2.new())
                end)
            end)
        else
            if A.conn then A.conn:Disconnect(); A.conn = nil end
            for _, c in ipairs(paused) do pcall(function() c:Enable() end) end
            paused = {}
        end
        if UIAPI.antiAfkChanged then pcall(UIAPI.antiAfkChanged) end
    end
    function A.set(on)
        apply(on and true or false)
        Cfg.antiAfk = A.on
        cfgSave()
    end
    if Cfg.antiAfk == true then apply(true) end
    -- killing the script gives Roblox its idle handler back (the saved choice stays)
    table.insert(cleanups, function() apply(false) end)
end

UIAPI.finder = { mode = "most", running = false, servers = {}, status = "Ready" }
do
    local F = UIAPI.finder
    local TeleportService = game:GetService("TeleportService")
    local SCAN_PAGES, MAX_RETRIES, MIN_MOST, MIN_LOW = 8, 15, 8, 2
    local HIST_DIR = "PuppyAdmin/ServerHistory"
    local HIST_FILE = HIST_DIR .. "/" .. tostring(game.PlaceId) .. ".json"
    local OLD_HIST = "ServerHistory/VisitedServers_" .. tostring(game.PlaceId) .. ".json" -- the engine's old place
    F.MODES = { { "most", "Most players" }, { "random", "Random" }, { "lowest", "Fewest players" } }

    local function say(text, progress)
        F.status = text
        if F.onStatus then pcall(F.onStatus, text, progress) end
    end

    function F.loadHistory()
        local data
        pcall(function()
            local path = (isfile(HIST_FILE) and HIST_FILE) or (isfile(OLD_HIST) and OLD_HIST) or nil
            if path then data = HttpService:JSONDecode(readfile(path)) end
        end)
        return type(data) == "table" and data or {}
    end
    function F.saveHistory(h)
        pcall(function()
            if makefolder and isfolder and not isfolder("PuppyAdmin") then makefolder("PuppyAdmin") end
            if makefolder and isfolder and not isfolder(HIST_DIR) then makefolder(HIST_DIR) end
            writefile(HIST_FILE, HttpService:JSONEncode(h))
        end)
    end
    function F.markCurrent()
        if game.JobId == "" then return end
        local h = F.loadHistory()
        h[game.JobId] = { timestamp = os.time(), playerCount = #Players:GetPlayers() }
        -- keep the file small: forget visits older than a day
        for id, v in pairs(h) do
            if type(v) ~= "table" or os.time() - (tonumber(v.timestamp) or 0) > 86400 then h[id] = nil end
        end
        F.saveHistory(h)
    end

    local function getJson(url)
        local body
        local req = (type(request) == "function" and request) or (type(http_request) == "function" and http_request)
            or (type(syn) == "table" and syn.request)
        if req then
            local ok, res = pcall(req, { Url = url, Method = "GET" })
            if ok and type(res) == "table" then
                if tonumber(res.StatusCode) == 429 then return nil, "rate limited" end
                body = res.Body
            end
        end
        if not body then
            local ok, res = pcall(function() return game:HttpGet(url) end)
            if ok then body = res end
        end
        if type(body) ~= "string" then return nil, "no answer" end
        local ok, data = pcall(function() return HttpService:JSONDecode(body) end)
        if not ok or type(data) ~= "table" then return nil, "bad answer" end
        return data
    end

    -- all public servers of this place (up to SCAN_PAGES pages of 100). Yields.
    function F.scan()
        local all, cursor, page = {}, "", 0
        repeat
            local url = "https://games.roblox.com/v1/games/" .. tostring(game.PlaceId) .. "/servers/Public?sortOrder=Desc&limit=100"
            if cursor ~= "" then url = url .. "&cursor=" .. cursor end
            local data, err
            for try = 1, 3 do
                data, err = getJson(url)
                if data then break end
                task.wait(try * 0.6)
            end
            if not data then
                if #all == 0 then return nil, err end
                break
            end
            for _, sv in ipairs(type(data.data) == "table" and data.data or {}) do
                if type(sv) == "table" and sv.id and tonumber(sv.playing) and tonumber(sv.maxPlayers) then
                    all[#all + 1] = { id = sv.id, playing = tonumber(sv.playing), maxPlayers = tonumber(sv.maxPlayers),
                        ping = tonumber(sv.ping), fps = tonumber(sv.fps) }
                end
            end
            cursor = data.nextPageCursor or ""
            page = page + 1
            say("Scanning... page " .. page .. " (" .. #all .. " servers)", 0.1 + page / SCAN_PAGES * 0.5)
            task.wait(0.1)
        until cursor == "" or page >= SCAN_PAGES
        F.servers = all
        return all
    end

    -- the engine's choice: score by mode, avoid servers visited in the last hour
    function F.pick(servers, visited, excluded, mode)
        local minPc = mode == "most" and MIN_MOST or MIN_LOW
        local maxPc = math.floor(Players.MaxPlayers * 0.95)
        local best, bestScore
        for _, sv in ipairs(servers) do
            local pc, mp = sv.playing or 0, sv.maxPlayers or Players.MaxPlayers
            if not excluded[sv.id] and sv.id ~= game.JobId and pc >= minPc and mp - pc >= 1 and pc <= maxPc then
                local score = mode == "most" and pc or (mode == "random" and math.random(0, 60) or -pc)
                local v = visited[sv.id]
                if type(v) == "table" then
                    local age = os.time() - (tonumber(v.timestamp) or 0)
                    if age < 1800 then score = score - 500 elseif age < 3600 then score = score - 200 end
                else
                    score = score + 100
                end
                if not bestScore or score > bestScore then best, bestScore = sv, score end
            end
        end
        return best
    end

    local excluded, retries, target = {}, 0, nil
    function F.teleport(id)
        F.markCurrent()
        AntiKick.allowUntil = os.clock() + 10
        target = id
        local ok, err = pcall(function() TeleportService:TeleportToPlaceInstance(game.PlaceId, id, plr) end)
        return ok, err
    end

    -- find a server by mode and join it; retries on a failed teleport. Yields.
    function F.hop(mode)
        if F.running then return end
        F.running = true
        F.mode = mode or F.mode
        say("Loading server list...", 0.05)
        local servers, err = F.scan()
        if not servers or #servers == 0 then
            say(servers and "No servers found" or ("Could not load servers: " .. tostring(err)), 1)
            F.running = false
            return
        end
        say("Choosing from " .. #servers .. " servers...", 0.7)
        local visited = F.loadHistory()
        local pick = F.pick(servers, visited, excluded, F.mode)
        if not pick then pick = F.pick(servers, {}, excluded, F.mode) end -- widen: ignore history
        if not pick then
            say("No suitable server found", 1)
            F.running = false
            return
        end
        say("Joining a server with " .. pick.playing .. " players (attempt " .. (retries + 1) .. ")", 0.95)
        local ok = F.teleport(pick.id)
        if not ok then
            excluded[pick.id] = true
            retries = retries + 1
            F.running = false
            if retries < MAX_RETRIES then task.delay(1, function() F.hop(F.mode) end)
            else say("Gave up after " .. MAX_RETRIES .. " attempts", 1) end
        end
    end

    function F.start(mode)
        excluded, retries, target = {}, 0, nil
        task.spawn(F.hop, mode)
    end

    -- full, closed or refused servers: try another one
    table.insert(conns, TeleportService.TeleportInitFailed:Connect(function(who, result)
        if who ~= plr then return end
        local reason = typeof(result) == "EnumItem" and result.Name or tostring(result)
        if target then excluded[target] = true end
        if F.running or retries > 0 then
            F.running = false
            if (reason == "GameEnded" or reason == "GameFull" or reason == "Unauthorized") and retries < MAX_RETRIES then
                retries = retries + 1
                say("That server refused (" .. reason .. "), trying another (" .. retries .. "/" .. MAX_RETRIES .. ")", 0.4)
                task.delay(1, function() F.hop(F.mode) end)
            else
                say("Teleport failed: " .. reason, 1)
            end
        else
            say("Teleport failed: " .. reason, 1)
        end
    end))

    function F.rejoin()
        F.markCurrent()
        AntiKick.allowUntil = os.clock() + 10
        pcall(function()
            if #Players:GetPlayers() <= 1 then
                TeleportService:Teleport(game.PlaceId, plr)
            else
                TeleportService:TeleportToPlaceInstance(game.PlaceId, game.JobId, plr)
            end
        end)
    end
end

function UIAPI.buildFinderPanel(screenGui)
    local F = UIAPI.finder
    local W, HGT = 380, 470
    local f = uiWindow(screenGui, "finder", "Puppy Finder", UDim2.fromOffset(W, HGT), UDim2.new(0.5, -W / 2, 0.5, -HGT / 2))
    local IW = W - 32

    local modeLabels = {}
    for i, m in ipairs(F.MODES) do modeLabels[i] = m[2] end
    local modeIdx = 1
    for i, m in ipairs(F.MODES) do if m[1] == F.mode then modeIdx = i end end
    uiDropdown(f, "", UDim2.fromOffset(140, 28), UDim2.fromOffset(16, 42), modeLabels, modeIdx, function(i) F.mode = F.MODES[i][1] end)
        .button.TextSize = 11

    local refresh -- set below
    uiButton(f, "Find & join", UDim2.fromOffset(110, 28), UDim2.fromOffset(160, 42), function() F.start(F.mode) end)
    uiButton(f, "Refresh", UDim2.fromOffset(74, 28), UDim2.fromOffset(16 + IW - 74, 42), function() refresh() end)

    local status = label(f, { Position = UDim2.fromOffset(16, 78), Size = UDim2.fromOffset(IW, 16), TextSize = 12,
        TextTruncate = Enum.TextTruncate.AtEnd, Text = F.status })
    local track = make("Frame", { Position = UDim2.fromOffset(16, 98), Size = UDim2.fromOffset(IW, 4), BackgroundColor3 = PAL.ELEVATED,
        BorderSizePixel = 0 }, f)
    corner(track, 2)
    local fill = make("Frame", { Size = UDim2.new(0, 0, 1, 0), BackgroundColor3 = PAL.ACCENT, BorderSizePixel = 0 }, track)
    corner(fill, 2)
    F.onStatus = function(text, progress)
        status.Text = text
        if progress then TweenService:Create(fill, TweenInfo.new(0.3), { Size = UDim2.new(math.clamp(progress, 0, 1), 0, 1, 0) }):Play() end
    end

    local countLbl = label(f, { Position = UDim2.fromOffset(16, 110), Size = UDim2.fromOffset(150, 18), TextSize = 11, TextColor3 = PAL.DIM,
        Text = "Servers" })
    local SORTS = { "Most players", "Fewest players", "Lowest ping" }
    local sortIdx = 1
    local render -- set below
    uiDropdown(f, "Sort: ", UDim2.fromOffset(150, 22), UDim2.fromOffset(16 + IW - 150, 108), SORTS, 1, function(i)
        sortIdx = i
        render()
    end).button.TextSize = 11

    local list = make("ScrollingFrame", {
        Position = UDim2.fromOffset(16, 136), Size = UDim2.fromOffset(IW, 262), BackgroundColor3 = PAL.CARD, BackgroundTransparency = 0.4,
        BorderSizePixel = 0, ScrollBarThickness = 3, ScrollBarImageColor3 = PAL.DIM, CanvasSize = UDim2.new(0, 0, 0, 0),
        AutomaticCanvasSize = Enum.AutomaticSize.Y,
    }, f)
    corner(list, 8)
    make("UIListLayout", { Padding = UDim.new(0, 3), SortOrder = Enum.SortOrder.LayoutOrder }, list)
    make("UIPadding", { PaddingTop = UDim.new(0, 3), PaddingLeft = UDim.new(0, 3), PaddingRight = UDim.new(0, 6) }, list)

    local function ago(t)
        local s = os.time() - (tonumber(t) or 0)
        if s < 60 then return "just now" end
        if s < 3600 then return math.floor(s / 60) .. " min ago" end
        return math.floor(s / 3600) .. " h ago"
    end

    local rows = {}
    render = function()
        for _, r in ipairs(rows) do r:Destroy() end
        rows = {}
        local servers = {}
        for _, sv in ipairs(F.servers) do servers[#servers + 1] = sv end
        if sortIdx == 1 then table.sort(servers, function(a, b) return a.playing > b.playing end)
        elseif sortIdx == 2 then table.sort(servers, function(a, b) return a.playing < b.playing end)
        else table.sort(servers, function(a, b) return (a.ping or 1e9) < (b.ping or 1e9) end) end
        local visited = F.loadHistory()
        countLbl.Text = #servers .. " servers"
        for i = 1, math.min(#servers, 150) do
            local sv = servers[i]
            local here = sv.id == game.JobId
            local full = sv.playing >= sv.maxPlayers
            local row = make("Frame", { Size = UDim2.new(1, 0, 0, 38), BackgroundColor3 = here and PAL.ELEVATED or PAL.CARD,
                BackgroundTransparency = 0.15, BorderSizePixel = 0, LayoutOrder = i }, list)
            corner(row, 6)
            label(row, { Position = UDim2.fromOffset(10, 3), Size = UDim2.new(1, -96, 0, 18), TextSize = 13, Font = Enum.Font.GothamBold,
                Text = sv.playing .. " / " .. sv.maxPlayers .. " players" .. (here and "  (you are here)" or "") })
            local bits = {}
            if sv.ping then bits[#bits + 1] = math.floor(sv.ping) .. " ms" end
            if sv.fps then bits[#bits + 1] = math.floor(sv.fps) .. " fps" end
            local v = visited[sv.id]
            if type(v) == "table" then bits[#bits + 1] = "visited " .. ago(v.timestamp) end
            label(row, { Position = UDim2.fromOffset(10, 20), Size = UDim2.new(1, -96, 0, 14), TextSize = 11, TextColor3 = PAL.DIM,
                Text = table.concat(bits, "  -  ") })
            if not here then
                local id = sv.id
                uiButton(row, full and "Full" or "Join", UDim2.fromOffset(70, 26), UDim2.new(1, -76, 0, 6), function()
                    if full then return end
                    F.onStatus("Joining...", 1)
                    local ok, err = F.teleport(id)
                    if not ok then F.onStatus("Could not join: " .. tostring(err), 1) end
                end)
            end
            rows[#rows + 1] = row
        end
    end

    local loading = false
    refresh = function()
        if loading then return end
        loading = true
        task.spawn(function()
            F.onStatus("Loading server list...", 0.05)
            local servers, err = F.scan()
            loading = false
            if not servers then F.onStatus("Could not load servers: " .. tostring(err), 1); return end
            F.onStatus("Ready - " .. #servers .. " servers", 1)
            task.delay(0.6, function() TweenService:Create(fill, TweenInfo.new(0.4), { Size = UDim2.new(0, 0, 1, 0) }):Play() end)
            render()
        end)
    end

    local bw = (IW - 8) / 2
    uiButton(f, "Rejoin this server", UDim2.fromOffset(bw, 30), UDim2.fromOffset(16, 406), function() F.rejoin() end)
    uiButton(f, "Copy join script", UDim2.fromOffset(bw, 30), UDim2.fromOffset(16 + bw + 8, 406), function()
        local text = string.format('game:GetService("TeleportService"):TeleportToPlaceInstance(%d, "%s")', game.PlaceId, game.JobId)
        local ok = pcall(function() (setclipboard or toclipboard)(text) end)
        note("Puppy Finder", ok and "Join script for this server copied - friends can run it to join you" or "This executor cannot copy to the clipboard", ok and LIGHT or RED)
    end)
    label(f, { Position = UDim2.fromOffset(16, 442), Size = UDim2.fromOffset(IW, 22), TextSize = 10, TextWrapped = true, TextColor3 = PAL.DIM,
        Text = "Find & join skips servers you visited in the last hour. Also: serverhop, shmost, shlowest, rejoin." })

    f:GetPropertyChangedSignal("Visible"):Connect(function()
        if f.Visible and #F.servers == 0 then refresh() end
    end)
end

local function buildPanels(screenGui)
    local B = UIAPI.builders
    B.tools = function() buildToolsPanel(screenGui) end
    B.move = function() buildMovementPanel(screenGui) end
    B.esp = function() buildEspPanel(screenGui) end
    B.floor = function() buildFloorPanel(screenGui) end
    B.tags = function() buildTagPanel(screenGui) end
    B.taglist = function() buildTagListPanel(screenGui) end
    B.vcb = function() buildVcbPanel(screenGui) end
    B.reanim = function() buildReanimPanel(screenGui) end
    B.owner = function() buildOwnerPanel(screenGui) end
    B.blacklist = function() buildBlacklistPanel(screenGui) end
    B.performance = function() buildPerformancePanel(screenGui) end
    B.games = function() buildGamesPanel(screenGui) end
    B.gameboy = function() UIAPI.buildGameBoyPanel(screenGui) end
    B.gba = function() UIAPI.buildGbaPanel(screenGui) end
    B.superfly = function() UIAPI.buildSuperflyPanel(screenGui) end
    B.doom = function() UIAPI.buildDoomPanel(screenGui) end
    B.finder = function() UIAPI.buildFinderPanel(screenGui) end
    B.alts = function() UIAPI.buildAltsPanel(screenGui) end
end

-- Custom mouse cursor (Settings > Look). The image follows the mouse in its own
-- ScreenGui above everything and Roblox's own pointer is hidden; "hot" is the point
-- of the image that sits on the mouse position (fraction of its size). Images live
-- in assets/cursors (new file name when one changes: they are cached by URL).
do
    local C = { gui = nil, img = nil, conn = nil }
    UIAPI.Cursor = C
    C.BUILTIN = {
        Glove = { file = "glove_v1.png", hot = Vector2.new(0.992, 0.391) },
        Light = { file = "light_v1.png", hot = Vector2.new(0.5, 0.5) },
        Keyblade = { file = "keyblade_v1.png", hot = Vector2.new(0.836, 0.008) },
    }
    C.CHOICES = { "Default", "Glove", "Light", "Keyblade", "Custom" }

    function C.off()
        if C.conn then C.conn:Disconnect(); C.conn = nil end
        if C.gui then pcall(function() C.gui:Destroy() end); C.gui, C.img = nil, nil end
        pcall(function() UserInputService.MouseIconEnabled = true end)
    end

    local function place()
        if not (C.img and C.img.Parent) then return end
        local locked = UserInputService.MouseBehavior == Enum.MouseBehavior.LockCenter
        C.img.Visible = not locked -- first person / shift lock: no pointer, like Roblox's own
        pcall(function() UserInputService.MouseIconEnabled = locked end)
        local m = UserInputService:GetMouseLocation()
        local size = C.img.AbsoluteSize
        C.img.Position = UDim2.fromOffset(m.X - size.X * C.hot.X, m.Y - size.Y * C.hot.Y)
    end

    -- name: one of C.CHOICES; returns ok, message. Yields while an image downloads.
    function C.set(name, quiet)
        name = table.find(C.CHOICES, name) and name or "Default"
        Cfg.cursor = name
        if not quiet then cfgSave() end
        if name == "Default" then C.off(); return true, "Cursor: Roblox's own" end
        local src, hot
        if name == "Custom" then
            local reason
            src, reason = resolveImageSource(Cfg.cursorImage, "cursor")
            if not src then C.off(); return false, "Custom cursor: " .. tostring(reason) end
            hot = Vector2.new(0, 0) -- a custom image points with its top-left corner, like an arrow
        else
            local b = C.BUILTIN[name]
            src = urlImageAsset(SETTINGS.Auras.assetBase .. "assets/cursors/" .. b.file, "cursor")
            if not src then C.off(); return false, "Cursor image could not be loaded (needs getcustomasset + writefile)" end
            hot = b.hot
        end
        if not C.gui then
            C.gui = Instance.new("ScreenGui")
            C.gui.Name = "PuppyAdminCursor"
            C.gui.IgnoreGuiInset = true
            C.gui.DisplayOrder = 2147483000
            C.gui.ResetOnSpawn = false
            parentGui(C.gui)
            C.img = make("ImageLabel", { BackgroundTransparency = 1, Active = false, ZIndex = 10,
                ScaleType = Enum.ScaleType.Fit }, C.gui)
            C.conn = RunService.RenderStepped:Connect(function() pcall(place) end)
        end
        C.hot = hot
        C.img.Image = src
        C.img.Size = UDim2.fromOffset(Cfg.cursorSize or 40, Cfg.cursorSize or 40)
        place()
        return true, "Cursor: " .. name
    end

    function C.setSize(px)
        Cfg.cursorSize = math.clamp(math.floor(tonumber(px) or 40), 16, 128)
        if C.img then C.img.Size = UDim2.fromOffset(Cfg.cursorSize, Cfg.cursorSize) end
        cfgSave()
    end

    table.insert(cleanups, C.off)
end

-- Command directory tabs: every command has one category (explicit list first,
-- then the engine's movement / performance groups, then words in its help line).
do
    UIAPI.CMD_CATEGORIES = { "Windows", "Movement", "Reanim", "Character", "Players", "Tools & auras", "Alts",
        "Tags", "Games", "Server", "Performance", "Owner", "Settings", "Other" }
    local EXPLICIT = {
        Movement = { "moveui", "infbaseplate", "uninfbaseplate", "tp", "superfly", "clicktp" },
        Reanim = { "reanim", "anim" },
        Players = { "esp", "unesp", "hide", "unhide", "mute", "unmute" },
        ["Tools & auras"] = { "tools", "aura", "unaura", "auras" },
        Alts = { "alts", "alt", "altcmds", "form", "unform" },
        Tags = { "tagui", "taglist", "tagsync", "tagrefresh", "hidetags", "showtags", "toggletags" },
        Games = { "games", "gameboy", "gba", "doom" },
        Server = { "finder", "shmost", "shlowest", "serverhop", "rejoin", "antiafk", "unantiafk", "antikick", "unantikick", "antivcban" },
        Performance = { "perf", "performance" },
        Owner = { "owner", "kick", "ban", "unban", "bans", "blacklist" },
        Settings = { "prefix", "uikey", "settings", "theme", "help", "kill", "stop", "cursor", "font" },
    }
    local byName = {}
    for cat, names in pairs(EXPLICIT) do for _, n in ipairs(names) do byName[n] = cat end end
    local WORDS = {
        { "Movement", { "fly", "speed", "walk", "jump", "noclip", "teleport", "swim", "float", "gravity", "airwalk", "spin" } },
        { "Character", { "animation", "emote", "dance", "sit", "character", "avatar", "rig", "limb", "body" } },
        { "Players", { "player", "spectate", "view", "follow" } },
        { "Performance", { "fps", "graphics", "lag", "shadow", "light" } },
        { "Server", { "server", "rejoin", "hop" } },
    }
    function UIAPI.cmdCategory(name)
        if byName[name] then return byName[name] end
        for _, c in ipairs(PUP_MOVE) do if c.name == name then return "Movement" end end
        for _, c in ipairs(PUP_PERF) do if c.name == name then return "Performance" end end
        local doc = tostring(cmdDocs[name] or ""):lower()
        for _, w in ipairs(WORDS) do
            for _, word in ipairs(w[2]) do
                if doc:find(word, 1, true) then return w[1] end
            end
        end
        return "Other"
    end

    -- commands that open a window. A string is the panel to show (without the command's
    -- other effects, e.g. esp / infbaseplate also switch their feature on); true runs the
    -- command, which opens its own window.
    UIAPI.CMD_OPENS = {
        tools = "tools", moveui = "move", infbaseplate = "floor", esp = "esp", superfly = true, reanim = true,
        tagui = true, taglist = true, owner = true, blacklist = true, performance = true,
        games = true, gameboy = true, gba = true, doom = true, finder = true, antivcban = true,
        alts = true, altcmds = true, settings = true, theme = true, help = true,
    }
    function UIAPI.cmdOpensWindow(name)
        local v = UIAPI.CMD_OPENS[name]
        if v == true then return type(H[name]) == "function" end
        return type(v) == "string"
    end
    function UIAPI.openForCommand(name)
        local v = UIAPI.CMD_OPENS[name]
        if type(v) == "string" then
            local p = UIAPI.panels[v]
            if p then p.Visible = true; UIAPI.sync() end
        elseif v == true and type(H[name]) == "function" then
            task.spawn(function() pcall(H[name], {}) end)
        end
    end
end

------------------------------------------------------------------------
-- Interface
------------------------------------------------------------------------

local helpEntries = {}

local function createUI()
    if genv.PuppyAdminUI then genv.PuppyAdminUI:Destroy() end

    local screenGui = Instance.new("ScreenGui")
    screenGui.Name = "PuppyAdminGui"
    parentGui(screenGui)
    genv.PuppyAdminUI = screenGui
    Theme.attach(screenGui)
    ui = screenGui

    local frame = make("Frame", {
        Size = UDim2.new(0.3, 0, 0, 80),
        Position = UDim2.new(0, 15, 0.5, -40),
        BackgroundColor3 = Color3.fromRGB(15, 15, 15),
        BackgroundTransparency = 0.4,
        BorderSizePixel = 0,
        Active = true,
        Draggable = true,
    }, screenGui)
    make("UICorner", { CornerRadius = UDim.new(0, 8) }, frame)
    make("UIStroke", { Color = Color3.fromRGB(80, 80, 80), Transparency = 0.6, Thickness = 1 }, frame)
    make("UISizeConstraint", { MaxSize = Vector2.new(350, 80), MinSize = Vector2.new(220, 80) }, frame)
    Theme.addBackdrop(frame, 8)

    make("TextLabel", {
        Size = UDim2.new(1, -15, 0, 25),
        Position = UDim2.new(0, 15, 0, 5),
        BackgroundTransparency = 1,
        Text = "PUPPY ADMIN",
        TextColor3 = LIGHT,
        Font = Enum.Font.Code,
        TextSize = 12,
        TextXAlignment = Enum.TextXAlignment.Left,
    }, frame)

    local gear = make("TextButton", {
        Size = UDim2.new(0, 34, 0, 18),
        Position = UDim2.new(1, -44, 0, 8),
        BackgroundTransparency = 1,
        Text = "SET",
        TextColor3 = GREY,
        Font = Enum.Font.Code,
        TextSize = 11,
    }, frame)
    gear.MouseButton1Click:Connect(function()
        if settingsFrame then settingsFrame.Visible = not settingsFrame.Visible end
    end)

    local inputContainer = make("Frame", {
        Size = UDim2.new(1, -30, 0, 35),
        Position = UDim2.new(0, 15, 0, 30),
        BackgroundColor3 = Color3.fromRGB(5, 5, 5),
        BackgroundTransparency = 0.5,
        BorderSizePixel = 0,
    }, frame)
    make("UICorner", { CornerRadius = UDim.new(0, 6) }, inputContainer)
    make("UIStroke", { Color = Color3.fromRGB(100, 100, 100), Transparency = 0.7, Thickness = 1 }, inputContainer)

    local suggestionLabel = make("TextLabel", {
        Size = UDim2.new(1, -20, 1, 0),
        Position = UDim2.new(0, 10, 0, 0),
        BackgroundTransparency = 1,
        TextColor3 = Color3.fromRGB(100, 100, 100),
        Font = Enum.Font.Code,
        TextSize = 13,
        TextXAlignment = Enum.TextXAlignment.Left,
        Text = "",
        ZIndex = 1,
    }, inputContainer)

    local cmdInput = make("TextBox", {
        Size = UDim2.new(1, -20, 1, 0),
        Position = UDim2.new(0, 10, 0, 0),
        BackgroundTransparency = 1,
        TextColor3 = Color3.new(1, 1, 1),
        PlaceholderText = "> type 'help'",
        PlaceholderColor3 = Color3.fromRGB(80, 80, 80),
        Font = Enum.Font.Code,
        TextSize = 13,
        TextXAlignment = Enum.TextXAlignment.Left,
        Text = "",
        ZIndex = 2,
        ClearTextOnFocus = false,
    }, inputContainer)

    helpFrame = make("Frame", {
        Size = UDim2.new(0.4, 0, 0.6, 0),
        Position = UDim2.new(0.5, 0, 0.5, 0),
        AnchorPoint = Vector2.new(0.5, 0.5),
        BackgroundColor3 = Color3.fromRGB(15, 15, 15),
        BackgroundTransparency = 0.2,
        BorderSizePixel = 0,
        Visible = false,
        Active = true,
        Draggable = true,
    }, screenGui)
    make("UICorner", { CornerRadius = UDim.new(0, 8) }, helpFrame)
    make("UIStroke", { Color = Color3.fromRGB(80, 80, 80), Transparency = 0.5, Thickness = 1 }, helpFrame)
    make("UISizeConstraint", { MaxSize = Vector2.new(450, 500), MinSize = Vector2.new(300, 300) }, helpFrame)
    Theme.addBackdrop(helpFrame, 8)

    make("TextLabel", {
        Size = UDim2.new(1, -20, 0, 35),
        Position = UDim2.new(0, 15, 0, 5),
        BackgroundTransparency = 1,
        Text = "COMMAND DIRECTORY",
        TextColor3 = Color3.new(1, 1, 1),
        Font = Enum.Font.Code,
        TextSize = 14,
        TextXAlignment = Enum.TextXAlignment.Left,
    }, helpFrame)

    local closeBtn = make("TextButton", {
        Size = UDim2.new(0, 30, 0, 30),
        Position = UDim2.new(1, -35, 0, 5),
        BackgroundTransparency = 1,
        Text = "X",
        TextColor3 = GREY,
        Font = Enum.Font.Code,
        TextSize = 16,
    }, helpFrame)
    closeBtn.MouseButton1Click:Connect(function() helpFrame.Visible = false end)

    local searchContainer = make("Frame", {
        Size = UDim2.new(1, -30, 0, 30),
        Position = UDim2.new(0, 15, 0, 40),
        BackgroundColor3 = Color3.fromRGB(5, 5, 5),
        BackgroundTransparency = 0.5,
        BorderSizePixel = 0,
    }, helpFrame)
    make("UICorner", { CornerRadius = UDim.new(0, 6) }, searchContainer)
    make("UIStroke", { Color = Color3.fromRGB(100, 100, 100), Transparency = 0.7, Thickness = 1 }, searchContainer)

    local searchBox = make("TextBox", {
        Size = UDim2.new(1, -20, 1, 0),
        Position = UDim2.new(0, 10, 0, 0),
        BackgroundTransparency = 1,
        TextColor3 = Color3.new(1, 1, 1),
        PlaceholderText = "Search commands...",
        PlaceholderColor3 = Color3.fromRGB(100, 100, 100),
        Font = Enum.Font.Code,
        TextSize = 12,
        TextXAlignment = Enum.TextXAlignment.Left,
        Text = "",
    }, searchContainer)

    -- Command directory: category tabs, then one row per command. A row that opens a
    -- window opens it when clicked; any other row puts the command in the command bar
    -- (so its arguments can be typed). Rebuilt on open, so late commands show up too.
    local tabBar = make("ScrollingFrame", {
        Size = UDim2.new(1, -30, 0, 28), Position = UDim2.new(0, 15, 0, 76), BackgroundTransparency = 1,
        ScrollBarThickness = 2, ScrollBarImageColor3 = Color3.fromRGB(100, 100, 100), ScrollingDirection = Enum.ScrollingDirection.X,
        CanvasSize = UDim2.new(0, 0, 0, 0), AutomaticCanvasSize = Enum.AutomaticSize.X,
    }, helpFrame)
    make("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder }, tabBar)
    local scrollFrame = make("ScrollingFrame", {
        Size = UDim2.new(1, -20, 1, -120),
        Position = UDim2.new(0, 10, 0, 112),
        BackgroundTransparency = 1,
        ScrollBarThickness = 2,
        ScrollBarImageColor3 = Color3.fromRGB(100, 100, 100),
        CanvasSize = UDim2.new(0, 0, 0, 0),
        AutomaticCanvasSize = Enum.AutomaticSize.Y,
    }, helpFrame)
    make("UIListLayout", { Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder }, scrollFrame)

    helpEntries.tab = "All"
    helpEntries.rows = {}
    helpEntries.tabs = {}
    local function filterRows()
        local query = searchBox.Text:lower()
        for _, r in ipairs(helpEntries.rows) do
            local inTab = helpEntries.tab == "All" or r.cat == helpEntries.tab
            local hit = query == "" or r.name:find(query, 1, true) ~= nil or r.doc:lower():find(query, 1, true) ~= nil
            -- a search looks through every tab
            r.frame.Visible = hit and (inTab or query ~= "")
        end
        for name, b in pairs(helpEntries.tabs) do
            local on = name == helpEntries.tab
            b.BackgroundTransparency = on and 0.1 or 0.6
            b.TextColor3 = on and Color3.new(1, 1, 1) or Color3.fromRGB(170, 170, 170)
        end
    end

    function UIAPI.fillHelp()
        if helpEntries.built == #cmds then filterRows(); return end
        helpEntries.built = #cmds
        for _, r in ipairs(helpEntries.rows) do r.frame:Destroy() end
        for _, b in pairs(helpEntries.tabs) do b:Destroy() end
        helpEntries.rows, helpEntries.tabs = {}, {}
        local counts = {}
        local sorted = {}
        for _, c in ipairs(cmds) do
            if cmdDocs[c] then sorted[#sorted + 1] = { name = c, cat = UIAPI.cmdCategory(c), doc = cmdDocs[c] } end
        end
        local order = {}
        for i, cat in ipairs(UIAPI.CMD_CATEGORIES) do order[cat] = i end
        table.sort(sorted, function(a, b)
            if a.cat ~= b.cat then return (order[a.cat] or 99) < (order[b.cat] or 99) end
            return a.name < b.name
        end)
        for idx, r in ipairs(sorted) do
            counts[r.cat] = (counts[r.cat] or 0) + 1
            local opens = UIAPI.cmdOpensWindow(r.name)
            local row = make("TextButton", {
                Size = UDim2.new(1, -10, 0, 30), BackgroundColor3 = Color3.fromRGB(20, 20, 20), BackgroundTransparency = 0.4,
                BorderSizePixel = 0, LayoutOrder = idx, Text = "", AutoButtonColor = true,
            }, scrollFrame)
            make("UICorner", { CornerRadius = UDim.new(0, 6) }, row)
            make("TextLabel", {
                Size = UDim2.new(1, opens and -78 or -14, 1, 0), Position = UDim2.new(0, 10, 0, 0), BackgroundTransparency = 1,
                Text = r.doc, TextColor3 = Color3.new(1, 1, 1), Font = Enum.Font.Code, TextSize = 12,
                TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd,
            }, row)
            if opens then
                make("TextLabel", {
                    Size = UDim2.new(0, 62, 0, 20), Position = UDim2.new(1, -68, 0.5, -10), BackgroundColor3 = PAL.ACCENT or Color3.fromRGB(90, 169, 255),
                    BackgroundTransparency = 0.55, Text = "Open", TextColor3 = Color3.new(1, 1, 1), Font = Enum.Font.GothamBold, TextSize = 11,
                }, row)
            end
            row.MouseButton1Click:Connect(function()
                if opens then
                    if r.name == "help" then return end
                    UIAPI.openForCommand(r.name)
                else
                    cmdInput.Text = firstPrefix() .. r.name .. " "
                    cmdInput:CaptureFocus()
                    task.defer(function() cmdInput.CursorPosition = #cmdInput.Text + 1 end)
                end
            end)
            r.frame = row
            helpEntries.rows[#helpEntries.rows + 1] = r
        end
        local tabsList = { "All" }
        for _, cat in ipairs(UIAPI.CMD_CATEGORIES) do if counts[cat] then tabsList[#tabsList + 1] = cat end end
        for i, name in ipairs(tabsList) do
            local b = make("TextButton", {
                AutomaticSize = Enum.AutomaticSize.X, Size = UDim2.new(0, 0, 0, 24), BackgroundColor3 = Color3.fromRGB(40, 40, 52),
                BorderSizePixel = 0, LayoutOrder = i, Font = Enum.Font.Code, TextSize = 11,
                Text = "  " .. name .. (name == "All" and "" or (" " .. counts[name])) .. "  ",
            }, tabBar)
            make("UICorner", { CornerRadius = UDim.new(0, 6) }, b)
            b.MouseButton1Click:Connect(function()
                helpEntries.tab = name
                searchBox.Text = ""
                filterRows()
                scrollFrame.CanvasPosition = Vector2.new(0, 0)
            end)
            helpEntries.tabs[name] = b
        end
        if not helpEntries.tabs[helpEntries.tab] then helpEntries.tab = "All" end
        filterRows()
    end

    searchBox:GetPropertyChangedSignal("Text"):Connect(filterRows)
    helpFrame:GetPropertyChangedSignal("Visible"):Connect(function()
        if helpFrame.Visible then pcall(UIAPI.fillHelp) end
    end)

    -- Settings window: command prefixes, UI key, kill switch
    local function windowFrame(size, title)
        local f = make("Frame", {
            Size = size,
            Position = UDim2.new(0.5, 0, 0.5, 0),
            AnchorPoint = Vector2.new(0.5, 0.5),
            BackgroundColor3 = Color3.fromRGB(15, 15, 15),
            BackgroundTransparency = 0.2,
            BorderSizePixel = 0,
            Visible = false,
            Active = true,
            Draggable = true,
        }, screenGui)
        make("UICorner", { CornerRadius = UDim.new(0, 8) }, f)
        make("UIStroke", { Color = Color3.fromRGB(80, 80, 80), Transparency = 0.5, Thickness = 1 }, f)
        Theme.addBackdrop(f, 8)
        make("TextLabel", {
            Size = UDim2.new(1, -50, 0, 30),
            Position = UDim2.new(0, 15, 0, 5),
            BackgroundTransparency = 1,
            Text = title,
            TextColor3 = Color3.new(1, 1, 1),
            Font = Enum.Font.Code,
            TextSize = 14,
            TextXAlignment = Enum.TextXAlignment.Left,
        }, f)
        local x = make("TextButton", {
            Size = UDim2.new(0, 30, 0, 30),
            Position = UDim2.new(1, -35, 0, 5),
            BackgroundTransparency = 1,
            Text = "X",
            TextColor3 = GREY,
            Font = Enum.Font.Code,
            TextSize = 16,
        }, f)
        x.MouseButton1Click:Connect(function() f.Visible = false end)
        UIAPI.makeResizable(f, title:match("^%S+"))
        UIAPI.markChrome(f)
        return f
    end

    local function fieldLabel(parent, text, y)
        make("TextLabel", {
            Size = UDim2.new(1, -30, 0, 16),
            Position = UDim2.new(0, 15, 0, y),
            BackgroundTransparency = 1,
            Text = text,
            TextColor3 = Color3.fromRGB(170, 170, 170),
            Font = Enum.Font.Code,
            TextSize = 11,
            TextXAlignment = Enum.TextXAlignment.Left,
        }, parent)
    end

    local function fieldBox(parent, y, text)
        local c = make("Frame", {
            Size = UDim2.new(1, -110, 0, 28),
            Position = UDim2.new(0, 15, 0, y),
            BackgroundColor3 = Color3.fromRGB(5, 5, 5),
            BackgroundTransparency = 0.5,
            BorderSizePixel = 0,
        }, parent)
        make("UICorner", { CornerRadius = UDim.new(0, 6) }, c)
        make("UIStroke", { Color = Color3.fromRGB(100, 100, 100), Transparency = 0.7, Thickness = 1 }, c)
        return make("TextBox", {
            Size = UDim2.new(1, -16, 1, 0),
            Position = UDim2.new(0, 8, 0, 0),
            BackgroundTransparency = 1,
            TextColor3 = Color3.new(1, 1, 1),
            Font = Enum.Font.Code,
            TextSize = 12,
            TextXAlignment = Enum.TextXAlignment.Left,
            Text = text,
            ClearTextOnFocus = false,
        }, c)
    end

    local function actionButton(parent, text, pos, size, color)
        local b = make("TextButton", {
            Size = size,
            Position = pos,
            BackgroundColor3 = color or Color3.fromRGB(30, 30, 38),
            BackgroundTransparency = 0.2,
            BorderSizePixel = 0,
            Text = text,
            TextColor3 = Color3.new(1, 1, 1),
            Font = Enum.Font.Code,
            TextSize = 12,
        }, parent)
        make("UICorner", { CornerRadius = UDim.new(0, 6) }, b)
        return b
    end

    settingsFrame = windowFrame(UDim2.new(0, 380, 0, 600), "SETTINGS  -  build " .. tostring(genv.PuppyAdminBuild))
    do
    -- three tabs: General (commands, keys, switches), Look (theme, image, font, text
    -- size, cursor), Windows (a button for every window). Each page scrolls.
    local pages, tabBtns = {}, {}
    local function showSettingsTab(name)
        for k, pg in pairs(pages) do pg.Visible = (k == name) end
        for k, b in pairs(tabBtns) do
            b.BackgroundTransparency = (k == name) and 0.1 or 0.6
            b.TextColor3 = (k == name) and Color3.new(1, 1, 1) or Color3.fromRGB(170, 170, 170)
        end
    end
    UIAPI.settingsTab = function(name)
        settingsFrame.Visible = true
        showSettingsTab(name)
    end
    for i, name in ipairs({ "General", "Look", "Windows" }) do
        local b = actionButton(settingsFrame, name, UDim2.new((i - 1) / 3, i == 1 and 15 or 4, 0, 40), UDim2.new(1 / 3, i == 2 and -8 or -19, 0, 28))
        b.MouseButton1Click:Connect(function() showSettingsTab(name) end)
        tabBtns[name] = b
        pages[name] = make("ScrollingFrame", {
            Size = UDim2.new(1, -4, 1, -132), Position = UDim2.new(0, 0, 0, 76), BackgroundTransparency = 1,
            BorderSizePixel = 0, ScrollBarThickness = 3, ScrollBarImageColor3 = Color3.fromRGB(100, 100, 100),
            CanvasSize = UDim2.new(0, 0, 0, 0), Visible = false,
        }, settingsFrame)
    end

    ---------------------------------------------------------------- General
    local gen = pages.General
    fieldLabel(gen, "Chat command prefixes (comma separated, 1-3 symbols)", 4)
    local prefixBox = fieldBox(gen, 24, table.concat(Cfg.prefixes, ", "))
    local prefixApply = actionButton(gen, "Apply", UDim2.new(1, -85, 0, 24), UDim2.new(0, 70, 0, 28))
    prefixApply.MouseButton1Click:Connect(function()
        local list = parsePrefixList(prefixBox.Text)
        if #list == 0 then note("Prefix", "1-3 symbols, no letters/digits/spaces", RED); return end
        Cfg.prefixes = list
        cfgSave()
        prefixBox.Text = table.concat(list, ", ")
        note("Prefix", table.concat(list, "  "), LIGHT)
    end)

    fieldLabel(gen, "Show/hide UI key (KeyCode name, e.g. RightControl)", 64)
    local keyBox = fieldBox(gen, 84, Cfg.uiKey)
    local keyApply = actionButton(gen, "Apply", UDim2.new(1, -85, 0, 84), UDim2.new(0, 70, 0, 28))
    keyApply.MouseButton1Click:Connect(function()
        local kc = resolveKeyCode(keyBox.Text)
        if not kc then note("UI Key", "Unknown key", RED); return end
        Cfg.uiKey = kc.Name
        keyBox.Text = kc.Name
        cfgSave()
        note("UI Key", kc.Name, LIGHT)
    end)

    local introBtn = actionButton(gen, "", UDim2.new(0, 15, 0, 124), UDim2.new(0.5, -19, 0, 28))
    introBtn.TextSize = 11
    local function introText() introBtn.Text = Cfg.skipIntro and "Intro: off" or "Intro: on" end
    introText()
    introBtn.MouseButton1Click:Connect(function()
        Cfg.skipIntro = not Cfg.skipIntro
        cfgSave()
        introText()
        note("Intro", Cfg.skipIntro and "Skipped from the next start" or "Shown at the next start", LIGHT)
    end)
    local afkBtn = actionButton(gen, "", UDim2.new(0.5, 4, 0, 124), UDim2.new(0.5, -19, 0, 28))
    afkBtn.TextSize = 11
    local function afkText()
        afkBtn.Text = UIAPI.antiAfk.on and "Anti-AFK: on" or "Anti-AFK: off"
        afkBtn.TextColor3 = UIAPI.antiAfk.on and Color3.fromRGB(120, 230, 140) or Color3.new(1, 1, 1)
    end
    afkText()
    UIAPI.antiAfkChanged = afkText
    afkBtn.MouseButton1Click:Connect(function() H.antiafk({}) end)

    -- nametags on your screen only (hidetags / showtags do the same)
    local tagVisBtn = actionButton(gen, "", UDim2.new(0, 15, 0, 160), UDim2.new(1, -30, 0, 28))
    tagVisBtn.TextSize = 12
    local function tagVisText()
        tagVisBtn.Text = Cfg.tagsHidden and "Nametags: hidden on your screen (click to show)" or "Nametags: shown (click to hide on your screen)"
        tagVisBtn.TextColor3 = Cfg.tagsHidden and Color3.fromRGB(255, 190, 120) or Color3.new(1, 1, 1)
    end
    tagVisText()
    UIAPI.tagsVisChanged = tagVisText
    tagVisBtn.MouseButton1Click:Connect(function() UIAPI.setTagsHidden(not Cfg.tagsHidden) end)

    -- alt formations (Puppy Companion's main and alts)
    local altsBtn = actionButton(gen, "Alts - accounts, formations & commands", UDim2.new(0, 15, 0, 196), UDim2.new(1, -30, 0, 28))
    altsBtn.TextSize = 12
    altsBtn.MouseButton1Click:Connect(function() if H.alts then H.alts({}) end end)
    -- live status on the button, so you can see your alts without opening the window
    UIAPI.altsButtonStatus = function()
        local A = UIAPI.Alts
        if not A or not A.loadRoster then return end
        local ok, r = pcall(A.loadRoster)
        if not ok or not r then return end
        if r.main == plr.UserId then
            local n = #A.present()
            altsBtn.Text = string.format("Alts - %d ready%s", n, A.active and (" - " .. tostring(A.active.label)) or "")
            altsBtn.TextColor3 = n > 0 and Color3.fromRGB(120, 230, 140) or Color3.new(1, 1, 1)
        elseif r.isAlt and r.isAlt[plr.UserId] then
            altsBtn.Text = "Alts - this account is an alt"
            altsBtn.TextColor3 = Color3.fromRGB(255, 190, 120)
        else
            altsBtn.Text = "Alts - accounts, formations & commands"
            altsBtn.TextColor3 = Color3.new(1, 1, 1)
        end
    end
    task.spawn(function()
        while settingsFrame.Parent do
            pcall(UIAPI.altsButtonStatus)
            task.wait(3)
        end
    end)

    -- The token only ever goes into a local file; it is never shown again or put in the config.
    fieldLabel(gen, "Tag sync: GitHub token (saved only in " .. SETTINGS.TagSync.tokenFile .. ")", 236)
    local tokenBox = fieldBox(gen, 256, "")
    tokenBox.PlaceholderText = TagSync.token() and "token saved - paste a new one, or 'remove'" or "github_pat_... (never type this in chat)"
    local tokenApply = actionButton(gen, "Save", UDim2.new(1, -85, 0, 256), UDim2.new(0, 70, 0, 28))
    tokenApply.MouseButton1Click:Connect(function()
        local t = tokenBox.Text
        tokenBox.Text = ""
        local ok, msg = TagSync.setToken(t:lower() == "remove" and "" or t)
        note("Tag sync", msg, ok and LIGHT or RED)
        tokenBox.PlaceholderText = TagSync.token() and "token saved - paste a new one, or 'remove'" or "github_pat_... (never type this in chat)"
        if ok and TagSync.token() then
            task.spawn(function()
                local okPull, status = TagSync.pull(true)
                note("Tag sync", status, okPull and LIGHT or RED)
            end)
        end
    end)
    gen.CanvasSize = UDim2.new(0, 0, 0, 300)

    ---------------------------------------------------------------- Look
    local look = pages.Look
    -- Theme: presets, then one row per colour role (hex, r,g,b or a colour name)
    fieldLabel(look, "UI theme", 4)
    local perRow = 6
    for i, p in ipairs(Theme.presets) do
        local col, row = (i - 1) % perRow, math.floor((i - 1) / perRow)
        local b = actionButton(look, p.name, UDim2.new(0, 15 + col * 56, 0, 24 + row * 30), UDim2.new(0, 52, 0, 26))
        b.TextSize = 11
        b.MouseButton1Click:Connect(function()
            Theme.usePreset(p.name)
            note("Theme", p.name, LIGHT)
        end)
    end
    local y = 24 + math.ceil(#Theme.presets / perRow) * 30 + 6
    fieldLabel(look, "Colors: #hex, r,g,b or a name (press Enter to apply)", y)
    y = y + 20
    local themeRows = {}
    for _, role in ipairs(Theme.roles) do
        make("TextLabel", {
            Size = UDim2.new(0, 110, 0, 26), Position = UDim2.new(0, 15, 0, y), BackgroundTransparency = 1,
            Text = Theme.labels[role], TextColor3 = Color3.new(1, 1, 1), Font = Enum.Font.Code, TextSize = 12,
            TextXAlignment = Enum.TextXAlignment.Left,
        }, look)
        local sw = make("Frame", {
            Name = "PuppyAdminSwatch", Size = UDim2.new(0, 26, 0, 26), Position = UDim2.new(0, 130, 0, y),
            BackgroundColor3 = Theme.current[role], BorderSizePixel = 0,
        }, look)
        make("UICorner", { CornerRadius = UDim.new(0, 6) }, sw)
        make("UIStroke", { Color = Color3.fromRGB(100, 100, 100), Transparency = 0.4, Thickness = 1 }, sw)
        local holder = make("Frame", {
            Size = UDim2.new(1, -181, 0, 26), Position = UDim2.new(0, 166, 0, y),
            BackgroundColor3 = Color3.fromRGB(5, 5, 5), BackgroundTransparency = 0.5, BorderSizePixel = 0,
        }, look)
        make("UICorner", { CornerRadius = UDim.new(0, 6) }, holder)
        make("UIStroke", { Color = Color3.fromRGB(100, 100, 100), Transparency = 0.7, Thickness = 1 }, holder)
        local box = make("TextBox", {
            Size = UDim2.new(1, -16, 1, 0), Position = UDim2.new(0, 8, 0, 0), BackgroundTransparency = 1,
            TextColor3 = Color3.new(1, 1, 1), Font = Enum.Font.Code, TextSize = 12,
            TextXAlignment = Enum.TextXAlignment.Left, Text = Theme.hex(Theme.current[role]), ClearTextOnFocus = false,
        }, holder)
        box.FocusLost:Connect(function()
            local r, g, b = parseColorArgs(splitArgs((box.Text:gsub(",%s+", ","))), 1)
            if not r then
                note("Theme", "Color: #hex, r,g,b or a name", RED)
                box.Text = Theme.hex(Theme.current[role])
                return
            end
            Theme.setRole(role, Color3.fromRGB(r, g, b))
        end)
        themeRows[role] = { swatch = sw, box = box }
        y = y + 32
    end
    table.insert(Theme.listeners, function()
        for role, row in pairs(themeRows) do
            row.swatch.BackgroundColor3 = Theme.current[role]
            if not row.box:IsFocused() then row.box.Text = Theme.hex(Theme.current[role]) end
        end
    end)

    y = y + 6
    fieldLabel(look, "Background image: id, rbxassetid, image URL or off [visibility 0-100]", y)
    local imageBox = fieldBox(look, y + 20, Theme.image and Theme.image.src or ((type(Cfg.theme) == "table" and type(Cfg.theme.image) == "table" and Cfg.theme.image.src) or ""))
    imageBox.PlaceholderText = "e.g. 1234567890 60"
    local imageApply = actionButton(look, "Apply", UDim2.new(1, -85, 0, y + 20), UDim2.new(0, 70, 0, 28))
    imageApply.MouseButton1Click:Connect(function()
        local args = splitArgs(imageBox.Text)
        task.spawn(function()
            local ok, msg = Theme.applyImageArgs(args)
            note("Theme", msg, ok and LIGHT or RED)
            if Theme.image then imageBox.Text = Theme.image.src elseif ok then imageBox.Text = "" end
        end)
    end)
    y = y + 60

    fieldLabel(look, "Script font (every window; Default = original fonts)", y)
    local fontChoices = UIFont.choices()
    uiDropdown(look, "Font: ", UDim2.new(1, -30, 0, 28), UDim2.new(0, 15, 0, y + 20), fontChoices,
        table.find(fontChoices, Cfg.uiFont) or 1, function(_, name)
            task.spawn(function()
                local ok, msg = UIFont.set(name)
                note("Font", msg, ok and LIGHT or RED)
            end)
        end)
    y = y + 56

    -- applied a moment after the slider stops, not on every step of a drag
    local scaleToken = 0
    local scaleSlider = uiSlider(look, "Text size (every window)", UDim2.new(0, 15, 0, y), 340, {
        min = 0.5, max = 2, step = 0.05, value = UIFont.scale,
        format = function(v) return math.floor(v * 100 + 0.5) .. "%" end,
        onChange = function(v)
            scaleToken = scaleToken + 1
            local mine = scaleToken
            task.delay(0.25, function()
                if mine == scaleToken then UIFont.setScale(v) end
            end)
        end,
    })
    actionButton(look, "Reset text size", UDim2.new(0, 15, 0, y + 48), UDim2.new(1, -30, 0, 26)).MouseButton1Click:Connect(function()
        scaleSlider.set(1)
        local ok, msg = UIFont.setScale(1)
        note("Text size", msg, ok and LIGHT or RED)
    end)
    y = y + 84

    -- custom mouse cursor
    local Cur = UIAPI.Cursor
    fieldLabel(look, "Cursor (Custom: image id or URL below; its top-left corner points)", y)
    uiDropdown(look, "Cursor: ", UDim2.new(1, -30, 0, 28), UDim2.new(0, 15, 0, y + 20), Cur.CHOICES,
        table.find(Cur.CHOICES, Cfg.cursor) or 1, function(_, name)
            task.spawn(function()
                local ok, msg = Cur.set(name)
                note("Cursor", msg, ok and LIGHT or RED)
            end)
        end)
    local curBox = fieldBox(look, y + 56, Cfg.cursorImage or "")
    curBox.PlaceholderText = "custom cursor image id or URL"
    actionButton(look, "Use", UDim2.new(1, -85, 0, y + 56), UDim2.new(0, 70, 0, 28)).MouseButton1Click:Connect(function()
        Cfg.cursorImage = curBox.Text
        task.spawn(function()
            local ok, msg = Cur.set("Custom")
            note("Cursor", msg, ok and LIGHT or RED)
        end)
    end)
    uiSlider(look, "Cursor size", UDim2.new(0, 15, 0, y + 92), 340, {
        min = 16, max = 128, step = 2, value = Cfg.cursorSize or 40,
        format = function(v) return math.floor(v) .. " px" end,
        onChange = function(v) Cur.setSize(v) end,
    })
    y = y + 140
    look.CanvasSize = UDim2.new(0, 0, 0, y)

    ---------------------------------------------------------------- Windows
    local win = pages.Windows
    fieldLabel(win, "Every window in Puppy Admin (also: click a command with 'Open' in help)", 4)
    local WINDOWS = {
        { "Commands", function() if helpFrame then helpFrame.Visible = true end end },
        { "Tools", "tools" }, { "Movement", "move" }, { "Superfly", "superfly" }, { "Floor", "floor" },
        { "ESP", "esp" }, { "Reanim", "reanim" }, { "Alts", "alts" }, { "Alt commands", "altcmds" },
        { "Performance", "performance" }, { "Finder", "finder" }, { "Anti VC ban", "antivcban" },
        { "Tag editor", "tagui" }, { "Tags", "taglist" }, { "Mini games", "games" }, { "Game Boy", "gameboy" },
        { "GBA", "gba" }, { "Doom", "doom" }, { "Owner", "owner" }, { "Blacklist", "blacklist" },
    }
    local PANEL_OF = { tools = "tools", move = "move", floor = "floor", esp = "esp" }
    local bw = (380 - 30 - 12) / 3
    for i, w in ipairs(WINDOWS) do
        local col, row = (i - 1) % 3, math.floor((i - 1) / 3)
        local b = actionButton(win, w[1], UDim2.new(0, 15 + col * (bw + 6), 0, 26 + row * 34), UDim2.new(0, bw, 0, 28))
        b.TextSize = 11
        b.MouseButton1Click:Connect(function()
            local target = w[2]
            if type(target) == "function" then target(); return end
            if PANEL_OF[target] then UIAPI.togglePanel(target); return end
            local fn = H[target]
            if type(fn) == "function" then task.spawn(function() pcall(fn, {}) end) end
        end)
    end
    win.CanvasSize = UDim2.new(0, 0, 0, 30 + math.ceil(#WINDOWS / 3) * 34)

    showSettingsTab("General")
    end

    local killBtn = actionButton(settingsFrame, "KILL SCRIPT", UDim2.new(0, 15, 1, -45), UDim2.new(1, -30, 0, 32), Color3.fromRGB(130, 35, 35))
    killBtn.MouseButton1Click:Connect(function() shutdown(false) end)
    settingsFrame:SetAttribute("PuppyAdminScrollBody", true) -- its tab pages scroll by themselves
    UIAPI.fitWindow(settingsFrame, 38)

    -- Output window used by auras / tags / anim / binds lists
    local outFrame = windowFrame(UDim2.new(0, 400, 0, 300), "OUTPUT")
    local outTitle = outFrame:FindFirstChildOfClass("TextLabel")
    local outScroll = make("ScrollingFrame", {
        Size = UDim2.new(1, -20, 1, -50),
        Position = UDim2.new(0, 10, 0, 40),
        BackgroundTransparency = 1,
        ScrollBarThickness = 2,
        CanvasSize = UDim2.new(0, 0, 0, 0),
        AutomaticCanvasSize = Enum.AutomaticSize.Y,
    }, outFrame)
    make("UIListLayout", { Padding = UDim.new(0, 4), SortOrder = Enum.SortOrder.LayoutOrder }, outScroll)

    UIAPI.showOutput = function(title, lines)
        outTitle.Text = title
        for _, ch in ipairs(outScroll:GetChildren()) do
            if ch:IsA("TextLabel") then ch:Destroy() end
        end
        for i, line in ipairs(lines) do
            make("TextLabel", {
                Size = UDim2.new(1, -10, 0, 18),
                AutomaticSize = Enum.AutomaticSize.Y,
                BackgroundTransparency = 1,
                Text = line,
                TextColor3 = Color3.new(1, 1, 1),
                Font = Enum.Font.Code,
                TextSize = 12,
                TextWrapped = true,
                TextXAlignment = Enum.TextXAlignment.Left,
                LayoutOrder = i,
            }, outScroll)
        end
        outFrame.Visible = true
    end

    buildPanels(screenGui)

    local isUpdating = false
    local currentSuggestionCommand = ""

    cmdInput:GetPropertyChangedSignal("Text"):Connect(function()
        if isUpdating then return end
        local txt = cmdInput.Text
        if txt == "" then suggestionLabel.Text = ""; currentSuggestionCommand = ""; return end

        local spaceHit = txt:sub(-1) == " "
        local evalTxt = spaceHit and txt:sub(1, -2) or txt
        local args = evalTxt:split(" ")

        local tCmd = args[1]:lower()
        local match = getPartialMatch(tCmd)

        currentSuggestionCommand = ""

        if spaceHit and #args == 1 and match then
            isUpdating = true
            cmdInput.Text = match .. " "
            cmdInput.CursorPosition = #cmdInput.Text + 1
            suggestionLabel.Text = match .. " "
            isUpdating = false
            return
        end

        if match then
            if #args == 1 then
                local doc = cmdDocs[match] or match
                suggestionLabel.Text = txt .. doc:sub(#tCmd + 1)
                currentSuggestionCommand = match
            elseif playerArgIndex(match, args) and #args == playerArgIndex(match, args) + 1 and args[#args] ~= "" then
                local sName = args[#args]:lower()
                local before = table.concat(args, " ", 1, #args - 1) .. " "
                local found = nil
                for _, p in ipairs(Players:GetPlayers()) do
                    if p.Name:lower():sub(1, #sName) == sName then found = p.Name break end
                    if p.DisplayName:lower():sub(1, #sName) == sName then found = p.DisplayName break end
                end

                if found then
                    currentSuggestionCommand = before .. found
                    suggestionLabel.Text = before .. args[#args] .. found:sub(#sName + 1)

                    if spaceHit then
                        isUpdating = true
                        cmdInput.Text = currentSuggestionCommand .. " "
                        cmdInput.CursorPosition = #cmdInput.Text + 1
                        suggestionLabel.Text = cmdInput.Text
                        isUpdating = false
                    end
                else
                    suggestionLabel.Text = ""
                end
            else
                suggestionLabel.Text = ""
            end
        else
            suggestionLabel.Text = ""
        end
    end)

    cmdInput.FocusLost:Connect(function(enter)
        if enter and cmdInput.Text:gsub(" ", "") ~= "" then
            local finalCmd = cmdInput.Text

            if currentSuggestionCommand ~= "" then
                if currentSuggestionCommand:lower():sub(1, #finalCmd) == finalCmd:lower() then
                    finalCmd = currentSuggestionCommand
                end
            end

            processCommandString(finalCmd)

            isUpdating = true
            cmdInput.Text = ""
            suggestionLabel.Text = ""
            currentSuggestionCommand = ""
            isUpdating = false
        end
    end)
end


------------------------------------------------------------------------
-- Shutdown (single cleanup path for `stop`, `kill` and respawn)
------------------------------------------------------------------------

shutdown = function(killCharacter)
    if genv.PuppyAdminActive ~= true then return end
    genv.PuppyAdminActive = false
    genv.PuppyAdminShutdown, genv.PuppyAdminBuild = nil, nil

    for _, c in ipairs(conns) do c:Disconnect() end
    table.clear(conns)

    for i = #cleanups, 1, -1 do pcall(cleanups[i]) end

    for i = #slots, 1, -1 do
        local slot = slots[i]
        destroySlotObjects(slot)
        if chr.Parent and slot.tool.Parent == chr then
            pcall(function() slot.tool.Parent = bp end)
        end
    end
    table.clear(slots)

    if ui then ui:Destroy(); ui = nil end
    genv.PuppyAdminUI = nil

    sendFlatNotification("System", "Puppy Admin Shutdown", Color3.fromRGB(100, 100, 100))
    task.delay(3.5, function() notifGui:Destroy() end)

    if killCharacter then
        -- the body must be able to die (reanimation turns Dead off while it runs)
        local body = plr.Character or chr
        local hum = body and body:FindFirstChildOfClass("Humanoid")
        if hum then
            pcall(function() hum:SetStateEnabled(Enum.HumanoidStateType.Dead, true) end)
            hum.Health = 0
        end
    end
end

------------------------------------------------------------------------
-- Brand intro: title text fades in on execute, holds, fades out after 5s.
-- Heart backdrop, title image (Kingdom Hearts font) and start-up sound from
-- assets/intro; the heart and title spin horizontally while the sound plays.
------------------------------------------------------------------------

local function safeFont(name, fallback)
    local ok, f = pcall(function() return Enum.Font[name] end)
    if ok and f then return f end
    return fallback
end

local function showBrandIntro()
    local g = Instance.new("ScreenGui")
    g.Name = "PuppyAdminIntro"
    g.IgnoreGuiInset = true
    g.DisplayOrder = 999999
    g.ResetOnSpawn = false
    parentGui(g)
    if g.Parent == nil then return end

    local holder = make("Frame", { Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, Active = false }, g)
    local subFont = safeFont("SourceSansItalic", Enum.Font.SourceSansItalic)
    local GOLD = Color3.fromRGB(255, 221, 150)
    local BASE = SETTINGS.Auras.assetBase .. "assets/intro/"

    -- Files in assets/intro, downloaded once into PuppyAdmin/ (each part is skipped if it cannot load):
    --   heart_moon_v2.png  backdrop,  title.png  the title drawn in the Kingdom Hearts font
    --   (an image, so it can be squeezed for the spin; text cannot),  kh_item_get.mp3  start-up sound.
    local heartAsset = urlImageAsset(BASE .. "heart_moon_v2.png", "intro")
    local titleAsset = urlImageAsset(BASE .. "title.png", "intro")
    local soundAsset = urlImageAsset(BASE .. "kh_item_get.mp3", "intro")

    local HEART_W, TITLE_W, TITLE_H = 380, 258, 89
    local heart, title
    if heartAsset then
        heart = make("ImageLabel", {
            AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.new(0.5, 0, 0.42, 6),
            Size = UDim2.fromOffset(HEART_W, HEART_W), BackgroundTransparency = 1, Image = heartAsset,
            ImageTransparency = 1, ScaleType = Enum.ScaleType.Stretch, ZIndex = 1,
        }, holder)
    end
    if titleAsset then
        title = make("ImageLabel", {
            AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.new(0.5, 0, 0.42, 0),
            Size = UDim2.fromOffset(TITLE_W, TITLE_H), BackgroundTransparency = 1, Image = titleAsset,
            ImageTransparency = 1, ScaleType = Enum.ScaleType.Stretch, ZIndex = 2,
        }, holder)
    end

    -- text title when the image is not available (no spin for it)
    local textTitle
    if not title then
        local face = UIFont.make("Kingdom Hearts")
        textTitle = make("TextLabel", {
            AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.new(0.5, 0, 0.42, 0), Size = UDim2.fromOffset(700, 100),
            BackgroundTransparency = 1, Font = safeFont("Garamond", Enum.Font.GothamBold),
            Text = face and "Puppy Admin" or "PUPPY ADMIN", TextSize = face and 62 or 50, TextColor3 = GOLD,
            TextStrokeColor3 = Color3.fromRGB(20, 40, 85), TextTransparency = 1, TextStrokeTransparency = 1, ZIndex = 2,
        }, holder)
        if face then pcall(function() textTitle.FontFace = face end) end
    end

    local sub = make("TextLabel", {
        AnchorPoint = Vector2.new(0.5, 0.5),
        Position = UDim2.new(0.5, 0, 0.42, 48),
        Size = UDim2.fromOffset(500, 30),
        BackgroundTransparency = 1,
        Font = subFont,
        Text = "r e a n i m a t i o n  &  a d m i n  t o o l s",
        TextSize = 15,
        TextColor3 = GOLD,
        TextStrokeColor3 = Color3.fromRGB(20, 40, 85),
        TextTransparency = 1,
        TextStrokeTransparency = 1,
        ZIndex = 2,
    }, holder)

    if soundAsset then
        pcall(function()
            local snd = Instance.new("Sound")
            snd.Name = "PuppyAdminIntroSound"
            snd.SoundId = soundAsset
            snd.Volume = 0.7
            snd.Parent = game:GetService("SoundService")
            snd:Play()
            local function gone() if snd.Parent then snd:Destroy() end end
            snd.Ended:Connect(gone)
            task.delay(5, gone)
        end)
    end

    local fadeIn = TweenInfo.new(1.1, Enum.EasingStyle.Sine, Enum.EasingDirection.Out)
    local fadeOut = TweenInfo.new(1.1, Enum.EasingStyle.Sine, Enum.EasingDirection.In)
    if heart then TweenService:Create(heart, fadeIn, { ImageTransparency = 0.1 }):Play() end
    if title then TweenService:Create(title, fadeIn, { ImageTransparency = 0 }):Play() end
    if textTitle then TweenService:Create(textTitle, fadeIn, { TextTransparency = 0, TextStrokeTransparency = 0.35 }):Play() end
    TweenService:Create(sub, fadeIn, { TextTransparency = 0.3, TextStrokeTransparency = 0.6 }):Play()

    -- Horizontal spin: two turns that slow to a stop over the length of the sound. A
    -- turn is faked by squeezing the width with |cos|; the far side is drawn a little darker.
    if heart or title then
        local SPIN_TIME, TURNS = 1.6, 2
        local start = os.clock()
        local spin
        spin = RunService.RenderStepped:Connect(function()
            local t = math.min(1, (os.clock() - start) / SPIN_TIME)
            local eased = 1 - (1 - t) ^ 3
            local c = math.cos(eased * TURNS * 2 * math.pi)
            local k = math.max(0.02, math.abs(c))
            local shade = c < 0 and Color3.fromRGB(200, 215, 235) or Color3.new(1, 1, 1)
            if heart then heart.Size = UDim2.fromOffset(HEART_W * k, HEART_W); heart.ImageColor3 = shade end
            if title then title.Size = UDim2.fromOffset(TITLE_W * k, TITLE_H); title.ImageColor3 = shade end
            if t >= 1 or not g.Parent then spin:Disconnect() end
        end)
        table.insert(conns, spin)
    end

    task.delay(5, function()
        if not g.Parent then return end
        TweenService:Create(sub, fadeOut, { TextTransparency = 1, TextStrokeTransparency = 1 }):Play()
        if textTitle then TweenService:Create(textTitle, fadeOut, { TextTransparency = 1, TextStrokeTransparency = 1 }):Play() end
        if heart then TweenService:Create(heart, fadeOut, { ImageTransparency = 1 }):Play() end
        if title then TweenService:Create(title, fadeOut, { ImageTransparency = 1 }):Play() end
        task.delay(1.3, function() if g.Parent then g:Destroy() end end)
    end)
end

------------------------------------------------------------------------
-- Desktop companion (the Puppy Companion app): every 10 s this window
-- writes PuppyAdmin/companion/<UserId>.json in the executor's workspace -
-- who is playing, which game and server - and marks it offline on `stop` /
-- `kill`. Nothing secret is in it and nothing leaves the PC. The app writes
-- roster.json (which user IDs are the main and the alts) next to it.
------------------------------------------------------------------------

function UIAPI.companionStart()
    if UIAPI.companionOn or not (writefile and isfolder and makefolder) then return end
    UIAPI.companionOn = true
    local DIR = "PuppyAdmin/companion"
    local FILE = DIR .. "/" .. tostring(plr.UserId) .. ".json"
    local build = tostring(genv.PuppyAdminBuild or "")
    local function write(online)
        pcall(function()
            if not isfolder("PuppyAdmin") then makefolder("PuppyAdmin") end
            if not isfolder(DIR) then makefolder(DIR) end
            -- best effort: a client may not see that its server is a private one
            local private = false
            pcall(function() private = game.PrivateServerId ~= "" or game.PrivateServerOwnerId ~= 0 end)
            writefile(FILE, HttpService:JSONEncode({
                userId = plr.UserId, name = plr.Name, displayName = plr.DisplayName,
                placeId = game.PlaceId, jobId = game.JobId, privateServer = private,
                players = #Players:GetPlayers(), online = online, time = os.time(), build = build,
            }))
        end)
    end
    write(true)
    task.spawn(function()
        -- UIAPI belongs to this copy of the script: a newer build's start ends this loop
        while UIAPI.companionOn and genv.PuppyAdminActive == true do
            task.wait(10)
            if UIAPI.companionOn and genv.PuppyAdminActive == true then write(true) end
        end
    end)
    table.insert(cleanups, function()
        UIAPI.companionOn = false
        write(false)
    end)
end

------------------------------------------------------------------------
-- Alt formations. Puppy Companion's roster.json says which account is the
-- main and which are alts. The main's Alts window writes altcmd.json in the
-- executor workspace; every alt on this PC reads it four times a second and,
-- while it is in the main's server, moves its own character to its place in
-- the shape around the main every frame. Characters replicate, so everyone
-- in the server sees the shape. No parts are created.
------------------------------------------------------------------------

function UIAPI.altsSetup()
    if UIAPI.Alts then return end
    local Alts = { roster = nil, rosterAt = -100, alive = true }
    UIAPI.Alts = Alts
    local DIR = "PuppyAdmin/companion"
    local ROSTER_FILE = DIR .. "/roster.json"
    local CMD_FILE = DIR .. "/altcmd.json"
    local STALE = 25 -- seconds: alts stop when the main's command is older (the main refreshes it every 5 s)
    local TAU = math.pi * 2
    local V3, CF = Vector3.new, CFrame.new

    local defaults = { preset = 1, size = 1, speed = 1, height = 0, glitch = false, spin = false, pulse = false, limbs = false, limbsDeath = false }
    for k, v in pairs(defaults) do
        if type(Cfg.altForm[k]) ~= type(v) then Cfg.altForm[k] = v end
    end

    local function readJson(path)
        if not (isfile and readfile) then return nil end
        local ok, data = pcall(function()
            if isfile(path) then return HttpService:JSONDecode(readfile(path)) end
            return nil
        end)
        if ok and type(data) == "table" then return data end
        return nil
    end

    local function writeText(path, text)
        if not (writefile and isfolder and makefolder) then return false end
        return pcall(function()
            if not isfolder("PuppyAdmin") then makefolder("PuppyAdmin") end
            if not isfolder(DIR) then makefolder(DIR) end
            writefile(path, text)
        end)
    end

    -- roster.json: { main = { userId, name }, alts = { { userId, name }, ... } }, re-read every 5 s
    function Alts.loadRoster(force)
        local now = os.clock()
        if Alts.roster and not force and now - Alts.rosterAt < 5 then return Alts.roster end
        Alts.rosterAt = now
        local data = readJson(ROSTER_FILE)
        local r = { main = nil, alts = {}, isAlt = {}, names = {}, prefs = {}, found = data ~= nil }
        if data then
            if type(data.main) == "table" then
                r.main = tonumber(data.main.userId)
                if r.main then r.names[r.main] = tostring(data.main.name or r.main) end
            end
            if type(data.alts) == "table" then
                for i = 1, math.min(#data.alts, 50) do
                    local a = data.alts[i]
                    local id = type(a) == "table" and tonumber(a.userId) or nil
                    if id and id ~= r.main and not r.isAlt[id] then
                        table.insert(r.alts, id)
                        r.isAlt[id] = true
                        r.names[id] = tostring(a.name or id)
                        -- per-account settings from Puppy Companion's Manage tab (missing = own switch)
                        if type(a.prefs) == "table" then
                            local pr = {}
                            if type(a.prefs.lite) == "boolean" then pr.lite = a.prefs.lite end
                            if type(a.prefs.mute) == "boolean" then pr.mute = a.prefs.mute end
                            if type(a.prefs.vcAuto) == "boolean" then pr.vcAuto = a.prefs.vcAuto end
                            local fps = tonumber(a.prefs.fps)
                            if fps and fps == fps then pr.fps = math.max(15, math.min(240, math.floor(fps))) end
                            r.prefs[id] = pr
                        end
                    end
                end
            end
        end
        Alts.roster = r
        return r
    end

    -- this account's own settings from the companion (empty when none are set)
    function Alts.myPrefs()
        local r = Alts.loadRoster()
        return (r.prefs and r.prefs[plr.UserId]) or {}
    end
    function Alts.liteOn()
        local p = Alts.myPrefs()
        if p.lite ~= nil then return p.lite end
        return Cfg.altLite ~= false
    end

    function Alts.role()
        local r = Alts.loadRoster()
        if r.main and r.main == plr.UserId then return "main" end
        if r.isAlt[plr.UserId] then return "alt" end
        return nil
    end

    ------------------------------------------------------------------
    -- Shapes. Each gives alt i (0-based) of n its place relative to the
    -- main: +X right, +Y up, -Z forward (the main's facing, kept level).
    -- A body is about 5 studs long; the main's feet are about 3 studs
    -- under its root part. t is the shape's clock (Speed scales it).
    ------------------------------------------------------------------

    -- a body at pos whose head points along up and whose front faces look
    local function orient(pos, up, look)
        up = up.Unit
        local right = look:Cross(up)
        if right.Magnitude < 1e-3 then right = up:Cross(V3(0, 0, 1)) end
        if right.Magnitude < 1e-3 then right = V3(1, 0, 0) end
        return CFrame.fromMatrix(pos, right.Unit, up)
    end
    Alts.orient = orient

    local SHAPES = {}
    Alts.SHAPES = SHAPES
    -- two fans behind the shoulders, heads outward, flapping
    function SHAPES.wings(i, n, t, s)
        local side = (i % 2 == 0) and 1 or -1
        local k = math.floor(i / 2)
        local per = math.ceil(n / 2) -- bodies per wing
        -- the fan opens from 14 to at most 78 degrees above level, so the two tips never meet overhead
        local a = math.rad(14 + (per > 1 and k / (per - 1) or 0) * math.min(64, 16 * (per - 1)))
        a = math.max(math.rad(5), math.min(math.rad(84), a + math.sin(t * 2.4) * 0.12 * (1 + k * 0.15)))
        local dir = V3(side * math.cos(a), math.sin(a), 0.22).Unit
        local pos = V3(side * 0.8, 1.3, 1.4) + dir * ((3.4 + 2.5 * k) * s)
        return orient(pos, dir, V3(0, 0, -1))
    end
    -- a wheel lying above the head, heads outward, turning
    function SHAPES.halo(i, n, t, s)
        local th = i / n * TAU + t * 0.9
        local u = V3(math.cos(th), 0, math.sin(th))
        local r = math.max(3, 0.45 * n + 1.6) * s
        return orient(V3(0, 5.6 + math.sin(t * 1.7) * 0.25, 0) + u * r, u, V3(0, 1, 0))
    end
    -- standing bodies running round the main
    function SHAPES.ring(i, n, t, s)
        local th = i / n * TAU + t * 1.6
        local r = math.max(4.2, 0.55 * n + 2.6) * s
        local pos = V3(math.cos(th) * r, 0.6 + math.sin(t * 2 + i) * 0.4, math.sin(th) * r)
        return orient(pos, V3(0, 1, 0), V3(-math.sin(th), 0, math.cos(th)))
    end
    -- an upright sunburst behind the back, heads outward, turning slowly
    function SHAPES.star(i, n, t, s)
        local th = i / n * TAU + t * 0.5
        local u = V3(math.cos(th), math.sin(th), 0)
        local r = math.max(3.2, 0.45 * n + 1.8) * s
        local centre = V3(0, math.max(2.2, r - 0.5), 3.2)
        return orient(centre + u * r, u, V3(0, 0, -1))
    end
    -- a rising helix round the main
    function SHAPES.spiral(i, n, t, s)
        local f = n > 1 and i / (n - 1) or 0.5
        local th = f * TAU * 1.25 + t * 1.3
        local r = 3.8 * s
        local pos = V3(math.cos(th) * r, 0.4 + f * (3.2 + 0.9 * n) * s + math.sin(t * 1.4 + i) * 0.4, math.sin(th) * r)
        return orient(pos, V3(0, 1, 0), V3(-math.sin(th), 0, math.cos(th)))
    end
    -- a stack on the head, every other body turning the other way
    function SHAPES.tower(i, n, t, s)
        return CF(0, (5.2 + i * 5) * math.max(1, s), 0) * CFrame.Angles(0, (i % 2 == 0 and 1 or -1) * t * 0.6, 0)
    end
    -- a line in front, facing the way the main faces
    function SHAPES.wall(i, n, t, s)
        return CF((i - (n - 1) / 2) * 3.2 * s, 0.3 + math.sin(t * 2 + i * 0.6) * 0.3, -5.5 * s)
    end
    -- a line behind (until the main has walked far enough to lay a path to follow)
    function SHAPES.trail(i, n, t, s)
        return CF(math.sin(t * 2.2 - i * 0.8) * 1.4 * s, 0.3 + math.sin(t * 1.6 - i * 0.6) * 0.3, (4.5 + i * 3.6) * s)
    end
    -- jumps between random spots round the main, at random angles
    function SHAPES.scatter(i, n, t, s, st)
        local g = st.scatter
        if not g or t >= g.hold then
            local rng = st.rng
            local dir = V3(rng:NextNumber(-1, 1), rng:NextNumber(0.05, 1), rng:NextNumber(-1, 1))
            if dir.Magnitude < 0.1 then dir = V3(0, 1, 0) end
            g = {
                hold = t + rng:NextNumber(0.15, 0.6),
                cf = CF(V3(0, 1, 0) + dir.Unit * (rng:NextNumber(5, 9) * s))
                    * CFrame.Angles(rng:NextNumber(-3.1, 3.1), rng:NextNumber(-3.1, 3.1), rng:NextNumber(-3.1, 3.1)),
            }
            st.scatter = g
        end
        return g.cf
    end

    -- layers: { shape, count (nil = every alt left), needs (only used with at least this many alts) }
    Alts.PRESETS = {
        { name = "Wings", key = "wings", layers = { { "wings" } } },
        { name = "Halo", key = "halo", layers = { { "halo" } } },
        { name = "Ring", key = "ring", layers = { { "ring" } } },
        { name = "Star", key = "star", layers = { { "star" } } },
        { name = "Spiral", key = "spiral", layers = { { "spiral" } } },
        { name = "Tower", key = "tower", layers = { { "tower" } } },
        { name = "Wall", key = "wall", layers = { { "wall" } } },
        { name = "Trail", key = "trail", layers = { { "trail" } } },
        { name = "Scatter", key = "scatter", layers = { { "scatter" } } },
        { name = "Wings + halo", key = "wingshalo", layers = { { "halo", 2, 4 }, { "wings" } } },
        { name = "Star + ring", key = "starring", layers = { { "ring", 3, 5 }, { "star" } } },
    }

    function Alts.findPreset(key)
        if type(key) ~= "string" or key == "" then return nil end
        key = key:lower():gsub("[^%a]", "")
        local hit
        for _, p in ipairs(Alts.PRESETS) do
            if p.key == key then return p end
            if p.key:sub(1, #key) == key then
                if hit then return nil end -- more than one starts like that
                hit = p
            end
        end
        return hit
    end

    function Alts.keyList()
        local keys = {}
        for _, p in ipairs(Alts.PRESETS) do table.insert(keys, p.key) end
        return table.concat(keys, ", ")
    end

    -- splits the alts (roster order) between the preset's layers
    function Alts.assign(preset, ids)
        local layers, at, total = {}, 1, #ids
        for _, L in ipairs(preset.layers) do
            local count = L[2]
            if count and total < (L[3] or 0) then count = 0 end
            local left = total - at + 1
            local take = count and math.min(count, left) or left
            if take > 0 then
                local part = {}
                for j = at, at + take - 1 do table.insert(part, ids[j]) end
                table.insert(layers, { form = L[1], ids = part })
                at = at + take
            end
        end
        return layers
    end

    ------------------------------------------------------------------
    -- Alt side: follow the main's command
    ------------------------------------------------------------------

    -- the main's position (a little ahead: the alts see it late), facing kept level
    local function levelFrame(root, lead)
        local cf = root.CFrame
        local pos = cf.Position
        if lead > 0 then
            local v = root.AssemblyLinearVelocity
            if v.Magnitude < 150 then pos = pos + v * lead end
        end
        local look = cf.LookVector
        local flat = V3(look.X, 0, look.Z)
        if flat.Magnitude < 0.05 then flat = V3(0, 0, -1) end
        return CFrame.lookAt(pos, pos + flat.Unit)
    end
    Alts.levelFrame = levelFrame

    -- the point dist studs back along the main's recent path, facing the way it went (nil: path too short)
    local function alongPath(hist, head, dist)
        local prev = head
        for j = #hist, 1, -1 do
            local p = hist[j]
            local d = prev - p
            local seg = d.Magnitude
            if seg > 1e-3 and seg >= dist then
                local at = prev - d * (dist / seg)
                local flat = V3(d.X, 0, d.Z)
                if flat.Magnitude > 0.05 then d = flat end
                return CFrame.lookAt(at, at + d.Unit)
            end
            dist = dist - seg
            prev = p
        end
        return nil
    end

    -- a short random jump and twist now and then (real time, so it also runs at Speed 0)
    local function glitchAt(st)
        local g = st.glitch
        local now = st.clock
        if not g or now >= g.nextAt then
            local rng = st.rng
            g = {
                to = now + rng:NextNumber(0.06, 0.2), nextAt = now + rng:NextNumber(0.4, 1.6),
                move = V3(rng:NextNumber(-2.5, 2.5), rng:NextNumber(-1, 2), rng:NextNumber(-2.5, 2.5)),
                turn = CFrame.Angles(rng:NextNumber(-1.2, 1.2), rng:NextNumber(-3.1, 3.1), rng:NextNumber(-1.2, 1.2)),
            }
            st.glitch = g
        end
        if now < g.to then return g.move, g.turn end
        return nil, nil
    end

    -- where this alt's root part goes this frame
    -- pulse / spin / glitch / blend wrappers shared by every placed behaviour
    local function applyExtras(st, base, off, dt)
        local p, t = st.params, st.t
        if p.pulse then off = CF(off.Position * (1 + 0.14 * math.sin(t * 3.2))) * off.Rotation end
        if p.spin then off = off * CFrame.Angles(0, t * 5 + st.index, 0) end
        if p.glitch then
            local move, turn = glitchAt(st)
            if move then off = CF(move) * off * turn end
        end
        local world = base * CF(0, p.height, 0) * off
        if st.blend < 1 and st.from then
            st.blend = math.min(1, st.blend + dt / 0.45)
            world = st.from:Lerp(world, 1 - (1 - st.blend) ^ 3)
        end
        return world
    end

    -- where this alt's root goes this frame (formation shapes and main/target behaviours)
    function Alts.target(st, centerRoot, dt)
        local p = st.params
        local base = levelFrame(centerRoot, st.lead or 0.1)
        local t = st.t
        local off
        if st.form == "trail" then
            local hist, mpos = st.hist, centerRoot.Position
            if #hist == 0 or (hist[#hist] - mpos).Magnitude >= 0.35 then
                table.insert(hist, mpos)
                if #hist > 600 then table.remove(hist, 1) end
            end
            local cf = alongPath(hist, mpos, (4.5 + st.index * 3.6) * p.size)
            if cf then off = base:ToObjectSpace(cf * CF(0, 0.3, 0)) end
        elseif st.behav and st.behav.frame then
            off = st.behav.frame(st, base, centerRoot, t)
        end
        if not off and st.form then off = SHAPES[st.form](st.index, st.count, t, p.size, st) end
        if not off then off = CFrame.new() end
        return applyExtras(st, base, off, dt)
    end

    local function selfRoot()
        local char = plr.Character
        if not char then return nil end
        return char:FindFirstChild("HumanoidRootPart"), char:FindFirstChildOfClass("Humanoid"), char
    end
    Alts.selfRoot = selfRoot

    local function resolveCenter(st)
        if st.center == "target" and st.target and st.target ~= 0 then
            local tp = Players:GetPlayerByUserId(st.target)
            local tc = tp and tp.Character
            return tc and tc:FindFirstChild("HumanoidRootPart")
        end
        local mp = Players:GetPlayerByUserId(st.main)
        local mc = mp and mp.Character
        return mc and mc:FindFirstChild("HumanoidRootPart")
    end

    -- the body passes through everything while it is placed by hand
    local function noclip()
        local char = plr.Character
        if not char then return end
        if Alts.partsOf ~= char then
            Alts.partsOf, Alts.parts = char, {}
            for _, d in ipairs(char:GetDescendants()) do
                if d:IsA("BasePart") then table.insert(Alts.parts, d) end
            end
        end
        for _, part in ipairs(Alts.parts) do part.CanCollide = false end
    end

    local function step(dt)
        local st = Alts.state
        if not st then return end
        st.clock = st.clock + dt
        if os.time() - st.cmdTime > STALE then Alts.stopFollowing(); return end
        local root, hum = selfRoot()
        local mode = st.mode or "pin"
        -- separated limbs: the game's ragdoll (no death) or, with the death switch, a death;
        -- until the body is actually loose the whole body is placed (and tumbles)
        local limbMode = st.limbs and mode == "pin" and st.center ~= "self"
        local ls = limbMode and Alts.shatter(st) or nil
        local loose = ls and ls.phase == "free"
        if not loose and (not (root and hum) or hum.Health <= 0) then return end
        st.t = st.t + dt * st.params.speed
        if Alts.lite then -- weak machines: place the body ~30 times a second, not every frame
            st.acc = (st.acc or 0) + dt
            if st.acc < 0.0333 then return end
            dt = st.acc; st.acc = 0
        end
        if mode == "idle" then
            if st.behav and st.behav.idle then st.behav.idle(st, root, hum, dt) end
            return
        end
        -- separated limbs: the alt's parts each take a point on the orbit, so one alt
        -- makes several orbiting pieces (the whole set of alts' limbs form the ring)
        if loose then
            local lc = resolveCenter(st)
            if not lc then return end
            local lbase = levelFrame(lc, st.lead or 0.1)
            local drivers = ls.parts
            local per = #drivers
            if per == 0 then return end
            local total = math.max(1, st.count) * per
            -- the netless push keeps each loose part awake and owned by this client, so
            -- the server (and everyone else) keeps receiving where it is
            local push = Vector3.new(0, (SETTINGS.VelocityY or 220.290009) + math.sin(st.clock), 0)
            local wiggle = CF(0, math.sin(st.clock * 15) * 0.0015, 0)
            for k, d in ipairs(drivers) do
                if d.Parent then
                    local slot = st.index * per + (k - 1)
                    d.CFrame = lbase * CF(0, st.params.height, 0)
                        * Alts.orbitOffset(slot, total, st.t, st.params.size, st.cmdParams.style) * wiggle
                    d.AssemblyLinearVelocity = push
                    d.AssemblyAngularVelocity = Vector3.zero
                end
            end
            if ls.root and ls.root.Parent then -- the invisible root waits at the centre
                ls.root.CFrame = lbase * CF(0, st.params.height - 6, 0)
                ls.root.AssemblyLinearVelocity = push
                ls.root.AssemblyAngularVelocity = Vector3.zero
            end
            return
        end
        local base, cf
        if st.center == "self" then
            if not st.selfBase then st.selfBase = levelFrame(root, 0) end
            base = st.selfBase
            local off = (st.behav and st.behav.frame and st.behav.frame(st, base, root, st.t)) or CFrame.new()
            cf = applyExtras(st, base, off, dt)
        else
            local center = resolveCenter(st)
            if not center then return end -- the main or the target is away: hold
            if mode == "walk" then
                if st.behav and st.behav.move then st.behav.move(st, center, root, hum, dt) end
                return
            end
            cf = Alts.target(st, center, dt)
        end
        if st.limbs and mode == "pin" then
            -- broken-up look while the body is whole (no ragdoll here, or waiting to separate):
            -- each body tumbles on its own axes at its own rate
            local k = (st.index or 0) + 1
            local t = st.clock
            cf = cf * CFrame.Angles(t * (1.3 + 0.37 * k), t * (0.9 + 0.23 * k), t * (1.7 - 0.19 * (k % 5)))
        end
        if not hum.PlatformStand then hum.PlatformStand = true end
        root.CFrame = cf
        if st.fling then
            root.AssemblyAngularVelocity = Vector3.new(0, 95, 0)
        else
            root.AssemblyLinearVelocity = Vector3.zero
            root.AssemblyAngularVelocity = Vector3.zero
        end
    end

    local function physStep()
        local st = Alts.state
        if st and st.noclip then noclip() end
    end

    function Alts.ensureLoop()
        if not Alts.hb then
            Alts.hb = RunService.Heartbeat:Connect(function(dt) pcall(step, dt) end)
            Alts.nc = RunService.Stepped:Connect(function() pcall(physStep) end)
        end
    end

    -- low-power: cap the alt's own FPS while it follows (a 2014 Surface Book runs many windows)
    function Alts.capFps()
        if Alts.lite and setfpscap and not Alts.capped then
            setfpscap(Alts.myPrefs().fps or Cfg.altLiteFps or 30)
            Alts.capped = true
        end
    end
    function Alts.restoreFps()
        if Alts.capped and setfpscap then pcall(setfpscap, 0); Alts.capped = false end
    end

    -- Alts run with the lightest graphics for minimal lag on weak PCs (done once per alt).
    function Alts.applyLowGraphics()
        if Alts.lowGfxDone then return end
        Alts.lowGfxDone = true
        pcall(function() settings().Rendering.QualityLevel = Enum.QualityLevel.Level01 end)
        pcall(function() UserSettings():GetService("UserGameSettings").SavedQualityLevel = Enum.SavedQualitiesLevel.Level01 end)
        pcall(function()
            local L = game:GetService("Lighting")
            L.GlobalShadows = false
            L.FogEnd = 1e9
            for _, e in ipairs(L:GetChildren()) do
                if e:IsA("PostEffect") then e.Enabled = false end
            end
        end)
    end

    -- Alts are silent: they never need to hear the game or other players, and muting
    -- every alt window stops a wall of overlapping audio. Voice chat is separate, so
    -- also stop subscribing to other players' voice when the API is present.
    function Alts.muteAudio()
        if Alts.mutedDone then return end
        Alts.mutedDone = true
        pcall(function() UserSettings():GetService("UserGameSettings").MasterVolume = 0 end)
        pcall(function() game:GetService("SoundService").AmbientReverb = Enum.ReverbType.NoReverb end)
        pcall(function()
            local vci = cloneref and cloneref(game:GetService("VoiceChatInternal")) or game:GetService("VoiceChatInternal")
            for _, p in ipairs(Players:GetPlayers()) do
                if p ~= plr then pcall(function() vci:SubscribePause(p.UserId, true) end) end
            end
        end)
    end

    -- client settings for an alt: always mute; drop graphics only in low-power mode
    function Alts.applyAltClientSettings()
        if Alts.myPrefs().mute ~= false then Alts.muteAudio() end
        if Alts.liteOn() then Alts.applyLowGraphics() end
    end

    -- Separated limbs, visible to everyone. A client cannot break its character's joints
    -- for other players (Motor6D changes here only change this screen), so the server has
    -- to do it. Two ways, as the reanimation engine does it:
    --   ragdoll: the game's own ragdoll remote (the engine's list of known games, then the
    --            common remote names). The server swaps the Motor6Ds for constraints; the
    --            alt stays alive. Constraints do not merge parts into one body, so after
    --            switching them off on this client (the owner simulates them) every limb
    --            is its own piece whose position replicates.
    --   death:   only with the "alts DIE" switch, when the game has no ragdoll: the alt
    --            dies with BreakJointsOnDeath and the server breaks every joint.
    -- A fresh body (just spawned / respawned) is first left to settle until this client
    -- owns it; separating it straight away left parts the client could not move.
    Alts.SETTLE = 2 -- seconds a new body waits before it is separated
    Alts.RAGDOLL_WAIT = 2.5 -- seconds to wait for the server's ragdoll before giving up

    -- The game's ragdoll remote, args and whether it is a local BindableEvent.
    -- Same games, names and args as get_game_ragdoll_info in the reanimation engine.
    function Alts.ragdollRemote(enable)
        local rep = game:GetService("ReplicatedStorage")
        local pid = game.PlaceId
        local function at(path)
            local cur = rep
            for part in path:gmatch("[^/]+") do
                if not cur then return nil end
                cur = cur:FindFirstChild(part)
            end
            return cur
        end
        if pid == 15546218972 or pid == 6884319169 then
            local r = at("event_rag"); if r then return r, { "Ball" }, false end
        elseif pid == 5991163185 then
            local r = at("Remotes/Physics/Ragdoll"); if r then return r, {}, false end
        elseif pid == 5683833663 then
            local r = at("LocalRagdollEvent"); if r then return r, { enable }, true end
        elseif pid == 86382196724726 or game.GameId == 10581310106 then
            local r = at("Remotes/RagdollToggle"); if r then return r, { enable and "Ball" or false }, false end
            return nil
        end
        for _, path in ipairs({ "Ragdoll", "RagdollEvent", "event_rag", "Rag", "Ragdolled", "Remotes/Ragdoll",
            "Events/Ragdoll", "Remotes/Physics/Ragdoll", "RemoteEvents/Ragdoll", "RemoteEvents/RagdollEvent" }) do
            local r = at(path)
            if r then
                if r:IsA("BindableEvent") then return r, { enable }, true end
                if r:IsA("RemoteEvent") or r:IsA("RemoteFunction") then return r, {}, false end
            end
        end
        return nil
    end

    function Alts.fireRagdoll(enable)
        local r, args, isLocal = Alts.ragdollRemote(enable)
        if not r then return false end
        return pcall(function()
            if isLocal then r:Fire(table.unpack(args))
            elseif r:IsA("RemoteEvent") then r:FireServer(table.unpack(args))
            else task.spawn(function() pcall(function() r:InvokeServer(table.unpack(args)) end) end) end
        end)
    end

    -- true when no working Motor6D holds the body together any more (the server's
    -- ragdoll disabled them, or a death broke them; both replicate here)
    local function jointsLoose(char)
        for _, d in ipairs(char:GetDescendants()) do
            if d:IsA("Motor6D") and d.Enabled and d.Part0 and d.Part1
                and d.Part0:IsDescendantOf(char) and d.Part1:IsDescendantOf(char) then
                return false
            end
        end
        return true
    end

    local function ownsBody(root)
        if not root then return false end
        if type(isnetworkowner) ~= "function" then return true end -- cannot ask: rely on the settle time
        local ok, mine = pcall(isnetworkowner, root)
        return not ok or mine == true
    end

    local function freeParts(ls)
        local char, root = ls.char, ls.root
        ls.parts, ls.constraints = {}, {}
        for _, d in ipairs(char:GetDescendants()) do
            if d:IsA("BasePart") and d ~= root then
                pcall(function() d.CanCollide = false end)
                table.insert(ls.parts, d)
            elseif d:IsA("BallSocketConstraint") or d:IsA("HingeConstraint") or d:IsA("RopeConstraint")
                or d:IsA("RodConstraint") or d:IsA("SpringConstraint") or d:IsA("AnimationConstraint") then
                if d.Enabled then
                    pcall(function() d.Enabled = false end) -- the owner simulates them: off here = loose for everyone
                    table.insert(ls.constraints, d)
                end
            elseif d:IsA("JointInstance") or d:IsA("WeldConstraint") or d:IsA("RigidConstraint") then
                pcall(function() d.Enabled = false end)
            end
        end
        pcall(function() settings().Physics.AllowSleep = false end)
        if sethiddenproperty then pcall(function() sethiddenproperty(plr, "SimulationRadius", math.huge) end) end
        ls.phase = "free"
    end

    -- Advances the separation of the current body; returns the state (phase "free" = loose
    -- parts to place). st carries the switches (st.limbsDeath allows the death fallback).
    function Alts.shatter(st)
        local char = plr.Character
        if not char then return nil end
        local ls = Alts.limbState
        if not ls or ls.char ~= char then
            if ls then Alts.reassemble() end
            local root = char:FindFirstChild("HumanoidRootPart")
            ls = { char = char, root = (root and root:IsA("BasePart")) and root or nil, born = os.clock(),
                phase = "settle", parts = {} }
            Alts.limbState = ls
        end
        if ls.phase == "free" or ls.phase == "whole" then return ls end
        local hum = char:FindFirstChildOfClass("Humanoid")
        if not hum then return ls end
        local now = os.clock()
        if ls.phase == "settle" then
            if hum.Health <= 0 then -- already dead (killed elsewhere): its joints are broken
                if jointsLoose(char) then ls.method = "death"; freeParts(ls) end
                return ls
            end
            if now - ls.born < Alts.SETTLE or not ownsBody(ls.root) then return ls end
            if Alts.fireRagdoll(true) then
                ls.phase, ls.method, ls.asked = "ragdoll", "ragdoll", now
            else
                ls.phase = "nodoll"
            end
        end
        if ls.phase == "ragdoll" then
            if jointsLoose(char) then freeParts(ls); return ls end
            if now - ls.asked < Alts.RAGDOLL_WAIT then return ls end
            Alts.fireRagdoll(false) -- the game did not ragdoll us: undo the request
            ls.method = nil
            ls.phase = "nodoll"
        end
        if ls.phase == "nodoll" then
            if st and st.limbsDeath then
                pcall(function() hum.BreakJointsOnDeath = true end)
                pcall(function() hum:SetStateEnabled(Enum.HumanoidStateType.Dead, true) end)
                hum.Health = 0
                ls.method = "death"
                freeParts(ls) -- the server's break follows a moment later; this screen matches at once
            else
                ls.phase = "whole" -- no ragdoll here and no death allowed: bodies tumble instead
                if not Alts.noDollNoted then
                    Alts.noDollNoted = true
                    note("Alts", "This game has no ragdoll, so limbs stay on (bodies tumble). The 'alts DIE' switch separates them by respawning.", LIGHT)
                end
            end
        end
        return ls
    end

    -- Ends the separation: a ragdolled body asks the game to stand up again (its loose
    -- constraints come back on); a body broken by death waits for its respawn.
    function Alts.reassemble()
        local ls = Alts.limbState
        Alts.limbState = nil
        if not ls then return end
        for _, c in ipairs(ls.constraints or {}) do pcall(function() c.Enabled = true end) end
        if ls.method == "ragdoll" and ls.char == plr.Character then
            for _, d in ipairs(ls.char:GetDescendants()) do
                if d:IsA("JointInstance") then pcall(function() d.Enabled = true end) end
            end
            Alts.fireRagdoll(false)
        end
    end

    local function num(v, lo, hi, default)
        v = tonumber(v)
        if not v or v ~= v then return default end
        return math.max(lo, math.min(hi, v))
    end

    local function cleanParams(c)
        local s = c.params or c
        return {
            size = num(s.size, 0.3, 4, 1), speed = num(s.speed, 0, 6, 1), height = num(s.height, -10, 30, 0),
            glitch = s.glitch == true, spin = s.spin == true, pulse = s.pulse == true,
        }
    end

    -- formations (shape path, unchanged behaviour)
    function Alts.follow(c, form, index, count, slot)
        local limbsDeath = (c.params or c).limbsDeath == true
        local limbs = (c.params or c).limbs == true or limbsDeath
        local st = Alts.state
        if st and st.form == form and st.index == index and st.count == count and st.main == c.main then
            st.params, st.cmdTime, st.slot, st.limbs, st.limbsDeath = cleanParams(c), c.time, slot, limbs, limbsDeath
            if not limbs then Alts.reassemble() end
            return
        end
        local root = selfRoot()
        local fresh = st == nil
        Alts.state = {
            main = c.main, form = form, center = "main", mode = "pin", noclip = true, lead = 0.1, limbs = limbs, limbsDeath = limbsDeath,
            index = index, count = count, slot = slot, params = cleanParams(c), cmdTime = c.time,
            t = 0, clock = 0, hist = {}, rng = Random.new(plr.UserId % 2147483647 + index * 7919),
            from = root and root.CFrame or nil, blend = root and 0 or 1,
        }
        if not limbs then Alts.reassemble() end
        Alts.ensureLoop(); Alts.capFps()
        if fresh then note("Alts", "Following the main: " .. form, LIGHT) end
    end

    -- a continuous command (orbit, circle, lines, stalk, spin, mirror, carpet, firework, nuke, ...)
    function Alts.beginCmd(c, name, spec, index, count, slot)
        local pinned = (spec.mode or "pin") == "pin" and (c.center or spec.center) ~= "self"
        local limbsDeath = (c.params or {}).limbsDeath == true and pinned
        local limbs = ((c.params or {}).limbs == true and pinned) or limbsDeath
        local st = Alts.state
        if st and st.cmd == name and st.index == index and st.count == count
            and st.main == c.main and st.target == (c.target or 0) then
            st.params, st.cmdTime, st.slot, st.cmdParams, st.limbs, st.limbsDeath = cleanParams(c), c.time, slot, c.params or {}, limbs, limbsDeath
            if not limbs then Alts.reassemble() end
            return
        end
        local root = selfRoot()
        local mode = spec.mode or "pin"
        Alts.state = {
            cmd = name, behav = spec, center = c.center or spec.center or "main", mode = mode, limbs = limbs, limbsDeath = limbsDeath,
            noclip = (spec.noclip ~= false) and mode == "pin" and name ~= "fling" and name ~= "carpet",
            fling = name == "fling", index = index, count = count, slot = slot,
            main = c.main, target = c.target or 0, params = cleanParams(c), cmdParams = c.params or {},
            cmdTime = c.time, t = 0, clock = 0, hist = {},
            rng = Random.new(plr.UserId % 2147483647 + index * 7919 + (name:byte(1) or 0)),
            from = root and root.CFrame or nil, blend = root and 0 or 1,
        }
        if not limbs then Alts.reassemble() end
        if spec.center == "self" and root then Alts.state.selfBase = levelFrame(root, 0) end
        Alts.ensureLoop(); Alts.capFps()
        if spec.onBegin then pcall(spec.onBegin, Alts.state) end
    end

    -- a one-shot command (jump, sit, dance, emote, say, equip, rest, firework trigger, ...)
    function Alts.runOnce(c, name, spec, index, count)
        Alts.stopFollowing()
        local st = {
            cmd = name, behav = spec, once = true, main = c.main, target = c.target or 0,
            index = index, count = count, params = cleanParams(c), cmdParams = c.params or {},
            cmdTime = c.time, clock = 0, rng = Random.new(plr.UserId % 2147483647 + index * 104729),
        }
        Alts.state = st
        if spec.action then pcall(spec.action, st) end
    end

    function Alts.stopFollowing()
        local st = Alts.state
        Alts.state = nil
        if Alts.hb then Alts.hb:Disconnect(); Alts.hb = nil end
        if Alts.nc then Alts.nc:Disconnect(); Alts.nc = nil end
        Alts.partsOf, Alts.parts = nil, nil
        Alts.stopAnim()
        Alts.restoreFps()
        Alts.reassemble() -- put separated limbs back together
        if not st then return end
        if st.behav and st.behav.onStop then pcall(st.behav.onStop, st) end
        local root, hum = selfRoot()
        if hum then pcall(function() hum.PlatformStand = false; hum.Sit = false end) end
        -- land beside the main, but only for jobs that pinned the body
        if (st.form or st.mode == "pin") and root then
            local mp = Players:GetPlayerByUserId(st.main)
            local mroot = mp and mp.Character and mp.Character:FindFirstChild("HumanoidRootPart")
            if mroot then
                pcall(function()
                    local side = ((st.slot or 0) % 2 == 0) and 1 or -1
                    local row = math.floor((st.slot or 0) / 2)
                    root.CFrame = levelFrame(mroot, 0) * CF(side * (3 + row * 2.5), 0, 3 + row)
                    root.AssemblyLinearVelocity = Vector3.zero
                end)
            end
        end
    end

    ------------------------------------------------------------------
    -- Emotes, chat, tools, pads, voice-ban (used by the command table)
    ------------------------------------------------------------------

    -- Roblox default R15 emote animations: dance, dance2, dance3, wave, point, laugh, cheer.
    -- These are Roblox's own public emote assets; confirm or override for your avatar's rig
    -- (R6 rigs use different ids). emote1-8 reuse them; rizz has no default - set rizzAnim.
    Alts.DANCE = { 507771019, 507776043, 507777268 }
    Alts.EMOTES = { 507771019, 507776043, 507777268, 507770239, 507770453, 507770818, 507770677, 507770239 }
    Alts.rizzAnim = 0 -- unknown: set to an animation id you own for `rizz`

    function Alts.stopAnim()
        if Alts.animTrack then pcall(function() Alts.animTrack:Stop() end); Alts.animTrack = nil end
    end

    local function playAnim(id)
        id = tonumber(id)
        if not id or id == 0 then return false end
        local char = plr.Character
        local hum = char and char:FindFirstChildOfClass("Humanoid")
        if not hum then return false end
        local animator = hum:FindFirstChildOfClass("Animator") or hum
        local anim = Instance.new("Animation")
        anim.AnimationId = "rbxassetid://" .. tostring(id)
        local ok, track = pcall(function() return animator:LoadAnimation(anim) end)
        if ok and track then
            Alts.stopAnim()
            Alts.animTrack = track
            pcall(function() track.Looped = true; track:Play() end)
            return true
        end
        return false
    end

    local function sayChat(text)
        text = tostring(text or ""):sub(1, 200)
        if text == "" then return false end
        local sent = false
        pcall(function()
            local TCS = game:GetService("TextChatService")
            if TCS.ChatVersion == Enum.ChatVersion.TextChatService then
                local chans = TCS:FindFirstChild("TextChannels")
                local gen = chans and chans:FindFirstChild("RBXGeneral")
                if gen then gen:SendAsync(text); sent = true end
            end
        end)
        if not sent then
            pcall(function()
                local ev = game:GetService("ReplicatedStorage"):FindFirstChild("DefaultChatSystemChatEvents")
                local say = ev and ev:FindFirstChild("SayMessageRequest")
                if say then say:FireServer(text, "All"); sent = true end
            end)
        end
        return sent
    end
    Alts.sayChat = sayChat

    local function equipSlot(n)
        n = tonumber(n) or 1
        local char = plr.Character
        local hum = char and char:FindFirstChildOfClass("Humanoid")
        local bp = plr:FindFirstChildOfClass("Backpack")
        if not (hum and bp) then return end
        local tools = {}
        for _, t in ipairs(bp:GetChildren()) do if t:IsA("Tool") then table.insert(tools, t) end end
        table.sort(tools, function(a, b) return a.Name < b.Name end)
        local tool = tools[n]
        if tool then pcall(function() hum:EquipTool(tool) end) end
    end

    local function makePad(st)
        local pad = Instance.new("Part")
        pad.Anchored = true; pad.CanCollide = true; pad.Size = Vector3.new(8, 1, 8)
        pad.Transparency = 0.35; pad.Material = Enum.Material.Neon
        pad.Color = Color3.fromRGB(90, 150, 255); pad.Name = "PuppyAltPad"
        pcall(function() pad.Parent = workspace end)
        st.extra = { pad = pad }
    end
    local function dropPad(st)
        if st.extra and st.extra.pad then pcall(function() st.extra.pad:Destroy() end); st.extra.pad = nil end
    end

    -- Voice-ban check (best effort): IsVoiceEnabledForUserIdAsync returns false when voice is
    -- not available to you, which includes a voice ban (it is also false if you never turned
    -- voice on, so treat it as "voice unavailable" and confirm on a known-banned account).
    function Alts.voiceUnavailable()
        local ok, enabled = pcall(function()
            return game:GetService("VoiceChatService"):IsVoiceEnabledForUserIdAsync(plr.UserId)
        end)
        if not ok then return nil end -- the API is not present here; unknown
        return enabled == false
    end

    -- run the existing antivcban bypass (VCB) if voice looks unavailable, or always when force
    function Alts.autoVcBan(force)
        if VCB.state == "active" or VCB.state == "running" then return end
        local banned = Alts.voiceUnavailable()
        if force or banned then
            note("Alts", banned and "Voice looks unavailable - running the VC-ban bypass" or "Running the VC-ban bypass", LIGHT)
            VCB.run()
        elseif banned == false then
            note("Alts", "Voice is available for this account (no ban detected)", LIGHT)
        else
            note("Alts", "Can't tell if voice is banned here; open antivcban to run the bypass by hand", RED)
        end
    end

    ------------------------------------------------------------------
    -- Behaviours (offset in the centre's local space: +X right, +Y up, -Z forward)
    ------------------------------------------------------------------
    local BEHAV = {}

    local ORB = {
        { r = 1.0, h = 0, tilt = 0, dir = 1 }, { r = 1.3, h = 0, tilt = 0, dir = -1 },
        { r = 0.8, h = 4, tilt = 0, dir = 1 }, { r = 1.5, h = 2, tilt = 0, dir = 1 },
        { r = 1.0, h = 0, tilt = 0.5, dir = 1 }, { r = 1.2, h = 1, tilt = -0.5, dir = -1 },
        { r = 1.0, h = 0, tilt = 1.1, dir = 1 }, { r = 1.4, h = 3, tilt = 0.8, dir = -1 },
        { r = 0.9, h = 6, tilt = 0.3, dir = 1 }, { r = 1.6, h = 0, tilt = 1.4, dir = -1 },
    }
    -- one point on an orbit ring: shared by the whole-body orbit and the separated-limbs orbit
    local function orbitOffset(i, n, t, s, style)
        local o = ORB[style or 1] or ORB[1]
        local th = (n > 0 and i / n * TAU or 0) + t * 1.5 * o.dir
        local r = (3.4 + 0.3 * n) * s * o.r
        local x, z = math.cos(th) * r, math.sin(th) * r
        local y = o.h * s
        local ct, stt = math.cos(o.tilt), math.sin(o.tilt)
        return orient(V3(x, y * ct - z * stt, y * stt + z * ct), V3(0, 1, 0), V3(-math.sin(th), 0, math.cos(th)))
    end
    Alts.orbitOffset = orbitOffset
    function BEHAV.orbit(st, base, root, t)
        return orbitOffset(st.index, st.count, t, st.params.size, st.cmdParams.style)
    end

    local SPI = {
        { turns = 1.25, h = 1.0, r = 3.8, dbl = false }, { turns = 2.0, h = 1.4, r = 3.0, dbl = false },
        { turns = 1.0, h = 0.8, r = 5.0, dbl = false }, { turns = 1.5, h = 1.2, r = 3.4, dbl = true },
        { turns = 3.0, h = 1.0, r = 2.6, dbl = false },
    }
    function BEHAV.spiral(st, base, root, t)
        local o = SPI[st.cmdParams.style or 1] or SPI[1]
        local n, i, s = st.count, st.index, st.params.size
        local f = n > 1 and i / (n - 1) or 0.5
        local side = (o.dbl and i % 2 == 1) and math.pi or 0
        local th = f * TAU * o.turns + t * 1.3 + side
        local r = o.r * s
        local y = 0.4 + f * (3.2 + o.h * n) * s + math.sin(t * 1.4 + i) * 0.3
        return orient(V3(math.cos(th) * r, y, math.sin(th) * r), V3(0, 1, 0), V3(-math.sin(th), 0, math.cos(th)))
    end

    function BEHAV.heli(st, base, root, t)
        local n, i, s = st.count, st.index, st.params.size
        local a = t * 4
        local arm = (i - (n - 1) / 2) * 2.2 * s
        return orient(V3(arm * math.cos(a), 5.2 + math.sin(t * 2) * 0.2, arm * math.sin(a)),
            V3(0, 1, 0), V3(-math.sin(a), 0, math.cos(a)))
    end

    function BEHAV.worm(st, base, centerRoot, t)
        local hist, mpos = st.hist, centerRoot.Position
        if #hist == 0 or (hist[#hist] - mpos).Magnitude >= 0.3 then
            table.insert(hist, mpos)
            if #hist > 600 then table.remove(hist, 1) end
        end
        local cf = alongPath(hist, mpos, (3 + st.index * 2.2) * st.params.size)
        if cf then return base:ToObjectSpace(cf) end
        return CF((st.index + 1) * -2.4 * st.params.size * 0, 0, (3 + st.index * 2.2) * st.params.size)
    end

    function BEHAV.shield(st, base, root, t)
        local style = st.cmdParams.style or 1
        local n, i, s = st.count, st.index, st.params.size
        if style == 2 then
            local r = ((i % 2 == 0) and 3.5 or 6) * s
            local th = (math.floor(i / 2) / math.max(1, math.ceil(n / 2))) * TAU
            return orient(V3(math.cos(th) * r, 1.5, math.sin(th) * r), V3(0, 1, 0), V3(math.cos(th), 0, math.sin(th)))
        elseif style == 3 then
            local f = (i + 0.5) / n
            local y = f * 5 * s
            local rr = math.sqrt(math.max(0, 1 - (f) ^ 2)) * 4.5 * s
            local th = i * 2.399963
            return orient(V3(math.cos(th) * rr, 1 + y, math.sin(th) * rr), V3(0, 1, 0), V3(math.cos(th), 0, math.sin(th)))
        elseif style == 4 then
            local c = { { -1, -1, -1 }, { 1, -1, -1 }, { -1, 1, -1 }, { 1, 1, -1 }, { -1, -1, 1 }, { 1, -1, 1 }, { -1, 1, 1 }, { 1, 1, 1 } }
            local v = c[(i % 8) + 1]; local r = 4 * s
            return orient(V3(v[1] * r, 2 + v[2] * r * 0.6, v[3] * r), V3(0, 1, 0), V3(v[1], 0, v[3]))
        end
        local r = (4 + 0.4 * n) * s
        local th = i / n * TAU + (style == 5 and t * 2 or 0)
        return orient(V3(math.cos(th) * r, 1.5, math.sin(th) * r), V3(0, 1, 0), V3(math.cos(th), 0, math.sin(th)))
    end

    function BEHAV.arrow(st, base, root, t)
        local i, s = st.index, st.params.size
        if i == 0 then return CF(0, 0.3, -4 * s) end
        local side = (i % 2 == 1) and 1 or -1
        local k = math.floor((i + 1) / 2)
        return CF(side * k * 2 * s, 0.3, k * 2 * s - 4 * s)
    end

    function BEHAV.box(st, base, root, t)
        local n, i, s = st.count, st.index, st.params.size
        local per = math.max(1, math.floor(n / 4))
        local side = math.floor(i / per) % 4
        local f = per > 1 and (i % per) / (per - 1) or 0.5
        local d = (3 + 0.3 * n) * s
        local u = (f - 0.5) * 2 * d
        local pos
        if side == 0 then pos = V3(u, 0.3, -d)
        elseif side == 1 then pos = V3(d, 0.3, u)
        elseif side == 2 then pos = V3(-u, 0.3, d)
        else pos = V3(-d, 0.3, -u) end
        return CF(pos.X, 0.3, pos.Z)
    end

    function BEHAV.star(st, base, root, t)
        local n, i, s = st.count, st.index, st.params.size
        local point = i % 5
        local outer = math.floor(i / 5) % 2 == 0
        local r = (outer and 5 or 2) * s + 0.3 * n * s
        local th = point / 5 * TAU + (outer and 0 or TAU / 10) - math.pi / 2
        return orient(V3(math.cos(th) * r, 0.3, math.sin(th) * r), V3(0, 1, 0), V3(-math.sin(th), 0, math.cos(th)))
    end

    function BEHAV.spin(st, base, root, t)
        local n, i, s = st.count, st.index, st.params.size
        local th = i / math.max(1, n) * TAU
        local r = (3 + 0.2 * n) * s
        return CF(math.cos(th) * r, 0.5, math.sin(th) * r) * CFrame.Angles(0, t * 6, 0)
    end

    function BEHAV.mirror(st, base, root, t)
        local n, i, s = st.count, st.index, st.params.size
        return CF((i - (n - 1) / 2) * 3 * s, 0, -5 * s) -- keeps the main's facing (no orient)
    end

    function BEHAV.carpet(st, base, root, t)
        local n, i, s = st.count, st.index, st.params.size
        local cols = math.max(1, math.ceil(math.sqrt(n)))
        local cx, cz = i % cols, math.floor(i / cols)
        local span = (cols - 1) / 2
        return CF((cx - span) * 4 * s, -3.2, (cz - span) * 4 * s - 1)
    end

    function BEHAV.firework(st, base, root, t)
        local c = st.clock
        local y = (c < 1.4) and c * 42 or math.max(0, 59 - (c - 1.4) * 55)
        local wob = math.sin(c * 20 + st.index) * (c < 1.4 and 0.3 or 1.5)
        return CF(wob, y, 0) * CFrame.Angles(0, c * 10, 0)
    end

    function BEHAV.nuke(st, base, centerRoot, t)
        local n, i, s = st.count, st.index, st.params.size
        local c = st.clock
        local y = math.max(0, 75 - c * 62)
        local th = i / math.max(1, n) * TAU
        local r = (1.5 + y * 0.05) * s
        return CF(math.cos(th) * r, y, math.sin(th) * r) * CFrame.Angles(0, c * 14, 0)
    end

    function BEHAV.swarm(st, base, centerRoot, t)
        local i, s = st.index, st.params.size
        local z = math.sin(t * 3 + i * 1.3) * 11 * s
        local x = math.cos(t * 1.5 + i) * 2 * s
        return CF(x, 0, z)
    end

    -- target-centred groupings
    function BEHAV.ringAt(st, base, root, t, radius, rot)
        local n, i, s = st.count, st.index, st.params.size
        local th = i / math.max(1, n) * TAU + (rot or 0)
        local r = radius * s
        return orient(V3(math.cos(th) * r, 0.4, math.sin(th) * r), V3(0, 1, 0), V3(-math.cos(th), 0, -math.sin(th)))
    end
    function BEHAV.goto1(st, b, r, t) return BEHAV.ringAt(st, b, r, t, 3) end
    function BEHAV.bring(st, b, r, t) return BEHAV.ringAt(st, b, r, t, 2) end
    function BEHAV.circle(st, b, r, t) return BEHAV.ringAt(st, b, r, t, 5 + 0.3 * st.count, 0) end
    function BEHAV.loopcircle(st, b, r, t) return BEHAV.ringAt(st, b, r, t, 5 + 0.3 * st.count, t * 1.6) end
    function BEHAV.rline(st, b, r, t) return CF((st.index + 1) * 2.4 * st.params.size, 0, 0) end
    function BEHAV.lline(st, b, r, t) return CF(-(st.index + 1) * 2.4 * st.params.size, 0, 0) end
    function BEHAV.bline(st, b, r, t) return CF(0, 0, (st.index + 1) * 2.6 * st.params.size) end
    function BEHAV.fline(st, b, r, t) return CF(0, 0, -(st.index + 1) * 2.6 * st.params.size) end
    function BEHAV.stackon(st, b, r, t) return CF(0, 3.5 + st.index * 4.5 * st.params.size, 0) end
    function BEHAV.clone(st, b, r, t) return CF(math.sin(st.index) * 0.2, 0, math.cos(st.index) * 0.2) end
    function BEHAV.stalk(st, b, r, t) return CF(0, 0, (7 + st.index * 2.5) * st.params.size) end
    function BEHAV.grab(st, b, r, t)
        if st.index == 0 then return CF(0, 0, 0) end
        return BEHAV.ringAt(st, b, r, t, 3)
    end

    -- walk behaviours (real walking, no pinning)
    function BEHAV.moveTo(st, centerRoot, root, hum, dt)
        pcall(function() hum.WalkSpeed = num(st.cmdParams.ws, 1, 500, hum.WalkSpeed) end)
        pcall(function() hum:MoveTo(centerRoot.Position) end)
    end
    function BEHAV.wander(st, centerRoot, root, hum, dt)
        st.wnext = (st.wnext or 0) - dt
        if st.wnext <= 0 or not st.wgoal then
            st.wnext = st.rng:NextNumber(2, 5)
            local a = st.rng:NextNumber(0, TAU)
            local d = st.rng:NextNumber(6, 18)
            st.wgoal = (st.home or root.Position) + V3(math.cos(a) * d, 0, math.sin(a) * d)
        end
        pcall(function() hum:MoveTo(st.wgoal) end)
    end

    Alts.BEHAV = BEHAV

    ------------------------------------------------------------------
    -- Command table (shared by the main and the alts)
    ------------------------------------------------------------------
    local SPECS = {}
    Alts.SPECS = SPECS

    local function onceAnim(list)
        return function(st)
            local n = #list
            local idx = ((st.cmdParams.style or 1) - 1) % n + 1
            playAnim(list[idx])
        end
    end

    -- movement / positioning
    SPECS.goto1 = nil -- placeholder removed below
    SPECS.bring = { center = "target", needsTarget = true, frame = BEHAV.bring, label = "Bring", doc = "bring <player> - your alts crowd onto a player (they cannot teleport another player on a normal server)" }
    SPECS["goto"] = { center = "target", needsTarget = true, frame = BEHAV.goto1, label = "Go to", doc = "goto <player> - your alts gather on a player" }
    SPECS.walkto = { center = "target", needsTarget = true, mode = "walk", move = BEHAV.moveTo, label = "Walk to", doc = "walkto <player> - your alts walk to a player" }
    SPECS.wander = { center = "self", mode = "walk", move = BEHAV.wander, noclip = false, label = "Wander", doc = "wander - your alts roam nearby" }
    SPECS.jump = { mode = "once", label = "Jump", doc = "jump - your alts jump once", action = function() local _, h = selfRoot(); if h then h.Jump = true end end }
    SPECS.sit = { mode = "once", label = "Sit", doc = "sit - your alts sit", action = function() local _, h = selfRoot(); if h then h.Sit = true end end }
    SPECS.noclip = { mode = "idle", label = "Noclip", doc = "noclip - your alts pass through objects", onBegin = function(st) st.noclip = true end }
    SPECS.clip = { mode = "once", label = "Clip", doc = "clip - restore your alts' collisions", action = function() Alts.stopFollowing() end }
    SPECS.antivoid = { mode = "idle", label = "Anti-void", noclip = false, doc = "antivoid - a platform under each alt so it cannot fall into the void",
        onBegin = function(st) makePad(st) end, onStop = function(st) dropPad(st) end,
        idle = function(st, root) if st.extra and st.extra.pad then st.extra.pad.CFrame = CF(root.Position - V3(0, 3.4, 0)) end end }
    SPECS.unantivoid = { mode = "once", label = "Remove anti-void", doc = "unantivoid - remove the anti-void platforms", action = function() Alts.stopFollowing() end }

    -- formations / patterns
    SPECS.rline = { center = "target", needsTarget = true, frame = BEHAV.rline, label = "Right line", doc = "rline <player> - a line on the player's right" }
    SPECS.lline = { center = "target", needsTarget = true, frame = BEHAV.lline, label = "Left line", doc = "lline <player> - a line on the player's left" }
    SPECS.bline = { center = "target", needsTarget = true, frame = BEHAV.bline, label = "Line behind", doc = "bline <player> - a line behind the player" }
    SPECS.fline = { center = "target", needsTarget = true, frame = BEHAV.fline, label = "Line in front", doc = "fline <player> - a line in front of the player" }
    SPECS.circle = { center = "target", needsTarget = true, frame = BEHAV.circle, label = "Circle", doc = "circle <player> - a ring around the player" }
    SPECS.loopcircle = { center = "target", needsTarget = true, frame = BEHAV.loopcircle, label = "Loop circle", doc = "loopcircle <player> - a turning ring around the player" }
    SPECS.stackon = { center = "target", needsTarget = true, frame = BEHAV.stackon, label = "Stack on", doc = "stackon <player> - your alts stack above the player" }
    SPECS.clone = { center = "target", needsTarget = true, frame = BEHAV.clone, label = "Clone", doc = "clone <player> - your alts sit on the player's position" }
    SPECS.loopclone = { center = "target", needsTarget = true, frame = BEHAV.clone, label = "Loop clone", doc = "loopclone <player> - keep cloning the player's position" }
    SPECS.worm = { center = "main", frame = BEHAV.worm, label = "Worm", doc = "worm - your alts trail you in a chain" }
    SPECS.stalk = { center = "target", needsTarget = true, frame = BEHAV.stalk, label = "Stalk", doc = "stalk <player> - your alts follow a player at a distance" }
    SPECS.orbit = { center = "main", frame = BEHAV.orbit, label = "Orbit", doc = "orbit1-10 - orbit patterns around you" }
    SPECS.spiral = { center = "main", frame = BEHAV.spiral, label = "Spiral", doc = "spiral1-5 - spiral patterns around you" }
    SPECS.heli = { center = "main", frame = BEHAV.heli, label = "Helicopter", doc = "heli - a spinning rotor over your head" }

    -- actions / emotes
    SPECS.dance = { mode = "once", label = "Dance", doc = "dance1-3 - your alts dance", action = onceAnim(Alts.DANCE) }
    SPECS.emote = { mode = "once", label = "Emote", doc = "emote1-8 - preset emotes", action = onceAnim(Alts.EMOTES) }
    SPECS.laugh = { mode = "once", label = "Laugh", doc = "laugh - laugh emote", action = function() playAnim(Alts.EMOTES[6]) end }
    SPECS.wave = { mode = "once", label = "Wave", doc = "wave - wave emote", action = function() playAnim(Alts.EMOTES[4]) end }
    SPECS.point = { mode = "once", label = "Point", doc = "point - point emote", action = function() playAnim(Alts.EMOTES[5]) end }
    SPECS.mirror = { center = "main", frame = BEHAV.mirror, label = "Mirror", doc = "mirror - your alts face the way you face" }
    SPECS.rizz = { mode = "once", label = "Rizz", doc = "rizz - plays Alts.rizzAnim (set an animation id you own)", action = function() playAnim(Alts.rizzAnim) end }
    SPECS.firework = { center = "self", frame = BEHAV.firework, label = "Firework", doc = "firework - your alts shoot up like fireworks" }
    SPECS.nuke = { center = "main", frame = BEHAV.nuke, label = "Nuke", doc = "nuke [player] - your alts drop from the sky, spinning" }
    SPECS.swarm = { center = "target", needsTarget = true, frame = BEHAV.swarm, label = "Swarm", doc = "swarm <player> - your alts dash through a player" }

    -- trolling (bang / fbang / mbang are intentionally not included)
    SPECS.fling = { center = "main", frame = BEHAV.spin, label = "Fling", doc = "fling - your alts spin to fling players they touch (depends on the game's physics ownership)" }
    SPECS.spin = { center = "main", frame = BEHAV.spin, label = "Spin", doc = "spin - your alts spin in place" }
    SPECS.shield = { center = "main", frame = BEHAV.shield, label = "Shield", doc = "shield1-5 - defensive formations around you" }

    -- form shapes
    SPECS.arrow = { center = "main", frame = BEHAV.arrow, label = "Arrow", doc = "arrow - your alts form an arrow" }
    SPECS.box = { center = "main", frame = BEHAV.box, label = "Box", doc = "box - your alts form a square" }
    SPECS.star = { center = "main", frame = BEHAV.star, label = "Star", doc = "star - your alts form a star outline" }

    -- chat
    SPECS.say = { mode = "once", label = "Say", text = true, doc = "say <text> - your alts say a message",
        action = function(st) sayChat(st.cmdParams.text) end }
    SPECS.spam = { mode = "once", label = "Spam", text = true, doc = "spam <text> - your alts repeat a message",
        action = function(st)
            task.spawn(function()
                while Alts.state == st and genv.PuppyAdminActive == true do
                    sayChat(st.cmdParams.text)
                    task.wait(num(st.cmdParams.interval, 1, 30, 3))
                end
            end)
        end }
    SPECS.w = { mode = "once", label = "Whisper", doc = "w <player> <text> - your alts whisper a player",
        action = function(st) if st.cmdParams.text then sayChat("/w " .. tostring(st.cmdParams.whisperTo or "") .. " " .. st.cmdParams.text) end end }

    -- self utility
    SPECS.speed = { mode = "once", label = "Walk speed", doc = "ws / speed <n> - set your alts' walk speed",
        action = function(st) local _, h = selfRoot(); if h then pcall(function() h.WalkSpeed = num(st.cmdParams.ws, 1, 500, 16) end) end end }
    SPECS.equip = { mode = "once", label = "Equip", doc = "equip1-10 - your alts equip a backpack slot",
        action = function(st) equipSlot(st.cmdParams.slot or 1) end }
    SPECS.rest = { mode = "once", label = "Reset", doc = "rest - reset your alts' characters", action = function() local _, h = selfRoot(); if h then h.Health = 0 end end }
    SPECS.ref = { mode = "once", label = "Refresh", doc = "ref - refresh your alts (clear and restand)", action = function() Alts.stopFollowing() end }
    SPECS.quit = { mode = "once", label = "Quit", doc = "quit - your alts leave the game", action = function() pcall(function() plr:Kick("Puppy Admin: quit") end) end }
    SPECS.vcban = { mode = "once", label = "VC-ban bypass", doc = "vcban - your alts run the voice-chat-ban bypass if voice looks unavailable",
        action = function() Alts.autoVcBan(false) end }

    SPECS["goto"].frame = BEHAV.goto1
    SPECS.goto1 = nil

    ------------------------------------------------------------------
    -- Main side: build the command, keep it fresh, run info / utility
    ------------------------------------------------------------------

    function Alts.paramsFromCfg()
        local s = Cfg.altForm
        return { size = s.size, speed = s.speed, height = s.height, glitch = s.glitch,
            spin = s.spin, pulse = s.pulse, limbs = s.limbs == true, limbsDeath = s.limbsDeath == true,
            lite = Cfg.altLite == true }
    end

    -- an alt's Puppy Admin is running in this server (its status file, written every 10 s); cached 2 s
    local liveCache = {}
    function Alts.isLive(id)
        local c = liveCache[id]
        if c and os.clock() - c.at < 2 then return c.live, c.elsewhere end
        local st = readJson(DIR .. "/" .. tostring(id) .. ".json")
        local t = st and tonumber(st.time)
        local fresh = t ~= nil and os.time() - t <= 35 and st.online ~= false
        local here = fresh and (st.jobId == nil or st.jobId == game.JobId)
        liveCache[id] = { at = os.clock(), live = here, elsewhere = fresh and not here }
        return here, fresh and not here
    end

    function Alts.present()
        local ids = {}
        for _, id in ipairs(Alts.loadRoster().alts) do
            if Players:GetPlayerByUserId(id) and Alts.isLive(id) then table.insert(ids, id) end
        end
        return ids
    end

    function Alts.send()
        if Alts.role() ~= "main" then return false end
        local c = { v = 2, main = plr.UserId, placeId = game.PlaceId, jobId = game.JobId, time = os.time(), action = "stop" }
        local A = Alts.active
        if A then
            c.action, c.cmd, c.params = "cmd", A.cmd, A.params
            c.target, c.targetName, c.center = A.target or 0, A.targetName, A.center
            if A.cmd == "form" then
                c.layers, c.preset = Alts.assign(A.preset, A.idsList or {}), A.preset.key
            else
                c.ids = A.idsList or Alts.present()
            end
        end
        local ok = writeText(CMD_FILE, HttpService:JSONEncode(c))
        Alts.sentAt = os.clock()
        return ok
    end

    local function mainLoop()
        if Alts.mainRunning then return end
        Alts.mainRunning = true
        task.spawn(function()
            while Alts.alive and Alts.active and genv.PuppyAdminActive == true do
                task.wait(Cfg.altLite and 0.8 or 0.5)
                local A = Alts.active
                if not A then break end
                local ids = Alts.present()
                local key = table.concat(ids, ",")
                if key ~= A.ids then
                    A.idsList, A.ids = ids, key
                    Alts.send()
                elseif os.clock() - (Alts.sentAt or 0) > 5 then
                    Alts.send()
                end
                -- keep alts out of your own physics, except commands that need to touch you
                if A.cmd ~= "carpet" and A.cmd ~= "fling" then
                    for _, id in ipairs(ids) do
                        local p = Players:GetPlayerByUserId(id)
                        local ch = p and p.Character
                        if ch then
                            for _, d in ipairs(ch:GetDescendants()) do
                                if d:IsA("BasePart") then d.CanCollide = false end
                            end
                        end
                    end
                end
            end
            Alts.mainRunning = false
        end)
    end

    local function leadCheck()
        local r = Alts.loadRoster(true)
        if not r.main or r.main ~= plr.UserId then
            note("Alts", r.main and "Only your main account leads the alts (set it in Puppy Companion)"
                or "No account list yet: add your accounts in Puppy Companion and set its executor folder", RED)
            return false
        end
        return true
    end

    function Alts.start(key) -- formations entry (form command and the window)
        if not leadCheck() then return false end
        local preset = Alts.findPreset(key) or Alts.PRESETS[Cfg.altForm.preset] or Alts.PRESETS[1]
        for i, p in ipairs(Alts.PRESETS) do if p == preset then Cfg.altForm.preset = i end end
        cfgSave()
        local ids = Alts.present()
        if #ids == 0 then
            note("Alts", "No alt with Puppy Admin running is in this server yet (Puppy Companion: Send alts to main's server)", RED)
            return false
        end
        Alts.active = { cmd = "form", preset = preset, params = Alts.paramsFromCfg(), target = 0, center = "main",
            idsList = ids, ids = table.concat(ids, ","), label = preset.name }
        if not Alts.send() then
            Alts.active = nil
            note("Alts", "This executor cannot write files, so it cannot reach your alts", RED)
            return false
        end
        mainLoop()
        note("Alts", preset.name .. " with " .. #ids .. " alt" .. (#ids == 1 and "" or "s"), LIGHT)
        if UIAPI.sync then UIAPI.sync() end
        return true
    end

    function Alts.run(name, args, extra)
        local spec = SPECS[name]
        if not spec then return end
        if spec.main then return spec.main(args) end
        if not leadCheck() then return end
        local target, targetName = 0, nil
        if spec.needsTarget or spec.optionalTarget then
            -- trim the typed name: a trailing space (common from the box / phone keyboards)
            -- otherwise makes the match fail and you get "name a player" even with a target filled in
            local token = args and args[1] and tostring(args[1]):match("^%s*(.-)%s*$") or ""
            if token ~= "" then
                local p = resolveTargets(token)[1]
                if p and p ~= plr then target, targetName = p.UserId, p.DisplayName end
                if target == 0 and token:match("^%d+$") then target = tonumber(token) end -- allow a raw UserId
            end
            if spec.needsTarget and target == 0 then
                note("Alts", token == "" and (name .. ": type a player's name in the Target box first")
                    or (name .. ": no player here matches '" .. token .. "'"), RED)
                return
            end
        end
        local params = Alts.paramsFromCfg()
        if extra then for k, v in pairs(extra) do params[k] = v end end
        if spec.params then spec.params(params, args) end
        local center = (target ~= 0 and (spec.needsTarget or spec.optionalTarget)) and "target" or (spec.center or "main")
        local ids = Alts.present()
        if #ids == 0 then
            note("Alts", "No alt with Puppy Admin running is in this server (Puppy Companion: Send alts to main's server)", RED)
            return
        end
        -- one-shot commands (say, jump, dance, emote, equip, rest, ...) fire once and are NOT
        -- kept as the active command, so the main never resends and re-fires them. spam keeps
        -- going through its own loop on the alt until a new command or stop.
        if (spec.mode or "pin") == "once" then
            Alts.active = nil -- also stops resending any continuous command that was running
            Alts.seq = (Alts.seq or 0) + 1
            local c = { v = 2, main = plr.UserId, placeId = game.PlaceId, jobId = game.JobId, time = os.time(),
                action = "cmd", cmd = name, params = params, target = target, targetName = targetName,
                center = center, ids = ids, seq = Alts.seq }
            if not writeText(CMD_FILE, HttpService:JSONEncode(c)) then
                note("Alts", "This executor cannot write files, so it cannot reach your alts", RED)
                return
            end
            note("Alts", (spec.label or name) .. (targetName and (" on " .. targetName) or "")
                .. " - " .. #ids .. " alt" .. (#ids == 1 and "" or "s"), LIGHT)
            if UIAPI.sync then UIAPI.sync() end
            return
        end
        Alts.active = { cmd = name, params = params, target = target, targetName = targetName, center = center,
            idsList = ids, ids = table.concat(ids, ","), label = spec.label or name }
        if not Alts.send() then
            Alts.active = nil
            note("Alts", "This executor cannot write files, so it cannot reach your alts", RED)
            return
        end
        mainLoop()
        note("Alts", (spec.label or name) .. (targetName and (" on " .. targetName) or "")
            .. " - " .. #ids .. " alt" .. (#ids == 1 and "" or "s"), LIGHT)
        if UIAPI.sync then UIAPI.sync() end
    end

    function Alts.stop(quiet)
        local was = Alts.active ~= nil
        Alts.active = nil
        if Alts.role() == "main" then Alts.send() end
        if was and not quiet then note("Alts", "Stopped: your alts stand down", LIGHT) end
        if UIAPI.sync then UIAPI.sync() end
    end

    function Alts.settingsChanged()
        if Alts.pending then return end
        Alts.pending = true
        task.delay(0.2, function()
            Alts.pending = false
            cfgSave()
            if Alts.active then
                -- refresh the motion settings in place, keep command extras (style, text, ...)
                local s, p = Cfg.altForm, Alts.active.params
                p.size, p.speed, p.height = s.size, s.speed, s.height
                p.glitch, p.spin, p.pulse, p.lite = s.glitch, s.spin, s.pulse, Cfg.altLite == true
                p.limbs, p.limbsDeath = s.limbs == true, s.limbsDeath == true
                Alts.send()
            end
        end)
    end

    function Alts.setLite(arg)
        local on = Cfg.altLite ~= true
        if arg == "on" then on = true elseif arg == "off" then on = false end
        Cfg.altLite = on
        cfgSave()
        if not on then Alts.restoreFps() end
        note("Alts", "Low-power alt mode " .. (on and "on (alts cap at " .. (Cfg.altLiteFps or 30) .. " FPS)" or "off"), LIGHT)
        if Alts.active then Alts.send() end
        if UIAPI.sync then UIAPI.sync() end
    end

    Cfg.altWhitelist = type(Cfg.altWhitelist) == "table" and Cfg.altWhitelist or {}
    function Alts.whitelist(nameArg, on)
        local p = nameArg and resolveTargets(nameArg)[1]
        local key = p and p.Name:lower() or (nameArg and nameArg:lower())
        if not key or key == "" then note("Alts", "Name a player to " .. (on and "whitelist" or "blacklist"), RED); return end
        Cfg.altWhitelist[key] = on or nil
        cfgSave()
        note("Alts", (p and p.Name or key) .. (on and " may now drive your alts by chat" or " can no longer drive your alts"), LIGHT)
    end

    -- let whitelisted players issue alt commands in chat (only alt commands, nothing else)
    function Alts.relay(msg)
        if type(msg) ~= "string" then return end
        local rest, matched = msg, false
        for _, pre in ipairs(Cfg.prefixes) do
            if msg:sub(1, #pre) == pre then rest, matched = msg:sub(#pre + 1), true; break end
        end
        if not matched then return end
        local args = splitArgs(rest)
        if #args == 0 then return end
        local head = (ALIASES[args[1]:lower()] or args[1]:lower())
        -- whitelisted players may only run alt commands, and only through the `alt` word
        if head ~= "alt" then return end
        table.remove(args, 1)
        pcall(H.alt, args)
    end

    function Alts.watchChat()
        if Alts.chatHooked then return end
        Alts.chatHooked = true
        local function hook(p)
            if p == plr then return end
            table.insert(conns, p.Chatted:Connect(function(msg)
                if Cfg.altWhitelist[p.Name:lower()] then Alts.relay(msg) end
            end))
        end
        for _, p in ipairs(Players:GetPlayers()) do hook(p) end
        table.insert(conns, Players.PlayerAdded:Connect(hook))
    end

    -- alts: check for a voice ban now and then, and bypass it automatically
    function Alts.vcTick()
        local vp = Alts.myPrefs().vcAuto
        if vp == false or (vp == nil and Cfg.altVcAuto == false) then return end
        if Alts.role() ~= "alt" then return end
        if VCB.state == "active" or VCB.state == "running" then return end
        if Alts.voiceUnavailable() then Alts.autoVcBan(true) end
    end

    -- one alt as the main sees it
    function Alts.describe(id)
        local here = Players:GetPlayerByUserId(id) ~= nil
        local live, elsewhere = Alts.isLive(id)
        if here and live then return "ready, in this server", PAL.GOOD end
        if here then return "here, Puppy Admin not running", Color3.fromRGB(255, 190, 120) end
        if elsewhere then return "in another server", PAL.DIM end
        return "not playing", PAL.DIM
    end

    -- altcmd.json from the main: { action = "cmd"|"stop", cmd, params, target, center, ids / layers }
    function Alts.onCommand(raw)
        local ok, c = pcall(function() return HttpService:JSONDecode(raw) end)
        if not ok or type(c) ~= "table" then return end
        local r = Alts.loadRoster()
        if not r.main or tonumber(c.main) ~= r.main then return end
        c.main, c.time, c.target = r.main, tonumber(c.time) or 0, tonumber(c.target) or 0
        local own = Alts.myPrefs().lite
        if own ~= nil then Alts.lite = own else Alts.lite = (c.params and c.params.lite == true) or Cfg.altLite == true end
        if c.jobId ~= game.JobId or os.time() - c.time > STALE or c.action ~= "cmd" then
            Alts.stopFollowing(); return
        end
        if c.cmd == "form" and type(c.layers) == "table" then
            local slot = 0
            for li = 1, math.min(#c.layers, 8) do
                local L = c.layers[li]
                if type(L) == "table" and type(L.form) == "string" and SHAPES[L.form] and type(L.ids) == "table" then
                    local n = math.min(#L.ids, 50)
                    for k = 1, n do
                        if tonumber(L.ids[k]) == plr.UserId then Alts.follow(c, L.form, k - 1, n, slot + k - 1); return end
                    end
                    slot = slot + n
                end
            end
            Alts.stopFollowing(); return
        end
        local spec = type(c.cmd) == "string" and SPECS[c.cmd]
        if not spec or spec.main or type(c.ids) ~= "table" then Alts.stopFollowing(); return end
        local n = math.min(#c.ids, 50)
        for k = 1, n do
            if tonumber(c.ids[k]) == plr.UserId then
                if (spec.mode or "pin") == "once" then Alts.runOnce(c, c.cmd, spec, k - 1, n)
                else Alts.beginCmd(c, c.cmd, spec, k - 1, n, k - 1) end
                return
            end
        end
        Alts.stopFollowing()
    end

    ------------------------------------------------------------------
    -- Info / utility commands that run on the main
    ------------------------------------------------------------------
    SPECS.stop = { main = function() Alts.stop() end, label = "Stop", doc = "stop - stop whatever your alts are doing" }
    SPECS.altcount = { main = function()
        local n = #Alts.present()
        note("Alts", n .. " alt" .. (n == 1 and "" or "s") .. " ready in this server")
    end, doc = "altcount - how many of your alts are ready here" }
    SPECS.uptime = { main = function()
        local s = os.clock() - (Perf.t0 or os.clock())
        note("Alts", string.format("Uptime %d:%02d", math.floor(s / 60), math.floor(s % 60)))
    end, doc = "uptime - how long Puppy Admin has run this session" }
    SPECS.memory = { main = function()
        local lua = (gcinfo and gcinfo()) or math.floor(collectgarbage("count"))
        local total = 0
        pcall(function() total = game:GetService("Stats"):GetTotalMemoryUsageMb() end)
        note("Alts", string.format("Memory: %d MB total, %d MB Lua", math.floor(total), lua))
    end, doc = "memory - memory usage" }
    SPECS.cpu = { main = function()
        local fps = 0
        pcall(function() fps = math.floor(workspace:GetRealPhysicsFPS()) end)
        note("Alts", "Frame rate about " .. fps .. " FPS (Roblox gives no direct CPU figure)")
    end, doc = "cpu - frame rate (Roblox exposes no direct CPU reading)" }
    SPECS.ping = { main = function()
        local ping = "?"
        pcall(function() ping = game:GetService("Stats").Network.ServerStatsItem["Data Ping"]:GetValueString() end)
        note("Alts", "Ping (this window): " .. tostring(ping) .. " (Roblox exposes the main's, not each bot's)")
    end, doc = "ping - your network ping" }
    SPECS.whitelist = { main = function(a) Alts.whitelist(a and a[1], true) end, doc = "whitelist <player> - let a player drive your alts by chat" }
    SPECS.blacklist = { main = function(a) Alts.whitelist(a and a[1], false) end, doc = "blacklist <player> - stop a player driving your alts (alt control only)" }
    SPECS.altlite = { main = function(a) Alts.setLite(a and a[1]) end, doc = "altlite [on|off] - low-power alt mode (caps alt FPS; for weak PCs like a 2014 Surface Book)" }

    ------------------------------------------------------------------
    -- Alt commands live under their own `alt <command>` word so they never clash
    -- with your own character's commands (your .noclip, .fly, .speed stay yours).
    ------------------------------------------------------------------
    local FAMILY = { orbit = 10, spiral = 5, shield = 5, dance = 3, emote = 8, equip = 10 }
    local NAME_ALIAS = { ws = "speed", antivc = "vcban", gather = "goto", form = "form" }

    -- a word like "orbit3" -> base "orbit", { style = 3 }; "equip2" -> "equip", { slot = 2 }
    function Alts.resolveName(word)
        word = tostring(word or ""):lower()
        word = NAME_ALIAS[word] or word
        if SPECS[word] then return word, nil end
        local base, n = word:match("^(%a+)(%d+)$")
        if base and FAMILY[base] and tonumber(n) >= 1 and tonumber(n) <= FAMILY[base] then
            return base, (base == "equip") and { slot = tonumber(n) } or { style = tonumber(n) }
        end
        return nil
    end

    -- text / target parameters for the few commands that take them
    SPECS.say.params = function(p, a) p.text = table.concat(a or {}, " ") end
    SPECS.spam.params = function(p, a) p.text = table.concat(a or {}, " ") end
    SPECS.w.params = function(p, a)
        p.whisperTo = a and a[1] or ""
        p.text = table.concat(a or {}, " ", math.min(2, #a + 1))
    end
    SPECS.speed.params = function(p, a) p.ws = tonumber(a and a[1]) end
    SPECS.nuke.optionalTarget = true

    function H.alt(a)
        if not a or not a[1] then
            note("Alts", "Use: alt <command> [args] - e.g. alt circle bob, alt orbit3, alt say hi, alt stop. Board: altcmds", LIGHT)
            return
        end
        local base, extra = Alts.resolveName(a[1])
        if not base then
            note("Alts", "No alt command '" .. tostring(a[1]) .. "'. Open the board with altcmds for the full list.", RED)
            return
        end
        local rest = {}
        for i = 2, #a do rest[#rest + 1] = a[i] end
        Alts.run(base, rest, extra)
    end

    for _, name in ipairs({ "alt", "altlite", "formation" }) do
        if not table.find(cmds, name) then table.insert(cmds, name) end
    end
    cmdDocs.alt = "alt <command> [args] - control your alts (goto, circle, orbit1-10, spiral1-5, shield1-5, dance1-3, emote1-8, say, spam, w, fling, spin, carpet, firework, nuke, swarm, noclip, antivoid, speed, equip1-10, rest, quit, vcban, stop, ...). Board: altcmds"
    cmdDocs.altlite = "altlite [on|off] - low-power alt mode (caps each alt's FPS; for weak PCs like a 2014 Surface Book)"
    cmdDocs.formation = "formation [shape] - alias of form (your alts take a shape around you)"
    H.altlite = function(a) Alts.setLite(a and a[1]) end
    H.formation = function(a) H.form(a) end
    ALIASES.a = "alt"; ALIASES.bot = "alt"; ALIASES.bots = "alt"

    ------------------------------------------------------------------
    function H.alts() UIAPI.togglePanel("alts") end

    function H.form(a)
        local key = a and a[1]
        if key and not Alts.findPreset(key) then
            note("Alts", "Shapes: " .. Alts.keyList(), RED)
            return
        end
        local size = tonumber(a and a[2])
        if size then Cfg.altForm.size = math.max(0.5, math.min(3, size)) end
        Alts.start(key)
    end

    function H.unform() Alts.stop() end

    -- One window, three tabs: Accounts (roster + power/voice), Formations, Commands.
    function UIAPI.buildAltsPanel(screenGui)
        local W, HGT = 360, 600
        local f = uiWindow(screenGui, "alts", "Alts", UDim2.fromOffset(W, HGT), UDim2.new(0.5, -W / 2, 0.5, -HGT / 2))
        local IW = W - 32
        local S = Cfg.altForm

        local status = label(f, { Position = UDim2.fromOffset(16, 44), Size = UDim2.fromOffset(IW, 16), TextSize = 11,
            TextColor3 = PAL.DIM, TextTruncate = Enum.TextTruncate.AtEnd })

        local pageTop = 100
        local pages, tabBtns = {}, {}
        local function showTab(nm)
            for k, pg in pairs(pages) do pg.Visible = (k == nm) end
            for k, b in pairs(tabBtns) do
                b.BackgroundTransparency = (k == nm) and 0 or 0.55
                b.TextColor3 = (k == nm) and PAL.TEXT or PAL.DIM
            end
            if UIAPI.syncFns.alts then UIAPI.syncFns.alts() end
        end
        UIAPI.altsTab = showTab
        local tabNames = { "Accounts", "Formations", "Commands" }
        local tw = (IW - 12) / 3
        for i, nm in ipairs(tabNames) do
            local b = uiButton(f, nm, UDim2.fromOffset(tw, 26), UDim2.fromOffset(16 + (i - 1) * (tw + 6), 66), function() showTab(nm) end)
            b.TextSize = 12
            tabBtns[nm] = b
            pages[nm] = make("Frame", { Position = UDim2.fromOffset(16, pageTop), Size = UDim2.fromOffset(IW, HGT - pageTop - 12),
                BackgroundTransparency = 1, Visible = false }, f)
        end

        -- Accounts ----------------------------------------------------------
        local acc = pages.Accounts
        local list = make("ScrollingFrame", { Size = UDim2.fromOffset(IW, 236), BackgroundColor3 = PAL.CARD,
            BackgroundTransparency = 0.3, BorderSizePixel = 0, ScrollBarThickness = 3, ScrollBarImageColor3 = PAL.DIM,
            CanvasSize = UDim2.fromOffset(0, 0) }, acc)
        corner(list, 8)
        local liteSw = uiSwitch(acc, "Low power (cap " .. (Cfg.altLiteFps or 30) .. " FPS, low graphics)", UDim2.fromOffset(0, 250), IW, Cfg.altLite ~= false, function(on)
            Cfg.altLite = on; cfgSave(); if not on then Alts.restoreFps() end; if Alts.active then Alts.send() end
        end)
        local vcSw = uiSwitch(acc, "Alts auto-bypass voice bans", UDim2.fromOffset(0, 282), IW, Cfg.altVcAuto ~= false, function(on)
            Cfg.altVcAuto = on; cfgSave()
        end)
        local bwA = (IW - 8) / 2
        uiButton(acc, "Run VC-ban bypass", UDim2.fromOffset(bwA, 30), UDim2.fromOffset(0, 318), function() Alts.autoVcBan(true) end)
        uiButton(acc, "Stop all", UDim2.fromOffset(bwA, 30), UDim2.fromOffset(bwA + 8, 318), function() Alts.stop() end)
        label(acc, { Position = UDim2.fromOffset(0, 356), Size = UDim2.fromOffset(IW, 120), TextWrapped = true, TextSize = 11,
            TextYAlignment = Enum.TextYAlignment.Top, TextColor3 = PAL.DIM,
            Text = "Accounts come from Puppy Companion: set your main, add alts, pick the executor folder. Each alt needs Puppy Admin auto-executing and must be in this server. The shape and commands are made of the alts' own characters, so everyone sees them." })

        -- Formations --------------------------------------------------------
        local fp = pages.Formations
        local names = {}
        for i, p in ipairs(Alts.PRESETS) do names[i] = p.name end
        if not Alts.PRESETS[S.preset] then S.preset = 1 end
        local dd = uiDropdown(fp, "Shape: ", UDim2.fromOffset(IW, 28), UDim2.fromOffset(0, 4), names, S.preset, function(i)
            S.preset = i; cfgSave()
            if Alts.active and Alts.active.cmd == "form" then Alts.start(Alts.PRESETS[i].key) end
        end)
        local sliders = {}
        local function slider(text, y, key, min, max, step, fmt)
            sliders[key] = uiSlider(fp, text, UDim2.fromOffset(0, y), IW, { min = min, max = max, step = step,
                value = S[key], format = fmt, onChange = function(v) S[key] = v; Alts.settingsChanged() end })
        end
        slider("Size", 44, "size", 0.5, 3, 0.1, function(v) return string.format("%.1fx", v) end)
        slider("Speed", 90, "speed", 0, 3, 0.1, function(v) return string.format("%.1fx", v) end)
        slider("Height", 136, "height", -3, 15, 0.5, function(v) return string.format("%+.1f", v) end)
        local switches = {}
        local function switch(text, y, key)
            switches[key] = uiSwitch(fp, text, UDim2.fromOffset(0, y), IW, S[key], function(on) S[key] = on; Alts.settingsChanged() end)
        end
        switch("Glitch: random jumps and twists", 186, "glitch")
        switch("Spin: bodies turn in place", 214, "spin")
        switch("Pulse: the shape breathes", 242, "pulse")
        switch("Separate limbs (game's ragdoll, no death)", 270, "limbs")
        switch("No ragdoll? Let alts DIE to separate", 298, "limbsDeath")
        local bwF = (IW - 8) / 2
        local startBtn = uiButton(fp, "Start", UDim2.fromOffset(bwF, 32), UDim2.fromOffset(0, 334), function()
            Alts.start((Alts.PRESETS[S.preset] or Alts.PRESETS[1]).key)
        end)
        uiButton(fp, "Stop", UDim2.fromOffset(bwF, 32), UDim2.fromOffset(bwF + 8, 334), function() Alts.stop() end)

        -- Commands ----------------------------------------------------------
        local cp = pages.Commands
        local targetBox = uiBox(cp, UDim2.fromOffset(0, 2), UDim2.fromOffset(IW, 26), "Target player (goto, circle, stalk, ...)")
        local chatBox = uiBox(cp, UDim2.fromOffset(0, 32), UDim2.fromOffset(IW, 26), "Message (say, spam, whisper)")
        local cbodyH = (HGT - pageTop - 12) - 64 - 36
        local cbody = make("ScrollingFrame", { Position = UDim2.fromOffset(0, 64), Size = UDim2.fromOffset(IW, cbodyH),
            BackgroundColor3 = PAL.CARD, BackgroundTransparency = 0.35, BorderSizePixel = 0, ScrollBarThickness = 4,
            ScrollBarImageColor3 = PAL.DIM, CanvasSize = UDim2.fromOffset(0, 0) }, cp)
        corner(cbody, 8)
        make("UIPadding", { PaddingTop = UDim.new(0, 6), PaddingLeft = UDim.new(0, 6), PaddingRight = UDim.new(0, 6) }, cbody)
        local function boardRun(name)
            local base, extra = Alts.resolveName(name)
            if not base then return end
            local spec = Alts.SPECS[base]
            local args
            if base == "say" or base == "spam" then args = { chatBox.Text }
            elseif base == "w" then args = { targetBox.Text, chatBox.Text }
            elseif spec and (spec.needsTarget or spec.optionalTarget) then args = { targetBox.Text }
            else args = {} end
            Alts.run(base, args, extra)
        end
        local cy = 0
        local colW = (IW - 12 - 12) / 3
        local function section(title, items)
            make("TextLabel", { Position = UDim2.fromOffset(2, cy), Size = UDim2.fromOffset(IW - 12, 18), BackgroundTransparency = 1,
                Text = title:upper(), Font = Enum.Font.GothamBold, TextSize = 11, TextColor3 = PAL.DIM,
                TextXAlignment = Enum.TextXAlignment.Left }, cbody)
            cy = cy + 20
            for idx, name in ipairs(items) do
                local col = (idx - 1) % 3
                local row = math.floor((idx - 1) / 3)
                local b = uiButton(cbody, name, UDim2.fromOffset(colW, 26),
                    UDim2.fromOffset(col * (colW + 6), cy + row * 30), function() boardRun(name) end)
                b.TextSize = 11
            end
            cy = cy + math.ceil(#items / 3) * 30 + 8
        end
        section("Move", { "goto", "bring", "walkto", "stalk", "noclip", "clip" })
        section("Around you", { "circle", "orbit1", "orbit2", "spin", "worm", "heli", "mirror" })
        section("Actions", { "dance1", "dance2", "dance3", "wave", "point", "firework", "nuke", "swarm" })
        section("Shapes", { "arrow", "box", "star", "fling" })
        section("Chat", { "say", "spam", "w" })
        section("Utility", { "speed", "equip1", "antivoid", "rest", "quit", "vcban" })
        cbody.CanvasSize = UDim2.fromOffset(0, cy + 6)
        label(cp, { Position = UDim2.fromOffset(0, 64 + cbodyH + 4), Size = UDim2.fromOffset(IW, 30), TextWrapped = true,
            TextSize = 10, TextColor3 = PAL.DIM, TextYAlignment = Enum.TextYAlignment.Top,
            Text = "Every command also works in chat: alt <name> (e.g. alt orbit5, alt shield3). Full list: help." })

        -- shared refresh / sync --------------------------------------------
        local function refresh()
            local r = Alts.loadRoster(true)
            local role = Alts.role()
            for _, c in ipairs(list:GetChildren()) do if c:IsA("GuiObject") then c:Destroy() end end
            for i, id in ipairs(r.alts) do
                local text, color = Alts.describe(id)
                local y = (i - 1) * 22 + 4
                label(list, { Position = UDim2.fromOffset(8, y), Size = UDim2.new(0.5, -8, 0, 20), TextSize = 12,
                    Text = r.names[id] or tostring(id), TextTruncate = Enum.TextTruncate.AtEnd })
                label(list, { Position = UDim2.new(0.5, 0, 0, y), Size = UDim2.new(0.5, -8, 0, 20), TextSize = 11,
                    Text = text, TextColor3 = color, TextXAlignment = Enum.TextXAlignment.Right })
            end
            list.CanvasSize = UDim2.fromOffset(0, #r.alts * 22 + 8)
            if not r.found then
                status.Text = "No accounts yet - set them up in Puppy Companion."
            elseif role == "alt" then
                status.Text = "This is an alt: it follows " .. tostring(r.names[r.main] or "the main") .. " by itself."
            elseif role ~= "main" then
                status.Text = "This account is not in Puppy Companion's list."
            else
                status.Text = string.format("You lead - %d of %d alt%s ready here.%s", #Alts.present(), #r.alts,
                    #r.alts == 1 and "" or "s", Alts.active and (" Now: " .. tostring(Alts.active.label)) or "")
            end
            startBtn.Text = Alts.active and "Restart" or "Start"
            if UIAPI.altsButtonStatus then pcall(UIAPI.altsButtonStatus) end
        end

        UIAPI.syncFns.alts = function()
            if not f.Visible then return end
            dd.set(S.preset)
            for key, s in pairs(sliders) do if not s.isDragging() then s.set(S[key]) end end
            for key, s in pairs(switches) do s.set(S[key]) end
            liteSw.set(Cfg.altLite ~= false)
            vcSw.set(Cfg.altVcAuto ~= false)
            pcall(refresh)
        end
        f:GetPropertyChangedSignal("Visible"):Connect(function() if f.Visible then UIAPI.syncFns.alts() end end)
        showTab("Accounts")
        task.spawn(function()
            while f.Parent and Alts.alive do
                task.wait(2)
                if f.Visible then pcall(refresh) end
            end
        end)
    end

    -- opens the Alts window straight on the Commands tab
    function H.altcmds()
        local f = UIAPI.panels.alts -- builds it if needed
        if f then f.Visible = true end
        if UIAPI.altsTab then UIAPI.altsTab("Commands") end
        if UIAPI.sync then UIAPI.sync() end
    end
    if not table.find(cmds, "altcmds") then table.insert(cmds, "altcmds") end
    cmdDocs.altcmds = "altcmds - open the Alts window on the Commands tab"
    ALIASES.altcommands = "altcmds"

    -- every copy watches the command file while it is an alt (the roster can change while it runs)
    task.spawn(function()
        while Alts.alive and genv.PuppyAdminActive == true do
            if Alts.role() == "alt" then
                Alts.applyAltClientSettings()
                local ok, raw = pcall(function()
                    if isfile and readfile and isfile(CMD_FILE) then return readfile(CMD_FILE) end
                    return nil
                end)
                if ok and raw and raw ~= Alts.lastRaw then
                    Alts.lastRaw = raw
                    Alts.onCommand(raw)
                end
                task.wait(0.25)
            else
                if Alts.state then Alts.stopFollowing() end
                task.wait(2)
            end
            pcall(Alts.vcTick)
            if Alts.role() == "main" then pcall(Alts.watchChat) end
        end
    end)

    table.insert(cleanups, function()
        Alts.alive = false
        if Alts.active then
            Alts.active = nil
            pcall(Alts.send) -- the alts land when the main's script stops
        end
        Alts.stopFollowing()
    end)
end

------------------------------------------------------------------------
-- Runtime
------------------------------------------------------------------------

Perf.since("Setup (everything before the UI)", Perf.t0)
genv.PuppyAdminShutdown = function() shutdown(false) end
task.delay(1, function() note("Puppy Admin", "Build " .. tostring(genv.PuppyAdminBuild) .. " loaded", GREY) end)
if not Cfg.skipIntro then showBrandIntro() end
do
    local uiStart = os.clock()
    createUI()
    if UIAPI.fps and UIAPI.fps.isOn() then pcall(UIAPI.fps.show) end
    if Cfg.cursor and Cfg.cursor ~= "Default" then
        task.spawn(function() pcall(UIAPI.Cursor.set, Cfg.cursor, true) end)
    end
    Perf.since("Main UI (terminal, help, settings, panel registry)", uiStart)
end
Watch.start()
pcall(UIAPI.companionStart)
pcall(UIAPI.altsSetup)
-- fetch the engine file in the background once per version, so the first reanim / movement command does not wait for it
task.spawn(function()
    task.wait(3)
    if genv.PuppyAdminActive == true and not Pup.chunk and not Pup.engineCached() then pcall(Pup.fetchEngine) end
end)
Chat.start()

table.insert(conns, UserInputService.InputBegan:Connect(function(input, processed)
    if processed then return end
    if input.UserInputType ~= Enum.UserInputType.Keyboard then return end
    if input.KeyCode.Name == Cfg.uiKey then
        Hide.setUI(not Hide.uiHidden)
    end
end))

local function isGrip(obj)
    return obj.Name == "RightGrip" and obj:IsA("JointInstance")
end

-- Tool and hand-grip hooks for the current body; re-run after every respawn.
local charConns = {}
local function hookCharacter(c, async)
    for _, cn in ipairs(charConns) do pcall(function() cn:Disconnect() end) end
    table.clear(charConns)
    if not S.enabled then return end -- tools system off: tools and grips are left alone
    table.insert(charConns, c.ChildAdded:Connect(function(t)
        if t:IsA("Tool") then
            task.wait()
            setupTool(t)
        end
    end))
    for _, v in ipairs(c:GetChildren()) do
        if v:IsA("Tool") then
            if async then task.spawn(setupTool, v) else setupTool(v) end
        end
    end
    for _, obj in ipairs(c:GetDescendants()) do
        if isGrip(obj) then obj:Destroy() end
    end
    table.insert(charConns, c.DescendantAdded:Connect(function(obj)
        if isGrip(obj) then obj:Destroy() end
    end))
end
hookCharacter(chr, false)

-- Tools system on / off. Off (the default) leaves your tools completely alone;
-- turning it off again releases every tool back to normal (in your backpack).
function S.setEnabled(on)
    on = on and true or false
    if S.enabled == on then return end
    S.enabled = on
    if on then
        hookCharacter(chr, true)
        note("Tools", "Tools system on - orbit/tail/wings now use your tools", LIGHT)
    else
        local released = {}
        for i = #slots, 1, -1 do
            destroySlotObjects(slots[i])
            table.insert(released, slots[i].tool)
        end
        table.clear(slots)
        table.clear(pendingTools)
        hookCharacter(chr, false)
        for _, tool in ipairs(released) do
            pcall(function() if tool.Parent then tool.Parent = bp end end)
        end
        note("Tools", "Tools system off - your tools are back to normal")
    end
    if UIAPI.sync then UIAPI.sync() end
end
table.insert(cleanups, function()
    for _, cn in ipairs(charConns) do pcall(function() cn:Disconnect() end) end
    table.clear(charConns)
end)

-- Rainbow tags and animated auras run every frame, whether or not the tools
-- system is on (they used to share the tools loop and froze while it was off).
table.insert(conns, RunService.RenderStepped:Connect(function(dt)
    if not genv.PuppyAdminActive then return end
    local t = os.clock()
    Aura.step(t, dt)
    Tags.step(t)
end))

table.insert(conns, RunService.RenderStepped:Connect(function(dt)
    if not genv.PuppyAdminActive or not S.enabled then return end
    if not targetHRP or not targetHRP.Parent then targetHRP = hrp end

    S.rot = S.rot + S.speed
    local time = os.clock()
    local base = targetHRP.CFrame
    local anchors = getAnchors(targetHRP.Parent, targetHRP)
    local shapedActive = S.tailOn or S.wingsOn
    local alpha = 1 - math.exp(-(shapedActive and S.lerpShape or S.lerpOrbit) * dt)

    for _, slot in ipairs(slots) do
        local p = slot.ref
        if p and p.Parent then
            local goal
            if slot.role == "idle" then
                applyConstraintState(slot, false)
                goal = base
            elseif slot.role == "orbit" then
                applyConstraintState(slot, false)
                goal = orbitCFrame(base, slot.k, slot.m, time)
                slot.angular.AngularVelocity = Vector3.new(0, S.toolRotSpeed * (10 + (S.mode % 30)), 0)
            else
                applyConstraintState(slot, true)
                goal = shapeGoal(base, slot, anchors, time)
            end
            p.CFrame = p.CFrame:Lerp(goal, alpha)
        end
    end


    if sethiddenproperty then
        pcall(function() sethiddenproperty(plr, "SimulationRadius", math.huge) end)
    end
end))

table.insert(conns, RunService.Stepped:Connect(function()
    pcall(function()
        settings().Physics.AllowSleep = false
        plr.SimulationRadius = SETTINGS.SimulationRadius
    end)
end))

local lastHRPPos = hrp.Position
local hrpVel = Vector3.zero

table.insert(conns, RunService.PostSimulation:Connect(function(dt)
    if not S.enabled then return end
    if not targetHRP or not targetHRP.Parent then return end

    local currentTime = os.clock()
    local currentPos = hrp.Position
    if dt > 0 then hrpVel = (currentPos - lastHRPPos) / dt end
    lastHRPPos = currentPos

    local predictedHRPPos = currentPos + hrpVel * 0.1
    local antiSleep = Vector3.new(0, math.sin(currentTime * 15) * 0.0015, 0)
    local gravityAxis = SETTINGS.VelocityY + math.sin(currentTime)

    for _, slot in ipairs(slots) do
        local h = slot.handle
        if h and h.Parent then
            local dir = predictedHRPPos - h.Position
            local xz = Vector3.new(dir.X, 0, dir.Z)
            local velXZ = Vector3.zero
            if xz.Magnitude > 0 then velXZ = xz.Unit * xz.Magnitude * 2 end

            h.AssemblyLinearVelocity = Vector3.new(velXZ.X, gravityAxis, velXZ.Z)
            if slot.shaped then
                h.AssemblyAngularVelocity = Vector3.zero
            else
                h.AssemblyAngularVelocity = Vector3.new(0, math.huge, math.huge)
            end
            h.CFrame = h.CFrame + antiSleep
        end
    end
end))

task.spawn(function()
    while genv.PuppyAdminActive do
        task.wait(0.1)
        local stray = {}
        for _, slot in ipairs(slots) do
            if slot.handle.Parent and slot.ref then
                if (slot.handle.Position - slot.ref.Position).Magnitude > SETTINGS.MaxOrbitDistance then
                    table.insert(stray, slot.tool)
                end
            end
        end
        for _, tool in ipairs(stray) do
            sendFlatNotification("Orbit Sync", "Resyncing: " .. tool.Name, GREY)
            task.spawn(function()
                if tool.Parent == chr then
                    tool.Parent = bp
                    task.wait()
                    if tool.Parent == bp then tool.Parent = chr end
                end
            end)
        end
    end
end)

-- Respawn: the script keeps running and moves to the new body (orbit tools,
-- orbit target, tool hooks). Reanimation swaps Character to its clone and back
-- on purpose; those swaps are not respawns and are left alone.
table.insert(conns, plr.CharacterAdded:Connect(function(newChar)
    if newChar == chr or Reanim.isClone(newChar) then return end
    task.wait(0.5) -- the engine can register the clone just after the swap
    if newChar == chr or Reanim.isClone(newChar) or plr.Character ~= newChar or genv.PuppyAdminActive ~= true then return end
    local newRoot = newChar:WaitForChild("HumanoidRootPart", 10)
    if not newRoot or plr.Character ~= newChar or genv.PuppyAdminActive ~= true then return end
    local followedSelf = targetHRP == hrp or not targetHRP or not targetHRP.Parent
    for i = #slots, 1, -1 do destroySlotObjects(slots[i]) end
    table.clear(slots)
    table.clear(pendingTools)
    chr, hrp = newChar, newRoot
    bp = plr:FindFirstChildOfClass("Backpack") or plr:WaitForChild("Backpack", 5) or bp
    if followedSelf then targetHRP = hrp end
    lastHRPPos, hrpVel = hrp.Position, Vector3.zero
    hookCharacter(chr, true)
    if UIAPI.sync then UIAPI.sync() end
end))

Perf.since("Start-up total (until ready)", Perf.t0)
sendFlatNotification("System", "Puppy Admin ready - " .. firstPrefix() .. "help in chat", LIGHT)

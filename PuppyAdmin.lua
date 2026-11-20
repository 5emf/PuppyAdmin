--[[
    Puppy Admin
    (formerly Tool Orbit) - orbit/tail/wings cosmetics, chat commands with
    editable prefixes, a settings window, hide/mute, auras/VFX, custom
    animations with keybinds, reanimation (ported from novoline.lua), teleport
    and click-teleport, and an allowlisted nametag editor.

    Everything the script draws (auras, nametags, hidden characters) is
    client-side: only you see it. Orbiting/tail/wings tools and the reanimation
    body follow the same replication rules as the original V3.

    Quick start:  .help   .tools   .tools tail on   .fly   .esp   .reanimui
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local CoreGui = game:GetService("CoreGui")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local HttpService = game:GetService("HttpService")
local TextChatService = game:GetService("TextChatService")

local genv = (getgenv and getgenv()) or _G
if genv.PuppyAdminActive == true then return end
genv.PuppyAdminActive = true

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
}

-- Animations that should exist on every run, e.g.
--   mywave = { id = "rbxassetid://<your id>", speed = 1, loop = false },
-- Left empty on purpose: add your own with `.anim add` or here.
local PRESET_ANIMATIONS = {}

local S = {
    offset = 8,
    speed = 1,
    mode = 1,
    rot = 0,
    toolRotSpeed = 1,
    lerpOrbit = 1,                   -- V3 default
    lerpShape = 14,                  -- uncalibrated: follow rate for tail/wings
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
-- novoline.lua's resolveAnim does the same GetObjects + KeyframeSequenceProvider
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
    tags = {},         -- tostring(UserId) -> { text, sub, color = {r,g,b}, rainbow, size, font, offset }
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
for name, def in pairs(PRESET_ANIMATIONS) do
    if not Cfg.anims[name] then
        local id = normalizeAnimId(def.id)
        if id then Cfg.anims[name] = { id = id, speed = def.speed or 1, loop = def.loop and true or false } end
    end
end


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
-- ported from novoline.lua: parts go invisible on your screen (re-asserted every
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
    -- voice pause is the novoline mute (SubscribePause); skipped while they are hidden
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
-- Auras / VFX (new, written for this script; add your own with Aura.register)
-- Visible on your screen only.
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
-- ctx = { char, hrp, head, color }
function Aura.register(name, desc, build)
    name = name:lower()
    if not Aura.defs[name] then table.insert(Aura.order, name) end
    Aura.defs[name] = { name = name, desc = desc, build = build }
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
    st[name] = { color = color or Aura.defaultColor }
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
-- Nametags (client-side billboards, saved per UserId in the config file)
------------------------------------------------------------------------

local Tags = { gui = {}, rainbow = {} }

local function tagColor(d)
    local c = d.color or { 255, 255, 255 }
    return Color3.fromRGB(c[1], c[2], c[3])
end

function Tags.destroy(userId)
    local g = Tags.gui[userId]
    if g then pcall(function() g:Destroy() end) end
    Tags.gui[userId] = nil
    Tags.rainbow[userId] = nil
end

function Tags.build(player, char)
    Tags.destroy(player.UserId)
    local d = Cfg.tags[tostring(player.UserId)]
    if not d or not char then return end
    local head = char:FindFirstChild("Head") or char:FindFirstChild("HumanoidRootPart")
    if not head then return end

    local okFont, font = pcall(function() return Enum.Font[d.font or "GothamBold"] end)
    if not okFont or not font then font = Enum.Font.GothamBold end
    local size = d.size or 22
    local color = tagColor(d)

    local g = make("BillboardGui", {
        Name = "PuppyAdminTag",
        Adornee = head,
        AlwaysOnTop = true,
        Size = UDim2.fromOffset(280, 64),
        StudsOffset = Vector3.new(0, d.offset or 3, 0),
        MaxDistance = 250,
        LightInfluence = 0,
        ResetOnSpawn = false,
    }, head)

    local main = make("TextLabel", {
        Size = UDim2.new(1, 0, 0.62, 0),
        BackgroundTransparency = 1,
        Text = d.text or "",
        Font = font,
        TextSize = size,
        TextColor3 = color,
        TextStrokeTransparency = 0.3,
    }, g)
    local sub = make("TextLabel", {
        Position = UDim2.new(0, 0, 0.62, 0),
        Size = UDim2.new(1, 0, 0.38, 0),
        BackgroundTransparency = 1,
        Text = d.sub or "",
        Font = font,
        TextSize = math.max(12, size - 8),
        TextColor3 = color:Lerp(Color3.new(1, 1, 1), 0.4),
        TextStrokeTransparency = 0.4,
    }, g)

    Tags.gui[player.UserId] = g
    if d.rainbow then Tags.rainbow[player.UserId] = { main, sub } end
end

function Tags.refresh(userId)
    local p = Players:GetPlayerByUserId(userId)
    if p and p.Character then Tags.build(p, p.Character) else Tags.destroy(userId) end
end

function Tags.step(t)
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

Watch.onCharacter(function(p, char) Tags.build(p, char) end)

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
-- Animations (Roblox AnimationIds and keyframe tables), reanimation, teleport
-- No animations ship with the script: you add your own.
--
-- Reanimation follows the design of novoline.lua: the character is cloned,
-- the clone becomes your Character (so controls and camera drive it), and the
-- real body is moved onto the clone every Heartbeat. Modes:
--   remote - fires the game's ragdoll remote so the server breaks the joints
--            (remote names and place ids come from novoline.lua)
--   client - no remote: disables your real Motor6D joints locally (untested)
--   local  - clone root welded to the real root, animation on the real joints
--            (only you see the animation)
------------------------------------------------------------------------

local Reanim = {
    active = false, starting = false, mode = nil, requested = "auto",
    real = nil, clone = nil, realHum = nil, cloneHum = nil, animBody = nil,
    conns = {}, noclip = true, noclipSet = {}, noclipWas = {},
    ignoreUntil = 0, listeners = {},
    remote = nil, remoteLocal = false,
    motors = {}, weld = nil, partState = {}, realAnimateWas = nil,
    destroyBehavior = nil,
}
local KF = {
    cache = {}, loadId = 0, userSpeed = 1, dir = 1, paused = false,
    playing = false, name = nil, frames = nil, times = nil, total = 0, t = 0,
    loop = true, isState = false, conn = nil, joints = {}, origC0 = {}, acMap = nil,
}
local Anim = { loaded = {}, manual = nil, manualTrack = nil, stateTrack = nil, stateName = nil, capture = nil }

function Reanim.changed()
    for _, fn in ipairs(Reanim.listeners) do pcall(fn) end
end

local function setAnimateEnabled(model, enabled)
    local a = model and model:FindFirstChild("Animate")
    if not a then return end
    pcall(function() a.Disabled = not enabled end)
    pcall(function() a.Enabled = enabled end)
end

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

------------------------------------------------------------------------
-- Keyframe tables: { ["Name"] = { { Time = 0, Data = { PartName = CFrame } }, ... } }
-- (the same layout novoline's recorder writes). Files run in a sandbox.
------------------------------------------------------------------------

local KF_MAX_FRAMES, KF_MAX_PARTS = 20000, 64

local function kfFetch(src)
    if src:match("^https?://") then
        local ok, res = pcall(function() return game:HttpGet(src) end)
        if ok and type(res) == "string" and #res > 0 then return res end
        return nil, "could not fetch the URL"
    end
    if isfile and readfile then
        local ok, res = pcall(function() if isfile(src) then return readfile(src) end end)
        if ok and type(res) == "string" then return res end
    end
    return nil, "file not found: " .. src
end

local function kfParse(source)
    if type(loadstring) ~= "function" then return nil, "loadstring is not available" end
    if type(setfenv) ~= "function" then return nil, "setfenv is not available, cannot sandbox the file" end
    local fn, err = loadstring(source)
    if not fn then return nil, "syntax error: " .. tostring(err) end
    setfenv(fn, {
        CFrame = CFrame, Vector3 = Vector3, math = math, table = table, string = string,
        pairs = pairs, ipairs = ipairs, tonumber = tonumber, tostring = tostring,
        select = select, unpack = unpack or table.unpack, type = type, next = next,
    })
    local ok, data = pcall(fn)
    if not ok then return nil, "runtime error: " .. tostring(data) end
    if type(data) ~= "table" then return nil, "the file did not return a table" end
    local _, frames = next(data)
    if type(frames) ~= "table" or #frames < 2 then return nil, "no keyframe list with 2+ frames found" end
    if #frames > KF_MAX_FRAMES then return nil, "too many keyframes" end
    local times, last = {}, -1
    for i, f in ipairs(frames) do
        if type(f) ~= "table" or type(f.Time) ~= "number" or f.Time < last or type(f.Data) ~= "table" then
            return nil, "keyframe " .. i .. " is malformed or out of order"
        end
        local n = 0
        for _, cf in pairs(f.Data) do
            n = n + 1
            if typeof(cf) ~= "CFrame" or n > KF_MAX_PARTS then return nil, "keyframe " .. i .. " has bad pose data" end
        end
        times[i] = f.Time
        last = f.Time
    end
    if frames[#frames].Time <= 0 then return nil, "animation has no duration" end
    return frames, times
end

function KF.load(name)
    local c = KF.cache[name]
    if c then return c.frames, c.times end
    local def = Cfg.anims[name]
    if not def or not def.src then return nil, "unknown animation" end
    local source, err = kfFetch(def.src)
    if not source then return nil, err end
    local frames, times = kfParse(source)
    if not frames then return nil, times end
    KF.cache[name] = { frames = frames, times = times }
    return frames, times
end

local function buildACJointMap(model)
    local map = {}
    for _, c in ipairs(model:GetDescendants()) do
        if c:IsA("AnimationConstraint") and c.Attachment0 and c.Attachment0.Parent
            and c.Attachment1 and c.Attachment1.Parent then
            map[c.Attachment1.Parent.Name] = { constraint = c }
        end
    end
    return map
end

function KF.bind(body)
    KF.joints, KF.origC0, KF.acMap = {}, {}, nil
    local hasMotor = false
    for _, d in ipairs(body:GetDescendants()) do
        if d:IsA("Motor6D") and d.Part1 then
            hasMotor = true
            KF.joints[d.Part1.Name] = d
            KF.origC0[d] = d.C0
        end
    end
    if not hasMotor then
        local map = buildACJointMap(body)
        if next(map) then KF.acMap = map end
    end
end

local function kfRestorePose()
    for motor, c0 in pairs(KF.origC0) do
        if motor.Parent then pcall(function() motor.C0 = c0 end) end
    end
    if KF.acMap then
        for _, jd in pairs(KF.acMap) do
            if jd.constraint and jd.constraint.Parent then
                pcall(function() jd.constraint.Transform = CFrame.identity end)
            end
        end
    end
end

local function kfApply(a, b, alpha)
    if KF.acMap then
        for partName, jd in pairs(KF.acMap) do
            local c = jd.constraint
            if c and c.Parent then
                local p = a.Data[partName]
                local pose = CFrame.identity
                if p then
                    local np = b.Data[partName]
                    pose = np and p:Lerp(np, alpha) or p
                end
                c.Transform = pose
            end
        end
    else
        for partName, p in pairs(a.Data) do
            local motor = KF.joints[partName]
            local orig = motor and KF.origC0[motor]
            if orig and motor.Parent then
                local np = b.Data[partName]
                motor.C0 = orig * (np and p:Lerp(np, alpha) or p)
            end
        end
    end
end

function KF.stop()
    KF.loadId = KF.loadId + 1
    if KF.conn then KF.conn:Disconnect(); KF.conn = nil end
    local was = KF.playing
    KF.playing, KF.name, KF.frames, KF.times, KF.t, KF.total = false, nil, nil, nil, 0, 0
    if was then
        kfRestorePose()
        if Reanim.animBody then setAnimateEnabled(Reanim.animBody, true) end
    end
    Reanim.changed()
end

function KF.step(dt)
    if not KF.playing or not Reanim.animBody or not Reanim.animBody.Parent then return end
    if not KF.paused then
        local nt = KF.t + dt * KF.userSpeed * (KF.speedMul or 1) * KF.dir
        if KF.loop or KF.isState then
            KF.t = nt % KF.total
        elseif nt >= KF.total or nt < 0 then
            KF.stop()
            if Anim.manual then Anim.manual = nil; Anim.stateName = nil end
            return
        else
            KF.t = nt
        end
    end
    local ia, ib, alpha = kfLocate(KF.times, KF.t, KF.total)
    if ia then kfApply(KF.frames[ia], KF.frames[ib], alpha) end
end

function KF.play(name, isState)
    if not Reanim.active or not Reanim.animBody then
        note("Anim", "Reanimate first (.reanim on)", RED)
        return false
    end
    local def = Cfg.anims[name]
    if not def then note("Anim", "Unknown animation: " .. tostring(name), RED); return false end
    KF.stop()
    local myId = KF.loadId
    task.spawn(function()
        local frames, times = KF.load(name)
        if myId ~= KF.loadId or not Reanim.active then return end
        if not frames then note("Anim", tostring(times), RED); Anim.manual = nil; return end
        local matched = 0
        for partName in pairs(kfPartNames(frames)) do
            if (KF.acMap and KF.acMap[partName]) or KF.joints[partName] then matched = matched + 1 end
        end
        if matched == 0 then
            note("Anim", name .. " matches none of this rig's joint names - recorded on a different body?", RED)
            Anim.manual = nil
            return
        end
        local body = Reanim.animBody
        local ctrl = body:FindFirstChildOfClass("Humanoid") or body:FindFirstChildOfClass("AnimationController")
        if ctrl then
            for _, tr in ipairs(ctrl:GetPlayingAnimationTracks()) do tr:Stop(0) end
        end
        setAnimateEnabled(body, false)
        KF.frames, KF.times, KF.total, KF.t = frames, times, frames[#frames].Time, 0
        KF.name, KF.isState = name, isState and true or false
        KF.loop = isState or def.loop ~= false
        KF.speedMul = def.speed or 1
        KF.playing = true
        local event = KF.acMap and RunService.PreSimulation or RunService.Heartbeat
        KF.conn = event:Connect(KF.step)
        Reanim.changed()
    end)
    return true
end

------------------------------------------------------------------------
-- Roblox AnimationId tracks (play on the animation body's Animator)
------------------------------------------------------------------------

local function getAnimator()
    local owner = (Reanim.active and Reanim.animBody) or chr
    local hum = owner and owner:FindFirstChildOfClass("Humanoid")
    if not hum then return nil end
    local an = hum:FindFirstChildOfClass("Animator")
    if not an then an = Instance.new("Animator"); an.Parent = hum end
    return an
end

function Anim.loadTrack(name)
    local def = Cfg.anims[name]
    local animator = getAnimator()
    if not def or not def.id or not animator then return nil end
    local cache = Anim.loaded[animator]
    if not cache then cache = {}; Anim.loaded[animator] = cache end
    if cache[name] then return cache[name] end
    local a = Instance.new("Animation")
    a.Name = name
    a.AnimationId = resolveAnimationId(def.id)
    local ok, track = pcall(function() return animator:LoadAnimation(a) end)
    if not ok or not track then return nil end
    cache[name] = track
    return track
end

function Anim.playTrack(name, isState)
    local def = Cfg.anims[name]
    local track = Anim.loadTrack(name)
    if not track then note("Anim", "Could not load " .. name, RED); return nil end
    track.Priority = isState and Enum.AnimationPriority.Action or Enum.AnimationPriority.Action4
    track.Looped = isState or def.loop or false
    track:Play(0.15, 1, def.speed or 1)
    task.delay(1.5, function()
        if track.Length == 0 and track.IsPlaying then
            note("Anim", name .. " has no keyframes - invalid or not allowed", RED)
        end
    end)
    return track
end

-- Starts a library animation. Returns true when it started (or is loading).
function Anim.startNamed(name, isState)
    local def = Cfg.anims[name]
    if not def then note("Anim", "Unknown animation: " .. tostring(name), RED); return false end
    if def.kind == "kf" then return KF.play(name, isState) end
    local track = Anim.playTrack(name, isState)
    if isState then Anim.stateTrack = track else Anim.manualTrack = track end
    return track ~= nil
end

function Anim.isPlaying(name)
    local def = Cfg.anims[name]
    if not def then return false end
    if def.kind == "kf" then return KF.playing and KF.name == name end
    local cache = Anim.loaded[getAnimator()]
    local t = cache and cache[name]
    return t ~= nil and t.IsPlaying
end

-- Keybind / button behaviour: press once to start, again to stop.
function Anim.toggle(name)
    if not Cfg.anims[name] then return end
    if Anim.isPlaying(name) then
        Anim.stopManual()
        return
    end
    Anim.stopManual()
    if Anim.startNamed(name, false) then Anim.manual = name end
    Reanim.changed()
end

function Anim.stopManual()
    if Anim.manualTrack then pcall(function() Anim.manualTrack:Stop(0.15) end); Anim.manualTrack = nil end
    if Anim.manual and Cfg.anims[Anim.manual] and Cfg.anims[Anim.manual].kind == "kf" then KF.stop() end
    Anim.manual = nil
    Anim.stateName = nil
    Reanim.changed()
end

function Anim.stopState()
    if Anim.stateTrack then pcall(function() Anim.stateTrack:Stop(0.2) end); Anim.stateTrack = nil end
    if KF.playing and KF.isState then KF.stop() end
end

function Anim.stopAll()
    for _, cache in pairs(Anim.loaded) do
        for _, track in pairs(cache) do pcall(function() track:Stop(0.1) end) end
    end
    Anim.manualTrack, Anim.stateTrack, Anim.manual, Anim.stateName = nil, nil, nil, nil
    KF.stop()
end

function Anim.clearCache()
    Anim.stopAll()
    Anim.loaded = {}
    KF.cache = {}
end

-- Adds or replaces a library entry. Returns ok, message.
function Anim.add(name, source, speed, loop)
    if not name or name == "" then return false, "give it a name" end
    local kind = classifyAnimSource(source)
    if not kind then return false, "source must be an animation id, a URL or a file path" end
    local def = { kind = kind, speed = speed or 1 }
    if kind == "id" then
        def.id = normalizeAnimId(source)
        def.loop = loop and true or false
    else
        def.src = source
        def.loop = loop ~= false
    end
    Cfg.anims[name] = def
    Anim.clearCache()
    cfgSave()
    return true, kind == "id" and "id animation added" or "keyframe animation added"
end

-- Picks idle / walk / jump / fall for the clone and plays what you mapped to it.
-- Anything you started yourself takes over until you stop it.
function Anim.updateState()
    local hum = Reanim.cloneHum
    if not Reanim.active or not hum then return end
    if Anim.manualTrack and not Anim.manualTrack.IsPlaying then Anim.manualTrack, Anim.manual, Anim.stateName = nil, nil, nil end
    if Anim.manual then return end
    local st
    if hum.FloorMaterial == Enum.Material.Air then
        st = (hum:GetState() == Enum.HumanoidStateType.Jumping) and "jump" or "fall"
    elseif hum.MoveDirection.Magnitude > 0.1 then
        st = "walk"
    else
        st = "idle"
    end
    if st == Anim.stateName then return end
    Anim.stateName = st
    Anim.stopState()
    local name = Cfg.animStates[st]
    if name and Cfg.anims[name] then Anim.startNamed(name, true) end
end

------------------------------------------------------------------------
-- Reanimation
------------------------------------------------------------------------

-- Ragdoll remotes: place ids and names come from novoline.lua (get_game_ragdoll_info).
local RAGDOLL_CANDIDATES = {
    "Ragdoll", "RagdollEvent", "event_rag", "Rag", "Ragdolled", "Remotes/Ragdoll",
    "Events/Ragdoll", "Remotes/Physics/Ragdoll", "RemoteEvents/Ragdoll", "RemoteEvents/RagdollEvent",
}

local function findPath(root, path)
    local cur = root
    for part in path:gmatch("[^/]+") do
        if not cur then return nil end
        cur = cur:FindFirstChild(part)
    end
    return cur
end

-- Returns remote, args, isLocalBindable (or nil when the game has none we know).
local function ragdollInfo(enable)
    local rep = game:GetService("ReplicatedStorage")
    local placeId = game.PlaceId
    if placeId == 15546218972 or placeId == 6884319169 then
        local r = rep:WaitForChild("event_rag", 4)
        if r then return r, { "Ball" }, false end
    elseif placeId == 5991163185 then
        local ok, r = pcall(function() return rep.Remotes.Physics.Ragdoll end)
        if ok and r then return r, {}, false end
    elseif placeId == 5683833663 then
        local r = rep:WaitForChild("LocalRagdollEvent", 4)
        if r then return r, { enable }, true end
    elseif placeId == 86382196724726 or game.GameId == 10581310106 then
        local remotes = rep:WaitForChild("Remotes", 4)
        local toggle = remotes and remotes:WaitForChild("RagdollToggle", 4)
        if toggle then return toggle, { enable and "Ball" or false }, false end
        return nil, nil, false
    end
    for _, path in ipairs(RAGDOLL_CANDIDATES) do
        local r = findPath(rep, path)
        if r then
            if r:IsA("BindableEvent") then return r, { enable }, true end
            if r:IsA("RemoteEvent") or r:IsA("RemoteFunction") then return r, {}, false end
        end
    end
    return nil, nil, false
end

local function fireRagdoll(remote, isLocal, args)
    if not remote then return end
    task.spawn(function()
        pcall(function()
            if isLocal then
                remote:Fire(unpack(args or {}))
            elseif remote:IsA("RemoteEvent") then
                remote:FireServer(unpack(args or {}))
            else
                remote:InvokeServer(unpack(args or {}))
            end
        end)
    end)
end

local function noclipRestore()
    for part in pairs(Reanim.noclipWas) do
        if part.Parent then pcall(function() part.CanCollide = true end) end
    end
    Reanim.noclipWas = {}
end

local function noclipStep()
    if not Reanim.noclip then return end
    for part in pairs(Reanim.noclipSet) do
        if part.Parent then
            if part.CanCollide then
                Reanim.noclipWas[part] = true
                part.CanCollide = false
            end
        else
            Reanim.noclipSet[part] = nil
        end
    end
end

local function noclipWatch(model)
    for _, d in ipairs(model:GetDescendants()) do
        if d:IsA("BasePart") then Reanim.noclipSet[d] = true end
    end
    return model.DescendantAdded:Connect(function(d)
        if d:IsA("BasePart") then Reanim.noclipSet[d] = true end
    end)
end

function Reanim.setNoclip(on)
    Reanim.noclip = on and true or false
    if not Reanim.noclip then noclipRestore() end
    Reanim.changed()
end

local function flipResetOnSpawn()
    local flipped = {}
    local gui = plr:FindFirstChildWhichIsA("PlayerGui")
    if gui then
        for _, g in ipairs(gui:GetChildren()) do
            if g:IsA("ScreenGui") and g.ResetOnSpawn then
                g.ResetOnSpawn = false
                flipped[g] = true
            end
        end
    end
    return flipped
end

local function unflipResetOnSpawn(flipped)
    for g in pairs(flipped) do
        if g.Parent then g.ResetOnSpawn = true end
    end
end

local function guardHealth(hum)
    pcall(function() hum:SetStateEnabled(Enum.HumanoidStateType.Dead, false) end)
    pcall(function()
        hum.HealthChanged:Connect(function(hp)
            if Reanim.active and hum.Parent and hp < hum.MaxHealth then hum.Health = hum.MaxHealth end
        end)
    end)
end

local function reanimStart(requested)
    local real = chr
    local realHum = real:FindFirstChildOfClass("Humanoid")
    local realRoot = real:FindFirstChild("HumanoidRootPart")
    if not (realHum and realRoot and real.Parent) then return false, "character is missing its humanoid or root" end

    local mode = requested
    local remote, rargs, rlocal
    if mode == "auto" or mode == "remote" then
        remote, rargs, rlocal = ragdollInfo(true)
        if remote then
            mode = "remote"
        elseif mode == "remote" then
            return false, "no ragdoll remote found for this game"
        else
            mode = "client"
        end
    end

    local prev = real.Archivable
    real.Archivable = true
    local clone = real:Clone()
    real.Archivable = prev
    if not clone then return false, "could not clone the character" end

    local doomed = {}
    for _, d in ipairs(clone:GetDescendants()) do
        if d.Name == "PuppyAdminFX" or d.Name == "PuppyAdminTag" or (d:IsA("Tool") and d.Parent == clone) then
            table.insert(doomed, d)
        end
    end
    for _, d in ipairs(doomed) do pcall(function() d:Destroy() end) end

    local cloneHum = clone:FindFirstChildOfClass("Humanoid")
    local cloneRoot = clone:FindFirstChild("HumanoidRootPart")
    if not (cloneHum and cloneRoot) then
        clone:Destroy()
        return false, "the clone is missing its humanoid or root"
    end

    clone.Name = "PuppyAdminClone"
    for _, d in ipairs(clone:GetDescendants()) do
        if d:IsA("BasePart") or d:IsA("Decal") then pcall(function() d.Transparency = 1 end) end
    end
    local ff = clone:FindFirstChildWhichIsA("ForceField")
    if ff then ff:Destroy() end
    cloneHum.RequiresNeck = false
    cloneHum.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
    setAnimateEnabled(clone, false)
    clone.Parent = workspace

    Reanim.real, Reanim.clone, Reanim.realHum, Reanim.cloneHum = real, clone, realHum, cloneHum
    Reanim.mode, Reanim.remote, Reanim.remoteLocal = mode, remote, rlocal
    Reanim.active = true

    local flipped = flipResetOnSpawn()
    if sethiddenproperty and gethiddenproperty then
        pcall(function()
            Reanim.destroyBehavior = gethiddenproperty(workspace, "PlayerCharacterDestroyBehavior")
            sethiddenproperty(workspace, "PlayerCharacterDestroyBehavior", Enum.PlayerCharacterDestroyBehavior.Disabled)
        end)
    end
    Reanim.ignoreUntil = os.clock() + 3
    plr.Character = clone
    if real.Parent == nil then pcall(function() real.Parent = workspace end) end
    pcall(function() realHum.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None end)
    if workspace.CurrentCamera then workspace.CurrentCamera.CameraSubject = cloneHum end
    setAnimateEnabled(clone, true)
    unflipResetOnSpawn(flipped)

    Reanim.animBody = (mode == "local") and real or clone
    KF.bind(Reanim.animBody)

    realHum.Health = realHum.MaxHealth
    for _, d in ipairs({ 0.1, 0.5, 1 }) do
        task.delay(d, function()
            if Reanim.active and realHum.Parent then realHum.Health = realHum.MaxHealth end
        end)
    end
    guardHealth(realHum)
    guardHealth(cloneHum)
    pcall(function()
        cloneHum:SetStateEnabled(Enum.HumanoidStateType.FallingDown, false)
        cloneHum:SetStateEnabled(Enum.HumanoidStateType.Ragdoll, false)
        cloneHum:SetStateEnabled(Enum.HumanoidStateType.Physics, false)
    end)

    if mode == "client" then
        Reanim.motors = {}
        for _, j in ipairs(real:GetDescendants()) do
            if j:IsA("Motor6D") then
                table.insert(Reanim.motors, { joint = j, enabled = j.Enabled })
                j.Enabled = false
            end
        end
    elseif mode == "local" then
        Reanim.partState = {}
        for _, d in ipairs(real:GetDescendants()) do
            if d:IsA("BasePart") then
                Reanim.partState[d] = { massless = d.Massless, collide = d.CanCollide }
                d.Massless = true
                if d ~= realRoot then d.CanCollide = false end
            end
        end
        local rAnim = real:FindFirstChild("Animate")
        if rAnim then
            Reanim.realAnimateWas = not rAnim.Disabled
            setAnimateEnabled(real, false)
        end
        Reanim.weld = make("Motor6D", {
            Name = "PuppetRoot", Part0 = cloneRoot, Part1 = realRoot,
            C0 = CFrame.identity, C1 = CFrame.identity,
        }, cloneRoot)
    elseif mode == "remote" then
        fireRagdoll(remote, rlocal, rargs)
    end

    table.insert(Reanim.conns, RunService.Heartbeat:Connect(function()
        if not Reanim.active then return end
        if real.Parent == nil then pcall(function() real.Parent = workspace end) end
        if not real.Parent or not clone.Parent then task.defer(Reanim.stop); return end
        if mode ~= "local" then
            for _, p in ipairs(real:GetChildren()) do
                if p:IsA("BasePart") then
                    local cp = clone:FindFirstChild(p.Name)
                    if cp and cp:IsA("BasePart") then
                        p.CFrame = cp.CFrame
                        p.AssemblyLinearVelocity = Vector3.zero
                        p.AssemblyAngularVelocity = Vector3.zero
                    end
                end
            end
        end
        if realHum.Parent and realHum.Health < realHum.MaxHealth then realHum.Health = realHum.MaxHealth end
        if cloneHum.Parent and cloneHum.Health < cloneHum.MaxHealth then cloneHum.Health = cloneHum.MaxHealth end
        Anim.updateState()
    end))

    task.delay(1.5, function()
        if not Reanim.active then return end
        table.insert(Reanim.conns, realHum.Died:Connect(function() task.defer(Reanim.stop) end))
        table.insert(Reanim.conns, real.ChildRemoved:Connect(function(c)
            if c == realHum or c == realRoot then task.defer(Reanim.stop) end
        end))
    end)
    table.insert(Reanim.conns, clone.ChildRemoved:Connect(function(c)
        if c == cloneHum then task.defer(Reanim.stop) end
    end))
    table.insert(Reanim.conns, plr.CharacterRemoving:Connect(function(c)
        if c == clone and Reanim.active and os.clock() > Reanim.ignoreUntil then task.defer(Reanim.stop) end
    end))

    Reanim.noclipSet = {}
    table.insert(Reanim.conns, noclipWatch(real))
    table.insert(Reanim.conns, noclipWatch(clone))
    table.insert(Reanim.conns, RunService.Stepped:Connect(noclipStep))
    return true, mode
end

function Reanim.start(requested)
    if Reanim.active or Reanim.starting then note("Reanim", "Already active"); return false end
    Reanim.starting = true
    requested = requested or Reanim.requested
    local ok, res, info = pcall(reanimStart, requested)
    Reanim.starting = false
    if not ok then
        note("Reanim", "Failed: " .. tostring(res):sub(1, 70), RED)
        Reanim.stop()
        return false
    end
    if not res then
        note("Reanim", tostring(info), RED)
        Reanim.stop()
        return false
    end
    note("Reanim", "Active (" .. tostring(info) .. ")", LIGHT)
    Reanim.changed()
    return true
end

function Reanim.stop()
    local real, clone = Reanim.real, Reanim.clone
    if not (Reanim.active or clone) then return end
    Reanim.active = false
    Anim.stopAll()
    for _, c in ipairs(Reanim.conns) do pcall(function() c:Disconnect() end) end
    Reanim.conns = {}

    local mode = Reanim.mode
    if mode == "remote" and Reanim.remote then
        local r2, a2, l2 = ragdollInfo(false)
        fireRagdoll(r2 or Reanim.remote, r2 and l2 or Reanim.remoteLocal, a2)
    elseif mode == "client" then
        for _, m in ipairs(Reanim.motors) do pcall(function() m.joint.Enabled = m.enabled end) end
    elseif mode == "local" then
        if Reanim.weld then pcall(function() Reanim.weld:Destroy() end) end
        for d, st in pairs(Reanim.partState) do
            if d.Parent then pcall(function() d.Massless = st.massless; d.CanCollide = st.collide end) end
        end
        if real and Reanim.realAnimateWas then setAnimateEnabled(real, true) end
    end
    Reanim.motors, Reanim.partState, Reanim.weld, Reanim.realAnimateWas = {}, {}, nil, nil
    noclipRestore()
    Reanim.noclipSet = {}

    local savedCF
    local cloneRoot = clone and clone:FindFirstChild("HumanoidRootPart")
    if cloneRoot then savedCF = cloneRoot.CFrame end

    if real and real.Parent then
        local flipped = flipResetOnSpawn()
        Reanim.ignoreUntil = os.clock() + 3
        plr.Character = real
        if clone then pcall(function() clone:Destroy() end) end
        local hum = real:FindFirstChildOfClass("Humanoid")
        if hum and workspace.CurrentCamera then workspace.CurrentCamera.CameraSubject = hum end
        unflipResetOnSpawn(flipped)
        if savedCF then
            task.spawn(function()
                local t0 = os.clock()
                while os.clock() - t0 < 0.5 do
                    task.wait()
                    local h = real.Parent and real:FindFirstChild("HumanoidRootPart")
                    if not h then return end
                    h.CFrame = savedCF
                    h.AssemblyLinearVelocity = Vector3.zero
                end
                for _, child in ipairs(real:GetChildren()) do
                    if child:IsA("Accessory") then
                        local handle = child:FindFirstChild("Handle")
                        local weld = handle and (handle:FindFirstChildWhichIsA("Weld") or handle:FindFirstChildWhichIsA("AccessoryWeld"))
                        if weld and weld.Part1 and weld.Part1.Parent then
                            pcall(function() handle.CFrame = weld.Part1.CFrame * weld.C1 * weld.C0:Inverse() end)
                        end
                    end
                end
            end)
        end
    elseif clone then
        pcall(function() clone:Destroy() end)
    end
    if Reanim.destroyBehavior ~= nil and sethiddenproperty then
        pcall(sethiddenproperty, workspace, "PlayerCharacterDestroyBehavior", Reanim.destroyBehavior)
    end
    Reanim.destroyBehavior = nil
    Reanim.real, Reanim.clone, Reanim.realHum, Reanim.cloneHum, Reanim.animBody = nil, nil, nil, nil, nil
    Reanim.mode, Reanim.remote = nil, nil
    Reanim.changed()
end

table.insert(cleanups, function() Reanim.stop() end)
table.insert(cleanups, function() Anim.stopAll() end)

------------------------------------------------------------------------
-- Teleport and click-teleport
------------------------------------------------------------------------

local Teleport = { click = false }

-- The part that actually moves you: the clone while reanimated.
local function bodyRoot()
    local owner = (Reanim.active and Reanim.clone) or chr
    return owner and owner:FindFirstChild("HumanoidRootPart")
end

function Teleport.toCFrame(cf)
    local root = bodyRoot()
    if not root then return false end
    root.CFrame = cf
    root.AssemblyLinearVelocity = Vector3.zero
    root.AssemblyAngularVelocity = Vector3.zero
    return true
end

function Teleport.toPlayer(p)
    local tr = p.Character and p.Character:FindFirstChild("HumanoidRootPart")
    if not tr then return false end
    return Teleport.toCFrame(tr.CFrame * CFrame.new(0, 0, 3))
end

function Teleport.toPoint(pos)
    local root = bodyRoot()
    if not root then return false end
    return Teleport.toCFrame(CFrame.new(pos) * (root.CFrame - root.CFrame.Position))
end

-- Raycast from the mouse position; returns the hit position or nil.
function Teleport.mousePoint(screenPos)
    local cam = workspace.CurrentCamera
    if not cam then return nil end
    local ray = cam:ScreenPointToRay(screenPos.X, screenPos.Y)
    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    local skip = { chr }
    if Reanim.clone then table.insert(skip, Reanim.clone) end
    params.FilterDescendantsInstances = skip
    local hit = workspace:Raycast(ray.Origin, ray.Direction * 2000, params)
    return hit and hit.Position
end

function Teleport.onClick(input)
    if not Teleport.click then return end
    local t = input.UserInputType
    if t ~= Enum.UserInputType.MouseButton1 and t ~= Enum.UserInputType.Touch then return end
    local p = Teleport.mousePoint(Vector2.new(input.Position.X, input.Position.Y))
    if p then Teleport.toPoint(p + Vector3.new(0, 3, 0)) end
end

------------------------------------------------------------------------
-- Movement, world and visuals (ported from novoline.lua)
-- fly / togglefly / flyspeed / superfly / hatfly / helicopter, noclip,
-- airwalk, swim, infinite baseplate, ESP (chams, hitboxes, tracers), rejoin.
-- Everything here acts on plr.Character at the moment it runs, so while you
-- are reanimated it drives the clone and your real body follows it.
------------------------------------------------------------------------

local Fly, Superfly, Helicopter, HatFly, Noclip, Airwalk, Swim, Baseplate, BASEPLATE_PRESETS, bpApplyAll, Esp, isMobile
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
-- Fly (novoline sFLY / mobilefly / NOFLY)
------------------------------------------------------------------------

Fly = { flying = false, speed = 1, qe = true, gen = 0, mouseHeld = false, conns = {}, diedConn = nil }
local FLY_VEL, FLY_GYRO = "_paFlyVel", "_paFlyGyro"

local function restoreFlyHumanoid(h, root)
    if h then
        pcall(function()
            h.PlatformStand = false
            h.Sit = false
            h.AutoRotate = true
            h:SetStateEnabled(Enum.HumanoidStateType.Jumping, true)
            h:SetStateEnabled(Enum.HumanoidStateType.GettingUp, true)
            h:SetStateEnabled(Enum.HumanoidStateType.Running, true)
            h:SetStateEnabled(Enum.HumanoidStateType.Freefall, true)
            h:ChangeState(Enum.HumanoidStateType.GettingUp)
        end)
        task.defer(function()
            if not h.Parent then return end
            pcall(function()
                if h.PlatformStand then h.PlatformStand = false end
                local st = h:GetState()
                if st == Enum.HumanoidStateType.Physics or st == Enum.HumanoidStateType.Ragdoll then
                    h:ChangeState(Enum.HumanoidStateType.GettingUp)
                end
            end)
        end)
    end
    if root then
        pcall(function()
            root.AssemblyLinearVelocity = Vector3.zero
            root.AssemblyAngularVelocity = Vector3.zero
        end)
    end
    pcall(function()
        local cam = workspace.CurrentCamera
        if cam then cam.CameraType = Enum.CameraType.Custom end
    end)
end

local function destroyFlyMovers(root)
    if not root then return end
    for _, n in ipairs({ FLY_VEL, FLY_GYRO }) do
        local o = root:FindFirstChild(n)
        if o then pcall(function() o:Destroy() end) end
    end
end

local function prepFlyHumanoid(hum)
    pcall(function()
        hum.Sit = false
        hum.AutoRotate = false
        hum:SetStateEnabled(Enum.HumanoidStateType.Jumping, false)
        hum.PlatformStand = true
    end)
end

function Fly.setSpeed(v)
    v = tonumber(v)
    if not v or v ~= v then return end
    Fly.speed = math.max(0.1, math.min(100, v))
end

local function flyInputConns()
    Fly.mouseHeld = false
    local held = isMobile and Enum.UserInputType.Touch or Enum.UserInputType.MouseButton1
    table.insert(Fly.conns, UserInputService.InputBegan:Connect(function(input, processed)
        if not processed and input.UserInputType == held then Fly.mouseHeld = true end
    end))
    table.insert(Fly.conns, UserInputService.InputEnded:Connect(function(input)
        if input.UserInputType == held then Fly.mouseHeld = false end
    end))
end

local function flyWatchDeath(hum)
    Fly.diedConn = disconnect(Fly.diedConn)
    Fly.diedConn = hum.Died:Connect(function()
        Fly.diedConn = disconnect(Fly.diedConn)
        if Fly.flying then pcall(Fly.stop) end
    end)
end

-- Keyboard / mouse flight: BodyVelocity + BodyGyro on the root, camera-relative.
local function flyDesktop(hum, T, myGen)
    local BG = make("BodyGyro", { Name = FLY_GYRO, P = 9e4, MaxTorque = Vector3.new(9e9, 9e9, 9e9), CFrame = T.CFrame }, T)
    local BV = make("BodyVelocity", { Name = FLY_VEL, Velocity = Vector3.zero, MaxForce = Vector3.new(9e9, 9e9, 9e9) }, T)
    task.spawn(function()
        local smooth = Vector3.zero
        while Fly.flying and myGen == Fly.gen do
            local dt = task.wait()
            if not Fly.flying or myGen ~= Fly.gen then break end
            local cam = workspace.CurrentCamera
            if not cam or not BV.Parent then break end
            if not T.Parent then
                local nt = getRootPart(plr.Character)
                if nt then T = nt; BG.Parent = T; BV.Parent = T end
            end
            if not hum.Parent then hum = plr.Character and plr.Character:FindFirstChildOfClass("Humanoid") or hum end
            if hum and hum.Parent and hum.PlatformStand ~= true then hum.PlatformStand = true end

            local fB, lR, qE = 0, 0, 0
            if not UserInputService:GetFocusedTextBox() then
                if UserInputService:IsKeyDown(Enum.KeyCode.W) then fB = fB + 1 end
                if UserInputService:IsKeyDown(Enum.KeyCode.S) then fB = fB - 1 end
                if UserInputService:IsKeyDown(Enum.KeyCode.D) then lR = lR + 1 end
                if UserInputService:IsKeyDown(Enum.KeyCode.A) then lR = lR - 1 end
                if Fly.qe then
                    if UserInputService:IsKeyDown(Enum.KeyCode.E) then qE = qE + 1 end
                    if UserInputService:IsKeyDown(Enum.KeyCode.Q) then qE = qE - 1 end
                end
                if UserInputService:IsKeyDown(Enum.KeyCode.Space) then qE = qE + 1 end
                if UserInputService:IsKeyDown(Enum.KeyCode.LeftControl) or UserInputService:IsKeyDown(Enum.KeyCode.RightControl) then
                    qE = qE - 1
                end
            end
            local camCF = cam.CFrame
            local dir = Vector3.zero
            if Superfly.on and Fly.mouseHeld then dir = dir + camCF.LookVector end
            dir = dir + camCF.LookVector * fB + camCF.RightVector * lR + Vector3.yAxis * qE
            local hasInput = dir.Magnitude > 0.05
            local target = hasInput and dir.Unit * (Fly.speed * 50) or Vector3.zero
            smooth = smooth:Lerp(target, 1 - math.exp(-dt * (hasInput and 9 or 3.5)))
            if not hasInput then smooth = Vector3.zero end
            BV.Velocity = smooth
            if not hasInput and T.Parent and T.AssemblyLinearVelocity.Magnitude > 0 then
                T.AssemblyLinearVelocity = Vector3.zero
            end
            BG.CFrame = BG.CFrame:Lerp(camCF, 1 - math.exp(-dt * 14))
        end
        local settleUntil = os.clock() + 0.08
        while os.clock() < settleUntil and BV.Parent and smooth.Magnitude > 4 do
            local dt = task.wait()
            smooth = smooth:Lerp(Vector3.zero, 1 - math.exp(-dt * 16))
            BV.Velocity = smooth
        end
        pcall(function() BG:Destroy() end)
        pcall(function() BV:Destroy() end)
        -- Fly.stop() bumps the generation and restores the humanoid itself; reaching here with
        -- the same generation means the loop ended on its own (root or movers removed)
        if myGen == Fly.gen then
            Fly.flying = false
            restoreFlyHumanoid(hum, T)
            if UIAPI.sync then UIAPI.sync() end
        end
    end)
end

-- Touch flight: the default ControlModule's move vector drives the velocity.
local function flyMobile(hum, root, myGen)
    local ok, controlModule = pcall(function()
        return require(plr:WaitForChild("PlayerScripts"):WaitForChild("PlayerModule", 5):WaitForChild("ControlModule", 5))
    end)
    if not ok or not controlModule then
        note("Fly", "Could not reach the touch controls", RED)
        Fly.flying = false
        return
    end
    make("BodyVelocity", { Name = FLY_VEL, MaxForce = Vector3.zero, Velocity = Vector3.zero }, root)
    make("BodyGyro", { Name = FLY_GYRO, MaxTorque = Vector3.new(9e9, 9e9, 9e9), P = 1000, D = 50 }, root)
    local smooth = Vector3.zero
    table.insert(Fly.conns, RunService.RenderStepped:Connect(function(dt)
        if myGen ~= Fly.gen then return end
        local r = getRootPart(plr.Character)
        local cam = workspace.CurrentCamera
        local h = plr.Character and plr.Character:FindFirstChildOfClass("Humanoid")
        local VH = r and r:FindFirstChild(FLY_VEL)
        local GH = r and r:FindFirstChild(FLY_GYRO)
        if not (h and VH and GH and cam) then return end
        VH.MaxForce = Vector3.new(9e9, 9e9, 9e9)
        if h.PlatformStand ~= true then h.PlatformStand = true end
        local spd = Fly.speed * 50
        local target, moving
        if Superfly.on then
            moving = Fly.mouseHeld
            target = moving and cam.CFrame.LookVector * spd or Vector3.zero
        else
            local d = controlModule:GetMoveVector()
            target = cam.CFrame.RightVector * (d.X * spd) - cam.CFrame.LookVector * (d.Z * spd)
            moving = d.Magnitude > 0.05
        end
        smooth = smooth:Lerp(target, 1 - math.exp(-dt * (moving and 9 or 3.5)))
        if not moving then smooth = Vector3.new(smooth.X, 0, smooth.Z) end
        VH.Velocity = smooth
        if not moving then
            local av = r.AssemblyLinearVelocity
            if av.Y ~= 0 then r.AssemblyLinearVelocity = Vector3.new(av.X, 0, av.Z) end
        end
        GH.CFrame = GH.CFrame:Lerp(cam.CFrame, 1 - math.exp(-dt * 14))
    end))
end

function Fly.start()
    Fly.stop(true)
    local char = plr.Character
    local hum = char and char:FindFirstChildOfClass("Humanoid")
    local root = getRootPart(char)
    if not (hum and root) then note("Fly", "No character", RED); return false end
    destroyFlyMovers(root)
    Fly.gen = Fly.gen + 1
    Fly.flying = true
    prepFlyHumanoid(hum)
    pcall(function()
        local cam = workspace.CurrentCamera
        if cam then cam.CameraType = Enum.CameraType.Custom end
    end)
    flyInputConns()
    if isMobile then flyMobile(hum, root, Fly.gen) else flyDesktop(hum, root, Fly.gen) end
    flyWatchDeath(hum)
    return true
end

-- keepModes: called from Fly.start, so superfly / helicopter state survives a restart.
function Fly.stop(keepModes)
    local was = Fly.flying
    Fly.flying = false
    Fly.gen = Fly.gen + 1
    for _, c in ipairs(Fly.conns) do disconnect(c) end
    Fly.conns = {}
    Fly.diedConn = disconnect(Fly.diedConn)
    Fly.mouseHeld = false
    if not keepModes then
        if Superfly then Superfly.off() end
        if Helicopter and Helicopter.on then Helicopter.stop(true) end
    end
    local char = plr.Character
    local root = getRootPart(char)
    destroyFlyMovers(root)
    if was then restoreFlyHumanoid(char and char:FindFirstChildOfClass("Humanoid"), root) end
end

------------------------------------------------------------------------
-- Superfly: hold the mouse (or the screen) to fly forward, with
-- state animations (novoline's ids).
------------------------------------------------------------------------

Superfly = {
    on = false, conn = nil, tracks = {}, current = nil, state = "", pending = "idle", pendingAt = 0, hum = nil,
    ids = {
        idle = 98353973763565, forward = 123269449592573, backward = 101457848070067,
        up = 102256275785620, down = 616108001,
    },
}

local function isTrack(t) return typeof(t) == "Instance" and t:IsA("AnimationTrack") end

local function loadLoopTrack(hum, id)
    local animator = hum:FindFirstChildOfClass("Animator") or make("Animator", {}, hum)
    local ok, played, tr = pcall(function() return hum:PlayEmoteAndGetAnimTrackById(id) end)
    if ok and played and isTrack(tr) then
        pcall(function()
            tr:Stop(0)
            tr.Priority = Enum.AnimationPriority.Action4
            tr.Looped = true
        end)
        return tr
    end
    local a = Instance.new("Animation")
    a.AnimationId = resolveAnimationId("rbxassetid://" .. tostring(id))
    local ok2, t2 = pcall(function() return animator:LoadAnimation(a) end)
    if ok2 and isTrack(t2) then
        t2.Priority = Enum.AnimationPriority.Action4
        t2.Looped = true
        return t2
    end
    return nil
end

function Superfly.stopTracks()
    Superfly.conn = disconnect(Superfly.conn)
    for _, tr in pairs(Superfly.tracks) do pcall(function() tr:Stop(0.15) end) end
    Superfly.tracks, Superfly.current, Superfly.hum, Superfly.state = {}, nil, nil, ""
    Superfly.pending, Superfly.pendingAt = "idle", 0
end

local function sfTrack(hum, state)
    if Superfly.hum ~= hum then Superfly.stopTracks(); Superfly.hum = hum end
    local t = Superfly.tracks[state]
    if isTrack(t) then return t end
    t = loadLoopTrack(hum, Superfly.ids[state] or Superfly.ids.idle)
    if not t and state ~= "idle" then
        t = Superfly.tracks.idle or loadLoopTrack(hum, Superfly.ids.idle)
    end
    if isTrack(t) then Superfly.tracks[state] = t end
    return t
end

local function sfStep()
    if not Superfly.on or not Fly.flying then return end
    local char = plr.Character
    local hum = char and char:FindFirstChildOfClass("Humanoid")
    local root = getRootPart(char)
    if not (hum and root) then return end
    local lv = root.CFrame:VectorToObjectSpace(root.AssemblyLinearVelocity)
    local hspd = math.sqrt(lv.X * lv.X + lv.Z * lv.Z)
    local thresh = math.max(10, Fly.speed * 50 * 0.4)
    local state = "idle"
    if math.abs(lv.Y) > thresh and math.abs(lv.Y) >= hspd * 0.9 then
        state = lv.Y > 0 and "up" or "down"
    elseif hspd > thresh then
        state = lv.Z > 0 and "backward" or "forward"
    end
    local now = os.clock()
    if Superfly.pending ~= state then Superfly.pending, Superfly.pendingAt = state, now end
    local holdFor = state == "idle" and 0.05 or 0.12
    if state ~= Superfly.state and now - Superfly.pendingAt < holdFor then state = Superfly.state end
    if state == "" then state = "idle" end
    local want = sfTrack(hum, state)
    if not isTrack(want) then return end
    local fade = state == "idle" and 0.14 or 0.3
    if Superfly.current ~= want then
        if isTrack(Superfly.current) and Superfly.current.IsPlaying then pcall(function() Superfly.current:Stop(fade) end) end
        pcall(function() want:Play(fade, 1, 1) end)
        Superfly.current, Superfly.state = want, state
    elseif not want.IsPlaying then
        pcall(function() want:Play(fade, 1, 1) end)
    end
end

function Superfly.set(on)
    if on then
        if not Fly.start() then return false end
        Superfly.on = true
        Superfly.conn = disconnect(Superfly.conn)
        Superfly.conn = RunService.RenderStepped:Connect(sfStep)
        return true
    end
    Fly.stop()
    return true
end

function Superfly.off()
    Superfly.on = false
    Superfly.stopTracks()
end

------------------------------------------------------------------------
-- Helicopter: fly + spinning animation + rotor sound (novoline's ids)
------------------------------------------------------------------------

Helicopter = { on = false, track = nil, sound = nil, diedConn = nil }
local HELI_ANIM, HELI_SOUND = "129132611803602", "99103708154004"

function Helicopter.stop(keepFly)
    Helicopter.on = false
    Helicopter.diedConn = disconnect(Helicopter.diedConn)
    if Helicopter.track then pcall(function() Helicopter.track:Stop(0) end); Helicopter.track = nil end
    if Helicopter.sound then pcall(function() Helicopter.sound:Stop(); Helicopter.sound:Destroy() end); Helicopter.sound = nil end
    if not keepFly then Fly.stop(true) end
end

function Helicopter.start()
    local char = plr.Character
    local hum = char and char:FindFirstChildOfClass("Humanoid")
    local root = getRootPart(char)
    if not (hum and root) then note("Helicopter", "No character", RED); return false end
    Helicopter.stop(true)
    if not Fly.start() then return false end
    Helicopter.on = true
    local animator = hum:FindFirstChildOfClass("Animator") or make("Animator", {}, hum)
    local a = Instance.new("Animation")
    a.AnimationId = resolveAnimationId("rbxassetid://" .. HELI_ANIM)
    local ok, track = pcall(function() return animator:LoadAnimation(a) end)
    if ok and track then
        Helicopter.track = track
        track.Priority = Enum.AnimationPriority.Action4
        track.Looped = true
        pcall(function() track:Play(0.1, 1, 1) end)
    end
    Helicopter.sound = make("Sound", {
        Name = "PuppyAdminHelicopter", SoundId = "rbxassetid://" .. HELI_SOUND, Volume = 0.35,
        Looped = true, RollOffMode = Enum.RollOffMode.InverseTapered,
    }, root)
    pcall(function() Helicopter.sound:Play() end)
    Helicopter.diedConn = hum.Died:Connect(function() Helicopter.stop(false) end)
    return true
end

------------------------------------------------------------------------
-- HatFly: your hats fly while the body is parked under the map
------------------------------------------------------------------------

HatFly = { active = false, conns = {}, vel = Vector3.zero }

function HatFly.stop()
    if not HatFly.active and not HatFly.plate then return end
    HatFly.active = false
    for _, c in ipairs(HatFly.conns) do disconnect(c) end
    HatFly.conns = {}
    for _, fp in ipairs(HatFly.parts or {}) do
        if fp.part and fp.part.Parent then pcall(function() fp.part:Destroy() end) end
    end
    if HatFly.plate then pcall(function() HatFly.plate:Destroy() end) end
    for _, sh in ipairs(HatFly.src or {}) do
        if sh.Parent then pcall(function() sh.LocalTransparencyModifier = 0 end) end
    end
    local root, hum = HatFly.root, HatFly.hum
    if root and root.Parent then
        pcall(function()
            root.AssemblyLinearVelocity = Vector3.zero
            root.AssemblyAngularVelocity = Vector3.zero
            if HatFly.savedCF then root.CFrame = HatFly.savedCF end
        end)
    end
    if hum and hum.Parent then pcall(function() hum.PlatformStand = false end) end
    pcall(function()
        local cam = workspace.CurrentCamera
        if cam and HatFly.camType then cam.CameraType = HatFly.camType end
        if cam and HatFly.camSubject and HatFly.camSubject.Parent then cam.CameraSubject = HatFly.camSubject end
    end)
    HatFly.parts, HatFly.src, HatFly.plate, HatFly.flyHat = nil, nil, nil, nil
    HatFly.root, HatFly.hum, HatFly.savedCF, HatFly.camType, HatFly.camSubject = nil, nil, nil, nil, nil
    HatFly.vel, HatFly.pos = Vector3.zero, nil
end

function HatFly.start()
    HatFly.stop()
    local char = plr.Character
    local hum = char and char:FindFirstChildOfClass("Humanoid")
    local root = getRootPart(char)
    if not (hum and root) then return false, "Character not ready" end
    local src = {}
    for _, v in ipairs(char:GetChildren()) do
        if v:IsA("Accessory") then
            local h = v:FindFirstChild("Handle")
            if h and h:IsA("BasePart") then table.insert(src, h) end
        end
    end
    if #src == 0 then return false, "No accessory handle found" end
    -- novoline parks at Y -4500; parts below FallenPartsDestroyHeight get deleted,
    -- so stay just above that limit when the game's limit is higher.
    local parkY = -4500
    pcall(function() parkY = math.max(parkY, workspace.FallenPartsDestroyHeight + 25) end)
    local plate = make("Part", {
        Name = "PuppyAdminHatFlyPlate", Anchored = true, CanCollide = true, CanTouch = false, CanQuery = false,
        CastShadow = false, Material = Enum.Material.SmoothPlastic, Color = Color3.fromRGB(30, 30, 34),
        Transparency = 0.45, Size = Vector3.new(220, 1, 220),
        CFrame = CFrame.new(root.Position.X, parkY, root.Position.Z),
    }, workspace)
    local primary = src[1]
    local primaryCF = primary.CFrame
    local function cleanClone(s)
        local c = s:Clone()
        c.Anchored, c.CanCollide, c.CanTouch, c.CanQuery, c.Massless = true, false, false, false, true
        for _, w in ipairs(c:GetDescendants()) do
            if w:IsA("JointInstance") or w:IsA("WeldConstraint") then w:Destroy() end
        end
        c.Name = "PuppyAdminHatFly"
        return c
    end
    local parts, flyHat = {}, nil
    for _, s in ipairs(src) do
        local c = cleanClone(s)
        c.CFrame = s.CFrame
        c.Parent = workspace
        if s == primary then flyHat = c end
        table.insert(parts, { part = c, offset = primaryCF:ToObjectSpace(s.CFrame) })
    end
    HatFly.active, HatFly.root, HatFly.hum, HatFly.src = true, root, hum, src
    HatFly.parts, HatFly.flyHat, HatFly.plate, HatFly.savedCF = parts, flyHat, plate, root.CFrame
    HatFly.pos, HatFly.vel = primaryCF.Position, Vector3.zero
    pcall(function()
        local cam = workspace.CurrentCamera
        HatFly.camType, HatFly.camSubject = cam.CameraType, cam.CameraSubject
        cam.CameraType = Enum.CameraType.Custom
        cam.CameraSubject = flyHat
    end)
    for _, s in ipairs(src) do pcall(function() s.LocalTransparencyModifier = 1 end) end
    pcall(function()
        if hum.SeatPart then hum.Sit = false end
        hum.PlatformStand = true
        root.CFrame = plate.CFrame + Vector3.new(0, 6, 0)
        root.AssemblyLinearVelocity = Vector3.zero
    end)
    table.insert(HatFly.conns, RunService.Heartbeat:Connect(function(dt)
        if not HatFly.active or not flyHat.Parent then return end
        local cam = workspace.CurrentCamera
        if not cam then return end
        if cam.CameraSubject ~= flyHat then pcall(function() cam.CameraType = Enum.CameraType.Custom; cam.CameraSubject = flyHat end) end
        local f, s, v = 0, 0, 0
        if not UserInputService:GetFocusedTextBox() then
            if UserInputService:IsKeyDown(Enum.KeyCode.W) then f = f + 1 end
            if UserInputService:IsKeyDown(Enum.KeyCode.S) then f = f - 1 end
            if UserInputService:IsKeyDown(Enum.KeyCode.D) then s = s + 1 end
            if UserInputService:IsKeyDown(Enum.KeyCode.A) then s = s - 1 end
            if UserInputService:IsKeyDown(Enum.KeyCode.E) or UserInputService:IsKeyDown(Enum.KeyCode.Space) then v = v + 1 end
            if UserInputService:IsKeyDown(Enum.KeyCode.Q) or UserInputService:IsKeyDown(Enum.KeyCode.LeftControl)
                or UserInputService:IsKeyDown(Enum.KeyCode.RightControl) then v = v - 1 end
        end
        local look, right = cam.CFrame.LookVector, cam.CFrame.RightVector
        local lookH = Vector3.new(look.X, 0, look.Z)
        lookH = lookH.Magnitude > 0.001 and lookH.Unit or Vector3.new(0, 0, -1)
        local rightH = Vector3.new(right.X, 0, right.Z)
        rightH = rightH.Magnitude > 0.001 and rightH.Unit or Vector3.new(1, 0, 0)
        local want = lookH * f + rightH * s + Vector3.new(0, v, 0)
        want = want.Magnitude > 0 and want.Unit * (math.max(Fly.speed, 0.5) * 85) or Vector3.zero
        if v == 0 then want = Vector3.new(want.X, 0, want.Z) end
        HatFly.vel = HatFly.vel + (want - HatFly.vel) * (want.Magnitude > 0 and 0.26 or 0.08)
        if v == 0 then HatFly.vel = Vector3.new(HatFly.vel.X, 0, HatFly.vel.Z) end
        HatFly.pos = HatFly.pos + HatFly.vel * math.max(dt, 0.016)
        local pcf = CFrame.new(HatFly.pos, HatFly.pos + look)
        for _, fp in ipairs(parts) do
            if fp.part.Parent then fp.part.CFrame = pcf * fp.offset end
        end
        if root.Parent and plate.Parent then
            root.CFrame = plate.CFrame + Vector3.new(0, 6, 0)
            root.AssemblyLinearVelocity = Vector3.zero
            root.AssemblyAngularVelocity = Vector3.zero
        end
    end))
    return true
end

------------------------------------------------------------------------
-- Noclip (novoline _mv.setNoclip: reference-counted holds)
------------------------------------------------------------------------

Noclip = { holds = {}, on = false, conn = nil, cache = {}, was = {}, cacheConns = {}, charConn = nil }

local function noclipRebuild()
    for _, c in ipairs(Noclip.cacheConns) do disconnect(c) end
    Noclip.cacheConns, Noclip.cache = {}, {}
    local char = plr.Character
    if not char then return end
    for _, p in ipairs(char:GetDescendants()) do
        if p:IsA("BasePart") then Noclip.cache[p] = true end
    end
    table.insert(Noclip.cacheConns, char.DescendantAdded:Connect(function(d)
        if d:IsA("BasePart") then Noclip.cache[d] = true end
    end))
    table.insert(Noclip.cacheConns, char.DescendantRemoving:Connect(function(d)
        Noclip.cache[d] = nil
        if Noclip.was[d] then
            Noclip.was[d] = nil
            pcall(function() d.CanCollide = true end)
        end
    end))
end

local function noclipRestore()
    for p in pairs(Noclip.was) do
        if p.Parent then pcall(function() p.CanCollide = true end) end
    end
    Noclip.was = {}
end

function Noclip.set(key, on)
    Noclip.holds[key] = on and true or nil
    Noclip.on = next(Noclip.holds) ~= nil
    if Noclip.on then
        if not Noclip.conn then
            noclipRebuild()
            Noclip.charConn = plr:GetPropertyChangedSignal("Character"):Connect(function()
                noclipRestore()
                noclipRebuild()
            end)
            Noclip.conn = RunService.Stepped:Connect(function()
                for p in pairs(Noclip.cache) do
                    if p.Parent and p.CanCollide then
                        Noclip.was[p] = true
                        p.CanCollide = false
                    end
                end
            end)
        end
        return
    end
    Noclip.conn = disconnect(Noclip.conn)
    Noclip.charConn = disconnect(Noclip.charConn)
    for _, c in ipairs(Noclip.cacheConns) do disconnect(c) end
    Noclip.cacheConns, Noclip.cache = {}, {}
    noclipRestore()
end

------------------------------------------------------------------------
-- Airwalk: an invisible platform follows under your feet; hold Space to rise
------------------------------------------------------------------------

Airwalk = { conn = nil, jumpConn = nil, part = nil, floorY = nil, holdUp = false }

function Airwalk.stop()
    Airwalk.conn = disconnect(Airwalk.conn)
    Airwalk.jumpConn = disconnect(Airwalk.jumpConn)
    Airwalk.holdUp, Airwalk.floorY = false, nil
    if Airwalk.part then pcall(function() Airwalk.part:Destroy() end); Airwalk.part = nil end
    local hum = plr.Character and plr.Character:FindFirstChildOfClass("Humanoid")
    if hum then pcall(function() hum:SetStateEnabled(Enum.HumanoidStateType.Freefall, true) end) end
end

local function airwalkPart()
    if Airwalk.part and Airwalk.part.Parent then return Airwalk.part end
    Airwalk.part = make("Part", {
        Name = "PuppyAdminAirwalk", Size = Vector3.new(12, 1, 12), Transparency = 1, Anchored = true,
        CanCollide = true, CanQuery = false, CanTouch = false, CastShadow = false, Massless = true,
    }, workspace)
    return Airwalk.part
end

local function airwalkFootOffset(hum, root, part)
    local hip = 0
    pcall(function() hip = hum and hum.HipHeight or 0 end)
    local rootH, partH = 2, 1
    pcall(function() rootH = root.Size.Y end)
    pcall(function() partH = part.Size.Y end)
    return hip + rootH * 0.5 + partH * 0.5
end

function Airwalk.start()
    if Airwalk.conn then return false end
    Airwalk.holdUp = false
    Airwalk.jumpConn = UserInputService.JumpRequest:Connect(function() Airwalk.holdUp = true end)
    Airwalk.conn = RunService.Heartbeat:Connect(function(dt)
        local char = plr.Character
        local hum = char and char:FindFirstChildOfClass("Humanoid")
        local root = getRootPart(char)
        if not root then return end
        local part = airwalkPart()
        local off = airwalkFootOffset(hum, root, part)
        local pos = root.Position
        if type(Airwalk.floorY) ~= "number" or pos.Y < Airwalk.floorY - 8 then Airwalk.floorY = pos.Y - off end
        local up = Airwalk.holdUp
        Airwalk.holdUp = false
        if not UserInputService:GetFocusedTextBox() and UserInputService:IsKeyDown(Enum.KeyCode.Space) then up = true end
        if up then Airwalk.floorY = Airwalk.floorY + 24 * dt end
        part.CFrame = CFrame.new(pos.X, Airwalk.floorY, pos.Z)
    end)
    return true
end

------------------------------------------------------------------------
-- Swim: zero gravity, every humanoid state but Swimming disabled
------------------------------------------------------------------------

Swim = { on = false, conn = nil, gravity = nil, hum = nil }

local function swimStates(hum, enabled)
    for _, st in ipairs(Enum.HumanoidStateType:GetEnumItems()) do
        if st ~= Enum.HumanoidStateType.None then
            pcall(function() hum:SetStateEnabled(st, enabled) end)
        end
    end
end

function Swim.start()
    if Swim.on then return false end
    local hum = plr.Character and plr.Character:FindFirstChildOfClass("Humanoid")
    if not hum then return false end
    Swim.gravity = workspace.Gravity
    workspace.Gravity = 0
    swimStates(hum, false)
    pcall(function() hum:ChangeState(Enum.HumanoidStateType.Swimming) end)
    Swim.hum = hum
    Swim.conn = RunService.Heartbeat:Connect(function()
        local root = getRootPart(plr.Character)
        if root and hum.MoveDirection == Vector3.zero and not UserInputService:IsKeyDown(Enum.KeyCode.Space) then
            root.AssemblyLinearVelocity = Vector3.zero
        end
    end)
    Swim.on = true
    return true
end

function Swim.stop()
    if not Swim.on then return end
    Swim.on = false
    workspace.Gravity = Swim.gravity or 196.2
    Swim.conn = disconnect(Swim.conn)
    if Swim.hum and Swim.hum.Parent then swimStates(Swim.hum, true) end
    Swim.hum = nil
end

------------------------------------------------------------------------
-- Infinite baseplate: 2000x2000 tiles spawned around you at floor height
------------------------------------------------------------------------

Baseplate = {
    enabled = false, folder = nil, grid = {}, gen = 0, top = nil,
    kind = "default", material = Enum.Material.SmoothPlastic, textureId = "", studs = 8, presetIndex = 1,
}

BASEPLATE_PRESETS = {
    { name = "Default" },
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
        part.Material, part.Color, part.Transparency = Baseplate.material, Color3.new(1, 1, 1), 0
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
    elseif p.texture then
        Baseplate.kind, Baseplate.textureId, Baseplate.studs = "texture", p.texture, 8
    else
        Baseplate.kind = "default"
    end
    bpApplyAll()
end

-- Downloads an image URL to the workspace folder and loads it as a custom asset.
local function bpUrlAsset(url)
    local getAsset = (type(getcustomasset) == "function" and getcustomasset) or (type(getsynasset) == "function" and getsynasset)
    if not getAsset then return nil end
    local h = 0
    for i = 1, #url do h = (h * 33 + string.byte(url, i)) % 2147483647 end
    local ext = (url:gsub("[?#].*$", ""):match("%.(%w+)$") or "png"):lower()
    if not ({ png = true, jpg = true, jpeg = true, webp = true, gif = true, bmp = true })[ext] then ext = "png" end
    local file = "PuppyAdmin/floor_" .. tostring(h) .. "." .. ext
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

-- Accepts rbxasset(s), rbxassetid://, a bare id, a roblox.com link, or an image URL.
function Baseplate.useCustom(raw)
    local s = tostring(raw or ""):match("^%s*(.-)%s*$") or ""
    if s == "" then return false, "Enter a texture" end
    local tex
    local user, repo, rest = s:match("^https://github%.com/([^/]+)/([^/]+)/blob/(.+)$")
    if user then s = "https://raw.githubusercontent.com/" .. user .. "/" .. repo .. "/" .. rest end
    if s:find("^rbxasset") or s:find("^rbxthumb") then
        tex = s
    elseif s:match("^%d+$") then
        tex = "rbxassetid://" .. s
    elseif s:find("roblox%.com") then
        local id = s:match("(%d+)")
        tex = id and ("rbxassetid://" .. id)
    elseif s:find("^https?://") then
        tex = bpUrlAsset(s)
        if not tex then return false, "Download failed (needs getcustomasset + writefile)" end
    end
    if not tex then return false, "Not a texture id, asset or image URL" end
    Baseplate.kind, Baseplate.textureId = "texture", tex
    bpApplyAll()
    return true
end

------------------------------------------------------------------------
-- ESP (novoline visuals: highlight + name/health/distance pill, chams,
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
    pcall(HatFly.stop)
    pcall(Helicopter.stop, true)
    pcall(Fly.stop)
    pcall(Airwalk.stop)
    pcall(Swim.stop)
    pcall(Baseplate.stop)
    Noclip.holds = {}
    pcall(Noclip.set, "user", false)
    Esp.mode, Esp.hitboxes, Esp.tracers = "off", false, false
    pcall(espStopIfIdle)
end)
end

------------------------------------------------------------------------
-- Anti VC ban (VC Bypasser panel, opened with `antivcban`)
------------------------------------------------------------------------

-- Ported from vcBypass_standalone.lua. Built on the first `antivcban`, in its
-- own function so its locals do not count against the main chunk's limit.
local VCB = { conns = {} }

function VCB.build()
local LocalPlayer = plr
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")
local GuiService = game:GetService("GuiService")
local function track(c)
	table.insert(VCB.conns, c)
	return c
end

-- Optional executor globals: fall back to safe no-ops when absent.
local clonerefFn = (type(cloneref) == "function") and cloneref or function(instance)
	return instance
end
local getconnectionsFn = (type(getconnections) == "function") and getconnections or nil
local gethuiFn = (type(gethui) == "function") and gethui or nil

-- Some services are protected; never hard-error on them.
local function softService(name)
	local ok, service = pcall(function()
		return game:GetService(name)
	end)
	if ok then
		return service
	end
	return nil
end

local isMobile = UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled

---------------------------------------------------------------------
-- 1.  Style tokens
---------------------------------------------------------------------
local S = {
	QUICK = TweenInfo.new(0.16, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
	SOFT = TweenInfo.new(0.30, Enum.EasingStyle.Quint, Enum.EasingDirection.Out),

	WHITE = Color3.fromRGB(255, 255, 255),
	INK = Color3.fromRGB(12, 14, 18),
	TEXT = Color3.fromRGB(236, 240, 248),
	SUBTLE = Color3.fromRGB(146, 154, 172),
	ACTION = Color3.fromRGB(96, 148, 255),
	DANGER = Color3.fromRGB(255, 96, 102),
	PANEL = Color3.fromRGB(22, 24, 31),
	BTN = Color3.fromRGB(40, 44, 55),

	TINT = {
		teal = { Color3.fromRGB(24, 78, 68), Color3.fromRGB(96, 240, 196) },
		gray = { Color3.fromRGB(48, 52, 64), Color3.fromRGB(214, 220, 232) },
		red = { Color3.fromRGB(78, 28, 34), Color3.fromRGB(255, 112, 118) },
	},
}

local ICON_IMAGES = {
	mic = "rbxasset://textures/ui/VoiceChat/MicLight/Talking0.png",
	micoff = "rbxasset://textures/ui/VoiceChat/MicLight/Muted.png",
}

---------------------------------------------------------------------
-- 2.  Tiny UI toolkit
---------------------------------------------------------------------
local function create(className, props)
	local instance = Instance.new(className)
	local parent = nil
	for key, value in pairs(props or {}) do
		if key == "Parent" then
			parent = value
		elseif key == "Icon" then
			instance:SetAttribute("NvIcon", value)
			if ICON_IMAGES[value] then
				instance.Image = ICON_IMAGES[value]
			end
		else
			instance[key] = value
		end
	end
	if parent then
		instance.Parent = parent
	end
	return instance
end

local function tween(instance, info, goals)
	if not instance then
		return nil
	end
	local anim = TweenService:Create(instance, info or S.QUICK, goals)
	anim:Play()
	return anim
end

local function round(instance, radius)
	return create("UICorner", {
		Parent = instance,
		CornerRadius = typeof(radius) == "UDim" and radius or UDim.new(0, radius or 10),
	})
end

local function rim(instance, transparency, thickness)
	return create("UIStroke", {
		Parent = instance,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
		Color = S.WHITE,
		Transparency = transparency or 0.9,
		Thickness = thickness or 1,
	})
end

local function setIcon(label, name)
	if not label then
		return
	end
	label:SetAttribute("NvIcon", name)
	if ICON_IMAGES[name] then
		label.Image = ICON_IMAGES[name]
	end
end

-- Draw a crisp X without relying on font glyph coverage.
local function xGlyph(parent, colour)
	local a = create("Frame", {
		Parent = parent,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(0.5, 0, 0.5, 0),
		Size = UDim2.fromOffset(10, 2),
		BackgroundColor3 = colour,
		BorderSizePixel = 0,
		Rotation = 45,
	})
	local b = create("Frame", {
		Parent = parent,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(0.5, 0, 0.5, 0),
		Size = UDim2.fromOffset(10, 2),
		BackgroundColor3 = colour,
		BorderSizePixel = 0,
		Rotation = -45,
	})
	round(a, 1)
	round(b, 1)
	return a, b
end

---------------------------------------------------------------------
-- 3.  GUI container (CoreGui when permitted, PlayerGui otherwise)
---------------------------------------------------------------------
local function resolveGuiRoot()
	if gethuiFn then
		local ok, result = pcall(gethuiFn)
		if ok and typeof(result) == "Instance" then
			return result
		end
	end

	local coreGui = softService("CoreGui")
	if coreGui then
		local probe = Instance.new("Folder")
		probe.Name = "VCB_Probe"
		local parented = pcall(function()
			probe.Parent = coreGui
		end)
		probe:Destroy()
		if parented then
			return coreGui
		end
	end

	return PlayerGui
end

local guiRoot = resolveGuiRoot()

local function attach(instance, preferred)
	local ok = pcall(function()
		instance.Parent = preferred or guiRoot
	end)
	if not ok then
		pcall(function()
			instance.Parent = PlayerGui
		end)
	end
	return instance
end

---------------------------------------------------------------------
-- 3b. Executor re-run safety: drop anything a previous run left behind
---------------------------------------------------------------------
local PREVIOUS_UI = { "VCBypass", "VCB_Toasts", "VCB_MicToggleGUI", "CustomVoiceController" }
for _, container in ipairs({ guiRoot, PlayerGui }) do
	if container then
		pcall(function()
			for _, name in ipairs(PREVIOUS_UI) do
				local stale = container:FindFirstChild(name)
				if stale then
					stale:Destroy()
				end
			end
		end)
	end
end

---------------------------------------------------------------------
-- 4.  Toasts (replacement for the host's notify helper)
---------------------------------------------------------------------
local toastGui = create("ScreenGui", {
	Name = "VCB_Toasts",
	ResetOnSpawn = false,
	IgnoreGuiInset = true,
	DisplayOrder = 240,
	ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
})
attach(toastGui)

local toastStack = create("Frame", {
	Parent = toastGui,
	Name = "Stack",
	AnchorPoint = Vector2.new(0.5, 1),
	Position = UDim2.new(0.5, 0, 1, -18),
	Size = UDim2.new(0, 300, 0, 0),
	BackgroundTransparency = 1,
})
create("UIListLayout", {
	Parent = toastStack,
	Padding = UDim.new(0, 8),
	SortOrder = Enum.SortOrder.LayoutOrder,
	HorizontalAlignment = Enum.HorizontalAlignment.Center,
	VerticalAlignment = Enum.VerticalAlignment.Bottom,
})

local toastIndex = 0

local function notify(title, body, duration)
	duration = tonumber(duration) or 3
	body = tostring(body or "")
	title = tostring(title or "")

	toastIndex = toastIndex + 1
	local height = (body ~= "" and 56) or 38

	local card = create("Frame", {
		Parent = toastStack,
		LayoutOrder = toastIndex,
		Size = UDim2.new(1, 0, 0, height),
		BackgroundColor3 = S.PANEL,
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
	})
	round(card, 10)
	local stroke = rim(card, 1, 1)

	local accent = create("Frame", {
		Parent = card,
		Size = UDim2.new(0, 3, 1, -16),
		Position = UDim2.new(0, 7, 0, 8),
		BackgroundColor3 = S.ACTION,
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
	})
	round(accent, UDim.new(1, 0))

	local headline = create("TextLabel", {
		Parent = card,
		BackgroundTransparency = 1,
		Position = UDim2.new(0, 18, 0, body ~= "" and 9 or 0),
		Size = UDim2.new(1, -30, 0, body ~= "" and 14 or height),
		Font = Enum.Font.GothamBold,
		TextSize = 12,
		Text = title,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextColor3 = S.WHITE,
		TextTransparency = 1,
	})

	local detail
	if body ~= "" then
		detail = create("TextLabel", {
			Parent = card,
			BackgroundTransparency = 1,
			Position = UDim2.new(0, 18, 0, 25),
			Size = UDim2.new(1, -30, 0, 24),
			Font = Enum.Font.GothamMedium,
			TextSize = 11,
			Text = body,
			TextWrapped = true,
			TextTruncate = Enum.TextTruncate.AtEnd,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextYAlignment = Enum.TextYAlignment.Top,
			TextColor3 = S.SUBTLE,
			TextTransparency = 1,
		})
	end

	tween(card, S.SOFT, { BackgroundTransparency = 0.06 })
	tween(accent, S.SOFT, { BackgroundTransparency = 0 })
	tween(headline, S.SOFT, { TextTransparency = 0 })
	if detail then
		tween(detail, S.SOFT, { TextTransparency = 0 })
	end

	task.delay(duration, function()
		if not card.Parent then
			return
		end
		tween(card, S.SOFT, { BackgroundTransparency = 1 })
		tween(accent, S.SOFT, { BackgroundTransparency = 1 })
		tween(headline, S.SOFT, { TextTransparency = 1 })
		if detail then
			tween(detail, S.SOFT, { TextTransparency = 1 })
		end
		task.delay(0.35, function()
			card:Destroy()
		end)
	end)
end

---------------------------------------------------------------------
-- 5.  Panel shell
---------------------------------------------------------------------
local VCB_W = isMobile and 280 or 260
local VCB_H = 170
local VCB_PAD = 18
local VCB_BTN_H = 36
local VCB_MIC_W = VCB_BTN_H

local panelGui = create("ScreenGui", {
	Name = "VCBypass",
	ResetOnSpawn = false,
	IgnoreGuiInset = true,
	DisplayOrder = 180,
	ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
})
attach(panelGui)

local panel = create("Frame", {
	Parent = panelGui,
	Name = "VCBypassPanel",
	AnchorPoint = Vector2.new(0.5, 0),
	Position = UDim2.new(0.5, 0, 0, 60),
	Size = UDim2.fromOffset(VCB_W, VCB_H),
	BackgroundColor3 = S.PANEL,
	BorderSizePixel = 0,
	Active = true,
	ZIndex = 150,
})
round(panel, 14)
rim(panel, 0.86, 1)

local panelShade = create("UIGradient", {
	Parent = panel,
	Rotation = 90,
	Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.35),
		NumberSequenceKeypoint.new(1, 0.72),
	}),
	Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(54, 62, 84)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(16, 18, 24)),
	}),
})

create("UIScale", { Parent = panel })

---------------------------------------------------------------------
-- 6.  Title bar: title, close button, drag
---------------------------------------------------------------------
local titleBar = create("Frame", {
	Parent = panel,
	Name = "TitleBar",
	Size = UDim2.new(1, 0, 0, 34),
	BackgroundTransparency = 1,
	ZIndex = 151,
})

local dot = create("Frame", {
	Parent = titleBar,
	AnchorPoint = Vector2.new(0, 0.5),
	Position = UDim2.new(0, VCB_PAD, 0.5, 0),
	Size = UDim2.fromOffset(6, 6),
	BackgroundColor3 = S.ACTION,
	BorderSizePixel = 0,
	ZIndex = 152,
})
round(dot, UDim.new(1, 0))

create("TextLabel", {
	Parent = titleBar,
	Position = UDim2.new(0, VCB_PAD + 14, 0, 0),
	Size = UDim2.new(1, -80, 1, 0),
	BackgroundTransparency = 1,
	Font = Enum.Font.GothamBold,
	TextSize = 12,
	Text = "VC BYPASSER",
	TextXAlignment = Enum.TextXAlignment.Left,
	TextColor3 = S.WHITE,
	ZIndex = 152,
})

local closeBtn = create("TextButton", {
	Parent = titleBar,
	Name = "Close",
	AnchorPoint = Vector2.new(1, 0.5),
	Position = UDim2.new(1, -12, 0.5, 0),
	Size = UDim2.fromOffset(24, 24),
	BackgroundColor3 = S.TINT.gray[1],
	BackgroundTransparency = 0.35,
	BorderSizePixel = 0,
	Text = "",
	AutoButtonColor = false,
	ZIndex = 153,
})
round(closeBtn, 8)
rim(closeBtn, 0.9, 1)
xGlyph(closeBtn, S.TEXT)

local function makeDraggable(frame, handle)
	local dragging = false
	local dragStart, startPos, moveConn, releaseConn

	handle.InputBegan:Connect(function(input)
		if input.UserInputType ~= Enum.UserInputType.MouseButton1
			and input.UserInputType ~= Enum.UserInputType.Touch then
			return
		end

		dragging = true
		dragStart = input.Position
		startPos = frame.Position

		moveConn = track(UserInputService.InputChanged:Connect(function(change)
			if not dragging then
				return
			end
			if change.UserInputType ~= Enum.UserInputType.MouseMovement
				and change.UserInputType ~= Enum.UserInputType.Touch then
				return
			end
			local delta = change.Position - dragStart
			frame.Position = UDim2.new(
				startPos.X.Scale,
				startPos.X.Offset + delta.X,
				startPos.Y.Scale,
				startPos.Y.Offset + delta.Y
			)
		end))

		releaseConn = track(UserInputService.InputEnded:Connect(function(ended)
			if ended.UserInputType ~= Enum.UserInputType.MouseButton1
				and ended.UserInputType ~= Enum.UserInputType.Touch then
				return
			end
			dragging = false
			if moveConn then
				moveConn:Disconnect()
				moveConn = nil
			end
			if releaseConn then
				releaseConn:Disconnect()
				releaseConn = nil
			end
		end))
	end)
end

makeDraggable(panel, titleBar)

---------------------------------------------------------------------
-- 7.  Content
---------------------------------------------------------------------
local content = create("Frame", {
	Parent = panel,
	Name = "Content",
	BackgroundTransparency = 1,
	BorderSizePixel = 0,
	Position = UDim2.new(0, 0, 0, 34),
	Size = UDim2.new(1, 0, 1, -34),
	ZIndex = 151,
})

local SEG_H = 32
local SEG_Y = 14
local BTN_Y = SEG_Y + SEG_H + 10
local NOTE_Y = BTN_Y + VCB_BTN_H + 12

local version = 1
local VCB_NOTES = { "Not supported on Xeno or Solara", "Second VCB" }

-- Version segmented control -----------------------------------------
local seg = create("Frame", {
	Parent = content,
	Name = "Versions",
	Position = UDim2.new(0, VCB_PAD, 0, SEG_Y),
	Size = UDim2.new(1, -VCB_PAD * 2, 0, SEG_H),
	BackgroundColor3 = S.TINT.gray[1],
	BackgroundTransparency = 0.25,
	BorderSizePixel = 0,
	ZIndex = 152,
})
round(seg, 9)
rim(seg, 0.9, 1)

local segThumb = create("Frame", {
	Parent = seg,
	Name = "Thumb",
	Position = UDim2.new(0, 3, 0, 3),
	Size = UDim2.new(0.5, -4, 1, -6),
	BackgroundColor3 = S.WHITE,
	BorderSizePixel = 0,
	ZIndex = 153,
})
round(segThumb, 7)

local segButtons = {}
for index, label in ipairs({ "Bypass V1", "Bypass V2" }) do
	segButtons[index] = create("TextButton", {
		Parent = seg,
		Name = "V" .. index,
		Position = UDim2.new((index - 1) * 0.5, 0, 0, 0),
		Size = UDim2.new(0.5, 0, 1, 0),
		BackgroundTransparency = 1,
		AutoButtonColor = false,
		Font = Enum.Font.GothamBold,
		TextSize = 12,
		Text = label,
		TextColor3 = (index == 1) and S.INK or S.TEXT,
		ZIndex = 154,
	})
end

-- Execute button ----------------------------------------------------
local execBtn = create("TextButton", {
	Parent = content,
	Name = "Execute",
	Position = UDim2.new(0, VCB_PAD, 0, BTN_Y),
	Size = UDim2.new(1, -(VCB_PAD * 2 + VCB_MIC_W + 8), 0, VCB_BTN_H),
	BackgroundColor3 = S.BTN,
	BorderSizePixel = 0,
	AutoButtonColor = false,
	Font = Enum.Font.GothamBold,
	TextSize = 13,
	TextColor3 = S.TEXT,
	Text = "Execute Bypass",
	ZIndex = 152,
})
round(execBtn, 10)
rim(execBtn, 0.88, 1)

local function execTint(text)
	local lowered = string.lower(tostring(text or ""))
	if lowered == "bypassed" then
		return S.TINT.teal
	end
	if string.find(lowered, "bypassing", 1, true) then
		return S.TINT.gray
	end
	return nil
end

do
	local function applyTint()
		local tint = execTint(execBtn.Text)
		tween(execBtn, S.QUICK, { BackgroundColor3 = tint and tint[1] or S.BTN })
		execBtn.TextColor3 = tint and tint[2] or S.TEXT
	end
	execBtn:GetPropertyChangedSignal("Text"):Connect(applyTint)
	execBtn.MouseEnter:Connect(function()
		if execTint(execBtn.Text) then
			return
		end
		tween(execBtn, S.QUICK, { BackgroundColor3 = Color3.fromRGB(52, 58, 72) })
	end)
	execBtn.MouseLeave:Connect(function()
		if execTint(execBtn.Text) then
			return
		end
		tween(execBtn, S.QUICK, { BackgroundColor3 = S.BTN })
	end)
	execBtn.MouseButton1Down:Connect(function()
		tween(execBtn, S.QUICK, { Size = UDim2.new(1, -(VCB_PAD * 2 + VCB_MIC_W + 8), 0, VCB_BTN_H - 2) })
	end)
	execBtn.MouseButton1Up:Connect(function()
		tween(execBtn, S.QUICK, { Size = UDim2.new(1, -(VCB_PAD * 2 + VCB_MIC_W + 8), 0, VCB_BTN_H) })
	end)
end

-- Note line ---------------------------------------------------------
local note = create("TextLabel", {
	Parent = content,
	Name = "Note",
	Position = UDim2.new(0, VCB_PAD, 0, NOTE_Y),
	Size = UDim2.new(1, -VCB_PAD * 2, 0, 14),
	BackgroundTransparency = 1,
	Font = Enum.Font.GothamMedium,
	TextSize = 11,
	Text = VCB_NOTES[1],
	TextXAlignment = Enum.TextXAlignment.Left,
	TextTruncate = Enum.TextTruncate.AtEnd,
	TextColor3 = S.SUBTLE,
	ZIndex = 152,
})

-- Mic button (bottom right of the button row) -----------------------
local micBtn = create("TextButton", {
	Parent = content,
	Name = "MicToggle",
	Position = UDim2.new(1, -(VCB_PAD + VCB_MIC_W), 0, BTN_Y),
	Size = UDim2.fromOffset(VCB_MIC_W, VCB_BTN_H),
	BackgroundTransparency = 1,
	Text = "",
	AutoButtonColor = false,
	BorderSizePixel = 0,
	ZIndex = 152,
})
round(micBtn, UDim.new(1, 0))

local micFace = create("Frame", {
	Parent = micBtn,
	Name = "Face",
	Size = UDim2.fromScale(1, 1),
	BackgroundColor3 = S.TINT.gray[1],
	BorderSizePixel = 0,
	ZIndex = 152,
})
round(micFace, UDim.new(1, 0))
rim(micFace, 0.9, 1)

local micIcon = create("ImageLabel", {
	Parent = micBtn,
	Size = UDim2.fromOffset(18, 18),
	AnchorPoint = Vector2.new(0.5, 0.5),
	Position = UDim2.new(0.5, 0, 0.5, 0),
	BackgroundTransparency = 1,
	Icon = "mic",
	ImageColor3 = S.WHITE,
	ScaleType = Enum.ScaleType.Fit,
	ZIndex = 153,
})

micIcon:GetAttributeChangedSignal("NvIcon"):Connect(function()
	local muted = micIcon:GetAttribute("NvIcon") == "micoff"
	local tint = muted and S.TINT.red or S.TINT.gray
	tween(micFace, S.QUICK, { BackgroundColor3 = tint[1] })
	micIcon.ImageColor3 = muted and tint[2] or S.WHITE
end)

micBtn.MouseEnter:Connect(function()
	tween(micFace, S.QUICK, { BackgroundTransparency = -0.12 })
end)
micBtn.MouseLeave:Connect(function()
	tween(micFace, S.QUICK, { BackgroundTransparency = 0 })
end)

-- Reopen chip (shown after closing the panel) ------------------------
local reopenBtn = create("TextButton", {
	Parent = panelGui,
	Name = "Reopen",
	AnchorPoint = Vector2.new(0.5, 0),
	Position = UDim2.new(0.5, 0, 0, 46),
	Size = UDim2.fromOffset(46, 28),
	BackgroundColor3 = S.PANEL,
	BackgroundTransparency = 0.08,
	BorderSizePixel = 0,
	AutoButtonColor = false,
	Font = Enum.Font.GothamBold,
	TextSize = 11,
	Text = "VC",
	TextColor3 = S.WHITE,
	Visible = false,
	ZIndex = 149,
})
round(reopenBtn, 9)
rim(reopenBtn, 0.85, 1)

---------------------------------------------------------------------
-- 8.  Placement (kept from the original module)
---------------------------------------------------------------------
local function placePanelTop()
	if not panel then
		return
	end

	local camera = workspace.CurrentCamera
	local viewport = camera and camera.ViewportSize
	local vpX = tonumber(viewport and viewport.X) or 1280
	local vpY = tonumber(viewport and viewport.Y) or 720

	local topInset = 36
	pcall(function()
		local inset = GuiService:GetGuiInset()
		if typeof(inset) == "Vector2" then
			topInset = math.max(tonumber(inset.Y) or 36, 36)
		end
	end)
	topInset = tonumber(topInset) or 36

	local sideMargin = isMobile and 12 or 16
	local topGap = isMobile and 8 or 10
	local maxWidth = math.max(180, vpX - sideMargin * 2)
	local fitWidth = math.clamp(VCB_W, 180, math.min(300, maxWidth))
	if vpX < 420 then
		fitWidth = math.clamp(vpX - sideMargin * 2, 180, 280)
	end
	panel.Size = UDim2.new(0, fitWidth, 0, VCB_H)

	local scale = 1
	local uiScale = panel:FindFirstChildOfClass("UIScale")
	if uiScale then
		local maxFit = math.min(
			(vpX - sideMargin * 2) / fitWidth,
			(vpY - topInset - topGap - 16) / VCB_H
		)
		scale = math.clamp(tonumber(maxFit) or 1, 0.45, 1.15)
		uiScale.Scale = scale
	end

	local scaledW = fitWidth * scale
	local scaledH = VCB_H * scale
	local posX = math.clamp(
		vpX * 0.5,
		scaledW * 0.5 + sideMargin,
		math.max(scaledW * 0.5 + sideMargin, vpX - scaledW * 0.5 - sideMargin)
	)
	local posY = math.clamp(topGap, topGap, math.max(topGap, vpY - scaledH - sideMargin))

	panel.AnchorPoint = Vector2.new(0.5, 0)
	panel.Position = UDim2.new(0, posX, 0, posY + topInset)
end

---------------------------------------------------------------------
-- 9.  Core state
---------------------------------------------------------------------
local mode = nil          -- "v1" | "v2" while a bypass is active
local executed = false
local muted = false

local function publishMute()
	local voiceInternal = clonerefFn(softService("VoiceChatInternal"))
	if not voiceInternal then
		return false
	end
	local ok = pcall(function()
		voiceInternal:PublishPause(muted)
	end)
	return ok
end

local function applyMicVisual(isMuted)
	setIcon(micIcon, isMuted and "micoff" or "mic")
	local tint = isMuted and S.TINT.red or S.TINT.gray
	tween(micFace, S.SOFT, { BackgroundColor3 = tint[1] })
	micIcon.ImageColor3 = isMuted and tint[2] or S.WHITE
end

local syncHud -- forward declaration (defined with the HUD below)
local vcb2SetMuted -- set by Bypass V2 once its mic controller exists

local function selectVersion(index)
	version = index
	tween(segThumb, S.QUICK, {
		Position = (index == 1)
			and UDim2.new(0, 3, 0, 3)
			or UDim2.new(0.5, 1, 0, 3),
	})
	for key, button in pairs(segButtons) do
		tween(button, S.QUICK, { TextColor3 = (key == index) and S.INK or S.TEXT })
	end
	note.Text = VCB_NOTES[index]
end

local function alreadyOn(requested)
	if mode == requested then
		notify("VC Bypasser", executed and "Already bypassed" or "Already running", 3)
	else
		notify("VC Bypasser", "Bypass " .. string.upper(mode or "?") .. " is already on. Rejoin to use the other one", 4)
	end
end

---------------------------------------------------------------------
-- 10. Mic HUD (standalone replacement for NV_MicToggleGUI)
---------------------------------------------------------------------
local function ensureMicHud()
	local existing = guiRoot:FindFirstChild("VCB_MicToggleGUI")
		or PlayerGui:FindFirstChild("VCB_MicToggleGUI")
	if existing then
		return
	end

	local displayOrder = 49
	pcall(function()
		local coreGui = softService("CoreGui")
		local topBar = coreGui and coreGui:FindFirstChild("TopBarApp")
		if topBar and topBar:IsA("ScreenGui") then
			displayOrder = topBar.DisplayOrder
		end
	end)

	local micGui = create("ScreenGui", {
		Name = "VCB_MicToggleGUI",
		ResetOnSpawn = false,
		DisplayOrder = displayOrder + 1,
	})
	attach(micGui)

	local frame = create("Frame", {
		Parent = micGui,
		Name = "StatusFrame",
		Position = UDim2.new(0, 165, 0, -45),
		Size = UDim2.fromOffset(40, 40),
		BackgroundColor3 = S.PANEL,
		BackgroundTransparency = 0.25,
		Active = true,
		BorderSizePixel = 0,
	})
	round(frame, 20)
	rim(frame, 0.85, 1)

	local hudIcon = create("ImageLabel", {
		Parent = frame,
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(0.5, 0, 0.5, 0),
		Size = UDim2.fromOffset(20, 20),
		Icon = "mic",
		ImageColor3 = S.WHITE,
		ScaleType = Enum.ScaleType.Fit,
	})

	local hudButton = create("TextButton", {
		Parent = frame,
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		Text = "",
		ZIndex = 2,
	})

	hudButton.MouseButton1Click:Connect(function()
		muted = not muted
		setIcon(hudIcon, muted and "micoff" or "mic")
		setIcon(micIcon, muted and "micoff" or "mic")
		local tint = muted and S.TINT.red or S.TINT.gray
		tween(micFace, S.SOFT, { BackgroundColor3 = tint[1] })
		tween(hudIcon, S.SOFT, { ImageColor3 = muted and S.DANGER or S.WHITE })
		pcall(publishMute)
	end)
end

syncHud = function()
	local micGui = guiRoot:FindFirstChild("VCB_MicToggleGUI")
		or PlayerGui:FindFirstChild("VCB_MicToggleGUI")
	if not micGui then
		return
	end
	local frame = micGui:FindFirstChild("StatusFrame")
	local icon = frame and frame:FindFirstChildOfClass("ImageLabel")
	if icon then
		setIcon(icon, muted and "micoff" or "mic")
		tween(icon, S.SOFT, { ImageColor3 = muted and S.DANGER or S.WHITE })
	end
end

---------------------------------------------------------------------
-- 11. Bypass V1
---------------------------------------------------------------------
local MUTED_ICON = "rbxasset://textures/ui/VoiceChat/MicLight/Muted.png"

local function waitMicUnmuted(timeout)
	timeout = timeout or 45
	local coreGui = softService("CoreGui")
	if not coreGui then
		return false
	end

	local micButton
	local ok = pcall(function()
		local topBar = coreGui:WaitForChild("TopBarApp", 5)
		topBar = topBar and topBar:WaitForChild("TopBarApp", 5)
		local leftFrame = topBar and topBar:WaitForChild("UnibarLeftFrame", 5)
		local menu = leftFrame and leftFrame:WaitForChild("UnibarMenu", 5)
		local layer2 = menu and menu:WaitForChild("2", 5)
		local layer3 = layer2 and layer2:WaitForChild("3", 5)
		micButton = layer3 and layer3:FindFirstChild("toggle_mic_mute", true)
	end)
	if not ok or not micButton then
		return false
	end

	local function iconImage()
		local frame = micButton:FindFirstChild("IntegrationIconFrame", true)
		local holder = frame and frame:FindFirstChild("IntegrationIcon", true)
		local label = holder and holder:FindFirstChild("1")
		return label and label.Image or nil
	end

	local elapsed = 0
	repeat
		task.wait(1)
		elapsed = elapsed + 1
		local image = iconImage()
		if image and image ~= MUTED_ICON then
			return true
		end
	until elapsed >= timeout

	return false
end

local function runBypassV1()
	local voiceService = clonerefFn(softService("VoiceChatService"))
	local voiceInternal = clonerefFn(softService("VoiceChatInternal"))
	if not (voiceService and voiceInternal) then
		notify("VC Bypasser", "Voice chat services are unavailable in this game", 5)
		return false
	end

	notify("VCBypasser", "Unmute your mic to continue bypass...")
	pcall(waitMicUnmuted, 45)

	pcall(function()
		voiceService:leaveVoice()
	end)
	task.wait(3)

	if getconnectionsFn then
		pcall(function()
			local connections = getconnectionsFn(voiceInternal.StateChanged)
			for index = 7, #connections do
				pcall(function()
					connections[index]:Disable()
				end)
			end
		end)
	end

	task.wait(3)
	pcall(function()
		voiceService:joinVoice()
	end)
	pcall(function()
		voiceInternal:PublishPause(muted)
	end)
	return true
end

---------------------------------------------------------------------
-- 12. Bypass V2
---------------------------------------------------------------------
local function runBypassV2()
	if mode then
		alreadyOn("v2")
		return
	end

	mode = "v2"
	selectVersion(2)
	execBtn.Text = "BYPASSING..."

	task.spawn(function()
		local ok, err = pcall(function()
			local HIT_OFFSET_X, HIT_OFFSET_Y, HIT_SIZE = 14, 13, 35

			local voiceService = clonerefFn(softService("VoiceChatService"))
			local voiceInternal = clonerefFn(softService("VoiceChatInternal"))
			local coreGui = clonerefFn(softService("CoreGui")) or guiRoot

			local existingGui = LocalPlayer:WaitForChild("PlayerGui")

			if not (voiceService and voiceInternal) then
				error("VoiceChat services are not accessible from this script")
			end

			local TALKING_ICON = "rbxasset://textures/ui/VoiceChat/MicLight/Talking0.png"

			local micToggle, iconFrame, iconHolder, redDot

			local function findMicNodes()
				for _, node in ipairs(coreGui:GetDescendants()) do
					if node.Name == "toggle_mic_mute" then
						micToggle = node
					elseif node.Name == "RedVoiceDot" and node:IsA("GuiObject") then
						redDot = node
					end
				end
				if micToggle then
					iconFrame = micToggle:FindFirstChild("IntegrationIconFrame", true)
					if iconFrame then
						iconHolder = iconFrame:FindFirstChild("IntegrationIcon", true)
					end
				end
			end

			findMicNodes()

			if not micToggle then
				task.spawn(function()
					pcall(function()
						voiceService:joinVoice()
					end)
				end)
				task.wait(1.5)
				findMicNodes()
			end

			notify("VC Bypasser", "Unmute to continue.", 5)

			local function iconImage()
				if iconHolder and iconHolder:FindFirstChild("1") then
					return iconHolder["1"].Image
				end
				return nil
			end

			local unmuted = false
			local waited = 0
			while not unmuted do
				local image = iconImage()
				if image and image ~= MUTED_ICON and image ~= "" then
					TALKING_ICON = image
					unmuted = true
				end
				if not unmuted then
					if waited >= 60 then
						error("timed out waiting for your mic to unmute")
					end
					task.wait(0.5)
					waited = waited + 0.5
				end
			end
			task.wait(1)

			task.spawn(function()
				pcall(function()
					voiceService:leaveVoice()
				end)
			end)
			task.wait(2)

			if getconnectionsFn then
				task.spawn(function()
					pcall(function()
						local connections = getconnectionsFn(voiceInternal.StateChanged)
						for index, connection in ipairs(connections) do
							if index >= 7 and connection then
								pcall(function()
									connection:Disable()
								end)
							end
						end
					end)
				end)
			end

			task.wait(2)
			task.spawn(function()
				pcall(function()
					voiceService:joinVoice()
				end)
			end)

			task.wait(1)
			findMicNodes()

			if micToggle then
				task.spawn(function()
					for _, descendant in ipairs(micToggle:GetDescendants()) do
						if descendant:IsA("ImageLabel") or descendant:IsA("ImageButton") then
							descendant.ImageTransparency = 1
						elseif descendant:IsA("TextLabel") or descendant:IsA("TextButton") then
							descendant.TextTransparency = 1
						end
					end
				end)
			end

			local root
			if gethuiFn then
				local okHui, result = pcall(gethuiFn)
				if okHui then
					root = result
				end
			end
			root = root or coreGui or existingGui

			local existingController = root:FindFirstChild("CustomVoiceController")
			if existingController then
				existingController:Destroy()
			end

			local controller = create("ScreenGui", {
				Name = "CustomVoiceController",
				ResetOnSpawn = false,
				IgnoreGuiInset = true,
				DisplayOrder = 999999,
				ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
			})
			attach(controller, root)

			local hitArea = create("TextButton", {
				Parent = controller,
				Name = "MicHitArea",
				Size = UDim2.fromOffset(HIT_SIZE, HIT_SIZE),
				Position = UDim2.new(0, 150 + HIT_OFFSET_X, 0, 4 + HIT_OFFSET_Y),
				BackgroundTransparency = 1,
				Text = "",
				Active = true,
				ZIndex = 10000,
			})

			local customIcon = create("ImageLabel", {
				Parent = hitArea,
				Name = "MicIcon",
				Size = UDim2.fromScale(1, 1),
				Position = UDim2.fromOffset(0, 0),
				BackgroundTransparency = 1,
				Image = MUTED_ICON,
				ScaleType = Enum.ScaleType.Fit,
				ZIndex = 10001,
			})

			local paused = false
			pcall(function()
				paused = voiceInternal:IsPublishPaused()
			end)

			local function applyPaused(value)
				customIcon.Image = value and MUTED_ICON or TALKING_ICON
				if redDot and redDot.Parent then
					redDot.Visible = not value
				end
				task.spawn(function()
					pcall(function()
						voiceInternal:PublishPause(value)
					end)
				end)
			end

			hitArea.MouseButton1Click:Connect(function()
				paused = not paused
				applyPaused(paused)
				muted = paused
				applyMicVisual(paused)
			end)

			vcb2SetMuted = function(value)
				paused = value
				applyPaused(value)
			end

			applyPaused(true)
			paused = true

			local function micAnchor()
				if not iconHolder or not iconHolder.Parent then
					findMicNodes()
				end
				if iconHolder and iconHolder.AbsolutePosition.X > 50 then
					return iconHolder.AbsolutePosition, iconHolder.AbsoluteSize
				elseif micToggle and micToggle.AbsolutePosition.X > 50 then
					return micToggle.AbsolutePosition, micToggle.AbsoluteSize
				end
				return nil, nil
			end

			local anchor = micAnchor()
			if anchor and anchor.X > 0 and anchor.Y >= 0 then
				hitArea.Position = UDim2.new(0, anchor.X + HIT_OFFSET_X, 0, anchor.Y + HIT_OFFSET_Y)
				hitArea.Size = UDim2.fromOffset(HIT_SIZE, HIT_SIZE)
			end

			if redDot and redDot:IsA("GuiObject") then
				redDot.Visible = not paused
			end

			voiceInternal.StateChanged:Connect(function()
				pcall(function()
					paused = voiceInternal:IsPublishPaused()
				end)
				if redDot and redDot.Parent then
					redDot.Visible = not paused
				end
			end)
		end)

		if ok then
			executed = true
			muted = true
			applyMicVisual(true)
			execBtn.Text = "BYPASSED"
			notify("VC Bypasser", "Bypass active. Use the mic button to mute and unmute.", 5)
		else
			mode = nil
					execBtn.Text = "Execute Bypass"
			notify("VC Bypasser", "Bypass failed: " .. tostring(err), 5)
		end
	end)
end

---------------------------------------------------------------------
-- 13. Wiring
---------------------------------------------------------------------
for index, button in pairs(segButtons) do
	button.MouseButton1Click:Connect(function()
		if version == index then
			return
		end
		if mode then
			notify("VC Bypasser", "A bypass is already on. Rejoin to switch versions", 3)
			return
		end
		selectVersion(index)
	end)
end

execBtn.MouseButton1Click:Connect(function()
	if version == 2 then
		runBypassV2()
		return
	end

	if mode then
		alreadyOn("v1")
		return
	end

	mode = "v1"
	execBtn.Text = "BYPASSING..."

	task.spawn(function()
		local ok, result = pcall(runBypassV1)
		if ok and result == true then
			executed = true
			execBtn.Text = "BYPASSED"
			notify("VCBypasser", "Bypass executed")
			pcall(ensureMicHud)
			pcall(syncHud)
		else
			mode = nil
					execBtn.Text = "Execute Bypass"
			if ok then
				notify("VCBypasser", "Bypass failed: voice chat unavailable", 5)
			else
				notify("VCBypasser", "Bypass failed: " .. tostring(result), 5)
			end
		end
	end)
end)

micBtn.MouseButton1Click:Connect(function()
	if not executed then
		notify("VCBypasser", "Execute bypass first")
		return
	end
	muted = not muted
	applyMicVisual(muted)
	if mode == "v2" then
		if vcb2SetMuted then
			pcall(vcb2SetMuted, muted)
		end
		return
	end
	pcall(syncHud)
	pcall(publishMute)
end)

---------------------------------------------------------------------
-- 14. Show / hide
---------------------------------------------------------------------
local function setOpen(open)
	panel.Visible = open
	reopenBtn.Visible = not open
	if open then
		task.defer(placePanelTop)
		notify("VC Bypasser", "Unmute your mic, talk into it for 5 seconds, then click execute bypass")
	end
end

closeBtn.MouseButton1Click:Connect(function()
	setOpen(false)
end)

reopenBtn.MouseButton1Click:Connect(function()
	setOpen(true)
end)

closeBtn.MouseEnter:Connect(function()
	tween(closeBtn, S.QUICK, { BackgroundColor3 = S.TINT.red[1] })
end)
closeBtn.MouseLeave:Connect(function()
	tween(closeBtn, S.QUICK, { BackgroundColor3 = S.TINT.gray[1] })
end)

track(UserInputService.InputBegan:Connect(function(input, processed)
	if processed then
		return
	end
	if input.KeyCode == Enum.KeyCode.RightShift then
		setOpen(not panel.Visible)
	end
end))

placePanelTop()

pcall(function()
	local camera = workspace.CurrentCamera
	if camera then
		track(camera:GetPropertyChangedSignal("ViewportSize"):Connect(function()
			if panel.Visible then
				placePanelTop()
			end
		end))
	end
end)

-- A bypass that already ran keeps its mic controls after PuppyAdmin stops,
-- because the disabled StateChanged handlers cannot be restored.
return {
	setOpen = setOpen,
	isOpen = function() return panel.Visible end,
	bypassActive = function() return mode ~= nil end,
	guiRoot = guiRoot,
	PlayerGui = PlayerGui,
}
end

table.insert(cleanups, function()
	for _, c in ipairs(VCB.conns) do pcall(function() c:Disconnect() end) end
	table.clear(VCB.conns)
	local api = VCB.api
	if not api then return end
	local names = { "VCBypass", "VCB_Toasts" }
	if not api.bypassActive() then
		table.insert(names, "VCB_MicToggleGUI")
		table.insert(names, "CustomVoiceController")
	end
	for _, container in ipairs({ api.guiRoot, api.PlayerGui }) do
		pcall(function()
			for _, name in ipairs(names) do
				local g = container:FindFirstChild(name)
				if g then g:Destroy() end
			end
		end)
	end
	VCB.api = nil
end)


------------------------------------------------------------------------
-- Commands (terminal and chat share this table)
------------------------------------------------------------------------

local cmds = {
    "tools",
    "fly", "unfly", "togglefly", "flyspeed", "superfly", "unsuperfly", "hatfly", "unhatfly",
    "helicopter", "unhelicopter", "noclip", "unnoclip", "togglenoclip", "airwalk", "unairwalk",
    "swim", "unswim", "moveui", "infbaseplate", "uninfbaseplate", "esp", "unesp", "rejoin",
    "hide", "unhide", "mute", "unmute",
    "reanimui", "tp", "goto", "clicktp",
    "aura", "unaura", "auras",
    "tagui", "antikick", "unantikick", "antivcban",
    "reanim", "anim", "bind", "unbind", "binds",
    "prefix", "uikey", "settings", "theme", "kill", "stop", "help",
}

-- Novoline's short names for the commands ported from it.
local ALIASES = {
    f = "fly", uf = "unfly", nofly = "unfly", tf = "togglefly", fs = "flyspeed", flysp = "flyspeed",
    sfly = "superfly", sflymode = "superfly", usfly = "unsuperfly", nosuperfly = "unsuperfly",
    hf = "hatfly", uhf = "unhatfly", nohatfly = "unhatfly", heli = "helicopter", unheli = "unhelicopter",
    noheli = "unhelicopter", nc = "noclip", unc = "unnoclip", clip = "unnoclip", tnc = "togglenoclip",
    aw = "airwalk", uaw = "unairwalk", sw = "swim", usw = "unswim", noswim = "unswim",
    wh = "esp", wallhack = "esp", unwh = "unesp", noesp = "unesp", ibp = "infbaseplate", rj = "rejoin",
}

local cmdDocs = {
    tools = "tools [sub] [value] - Orbit/tail/wings; no sub opens the panel, 'tools help' lists subs",
    fly = "fly [speed] - Fly (WASD, Space/Ctrl or E/Q for up/down)",
    unfly = "unfly - Stop flying",
    togglefly = "togglefly - Toggle fly",
    flyspeed = "flyspeed [num] - Fly speed (default 1)",
    superfly = "superfly [speed] - Hold the mouse to fly, with fly animations",
    unsuperfly = "unsuperfly - Stop superfly",
    hatfly = "hatfly - Fly your hats while your body waits under the map",
    unhatfly = "unhatfly - Stop hatfly and bring your body back",
    helicopter = "helicopter - Fly while spinning like a helicopter",
    unhelicopter = "unhelicopter - Stop helicopter",
    noclip = "noclip - Walk through walls",
    unnoclip = "unnoclip - Restore collision",
    togglenoclip = "togglenoclip - Toggle noclip",
    airwalk = "airwalk - Walk on air (Space to rise)",
    unairwalk = "unairwalk - Stop airwalk",
    swim = "swim - Float in zero gravity",
    unswim = "unswim - Stop swimming",
    moveui = "moveui - Movement panel (fly modes, speed, noclip, airwalk, swim)",
    infbaseplate = "infbaseplate - Endless floor under you (opens its panel)",
    uninfbaseplate = "uninfbaseplate - Remove the endless floor",
    esp = "esp - Names, health and distance through walls (opens its panel)",
    unesp = "unesp - Turn ESP, chams, hitboxes and tracers off",
    rejoin = "rejoin - Rejoin this server",
    reanimui = "reanimui - Reanimation panel",
    tp = "tp [name] or tp [x] [y] [z] - Teleport to a player or a point",
    ["goto"] = "goto [name] - Same as tp",
    clicktp = "clicktp [on|off] - Click anywhere to teleport there",
    hide = "hide [ui|me|all|others|name] - Hide the script UI or a character (your screen)",
    unhide = "unhide [ui|me|all|others|name] - Undo hide",
    mute = "mute [name|all|others] - Silence a player's chat and sounds (your side)",
    unmute = "unmute [name|all|others] - Undo mute",
    tagui = "tagui - Open the nametag editor (allowlisted users only)",
    antikick = "antikick - Block client-side Kick calls on you",
    unantikick = "unantikick - Turn antikick off",
    antivcban = "antivcban [close] - Open the VC bypass panel (V1 / V2, mic mute)",
    aura = "aura [name] [target] [color] - Apply an aura (see auras)",
    unaura = "unaura [name|all] [target] - Remove auras",
    auras = "auras - List usable auras",
    reanim = "reanim [on|off] [auto|remote|client|local] - Reanimate (opens with reanimui)",
    anim = "anim [add|remove|play|stop|list|state|bind|unbind|binds|speed|pause|reverse|noclip]",
    bind = "bind [key] [anim] - Keybind an animation (press again to stop)",
    unbind = "unbind [key] - Remove an animation keybind",
    binds = "binds - List animation keybinds",
    prefix = "prefix [add|remove|set] [chars] - Chat command prefixes",
    uikey = "uikey [key] - Key that shows/hides the script UI",
    settings = "settings - Toggles the settings window",
    theme = "theme [preset | role color | reset] - Script UI colours (also in Settings)",
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

function H.aura(a)
    local name = a[1] and a[1]:lower()
    if not name then note("Aura", "Usage: aura [name] [target] [color] - see 'auras'"); return end
    if not Aura.defs[name] then note("Aura", "Unknown aura '" .. name .. "' - see 'auras'", RED); return end
    local color = Aura.defaultColor
    local r, g, b = parseColorArgs(a, 3)
    if r then color = Color3.fromRGB(r, g, b) end
    local list = resolveTargets(a[2])
    if #list == 0 then note("Aura", "No matching player", RED); return end
    for _, p in ipairs(list) do Aura.apply(p, name, color) end
    note("Aura", name .. " -> " .. (#list == 1 and list[1].DisplayName or (#list .. " players")), LIGHT)
end

function H.unaura(a)
    local name = a[1] and a[1]:lower()
    if not name then note("Aura", "Usage: unaura [name|all] [target]"); return end
    if name == "all" then name = nil end
    local list = resolveTargets(a[2])
    local n = 0
    for _, p in ipairs(list) do n = n + Aura.remove(p, name) end
    note("Aura", "Removed " .. n)
end

function H.auras()
    local lines = {}
    for _, name in ipairs(Aura.order) do
        table.insert(lines, name .. " - " .. Aura.defs[name].desc)
    end
    table.insert(lines, "")
    table.insert(lines, "color: name, #hex or r,g,b (red green blue white yellow orange purple pink cyan gold)")
    UIAPI.showOutput("AURAS", lines)
end

-- Reanimation / animations ---------------------------------------------------------

function H.reanim(a)
    local want
    for _, tok in ipairs(a) do
        local l = tok:lower()
        if l == "on" or l == "off" then
            want = (l == "on")
        elseif l == "auto" or l == "remote" or l == "client" or l == "local" then
            Reanim.requested = l
        end
    end
    if want == nil then want = not Reanim.active end
    if want then
        Reanim.start(Reanim.requested)
    else
        Reanim.stop()
        note("Reanim", "Stopped", LIGHT)
    end
end

local function animBind(key, name)
    local kc = resolveKeyCode(key)
    if not kc then note("Anim", "Unknown key '" .. tostring(key) .. "'", RED); return end
    if not name or not Cfg.anims[name] then note("Anim", "Unknown animation '" .. tostring(name) .. "'", RED); return end
    for k, v in pairs(Cfg.binds) do if v == name then Cfg.binds[k] = nil end end
    Cfg.binds[kc.Name] = name
    cfgSave()
    note("Anim", kc.Name .. " -> " .. name, LIGHT)
end

local function animUnbind(key)
    local kc = resolveKeyCode(key)
    if kc and Cfg.binds[kc.Name] then
        Cfg.binds[kc.Name] = nil
        cfgSave()
        note("Anim", "Unbound " .. kc.Name)
    else
        note("Anim", "That key has no bind")
    end
end

local function animBinds()
    local lines = {}
    for k, v in pairs(Cfg.binds) do table.insert(lines, k .. " -> " .. v) end
    table.sort(lines)
    if #lines == 0 then lines[1] = "No binds yet - try: bind G myanim" end
    UIAPI.showOutput("ANIMATION KEYBINDS", lines)
end

function H.bind(a) animBind(a[1], a[2]) end
function H.unbind(a) animUnbind(a[1]) end
function H.binds() animBinds() end

function H.anim(a)
    local sub = a[1] and a[1]:lower()
    if sub == "add" then
        local speed, loop = 1, nil
        for i = 4, #a do
            local l = a[i]:lower()
            if l == "loop" then loop = true elseif l == "once" then loop = false else speed = tonumber(a[i]) or speed end
        end
        local ok, msg = Anim.add(a[2], a[3], speed, loop)
        note("Anim", msg, ok and LIGHT or RED)
    elseif sub == "remove" then
        local name = a[2]
        if not name or not Cfg.anims[name] then note("Anim", "Unknown animation"); return end
        Anim.stopAll()
        Cfg.anims[name] = nil
        for k, v in pairs(Cfg.binds) do if v == name then Cfg.binds[k] = nil end end
        for k, v in pairs(Cfg.animStates) do if v == name then Cfg.animStates[k] = nil end end
        Anim.clearCache()
        cfgSave()
        note("Anim", "Removed " .. name)
    elseif sub == "play" then
        local name = a[2]
        if not name or not Cfg.anims[name] then note("Anim", "Unknown animation"); return end
        Anim.stopManual()
        if Anim.startNamed(name, false) then Anim.manual = name end
    elseif sub == "stop" then
        Anim.stopManual()
        Anim.stopState()
        note("Anim", "Stopped")
    elseif sub == "list" then
        local lines = {}
        for name, d in pairs(Cfg.anims) do
            table.insert(lines, string.format("%s  [%s]  %s  speed %s%s", name, d.kind or "id", d.src or d.id or "?", tostring(d.speed or 1), d.loop and "  loop" or ""))
        end
        table.sort(lines)
        for st, name in pairs(Cfg.animStates) do table.insert(lines, "state " .. st .. " = " .. name) end
        if #lines == 0 then lines[1] = "No animations yet - try: anim add wave 1234567890" end
        UIAPI.showOutput("ANIMATIONS", lines)
    elseif sub == "state" then
        local st, name = a[2] and a[2]:lower(), a[3]
        if st ~= "idle" and st ~= "walk" and st ~= "jump" and st ~= "fall" then
            note("Anim", "States: idle walk jump fall (used while reanimated)"); return
        end
        if not name or name:lower() == "none" then
            Cfg.animStates[st] = nil
        elseif Cfg.anims[name] then
            Cfg.animStates[st] = name
        else
            note("Anim", "Unknown animation", RED); return
        end
        Anim.stateName = nil
        cfgSave()
        note("Anim", st .. " = " .. tostring(Cfg.animStates[st] or "none"), LIGHT)
    elseif sub == "speed" then
        KF.userSpeed = math.max(0.1, math.min(4, tonumber(a[2]) or KF.userSpeed))
        note("Anim", "Speed " .. KF.userSpeed .. "x")
    elseif sub == "pause" then
        KF.paused = parseToggle(a[2], KF.paused)
        note("Anim", KF.paused and "Paused" or "Playing")
    elseif sub == "reverse" then
        KF.dir = parseToggle(a[2], KF.dir == -1) and -1 or 1
        note("Anim", KF.dir == -1 and "Reversed" or "Forward")
    elseif sub == "noclip" then
        Reanim.setNoclip(parseToggle(a[2], Reanim.noclip))
        note("Anim", "Noclip " .. (Reanim.noclip and "on" or "off"))
    elseif sub == "bind" then
        animBind(a[2], a[3])
    elseif sub == "unbind" then
        animUnbind(a[2])
    elseif sub == "binds" then
        animBinds()
    else
        note("Anim", "anim add|remove|play|stop|list|state|bind|unbind|binds|speed|pause|reverse|noclip")
    end
    Reanim.changed()
end

-- Panels and teleport -------------------------------------------------------------

function H.reanimui() UIAPI.togglePanel("reanim") end

function H.tp(a)
    local x, y, z = tonumber(a[1]), tonumber(a[2]), tonumber(a[3])
    if x and y and z then
        if Teleport.toPoint(Vector3.new(x, y, z)) then
            note("Teleport", string.format("%.0f, %.0f, %.0f", x, y, z), LIGHT)
        else
            note("Teleport", "No body to move", RED)
        end
        return
    end
    if not a[1] then note("Teleport", "Usage: tp [name] or tp [x] [y] [z]"); return end
    local target
    for _, p in ipairs(resolveTargets(a[1])) do
        if p ~= plr then target = p; break end
    end
    if not target then note("Teleport", "No matching player", RED); return end
    if Teleport.toPlayer(target) then
        note("Teleport", "To " .. target.DisplayName, LIGHT)
    else
        note("Teleport", target.DisplayName .. " has no character", RED)
    end
end
H["goto"] = H.tp

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
    if not VCB.api then
        if sub == "close" then return end
        local ok, api = pcall(VCB.build)
        if not ok or type(api) ~= "table" then
            note("Anti VC Ban", "Panel failed: " .. tostring(api):sub(1, 60), RED)
            return
        end
        VCB.api = api
    end
    VCB.api.setOpen(sub ~= "close")
end

function H.tagui()
    if not canEditTags() then
        note("Tags", "Not authorized to edit nametags", RED)
        return
    end
    UIAPI.togglePanel("tags")
end

function H.clicktp(a)
    Teleport.click = parseToggle(a[1], Teleport.click)
    note("Click TP", Teleport.click and "On - click to teleport" or "Off", LIGHT)
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
        if settingsFrame then settingsFrame.Visible = true end
        local names = {}
        for _, p in ipairs(Theme.presets) do table.insert(names, p.name) end
        note("Theme", "Presets: " .. table.concat(names, ", "))
        return
    end
    if first:lower() == "reset" then first = "Default" end
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

function H.help()
    if helpFrame then helpFrame.Visible = not helpFrame.Visible end
end

function H.kill() shutdown(false) end
function H.stop() shutdown(SETTINGS.KillCharacterOnStop) end

do
-- Tools: every orbit / tail / wings command lives under `tools` ---------------------

local TOOL_SUBS = {
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
    if not TOOL_SUB_SET[sub] or not H[sub] then
        note("Tools", "Unknown '" .. sub .. "' - try tools help", RED)
        return
    end
    table.remove(a, 1)
    H[sub](a)
end

-- Movement (novoline) ----------------------------------------------------------------

local function showPanel(key)
    local p = UIAPI.panels[key]
    if p then p.Visible = true; UIAPI.sync() end
end

function H.fly(a)
    local v = tonumber(a[1])
    if v and Fly.flying then
        Fly.setSpeed(v)
        note("Fly", "Speed " .. Fly.speed)
        return
    end
    HatFly.stop()
    Fly.stop()
    if Fly.start() then
        if v then Fly.setSpeed(v) end
        note("Fly", "Enabled - WASD, Space up, Ctrl down (Q/E too)", LIGHT)
    end
end

function H.unfly()
    Fly.stop()
    note("Fly", "Disabled")
end

function H.togglefly()
    if Fly.flying then H.unfly() else H.fly({}) end
end

function H.flyspeed(a)
    local v = tonumber(a[1])
    if not v then note("Fly", "Speed is " .. Fly.speed .. " - usage: flyspeed [num]"); return end
    Fly.setSpeed(v)
    note("Fly", "Speed set to " .. Fly.speed, LIGHT)
end

function H.superfly(a)
    local v = tonumber(a[1])
    if v then Fly.setSpeed(v) end
    HatFly.stop()
    if Helicopter.on then Helicopter.stop(true) end
    if Superfly.set(true) then
        note("Superfly", isMobile and "Hold the screen to fly" or "Hold the mouse to fly", LIGHT)
    end
    showPanel("move")
end

function H.unsuperfly()
    Superfly.set(false)
    note("Superfly", "Disabled")
end

function H.helicopter()
    HatFly.stop()
    Superfly.off()
    if Helicopter.start() then note("Helicopter", "Enabled - " .. firstPrefix() .. "unhelicopter to stop", LIGHT) end
end

function H.unhelicopter()
    Helicopter.stop(false)
    note("Helicopter", "Disabled")
end

function H.hatfly()
    if Fly.flying then Fly.stop() end
    local ok, msg = HatFly.start()
    note("HatFly", ok and "Enabled - WASD to move the hat" or tostring(msg), ok and LIGHT or RED)
end

function H.unhatfly()
    HatFly.stop()
    note("HatFly", "Disabled")
end

function H.noclip()
    Noclip.set("user", true)
    note("Noclip", "On", LIGHT)
end

function H.unnoclip()
    Noclip.set("user", false)
    note("Noclip", "Off")
end

function H.togglenoclip()
    if Noclip.holds.user then H.unnoclip() else H.noclip() end
end

function H.airwalk()
    if not Airwalk.start() then note("Airwalk", "Already active"); return end
    note("Airwalk", "Enabled - Space to go up", LIGHT)
end

function H.unairwalk()
    Airwalk.stop()
    note("Airwalk", "Disabled")
end

function H.swim()
    if Swim.on then note("Swim", "Already swimming"); return end
    if Swim.start() then note("Swim", "Enabled", LIGHT) else note("Swim", "No character", RED) end
end

function H.unswim()
    Swim.stop()
    note("Swim", "Disabled")
end

function H.moveui() UIAPI.togglePanel("move") end

-- World / visuals (novoline) -----------------------------------------------------------

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

function H.rejoin()
    note("Rejoin", "Rejoining...", LIGHT)
    task.spawn(function()
        local ts = game:GetService("TeleportService")
        local ok, err = pcall(function()
            if #Players:GetPlayers() <= 1 then
                -- a solo server closes once you leave it, so leave first, then teleport back
                AntiKick.allowUntil = os.clock() + 2
                plr:Kick("\nRejoining...")
                task.wait()
                ts:Teleport(game.PlaceId, plr)
            else
                ts:TeleportToPlaceInstance(game.PlaceId, game.JobId, plr)
            end
        end)
        if not ok then note("Rejoin", tostring(err):sub(1, 70), RED) end
    end)
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
-- Panels: orbit / tail / wings / reanimation (palette follows novoline.lua)
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

    Theme.load()
    Theme.applyPAL()
    Theme.attach(notifGui)
end

UIAPI.panels = {}
UIAPI.syncFns = {}

function UIAPI.sync()
    for _, fn in pairs(UIAPI.syncFns) do pcall(fn) end
end

function UIAPI.togglePanel(key)
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

local function uiWindow(screenGui, key, title, size, pos)
    local f = make("Frame", {
        Name = key, Size = size, Position = pos, BackgroundColor3 = PAL.PANEL,
        BackgroundTransparency = 0.05, BorderSizePixel = 0, Visible = false, Active = true,
    }, screenGui)
    corner(f, 12)
    stroke(f, PAL.STROKE, 1, 0)
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

------------------------------------------------------------------------
-- Orbit / tail / wings panels
------------------------------------------------------------------------

local buildToolsPanel, buildMovementPanel, buildEspPanel, buildFloorPanel
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
local function scrollBody(f, topY)
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

local function sectionTitle(parent, add, text)
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
    local splitBtn
    splitBtn = uiButton(body, "", UDim2.new(1, -24, 0, 28), UDim2.fromOffset(12, sy), function()
        -- cycles auto -> 1 -> 2 ... -> number of tools -> auto
        local n = #slots
        if S.tailCount == nil then S.tailCount = 1
        elseif S.tailCount >= math.max(1, n) then S.tailCount = nil
        else S.tailCount = S.tailCount + 1 end
        assignRoles()
        UIAPI.sync()
    end)
    table.insert(syncers, function() splitBtn.Text = "Tail tools when combined: " .. (S.tailCount and tostring(S.tailCount) or "auto") end)

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
    local axisBtn
    axisBtn = uiButton(body, "", UDim2.new(1, -24, 0, 28), UDim2.fromOffset(12, ay), function()
        local i = table.find(AXIS_ORDER, S.axis) or 0
        S.axis = AXIS_ORDER[i % #AXIS_ORDER + 1]
        UIAPI.sync()
    end)
    table.insert(syncers, function() axisBtn.Text = "Handle axis: " .. S.axis end)
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
    switch("Fly", function() return Fly.flying and not Superfly.on and not Helicopter.on end, function(on) H[on and "fly" or "unfly"]({}) end)
    switch("Superfly (hold mouse)", function() return Superfly.on end, function(on) H[on and "superfly" or "unsuperfly"]({}) end)
    switch("Helicopter", function() return Helicopter.on end, function(on) H[on and "helicopter" or "unhelicopter"]({}) end)
    switch("HatFly", function() return HatFly.active end, function(on) H[on and "hatfly" or "unhatfly"]({}) end)
    local sp = uiSlider(body, "Fly speed", UDim2.fromOffset(12, add(48)), IW, {
        min = 0.5, max = 20, step = 0.5, value = Fly.speed, format = function(v) return string.format("%.1f", v) end,
        onChange = function(v) Fly.setSpeed(v) end,
    })
    table.insert(syncers, function() if not sp.isDragging() then sp.set(Fly.speed) end end)
    sectionTitle(body, add, "Body")
    switch("Noclip", function() return Noclip.holds.user == true end, function(on) H[on and "noclip" or "unnoclip"]({}) end)
    switch("Airwalk (Space to rise)", function() return Airwalk.conn ~= nil end, function(on) H[on and "airwalk" or "unairwalk"]({}) end)
    switch("Swim", function() return Swim.on end, function(on) H[on and "swim" or "unswim"]({}) end)
    UIAPI.syncFns.move = function()
        if not f.Visible then return end
        for _, fn in ipairs(syncers) do pcall(fn) end
    end
    f:GetPropertyChangedSignal("Visible"):Connect(function() if f.Visible then UIAPI.syncFns.move() end end)
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
    local W, HGT = 300, 270
    local f = uiWindow(screenGui, "floor", "Infinite baseplate", UDim2.fromOffset(W, HGT), UDim2.new(0.5, 20, 0.5, -HGT / 2))
    local IW = W - 32
    local sw = uiSwitch(f, "Enabled", UDim2.fromOffset(16, 48), IW, Baseplate.enabled, function(on)
        H[on and "infbaseplate" or "uninfbaseplate"]({ "quiet" })
    end)
    local name = label(f, { Position = UDim2.fromOffset(56, 86), Size = UDim2.new(1, -112, 0, 28), Text = "", TextXAlignment = Enum.TextXAlignment.Center })
    local function step(d)
        local n = #BASEPLATE_PRESETS
        Baseplate.usePreset((Baseplate.presetIndex - 1 + d) % n + 1)
        UIAPI.sync()
    end
    uiButton(f, "<", UDim2.fromOffset(36, 28), UDim2.fromOffset(16, 86), function() step(-1) end)
    uiButton(f, ">", UDim2.fromOffset(36, 28), UDim2.new(1, -52, 0, 86), function() step(1) end)
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
    label(f, { Position = UDim2.fromOffset(16, 216), Size = UDim2.new(1, -32, 0, 40), TextWrapped = true, TextSize = 11, TextColor3 = PAL.DIM,
        TextYAlignment = Enum.TextYAlignment.Top,
        Text = "Tiles spawn around you at the height of the floor you stood on when it was enabled. Only you see them." })
    UIAPI.syncFns.floor = function()
        if not f.Visible then return end
        sw.set(Baseplate.enabled)
        local p = BASEPLATE_PRESETS[Baseplate.presetIndex]
        name.Text = (Baseplate.kind == "texture" and not (p and p.texture == Baseplate.textureId)) and "Custom texture" or (p and p.name or "?")
        if not studs.isDragging() then studs.set(Baseplate.studs) end
    end
    f:GetPropertyChangedSignal("Visible"):Connect(function() if f.Visible then UIAPI.syncFns.floor() end end)
end
end

------------------------------------------------------------------------
-- Reanimation panel
------------------------------------------------------------------------

local function sortedAnimNames()
    local names = {}
    for n in pairs(Cfg.anims) do table.insert(names, n) end
    table.sort(names)
    return names
end

local function keyOfAnim(name)
    for k, v in pairs(Cfg.binds) do
        if v == name then return k end
    end
    return nil
end

local function buildReanimPanel(screenGui)
    local W, HGT = 360, 520
    local f = uiWindow(screenGui, "reanim", "Reanimation", UDim2.fromOffset(W, HGT), UDim2.new(0.5, 30, 0.5, -HGT / 2))

    -- status + main button
    local chip = make("Frame", { Size = UDim2.new(1, -164, 0, 32), Position = UDim2.fromOffset(16, 46), BackgroundTransparency = 1 }, f)
    local dot = make("Frame", {
        Size = UDim2.fromOffset(8, 8), AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, 2, 0.5, 0),
        BackgroundColor3 = PAL.DIV, BorderSizePixel = 0,
    }, chip)
    corner(dot, 4)
    local statusLbl = label(chip, { Size = UDim2.new(1, -18, 1, 0), Position = UDim2.fromOffset(18, 0), Text = "Status: Idle", TextColor3 = PAL.TEXT })
    local mainBtn = uiButton(f, "Reanimate", UDim2.fromOffset(120, 32), UDim2.new(1, -136, 0, 46), function()
        if Reanim.active then Reanim.stop() else task.spawn(Reanim.start, Reanim.requested) end
    end)

    -- mode row
    local modeBtns = {}
    for i, m in ipairs({ "auto", "remote", "client", "local" }) do
        modeBtns[m] = uiButton(f, m:sub(1, 1):upper() .. m:sub(2), UDim2.fromOffset(76, 26), UDim2.fromOffset(16 + (i - 1) * 82, 86), function()
            if Reanim.active then note("Reanim", "Stop first to change the mode"); return end
            Reanim.requested = m
            Reanim.changed()
        end)
    end

    -- tabs
    local tabNames = { "Library", "States", "Play", "Keys" }
    local tabBtns, pages = {}, {}
    local PAGE_Y, PAGE_H = 158, HGT - 170
    local function showTab(name)
        for n, p in pairs(pages) do p.Visible = (n == name) end
        for n, b in pairs(tabBtns) do
            b.BackgroundColor3 = (n == name) and PAL.ELEVATED or PAL.CARD
            b.TextColor3 = (n == name) and PAL.TEXT or PAL.DIM
        end
    end
    for i, n in ipairs(tabNames) do
        tabBtns[n] = uiButton(f, n, UDim2.fromOffset(80, 28), UDim2.fromOffset(16 + (i - 1) * 85, 120), function() showTab(n) end)
        pages[n] = make("Frame", {
            Size = UDim2.new(1, -32, 0, PAGE_H), Position = UDim2.fromOffset(16, PAGE_Y),
            BackgroundTransparency = 1, Visible = false, ClipsDescendants = true,
        }, f)
    end

    -- Library page
    local lib = pages.Library
    local search = uiBox(lib, UDim2.fromOffset(0, 0), UDim2.new(1, 0, 0, 28), "Search animations...")
    local list = make("ScrollingFrame", {
        Size = UDim2.new(1, 0, 1, -110), Position = UDim2.fromOffset(0, 34), BackgroundTransparency = 1,
        ScrollBarThickness = 2, ScrollBarImageColor3 = PAL.DIM, CanvasSize = UDim2.new(0, 0, 0, 0),
        AutomaticCanvasSize = Enum.AutomaticSize.Y, BorderSizePixel = 0,
    }, lib)
    make("UIListLayout", { Padding = UDim.new(0, 4), SortOrder = Enum.SortOrder.LayoutOrder }, list)
    local nameBox = uiBox(lib, UDim2.new(0, 0, 1, -70), UDim2.new(0.4, -4, 0, 28), "name")
    local srcBox = uiBox(lib, UDim2.new(0.4, 4, 1, -70), UDim2.new(0.6, -4, 0, 28), "id, URL or file")
    uiButton(lib, "Add animation", UDim2.new(1, 0, 0, 30), UDim2.new(0, 0, 1, -34), function()
        local nm = (nameBox.Text:gsub("%s", ""))
        local src = (srcBox.Text:gsub("^%s+", ""):gsub("%s+$", ""))
        local ok, msg = Anim.add(nm, src)
        note("Anim", msg, ok and LIGHT or RED)
        if ok then nameBox.Text, srcBox.Text = "", "" end
        Reanim.changed()
    end)

    local function refreshLibrary()
        for _, c in ipairs(list:GetChildren()) do
            if c:IsA("Frame") then c:Destroy() end
        end
        local q = search.Text:lower()
        for i, name in ipairs(sortedAnimNames()) do
            if q == "" or name:lower():find(q, 1, true) then
                local def = Cfg.anims[name]
                local row = make("Frame", { Size = UDim2.new(1, -6, 0, 34), BackgroundColor3 = PAL.CARD, BackgroundTransparency = 0.3, BorderSizePixel = 0, LayoutOrder = i }, list)
                corner(row, 8)
                local playing = Anim.isPlaying(name)
                label(row, {
                    Size = UDim2.new(1, -176, 1, 0), Position = UDim2.fromOffset(10, 0),
                    Text = name .. "  " .. (def.kind == "kf" and "[kf]" or "[id]"),
                    TextColor3 = playing and PAL.GOOD or PAL.TEXT, TextTruncate = Enum.TextTruncate.AtEnd,
                })
                uiButton(row, playing and "Stop" or "Play", UDim2.fromOffset(48, 24), UDim2.new(1, -168, 0.5, -12), function()
                    Anim.toggle(name)
                end)
                local k = keyOfAnim(name)
                local bindBtn = uiButton(row, Anim.capture == name and "..." or (k or "bind"), UDim2.fromOffset(62, 24), UDim2.new(1, -114, 0.5, -12), function()
                    Anim.capture = name
                    note("Anim", "Press a key for " .. name .. " (Esc cancels, Backspace clears)")
                    Reanim.changed()
                end)
                bindBtn.TextSize = 11
                uiButton(row, "x", UDim2.fromOffset(28, 24), UDim2.new(1, -38, 0.5, -12), function()
                    H.anim({ "remove", name })
                    Reanim.changed()
                end, true)
            end
        end
    end
    search:GetPropertyChangedSignal("Text"):Connect(refreshLibrary)

    -- States page
    local st = pages.States
    label(st, { Size = UDim2.new(1, 0, 0, 30), Text = "Played automatically while reanimated. Anything you start from the library takes over until you stop it.", TextColor3 = PAL.DIM, TextSize = 11, TextWrapped = true, TextYAlignment = Enum.TextYAlignment.Top })
    local stateBtns = {}
    for i, s in ipairs({ "idle", "walk", "jump", "fall" }) do
        local y = 44 + (i - 1) * 40
        label(st, { Size = UDim2.fromOffset(80, 30), Position = UDim2.fromOffset(0, y), Text = s:sub(1, 1):upper() .. s:sub(2) })
        stateBtns[s] = uiButton(st, "None", UDim2.new(1, -90, 0, 30), UDim2.new(0, 90, 0, y), function()
            local names = sortedAnimNames()
            local cur, idx = Cfg.animStates[s], 0
            for j, n in ipairs(names) do if n == cur then idx = j end end
            local nxt = names[idx + 1]
            Cfg.animStates[s] = nxt
            Anim.stateName = nil
            cfgSave()
            Reanim.changed()
        end)
    end

    -- Play page
    local pl = pages.Play
    local speedSl = uiSlider(pl, "Speed", UDim2.fromOffset(0, 0), W - 32, {
        min = 0.1, max = 4, step = 0.1, value = KF.userSpeed,
        format = function(v) return string.format("%.1fx", v) end,
        onChange = function(v) KF.userSpeed = v end,
    })
    local timeSl = uiSlider(pl, "Time", UDim2.fromOffset(0, 52), W - 32, {
        min = 0, max = 1, step = 0.01, value = 0,
        format = function(v) return string.format("%.2fs", v) end,
        onChange = function(v) if KF.playing then KF.t = math.min(v, KF.total - 0.001) end end,
    })
    local revSw = uiSwitch(pl, "Reverse", UDim2.fromOffset(0, 112), W - 32, KF.dir == -1, function(on) KF.dir = on and -1 or 1 end)
    local pauseSw = uiSwitch(pl, "Pause", UDim2.fromOffset(0, 142), W - 32, KF.paused, function(on) KF.paused = on end)
    local clipSw = uiSwitch(pl, "Noclip", UDim2.fromOffset(0, 172), W - 32, Reanim.noclip, function(on) Reanim.setNoclip(on) end)
    uiButton(pl, "Stop animation", UDim2.new(1, 0, 0, 30), UDim2.fromOffset(0, 210), function() Anim.stopManual(); Anim.stopState(); Reanim.changed() end)

    -- Keys page
    local ky = pages.Keys
    label(ky, { Size = UDim2.new(1, 0, 0, 30), Text = "Bind keys from the Library tab. Press once to start, again to stop.", TextColor3 = PAL.DIM, TextSize = 11, TextWrapped = true, TextYAlignment = Enum.TextYAlignment.Top })
    local keyList = make("ScrollingFrame", {
        Size = UDim2.new(1, 0, 1, -40), Position = UDim2.fromOffset(0, 36), BackgroundTransparency = 1,
        ScrollBarThickness = 2, ScrollBarImageColor3 = PAL.DIM, CanvasSize = UDim2.new(0, 0, 0, 0),
        AutomaticCanvasSize = Enum.AutomaticSize.Y, BorderSizePixel = 0,
    }, ky)
    make("UIListLayout", { Padding = UDim.new(0, 4), SortOrder = Enum.SortOrder.LayoutOrder }, keyList)

    local function refreshKeys()
        for _, c in ipairs(keyList:GetChildren()) do
            if c:IsA("Frame") then c:Destroy() end
        end
        local keys = {}
        for k in pairs(Cfg.binds) do table.insert(keys, k) end
        table.sort(keys)
        for i, k in ipairs(keys) do
            local row = make("Frame", { Size = UDim2.new(1, -6, 0, 32), BackgroundColor3 = PAL.CARD, BackgroundTransparency = 0.3, BorderSizePixel = 0, LayoutOrder = i }, keyList)
            corner(row, 8)
            label(row, { Size = UDim2.new(1, -90, 1, 0), Position = UDim2.fromOffset(10, 0), Text = k .. "  ->  " .. Cfg.binds[k] })
            uiButton(row, "Unbind", UDim2.fromOffset(64, 24), UDim2.new(1, -72, 0.5, -12), function()
                Cfg.binds[k] = nil
                cfgSave()
                Reanim.changed()
            end)
        end
    end

    local function refreshAll()
        local active = Reanim.active
        dot.BackgroundColor3 = active and PAL.GOOD or PAL.DIV
        statusLbl.Text = active and ("Status: Active (" .. tostring(Reanim.mode) .. ")") or "Status: Idle"
        mainBtn.Text = active and "Stop Reanim" or "Reanimate"
        for m, b in pairs(modeBtns) do
            b.BackgroundColor3 = (m == Reanim.requested) and PAL.ELEVATED or PAL.CARD
            b.TextColor3 = (m == Reanim.requested) and PAL.TEXT or PAL.DIM
        end
        for s, b in pairs(stateBtns) do
            local n = Cfg.animStates[s]
            b.Text = (n and Cfg.anims[n]) and n or "None"
        end
        refreshLibrary()
        refreshKeys()
        speedSl.set(KF.userSpeed)
        revSw.set(KF.dir == -1)
        pauseSw.set(KF.paused)
        clipSw.set(Reanim.noclip)
        timeSl.setRange(0, KF.playing and KF.total or 1)
    end

    table.insert(Reanim.listeners, refreshAll)
    UIAPI.syncFns.reanim = function()
        if f.Visible then refreshAll() end
    end
    table.insert(conns, RunService.Heartbeat:Connect(function()
        if f.Visible and pages.Play.Visible and KF.playing and not timeSl.isDragging() then
            timeSl.set(KF.t)
        end
    end))
    f:GetPropertyChangedSignal("Visible"):Connect(function()
        if f.Visible then refreshAll() end
    end)
    showTab("Library")
    refreshAll()
end

------------------------------------------------------------------------
-- Nametag editor (opened with `tagui`; allowlisted accounts only)
------------------------------------------------------------------------

local TAG_FONTS = { "GothamBold", "Gotham", "GothamSemibold", "Code", "Arcade", "SourceSansBold", "FredokaOne", "Bangers", "SciFi", "Fantasy" }

local function buildTagPanel(screenGui)
    local W, HGT = 380, 600
    local f = uiWindow(screenGui, "tags", "Nametag editor", UDim2.fromOffset(W, HGT), UDim2.new(0.5, -W / 2, 0.5, -HGT / 2))
    local selUserId, selName, fontIdx = nil, nil, 1

    local selLbl = label(f, { Position = UDim2.fromOffset(16, 46), Size = UDim2.new(1, -32, 0, 18), Text = "Target: none", TextColor3 = PAL.DIM })
    local list = make("ScrollingFrame", {
        Size = UDim2.new(1, -32, 0, 120), Position = UDim2.fromOffset(16, 68), BackgroundColor3 = PAL.CARD,
        BackgroundTransparency = 0.4, BorderSizePixel = 0, ScrollBarThickness = 2, ScrollBarImageColor3 = PAL.DIM,
        CanvasSize = UDim2.new(0, 0, 0, 0), AutomaticCanvasSize = Enum.AutomaticSize.Y,
    }, f)
    corner(list, 8)
    make("UIListLayout", { Padding = UDim.new(0, 3), SortOrder = Enum.SortOrder.LayoutOrder }, list)

    local idBox = uiBox(f, UDim2.fromOffset(16, 196), UDim2.new(1, -32, 0, 28), "or a UserId (for someone who left)")
    local textBox = uiBox(f, UDim2.fromOffset(16, 232), UDim2.new(1, -32, 0, 28), "Tag text (max 40)")
    local subBox = uiBox(f, UDim2.fromOffset(16, 268), UDim2.new(1, -32, 0, 28), "Subtitle (optional)")
    local colorBox = uiBox(f, UDim2.fromOffset(16, 304), UDim2.new(1, -32, 0, 28), "Color: name, #hex, r,g,b", "255,255,255")
    local rainbowSw = uiSwitch(f, "Rainbow", UDim2.fromOffset(16, 340), W - 32, false, function() end)
    local sizeSl = uiSlider(f, "Text size", UDim2.fromOffset(16, 372), W - 32, {
        min = 8, max = 48, step = 1, value = 22, format = function(v) return string.format("%d", v) end,
    })
    local offSl = uiSlider(f, "Height above head", UDim2.fromOffset(16, 420), W - 32, {
        min = 0, max = 12, step = 0.5, value = 3, format = function(v) return string.format("%.1f", v) end,
    })
    local fontBtn = uiButton(f, TAG_FONTS[1], UDim2.new(1, -32, 0, 28), UDim2.fromOffset(16, 470), function()
        fontIdx = fontIdx % #TAG_FONTS + 1
        f:FindFirstChild("FontBtn").Text = TAG_FONTS[fontIdx]
    end)
    fontBtn.Name = "FontBtn"

    local function targetId()
        return selUserId or tonumber(idBox.Text)
    end

    local refreshPlayers
    local function select(userId, name)
        selUserId, selName = userId, name
        selLbl.Text = "Target: " .. (name or "none")
        local d = userId and Cfg.tags[tostring(userId)]
        textBox.Text = d and d.text or ""
        subBox.Text = d and d.sub or ""
        local c = d and d.color or { 255, 255, 255 }
        colorBox.Text = string.format("%d,%d,%d", c[1], c[2], c[3])
        rainbowSw.set(d and d.rainbow or false)
        sizeSl.set(d and d.size or 22)
        offSl.set(d and d.offset or 3)
        fontIdx = table.find(TAG_FONTS, d and d.font or "GothamBold") or 1
        fontBtn.Text = TAG_FONTS[fontIdx]
    end

    refreshPlayers = function()
        for _, c in ipairs(list:GetChildren()) do
            if c:IsA("TextButton") then c:Destroy() end
        end
        for i, p in ipairs(Players:GetPlayers()) do
            local b = make("TextButton", {
                Size = UDim2.new(1, -6, 0, 26), BackgroundColor3 = (selUserId == p.UserId) and PAL.ELEVATED or PAL.CARD,
                BackgroundTransparency = 0.2, BorderSizePixel = 0, AutoButtonColor = false, LayoutOrder = i,
                Text = p.DisplayName .. "  (@" .. p.Name .. ")" .. (Cfg.tags[tostring(p.UserId)] and "  [tag]" or ""),
                TextColor3 = PAL.TEXT, Font = Enum.Font.Gotham, TextSize = 12, TextXAlignment = Enum.TextXAlignment.Left,
            }, list)
            corner(b, 6)
            make("UIPadding", { PaddingLeft = UDim.new(0, 8) }, b)
            b.MouseButton1Click:Connect(function()
                idBox.Text = ""
                select(p.UserId, p.DisplayName)
                refreshPlayers()
            end)
        end
    end

    local function guard()
        if canEditTags() then return true end
        note("Tags", "Not authorized to edit nametags", RED)
        return false
    end

    uiButton(f, "Apply tag", UDim2.new(0.5, -20, 0, 32), UDim2.fromOffset(16, 512), function()
        if not guard() then return end
        local uid = targetId()
        if not uid then note("Tags", "Pick a player or enter a UserId", RED); return end
        local text = textBox.Text:sub(1, 40)
        if text == "" then note("Tags", "Enter the tag text", RED); return end
        local r, g, b = parseColorArgs(splitArgs(colorBox.Text), 1)
        if not r then note("Tags", "Color: name, #hex, r,g,b or r g b", RED); return end
        Cfg.tags[tostring(uid)] = {
            text = text, sub = subBox.Text:sub(1, 40), color = { r, g, b }, rainbow = rainbowSw.get(),
            size = sizeSl.get(), offset = offSl.get(), font = TAG_FONTS[fontIdx],
        }
        cfgSave()
        Tags.refresh(uid)
        refreshPlayers()
        note("Tags", "Tag saved", LIGHT)
    end)
    uiButton(f, "Remove tag", UDim2.new(0.5, -20, 0, 32), UDim2.new(0.5, 4, 0, 512), function()
        if not guard() then return end
        local uid = targetId()
        if not uid or not Cfg.tags[tostring(uid)] then note("Tags", "That target has no tag"); return end
        Cfg.tags[tostring(uid)] = nil
        Tags.destroy(uid)
        cfgSave()
        refreshPlayers()
        note("Tags", "Tag removed")
    end, true)
    uiButton(f, "Remove ALL tags", UDim2.new(1, -32, 0, 28), UDim2.fromOffset(16, 556), function()
        if not guard() then return end
        for k in pairs(Cfg.tags) do Tags.destroy(tonumber(k)) end
        Cfg.tags = {}
        cfgSave()
        refreshPlayers()
        note("Tags", "All tags removed")
    end, true)

    UIAPI.syncFns.tags = function()
        if f.Visible then refreshPlayers() end
    end
    f:GetPropertyChangedSignal("Visible"):Connect(function()
        if f.Visible then
            if not canEditTags() then f.Visible = false; return end
            refreshPlayers()
        end
    end)
    refreshPlayers()
end

local function buildPanels(screenGui)
    -- listeners from a previous UI instance must not keep pointing at destroyed frames
    Reanim.listeners = {}
    buildToolsPanel(screenGui)
    buildMovementPanel(screenGui)
    buildEspPanel(screenGui)
    buildFloorPanel(screenGui)
    buildReanimPanel(screenGui)
    buildTagPanel(screenGui)
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

    local scrollFrame = make("ScrollingFrame", {
        Size = UDim2.new(1, -20, 1, -90),
        Position = UDim2.new(0, 10, 0, 80),
        BackgroundTransparency = 1,
        ScrollBarThickness = 2,
        ScrollBarImageColor3 = Color3.fromRGB(100, 100, 100),
        CanvasSize = UDim2.new(0, 0, 0, 0),
        AutomaticCanvasSize = Enum.AutomaticSize.Y,
    }, helpFrame)
    make("UIListLayout", { Padding = UDim.new(0, 8), SortOrder = Enum.SortOrder.LayoutOrder }, scrollFrame)

    for idx, c in ipairs(cmds) do
        local entry = make("Frame", {
            Size = UDim2.new(1, -10, 0, 30),
            BackgroundColor3 = Color3.fromRGB(20, 20, 20),
            BackgroundTransparency = 0.4,
            BorderSizePixel = 0,
            LayoutOrder = idx,
        }, scrollFrame)
        make("UICorner", { CornerRadius = UDim.new(0, 6) }, entry)
        make("TextLabel", {
            Size = UDim2.new(1, -10, 1, 0),
            Position = UDim2.new(0, 10, 0, 0),
            BackgroundTransparency = 1,
            Text = cmdDocs[c],
            TextColor3 = Color3.new(1, 1, 1),
            Font = Enum.Font.Code,
            TextSize = 12,
            TextXAlignment = Enum.TextXAlignment.Left,
            TextTruncate = Enum.TextTruncate.AtEnd,
        }, entry)
        helpEntries[c] = entry
    end

    searchBox:GetPropertyChangedSignal("Text"):Connect(function()
        local query = searchBox.Text:lower()
        for c, entry in pairs(helpEntries) do
            entry.Visible = query == "" or c:find(query, 1, true) ~= nil or cmdDocs[c]:lower():find(query, 1, true) ~= nil
        end
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

    settingsFrame = windowFrame(UDim2.new(0, 360, 0, 556), "SETTINGS")

    fieldLabel(settingsFrame, "Chat command prefixes (comma separated, 1-3 symbols)", 45)
    local prefixBox = fieldBox(settingsFrame, 65, table.concat(Cfg.prefixes, ", "))
    local prefixApply = actionButton(settingsFrame, "Apply", UDim2.new(1, -85, 0, 65), UDim2.new(0, 70, 0, 28))
    prefixApply.MouseButton1Click:Connect(function()
        local list = parsePrefixList(prefixBox.Text)
        if #list == 0 then note("Prefix", "1-3 symbols, no letters/digits/spaces", RED); return end
        Cfg.prefixes = list
        cfgSave()
        prefixBox.Text = table.concat(list, ", ")
        note("Prefix", table.concat(list, "  "), LIGHT)
    end)

    fieldLabel(settingsFrame, "Show/hide UI key (KeyCode name, e.g. RightControl)", 105)
    local keyBox = fieldBox(settingsFrame, 125, Cfg.uiKey)
    local keyApply = actionButton(settingsFrame, "Apply", UDim2.new(1, -85, 0, 125), UDim2.new(0, 70, 0, 28))
    keyApply.MouseButton1Click:Connect(function()
        local kc = resolveKeyCode(keyBox.Text)
        if not kc then note("UI Key", "Unknown key", RED); return end
        Cfg.uiKey = kc.Name
        keyBox.Text = kc.Name
        cfgSave()
        note("UI Key", kc.Name, LIGHT)
    end)

    for i, p in ipairs({ { "Tools", "tools" }, { "Reanim", "reanim" }, { "Move", "move" }, { "ESP", "esp" }, { "Floor", "floor" } }) do
        actionButton(settingsFrame, p[1], UDim2.new(0, 15 + (i - 1) * 66, 0, 162), UDim2.new(0, 62, 0, 28)).MouseButton1Click:Connect(function()
            UIAPI.togglePanel(p[2])
        end)
    end

    -- Theme: presets, then one row per colour role (hex, r,g,b or a colour name)
    fieldLabel(settingsFrame, "UI theme", 200)
    for i, p in ipairs(Theme.presets) do
        local b = actionButton(settingsFrame, p.name, UDim2.new(0, 15 + (i - 1) * 56, 0, 220), UDim2.new(0, 52, 0, 26))
        b.TextSize = 11
        b.MouseButton1Click:Connect(function()
            Theme.usePreset(p.name)
            note("Theme", p.name, LIGHT)
        end)
    end
    fieldLabel(settingsFrame, "Colors: #hex, r,g,b or a name (press Enter to apply)", 256)
    local themeRows = {}
    for i, role in ipairs(Theme.roles) do
        local y = 276 + (i - 1) * 32
        make("TextLabel", {
            Size = UDim2.new(0, 110, 0, 26), Position = UDim2.new(0, 15, 0, y), BackgroundTransparency = 1,
            Text = Theme.labels[role], TextColor3 = Color3.new(1, 1, 1), Font = Enum.Font.Code, TextSize = 12,
            TextXAlignment = Enum.TextXAlignment.Left,
        }, settingsFrame)
        local sw = make("Frame", {
            Name = "PuppyAdminSwatch", Size = UDim2.new(0, 26, 0, 26), Position = UDim2.new(0, 130, 0, y),
            BackgroundColor3 = Theme.current[role], BorderSizePixel = 0,
        }, settingsFrame)
        make("UICorner", { CornerRadius = UDim.new(0, 6) }, sw)
        make("UIStroke", { Color = Color3.fromRGB(100, 100, 100), Transparency = 0.4, Thickness = 1 }, sw)
        local holder = make("Frame", {
            Size = UDim2.new(1, -181, 0, 26), Position = UDim2.new(0, 166, 0, y),
            BackgroundColor3 = Color3.fromRGB(5, 5, 5), BackgroundTransparency = 0.5, BorderSizePixel = 0,
        }, settingsFrame)
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
    end
    table.insert(Theme.listeners, function()
        for role, row in pairs(themeRows) do
            row.swatch.BackgroundColor3 = Theme.current[role]
            if not row.box:IsFocused() then row.box.Text = Theme.hex(Theme.current[role]) end
        end
    end)

    local killBtn = actionButton(settingsFrame, "KILL SCRIPT", UDim2.new(0, 15, 1, -45), UDim2.new(1, -30, 0, 32), Color3.fromRGB(130, 35, 35))
    killBtn.MouseButton1Click:Connect(function() shutdown(false) end)

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
        local hum = chr:FindFirstChildOfClass("Humanoid")
        if hum then hum.Health = 0 end
    end
end

------------------------------------------------------------------------
-- Brand intro: title text fades in on execute, holds, fades out after 5s.
-- Style only - no copyrighted logo, font or imagery is reproduced.
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
    local titleFont = safeFont("Garamond", Enum.Font.GothamBold)
    local subFont = safeFont("SourceSansItalic", Enum.Font.SourceSansItalic)
    local GOLD = Color3.fromRGB(255, 221, 150)

    local function titleLabel(size, color)
        return make("TextLabel", {
            AnchorPoint = Vector2.new(0.5, 0.5),
            Position = UDim2.new(0.5, 0, 0.42, 0),
            Size = UDim2.fromOffset(700, 100),
            BackgroundTransparency = 1,
            Font = titleFont,
            Text = "PUPPY ADMIN",
            TextSize = size,
            TextColor3 = color,
            TextTransparency = 1,
            TextStrokeTransparency = 1,
        }, holder)
    end

    -- two oversized, more-transparent copies behind the crisp one fake a soft glow
    local glowOuter = titleLabel(60, GOLD)
    local glowInner = titleLabel(56, GOLD)
    local main = titleLabel(50, Color3.fromRGB(255, 255, 255))
    make("UIGradient", {
        Color = ColorSequence.new({
            ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 250, 235)),
            ColorSequenceKeypoint.new(0.5, GOLD),
            ColorSequenceKeypoint.new(1, Color3.fromRGB(255, 250, 235)),
        }),
    }, main)

    local sub = make("TextLabel", {
        AnchorPoint = Vector2.new(0.5, 0.5),
        Position = UDim2.new(0.5, 0, 0.42, 48),
        Size = UDim2.fromOffset(500, 30),
        BackgroundTransparency = 1,
        Font = subFont,
        Text = "r e a n i m a t i o n  &  a d m i n  t o o l s",
        TextSize = 15,
        TextColor3 = GOLD,
        TextTransparency = 1,
    }, holder)

    local fadeIn = TweenInfo.new(1.1, Enum.EasingStyle.Sine, Enum.EasingDirection.Out)
    local fadeOut = TweenInfo.new(1.1, Enum.EasingStyle.Sine, Enum.EasingDirection.In)
    TweenService:Create(glowOuter, fadeIn, { TextTransparency = 0.8 }):Play()
    TweenService:Create(glowInner, fadeIn, { TextTransparency = 0.6 }):Play()
    TweenService:Create(main, fadeIn, { TextTransparency = 0 }):Play()
    TweenService:Create(sub, fadeIn, { TextTransparency = 0.3 }):Play()

    task.delay(5, function()
        if not g.Parent then return end
        for _, lbl in ipairs({ glowOuter, glowInner, main, sub }) do
            TweenService:Create(lbl, fadeOut, { TextTransparency = 1 }):Play()
        end
        task.delay(1.3, function() if g.Parent then g:Destroy() end end)
    end)
end

------------------------------------------------------------------------
-- Runtime
------------------------------------------------------------------------

showBrandIntro()
createUI()
Watch.start()
Chat.start()

table.insert(conns, UserInputService.InputBegan:Connect(function(input, processed)
    if processed then return end
    if input.UserInputType ~= Enum.UserInputType.Keyboard then
        Teleport.onClick(input)
        return
    end
    local key = input.KeyCode.Name
    if Anim.capture then
        local name = Anim.capture
        Anim.capture = nil
        if key ~= "Escape" then
            for k, v in pairs(Cfg.binds) do if v == name then Cfg.binds[k] = nil end end
            if key ~= "Backspace" and key ~= "Delete" then Cfg.binds[key] = name end
            cfgSave()
        end
        Reanim.changed()
        return
    end
    if key == Cfg.uiKey then
        Hide.setUI(not Hide.uiHidden)
        return
    end
    local animName = Cfg.binds[key]
    if animName then Anim.toggle(animName) end
end))

table.insert(conns, chr.ChildAdded:Connect(function(c)
    if c:IsA("Tool") then
        task.wait()
        setupTool(c)
    end
end))

for _, v in ipairs(chr:GetChildren()) do
    if v:IsA("Tool") then setupTool(v) end
end

local function isGrip(obj)
    return obj.Name == "RightGrip" and obj:IsA("JointInstance")
end

for _, obj in ipairs(chr:GetDescendants()) do
    if isGrip(obj) then obj:Destroy() end
end
table.insert(conns, chr.DescendantAdded:Connect(function(obj)
    if isGrip(obj) then obj:Destroy() end
end))

table.insert(conns, RunService.RenderStepped:Connect(function(dt)
    if not genv.PuppyAdminActive then return end
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

    Aura.step(time, dt)
    Tags.step(time)

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

table.insert(conns, plr.CharacterAdded:Connect(function(newChar)
    -- reanimation swaps your Character on purpose; only a real respawn ends the script
    if Reanim.active or Reanim.starting or os.clock() < Reanim.ignoreUntil or newChar.Name == "PuppyAdminClone" then return end
    shutdown(false)
end))

sendFlatNotification("System", "Puppy Admin ready - " .. firstPrefix() .. "help in chat", LIGHT)

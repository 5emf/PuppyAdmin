local M = host_load(host_read(TOOLS .. "/mock.lua"), "=mock")()
local env = {}
for _, k in ipairs({"string","table","math","bit32","buffer","os","utf8","coroutine","debug","pairs","ipairs","next","select","type","tostring","tonumber","pcall","xpcall","error","assert","rawget","rawset","rawequal","rawlen","setmetatable","getmetatable","unpack","newproxy","getfenv","setfenv","print","loadstring","gcinfo"}) do env[k] = _G[k] end
env._G = env
local function demock(...)
  local a = table.pack(...)
  for i = 1, a.n do if M.registry[a[i]] then a[i] = 0 end end
  return table.unpack(a, 1, a.n)
end
local function wraplib(lib)
  local t = {}
  for k, f in pairs(lib) do
    if type(f) == "function" then t[k] = function(...) return f(demock(...)) end else t[k] = f end
  end
  return t
end
env.math = wraplib(math)
local str = wraplib(string)
str.format = function(fmt, ...) return string.format(fmt, demock(...)) end
env.string = str
pcall(function() getmetatable("").__index = str end)
env.tostring = function(v) if M.registry[v] then return M.registry[v].path end return tostring(v) end
env._VERSION = "Luau"
for _, k in ipairs({"game","workspace","Instance","Vector3","Vector2","CFrame","Color3","UDim2","UDim","TweenInfo","Enum","task","Ray","RaycastParams","NumberSequence","NumberSequenceKeypoint","ColorSequence","ColorSequenceKeypoint","NumberRange","Rect","BrickColor","PhysicalProperties","OverlapParams","Font","DateTime","Random","script","shared","plugin","settings","UserSettings","Region3","Axes","Faces"}) do env[k] = M.mk(k) end
env.typeof = function(v) if M.registry[v] then return "Instance" end return type(v) end
env.tick = os.clock
env.time = os.clock
env.wait = function() return 0, 0 end
env.spawn = function() end
env.delay = function() end
env.warn = function(...) M.L("WARN " .. table.concat({...}, " ")) end
setmetatable(env, {__index = function(t, k)
  if k == "AK_ADMIN_EXECUTED" then return nil end
  local m = M.mk(tostring(k)); rawset(t, k, m); M.L("GLOBAL " .. tostring(k)); return m
end})
return env, M

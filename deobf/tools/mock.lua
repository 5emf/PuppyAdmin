-- generic Roblox mock: every unknown access returns a logged proxy
local M = {}
local LOG = {}
M.log = LOG
local registry = setmetatable({}, {__mode="k"})
M.registry = registry
local function L(s) local lg = M.log; local n = #lg; if n > 300000 then error("LOG_LIMIT") end; lg[n+1]=s end
M.L = L
local mk
local mt = {}
mt.__index = function(t, k)
  local info = registry[t]
  local r = rawget(info.children, k)
  if r ~= nil then return r end
  local c = mk(info.path .. "." .. tostring(k), info.typ)
  info.children[k] = c
  L("GET " .. info.path .. "." .. tostring(k))
  return c
end
mt.__newindex = function(t, k, v)
  local info = registry[t]
  L("SET " .. info.path .. "." .. tostring(k) .. " = " .. M.fmt(v))
  info.children[k] = v
end
mt.__call = function(t, ...)
  local info = registry[t]
  local a = table.pack(...)
  local parts = {}
  for i=1,a.n do parts[i]=M.fmt(a[i]) end
  L("CALL " .. info.path .. "(" .. table.concat(parts, ", ") .. ")")
  if info.onCall then return info.onCall(...) end
  if a.n >= 1 and a[1] == nil and info.path:sub(-1) == ")" then return nil end
  local last = info.path:match("%.([%w_]+)$")
  if last and (last == "GetChildren" or last == "GetDescendants" or last == "GetPlayers" or last == "GetTags" or last == "GetTagged" or last == "GetAttributes" or last == "GetConnections") then return {} end
  if last == "Wait" or info.path == "task.wait" or info.path == "wait" then
    M.waits = (M.waits or 0) + 1
    if (M.spawndepth or 0) > 0 and M.waits > 40 then error("SPAWN_YIELD_LIMIT") end
    if M.waits > 5000 then error("MAIN_YIELD_LIMIT") end
    return 0.25, 0.25
  end
  if info.path == "task.spawn" or info.path == "task.defer" or info.path == "spawn" or info.path == "task.delay" or info.path == "delay" then
    local f = a[1]; local i = 2
    if info.path == "task.delay" or info.path == "delay" then f = a[2]; i = 3 end
    if type(f) == "function" then
      local sw = M.waits; M.waits = 0; M.spawndepth = (M.spawndepth or 0) + 1
      local ok, e = pcall(f, table.unpack(a, i, a.n))
      M.spawndepth = M.spawndepth - 1; M.waits = sw
      L("SPAWNED " .. tostring(ok) .. " " .. M.fmt(e))
    end
    return nil
  end
  return mk(info.path .. "()", info.typ)
end
mt.__tostring = function(t) return registry[t].name or registry[t].path end
local function arith(name) return function(a, b)
  local p = (registry[a] and registry[a].path or tostring(a)) .. name .. (registry[b] and registry[b].path or tostring(b))
  return mk("(" .. p .. ")", "Mock")
end end
for _, n in ipairs({"__add","__sub","__mul","__div","__mod","__pow","__idiv","__concat"}) do mt[n] = arith(n) end
mt.__unm = function(a) return a end
mt.__eq = function(a,b) return rawequal(a,b) end
mt.__lt = function() return false end
mt.__le = function() return true end
mt.__len = function() return 0 end
mt.__iter = function() return next, {} end
mk = function(path, typ)
  local p = newproxy(true)
  local m = getmetatable(p)
  for k, v in pairs(mt) do m[k] = v end
  registry[p] = {path = path, children = {}, typ = typ or "Mock"}
  return p
end
M.mk = mk
function M.fmt(v)
  local t = type(v)
  if t == "string" then return string.format("%q", v) end
  if registry[v] then return "<" .. registry[v].path .. ">" end
  if t == "table" or t == "function" or t == "userdata" or t == "thread" then return "<" .. t .. ">" end
  return tostring(v)
end
return M

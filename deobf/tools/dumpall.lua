TOOLS = host_args[1]
local env, M = host_load(host_read(TOOLS .. "/env.lua"), "=env")()
local f, err = host_load(host_read(host_args[2]), "=obf", env)
assert(f, err)
local T = f()
T.ri = function(self, hJ) return function(main, ...) end end
T:ui()
local out = {}
local function w(s) out[#out+1] = s end
local function hex(s) return (s:gsub(".", function(c) return string.format("%02x", string.byte(c)) end)) end
local function val(v, nodeidx)
  local t = type(v)
  if t == "nil" then return "nil" end
  if t == "boolean" then return v and "true" or "false" end
  if t == "number" then
    if v ~= v then return "nan" end
    if v == math.huge then return "inf" end
    if v == -math.huge then return "-inf" end
    return string.format("%.17g", v)
  end
  if t == "string" then return "s" .. hex(v) end
  if t == "table" then
    if nodeidx and nodeidx[v] then return "@" .. nodeidx[v] end
    local parts = {}
    for k, x in pairs(v) do parts[#parts+1] = val(k, nodeidx) .. "=" .. val(x, nodeidx) end
    table.sort(parts)
    return "{" .. table.concat(parts, ",") .. "}"
  end
  return "?" .. t
end
local np = 0
for i = 0, 100000 do
  local ok, p = pcall(T.gO, i)
  if not ok or p == nil then break end
  np = i
  local zP = T:eW(p[8])
  local ins = p[1]
  local nodeidx = {}
  for k, n in pairs(ins) do nodeidx[n] = k end
  w(string.format("P %d %s %s %s %s %s %s %s", i, val(p[4]), val(p[5]), val(p[6]), val(p[7]), val(p[8]), val(p[9]), zP and table.concat(zP, ",") or ""))
  local kmax = -1
  for k in pairs(ins) do if type(k) == "number" and k > kmax then kmax = k end end
  for k = 0, kmax do
    local n = ins[k]
    if n then
      local fs = {}
      for j = 1, 8 do fs[j] = val(n[zP[j]], nodeidx) end
      w("I " .. k .. " " .. table.concat(fs, " "))
    end
  end
  local gc = p[2]
  local VZ = rawget(gc, T.kw)
  local keys = {}
  for k in pairs(gc) do if type(k) == "number" then keys[k] = true end end
  if VZ then for k in pairs(VZ) do keys[k] = true end end
  for k in pairs(keys) do
    w("K " .. val(k) .. " " .. val(gc[k]))
  end
  local ye = p[3]
  for k, v in pairs(ye) do w("Y " .. val(k) .. " " .. val(v)) end
end
host_write(host_args[3], table.concat(out, "\n") .. "\n")
print("protos", np + 1, "kw", T.kw, "qh", T.qh, "Cs", T.Cs)

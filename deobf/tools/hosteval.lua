TOOLS = host_args[1]
local env, M = host_load(host_read(TOOLS .. "/env.lua"), "=env")()
local f, err = host_load(host_read(host_args[2]), "=obf", env)
local T = f()
T.ri = function(self, hJ) return function(main, ...) end end
T:ui()
local out = {}
for line in string.gmatch(host_read(host_args[3]), "[^\n]+") do
  local parts = {}
  for p in string.gmatch(line, "%S+") do parts[#parts+1] = p end
  local name = table.remove(parts, 1)
  local args = {}
  for i, p in ipairs(parts) do args[i] = tonumber(p) end
  local ok, r = pcall(T[name], T, table.unpack(args))
  out[#out+1] = ok and type(r) == "number" and string.format("%.17g", r) or "ERR"
end
host_write(host_args[4], table.concat(out, "\n") .. "\n")

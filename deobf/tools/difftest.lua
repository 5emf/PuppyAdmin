TOOLS = host_args[1]
local WORK = host_args[2]
local mode = host_args[3]
local src = host_read(TOOLS .. "/irvm_src.lua")
src = src:gsub("\n%s*", " ")
local envf = host_load(host_read(TOOLS .. "/env.lua"), "=env")
local env, M = envf()
for _, k in ipairs({"task"}) do end
math.randomseed(1)
host_deadline(tonumber(host_args[4] or "20"))
local ok, err
if mode == "orig" then
	local f = host_load(host_read(WORK .. "/orig.lua"), "=obf", env)
	ok, err = pcall(f)
	host_deadline(1e9)
elseif mode == "src" then
	local tf = host_load(host_read(WORK .. "/tbl.lua"), "=obf", env)
	local T = tf()
	T.ri = function(self, hJ) return function() end end
	T:ui()
	rawset(env, "__VM_STATE__", T:yu()); rawset(env, "__VM_CHARMAP__", T.j)
	rawset(env, "__VM_REGISTERS__", {}); rawset(env, "__VM_CONSTANTS__", {}); rawset(env, "__VM_CURRENT_INSN__", {})
	local code = host_read(WORK .. "/akadmin_decompiled.lua")
	local lines = {}
	for line in string.gmatch(code, "[^\n]+") do
		local t = line:match("^%s*(.-)$")
		if t:sub(1, 2) ~= "--" then
			t = t:gsub("goto (L%d+)", "error('GOTO %1')"):gsub("::L%d+::", "")
			lines[#lines + 1] = t
		end
	end
	local f, e = host_load(table.concat(lines, " "), "=obf", env)
	assert(f, e)
	ok, err = pcall(f)
	host_deadline(1e9)
else
	local P = host_load(host_read(WORK .. "/irdata.lua"), "=irdata")()
	local mk = host_load(src, "=obf")
	local tf = host_load(host_read(WORK .. "/tbl.lua"), "=obf", env)
	local T = tf()
	T.ri = function(self, hJ) return function() end end
	T:ui()
	local mkclosure = mk(P, env, {__VM_CHARMAP__ = T.j, __VM_CONSTANTS__ = {}, __VM_CURRENT_INSN__ = {}, __VM_STATE__ = T:yu()})
	local main = mkclosure(0, {})
	setfenv(main, env)
	ok, err = pcall(main)
	host_deadline(1e9)
end
host_deadline(1e9)
M.log[#M.log + 1] = "END " .. tostring(ok) .. " " .. tostring(err)
local out = table.concat(M.log, "\n")
out = out:gsub("0x%x+", "ADDR")
host_write(WORK .. "/trace_" .. mode .. ".txt", out .. "\n")
print(mode, ok, err, #M.log)

local P, ENV, VMV = ...
local unpack = table.unpack
local select = select
local exec
local function mkclosure(pid, cells)
	return function(...) return exec(pid, cells, ...) end
end
local function V(R, o)
	if type(o) == "table" then return o[1] end
	return R[o]
end
local function cmp(rel, a, b)
	if rel == "==" then return a == b end
	if rel == "~=" then return a ~= b end
	if rel == "<" then return a < b end
	if rel == "<=" then return a <= b end
	if rel == ">" then return a > b end
	return a >= b
end
local ARITH = {
	ADD = function(a, b) return a + b end, SUB = function(a, b) return a - b end,
	MUL = function(a, b) return a * b end, DIV = function(a, b) return a / b end,
	MOD = function(a, b) return a % b end, POW = function(a, b) return a ^ b end,
}
exec = function(pid, cells, ...)
	local proto = P[pid]
	local code = proto.code
	local R = {}
	local open = {}
	local args = table.pack(...)
	local np = proto.np
	for i = 1, np do R[i - 1] = args[i] end
	local va = {}
	local nva = 0
	for i = np + 1, args.n do nva = nva + 1; va[nva] = args[i] end
	local top = -1
	local pc = 1
	while true do
		local x = code[pc]
		pc = pc + 1
		local op = x[1]
		if op == "MOVE" then R[x[2]] = V(R, x[3])
		elseif op == "LOADK" then R[x[2]] = x[3][1]
		elseif op == "LOADBOOL" then R[x[2]] = (x[3] == 1)
		elseif op == "LOADNIL" then for i = x[2], x[3] do R[i] = nil end
		elseif op == "VMVAL" then
			local k = x[3]
			if k == "getfenv()" then R[x[2]] = ENV
			elseif k == "__VM_REGISTERS__" then R[x[2]] = R
			else R[x[2]] = VMV[k] end
		elseif op == "GETUPVAL" then local c = cells[x[3] + 1]; R[x[2]] = c.t[c.i]
		elseif op == "SETUPVAL" then local c = cells[x[3] + 1]; c.t[c.i] = V(R, x[2])
		elseif op == "GETGLOBALR" then R[x[2]] = ENV[V(R, x[3])]
		elseif op == "SETGLOBALR" then ENV[V(R, x[3])] = V(R, x[2])
		elseif op == "GETTABLE" then R[x[2]] = V(R, x[3])[V(R, x[4])]
		elseif op == "SETTABLE" then R[x[2]][V(R, x[3])] = V(R, x[4])
		elseif op == "NEWTABLE" then R[x[2]] = {}
		elseif op == "SELF" then local o = V(R, x[3]); R[x[2] + 1] = o; R[x[2]] = o[V(R, x[4])]
		elseif ARITH[op] then R[x[2]] = ARITH[op](V(R, x[3]), V(R, x[4]))
		elseif op == "UNM" then R[x[2]] = -V(R, x[3])
		elseif op == "NOT" then R[x[2]] = not V(R, x[3])
		elseif op == "LEN" then R[x[2]] = #V(R, x[3])
		elseif op == "CONCAT" then local s = R[x[3]]; for i = x[3] + 1, x[4] do s = s .. R[i] end; R[x[2]] = s
		elseif op == "APPEND" then R[x[2]] = R[x[2]] .. V(R, x[3])
		elseif op == "JMP" then pc = x[2] + 1
		elseif op == "CMP" then if cmp(x[2], V(R, x[3]), V(R, x[4])) then pc = x[5] + 1 end
		elseif op == "TEST" then
			local v = V(R, x[2])
			if x[3] == 1 then if v then pc = x[4] + 1 end else if not v then pc = x[4] + 1 end end
		elseif op == "TESTSET" then
			local v = V(R, x[3])
			if (x[4] == 1 and v) or (x[4] == 0 and not v) then R[x[2]] = v; pc = x[5] + 1 end
		elseif op == "RETURN" then
			local a, b = x[2], x[3]
			if b == 0 then return unpack(R, a, top) end
			if b == 1 then return end
			return unpack(R, a, a + b - 2)
		elseif op == "CALL" then
			local a, b, c = x[2], x[3], x[4]
			local last = (b == 0) and top or (a + b - 1)
			local f = R[a]
			if f == nil then error("IRVM nil call pid=" .. pid .. " pc=" .. (pc - 2) .. " reg=" .. a) end
			if c == 1 then f(unpack(R, a + 1, last))
			elseif c == 2 then R[a] = f(unpack(R, a + 1, last))
			else
				local res = table.pack(f(unpack(R, a + 1, last)))
				if c == 0 then
					for i = 1, res.n do R[a + i - 1] = res[i] end
					top = a + res.n - 1
				else
					for i = 1, c - 1 do R[a + i - 1] = res[i] end
				end
			end
		elseif op == "TAILCALL" then
			local a, b = x[2], x[3]
			local last = (b == 0) and top or (a + b - 1)
			return R[a](unpack(R, a + 1, last))
		elseif op == "FORPREP" then local a = x[2]; R[a] = R[a] - R[a + 2]; pc = x[3] + 1
		elseif op == "FORLOOP" then
			local a = x[2]; local st = R[a + 2]; local i = R[a] + st; R[a] = i
			if st > 0 then if i <= R[a + 1] then pc = x[3] + 1; R[a + 3] = i end
			elseif i >= R[a + 1] then pc = x[3] + 1; R[a + 3] = i end
		elseif op == "TFORLOOP" then
			local a, c = x[2], x[3]
			local f = R[a]
			if f == nil then for i = 1, c do R[a + i + 2] = nil end
			else
				local res = table.pack(f(R[a + 1], R[a + 2]))
				for i = 1, c do R[a + i + 2] = res[i] end
			end
			if R[a + 3] then R[a + 2] = R[a + 3]; pc = x[4] + 1 end
		elseif op == "VARARG" then
			local a, b = x[2], x[3]
			if b == 0 then for i = 1, nva do R[a + i - 1] = va[i] end; top = a + nva - 1
			else for i = 1, b - 1 do R[a + i - 1] = va[i] end end
		elseif op == "SETLIST" then
			local a, b, c = x[2], x[3], x[4]
			local last = (b == 0) and top or (a + b)
			local t = R[a]; local base = (c - 1) * 50
			for i = a + 1, last do t[base + i - a] = R[i] end
		elseif op == "CLOSE" then
			local a = x[2]
			for i = #open, 1, -1 do
				local cl = open[i]
				if cl.t == R and cl.i >= a then cl.t = { [cl.i] = R[cl.i] } end
			end
		elseif op == "CLOSURE" then
			local nc = {}
			for k, d in ipairs(x[4]) do
				if d[1] == 0 then local cl = { t = R, i = d[2] }; nc[k] = cl; open[#open + 1] = cl
				else nc[k] = cells[d[2] + 1] end
			end
			R[x[2]] = mkclosure(x[3], nc)
		else error("bad op " .. tostring(op)) end
	end
end
return mkclosure

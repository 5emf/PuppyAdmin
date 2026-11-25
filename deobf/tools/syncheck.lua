local src = host_read(host_args[1])
src = src:gsub("goto (L%d+)", "--[[goto %1]]"):gsub("::(L%d+)::", "--[[label %1]]")
local f, err = host_load(src, "=decompiled")
print(f and "SYNTAX OK" or ("SYNTAX ERROR: " .. tostring(err)))

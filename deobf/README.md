# AKADMIN_FULL_RAW_1.lua: devirtualized

| File | What it is |
|---|---|
| `AKADMIN_deobfuscated.lua` | Decompiled source, about 14.1k lines. The header comment explains the naming conventions and what was verified. |
| `AKADMIN_disasm.txt` | Lifted IR (Lua 5.1-style ops) for all 1678 prototypes, with constants resolved. Use it to check the decompiler against the raw instructions. |
| `tools/` | The pipeline that produced both files (Python 3 + Luau). |
| `host/` | A small Rust/mlua Luau host. It runs the loader, evaluates the obfuscator's helper functions, and runs the differential test. |

## Re-run

```bash
bash tools/run.sh /path/to/AKADMIN_FULL_RAW_1.lua   # needs cargo + python3
# outputs: work/akadmin_decompiled.lua, work/akadmin_disasm.txt
```

The pipeline is tied to this obfuscator build. It depends on the dispatch hash
(`(op+25104)*34589+7783 % 65521` in `tools/dispatch.py`), the internal member names
(`ri`/`ie`/`vg`/`QO`/`kw`/`qh`) and the string-decryptor algorithm in `tools/post.py`.
Any of these can change in a re-obfuscated build. When that happens the run stops
with an assertion or classifier error. It does not produce wrong output silently.

## Differential test (optional)

```bash
python3 tools/irdump.py
host/target/release/host tools/difftest.lua tools work orig 40   # original VM
host/target/release/host tools/difftest.lua tools work ir 40     # lifted IR
host/target/release/host tools/difftest.lua tools work src 40    # decompiled source
diff work/trace_orig.txt work/trace_ir.txt
```

## Known gaps

* 16 `goto`/`::L::` pairs are still unstructured. Luau has no goto, so those spots need
  manual rewriting before the file can run.
* Local names are register-based (`v12`, `v2_40`). Only names that came from the
  obfuscator's own native functions are single letters.
* The prologue before `_G.AK_ADMIN_EXECUTED` is obfuscator runtime, not AK Admin code.

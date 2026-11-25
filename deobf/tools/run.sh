#!/usr/bin/env bash
# Usage: tools/run.sh /path/to/AKADMIN_obfuscated.lua
# Rebuilds work/ and writes work/akadmin_decompiled.lua + work/akadmin_disasm.txt
set -euo pipefail
D="$(cd "$(dirname "$0")/.." && pwd)"
T="$D/tools"; W="$D/work"; H="$D/host/target/release/host"
mkdir -p "$W"
[ -x "$H" ] || (cd "$D/host" && cargo build --release)
cp "$1" "$W/orig.lua"
python3 - "$W/orig.lua" "$W/tbl.lua" <<'PY'
import sys
s=open(sys.argv[1]).read().rstrip()
suf=':ui()(...);'
assert s.endswith('})'+suf), 'unexpected loader tail'
open(sys.argv[2],'w').write(s[:-len(suf)])
PY
rm -f "$W"/*.pkl "$W/callcache.json"
"$H" "$T/dumpall.lua" "$T" "$W/tbl.lua" "$W/protos.txt"
python3 "$T/extract_handlers.py"
python3 "$T/run_decomp.py"
python3 "$T/dis.py"
"$H" "$T/syncheck.lua" "$W/akadmin_decompiled.lua"

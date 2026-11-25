import sys,os
sys.path.insert(0,os.path.dirname(os.path.abspath(__file__)))
from decomp import *
def lit(v):
    if v is None: return 'nil'
    if v is True: return 'true'
    if v is False: return 'false'
    if isinstance(v,bytes): return '"'+''.join('\\%d'%c for c in v)+'"'
    if isinstance(v,float):
        if v!=v: return '(0/0)'
        if v in(float('inf'),-float('inf')): return '(1/0)' if v>0 else '(-1/0)'
        return repr(v)
    return str(v)
def opnd(v):
    if isinstance(v,Kv): return '{'+lit(v.v)+'}'
    if isinstance(v,list): return '{'+','.join('{%d,%d}'%(t,i) for t,i in v)+'}'
    if isinstance(v,str): return '"'+v+'"'
    return lit(v)
P=load(); out=['local P={}']
for p in P:
    ir=build_ir(p); pass_slots(p,ir); pass_strings(p,ir); pass_globals(p,ir)
    code=linearize(ir)
    rows=[]
    for x in code:
        rows.append('{"'+x[0]+'",'+','.join(opnd(a) for a in x[1:])+'}')
    out.append('P[%d]={np=%d,code={%s}}'%(p.id,int(p.nparams),','.join(rows)))
out.append('return P')
open(WORK+'/irdata.lua','w').write('\n'.join(out))

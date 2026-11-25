import sys,os
sys.path.insert(0,os.path.dirname(os.path.abspath(__file__)))
from decomp import *
from luaprint import qstr
def fmtv(v):
    if isinstance(v,Kv):
        x=v.v
        return qstr(x) if isinstance(x,bytes) else repr(x)
    return 'r%d'%v if isreg(v) else repr(v)
def dis(p,code):
    out=['-- proto %d  params=%s maxstack=%s'%(p.id,p.nparams,p.maxstack)]
    for i,x in enumerate(code):
        out.append('%5d  %-10s %s'%(i,x[0],' '.join(fmtv(a) if not isinstance(a,list) else repr(a) for a in x[1:])))
    return '\n'.join(out)
if __name__=='__main__':
    P=load(); allp={p.id:p for p in P}
    res=[]
    for p in P:
        ir=build_ir(p); pass_slots(p,ir); pass_strings(p,ir); pass_globals(p,ir)
        res.append(dis(p,linearize(ir)))
    open(WORK+'/akadmin_disasm.txt','w').write('\n\n'.join(res))

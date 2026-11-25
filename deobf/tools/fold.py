import math
CONSTK=('Num','Str','True','False','Nil')
def isc(e): return e[0] in CONSTK
def cval(e):
    k=e[0]
    if k=='Num': return e[1]
    if k=='Str': return e[1]
    if k=='True': return True
    if k=='False': return False
    return None
def mk(v):
    if v is None: return ['Nil']
    if v is True: return ['True']
    if v is False: return ['False']
    if isinstance(v,(bytes,str)): return ['Str',v if isinstance(v,bytes) else v.encode()]
    if isinstance(v,float) and v==int(v) and abs(v)<2**53: v=int(v)
    if isinstance(v,int) and v<0: return ['Un','-',['Num',-v]]
    if isinstance(v,float) and v<0: return ['Un','-',['Num',-v]]
    return ['Num',v]
def truthy(v): return v is not None and v is not False
def lmod(a,b):
    if b==0: return float('nan')
    if isinstance(a,int) and isinstance(b,int): return a%b
    return a-math.floor(a/b)*b
def binop(op,a,b):
    if op=='==': return a==b and type(a)==type(b) or (isinstance(a,(int,float)) and isinstance(b,(int,float)) and a==b)
    if op=='~=': return not binop('==',a,b)
    num=lambda x: isinstance(x,(int,float)) and not isinstance(x,bool)
    if op in('+','-','*','/','%','^','//','<','>','<=','>='):
        if not(num(a) and num(b)):
            raise ValueError
    if op=='+': return a+b
    if op=='-': return a-b
    if op=='*': return a*b
    if op=='/': return a/b if b!=0 else (float('nan') if a==0 else math.copysign(float('inf'),a))
    if op=='%': return lmod(a,b)
    if op=='//': return math.floor(a/b)
    if op=='^': return float(a)**b
    if op=='<': return a<b
    if op=='>': return a>b
    if op=='<=': return a<=b
    if op=='>=': return a>=b
    if op=='..':
        def s(x):
            if isinstance(x,bytes): return x
            if num(x): 
                if isinstance(x,float) and x==int(x): x=int(x)
                return str(x).encode()
            raise ValueError
        return s(a)+s(b)
    raise ValueError
def u32(x): return int(x)%2**32
BITF={
 'bxor':lambda *a: _red(lambda x,y:x^y,a,0),
 'band':lambda *a: _red(lambda x,y:x&y,a,0xffffffff),
 'bor':lambda *a: _red(lambda x,y:x|y,a,0),
 'rshift':lambda a,b: u32(a)>>int(b) if 0<=b<32 else 0,
 'lshift':lambda a,b: (u32(a)<<int(b))%2**32 if 0<=b<32 else 0,
 'lrotate':lambda a,b: ((u32(a)<<(int(b)%32))|(u32(a)>>(32-int(b)%32)))%2**32,
 'rrotate':lambda a,b: ((u32(a)>>(int(b)%32))|(u32(a)<<(32-int(b)%32)))%2**32,
 'bnot':lambda a: (~u32(a))%2**32,
}
def _red(f,a,init):
    r=init
    for x in a: r=f(r,u32(x))
    return r
class Folder:
    def __init__(s,aliases,callcache=None):
        s.al=aliases  # name -> ('const',v) | ('bit',fname) | ('floor',)
        s.cc=callcache if callcache is not None else {}
        s.pending=set()
        s.env={}
    def f(s,e):
        k=e[0]
        if k in CONSTK: return e
        if k=='Name':
            if e[1] in s.env: return mk(s.env[e[1]])
            return e
        if k=='Paren':
            x=s.f(e[1])
            if isc(x) or x[0] in('Name','Index','Un') and not (x[0]=='Un' and x[1]=='-' and False): 
                if isc(x) or x[0]=='Name': return x
            if x[0]=='Un' and x[1]=='-' and isc(x[2]): return x
            if x[0] in ('Call','Method','Vararg'): return ['Paren',x]
            return x if x[0]!='Paren' else x
        if k=='Un':
            x=s.f(e[2])
            v=s.const(x)
            if v is not NOTC:
                if e[1]=='not': return mk(not truthy(v))
                if e[1]=='-' and isinstance(v,(int,float)) and not isinstance(v,bool): return mk(-v)
                if e[1]=='#' and isinstance(v,bytes): return mk(len(v))
            if e[1]=='not':
                if x[0]=='Un' and x[1]=='not':
                    inner=x[2]
                    if inner[0]=='Bin' and inner[1] in('==','~=','<','>','<=','>=') or inner[0]=='Un' and inner[1]=='not': return inner
                    return ['Un','not',['Un','not',inner]]
                if x[0]=='Bin' and x[1] in('==','~='): return ['Bin','~=' if x[1]=='==' else '==',x[2],x[3]]
            return ['Un',e[1],x]
        if k=='Bin':
            op=e[1]; a=s.f(e[2]); b=s.f(e[3])
            va=s.const(a); vb=s.const(b)
            if op=='and':
                if va is not NOTC: return b if truthy(va) else a
                return ['Bin',op,a,b]
            if op=='or':
                if va is not NOTC: return a if truthy(va) else b
                if vb is not NOTC and a[0]=='Index' and a[1]==['Index',['Name','Mv'],['Str',b'v']]: return b
                if vb is False and a[0]=='Bin' and a[1] in('==','~=','<','>','<=','>='): return a
                return ['Bin',op,a,b]
            if va is not NOTC and vb is not NOTC:
                try: return mk(binop(op,va,vb))
                except (ValueError,TypeError,OverflowError,ZeroDivisionError): pass
            return ['Bin',op,a,b]
        if k=='Index':
            o=s.f(e[1]); key=s.f(e[2])
            if o==['Name','Mv'] and key[0]=='Str':
                a=s.al.get(key[1].decode() if isinstance(key[1],bytes) else key[1])
                if a and a[0]=='const': return mk(a[1])
            return ['Index',o,key]
        if k=='Call':
            fn=e[1]
            while fn[0]=='Paren': fn=fn[1]
            if fn[0]=='Function':
                args=[s.f(x) for x in e[2]]
                cv=[s.const(x) for x in args]
                if all(v is not NOTC for v in cv):
                    r=exec_const(s,fn,cv)
                    if r is not NOTC and not isinstance(r,(bytes,)) and r is not None: return mk(r)
            fn=s.f(e[1]); args=[s.f(x) for x in e[2]]
            if fn[0]=='Index' and fn[1]==['Name','Mv'] and fn[2][0]=='Str':
                nm=fn[2][1].decode()
                a=s.al.get(nm)
                selfcall = bool(args) and args[0]==['Name','Mv']
                cv=[s.const(x) for x in (args[1:] if selfcall else args)]
                if all(v is not NOTC for v in cv):
                    try:
                        if a and a[0]=='bit': return mk(BITF[a[1]](*cv))
                        if a and a[0]=='floor': return mk(math.floor(cv[0]))
                    except Exception: pass
                    if a and a[0]=='method' and selfcall:
                        key=(nm,tuple(cv))
                        if key in s.cc: return mk(s.cc[key])
                        s.pending.add(key)
            return ['Call',fn,args]
        if k=='Method':
            o=s.f(e[1]); args=[s.f(x) for x in e[3]]
            if o==['Name','Mv'] and s.al.get(e[2],('',))[0]=='method':
                cv=[s.const(x) for x in args]
                if all(v is not NOTC for v in cv):
                    key=(e[2],tuple(cv))
                    if key in s.cc: return mk(s.cc[key])
                    s.pending.add(key)
            return ['Method',o,e[2],args]
        if k=='Function': return e
        if k=='Table': return ['Table',[(it[0],)+tuple(s.f(x) for x in it[1:]) for it in e[1]]]
        if k=='IfExpr': return ['IfExpr',[(s.f(c),s.f(a)) for c,a in e[1]],s.f(e[2])]
        return e
    def const(s,e):
        if isc(e): return cval(e)
        if e[0]=='Un' and e[1]=='-' and e[2][0]=='Num': return -e[2][1]
        return NOTC
NOTC=object()

class _Ret(Exception):
    def __init__(s,v): s.v=v
class _Brk(Exception): pass
class _Fail(Exception): pass
def exec_const(fd, fn, args):
    """Concretely execute a function literal with constant args; returns value or NOTC."""
    old=fd.env
    fd.env=dict(old)
    for i,p in enumerate(fn[1]): fd.env[p]=args[i] if i<len(args) else None
    steps=[0]
    def ev(e):
        r=fd.f(e); v=fd.const(r)
        if v is NOTC: raise _Fail()
        return v
    def run(b):
        for st in b:
            steps[0]+=1
            if steps[0]>100000: raise _Fail()
            k=st[0]
            if k=='Local':
                vals=[ev(x) for x in st[2]]
                for i,n in enumerate(st[1]): fd.env[n]=vals[i] if i<len(vals) else None
            elif k=='Assign':
                vals=[ev(x) for x in st[2]]
                for i,t in enumerate(st[1]):
                    v=vals[i] if i<len(vals) else None
                    if t[0]=='Name': fd.env[t[1]]=v
                    elif t[0]=='Index' and t[1]==['Index',['Name','Mv'],['Str',b'v']]: LASTV[0]=v
                    else: raise _Fail()
            elif k=='If':
                for c,bb in st[1]:
                    if truthy(ev(c)): run(bb); break
                else:
                    if st[2]: run(st[2])
            elif k=='While':
                try:
                    while truthy(ev(st[1])): run(st[2])
                except _Brk: pass
            elif k=='Repeat':
                try:
                    while True:
                        run(st[1])
                        if truthy(ev(st[2])): break
                except _Brk: pass
            elif k=='NumFor':
                a=ev(st[2]); b2=ev(st[3]); c=ev(st[4]) if st[4] else 1
                i=a
                try:
                    while (c>0 and i<=b2) or (c<0 and i>=b2):
                        fd.env[st[1]]=i; run(st[5]); i+=c
                except _Brk: pass
            elif k=='Do': run(st[1])
            elif k=='Break': raise _Brk()
            elif k=='Return':
                if len(st[1])!=1: raise _Fail()
                e=st[1][0]
                if e[0]=='Paren': e=e[1]
                if e[0]=='Index' and e[1]==['Index',['Name','Mv'],['Str',b'v']]:
                    raise _Ret(LASTV[0])
                raise _Ret(ev(e))
            else: raise _Fail()
    LASTV=[NOTC]
    # track Mv.v assignments value
    def run_wrap(b):
        pass
    # patch Assign to capture Mv.v values
    orig_run=run
    def run2(b):
        for st in b:
            if st[0]=='Assign' and len(st[1])==1 and st[1][0][0]=='Index' and st[1][0][1]==['Index',['Name','Mv'],['Str',b'v']]:
                LASTV[0]=ev(st[2][0])
        return None
    try:
        # simple approach: wrap fd.f for Assign capture by pre-walking in run
        def run3(b):
            for st in b:
                if st[0]=='Assign' and len(st[1])==1 and st[1][0][0]=='Index' and st[1][0][1]==['Index',['Name','Mv'],['Str',b'v']]:
                    LASTV[0]=ev(st[2][0])
            return orig_run(b)
        globals()['_runhook']=run3
        nonlocal_run=run
        try:
            _run_with_capture(run, fd, ev, LASTV, fn[3])
        except _Ret as r:
            return r.v
        except (_Fail,_Brk):
            return NOTC
        return None
    finally:
        fd.env=old
def _run_with_capture(run, fd, ev, LASTV, body):
    # monkey: intercept Mv.v assigns by scanning just-before execution
    import types
    def walkcap(b):
        for st in b:
            if st[0]=='Assign' and len(st[1])==1 and st[1][0][0]=='Index' and st[1][0][1]==['Index',['Name','Mv'],['Str',b'v']]:
                st.append('__cap__') if '__cap__' not in st else None
    run(body)

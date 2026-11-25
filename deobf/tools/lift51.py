import sys,os,struct,math
sys.path.insert(0,os.path.dirname(__file__))
from protos import *
from classify import classify_all
CL,_bad=classify_all()
NIL=('nil',)
class Kv:
    """constant operand"""
    __slots__=('v',)
    def __init__(s,v): s.v=v
    def __repr__(s): return 'K(%r)'%(s.v,)
def ev(f,o):
    k,ofs=o; v=f['ABCD'.index(k)+1]
    return v+ofs if isinstance(v,(int,float)) and not isinstance(v,bool) else v
def kval(p,x):
    if isinstance(x,(int,float)) and not isinstance(x,bool): return p.K.get(x)
    return x
def layout(p):
    order=[]; placed=set()
    targets=[]
    def chain(n):
        seq=[]
        while n is not None and n not in placed:
            placed.add(n); seq.append(n)
            f=p.ins[n]
            for x in f[1:4]:
                if isinstance(x,Ref): targets.append(x.i)
            nx=f[5]; n=nx.i if isinstance(nx,Ref) else None
        return seq,n
    work=[p.entry]
    while work:
        st=work.pop(0)
        if st in placed: continue
        seq,end=chain(st)
        order.append((seq,end))
        for t in targets:
            if t not in placed: work.append(t)
        targets.clear()
    return order
def build_ir(p):
    """returns list of (node, ir) in layout order; ir is tuple; plus fallthrough jumps"""
    blocks=layout(p)
    ir=[]
    for seq,end in blocks:
        for n in seq:
            f=p.ins[n]; s=CL[f[0]][0]; op=s[0]
            ir.append([n]+lift_one(p,f,s))
        last=ir[-1][1] if ir else None
        if end is not None and last not in ('RETURN','TAILCALL','JMP'):
            ir.append([None,'JMP',end])
        elif seq:
            # chain ended (next nil): fine if last is return/jmp
            pass
    return ir
def R(f,o): return ev(f,o)
def RKo(p,f,o):
    t,k,ofs=o
    v=ev(f,(k,ofs))
    if t=='R': return v
    return Kv(kval(p,v))
def tgt(f,o):
    v=ev(f,o); assert isinstance(v,Ref),(f,o); return v.i
def lift_one(p,f,s):
    op=s[0]
    if op=='MOVE': return ['MOVE',R(f,s[1]),R(f,s[2])]
    if op=='LOADK': return ['LOADK',R(f,s[1]),Kv(kval(p,ev(f,s[2])))]
    if op=='LOADCHAR': return ['LOADK',R(f,s[1]),Kv(bytes([int(ev(f,s[2]))^16]))]
    if op=='APPENDCHAR': return ['APPEND',R(f,s[1]),Kv(bytes([int(ev(f,s[2]))^16]))]
    if op=='LOADBOOL': return ['LOADBOOL',R(f,s[1]),1 if ev(f,s[2])!=0 else 0]
    if op=='LOADNIL': return ['LOADNIL',R(f,s[1]),R(f,s[2])]
    if op=='LOADNIL1': return ['LOADNIL',R(f,s[1]),R(f,s[1])]
    if op=='JUNK': return ['VMVAL',R(f,s[1]),{'Mv.j':'__VM_CHARMAP__','K':'__VM_CONSTANTS__','R':'__VM_REGISTERS__','vy':'getfenv()','Ng':'__VM_CURRENT_INSN__','Mv:yu()':'__VM_STATE__'}[s[2]]]
    if op=='GETUPVAL': return ['GETUPVAL',R(f,s[1]),R(f,s[2])]
    if op=='SETUPVAL': return ['SETUPVAL',R(f,s[1]),R(f,s[2])]  # (reg value, upval idx)
    if op=='GETGLOBALR': return ['GETGLOBALR',R(f,s[1]),R(f,s[2])]
    if op=='SETGLOBALR': return ['SETGLOBALR',R(f,s[1]),R(f,s[2])]
    if op=='GETTABLE': return ['GETTABLE',R(f,s[1]),R(f,s[2]),RKo(p,f,s[3])]
    if op=='SETTABLE': return ['SETTABLE',R(f,s[1]),RKo(p,f,s[2]),RKo(p,f,s[3])]
    if op=='SETTABLE_RORK': return ['SETTABLE',R(f,s[1]),R(f,s[2]),RKo(p,f,s[3])]
    if op=='NEWTABLE': return ['NEWTABLE',R(f,s[1])]
    if op=='SELF': return ['SELF',R(f,s[1]),R(f,s[2]),RKo(p,f,s[3])]
    if op in('ADD','SUB','MUL','DIV','MOD','POW'): return [op,R(f,s[1]),RKo(p,f,s[2]),RKo(p,f,s[3])]
    if op in('UNM','NOT','LEN'): return [op,R(f,s[1]),R(f,s[2])]
    if op=='CONCAT': return ['CONCAT',R(f,s[1]),R(f,s[2]),R(f,s[3])]
    if op=='JMP': return ['JMP',tgt(f,s[1])]
    if op=='CMP': return ['CMP',s[1],RKo(p,f,s[2]),RKo(p,f,s[3]),tgt(f,s[4])]
    if op=='TEST': return ['TEST',R(f,s[1]),s[2],tgt(f,s[3])]
    if op=='TESTSET': return ['TESTSET',R(f,s[1]),R(f,s[2]),s[3],tgt(f,s[4])]
    if op=='RETURN':
        a=R(f,s[1]); n=s[2]
        return ['RETURN',a,0 if n=='MULT' else n+1]
    if op=='RETURNB': return ['RETURN',R(f,s[1]),R(f,s[2])+2]
    if op=='FORPREP': return ['FORPREP',R(f,s[1]),tgt(f,s[2])]
    if op=='FORLOOP': return ['FORLOOP',R(f,s[1]),tgt(f,s[2])]
    if op=='TFORLOOP': return ['TFORLOOP',R(f,s[1]),R(f,s[2]),tgt(f,s[3])]
    if op=='VARARG':
        a=R(f,s[1]); return ['VARARG',a,0 if s[2]=='MULT' else R(f,s[2])]
    if op=='CALL': return ['CALL',R(f,s[1]),R(f,s[2]),R(f,s[3])]
    if op=='TAILCALL': return ['TAILCALL',R(f,s[1]),R(f,s[2])]
    if op=='SETLIST':
        a=R(f,s[1])
        b=0 if s[2]=='MULT' else R(f,s[2])-a
        return ['SETLIST',a,b,R(f,s[3])]
    if op=='CLOSE': return ['CLOSE',R(f,s[1])]
    if op=='CLOSURE':
        b=int(ev(f,s[2])); key=b^int(p.pL); cid=p.Y.get(key,key)
        ups=[]
        if s[3] is not None:
            nup=int(ev(f,s[3])); D=ev(f,s[4]) or {}
            for i in range(1,nup+1):
                d=D[i]; ups.append((d[0],d[1]))
        return ['CLOSURE',R(f,s[1]),cid,ups]
    if op=='NOP': return ['NOP']
    raise ValueError(op)

# ---------------- IR passes ----------------
REGREAD={ # op -> indices of register-read operands in ir list (ir[0]=node, ir[1]=op)
 'MOVE':[3],'GETTABLE':[3,4],'SETTABLE':[2,3,4],'SELF':[3,4],'ADD':[3,4],'SUB':[3,4],'MUL':[3,4],'DIV':[3,4],'MOD':[3,4],'POW':[3,4],
 'UNM':[3],'NOT':[3],'LEN':[3],'CMP':[3,4],'TEST':[2],'TESTSET':[3],'GETGLOBALR':[3],'SETGLOBALR':[2,3],'SETUPVAL':[2],'APPEND':[2],
}
def pass_slots(p,ir):
    from decomp import rw
    slots={}; bad=set()
    for x in ir:
        op=x[1]
        if op in('NOP','JMP'): continue
        if op=='CLOSURE':
            for t,i in x[4]:
                if t==0: bad.add(i)
        if op=='LOADK':
            r=x[2]
            if r in slots and repr(slots[r].v)!=repr(x[3].v): bad.add(r)
            slots[r]=x[3]
            continue
        R_,W=rw(x[1:])
        if op=='TESTSET': W={x[2]}
        bad|=W
        okpos={x[i] for i in REGREAD.get(op,[]) if isinstance(x[i],int) and not isinstance(x[i],bool)}
        for r in R_:
            if r not in okpos: bad.add(r)
        if op=='SETTABLE' and isinstance(x[2],int): bad.add(x[2])
        if op=='APPEND': bad.add(x[2])
    for r in bad: slots.pop(r,None)
    for x in ir:
        op=x[1]
        if op=='LOADK' and x[2] in slots: x[1]='NOP'; del x[2:]; continue
        for i in REGREAD.get(op,[]):
            v=x[i]
            if isinstance(v,int) and v in slots: x[i]=slots[v]
    return slots
def jump_targets(ir):
    t=set()
    for x in ir:
        op=x[1]
        if op in('JMP',): t.add(x[2])
        elif op=='CMP': t.add(x[5])
        elif op=='TEST': t.add(x[4])
        elif op=='TESTSET': t.add(x[5])
        elif op in('FORPREP','FORLOOP'): t.add(x[3])
        elif op=='TFORLOOP': t.add(x[4])
    return t
def pass_strings(p,ir):
    T=jump_targets(ir)
    i=0;n=len(ir)
    while i<n:
        x=ir[i]
        if x[1]=='LOADK' and isinstance(x[3].v,bytes):
            r=x[2]; j=i+1; acc=x[3].v; last=i
            while j<n:
                y=ir[j]
                if y[0] in T: break
                if y[1]=='NOP': j+=1; continue
                if y[1]=='APPEND' and y[2]==r and isinstance(y[3],Kv) and isinstance(y[3].v,bytes):
                    acc+=y[3].v; y[1]='NOP'; del y[2:]; last=j; j+=1; continue
                break
            x[3]=Kv(acc)
            i=last+1
        else: i+=1
def pass_globals(p,ir):
    # GETGLOBALR with real register key loaded by LOADK just before
    T=jump_targets(ir)
    for i,x in enumerate(ir):
        if x[1] in('GETGLOBALR','SETGLOBALR'):
            k=x[3]
            if isinstance(k,Kv): continue
            j=i-1
            while j>=0 and ir[j][1]=='NOP' : j-=1
            y=ir[j]
            if y[1]=='LOADK' and y[2]==k and ir[i][0] not in T:
                x[3]=y[3]
                # drop the load if the register is overwritten before being read again (simple scan)
                if not reg_read_later(ir,i+1,k,T): y[1]='NOP'; del y[2:]
def reg_read_later(ir,start,r,T):
    for x in ir[start:start+200]:
        op=x[1]
        if op in('NOP',): continue
        if op in('JMP','CMP','TEST','TESTSET','FORPREP','FORLOOP','TFORLOOP','RETURN','TAILCALL','CALL','VARARG','SETLIST','CLOSE','CLOSURE','CONCAT'): return True
        for i2 in REGREAD.get(op,[]):
            if x[i2]==r: return True
        if len(x)>2 and x[2]==r and op not in('SETTABLE','SETGLOBALR','SETUPVAL','TEST'): return False
    return True

# ---------------- Lua 5.1 emitter ----------------
OPN={n:i for i,n in enumerate('MOVE LOADK LOADBOOL LOADNIL GETUPVAL GETGLOBAL GETTABLE SETGLOBAL SETUPVAL SETTABLE NEWTABLE SELF ADD SUB MUL DIV MOD POW UNM NOT LEN CONCAT JMP EQ LT LE TEST TESTSET CALL TAILCALL RETURN FORLOOP FORPREP TFORLOOP SETLIST CLOSE CLOSURE VARARG'.split())}
def ABC(op,a,b,c):
    assert 0<=a<256 and 0<=b<512 and 0<=c<512,(op,a,b,c)
    return OPN[op]|(a<<6)|(c<<14)|(b<<23)
def ABx(op,a,bx):
    assert 0<=a<256 and 0<=bx<2**18,(op,a,bx)
    return OPN[op]|(a<<6)|(bx<<14)
class FuncOut:
    def __init__(s,p):
        s.p=p; s.code=[]; s.K=[]; s.kidx={}; s.protos=[]; s.fix=[]; s.label={}
        s.tbase=p.maxstack; s.maxtemp=0; s.vararg=False; s.nups=0
    def k(s,v):
        if isinstance(v,bool): key=('b',v)
        elif v is None: key=('n',)
        elif isinstance(v,(int,float)): key=('d',repr(float(v)))
        else: key=('s',v)
        if key not in s.kidx: s.kidx[key]=len(s.K); s.K.append(v)
        return s.kidx[key]
    def temp(s,i):
        s.maxtemp=max(s.maxtemp,i+1); return s.tbase+i
    def reg(s,v,ti):
        """ensure v is a register; materialize constants into temp ti"""
        if isinstance(v,Kv):
            t=s.temp(ti); s.loadk(t,v.v); return t
        return v
    def rk(s,v,ti):
        if isinstance(v,Kv):
            i=s.k(v.v)
            if i<256: return 256+i
            t=s.temp(ti); s.loadk(t,v.v); return t
        return v
    def loadk(s,a,v):
        if v is None: s.code.append(ABC('LOADNIL',a,a,0))
        elif v is True or v is False: s.code.append(ABC('LOADBOOL',a,1 if v else 0,0))
        else: s.code.append(ABx('LOADK',a,s.k(v)))
    def jmp(s,target):
        s.fix.append((len(s.code),target)); s.code.append(None)
    def emit(s,x,children):
        op=x[1]; c=s.code
        if op=='NOP': return
        if op=='MOVE':
            if isinstance(x[3],Kv): s.loadk(x[2],x[3].v)
            else: c.append(ABC('MOVE',x[2],x[3],0))
        elif op=='LOADK': s.loadk(x[2],x[3].v)
        elif op=='APPEND':
            a=x[2]; t0=s.temp(0); t1=s.temp(1)
            c.append(ABC('MOVE',t0,a,0)); s.loadk(t1,x[3].v); c.append(ABC('CONCAT',a,t0,t1))
        elif op=='LOADBOOL': c.append(ABC('LOADBOOL',x[2],x[3],0))
        elif op=='LOADNIL': c.append(ABC('LOADNIL',x[2],x[3],0))
        elif op=='GETUPVAL': c.append(ABC('GETUPVAL',x[2],x[3],0))
        elif op=='SETUPVAL': c.append(ABC('SETUPVAL',s.reg(x[2],0),x[3],0))
        elif op=='GETGLOBALR':
            if isinstance(x[3],Kv) and isinstance(x[3].v,bytes): c.append(ABx('GETGLOBAL',x[2],s.k(x[3].v)))
            else:
                # unknown key: getfenv-style access, emit _G[key]
                t=s.temp(0); c.append(ABx('GETGLOBAL',t,s.k(b'_G'))); c.append(ABC('GETTABLE',x[2],t,s.rk(x[3],1)))
        elif op=='SETGLOBALR':
            val=s.reg(x[2],0)
            if isinstance(x[3],Kv) and isinstance(x[3].v,bytes): c.append(ABx('SETGLOBAL',val,s.k(x[3].v)))
            else:
                t=s.temp(1); c.append(ABx('GETGLOBAL',t,s.k(b'_G'))); c.append(ABC('SETTABLE',t,s.rk(x[3],2),val))
        elif op=='GETTABLE': c.append(ABC('GETTABLE',x[2],s.reg(x[3],0),s.rk(x[4],1)))
        elif op=='SETTABLE':
            b=s.rk(x[3],0); cc=s.rk(x[4],1); c.append(ABC('SETTABLE',x[2],b,cc))
        elif op=='NEWTABLE': c.append(ABC('NEWTABLE',x[2],0,0))
        elif op=='SELF': c.append(ABC('SELF',x[2],s.reg(x[3],0),s.rk(x[4],1)))
        elif op in('ADD','SUB','MUL','DIV','MOD','POW'):
            b=s.rk(x[3],0); cc=s.rk(x[4],1); c.append(ABC(op,x[2],b,cc))
        elif op in('UNM','NOT','LEN'): c.append(ABC(op,x[2],s.reg(x[3],0),0))
        elif op=='CONCAT': c.append(ABC('CONCAT',x[2],x[3],x[4]))
        elif op=='JMP': s.jmp(x[2])
        elif op=='CMP':
            rel=x[2]; a=x[3]; b=x[4]
            if rel=='==': o,flag,l,r='EQ',1,a,b
            elif rel=='~=': o,flag,l,r='EQ',0,a,b
            elif rel=='<': o,flag,l,r='LT',1,a,b
            elif rel=='<=': o,flag,l,r='LE',1,a,b
            elif rel=='>': o,flag,l,r='LT',1,b,a
            elif rel=='>=': o,flag,l,r='LE',1,b,a
            l=s.rk(l,0); r=s.rk(r,1)
            c.append(ABC(o,flag,l,r)); s.jmp(x[5])
        elif op=='TEST': c.append(ABC('TEST',s.reg(x[2],0),0,x[3])); s.jmp(x[4])
        elif op=='TESTSET': c.append(ABC('TESTSET',x[2],s.reg(x[3],0),x[4])); s.jmp(x[5])
        elif op=='RETURN': c.append(ABC('RETURN',x[2],x[3],0))
        elif op=='FORPREP': s.fix.append((len(c),x[3],'FORPREP',x[2])); c.append(None)
        elif op=='FORLOOP': s.fix.append((len(c),x[3],'FORLOOP',x[2])); c.append(None)
        elif op=='TFORLOOP': c.append(ABC('TFORLOOP',x[2],0,x[3])); s.jmp(x[4])
        elif op=='VARARG': s.vararg=True; c.append(ABC('VARARG',x[2],x[3],0))
        elif op=='CALL': c.append(ABC('CALL',x[2],x[3],x[4]))
        elif op=='TAILCALL': c.append(ABC('TAILCALL',x[2],x[3],0)); c.append(ABC('RETURN',x[2],0,0))
        elif op=='SETLIST': c.append(ABC('SETLIST',x[2],x[3],x[4]))
        elif op=='CLOSE': c.append(ABC('CLOSE',x[2],0,0))
        elif op=='CLOSURE':
            idx=len(s.protos); s.protos.append((x[3],len(x[4])))
            c.append(ABx('CLOSURE',x[2],idx))
            for t,i in x[4]:
                if t==0: c.append(ABC('MOVE',0,i,0))
                else: c.append(ABC('GETUPVAL',0,i,0))
        else: raise ValueError(op)
    def finish(s):
        for fx in s.fix:
            pc=fx[0]; t=fx[1]
            tp=s.label[t]
            off=tp-(pc+1)
            if len(fx)==2: s.code[pc]=ABx('JMP',0,off+131071)
            else: s.code[pc]=ABx(fx[2],fx[3],off+131071)
def compile_proto(p):
    ir=build_ir(p)
    pass_slots(p,ir); pass_strings(p,ir); pass_globals(p,ir)
    fo=FuncOut(p)
    for x in ir:
        if x[0] is not None and x[0] not in fo.label: fo.label[x[0]]=len(fo.code)
        fo.emit(x,None)
    # labels for nodes that emitted nothing point to next emitted pc -- already handled (label set before emit)
    fo.finish()
    return fo,ir
def ser_str(b):
    if b is None: return struct.pack('<Q',0)
    return struct.pack('<Q',len(b)+1)+b+b'\0'
def ser_func(fo,allf,nups,src=None):
    p=fo.p
    out=[ser_str(src),struct.pack('<ii',0,0)]
    ms=min(255,max(2,p.maxstack+fo.maxtemp))
    out.append(bytes([nups,int(p.nparams),2 if (fo.vararg or p.id==0) else 0,ms]))
    out.append(struct.pack('<i',len(fo.code))+b''.join(struct.pack('<I',x) for x in fo.code))
    out.append(struct.pack('<i',len(fo.K)))
    for v in fo.K:
        if v is None: out.append(b'\0')
        elif isinstance(v,bool): out.append(b'\1'+bytes([1 if v else 0]))
        elif isinstance(v,(int,float)): out.append(b'\3'+struct.pack('<d',float(v)))
        else: out.append(b'\4'+ser_str(v))
    out.append(struct.pack('<i',len(fo.protos)))
    for cid,nu in fo.protos:
        out.append(ser_func(allf[cid],allf,nu))
    out.append(struct.pack('<iii',0,0,0))
    return b''.join(out)
HEADER=b'\x1bLua'+bytes([0x51,0,1,4,8,4,8,0])
def build_all(P):
    allf={}
    for p in P:
        fo,ir=compile_proto(p); allf[p.id]=fo
    return allf
if __name__=='__main__':
    P=load()
    allf=build_all(P)
    data=HEADER+ser_func(allf[0],allf,0,b'=AKADMIN')
    open(WORK+'/akadmin.luac','wb').write(data)
    print('wrote',len(data),'bytes; max temps',max(f.maxtemp for f in allf.values()),'max ms',max(f.p.maxstack for f in allf.values()))

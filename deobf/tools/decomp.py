import sys,os,re
sys.path.insert(0,os.path.dirname(__file__))
from lift51 import *
from luaprint import blk as pblk, ex as pex, isname
from vmx import walk
BRANCH={'JMP','CMP','TEST','TESTSET','FORPREP','FORLOOP','TFORLOOP','RETURN','TAILCALL'}
def linearize(ir):
    lab={}; out=[]
    for x in ir:
        if x[0] is not None and x[0] not in lab: lab[x[0]]=len(out)
        if x[1]=='NOP': continue
        out.append(list(x[1:]))
    end=len(out)
    def L(n): return lab.get(n,end)
    for x in out:
        op=x[0]
        if op=='JMP': x[1]=L(x[1])
        elif op=='CMP': x[4]=L(x[4])
        elif op=='TEST': x[3]=L(x[3])
        elif op=='TESTSET': x[4]=L(x[4])
        elif op in('FORPREP','FORLOOP'): x[2]=L(x[2])
        elif op=='TFORLOOP': x[3]=L(x[3])
    if not out or out[-1][0] not in('RETURN','TAILCALL','JMP'):
        out.append(['RETURN',0,1])
    return out
def target_of(x):
    op=x[0]
    if op=='JMP': return x[1]
    if op=='CMP': return x[4]
    if op=='TEST': return x[3]
    if op=='TESTSET': return x[4]
    if op in('FORPREP','FORLOOP'): return x[2]
    if op=='TFORLOOP': return x[3]
    return None
def isreg(v): return isinstance(v,int) and not isinstance(v,bool)
def rw(x,top=None):
    """reads, writes register sets; top = open-multret start register if known"""
    op=x[0]; R=set(); W=set()
    def r(v):
        if isreg(v): R.add(v)
    if op=='MOVE': W.add(x[1]); r(x[2])
    elif op in('LOADK','LOADBOOL','GETUPVAL','NEWTABLE','VMVAL'): W.add(x[1])
    elif op=='LOADNIL': W.update(range(x[1],x[2]+1))
    elif op=='SETUPVAL': r(x[1])
    elif op=='GETGLOBALR': W.add(x[1]); r(x[2])
    elif op=='SETGLOBALR': r(x[1]); r(x[2])
    elif op=='GETTABLE': W.add(x[1]); r(x[2]); r(x[3])
    elif op=='SETTABLE': r(x[1]); r(x[2]); r(x[3])
    elif op=='SELF': W.update((x[1],x[1]+1)); r(x[2]); r(x[3])
    elif op in('ADD','SUB','MUL','DIV','MOD','POW'): W.add(x[1]); r(x[2]); r(x[3])
    elif op in('UNM','NOT','LEN'): W.add(x[1]); r(x[2])
    elif op=='CONCAT': W.add(x[1]); R.update(range(x[2],x[3]+1))
    elif op=='APPEND': r(x[1]); W.add(x[1])
    elif op=='CMP': r(x[2]); r(x[3])
    elif op=='TEST': r(x[1])
    elif op=='TESTSET': r(x[2])
    elif op=='RETURN':
        if x[2]==0: R.update(range(x[1],(top if top is not None else x[1])+1))
        else: R.update(range(x[1],x[1]+x[2]-1))
    elif op=='CALL':
        a,b,c=x[1],x[2],x[3]
        if b==0: R.update(range(a,(top if top is not None else a)+1))
        else: R.update(range(a,a+b))
        if c==0: W.add(a)
        else: W.update(range(a,a+c-1))
    elif op=='TAILCALL':
        a,b=x[1],x[2]
        if b==0: R.update(range(a,(top if top is not None else a)+1))
        else: R.update(range(a,a+b))
    elif op=='FORPREP': R.update((x[1],x[1]+1,x[1]+2)); W.add(x[1])
    elif op=='FORLOOP': W.add(x[1]+3)
    elif op=='TFORLOOP': W.update(range(x[1]+3,x[1]+3+max(1,x[2])))
    elif op=='VARARG':
        if x[2]==0: W.add(x[1])
        else: W.update(range(x[1],x[1]+x[2]-1))
    elif op=='SETLIST':
        a,b=x[1],x[2]; R.add(a)
        if b==0: R.update(range(a+1,(top if top is not None else a+1)+1))
        else: R.update(range(a+1,a+b+1))
    elif op=='CLOSURE':
        W.add(x[1])
        for t,i in x[3]:
            if t==0: R.add(i)
    return R,W

class Block:
    __slots__=('id','start','end','succ','pred','stmts','term','dead','use','defs','livein','liveout')
    def __init__(s,i,a,b): s.id=i; s.start=a; s.end=b; s.succ=[]; s.pred=[]; s.stmts=[]; s.term=None; s.dead=False
def make_blocks(code):
    n=len(code); lead={0}
    for i,x in enumerate(code):
        t=target_of(x)
        if t is not None and t<n: lead.add(t)
        if x[0] in BRANCH and i+1<n: lead.add(i+1)
    L=sorted(lead); blocks=[]; at={}
    for k,a in enumerate(L):
        b=L[k+1] if k+1<len(L) else n
        bl=Block(k,a,b); blocks.append(bl); at[a]=bl
    for bl in blocks:
        x=code[bl.end-1]; op=x[0]; i=bl.end-1
        nxt=at.get(bl.end)
        if op=='JMP': bl.succ=[at[x[1]]] if x[1] in at else []
        elif op in('CMP','TEST','TESTSET','FORLOOP','TFORLOOP'):
            bl.succ=[at[target_of(x)]]+([nxt] if nxt else [])
        elif op=='FORPREP': bl.succ=[at[x[2]]]
        elif op in('RETURN','TAILCALL'): bl.succ=[]
        else: bl.succ=[nxt] if nxt else []
        for s in bl.succ: s.pred.append(bl)
    return blocks,at
def liveness(code,blocks):
    for bl in blocks:
        use=set(); d=set(); top=None
        for i in range(bl.start,bl.end):
            x=code[i]
            R,W=rw(x,top)
            if x[0] in('FORLOOP','TFORLOOP'): R=set()
            use|= (R-d); d|=W
            if x[0]=='CALL' and x[3]==0: top=x[1]
            elif x[0]=='VARARG' and x[2]==0: top=x[1]
            elif x[0] in('CALL','RETURN','SETLIST','TAILCALL'): top=None
        bl.use=use; bl.defs=d; bl.livein=set(); bl.liveout=set()
    changed=True
    while changed:
        changed=False
        for bl in reversed(blocks):
            out=set()
            for s in bl.succ: out|=s.livein
            inn=bl.use|(out-bl.defs)
            if out!=bl.liveout or inn!=bl.livein: bl.liveout=out; bl.livein=inn; changed=True

def cexpr(v):
    if v is None: return ['Nil']
    if v is True: return ['True']
    if v is False: return ['False']
    if isinstance(v,bytes): return ['Str',v]
    if isinstance(v,float) and v!=v: return ['Bin','/',['Num',0],['Num',0]]
    if isinstance(v,(int,float)):
        if isinstance(v,float) and v==int(v) and abs(v)<2**53: v=int(v)
        if v<0: return ['Un','-',['Num',-v]]
        return ['Num',v]
    return ['Raw',repr(v)]
def has_call(e):
    r=[False]
    walk(e,lambda n: r.__setitem__(0,True) if n[0] in('Call','Method') else None)
    return r[0]
ARITHOP={'ADD':'+','SUB':'-','MUL':'*','DIV':'/','MOD':'%','POW':'^'}
class FnDecomp:
    def __init__(s,allp,pid,depth,upnames,code_cache):
        s.allp=allp; s.p=allp[pid]; s.depth=depth; s.upnames=upnames; s.cc=code_cache
        s.code=code_cache[pid]
        s.captured=set()
        for x in s.code:
            if x[0]=='CLOSURE':
                for t,i in x[3]:
                    if t==0: s.captured.add(i)
        s.vars=set(); s.singles=set(); s.opens=set()
    def vn(s,r):
        s.vars.add(r)
        return ('v%d'%r) if s.depth==0 else ('v%d_%d'%(s.depth,r))
    def params(s): return [s.vn(i) for i in range(int(s.p.nparams))]
    # ---------- per-block expression building
    def prepass(s,bl):
        code=s.code; info={}; cur={}; top=None
        tabledef=set()
        for i in range(bl.start,bl.end):
            x=code[i]; op=x[0]
            R,W=rw(x,top)
            if op in('FORLOOP','TFORLOOP'): R=set()
            if op in('SETTABLE','SETLIST') and isreg(x[1]) and cur.get(x[1]) in tabledef: R=R-{x[1]} if not (op=='SETTABLE' and (x[2]==x[1] or x[3]==x[1])) else R
            for r in R:
                if r in cur: info[cur[r]][0]+= (2 if op=='CLOSURE' else 1)
            if op=='TESTSET': W=set()
            for r in W:
                d=(i,r); info[d]=[0,False,op]; cur[r]=d
                if op=='NEWTABLE': tabledef.add(d)
            if op=='CALL' and x[3]==0: top=x[1]
            elif op=='VARARG' and x[2]==0: top=x[1]
            elif op in('CALL','RETURN','SETLIST','TAILCALL'): top=None
        for r,d in cur.items(): info[d][1]= r in bl.liveout
        # generic-for setup: block ending in JMP to TFORLOOP block
        s.gf=None
        last=code[bl.end-1]
        if last[0]=='JMP':
            t=last[1]
            if t<len(code) and code[t][0]=='TFORLOOP' and code[t][3]==bl.end:
                a=code[t][1]
                s.gf=a
                for r in (a,a+1,a+2):
                    if r in cur and info[cur[r]][0]==0: info[cur[r]][0]=1; info[cur[r]][1]=False
        s.info=info
    def inl(s,i,r):
        d=s.info.get((i,r))
        if d is None: return False
        return d[0]==1 and not d[1]
    def deadd(s,i,r):
        d=s.info.get((i,r))
        return d is not None and d[0]==0 and not d[1]
    def getr(s,r):
        if isinstance(r,Kv): return cexpr(r.v)
        if r in s.pend:
            return s.pend.pop(r)
        return ['Name',s.vn(r)]
    def emit(s,st):
        s.flush(); s.out.append(st)
    def flush(s):
        for r,e in list(s.pend.items()):
            if e[0]=='SelfArg': continue
            s.out.append(['Assign',[['Name',s.vn(r)]],[e]])
        s.pend.clear()
    def setr(s,i,r,e):
        if s.inl(i,r): s.pend[r]=e; return
        if s.deadd(i,r) and e[0]!='Function':
            if e[0] in('Call','Method'): s.emit(['ExprStat',e])
            elif has_call(e): s.emit(['Assign',[['Name','_']],[e]])
            return
        if r in s.pend: s.pend.pop(r)
        s.emit(['Assign',[['Name',s.vn(r)]],[e]])
    def arglist(s,a,n_or_top,openreg=None):
        """read registers a..b inclusive as expression list"""
        return [s.getr(r) for r in range(a,n_or_top+1)]
    def fixlast(s,lst):
        if lst and id(lst[-1]) in s.singles: lst[-1]=['Paren',lst[-1]]
        return lst
    def build_block(s,bl):
        s.prepass(bl); s.pend={}; s.out=[]; code=s.code; top=None
        term=None
        for i in range(bl.start,bl.end):
            x=code[i]; op=x[0]
            if op=='MOVE': s.setr(i,x[1],s.getr(x[2]))
            elif op=='LOADK': s.setr(i,x[1],cexpr(x[2].v))
            elif op=='VMVAL': s.setr(i,x[1],['Raw',x[2]])
            elif op=='LOADBOOL': s.setr(i,x[1],['True'] if x[2] else ['False'])
            elif op=='LOADNIL':
                for r in range(x[1],x[2]+1): s.setr(i,r,['Nil'])
            elif op=='GETUPVAL': s.setr(i,x[1],['Name',s.upname(x[2])])
            elif op=='SETUPVAL': v=s.getr(x[1]); s.emit(['Assign',[['Name',s.upname(x[2])]],[v]])
            elif op=='GETGLOBALR': s.setr(i,x[1],s.glob(x[2]))
            elif op=='SETGLOBALR':
                v=s.getr(x[1]); s.emit(['Assign',[s.glob(x[2])],[v]])
            elif op=='GETTABLE':
                o=s.getr(x[2]); k=s.getr(x[3]); s.setr(i,x[1],['Index',o,k])
            elif op=='SETTABLE':
                k=s.getr(x[2]); v=s.getr(x[3])
                if x[1] in s.pend and s.pend[x[1]][0]=='Table':
                    t=s.pend[x[1]]
                    t[1].append(('kv',k,v))
                else:
                    o=s.getr(x[1]); s.emit(['Assign',[['Index',o,k]],[v]])
            elif op=='NEWTABLE': s.setr(i,x[1],['Table',[]])
            elif op=='SELF':
                a=x[1]; obj=s.getr(x[2]); key=s.getr(x[3])
                if s.inl(i,a) and s.inl(i,a+1):
                    s.pend[a]=['MethodRef',obj,key]; s.pend[a+1]=['SelfArg']
                else:
                    s.emit(['Assign',[['Name',s.vn(a+1)]],[obj]])
                    s.setr(i,a,['Index',['Name',s.vn(a+1)],key])
            elif op in ARITHOP:
                b=s.getr(x[2]); c=s.getr(x[3]); s.setr(i,x[1],['Bin',ARITHOP[op],b,c])
            elif op=='UNM': s.setr(i,x[1],['Un','-',s.getr(x[2])])
            elif op=='NOT': s.setr(i,x[1],['Un','not',s.getr(x[2])])
            elif op=='LEN': s.setr(i,x[1],['Un','#',s.getr(x[2])])
            elif op=='CONCAT':
                parts=[s.getr(r) for r in range(x[2],x[3]+1)]
                e=parts[-1]
                for pe in reversed(parts[:-1]): e=['Bin','..',pe,e]
                s.setr(i,x[1],e)
            elif op=='APPEND':
                a=s.getr(x[1]); s.setr(i,x[1],['Bin','..',a,s.getr(x[2])])
            elif op=='CALL':
                a,b,c=x[1],x[2],x[3]
                last=(top if b==0 else a+b-1)
                fn=s.getr(a)
                if fn[0]=='MethodRef':
                    s.pend.pop(a+1,None)
                    args=s.fixlast([s.getr(r) for r in range(a+2,last+1)] if last is not None else [])
                    call=['Method',fn[1],fn[2][1].decode() if fn[2][0]=='Str' and isname(fn[2][1]) else None,args] if fn[2][0]=='Str' and isname(fn[2][1]) else ['Call',['Index',fn[1],fn[2]],[fn[1]]+args]
                    if call[0]=='Method' and call[2] is None: call=['Call',['Index',fn[1],fn[2]],[fn[1]]+args]
                else:
                    args=s.fixlast([s.getr(r) for r in range(a+1,last+1)] if last is not None else [])
                    call=['Call',fn,args]
                top=None
                if c==1: s.emit(['ExprStat',call])
                elif c==2:
                    s.singles.add(id(call)); s.setr(i,a,call)
                elif c==0:
                    s.pend[a]=call; top=a
                else:
                    s.emit(['Assign',[['Name',s.vn(r)] for r in range(a,a+c-1)],[call]])
                continue
            elif op=='VARARG':
                a,b=x[1],x[2]
                if b==0: s.pend[a]=['Vararg']; top=a; continue
                elif b==2: e=['Vararg']; s.singles.add(id(e)); s.setr(i,a,e)
                elif b>2: s.emit(['Assign',[['Name',s.vn(r)] for r in range(a,a+b-1)],[['Vararg']]])
            elif op=='SETLIST':
                a,b,c=x[1],x[2],x[3]
                last=(top if b==0 else a+b)
                vals=[s.getr(r) for r in range(a+1,last+1)] if last is not None else []
                vals=s.fixlast(vals)
                if a in s.pend and s.pend[a][0]=='Table':
                    for v in vals: s.pend[a][1].append(('pos',v))
                else:
                    base=(c-1)*50
                    o=['Name',s.vn(a)]
                    for k,v in enumerate(vals): s.emit(['Assign',[['Index',o,cexpr(base+k+1)]],[v]])
                top=None; continue
            elif op=='CLOSE': pass
            elif op=='CLOSURE':
                ups=[]
                for t,ii in x[3]:
                    if t==0 and ii in s.pend:
                        e=s.pend.pop(ii); s.emit(['Assign',[['Name',s.vn(ii)]],[e]])
                    ups.append(s.vn(ii) if t==0 else s.upname(ii))
                sub=FnDecomp(s.allp,x[2],s.depth+1,ups,s.cc)
                body=sub.decompile()
                s.setr(i,x[1],['Function',sub.params(),sub.isvararg(),body])
            elif op=='RETURN':
                a,b=x[1],x[2]
                last=(top if b==0 else a+b-2)
                vals=s.fixlast([s.getr(r) for r in range(a,last+1)] if last is not None else [])
                s.flush(); term=('ret',vals)
            elif op=='TAILCALL':
                a,b=x[1],x[2]; last=(top if b==0 else a+b-1)
                fn=s.getr(a)
                if fn[0]=='MethodRef':
                    s.pend.pop(a+1,None); args=[s.getr(r) for r in range(a+2,last+1)]
                    call=['Method',fn[1],fn[2][1].decode(),args] if fn[2][0]=='Str' and isname(fn[2][1]) else ['Call',['Index',fn[1],fn[2]],[fn[1]]+args]
                else: call=['Call',fn,[s.getr(r) for r in range(a+1,last+1)]]
                s.flush(); term=('ret',[call])
            elif op=='JMP':
                if s.gf is not None:
                    a=s.gf; exprs=[s.getr(r) for r in (a,a+1,a+2)]
                    while len(exprs)>1 and exprs[-1]==['Nil']: exprs.pop()
                    s.flush(); term=('genfor_setup',exprs,x[1])
                else: s.flush(); term=('jmp',x[1])
            elif op=='CMP':
                l=s.getr(x[2]); r_=s.getr(x[3]); s.flush()
                term=('cond',['Bin',x[1],l,r_],x[4],bl.end)
            elif op=='TEST':
                e=s.getr(x[1]); s.flush()
                term=('cond',e if x[2] else ['Un','not',e],x[3],bl.end)
            elif op=='TESTSET':
                src=s.getr(x[2])
                if src[0] not in('Name',) and not (src[0] in('Str','Num','Nil','True','False')):
                    s.emit(['Assign',[['Name',s.vn(x[2])]],[src]]); src=['Name',s.vn(x[2])]
                s.flush()
                term=('testset',src if x[3] else ['Un','not',src],x[4],bl.end,x[1],src)
            elif op=='FORPREP':
                a=x[1]; ex3=[s.getr(r) for r in (a,a+1,a+2)]; s.flush()
                term=('forprep',a,ex3,x[2])
            elif op=='FORLOOP':
                s.flush(); term=('forloop',x[1],x[2],bl.end)
            elif op=='TFORLOOP':
                s.flush(); term=('tforloop',x[1],x[2],x[3],bl.end)
            else: raise ValueError(op)
            if op in('CALL','RETURN','SETLIST','TAILCALL'): top=None
        if term is None:
            s.flush(); term=('fall',bl.end)
        bl.stmts=s.out; bl.term=term
    def upname(s,i):
        if i<len(s.upnames): return s.upnames[i]
        return 'upval%d'%i
    def glob(s,k):
        if isinstance(k,Kv) and isinstance(k.v,bytes):
            if isname(k.v): return ['Name',k.v.decode()]
            return ['Index',['Name','_G'],['Str',k.v]]
        return ['Index',['Name','_G'],s.getr(k)]
    def isvararg(s):
        return any(x[0]=='VARARG' for x in s.code)

def term_succ(t):
    k=t[0]
    if k in('fall','jmp'): return [t[1]]
    if k=='cond': return [t[2],t[3]]
    if k=='testset': return [t[2],t[3]]
    if k=='ret': return []
    if k=='forprep': return [t[3]]
    if k=='forloop': return [t[2],t[3]]
    if k=='genfor_setup': return [t[2]]
    if k=='tforloop': return [t[3],t[4]]
    return []
def neg(e):
    if e[0]=='Un' and e[1]=='not': return e[2]
    if e[0]=='Bin':
        inv={'==':'~=','~=':'==','<':'>=','<=':'>','>':'<=','>=':'<'}
        if e[1] in('==','~='): return ['Bin',inv[e[1]],e[2],e[3]]
    if e[0]=='Bin' and e[1]=='and': return ['Bin','or',neg(e[2]),neg(e[3])]
    if e[0]=='Bin' and e[1]=='or': return ['Bin','and',neg(e[2]),neg(e[3])]
    return ['Un','not',e]
def collapse(blocks,at):
    alive={b.start:b for b in blocks}
    preds={}
    def recompute():
        preds.clear()
        for b in alive.values():
            for t in term_succ(b.term):
                preds.setdefault(t,[]).append(b.start)
    recompute()
    changed=True
    while changed:
        changed=False
        for b in sorted(alive.values(),key=lambda x:-x.start):
            if b.start not in alive or b.term[0]!='cond': continue
            _,cx,T1,F1=b.term
            for Ys in (F1,T1):
                Y=alive.get(Ys)
                if Y is None or Y is b or Y.stmts or Y.term[0]!='cond' or preds.get(Ys,[])!=[b.start]: continue
                _,cy,T2,F2=Y.term
                nt=None
                if Ys==F1 and Ys!=T1:
                    if T2==T1: nt=('cond',['Bin','or',cx,cy],T1,F2)
                    elif F2==T1: nt=('cond',['Bin','or',cx,neg(cy)],T1,T2)
                elif Ys==T1 and Ys!=F1:
                    if F2==F1: nt=('cond',['Bin','and',cx,cy],T2,F1)
                    elif T2==F1: nt=('cond',['Bin','and',cx,neg(cy)],F2,F1)
                if nt:
                    b.term=nt; del alive[Ys]; recompute(); changed=True; break
    return alive
def postdom(alive):
    nodes=sorted(alive); EXIT=-1
    succ={n:[t if t in alive else EXIT for t in term_succ(alive[n].term)] or [EXIT] for n in nodes}
    for n in nodes:
        if alive[n].term[0]=='ret': succ[n]=[EXIT]
    # reverse graph postorder from EXIT
    rpred={n:[] for n in nodes}; rpred[EXIT]=[]
    for n in nodes:
        for t in succ[n]: rpred.setdefault(t,[]).append(n)
    order=[]; seen=set(); 
    stack=[(EXIT,iter(rpred[EXIT]))]; seen.add(EXIT)
    while stack:
        n,it=stack[-1]
        for m in it:
            if m not in seen:
                seen.add(m); stack.append((m,iter(rpred.get(m,[])))); break
        else:
            stack.pop(); order.append(n)
    po={n:i for i,n in enumerate(order)}
    ipd={EXIT:EXIT}
    def inter(a,b):
        while a!=b:
            while po[a]<po[b]: a=ipd[a]
            while po[b]<po[a]: b=ipd[b]
        return a
    changed=True
    rev=list(reversed(order))
    while changed:
        changed=False
        for n in rev:
            if n==EXIT: continue
            cands=[s for s in succ[n] if s in ipd]
            if not cands: continue
            new=cands[0]
            for c in cands[1:]: new=inter(c,new)
            if ipd.get(n)!=new: ipd[n]=new; changed=True
    return {n:(None if v==EXIT else v) for n,v in ipd.items() if n!=EXIT}
class Ctx:
    def __init__(s,exit=None,cont=None,parent=None): s.exit=exit; s.cont=cont; s.parent=parent
def truthiness(e):
    k=e[0]
    if k in('Str','Num','True','Table','Function'): return True
    if k in('Nil','False'): return False
    if k=='Un' and e[1] in('-','#'): return True
    if k=='Bin' and e[1] in('+','-','*','/','%','^','..'): return True
    return None
def fold_const_tests(blocks):
    for b in blocks:
        t=b.term
        if not t or t[0]!='cond': continue
        e=t[1]; negd=False
        if e[0]=='Un' and e[1]=='not': e=e[2]; negd=True
        tv=truthiness(e) if e[0]!='Bin' else None
        if tv is not None:
            if negd: tv=not tv
            b.term=('jmp',t[2] if tv else t[3]); continue
        if not b.stmts: continue
        if e[0]!='Name': continue
        last=b.stmts[-1]
        if last[0]=='Assign' and len(last[1])==1 and last[1][0]==e and len(last[2])==1:
            tv=truthiness(last[2][0])
            if tv is None: continue
            if negd: tv=not tv
            b.term=('jmp',t[2] if tv else t[3])
def fold_andor(alive,fd_vn=lambda r:None):
    def preds():
        P={}
        for b in alive.values():
            for t in term_succ(b.term): P.setdefault(t,set()).add(b.start)
        return P
    def single_assign(B):
        if len(B.stmts)==1 and B.stmts[0][0]=='Assign' and len(B.stmts[0][1])==1 and B.stmts[0][1][0][0]=='Name' and len(B.stmts[0][2])==1:
            return B.stmts[0][1][0][1], B.stmts[0][2][0]
        return None
    def truthy_branch(term,v):
        e=term[1]
        if e==['Name',v]: return term[2],term[3]
        if e==['Un','not',['Name',v]]: return term[3],term[2]
        return None
    def nxt(B):
        t=B.term
        if t[0] in('fall','jmp'): return t[1]
        return None
    changed=True
    while changed:
        changed=False; P=preds()
        for X in sorted(alive.values(),key=lambda b:b.start):
            if X.start not in alive or X.term[0]!='cond': continue
            # shape 0: X ends with v = a ; test v
            if X.stmts and X.stmts[-1][0]=='Assign' and len(X.stmts[-1][1])==1 and X.stmts[-1][1][0][0]=='Name' and len(X.stmts[-1][2])==1:
                v=X.stmts[-1][1][0][1]; tb=truthy_branch(X.term,v)
                if tb:
                    tr,fa=tb
                    for other,op in ((fa,'or'),(tr,'and')):
                        L=alive.get(other)
                        if L is None or P.get(other)!={X.start}: continue
                        sa=single_assign(L)
                        if not sa or sa[0]!=v: continue
                        end=nxt(L); goal=tr if op=='or' else fa
                        if end!=goal: continue
                        a=X.stmts[-1][2][0]
                        X.stmts[-1]=['Assign',[['Name',v]],[['Bin',op,a,sa[1]]]]
                        X.term=('jmp',goal); del alive[other]; changed=True; break
                    if changed: break
            # shape 1: a and b or c
            _,J,T1,F1=X.term
            for Lb,Ys,a in ((T1,F1,None),(F1,T1,J)):
                Y=alive.get(Ys); L=alive.get(Lb)
                if Y is None or L is None or Ys==Lb: continue
                if P.get(Ys)!={X.start} or P.get(Lb)!={X.start,Ys}: continue
                sl=single_assign(L)
                if Y.term[0]=='testset' and not Y.stmts and sl:
                    _,ce,T2,F2,dst,src=Y.term
                    if fd_vn(dst)==sl[0] and F2==Lb and nxt(L)==T2 and ce==src:
                        cond=neg(J) if a is None else J
                        X.stmts=X.stmts+[['Assign',[['Name',sl[0]]],[['Bin','or',['Bin','and',cond,src],sl[1]]]]]
                        X.term=('jmp',T2); del alive[Ys]; del alive[Lb]; changed=True; break
                sy=single_assign(Y)
                if not sy or not sl or sy[0]!=sl[0] or Y.term[0]!='cond': continue
                v=sy[0]; tb=truthy_branch(Y.term,v)
                if not tb: continue
                tr,fa=tb
                if fa!=Lb: continue
                Lend=nxt(L)
                if Lend!=tr: continue
                cond=neg(J) if a is None else J
                X.stmts=X.stmts+[['Assign',[['Name',v]],[['Bin','or',['Bin','and',cond,sy[1]],sl[1]]]]]
                X.term=('jmp',Lend); del alive[Ys]; del alive[Lb]; changed=True; break
            if changed: break
    return alive
BOOLOPS=('==','~=','<','<=','>','>=')
def isbool(e):
    return (e[0]=='Bin' and (e[1] in BOOLOPS or (e[1] in('and','or') and isbool(e[2]) and isbool(e[3])))) or (e[0]=='Un' and e[1]=='not') or e[0] in('True','False')
def boolify(e): return e if isbool(e) else ['Un','not',['Un','not',e]]
def combine(e,vt,vf):
    T,F=['True'],['False']
    if vt==T and vf==F: return boolify(e)
    if vt==F and vf==T: return boolify(neg(e))
    if vt==T and isbool(vf): return ['Bin','or',boolify(e),vf]
    if vf==F and isbool(vt): return ['Bin','and',boolify(e),vt]
    if vt==F and isbool(vf): return ['Bin','and',boolify(neg(e)),vf]
    if vf==T and isbool(vt): return ['Bin','or',boolify(neg(e)),vt]
    return ['IfExpr',[(e,vt)],vf]
def fold_boolregion(alive):
    def preds():
        P={}
        for b in alive.values():
            for t in term_succ(b.term): P.setdefault(t,set()).add(b.start)
        return P
    changed=True
    while changed:
        changed=False; P=preds()
        for X in sorted(alive.values(),key=lambda b:b.start):
            if X.start not in alive or X.term[0]!='cond': continue
            region={}; var=[None]; lend=[None]; ok=[True]
            def visit(n,depth=0):
                if not ok[0]: return None
                if n in region: return region[n]
                B=alive.get(n)
                if B is None or n==X.start or len(region)>64: ok[0]=False; return None
                if not B.stmts and B.term[0]=='cond':
                    region[n]=None
                    vt=visit(B.term[2]); vf=visit(B.term[3])
                    if not ok[0]: return None
                    r=combine(B.term[1],vt,vf); region[n]=r; return r
                if len(B.stmts)==1 and B.stmts[0][0]=='Assign' and len(B.stmts[0][1])==1 and B.stmts[0][1][0][0]=='Name' and len(B.stmts[0][2])==1 and B.term[0] in('fall','jmp'):
                    v=B.stmts[0][1][0][1]
                    if var[0] is None: var[0]=v
                    if lend[0] is None: lend[0]=B.term[1]
                    if v!=var[0] or B.term[1]!=lend[0]: ok[0]=False; return None
                    region[n]=B.stmts[0][2][0]; return region[n]
                ok[0]=False; return None
            vt=visit(X.term[2]); vf=visit(X.term[3])
            if not ok[0] or var[0] is None or len(region)<3: continue
            if lend[0] in region: continue
            # all preds of region nodes must be inside region or X
            inside=set(region)|{X.start}
            if any(not P.get(n,set())<=inside for n in region): continue
            X.stmts=X.stmts+[['Assign',[['Name',var[0]]],[combine(X.term[1],vt,vf)]]]
            X.term=('jmp',lend[0])
            for n in region: alive.pop(n,None)
            changed=True; break
    return alive
def orlist(e):
    if e[0]=='Bin' and e[1]=='or': return orlist(e[2])+orlist(e[3])
    return [e]
def mkor(lst):
    r=lst[-1]
    for x in reversed(lst[:-1]): r=['Bin','or',x,r]
    return r
def simp_if(c,A,B):
    T,F=['True'],['False']
    if A is None or B is None: return ['IfExpr',[(c,A or ['Nil'])],B or ['Nil']]
    if A==B: return A
    if c[0]=='Un' and c[1]=='not' and not (A==c[2] or B==c[2]): return simp_if(c[2],B,A)
    la,lb=orlist(A),orlist(B)
    if len(la)>len(lb) and la[-len(lb):]==lb:
        return mkor([['Bin','and',c,mkor(la[:-len(lb)])]]+lb)
    if len(lb)>len(la) and lb[-len(la):]==la:
        return mkor([['Bin','and',neg(c),mkor(lb[:-len(la)])]]+la)
    if A==T and B==F: return boolify(c)
    if A==F and B==T: return boolify(neg(c))
    if A==c: return ['Bin','or',c,B]
    if B==c: return ['Bin','and',c,A]
    if A[0]=='Bin' and A[1]=='or' and A[3]==B: return ['Bin','or',['Bin','and',c,A[2]],B]
    if B==F and isbool(c) and isbool(A): return ['Bin','and',c,A]
    if A==T and isbool(c) and isbool(B): return ['Bin','or',c,B]
    return ['IfExpr',[(c,A)],B]
def fold_valueregion(alive,fd):
    def preds():
        P={}
        for b in alive.values():
            for t in term_succ(b.term): P.setdefault(t,set()).add(b.start)
        return P
    def lastassign(B):
        if B.stmts and B.stmts[-1][0]=='Assign' and len(B.stmts[-1][1])==1 and B.stmts[-1][1][0][0]=='Name' and len(B.stmts[-1][2])==1:
            return B.stmts[-1][1][0][1],B.stmts[-1][2][0]
        return None
    def testof(B,v):
        t=B.term
        if t[0]=='cond':
            if t[1]==['Name',v]: return t[2],t[3]
            if t[1]==['Un','not',['Name',v]]: return t[3],t[2]
        if t[0]=='testset' and fd.vn(t[4])==v and t[1]==t[5]: return t[2],t[3]
        return None
    changed=True; guard=0
    while changed and guard<10000:
        changed=False; guard+=1; P=preds()
        for X in sorted(alive.values(),key=lambda b:b.start):
            if X.start not in alive or X.term[0] not in('cond','testset'): continue
            st={'v':None,'end':None,'ok':True,'nodes':set(),'n':0}
            def val(n,cur):
                if not st['ok']: return None
                st['n']+=1
                if st['n']>400: st['ok']=False; return None
                if n==st['end']:
                    if cur is None: st['ok']=False
                    return cur
                B=alive.get(n)
                if B is None or n==X.start: st['ok']=False; return None
                if not B.stmts and B.term[0]=='cond':
                    st['nodes'].add(n)
                    a=val(B.term[2],cur); b=val(B.term[3],cur)
                    if not st['ok']: return None
                    return simp_if(B.term[1],a,b)
                la=lastassign(B)
                if la and len(B.stmts)==1:
                    v,e=la
                    if st['v'] is None: st['v']=v
                    if v!=st['v']: st['ok']=False; return None
                    tt=testof(B,v)
                    st['nodes'].add(n)
                    if tt:
                        a=val(tt[0],e); b=val(tt[1],e)
                        if not st['ok']: return None
                        return simp_if(e,a,b)
                    if B.term[0] in('fall','jmp'):
                        nx=B.term[1]
                        if st['end'] is None and (nx not in alive or alive[nx].stmts or alive[nx].term[0]!='cond' or True):
                            # first assign+jump decides the end, unless next is a region node
                            nb=alive.get(nx)
                            is_region_like = nb is not None and ((not nb.stmts and nb.term[0]=='cond') or (len(nb.stmts)==1 and lastassign(nb) and lastassign(nb)[0]==v))
                            if not is_region_like: st['end']=nx
                        return val(nx,e)
                st['ok']=False; return None
            # entry
            if X.term[0]=='testset' or (lastassign(X) and testof(X,lastassign(X)[0])):
                la=lastassign(X)
                if X.term[0]=='testset':
                    v=fd.vn(X.term[4]); e=X.term[5]; st['v']=v; tt=(X.term[2],X.term[3]); pre=X.stmts
                else:
                    v,e=la; st['v']=v; tt=testof(X,v); pre=X.stmts[:-1]
                a=val(tt[0],e); b=val(tt[1],e)
                if not st['ok'] or st['end'] is None or not st['nodes']: continue
                res=simp_if(e,a,b)
            else:
                pre=X.stmts
                a=val(X.term[2],None); b=val(X.term[3],None)
                if not st['ok'] or st['end'] is None or st['v'] is None or len(st['nodes'])<2: continue
                res=simp_if(X.term[1],a,b)
            inside=st['nodes']|{X.start}
            if st['end'] in inside: continue
            if any(not P.get(n,set())<=inside for n in st['nodes']): continue
            X.stmts=pre+[['Assign',[['Name',st['v']]],[res]]]
            X.term=('jmp',st['end'])
            for n in st['nodes']: alive.pop(n,None)
            changed=True; break
    return alive
def structure(fd,blocks,at):
    fold_const_tests(blocks)
    alive=collapse(blocks,at)
    alive=fold_valueregion(alive,fd)
    alive=fold_andor(alive,fd.vn)
    alive=fold_boolregion(alive)
    # drop unreachable blocks
    reach=set(); st=[min(alive)]
    while st:
        n=st.pop()
        if n in reach or n not in alive: continue
        reach.add(n); st.extend(term_succ(alive[n].term))
    for n in list(alive):
        if n not in reach: del alive[n]
    ipd=postdom(alive)
    def reaches_target(src,tgt,limit=400):
        seen=set(); st=[src]
        while st and len(seen)<limit:
            n=st.pop()
            if n==tgt: return True
            if n in seen or n not in alive: continue
            seen.add(n)
            for m in term_succ(alive[n].term):
                if m==tgt: return True
                if m>n or True: st.append(m)
        return False
    order=sorted(alive)
    nxt={order[i]:(order[i+1] if i+1<len(order) else None) for i in range(len(order))}
    backpreds={}
    for n in order:
        for t in term_succ(alive[n].term):
            if t in alive and t<=n: backpreds.setdefault(t,[]).append(n)
    emitted=set(); gotos=set(); handled_hdr=set()
    def G(t,out):
        gotos.add(t); out.append(['Goto','L%d'%t])
    def seq(b,stop,ctx,out,skiploop=False):
        guard=0
        while b is not None and b!=stop:
            guard+=1
            if guard>100000: out.append(['Comment','structuring guard']); return
            if b not in alive: G(b,out); return
            if ctx and b==ctx.exit: out.append(['Break']); return
            if b in emitted: G(b,out); return
            B=alive[b]
            if b in backpreds and not skiploop and b not in handled_hdr:
                b=loop(b,stop,ctx,out); skiploop=False; continue
            skiploop=False
            emitted.add(b); out.append(['Mark',b])
            out.extend(B.stmts)
            t=B.term; k=t[0]
            if k=='ret': out.append(['Return',t[1]]); return
            if k=='fall': b=t[1]; continue
            if k=='jmp':
                tg=t[1]
                if ctx and tg==ctx.exit: out.append(['Break']); return
                if ctx and tg==ctx.cont: out.append(['Continue']); return
                if tg==stop: return
                if tg in emitted or tg not in alive: G(tg,out); return
                if tg<b: G(tg,out); return
                # forward jump: is it the natural continuation (merge)? only if nothing else between
                b=tg; continue
            if k in('cond','testset'):
                expr,T,F=t[1],t[2],t[3]
                pre=[]
                if k=='testset': pre=[['Assign',[['Name',fd.vn(t[4])]],[t[5]]]]
                if ctx and T==ctx.exit and not pre:
                    out.append(['If',[(expr,[['Break']])],None]); b=F; continue
                if ctx and T==ctx.cont and not pre:
                    out.append(['If',[(expr,[['Continue']])],None]); b=F; continue
                M=ipd.get(b)
                if M is None or (stop is not None and M>stop) or (ctx and ctx.exit is not None and M>=ctx.exit and M!=ctx.exit):
                    M=stop
                    if T>b and T in alive and (stop is None or T<stop) and T not in emitted and reaches_target(F,T):
                        M=T
                if ctx and M is not None and ctx.exit is not None and M>ctx.exit: M=ctx.exit
                thenb=[]; elseb=[]
                # taken branch T, fall F
                if T==M:
                    seq(F,M,ctx,thenb)
                    if pre: out.append(['If',[(expr,pre)],thenb or None])
                    else: out.append(['If',[(neg(expr),thenb)],None])
                elif F==M:
                    seq(T,M,ctx,thenb)
                    out.append(['If',[(expr,pre+thenb)],None])
                else:
                    seq(F,M,ctx,thenb); seq(T,M,ctx,elseb)
                    if pre: out.append(['If',[(expr,pre+elseb)],thenb or None])
                    else: out.append(['If',[(neg(expr),thenb)],elseb or None])
                b=M; continue
            if k=='forprep':
                a,exs,tfl=t[1],t[2],t[3]
                FL=alive.get(tfl)
                if FL is None or FL.term[0]!='forloop': out.append(['Comment','bad for']); G(tfl,out); return
                body=FL.term[2]; ex_=FL.term[3]
                inner=[]; handled_hdr.add(body)
                seq(body,tfl,Ctx(ex_,tfl,ctx),inner)
                emitted.add(tfl); out.append(['Mark',tfl])
                out.append(['NumFor',fd.vn(a+3),exs[0],exs[1],None if exs[2]==['Num',1] else exs[2],inner])
                b=ex_; continue
            if k=='genfor_setup':
                exs,ttl=t[1],t[2]
                TL=alive.get(ttl)
                if TL is None or TL.term[0]!='tforloop': out.append(['Comment','bad genfor']); G(ttl,out); return
                a,c,body,ex_=TL.term[1],TL.term[2],TL.term[3],TL.term[4]
                inner=[]; handled_hdr.add(body)
                seq(body,ttl,Ctx(ex_,ttl,ctx),inner)
                emitted.add(ttl); out.append(['Mark',ttl])
                out.append(['GenFor',[fd.vn(r) for r in range(a+3,a+3+max(1,c))],exs,inner])
                b=ex_; continue
            out.append(['Comment','unhandled term %s'%k]); return
    def loop(h,stop,ctx,out):
        latch=max(backpreds[h]); L=alive[latch]; H=alive[h]
        ex_=nxt.get(latch)
        handled_hdr.add(h)
        lt=L.term
        if lt[0]=='cond' and lt[2]==h and latch!=h or (lt[0]=='cond' and lt[2]==h and latch==h):
            # repeat ... until
            inner=[]
            if latch==h:
                emitted.add(h); inner.append(['Mark',h]); inner.extend(H.stmts)
            else:
                seq(h,latch,Ctx(ex_,latch,ctx),inner,skiploop=True)
                emitted.add(latch); inner.append(['Mark',latch]); inner.extend(L.stmts)
            out.append(['Repeat',inner,neg(lt[1])])
            return lt[3]
        if lt[0] in('jmp','fall'):
            ht=H.term
            if ht[0]=='cond' and not H.stmts and ex_ is not None and (ht[2]==ex_ or ht[3]==ex_) and latch!=h:
                body=ht[3] if ht[2]==ex_ else ht[2]
                c=neg(ht[1]) if ht[2]==ex_ else ht[1]
                emitted.add(h); out.append(['Mark',h])
                inner=[]
                seq(body,latch,Ctx(ex_,h,ctx),inner)
                if latch not in emitted:
                    emitted.add(latch); inner.append(['Mark',latch]); inner.extend(L.stmts)
                out.append(['While',c,inner])
                return ex_
            inner=[]
            seq(h,latch,Ctx(ex_,h,ctx),inner,skiploop=True)
            if latch not in emitted:
                emitted.add(latch); inner.append(['Mark',latch]); inner.extend(L.stmts)
            out.append(['While',['True'],inner])
            return ex_
        # other latch kinds (forloop handled elsewhere)
        out.append(['Comment','loop with latch %s'%lt[0]])
        return None
    out=[]
    seq(order[0],None,None,out)
    # emit any goto targets not yet emitted
    rounds=0
    while True:
        pend=[g for g in sorted(gotos) if g not in emitted and g in alive]
        if not pend or rounds>50: break
        rounds+=1
        for g in pend:
            out.append(['Comment','-- detached block --'])
            seq(g,None,None,out)
    # convert marks into labels where needed
    def fix(lst):
        res=[]
        for st in lst:
            if st[0]=='Mark':
                if st[1] in gotos: res.append(['Label','L%d'%st[1]])
                continue
            if st[0]=='If': st=['If',[(c,fix(b)) for c,b in st[1]],fix(st[2]) if st[2] else None]
            elif st[0]=='While': st=['While',st[1],fix(st[2])]
            elif st[0]=='Repeat': st=['Repeat',fix(st[1]),st[2]]
            elif st[0]=='NumFor': st=st[:5]+[fix(st[5])]
            elif st[0]=='GenFor': st=st[:3]+[fix(st[3])]
            res.append(st)
        return res
    return fix(out)
def _decompile(self):
    p=self.p
    code=self.code
    blocks,at=make_blocks(code)
    liveness(code,blocks)
    for bl in blocks: self.build_block(bl)
    body=structure(self,blocks,at)
    # trailing empty return
    if body and body[-1]==['Return',[]]: body.pop()
    # declare locals
    params=set(range(int(p.nparams)))
    loc=sorted(r for r in self.vars if r not in params)
    decl=[]
    names=[self.vn(r) for r in loc]
    for i in range(0,len(names),12):
        decl.append(['Local',names[i:i+12],[]])
    return decl+body
FnDecomp.decompile=_decompile

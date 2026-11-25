from common import *
import copy
def names_used(b):
    c={}
    walk(b,lambda n: c.__setitem__(n[1],c.get(n[1],0)+1) if n[0]=='Name' else None)
    return c
def assigns_in(b):
    r=set()
    def f(n):
        if n[0]=='Assign':
            for t in n[1]:
                if t[0]=='Name': r.add(t[1])
        if n[0]=='Local': r.update(n[1])
        if n[0]=='NumFor': r.add(n[1])
        if n[0]=='GenFor': r.update(n[1])
        if n[0]=='Compound' and n[2][0]=='Name': r.add(n[2][1])
    walk(b,f); return r
def free_names(e):
    r=set(); walk(e,lambda n: r.add(n[1]) if n[0]=='Name' else None); return r
def static_vars(b,extra=()):
    # candidates: every assignment RHS uses consts + candidates; no function closures referencing
    assigns={}
    def f(n):
        if n[0] in('Local','Assign'):
            tg=n[1] if n[0]=='Local' else [t[1] if t[0]=='Name' else None for t in n[1]]
            for i,t in enumerate(tg):
                if t is None: continue
                rhs=n[2][i] if i<len(n[2]) else (['Nil'] if n[0]=='Local' or len(n[2])==0 else None)
                if len(n[2])<len(tg) and i>=len(n[2]) and n[2] and n[2][-1][0] in('Call','Method','Vararg'): rhs=None
                assigns.setdefault(t,[]).append(rhs)
        if n[0]=='NumFor': assigns.setdefault(n[1],[]).append('FOR')
        if n[0]=='GenFor':
            for t in n[1]: assigns.setdefault(t,[]).append(None)
        if n[0]=='Compound' and n[2][0]=='Name': assigns.setdefault(n[2][1],[]).append(['Bin',n[1],n[2],n[3]])
        if n[0]=='Function':
            for p in n[1]: assigns.setdefault(p,[]).append(None)
    walk(b,f)
    cand=set(k for k in assigns)
    changed=True
    def ok(rhs):
        if rhs is None: return False
        if rhs=='FOR': return True
        bad=[False]
        def g(n):
            if n[0]=='Name' and n[1] not in cand and n[1]!='Mv': bad[0]=True
            if n[0] in ('Vararg','Function','Table'): bad[0]=True
            if n[0]=='Index':
                o=n[1]
                if not (o==['Name','Mv'] or o==['Index',['Name','Mv'],['Str',b'v']]): bad[0]=True
            if n[0] in ('Call','Method'):
                fn=n[1]
                if not(fn[0]=='Index' and fn[1]==['Name','Mv']) and not (n[0]=='Method' and fn==['Name','Mv']) and not fn[0] in ('Function','Paren'): bad[0]=True
        walk(rhs,g); return not bad[0]
    while changed:
        changed=False
        for v in list(cand):
            if not all(ok(r) for r in assigns[v]): cand.discard(v); changed=True
    return cand
class PE:
    def __init__(s,fd,S):
        s.fd=fd; s.S=set(S); s.env={}
    def fe(s,e):
        s.fd.env={k:v for k,v in s.env.items() if k in s.S}
        r=s.fd.f(e); s.fd.env={}; return r
    def cv(s,e):
        return s.fd.const(s.fe(e))
    def block(s,b,out):
        """returns control: None | 'break' | 'return' | 'continue'; raises Dyn if a static break happens under dynamic control"""
        for st in b:
            r=s.stmt(st,out)
            if r: return r
        return None
    def stmt(s,st,out):
        k=st[0]
        if k=='Local' or (k=='Assign' and all(t[0]=='Name' for t in st[1])):
            names=st[1] if k=='Local' else [t[1] for t in st[1]]
            if all(n in s.S for n in names):
                vals=[s.cv(x) for x in st[2]]
                if all(v is not NOTC for v in vals):
                    for i,n in enumerate(names): s.env[n]=vals[i] if i<len(vals) else None
                    return None
                for n in names: s.S.discard(n); s.env.pop(n,None)
            # residual
            for n in names:
                if n in s.S: s.S.discard(n); s.env.pop(n,None)
        if k=='If':
            for c,b in st[1]:
                v=s.cv(c)
                if v is NOTC: break
                if truthy(v): return s.block(b,out)
            else:
                if st[2] is not None: return s.block(st[2],out)
                return None
            # dynamic: residual if; fold rest clauses
            clauses=[]
            started=False
            for c,b in st[1]:
                v=s.cv(c)
                if not started and v is not NOTC and not truthy(v): continue
                started=True
                if v is not NOTC and truthy(v):
                    els=s.sub(b); return s.emit_if(clauses,els,out)
                if v is not NOTC: continue
                clauses.append((s.fe(c),s.sub(b)))
            els=s.sub(st[2]) if st[2] is not None else None
            return s.emit_if(clauses,els,out)
        if k=='Do':
            # keep scoping but flatten if nothing local
            sub=[]; r=s.block(st[1],sub)
            if any(x[0] in('Local','LocalFunction') for x in sub): out.append(['Do',sub])
            else: out.extend(sub)
            return r
        if k in('While','Repeat','NumFor'):
            if s.static_loop(st):
                return s.unroll(st,out)
            s.residual_loop(st,out); return None
        if k=='Break': out.append(st) if s.in_residual_loop() else None; return 'break'
        if k=='Continue': out.append(st); return 'continue'
        if k=='Return': out.append(['Return',[s.fe(e) for e in st[1]]]); return 'return'
        out.append(s.rexpr_stmt(st)); return None
    LOOPDEPTH=0
    def in_residual_loop(s): return getattr(s,'rdepth',0)>0
    def emit_if(s,clauses,els,out):
        if not clauses:
            if els: out.extend(els)
            return None
        # drop empty else
        if els is not None and len(els)==0: els=None
        # drop clauses with empty bodies if no else and last
        out.append(['If',clauses,els]); return None
    def sub(s,b):
        # dynamic branch: static assignments inside become unknown afterwards
        saved=dict(s.env); savedS=set(s.S)
        o=[]
        r=s.block(b,o)
        changed={k for k in s.S if s.env.get(k,NOTC)!=saved.get(k,NOTC)}
        s.env=saved; s.S=savedS
        for k in changed:
            s.S.discard(k); s.env.pop(k,None)
        return o
    def static_loop(s,st):
        k=st[0]
        if k=='NumFor':
            return all(s.cv(x) is not NOTC for x in st[2:5] if x is not None)
        if k=='While': return s.cv(st[1]) is not NOTC
        if k=='Repeat':
            # cond may reference body locals; assume static if names in S
            return all(n in s.S or n=='Mv' for n in free_names(st[2]))
    def unroll(s,st,out):
        k=st[0]; it=0
        def body(b):
            sub=[]
            r=s.block(b,sub)
            out.extend(sub); return r
        if k=='NumFor':
            a=s.cv(st[2]); b2=s.cv(st[3]); c=s.cv(st[4]) if st[4] else 1
            i=a
            while (c>0 and i<=b2) or (c<0 and i>=b2):
                it+=1
                if it>5000: raise RuntimeError('unroll limit')
                s.S.add(st[1]); s.env[st[1]]=i
                r=body(st[5])
                if r=='break': break
                if r=='return': return r
                i+=c
            return None
        if k=='While':
            while True:
                v=s.cv(st[1])
                if v is NOTC: raise RuntimeError('loop became dynamic')
                if not truthy(v): break
                it+=1
                if it>5000: raise RuntimeError('unroll limit')
                r=body(st[2])
                if r=='break': break
                if r=='return': return r
            return None
        if k=='Repeat':
            while True:
                it+=1
                if it>5000: raise RuntimeError('unroll limit')
                r=body(st[1])
                if r=='break': break
                if r=='return': return r
                v=s.cv(st[2])
                if v is NOTC: raise RuntimeError('repeat became dynamic')
                if truthy(v): break
            return None
    def residual_loop(s,st,out):
        a=assigns_in(st)
        for n in list(s.S):
            if n in a:
                if n in s.env: out.append(['Local',[n],[mk(s.env[n])]])
                s.S.discard(n); s.env.pop(n,None)
        s.rdepth=getattr(s,'rdepth',0)+1
        k=st[0]
        if k=='NumFor':
            b=[]; s.block(st[5],b) ; out.append(['NumFor',st[1],s.fe(st[2]),s.fe(st[3]),s.fe(st[4]) if st[4] else None,b])
        elif k=='While':
            b=[]; s.block(st[2],b); out.append(['While',s.fe(st[1]),b])
        elif k=='Repeat':
            b=[]; s.block(st[1],b); out.append(['Repeat',b,s.fe(st[2])])
        s.rdepth-=1
    def rexpr_stmt(s,st):
        k=st[0]
        if k=='Local': return ['Local',st[1],[s.fe(e) for e in st[2]]]
        if k=='Assign': return ['Assign',[s.fe_target(t) for t in st[1]],[s.fe(e) for e in st[2]]]
        if k=='ExprStat': return ['ExprStat',s.fe(st[1])]
        if k=='Compound': return ['Compound',st[1],s.fe_target(st[2]),s.fe(st[3])]
        if k=='GenFor':
            b=[]; s.rdepth=getattr(s,'rdepth',0)+1; s.block(st[3],b); s.rdepth-=1
            return ['GenFor',st[1],[s.fe(e) for e in st[2]],b]
        if k=='LocalFunction': return ['LocalFunction',st[1],['Function',st[2][1],st[2][2],simplify(st[2][3],s.fd)]]
        return st
    def fe_target(s,t):
        if t[0]=='Name': return t
        if t[0]=='Index': return ['Index',s.fe(t[1]),s.fe(t[2])]
        return t
def cleanup(b):
    """remove unused junk locals with constant init, unwrap parens."""
    used=names_used(b)
    out=[]
    for st in b:
        if st[0]=='Local' and len(st[1])==1 and len(st[2])==1 and isc(st[2][0]) or (st[0]=='Local' and len(st[2])==1 and st[2][0][0]=='Un' and isc(st[2][0][2])):
            if used.get(st[1][0],0)==0: continue
        if st[0]=='If':
            st=['If',[(c,cleanup(bb)) for c,bb in st[1]],cleanup(st[2]) if st[2] is not None else None]
            if st[2] is not None and len(st[2])==0: st[2]=None
            if len(st[1])==1 and len(st[1][0][1])==0 and st[2]:
                c=st[1][0][0]
                nc=c[2] if c[0]=='Un' and c[1]=='not' else (['Bin',{'==':'~=','~=':'=='}[c[1]],c[2],c[3]] if c[0]=='Bin' and c[1] in('==','~=') else ['Un','not',c])
                st=['If',[(nc,st[2])],None]
            if all(len(bb)==0 for c,bb in st[1]) and not st[2]: continue
        elif st[0] in('While',): st=['While',st[1],cleanup(st[2])]
        elif st[0]=='NumFor': st=st[:5]+[cleanup(st[5])]
        elif st[0]=='GenFor': st=st[:3]+[cleanup(st[3])]
        elif st[0]=='Repeat': st=['Repeat',cleanup(st[1]),st[2]]
        elif st[0]=='Do': st=['Do',cleanup(st[1])]
        out.append(st)
    return out
def simp_funcs(b,fd):
    def f(n):
        if n[0]=='Function':
            n[3][:]=simplify(n[3],fd)
    for st in b: walk(st,f)
    return b
def simplify(b,fd,extraS=()):
    S=static_vars(b)|set(extraS)
    pe=PE(fd,S)
    out=[]
    pe.block(b,out)
    for _ in range(3): out=cleanup(out)
    simp_funcs(out,fd)
    return out

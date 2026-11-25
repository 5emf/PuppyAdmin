# AST post-processing: string decryption, else-hoisting, boolean peepholes
import re
TERM=('Return','Break','Continue','Goto')
def ends(b): return bool(b) and b[-1][0] in TERM
def decrypt_hex(h,key):
    try: data=bytes.fromhex(h.decode() if isinstance(h,bytes) else h)
    except ValueError: return None
    k=120; out=bytearray()
    for i,b in enumerate(data):
        o=((b^k)-17-i*7)%256
        k=(k+b+i+13)%256
        out.append(o)
    return bytes(out)
STATS={'dec':0}
def xform_expr(e,names):
    if not isinstance(e,list) or not e or not isinstance(e[0],str): return e
    for i in range(1,len(e)):
        v=e[i]
        if isinstance(v,list):
            if v and isinstance(v[0],str): e[i]=xform_expr(v,names)
            else:
                for j,it in enumerate(v):
                    if isinstance(it,list) and it and isinstance(it[0],str): v[j]=xform_expr(it,names)
                    elif isinstance(it,tuple): v[j]=tuple(xform_expr(z,names) if isinstance(z,list) else z for z in it)
                    elif isinstance(it,list): v[j]=[xform_expr(z,names) if isinstance(z,list) else z for z in it]
        elif isinstance(v,tuple):
            e[i]=tuple(xform_expr(z,names) if isinstance(z,list) else z for z in v)
    if e[0]=='Index' and e[1]==['Name',names[0]] and e[2][0]=='Call' and e[2][1]==['Name',names[1]] and len(e[2][2])==2:
        a,k=e[2][2]
        if a[0]=='Str' and k[0]=='Num':
            d=decrypt_hex(a[1],k[1])
            if d is not None: STATS['dec']+=1; return ['Str',d]
    return e
def xform_block(b,names):
    out=[]
    for st in b:
        st=xform_stmt(st,names)
        # else hoisting
        if st[0]=='If' and st[2] and len(st[1])>=1 and all(ends(bb) for c,bb in st[1]):
            els=st[2]; st=['If',st[1],None]; out.append(st); out.extend(els); continue
        # if c then v=false else v=true -> v = not c
        if st[0]=='If' and len(st[1])==1 and st[2] and len(st[1][0][1])==1 and len(st[2])==1:
            a=st[1][0][1][0]; b2=st[2][0]
            if a[0]=='Assign' and b2[0]=='Assign' and len(a[1])==1 and a[1]==b2[1] and len(a[2])==1 and len(b2[2])==1:
                va,vb=a[2][0],b2[2][0]; c=st[1][0][0]
                if va==['True'] and vb==['False']: out.append(['Assign',a[1],[bool_of(c)]]); continue
                if va==['False'] and vb==['True']: out.append(['Assign',a[1],[negb(c)]]); continue
        # if a then v = a else v = b end  -> v = a or b ; if not a then v = a else v = b -> v = a and b
        if st[0]=='If' and len(st[1])==1 and st[2] and len(st[1][0][1])==1 and len(st[2])==1:
            c=st[1][0][0]; a=st[1][0][1][0]; b2=st[2][0]
            if a[0]=='Assign' and b2[0]=='Assign' and len(a[1])==1 and a[1]==b2[1] and len(a[2])==1 and len(b2[2])==1:
                if a[2][0]==c: out.append(['Assign',a[1],[['Bin','or',c,b2[2][0]]]]); continue
                if c[0]=='Un' and c[1]=='not' and a[2][0]==c[2]: out.append(['Assign',a[1],[['Bin','and',c[2],b2[2][0]]]]); continue
        # merge "else { if ... }" into elseif
        if st[0]=='If' and st[2] and len(st[2])==1 and st[2][0][0]=='If':
            inner=st[2][0]; st=['If',st[1]+inner[1],inner[2]]
        out.append(st)
    return out
def bool_of(c):
    if c[0]=='Bin' and c[1] in('==','~=','<','<=','>','>='): return c
    if c[0]=='Un' and c[1]=='not': return c
    return ['Bin','~=',['Paren',c],['Nil']] if False else ['Un','not',['Un','not',c]]
def negb(c):
    inv={'==':'~=','~=':'==','<':'>=','<=':'>','>':'<=','>=':'<'}
    if c[0]=='Bin' and c[1] in('==','~='): return ['Bin',inv[c[1]],c[2],c[3]]
    if c[0]=='Un' and c[1]=='not': return bool_of(c[2])
    return ['Un','not',c]
def xform_stmt(st,names):
    k=st[0]
    if k=='If': return ['If',[(xform_expr(c,names),xform_block(b,names)) for c,b in st[1]],xform_block(st[2],names) if st[2] else None]
    if k=='While': return ['While',xform_expr(st[1],names),xform_block(st[2],names)]
    if k=='Repeat': return ['Repeat',xform_block(st[1],names),xform_expr(st[2],names)]
    if k=='NumFor': return ['NumFor',st[1]]+[xform_expr(x,names) if x else x for x in st[2:5]]+[xform_block(st[5],names)]
    if k=='GenFor': return ['GenFor',st[1],[xform_expr(x,names) for x in st[2]],xform_block(st[3],names)]
    if k in('Assign','Local'):
        return [k,[xform_expr(t,names) if isinstance(t,list) else t for t in st[1]],[xform_expr(x,names) for x in st[2]]]
    if k=='ExprStat': return ['ExprStat',xform_expr(st[1],names)]
    if k=='Return': return ['Return',[xform_expr(x,names) for x in st[1]]]
    return st
def walk_functions(b,names):
    # apply inside nested function bodies: Function exprs contain bodies
    def fx(e):
        if isinstance(e,list) and e and e[0]=='Function':
            e[3][:]=xform_block(e[3],names)
            for s in e[3]: walk_stmt(s)
        if isinstance(e,list):
            for x in e:
                if isinstance(x,(list,tuple)): fx2(x)
    def fx2(x):
        if isinstance(x,list): fx(x)
        elif isinstance(x,tuple):
            for z in x:
                if isinstance(z,(list,tuple)): fx2(z)
    def walk_stmt(s): fx(s)
    for s in b: walk_stmt(s)
def process(body,names=('v0','v1')):
    body=xform_block(body,names)
    walk_functions(body,names)
    return body

# ---- VM state (hoisted members) resolution ----
import copy as _copy
VS=None; USED_DATA={}; FSTATS={'inlined':0,'data':0,'unresolved':set()}
def vm_expr(e, sname='v2'):
    """rewrite v2.alias(v2, cells) -> inlined native function; v2.alias -> VM_member"""
    from factories import cellmap, subst
    if not isinstance(e,list) or not e or not isinstance(e[0],str): return e
    # recurse first
    out=[e[0]]
    for x in e[1:]:
        if isinstance(x,list):
            if x and isinstance(x[0],str): out.append(vm_expr(x,sname))
            else: out.append([vm_item(y,sname) for y in x])
        elif isinstance(x,tuple): out.append(tuple(vm_item(y,sname) for y in x))
        else: out.append(x)
    e=out
    if e[0]=='Call' and e[1][0]=='Index' and e[1][1]==['Name',sname] and e[1][2][0]=='Str' and len(e[2])==2 and e[2][0]==['Name',sname]:
        mem=VS.resolve(e[1][2][1].decode())
        if mem in VS.fact:
            m=cellmap(e[2][1])
            if m is not None:
                import luaprint as _lp
                need=set()
                walk_refs(VS.fact[mem],need)
                miss=need-set(m)
                if miss:
                    FSTATS.setdefault('miss',[]).append((mem,sorted(miss)[:5],_lp.ex(e[2][1])[:300]))
                FSTATS['inlined']+=1
                f=_copy.deepcopy(VS.fact[mem])
                return ['Function',f[1],f[2],_fix(f[3],m)]
    if e[0]=='Method' and e[1]==['Name',sname] and len(e[3])==1:
        mem=VS.resolve(e[2])
        if mem in VS.fact:
            m=cellmap(e[3][0])
            if m is not None:
                FSTATS['inlined']+=1
                f=_copy.deepcopy(VS.fact[mem])
                return ['Function',f[1],f[2],_fix(f[3],m)]
    if e[0]=='Index' and e[1]==['Name',sname] and e[2][0]=='Str':
        mem=VS.resolve(e[2][1].decode())
        if mem in VS.data:
            USED_DATA[mem]=VS.data[mem]; FSTATS['data']+=1
            return ['Name','VM_'+mem]
        FSTATS['unresolved'].add(mem)
    return e
def vm_item(y,sname):
    if isinstance(y,list):
        if y and isinstance(y[0],str): return vm_expr(y,sname)
        return [vm_item(z,sname) for z in y]
    if isinstance(y,tuple): return tuple(vm_item(z,sname) if isinstance(z,(list,tuple)) else z for z in y)
    return y
def vm_block(b,sname='v2'):
    return [vm_item(st,sname) for st in b]

# ---- move local declarations to first assignment ----
def _names_in(node,acc):
    if isinstance(node,list):
        if node and node[0]=='Name' and len(node)==2 and isinstance(node[1],str): acc.add(node[1]); return
        if node and node[0] in('NumFor',): acc.add(node[1])
        if node and node[0]=='GenFor':
            for n in node[1]: acc.add(n)
        if node and node[0]=='Function':
            for n in node[1]: acc.add(n)
        for x in node: _names_in(x,acc)
    elif isinstance(node,tuple):
        for x in node: _names_in(x,acc)
def localize(body):
    # leading decls
    i=0; declared=[]
    while i<len(body) and body[i][0]=='Local' and not body[i][2]:
        declared+=body[i][1]; i+=1
    rest=body[i:]
    todo=set(declared); keep=[]
    seen=set(); newrest=[]
    for st in rest:
        refs=set(); _names_in(st,refs)
        if st[0]=='Assign' and all(t[0]=='Name' for t in st[1]):
            tg=[t[1] for t in st[1]]
            rhs=set(); _names_in(st[2],rhs)
            if all(n in todo and n not in seen and n not in rhs for n in tg) and len(set(tg))==len(tg):
                for n in tg: todo.discard(n); seen.add(n)
                newrest.append(['Local',tg,st[2]]); seen|=refs; continue
        seen|=refs
        newrest.append(st)
    still=[n for n in declared if n in todo and n in _all_refs(rest)]
    decl=[]
    for j in range(0,len(still),12): decl.append(['Local',still[j:j+12],[]])
    return decl+newrest
def _all_refs(b):
    s=set(); _names_in(b,s); return s
def localize_all(body):
    def fx(node):
        if isinstance(node,list):
            if node and node[0]=='Function' and isinstance(node[3],list):
                for x in node[3]: fx(x)
                node[3][:]=localize(node[3])
                return
            for x in node: fx(x)
        elif isinstance(node,tuple):
            for x in node: fx(x)
    for st in body: fx(st)
    return localize(body)

def walk_refs(n,acc):
    if isinstance(n,list):
        if len(n)==3 and n[0]=='Index' and isinstance(n[1],list) and n[1][0]=='Index' and n[1][1]==['Name','a'] and n[1][2][0]=='Num' and n[2][0]=='Num':
            acc.add((n[1][2][1],n[2][1]))
        for x in n: walk_refs(x,acc)
    elif isinstance(n,tuple):
        for x in n: walk_refs(x,acc)

def _fix(body,m):
    from factories import subst
    for _ in range(4):
        body=[subst(st,m) for st in body]
    return body

INVCMP={'<':'>=','<=':'>','>':'<=','>=':'<','==':'~=','~=':'=='}
def tidy(n):
    if isinstance(n,list):
        for i,x in enumerate(n):
            if isinstance(x,(list,tuple)): n[i]=tidy(x)
        if len(n)==3 and n[0]=='Un' and n[1]=='not' and isinstance(n[2],list) and n[2] and n[2][0]=='Bin' and n[2][1] in INVCMP:
            b=n[2]; return ['Bin',INVCMP[b[1]],b[2],b[3]]
        return n
    if isinstance(n,tuple): return tuple(tidy(x) if isinstance(x,(list,tuple)) else x for x in n)
    return n

def _simple(e):
    if e[0]=='Name': return True
    if e[0]=='Index' and e[2][0]=='Str': return _simple(e[1])
    return False
def methodize(n):
    from luaprint import isname
    if isinstance(n,list):
        for i,x in enumerate(n):
            if isinstance(x,(list,tuple)): n[i]=methodize(x)
        if len(n)==3 and n[0]=='Call' and isinstance(n[1],list) and n[1] and n[1][0]=='Index' and n[1][2][0]=='Str' and isname(n[1][2][1]) and n[2] and n[2][0]==n[1][1] and _simple(n[1][1]):
            nm=n[1][2][1]; nm=nm.decode() if isinstance(nm,bytes) else nm
            return ['Method',n[1][1],nm,n[2][1:]]
        return n
    if isinstance(n,tuple): return tuple(methodize(x) if isinstance(x,(list,tuple)) else x for x in n)
    return n

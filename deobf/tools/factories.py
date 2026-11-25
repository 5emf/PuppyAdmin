import copy
from vmx import load as vload, members, walk
from fold import cval, CONSTK
def sstr(v): return v.decode('latin-1') if isinstance(v,bytes) else v
class VMState:
    def __init__(s,tblpath):
        M=members(vload(tblpath)); s.M=M
        qo={}
        for it in M['QO'][1]:
            qo[sstr(it[1][1])]=sstr(it[2][1])
        s.qo=qo
        s.fact={}; s.data={}
        for k,v in M.items():
            if v[0]=='Function' and len(v[3])==1 and v[3][0][0]=='Return' and len(v[3][0][1])==1 and v[3][0][1][0][0]=='Function' and v[1]==['a','a']:
                s.fact[k]=v[3][0][1][0]
            elif v[0] in('Table',)+CONSTK: s.data[k]=v
    def resolve(s,alias):
        return s.qo.get(alias,alias)
def is_getter(f):
    return f[0]=='Function' and not f[1] and len(f[3])==1 and f[3][0][0]=='Return' and len(f[3][0][1])==1
def is_setter(f):
    if f[0]!='Function' or len(f[1])!=1: return None
    b=[x for x in f[3] if x!=['Return',[]]]
    if len(b)==1 and b[0][0]=='Assign' and len(b[0][1])==1 and b[0][2]==[['Name',f[1][0]]]: return b[0][1][0]
    return None
def cellmap(tbl):
    m={}
    if tbl[0]!='Table': return None
    pos=0
    for it in tbl[1]:
        if it[0]=='pos': pos+=1; i=pos; cell=it[1]
        else:
            if it[1][0]!='Num': return None
            i=it[1][1]; cell=it[2]
        if cell[0]!='Table': return None
        p2=0
        for c in cell[1]:
            if c[0]=='pos': p2+=1; m[(i,p2)]=c[1]
            elif c[1][0]=='Num': m[(i,c[1][1])]=c[2]
    return m
def subst(node,m,ctx_stmt=False):
    """substitute a[i][j] in factory body AST (list-based)"""
    if not isinstance(node,list) or not node or not isinstance(node[0],str):
        return node
    k=node[0]
    def ref(e):
        if e[0]=='Index' and e[1][0]=='Index' and e[1][1]==['Name','a'] and e[1][2][0]=='Num' and e[2][0]=='Num':
            return (e[1][2][1],e[2][1])
        return None
    if k=='ExprStat':
        c=node[1]
        if c[0]=='Call':
            r=ref(c[1])
            if r and r in m:
                tgt=is_setter(m[r])
                if tgt is not None and len(c[2])==1:
                    return ['Assign',[copy.deepcopy(tgt)],[subst(c[2][0],m)]]
    if k=='Call':
        r=ref(node[1])
        if r and r in m:
            v=m[r]
            if is_getter(v) and not node[2]: return copy.deepcopy(v[3][0][1][0])
            tgt=is_setter(v)
            if tgt is not None and len(node[2])==1:
                return ['Paren',['Raw','(function() %s = ... end)'%'?']]
            return ['Call',copy.deepcopy(v),[subst(a,m) for a in node[2]]]
    r=ref(node)
    if r and r in m:
        v=m[r]
        if v[0] in CONSTK or (v[0]=='Un' and v[1]=='-'): return copy.deepcopy(v)
        return copy.deepcopy(v)
    out=[k]
    for x in node[1:]:
        if isinstance(x,list):
            if x and isinstance(x[0],str): out.append(subst(x,m))
            else: out.append([subst_item(y,m) for y in x])
        elif isinstance(x,tuple): out.append(tuple(subst(y,m) if isinstance(y,list) else y for y in x))
        else: out.append(x)
    return out
def subst_item(y,m):
    if isinstance(y,list):
        if y and isinstance(y[0],str): return subst(y,m)
        return [subst_item(z,m) for z in y]
    if isinstance(y,tuple): return tuple(subst_item(z,m) if isinstance(z,(list,tuple)) else z for z in y)
    return y

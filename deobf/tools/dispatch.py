from common import *
from luaprint import blk, ex
def mentions(e,name):
    r=[False]
    walk(e,lambda n: r.__setitem__(0,True) if n[0]=='Name' and n[1]==name else None)
    return r[0]
def get_ie(M):
    found=[]
    walk(M['ri'],lambda n: found.append(n) if n[0]=='LocalFunction' and n[1]=='ie' else None)
    return found[0][2]
def get_tree(ie):
    w=[s for s in ie[3] if s[0]=='While'][0]
    return w, w[2][-1]
def is_dispatch(block):
    return len(block)==1 and block[0][0]=='If' and all(mentions(c,'Zb') for c,_ in block[0][1])
def find_leaf(tree,h,fd,path=()):
    blockk=[tree]
    while is_dispatch(blockk):
        s=blockk[0]
        nxt=None
        for i,(c,b) in enumerate(s[1]):
            fd.env={'Zb':h}
            v=fd.const(fd.f(c)); fd.env={}
            if v is NOTC: raise ValueError('nonconst cond '+ex(c))
            if truthy(v): nxt=b; path+=(i,); break
        if nxt is None: nxt=s[2] if s[2] is not None else []; path+=('e',)
        blockk=nxt
    return path, blockk
def hashop(o): return ((((o or 0)+25104)*34589)+7783)%65521

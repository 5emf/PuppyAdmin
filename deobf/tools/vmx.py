import sys,pickle,os;sys.path.insert(0,os.path.dirname(__file__))
from luaparse import parse
from luaprint import blk,ex,st
def load(path):
    pk=path+'.pkl'
    if os.path.exists(pk): return pickle.load(open(pk,'rb'))
    a=parse(open(path).read()); pickle.dump(a,open(pk,'wb')); return a
def members(ast):
    tbl=ast[0][1][0][1][1] if ast[0][1][0][0]=='Paren' else ast[0][1][0][1]
    d={}
    for it in tbl:
        if it[0]=='kv': k=it[1][1]; d[k.decode() if isinstance(k,bytes) else k]=it[2]
    return d
def walk(n,f):
    if isinstance(n,list):
        if n and isinstance(n[0],str): f(n)
        for c in n: walk(c,f)
    elif isinstance(n,tuple):
        for c in n: walk(c,f)

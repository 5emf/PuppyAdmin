import os,re
WORK=os.path.dirname(os.path.dirname(os.path.abspath(__file__)))+'/work'
class Ref:
    __slots__=('i',)
    def __init__(s,i): s.i=i
    def __repr__(s): return '@%d'%s.i
    def __eq__(s,o): return isinstance(o,Ref) and o.i==s.i
    def __hash__(s): return hash(('ref',s.i))
def pval(s,i=0):
    c=s[i]
    if c=='{':
        i+=1; d={}
        if s[i]=='}': return d,i+1
        while True:
            k,i=pval(s,i); assert s[i]=='=',(s,i); v,i=pval(s,i+1); d[k]=v
            if s[i]==',': i+=1; continue
            assert s[i]=='}'; return d,i+1
    m=re.compile(r'[^,={}\s]+').match(s,i)
    tok=m.group(0); i=m.end()
    if tok=='nil': return None,i
    if tok=='true': return True,i
    if tok=='false': return False,i
    if tok[0]=='s': return bytes.fromhex(tok[1:]),i
    if tok[0]=='@': return Ref(int(tok[1:])),i
    if tok=='nan': return float('nan'),i
    if tok=='inf': return float('inf'),i
    if tok=='-inf': return float('-inf'),i
    x=float(tok); return (int(x) if x==int(x) and abs(x)<2**53 else x),i
def pv(t): return pval(t,0)[0]
class Proto:
    def __init__(s,f):
        s.id=int(f[1]); s.maxstack=pv(f[2]); s.nparams=pv(f[3]); s.entry=pv(f[4]); s.eG=pv(f[5]); s.key=pv(f[6]); s.pL=pv(f[7])
        s.ins={}; s.K={}; s.Y={}
def load():
    P=[]; cur=None
    for line in open(WORK+'/protos.txt'):
        f=line.rstrip('\n').split(' ')
        if f[0]=='P': cur=Proto(f); P.append(cur)
        elif f[0]=='I': cur.ins[int(f[1])]=[pv(x) for x in f[2:10]]
        elif f[0]=='K': cur.K[pv(f[1])]=pv(' '.join(f[2:]))
        elif f[0]=='Y': cur.Y[pv(f[1])]=pv(f[2])
    return P

import sys,os,json,subprocess
sys.path.insert(0,os.path.dirname(__file__))
from vmx import *
from fold import *
S=os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
HOST=S+'/host/target/release/host'
TOOLS=S+'/tools'
WORK=S+'/work'
def aliases(M):
    al={}
    for k,v in M.items():
        if v[0] in CONSTK: al[k]=('const',cval(v))
        elif v[0]=='Un' and v[1]=='-' and v[2][0]=='Num': al[k]=('const',-v[2][1])
        elif v[0]=='Function': al[k]=('method',)
        elif v[0]=='Index' and v[1]==['Name','bit32']: al[k]=('bit',v[2][1].decode())
        elif v[0]=='Index' and v[1]==['Name','math'] and v[2][1]==b'floor': al[k]=('floor',)
    return al
CCF=WORK+'/callcache.json'
def loadcc():
    if os.path.exists(CCF): return {(a,tuple(b)):c for a,b,c in json.load(open(CCF))}
    return {}
def resolve(fd):
    if not fd.pending: return False
    req=WORK+'/req.txt'; res=WORK+'/res.txt'
    keys=sorted(fd.pending,key=str)
    open(req,'w').write('\n'.join(k[0]+' '+' '.join(repr(x) for x in k[1]) for k in keys)+'\n')
    subprocess.run([HOST,TOOLS+'/hosteval.lua',TOOLS,WORK+'/tbl.lua',req,res],check=True)
    vals=open(res).read().split('\n')
    for k,v in zip(keys,vals):
        if v!='ERR':
            x=float(v); fd.cc[k]=int(x) if x==int(x) else x
    fd.pending=set()
    json.dump([[a,list(b),c] for (a,b),c in fd.cc.items()],open(CCF,'w'))
    return True

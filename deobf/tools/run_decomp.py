import sys,os,time
sys.path.insert(0,os.path.dirname(os.path.abspath(__file__)))
from decomp import *
import luaprint
_ex=luaprint.ex
def ex2(e,pri=0):
    if e[0]=='MethodRef': return _ex(['Index',e[1],e[2]],pri)
    if e[0]=='SelfArg': return '--[[self]]nil'
    return _ex(e,pri)
luaprint.ex=ex2
t0=time.time()
P=load()
allp={p.id:p for p in P}
cc={}
for p in P:
    ir=build_ir(p); pass_slots(p,ir); pass_strings(p,ir); pass_globals(p,ir)
    cc[p.id]=linearize(ir)
print('lifted',time.time()-t0)
sys.setrecursionlimit(100000)
fd=FnDecomp(allp,0,0,[],cc)
body=fd.decompile()
import post
for _ in range(2): body=post.process(body)
from factories import VMState
post.VS=VMState(WORK+'/tbl.lua')
body=post.vm_block(body)
body=post.process(body)
decl=[['Comment','--- members hoisted by the obfuscator into its VM state table (originally plain constants of the script) ---']]
for k,v in post.USED_DATA.items(): decl.append(['Local',['VM_'+k],[v]])
body=post.localize_all(body)
body=post.tidy(body)
body=post.methodize(body)
if body and body[-1]==['Return',[]]: body.pop()
body=decl+body
print('factories inlined',post.FSTATS)
print('decrypted strings',post.STATS)
print('decompiled',time.time()-t0)
src=luaprint.blk(body,0)
open(WORK+'/akadmin_decompiled.lua','w').write(src)
print('lines',src.count('\n'),'gotos',src.count('goto '),'detached',src.count('detached block'))

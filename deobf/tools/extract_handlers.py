# Extract and simplify every VM opcode handler -> work/handlers.lua, work/handlers_norm.lua
import sys,os,re,pickle
sys.path.insert(0,os.path.dirname(os.path.abspath(__file__)))
from dispatch import *
from simp import simplify
from luaprint import blk
ast=load(WORK+'/tbl.lua'); M=members(ast); al=aliases(M)
fd=Folder(al,loadcc())
ie=get_ie(M); w,tree=get_tree(ie)
for it in range(3):
    walk(tree,lambda n: fd.f(n) if n[0] in('Call','Method') else None)
    if not resolve(fd): break
used=set()
for line in open(WORK+'/protos.txt'):
    if line.startswith('I '): used.add(int(line.split()[2]))
out=[]; H={}
for o in sorted(used)+[-1413,-1453]:
    p,b=find_leaf(tree,hashop(o),fd)
    for it in range(4):
        try: sb=simplify(b,fd)
        except RuntimeError as e: sb=b; print('op',o,'ERR',e)
        if not resolve(fd): break
    H[o]=sb
    out.append('-- ===== op %d\n'%o+blk(sb,0))
src='\n'.join(out)
open(WORK+'/handlers.lua','w').write(src)
def norm(t):
    t=t.replace('Ng[NI]','A').replace('Ng[OM]','B').replace('Ng[Sn]','C').replace('Ng[Jl]','D')
    t=re.sub(r'\bga\b','R',t); t=re.sub(r'\bCe\b','K',t); return t
parts=re.split(r'-- ===== op (-?\d+)\n',src)[1:]
Hn={int(parts[i]):parts[i+1].strip() for i in range(0,len(parts),2)}
open(WORK+'/handlers_norm.lua','w').write('\n'.join('-- ===== op %d\n%s\n'%(o,norm(t)) for o,t in sorted(Hn.items())))
print('handlers',len(H))

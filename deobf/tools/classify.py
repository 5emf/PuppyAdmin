import re,sys,os
sys.path.insert(0,os.path.dirname(__file__))
WORK=os.path.dirname(os.path.dirname(os.path.abspath(__file__)))+'/work'
def load_norm():
    s=open(WORK+'/handlers_norm.lua').read()
    parts=re.split(r'-- ===== op (-?\d+)\n',s)[1:]
    return {int(parts[i]):parts[i+1].strip() for i in range(0,len(parts),2)}
O=r'(A|B|C)(?: - (\d))?'   # operand with offset
R_=r'R\[%s\]'%O
RK=r'(R\[%s\]|K\[%s\]|nq\(%s\))'%(O,O,O)
def opnd(m,i):
    # returns ('A',ofs)
    return (m.group(i), -int(m.group(i+1) or 0))
def rk(tok):
    m=re.fullmatch(r'R\[%s\]'%O,tok)
    if m: return ('R',m.group(1),-int(m.group(2) or 0))
    m=re.fullmatch(r'(?:K\[%s\]|nq\(%s\))'%(O,O),tok)
    if m:
        g=[x for x in m.groups() if x is not None]
        return ('K',g[0],-int(g[1]) if len(g)>1 else 0)
    raise ValueError(tok)
ARITH={'+':'ADD','-':'SUB','*':'MUL','/':'DIV','%':'MOD','^':'POW'}
VAL=r'(R\[(?:A|B|C)(?: - \d)?\]|K\[(?:A|B|C)(?: - \d)?\]|nq\((?:A|B|C)(?: - \d)?\))'
def seg_classify(t):
    t=t.strip(' ;')
    t=re.sub(r'^do ; (.*) ; end$',r'\1',t)
    # strip local alias declarations: local X = A ; ... X  -> substitute
    for _ in range(4):
        m=re.match(r'^(?:local (\w+) ; )?(?:local )?(\w+) = (A|B|C)(?: - (\d))? ; (.*)$',t)
        if m and (m.group(1) in (None,m.group(2))):
            v=m.group(2); rep=m.group(3)+(' - '+m.group(4) if m.group(4) else '')
            rest=m.group(5)
            rest=re.sub(r'\b%s \+ (\d)\b'%v,lambda mm: '%s+%s'%(rep,mm.group(1)),rest)
            rest=re.sub(r'\b%s\b'%v,rep,rest); t=rest; continue
        break
    pats=[
     (r'R\[%s\] = R\[%s\]'%(O,O), lambda m:('MOVE',opnd(m,1),opnd(m,3))),
     (r'R\[%s\] = (?:nq\(%s\)|K\[%s\])'%(O,O,O), lambda m:('LOADK',opnd(m,1),(m.group(3) or m.group(5),-int(m.group(4) or m.group(6) or 0)))),
     (r'R\[%s\] = Mv\.g\[%s\]'%(O,O), lambda m:('LOADCHAR',opnd(m,1),opnd(m,3))),
     (r'R\[%s\] = R\[%s\] \.\. Mv\.g\[%s\]'%(O,O,O), lambda m:('APPENDCHAR',opnd(m,1),opnd(m,5))),
     (r'R\[%s\] = %s ~= 0'%(O,O), lambda m:('LOADBOOL',opnd(m,1),opnd(m,3))),
     (r'for \w+ = %s, %s do ; R\[\w+\] = nil ; end'%(O,O), lambda m:('LOADNIL',opnd(m,1),opnd(m,3))),
     (r'R\[%s\] = nil'%O, lambda m:('LOADNIL1',opnd(m,1))),
     (r'R\[%s\] = zH\(%s\)'%(O,O), lambda m:('GETUPVAL',opnd(m,1),opnd(m,3))),
     (r'Hj\(%s, R\[%s\]\)'%(O,O), lambda m:('SETUPVAL',opnd(m,3),opnd(m,1))),
     (r'R\[%s\] = vy\[R\[%s\]\]'%(O,O), lambda m:('GETGLOBALR',opnd(m,1),opnd(m,3))),
     (r'vy\[R\[%s\]\] = R\[%s\]'%(O,O), lambda m:('SETGLOBALR',opnd(m,3),opnd(m,1))),
     (r'R\[%s\] = R\[%s\]\[%s\]'%(O,O,VAL), lambda m:('GETTABLE',opnd(m,1),opnd(m,3),rk(m.group(5)))),
     (r'R\[%s\]\[%s\] = %s'%(O,VAL,VAL), lambda m:('SETTABLE',opnd(m,1),rk(m.group(3)),rk(m.group(4)))),
     (r'local (\w+) = R\[%s\] ; if \1 == nil then ; \1 = nq\(%s\) ; end ; R\[%s\]\[\1\] = %s'%(O,O,O,VAL), lambda m:('SETTABLE_RORK',opnd(m,6),opnd(m,2),rk(m.group(8)))),
     (r'local (\w+) = R\[%s\] ; if \1 ~= nil then ; else ; \1 = nq\(%s\) ; end ; R\[%s\]\[\1\] = %s'%(O,O,O,VAL), lambda m:('SETTABLE_RORK',opnd(m,6),opnd(m,2),rk(m.group(8)))),
     (r'R\[%s\] = (?:\{\}|Mv\.D\(%s\)|Mv\.D\(256\))'%(O,O), lambda m:('NEWTABLE',opnd(m,1))),
     (r'local (\w+) = R\[%s\] ; R\[%s\+1\] = \1 ; R\[%s\] = \1\[%s\]'%(O,O,O,VAL), lambda m:('SELF',opnd(m,4),opnd(m,2),rk(m.group(8)))),
     (r'R\[%s\] = %s ([-+*/%%^]) %s'%(O,VAL,VAL), lambda m:(ARITH[m.group(4)],opnd(m,1),rk(m.group(3)),rk(m.group(5)))),
     (r'R\[%s\] = -R\[%s\]'%(O,O), lambda m:('UNM',opnd(m,1),opnd(m,3))),
     (r'R\[%s\] = not R\[%s\]'%(O,O), lambda m:('NOT',opnd(m,1),opnd(m,3))),
     (r'R\[%s\] = #R\[%s\]'%(O,O), lambda m:('LEN',opnd(m,1),opnd(m,3))),
     (r'R\[%s\] = R\[%s\] ; for (\w+) = %s\+1, %s do ; R\[%s\] = R\[%s\] \.\. R\[\5\] ; end'%(O,O,O,O,O,O), lambda m:('CONCAT',opnd(m,1),opnd(m,3),opnd(m,8))),
     (r'rz = %s'%O, lambda m:('JMP',opnd(m,1))),
     (r'if (not not )?\(?(.*?)\)? then ; rz = %s ; end'%O, lambda m: cond(m.group(2),opnd(m,3))),
     (r'local (\w+) = R\[%s\] ; if not \1 then ; R\[%s\] = \1 ; rz = %s ; end'%(O,O,O), lambda m:('TESTSET',opnd(m,4),opnd(m,2),0,opnd(m,6))),
     (r'local (\w+) ; \1 = R\[%s\] ; if \1 then ; R\[%s\] = \1 ; rz = %s ; end'%(O,O,O), lambda m:('TESTSET',opnd(m,4),opnd(m,2),1,opnd(m,6))),
     (r'return', lambda m:('RETURN',('A',0),0)),
     (r'return R\[%s\]'%O, lambda m:('RETURN',opnd(m,1),1)),
     (r'return R\[%s\], R\[%s\+1\]'%(O,O), lambda m:('RETURN',opnd(m,1),2)),
     (r'return rP\(R, %s, %s \+ %s\)'%(O,O,O), lambda m:('RETURNB',opnd(m,1),opnd(m,5))),
     (r'local (\w+) ; \1 = %s ; return rP\(R, \1, PV\)'%O, lambda m:('RETURN',opnd(m,2),'MULT')),
     (r'return rP\(R, %s, PV\)'%O, lambda m:('RETURN',opnd(m,1),'MULT')),
     (r'R\[%s\] = R\[%s\] - R\[%s\+2\] ; rz = %s'%(O,O,O,O), lambda m:('FORPREP',opnd(m,1),opnd(m,7))),
     (r'local (\w+) ; local (\w+) ; \2 = %s ; \1 = %s - 1 ; PV = \2 \+ \1 - 1 ; for \w+ = 0, \1 - 1 do ; R\[\2 \+ \w+\] = bs\[\w+\] ; end'%(O,O), lambda m:('VARARG',opnd(m,3),opnd(m,5))),
     (r'local (\w+) ; \1 = Ng\[zP\[7\]\] ; if \1 ~= nil then ; nt = Mv\.I\(nt or 0, \1\) ; end', lambda m:('NOP',)),
     (r'local (\w+) = qY\.Dl ; if \1 ~= nil then ; local (\w+) = qY\.iC ; local (\w+), (\w+) = Mv:kU\(\2\) ; qY\.YO = \3 ; qY\.yL = \4 ; end', lambda m:('NOP',)),
     (r'R\[%s\] = (Mv\.j|K|R|vy|Ng|Mv:yu\(\))'%O, lambda m:('JUNK',opnd(m,1),m.group(3))),
    ]
    for p,f in pats:
        m=re.fullmatch(p,t)
        if m: return f(m)
    return None
def cond(c,tgt):
    c=c.strip()
    m=re.fullmatch(r'\(?%s\)?'%r'(not )?R\[(A|B|C)(?: - (\d))?\]',c)
    if m: return ('TEST',('A' if m.group(2)=='A' else m.group(2),-int(m.group(3) or 0)),0 if m.group(1) else 1,tgt)
    # comparisons
    m=re.fullmatch(r'%s (==|~=|<=|>=|<|>) %s'%(VAL,VAL),c)
    if m: return ('CMP',m.group(2),rk(m.group(1)),rk(m.group(3)),tgt)
    m=re.fullmatch(r'%s (==|>) %s or %s (==|>) %s'%(VAL,VAL,VAL,VAL),c)
    if m and m.group(1)==m.group(4) and m.group(3)==m.group(6) and {m.group(2),m.group(5)}=={'==','>'}:
        return ('CMP','>=',rk(m.group(1)),rk(m.group(3)),tgt)
    m=re.fullmatch(r'%s (==|<) %s or %s (==|<) %s'%(VAL,VAL,VAL,VAL),c)
    if m and m.group(1)==m.group(4) and m.group(3)==m.group(6) and {m.group(2),m.group(5)}=={'==','<'}:
        return ('CMP','<=',rk(m.group(1)),rk(m.group(3)),tgt)
    return ('UNKCOND',c)
MANUAL={}
for o in (76,88,161,219): MANUAL[o]=[('CALL',('A',0),('B',0),('C',0))]
for o in (80,111,191,235): MANUAL[o]=[('TFORLOOP',('A',0),('C',0),('B',0))]
for o in (11,99,190,221): MANUAL[o]=[('CLOSE',('A',0))]
for o in (93,149,183,186): MANUAL[o]=[('SETLIST',('A',0),('B',0),('C',0))]
MANUAL[209]=[('SETLIST',('A',0),'MULT',('C',0))]
for o in (101,152,220,228): MANUAL[o]=[('FORLOOP',('A',0),('B',0))]
for o in (15,117,131,178): MANUAL[o]=[('CLOSURE',('A',0),('B',0),('C',0),('D',0))]
for o in (67,173,243,247): MANUAL[o]=[('CLOSURE',('A',0),('B',0),None,None)]
for o in (129,162,164,193): MANUAL[o]=[('LOADK',('A',0),('B',0))]
MANUAL[150]=[('LOADK',('A',0),('B',0)),('NOP',)]
for o in (1,75,79,104,115,156,157,165,184,192,194,200,202,114,238,244,0): MANUAL[o]=[('NOP',)]
MANUAL[171]=[('VARARG',('A',0),'MULT')]
MANUAL[198]=[('TAILCALL',('A',0),('B',0))]
MANUAL[179]=[('SETTABLE_RORK',('A',-2),('B',-2),('R','C',-2))]
MANUAL[249]=[('SETTABLE_RORK',('A',-1),('B',-1),('R','C',-1))]
def classify_all():
    H=load_norm(); res={}; bad={}
    for o,t in H.items():
        if o in MANUAL: res[o]=MANUAL[o]; continue
        if o<0: continue
        one=' ; '.join(x.strip() for x in t.split('\n') if x.strip())
        segs=re.split(r' ; Ng = rz ; rz = Ng\[ch\] ; ',one)
        out=[]
        for sg in segs:
            c=seg_classify(sg)
            if c is None or c[0]=='UNKCOND': bad[o]=sg; break
            out.append(c)
        else: res[o]=out
    return res,bad
if __name__=='__main__':
    res,bad=classify_all()
    for o in sorted(res): print(o,res[o])
    print('BAD',len(bad))
    for o,t in sorted(bad.items()): print(' ',o,'|',t)

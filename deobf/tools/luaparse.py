# Minimal Luau parser -> nested lists AST, plus printer
import sys
sys.setrecursionlimit(100000)
from lex import tokenize, KW
BINPRI = {'or':(1,1),'and':(2,2),'<':(3,3),'>':(3,3),'<=':(3,3),'>=':(3,3),'~=':(3,3),'==':(3,3),
 '..':(9,8),'+':(10,10),'-':(10,10),'*':(11,11),'/':(11,11),'//':(11,11),'%':(11,11),'^':(14,13)}
UNPRI=12
class P:
    def __init__(s,src):
        s.t=tokenize(src)+[('eof','<eof>')]; s.i=0
    def peek(s,o=0): return s.t[s.i+o]
    def v(s,o=0): return s.t[s.i+o][1]
    def nx(s): t=s.t[s.i]; s.i+=1; return t
    def ck(s,v):
        if s.t[s.i][1]==v and s.t[s.i][0] in('op','name'): s.i+=1; return True
        return False
    def ex(s,v):
        if not s.ck(v): raise SyntaxError('expected %s got %r at tok %d ctx %s'%(v,s.t[s.i],s.i,' '.join(x[1] for x in s.t[s.i-10:s.i+10])))
    def name(s):
        t=s.nx(); assert t[0]=='name' and t[1] not in KW,(t,s.i); return t[1]
    def block(s):
        b=[]
        while True:
            v=s.v()
            if v in('end','else','elseif','until','<eof>') and s.peek()[0] in ('name','eof'): return b
            if s.ck(';'): continue
            st=s.stat(); b.append(st)
            if st[0] in('Return','Break','Continue'):
                s.ck(';'); return b
    def stat(s):
        v=s.v(); tk=s.peek()[0]
        if tk=='name':
            if v=='local':
                s.nx()
                if s.ck('function'):
                    n=s.name(); return ['LocalFunction',n,s.funcbody()]
                names=[]
                while True:
                    names.append(s.name())
                    if s.ck(':'): s.typ()
                    if s.ck('<'): s.name(); s.ex('>')
                    if not s.ck(','): break
                exprs=s.exprlist() if s.ck('=') else []
                return ['Local',names,exprs]
            if v=='if':
                s.nx(); clauses=[]
                c=s.expr(); s.ex('then'); clauses.append((c,s.block()))
                els=None
                while True:
                    if s.ck('elseif'): c=s.expr(); s.ex('then'); clauses.append((c,s.block()))
                    elif s.ck('else'): els=s.block(); s.ex('end'); break
                    else: s.ex('end'); break
                return ['If',clauses,els]
            if v=='while':
                s.nx(); c=s.expr(); s.ex('do'); b=s.block(); s.ex('end'); return ['While',c,b]
            if v=='repeat':
                s.nx(); b=s.block(); s.ex('until'); c=s.expr(); return ['Repeat',b,c]
            if v=='do':
                s.nx(); b=s.block(); s.ex('end'); return ['Do',b]
            if v=='for':
                s.nx(); n1=s.name()
                if s.ck(':'): s.typ()
                if s.ck('='):
                    a=s.expr(); s.ex(','); b=s.expr(); c=s.expr() if s.ck(',') else None
                    s.ex('do'); bl=s.block(); s.ex('end'); return ['NumFor',n1,a,b,c,bl]
                names=[n1]
                while s.ck(','):
                    names.append(s.name())
                    if s.ck(':'): s.typ()
                s.ex('in'); el=s.exprlist(); s.ex('do'); bl=s.block(); s.ex('end'); return ['GenFor',names,el,bl]
            if v=='function':
                s.nx(); n=['Name',s.name()]; meth=None
                while True:
                    if s.ck('.'): n=['Index',n,['Str',s.name().encode()]]
                    elif s.ck(':'): meth=s.name(); break
                    else: break
                f=s.funcbody(meth is not None)
                if meth: n=['Index',n,['Str',meth.encode()]]
                return ['Assign',[n],[f]]
            if v=='return':
                s.nx()
                if s.v() in('end','else','elseif','until','<eof>',';') and s.peek()[0] in('name','eof','op'): return ['Return',[]]
                return ['Return',s.exprlist()]
            if v=='break': s.nx(); return ['Break']
            if v=='continue' and s.v(1) not in ('=','(','.','[',':',',','"','{') : s.nx(); return ['Continue']
        e=s.suffixed()
        if s.v() in ('=',','):
            targets=[e]
            while s.ck(','): targets.append(s.suffixed())
            s.ex('='); return ['Assign',targets,s.exprlist()]
        if s.v() in ('+=','-=','*=','/=','%=','^=','..=','//='):
            op=s.nx()[1][:-1]; r=s.expr(); return ['Compound',op,e,r]
        assert e[0] in('Call','Method'),('bad stmt',e,s.i,s.t[s.i-5:s.i+5])
        return ['ExprStat',e]
    def typ(s):
        # skip a simple type annotation
        depth=0
        while True:
            v=s.v()
            if v in('(','{','<'): depth+=1
            elif v in(')','}','>'):
                if depth==0: return
                depth-=1
            elif depth==0 and v in(',','=',')') : return
            s.nx()
    def funcbody(s,method=False):
        s.ex('('); params=['self'] if method else []; va=False
        if not s.ck(')'):
            while True:
                if s.ck('...'): va=True
                else: params.append(s.name())
                if s.ck(':'): s.typ()
                if not s.ck(','): break
            s.ex(')')
        if s.ck(':'): s.typ()
        b=s.block(); s.ex('end'); return ['Function',params,va,b]
    def exprlist(s):
        l=[s.expr()]
        while s.ck(','): l.append(s.expr())
        return l
    def primary(s):
        t=s.peek()
        if t[0]=='name' and t[1] not in KW: s.nx(); return ['Name',t[1]]
        if s.ck('('): e=s.expr(); s.ex(')'); return ['Paren',e]
        raise SyntaxError('primary %r %d'%(t,s.i))
    def suffixed(s):
        e=s.primary()
        while True:
            v=s.v(); tk=s.peek()[0]
            if tk=='op' and v=='.': s.nx(); e=['Index',e,['Str',s.name().encode()]]
            elif tk=='op' and v=='[': s.nx(); k=s.expr(); s.ex(']'); e=['Index',e,k]
            elif tk=='op' and v==':': s.nx(); m=s.name(); e=['Method',e,m,s.args()]
            elif (tk=='op' and v in('(','{')) or tk=='str': e=['Call',e,s.args()]
            else: return e
    def args(s):
        t=s.peek()
        if t[0]=='str': s.nx(); return [['Str',strval(t[1])]]
        if t[1]=='{': return [s.table()]
        s.ex('(')
        if s.ck(')'): return []
        l=s.exprlist(); s.ex(')'); return l
    def table(s):
        s.ex('{'); items=[]
        while not s.ck('}'):
            if s.v()=='[' and s.peek()[0]=='op':
                s.nx(); k=s.expr(); s.ex(']'); s.ex('='); items.append(('kv',k,s.expr()))
            elif s.peek()[0]=='name' and s.v(1)=='=' and s.v() not in KW:
                k=s.name(); s.nx(); items.append(('kv',['Str',k.encode()],s.expr()))
            else: items.append(('pos',s.expr()))
            if not s.ck(',') and not s.ck(';'): s.ex('}'); break
        return ['Table',items]
    def simple(s):
        t=s.peek()
        if t[0]=='num': s.nx(); return ['Num',float(t[1]) if any(c in t[1] for c in '.eEinf') else int(t[1])] if t[1] not in('inf',) else ['Num',float('inf')]
        if t[0]=='str': s.nx(); return ['Str',strval(t[1])]
        v=t[1]
        if t[0]=='name':
            if v=='nil': s.nx(); return ['Nil']
            if v=='true': s.nx(); return ['True']
            if v=='false': s.nx(); return ['False']
            if v=='function': s.nx(); return s.funcbody()
            if v=='if':
                s.nx(); c=s.expr(); s.ex('then'); a=s.expr(); cl=[(c,a)]
                while s.ck('elseif'): c=s.expr(); s.ex('then'); cl.append((c,s.expr()))
                s.ex('else'); return ['IfExpr',cl,s.expr()]
        if v=='...' and t[0]=='op': s.nx(); return ['Vararg']
        if v=='{' and t[0]=='op': return s.table()
        return s.suffixed()
    def expr(s,limit=0):
        t=s.peek()
        if (t[0]=='name' and t[1]=='not') or (t[0]=='op' and t[1] in('-','#')):
            s.nx(); e=['Un',t[1],s.expr(UNPRI)]
        else: e=s.simple()
        if s.v()=='::' : s.nx(); s.typ()
        while True:
            t=s.peek(); op=t[1]
            if t[0] in('op','name') and op in BINPRI and BINPRI[op][0]>limit:
                s.nx(); r=s.expr(BINPRI[op][1]); e=['Bin',op,e,r]
            else: return e
def strval(tok):
    if tok[0]=='[':
        import re
        m=re.match(r'\[(=*)\[',tok); body=tok[len(m.group(0)):-len(m.group(0))]
        if body.startswith('\n'): body=body[1:]
        return body.encode('latin-1','surrogateescape') if False else bytes(body,'utf-8')
    q=tok[0]; b=tok[1:-1]; out=bytearray(); i=0
    raw=b.encode('utf-8')
    i=0;n=len(raw)
    while i<n:
        c=raw[i]
        if c!=92: out.append(c); i+=1; continue
        i+=1; c=chr(raw[i])
        if c.isdigit():
            j=i
            while j<n and j<i+3 and chr(raw[j]).isdigit(): j+=1
            out.append(int(raw[i:j])); i=j; continue
        if c=='x': out.append(int(raw[i+1:i+3],16)); i+=3; continue
        if c=='u':
            j=raw.index(b'}',i); out+=chr(int(raw[i+2:j],16)).encode('utf-8'); i=j+1; continue
        if c=='z':
            i+=1
            while i<n and chr(raw[i]) in ' \t\r\n': i+=1
            continue
        if c=='\n': out.append(10); i+=1; continue
        out.append({'n':10,'t':9,'r':13,'a':7,'b':8,'f':12,'v':11,'\\':92,'"':34,"'":39}[c]); i+=1
    return bytes(out)
def parse(src):
    p=P(src); b=p.block(); assert p.peek()[0]=='eof',p.peek(); return b

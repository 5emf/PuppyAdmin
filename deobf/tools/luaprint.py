import re
KW=set('and break do else elseif end false for function if in local nil not or repeat return then true until while continue'.split())
PRI={'or':1,'and':2,'<':3,'>':3,'<=':3,'>=':3,'~=':3,'==':3,'..':9,'+':10,'-':10,'*':11,'/':11,'//':11,'%':11,'^':14}
def qstr(b):
    if isinstance(b,str): b=b.encode('utf-8')
    out=['"']
    try:
        txt=b.decode('utf-8'); printable=all(ch>=' ' or ch in '\n\t' for ch in txt)
    except UnicodeDecodeError: printable=False
    if printable:
        for ch in txt:
            if ch=='"': out.append('\\"')
            elif ch=='\\': out.append('\\\\')
            elif ch=='\n': out.append('\\n')
            elif ch=='\t': out.append('\\t')
            elif ch=='\x7f': out.append('\\127')
            else: out.append(ch)
    else:
        for c in b:
            if 32<=c<127 and c not in (34,92): out.append(chr(c))
            elif c==34: out.append('\\"')
            elif c==92: out.append('\\\\')
            elif c==10: out.append('\\n')
            else: out.append('\\%03d'%c)
        return ''.join(out)+'"'
    out.append('"'); return ''.join(out)
def num(v):
    if isinstance(v,float):
        if v!=v: return '(0/0)'
        if v==float('inf'): return 'math.huge'
        if v==-float('inf'): return '-math.huge'
        if v==int(v) and abs(v)<2**53: return str(int(v))
        r=repr(v); return r
    return str(v)
def isname(s): return isinstance(s,(bytes,str)) and re.fullmatch(r'[A-Za-z_][A-Za-z0-9_]*',s if isinstance(s,str) else s.decode('latin-1')) and (s if isinstance(s,str) else s.decode()) not in KW
def ex(e,pri=0):
    k=e[0]
    if k=='Name': return e[1]
    if k=='Num': s=num(e[1]); return '('+s+')' if s.startswith('-') and pri>=12 else s
    if k=='Str': return qstr(e[1])
    if k=='Nil': return 'nil'
    if k=='True': return 'true'
    if k=='False': return 'false'
    if k=='Vararg': return '...'
    if k=='Paren': return '('+ex(e[1])+')'
    if k=='Raw': return e[1]
    if k=='Index':
        b=prefix(e[1])
        if e[2][0]=='Str' and isname(e[2][1]): return b+'.'+(e[2][1].decode() if isinstance(e[2][1],bytes) else e[2][1])
        return b+'['+ex(e[2])+']'
    if k=='Call': return prefix(e[1])+'('+', '.join(ex(a) for a in e[2])+')'
    if k=='Method': return prefix(e[1])+':'+e[2]+'('+', '.join(ex(a) for a in e[3])+')'
    if k=='Function': return 'function('+', '.join(e[1]+(['...'] if e[2] else []))+')\n'+blk(e[3],IND[0]+1)+'\t'*IND[0]+'end'
    if k=='Table':
        if not e[1]: return '{}'
        parts=[]
        for it in e[1]:
            if it[0]=='pos': parts.append(ex(it[1]))
            else:
                kk=it[1]
                if kk[0]=='Str' and isname(kk[1]): parts.append((kk[1].decode() if isinstance(kk[1],bytes) else kk[1])+' = '+ex(it[2]))
                else: parts.append('['+ex(kk)+'] = '+ex(it[2]))
        return '{'+', '.join(parts)+'}'
    if k=='Un':
        op=e[1]; s=op+(' ' if op=='not' else '')+ex(e[2],12)
        if op=='-' and s.startswith('--'): s='-('+s[1:]+')'
        return '('+s+')' if pri>12 else s
    if k=='Bin':
        op=e[1]; p=PRI[op]
        right_assoc = op in ('..','^')
        l=ex(e[2],p+ (1 if right_assoc else 0)); r=ex(e[3],p+(0 if right_assoc else 1))
        s=l+' '+op+' '+r
        return '('+s+')' if p<pri else s
    if k=='IfExpr':
        s='if '+' elseif '.join(ex(c)+' then '+ex(a) for c,a in e[1])+' else '+ex(e[2]); return '('+s+')' if pri>0 else s
    raise ValueError(k)
def prefix(e):
    if e[0] in('Name','Index','Call','Method','Paren'): return ex(e)
    return '('+ex(e)+')'
IND=[0]
def blk(b,ind):
    old=IND[0]; IND[0]=ind
    parts=[]
    for i,s in enumerate(b):
        if s[0] in('Return','Break','Continue') and i<len(b)-1:
            parts.append('\t'*ind+'do\n'+st(s,ind+1)+'\t'*ind+'end\n')
        else: parts.append(st(s,ind))
    out=''.join(parts); IND[0]=old; return out
def st(s,ind):
    old=IND[0]; IND[0]=ind
    t='\t'*ind; k=s[0]
    try:
        if k=='Local': return t+'local '+', '.join(s[1])+(' = '+', '.join(ex(e) for e in s[2]) if s[2] else '')+'\n'
        if k=='LocalFunction':
            f=s[2]; return t+'local function '+s[1]+'('+', '.join(f[1]+(['...'] if f[2] else []))+')\n'+blk(f[3],ind+1)+t+'end\n'
        if k=='Assign':
            r=', '.join(ex(x) for x in s[1])+' = '+', '.join(ex(e) for e in s[2])
            return t+(';' if r.startswith('(') else '')+r+'\n'
        if k=='Compound': return t+ex(s[2])+' '+s[1]+'= '+ex(s[3])+'\n'
        if k=='ExprStat':
            r=ex(s[1]); return t+(';' if r.startswith('(') else '')+r+'\n'
        if k=='Return': return t+'return'+(' '+', '.join(ex(e) for e in s[1]) if s[1] else '')+'\n'
        if k=='Break': return t+'break\n'
        if k=='Continue': return t+'continue\n'
        if k=='Comment': return t+'-- '+s[1]+'\n'
        if k=='Label': return t+'::'+s[1]+'::\n'
        if k=='Goto': return t+'goto '+s[1]+'\n'
        if k=='Do': return t+'do\n'+blk(s[1],ind+1)+t+'end\n'
        if k=='While': return t+'while '+ex(s[1])+' do\n'+blk(s[2],ind+1)+t+'end\n'
        if k=='Repeat': return t+'repeat\n'+blk(s[1],ind+1)+t+'until '+ex(s[2])+'\n'
        if k=='NumFor': return t+'for '+s[1]+' = '+ex(s[2])+', '+ex(s[3])+(', '+ex(s[4]) if s[4] else '')+' do\n'+blk(s[5],ind+1)+t+'end\n'
        if k=='GenFor': return t+'for '+', '.join(s[1])+' in '+', '.join(ex(e) for e in s[2])+' do\n'+blk(s[3],ind+1)+t+'end\n'
        if k=='If':
            o=''
            for i,(c,b) in enumerate(s[1]):
                o+=t+('if ' if i==0 else 'elseif ')+ex(c)+' then\n'+blk(b,ind+1)
            if s[2] is not None: o+=t+'else\n'+blk(s[2],ind+1)
            return o+t+'end\n'
        raise ValueError(k)
    finally: IND[0]=old

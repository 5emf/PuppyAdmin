import re
def tokenize(s):
    i=0;n=len(s);out=[]
    while i<n:
        c=s[i]
        if c in ' \t\r\n': i+=1; continue
        if s.startswith('--',i):
            m=re.match(r'--\[(=*)\[',s[i:])
            if m:
                e=s.find(']'+m.group(1)+']',i); i=e+len(m.group(1))+2
            else:
                e=s.find('\n',i); i=n if e<0 else e
            continue
        if c in '"\'':
            j=i+1
            while s[j]!=c:
                j+= 2 if s[j]=='\\' else 1
            out.append(('str',s[i:j+1])); i=j+1; continue
        if c=='`':
            j=i+1
            while s[j]!='`': j+= 2 if s[j]=='\\' else 1
            out.append(('str',s[i:j+1])); i=j+1; continue
        m=re.match(r'\[(=*)\[',s[i:])
        if m:
            e=s.find(']'+m.group(1)+']',i); out.append(('str',s[i:e+len(m.group(1))+2])); i=e+len(m.group(1))+2; continue
        if c.isdigit() or (c=='.' and i+1<n and s[i+1].isdigit()):
            j=i
            while j<n and (s[j].isalnum() or s[j] in '._'):
                if s[j] in 'eE' and not s[i:j].lower().replace('_','').startswith(('0x','0b')) and j+1<n and s[j+1] in '+-': j+=2; continue
                j+=1
            out.append(('num',numfix(s[i:j]))); i=j; continue
        if c.isalpha() or c=='_':
            m=re.match(r'[A-Za-z_][A-Za-z0-9_]*',s[i:]); out.append(('name',m.group(0))); i+=len(m.group(0)); continue
        for op in ('...','..=','//=','==','~=','<=','>=','..','::','->','+=','-=','*=','/=','%=','^=','//'):
            if s.startswith(op,i): out.append(('op',op)); i+=len(op); break
        else:
            out.append(('op',c)); i+=1
    return out
def numfix(t):
    u=t.replace('_','')
    l=u.lower()
    try:
        if l.startswith('0x'): return str(int(l[2:],16))
        if l.startswith('0b'): return str(int(l[2:],2))
        if re.fullmatch(r'\d+',u): return str(int(u))
    except ValueError: pass
    return u
KW=set('and break do else elseif end false for function if in local nil not or repeat return then true until while continue'.split())
def emit(toks):
    out=[];prev=None
    for t,v in toks:
        if prev is not None:
            pt,pv=prev
            if (pt in('name','num') or pv in KW) and (t in('name','num') or v in KW): out.append(' ')
            elif pt=='num' and v.startswith('.'): out.append(' ')
            elif pv=='-' and v.startswith('-'): out.append(' ')
        out.append(v); prev=(t,v)
    return ''.join(out)

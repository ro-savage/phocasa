import re,sys
def load(p):
    d={}
    for l in open(p):
        parts=l.strip().split('|')
        if len(parts)<3: continue
        key=parts[1] if parts[0]=='COORD' and parts[1]!='info' else parts[1]+'|'+parts[2]
        m=re.search(r'(?:median_ms|\|ms)=([\d.]+)',l)
        if m: d[key]=float(m.group(1))
        elif 'info' in l: d[key+'|'+'|'.join(parts[3:])]=None
    return d
a=load(sys.argv[1]); b=load(sys.argv[2]); flt=sys.argv[3] if len(sys.argv)>3 else ''
for k in b:
    if flt and not re.search(flt,k): continue
    if k in a and a[k] is not None and b[k] is not None:
        d=(b[k]-a[k])/a[k]*100 if a[k] else 0
        flag=' <<' if d>5 and a[k]>1 else ''
        print(f"{k[:78]:78s} {a[k]:10.3f} {b[k]:10.3f} {d:+7.1f}%{flag}")
    elif b[k] is None: print(k)

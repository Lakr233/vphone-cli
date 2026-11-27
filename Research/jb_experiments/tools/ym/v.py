#!/usr/bin/env python3
# usage: v.py <method> '<json params>' [timeout]   |  v.py shot <name>  | v.py ui  | v.py ocr
import json,socket,sys,base64,os
S=os.path.expanduser('~/.vphone/machines/Basil/vphone.sock')
def send(obj,t=30):
    s=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM); s.settimeout(t); s.connect(S)
    s.sendall((json.dumps(obj,ensure_ascii=False)+'\n').encode())
    b=b''
    while True:
        c=s.recv(1<<20)
        if not c: break
        b+=c
        try:
            if b.strip().endswith(b'}') and json.loads(b): break
        except Exception: pass
    s.close(); return json.loads(b)
m=sys.argv[1]
if m=='shot':
    r=send({'t':'screenshot','path':f'/tmp/ym/shots/{sys.argv[2]}.png'})
    print(r.get('ok'),r.get('path'))
elif m in('ui','ocr'):
    r=send({'t':'rpc','method':'ui.tree' if m=='ui' else 'ui.ocr','params':{'nested':False,'visible_only':True,'max_elements':400} if m=='ui' else {}})
    r=r.get('result',r)
    def p(e):
        f=e.get('frame') or {}
        print(f"{(e.get('role') or '')[:10]:10} x{f.get('x',0):.0f} y{f.get('y',0):.0f} w{f.get('width',0):.0f} h{f.get('height',0):.0f} | {(e.get('text') or '')[:80]} | {(e.get('identifier') or '')[:40]}")
        for c in e.get('children',[]) or []: p(c)
    if m=='ui':
        for e in r.get('elements',[]): p(e)
    else:
        print(json.dumps(r,ensure_ascii=False)[:3000])
else:
    r=send({'t':'rpc','method':m,'params':json.loads(sys.argv[2]) if len(sys.argv)>2 else {}},int(sys.argv[3]) if len(sys.argv)>3 else 30)
    print(json.dumps(r,ensure_ascii=False)[:int(os.environ.get('MAXC','4000'))])

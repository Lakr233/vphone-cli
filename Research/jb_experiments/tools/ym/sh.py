#!/usr/bin/env python3
# usage: sh.py 'js line' ...   (runs in guest via script.eval; prints lines)
import json,sys,socket,os
s=socket.socket(socket.AF_UNIX); s.connect(os.path.expanduser('~/.vphone/machines/Basil/vphone.sock'))
src="print("+")\nprint(".join("JSON.stringify("+l+")" for l in sys.argv[1:])+")"
s.sendall((json.dumps({"t":"rpc","method":"script.eval","params":{"source":src,"timeout_ms":180000}})+"\n").encode())
b=b''
while True:
    c=s.recv(1<<20)
    if not c: break
    b+=c
d=json.loads(b); r=d.get('result',d)
print(r.get('output') if isinstance(r,dict) else r)
if isinstance(r,dict) and r.get('error'): print('ERR:',r.get('error')[:800],file=sys.stderr)

import socket,json,sys
S='/Users/i_strelov/.vphone/machines/Basil/vphone.sock'
def ctl(t,**a):
    s=socket.socket(socket.AF_UNIX); s.settimeout(120); s.connect(S)
    s.sendall((json.dumps({'t':t,**a})+'\n').encode()); buf=b''
    while True:
        c=s.recv(1<<20)
        if not c: break
        buf+=c
        try:
            if json.loads(buf): break
        except Exception: pass
    s.close(); return json.loads(buf)
def rpc(method,params=None): return ctl('rpc',method=method,params=params or {})
if __name__=='__main__':
    m=sys.argv[1]; p=json.loads(sys.argv[2]) if len(sys.argv)>2 else {}
    r=rpc(m,p); print(json.dumps(r.get('result',r),indent=1)[:4000])

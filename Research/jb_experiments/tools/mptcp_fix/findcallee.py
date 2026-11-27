#!/tmp/jbresearch/venv/bin/python
# findcallee.py <kc> <start_va> <n> : print bl targets in a function with callee prologue first-8 ins (signature)
import sys, struct
import kdiff
kc, start, n = sys.argv[1], int(sys.argv[2],16), int(sys.argv[3])
f,kb,secs=kdiff.load(kc,'com.apple.kernel')
S=next(s for s in secs if s[1]=='__text' and 'EXEC' in s[0])
seen={}
for pc,mn,ops in kdiff.dis(f,secs,start,n):
    if mn=='bl':
        t=int(ops.lstrip('#'),16)
        if t not in seen:
            seen[t]=True
            # callee prologue
            pro=[]
            for p2,m2,o2 in kdiff.dis(f,secs,t,6,stop_ret=False):
                pro.append(f'{m2} {o2}')
            print(f'{pc:#x}  bl {t:#x}  ; {pro[:4]}')

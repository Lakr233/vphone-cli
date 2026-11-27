#!/tmp/jbresearch/venv/bin/python
# funclist.py <kc> <lo> <hi> — list function starts (pacibsp) in [lo,hi) with size
import sys, struct; sys.path.insert(0,'/tmp/jbresearch/igmp')
import kdiff
kc=sys.argv[1]; lo=int(sys.argv[2],16); hi=int(sys.argv[3],16)
f,kb,secs=kdiff.load(kc,'com.apple.kernel')
S=next(s for s in secs if s[1]=='__text' and 'EXEC' in s[0])
fo=S[4]+(lo-S[2]); n=(hi-lo)//4
starts=[lo+4*k for k in range(n) if struct.unpack_from('<I',f,fo+4*k)[0] in (0xd503237f,0xd503237b)]
starts.append(hi)
for a,b in zip(starts,starts[1:]): print(f'{a:#x} {b-a:#x}')

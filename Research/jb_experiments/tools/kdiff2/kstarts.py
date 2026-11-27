"""kstarts.py <kc> <kext> [addr...] — LC_FUNCTION_STARTS of a fileset kext (ULEB128 deltas from the image's __TEXT vmaddr).
Without addr: one start per line. With addr: the function [start, next) holding each address."""
import sys,struct,re,subprocess,bisect
K,kext=sys.argv[1],sys.argv[2]; f=open(K,'rb').read()
o=subprocess.run(['xcrun','otool','-l',K],capture_output=True,text=True).stdout
m=re.search(r'vmaddr 0x([0-9a-f]+)\n\s+fileoff (\d+)\n\s+entry_id\s+'+re.escape(kext)+r'\s',o)
vb=int(m.group(1),16); kfo=int(m.group(2))
ncmds=struct.unpack_from('<I',f,kfo+16)[0]; off=kfo+32
for _ in range(ncmds):
    cmd,cs=struct.unpack_from('<II',f,off)
    if cmd==0x26: dfo,dsz=struct.unpack_from('<II',f,off+8)
    off+=cs
starts=[]; v=vb; acc=0; shift=0
for b in f[dfo:dfo+dsz]:
    if b==0:
        starts.append(v); v=vb; acc=0; shift=0
    else:
        acc|=(b&0x7f)<<shift; shift+=7
        if not b&0x80:
            v+=acc; starts.append(v); acc=0; shift=0
if len(sys.argv)>3:
    for a in sys.argv[3:]:
        t=int(a,16); i=bisect.bisect_right(starts,t)-1
        print('%#x -> %#x size %#x' % (t, starts[i], starts[i+1]-starts[i]))
else:
    for s in starts: print(hex(s))

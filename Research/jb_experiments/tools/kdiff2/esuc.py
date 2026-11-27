"""esuc.py <kc> <kext> — find functions that materialise a given 32-bit FourCC constant (movz+movk) in a fileset kext's __text."""
import sys,re,struct,subprocess
K=sys.argv[1]; kext=sys.argv[2]; val=int(sys.argv[3],16)
f=open(K,'rb').read()
o=subprocess.run(['xcrun','otool','-l',K],capture_output=True,text=True).stdout
m=re.search(r'vmaddr 0x([0-9a-f]+)\n\s+fileoff (\d+)\n\s+entry_id\s+'+re.escape(kext)+r'\s',o); kfo=int(m.group(2))
ncmds=struct.unpack_from('<I',f,kfo+16)[0]; off=kfo+32; S=[]
for _ in range(ncmds):
    cmd,cs=struct.unpack_from('<II',f,off)
    if cmd==0x19:
        for s in range(struct.unpack_from('<I',f,off+64)[0]):
            so=off+72+s*80; S.append((f[so:so+16].rstrip(b'\0').decode(),*struct.unpack_from('<QQI',f,so+32)))
    off+=cs
tx=next(s for s in S if s[0]=='__text'); blob=f[tx[3]:tx[3]+tx[2]]
lo,hi=val&0xffff,(val>>16)&0xffff
for i in range(0,len(blob)-8,4):
    a,b=struct.unpack_from('<II',blob,i)
    for base in (0x52800000,0xd2800000):
        if (a&0xffe00000)==base and ((a>>5)&0xffff)==lo and (b&0xffe00000|0x0)==(0x72a00000 if base==0x52800000 else 0xf2a00000) and ((b>>5)&0xffff)==hi and ((b>>21)&3)==1:
            print(hex(tx[1]+i))

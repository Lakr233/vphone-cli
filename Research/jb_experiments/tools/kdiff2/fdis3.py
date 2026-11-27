"""fdis3.py <kc> <kext> <va> [n] — per-word capstone disassembly of a fileset kext."""
import sys,struct,re,subprocess
from capstone import Cs,CS_ARCH_ARM64,CS_MODE_ARM
K=sys.argv[1]; kext=sys.argv[2]; va=int(sys.argv[3],16); n=int(sys.argv[4]) if len(sys.argv)>4 else 60
f=open(K,'rb').read()
o=subprocess.run(['xcrun','otool','-l',K],capture_output=True,text=True).stdout
m=re.search(r'vmaddr 0x([0-9a-f]+)\n\s+fileoff (\d+)\n\s+entry_id\s+'+re.escape(kext)+r'\s',o); kfo=int(m.group(2))
ncmds=struct.unpack_from('<I',f,kfo+16)[0]; off=kfo+32; S=[]
for _ in range(ncmds):
    cmd,cs=struct.unpack_from('<II',f,off)
    if cmd==0x19:
        for s in range(struct.unpack_from('<I',f,off+64)[0]):
            so=off+72+s*80; a,sz,sfo=struct.unpack_from('<QQI',f,so+32)
            if sfo: S.append((a,sz,sfo))
    off+=cs
def off_of(v):
    for a,sz,fo in S:
        if a<=v<a+sz: return fo+v-a
md=Cs(CS_ARCH_ARM64,CS_MODE_ARM)
for i in range(n):
    w=struct.unpack_from('<I',f,off_of(va+4*i))[0]
    ins=next(md.disasm(struct.pack('<I',w),va+4*i,1),None)
    print(f"{va+4*i:#x} {w:08x} {ins.mnemonic+' '+ins.op_str if ins else '.word'}")

"""fdis2.py <kc> <va> [n] — per-word disassembly (survives undecodable words)."""
import sys,struct; sys.path.insert(0,'/tmp/jbresearch/ipsw'); from kc import KC
from capstone import Cs,CS_ARCH_ARM64,CS_MODE_ARM
K=KC(sys.argv[1]); va=int(sys.argv[2],16); n=int(sys.argv[3]) if len(sys.argv)>3 else 60
md=Cs(CS_ARCH_ARM64,CS_MODE_ARM)
for i,w in enumerate(K.words(va,n)):
    ins=next(md.disasm(struct.pack('<I',w),va+4*i,1),None)
    print(f"{va+4*i:#x}  {w:08x}  {ins.mnemonic+' '+ins.op_str if ins else '.word '+hex(w)}")

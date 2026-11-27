#!/tmp/jbresearch/venv/bin/python
# fdump.py <kc> <va> — dump a whole function: from its pacibsp to the instruction before the next pacibsp
import sys, struct, re; sys.path.insert(0,'/tmp/jbresearch/igmp')
import kdiff
from capstone import *
kc, va = sys.argv[1], int(sys.argv[2],16); maxn=int(sys.argv[3]) if len(sys.argv)>3 else 6000
f,kb,secs=kdiff.load(kc,'com.apple.kernel')
S=next(s for s in secs if s[1]=='__text' and 'EXEC' in s[0])
fo=S[4]+(va-S[2]); md=Cs(CS_ARCH_ARM64,CS_MODE_ARM)
PAC={0xd503237f,0xd503237b,0xd503233f,0xd5032333}
for k in range(maxn):
    w=struct.unpack_from('<I',f,fo+4*k)[0]; pc=va+4*k
    if k>0 and w in PAC: break
    ins=next(md.disasm(struct.pack('<I',w),pc),None)
    mn,ops=(ins.mnemonic,ins.op_str) if ins else ('.word',f'{w:#010x}')
    ops=re.sub(r'#-?0x[0-9a-f]+','#IMM',ops); ops=re.sub(r'#[0-9]+','#IMM',ops)
    print(f'{pc:#x} {w:08x} {mn} {ops}')

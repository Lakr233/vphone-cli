#!/tmp/jbresearch/venv/bin/python
# callers.py <kc> <target_hex> : find all bl/b instructions in __text exec targeting <target>
import sys, struct
import kdiff
kc, target = sys.argv[1], int(sys.argv[2],16)
f,kb,secs=kdiff.load(kc,'com.apple.kernel')
for seg,sect,addr,size,foff in secs:
    if sect!='__text' or 'EXEC' not in seg: continue
    td=f[foff:foff+size]
    for i in range(0,len(td)-4,4):
        w=struct.unpack_from('<I',td,i)[0]
        if (w&0x7c000000)!=0x14000000: continue
        imm=w&0x3ffffff
        if imm&0x2000000: imm-=0x4000000
        pc=addr+i; t=pc+imm*4
        if t==target:
            fs=kdiff.func_start(f,secs,pc)
            print(f'{pc:#x} ({"bl" if w>>31 else "b"}) -> {target:#x}  in fn {fs and hex(fs)}')

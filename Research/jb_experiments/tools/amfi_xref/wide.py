import struct, re, subprocess, sys
KEXT='com.apple.driver.AppleMobileFileIntegrity'
kc,kb=sys.argv[1],int(sys.argv[2],16); names=sys.argv[3:]
f=open(kc,'rb').read()
o=subprocess.run(['otool','-l',kc],capture_output=True,text=True).stdout
m=re.search(r'vmaddr 0x([0-9a-f]+)\n\s+fileoff (\d+)\n\s+entry_id\s+'+re.escape(KEXT)+r'\s',o)
kfo=int(m.group(2)); ncmds=struct.unpack_from('<I',f,kfo+16)[0]; off=kfo+32; S=[]
for _ in range(ncmds):
    cmd,cs=struct.unpack_from('<II',f,off)
    if cmd==0x19:
        for s in range(struct.unpack_from('<I',f,off+64)[0]):
            so=off+72+s*80
            S.append((f[off+8:off+24].rstrip(b'\0').decode(),f[so:so+16].rstrip(b'\0').decode(),*struct.unpack_from('<QQI',f,so+32)))
    off+=cs
cs=next(s for s in S if s[0]=='__TEXT' and s[1]=='__cstring')
tx=next(s for s in S if s[0]=='__TEXT_EXEC' and s[1]=='__text')
blob=f[cs[4]:cs[4]+cs[3]]
pages={}
for name in names:
    i=blob.find(name.encode()+b'\0')
    if i>=0: pages.setdefault(((cs[2]+i)&~0xfff)&0xffffffff,[]).append(((cs[2]+i)&0xffffffff,name))
td=f[tx[4]:tx[4]+tx[3]]
for j in range(0,len(td)-8,4):
    a,b=struct.unpack_from('<II',td,j)
    if (a&0x9f000000)!=0x90000000: continue
    rd=a&31; imm=(((a>>5)&0x7ffff)<<2)|((a>>29)&3); imm=(imm<<43)>>43
    pc=tx[2]+j; page=((pc&~0xfff)+(imm<<12))&0xffffffff
    if page in pages:
        kind = 'add' if (b&0xff800000)==0x91000000 and ((b>>5)&31)==rd else ('ldr' if (b&0xffc00000) in (0xf9400000,) and ((b>>5)&31)==rd else None)
        if kind=='add': t=page+((b>>10)&0xfff)
        elif kind=='ldr': t=page+((b>>10)&0xfff)*8
        else: t=None
        print(f'adrp@{pc-kb:#x} next={kind} -> {hex(t) if t else "?"}  ' + ' | '.join(f'{n}@{a:#x}' for a,n in pages[page]))

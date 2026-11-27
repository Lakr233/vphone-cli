import struct, re, subprocess, sys, os
I = os.environ.get('JB_IPSW', '/tmp/jbresearch/ipsw')
KEXT='com.apple.driver.AppleMobileFileIntegrity'
KC={'x13': (I + '/x13/kc.decomp/kernelcache.release.iphone14.decompressed',0xfffffff007546c20),
    'x17': (I + '/x17/kc.decomp/kernelcache.release.v54.decompressed',0xfffffe0007665c40)}
names=sys.argv[1:]
for tag,(kc,kb) in KC.items():
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
    for name in names:
        i=blob.find(name.encode()+b'\0')
        if i<0: print(tag, name, 'NOT IN __cstring'); continue
        sa=cs[2]+i; sal=sa&0xffffffff
        slots=[]
        for seg,sect,addr,size,foff in S:
            if foff==0: continue
            bl=f[foff:foff+size]
            for rel in range(0,len(bl)-8,4):
                v=struct.unpack_from('<Q',bl,rel)[0]
                if (v&0xfffffffff)==sal-kb or v==sa or v==sa+0x200000000: slots.append((seg,sect,addr+rel))
        td=f[tx[4]:tx[4]+tx[3]]; hits=[]
        for j in range(0,len(td)-8,4):
            a,bb=struct.unpack_from('<II',td,j)
            if (a&0x9f000000)!=0x90000000: continue
            rd=a&31; imm=(((a>>5)&0x7ffff)<<2)|((a>>29)&3); imm=(imm<<43)>>43
            pc=tx[2]+j; page=(pc&~0xfff)+(imm<<12)
            if (bb&0xffc00000)==0xf9400000 and ((bb>>5)&31)==rd:
                p=page+((bb>>10)&0xfff)*8
                for seg,sect,a in slots:
                    if (p&0xffffffff)==(a&0xffffffff): hits.append((pc,seg,sect,a))
        print(tag, repr(name), 'str', hex(sa), 'slots', [(s[0],s[1],hex(a)) for s in slots], 'ldr-xrefs', [(hex(pc),hex(a)) for pc,_,_,a in hits])

#!/usr/bin/env python3
"""Find kernel read gadgets in Basil's kernelcache (no symbols): tiny functions in __text."""
import struct,bisect,sys
b=open("/tmp/jbresearch/basil/kernelcache.kc","rb").read()
BASE=0xfffffe0007008000; FOFF=0x4000
def fo(link): return FOFF+link-BASE
starts=[a for a in (int(x,16) for x in open("/tmp/jbresearch/basil/fstarts.txt").read().split()) if 0xfffffe0008ca9000<=a<0xfffffe0009514000]
res={}
for a,z in zip(starts,starts[1:]):
    if z-a!=8: continue
    i0,i1=struct.unpack('<II',b[fo(a):fo(a)+8])
    if i1!=0xD65F03C0: continue
    # ldr xT,[x0]        ldr wT,[x0]        ldr xT,[x0,#imm] (unsigned offset, scaled by 8)
    if (i0&0xFFC003FF)==0xF9400000| (0<<5): res.setdefault("ldr xT,[x0]",[]).append((a,i0&31))
    if (i0&0xFFC003FF)==0xB9400000| (0<<5): res.setdefault("ldr wT,[x0]",[]).append((a,i0&31))
    if (i0&0xFFC0003FF)==0xF9400000 and (i0>>5)&31==0: res.setdefault("ldr xT,[x0,#imm]",[]).append((a,i0&31,(i0>>10)&4095))
for k,v in res.items():
    print(f"{len(v):4d}  {k}")
    for a,*rest in v[:6]: print("        %#x %s"%(a,rest))

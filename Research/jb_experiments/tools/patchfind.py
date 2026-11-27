#!/usr/bin/env python3
"""patchfind.py — find xrefs (adrp+add / adrp+ldr) from a kext's __text to a cstring.
usage: patchfind.py <decompressed kernelcache> <kext entry_id> "<cstring>"
Kernelcache fileset adrp targets carry a +0x200000000 slide vs section vmaddrs; we handle both."""
import sys, struct, re, subprocess

KC, kext, needle = sys.argv[1], sys.argv[2], sys.argv[3].encode()
f = open(KC, 'rb').read()
o = subprocess.run(['xcrun', 'otool', '-l', KC], capture_output=True, text=True).stdout

def sections(fo):
    ncmds = struct.unpack_from('<I', f, fo + 16)[0]; off = fo + 32; out = []
    for _ in range(ncmds):
        cmd, cs = struct.unpack_from('<II', f, off)
        if cmd == 0x19:
            seg = f[off + 8:off + 24].rstrip(b'\0').decode()
            n = struct.unpack_from('<I', f, off + 64)[0]
            for s in range(n):
                so = off + 72 + s * 80
                out.append((seg, f[so:so + 16].rstrip(b'\0').decode(), *struct.unpack_from('<QQI', f, so + 32)))
        off += cs
    return out

m = re.search(r'vmaddr 0x([0-9a-f]+)\n\s+fileoff (\d+)\n\s+entry_id\s+' + re.escape(kext) + r'\s', o)
kbase, kfo = int(m.group(1), 16), int(m.group(2))
S = sections(kfo)
cs = next(s for s in S if s[0] == '__TEXT' and s[1] == '__cstring')
tx = next(s for s in S if s[0] == '__TEXT_EXEC' and s[1] == '__text')
ci = f[cs[4]:cs[4] + cs[3]].find(needle); assert ci >= 0, 'string not in __cstring'
saddr = cs[2] + ci
print(f'{kext} base={kbase:#x} __text={tx[2]:#x}+{tx[3]:#x}  "{needle.decode()}" @ {saddr:#x}')

hits = []
td = f[tx[4]:tx[4] + tx[3]]
for i in range(0, len(td) - 8, 4):
    a, b = struct.unpack_from('<II', td, i)
    if (a & 0x9f000000) != 0x90000000: continue
    rd = a & 31; imm = (((a >> 5) & 0x7ffff) << 2) | ((a >> 29) & 3); imm = (imm << 43) >> 43
    pc = tx[2] + i
    target = ((pc & ~0xfff) + (imm << 12)) & 0xffffffffffffffff
    if (b & 0xff800000) == 0x91000000 and ((b >> 5) & 31) == rd and (target + ((b >> 10) & 0xfff)) in (saddr, saddr + 0x200000000):
        hits.append(pc)
print(len(hits), 'xref(s):', ' '.join(hex(h) for h in hits))

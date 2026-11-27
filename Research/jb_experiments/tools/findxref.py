import sys, struct, re, subprocess
# usage: findxref.py <kernelcache> <kext-id> "<cstring>"
KC, kext, needle = sys.argv[1], sys.argv[2], sys.argv[3].encode()
f = open(KC, 'rb').read()
o = subprocess.run(['xcrun', 'otool', '-l', KC], capture_output=True, text=True).stdout
m = re.search(r'cmd LC_FILESET_ENTRY\n.*?vmaddr 0x([0-9a-f]+)\n\s+fileoff (\d+)\n\s+entry_id\s+' + re.escape(kext) + r'\s', o, re.S)
kbase, kfo = int(m.group(1), 16), int(m.group(2))

def sections(fo):
    """[(segname, sectname, vmaddr, size, fileoff)] of the Mach-O at file offset fo"""
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

S = sections(kfo)
cs = next(s for s in S if s[0] == '__TEXT' and s[1] == '__cstring')
tx = next(s for s in S if s[0] == '__TEXT_EXEC' and s[1] == '__text')
ci = f[cs[4]:cs[4] + cs[3]].find(needle); assert ci >= 0, 'string not in __cstring'
saddr = cs[2] + ci
page, lo = saddr & ~0xfff, saddr & 0xfff
print(f'{kext} base={kbase:#x} __text={tx[2]:#x}+{tx[3]:#x}  string={saddr:#x}')

# pointer slots (chained-fixup targets are stored as (target - kbase) with a low-bit tag in __DATA*)
ptrs = set()
for seg, sect, addr, size, foff in S:
    if foff == 0 or seg not in ('__DATA_CONST', '__DATA'): continue
    blob = f[foff:foff + size]
    for rel in range(0, len(blob) - 8, 4):
        v = struct.unpack_from('<Q', blob, rel)[0]
        if (v & ~0xfffffffff) == 0 and (v & 0xfffffffff) + kbase == saddr: ptrs.add(addr + rel)

td = f[tx[4]:tx[4] + tx[3]]
hits = []
for i in range(0, len(td) - 8, 4):
    a, b = struct.unpack_from('<II', td, i); pc = tx[2] + i
    if (a & 0x9f000000) != 0x90000000: continue
    rd = a & 31; imm = (((a >> 5) & 0x7ffff) << 2) | ((a >> 29) & 3); imm = (imm << 43) >> 43
    p = (pc & ~0xfff) + (imm << 12)
    if p == page and (b & 0xff800000) == 0x91000000 and ((b >> 10) & 0xfff) == lo and ((b >> 5) & 31) == rd: hits.append(('add', pc))
    if (b & 0xffc00000) == 0xf9400000 and ((b >> 5) & 31) == rd and p + ((b >> 10) & 0xfff) * 8 in ptrs: hits.append(('ldr', pc))
print(len(ptrs), 'ptr slots;', len(hits), 'xref(s):', ' '.join(f'{k}@{h:#x}' for k, h in hits))

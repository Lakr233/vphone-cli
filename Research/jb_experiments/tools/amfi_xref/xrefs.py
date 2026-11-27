"""xrefs.py <kc> <kext-id> <substr>... : all adrp+add / adrp+ldr xrefs from __text to every __cstring string containing substr"""
import sys, struct, re, subprocess
KC, kext = sys.argv[1], sys.argv[2]
needles = [n.encode() for n in sys.argv[3:]]
f = open(KC, 'rb').read()
o = subprocess.run(['otool', '-l', KC], capture_output=True, text=True).stdout
m = re.search(r'vmaddr 0x([0-9a-f]+)\n\s+fileoff (\d+)\n\s+entry_id\s+' + re.escape(kext) + r'\s', o)
kbase, kfo = int(m.group(1), 16), int(m.group(2))
ncmds = struct.unpack_from('<I', f, kfo + 16)[0]; off = kfo + 32; S = []
for _ in range(ncmds):
    cmd, cs = struct.unpack_from('<II', f, off)
    if cmd == 0x19:
        for s in range(struct.unpack_from('<I', f, off + 64)[0]):
            so = off + 72 + s * 80
            S.append((f[off+8:off+24].rstrip(b'\0').decode(), f[so:so+16].rstrip(b'\0').decode(), *struct.unpack_from('<QQI', f, so + 32)))
    off += cs
cs = next(s for s in S if s[0] == '__TEXT' and s[1] == '__cstring')
tx = next(s for s in S if s[0] == '__TEXT_EXEC' and s[1] == '__text')
blob = f[cs[4]:cs[4]+cs[3]]
targets = {}  # saddr -> string
pos = 0
while True:
    e = blob.find(b'\0', pos)
    if e < 0: break
    sv = blob[pos:e]
    if sv and any(n.lower() in sv.lower() for n in needles): targets[cs[2]+pos] = sv
    pos = e + 1
# pointer slots in __DATA* holding (target - kbase) chained-fixup rebase
targets_low = {a & 0xffffffff: a for a in targets}
ptrs_low = {}
for seg, sect, addr, size, foff in S:
    if foff == 0 or not seg.startswith('__DATA'): continue
    b = f[foff:foff+size]
    for rel in range(0, len(b) - 8, 4):
        v = struct.unpack_from('<Q', b, rel)[0]
        t = (v & 0xfffffffff) + kbase
        if (t & 0xffffffff) in targets_low: ptrs_low[addr + rel] = t & 0xffffffff
td = f[tx[4]:tx[4]+tx[3]]
res = {a: [] for a in targets}
for i in range(0, len(td) - 8, 4):
    a, b = struct.unpack_from('<II', td, i)
    if (a & 0x9f000000) != 0x90000000: continue
    rd = a & 31; imm = (((a >> 5) & 0x7ffff) << 2) | ((a >> 29) & 3); imm = (imm << 43) >> 43
    pc = tx[2] + i; page = (pc & ~0xfff) + (imm << 12)
    if (b & 0xff800000) == 0x91000000 and ((b >> 5) & 31) == rd:
        t = page + ((b >> 10) & 0xfff)
        if t & 0xffffffff in targets_low:  # x13 adrp targets carry +0x200000000 slide
            res[targets_low[t & 0xffffffff]].append((pc, "add", None))
    if (b & 0xffc00000) == 0xf9400000 and ((b >> 5) & 31) == rd:
        p = page & 0xffffffff
        if p in ptrs_low: res[targets_low[ptrs_low[p]]].append((pc, "ldr", p))
for a in sorted(res):
    print(f'STR {a-kbase:#x} {a:#x} {targets[a].decode("latin1")!r}')
    for pc, kind, p in res[a]:
        print(f'    XREF {pc-kbase:#x} {pc:#x} {kind}' + (f' ptr@{p:#x}' if p else ''))
    if not res[a]: print('    XREF none')

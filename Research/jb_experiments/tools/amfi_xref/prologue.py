"""prologue.py <kc> <kext-id> <va>... : nearest function prologue (pacibsp/pacibz/sub sp,sp) at or before each va"""
import sys, struct, re, subprocess
KC, kext = sys.argv[1], sys.argv[2]
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
tx = next(s for s in S if s[0] == '__TEXT_EXEC' and s[1] == '__text')
kbase = int(m.group(1), 16)
def w(va): return struct.unpack_from('<I', f, tx[4] + (va - tx[2]))[0]
MAX = 0x4000
for a in sys.argv[3:]:
    va = int(a, 16)
    best = None
    for d in range(0, MAX, 4):
        p = va - d
        if p < tx[2]: break
        i = w(p)
        kind = None
        if i == 0xd503237f: kind = 'pacibsp'
        elif i == 0xd50323bf: kind = 'pacibz'
        elif p > tx[2] and w(p - 4) == 0xd503237f: kind = 'pacibsp'  # pacibsp; sub sp -> pacibsp is the entry
        elif p > tx[2] and w(p - 4) == 0xd50323bf: kind = 'pacibz'
        elif (i & 0xff8003ff) == 0xd10003ff: kind = f'sub sp, sp, #{(i>>10)&0xfff:#x}'
        if kind:
            best = (p - 4 if kind.startswith('pacib') and w(p - 4) in (0xd503237f, 0xd50323bf) else p, kind, d); break
    if best: print(f'{va:#x} -> prologue {best[0]:#x} ({best[1]}) dist={best[2]:#x}')
    else: print(f'{va:#x} -> no prologue within {MAX:#x}')

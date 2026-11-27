import sys, struct, re, subprocess
KC, kext = sys.argv[1], sys.argv[2]
f = open(KC, 'rb').read()
o = subprocess.run(['otool', '-l', KC], capture_output=True, text=True).stdout
m = re.search(r'vmaddr 0x([0-9a-f]+)\n\s+fileoff (\d+)\n\s+entry_id\s+' + re.escape(kext) + r'\s', o)
kbase, kfo = int(m.group(1), 16), int(m.group(2))
ncmds = struct.unpack_from('<I', f, kfo + 16)[0]; off = kfo + 32; secs = []
for _ in range(ncmds):
    cmd, cs = struct.unpack_from('<II', f, off)
    if cmd == 0x19:
        n = struct.unpack_from('<I', f, off + 64)[0]
        for s in range(n):
            so = off + 72 + s * 80
            secs.append((f[off+8:off+24].rstrip(b'\0').decode(), f[so:so+16].rstrip(b'\0').decode(), *struct.unpack_from('<QQI', f, so + 32)))
    off += cs
print(f'kbase={kbase:#x}')
for s in secs:
    print(f'{s[0]:13s} {s[1]:22s} vmaddr={s[2]:#x} size={s[3]:#x} fileoff={s[4]:#x}')
cs = next(s for s in secs if s[0] == '__TEXT' and s[1] == '__cstring')
needles = [n.lower().encode() for n in sys.argv[3:]]
blob = f[cs[4]:cs[4]+cs[3]]
pos = 0
while True:
    e = blob.find(b'\0', pos)
    if e < 0: break
    sv = blob[pos:e]
    if sv and any(n in sv.lower() for n in needles):
        print(f'{cs[2]+pos:#x} (+{cs[2]+pos-kbase:#x}) {sv.decode("latin1")}')
    pos = e + 1

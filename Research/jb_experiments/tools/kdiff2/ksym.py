"""ksym.py <kc> <addr>... — kernelcache symbol lookup by address (symbols of the whole cache, LC_SYMTAB of the
com.apple.kernel fileset entry). Prints the exact symbol, else the nearest one below."""
import sys, struct, re, subprocess, bisect

K = sys.argv[1]
f = open(K, 'rb').read()
o = subprocess.run(['xcrun', 'otool', '-l', K], capture_output=True, text=True).stdout
m = re.search(r'fileoff (\d+)\n\s+entry_id com\.apple\.kernel( |\n)', o)
kfo = int(m.group(1))
ncmds = struct.unpack_from('<I', f, kfo + 16)[0]
off = kfo + 32
nsyms = None
for _ in range(ncmds):
    cmd, cs = struct.unpack_from('<II', f, off)
    if cmd == 0x2:
        _, _, symoff, nsyms, stroff, _ = struct.unpack_from('<6I', f, off)
    off += cs
S = []
for i in range(nsyms):
    strx, typ, sect, desc, n_value = struct.unpack_from('<IBBHQ', f, symoff + 16 * i)
    if n_value:
        e = f.find(b'\0', stroff + strx)
        S.append((n_value, f[stroff + strx:e].decode(errors='replace')))
S.sort()
A = [x[0] for x in S]
print('symbols with addresses: %d' % len(S), file=sys.stderr)
for a in sys.argv[2:]:
    v = int(a, 16)
    i = bisect.bisect_left(A, v)
    if i < len(A) and A[i] == v:
        print('%#x = %s' % (v, S[i][1]))
    else:
        j = i - 1
        print('%#x  no exact symbol; nearest below %#x %s (+%#x)' % (v, S[j][0], S[j][1], v - S[j][0]))

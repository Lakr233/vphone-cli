"""kdisp.py <kc> [kext] — IOExternalMethodDispatch2022 tables in the fileset kexts of a kernelcache.

Entry is 0x28 bytes: a chained pointer to a function of the same kext's __text, then four uint32 checks
(0, 0xffffffff or a small count). Consecutive entries form one table.
Without kext: TSV "kext, tables, selectors" for every kext.
With kext: every table (selector -> function [start, size], checks) and the functions that take the table's address."""
import sys, struct, re, subprocess, bisect, os

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from allseg import load

B = 0xfffffff007004000
SKIP = ('__text', '__cstring', '__ustring', '__os_log', '__bss', '__common')
K = sys.argv[1]
f, segs = load(K)
otool = subprocess.run(['xcrun', 'otool', '-l', K], capture_output=True, text=True).stdout
hdr = {m.group(3): (int(m.group(2)), int(m.group(1), 16)) for m in
       re.finditer(r'vmaddr 0x([0-9a-f]+)\n\s+fileoff (\d+)\n\s+entry_id (\S+)', otool)}

def kexts():
    return sorted({s[0] for s in segs})


def text_range(kext):
    t = [s for s in segs if s[0] == kext and s[2] == '__text']
    return (min(s[3] for s in t), max(s[3] + s[4] for s in t)) if t else None


def entries(kext):
    rng = text_range(kext)
    if not rng:
        return []
    lo, hi = rng
    out = []
    for s in segs:
        if s[0] != kext or s[2] in SKIP or not s[5]:
            continue
        for o in range(0, s[4] - 0x28 + 1, 8):
            v = struct.unpack_from('<Q', f, s[5] + o)[0]
            if not v or not v >> 63:  # real entries are authenticated pointers
                continue
            t = B + (v & 0x3fffffff)
            if not lo <= t < hi:
                continue
            c = struct.unpack_from('<4I', f, s[5] + o + 8)
            if all(x in (0, 0xffffffff) or x < 0x10000 for x in c):
                out.append((s[3] + o, t, c))
    return out


def tables(kext):
    out = []
    for e in entries(kext):
        if out and e[0] == out[-1][-1][0] + 0x28:
            out[-1].append(e)
        else:
            out.append([e])
    return out


def fstarts(kext):
    if kext not in hdr:
        return []
    kfo, vb = hdr[kext][0], hdr[kext][1]
    n = struct.unpack_from('<I', f, kfo + 16)[0]
    off = kfo + 32
    for _ in range(n):
        cmd, cs = struct.unpack_from('<II', f, off)
        if cmd == 0x26:
            dfo, dsz = struct.unpack_from('<II', f, off + 8)
        off += cs
    st = []
    v = vb
    acc = sh = 0
    for b in f[dfo:dfo + dsz]:
        acc |= (b & 0x7f) << sh
        sh += 7
        if b & 0x80:
            continue
        v += acc
        st.append(v)
        acc = sh = 0
    return st


def xref(kext, addr):
    out = []
    for s in segs:
        if s[0] != kext or s[2] != '__text':
            continue
        blob = f[s[5]:s[5] + s[4]]
        for i in range(0, len(blob) - 20, 4):
            w = struct.unpack_from('<I', blob, i)[0]
            if (w & 0x9f000000) != 0x90000000:
                continue
            imm = (((w >> 5) & 0x7ffff) << 2) | ((w >> 29) & 3)
            if imm & (1 << 20):
                imm -= 1 << 21
            if s[3] + i + (imm << 12) != addr & ~0xfff:
                continue
            w2 = struct.unpack_from('<I', blob, i + 4)[0]
            if (w2 & 0xff000000) == 0x91000000 and ((w2 >> 5) & 31) == (w & 31) \
                    and (s[3] + i + (imm << 12)) + ((w2 >> 10) & 0xfff) == addr:
                out.append(s[3] + i)
    return out


def fn(st, a):
    i = bisect.bisect_right(st, a) - 1
    return st[i], (st[i + 1] - st[i]) if i + 1 < len(st) else 0


if len(sys.argv) > 2:
    kext = sys.argv[2]
    st = fstarts(kext)
    for t in tables(kext):
        print('table %#x: %d selector(s); referenced from %s' % (
            t[0][0], len(t), ', '.join('%#x (fn %#x)' % (a, fn(st, a)[0]) for a in xref(kext, t[0][0])) or '-'))
        for n, e in enumerate(t):
            a, sz = fn(st, e[1])
            print('  sel %3d  fn %#x size %#-7x scalars_in=%u struct_in=%s scalars_out=%u struct_out=%s' % (
                n, e[1], sz, e[2][0], hex(e[2][1]), e[2][2], hex(e[2][3])))
else:
    print('kext\ttables\tselectors')
    rows = []
    for k in kexts():
        ts = tables(k)
        if ts:
            rows.append((sum(len(t) for t in ts), k, len(ts)))
    for n, k, c in sorted(rows, reverse=True):
        print('%s\t%d\t%d' % (k, c, n))

#!/tmp/jbresearch/venv/bin/python
"""kfnames.py — name kernel functions without symbols: for a function body, collect cstrings it references
(adrp+add / adrp+ldr) and print the top ones. usage: kfnames.py <kc> <kext> <hexaddr> [<hexaddr> ...]"""
import sys, struct, re, subprocess
sys.path.insert(0, __import__('os').path.dirname(__import__('os').path.abspath(__file__)))
from ins_iter import iter_ins
from capstone import Cs, CS_ARCH_ARM64, CS_MODE_ARM


def load(kc, kext):
    f = open(kc, 'rb').read()
    o = subprocess.run(['xcrun', 'otool', '-l', kc], capture_output=True, text=True).stdout
    m = re.search(r'cmd LC_FILESET_ENTRY\n.*?vmaddr 0x([0-9a-f]+)\n\s+fileoff (\d+)\n\s+entry_id\s+' + re.escape(kext) + r'\s', o, re.S)
    if not m:
        sys.exit('kext not found: ' + kext)
    kbase, kfo = int(m.group(1), 16), int(m.group(2))
    ncmds = struct.unpack_from('<I', f, kfo + 16)[0]
    off = kfo + 32
    secs = []
    for _ in range(ncmds):
        cmd, cs = struct.unpack_from('<II', f, off)
        if cmd == 0x19:
            for s in range(struct.unpack_from('<I', f, off + 64)[0]):
                so = off + 72 + s * 80
                seg = f[off + 8:off + 24].rstrip(b'\0').decode()
                sect = f[so:so + 16].rstrip(b'\0').decode()
                addr, size, foff = struct.unpack_from('<QQI', f, so + 32)
                secs.append((seg, sect, addr, size, foff))
        off += cs
    return f, secs


def read_cstr(f, secs, addr):
    for seg, sect, a, size, foff in secs:
        if a <= addr < a + size and ('const' in sect or 'cstring' in sect or 'DATA' in seg):
            fo = foff + (addr - a)
            end = f.find(b'\0', fo, fo + 200)
            if end < 0:
                return None
            s = f[fo:end]
            if len(s) >= 3 and all(32 <= c < 127 or c in (9, 10) for c in s):
                return s.decode()
    return None


def strings_in_func(f, secs, start, maxlen):
    S = next(s for s in secs if s[2] <= start < s[2] + s[3])
    fo = S[4] + (start - S[2])
    refs = []
    page = {}
    for pc, mn, ops in iter_ins(f[fo:fo + maxlen], start):
        parts = [p.strip() for p in ops.split(',')]
        if mn == 'adrp' and len(parts) >= 2:
            page[parts[0]] = int(parts[1].lstrip('#'), 16)
        elif mn == 'add' and len(parts) == 3 and parts[1] in page and parts[2].startswith('#'):
            refs.append(page[parts[1]] + int(parts[2][1:], 0))
        elif mn == 'adr' and len(parts) == 2:
            refs.append(int(parts[1].lstrip('#'), 16))
    out = []
    for r in refs:
        s = read_cstr(f, secs, r)
        if s and s not in out:
            out.append(s)
    return out


def func_end(f, secs, starts, a):
    import bisect
    i = bisect.bisect_right(starts, a)
    return starts[i] if i < len(starts) else a + 0x4000


if __name__ == '__main__':
    kc, kext = sys.argv[1], sys.argv[2]
    f, secs = load(kc, kext)
    starts = []
    for seg, sect, addr, size, foff in secs:
        if sect == '__text' and 'EXEC' in seg:
            words = struct.unpack_from('<%dI' % (size // 4), f, foff)
            starts += [addr + 4 * i for i, w in enumerate(words) if w in (0xd503237f, 0xd503237b, 0xd503233f, 0xd5032333)]
    starts.sort()
    for h in sys.argv[3:]:
        a = int(h, 16)
        n = (func_end(f, secs, starts, a) - a) // 4
        names = strings_in_func(f, secs, a, n * 4)
        print(f'{a:#x} ({n} ins): ' + ' | '.join(x[:70] for x in names[:5]))

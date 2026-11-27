#!/tmp/jbresearch/venv/bin/python
"""kfun.py — normalized per-function diff of one kext between two kernelcaches.
usage: kfun.py <old.kc> <new.kc> <bundle-id>   -> prints functions whose normalized body changed."""
import sys, struct, re, subprocess, bisect
from capstone import Cs, CS_ARCH_ARM64, CS_MODE_ARM
sys.path.insert(0, __import__('os').path.dirname(__import__('os').path.abspath(__file__)))
from ins_iter import iter_ins

PROLOGUES = (0xd503237f, 0xd503237b, 0xd503233f, 0xd5032333)


def load(kc, kext):
    f = open(kc, 'rb').read()
    o = subprocess.run(['xcrun', 'otool', '-l', kc], capture_output=True, text=True).stdout
    m = re.search(r'cmd LC_FILESET_ENTRY\n.*?vmaddr 0x([0-9a-f]+)\n\s+fileoff (\d+)\n\s+entry_id\s+' + re.escape(kext) + r'\s', o, re.S)
    if not m:
        return f, None, []
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
    return f, kbase, secs


def functions(f, secs):
    """[(addr, end)] split on pacibsp/paciasp prologues inside __text."""
    out = []
    for seg, sect, addr, size, foff in secs:
        if sect != '__text' or 'EXEC' not in seg:
            continue
        words = struct.unpack_from('<%dI' % (size // 4), f, foff)
        starts = [addr + 4 * i for i, w in enumerate(words) if w in PROLOGUES]
        for a, b in zip(starts, starts[1:] + [addr + size]):
            out.append((a, b))
    return sorted(out)


def normalize(f, secs, a, b):
    S = next(s for s in secs if s[2] <= a < s[2] + s[3])
    fo = S[4] + (a - S[2])
    sig = []
    for pc, mn, ops in iter_ins(f[fo:fo + (b - a)], a):
        ops = re.sub(r'#-?0x[0-9a-f]+|#-?\d+', '#N', ops)
        sig.append(mn + ' ' + ops)
    return sig


def fnhash(sig):
    import hashlib
    return hashlib.sha1('\n'.join(sig).encode()).hexdigest()[:16]


def removed_added(F, N):
    """F, N: [(addr, end, sig)]. Returns (gone_from_new, new_in_new) by normalized-body hash."""
    from collections import Counter
    ho = Counter(fnhash(x[2]) for x in F)
    hn = Counter(fnhash(x[2]) for x in N)
    gone = [x for x in F if ho[fnhash(x[2])] > hn.get(fnhash(x[2]), 0)]
    new = [x for x in N if hn[fnhash(x[2])] > ho.get(fnhash(x[2]), 0)]
    gone.sort(key=lambda x: -(x[1] - x[0]))
    new.sort(key=lambda x: -(x[1] - x[0]))
    return gone, new


if __name__ == '__main__':
    old_kc, new_kc, kext = sys.argv[1:4]
    limit = int(sys.argv[4]) if len(sys.argv) > 4 else 40
    fo_, kb_o, secs_o = load(old_kc, kext)
    fn_, kb_n, secs_n = load(new_kc, kext)
    if kb_o is None or kb_n is None:
        sys.exit('kext not found: ' + kext)
    F = [(a, b, normalize(fo_, secs_o, a, b)) for a, b in functions(fo_, secs_o)]
    N = [(a, b, normalize(fn_, secs_n, a, b)) for a, b in functions(fn_, secs_n)]
    gone, new = removed_added(F, N)
    print(f'# {kext}: old {len(F)} fns, new {len(N)} fns; body changed/removed in old: {len(gone)}, new/changed in new: {len(new)}')
    for label, lst in (('GONE', gone), ('NEW', new)):
        for a, b, sig in lst[:limit]:
            print(f'{label:4} {a:#x} size={(b - a) // 4} ins')

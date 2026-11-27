#!/tmp/jbresearch/venv/bin/python
"""cstr.py <kc> <kext> <hexaddr>... — read NUL-terminated strings at VM addresses of a fileset kext."""
import sys
from kfun import load
kc, kext = sys.argv[1], sys.argv[2]
f, _, secs = load(kc, kext)
for a in sys.argv[3:]:
    v = int(a, 16); got = None
    for seg, sect, addr, size, foff in secs:
        if addr <= v < addr + size:
            off = foff + (v - addr); e = f.index(b'\0', off)
            got = f[off:e].decode('latin1'); break
    print('%#x: %r' % (v, got))

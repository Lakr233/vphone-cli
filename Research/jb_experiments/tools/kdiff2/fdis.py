#!/tmp/jbresearch/venv/bin/python
"""fdis.py <kc> <kext> <hexaddr> — plain one-line-per-instruction disassembly of one function (via kfun prologue split)."""
import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from kfun import load, functions
from ins_iter import iter_ins

if __name__ == '__main__':
    kc, kext, a = sys.argv[1], sys.argv[2], int(sys.argv[3], 16)
    f, _, secs = load(kc, kext)
    for s, e in functions(f, secs):
        if s == a:
            S = next(x for x in secs if x[2] <= s < x[2] + x[3])
            fo = S[4] + (s - S[2])
            for pc, mn, ops in iter_ins(f[fo:fo + (e - s)], s):
                print(f'{pc:#x}  {mn} {ops}')
            break
    else:
        sys.exit('no function at %#x' % a)

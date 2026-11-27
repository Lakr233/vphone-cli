# fnfull.py <kc> <start> <n> : per-word listing of a function (no stop on ret), up to the next function's pacibsp
import os, sys
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, '..', 'kdiff2'))  # tools/kdiff2/ins_iter.py (per-word decode)
import kdiff, ins_iter
kc, st, n = sys.argv[1], int(sys.argv[2], 16), int(sys.argv[3])
f, kb, secs = kdiff.load(kc, 'com.apple.kernel')
S = next(s for s in secs if s[4] and s[2] <= st < s[2] + s[3]); fo = S[4] + (st - S[2])
for i, (a, m, o) in enumerate(ins_iter.iter_ins(f[fo:fo + 4 * n], st)):
    if i and m == 'pacibsp':
        break
    print(f'{a:#x}  {m:<8} {o}')

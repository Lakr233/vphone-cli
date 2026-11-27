# tail.py <kc> <start> <n> : per-word listing (no stop on ret) of a fixed range
import os, sys
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, '..', 'kdiff2'))  # tools/kdiff2/ins_iter.py (per-word decode)
import kdiff, ins_iter
kc, st, n = sys.argv[1], int(sys.argv[2], 16), int(sys.argv[3])
f, kb, secs = kdiff.load(kc, 'com.apple.kernel')
S = next(s for s in secs if s[4] and s[2] <= st < s[2] + s[3]); fo = S[4] + (st - S[2])
for a, m, o in ins_iter.iter_ins(f[fo:fo + 4 * n], st):
    print(f'{a:#x}  {m:<8} {o}')
    if m in ('retab', 'retaa', 'ret', 'retx16', 'retaa'): break

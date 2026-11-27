# wordcheck.py <kc> <start> <n_words> <listing.dis> : per-word decode (tools/kdiff2/ins_iter.py) vs a listing made by kdiff.dis
import os, sys
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, '..', 'kdiff2'))  # tools/kdiff2/ins_iter.py (per-word decode)
import kdiff, ins_iter
kc, st, n, lst = sys.argv[1], int(sys.argv[2], 16), int(sys.argv[3]), sys.argv[4]
f, kb, secs = kdiff.load(kc, 'com.apple.kernel')
S = next(s for s in secs if s[4] and s[2] <= st < s[2] + s[3])
fo = S[4] + (st - S[2])
words = list(ins_iter.iter_ins(f[fo:fo + 4 * n], st))
listed = {}
for ln in open(lst):
    a, m, *o = ln.split(None, 2)
    listed[int(a, 16)] = (m, (o[0].strip() if o else ''))
nd = [(hex(a), m, o) for a, m, o in words if m == '.word']
mism = [(hex(a), m, o, listed.get(a)) for a, m, o in words if a in listed and (m, o) != listed[a]]
last = max(listed)
print(f'{lst.split("/")[-1]}: listing has {len(listed)} ins, last={last:#x}; per-word range {st:#x}..{st + 4 * n - 4:#x}')
print(f'  undecodable words in listing range: {len([x for x in nd if st <= int(x[0], 16) <= last])}  (in full range: {len(nd)})')
print(f'  listing-vs-per-word mismatches: {len(mism)}')
after = [(a, m, o) for a, m, o in words if a > last]
print(f'  words after last listed: {len(after)}; first 6:', [(hex(a), m, o) for a, m, o in after[:6]])

#!/tmp/jbresearch/venv/bin/python
"""fdiff.py — normalized instruction diff of ONE function between two kernelcaches (same kext).
usage: fdiff.py <old.kc> <new.kc> <kext> <old_hexaddr> <new_hexaddr>"""
import sys, re, difflib, struct
sys.path.insert(0, __import__('os').path.dirname(__import__('os').path.abspath(__file__)))
from kfun import load, functions, normalize


def func_at(f, secs, a):
    for s, e in functions(f, secs):
        if s == a:
            return s, e
    sys.exit('no function starts at %#x' % a)


if __name__ == '__main__':
    old_kc, new_kc, kext, oa, na = sys.argv[1:6]
    oa, na = int(oa, 16), int(na, 16)
    fo, _, so = load(old_kc, kext)
    fn, _, sn = load(new_kc, kext)
    a1, b1 = func_at(fo, so, oa)
    a2, b2 = func_at(fn, sn, na)
    s1 = normalize(fo, so, a1, b1)
    s2 = normalize(fn, sn, a2, b2)
    print(f'# old {a1:#x} {len(s1)} ins | new {a2:#x} {len(s2)} ins')
    n = 0
    for line in difflib.unified_diff(s1, s2, 'old', 'new', lineterm='', n=3):
        print(line)
        n += 1
        if n > 400:
            print('... truncated')
            break

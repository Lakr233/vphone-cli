#!/tmp/jbresearch/venv/bin/python
"""xref.py <kc> <kext> <hexaddr> — find bl/b instructions in the kext's __text that target <addr>."""
import sys, struct
sys.path.insert(0, '/tmp/jbresearch/igmp')
from kfun import load
from ins_iter import iter_ins
kc, kext, target = sys.argv[1], sys.argv[2], int(sys.argv[3], 16)
f, _, secs = load(kc, kext)
for seg, sect, addr, size, foff in secs:
    if sect != '__text' or 'EXEC' not in seg:
        continue
    for pc, mn, ops in iter_ins(f[foff:foff + size], addr):
        if mn in ('bl', 'b') and ops.startswith('#'):
            try:
                t = int(ops[1:], 16)
            except ValueError:
                continue
            if t == target:
                print('%#x  %s' % (pc, mn))

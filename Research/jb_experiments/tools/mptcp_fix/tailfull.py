# tailfull.py <kc> <start> <n> : per-word listing of the cold tail (after first retab) up to the 2nd retab; flags sb_mb/sb_lastrecord writes, m_freem
import os, sys, re
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, '..', 'kdiff2'))  # tools/kdiff2/ins_iter.py (per-word decode)
import kdiff, ins_iter
kc, st, n = sys.argv[1], int(sys.argv[2], 16), int(sys.argv[3])
f, kb, secs = kdiff.load(kc, 'com.apple.kernel')
S = next(s for s in secs if s[4] and s[2] <= st < s[2] + s[3]); fo = S[4] + (st - S[2])
rets = 0
for a, m, o in ins_iter.iter_ins(f[fo:fo + 4 * n], st):
    flag = ''
    if re.search(r'\[x19, #(0x88|0x90|0x98)\]', o) and m.startswith('st'): flag = '  <== so_rcv write'
    if m in ('stp',) and 'x19' in o and '#0x90' in o: flag = '  <== SB_EMPTY_FIXUP'
    print(f'{a:#x}  {m:<8} {o}{flag}')
    if m in ('retab', 'retaa', 'ret', 'retx16'):
        rets += 1
        if rets >= 2: break

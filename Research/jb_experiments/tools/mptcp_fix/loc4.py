#!/tmp/jbresearch/venv/bin/python
# loc4.py <kc> : locate mptcp_subflow_soreceive (via unique string xrefs) and print bounds + anchor xrefs
import sys, struct
import kdiff
kc = sys.argv[1]
f, kb, secs = kdiff.load(kc, 'com.apple.kernel')
S = next(s for s in secs if s[1] == '__text' and 'EXEC' in s[0])
text_addr, text_size, text_fo = S[2], S[3], S[4]

def word(pc):
    return struct.unpack_from('<I', f, text_fo + (pc - text_addr))[0]

PAC = {0xd503233f: 'pacibsp', 0xd5032333: 'paciasp', 0xd503237f: 'pacibsp?', 0xd503237b: 'paciasp?'}
RET = (0xd61f03c0, 0xd61f03c1)  # br x16 after autiasp etc. -> we'll treat 'retab/retaa' via capstone

def fn_bounds(pc):
    # walk back to prologue
    st = None
    for k in range(1, 20000):
        w = word(pc - 4 * k)
        if (w & 0xfffffc1f) == 0xd503233f or (w & 0xfffffc1f) == 0xd5032333:
            st = pc - 4 * k; break
    # walk forward to next prologue
    for k in range(1, 400000):
        w = word(st + 4 * k)
        if (w & 0xfffffc1f) == 0xd503233f or (w & 0xfffffc1f) == 0xd5032333:
            return st, st + 4 * k
    return st, None

anchors = ['mptcp_subflow_soreceive 1', 'mptcp_subflow_soreceive 2', 'm->m_nextpkt == NULL',
           'No DSS on secondary subflow', 'without DSS-mapping', 'mptcp_subflow_soreceive']
found = {}
for needle in anchors:
    for s in kdiff.find_str(f, secs, needle.encode())[:1]:
        xs = kdiff.xrefs(f, secs, s)
        for x in xs:
            st = kdiff.func_start(f, secs, x)
            found.setdefault(needle, []).append((s, x, st))
for n, v in found.items():
    for s, x, st in v:
        print(f'{n!r:34} str={s:#x} xref={x:#x} fn_start={st:#x}')
starts = sorted({st for v in found.values() for (_, _, st) in v if st})
print('FUNCTION starts:', [hex(s) for s in starts])
if len(starts) == 1:
    st, en = fn_bounds(starts[0])
    print(f'FUNCTION mptcp_subflow_soreceive start={st:#x} end={en and hex(en)} size={en and hex(en - st)}')
    # print every xref inside the function with its line
    for n, v in found.items():
        for s, x, _ in v:
            if st <= x < en:
                print(f'  anchor {n!r}: xref@{x:#x} (+{x - st:#x}) str@{s:#x}')

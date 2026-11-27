#!/tmp/jbresearch/venv/bin/python
# check_fix.py : re-derive the per-build table of mptcp_fix_localization.md from the four kernelcaches.
# usage: check_fix.py [kc23F84 kc23G71 kc23G83 kc24B156]   (defaults = the paths used in the note)
# Prints, per build: function start, the DFIN test, the sb_cc<dlen check, the loop-skip compare,
# the unlink block (present/absent), the validate_csum call and the failure handler. Exit 1 if any
# anchor is missing.
import os, sys, struct
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, '..', 'kdiff2'))  # tools/kdiff2/ins_iter.py (per-word decode)
import kdiff, ins_iter

DEFAULT = [
    ('23F84',  '/tmp/jbresearch/ipsw/x13/kc.decomp/kernelcache.release.iphone14.decompressed'),
    ('23G71',  '/tmp/jbresearch/ipsw/266/23G71__iPhone14,5/kernelcache.release.iPhone14,5'),
    ('23G83',  '/tmp/jbresearch/ipsw/2661/23G83__iPhone14,5/kernelcache.release.iPhone14,5'),
    ('24B156', '/tmp/jbresearch/ipsw/x17/kc.decomp/kernelcache.release.v54.decompressed'),
]
DFIN = 0x40000000          # PKTF_MPTCP_DFIN
SO_SBMB, SO_LASTREC = 0x88, 0x98

def reg(s):  # 'w12' -> 'x12'
    return 'x' + s[1:] if s[0] in 'wx' and s[1:].isdigit() else s

def analyse(kc):
    f, kb, secs = kdiff.load(kc, 'com.apple.kernel')
    st = kdiff.func_start(f, secs, kdiff.xrefs(f, secs, kdiff.find_str(f, secs, b'mptcp_subflow_soreceive 1')[0])[0])
    S_ = next(s_ for s_ in secs if s_[4] and s_[2] <= st < s_[2] + s_[3]); fo_ = S_[4] + (st - S_[2])
    ins = []  # whole function, per word, up to the next function's pacibsp
    for i, (a_, m_, o_) in enumerate(ins_iter.iter_ins(f[fo_:fo_ + 4 * 2000], st)):
        if i and m_ == 'pacibsp':
            break
        ins.append((a_, m_, o_))
    out = {'start': st, 'n': len(ins)}
    # (a) the only `and wX, wY, #0x40000000` in the function
    a = [(i, p, o) for i, (p, m, o) in enumerate(ins) if m == 'and' and hex(DFIN) in o]
    assert len(a) == 1, f'{kc}: expected one DFIN test, got {len(a)}'
    i0, p0, o0 = a[0]; wdfin = o0.split(',')[0].strip()
    out['dfin_test'] = p0; out['dfin_reg'] = wdfin
    # (a) dlen = mp_rlen + (dfin<<1 asr #31): first `add wX, wY, wZ, asr #31` after it
    j = next(i for i in range(i0, i0 + 6) if ins[i][1] == 'add' and 'asr #31' in ins[i][2])
    wdlen = ins[j][2].split(',')[0].strip(); out['dlen_calc'] = ins[j][0]; out['dlen_reg'] = wdlen
    # (b) `cmp wX, wY` (sb_cc, dlen) then `b.lt` ; then first `cmp wY, #1` + `b.lt`
    k = next(i for i in range(j, j + 6) if ins[i][1] == 'cmp' and ins[i][2].endswith(', ' + wdlen))
    out['sbcc_cmp'] = ins[k][0]; out['sbcc_blt'] = ins[k + 1][0]
    l = next(i for i in range(k, k + 80) if ins[i][1] == 'cmp' and ins[i][2] == f'{wdlen}, #1' and ins[i + 1][1] == 'b.lt')
    out['loop_skip'] = ins[l][0]; out['loop_skip_target'] = int(ins[l + 1][2].split('#')[1], 16)
    # unlink block: between sbcc_blt and loop_skip, a `cbz <dfin_reg>, T` followed (within 8 ins) by `bl sbfree`
    blk = [i for i in range(k + 2, l) if ins[i][1] == 'cbz' and ins[i][2].startswith(wdfin + ',')]
    out['unlink_block'] = None
    for i in blk:
        bls = [x for x in ins[i:i + 16] if x[1] == 'bl']
        if bls:
            out['unlink_block'] = (ins[i][0], int(ins[i][2].split('#')[1], 16), bls[0][0], int(bls[0][2].split('#')[1], 16))
    # (c) bl mptcp_validate_csum: the first `bl` after loop_skip whose callee body contains `rev16` and `rev w`
    for i in range(l, len(ins)):
        if ins[i][1] == 'bl':
            t = int(ins[i][2].split('#')[1], 16)
            S_ = next(s_ for s_ in secs if s_[4] and s_[2] <= t < s_[2] + s_[3]); fo_ = S_[4] + (t - S_[2])
            body = [m + ' ' + o for _, m, o in ins_iter.iter_ins(f[fo_:fo_ + 4 * 115], t)]  # per word: md.disasm stops at the first undecodable word
            if any(x.startswith('rev16 ') for x in body) and any(x.startswith('rev w') for x in body):
                out['validate_call'] = ins[i][0]; out['validate'] = t
                out['validate_x1'] = next(o for _, m, o in ins[max(0, i - 8):i] if m in ('mov', 'ldur', 'ldr') and o.startswith('x1,'))
                c = next(x for x in ins[i + 1:i + 5] if x[1] == 'cbnz' and x[2].startswith('w0,'))
                out['validate_fail'] = int(c[2].split('#')[1], 16)
                break
    # (d) at validate_fail: `str xzr, [xN]` then `mov wM, #5`
    if out.get('validate_fail'):
        fa = next(p for p, _, _ in ins if p == out['validate_fail'])
        d = [(p, m, o) for p, m, o in ins if p >= fa][:3]
        assert d[0][1] == 'str' and d[0][2] == 'xzr, [x20]' and d[1][2].startswith('w20, #5'), f'{kc}: unexpected failure handler {d}'
        out['fail_handler'] = (d[0][0], d[1][0])
    return out

if __name__ == '__main__':
    paths = sys.argv[1:] or [p for _, p in DEFAULT]
    names = ['23F84', '23G71', '23G83', '24B156']
    for name, kc in zip(names, paths):
        r = analyse(kc)
        fh = r['fail_handler']
        print(f'{name}: start={r["start"]:#x} ins={r["n"]} dfin_test={r["dfin_test"]:#x} dlen={r["dlen_calc"]:#x} '
              f'sbcc_cmp={r["sbcc_cmp"]:#x} loop_skip={r["loop_skip"]:#x}->{r["loop_skip_target"]:#x} '
              f'unlink_block={("present cbz@%#x bl@%#x" % (r["unlink_block"][0], r["unlink_block"][2])) if r["unlink_block"] else "ABSENT"} '
              f'validate_call={r["validate_call"]:#x}->{r["validate"]:#x} (x1={r["validate_x1"]}) '
              f'fail_handler=({fh[0]:#x}, {fh[1]:#x})')

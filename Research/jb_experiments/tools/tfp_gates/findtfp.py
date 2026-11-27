#!/usr/bin/env python3
"""findtfp.py <kernelcache> — locate task_for_pid from the 'proc_ro_ref_task' string (vphone patcher's anchor),
then report the S1 (pid==0 cbz) and S3 (cbnz w0 after bl <mac_proc_check_get_task>) gates with file offsets and bytes.
Everything is read from the file with the section table (VA -> foff per section)."""
import sys, struct
sys.path.insert(0, __import__('os').path.dirname(__import__('os').path.abspath(__file__)))
import kdiff
from capstone import Cs, CS_ARCH_ARM64, CS_MODE_ARM

def fo(secs, va):
    S = next(s for s in secs if s[4] and s[2] <= va < s[2] + s[3])
    return S[4] + (va - S[2])

def word(f, secs, va):
    return struct.unpack_from('<I', f, fo(secs, va))[0]

def dis(f, secs, va, n):
    o = fo(secs, va); md = Cs(CS_ARCH_ARM64, CS_MODE_ARM)
    return [(i.address, i.mnemonic, i.op_str) for i in md.disasm(f[o:o + 4 * n], va)]

if __name__ == '__main__':
    kc = sys.argv[1]
    f, kb, secs = kdiff.load(kc, 'com.apple.kernel')
    cs = [s for s in secs if s[1] == '__cstring' and s[4]]
    saddr = None
    for seg, sect, addr, size, foff in cs:
        i = f[foff:foff + size].find(b'proc_ro_ref_task\x00')
        if i >= 0: saddr = addr + i
    refs = kdiff.xrefs(f, secs, saddr)
    fn = kdiff.func_start(f, secs, refs[0]) if refs else None
    print(f'{kc.split("/")[-1]}: fileset base {kb:#x}  "proc_ro_ref_task" {saddr:#x}  xrefs {[hex(r) for r in refs]}  func {fn:#x} (foff {fo(secs, fn):#x})')
    ins = dis(f, secs, fn, 0x140)
    for a, m, o in ins[:12]:
        print(f'   {a:#x} {word(f, secs, a):08x}  {m:7} {o}')
    # S1: first cbz wN, target whose next insns are mov w1,#0; mov w2,#0; mov w3,#0; mov x4,#0; bl; cbz x0, same target
    s1 = None
    for k in range(len(ins) - 7):
        a, m, o = ins[k]
        if m != 'cbz' or not o.startswith('w'): continue
        tgt = o.split(', ')[1]
        seq = ins[k + 1:k + 7]
        want = [('mov', 'w1, #0'), ('mov', 'w2, #0'), ('mov', 'w3, #0'), ('mov', 'x4, #0'), ('bl', None), ('cbz', 'x0, ' + tgt)]
        if all(x[1] == w[0] and (w[1] is None or x[2] == w[1]) for x, w in zip(seq, want)):
            s1 = a; break
    print(f'   S1 pid==0 cbz : {s1:#x} foff {fo(secs, s1):#x} bytes {word(f, secs, s1):08x}')
    # S3: the bl whose following insn is `cbnz w0, X`, where between the cbz w0 of posix_check and it lie the MACF call
    # find every `bl` followed immediately by `cbnz w0`
    cands = []
    for k in range(len(ins) - 1):
        a, m, o = ins[k]
        if m == 'bl' and ins[k + 1][1] == 'cbnz' and ins[k + 1][2].startswith('w0'):
            cands.append((a, int(o.lstrip('#'), 16), ins[k + 1][0]))
    for a, tgt, cb in cands:
        print(f'   bl@{a:#x} -> {tgt:#x} ; cbnz w0 @{cb:#x} bytes {word(f, secs, cb):08x} foff {fo(secs, cb):#x}')

#!/usr/bin/env python3
"""kc.py <kernelcache> — VA -> file bytes and capstone listing for one com.apple.kernel fileset entry.
usage: kc.py <kc> bytes VA [n]        -> n words at VA with their file offsets
       kc.py <kc> dis VA [n]          -> capstone listing (stops at first retab/ret after 3 insns unless n given)
       kc.py <kc> secs                -> sections
VA->file: section foff + (VA - section addr). In a kernel-last mix that is NOT (VA - fileset base)."""
import sys, struct, re, subprocess
sys.path.insert(0, __import__('os').path.dirname(__import__('os').path.abspath(__file__)))
import kdiff
from capstone import Cs, CS_ARCH_ARM64, CS_MODE_ARM

def words(f, secs, va, n=1):
    S = next(s for s in secs if s[4] and s[2] <= va < s[2] + s[3])
    fo = S[4] + (va - S[2])
    return fo, S, [struct.unpack_from('<I', f, fo + 4 * k)[0] for k in range(n)]

if __name__ == '__main__':
    kc, cmd = sys.argv[1], sys.argv[2]
    f, kbase, secs = kdiff.load(kc, 'com.apple.kernel')
    if cmd == 'secs':
        for s in secs:
            if s[4] or s[3]: print(f'{s[0]:16} {s[1]:22} addr {s[2]:#x} size {s[3]:#x} foff {s[4]:#x}')
        sys.exit()
    va = int(sys.argv[3], 16); n = int(sys.argv[4]) if len(sys.argv) > 4 else 1
    if cmd == 'bytes':
        for k in range(n):
            fo, S, w = words(f, secs, va + 4 * k, 1)
            print(f'{va + 4 * k:#x}  foff {fo:#x}  {w[0]:08x}')
    elif cmd == 'dis':
        S = next(s for s in secs if s[4] and s[2] <= va < s[2] + s[3])
        fo = S[4] + (va - S[2])
        md = Cs(CS_ARCH_ARM64, CS_MODE_ARM)
        out = []
        for ins in md.disasm(f[fo:fo + 4 * n], va):
            w = struct.unpack_from('<I', f, fo + ins.address - va)[0]
            out.append(f'{ins.address:#x}  {w:08x}  {ins.mnemonic:8} {ins.op_str}')
            if ins.mnemonic in ('retab', 'ret', 'retaa') and len(out) > 3: break
        print('\n'.join(out) if out else 'no decode')

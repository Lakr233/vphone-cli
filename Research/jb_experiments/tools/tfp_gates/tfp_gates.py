#!/usr/bin/env python3
"""tfp_gates.py <kernelcache> <task_for_pid VA> [n_ins] — full listing of task_for_pid with file offsets and bytes.
Stops at the function's tail return; prints every kr-setting site."""
import sys, struct
sys.path.insert(0, __import__('os').path.dirname(__import__('os').path.abspath(__file__)))
import kdiff
from capstone import Cs, CS_ARCH_ARM64, CS_MODE_ARM

def fo(secs, va):
    S = next(s for s in secs if s[4] and s[2] <= va < s[2] + s[3])
    return S[4] + (va - S[2])

kc, start = sys.argv[1], int(sys.argv[2], 16)
n = int(sys.argv[3], 0) if len(sys.argv) > 3 else 0x480 // 4
f, kb, secs = kdiff.load(kc, 'com.apple.kernel')
o = fo(secs, start); md = Cs(CS_ARCH_ARM64, CS_MODE_ARM)
out = []
for i in md.disasm(f[o:o + 4 * n], start):
    w = struct.unpack_from('<I', f, o + i.address - start)[0]
    out.append(f'{i.address:#x}  foff {fo(secs, i.address):#010x}  {w:08x}  {i.mnemonic:8} {i.op_str}')
open(sys.argv[4] if len(sys.argv) > 4 else '/dev/stdout', 'w').write('\n'.join(out) + '\n')
print(len(out), 'insns ->', sys.argv[4] if len(sys.argv) > 4 else 'stdout')

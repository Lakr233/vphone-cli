#!/usr/bin/env python3
"""disasm.py <kernelcache> <kext-id> <va> [count] — disassemble raw arm64e from a fileset sub-binary (minimal decoder)."""
import sys, struct, re, subprocess
KC, kext, va = sys.argv[1], sys.argv[2], int(sys.argv[3], 16)
n = int(sys.argv[4]) if len(sys.argv) > 4 else 24
f = open(KC, 'rb').read()
o = subprocess.run(['xcrun', 'otool', '-l', KC], capture_output=True, text=True).stdout
m = re.search(r'vmaddr 0x([0-9a-f]+)\n\s+fileoff (\d+)\n\s+entry_id\s+' + re.escape(kext) + r'\s', o)
kfo = int(m.group(2)); ncmds = struct.unpack_from('<I', f, kfo + 16)[0]; off = kfo + 32
secs = []
for _ in range(ncmds):
    cmd, cs = struct.unpack_from('<II', f, off)
    if cmd == 0x19:
        for s in range(struct.unpack_from('<I', f, off + 64)[0]):
            so = off + 72 + s * 80
            secs.append(struct.unpack_from('<QQI', f, so + 32))
    off += cs
a, sz, sfo = next(s for s in secs if s[0] <= va < s[0] + s[1])
fo = sfo + (va - a)

def bits(v, hi, lo): return (v >> lo) & ((1 << (hi - lo + 1)) - 1)
def dec(i):
    op = i >> 24
    if (i & 0x7f000000) == 0x34000000:  # cbz/cbnz 32/64
        sf, nz = i >> 31, (i >> 24) & 1
        imm = bits(i, 23, 5); rt = i & 31
        return f"{'cbnz' if nz else 'cbz'} {'x' if sf else 'w'}{rt}, +{imm*4:#x}"
    if (i & 0xff800000) == 0x52800000 or (i & 0xff800000) == 0xd2800000:
        sf = i >> 31; hw = bits(i, 22, 21); imm16 = bits(i, 20, 5); rd = i & 31
        return f"mov {'x' if sf else 'w'}{rd}, #{imm16 << (16 * hw):#x}"
    if (i & 0x7c000000) == 0x14000000:
        imm = bits(i, 25, 0); imm = imm - (1 << 26) if imm & (1 << 25) else imm
        return f"{'bl' if i >> 31 else 'b'} +{imm*4:+#x}"
    if (i & 0xffc00000) == 0xf9400000: return f"ldr x{i & 31}, [x{(i>>5)&31}, #{bits(i,21,10)*8:#x}]"
    if (i & 0xffc00000) == 0xb9400000: return f"ldr w{i & 31}, [x{(i>>5)&31}, #{bits(i,21,10)*4:#x}]"
    if i == 0xd503201f: return "nop"
    if (i & 0x9f000000) == 0x90000000:
        imm = (((i >> 5) & 0x7ffff) << 2) | ((i >> 29) & 3); imm = (imm << 43) >> 43
        return f"adrp x{i & 31}, {((va & ~0xfff) + (imm << 12)):#x}"
    if (i & 0xff800000) == 0x91000000: return f"add x{i & 31}, x{(i>>5)&31}, #{bits(i,21,10):#x}"
    if (i & 0xffe0fc00) == 0xaa0003e0 or (i & 0x7fe0fc00) == 0x2a0003e0: return f"mov {'x' if i>>31 else 'w'}{i & 31}, {'x' if i>>31 else 'w'}{(i>>16)&31}"
    if i == 0xd65f03c0: return "ret"
    if (i & 0xffe0fc00) == 0x6b00001f: return f"cmp {'x' if i>>31 else 'w'}{(i>>5)&31}, #{bits(i,20,10):#x}"
    if (i & 0x7e000000) == 0x36000000: return f"tbz/tbnz w{i&31}"
    return f".word {i:#010x}"

for k in range(n):
    pc = va + 4 * k
    i = struct.unpack_from('<I', f, fo + 4 * k)[0]
    print(f"{pc:#x}  {i:08x}  {dec(i)}")

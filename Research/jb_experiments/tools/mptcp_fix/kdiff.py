#!/tmp/jbresearch/venv/bin/python
"""kdiff.py — locate functions in a decompressed kernelcache by string xref and compare across builds.
usage: kdiff.py <kc> "<cstring>" [--kext com.apple.kernel] [--all]"""
import sys, struct, re, subprocess, argparse
from capstone import Cs, CS_ARCH_ARM64, CS_MODE_ARM

def load(kc, kext):
    f = open(kc, 'rb').read()
    o = subprocess.run(['xcrun', 'otool', '-l', kc], capture_output=True, text=True).stdout
    m = re.search(r'cmd LC_FILESET_ENTRY\n.*?vmaddr 0x([0-9a-f]+)\n\s+fileoff (\d+)\n\s+entry_id\s+' + re.escape(kext) + r'\s', o, re.S)
    kbase, kfo = int(m.group(1), 16), int(m.group(2))
    ncmds = struct.unpack_from('<I', f, kfo + 16)[0]; off = kfo + 32; secs = []
    for _ in range(ncmds):
        cmd, cs = struct.unpack_from('<II', f, off)
        if cmd == 0x19:
            seg = f[off + 8:off + 24].rstrip(b'\0').decode()
            for s in range(struct.unpack_from('<I', f, off + 64)[0]):
                so = off + 72 + s * 80
                secs.append((seg, f[so:so + 16].rstrip(b'\0').decode(), *struct.unpack_from('<QQI', f, so + 32)))
        off += cs
    return f, kbase, secs

def find_str(f, secs, needle):
    out = []
    for seg, sect, addr, size, foff in secs:
        if sect != '__cstring': continue
        blob = f[foff:foff + size]; i = blob.find(needle)
        while i >= 0 and len(out) < 3:
            out.append(addr + i)
            i = blob.find(needle, i + 1)
    return out

def xrefs(f, secs, saddr):
    hits = []
    for seg, sect, addr, size, foff in secs:
        if sect != '__text' and sect != '__text': continue
        if 'EXEC' not in seg: continue
        td = f[foff:foff + size]
        for i in range(0, len(td) - 8, 4):
            a, b = struct.unpack_from('<II', td, i)
            if (a & 0x9f000000) != 0x90000000: continue
            rd = a & 31; imm = (((a >> 5) & 0x7ffff) << 2) | ((a >> 29) & 3); imm = (imm << 43) >> 43
            pc = addr + i
            t = ((pc & ~0xfff) + (imm << 12)) & 0xffffffffffffffff
            if (b & 0xff800000) == 0x91000000 and ((b >> 5) & 31) == rd and ((t + ((b >> 10) & 0xfff)) & 0xffffffffffffffff) in (saddr, saddr + 0x200000000):
                hits.append(pc)
    return hits

def func_start(f, secs, pc):
    """walk back to a pacibsp/paciasp prologue (0xd503233f / 0xd5032333)"""
    S = next(s for s in secs if s[4] and s[2] <= pc < s[2] + s[3])
    fo = S[4] + (pc - S[2])
    for k in range(1, 4000):
        i = struct.unpack_from('<I', f, fo - 4 * k)[0]
        if i in (0xd503237f, 0xd503237b, 0xd503233f, 0xd5032333): return pc - 4 * k
    return None

def dis(f, secs, start, n=400, stop_ret=True):
    S = next(s for s in secs if s[4] and s[2] <= start < s[2] + s[3])
    fo = S[4] + (start - S[2])
    md = Cs(CS_ARCH_ARM64, CS_MODE_ARM); md.detail = False
    out = []
    for ins in md.disasm(f[fo:fo + 4 * n], start):
        out.append((ins.address, ins.mnemonic, ins.op_str))
        if stop_ret and ins.mnemonic in ('retab', 'retaa', 'ret', 'retaa') and len(out) > 3: break
    if not out:
        # fallback: raw
        for k in range(n):
            i = struct.unpack_from('<I', f, fo + 4 * k)[0]
            out.append((start + 4 * k, '.word', hex(i)))
    return out

if __name__ == '__main__':
    ap = argparse.ArgumentParser(); ap.add_argument('kc'); ap.add_argument('needle'); ap.add_argument('--kext', default='com.apple.kernel'); ap.add_argument('--n', type=int, default=400)
    a = ap.parse_args()
    f, kbase, secs = load(a.kc, a.kext)
    sa = find_str(f, secs, a.needle.encode())
    print(f'# string "{a.needle}" @', [hex(x) for x in sa])
    for s in sa[:1]:
        xs = xrefs(f, secs, s)
        print(f'# xrefs:', [hex(x) for x in xs])
        for x in xs[:4]:
            fs_ = func_start(f, secs, x)
            if fs_ is None: print(f'## xref {x:#x} -> function start not found (no pacibsp within 4000 ins)'); continue
            print(f'## xref {x:#x} -> function {fs_:#x}')
            for pc, mn, ops in dis(f, secs, fs_, a.n): print(f'{pc:#x}  {mn} {ops}')
            print()

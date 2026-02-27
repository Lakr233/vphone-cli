#!/usr/bin/env python3
"""
txm_patcher.py — Dynamic patcher for TXM (Trusted Execution Monitor) images.

Finds the trustcache hash lookup (binary search) in the AMFI certificate
verification function and bypasses it.  NO hardcoded offsets.

Dependencies:  keystone-engine, capstone
"""

import struct
from keystone import Ks, KS_ARCH_ARM64, KS_MODE_LITTLE_ENDIAN as KS_MODE_LE
from capstone import Cs, CS_ARCH_ARM64, CS_MODE_LITTLE_ENDIAN

# ── Assembly / disassembly singletons ──────────────────────────
_ks = Ks(KS_ARCH_ARM64, KS_MODE_LE)
_cs = Cs(CS_ARCH_ARM64, CS_MODE_LITTLE_ENDIAN)
_cs.detail = True
_cs.skipdata = True


def _asm(s):
    enc, _ = _ks.asm(s)
    if not enc:
        raise RuntimeError(f"asm failed: {s}")
    return bytes(enc)


MOV_X0_0 = _asm("mov x0, #0")


def _disasm_one(data, off):
    insns = list(_cs.disasm(data[off:off + 4], off))
    return insns[0] if insns else None


def _find_asm_pattern(data, asm_str):
    enc, _ = _ks.asm(asm_str)
    pattern = bytes(enc)
    results = []
    off = 0
    while True:
        idx = data.find(pattern, off)
        if idx < 0:
            break
        results.append(idx)
        off = idx + 4
    return results


# ── TXMPatcher ─────────────────────────────────────────────────

class TXMPatcher:
    """Dynamic patcher for TXM images.

    Patches:
      1. Trustcache binary-search BL → mov x0, #0
         (in the AMFI cert verification function identified by the
          unique constant 0x20446 loaded into w19)
    """

    def __init__(self, data, verbose=True):
        self.data    = data
        self.raw     = bytes(data)
        self.size    = len(data)
        self.verbose = verbose
        self.patches = []

    def _log(self, msg):
        if self.verbose:
            print(msg)

    def emit(self, off, patch_bytes, desc):
        self.patches.append((off, patch_bytes, desc))
        if self.verbose:
            before_insns = list(_cs.disasm(self.raw[off:off + 4], off))
            after_insns = list(_cs.disasm(patch_bytes, off))
            b_str = (f"{before_insns[0].mnemonic} {before_insns[0].op_str}"
                     if before_insns else "???")
            a_str = (f"{after_insns[0].mnemonic} {after_insns[0].op_str}"
                     if after_insns else "???")
            print(f"  0x{off:06X}: {b_str} → {a_str}  [{desc}]")

    def apply(self):
        self.find_all()
        for off, pb, _ in self.patches:
            self.data[off:off + len(pb)] = pb
        if self.verbose and self.patches:
            self._log(f"\n  [{len(self.patches)} TXM patches applied]")
        return len(self.patches)

    def find_all(self):
        self.patches = []
        self.patch_trustcache_bypass()
        return self.patches

    # ═══════════════════════════════════════════════════════════
    #  Trustcache bypass
    #
    #  The AMFI cert verification function has a unique constant:
    #    mov w19, #0x2446; movk w19, #2, lsl #16  (= 0x20446)
    #
    #  Within that function, a binary search calls a hash-compare
    #  function with SHA-1 size:
    #    mov w2, #0x14; bl <hash_cmp>; cbz w0, <match>
    #  followed by:
    #    tbnz w0, #0x1f, <lower_half>   (sign bit = search direction)
    #
    #  Patch: bl <hash_cmp> → mov x0, #0
    #    This makes cbz always branch to <match>, bypassing the
    #    trustcache lookup entirely.
    # ═══════════════════════════════════════════════════════════
    def patch_trustcache_bypass(self):
        # Step 1: Find the unique function marker (mov w19, #0x2446)
        locs = _find_asm_pattern(self.raw, "mov w19, #0x2446")
        if len(locs) != 1:
            self._log(f"  [-] TXM: expected 1 'mov w19, #0x2446', "
                       f"found {len(locs)}")
            return
        marker_off = locs[0]

        # Step 2: Find the containing function (scan back for PACIBSP)
        pacibsp = _asm("hint #27")
        func_start = None
        for scan in range(marker_off & ~3, max(0, marker_off - 0x200), -4):
            if self.raw[scan:scan + 4] == pacibsp:
                func_start = scan
                break
        if func_start is None:
            self._log("  [-] TXM: function start not found")
            return

        # Step 3: Within the function, find mov w2, #0x14; bl; cbz w0; tbnz w0, #0x1f
        func_end = min(func_start + 0x2000, self.size)
        insns = list(_cs.disasm(self.raw[func_start:func_end], func_start))

        for i, ins in enumerate(insns):
            if not (ins.mnemonic == 'mov' and ins.op_str == 'w2, #0x14'):
                continue
            if i + 3 >= len(insns):
                continue
            bl_ins = insns[i + 1]
            cbz_ins = insns[i + 2]
            tbnz_ins = insns[i + 3]
            if (bl_ins.mnemonic == 'bl'
                    and cbz_ins.mnemonic == 'cbz' and 'w0' in cbz_ins.op_str
                    and tbnz_ins.mnemonic in ('tbnz', 'tbz')
                    and '#0x1f' in tbnz_ins.op_str):
                self.emit(bl_ins.address, MOV_X0_0,
                          "trustcache bypass: bl → mov x0, #0")
                return

        self._log("  [-] TXM: binary search pattern not found in function")


# ── CLI entry point ────────────────────────────────────────────
if __name__ == "__main__":
    import sys, argparse

    parser = argparse.ArgumentParser(
        description="Dynamic TXM patcher")
    parser.add_argument("txm", help="Path to raw or IM4P TXM image")
    parser.add_argument("-q", "--quiet", action="store_true")
    args = parser.parse_args()

    print(f"Loading {args.txm}...")
    file_raw = open(args.txm, "rb").read()

    try:
        from pyimg4 import IM4P
        im4p = IM4P(file_raw)
        if im4p.payload.compression:
            im4p.payload.decompress()
        payload = im4p.payload.data
        print(f"  format: IM4P (fourcc={im4p.fourcc})")
    except Exception:
        payload = file_raw
        print(f"  format: raw")

    data = bytearray(payload)
    print(f"  size:   {len(data)} bytes ({len(data)/1024:.1f} KB)\n")

    patcher = TXMPatcher(data, verbose=not args.quiet)
    n = patcher.apply()
    print(f"\n  {n} patches applied.")

#!/usr/bin/env python3
"""
iboot_patcher.py — Dynamic patcher for iBoot-based images (iBSS, iBEC, LLB).

Finds all patch sites by string anchors, instruction patterns, and unique
error-code constants — NO hardcoded offsets.  Works across iBoot variants
as long as the code structure is preserved.

iBSS, iBEC, and LLB share the same raw binary; the difference is which
patches are applied:
  - iBSS:  serial labels + image4 callback bypass
  - iBEC:  iBSS + boot-args
  - LLB:   iBEC + rootfs bypass (6 patches) + panic bypass

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


NOP      = _asm("nop")
MOV_X0_0 = _asm("mov x0, #0")
PACIBSP  = _asm("hint #27")


def _rd32(buf, off):
    return struct.unpack_from("<I", buf, off)[0]


def _wr32(buf, off, v):
    struct.pack_into("<I", buf, off, v)


def _disasm_one(data, off):
    insns = list(_cs.disasm(data[off:off + 4], off))
    return insns[0] if insns else None


def _disasm_n(data, off, n):
    return list(_cs.disasm(data[off:off + n * 4], off))


def _find_asm_pattern(data, asm_str):
    """Find all file offsets where the assembled instruction appears."""
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


def _encode_b(pc, target):
    """Encode an unconditional `b` instruction at pc targeting target."""
    offset = (target - pc) >> 2
    return 0x14000000 | (offset & 0x3FFFFFF)


def _encode_adrp(rd, pc, target):
    imm = ((target & ~0xFFF) - (pc & ~0xFFF)) >> 12
    imm &= (1 << 21) - 1
    return 0x90000000 | ((imm & 3) << 29) | ((imm >> 2) << 5) | (rd & 0x1F)


def _encode_add_imm12(rd, rn, imm12):
    return 0x91000000 | ((imm12 & 0xFFF) << 10) | ((rn & 0x1F) << 5) | (rd & 0x1F)


# ── IBootPatcher ───────────────────────────────────────────────

class IBootPatcher:
    """Dynamic patcher for iBoot binaries (iBSS / iBEC / LLB).

    mode controls which patches are applied:
      'ibss' — serial labels + image4 callback
      'ibec' — ibss + boot-args
      'llb'  — ibec + rootfs bypass + panic bypass
    """

    BOOT_ARGS = b"serial=3 -v debug=0x2014e %s"
    CHUNK_SIZE, OVERLAP = 0x2000, 0x100

    def __init__(self, data, mode='ibss', label=None, verbose=True):
        self.data    = data            # bytearray (mutable)
        self.raw     = bytes(data)     # immutable snapshot
        self.size    = len(data)
        self.mode    = mode
        self.label   = label or f"Loaded {mode.upper()}"
        self.verbose = verbose
        self.patches = []

    def _log(self, msg):
        if self.verbose:
            print(msg)

    # ── emit / apply ───────────────────────────────────────────
    def emit(self, off, patch_bytes, desc):
        self.patches.append((off, patch_bytes, desc))
        if self.verbose:
            original = self.raw[off:off + len(patch_bytes)]
            before_insns = _disasm_n(self.raw, off, len(patch_bytes) // 4)
            after_insns = list(_cs.disasm(patch_bytes, off))
            b_str = "; ".join(f"{i.mnemonic} {i.op_str}" for i in before_insns) or "???"
            a_str = "; ".join(f"{i.mnemonic} {i.op_str}" for i in after_insns) or "???"
            print(f"  0x{off:06X}: {b_str} → {a_str}  [{desc}]")

    def emit_string(self, off, data_bytes, desc):
        """Record a string/data patch (not disassemblable)."""
        self.patches.append((off, data_bytes, desc))
        if self.verbose:
            try:
                txt = data_bytes.decode('ascii')
            except Exception:
                txt = data_bytes.hex()
            print(f"  0x{off:06X}: → {repr(txt)}  [{desc}]")

    def apply(self):
        """Find all patches, apply them, return count."""
        self.find_all()
        for off, pb, _ in self.patches:
            self.data[off:off + len(pb)] = pb

        if self.verbose and self.patches:
            self._log(f"\n  [{len(self.patches)} {self.mode.upper()} patches applied]")
        return len(self.patches)

    # ── Master find ────────────────────────────────────────────
    def find_all(self):
        self.patches = []

        self.patch_serial_labels()
        self.patch_image4_callback()

        if self.mode in ('ibec', 'llb'):
            self.patch_boot_args()

        if self.mode == 'llb':
            self.patch_rootfs_bypass()
            self.patch_panic_bypass()

        return self.patches

    # ═══════════════════════════════════════════════════════════
    #  1. Serial labels — find two long '====...' banner runs
    # ═══════════════════════════════════════════════════════════
    def patch_serial_labels(self):
        label_bytes = self.label.encode() if isinstance(self.label, str) else self.label
        eq_runs = []
        i = 0
        while i < self.size:
            if self.raw[i] == ord('='):
                start = i
                while i < self.size and self.raw[i] == ord('='):
                    i += 1
                if i - start >= 20:
                    eq_runs.append(start)
            else:
                i += 1

        if len(eq_runs) < 2:
            self._log("  [-] serial labels: <2 banner runs found")
            return

        for run_start in eq_runs[:2]:
            write_off = run_start + 1
            self.emit_string(write_off, label_bytes, f"serial label")

    # ═══════════════════════════════════════════════════════════
    #  2. image4_validate_property_callback
    #     Pattern: b.ne + mov x0, x22 (preceded by cmp within 8 insns)
    #     Patch: b.ne → NOP, mov x0, x22 → mov x0, #0
    # ═══════════════════════════════════════════════════════════
    def patch_image4_callback(self):
        candidates = []
        for insns in self._chunked_disasm():
            for i in range(len(insns) - 1):
                if insns[i].mnemonic != "b.ne":
                    continue
                if not (insns[i + 1].mnemonic == "mov"
                        and insns[i + 1].op_str == "x0, x22"):
                    continue
                addr = insns[i].address
                if not any(insns[j].mnemonic == "cmp"
                           for j in range(max(0, i - 8), i)):
                    continue
                # Prefer candidate with movn w22 (sets -1) earlier
                neg1 = any(
                    (insns[j].mnemonic == "movn"
                     and insns[j].op_str.startswith("w22,"))
                    or (insns[j].mnemonic == "mov"
                        and "w22" in insns[j].op_str
                        and ("#-1" in insns[j].op_str
                             or "#0xffffffff" in insns[j].op_str))
                    for j in range(max(0, i - 64), i)
                )
                candidates.append((addr, neg1))

        if not candidates:
            self._log("  [-] image4 callback: pattern not found")
            return

        # Prefer the candidate with the movn w22 (error return -1)
        off = None
        for a, n in candidates:
            if n:
                off = a
                break
        if off is None:
            off = candidates[-1][0]

        self.emit(off, NOP, "image4 callback: b.ne → nop")
        self.emit(off + 4, MOV_X0_0, "image4 callback: mov x0,x22 → mov x0,#0")

    # ═══════════════════════════════════════════════════════════
    #  3. Boot-args — redirect ADRP+ADD x2 to custom string
    # ═══════════════════════════════════════════════════════════
    def patch_boot_args(self, new_args=None):
        if new_args is None:
            new_args = self.BOOT_ARGS

        # Find the standalone "%s" format string near "rd=md0"
        fmt_off = self._find_boot_args_fmt()
        if fmt_off < 0:
            self._log("  [-] boot-args: format string not found")
            return

        # Find ADRP+ADD x2 referencing it
        adrp_off, add_off = self._find_boot_args_adrp(fmt_off)
        if adrp_off < 0:
            self._log("  [-] boot-args: ADRP+ADD x2 not found")
            return

        # Find a NUL slot for the new string
        new_off = self._find_string_slot(len(new_args))
        if new_off < 0:
            self._log("  [-] boot-args: no NUL slot")
            return

        self.emit_string(new_off, new_args, "boot-args string")
        new_adrp = struct.pack("<I", _encode_adrp(2, adrp_off, new_off))
        new_add = struct.pack("<I", _encode_add_imm12(2, 2, new_off & 0xFFF))
        self.emit(adrp_off, new_adrp, "boot-args: adrp x2 → new string page")
        self.emit(add_off, new_add, "boot-args: add x2 → new string offset")

    def _find_boot_args_fmt(self):
        anchor = self.raw.find(b"rd=md0")
        if anchor < 0:
            anchor = self.raw.find(b"BootArgs")
        if anchor < 0:
            return -1
        off = anchor
        while off < anchor + 0x40:
            off = self.raw.find(b"%s", off)
            if off < 0 or off >= anchor + 0x40:
                return -1
            if self.raw[off - 1] == 0 and self.raw[off + 2] == 0:
                return off
            off += 1
        return -1

    def _find_boot_args_adrp(self, fmt_off):
        for insns in self._chunked_disasm():
            for i in range(len(insns) - 1):
                a, b = insns[i], insns[i + 1]
                if a.mnemonic != "adrp" or b.mnemonic != "add":
                    continue
                if a.op_str.split(",")[0].strip() != "x2":
                    continue
                if len(a.operands) < 2 or len(b.operands) < 3:
                    continue
                if a.operands[0].reg != b.operands[1].reg:
                    continue
                if a.operands[1].imm + b.operands[2].imm == fmt_off:
                    return a.address, b.address
        return -1, -1

    def _find_string_slot(self, string_len, search_start=0x14000):
        off = search_start
        while off < self.size:
            if self.raw[off] == 0:
                run_start = off
                while off < self.size and self.raw[off] == 0:
                    off += 1
                if off - run_start >= 64:
                    write_off = (run_start + 8 + 15) & ~15
                    if write_off + string_len <= off:
                        return write_off
            else:
                off += 1
        return -1

    # ═══════════════════════════════════════════════════════════
    #  4. LLB rootfs bypass — 6 patches in two functions
    # ═══════════════════════════════════════════════════════════
    def patch_rootfs_bypass(self):
        # ── 4a: cbz w0 → unconditional b  (error code 0x3B7) ──
        self._patch_cbz_before_error(0x3B7, "rootfs: skip sig check (0x3B7)")

        # ── 4b: cmp x8, #0x400; b.hs → nop ────────────────────
        self._patch_bhs_after_cmp_0x400()

        # ── 4c: cbz w0 → unconditional b  (error code 0x3C2) ──
        self._patch_cbz_before_error(0x3C2, "rootfs: skip sig verify (0x3C2)")

        # ── 4d: cbz x8 → nop  (ldr xR, [xN, #0x78]) ──────────
        self._patch_null_check_0x78()

        # ── 4e: cbz w0 → unconditional b  (error code 0x110) ──
        self._patch_cbz_before_error(0x110, "rootfs: skip size verify (0x110)")

    def _patch_cbz_before_error(self, error_code, desc):
        """Find unique 'mov w8, #<error_code>', cbz/cbnz is 4 bytes before.
        Convert conditional branch to unconditional b to same target."""
        locs = _find_asm_pattern(self.raw, f"mov w8, #{error_code}")
        if len(locs) != 1:
            self._log(f"  [-] {desc}: expected 1 'mov w8, #{error_code:#x}', "
                       f"found {len(locs)}")
            return

        err_off = locs[0]
        cbz_off = err_off - 4
        insn = _disasm_one(self.raw, cbz_off)
        if not insn or insn.mnemonic not in ('cbz', 'cbnz'):
            self._log(f"  [-] {desc}: expected cbz/cbnz at 0x{cbz_off:X}, "
                       f"got {insn.mnemonic if insn else '???'}")
            return

        # Extract the branch target from the conditional instruction
        target = insn.operands[1].imm
        b_word = _encode_b(cbz_off, target)
        self.emit(cbz_off, struct.pack("<I", b_word), desc)

    def _patch_bhs_after_cmp_0x400(self):
        """Find unique 'cmp x8, #0x400', NOP the b.hs that follows."""
        locs = _find_asm_pattern(self.raw, "cmp x8, #0x400")
        if len(locs) != 1:
            self._log(f"  [-] rootfs b.hs: expected 1 'cmp x8, #0x400', "
                       f"found {len(locs)}")
            return

        cmp_off = locs[0]
        bhs_off = cmp_off + 4
        insn = _disasm_one(self.raw, bhs_off)
        if not insn or insn.mnemonic != 'b.hs':
            self._log(f"  [-] rootfs b.hs: expected b.hs at 0x{bhs_off:X}, "
                       f"got {insn.mnemonic if insn else '???'}")
            return

        self.emit(bhs_off, NOP, "rootfs: NOP b.hs size check (0x400)")

    def _patch_null_check_0x78(self):
        """Find 'ldr x8, [xN, #0x78]; cbz x8' preceding unique error 0x110.
        NOP the cbz."""
        locs = _find_asm_pattern(self.raw, "mov w8, #0x110")
        if len(locs) != 1:
            self._log(f"  [-] rootfs null check: expected 1 'mov w8, #0x110', "
                       f"found {len(locs)}")
            return

        err_off = locs[0]
        # Walk backwards from the error code to find ldr+cbz pattern
        for scan in range(err_off - 4, max(err_off - 0x300, 0), -4):
            i1 = _disasm_one(self.raw, scan)
            i2 = _disasm_one(self.raw, scan + 4)
            if (i1 and i2
                    and i1.mnemonic == 'ldr' and '#0x78' in i1.op_str
                    and i2.mnemonic == 'cbz' and i2.op_str.startswith('x')):
                self.emit(scan + 4, NOP,
                          "rootfs: NOP cbz x8 null check (#0x78)")
                return

        self._log("  [-] rootfs null check: ldr+cbz #0x78 pattern not found")

    # ═══════════════════════════════════════════════════════════
    #  5. LLB panic bypass
    #     Pattern: mov w8, #0x328; movk w8, #0x40, lsl #16;
    #              str wzr, ...; str wzr, ...; bl X; cbnz w0
    #     Patch: NOP the cbnz
    # ═══════════════════════════════════════════════════════════
    def patch_panic_bypass(self):
        mov328_locs = _find_asm_pattern(self.raw, "mov w8, #0x328")
        for loc in mov328_locs:
            # Verify movk w8, #0x40, lsl #16 follows
            next_insn = _disasm_one(self.raw, loc + 4)
            if not (next_insn and next_insn.mnemonic == 'movk'
                    and 'w8' in next_insn.op_str
                    and '#0x40' in next_insn.op_str
                    and 'lsl #16' in next_insn.op_str):
                continue

            # Walk forward to find bl; cbnz w0
            for step in range(loc + 8, loc + 32, 4):
                i = _disasm_one(self.raw, step)
                if i and i.mnemonic == 'bl':
                    ni = _disasm_one(self.raw, step + 4)
                    if ni and ni.mnemonic == 'cbnz':
                        self.emit(step + 4, NOP,
                                  "panic bypass: NOP cbnz w0")
                        return
                    break

        self._log("  [-] panic bypass: pattern not found")

    # ── Chunked disassembly helper ─────────────────────────────
    def _chunked_disasm(self):
        off = 0
        while off < self.size:
            end = min(off + self.CHUNK_SIZE, self.size)
            insns = list(_cs.disasm(self.raw[off:end], off))
            yield insns
            off += self.CHUNK_SIZE - self.OVERLAP


# ── CLI entry point ────────────────────────────────────────────
if __name__ == "__main__":
    import sys, argparse

    parser = argparse.ArgumentParser(
        description="Dynamic iBoot patcher (iBSS / iBEC / LLB)")
    parser.add_argument("firmware", help="Path to raw or IM4P iBoot image")
    parser.add_argument("-m", "--mode", choices=["ibss", "ibec", "llb"],
                        default="llb",
                        help="Patch mode (default: llb = all patches)")
    parser.add_argument("-l", "--label", default=None,
                        help="Serial label text (default: 'Loaded MODE')")
    parser.add_argument("-q", "--quiet", action="store_true")
    args = parser.parse_args()

    print(f"Loading {args.firmware}...")
    file_raw = open(args.firmware, "rb").read()

    # Auto-detect IM4P
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

    patcher = IBootPatcher(data, mode=args.mode, label=args.label,
                           verbose=not args.quiet)
    n = patcher.apply()
    print(f"\n  {n} patches applied.")

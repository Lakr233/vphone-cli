#!/usr/bin/env python3
"""
txm_patcher.py — Dynamic patcher for TXM (Trusted Execution Monitor) images.

Finds TXM patch sites dynamically and applies trustcache/entitlement/developer
mode bypasses. NO hardcoded offsets.

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
MOV_X0_1 = _asm("mov x0, #1")
MOV_W0_1 = _asm("mov w0, #1")
MOV_X0_X20 = _asm("mov x0, x20")
STRB_W0_X20_30 = _asm("strb w0, [x20, #0x30]")
NOP = _asm("nop")
PACIBSP = _asm("hint #27")


def _disasm_one(data, off):
    insns = list(_cs.disasm(data[off : off + 4], off))
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
    """Dev/JB dynamic patcher for TXM images.

    Patches (base trustcache bypass is in txm.py):
      1. Selector24: force PASS return (mov w0, #0xa1 + b epilogue)
      2. get-task-allow entitlement check BL → mov x0, #1
      3. Selector42|29: shellcode hook + manifest flag force
      4. debugger entitlement check BL → mov w0, #1
      5. developer-mode guard branch → nop
    """

    def __init__(self, data, verbose=True):
        self.data = data
        self.raw = bytes(data)
        self.size = len(data)
        self.verbose = verbose
        self.patches = []

    def _log(self, msg):
        if self.verbose:
            print(msg)

    def emit(self, off, patch_bytes, desc):
        self.patches.append((off, patch_bytes, desc))
        if self.verbose:
            before_insns = list(_cs.disasm(self.raw[off : off + 4], off))
            after_insns = list(_cs.disasm(patch_bytes, off))
            b_str = (
                f"{before_insns[0].mnemonic} {before_insns[0].op_str}"
                if before_insns
                else "???"
            )
            a_str = (
                f"{after_insns[0].mnemonic} {after_insns[0].op_str}"
                if after_insns
                else "???"
            )
            print(f"  0x{off:06X}: {b_str} → {a_str}  [{desc}]")

    def apply(self):
        self.find_all()
        for off, pb, _ in self.patches:
            self.data[off : off + len(pb)] = pb
        if self.verbose and self.patches:
            self._log(f"\n  [{len(self.patches)} TXM patches applied]")
        return len(self.patches)

    def find_all(self):
        self.patches = []
        self.patch_selector24_force_pass()
        self.patch_get_task_allow_force_true()
        self.patch_selector42_29_shellcode()
        self.patch_debugger_entitlement_force_true()
        self.patch_developer_mode_bypass()
        return self.patches

    # ── helpers ──────────────────────────────────────────────────
    def _asm_at(self, asm_line, addr):
        enc, _ = _ks.asm(asm_line, addr=addr)
        if not enc:
            raise RuntimeError(f"asm failed at 0x{addr:X}: {asm_line}")
        return bytes(enc)

    def _find_func_start(self, off, back=0x1000):
        start = max(0, off - back)
        for scan in range(off & ~3, start - 1, -4):
            if self.raw[scan : scan + 4] == PACIBSP:
                return scan
        return None

    def _find_refs_to_offset(self, target_off):
        refs = []
        for off in range(0, self.size - 8, 4):
            a = _disasm_one(self.raw, off)
            b = _disasm_one(self.raw, off + 4)
            if not a or not b:
                continue
            if a.mnemonic != "adrp" or b.mnemonic != "add":
                continue
            if len(a.operands) < 2 or len(b.operands) < 3:
                continue
            if a.operands[0].reg != b.operands[1].reg:
                continue
            if a.operands[1].imm + b.operands[2].imm == target_off:
                refs.append((off, off + 4))
        return refs

    def _find_string_refs(self, needle):
        if isinstance(needle, str):
            needle = needle.encode()
        refs = []
        seen = set()
        off = 0
        while True:
            s_off = self.raw.find(needle, off)
            if s_off < 0:
                break
            off = s_off + 1
            for r in self._find_refs_to_offset(s_off):
                if r[0] not in seen:
                    seen.add(r[0])
                    refs.append((s_off, r[0], r[1]))
        return refs

    def _find_debugger_gate_func_start(self):
        refs = self._find_string_refs(b"com.apple.private.cs.debugger")
        starts = set()
        for _, _, add_off in refs:
            for scan in range(add_off, min(add_off + 0x20, self.size - 8), 4):
                i = _disasm_one(self.raw, scan)
                n = _disasm_one(self.raw, scan + 4)
                p1 = _disasm_one(self.raw, scan - 4) if scan >= 4 else None
                p2 = _disasm_one(self.raw, scan - 8) if scan >= 8 else None
                if not all((i, n, p1, p2)):
                    continue
                if not (
                    i.mnemonic == "bl"
                    and n.mnemonic == "tbnz"
                    and n.op_str.startswith("w0, #0,")
                    and p1.mnemonic == "mov"
                    and p1.op_str == "x2, #0"
                    and p2.mnemonic == "mov"
                    and p2.op_str == "x0, #0"
                ):
                    continue
                fs = self._find_func_start(scan)
                if fs is not None:
                    starts.add(fs)
        if len(starts) != 1:
            return None
        return next(iter(starts))

    def _find_udf_cave(self, min_insns=6, near_off=None, max_distance=0x80000):
        need = min_insns * 4
        start = 0 if near_off is None else max(0, near_off - 0x1000)
        end = self.size if near_off is None else min(self.size, near_off + max_distance)
        best = None
        best_dist = None
        off = start
        while off < end:
            run = off
            while run < end and self.raw[run : run + 4] == b"\x00\x00\x00\x00":
                run += 4
            if run - off >= need:
                prev = _disasm_one(self.raw, off - 4) if off >= 4 else None
                if prev and prev.mnemonic in (
                    "b",
                    "b.eq",
                    "b.ne",
                    "b.lo",
                    "b.hs",
                    "cbz",
                    "cbnz",
                    "tbz",
                    "tbnz",
                ):
                    # Leave 2-word safety gap after the preceding branch.
                    padded = off + 8
                    if padded + need <= run:
                        return padded
                    return off
                if near_off is not None and _disasm_one(self.raw, off):
                    dist = abs(off - near_off)
                    if best is None or dist < best_dist:
                        best = off
                        best_dist = dist
            off = run + 4 if run > off else off + 4
        return best

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
            self._log(f"  [-] TXM: expected 1 'mov w19, #0x2446', found {len(locs)}")
            return
        marker_off = locs[0]

        # Step 2: Find the containing function (scan back for PACIBSP)
        pacibsp = _asm("hint #27")
        func_start = None
        for scan in range(marker_off & ~3, max(0, marker_off - 0x200), -4):
            if self.raw[scan : scan + 4] == pacibsp:
                func_start = scan
                break
        if func_start is None:
            self._log("  [-] TXM: function start not found")
            return

        # Step 3: Within the function, find mov w2, #0x14; bl; cbz w0; tbnz w0, #0x1f
        func_end = min(func_start + 0x2000, self.size)
        insns = list(_cs.disasm(self.raw[func_start:func_end], func_start))

        for i, ins in enumerate(insns):
            if not (ins.mnemonic == "mov" and ins.op_str == "w2, #0x14"):
                continue
            if i + 3 >= len(insns):
                continue
            bl_ins = insns[i + 1]
            cbz_ins = insns[i + 2]
            tbnz_ins = insns[i + 3]
            if (
                bl_ins.mnemonic == "bl"
                and cbz_ins.mnemonic == "cbz"
                and "w0" in cbz_ins.op_str
                and tbnz_ins.mnemonic in ("tbnz", "tbz")
                and "#0x1f" in tbnz_ins.op_str
            ):
                self.emit(
                    bl_ins.address, MOV_X0_0, "trustcache bypass: bl → mov x0, #0"
                )
                return

        self._log("  [-] TXM: binary search pattern not found in function")

    def patch_selector24_force_pass(self):
        """Force selector24 handler to return 0xA1 (PASS) immediately.

        Return code semantics (checked by caller via `tst w0, #0xff00`):
          - 0xA1     (byte 1 = 0x00) → PASS
          - 0x130A1  (byte 1 = 0x30) → FAIL
          - 0x22DA1  (byte 1 = 0x2D) → FAIL

        We insert `mov w0, #0xa1 ; b <epilogue>` right after the prologue,
        skipping all validation logic while preserving the stack frame for
        clean register restore via the existing epilogue.
        """
        for off in range(0, self.size - 4, 4):
            ins = _disasm_one(self.raw, off)
            if not (ins and ins.mnemonic == "mov" and ins.op_str == "w0, #0xa1"):
                continue

            func_start = self._find_func_start(off)
            if func_start is None:
                continue

            # Verify this is the selector24 handler by checking for the
            # characteristic pattern: LDR X1,[Xn,#0x38] / ADD X2,... / BL / LDP
            for scan in range(func_start, off, 4):
                i0 = _disasm_one(self.raw, scan)
                i1 = _disasm_one(self.raw, scan + 4)
                i2 = _disasm_one(self.raw, scan + 8)
                i3 = _disasm_one(self.raw, scan + 12)
                if not all((i0, i1, i2, i3)):
                    continue
                if not (
                    i0.mnemonic == "ldr"
                    and "x1," in i0.op_str
                    and "#0x38]" in i0.op_str
                ):
                    continue
                if not (i1.mnemonic == "add" and i1.op_str.startswith("x2,")):
                    continue
                if i2.mnemonic != "bl":
                    continue
                if i3.mnemonic != "ldp":
                    continue

                # Find prologue end: scan for `add x29, sp, #imm`
                body_start = None
                for p in range(func_start + 4, func_start + 0x30, 4):
                    pi = _disasm_one(self.raw, p)
                    if pi and pi.mnemonic == "add" and pi.op_str.startswith("x29, sp,"):
                        body_start = p + 4
                        break
                if body_start is None:
                    self._log("  [-] TXM: selector24 prologue end not found")
                    return False

                # Find epilogue: scan for retab/ret, walk back to first ldp x29
                epilogue = None
                for r in range(off, min(off + 0x200, self.size), 4):
                    ri = _disasm_one(self.raw, r)
                    if ri and ri.mnemonic in ("retab", "ret"):
                        for e in range(r - 4, max(r - 0x20, func_start), -4):
                            ei = _disasm_one(self.raw, e)
                            if ei and ei.mnemonic == "ldp" and "x29, x30" in ei.op_str:
                                epilogue = e
                                break
                        break
                if epilogue is None:
                    self._log("  [-] TXM: selector24 epilogue not found")
                    return False

                self.emit(
                    body_start,
                    _asm("mov w0, #0xa1"),
                    "selector24 bypass: mov w0, #0xa1 (PASS)",
                )
                self.emit(
                    body_start + 4,
                    self._asm_at(f"b #0x{epilogue:x}", body_start + 4),
                    "selector24 bypass: b epilogue",
                )
                return True

        self._log("  [-] TXM: selector24 handler not found")
        return False

    def patch_get_task_allow_force_true(self):
        """Force get-task-allow entitlement call to return true."""
        refs = self._find_string_refs(b"get-task-allow")
        if not refs:
            self._log("  [-] TXM: get-task-allow string refs not found")
            return False

        cands = []
        for _, _, add_off in refs:
            for scan in range(add_off, min(add_off + 0x20, self.size - 4), 4):
                i = _disasm_one(self.raw, scan)
                n = _disasm_one(self.raw, scan + 4)
                if not i or not n:
                    continue
                if (
                    i.mnemonic == "bl"
                    and n.mnemonic == "tbnz"
                    and n.op_str.startswith("w0, #0,")
                ):
                    cands.append(scan)

        if len(cands) != 1:
            self._log(
                f"  [-] TXM: expected 1 get-task-allow BL site, found {len(cands)}"
            )
            return False

        self.emit(cands[0], MOV_X0_1, "get-task-allow: bl -> mov x0,#1")
        return True

    def patch_selector42_29_shellcode(self):
        """Selector 42|29 patch via dynamic cave shellcode + branch redirect."""
        fn = self._find_debugger_gate_func_start()
        if fn is None:
            self._log("  [-] TXM: debugger-gate function not found (selector42|29)")
            return False

        stubs = []
        for off in range(4, self.size - 24, 4):
            p = _disasm_one(self.raw, off - 4)
            i0 = _disasm_one(self.raw, off)
            i1 = _disasm_one(self.raw, off + 4)
            i2 = _disasm_one(self.raw, off + 8)
            i3 = _disasm_one(self.raw, off + 12)
            i4 = _disasm_one(self.raw, off + 16)
            i5 = _disasm_one(self.raw, off + 20)
            if not all((p, i0, i1, i2, i3, i4, i5)):
                continue
            if not (p.mnemonic == "bti" and p.op_str == "j"):
                continue
            if not (i0.mnemonic == "mov" and i0.op_str == "x0, x20"):
                continue
            if not (
                i1.mnemonic == "bl" and i2.mnemonic == "mov" and i2.op_str == "x1, x21"
            ):
                continue
            if not (
                i3.mnemonic == "mov"
                and i3.op_str == "x2, x22"
                and i4.mnemonic == "bl"
                and i5.mnemonic == "b"
            ):
                continue
            if i4.operands and i4.operands[0].imm == fn:
                stubs.append(off)

        if len(stubs) != 1:
            self._log(f"  [-] TXM: selector42|29 stub expected 1, found {len(stubs)}")
            return False
        stub_off = stubs[0]

        cave = self._find_udf_cave(min_insns=6, near_off=stub_off)
        if cave is None:
            self._log("  [-] TXM: no UDF cave found for selector42|29 shellcode")
            return False

        self.emit(
            stub_off,
            self._asm_at(f"b #0x{cave:X}", stub_off),
            "selector42|29: branch to shellcode",
        )
        self.emit(cave, NOP, "selector42|29 shellcode pad: udf -> nop")
        self.emit(cave + 4, MOV_X0_1, "selector42|29 shellcode: mov x0,#1")
        self.emit(
            cave + 8, STRB_W0_X20_30, "selector42|29 shellcode: strb w0,[x20,#0x30]"
        )
        self.emit(cave + 12, MOV_X0_X20, "selector42|29 shellcode: mov x0,x20")
        self.emit(
            cave + 16,
            self._asm_at(f"b #0x{stub_off + 4:X}", cave + 16),
            "selector42|29 shellcode: branch back",
        )
        return True

    def patch_debugger_entitlement_force_true(self):
        """Force debugger entitlement call to return true."""
        refs = self._find_string_refs(b"com.apple.private.cs.debugger")
        if not refs:
            self._log("  [-] TXM: debugger refs not found")
            return False

        cands = []
        for _, _, add_off in refs:
            for scan in range(add_off, min(add_off + 0x20, self.size - 4), 4):
                i = _disasm_one(self.raw, scan)
                n = _disasm_one(self.raw, scan + 4)
                p1 = _disasm_one(self.raw, scan - 4) if scan >= 4 else None
                p2 = _disasm_one(self.raw, scan - 8) if scan >= 8 else None
                if not all((i, n, p1, p2)):
                    continue
                if (
                    i.mnemonic == "bl"
                    and n.mnemonic == "tbnz"
                    and n.op_str.startswith("w0, #0,")
                    and p1.mnemonic == "mov"
                    and p1.op_str == "x2, #0"
                    and p2.mnemonic == "mov"
                    and p2.op_str == "x0, #0"
                ):
                    cands.append(scan)

        if len(cands) != 1:
            self._log(f"  [-] TXM: expected 1 debugger BL site, found {len(cands)}")
            return False

        self.emit(cands[0], MOV_W0_1, "debugger entitlement: bl -> mov w0,#1")
        return True

    def patch_developer_mode_bypass(self):
        """Developer-mode bypass: NOP conditional guard before deny log path."""
        refs = self._find_string_refs(
            b"developer mode enabled due to system policy configuration"
        )
        if not refs:
            self._log("  [-] TXM: developer-mode string ref not found")
            return False

        cands = []
        for _, _, add_off in refs:
            for back in range(add_off - 4, max(add_off - 0x20, 0), -4):
                ins = _disasm_one(self.raw, back)
                if not ins:
                    continue
                if ins.mnemonic not in ("tbz", "tbnz", "cbz", "cbnz"):
                    continue
                if not ins.op_str.startswith("w9, #0,"):
                    continue
                cands.append(back)

        if len(cands) != 1:
            self._log(
                f"  [-] TXM: expected 1 developer mode guard, found {len(cands)}"
            )
            return False

        self.emit(cands[0], NOP, "developer mode bypass")
        return True


# ── CLI entry point ────────────────────────────────────────────
if __name__ == "__main__":
    import sys, argparse

    parser = argparse.ArgumentParser(description="Dynamic TXM patcher")
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
    print(f"  size:   {len(data)} bytes ({len(data) / 1024:.1f} KB)\n")

    patcher = TXMPatcher(data, verbose=not args.quiet)
    n = patcher.apply()
    print(f"\n  {n} patches applied.")

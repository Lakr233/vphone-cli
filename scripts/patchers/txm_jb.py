#!/usr/bin/env python3
"""
txm_jb.py — Jailbreak extension patcher for TXM images.

All patch sites are found dynamically via string xrefs + instruction pattern
matching. No fixed byte offsets.
"""

from keystone import Ks, KS_ARCH_ARM64, KS_MODE_LITTLE_ENDIAN as KS_MODE_LE

from .txm import TXMPatcher, MOV_X0_0, _asm, _disasm_one


_ks = Ks(KS_ARCH_ARM64, KS_MODE_LE)
NOP = _asm("nop")
MOV_X0_1 = _asm("mov x0, #1")
MOV_W0_1 = _asm("mov w0, #1")
MOV_X0_X20 = _asm("mov x0, x20")
STRB_W0_X20_30 = _asm("strb w0, [x20, #0x30]")
PACIBSP = _asm("hint #27")


class TXMJBPatcher(TXMPatcher):
    """JB-only TXM patcher."""

    def apply(self):
        self.find_all()
        for off, pb, _ in self.patches:
            self.data[off : off + len(pb)] = pb
        if self.verbose and self.patches:
            self._log(f"\n  [{len(self.patches)} TXM JB patches applied]")
        return len(self.patches)

    def find_all(self):
        self.patches = []
        self.patch_selector24_hash_extraction_nop()
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

    def _find_func_end(self, func_start, forward=0x1200):
        end = min(self.size, func_start + forward)
        for scan in range(func_start + 4, end, 4):
            if self.raw[scan : scan + 4] == PACIBSP:
                return scan
        return end

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

    def _ref_in_function(self, refs, func_start):
        out = []
        for s_off, adrp_off, add_off in refs:
            fs = self._find_func_start(adrp_off)
            if fs == func_start:
                out.append((s_off, adrp_off, add_off))
        return out

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
                    # Leave 2-word safety gap after the preceding branch
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

    # ── JB patches ───────────────────────────────────────────────
    def patch_selector24_hash_extraction_nop(self):
        """NOP the hash flags extraction BL and its LDR X1 arg setup.

        The CS hash validator function has a distinctive dual-BL pattern:
            LDR  X0, [Xn, #0x30]     ; blob data
            LDR  X1, [Xn, #0x38]     ; blob size        <-- NOP
            ADD  X2, SP, #...        ; output ptr
            BL   hash_flags_extract  ;                  <-- NOP
            LDP  X0, X1, [Xn, #0x30] ; reload for 2nd call
            ADD  X2, SP, #...
            BL   hash_data_lookup    ; (keep)

        Found via 'mov w0, #0xa1' anchor unique to this function.
        """
        for off in range(0, self.size - 4, 4):
            ins = _disasm_one(self.raw, off)
            if not (ins and ins.mnemonic == "mov" and ins.op_str == "w0, #0xa1"):
                continue

            func_start = self._find_func_start(off)
            if func_start is None:
                continue

            # Scan function for: LDR X1,[Xn,#0x38] / ADD X2,... / BL / LDP
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

                self.emit(scan, NOP, "selector24 CS: nop ldr x1,[xN,#0x38]")
                self.emit(scan + 8, NOP, "selector24 CS: nop bl hash_flags_extract")
                return True

        self._log("  [-] TXM JB: selector24 hash extraction site not found")
        return False

    def patch_get_task_allow_force_true(self):
        """Force get-task-allow entitlement call to return true."""
        refs = self._find_string_refs(b"get-task-allow")
        if not refs:
            self._log("  [-] TXM JB: get-task-allow string refs not found")
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
                f"  [-] TXM JB: expected 1 get-task-allow BL site, found {len(cands)}"
            )
            return False

        self.emit(cands[0], MOV_X0_1, "get-task-allow: bl -> mov x0,#1")
        return True

    def patch_selector42_29_shellcode(self):
        """Selector 42|29 patch via dynamic cave shellcode + branch redirect."""
        fn = self._find_debugger_gate_func_start()
        if fn is None:
            self._log("  [-] TXM JB: debugger-gate function not found (selector42|29)")
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
            self._log(
                f"  [-] TXM JB: selector42|29 stub expected 1, found {len(stubs)}"
            )
            return False
        stub_off = stubs[0]

        cave = self._find_udf_cave(min_insns=6, near_off=stub_off)
        if cave is None:
            self._log("  [-] TXM JB: no UDF cave found for selector42|29 shellcode")
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
            self._log("  [-] TXM JB: debugger refs not found")
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
            self._log(f"  [-] TXM JB: expected 1 debugger BL site, found {len(cands)}")
            return False

        self.emit(cands[0], MOV_W0_1, "debugger entitlement: bl -> mov w0,#1")
        return True

    def patch_developer_mode_bypass(self):
        """Developer-mode bypass: NOP conditional guard before deny log path."""
        refs = self._find_string_refs(
            b"developer mode enabled due to system policy configuration"
        )
        if not refs:
            self._log("  [-] TXM JB: developer-mode string ref not found")
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
                f"  [-] TXM JB: expected 1 developer mode guard, found {len(cands)}"
            )
            return False

        self.emit(cands[0], NOP, "developer mode bypass")
        return True

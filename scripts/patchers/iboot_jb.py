#!/usr/bin/env python3
"""
iboot_jb.py — Jailbreak extension patcher for iBoot-based images.

Currently adds iBSS-only nonce generation bypass used by fw_patch_jb.py.
"""

from keystone import Ks, KS_ARCH_ARM64, KS_MODE_LITTLE_ENDIAN as KS_MODE_LE

from capstone.arm64_const import ARM64_OP_IMM, ARM64_OP_REG, ARM64_REG_W0

from .iboot import IBootPatcher, _disasm_one


_ks = Ks(KS_ARCH_ARM64, KS_MODE_LE)


class IBootJBPatcher(IBootPatcher):
    """JB-only patcher for iBoot images."""

    def _asm_at(self, asm_line, addr):
        enc, _ = _ks.asm(asm_line, addr=addr)
        if not enc:
            raise RuntimeError(f"asm failed at 0x{addr:X}: {asm_line}")
        return bytes(enc)

    def apply(self):
        self.patches = []
        if self.mode == "ibss":
            self.patch_skip_generate_nonce()

        for off, pb, _ in self.patches:
            self.data[off:off + len(pb)] = pb

        if self.verbose and self.patches:
            self._log(f"\n  [{len(self.patches)} {self.mode.upper()} JB patches applied]")
        return len(self.patches)

    def _find_refs_to_offset(self, target_off):
        refs = []
        for insns in self._chunked_disasm():
            for i in range(len(insns) - 1):
                a, b = insns[i], insns[i + 1]
                if a.mnemonic != "adrp" or b.mnemonic != "add":
                    continue
                if len(a.operands) < 2 or len(b.operands) < 3:
                    continue
                if a.operands[0].reg != b.operands[1].reg:
                    continue
                if a.operands[1].imm + b.operands[2].imm == target_off:
                    refs.append((a.address, b.address, b.operands[0].reg))
        return refs

    def _find_string_refs(self, needle):
        if isinstance(needle, str):
            needle = needle.encode()
        seen = set()
        refs = []
        off = 0
        while True:
            s_off = self.raw.find(needle, off)
            if s_off < 0:
                break
            off = s_off + 1
            for r in self._find_refs_to_offset(s_off):
                if r[0] not in seen:
                    seen.add(r[0])
                    refs.append(r)
        return refs

    def patch_skip_generate_nonce(self):
        refs = self._find_string_refs(b"boot-nonce")
        if not refs:
            self._log("  [-] iBSS JB: no refs to 'boot-nonce'")
            return False

        for _, add_off, _ in refs:
            for scan in range(add_off, min(add_off + 0x100, self.size - 12), 4):
                i0 = _disasm_one(self.raw, scan)
                i1 = _disasm_one(self.raw, scan + 4)
                i2 = _disasm_one(self.raw, scan + 8)
                if not i0 or not i1 or not i2:
                    continue
                if i0.mnemonic not in ("tbz", "tbnz"):
                    continue
                if len(i0.operands) < 3:
                    continue
                if not (i0.operands[0].type == ARM64_OP_REG
                        and i0.operands[0].reg == ARM64_REG_W0):
                    continue
                if not (i0.operands[1].type == ARM64_OP_IMM
                        and i0.operands[1].imm == 0):
                    continue
                if i1.mnemonic != "mov" or i1.op_str != "w0, #0":
                    continue
                if i2.mnemonic != "bl":
                    continue

                target = i0.operands[2].imm
                self.emit(scan, self._asm_at(f"b #0x{target:X}", scan),
                          "JB: skip generate_nonce")
                return True

        self._log("  [-] iBSS JB: generate_nonce branch pattern not found")
        return False

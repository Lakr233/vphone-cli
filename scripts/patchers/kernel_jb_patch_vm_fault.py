"""Mixin: KernelJBPatchVmFaultMixin."""

from capstone.arm64_const import ARM64_OP_IMM, ARM64_OP_MEM, ARM64_OP_REG

from .kernel_jb_base import NOP


class KernelJBPatchVmFaultMixin:
    def patch_vm_fault_enter_prepare(self):
        """Force the upstream cs_bypass fast-path in _vm_fault_enter_prepare.

        Strict mode:
        - Resolve vm_fault_enter_prepare function via symbol/string anchor.
        - In-function only (no global fallback scan).
        - Require the unique `tbz Wflags,#3 ; mov W?,#0 ; b ...` gate where
          Wflags is loaded from `[fault_info,#0x28]` near the function prologue.

        This intentionally reproduces the upstream PCC 26.1 research-site
        semantics and avoids the old false-positive matcher that drifted onto
        the `pmap_lock_phys_page()` / `pmap_unlock_phys_page()` pair.
        """
        self._log("\n[JB] _vm_fault_enter_prepare: NOP")

        candidate_funcs = []

        foff = self._resolve_symbol("_vm_fault_enter_prepare")
        if foff >= 0:
            candidate_funcs.append(foff)

        str_off = self.find_string(b"vm_fault_enter_prepare")
        if str_off >= 0:
            refs = self.find_string_refs(str_off, *self.kern_text)
            candidate_funcs.extend(
                self.find_function_start(adrp_off)
                for adrp_off, _, _ in refs
                if self.find_function_start(adrp_off) >= 0
            )

        candidate_sites = set()
        for func_start in sorted(set(candidate_funcs)):
            func_end = self._find_func_end(func_start, 0x4000)
            result = self._find_cs_bypass_gate(func_start, func_end)
            if result is not None:
                candidate_sites.add(result)

        if len(candidate_sites) == 1:
            result = next(iter(candidate_sites))
            self.emit(result, NOP, "NOP [_vm_fault_enter_prepare]")
            return True
        if len(candidate_sites) > 1:
            self._log(
                "  [-] ambiguous vm_fault_enter_prepare candidates: "
                + ", ".join(f"0x{x:X}" for x in sorted(candidate_sites))
            )
            return False

        self._log("  [-] patch site not found")
        return False

    def _find_cs_bypass_gate(self, start, end):
        """Find the upstream-style cs_bypass gate in vm_fault_enter_prepare.

        Expected semantic shape:
          ... early in prologue: LDR Wflags, [fault_info_reg, #0x28]
          ... later:           TBZ Wflags, #3, validation_path
                              MOV Wtainted, #0
                              B   post_validation_success

        Bit #3 in the packed fault_info flags word is `cs_bypass`.
        NOPing the TBZ forces the fast-path unconditionally, matching the
        upstream PCC 26.1 research patch site.
        """
        flag_regs = set()
        prologue_end = min(end, start + 0x120)
        for off in range(start, prologue_end, 4):
            d0 = self._disas_at(off)
            if not d0:
                continue
            insn = d0[0]
            if insn.mnemonic != "ldr" or len(insn.operands) < 2:
                continue
            dst, src = insn.operands[0], insn.operands[1]
            if dst.type != ARM64_OP_REG or src.type != ARM64_OP_MEM:
                continue
            dst_name = insn.reg_name(dst.reg)
            if not dst_name.startswith("w"):
                continue
            if src.mem.base == 0 or src.mem.disp != 0x28:
                continue
            flag_regs.add(dst.reg)

        if not flag_regs:
            return None

        hits = []
        scan_start = max(start + 0x80, start)
        for off in range(scan_start, end - 0x8, 4):
            d0 = self._disas_at(off)
            if not d0:
                continue
            gate = d0[0]
            if gate.mnemonic != "tbz" or len(gate.operands) != 3:
                continue
            reg_op, bit_op, target_op = gate.operands
            if reg_op.type != ARM64_OP_REG or reg_op.reg not in flag_regs:
                continue
            if bit_op.type != ARM64_OP_IMM or bit_op.imm != 3:
                continue
            if target_op.type != ARM64_OP_IMM:
                continue

            d1 = self._disas_at(off + 4)
            d2 = self._disas_at(off + 8)
            if not d1 or not d2:
                continue
            mov_insn = d1[0]
            branch_insn = d2[0]

            if mov_insn.mnemonic != "mov" or len(mov_insn.operands) != 2:
                continue
            mov_dst, mov_src = mov_insn.operands
            if mov_dst.type != ARM64_OP_REG or mov_src.type != ARM64_OP_IMM:
                continue
            if mov_src.imm != 0:
                continue
            if not mov_insn.reg_name(mov_dst.reg).startswith("w"):
                continue

            if branch_insn.mnemonic != "b" or len(branch_insn.operands) != 1:
                continue
            if branch_insn.operands[0].type != ARM64_OP_IMM:
                continue

            hits.append(off)

        if len(hits) == 1:
            return hits[0]
        return None

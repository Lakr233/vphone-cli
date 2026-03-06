"""Mixin: KernelJBPatchSyscallmaskMixin."""

from .kernel_jb_base import asm, _rd32, struct


class KernelJBPatchSyscallmaskMixin:
    _PACIBSP_U32 = 0xD503237F
    _SYSCALLMASK_FF_BLOB_SIZE = 0x100

    def _find_syscallmask_manager_func(self):
        """Find the high-level apply manager using its error strings."""
        strings = (
            b"failed to apply unix syscall mask",
            b"failed to apply mach trap mask",
            b"failed to apply kernel MIG routine mask",
        )
        candidates = None
        for string in strings:
            str_off = self.find_string(string)
            if str_off < 0:
                return -1
            refs = self.find_string_refs(str_off, *self.sandbox_text)
            if not refs:
                refs = self.find_string_refs(str_off)
            func_starts = {
                self.find_function_start(ref[0])
                for ref in refs
                if self.find_function_start(ref[0]) >= 0
            }
            if not func_starts:
                return -1
            candidates = func_starts if candidates is None else candidates & func_starts
            if not candidates:
                return -1

        return min(candidates)

    def _extract_w1_immediate_near_call(self, func_off, call_off):
        """Best-effort lookup of the last `mov w1, #imm` before a BL."""
        scan_start = max(func_off, call_off - 0x20)
        for off in range(call_off - 4, scan_start - 4, -4):
            d = self._disas_at(off)
            if not d:
                continue
            insn = d[0]
            if insn.mnemonic != "mov":
                continue
            op = insn.op_str.replace(" ", "")
            if not op.startswith("w1,#"):
                continue
            try:
                return int(op.split("#", 1)[1], 0)
            except ValueError:
                return None
        return None

    def _find_syscallmask_apply_func(self):
        """Find the low-level syscallmask apply wrapper used three times.

        On older PCC kernels this corresponds to the stripped function patched by
        the historical upstream C22 shellcode. On newer kernels it is the wrapper
        underneath `_proc_apply_syscall_masks`.
        """
        for name in ("_syscallmask_apply_to_proc", "_proc_apply_syscall_masks"):
            sym_off = self._resolve_symbol(name)
            if sym_off >= 0:
                return sym_off

        manager_off = self._find_syscallmask_manager_func()
        if manager_off < 0:
            return -1

        func_end = self._find_func_end(manager_off, 0x300)
        target_calls = {}
        for off in range(manager_off, func_end, 4):
            target = self._is_bl(off)
            if target < 0:
                continue
            target_calls.setdefault(target, []).append(off)

        for target, calls in sorted(target_calls.items(), key=lambda item: -len(item[1])):
            if len(calls) < 3:
                continue
            whiches = {
                self._extract_w1_immediate_near_call(manager_off, call_off)
                for call_off in calls
            }
            if {0, 1, 2}.issubset(whiches):
                return target

        return -1

    def _find_last_branch_target(self, func_off):
        """Find the last BL/B target in a function."""
        func_end = self._find_func_end(func_off, 0x280)
        for off in range(func_end - 4, func_off, -4):
            target = self._is_bl(off)
            if target >= 0:
                return off, target
            val = _rd32(self.raw, off)
            if (val & 0xFC000000) == 0x14000000:
                imm26 = val & 0x3FFFFFF
                if imm26 & (1 << 25):
                    imm26 -= 1 << 26
                target = off + imm26 * 4
                if self.kern_text[0] <= target < self.kern_text[1]:
                    return off, target
        return -1, -1

    def _resolve_syscallmask_helpers(self, func_off, helper_target):
        """Resolve the mutation helper and tail setter target deterministically.

        Historical C22 calls the next function after the pre-setter helper's
        containing function. On the upstream PCC 26.1 kernel this is the
        `zalloc_ro_mut` wrapper used by the original shellcode. We derive the
        same relation structurally instead of relying on symbol fallback.
        """
        if helper_target < 0:
            return -1, -1

        helper_func = self.find_function_start(helper_target)
        if helper_func < 0:
            return -1, -1

        mutator_off = self._find_func_end(helper_func, 0x200)
        if mutator_off <= helper_target or mutator_off >= helper_func + 0x200:
            return -1, -1

        head = self._disas_at(mutator_off)
        if not head:
            return -1, -1
        if head[0].mnemonic not in ("pacibsp", "bti"):
            return -1, -1

        _, setter_off = self._find_last_branch_target(func_off)
        if setter_off < 0:
            return -1, -1
        return mutator_off, setter_off

    def _find_syscallmask_inject_bl(self, func_off):
        """Find the pre-setter helper BL that upstream C22 replaced."""
        func_end = self._find_func_end(func_off, 0x280)
        scan_end = min(func_off + 0x80, func_end)
        seen_cbz_x2 = False
        for off in range(func_off, scan_end, 4):
            d = self._disas_at(off)
            if not d:
                continue
            insn = d[0]
            op = insn.op_str.replace(" ", "")
            if insn.mnemonic == "cbz" and op.startswith("x2,"):
                seen_cbz_x2 = True
                continue
            if seen_cbz_x2 and self._is_bl(off) >= 0:
                return off
        return -1

    def _find_syscallmask_tail_branch(self, func_off):
        """Find the final tail `B` into the setter core."""
        branch_off, target = self._find_last_branch_target(func_off)
        if branch_off < 0:
            return -1, -1
        if self._is_bl(branch_off) >= 0:
            return -1, -1
        return branch_off, target

    def _build_syscallmask_cave(self, cave_off, zalloc_off, setter_off):
        """Build a C22 cave that forces the installed mask bytes to 0xFF.

        Semantics intentionally follow the historical upstream design: mutate the
        pointed-to mask buffer into an allow-all mask, then continue through the
        normal setter path.
        """
        blob_size = self._SYSCALLMASK_FF_BLOB_SIZE
        code_off = cave_off + blob_size
        code = []
        code.append(asm("cbz x2, #0x6c"))
        code.append(asm("sub sp, sp, #0x40"))
        code.append(asm("stp x19, x20, [sp, #0x10]"))
        code.append(asm("stp x21, x22, [sp, #0x20]"))
        code.append(asm("stp x29, x30, [sp, #0x30]"))
        code.append(asm("mov x19, x0"))
        code.append(asm("mov x20, x1"))
        code.append(asm("mov x21, x2"))
        code.append(asm("mov x22, x3"))
        code.append(asm("mov x8, #8"))
        code.append(asm("mov x0, x17"))
        code.append(asm("mov x1, x21"))
        code.append(asm("mov x2, #0"))

        adr_off = code_off + len(code) * 4
        blob_delta = cave_off - adr_off
        code.append(asm(f"adr x3, #{blob_delta}"))
        code.append(asm("udiv x4, x22, x8"))
        code.append(asm("msub x10, x4, x8, x22"))
        code.append(asm("cbz x10, #8"))
        code.append(asm("add x4, x4, #1"))

        bl_off = code_off + len(code) * 4
        branch_back_off = code_off + 27 * 4
        bl = self._encode_bl(bl_off, zalloc_off)
        branch_back = self._encode_b(branch_back_off, setter_off)
        if not bl or not branch_back:
            return None
        code.append(bl)
        code.append(asm("mov x0, x19"))
        code.append(asm("mov x1, x20"))
        code.append(asm("mov x2, x21"))
        code.append(asm("mov x3, x22"))
        code.append(asm("ldp x19, x20, [sp, #0x10]"))
        code.append(asm("ldp x21, x22, [sp, #0x20]"))
        code.append(asm("ldp x29, x30, [sp, #0x30]"))
        code.append(asm("add sp, sp, #0x40"))
        code.append(branch_back)

        return (b"\xFF" * blob_size) + b"".join(code), code_off, blob_size

    def patch_syscallmask_apply_to_proc(self):
        """Retargeted C22 patch based on the verified upstream semantics.

        Historical C22 does not early-return. It hijacks the low-level apply
        wrapper, rewrites the effective syscall/mach/kobj mask bytes to an
        allow-all blob via `zalloc_ro_mut`, then resumes through the normal
        setter path.
        """
        self._log("\n[JB] _syscallmask_apply_to_proc: retargeted upstream C22")

        func_off = self._find_syscallmask_apply_func()
        if func_off < 0:
            self._log("  [-] syscallmask apply wrapper not found (fail-closed)")
            return False

        call_off = self._find_syscallmask_inject_bl(func_off)
        if call_off < 0:
            self._log("  [-] helper BL site not found in syscallmask wrapper")
            return False

        branch_off, setter_off = self._find_syscallmask_tail_branch(func_off)
        if branch_off < 0 or setter_off < 0:
            self._log("  [-] setter tail branch not found in syscallmask wrapper")
            return False

        mutator_off, _ = self._resolve_syscallmask_helpers(func_off, self._is_bl(call_off))
        if mutator_off < 0:
            self._log("  [-] syscallmask mutation helper not resolved structurally")
            return False

        cave_size = self._SYSCALLMASK_FF_BLOB_SIZE + 0x80
        cave_off = self._find_code_cave(cave_size)
        if cave_off < 0:
            self._log("  [-] no executable code cave found for C22")
            return False

        cave_info = self._build_syscallmask_cave(cave_off, mutator_off, setter_off)
        if cave_info is None:
            self._log("  [-] failed to encode C22 cave branches")
            return False
        cave_bytes, code_off, blob_size = cave_info

        branch_to_cave = self._encode_b(branch_off, code_off)
        if not branch_to_cave:
            self._log("  [-] tail branch cannot reach C22 cave")
            return False

        self.emit(
            call_off,
            asm("mov x17, x0"),
            "mov x17,x0 [syscallmask C22 save RO selector]",
        )
        self.emit(
            branch_off,
            branch_to_cave,
            "b cave [syscallmask C22 mutate mask then setter]",
        )
        self.emit(
            cave_off,
            cave_bytes,
            f"syscallmask C22 cave (ff blob {blob_size:#x} + structural mutator + setter tail)",
        )
        return True

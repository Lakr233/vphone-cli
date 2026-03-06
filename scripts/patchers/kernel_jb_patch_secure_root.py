"""Mixin: KernelJBPatchSecureRootMixin."""

from .kernel_jb_base import ARM64_OP_IMM, asm


class KernelJBPatchSecureRootMixin:
    _SECURE_ROOT_MATCH_OFFSET = 0x11A

    def patch_io_secure_bsd_root(self):
        """Force the SecureRootName policy return to success.

        Historical versions of this patch matched the first BL* + CBZ/CBNZ W0
        inside the AppleARMPE secure-root dispatch function and rewrote the
        "SecureRoot" gate. That site is semantically wrong and can perturb the
        broader platform-function dispatch path.

        The correct minimal bypass is the final CSEL in the "SecureRootName"
        path that selects between success (0) and kIOReturnNotPrivileged.
        """
        self._log("\n[JB] _IOSecureBSDRoot: force SecureRootName success")

        func_candidates = self._find_secure_root_functions()
        if not func_candidates:
            self._log("  [-] secure-root dispatch function not found")
            return False

        for func_start in sorted(func_candidates):
            func_end = self._find_func_end(func_start, 0x1200)
            site = self._find_secure_root_return_site(func_start, func_end)
            if not site:
                continue

            off, reg_name = site
            patch_bytes = self._compile_zero_return_checked(reg_name)
            self.emit(
                off,
                patch_bytes,
                f"mov {reg_name}, #0 [_IOSecureBSDRoot SecureRootName allow]",
            )
            return True

        self._log("  [-] SecureRootName deny-return site not found")
        return False

    def _find_secure_root_functions(self):
        funcs_with_name = self._functions_referencing_string(b"SecureRootName")
        if not funcs_with_name:
            return set()

        funcs_with_root = self._functions_referencing_string(b"SecureRoot")
        common = funcs_with_name & funcs_with_root
        if common:
            return common
        return funcs_with_name

    def _functions_referencing_string(self, needle):
        func_starts = set()
        for str_off in self._all_cstring_offsets(needle):
            refs = self.find_string_refs(str_off, *self.kern_text)
            for adrp_off, _, _ in refs:
                fn = self.find_function_start(adrp_off)
                if fn >= 0:
                    func_starts.add(fn)
        return func_starts

    def _all_cstring_offsets(self, needle):
        if isinstance(needle, str):
            needle = needle.encode()
        out = []
        start = 0
        while True:
            pos = self.raw.find(needle, start)
            if pos < 0:
                break
            cstr = pos
            while cstr > 0 and self.raw[cstr - 1] != 0:
                cstr -= 1
            cend = self.raw.find(b"\x00", cstr)
            if cend > cstr and self.raw[cstr:cend] == needle:
                out.append(cstr)
            start = pos + 1
        return sorted(set(out))

    def _find_secure_root_return_site(self, func_start, func_end):
        for off in range(func_start, func_end - 4, 4):
            dis = self._disas_at(off)
            if not dis:
                continue
            ins = dis[0]
            if ins.mnemonic != "csel" or len(ins.operands) != 3:
                continue
            if ins.op_str.replace(" ", "").split(",")[-1] != "ne":
                continue

            dest = ins.reg_name(ins.operands[0].reg)
            zero_src = ins.reg_name(ins.operands[1].reg)
            err_src = ins.reg_name(ins.operands[2].reg)
            if zero_src not in ("wzr", "xzr"):
                continue
            if not dest.startswith("w"):
                continue
            if not self._has_secure_rootname_return_context(off, func_start, err_src):
                continue
            if not self._has_secure_rootname_compare_context(off, func_start):
                continue

            return off, dest
        return None

    def _has_secure_rootname_return_context(self, off, func_start, err_reg_name):
        saw_flag_load = False
        saw_flag_test = False
        saw_err_build = False
        lookback_start = max(func_start, off - 0x40)

        for probe in range(off - 4, lookback_start - 4, -4):
            dis = self._disas_at(probe)
            if not dis:
                continue
            ins = dis[0]
            ops = ins.op_str.replace(" ", "")

            if not saw_flag_test and ins.mnemonic == "tst" and ops.endswith("#1"):
                saw_flag_test = True
                continue

            if (
                saw_flag_test
                and not saw_flag_load
                and ins.mnemonic == "ldrb"
                and f"[x19,#0x{self._SECURE_ROOT_MATCH_OFFSET:x}]" in ops
            ):
                saw_flag_load = True
                continue

            if self._writes_register(ins, err_reg_name) and ins.mnemonic in ("mov", "movk", "sub"):
                saw_err_build = True

        return saw_flag_load and saw_flag_test and saw_err_build

    def _has_secure_rootname_compare_context(self, off, func_start):
        saw_match_store = False
        saw_cset_eq = False
        saw_cmp_w0_zero = False
        lookback_start = max(func_start, off - 0xA0)

        for probe in range(off - 4, lookback_start - 4, -4):
            dis = self._disas_at(probe)
            if not dis:
                continue
            ins = dis[0]
            ops = ins.op_str.replace(" ", "")

            if (
                not saw_match_store
                and ins.mnemonic == "strb"
                and f"[x19,#0x{self._SECURE_ROOT_MATCH_OFFSET:x}]" in ops
            ):
                saw_match_store = True
                continue

            if saw_match_store and not saw_cset_eq and ins.mnemonic == "cset" and ops.endswith(",eq"):
                saw_cset_eq = True
                continue

            if saw_match_store and saw_cset_eq and not saw_cmp_w0_zero and ins.mnemonic == "cmp":
                if ops.startswith("w0,#0"):
                    saw_cmp_w0_zero = True
                    break

        return saw_match_store and saw_cset_eq and saw_cmp_w0_zero

    def _writes_register(self, ins, reg_name):
        if not ins.operands:
            return False
        first = ins.operands[0]
        if getattr(first, "type", None) != 1:
            return False
        return ins.reg_name(first.reg) == reg_name

    def _compile_zero_return_checked(self, reg_name):
        patch_bytes = asm(f"mov {reg_name}, #0")
        insns = self._disas_n(patch_bytes, 0, 1)
        assert insns, "capstone decode failed for secure-root zero-return patch"
        ins = insns[0]
        assert ins.mnemonic == "mov", (
            f"secure-root zero-return decode mismatch: expected 'mov', got '{ins.mnemonic}'"
        )
        got_dst = ins.reg_name(ins.operands[0].reg)
        assert got_dst == reg_name, (
            f"secure-root zero-return destination mismatch: expected '{reg_name}', got '{got_dst}'"
        )
        got_imm = None
        for op in ins.operands[1:]:
            if op.type == ARM64_OP_IMM:
                got_imm = op.imm
                break
        assert got_imm == 0, (
            f"secure-root zero-return immediate mismatch: expected 0, got {got_imm}"
        )
        return patch_bytes

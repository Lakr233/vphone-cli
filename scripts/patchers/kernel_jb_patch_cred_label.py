"""Mixin: KernelJBPatchCredLabelMixin."""

from .kernel_jb_base import asm, _rd32


class KernelJBPatchCredLabelMixin:
    _RET_INSNS = (0xD65F0FFF, 0xD65F0BFF, 0xD65F03C0)
    _MOV_W0_0_U32 = int.from_bytes(asm("mov w0, #0"), "little")
    _MOV_W0_1_U32 = int.from_bytes(asm("mov w0, #1"), "little")
    _RELAX_CSMASK = 0xFFFFC0FF
    _RELAX_SETMASK = 0x0000000C

    def _is_cred_label_execve_candidate(self, func_off, anchor_refs):
        """Validate candidate function shape for _cred_label_update_execve."""
        func_end = self._find_func_end(func_off, 0x1000)
        if func_end - func_off < 0x200:
            return False, 0, func_end

        anchor_hits = sum(1 for r in anchor_refs if func_off <= r < func_end)
        if anchor_hits == 0:
            return False, 0, func_end

        has_arg9_load = False
        has_flags_load = False
        has_flags_store = False

        for off in range(func_off, func_end, 4):
            d = self._disas_at(off)
            if not d:
                continue
            i = d[0]
            op = i.op_str.replace(" ", "")
            if i.mnemonic == "ldr" and op.startswith("x26,[x29"):
                has_arg9_load = True
                break

        for off in range(func_off, func_end, 4):
            d = self._disas_at(off)
            if not d:
                continue
            i = d[0]
            op = i.op_str.replace(" ", "")
            if i.mnemonic == "ldr" and op.startswith("w") and ",[x26" in op:
                has_flags_load = True
            elif i.mnemonic == "str" and op.startswith("w") and ",[x26" in op:
                has_flags_store = True
            if has_flags_load and has_flags_store:
                break

        ok = has_arg9_load and has_flags_load and has_flags_store
        score = anchor_hits * 10 + (1 if has_arg9_load else 0) + (1 if has_flags_load else 0) + (1 if has_flags_store else 0)
        return ok, score, func_end

    def _find_cred_label_execve_func(self):
        """Locate _cred_label_update_execve by AMFI kill-path string cluster."""
        anchor_strings = (
            b"AMFI: hook..execve() killing",
            b"Attempt to execute completely unsigned code",
            b"Attempt to execute a Legacy VPN Plugin",
            b"dyld signature cannot be verified",
        )

        anchor_refs = set()
        candidates = set()
        s, e = self.amfi_text

        for anchor in anchor_strings:
            str_off = self.find_string(anchor)
            if str_off < 0:
                continue
            refs = self.find_string_refs(str_off, s, e)
            if not refs:
                refs = self.find_string_refs(str_off)
            for adrp_off, _, _ in refs:
                anchor_refs.add(adrp_off)
                func_off = self.find_function_start(adrp_off)
                if func_off >= 0 and s <= func_off < e:
                    candidates.add(func_off)

        best_func = -1
        best_score = -1
        for func_off in sorted(candidates):
            ok, score, _ = self._is_cred_label_execve_candidate(func_off, anchor_refs)
            if ok and score > best_score:
                best_score = score
                best_func = func_off

        return best_func

    def _find_cred_label_return_site(self, func_off):
        """Pick a return site with full epilogue restore (SP/frame restored)."""
        func_end = self._find_func_end(func_off, 0x1000)
        fallback = -1
        for off in range(func_end - 4, func_off, -4):
            val = _rd32(self.raw, off)
            if val not in self._RET_INSNS:
                continue
            if fallback < 0:
                fallback = off

            saw_add_sp = False
            saw_ldp_fp = False
            for prev in range(max(func_off, off - 0x24), off, 4):
                d = self._disas_at(prev)
                if not d:
                    continue
                i = d[0]
                op = i.op_str.replace(" ", "")
                if i.mnemonic == "add" and op.startswith("sp,sp,#"):
                    saw_add_sp = True
                elif i.mnemonic == "ldp" and op.startswith("x29,x30,[sp"):
                    saw_ldp_fp = True

            if saw_add_sp and saw_ldp_fp:
                return off

        return fallback

    def _find_cred_label_epilogue(self, func_off):
        """Locate the canonical epilogue start (`ldp x29, x30, [sp, ...]`)."""
        func_end = self._find_func_end(func_off, 0x1000)
        for off in range(func_end - 4, func_off, -4):
            d = self._disas_at(off)
            if not d:
                continue
            i = d[0]
            op = i.op_str.replace(" ", "")
            if i.mnemonic == "ldp" and op.startswith("x29,x30,[sp"):
                return off

        return -1

    def _find_cred_label_csflags_ptr_reload(self, func_off):
        """Recover the stack-based `u_int *csflags` reload used by the function.

        We reuse the same `ldr x26, [x29, #imm]` form in the trampoline so the
        common C21-v1 cave works for both deny and success exits, even when the
        live x26 register has not been initialized on a deny-only path.
        """
        func_end = self._find_func_end(func_off, 0x1000)
        for off in range(func_off, func_end, 4):
            d = self._disas_at(off)
            if not d:
                continue
            i = d[0]
            op = i.op_str.replace(" ", "")
            if i.mnemonic != "ldr" or not op.startswith("x26,[x29"):
                continue
            mem_op = i.op_str.split(",", 1)[1].strip()
            return off, mem_op

        return -1, None

    def _decode_b_target(self, off):
        """Return target of unconditional `b`, or -1 if instruction is not `b`."""
        insn = _rd32(self.raw, off)
        if (insn & 0x7C000000) != 0x14000000:
            return -1
        imm26 = insn & 0x03FFFFFF
        if imm26 & (1 << 25):
            imm26 -= 1 << 26
        return off + imm26 * 4

    def _find_cred_label_deny_return(self, func_off, epilogue_off):
        """Find the shared `mov w0,#1` kill-return right before the epilogue."""
        mov_w0_1 = self._MOV_W0_1_U32
        scan_start = max(func_off, epilogue_off - 0x40)
        for off in range(epilogue_off - 4, scan_start - 4, -4):
            if _rd32(self.raw, off) == mov_w0_1 and off + 4 == epilogue_off:
                return off

        return -1

    def _find_cred_label_success_exits(self, func_off, epilogue_off):
        """Find late success edges that already decided to return 0.

        On the current vphone600 AMFI body these are the final `b epilogue`
        instructions in the success tail, reached after the original
        `tst/orr/str` cleanup has already run.
        """
        exits = []
        func_end = self._find_func_end(func_off, 0x1000)
        for off in range(func_off, func_end, 4):
            target = self._decode_b_target(off)
            if target != epilogue_off:
                continue
            saw_mov_w0_0 = False
            for prev in range(max(func_off, off - 0x10), off, 4):
                if _rd32(self.raw, prev) == self._MOV_W0_0_U32:
                    saw_mov_w0_0 = True
                    break
            if saw_mov_w0_0:
                exits.append(off)

        return tuple(exits)

    def patch_cred_label_update_execve(self):
        """C21-v3: split late exits and add minimal helper bits on success.

        This version keeps the boot-safe late-exit structure from v2, but adds
        a small success-only extension inspired by the older upstream shellcode:

        - keep `_cred_label_update_execve`'s body intact;
        - redirect the shared deny return into a tiny deny cave that only
          forces `w0 = 0` and returns through the original epilogue;
        - redirect the late success exits into a success cave;
        - reload `u_int *csflags` from the stack only on the success cave;
        - clear only `CS_HARD|CS_KILL|CS_CHECK_EXPIRATION|CS_RESTRICT|
          CS_ENFORCEMENT|CS_REQUIRE_LV` on the success cave;
        - then OR only `CS_GET_TASK_ALLOW|CS_INSTALLER` (`0xC`) on the
          success cave;
        - return through the original epilogue in both cases.

        This preserves AMFI's exec-time analytics / entitlement handling and
        avoids the boot-unsafe entry-time early return used by older variants.
        """
        self._log("\n[JB] _cred_label_update_execve: C21-v3 split exits + helper bits")

        func_off = -1

        # Try symbol first, but still validate shape.
        for sym, off in self.symbols.items():
            if "cred_label_update_execve" in sym and "hook" not in sym:
                ok, _, _ = self._is_cred_label_execve_candidate(off, set([off]))
                if ok:
                    func_off = off
                break

        if func_off < 0:
            func_off = self._find_cred_label_execve_func()

        if func_off < 0:
            self._log("  [-] function not found, skipping shellcode patch")
            return False

        epilogue_off = self._find_cred_label_epilogue(func_off)
        if epilogue_off < 0:
            self._log("  [-] epilogue not found")
            return False

        deny_off = self._find_cred_label_deny_return(func_off, epilogue_off)
        if deny_off < 0:
            self._log("  [-] shared deny return not found")
            return False

        success_exits = self._find_cred_label_success_exits(func_off, epilogue_off)
        if not success_exits:
            self._log("  [-] success exits not found")
            return False

        _, csflags_mem_op = self._find_cred_label_csflags_ptr_reload(func_off)
        if not csflags_mem_op:
            self._log("  [-] csflags stack reload not found")
            return False

        deny_cave = self._find_code_cave(8)
        if deny_cave < 0:
            self._log("  [-] no code cave found for C21-v3 deny trampoline")
            return False

        success_cave = self._find_code_cave(32)
        if success_cave < 0 or success_cave == deny_cave:
            self._log("  [-] no code cave found for C21-v3 success trampoline")
            return False

        deny_branch_back = self._encode_b(deny_cave + 4, epilogue_off)
        if not deny_branch_back:
            self._log("  [-] branch from deny trampoline back to epilogue is out of range")
            return False

        success_branch_back = self._encode_b(success_cave + 28, epilogue_off)
        if not success_branch_back:
            self._log("  [-] branch from success trampoline back to epilogue is out of range")
            return False

        deny_shellcode = asm("mov w0, #0") + deny_branch_back
        success_shellcode = (
            asm(f"ldr x26, {csflags_mem_op}")
            + asm("cbz x26, #0x10")
            + asm("ldr w8, [x26]")
            + asm(f"and w8, w8, #{self._RELAX_CSMASK:#x}")
            + asm(f"orr w8, w8, #{self._RELAX_SETMASK:#x}")
            + asm("str w8, [x26]")
            + asm("mov w0, #0")
            + success_branch_back
        )

        for index in range(0, len(deny_shellcode), 4):
            self.emit(
                deny_cave + index,
                deny_shellcode[index : index + 4],
                f"deny_trampoline+{index} [_cred_label_update_execve C21-v3]",
            )

        for index in range(0, len(success_shellcode), 4):
            self.emit(
                success_cave + index,
                success_shellcode[index : index + 4],
                f"success_trampoline+{index} [_cred_label_update_execve C21-v3]",
            )

        deny_branch_to_cave = self._encode_b(deny_off, deny_cave)
        if not deny_branch_to_cave:
            self._log(f"  [-] branch from 0x{deny_off:X} to deny trampoline is out of range")
            return False
        self.emit(
            deny_off,
            deny_branch_to_cave,
            f"b deny cave [_cred_label_update_execve C21-v3 exit @ 0x{deny_off:X}]",
        )

        for off in success_exits:
            branch_to_cave = self._encode_b(off, success_cave)
            if not branch_to_cave:
                self._log(f"  [-] branch from 0x{off:X} to success trampoline is out of range")
                return False
            self.emit(
                off,
                branch_to_cave,
                f"b success cave [_cred_label_update_execve C21-v3 exit @ 0x{off:X}]",
            )

        return True

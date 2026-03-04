"""Mixin: KernelJBPatchHookCredLabelMixin."""

from .kernel_jb_base import asm, _rd32, _rd64, RET, NOP, struct

PACIBSP = bytes([0x7F, 0x23, 0x03, 0xD5])  # 0xD503237F


class KernelJBPatchHookCredLabelMixin:
    def patch_hook_cred_label_update_execve(self):
        """Inline-trampoline the sandbox cred_label_update_execve hook.

        Injects ownership-propagation shellcode by replacing the first
        instruction (PACIBSP) of the original hook with ``B cave``.
        The cave runs PACIBSP, performs vnode_getattr ownership propagation,
        then ``B hook+4`` to resume the original function.

        Previous approach (ops table pointer rewrite) broke the chained
        fixup integrity check, causing PAC failures in unrelated kexts.
        Inline trampoline avoids PAC entirely — B is PC-relative.
        """
        self._log(
            "\n[JB] _hook_cred_label_update_execve: "
            "inline trampoline + shellcode"
        )

        # ── 1. Find vnode_getattr via string anchor ──────────────
        vnode_getattr_off = self._resolve_symbol("_vnode_getattr")
        if vnode_getattr_off < 0:
            str_off = self.find_string(b"vnode_getattr")
            if str_off >= 0:
                refs = self.find_string_refs(str_off)
                if refs:
                    vnode_getattr_off = self.find_function_start(refs[0][0])
                    if vnode_getattr_off >= 0:
                        self._log(
                            f"  [+] vnode_getattr at 0x"
                            f"{vnode_getattr_off:X} (via string)"
                        )

        if vnode_getattr_off < 0:
            self._log("  [-] vnode_getattr not found")
            return False

        # ── 2. Find sandbox ops table ────────────────────────────
        ops_table = self._find_sandbox_ops_table_via_conf()
        if ops_table is None:
            self._log("  [-] sandbox ops table not found")
            return False

        # ── 3. Find hook index dynamically ───────────────────────
        # mpo_cred_label_update_execve is one of the largest sandbox
        # hooks at an early index (< 30).  Scan for it.
        hook_index = -1
        orig_hook = -1
        best_size = 0
        for idx in range(0, 30):
            entry = self._read_ops_entry(ops_table, idx)
            if entry is None or entry <= 0:
                continue
            if not any(s <= entry < e for s, e in self.code_ranges):
                continue
            fend = self._find_func_end(entry, 0x2000)
            fsize = fend - entry
            if fsize > best_size:
                best_size = fsize
                hook_index = idx
                orig_hook = entry

        if hook_index < 0 or best_size < 1000:
            self._log(
                "  [-] hook entry not found in ops table "
                f"(best: idx={hook_index}, size={best_size})"
            )
            return False

        self._log(
            f"  [+] hook at ops[{hook_index}] = 0x{orig_hook:X} "
            f"({best_size} bytes)"
        )

        # Verify first instruction is PACIBSP
        first_insn = self.raw[orig_hook : orig_hook + 4]
        if first_insn != PACIBSP:
            self._log(
                f"  [-] first insn not PACIBSP "
                f"(got 0x{_rd32(self.raw, orig_hook):08X})"
            )
            return False

        # ── 4. Find code cave ────────────────────────────────────
        cave = self._find_code_cave(200)
        if cave < 0:
            self._log("  [-] no code cave found")
            return False
        self._log(f"  [+] code cave at 0x{cave:X}")

        # ── 5. Encode branches ─────────────────────────────────
        # BL cave→vnode_getattr  (slot 18)
        vnode_bl_off = cave + 18 * 4
        vnode_bl = self._encode_bl(vnode_bl_off, vnode_getattr_off)
        if not vnode_bl:
            self._log("  [-] BL to vnode_getattr out of range")
            return False

        # B cave→hook+4  (back to STP after PACIBSP, last slot)
        b_resume_slot = 45
        b_resume_off = cave + b_resume_slot * 4
        b_resume = self._encode_b(b_resume_off, orig_hook + 4)
        if not b_resume:
            self._log("  [-] B to hook+4 out of range")
            return False

        # B hook→cave  (replaces PACIBSP at function entry)
        b_to_cave = self._encode_b(orig_hook, cave)
        if not b_to_cave:
            self._log("  [-] B to cave out of range")
            return False

        # ── 6. Build shellcode ───────────────────────────────────
        # MAC hook args: x0=old_cred, x1=new_cred, x2=proc, x3=vp
        #
        # The cave starts with PACIBSP (relocated from hook entry),
        # then performs ownership propagation, then resumes the
        # original function at hook+4 (the STP instruction).
        #
        # struct vfs_context { thread_t vc_thread; kauth_cred_t vc_ucred; }
        # Built on the stack at [sp, #0x70].
        parts = []
        parts.append(PACIBSP)                        # 0: relocated from hook
        parts.append(asm("cbz x3, #0xb0"))           # 1: if vp==NULL → slot 45
        parts.append(asm("sub sp, sp, #0x400"))      # 2
        parts.append(asm("stp x29, x30, [sp]"))      # 3
        parts.append(asm("stp x0, x1, [sp, #16]"))   # 4
        parts.append(asm("stp x2, x3, [sp, #32]"))   # 5
        parts.append(asm("stp x4, x5, [sp, #48]"))   # 6
        parts.append(asm("stp x6, x7, [sp, #64]"))   # 7
        # Construct vfs_context inline
        parts.append(asm("mrs x8, tpidr_el1"))       # 8: current_thread
        parts.append(asm("stp x8, x0, [sp, #0x70]")) # 9: {thread, cred}
        parts.append(asm("add x2, sp, #0x70"))       # 10: ctx = &vfs_ctx
        # Setup vnode_getattr(vp, &vattr, ctx)
        parts.append(asm("ldr x0, [sp, #0x28]"))     # 11: x0 = vp (saved x3)
        parts.append(asm("add x1, sp, #0x80"))       # 12: x1 = &vattr
        parts.append(asm("mov w8, #0x380"))           # 13: vattr size
        parts.append(asm("stp xzr, x8, [x1]"))       # 14: init vattr
        parts.append(asm("stp xzr, xzr, [x1, #0x10]"))  # 15: init vattr+16
        parts.append(NOP)                             # 16
        parts.append(NOP)                             # 17
        parts.append(vnode_bl)                        # 18: BL vnode_getattr
        # Check result + propagate ownership
        parts.append(asm("cbnz x0, #0x4c"))          # 19: error → slot 38
        parts.append(asm("mov w2, #0"))              # 20: changed = 0
        parts.append(asm("ldr w8, [sp, #0xCC]"))     # 21: va_mode
        parts.append(bytes([0xA8, 0x00, 0x58, 0x36]))  # 22: tbz w8,#11
        parts.append(asm("ldr w8, [sp, #0xC4]"))     # 23: va_uid
        parts.append(asm("ldr x0, [sp, #0x18]"))     # 24: new_cred
        parts.append(asm("str w8, [x0, #0x18]"))     # 25: cred->uid
        parts.append(asm("mov w2, #1"))              # 26: changed = 1
        parts.append(asm("ldr w8, [sp, #0xCC]"))     # 27: va_mode
        parts.append(bytes([0xA8, 0x00, 0x50, 0x36]))  # 28: tbz w8,#10
        parts.append(asm("mov w2, #1"))              # 29: changed = 1
        parts.append(asm("ldr w8, [sp, #0xC8]"))     # 30: va_gid
        parts.append(asm("ldr x0, [sp, #0x18]"))     # 31: new_cred
        parts.append(asm("str w8, [x0, #0x28]"))     # 32: cred->gid
        parts.append(asm("cbz w2, #0x14"))           # 33: if !changed → slot 38
        parts.append(asm("ldr x0, [sp, #0x20]"))     # 34: proc
        parts.append(asm("ldr w8, [x0, #0x454]"))    # 35: p_csflags
        parts.append(asm("orr w8, w8, #0x100"))      # 36: CS_VALID
        parts.append(asm("str w8, [x0, #0x454]"))    # 37: store
        # Restore and resume
        parts.append(asm("ldp x0, x1, [sp, #16]"))   # 38
        parts.append(asm("ldp x2, x3, [sp, #32]"))   # 39
        parts.append(asm("ldp x4, x5, [sp, #48]"))   # 40
        parts.append(asm("ldp x6, x7, [sp, #64]"))   # 41
        parts.append(asm("ldp x29, x30, [sp]"))      # 42
        parts.append(asm("add sp, sp, #0x400"))       # 43
        parts.append(NOP)                             # 44
        parts.append(b_resume)                        # 45: B hook+4

        for i, part in enumerate(parts):
            self.emit(
                cave + i * 4,
                part,
                f"shellcode+{i * 4} [_hook_cred_label_update_execve]",
            )

        # ── 7. Patch function entry ─────────────────────────────
        # Replace PACIBSP with B cave (inline trampoline).
        # No ops table modification — avoids chained fixup integrity issues.
        self.emit(
            orig_hook,
            b_to_cave,
            "B cave [_hook_cred_label_update_execve trampoline]",
        )

        return True

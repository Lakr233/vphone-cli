"""Mixin: KernelJBPatchBsdInitAuthMixin."""

from .kernel_jb_base import ARM64_OP_REG, ARM64_REG_W0, ARM64_REG_X0, NOP


class KernelJBPatchBsdInitAuthMixin:
    _ROOTVP_PANIC_NEEDLE = b"rootvp not authenticated after mounting"

    def patch_bsd_init_auth(self):
        """Bypass the real rootvp auth failure branch inside ``_bsd_init``.

        Fresh analysis on ``kernelcache.research.vphone600`` shows the boot gate is
        the in-function sequence:

            call vnode ioctl handler for ``FSIOC_KERNEL_ROOTAUTH``
            cbnz w0, panic_path
            bl imageboot_needed

        The older ``ldr/cbz/bl`` matcher was not semantically tied to ``_bsd_init``
        and could false-hit unrelated functions. We now resolve the branch using the
        panic string anchor and the surrounding local control-flow instead.
        """
        self._log("\n[JB] _bsd_init: ignore FSIOC_KERNEL_ROOTAUTH failure")

        func_start = self._resolve_symbol("_bsd_init")
        if func_start < 0:
            func_start = self._func_for_rootvp_anchor()
        if func_start is None or func_start < 0:
            self._log("  [-] _bsd_init not found")
            return False

        site = self._find_bsd_init_rootauth_site(func_start)
        if site is None:
            self._log("  [-] rootauth branch site not found")
            return False

        branch_off, state = site
        if state == "patched":
            self._log(f"  [=] rootauth branch already bypassed at 0x{branch_off:X}")
            return True

        self.emit(branch_off, NOP, "NOP cbnz (rootvp auth) [_bsd_init]")
        return True

    def _find_bsd_init_rootauth_site(self, func_start):
        panic_ref = self._rootvp_panic_ref_in_func(func_start)
        if panic_ref is None:
            return None

        adrp_off, add_off = panic_ref
        bl_panic_off = self._find_panic_call_near(add_off)
        if bl_panic_off is None:
            return None

        err_lo = bl_panic_off - 0x40
        err_hi = bl_panic_off + 4
        imageboot_needed = self._resolve_symbol("_imageboot_needed")

        candidates = []
        scan_start = max(func_start, adrp_off - 0x400)
        for off in range(scan_start, adrp_off, 4):
            state = self._match_rootauth_branch_site(off, err_lo, err_hi, imageboot_needed)
            if state is not None:
                candidates.append((off, state))

        if not candidates:
            return None

        if len(candidates) > 1:
            live = [item for item in candidates if item[1] == "live"]
            if len(live) == 1:
                return live[0]
            return None

        return candidates[0]

    def _rootvp_panic_ref_in_func(self, func_start):
        str_off = self.find_string(self._ROOTVP_PANIC_NEEDLE)
        if str_off < 0:
            return None

        refs = self.find_string_refs(str_off, *self.kern_text)
        for adrp_off, add_off, _ in refs:
            if self.find_function_start(adrp_off) == func_start:
                return adrp_off, add_off
        return None

    def _find_panic_call_near(self, add_off):
        for scan in range(add_off, min(add_off + 0x40, self.size), 4):
            if self._is_bl(scan) == self.panic_off:
                return scan
        return None

    def _match_rootauth_branch_site(self, off, err_lo, err_hi, imageboot_needed):
        insns = self._disas_at(off, 1)
        if not insns:
            return None
        insn = insns[0]

        if not self._is_call(off - 4):
            return None
        if not self._has_imageboot_call_near(off, imageboot_needed):
            return None

        if insn.mnemonic == "nop":
            return "patched"

        if insn.mnemonic != "cbnz":
            return None
        if len(insn.operands) < 2 or insn.operands[0].type != ARM64_OP_REG:
            return None
        if insn.operands[0].reg not in (ARM64_REG_W0, ARM64_REG_X0):
            return None

        target, _ = self._decode_branch_target(off)
        if target is None or not (err_lo <= target <= err_hi):
            return None

        return "live"

    def _is_call(self, off):
        if off < 0:
            return False
        insns = self._disas_at(off, 1)
        return bool(insns) and insns[0].mnemonic.startswith("bl")

    def _has_imageboot_call_near(self, off, imageboot_needed):
        for scan in range(off + 4, min(off + 0x18, self.size), 4):
            target = self._is_bl(scan)
            if target < 0:
                continue
            if imageboot_needed < 0 or target == imageboot_needed:
                return True
        return False

    def _func_for_rootvp_anchor(self):
        needle = b"rootvp not authenticated after mounting @%s:%d"
        str_off = self.find_string(needle)
        if str_off < 0:
            return None
        refs = self.find_string_refs(str_off, *self.kern_text)
        if not refs:
            return None
        fn = self.find_function_start(refs[0][0])
        return fn if fn >= 0 else None

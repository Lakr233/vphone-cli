"""Mixin: KernelJBPatchIoucmacfMixin."""


class KernelJBPatchIoucmacfMixin:
    def patch_iouc_failed_macf(self):
        """Bypass the narrow IOUC MACF deny branch after mac_iokit_check_open.

        Upstream-equivalent design goal:
        - keep the large IOUserClient open/setup path intact
        - keep entitlement/default-locking/sandbox-resolver flow intact
        - only force the post-MACF gate onto the allow path

        Local validated shape in `sub_FFFFFE000825B0C0`:
        - `BL <macf_aggregator>`
        - `CBZ W0, <allow>`
        - later `ADRL X0, "IOUC %s failed MACF in process %s\n"`

        Patch action:
        - replace that `CBZ W0, <allow>` with unconditional `B <allow>`
        """
        self._log("\n[JB] IOUC MACF gate: branch-level deny bypass")

        fail_macf_str = self.find_string(b"IOUC %s failed MACF in process %s")
        if fail_macf_str < 0:
            self._log("  [-] IOUC failed-MACF format string not found")
            return False

        refs = self.find_string_refs(fail_macf_str, *self.kern_text)
        if not refs:
            self._log("  [-] no xrefs for IOUC failed-MACF format string")
            return False

        def _has_macf_aggregator_shape(callee_off):
            callee_end = self._find_func_end(callee_off, 0x400)
            saw_slot_load = False
            saw_indirect_call = False
            for off in range(callee_off, callee_end, 4):
                d = self._disas_at(off)
                if not d:
                    continue
                ins = d[0]
                op = ins.op_str.replace(" ", "").lower()
                if ins.mnemonic == "ldr" and ",#0x9e8]" in op and op.startswith("x10,[x10"):
                    saw_slot_load = True
                if ins.mnemonic in ("blraa", "blrab", "blr") and op.startswith("x10"):
                    saw_indirect_call = True
                if saw_slot_load and saw_indirect_call:
                    return True
            return False

        for adrp_off, _, _ in refs:
            func_start = self.find_function_start(adrp_off)
            if func_start < 0:
                continue
            func_end = self._find_func_end(func_start, 0x2000)

            for off in range(max(func_start, adrp_off - 0x120), min(func_end, adrp_off + 4), 4):
                d0 = self._disas_at(off)
                d1 = self._disas_at(off + 4)
                if not d0 or not d1:
                    continue
                i0 = d0[0]
                i1 = d1[0]
                if i0.mnemonic != "bl" or i1.mnemonic != "cbz":
                    continue
                if not i1.op_str.replace(" ", "").startswith("w0,"):
                    continue

                bl_target = self._is_bl(off)
                if bl_target < 0 or not _has_macf_aggregator_shape(bl_target):
                    continue

                if len(i1.operands) < 2:
                    continue
                allow_target = getattr(i1.operands[-1], 'imm', -1)
                if not (off < allow_target < func_end):
                    continue

                fail_log_adrp = None
                for probe in range(off + 8, min(func_end, off + 0x80), 4):
                    d = self._disas_at(probe)
                    if not d:
                        continue
                    ins = d[0]
                    if ins.mnemonic == "adrp" and probe == adrp_off:
                        fail_log_adrp = probe
                        break
                if fail_log_adrp is None:
                    continue

                patch_bytes = self._encode_b(off + 4, allow_target)
                if not patch_bytes:
                    continue

                self._log(
                    f"  [+] IOUC MACF gate fn=0x{func_start:X}, bl=0x{off:X}, cbz=0x{off + 4:X}, allow=0x{allow_target:X}"
                )
                self.emit(
                    off + 4,
                    patch_bytes,
                    f"b #0x{allow_target - (off + 4):X} [IOUC MACF deny → allow]",
                )
                return True

        self._log("  [-] narrow IOUC MACF deny branch not found")
        return False

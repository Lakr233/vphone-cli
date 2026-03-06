"""Mixin: KernelJBPatchHookCredLabelMixin."""

import struct

from .kernel_asm import asm, _PACIBSP_U32, _asm_u32
from .kernel_jb_base import _rd32, _rd64


class KernelJBPatchHookCredLabelMixin:
    _HOOK_CRED_LABEL_INDEX = 18
    _C23_CAVE_WORDS = 46
    _VFS_CONTEXT_CURRENT_SHAPE = (
        _PACIBSP_U32,
        _asm_u32("stp x29, x30, [sp, #-0x10]!"),
        _asm_u32("mov x29, sp"),
        _asm_u32("mrs x0, tpidr_el1"),
        _asm_u32("ldr x1, [x0, #0x3e0]"),
    )

    def _find_vnode_getattr_via_string(self):
        """Resolve vnode_getattr from a nearby BL around its log string."""
        str_off = self.find_string(b"vnode_getattr")
        if str_off < 0:
            return -1

        refs = self.find_string_refs(str_off)
        if not refs:
            return -1

        start = str_off
        for _ in range(6):
            refs = self.find_string_refs(start)
            if refs:
                ref_off = refs[0][0]
                for scan_off in range(ref_off - 4, ref_off - 80, -4):
                    if scan_off < 0:
                        break
                    insn = _rd32(self.raw, scan_off)
                    if (insn >> 26) != 0x25:
                        continue
                    imm26 = insn & 0x3FFFFFF
                    if imm26 & (1 << 25):
                        imm26 -= 1 << 26
                    target = scan_off + imm26 * 4
                    if any(s <= target < e for s, e in self.code_ranges):
                        self._log(
                            f"  [+] vnode_getattr at 0x{target:X} "
                            f"(via BL at 0x{scan_off:X}, near string ref 0x{ref_off:X})"
                        )
                        return target
            next_off = self.find_string(b"vnode_getattr", start + 1)
            if next_off < 0:
                break
            start = next_off

        return -1

    def _find_vfs_context_current_via_shape(self):
        """Locate the concrete vfs_context_current body by its unique prologue."""
        key = ("c23_vfs_context_current", self.kern_text)
        cached = self._jb_scan_cache.get(key)
        if cached is not None:
            return cached

        ks, ke = self.kern_text
        hits = []
        pat = self._VFS_CONTEXT_CURRENT_SHAPE
        for off in range(ks, ke - len(pat) * 4, 4):
            if all(_rd32(self.raw, off + i * 4) == pat[i] for i in range(len(pat))):
                hits.append(off)

        result = hits[0] if len(hits) == 1 else -1
        if result >= 0:
            self._log(f"  [+] vfs_context_current body at 0x{result:X} (shape match)")
        else:
            self._log(f"  [-] vfs_context_current shape scan ambiguous ({len(hits)} hits)")
        self._jb_scan_cache[key] = result
        return result

    def _find_hook_cred_label_update_execve_wrapper(self):
        """Resolve the faithful upstream C23 target: sandbox ops[18] wrapper."""
        ops_table = self._find_sandbox_ops_table_via_conf()
        if ops_table is None:
            self._log("  [-] sandbox ops table not found")
            return None

        entry_off = ops_table + self._HOOK_CRED_LABEL_INDEX * 8
        if entry_off + 8 > self.size:
            self._log("  [-] hook ops entry outside file")
            return None

        entry_raw = _rd64(self.raw, entry_off)
        if entry_raw == 0:
            self._log("  [-] hook ops entry is null")
            return None
        if (entry_raw & (1 << 63)) == 0:
            self._log(
                f"  [-] hook ops entry is not auth-rebase encoded: 0x{entry_raw:016X}"
            )
            return None

        wrapper_off = self._decode_chained_ptr(entry_raw)
        if wrapper_off < 0 or not any(s <= wrapper_off < e for s, e in self.code_ranges):
            self._log(f"  [-] decoded wrapper target invalid: 0x{wrapper_off:X}")
            return None

        self._log(
            f"  [+] hook cred-label wrapper ops[{self._HOOK_CRED_LABEL_INDEX}] "
            f"entry 0x{entry_off:X} -> 0x{wrapper_off:X}"
        )
        return ops_table, entry_off, entry_raw, wrapper_off

    def _encode_auth_rebase_like(self, orig_val, target_off):
        """Retarget an auth-rebase chained pointer while preserving PAC metadata."""
        if (orig_val & (1 << 63)) == 0:
            return None
        return struct.pack("<Q", (orig_val & ~0xFFFFFFFF) | (target_off & 0xFFFFFFFF))

    def _build_upstream_c23_cave(
        self,
        cave_off,
        vfs_context_current_off,
        vnode_getattr_off,
        wrapper_off,
    ):
        code = []
        code.append(asm("nop"))
        code.append(asm("cbz x3, #0xa8"))
        code.append(asm("sub sp, sp, #0x400"))
        code.append(asm("stp x29, x30, [sp]"))
        code.append(asm("stp x0, x1, [sp, #0x10]"))
        code.append(asm("stp x2, x3, [sp, #0x20]"))
        code.append(asm("stp x4, x5, [sp, #0x30]"))
        code.append(asm("stp x6, x7, [sp, #0x40]"))
        code.append(asm("nop"))

        bl_vfs_off = cave_off + len(code) * 4
        bl_vfs = self._encode_bl(bl_vfs_off, vfs_context_current_off)
        if not bl_vfs:
            return None
        code.append(bl_vfs)

        code.append(asm("mov x2, x0"))
        code.append(asm("ldr x0, [sp, #0x28]"))
        code.append(asm("add x1, sp, #0x80"))
        code.append(asm("mov w8, #0x380"))
        code.append(asm("stp xzr, x8, [x1]"))
        code.append(asm("stp xzr, xzr, [x1, #0x10]"))
        code.append(asm("nop"))

        bl_getattr_off = cave_off + len(code) * 4
        bl_getattr = self._encode_bl(bl_getattr_off, vnode_getattr_off)
        if not bl_getattr:
            return None
        code.append(bl_getattr)

        code.append(asm("cbnz x0, #0x4c"))
        code.append(asm("mov w2, #0"))
        code.append(asm("ldr w8, [sp, #0xcc]"))
        code.append(asm("tbz w8, #0xb, #0x14"))
        code.append(asm("ldr w8, [sp, #0xc4]"))
        code.append(asm("ldr x0, [sp, #0x18]"))
        code.append(asm("str w8, [x0, #0x18]"))
        code.append(asm("mov w2, #1"))
        code.append(asm("ldr w8, [sp, #0xcc]"))
        code.append(asm("tbz w8, #0xa, #0x14"))
        code.append(asm("mov w2, #1"))
        code.append(asm("ldr w8, [sp, #0xc8]"))
        code.append(asm("ldr x0, [sp, #0x18]"))
        code.append(asm("str w8, [x0, #0x28]"))
        code.append(asm("cbz w2, #0x14"))
        code.append(asm("ldr x0, [sp, #0x20]"))
        code.append(asm("ldr w8, [x0, #0x454]"))
        code.append(asm("orr w8, w8, #0x100"))
        code.append(asm("str w8, [x0, #0x454]"))
        code.append(asm("ldp x0, x1, [sp, #0x10]"))
        code.append(asm("ldp x2, x3, [sp, #0x20]"))
        code.append(asm("ldp x4, x5, [sp, #0x30]"))
        code.append(asm("ldp x6, x7, [sp, #0x40]"))
        code.append(asm("ldp x29, x30, [sp]"))
        code.append(asm("add sp, sp, #0x400"))
        code.append(asm("nop"))

        branch_back_off = cave_off + len(code) * 4
        branch_back = self._encode_b(branch_back_off, wrapper_off)
        if not branch_back:
            return None
        code.append(branch_back)
        code.append(asm("nop"))

        if len(code) != self._C23_CAVE_WORDS:
            raise RuntimeError(
                f"C23 cave length drifted: {len(code)} insns, expected {self._C23_CAVE_WORDS}"
            )
        return b"".join(code)

    def patch_hook_cred_label_update_execve(self):
        """Faithful upstream C23: wrapper trampoline + setugid credential fixup.

        Historical upstream behavior does not short-circuit the sandbox execve
        update hook. It redirects `mac_policy_ops[18]` to a code cave that:
          - fetches vnode owner/mode via vnode_getattr(vp, vap, vfs_context_current()),
          - copies VSUID/VSGID owner values into the pending new credential,
          - sets P_SUGID when either credential field changes,
          - then branches back to the original sandbox wrapper.
        """
        self._log("\n[JB] _hook_cred_label_update_execve: faithful upstream C23")

        wrapper_info = self._find_hook_cred_label_update_execve_wrapper()
        if wrapper_info is None:
            return False
        _, entry_off, entry_raw, wrapper_off = wrapper_info

        vfs_context_current_off = self._find_vfs_context_current_via_shape()
        if vfs_context_current_off < 0:
            self._log("  [-] vfs_context_current not resolved")
            return False

        vnode_getattr_off = self._find_vnode_getattr_via_string()
        if vnode_getattr_off < 0:
            self._log("  [-] vnode_getattr not resolved")
            return False

        cave_size = self._C23_CAVE_WORDS * 4
        cave_off = self._find_code_cave(cave_size)
        if cave_off < 0:
            self._log("  [-] no executable code cave found for faithful C23")
            return False

        cave_bytes = self._build_upstream_c23_cave(
            cave_off,
            vfs_context_current_off,
            vnode_getattr_off,
            wrapper_off,
        )
        if cave_bytes is None:
            self._log("  [-] failed to encode faithful C23 branch/call relocations")
            return False

        new_entry = self._encode_auth_rebase_like(entry_raw, cave_off)
        if new_entry is None:
            self._log("  [-] failed to encode hook ops entry retarget")
            return False

        self.emit(
            entry_off,
            new_entry,
            "retarget ops[18] to faithful C23 cave [_hook_cred_label_update_execve]",
        )
        self.emit(
            cave_off,
            cave_bytes,
            "faithful upstream C23 cave (vnode getattr -> uid/gid/P_SUGID fixup -> wrapper)",
        )
        return True

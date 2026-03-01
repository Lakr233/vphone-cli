#!/usr/bin/env python3
"""
kernel_jb.py — Jailbreak extension patcher for iOS kernelcache.

Builds on kernel.py's Mach-O parsing / indexing helpers while keeping JB logic
in a separate file for clean layering.

All patches use dynamic matchers:
  - String anchors → ADRP+ADD xrefs → function scope → patch site
  - BL frequency analysis to identify stub targets
  - Pattern matching (≤3 instruction sequences)
  - No symbols or hardcoded offsets

Patches are split into:
  - Group A: Already implemented (AMFI trustcache, execve, task conversion, sandbox)
  - Group B: Simple patches (string-anchored / pattern-matched)
  - Group C: Complex shellcode patches (code cave + branch redirects)
"""

import struct
from collections import Counter

from capstone.arm64_const import (
    ARM64_OP_REG, ARM64_OP_IMM, ARM64_OP_MEM,
    ARM64_REG_X0, ARM64_REG_X1, ARM64_REG_W0, ARM64_REG_X8,
)

from .kernel import (
    KernelPatcher,
    NOP,
    MOV_X0_0,
    MOV_X0_1,
    MOV_W0_0,
    MOV_W0_1,
    CMP_W0_W0,
    CMP_X0_X0,
    RET,
    asm,
    _rd32,
    _rd64,
)


CBZ_X2_8 = asm("cbz x2, #8")
STR_X0_X2 = asm("str x0, [x2]")
CMP_XZR_XZR = asm("cmp xzr, xzr")
MOV_X8_XZR = asm("mov x8, xzr")


class KernelJBPatcher(KernelPatcher):
    """JB-only kernel patcher."""

    def __init__(self, data, verbose=True):
        super().__init__(data, verbose)
        self._build_symbol_table()

    # ── Symbol table (best-effort, may find 0 on stripped kernels) ──

    def _build_symbol_table(self):
        """Parse nlist entries from LC_SYMTAB to build symbol→foff map."""
        self.symbols = {}

        # Parse top-level LC_SYMTAB
        ncmds = struct.unpack_from("<I", self.raw, 16)[0]
        off = 32
        for _ in range(ncmds):
            if off + 8 > self.size:
                break
            cmd, cmdsize = struct.unpack_from("<II", self.raw, off)
            if cmd == 0x2:  # LC_SYMTAB
                symoff = struct.unpack_from("<I", self.raw, off + 8)[0]
                nsyms = struct.unpack_from("<I", self.raw, off + 12)[0]
                stroff = struct.unpack_from("<I", self.raw, off + 16)[0]
                self._parse_nlist(symoff, nsyms, stroff)
            off += cmdsize

        # Parse fileset entries' LC_SYMTAB
        off = 32
        for _ in range(ncmds):
            if off + 8 > self.size:
                break
            cmd, cmdsize = struct.unpack_from("<II", self.raw, off)
            if cmd == 0x80000035:  # LC_FILESET_ENTRY
                # fileoff is at off+16
                foff_entry = struct.unpack_from("<Q", self.raw, off + 16)[0]
                self._parse_fileset_symtab(foff_entry)
            off += cmdsize

        self._log(f"[*] Symbol table: {len(self.symbols)} symbols resolved")

    def _parse_fileset_symtab(self, mh_off):
        """Parse LC_SYMTAB from a fileset entry Mach-O."""
        if mh_off < 0 or mh_off + 32 > self.size:
            return
        magic = _rd32(self.raw, mh_off)
        if magic != 0xFEEDFACF:
            return
        ncmds = struct.unpack_from("<I", self.raw, mh_off + 16)[0]
        off = mh_off + 32
        for _ in range(ncmds):
            if off + 8 > self.size:
                break
            cmd, cmdsize = struct.unpack_from("<II", self.raw, off)
            if cmd == 0x2:  # LC_SYMTAB
                symoff = struct.unpack_from("<I", self.raw, off + 8)[0]
                nsyms = struct.unpack_from("<I", self.raw, off + 12)[0]
                stroff = struct.unpack_from("<I", self.raw, off + 16)[0]
                self._parse_nlist(symoff, nsyms, stroff)
            off += cmdsize

    def _parse_nlist(self, symoff, nsyms, stroff):
        """Parse nlist64 entries: add defined function symbols to self.symbols."""
        for i in range(nsyms):
            entry_off = symoff + i * 16
            if entry_off + 16 > self.size:
                break
            n_strx, n_type, n_sect, n_desc, n_value = struct.unpack_from(
                "<IBBHQ", self.raw, entry_off)
            if n_type & 0x0E != 0x0E:
                continue
            if n_value == 0:
                continue
            name_off = stroff + n_strx
            if name_off >= self.size:
                continue
            name_end = self.raw.find(b'\x00', name_off)
            if name_end < 0 or name_end - name_off > 512:
                continue
            name = self.raw[name_off:name_end].decode('ascii', errors='replace')
            foff = n_value - self.base_va
            if 0 <= foff < self.size:
                self.symbols[name] = foff

    def _resolve_symbol(self, name):
        """Look up a function symbol, return file offset or -1."""
        return self.symbols.get(name, -1)

    # ── Code cave finder ──────────────────────────────────────────

    def _find_code_cave(self, size, align=4):
        """Find a region of zeros/0xFF/UDF in executable memory for shellcode.
        Returns file offset of the cave start, or -1 if not found.
        Reads from self.data (mutable) so previously allocated caves are skipped.
        """
        needed = (size + align - 1) // align * align
        for rng_start, rng_end in self.code_ranges:
            run_start = -1
            run_len = 0
            for off in range(rng_start, rng_end, 4):
                val = _rd32(self.data, off)
                if val == 0x00000000 or val == 0xFFFFFFFF or val == 0xD4200000:
                    if run_start < 0:
                        run_start = off
                        run_len = 4
                    else:
                        run_len += 4
                    if run_len >= needed:
                        return run_start
                else:
                    run_start = -1
                    run_len = 0
        return -1

    # ── Branch encoding helpers ───────────────────────────────────

    def _encode_b(self, from_off, to_off):
        """Encode an unconditional B instruction."""
        delta = (to_off - from_off) // 4
        if delta < -(1 << 25) or delta >= (1 << 25):
            return None
        return struct.pack("<I", 0x14000000 | (delta & 0x3FFFFFF))

    def _encode_bl(self, from_off, to_off):
        """Encode a BL instruction."""
        delta = (to_off - from_off) // 4
        if delta < -(1 << 25) or delta >= (1 << 25):
            return None
        return struct.pack("<I", 0x94000000 | (delta & 0x3FFFFFF))

    # ── Function finding helpers ──────────────────────────────────

    def _find_func_end(self, func_start, max_size=0x4000):
        """Find the end of a function (next PACIBSP or limit)."""
        limit = min(func_start + max_size, self.size)
        for off in range(func_start + 4, limit, 4):
            d = self._disas_at(off)
            if d and d[0].mnemonic == "pacibsp":
                return off
        return limit

    def _find_bl_to_panic_in_range(self, start, end):
        """Find first BL to _panic in range, return offset or -1."""
        for off in range(start, end, 4):
            bl_target = self._is_bl(off)
            if bl_target == self.panic_off:
                return off
        return -1

    def _find_func_by_string(self, string, code_range=None):
        """Find a function that references a given string.
        Returns the function start (PACIBSP), or -1.
        """
        str_off = self.find_string(string)
        if str_off < 0:
            return -1
        if code_range:
            refs = self.find_string_refs(str_off, *code_range)
        else:
            refs = self.find_string_refs(str_off)
        if not refs:
            return -1
        func_start = self.find_function_start(refs[0][0])
        return func_start

    def _find_func_containing_string(self, string, code_range=None):
        """Find a function containing a string reference.
        Returns (func_start, func_end, refs) or (None, None, None).
        """
        str_off = self.find_string(string)
        if str_off < 0:
            return None, None, None
        if code_range:
            refs = self.find_string_refs(str_off, *code_range)
        else:
            refs = self.find_string_refs(str_off)
        if not refs:
            return None, None, None
        func_start = self.find_function_start(refs[0][0])
        if func_start < 0:
            return None, None, None
        func_end = self._find_func_end(func_start)
        return func_start, func_end, refs

    def _find_nosys(self):
        """Find _nosys: a tiny function that returns ENOSYS (78 = 0x4e).
        Pattern: mov w0, #0x4e; ret (or with PACIBSP wrapper).
        """
        # Search for: mov w0, #0x4e (= 0x528009C0) followed by ret (= 0xD65F03C0)
        mov_w0_4e = struct.unpack("<I", asm("mov w0, #0x4e"))[0]
        ret_val = struct.unpack("<I", RET)[0]
        for s, e in self.code_ranges:
            for off in range(s, e - 4, 4):
                v0 = _rd32(self.raw, off)
                v1 = _rd32(self.raw, off + 4)
                if v0 == mov_w0_4e and v1 == ret_val:
                    return off
                # Also check with PACIBSP prefix
                if v0 == 0xD503237F and v1 == mov_w0_4e:
                    v2 = _rd32(self.raw, off + 8)
                    if v2 == ret_val:
                        return off
        return -1

    # ══════════════════════════════════════════════════════════════
    # Patch dispatcher
    # ══════════════════════════════════════════════════════════════

    def find_all(self):
        self.patches = []

        # Group A: Existing patches
        self.patch_amfi_cdhash_in_trustcache()
        self.patch_amfi_execve_kill_path()
        self.patch_task_conversion_eval_internal()
        self.patch_sandbox_hooks_extended()

        # Group B: Simple patches (string-anchored / pattern-matched)
        self.patch_post_validation_additional()
        self.patch_proc_security_policy()
        self.patch_proc_pidinfo()
        self.patch_convert_port_to_map()
        self.patch_vm_fault_enter_prepare()
        self.patch_vm_map_protect()
        self.patch_mac_mount()
        self.patch_dounmount()
        self.patch_bsd_init_auth()
        self.patch_spawn_validate_persona()
        self.patch_task_for_pid()
        self.patch_load_dylinker()
        self.patch_shared_region_map()
        self.patch_nvram_verify_permission()
        self.patch_io_secure_bsd_root()
        self.patch_thid_should_crash()

        # Group C: Complex shellcode patches
        self.patch_cred_label_update_execve()
        self.patch_syscallmask_apply_to_proc()
        self.patch_hook_cred_label_update_execve()
        self.patch_kcall10()

        return self.patches

    def apply(self):
        patches = self.find_all()
        for off, patch_bytes, _ in patches:
            self.data[off:off + len(patch_bytes)] = patch_bytes
        return len(patches)

    # ══════════════════════════════════════════════════════════════
    # Group A: Existing patches (unchanged)
    # ══════════════════════════════════════════════════════════════

    def patch_amfi_cdhash_in_trustcache(self):
        """AMFIIsCDHashInTrustCache rewrite (semantic function matching)."""
        self._log("\n[JB] AMFIIsCDHashInTrustCache: always allow + store flag")

        def _find_after(insns, start, pred):
            for idx in range(start, len(insns)):
                if pred(insns[idx]):
                    return idx
            return -1

        hits = []
        s, e = self.amfi_text
        for off in range(s, e - 4, 4):
            d0 = self._disas_at(off)
            if not d0 or d0[0].mnemonic != "pacibsp":
                continue

            func_end = min(off + 0x200, e)
            for p in range(off + 4, func_end, 4):
                dp = self._disas_at(p)
                if dp and dp[0].mnemonic == "pacibsp":
                    func_end = p
                    break

            insns = []
            for p in range(off, func_end, 4):
                d = self._disas_at(p)
                if not d:
                    break
                insns.append(d[0])

            i1 = _find_after(insns, 0,
                             lambda x: x.mnemonic == "mov" and x.op_str == "x19, x2")
            if i1 < 0:
                continue
            i2 = _find_after(insns, i1 + 1,
                             lambda x: x.mnemonic == "stp"
                             and x.op_str.startswith("xzr, xzr, [sp"))
            if i2 < 0:
                continue
            i3 = _find_after(insns, i2 + 1,
                             lambda x: x.mnemonic == "mov" and x.op_str == "x2, sp")
            if i3 < 0:
                continue
            i4 = _find_after(insns, i3 + 1, lambda x: x.mnemonic == "bl")
            if i4 < 0:
                continue
            i5 = _find_after(insns, i4 + 1,
                             lambda x: x.mnemonic == "mov" and x.op_str == "x20, x0")
            if i5 < 0:
                continue
            i6 = _find_after(insns, i5 + 1,
                             lambda x: x.mnemonic == "cbnz" and x.op_str.startswith("w0,"))
            if i6 < 0:
                continue
            i7 = _find_after(insns, i6 + 1,
                             lambda x: x.mnemonic == "cbz" and x.op_str.startswith("x19,"))
            if i7 < 0:
                continue

            hits.append(off)

        if len(hits) != 1:
            self._log(f"  [-] expected 1 AMFI trustcache body hit, found {len(hits)}")
            return False

        func_start = hits[0]
        self.emit(func_start, MOV_X0_1,
                  "mov x0,#1 [AMFIIsCDHashInTrustCache]")
        self.emit(func_start + 4, CBZ_X2_8,
                  "cbz x2,+8 [AMFIIsCDHashInTrustCache]")
        self.emit(func_start + 8, STR_X0_X2,
                  "str x0,[x2] [AMFIIsCDHashInTrustCache]")
        self.emit(func_start + 12, RET,
                  "ret [AMFIIsCDHashInTrustCache]")
        return True

    def patch_amfi_execve_kill_path(self):
        """Bypass AMFI execve kill helpers (string xref -> function local pair)."""
        self._log("\n[JB] AMFI execve kill path: BL -> mov x0,#0 (2 sites)")

        str_off = self.find_string(b"AMFI: hook..execve() killing")
        if str_off < 0:
            str_off = self.find_string(b"execve() killing")
        if str_off < 0:
            self._log("  [-] execve kill log string not found")
            return False

        refs = self.find_string_refs(str_off, *self.kern_text)
        if not refs:
            refs = self.find_string_refs(str_off)
        if not refs:
            self._log("  [-] no refs to execve kill log string")
            return False

        patched = False
        seen_funcs = set()
        for adrp_off, _, _ in refs:
            func_start = self.find_function_start(adrp_off)
            if func_start < 0 or func_start in seen_funcs:
                continue
            seen_funcs.add(func_start)

            func_end = min(func_start + 0x800, self.kern_text[1])
            for p in range(func_start + 4, func_end, 4):
                d = self._disas_at(p)
                if d and d[0].mnemonic == "pacibsp":
                    func_end = p
                    break

            early_window_end = min(func_start + 0x120, func_end)
            hits = []
            for off in range(func_start, early_window_end - 4, 4):
                d0 = self._disas_at(off)
                d1 = self._disas_at(off + 4)
                if not d0 or not d1:
                    continue
                i0, i1 = d0[0], d1[0]
                if i0.mnemonic != "bl":
                    continue
                if i1.mnemonic in ("cbz", "cbnz") and i1.op_str.startswith("w0,"):
                    hits.append(off)

            if len(hits) != 2:
                self._log(f"  [-] execve helper at 0x{func_start:X}: "
                          f"expected 2 early BL+W0-branch sites, found {len(hits)}")
                continue

            self.emit(hits[0], MOV_X0_0, "mov x0,#0 [AMFI execve helper A]")
            self.emit(hits[1], MOV_X0_0, "mov x0,#0 [AMFI execve helper B]")
            patched = True
            break

        if not patched:
            self._log("  [-] AMFI execve helper patch sites not found")
        return patched

    def patch_task_conversion_eval_internal(self):
        """Allow task conversion: cmp Xn,x0 -> cmp xzr,xzr at unique guard site."""
        self._log("\n[JB] task_conversion_eval_internal: cmp xzr,xzr")

        candidates = []
        ks, ke = self.kern_text
        for off in range(ks + 4, ke - 12, 4):
            d0 = self._disas_at(off)
            if not d0:
                continue
            i0 = d0[0]
            if i0.mnemonic != "cmp" or len(i0.operands) < 2:
                continue
            a0, a1 = i0.operands[0], i0.operands[1]
            if not (a0.type == ARM64_OP_REG and a1.type == ARM64_OP_REG):
                continue
            if a1.reg != ARM64_REG_X0:
                continue
            cmp_reg = a0.reg

            dp = self._disas_at(off - 4)
            d1 = self._disas_at(off + 4)
            d2 = self._disas_at(off + 8)
            d3 = self._disas_at(off + 12)
            if not dp or not d1 or not d2 or not d3:
                continue
            p = dp[0]
            i1, i2, i3 = d1[0], d2[0], d3[0]

            if p.mnemonic != "ldr" or len(p.operands) < 2:
                continue
            p0, p1 = p.operands[0], p.operands[1]
            if p0.type != ARM64_OP_REG or p0.reg != cmp_reg:
                continue
            if p1.type != ARM64_OP_MEM:
                continue
            if p1.mem.base != cmp_reg:
                continue

            if i1.mnemonic != "b.eq":
                continue
            if i2.mnemonic != "cmp" or len(i2.operands) < 2:
                continue
            j0, j1 = i2.operands[0], i2.operands[1]
            if not (j0.type == ARM64_OP_REG and j1.type == ARM64_OP_REG):
                continue
            if not (j0.reg == cmp_reg and j1.reg == ARM64_REG_X1):
                continue
            if i3.mnemonic != "b.eq":
                continue

            candidates.append(off)

        if len(candidates) != 1:
            self._log(f"  [-] expected 1 task-conversion guard site, found {len(candidates)}")
            return False

        self.emit(candidates[0], CMP_XZR_XZR,
                  "cmp xzr,xzr [_task_conversion_eval_internal]")
        return True

    def patch_sandbox_hooks_extended(self):
        """Stub remaining sandbox MACF hooks (JB extension beyond base 5 hooks)."""
        self._log("\n[JB] Sandbox extended hooks: mov x0,#0; ret")

        ops_table = self._find_sandbox_ops_table_via_conf()
        if ops_table is None:
            return False

        HOOK_INDICES_EXT = {
            "vnode_check_getattr": 245,
            "proc_check_get_cs_info": 249,
            "proc_check_set_cs_info": 250,
            "proc_check_set_cs_info2": 252,
            "vnode_check_chroot": 254,
            "vnode_check_create": 255,
            "vnode_check_deleteextattr": 256,
            "vnode_check_exchangedata": 257,
            "vnode_check_exec": 258,
            "vnode_check_getattrlist": 259,
            "vnode_check_getextattr": 260,
            "vnode_check_ioctl": 261,
            "vnode_check_link": 264,
            "vnode_check_listextattr": 265,
            "vnode_check_open": 267,
            "vnode_check_readlink": 270,
            "vnode_check_setattrlist": 275,
            "vnode_check_setextattr": 276,
            "vnode_check_setflags": 277,
            "vnode_check_setmode": 278,
            "vnode_check_setowner": 279,
            "vnode_check_setutimes": 280,
            "vnode_check_stat": 281,
            "vnode_check_truncate": 282,
            "vnode_check_unlink": 283,
            "vnode_check_fsgetpath": 316,
        }

        sb_start, sb_end = self.sandbox_text
        patched = 0
        seen = set()

        for hook_name, idx in HOOK_INDICES_EXT.items():
            func_off = self._read_ops_entry(ops_table, idx)
            if func_off is None or func_off <= 0:
                continue
            if not (sb_start <= func_off < sb_end):
                continue
            if func_off in seen:
                continue
            seen.add(func_off)

            self.emit(func_off, MOV_X0_0, f"mov x0,#0 [_hook_{hook_name}]")
            self.emit(func_off + 4, RET, f"ret [_hook_{hook_name}]")
            patched += 1

        if patched == 0:
            self._log("  [-] no extended sandbox hooks patched")
            return False
        return True

    # ══════════════════════════════════════════════════════════════
    # Group B: Simple patches
    # ══════════════════════════════════════════════════════════════

    def patch_post_validation_additional(self):
        """Additional postValidation CMP W0,W0 in AMFI code signing path."""
        self._log("\n[JB] postValidation additional: cmp w0,w0")

        str_off = self.find_string(b"AMFI: code signature validation failed")
        if str_off < 0:
            self._log("  [-] string not found")
            return False

        refs = self.find_string_refs(str_off, *self.amfi_text)
        if not refs:
            refs = self.find_string_refs(str_off)
        if not refs:
            self._log("  [-] no code refs")
            return False

        caller_start = self.find_function_start(refs[0][0])
        if caller_start < 0:
            return False

        bl_targets = set()
        func_end = self._find_func_end(caller_start, 0x2000)
        for scan in range(caller_start, func_end, 4):
            target = self._is_bl(scan)
            if target >= 0:
                bl_targets.add(target)

        patched = 0
        for target in sorted(bl_targets):
            if not (self.amfi_text[0] <= target < self.amfi_text[1]):
                continue
            callee_end = self._find_func_end(target, 0x200)
            for off in range(target, callee_end, 4):
                d = self._disas_at(off, 2)
                if len(d) < 2:
                    continue
                i0, i1 = d[0], d[1]
                if i0.mnemonic != "cmp" or i1.mnemonic != "b.ne":
                    continue
                ops = i0.operands
                if len(ops) < 2:
                    continue
                if ops[0].type != ARM64_OP_REG or ops[0].reg != ARM64_REG_W0:
                    continue
                if ops[1].type != ARM64_OP_IMM:
                    continue
                has_bl = False
                for back in range(off - 4, max(off - 12, target), -4):
                    bt = self._is_bl(back)
                    if bt >= 0:
                        has_bl = True
                        break
                if has_bl:
                    self.emit(off, CMP_W0_W0,
                              f"cmp w0,w0 [postValidation additional]")
                    patched += 1

        if patched == 0:
            self._log("  [-] no additional postValidation CMP sites found")
            return False
        return True

    def patch_proc_security_policy(self):
        """Stub _proc_security_policy: mov x0,#0; ret.

        Anchor: find _proc_info via its distinctive switch-table pattern
        (sub wN,wM,#1; cmp wN,#0x21), then identify the most-called BL
        target within that function — that's _proc_security_policy.
        """
        self._log("\n[JB] _proc_security_policy: mov x0,#0; ret")

        # Try symbol first
        foff = self._resolve_symbol("_proc_security_policy")
        if foff >= 0:
            self.emit(foff, MOV_X0_0, "mov x0,#0 [_proc_security_policy]")
            self.emit(foff + 4, RET, "ret [_proc_security_policy]")
            return True

        # Find _proc_info by its distinctive switch table
        # Pattern: sub wN, wM, #1; cmp wN, #0x21 (33 = max proc_info callnum)
        proc_info_func = -1
        ks, ke = self.kern_text
        for off in range(ks, ke - 8, 4):
            d = self._disas_at(off, 2)
            if len(d) < 2:
                continue
            i0, i1 = d[0], d[1]
            if i0.mnemonic != "sub" or i1.mnemonic != "cmp":
                continue
            # sub wN, wM, #1
            if len(i0.operands) < 3:
                continue
            if i0.operands[2].type != ARM64_OP_IMM or i0.operands[2].imm != 1:
                continue
            # cmp wN, #0x21
            if len(i1.operands) < 2:
                continue
            if i1.operands[1].type != ARM64_OP_IMM or i1.operands[1].imm != 0x21:
                continue
            # Verify same register
            if i0.operands[0].reg != i1.operands[0].reg:
                continue
            # Found it — find function start
            proc_info_func = self.find_function_start(off)
            break

        if proc_info_func < 0:
            self._log("  [-] _proc_info function not found")
            return False

        proc_info_end = self._find_func_end(proc_info_func, 0x4000)
        self._log(f"  [+] _proc_info at 0x{proc_info_func:X} (size 0x{proc_info_end - proc_info_func:X})")

        # Count BL targets within _proc_info — the most frequent one
        # is _proc_security_policy (called once per switch case)
        bl_targets = Counter()
        for off in range(proc_info_func, proc_info_end, 4):
            target = self._is_bl(off)
            if target >= 0 and ks <= target < ke:
                bl_targets[target] += 1

        if not bl_targets:
            self._log("  [-] no BL targets found in _proc_info")
            return False

        # The security policy check is called the most (once per case)
        most_called = bl_targets.most_common(1)[0]
        foff = most_called[0]
        count = most_called[1]
        self._log(f"  [+] most-called BL target: 0x{foff:X} ({count} calls)")

        if count < 3:
            self._log("  [-] most-called target has too few calls")
            return False

        self.emit(foff, MOV_X0_0, "mov x0,#0 [_proc_security_policy]")
        self.emit(foff + 4, RET, "ret [_proc_security_policy]")
        return True

    def patch_proc_pidinfo(self):
        """Bypass pid-0 checks in _proc_info: NOP first 2 CBZ/CBNZ on w-regs.

        Anchor: find _proc_info via its switch-table pattern, then NOP the
        first two CBZ/CBNZ instructions that guard against pid 0.
        """
        self._log("\n[JB] _proc_pidinfo: NOP pid-0 guard (2 sites)")

        # Try symbol first
        foff = self._resolve_symbol("_proc_pidinfo")
        if foff >= 0:
            func_end = min(foff + 0x80, self.size)
            hits = []
            for off in range(foff, func_end, 4):
                d = self._disas_at(off)
                if d and d[0].mnemonic in ("cbz", "cbnz") and d[0].op_str.startswith("w"):
                    hits.append(off)
            if len(hits) >= 2:
                self.emit(hits[0], NOP, "NOP [_proc_pidinfo pid-0 guard A]")
                self.emit(hits[1], NOP, "NOP [_proc_pidinfo pid-0 guard B]")
                return True

        # Find _proc_info by switch table pattern (same as proc_security_policy)
        proc_info_func = -1
        ks, ke = self.kern_text
        for off in range(ks, ke - 8, 4):
            d = self._disas_at(off, 2)
            if len(d) < 2:
                continue
            i0, i1 = d[0], d[1]
            if i0.mnemonic != "sub" or i1.mnemonic != "cmp":
                continue
            if len(i0.operands) < 3:
                continue
            if i0.operands[2].type != ARM64_OP_IMM or i0.operands[2].imm != 1:
                continue
            if len(i1.operands) < 2:
                continue
            if i1.operands[1].type != ARM64_OP_IMM or i1.operands[1].imm != 0x21:
                continue
            if i0.operands[0].reg != i1.operands[0].reg:
                continue
            proc_info_func = self.find_function_start(off)
            break

        if proc_info_func < 0:
            self._log("  [-] _proc_info function not found")
            return False

        # Find first CBZ x0 (null proc check) and the CBZ/CBNZ wN after
        # the first BL in the prologue region
        hits = []
        prologue_end = min(proc_info_func + 0x80, self.size)
        for off in range(proc_info_func, prologue_end, 4):
            d = self._disas_at(off)
            if not d:
                continue
            i = d[0]
            if i.mnemonic in ("cbz", "cbnz"):
                # CBZ x0 (null check) or CBZ wN (pid-0 check)
                hits.append(off)

        if len(hits) < 2:
            self._log(f"  [-] expected 2+ early CBZ/CBNZ, found {len(hits)}")
            return False

        self.emit(hits[0], NOP, "NOP [_proc_pidinfo pid-0 guard A]")
        self.emit(hits[1], NOP, "NOP [_proc_pidinfo pid-0 guard B]")
        return True

    def patch_convert_port_to_map(self):
        """Skip panic in _convert_port_to_map_with_flavor.
        Anchor: 'userspace has control access to a kernel map' panic string.
        """
        self._log("\n[JB] _convert_port_to_map_with_flavor: skip panic")

        str_off = self.find_string(b"userspace has control access to a kernel map")
        if str_off < 0:
            self._log("  [-] panic string not found")
            return False

        refs = self.find_string_refs(str_off, *self.kern_text)
        if not refs:
            self._log("  [-] no code refs")
            return False

        for adrp_off, add_off, _ in refs:
            bl_panic = self._find_bl_to_panic_in_range(add_off, min(add_off + 0x40, self.size))
            if bl_panic < 0:
                continue
            resume_off = bl_panic + 4
            err_lo = adrp_off - 0x40
            for back in range(adrp_off - 4, max(adrp_off - 0x200, 0), -4):
                target, kind = self._decode_branch_target(back)
                if target is not None and err_lo <= target <= bl_panic + 4:
                    b_bytes = self._encode_b(back, resume_off)
                    if b_bytes:
                        self.emit(back, b_bytes,
                                  f"b #0x{resume_off - back:X} "
                                  f"[_convert_port_to_map skip panic]")
                        return True

        self._log("  [-] branch site not found")
        return False

    def patch_vm_fault_enter_prepare(self):
        """NOP a PMAP check in _vm_fault_enter_prepare.
        Find BL to a rarely-called function followed within 4 instructions
        by TBZ/TBNZ on w0.
        """
        self._log("\n[JB] _vm_fault_enter_prepare: NOP")

        # Try symbol first
        foff = self._resolve_symbol("_vm_fault_enter_prepare")
        if foff >= 0:
            func_end = self._find_func_end(foff, 0x2000)
            result = self._find_bl_tbz_pmap(foff + 0x100, func_end)
            if result:
                self.emit(result, NOP, "NOP [_vm_fault_enter_prepare]")
                return True

        # String anchor: all refs to "vm_fault_enter_prepare"
        str_off = self.find_string(b"vm_fault_enter_prepare")
        if str_off >= 0:
            refs = self.find_string_refs(str_off)
            for adrp_off, _, _ in refs:
                func_start = self.find_function_start(adrp_off)
                if func_start < 0:
                    continue
                func_end = self._find_func_end(func_start, 0x4000)
                result = self._find_bl_tbz_pmap(func_start + 0x100, func_end)
                if result:
                    self.emit(result, NOP, "NOP [_vm_fault_enter_prepare]")
                    return True

        # Broader: scan all kern_text for BL to rarely-called func + TBZ w0
        # in a large function (>0x2000 bytes)
        ks, ke = self.kern_text
        for off in range(ks, ke - 16, 4):
            result = self._find_bl_tbz_pmap(off, min(off + 16, ke))
            if result:
                # Verify it's in a large function
                func_start = self.find_function_start(result)
                if func_start >= 0:
                    func_end = self._find_func_end(func_start, 0x4000)
                    if func_end - func_start > 0x2000:
                        self.emit(result, NOP, "NOP [_vm_fault_enter_prepare]")
                        return True

        self._log("  [-] patch site not found")
        return False

    def _find_bl_tbz_pmap(self, start, end):
        """Find BL to a rarely-called function followed within 4 insns by TBZ/TBNZ w0.
        Returns the BL offset, or None."""
        for off in range(start, end - 4, 4):
            d0 = self._disas_at(off)
            if not d0 or d0[0].mnemonic != "bl":
                continue
            bl_target = d0[0].operands[0].imm
            n_callers = len(self.bl_callers.get(bl_target, []))
            if n_callers >= 20:
                continue
            # Check next 4 instructions for TBZ/TBNZ on w0
            for delta in range(1, 5):
                d1 = self._disas_at(off + delta * 4)
                if not d1:
                    break
                i1 = d1[0]
                if i1.mnemonic in ("tbnz", "tbz") and len(i1.operands) >= 2:
                    if i1.operands[0].type == ARM64_OP_REG and \
                            i1.operands[0].reg == ARM64_REG_W0:
                        return off
        return None

    def patch_vm_map_protect(self):
        """Skip a check in _vm_map_protect: branch over guard.
        Anchor: 'vm_map_protect(' panic string → function → TBNZ with high bit.
        """
        self._log("\n[JB] _vm_map_protect: skip check")

        # Try symbol first
        foff = self._resolve_symbol("_vm_map_protect")
        if foff < 0:
            # String anchor
            foff = self._find_func_by_string(b"vm_map_protect(", self.kern_text)
        if foff < 0:
            foff = self._find_func_by_string(b"vm_map_protect(")
        if foff < 0:
            self._log("  [-] function not found")
            return False

        func_end = self._find_func_end(foff, 0x2000)

        # Find TBNZ with bit >= 24 that branches forward (permission check guard)
        for off in range(foff, func_end - 4, 4):
            d = self._disas_at(off)
            if not d:
                continue
            i = d[0]
            if i.mnemonic != "tbnz":
                continue
            if len(i.operands) < 3:
                continue
            bit_op = i.operands[1]
            if bit_op.type == ARM64_OP_IMM and bit_op.imm >= 24:
                target = i.operands[2].imm if i.operands[2].type == ARM64_OP_IMM else -1
                if target > off:
                    b_bytes = self._encode_b(off, target)
                    if b_bytes:
                        self.emit(off, b_bytes,
                                  f"b #0x{target - off:X} [_vm_map_protect]")
                        return True

        self._log("  [-] patch site not found")
        return False

    def patch_mac_mount(self):
        """Bypass MAC mount check: NOP + mov x8,xzr in ___mac_mount.
        Anchor: 'mount_common()' string → find nearby ___mac_mount function.
        """
        self._log("\n[JB] ___mac_mount: NOP + mov x8,xzr")

        # Try symbol first
        foff = self._resolve_symbol("___mac_mount")
        if foff < 0:
            foff = self._resolve_symbol("__mac_mount")
        if foff < 0:
            # Find via 'mount_common()' string → function area
            # ___mac_mount is typically called from mount_common/kernel_mount
            # Search for a function containing a BL+CBNZ w0 pattern
            # near the mount_common string reference area
            str_off = self.find_string(b"mount_common()")
            if str_off >= 0:
                refs = self.find_string_refs(str_off, *self.kern_text)
                if refs:
                    mount_common_func = self.find_function_start(refs[0][0])
                    if mount_common_func >= 0:
                        # __mac_mount is called from mount_common
                        # Find BL targets from mount_common
                        mc_end = self._find_func_end(mount_common_func, 0x2000)
                        for off in range(mount_common_func, mc_end, 4):
                            target = self._is_bl(off)
                            if target >= 0 and self.kern_text[0] <= target < self.kern_text[1]:
                                # Check if this target contains BL+CBNZ w0 pattern
                                # (mac check) followed by a mov to x8
                                te = self._find_func_end(target, 0x1000)
                                for off2 in range(target, te - 8, 4):
                                    d0 = self._disas_at(off2)
                                    if not d0 or d0[0].mnemonic != "bl":
                                        continue
                                    d1 = self._disas_at(off2 + 4)
                                    if d1 and d1[0].mnemonic == "cbnz" and d1[0].op_str.startswith("w0,"):
                                        foff = target
                                        break
                                if foff >= 0:
                                    break

        if foff < 0:
            self._log("  [-] function not found")
            return False

        func_end = self._find_func_end(foff, 0x1000)
        patched = 0

        for off in range(foff, func_end - 8, 4):
            d0 = self._disas_at(off)
            if not d0 or d0[0].mnemonic != "bl":
                continue
            d1 = self._disas_at(off + 4)
            if not d1:
                continue
            if d1[0].mnemonic == "cbnz" and d1[0].op_str.startswith("w0,"):
                self.emit(off, NOP, "NOP [___mac_mount BL check]")
                patched += 1
                for off2 in range(off + 8, min(off + 0x60, func_end), 4):
                    d2 = self._disas_at(off2)
                    if not d2:
                        continue
                    if d2[0].mnemonic == "mov" and "x8" in d2[0].op_str:
                        if d2[0].op_str != "x8, xzr":
                            self.emit(off2, MOV_X8_XZR,
                                      "mov x8,xzr [___mac_mount]")
                            patched += 1
                            break
                break

        if patched == 0:
            self._log("  [-] patch sites not found")
            return False
        return True

    def patch_dounmount(self):
        """NOP a MAC check in _dounmount.
        Pattern: mov w1,#0; mov x2,#0; bl TARGET (MAC policy check pattern).
        """
        self._log("\n[JB] _dounmount: NOP")

        # Try symbol first
        foff = self._resolve_symbol("_dounmount")
        if foff >= 0:
            func_end = self._find_func_end(foff, 0x1000)
            result = self._find_mac_check_bl(foff, func_end)
            if result:
                self.emit(result, NOP, "NOP [_dounmount MAC check]")
                return True

        # String anchor: "dounmount:" → find function → search BL targets
        # for the actual _dounmount with MAC check
        str_off = self.find_string(b"dounmount:")
        if str_off >= 0:
            refs = self.find_string_refs(str_off)
            for adrp_off, _, _ in refs:
                caller = self.find_function_start(adrp_off)
                if caller < 0:
                    continue
                caller_end = self._find_func_end(caller, 0x2000)
                # Check BL targets from this function
                for off in range(caller, caller_end, 4):
                    target = self._is_bl(off)
                    if target < 0 or not (self.kern_text[0] <= target < self.kern_text[1]):
                        continue
                    te = self._find_func_end(target, 0x400)
                    result = self._find_mac_check_bl(target, te)
                    if result:
                        self.emit(result, NOP, "NOP [_dounmount MAC check]")
                        return True

        # Broader: scan kern_text for short functions with MAC check pattern
        ks, ke = self.kern_text
        for off in range(ks, ke - 12, 4):
            d = self._disas_at(off)
            if not d or d[0].mnemonic != "pacibsp":
                continue
            func_end = self._find_func_end(off, 0x400)
            if func_end - off > 0x400:
                continue
            result = self._find_mac_check_bl(off, func_end)
            if result:
                # Verify: function should have "unmount" context
                # (contain a BL to a function also called from known mount code)
                self.emit(result, NOP, "NOP [_dounmount MAC check]")
                return True

        self._log("  [-] patch site not found")
        return False

    def _find_mac_check_bl(self, start, end):
        """Find mov w1,#0; mov x2,#0; bl TARGET pattern. Returns BL offset or None."""
        for off in range(start, end - 8, 4):
            d = self._disas_at(off, 3)
            if len(d) < 3:
                continue
            i0, i1, i2 = d[0], d[1], d[2]
            if i0.mnemonic != "mov" or i1.mnemonic != "mov" or i2.mnemonic != "bl":
                continue
            # Check: mov w1, #0; mov x2, #0
            if "w1" in i0.op_str and "#0" in i0.op_str:
                if "x2" in i1.op_str and "#0" in i1.op_str:
                    return off + 8
            # Also match: mov x2, #0; mov w1, #0
            if "x2" in i0.op_str and "#0" in i0.op_str:
                if "w1" in i1.op_str and "#0" in i1.op_str:
                    return off + 8
        return None

    def patch_bsd_init_auth(self):
        """Bypass rootvp authentication check in _bsd_init.
        Pattern: ldr x0, [xN, #0x2b8]; cbz x0, ...; bl AUTH_FUNC
        Replace the BL with mov x0, #0.
        """
        self._log("\n[JB] _bsd_init: mov x0,#0 (auth bypass)")

        # Try symbol first
        foff = self._resolve_symbol("_bsd_init")
        if foff >= 0:
            func_end = self._find_func_end(foff, 0x2000)
            result = self._find_auth_bl(foff, func_end)
            if result:
                self.emit(result, MOV_X0_0, "mov x0,#0 [_bsd_init auth]")
                return True

        # Pattern search: ldr x0, [xN, #0x2b8]; cbz x0; bl
        ks, ke = self.kern_text
        candidates = []
        for off in range(ks, ke - 8, 4):
            d = self._disas_at(off, 3)
            if len(d) < 3:
                continue
            i0, i1, i2 = d[0], d[1], d[2]
            if i0.mnemonic != "ldr" or i1.mnemonic != "cbz" or i2.mnemonic != "bl":
                continue
            if not i0.op_str.startswith("x0,"):
                continue
            if "#0x2b8" not in i0.op_str:
                continue
            if not i1.op_str.startswith("x0,"):
                continue
            candidates.append(off + 8)  # the BL offset

        if not candidates:
            self._log("  [-] ldr+cbz+bl pattern not found")
            return False

        # Filter to kern_text range (exclude kexts)
        kern_candidates = [c for c in candidates
                           if ks <= c < ke]
        if not kern_candidates:
            kern_candidates = candidates

        # Pick the last one in the kernel (bsd_init is typically late in boot)
        bl_off = kern_candidates[-1]
        self._log(f"  [+] auth BL at 0x{bl_off:X} "
                  f"({len(kern_candidates)} kern candidates)")
        self.emit(bl_off, MOV_X0_0, "mov x0,#0 [_bsd_init auth]")
        return True

    def _find_auth_bl(self, start, end):
        """Find ldr x0,[xN,#0x2b8]; cbz x0; bl pattern. Returns BL offset."""
        for off in range(start, end - 8, 4):
            d = self._disas_at(off, 3)
            if len(d) < 3:
                continue
            i0, i1, i2 = d[0], d[1], d[2]
            if i0.mnemonic == "ldr" and i1.mnemonic == "cbz" and i2.mnemonic == "bl":
                if i0.op_str.startswith("x0,") and "#0x2b8" in i0.op_str:
                    if i1.op_str.startswith("x0,"):
                        return off + 8
        return None

    def patch_spawn_validate_persona(self):
        """NOP persona validation: LDR + TBNZ sites.
        Pattern: ldr wN, [xN, #0x600] (unique struct offset) followed by
        cbz wN then tbnz wN, #1 — NOP both the LDR and the TBNZ.
        """
        self._log("\n[JB] _spawn_validate_persona: NOP (2 sites)")

        # Try symbol first
        foff = self._resolve_symbol("_spawn_validate_persona")
        if foff >= 0:
            func_end = self._find_func_end(foff, 0x800)
            result = self._find_persona_pattern(foff, func_end)
            if result:
                self.emit(result[0], NOP, "NOP [_spawn_validate_persona LDR]")
                self.emit(result[1], NOP, "NOP [_spawn_validate_persona TBNZ]")
                return True

        # Pattern search: ldr wN, [xN, #0x600] ... tbnz wN, #1
        # This pattern is unique to _spawn_validate_persona
        ks, ke = self.kern_text
        for off in range(ks, ke - 0x30, 4):
            d = self._disas_at(off)
            if not d or d[0].mnemonic != "ldr":
                continue
            if "#0x600" not in d[0].op_str:
                continue
            if not d[0].op_str.startswith("w"):
                continue
            # Found LDR wN, [xN, #0x600] — look for TBNZ wN, #1 within 0x30
            for delta in range(4, 0x30, 4):
                d2 = self._disas_at(off + delta)
                if not d2:
                    continue
                if d2[0].mnemonic == "tbnz" and "#1" in d2[0].op_str:
                    # Verify it's a w-register
                    if d2[0].op_str.startswith("w"):
                        self._log(f"  [+] LDR at 0x{off:X}, "
                                  f"TBNZ at 0x{off + delta:X}")
                        self.emit(off, NOP,
                                  "NOP [_spawn_validate_persona LDR]")
                        self.emit(off + delta, NOP,
                                  "NOP [_spawn_validate_persona TBNZ]")
                        return True

        self._log("  [-] pattern not found")
        return False

    def _find_persona_pattern(self, start, end):
        """Find ldr wN,[xN,#0x600] + tbnz wN,#1 pattern. Returns (ldr_off, tbnz_off)."""
        for off in range(start, end - 0x30, 4):
            d = self._disas_at(off)
            if not d or d[0].mnemonic != "ldr":
                continue
            if "#0x600" not in d[0].op_str or not d[0].op_str.startswith("w"):
                continue
            for delta in range(4, 0x30, 4):
                d2 = self._disas_at(off + delta)
                if d2 and d2[0].mnemonic == "tbnz" and "#1" in d2[0].op_str:
                    if d2[0].op_str.startswith("w"):
                        return (off, off + delta)
        return None

    def patch_task_for_pid(self):
        """NOP proc_ro security policy copy in _task_for_pid.

        Pattern: _task_for_pid is a Mach trap handler (0 BL callers) with:
          - 2x ldadda (proc reference counting)
          - 2x ldr wN,[xN,#0x490]; str wN,[xN,#0xc] (proc_ro security copy)
          - movk xN, #0xc8a2, lsl #48 (PAC discriminator)
          - BL to a non-panic function with >500 callers (proc_find etc.)
        NOP the second ldr wN,[xN,#0x490] (the target process security copy).
        """
        self._log("\n[JB] _task_for_pid: NOP")

        # Try symbol first
        foff = self._resolve_symbol("_task_for_pid")
        if foff >= 0:
            func_end = self._find_func_end(foff, 0x800)
            patch_off = self._find_second_ldr490(foff, func_end)
            if patch_off:
                self.emit(patch_off, NOP,
                          "NOP [_task_for_pid proc_ro copy]")
                return True

        # Pattern search: scan kern_text for functions matching the profile
        ks, ke = self.kern_text
        off = ks
        while off < ke - 4:
            d = self._disas_at(off)
            if not d or d[0].mnemonic != "pacibsp":
                off += 4
                continue
            func_start = off
            func_end = self._find_func_end(func_start, 0x1000)

            # Quick filter: skip functions with BL callers (Mach trap = indirect)
            if self.bl_callers.get(func_start, []):
                off = func_end
                continue

            ldadda_count = 0
            ldr490_count = 0
            ldr490_offs = []
            has_movk_c8a2 = False
            has_high_caller_bl = False

            for o in range(func_start, func_end, 4):
                d = self._disas_at(o)
                if not d:
                    continue
                i = d[0]
                if i.mnemonic == "ldadda":
                    ldadda_count += 1
                elif i.mnemonic == "ldr" and "#0x490" in i.op_str \
                        and i.op_str.startswith("w"):
                    d2 = self._disas_at(o + 4)
                    if d2 and d2[0].mnemonic == "str" \
                            and "#0xc" in d2[0].op_str \
                            and d2[0].op_str.startswith("w"):
                        ldr490_count += 1
                        ldr490_offs.append(o)
                elif i.mnemonic == "movk" and "#0xc8a2" in i.op_str:
                    has_movk_c8a2 = True
                elif i.mnemonic == "bl":
                    target = i.operands[0].imm
                    n_callers = len(self.bl_callers.get(target, []))
                    # >500 but <8000 excludes _panic (typically 8000+)
                    if 500 < n_callers < 8000:
                        has_high_caller_bl = True

            if ldadda_count >= 2 and ldr490_count >= 2 \
                    and has_movk_c8a2 and has_high_caller_bl:
                patch_off = ldr490_offs[1]  # NOP the second occurrence
                self._log(f"  [+] _task_for_pid at 0x{func_start:X}, "
                          f"patch at 0x{patch_off:X}")
                self.emit(patch_off, NOP,
                          "NOP [_task_for_pid proc_ro copy]")
                return True

            off = func_end

        self._log("  [-] function not found")
        return False

    def _find_second_ldr490(self, start, end):
        """Find the second ldr wN,[xN,#0x490]+str wN,[xN,#0xc] in range."""
        count = 0
        for off in range(start, end - 4, 4):
            d = self._disas_at(off)
            if not d or d[0].mnemonic != "ldr":
                continue
            if "#0x490" not in d[0].op_str or not d[0].op_str.startswith("w"):
                continue
            d2 = self._disas_at(off + 4)
            if d2 and d2[0].mnemonic == "str" \
                    and "#0xc" in d2[0].op_str \
                    and d2[0].op_str.startswith("w"):
                count += 1
                if count == 2:
                    return off
        return None

    def patch_load_dylinker(self):
        """Bypass PAC auth check in Mach-O chained fixup rebase code.

        The kernel's chained fixup pointer rebase function contains PAC
        authentication triplets: TST xN, #high; B.EQ skip; MOVK xN, #0xc8a2.
        This function has 3+ such triplets and 0 BL callers (indirect call).

        Find the function and replace the LAST TST with an unconditional
        branch to the B.EQ target (always skip PAC re-signing).
        """
        self._log("\n[JB] _load_dylinker: PAC rebase bypass")

        # Try symbol first
        foff = self._resolve_symbol("_load_dylinker")
        if foff >= 0:
            func_end = self._find_func_end(foff, 0x2000)
            result = self._find_tst_pac_triplet(foff, func_end)
            if result:
                tst_off, beq_target = result
                b_bytes = self._encode_b(tst_off, beq_target)
                if b_bytes:
                    self.emit(tst_off, b_bytes,
                              f"b #0x{beq_target - tst_off:X} [_load_dylinker]")
                    return True

        # Pattern search: find functions with 3+ TST+B.EQ+MOVK(#0xc8a2)
        # triplets and 0 BL callers. This is the chained fixup rebase code.
        ks, ke = self.kern_text
        off = ks
        while off < ke - 4:
            d = self._disas_at(off)
            if not d or d[0].mnemonic != "pacibsp":
                off += 4
                continue
            func_start = off
            func_end = self._find_func_end(func_start, 0x2000)

            # Must have 0 BL callers (indirect call via function pointer)
            if self.bl_callers.get(func_start, []):
                off = func_end
                continue

            # Count TST+B.EQ+MOVK(#0xc8a2) triplets
            triplets = []
            for o in range(func_start, func_end - 8, 4):
                d3 = self._disas_at(o, 3)
                if len(d3) < 3:
                    continue
                i0, i1, i2 = d3[0], d3[1], d3[2]
                if i0.mnemonic == "tst" \
                        and "40000000000000" in i0.op_str \
                        and i1.mnemonic == "b.eq" \
                        and i2.mnemonic == "movk" \
                        and "#0xc8a2" in i2.op_str:
                    beq_target = i1.operands[-1].imm
                    triplets.append((o, beq_target))

            if len(triplets) >= 3:
                # Patch the last triplet (deepest in the function)
                tst_off, beq_target = triplets[-1]
                b_bytes = self._encode_b(tst_off, beq_target)
                if b_bytes:
                    self._log(f"  [+] rebase func at 0x{func_start:X}, "
                              f"patch TST at 0x{tst_off:X}")
                    self.emit(tst_off, b_bytes,
                              f"b #0x{beq_target - tst_off:X} "
                              f"[_load_dylinker PAC bypass]")
                    return True

            off = func_end

        self._log("  [-] PAC rebase function not found")
        return False

    def _find_tst_pac_triplet(self, start, end):
        """Find last TST+B.EQ+MOVK(#0xc8a2) triplet. Returns (tst_off, beq_target)."""
        last = None
        for off in range(start, end - 8, 4):
            d = self._disas_at(off, 3)
            if len(d) < 3:
                continue
            i0, i1, i2 = d[0], d[1], d[2]
            if i0.mnemonic == "tst" \
                    and "40000000000000" in i0.op_str \
                    and i1.mnemonic == "b.eq" \
                    and i2.mnemonic == "movk" \
                    and "#0xc8a2" in i2.op_str:
                last = (off, i1.operands[-1].imm)
        return last

    def patch_shared_region_map(self):
        """Force shared region check: cmp x0,x0.
        Anchor: '/private/preboot/Cryptexes' string → function → CMP+B.NE.
        """
        self._log("\n[JB] _shared_region_map_and_slide_setup: cmp x0,x0")

        # Try symbol first
        foff = self._resolve_symbol("_shared_region_map_and_slide_setup")
        if foff < 0:
            foff = self._find_func_by_string(
                b"/private/preboot/Cryptexes", self.kern_text)
        if foff < 0:
            foff = self._find_func_by_string(b"/private/preboot/Cryptexes")
        if foff < 0:
            self._log("  [-] function not found")
            return False

        func_end = self._find_func_end(foff, 0x2000)

        for off in range(foff, func_end - 4, 4):
            d = self._disas_at(off, 2)
            if len(d) < 2:
                continue
            i0, i1 = d[0], d[1]
            if i0.mnemonic != "cmp" or i1.mnemonic != "b.ne":
                continue
            ops = i0.operands
            if len(ops) < 2:
                continue
            if ops[0].type == ARM64_OP_REG and ops[1].type == ARM64_OP_REG:
                self.emit(off, CMP_X0_X0,
                          "cmp x0,x0 [_shared_region_map_and_slide_setup]")
                return True

        self._log("  [-] CMP+B.NE pattern not found")
        return False

    def patch_nvram_verify_permission(self):
        """NOP verification in IONVRAMController's verifyPermission.
        Anchor: 'krn.' string (NVRAM key prefix) → xref → function → TBZ/TBNZ.
        """
        self._log("\n[JB] verifyPermission (NVRAM): NOP")

        # Try symbol first
        sym_off = self._resolve_symbol(
            "__ZL16verifyPermission16IONVRAMOperationPKhPKcb")
        if sym_off < 0:
            for sym, off in self.symbols.items():
                if "verifyPermission" in sym and "NVRAM" in sym:
                    sym_off = off
                    break

        # String anchor: "krn." is referenced in verifyPermission.
        # The TBZ/TBNZ guard is immediately before the ADRP+ADD that
        # loads the "krn." string, so search backward from that ref.
        str_off = self.find_string(b"krn.")
        ref_off = -1
        if str_off >= 0:
            refs = self.find_string_refs(str_off)
            if refs:
                ref_off = refs[0][0]  # ADRP instruction offset

        foff = sym_off if sym_off >= 0 else (
            self.find_function_start(ref_off) if ref_off >= 0 else -1)

        if foff < 0:
            # Fallback: try NVRAM entitlement string
            ent_off = self.find_string(
                b"com.apple.private.iokit.nvram-write-access")
            if ent_off >= 0:
                ent_refs = self.find_string_refs(ent_off)
                if ent_refs:
                    foff = self.find_function_start(ent_refs[0][0])

        if foff < 0:
            self._log("  [-] function not found")
            return False

        func_end = self._find_func_end(foff, 0x600)

        # Strategy 1: search backward from "krn." string ref for
        # nearest TBZ/TBNZ — the guard branch is typically within
        # a few instructions before the ADRP that loads "krn.".
        if ref_off > foff:
            for off in range(ref_off - 4, max(foff - 4, ref_off - 0x20), -4):
                d = self._disas_at(off)
                if d and d[0].mnemonic in ("tbnz", "tbz"):
                    self.emit(off, NOP, "NOP [verifyPermission NVRAM]")
                    return True

        # Strategy 2: scan full function for first TBZ/TBNZ
        for off in range(foff, func_end, 4):
            d = self._disas_at(off)
            if not d:
                continue
            if d[0].mnemonic in ("tbnz", "tbz"):
                self.emit(off, NOP, "NOP [verifyPermission NVRAM]")
                return True

        self._log("  [-] TBZ/TBNZ not found in function")
        return False

    def patch_io_secure_bsd_root(self):
        """Skip security check in _IOSecureBSDRoot.
        Anchor: 'SecureRootName' string → function → CBZ/CBNZ → unconditional B.
        """
        self._log("\n[JB] _IOSecureBSDRoot: skip check")

        # Try symbol first
        foff = self._resolve_symbol("_IOSecureBSDRoot")
        if foff < 0:
            foff = self._find_func_by_string(b"SecureRootName")
        if foff < 0:
            self._log("  [-] function not found")
            return False

        func_end = self._find_func_end(foff, 0x400)

        for off in range(foff, func_end - 4, 4):
            d = self._disas_at(off)
            if not d:
                continue
            i = d[0]
            if i.mnemonic in ("cbnz", "cbz", "tbnz", "tbz"):
                target = None
                for op in reversed(i.operands):
                    if op.type == ARM64_OP_IMM:
                        target = op.imm
                        break
                if target and target > off:
                    b_bytes = self._encode_b(off, target)
                    if b_bytes:
                        self.emit(off, b_bytes,
                                  f"b #0x{target - off:X} [_IOSecureBSDRoot]")
                        return True

        self._log("  [-] conditional branch not found")
        return False

    def patch_thid_should_crash(self):
        """Zero out _thid_should_crash global variable.
        Anchor: 'thid_should_crash' string in __DATA → nearby sysctl_oid struct
        contains a raw pointer (low32 = file offset) to the variable.
        """
        self._log("\n[JB] _thid_should_crash: zero out")

        # Try symbol first
        foff = self._resolve_symbol("_thid_should_crash")
        if foff >= 0:
            self.emit(foff, b'\x00\x00\x00\x00',
                      "zero [_thid_should_crash]")
            return True

        # Find the string in __DATA (sysctl name string)
        str_off = self.find_string(b"thid_should_crash")
        if str_off < 0:
            self._log("  [-] string not found")
            return False

        self._log(f"  [*] string at foff 0x{str_off:X}")

        # The sysctl_oid struct is near the string in __DATA.
        # It contains 8-byte entries, one of which has its low32 bits
        # equal to the file offset of the variable (chained fixup encoding).
        # The variable is a 4-byte int (typically value 1) in __DATA_CONST.
        #
        # Search forward from the string for 8-byte values whose low32
        # points to a valid location holding a small non-zero value.
        data_const_ranges = [(fo, fo + fs) for name, _, fo, fs, _
                             in self.all_segments
                             if name in ("__DATA_CONST",) and fs > 0]

        for delta in range(0, 128, 8):
            check = str_off + delta
            if check + 8 > self.size:
                break
            val = _rd64(self.raw, check)
            if val == 0:
                continue
            low32 = val & 0xFFFFFFFF
            # The variable should be in __DATA_CONST or __DATA
            if low32 == 0 or low32 >= self.size:
                continue
            # Check if low32 points to a location holding a small int (1-255)
            target_val = _rd32(self.raw, low32)
            if 1 <= target_val <= 255:
                # Verify it's in a data segment (not code)
                in_data = any(s <= low32 < e for s, e in data_const_ranges)
                if not in_data:
                    # Also accept __DATA segments
                    in_data = any(
                        fo <= low32 < fo + fs
                        for name, _, fo, fs, _ in self.all_segments
                        if "DATA" in name and fs > 0)
                if in_data:
                    self._log(f"  [+] variable at foff 0x{low32:X} "
                              f"(value={target_val}, found via sysctl_oid "
                              f"at str+0x{delta:X})")
                    self.emit(low32, b'\x00\x00\x00\x00',
                              "zero [_thid_should_crash]")
                    return True

        # Fallback: if string has code refs, search via ADRP+ADD
        refs = self.find_string_refs(str_off)
        if refs:
            func_start = self.find_function_start(refs[0][0])
            if func_start >= 0:
                func_end = self._find_func_end(func_start, 0x200)
                for off in range(func_start, func_end - 4, 4):
                    d = self._disas_at(off, 2)
                    if len(d) < 2:
                        continue
                    i0, i1 = d[0], d[1]
                    if i0.mnemonic == "adrp" and i1.mnemonic == "add":
                        page = (i0.operands[1].imm - self.base_va) & ~0xFFF
                        imm12 = (i1.operands[2].imm if len(i1.operands) > 2
                                 else 0)
                        target = page + imm12
                        if 0 < target < self.size:
                            tv = _rd32(self.raw, target)
                            if 1 <= tv <= 255:
                                self.emit(target, b'\x00\x00\x00\x00',
                                          "zero [_thid_should_crash]")
                                return True

        self._log("  [-] variable not found")
        return False

    # ══════════════════════════════════════════════════════════════
    # Group C: Complex shellcode patches
    # ══════════════════════════════════════════════════════════════

    def patch_cred_label_update_execve(self):
        """Redirect _cred_label_update_execve to shellcode that sets cs_flags.

        Shellcode: LDR x0,[sp,#8]; LDR w1,[x0]; ORR w1,w1,#0x4000000;
                   ORR w1,w1,#0xF; AND w1,w1,#0xFFFFC0FF; STR w1,[x0];
                   MOV x0,xzr; RETAB
        """
        self._log("\n[JB] _cred_label_update_execve: shellcode (cs_flags)")

        # Find the function via AMFI string reference
        func_off = -1

        # Try symbol
        for sym, off in self.symbols.items():
            if "cred_label_update_execve" in sym and "hook" not in sym:
                func_off = off
                break

        if func_off < 0:
            # String anchor: the function is near execve-related AMFI code.
            # Look for the function that contains the AMFI string ref and
            # then find _cred_label_update_execve through BL targets.
            str_off = self.find_string(b"AMFI: code signature validation failed")
            if str_off >= 0:
                refs = self.find_string_refs(str_off, *self.amfi_text)
                if refs:
                    caller = self.find_function_start(refs[0][0])
                    if caller >= 0:
                        # Walk through the AMFI text section to find functions
                        # that have a RETAB at the end and take many arguments
                        # The _cred_label_update_execve has many args and a
                        # distinctive prologue.
                        pass

        if func_off < 0:
            # Alternative: search AMFI text for functions that match the pattern
            # of _cred_label_update_execve (long prologue, many saved regs, RETAB)
            # Look for the specific pattern: mov xN, x2 in early prologue
            # (saves the vnode arg) followed by stp xzr,xzr pattern
            s, e = self.amfi_text
            # Search for PACIBSP functions in AMFI that are BL targets from
            # the execve kill path area
            str_off = self.find_string(b"AMFI: hook..execve() killing")
            if str_off < 0:
                str_off = self.find_string(b"execve() killing")
            if str_off >= 0:
                refs = self.find_string_refs(str_off, s, e)
                if not refs:
                    refs = self.find_string_refs(str_off)
                if refs:
                    kill_func = self.find_function_start(refs[0][0])
                    if kill_func >= 0:
                        kill_end = self._find_func_end(kill_func, 0x800)
                        # The kill function ends with RETAB. The next function
                        # after it should be close to _cred_label_update_execve.
                        # Actually, _cred_label_update_execve is typically the
                        # function BEFORE the kill function.
                        # Search backward from kill_func for a RETAB/RET
                        for back in range(kill_func - 4, max(kill_func - 0x400, s), -4):
                            val = _rd32(self.raw, back)
                            if val in (0xD65F0FFF, 0xD65F0BFF, 0xD65F03C0):
                                # Found end of previous function.
                                # The function we want starts at the next PACIBSP before back.
                                for scan in range(back - 4, max(back - 0x400, s), -4):
                                    d = self._disas_at(scan)
                                    if d and d[0].mnemonic == "pacibsp":
                                        func_off = scan
                                        break
                                break

        if func_off < 0:
            self._log("  [-] function not found, skipping shellcode patch")
            return False

        # Find code cave
        cave = self._find_code_cave(32)  # 8 instructions = 32 bytes
        if cave < 0:
            self._log("  [-] no code cave found for shellcode")
            return False

        # Assemble shellcode
        shellcode = (
            asm("ldr x0, [sp, #8]") +         # load cred pointer
            asm("ldr w1, [x0]") +              # load cs_flags
            asm("orr w1, w1, #0x4000000") +    # set CS_PLATFORM_BINARY
            asm("orr w1, w1, #0xF") +          # set CS_VALID|CS_ADHOC|CS_GET_TASK_ALLOW|CS_INSTALLER
            bytes([0x21, 0x64, 0x12, 0x12]) +  # AND w1, w1, #0xFFFFC0FF (clear CS_HARD|CS_KILL etc)
            asm("str w1, [x0]") +              # store back
            asm("mov x0, xzr") +               # return 0
            bytes([0xFF, 0x0F, 0x5F, 0xD6])    # RETAB
        )

        # Find the return site in the function (last RETAB)
        func_end = self._find_func_end(func_off, 0x200)
        ret_off = -1
        for off in range(func_end - 4, func_off, -4):
            val = _rd32(self.raw, off)
            if val in (0xD65F0FFF, 0xD65F0BFF, 0xD65F03C0):
                ret_off = off
                break
        if ret_off < 0:
            self._log("  [-] function return not found")
            return False

        # Write shellcode to cave
        for i in range(0, len(shellcode), 4):
            self.emit(cave + i, shellcode[i:i+4],
                      f"shellcode+{i} [_cred_label_update_execve]")

        # Branch from function return to cave
        b_bytes = self._encode_b(ret_off, cave)
        if b_bytes:
            self.emit(ret_off, b_bytes,
                      f"b cave [_cred_label_update_execve -> 0x{cave:X}]")
        else:
            self._log("  [-] branch to cave out of range")
            return False

        return True

    def patch_syscallmask_apply_to_proc(self):
        """Redirect _syscallmask_apply_to_proc to custom filter shellcode.
        Anchor: 'syscallmask.c' string → find function → redirect to cave.
        """
        self._log("\n[JB] _syscallmask_apply_to_proc: shellcode (filter mask)")

        # Resolve required functions
        func_off = self._resolve_symbol("_syscallmask_apply_to_proc")
        zalloc_off = self._resolve_symbol("_zalloc_ro_mut")
        filter_off = self._resolve_symbol("_proc_set_syscall_filter_mask")

        if func_off < 0:
            # String anchor: "syscallmask.c"
            str_off = self.find_string(b"syscallmask.c")
            if str_off >= 0:
                refs = self.find_string_refs(str_off, *self.kern_text)
                if not refs:
                    refs = self.find_string_refs(str_off)
                if refs:
                    # The function containing this string ref is in the
                    # syscallmask module. Find _syscallmask_apply_to_proc
                    # by looking for a function nearby that takes 4 args.
                    base_func = self.find_function_start(refs[0][0])
                    if base_func >= 0:
                        # Search nearby functions for the one that has a
                        # BL to _proc_set_syscall_filter_mask-like function.
                        # Actually, the function with "syscallmask.c" IS likely
                        # _syscallmask_apply_to_proc or very close to it.
                        func_off = base_func

        if func_off < 0:
            self._log("  [-] _syscallmask_apply_to_proc not found")
            return False

        # Find _zalloc_ro_mut: search for the BL target from within the function
        # that's called with specific arguments. Use BL callers analysis.
        if zalloc_off < 0:
            func_end = self._find_func_end(func_off, 0x200)
            for off in range(func_off, func_end, 4):
                target = self._is_bl(off)
                if target >= 0:
                    # _zalloc_ro_mut is typically one of the BL targets
                    # It's the one with many callers (>50)
                    # bl_callers is keyed by file offset (same as _is_bl returns)
                    n = len(self.bl_callers.get(target, []))
                    if n > 50:
                        zalloc_off = target
                        break

        # Find _proc_set_syscall_filter_mask: search for a BL or B target
        if filter_off < 0:
            func_end = self._find_func_end(func_off, 0x200)
            # It's typically the last BL/B target in the function (tail call)
            for off in range(func_end - 4, func_off, -4):
                target = self._is_bl(off)
                if target >= 0:
                    filter_off = target
                    break
                # Also check for unconditional B
                val = _rd32(self.raw, off)
                if (val & 0xFC000000) == 0x14000000:
                    imm26 = val & 0x3FFFFFF
                    if imm26 & (1 << 25):
                        imm26 -= (1 << 26)
                    target = off + imm26 * 4
                    if self.kern_text[0] <= target < self.kern_text[1]:
                        filter_off = target
                        break

        if zalloc_off < 0 or filter_off < 0:
            self._log(f"  [-] required functions not found "
                      f"(zalloc={'found' if zalloc_off >= 0 else 'missing'}, "
                      f"filter={'found' if filter_off >= 0 else 'missing'})")
            return False

        # Find code cave (need ~160 bytes)
        cave = self._find_code_cave(160)
        if cave < 0:
            self._log("  [-] no code cave found")
            return False

        cave_base = cave

        # Encode BL to _zalloc_ro_mut (at cave + 28*4)
        zalloc_bl_off = cave_base + 28 * 4
        zalloc_bl = self._encode_bl(zalloc_bl_off, zalloc_off)
        if not zalloc_bl:
            self._log("  [-] BL to _zalloc_ro_mut out of range")
            return False

        # Encode B to _proc_set_syscall_filter_mask (at end of shellcode)
        filter_b_off = cave_base + 37 * 4
        filter_b = self._encode_b(filter_b_off, filter_off)
        if not filter_b:
            self._log("  [-] B to _proc_set_syscall_filter_mask out of range")
            return False

        # Build shellcode
        shellcode_parts = []
        for _ in range(10):
            shellcode_parts.append(b'\xff\xff\xff\xff')

        shellcode_parts.append(asm("cbz x2, #0x6c"))       # idx 10
        shellcode_parts.append(asm("sub sp, sp, #0x40"))    # idx 11
        shellcode_parts.append(asm("stp x19, x20, [sp, #0x10]"))  # idx 12
        shellcode_parts.append(asm("stp x21, x22, [sp, #0x20]"))  # idx 13
        shellcode_parts.append(asm("stp x29, x30, [sp, #0x30]"))  # idx 14
        shellcode_parts.append(asm("mov x19, x0"))          # idx 15
        shellcode_parts.append(asm("mov x20, x1"))          # idx 16
        shellcode_parts.append(asm("mov x21, x2"))          # idx 17
        shellcode_parts.append(asm("mov x22, x3"))          # idx 18
        shellcode_parts.append(asm("mov x8, #8"))           # idx 19
        shellcode_parts.append(asm("mov x0, x17"))          # idx 20
        shellcode_parts.append(asm("mov x1, x21"))          # idx 21
        shellcode_parts.append(asm("mov x2, #0"))           # idx 22
        # adr x3, #-0x5C — encode manually
        adr_delta = -(23 * 4)
        immhi = (adr_delta >> 2) & 0x7FFFF
        immlo = adr_delta & 0x3
        adr_insn = 0x10000003 | (immlo << 29) | (immhi << 5)
        shellcode_parts.append(struct.pack("<I", adr_insn))  # idx 23
        shellcode_parts.append(asm("udiv x4, x22, x8"))     # idx 24
        shellcode_parts.append(asm("msub x10, x4, x8, x22"))  # idx 25
        shellcode_parts.append(asm("cbz x10, #8"))          # idx 26
        shellcode_parts.append(asm("add x4, x4, #1"))       # idx 27
        shellcode_parts.append(zalloc_bl)                    # idx 28
        shellcode_parts.append(asm("mov x0, x19"))           # idx 29
        shellcode_parts.append(asm("mov x1, x20"))           # idx 30
        shellcode_parts.append(asm("mov x2, x21"))           # idx 31
        shellcode_parts.append(asm("mov x3, x22"))           # idx 32
        shellcode_parts.append(asm("ldp x19, x20, [sp, #0x10]"))  # idx 33
        shellcode_parts.append(asm("ldp x21, x22, [sp, #0x20]"))  # idx 34
        shellcode_parts.append(asm("ldp x29, x30, [sp, #0x30]"))  # idx 35
        shellcode_parts.append(asm("add sp, sp, #0x40"))    # idx 36
        shellcode_parts.append(filter_b)                     # idx 37

        # Write shellcode
        for i, part in enumerate(shellcode_parts):
            self.emit(cave_base + i * 4, part,
                      f"shellcode+{i*4} [_syscallmask_apply_to_proc]")

        # Redirect original function
        func_end = self._find_func_end(func_off, 0x200)
        for off in range(func_off, min(func_off + 0x100, func_end), 4):
            d = self._disas_at(off)
            if not d:
                continue
            if d[0].mnemonic == "bl":
                self.emit(off - 4, asm("mov x17, x0"),
                          "mov x17,x0 [_syscallmask_apply_to_proc inject]")
                b_to_cave = self._encode_b(off, cave_base + 10 * 4)
                if b_to_cave:
                    self.emit(off, b_to_cave,
                              f"b cave [_syscallmask_apply_to_proc -> 0x{cave_base + 40:X}]")
                return True

        self._log("  [-] injection point not found")
        return False

    def patch_hook_cred_label_update_execve(self):
        """Redirect _hook_cred_label_update_execve ops table entry to shellcode.

        Patches the sandbox MAC ops table entry for cred_label_update_execve
        to point to custom shellcode that performs vnode_getattr ownership
        propagation.  Instead of calling vfs_context_current (which may not
        exist as a BL-callable function), we construct a vfs_context on the
        stack using current_thread (mrs tpidr_el1) and the caller's
        credential (x0 = old_cred).
        """
        self._log("\n[JB] _hook_cred_label_update_execve: ops table + shellcode")

        # ── 1. Find vnode_getattr via string anchor ──────────────
        vnode_getattr_off = self._resolve_symbol("_vnode_getattr")
        if vnode_getattr_off < 0:
            str_off = self.find_string(b"vnode_getattr")
            if str_off >= 0:
                refs = self.find_string_refs(str_off)
                if refs:
                    vnode_getattr_off = self.find_function_start(refs[0][0])
                    if vnode_getattr_off >= 0:
                        self._log(f"  [+] vnode_getattr at 0x"
                                  f"{vnode_getattr_off:X} (via string)")

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
            self._log("  [-] hook entry not found in ops table "
                      f"(best: idx={hook_index}, size={best_size})")
            return False

        self._log(f"  [+] hook at ops[{hook_index}] = 0x{orig_hook:X} "
                  f"({best_size} bytes)")

        # ── 4. Find code cave ────────────────────────────────────
        cave = self._find_code_cave(180)
        if cave < 0:
            self._log("  [-] no code cave found")
            return False
        self._log(f"  [+] code cave at 0x{cave:X}")

        # ── 5. Encode BL to vnode_getattr ────────────────────────
        vnode_bl_off = cave + 17 * 4
        vnode_bl = self._encode_bl(vnode_bl_off, vnode_getattr_off)
        if not vnode_bl:
            self._log("  [-] BL to vnode_getattr out of range")
            return False

        # ── 6. Encode B to original hook ─────────────────────────
        b_back_off = cave + 44 * 4
        b_back = self._encode_b(b_back_off, orig_hook)
        if not b_back:
            self._log("  [-] B to original hook out of range")
            return False

        # ── 7. Build shellcode ───────────────────────────────────
        # MAC hook args: x0=old_cred, x1=new_cred, x2=proc, x3=vp
        #
        # Parts [8-10] construct a vfs_context on the stack instead
        # of calling vfs_context_current, which may not exist as a
        # direct BL target in stripped ARM64e kernels.
        #
        # struct vfs_context { thread_t vc_thread; kauth_cred_t vc_ucred; }
        # We place it at [sp, #0x70] (between saved regs and vattr buffer).
        parts = []
        parts.append(NOP)                                       # 0
        parts.append(asm("cbz x3, #0xa8"))                     # 1
        parts.append(asm("sub sp, sp, #0x400"))                # 2
        parts.append(asm("stp x29, x30, [sp]"))               # 3
        parts.append(asm("stp x0, x1, [sp, #16]"))            # 4
        parts.append(asm("stp x2, x3, [sp, #32]"))            # 5
        parts.append(asm("stp x4, x5, [sp, #48]"))            # 6
        parts.append(asm("stp x6, x7, [sp, #64]"))            # 7
        # Construct vfs_context inline (replaces BL vfs_context_current)
        parts.append(asm("mrs x8, tpidr_el1"))                 # 8: current_thread
        parts.append(asm("stp x8, x0, [sp, #0x70]"))          # 9: {thread, cred}
        parts.append(asm("add x2, sp, #0x70"))                 # 10: ctx = &vfs_ctx
        # Setup vnode_getattr(vp, &vattr, ctx)
        parts.append(asm("ldr x0, [sp, #0x28]"))              # 11: x0 = vp
        parts.append(asm("add x1, sp, #0x80"))                # 12: x1 = &vattr
        parts.append(asm("mov w8, #0x380"))                    # 13: vattr size
        parts.append(asm("stp xzr, x8, [x1]"))               # 14: init vattr
        parts.append(asm("stp xzr, xzr, [x1, #0x10]"))       # 15: init vattr
        parts.append(NOP)                                       # 16
        parts.append(vnode_bl)                                  # 17: BL vnode_getattr
        # Check result + propagate ownership
        parts.append(asm("cbnz x0, #0x50"))                   # 18: error → skip
        parts.append(asm("mov w2, #0"))                        # 19: changed = 0
        parts.append(asm("ldr w8, [sp, #0xCC]"))              # 20: va_mode
        parts.append(bytes([0xa8, 0x00, 0x58, 0x36]))          # 21: tbz w8,#11
        parts.append(asm("ldr w8, [sp, #0xC4]"))              # 22: va_uid
        parts.append(asm("ldr x0, [sp, #0x18]"))              # 23: new_cred
        parts.append(asm("str w8, [x0, #0x18]"))              # 24: cred->uid
        parts.append(asm("mov w2, #1"))                        # 25: changed = 1
        parts.append(asm("ldr w8, [sp, #0xCC]"))              # 26: va_mode
        parts.append(bytes([0xa8, 0x00, 0x50, 0x36]))          # 27: tbz w8,#10
        parts.append(asm("mov w2, #1"))                        # 28: changed = 1
        parts.append(asm("ldr w8, [sp, #0xC8]"))              # 29: va_gid
        parts.append(asm("ldr x0, [sp, #0x18]"))              # 30: new_cred
        parts.append(asm("str w8, [x0, #0x28]"))              # 31: cred->gid
        parts.append(asm("cbz w2, #0x1c"))                     # 32: if !changed
        parts.append(asm("ldr x0, [sp, #0x20]"))              # 33: proc
        parts.append(asm("ldr w8, [x0, #0x454]"))             # 34: p_csflags
        parts.append(asm("orr w8, w8, #0x100"))               # 35: CS_VALID
        parts.append(asm("str w8, [x0, #0x454]"))             # 36: store
        parts.append(asm("ldp x0, x1, [sp, #16]"))            # 37: restore
        parts.append(asm("ldp x2, x3, [sp, #32]"))            # 38
        parts.append(asm("ldp x4, x5, [sp, #48]"))            # 39
        parts.append(asm("ldp x6, x7, [sp, #64]"))            # 40
        parts.append(asm("ldp x29, x30, [sp]"))               # 41
        parts.append(asm("add sp, sp, #0x400"))                # 42
        parts.append(NOP)                                       # 43
        parts.append(b_back)                                    # 44: B orig_hook

        for i, part in enumerate(parts):
            self.emit(cave + i * 4, part,
                      f"shellcode+{i*4} [_hook_cred_label_update_execve]")

        # ── 8. Rewrite ops table entry ───────────────────────────
        # Preserve auth rebase upper 32 bits (PAC key, diversity,
        # chain next) and replace lower 32 bits with cave foff.
        entry_off = ops_table + hook_index * 8
        orig_raw = _rd64(self.raw, entry_off)
        new_raw = (orig_raw & 0xFFFFFFFF00000000) | (cave & 0xFFFFFFFF)
        self.emit(entry_off, struct.pack("<Q", new_raw),
                  f"ops_table[{hook_index}] = cave 0x{cave:X} "
                  f"[_hook_cred_label_update_execve]")

        return True

    def patch_kcall10(self):
        """Replace SYS_kas_info (syscall 439) with kcall10 shellcode.

        Anchor: find _nosys function by pattern, then search DATA segments
        for the sysent table (first entry points to _nosys).
        """
        self._log("\n[JB] kcall10: syscall 439 replacement")

        # Find _nosys
        nosys_off = self._resolve_symbol("_nosys")
        if nosys_off < 0:
            nosys_off = self._find_nosys()
        if nosys_off < 0:
            self._log("  [-] _nosys not found")
            return False

        self._log(f"  [+] _nosys at 0x{nosys_off:X}")

        # Find _munge_wwwwwwww
        munge_off = self._resolve_symbol("_munge_wwwwwwww")
        if munge_off < 0:
            for sym, off in self.symbols.items():
                if "munge_wwwwwwww" in sym:
                    munge_off = off
                    break

        # Search for sysent table in DATA segments
        sysent_off = -1
        for seg_name, vmaddr, fileoff, filesize, _ in self.all_segments:
            if "DATA" not in seg_name:
                continue
            for off in range(fileoff, fileoff + filesize - 24, 8):
                val = _rd64(self.raw, off)
                decoded = self._decode_chained_ptr(val)
                if decoded == nosys_off:
                    # Verify: sysent[1] should also point to valid code
                    val2 = _rd64(self.raw, off + 24)
                    decoded2 = self._decode_chained_ptr(val2)
                    if decoded2 > 0 and any(
                            s <= decoded2 < e for s, e in self.code_ranges):
                        sysent_off = off
                        break
            if sysent_off >= 0:
                break

        if sysent_off < 0:
            self._log("  [-] sysent table not found")
            return False

        self._log(f"  [+] sysent table at file offset 0x{sysent_off:X}")

        # Entry 439 (SYS_kas_info)
        entry_439 = sysent_off + 439 * 24

        # Find code cave for kcall10 shellcode (~128 bytes = 32 instructions)
        cave = self._find_code_cave(128)
        if cave < 0:
            self._log("  [-] no code cave found")
            return False

        # Build kcall10 shellcode
        parts = [
            asm("ldr x10, [sp, #0x40]"),     # 0
            asm("ldp x0, x1, [x10, #0]"),    # 1
            asm("ldp x2, x3, [x10, #0x10]"), # 2
            asm("ldp x4, x5, [x10, #0x20]"), # 3
            asm("ldp x6, x7, [x10, #0x30]"), # 4
            asm("ldp x8, x9, [x10, #0x40]"), # 5
            asm("ldr x10, [x10, #0x50]"),    # 6
            asm("mov x16, x0"),               # 7
            asm("mov x0, x1"),                # 8
            asm("mov x1, x2"),                # 9
            asm("mov x2, x3"),                # 10
            asm("mov x3, x4"),                # 11
            asm("mov x4, x5"),                # 12
            asm("mov x5, x6"),                # 13
            asm("mov x6, x7"),                # 14
            asm("mov x7, x8"),                # 15
            asm("mov x8, x9"),                # 16
            asm("mov x9, x10"),               # 17
            asm("stp x29, x30, [sp, #-0x10]!"),  # 18
            bytes([0x00, 0x02, 0x3F, 0xD6]),  # 19: BLR x16
            asm("ldp x29, x30, [sp], #0x10"), # 20
            asm("ldr x11, [sp, #0x40]"),      # 21
            NOP,                               # 22
            asm("stp x0, x1, [x11, #0]"),     # 23
            asm("stp x2, x3, [x11, #0x10]"),  # 24
            asm("stp x4, x5, [x11, #0x20]"),  # 25
            asm("stp x6, x7, [x11, #0x30]"),  # 26
            asm("stp x8, x9, [x11, #0x40]"),  # 27
            asm("str x10, [x11, #0x50]"),     # 28
            asm("mov x0, #0"),                 # 29
            asm("ret"),                        # 30
            NOP,                               # 31
        ]

        for i, part in enumerate(parts):
            self.emit(cave + i * 4, part,
                      f"shellcode+{i*4} [kcall10]")

        # Patch sysent[439]
        cave_va = self.base_va + cave
        self.emit(entry_439, struct.pack("<Q", cave_va),
                  f"sysent[439].sy_call = 0x{cave_va:X} [kcall10]")

        if munge_off >= 0:
            munge_va = self.base_va + munge_off
            self.emit(entry_439 + 8, struct.pack("<Q", munge_va),
                      f"sysent[439].sy_munge32 = 0x{munge_va:X} [kcall10]")

        # sy_return_type = SYSCALL_RET_UINT64_T (7)
        self.emit(entry_439 + 16, struct.pack("<I", 7),
                  "sysent[439].sy_return_type = 7 [kcall10]")

        # sy_narg = 8, sy_arg_bytes = 0x20
        self.emit(entry_439 + 20, struct.pack("<I", 0x200008),
                  "sysent[439].sy_narg=8,sy_arg_bytes=0x20 [kcall10]")

        return True

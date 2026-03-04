"""kernel_jb_base.py — JB base class with infrastructure methods."""

import struct
from collections import Counter

from capstone.arm64_const import (
    ARM64_OP_REG,
    ARM64_OP_IMM,
    ARM64_OP_MEM,
    ARM64_REG_X0,
    ARM64_REG_X1,
    ARM64_REG_W0,
    ARM64_REG_X8,
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


class KernelJBPatcherBase(KernelPatcher):
    def __init__(self, data, verbose=False):
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
                "<IBBHQ", self.raw, entry_off
            )
            if n_type & 0x0E != 0x0E:
                continue
            if n_value == 0:
                continue
            name_off = stroff + n_strx
            if name_off >= self.size:
                continue
            name_end = self.raw.find(b"\x00", name_off)
            if name_end < 0 or name_end - name_off > 512:
                continue
            name = self.raw[name_off:name_end].decode("ascii", errors="replace")
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

        Only searches __TEXT_EXEC and __TEXT_BOOT_EXEC segments.
        __PRELINK_TEXT is excluded because KTRR makes it non-executable at
        runtime on ARM64e, even though the Mach-O marks it R-X.
        """
        EXEC_SEGS = ("__TEXT_EXEC", "__TEXT_BOOT_EXEC")
        exec_ranges = [
            (foff, foff + fsz)
            for name, _, foff, fsz, _ in self.all_segments
            if name in EXEC_SEGS and fsz > 0
        ]
        exec_ranges.sort()

        needed = (size + align - 1) // align * align
        for rng_start, rng_end in exec_ranges:
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


# Re-export for patch mixins
__all__ = [
    "KernelJBPatcherBase",
    "CBZ_X2_8",
    "STR_X0_X2",
    "CMP_XZR_XZR",
    "MOV_X8_XZR",
    "NOP",
    "MOV_X0_0",
    "MOV_X0_1",
    "MOV_W0_0",
    "MOV_W0_1",
    "CMP_W0_W0",
    "CMP_X0_X0",
    "RET",
    "asm",
    "_rd32",
    "_rd64",
    "struct",
    "Counter",
    "ARM64_OP_REG",
    "ARM64_OP_IMM",
    "ARM64_OP_MEM",
    "ARM64_REG_X0",
    "ARM64_REG_X1",
    "ARM64_REG_W0",
    "ARM64_REG_X8",
]

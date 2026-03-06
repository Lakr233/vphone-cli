"""Mixin: KernelJBPatchKcall10Mixin."""

from .kernel_jb_base import _rd64, struct
from .kernel import asm
from .kernel_asm import _PACIBSP_U32, _RETAB_U32


# Max sysent entries in XNU (dispatch clamps at 0x22E = 558).
_SYSENT_MAX_ENTRIES = 558
# Each sysent entry is 24 bytes.
_SYSENT_ENTRY_SIZE = 24
# PAC discriminator used by the syscall dispatch (MOV X17, #0xBCAD; BLRAA X8, X17).
_SYSENT_PAC_DIVERSITY = 0xBCAD

# Rebuilt PCC 26.1 semantics:
#   uap[0] = target function pointer
#   uap[1] = arg0
#   ...
#   uap[7] = arg6
# Return path:
#   store X0 as 64-bit into retval, expose through sy_return_type=UINT64
_KCALL10_NARG = 8
_KCALL10_ARG_BYTES_32 = _KCALL10_NARG * 4
_KCALL10_RETURN_TYPE = 7
_KCALL10_EINVAL = 22


class KernelJBPatchKcall10Mixin:
    def _find_sysent_table(self, nosys_off):
        """Find the real sysent table base.

        Strategy:
        1. Find any DATA entry whose decoded pointer == _nosys.
        2. Scan backward in 24-byte steps to find the true table start
           (entry 0 is the indirect syscall handler, NOT _nosys).
        3. Validate each backward entry: sy_call decodes to a code range
           AND the metadata fields (narg, arg_bytes) look reasonable.

        Previous bug: the old code took the first _nosys match as entry 0,
        but _nosys first appears at entry ~428 (varies by XNU build).
        """
        nosys_entry = -1
        seg_start = -1
        for seg_name, _, fileoff, filesize, _ in self.all_segments:
            if "DATA" not in seg_name:
                continue
            for off in range(fileoff, fileoff + filesize - _SYSENT_ENTRY_SIZE, 8):
                val = _rd64(self.raw, off)
                decoded = self._decode_chained_ptr(val)
                if decoded == nosys_off:
                    val2 = _rd64(self.raw, off + _SYSENT_ENTRY_SIZE)
                    decoded2 = self._decode_chained_ptr(val2)
                    if decoded2 > 0 and any(
                        s <= decoded2 < e for s, e in self.code_ranges
                    ):
                        nosys_entry = off
                        seg_start = fileoff
                        break
            if nosys_entry >= 0:
                break

        if nosys_entry < 0:
            return -1

        self._log(
            f"  [*] _nosys entry found at foff 0x{nosys_entry:X}, "
            f"scanning backward for table start"
        )

        base = nosys_entry
        entries_back = 0
        while base - _SYSENT_ENTRY_SIZE >= seg_start:
            if entries_back >= _SYSENT_MAX_ENTRIES:
                break
            prev = base - _SYSENT_ENTRY_SIZE
            val = _rd64(self.raw, prev)
            decoded = self._decode_chained_ptr(val)
            if decoded <= 0 or not any(s <= decoded < e for s, e in self.code_ranges):
                break
            narg = struct.unpack_from("<H", self.raw, prev + 20)[0]
            arg_bytes = struct.unpack_from("<H", self.raw, prev + 22)[0]
            if narg > 12 or arg_bytes > 96:
                break
            base = prev
            entries_back += 1

        self._log(
            f"  [+] sysent table base at foff 0x{base:X} "
            f"({entries_back} entries before first _nosys)"
        )
        return base

    def _encode_chained_auth_ptr(self, target_foff, next_val, diversity=0, key=0, addr_div=0):
        """Encode an arm64e kernel cache auth rebase chained fixup pointer."""
        val = (
            (target_foff & 0x3FFFFFFF)
            | ((diversity & 0xFFFF) << 32)
            | ((addr_div & 1) << 48)
            | ((key & 3) << 49)
            | ((next_val & 0xFFF) << 51)
            | (1 << 63)
        )
        return struct.pack("<Q", val)

    def _extract_chain_next(self, raw_val):
        return (raw_val >> 51) & 0xFFF

    def _extract_chain_diversity(self, raw_val):
        return (raw_val >> 32) & 0xFFFF

    def _extract_chain_addr_div(self, raw_val):
        return (raw_val >> 48) & 1

    def _extract_chain_key(self, raw_val):
        return (raw_val >> 49) & 3

    def _find_munge32_for_narg(self, sysent_off, narg, arg_bytes):
        """Find a reusable 32-bit munger entry with matching metadata.

        Returns `(target_foff, exemplar_entry, match_count)` or `(-1, -1, 0)`.
        Requires a unique decoded helper target across all matching sysent rows.
        """
        candidates = {}
        for idx in range(_SYSENT_MAX_ENTRIES):
            entry = sysent_off + idx * _SYSENT_ENTRY_SIZE
            cur_narg = struct.unpack_from("<H", self.raw, entry + 20)[0]
            cur_arg_bytes = struct.unpack_from("<H", self.raw, entry + 22)[0]
            if cur_narg != narg or cur_arg_bytes != arg_bytes:
                continue
            raw_munge = _rd64(self.raw, entry + 8)
            target = self._decode_chained_ptr(raw_munge)
            if target <= 0:
                continue
            bucket = candidates.setdefault(target, [])
            bucket.append(entry)

        if not candidates:
            return -1, -1, 0
        if len(candidates) != 1:
            self._log(
                "  [-] multiple distinct 8-arg munge32 helpers found: "
                + ", ".join(f"0x{target:X}" for target in sorted(candidates))
            )
            return -1, -1, 0

        target, entries = next(iter(candidates.items()))
        return target, entries[0], len(entries)

    def _build_kcall10_cave(self):
        """Build an ABI-correct kcall cave.

        Contract:
          x0 = proc*
          x1 = &uthread->uu_arg[0]
          x2 = &uthread->uu_rval[0]

        uap layout (8 qwords):
          [0] target function pointer
          [1] arg0
          [2] arg1
          [3] arg2
          [4] arg3
          [5] arg4
          [6] arg5
          [7] arg6

        Behavior:
          - validates uap / retval / target are non-null
          - invokes target(arg0..arg6, x7=0)
          - stores 64-bit X0 into retval for `_SYSCALL_RET_UINT64_T`
          - returns 0 on success or EINVAL on malformed request
        """
        code = []
        code.append(struct.pack("<I", _PACIBSP_U32))
        code.append(asm("sub sp, sp, #0x30"))
        code.append(asm("stp x21, x22, [sp]"))
        code.append(asm("stp x19, x20, [sp, #0x10]"))
        code.append(asm("stp x29, x30, [sp, #0x20]"))
        code.append(asm("add x29, sp, #0x20"))
        code.append(asm(f"mov w19, #{_KCALL10_EINVAL}"))
        code.append(asm("mov x20, x1"))
        code.append(asm("mov x21, x2"))
        code.append(asm("cbz x20, #0x30"))
        code.append(asm("cbz x21, #0x2c"))
        code.append(asm("ldr x16, [x20]"))
        code.append(asm("cbz x16, #0x24"))
        code.append(asm("ldp x0, x1, [x20, #0x8]"))
        code.append(asm("ldp x2, x3, [x20, #0x18]"))
        code.append(asm("ldp x4, x5, [x20, #0x28]"))
        code.append(asm("ldr x6, [x20, #0x38]"))
        code.append(asm("mov x7, xzr"))
        code.append(asm("blr x16"))
        code.append(asm("str x0, [x21]"))
        code.append(asm("mov w19, #0"))
        code.append(asm("mov w0, w19"))
        code.append(asm("ldp x21, x22, [sp]"))
        code.append(asm("ldp x19, x20, [sp, #0x10]"))
        code.append(asm("ldp x29, x30, [sp, #0x20]"))
        code.append(asm("add sp, sp, #0x30"))
        code.append(struct.pack("<I", _RETAB_U32))
        return b"".join(code)

    def patch_kcall10(self):
        """Rebuilt ABI-correct kcall patch for syscall 439.

        The historical `kcall10` idea cannot be implemented as a literal
        10-argument Unix syscall on arm64 XNU. The rebuilt variant instead
        repoints `SYS_kas_info` to a cave that consumes the real syscall ABI:

          uap[0] = target
          uap[1..7] = arg0..arg6

        It returns the 64-bit X0 result via `retval` and
        `_SYSCALL_RET_UINT64_T`.
        """
        self._log("\n[JB] kcall10: ABI-correct sysent[439] cave")

        nosys_off = self._resolve_symbol("_nosys")
        if nosys_off < 0:
            nosys_off = self._find_nosys()
        if nosys_off < 0:
            self._log("  [-] _nosys not found")
            return False

        sysent_off = self._find_sysent_table(nosys_off)
        if sysent_off < 0:
            self._log("  [-] sysent table not found")
            return False

        entry_439 = sysent_off + 439 * _SYSENT_ENTRY_SIZE

        munger_target, exemplar_entry, match_count = self._find_munge32_for_narg(
            sysent_off, _KCALL10_NARG, _KCALL10_ARG_BYTES_32
        )
        if munger_target < 0:
            self._log("  [-] no unique reusable 8-arg munge32 helper found")
            return False

        cave_bytes = self._build_kcall10_cave()
        cave_off = self._find_code_cave(len(cave_bytes))
        if cave_off < 0:
            self._log("  [-] no executable code cave found for kcall10")
            return False

        old_sy_call_raw = _rd64(self.raw, entry_439)
        call_next = self._extract_chain_next(old_sy_call_raw)

        old_munge_raw = _rd64(self.raw, entry_439 + 8)
        munge_next = self._extract_chain_next(old_munge_raw)
        munge_div = self._extract_chain_diversity(old_munge_raw)
        munge_addr_div = self._extract_chain_addr_div(old_munge_raw)
        munge_key = self._extract_chain_key(old_munge_raw)

        self._log(f"  [+] sysent table at file offset 0x{sysent_off:X}")
        self._log(f"  [+] sysent[439] entry at 0x{entry_439:X}")
        self._log(
            f"  [+] reusing unique 8-arg munge32 target 0x{munger_target:X} "
            f"from exemplar entry 0x{exemplar_entry:X} ({match_count} matching sysent rows)"
        )
        self._log(f"  [+] cave at 0x{cave_off:X} ({len(cave_bytes):#x} bytes)")

        self.emit(
            cave_off,
            cave_bytes,
            "kcall10 ABI-correct cave (target + 7 args -> uint64 x0)",
        )
        self.emit(
            entry_439,
            self._encode_chained_auth_ptr(
                cave_off,
                next_val=call_next,
                diversity=_SYSENT_PAC_DIVERSITY,
                key=0,
                addr_div=0,
            ),
            f"sysent[439].sy_call = cave 0x{cave_off:X} (auth rebase, div=0xBCAD, next={call_next}) [kcall10]",
        )
        self.emit(
            entry_439 + 8,
            self._encode_chained_auth_ptr(
                munger_target,
                next_val=munge_next,
                diversity=munge_div,
                key=munge_key,
                addr_div=munge_addr_div,
            ),
            f"sysent[439].sy_arg_munge32 = 8-arg helper 0x{munger_target:X} [kcall10]",
        )
        self.emit(
            entry_439 + 16,
            struct.pack("<IHH", _KCALL10_RETURN_TYPE, _KCALL10_NARG, _KCALL10_ARG_BYTES_32),
            "sysent[439].sy_return_type=7,sy_narg=8,sy_arg_bytes=0x20 [kcall10]",
        )
        return True

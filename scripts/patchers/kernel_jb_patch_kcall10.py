"""Mixin: KernelJBPatchKcall10Mixin."""

from .kernel_jb_base import asm, _rd32, _rd64, RET, NOP, struct

# Max sysent entries in XNU (dispatch clamps at 0x22E = 558).
_SYSENT_MAX_ENTRIES = 558
# Each sysent entry is 24 bytes.
_SYSENT_ENTRY_SIZE = 24
# PAC discriminator used by the syscall dispatch (MOV X17, #0xBCAD; BLRAA X8, X17).
_SYSENT_PAC_DIVERSITY = 0xBCAD


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
        # Step 1: find any _nosys-matching entry
        nosys_entry = -1
        seg_start = -1
        for seg_name, vmaddr, fileoff, filesize, _ in self.all_segments:
            if "DATA" not in seg_name:
                continue
            for off in range(fileoff, fileoff + filesize - _SYSENT_ENTRY_SIZE, 8):
                val = _rd64(self.raw, off)
                decoded = self._decode_chained_ptr(val)
                if decoded == nosys_off:
                    # Verify: next entry should also have valid sy_call
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

        # Step 2: scan backward to find entry 0
        base = nosys_entry
        entries_back = 0
        while base - _SYSENT_ENTRY_SIZE >= seg_start:
            if entries_back >= _SYSENT_MAX_ENTRIES:
                break
            prev = base - _SYSENT_ENTRY_SIZE
            # Check sy_call decodes to valid code
            val = _rd64(self.raw, prev)
            decoded = self._decode_chained_ptr(val)
            if decoded <= 0 or not any(
                s <= decoded < e for s, e in self.code_ranges
            ):
                break
            # Check metadata looks like a sysent entry
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

    def _encode_chained_auth_ptr(self, target_foff, next_val, diversity=0,
                                  key=0, addr_div=0):
        """Encode an arm64e kernel cache auth rebase chained fixup pointer.

        Layout (DYLD_CHAINED_PTR_64_KERNEL_CACHE):
          bits[29:0]:  target (file offset)
          bits[31:30]: cacheLevel (0)
          bits[47:32]: diversity (16 bits)
          bit[48]:     addrDiv
          bits[50:49]: key (0=IA, 1=IB, 2=DA, 3=DB)
          bits[62:51]: next (12 bits, 4-byte stride delta to next fixup)
          bit[63]:     isAuth (1)
        """
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
        """Extract the 'next' chain field from a raw chained fixup pointer."""
        return (raw_val >> 51) & 0xFFF

    def patch_kcall10(self):
        """Replace SYS_kas_info (syscall 439) with kcall10 shellcode.

        Anchor: find _nosys function by pattern, then search DATA segments
        for the sysent table base (backward scan from first _nosys entry).

        The sysent dispatch uses BLRAA X8, X17 with X17=0xBCAD, so all
        sy_call pointers must be PAC-signed with key=IA, diversity=0xBCAD,
        addrDiv=0.  We encode the cave pointer as a proper auth rebase
        chained fixup entry to match.
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

        # Find sysent table (real base via backward scan)
        sysent_off = self._find_sysent_table(nosys_off)
        if sysent_off < 0:
            self._log("  [-] sysent table not found")
            return False

        self._log(f"  [+] sysent table at file offset 0x{sysent_off:X}")

        # Entry 439 (SYS_kas_info)
        entry_439 = sysent_off + 439 * _SYSENT_ENTRY_SIZE

        # Find code cave for kcall10 shellcode (~128 bytes = 32 instructions)
        cave = self._find_code_cave(128)
        if cave < 0:
            self._log("  [-] no code cave found")
            return False

        # Build kcall10 shellcode
        # Syscall args arrive via the saved state on the stack.
        # arg[0] = pointer to a userspace buffer with {func_ptr, arg0..arg9}.
        # We unpack, call func_ptr(arg0..arg9), write results back.
        parts = [
            asm("ldr x10, [sp, #0x40]"),         # 0
            asm("ldp x0, x1, [x10, #0]"),        # 1
            asm("ldp x2, x3, [x10, #0x10]"),     # 2
            asm("ldp x4, x5, [x10, #0x20]"),     # 3
            asm("ldp x6, x7, [x10, #0x30]"),     # 4
            asm("ldp x8, x9, [x10, #0x40]"),     # 5
            asm("ldr x10, [x10, #0x50]"),         # 6
            asm("mov x16, x0"),                   # 7
            asm("mov x0, x1"),                    # 8
            asm("mov x1, x2"),                    # 9
            asm("mov x2, x3"),                    # 10
            asm("mov x3, x4"),                    # 11
            asm("mov x4, x5"),                    # 12
            asm("mov x5, x6"),                    # 13
            asm("mov x6, x7"),                    # 14
            asm("mov x7, x8"),                    # 15
            asm("mov x8, x9"),                    # 16
            asm("mov x9, x10"),                   # 17
            asm("stp x29, x30, [sp, #-0x10]!"),  # 18
            bytes([0x00, 0x02, 0x3F, 0xD6]),      # 19: BLR x16
            asm("ldp x29, x30, [sp], #0x10"),     # 20
            asm("ldr x11, [sp, #0x40]"),          # 21
            NOP,                                   # 22
            asm("stp x0, x1, [x11, #0]"),         # 23
            asm("stp x2, x3, [x11, #0x10]"),      # 24
            asm("stp x4, x5, [x11, #0x20]"),      # 25
            asm("stp x6, x7, [x11, #0x30]"),      # 26
            asm("stp x8, x9, [x11, #0x40]"),      # 27
            asm("str x10, [x11, #0x50]"),          # 28
            asm("mov x0, #0"),                     # 29
            asm("ret"),                             # 30
            NOP,                                    # 31
        ]

        for i, part in enumerate(parts):
            self.emit(cave + i * 4, part, f"shellcode+{i * 4} [kcall10]")

        # ── Patch sysent[439] with proper chained fixup encoding ────────
        #
        # The old code wrote raw VAs (struct.pack("<Q", cave_va)) which
        # breaks the chained fixup chain and produces invalid PAC-signed
        # pointers.  We now encode as auth rebase pointers matching the
        # dispatch's BLRAA X8, X17 (X17=0xBCAD).

        # Read original raw value to preserve the chain 'next' field
        old_sy_call_raw = _rd64(self.raw, entry_439)
        call_next = self._extract_chain_next(old_sy_call_raw)

        self.emit(
            entry_439,
            self._encode_chained_auth_ptr(
                cave,
                next_val=call_next,
                diversity=_SYSENT_PAC_DIVERSITY,
                key=0,       # IA
                addr_div=0,  # fixed discriminator (not address-blended)
            ),
            f"sysent[439].sy_call = cave 0x{cave:X} "
            f"(auth rebase, div=0xBCAD, next={call_next}) [kcall10]",
        )

        if munge_off >= 0:
            old_sy_munge_raw = _rd64(self.raw, entry_439 + 8)
            munge_next = self._extract_chain_next(old_sy_munge_raw)
            self.emit(
                entry_439 + 8,
                self._encode_chained_auth_ptr(
                    munge_off,
                    next_val=munge_next,
                    diversity=_SYSENT_PAC_DIVERSITY,
                    key=0,
                    addr_div=0,
                ),
                f"sysent[439].sy_munge32 = 0x{munge_off:X} "
                f"(auth rebase, next={munge_next}) [kcall10]",
            )

        # sy_return_type = SYSCALL_RET_UINT64_T (7)
        self.emit(
            entry_439 + 16,
            struct.pack("<I", 7),
            "sysent[439].sy_return_type = 7 [kcall10]",
        )

        # sy_narg = 8, sy_arg_bytes = 0x20
        self.emit(
            entry_439 + 20,
            struct.pack("<I", 0x200008),
            "sysent[439].sy_narg=8,sy_arg_bytes=0x20 [kcall10]",
        )

        return True

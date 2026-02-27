#!/usr/bin/env python3
"""
kernel_patcher.py — Dynamic kernel patcher for iOS prelinked kernelcaches.

Finds all patch sites by string anchors, ADRP+ADD cross-references,
BL frequency analysis, and Mach-O structure parsing.  Nothing is hardcoded;
works across kernel variants (vresearch101, vphone600, etc.).

Dependencies:  keystone-engine, capstone
"""

import struct, plistlib
from collections import defaultdict
from keystone import Ks, KS_ARCH_ARM64, KS_MODE_LITTLE_ENDIAN as KS_MODE_LE
from capstone import Cs, CS_ARCH_ARM64, CS_MODE_ARM
from capstone.arm64_const import (ARM64_OP_REG, ARM64_OP_IMM,
                                  ARM64_REG_W0, ARM64_REG_X0, ARM64_REG_X8)

# ── Assembly / disassembly helpers ───────────────────────────────
_ks = Ks(KS_ARCH_ARM64, KS_MODE_LE)
_cs = Cs(CS_ARCH_ARM64, CS_MODE_ARM)
_cs.detail = True


def asm(s):
    enc, _ = _ks.asm(s)
    if not enc:
        raise RuntimeError(f"asm failed: {s}")
    return bytes(enc)


NOP       = asm("nop")
MOV_X0_0  = asm("mov x0, #0")
MOV_X0_1  = asm("mov x0, #1")
MOV_W0_0  = asm("mov w0, #0")
MOV_W0_1  = asm("mov w0, #1")
RET       = asm("ret")
CMP_W0_W0 = asm("cmp w0, w0")
CMP_X0_X0 = asm("cmp x0, x0")


def _asm_u32(s):
    """Assemble a single instruction and return its uint32 encoding."""
    return struct.unpack("<I", asm(s))[0]


def _verify_disas(u32_val, expected_mnemonic):
    """Verify a uint32 encoding disassembles to expected mnemonic via capstone."""
    code = struct.pack("<I", u32_val)
    insns = list(_cs.disasm(code, 0, 1))
    assert insns and insns[0].mnemonic == expected_mnemonic, \
        f"0x{u32_val:08X} disassembles to {insns[0].mnemonic if insns else '???'}, expected {expected_mnemonic}"
    return u32_val


# Named instruction constants (via keystone where possible, capstone-verified otherwise)
_PACIBSP_U32 = _asm_u32("hint #27")     # keystone doesn't know 'pacibsp'
_RET_U32     = _asm_u32("ret")
_RETAA_U32   = _verify_disas(0xD65F0BFF, "retaa")   # keystone can't assemble PAC returns
_RETAB_U32   = _verify_disas(0xD65F0FFF, "retab")   # verified via capstone disassembly
_FUNC_BOUNDARY_U32S = frozenset((_RET_U32, _RETAA_U32, _RETAB_U32, _PACIBSP_U32))


def _rd32(buf, off):
    return struct.unpack_from("<I", buf, off)[0]


def _rd64(buf, off):
    return struct.unpack_from("<Q", buf, off)[0]


# ── KernelPatcher ────────────────────────────────────────────────

class KernelPatcher:
    """Dynamic kernel patcher — all offsets found at runtime."""

    def __init__(self, data, verbose=True):
        self.data    = data            # bytearray (mutable)
        self.raw     = bytes(data)     # immutable snapshot for searching
        self.size    = len(data)
        self.patches = []              # collected (offset, bytes, description)
        self.verbose = verbose

        self._log("[*] Parsing Mach-O segments …")
        self._parse_macho()

        self._log("[*] Discovering kext code ranges from __PRELINK_INFO …")
        self._discover_kext_ranges()

        self._log("[*] Building ADRP index …")
        self._build_adrp_index()

        self._log("[*] Building BL index …")
        self._build_bl_index()

        self._find_panic()
        self._log(f"[*] _panic at foff 0x{self.panic_off:X}  "
                  f"({len(self.bl_callers[self.panic_off])} callers)")

    # ── Logging ──────────────────────────────────────────────────
    def _log(self, msg):
        if self.verbose:
            print(msg)

    # ── Mach-O / segment parsing ─────────────────────────────────
    def _parse_macho(self):
        """Parse top-level Mach-O: discover BASE_VA, segments, code ranges."""
        magic = _rd32(self.raw, 0)
        if magic != 0xFEEDFACF:
            raise ValueError(f"Not a 64-bit Mach-O (magic 0x{magic:08X})")

        self.code_ranges  = []   # [(start_foff, end_foff), ...]
        self.all_segments = []   # [(name, vmaddr, fileoff, filesize, initprot)]
        self.base_va      = None

        ncmds = struct.unpack_from("<I", self.raw, 16)[0]
        off = 32  # past mach_header_64
        for _ in range(ncmds):
            cmd, cmdsize = struct.unpack_from("<II", self.raw, off)
            if cmd == 0x19:  # LC_SEGMENT_64
                segname = self.raw[off+8:off+24].split(b'\x00')[0].decode()
                vmaddr, vmsize, fileoff, filesize = struct.unpack_from(
                    "<QQQQ", self.raw, off + 24)
                initprot = struct.unpack_from("<I", self.raw, off + 60)[0]
                self.all_segments.append(
                    (segname, vmaddr, fileoff, filesize, initprot))
                if segname == "__TEXT":
                    self.base_va = vmaddr
                CODE_SEGS = ("__PRELINK_TEXT", "__TEXT_EXEC", "__TEXT_BOOT_EXEC")
                if segname in CODE_SEGS and filesize > 0:
                    self.code_ranges.append((fileoff, fileoff + filesize))
            off += cmdsize

        if self.base_va is None:
            raise ValueError("__TEXT segment not found — cannot determine BASE_VA")

        self.code_ranges.sort()
        total_mb = sum(e - s for s, e in self.code_ranges) / (1024 * 1024)
        self._log(f"  BASE_VA = 0x{self.base_va:016X}")
        self._log(f"  {len(self.code_ranges)} executable ranges, total {total_mb:.1f} MB")

    def _va(self, foff):
        return self.base_va + foff

    def _foff(self, va):
        return va - self.base_va

    # ── Kext range discovery ─────────────────────────────────────
    def _discover_kext_ranges(self):
        """Parse __PRELINK_INFO + embedded kext Mach-Os to find code section ranges."""
        self.kext_ranges = {}   # bundle_id -> (text_start, text_end)

        # Find __PRELINK_INFO segment
        prelink_info = None
        for name, vmaddr, fileoff, filesize, _ in self.all_segments:
            if name == "__PRELINK_INFO":
                prelink_info = (fileoff, filesize)
                break

        if prelink_info is None:
            self._log("  [-] __PRELINK_INFO not found, using __TEXT_EXEC for all")
            self._set_fallback_ranges()
            return

        foff, fsize = prelink_info
        pdata = self.raw[foff:foff + fsize]

        # Parse the XML plist
        xml_start = pdata.find(b"<?xml")
        xml_end = pdata.find(b"</plist>")
        if xml_start < 0 or xml_end < 0:
            self._log("  [-] __PRELINK_INFO plist not found")
            self._set_fallback_ranges()
            return

        xml = pdata[xml_start:xml_end + len(b"</plist>")]
        pl = plistlib.loads(xml)
        items = pl.get("_PrelinkInfoDictionary", [])

        # Kexts we need ranges for
        WANTED = {
            "com.apple.filesystems.apfs": "apfs",
            "com.apple.security.sandbox": "sandbox",
            "com.apple.driver.AppleMobileFileIntegrity": "amfi",
        }

        for item in items:
            bid = item.get("CFBundleIdentifier", "")
            tag = WANTED.get(bid)
            if tag is None:
                continue

            exec_addr = item.get("_PrelinkExecutableLoadAddr", 0) & 0xFFFFFFFFFFFFFFFF
            kext_foff = exec_addr - self.base_va
            if kext_foff < 0 or kext_foff >= self.size:
                continue

            # Parse this kext's embedded Mach-O to find __TEXT_EXEC.__text
            text_range = self._parse_kext_text_exec(kext_foff)
            if text_range:
                self.kext_ranges[tag] = text_range
                self._log(f"  {tag:10s} __text: 0x{text_range[0]:08X} - 0x{text_range[1]:08X} "
                          f"({(text_range[1]-text_range[0])//1024} KB)")

        # Derive the ranges used by patch methods
        self._set_ranges_from_kexts()

    def _parse_kext_text_exec(self, kext_foff):
        """Parse an embedded kext Mach-O header and return (__text start, end) in file offsets."""
        if kext_foff + 32 > self.size:
            return None
        magic = _rd32(self.raw, kext_foff)
        if magic != 0xFEEDFACF:
            return None

        ncmds = struct.unpack_from("<I", self.raw, kext_foff + 16)[0]
        off = kext_foff + 32
        for _ in range(ncmds):
            if off + 8 > self.size:
                break
            cmd, cmdsize = struct.unpack_from("<II", self.raw, off)
            if cmd == 0x19:  # LC_SEGMENT_64
                segname = self.raw[off+8:off+24].split(b'\x00')[0].decode()
                if segname == "__TEXT_EXEC":
                    vmaddr = struct.unpack_from("<Q", self.raw, off + 24)[0]
                    filesize = struct.unpack_from("<Q", self.raw, off + 48)[0]
                    nsects = struct.unpack_from("<I", self.raw, off + 64)[0]
                    # Parse sections to find __text
                    sect_off = off + 72
                    for _ in range(nsects):
                        if sect_off + 80 > self.size:
                            break
                        sectname = self.raw[sect_off:sect_off+16].split(b'\x00')[0].decode()
                        if sectname == "__text":
                            sect_addr = struct.unpack_from("<Q", self.raw, sect_off + 32)[0]
                            sect_size = struct.unpack_from("<Q", self.raw, sect_off + 40)[0]
                            sect_foff = sect_addr - self.base_va
                            return (sect_foff, sect_foff + sect_size)
                        sect_off += 80
                    # No __text section found, use the segment
                    seg_foff = vmaddr - self.base_va
                    return (seg_foff, seg_foff + filesize)
            off += cmdsize
        return None

    def _set_ranges_from_kexts(self):
        """Set patch-method ranges from discovered kext info, with fallbacks."""
        # Full __TEXT_EXEC range
        text_exec = None
        for name, vmaddr, fileoff, filesize, _ in self.all_segments:
            if name == "__TEXT_EXEC":
                text_exec = (fileoff, fileoff + filesize)
                break

        if text_exec is None:
            text_exec = (0, self.size)

        self.text_exec_range = text_exec
        self.apfs_text    = self.kext_ranges.get("apfs",    text_exec)
        self.amfi_text    = self.kext_ranges.get("amfi",    text_exec)
        self.sandbox_text = self.kext_ranges.get("sandbox", text_exec)
        # Kernel code = full __TEXT_EXEC (includes all kexts, but that's OK)
        self.kern_text    = text_exec

    def _set_fallback_ranges(self):
        """Use __TEXT_EXEC for everything when __PRELINK_INFO is unavailable."""
        text_exec = None
        for name, vmaddr, fileoff, filesize, _ in self.all_segments:
            if name == "__TEXT_EXEC":
                text_exec = (fileoff, fileoff + filesize)
                break
        if text_exec is None:
            text_exec = (0, self.size)

        self.text_exec_range = text_exec
        self.apfs_text    = text_exec
        self.amfi_text    = text_exec
        self.sandbox_text = text_exec
        self.kern_text    = text_exec

    # ── Index builders ───────────────────────────────────────────
    def _build_adrp_index(self):
        """Index ADRP instructions by target page for O(1) string-ref lookup."""
        self.adrp_by_page = defaultdict(list)
        for rng_start, rng_end in self.code_ranges:
            for off in range(rng_start, rng_end, 4):
                insn = _rd32(self.raw, off)
                if (insn & 0x9F000000) != 0x90000000:
                    continue
                rd    = insn & 0x1F
                immhi = (insn >> 5)  & 0x7FFFF
                immlo = (insn >> 29) & 0x3
                imm   = (immhi << 2) | immlo
                if imm & (1 << 20):
                    imm -= (1 << 21)
                pc   = self._va(off)
                page = (pc & ~0xFFF) + (imm << 12)
                self.adrp_by_page[page].append((off, rd))

        n = sum(len(v) for v in self.adrp_by_page.values())
        self._log(f"  {n} ADRP entries, {len(self.adrp_by_page)} distinct pages")

    def _build_bl_index(self):
        """Index BL instructions by target offset."""
        self.bl_callers = defaultdict(list)  # target_off -> [caller_off, ...]
        for rng_start, rng_end in self.code_ranges:
            for off in range(rng_start, rng_end, 4):
                insn = _rd32(self.raw, off)
                if (insn & 0xFC000000) != 0x94000000:
                    continue
                imm26 = insn & 0x3FFFFFF
                if imm26 & (1 << 25):
                    imm26 -= (1 << 26)
                target = off + imm26 * 4
                self.bl_callers[target].append(off)

    def _find_panic(self):
        """Find _panic: most-called function whose callers reference '@%s:%d' strings."""
        candidates = sorted(self.bl_callers.items(), key=lambda x: -len(x[1]))[:15]
        for target_off, callers in candidates:
            if len(callers) < 2000:
                break
            confirmed = 0
            for caller_off in callers[:30]:
                for back in range(caller_off - 4, max(caller_off - 32, 0), -4):
                    insn = _rd32(self.raw, back)
                    # ADD x0, x0, #imm
                    if (insn & 0xFFC003E0) == 0x91000000:
                        add_imm = (insn >> 10) & 0xFFF
                        if back >= 4:
                            prev = _rd32(self.raw, back - 4)
                            if (prev & 0x9F00001F) == 0x90000000:  # ADRP x0
                                immhi = (prev >> 5) & 0x7FFFF
                                immlo = (prev >> 29) & 0x3
                                imm = (immhi << 2) | immlo
                                if imm & (1 << 20):
                                    imm -= (1 << 21)
                                pc   = self._va(back - 4)
                                page = (pc & ~0xFFF) + (imm << 12)
                                str_foff = self._foff(page + add_imm)
                                if 0 <= str_foff < self.size - 10:
                                    snippet = self.raw[str_foff:str_foff + 60]
                                    if b"@%s:%d" in snippet or b"%s:%d" in snippet:
                                        confirmed += 1
                                        break
                        break
            if confirmed >= 3:
                self.panic_off = target_off
                return
        self.panic_off = candidates[2][0] if len(candidates) > 2 else candidates[0][0]

    # ── Helpers ──────────────────────────────────────────────────
    def _disas_at(self, off, count=1):
        """Disassemble *count* instructions at file offset.  Returns a list."""
        end = min(off + count * 4, self.size)
        if off < 0 or off >= self.size:
            return []
        code = bytes(self.raw[off:end])
        return list(_cs.disasm(code, off, count))

    def _is_bl(self, off):
        """Return BL target file offset, or -1 if not a BL."""
        insns = self._disas_at(off)
        if insns and insns[0].mnemonic == "bl":
            return insns[0].operands[0].imm
        return -1

    def _is_cond_branch_w0(self, off):
        """Return True if instruction is a conditional branch on w0 (cbz/cbnz/tbz/tbnz)."""
        insns = self._disas_at(off)
        if not insns:
            return False
        i = insns[0]
        if i.mnemonic in ("cbz", "cbnz", "tbz", "tbnz"):
            return i.operands[0].type == ARM64_OP_REG and i.operands[0].reg == ARM64_REG_W0
        return False

    def find_string(self, s, start=0):
        """Find string, return file offset of the enclosing C string start."""
        if isinstance(s, str):
            s = s.encode()
        off = self.raw.find(s, start)
        if off < 0:
            return -1
        # Walk backward to the preceding NUL — that's the C string start
        cstr = off
        while cstr > 0 and self.raw[cstr - 1] != 0:
            cstr -= 1
        return cstr

    def find_string_refs(self, str_off, code_start=None, code_end=None):
        """Find all (adrp_off, add_off, dest_reg) referencing str_off via ADRP+ADD."""
        target_va   = self._va(str_off)
        target_page = target_va & ~0xFFF
        page_off    = target_va & 0xFFF

        refs = []
        for adrp_off, rd in self.adrp_by_page.get(target_page, []):
            if code_start is not None and adrp_off < code_start:
                continue
            if code_end is not None and adrp_off >= code_end:
                continue
            if adrp_off + 4 >= self.size:
                continue
            nxt = _rd32(self.raw, adrp_off + 4)
            # ADD (imm) 64-bit: 1001_0001_00_imm12_Rn_Rd
            if (nxt & 0xFFC00000) != 0x91000000:
                continue
            add_rn  = (nxt >> 5)  & 0x1F
            add_imm = (nxt >> 10) & 0xFFF
            if add_rn == rd and add_imm == page_off:
                add_rd = nxt & 0x1F
                refs.append((adrp_off, adrp_off + 4, add_rd))
        return refs

    def find_function_start(self, off, max_back=0x4000):
        """Walk backwards to find PACIBSP or STP x29,x30,[sp,#imm].

        When STP x29,x30 is found, continues backward up to 0x20 more
        bytes to look for PACIBSP (ARM64e functions may have several STP
        instructions in the prologue before STP x29,x30).
        """
        for o in range(off - 4, max(off - max_back, 0), -4):
            insn = _rd32(self.raw, o)
            if insn == _PACIBSP_U32:
                return o
            dis = self._disas_at(o)
            if dis and dis[0].mnemonic == "stp" and "x29, x30, [sp" in dis[0].op_str:
                # Check further back for PACIBSP (prologue may have
                # multiple STP instructions before x29,x30)
                for k in range(o - 4, max(o - 0x24, 0), -4):
                    if _rd32(self.raw, k) == _PACIBSP_U32:
                        return k
                return o
        return -1

    def _disas_n(self, buf, off, count):
        """Disassemble *count* instructions from *buf* at file offset *off*."""
        end = min(off + count * 4, len(buf))
        if off < 0 or off >= len(buf):
            return []
        code = bytes(buf[off:end])
        return list(_cs.disasm(code, off, count))

    def _fmt_insn(self, insn, marker=""):
        """Format one capstone instruction for display."""
        raw = insn.bytes
        hex_str = " ".join(f"{b:02x}" for b in raw)
        s = f"  0x{insn.address:08X}: {hex_str:12s}  {insn.mnemonic:8s} {insn.op_str}"
        if marker:
            s += f"  {marker}"
        return s

    def _print_patch_context(self, off, patch_bytes, desc):
        """Print disassembly before/after a patch site for debugging."""
        ctx = 3  # instructions of context before and after
        # -- BEFORE (original bytes) --
        lines = [f"  ┌─ PATCH 0x{off:08X}: {desc}"]
        lines.append("  │ BEFORE:")
        start = max(off - ctx * 4, 0)
        before_insns = self._disas_n(self.raw, start, ctx + 1 + ctx)
        for insn in before_insns:
            if insn.address == off:
                lines.append(self._fmt_insn(insn, "  ◄━━ PATCHED"))
            elif off < insn.address < off + len(patch_bytes):
                lines.append(self._fmt_insn(insn, "  ◄━━ PATCHED"))
            else:
                lines.append(self._fmt_insn(insn))

        # -- AFTER (new bytes) --
        lines.append("  │ AFTER:")
        after_insns = self._disas_n(self.raw, start, ctx)
        for insn in after_insns:
            lines.append(self._fmt_insn(insn))
        # Decode the patch bytes themselves
        patch_insns = list(_cs.disasm(patch_bytes, off, len(patch_bytes) // 4))
        for insn in patch_insns:
            lines.append(self._fmt_insn(insn, "  ◄━━ NEW"))
        # Trailing context after the patch
        trail_start = off + len(patch_bytes)
        trail_insns = self._disas_n(self.raw, trail_start, ctx)
        for insn in trail_insns:
            lines.append(self._fmt_insn(insn))
        lines.append(f"  └─")
        self._log("\n".join(lines))

    def emit(self, off, patch_bytes, desc):
        """Record a patch and print before/after disassembly context."""
        self.patches.append((off, patch_bytes, desc))
        if self.verbose:
            self._print_patch_context(off, patch_bytes, desc)

    def _find_by_string_in_range(self, string, code_range, label):
        """Find string, find ADRP+ADD ref in code_range, return ref list."""
        str_off = self.find_string(string)
        if str_off < 0:
            self._log(f"  [-] string not found: {string!r}")
            return []
        refs = self.find_string_refs(str_off, code_range[0], code_range[1])
        if not refs:
            self._log(f"  [-] no code refs to {label} (str at 0x{str_off:X})")
        return refs

    # ── Chained fixup pointer decoding ───────────────────────────
    def _decode_chained_ptr(self, val):
        """Decode an arm64e chained fixup pointer to a file offset.

        - auth rebase (bit63=1):     foff = bits[31:0]
        - non-auth rebase (bit63=0): VA = (bits[50:43] << 56) | bits[42:0]
        """
        if val == 0:
            return -1
        if val & (1 << 63):  # auth rebase
            return val & 0xFFFFFFFF
        else:  # non-auth rebase
            target = val & 0x7FFFFFFFFFF  # bits[42:0]
            high8  = (val >> 43) & 0xFF
            full_va = (high8 << 56) | target
            if full_va > self.base_va:
                return full_va - self.base_va
            return -1

    # ═══════════════════════════════════════════════════════════════
    # Per-patch finders
    # ═══════════════════════════════════════════════════════════════

    def patch_apfs_root_snapshot(self):
        """Patch 1: NOP the tbnz w8,#5 that gates sealed-volume root snapshot panic."""
        self._log("\n[1] _apfs_vfsop_mount: root snapshot sealed volume check")

        refs = self._find_by_string_in_range(
            b"Rooting from snapshot with xid",
            self.apfs_text, "apfs_vfsop_mount log")
        if not refs:
            refs = self._find_by_string_in_range(
                b"Failed to find the root snapshot",
                self.apfs_text, "root snapshot panic")
            if not refs:
                return False

        for adrp_off, add_off, _ in refs:
            for scan in range(add_off, min(add_off + 0x200, self.size), 4):
                insns = self._disas_at(scan)
                if not insns:
                    continue
                i = insns[0]
                if i.mnemonic not in ("tbnz", "tbz"):
                    continue
                # Check: tbz/tbnz w8, #5, ...
                ops = i.operands
                if (len(ops) >= 2
                        and ops[0].type == ARM64_OP_REG
                        and ops[1].type == ARM64_OP_IMM
                        and ops[1].imm == 5):
                    self.emit(scan, NOP,
                              f"NOP {i.mnemonic} {i.op_str} "
                              "(sealed vol check) [_apfs_vfsop_mount]")
                    return True

        self._log("  [-] tbz/tbnz w8,#5 not found near xref")
        return False

    def patch_apfs_seal_broken(self):
        """Patch 2: NOP the conditional branch leading to 'root volume seal is broken' panic."""
        self._log("\n[2] _authapfs_seal_is_broken: seal broken panic")

        str_off = self.find_string(b"root volume seal is broken")
        if str_off < 0:
            self._log("  [-] string not found")
            return False

        refs = self.find_string_refs(str_off, *self.apfs_text)
        if not refs:
            self._log("  [-] no code refs")
            return False

        for adrp_off, add_off, _ in refs:
            # Find BL _panic after string ref
            bl_off = -1
            for scan in range(add_off, min(add_off + 0x40, self.size), 4):
                bl_target = self._is_bl(scan)
                if bl_target == self.panic_off:
                    bl_off = scan
                    break

            if bl_off < 0:
                continue

            # Search backwards for a conditional branch that jumps INTO the
            # panic path.  The error block may set up __FILE__/line args
            # before the string ADRP, so allow target up to 0x40 before it.
            err_lo = adrp_off - 0x40
            for back in range(adrp_off - 4, max(adrp_off - 0x200, 0), -4):
                target, kind = self._decode_branch_target(back)
                if target is not None and err_lo <= target <= bl_off + 4:
                    self.emit(back, NOP,
                              f"NOP {kind} (seal broken) "
                              "[_authapfs_seal_is_broken]")
                    return True

        self._log("  [-] could not find conditional branch to NOP")
        return False

    _COND_BRANCH_MNEMONICS = frozenset((
        "b.eq", "b.ne", "b.cs", "b.hs", "b.cc", "b.lo",
        "b.mi", "b.pl", "b.vs", "b.vc", "b.hi", "b.ls",
        "b.ge", "b.lt", "b.gt", "b.le", "b.al",
        "cbz", "cbnz", "tbz", "tbnz",
    ))

    def _decode_branch_target(self, off):
        """Decode conditional branch at off via capstone. Returns (target, mnemonic) or (None, None)."""
        insns = self._disas_at(off)
        if not insns:
            return None, None
        i = insns[0]
        if i.mnemonic in self._COND_BRANCH_MNEMONICS:
            # Target is always the last IMM operand
            for op in reversed(i.operands):
                if op.type == ARM64_OP_IMM:
                    return op.imm, i.mnemonic
        return None, None

    def patch_bsd_init_rootvp(self):
        """Patch 3: NOP the conditional branch guarding the 'rootvp not authenticated' panic."""
        self._log("\n[3] _bsd_init: rootvp not authenticated panic")

        str_off = self.find_string(b"rootvp not authenticated after mounting")
        if str_off < 0:
            self._log("  [-] string not found")
            return False

        refs = self.find_string_refs(str_off, *self.kern_text)
        if not refs:
            self._log("  [-] no code refs in kernel __text")
            return False

        for adrp_off, add_off, _ in refs:
            # Find the BL _panic after the string ref
            bl_panic_off = -1
            for scan in range(add_off, min(add_off + 0x40, self.size), 4):
                bl_target = self._is_bl(scan)
                if bl_target == self.panic_off:
                    bl_panic_off = scan
                    break

            if bl_panic_off < 0:
                continue

            # Search backwards for a conditional branch whose target is in
            # the error path (the block ending with BL _panic).
            # The error path is typically a few instructions before BL _panic.
            err_lo = bl_panic_off - 0x40   # error block start (generous)
            err_hi = bl_panic_off + 4      # error block end

            for back in range(adrp_off - 4, max(adrp_off - 0x400, 0), -4):
                target, kind = self._decode_branch_target(back)
                if target is not None and err_lo <= target <= err_hi:
                    self.emit(back, NOP,
                              f"NOP {kind} (rootvp auth) [_bsd_init]")
                    return True

        self._log("  [-] conditional branch into panic path not found")
        return False

    def patch_proc_check_launch_constraints(self):
        """Patches 4-5: mov w0,#0; ret at _proc_check_launch_constraints start.

        The AMFI function does NOT reference the symbol name string
        '_proc_check_launch_constraints' — only the kernel wrapper does.
        Instead, use 'AMFI: Validation Category info' which IS referenced
        from the actual AMFI function.
        """
        self._log("\n[4-5] _proc_check_launch_constraints: stub with mov w0,#0; ret")

        str_off = self.find_string(b"AMFI: Validation Category info")
        if str_off < 0:
            self._log("  [-] 'AMFI: Validation Category info' string not found")
            return False

        refs = self.find_string_refs(str_off, *self.amfi_text)
        if not refs:
            self._log("  [-] no code refs in AMFI")
            return False

        for adrp_off, add_off, _ in refs:
            func_start = self.find_function_start(adrp_off)
            if func_start < 0:
                continue
            self.emit(func_start, MOV_W0_0,
                      "mov w0,#0 [_proc_check_launch_constraints]")
            self.emit(func_start + 4, RET,
                      "ret [_proc_check_launch_constraints]")
            return True

        self._log("  [-] function start not found")
        return False

    def _get_kernel_text_range(self):
        """Return (start, end) file offsets of the kernel's own __TEXT_EXEC.__text.

        Parses fileset entries (LC_FILESET_ENTRY) to find the kernel component,
        then reads its Mach-O header to get the __TEXT_EXEC.__text section.
        Falls back to the full __TEXT_EXEC segment.
        """
        # Try fileset entries
        ncmds = struct.unpack_from("<I", self.raw, 16)[0]
        off = 32
        for _ in range(ncmds):
            cmd, cmdsize = struct.unpack_from("<II", self.raw, off)
            if cmd == 0x80000035:  # LC_FILESET_ENTRY
                vmaddr = struct.unpack_from("<Q", self.raw, off + 8)[0]
                str_off_in_cmd = struct.unpack_from("<I", self.raw, off + 24)[0]
                entry_id = self.raw[off + str_off_in_cmd:].split(b'\x00')[0].decode()
                if entry_id == "com.apple.kernel":
                    kext_foff = vmaddr - self.base_va
                    text_range = self._parse_kext_text_exec(kext_foff)
                    if text_range:
                        return text_range
            off += cmdsize
        return self.kern_text

    @staticmethod
    def _is_func_boundary(insn):
        """Return True if *insn* typically ends/starts a function."""
        return insn in _FUNC_BOUNDARY_U32S

    def patch_PE_i_can_has_debugger(self):
        """Patches 6-7: mov x0,#1; ret at _PE_i_can_has_debugger."""
        self._log("\n[6-7] _PE_i_can_has_debugger: stub with mov x0,#1; ret")

        # Strategy 1: find symbol name in __LINKEDIT and parse nearby VA
        str_off = self.find_string(b"\x00_PE_i_can_has_debugger\x00")
        if str_off < 0:
            str_off = self.find_string(b"PE_i_can_has_debugger")
        if str_off >= 0:
            linkedit = None
            for name, vmaddr, fileoff, filesize, _ in self.all_segments:
                if name == "__LINKEDIT":
                    linkedit = (fileoff, fileoff + filesize)
            if linkedit and linkedit[0] <= str_off < linkedit[1]:
                name_end = self.raw.find(b'\x00', str_off + 1)
                if name_end > 0:
                    for probe in range(name_end + 1, min(name_end + 32, self.size - 7)):
                        val = _rd64(self.raw, probe)
                        func_foff = val - self.base_va
                        if self.kern_text[0] <= func_foff < self.kern_text[1]:
                            first_insn = _rd32(self.raw, func_foff)
                            if first_insn != 0 and first_insn != 0xD503201F:
                                self.emit(func_foff, MOV_X0_1,
                                          "mov x0,#1 [_PE_i_can_has_debugger]")
                                self.emit(func_foff + 4, RET,
                                          "ret [_PE_i_can_has_debugger]")
                                return True

        # Strategy 2: code pattern — function starts with ADRP x8,
        # preceded by a function boundary, has many BL callers,
        # and reads a 32-bit (w-register) value within first few instructions.
        self._log("  [*] trying code pattern search...")

        # Determine kernel-only __text range from fileset entries if available
        kern_text_start, kern_text_end = self._get_kernel_text_range()

        best_off = -1
        best_callers = 0
        for off in range(kern_text_start, kern_text_end - 12, 4):
            dis = self._disas_at(off)
            if not dis or dis[0].mnemonic != "adrp":
                continue
            # Must target x8
            if dis[0].operands[0].reg != ARM64_REG_X8:
                continue
            # Must be preceded by function boundary
            if off >= 4:
                prev = _rd32(self.raw, off - 4)
                if not self._is_func_boundary(prev):
                    continue
            # Must read a w-register (32-bit) from [x8, #imm] within first 6 instructions
            has_w_load = False
            for k in range(1, 7):
                if off + k * 4 >= self.size:
                    break
                dk = self._disas_at(off + k * 4)
                if dk and dk[0].mnemonic == "ldr" and dk[0].op_str.startswith("w") and "x8" in dk[0].op_str:
                    has_w_load = True
                    break
            if not has_w_load:
                continue
            # Count callers — _PE_i_can_has_debugger has ~80-200 callers
            # (widely used but not a basic kernel primitive)
            n_callers = len(self.bl_callers.get(off, []))
            if 50 <= n_callers <= 250 and n_callers > best_callers:
                best_callers = n_callers
                best_off = off

        if best_off >= 0:
            self._log(f"  [+] code pattern match at 0x{best_off:X} ({best_callers} callers)")
            self.emit(best_off, MOV_X0_1, "mov x0,#1 [_PE_i_can_has_debugger]")
            self.emit(best_off + 4, RET, "ret [_PE_i_can_has_debugger]")
            return True

        self._log("  [-] function not found")
        return False

    def patch_post_validation_nop(self):
        """Patch 8: NOP the TBNZ after TXM CodeSignature error logging.

        The 'TXM [Error]: CodeSignature: selector: ...' string is followed
        by a BL (printf/log), then a TBNZ that branches to an additional
        validation path.  NOP the TBNZ to skip it.
        """
        self._log("\n[8] post-validation NOP (txm-related)")

        str_off = self.find_string(b"TXM [Error]: CodeSignature")
        if str_off < 0:
            self._log("  [-] 'TXM [Error]: CodeSignature' string not found")
            return False

        refs = self.find_string_refs(str_off, *self.kern_text)
        if not refs:
            refs = self.find_string_refs(str_off)
        if not refs:
            self._log("  [-] no code refs")
            return False

        for adrp_off, add_off, _ in refs:
            # Scan forward past the BL (printf/log) for a TBNZ
            for scan in range(add_off, min(add_off + 0x40, self.size), 4):
                insns = self._disas_at(scan)
                if not insns:
                    continue
                if insns[0].mnemonic == "tbnz":
                    self.emit(scan, NOP,
                              f"NOP {insns[0].mnemonic} {insns[0].op_str} "
                              "[txm post-validation]")
                    return True

        self._log("  [-] TBNZ not found after TXM error string ref")
        return False

    def patch_post_validation_cmp(self):
        """Patch 9: cmp w0,w0 in postValidation (AMFI code signing).

        The 'AMFI: code signature validation failed' string is in the CALLER
        function, not in postValidation itself.  We find the caller, collect
        its BL targets, then look inside each target for CMP W0, #imm + B.NE.
        """
        self._log("\n[9] postValidation: cmp w0,w0 (AMFI code signing)")

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
            self._log("  [-] caller function start not found")
            return False

        # Collect unique BL targets from the caller function
        # Only stop at PACIBSP (new function), not at ret/retab (early returns)
        bl_targets = set()
        for scan in range(caller_start, min(caller_start + 0x2000, self.size), 4):
            if scan > caller_start + 8 and _rd32(self.raw, scan) == _PACIBSP_U32:
                break
            target = self._is_bl(scan)
            if target >= 0:
                bl_targets.add(target)

        # In each BL target in AMFI, look for:  BL ... ; CMP W0, #imm ; B.NE
        # The CMP must check W0 (return value of preceding BL call).
        for target in sorted(bl_targets):
            if not (self.amfi_text[0] <= target < self.amfi_text[1]):
                continue
            for off in range(target, min(target + 0x200, self.size), 4):
                if off > target + 8 and _rd32(self.raw, off) == _PACIBSP_U32:
                    break
                dis = self._disas_at(off, 2)
                if len(dis) < 2:
                    continue
                i0, i1 = dis[0], dis[1]
                if i0.mnemonic != "cmp" or i1.mnemonic != "b.ne":
                    continue
                # Must be CMP W0, #imm (first operand = w0, second = immediate)
                ops = i0.operands
                if len(ops) < 2:
                    continue
                if ops[0].type != ARM64_OP_REG or ops[0].reg != ARM64_REG_W0:
                    continue
                if ops[1].type != ARM64_OP_IMM:
                    continue
                # Must be preceded by a BL within 2 instructions
                has_bl = False
                for gap in (4, 8):
                    if self._is_bl(off - gap) >= 0:
                        has_bl = True
                        break
                if not has_bl:
                    continue
                self.emit(off, CMP_W0_W0,
                          f"cmp w0,w0 (was {i0.mnemonic} {i0.op_str}) "
                          "[postValidation]")
                return True

        self._log("  [-] CMP+B.NE pattern not found in caller's BL targets")
        return False

    def patch_check_dyld_policy(self):
        """Patches 10-11: Replace two BL calls in _check_dyld_policy_internal with mov w0,#1.

        The function is found via its reference to the Swift Playgrounds
        entitlement string.  The two BLs immediately preceding that string
        reference (each followed by a conditional branch on w0) are patched.
        """
        self._log("\n[10-11] _check_dyld_policy_internal: mov w0,#1 (two BLs)")

        # Anchor: entitlement string referenced from within the function
        str_off = self.find_string(
            b"com.apple.developer.swift-playgrounds-app.development-build")
        if str_off < 0:
            self._log("  [-] swift-playgrounds entitlement string not found")
            return False

        refs = self.find_string_refs(str_off, *self.amfi_text)
        if not refs:
            refs = self.find_string_refs(str_off)
        if not refs:
            self._log("  [-] no code refs in AMFI")
            return False

        for adrp_off, add_off, _ in refs:
            # Walk backward from the ADRP, looking for BL + conditional-on-w0 pairs
            bls_with_cond = []   # [(bl_off, bl_target), ...]
            for back in range(adrp_off - 4, max(adrp_off - 80, 0), -4):
                bl_target = self._is_bl(back)
                if bl_target < 0:
                    continue
                if self._is_cond_branch_w0(back + 4):
                    bls_with_cond.append((back, bl_target))

            if len(bls_with_cond) >= 2:
                bl2_off, bl2_tgt = bls_with_cond[0]   # closer  to ADRP
                bl1_off, bl1_tgt = bls_with_cond[1]   # farther from ADRP
                # The two BLs must call DIFFERENT functions — this
                # distinguishes _check_dyld_policy_internal from other
                # functions that repeat calls to the same helper.
                if bl1_tgt == bl2_tgt:
                    continue
                self.emit(bl1_off, MOV_W0_1,
                          "mov w0,#1 (was BL) [_check_dyld_policy_internal @1]")
                self.emit(bl2_off, MOV_W0_1,
                          "mov w0,#1 (was BL) [_check_dyld_policy_internal @2]")
                return True

        self._log("  [-] _check_dyld_policy_internal BL pair not found")
        return False

    def _find_validate_root_hash_func(self):
        """Find validate_on_disk_root_hash function via 'authenticate_root_hash' string."""
        str_off = self.find_string(b"authenticate_root_hash")
        if str_off < 0:
            return -1
        refs = self.find_string_refs(str_off, *self.apfs_text)
        if not refs:
            return -1
        return self.find_function_start(refs[0][0])

    def patch_apfs_graft(self):
        """Patch 12: Replace BL to validate_on_disk_root_hash with mov w0,#0.

        Instead of stubbing _apfs_graft at entry, find the specific BL
        that calls the root hash validation and neutralize just that call.
        """
        self._log("\n[12] _apfs_graft: mov w0,#0 (validate_root_hash BL)")

        # Find _apfs_graft function
        exact = self.raw.find(b"\x00apfs_graft\x00")
        if exact < 0:
            self._log("  [-] 'apfs_graft' string not found")
            return False
        str_off = exact + 1

        refs = self.find_string_refs(str_off, *self.apfs_text)
        if not refs:
            self._log("  [-] no code refs")
            return False

        graft_start = self.find_function_start(refs[0][0])
        if graft_start < 0:
            self._log("  [-] _apfs_graft function start not found")
            return False

        # Find validate_on_disk_root_hash function
        vrh_func = self._find_validate_root_hash_func()
        if vrh_func < 0:
            self._log("  [-] validate_on_disk_root_hash not found")
            return False

        # Scan _apfs_graft for BL to validate_on_disk_root_hash
        # Don't stop at ret/retab (early returns) — only stop at PACIBSP (new function)
        for scan in range(graft_start, min(graft_start + 0x2000, self.size), 4):
            if scan > graft_start + 8 and _rd32(self.raw, scan) == _PACIBSP_U32:
                break
            bl_target = self._is_bl(scan)
            if bl_target == vrh_func:
                self.emit(scan, MOV_W0_0, "mov w0,#0 [_apfs_graft]")
                return True

        self._log("  [-] BL to validate_on_disk_root_hash not found in _apfs_graft")
        return False

    def patch_apfs_vfsop_mount_cmp(self):
        """Patch 13: cmp x0,x0 in _apfs_vfsop_mount (current_thread == kernel_task check).

        The target CMP follows the pattern: BL (returns current_thread in x0),
        ADRP + LDR + LDR (load kernel_task global), CMP x0, Xm, B.EQ.
        We require x0 as the first CMP operand to distinguish it from other
        CMP Xn,Xm instructions in the same function.
        """
        self._log("\n[13] _apfs_vfsop_mount: cmp x0,x0 (mount rw check)")

        refs_upgrade = self._find_by_string_in_range(
            b"apfs_mount_upgrade_checks\x00",
            self.apfs_text, "apfs_mount_upgrade_checks")
        if not refs_upgrade:
            return False

        func_start = self.find_function_start(refs_upgrade[0][0])
        if func_start < 0:
            return False

        # Find BL callers of _apfs_mount_upgrade_checks
        callers = self.bl_callers.get(func_start, [])
        if not callers:
            for off_try in [func_start, func_start + 4]:
                callers = self.bl_callers.get(off_try, [])
                if callers:
                    break

        if not callers:
            self._log("  [-] no BL callers of _apfs_mount_upgrade_checks found")
            for off in range(self.apfs_text[0], self.apfs_text[1], 4):
                bl_target = self._is_bl(off)
                if bl_target >= 0 and func_start <= bl_target <= func_start + 4:
                    callers.append(off)

        for caller_off in callers:
            if not (self.apfs_text[0] <= caller_off < self.apfs_text[1]):
                continue
            # Scan a wider range — the CMP can be 0x800+ bytes before the BL
            caller_func = self.find_function_start(caller_off)
            scan_start = caller_func if caller_func >= 0 else max(caller_off - 0x800, self.apfs_text[0])
            scan_end = min(caller_off + 0x100, self.apfs_text[1])

            for scan in range(scan_start, scan_end, 4):
                dis = self._disas_at(scan)
                if not dis or dis[0].mnemonic != "cmp":
                    continue
                ops = dis[0].operands
                if len(ops) < 2:
                    continue
                # Require CMP Xn, Xm (both register operands)
                if ops[0].type != ARM64_OP_REG or ops[1].type != ARM64_OP_REG:
                    continue
                # Require x0 as first operand (return value from BL)
                if ops[0].reg != ARM64_REG_X0:
                    continue
                # Skip CMP x0, x0 (already patched or trivial)
                if ops[0].reg == ops[1].reg:
                    continue
                self.emit(scan, CMP_X0_X0,
                          f"cmp x0,x0 (was {dis[0].mnemonic} {dis[0].op_str}) "
                          "[_apfs_vfsop_mount]")
                return True

        self._log("  [-] CMP x0,Xm not found near mount_upgrade_checks caller")
        return False

    def patch_apfs_mount_upgrade_checks(self):
        """Patch 14: Replace TBNZ w0,#0xe with mov w0,#0 in _apfs_mount_upgrade_checks.

        Within the function, a BL calls a small flag-reading leaf function,
        then TBNZ w0,#0xe branches to the error path.  Replace the TBNZ
        with mov w0,#0 to force the success path.
        """
        self._log("\n[14] _apfs_mount_upgrade_checks: mov w0,#0 (tbnz bypass)")

        refs = self._find_by_string_in_range(
            b"apfs_mount_upgrade_checks\x00",
            self.apfs_text, "apfs_mount_upgrade_checks")
        if not refs:
            return False

        func_start = self.find_function_start(refs[0][0])
        if func_start < 0:
            self._log("  [-] function start not found")
            return False

        # Scan for BL followed by TBNZ w0
        # Don't stop at ret/retab (early returns) — only stop at PACIBSP (new function)
        for scan in range(func_start, min(func_start + 0x200, self.size), 4):
            if scan > func_start + 8 and _rd32(self.raw, scan) == _PACIBSP_U32:
                break
            bl_target = self._is_bl(scan)
            if bl_target < 0:
                continue
            # Check if BL target is a small leaf function (< 0x20 bytes, ends with ret)
            is_leaf = False
            for k in range(0, 0x20, 4):
                if bl_target + k >= self.size:
                    break
                dis = self._disas_at(bl_target + k)
                if dis and dis[0].mnemonic == "ret":
                    is_leaf = True
                    break
            if not is_leaf:
                continue
            # Check next instruction is TBNZ w0, #0xe
            next_off = scan + 4
            insns = self._disas_at(next_off)
            if not insns:
                continue
            i = insns[0]
            if i.mnemonic == "tbnz" and len(i.operands) >= 1:
                if (i.operands[0].type == ARM64_OP_REG and
                        i.operands[0].reg == ARM64_REG_W0):
                    self.emit(next_off, MOV_W0_0,
                              "mov w0,#0 [_apfs_mount_upgrade_checks]")
                    return True

        self._log("  [-] BL + TBNZ w0 pattern not found")
        return False

    def _find_validate_payload_manifest_func(self):
        """Find the AppleImage4 validate_payload_and_manifest function."""
        str_off = self.find_string(b"validate_payload_and_manifest")
        if str_off < 0:
            return -1
        refs = self.find_string_refs(str_off, *self.apfs_text)
        if not refs:
            return -1
        return self.find_function_start(refs[0][0])

    def patch_handle_fsioc_graft(self):
        """Patch 15: Replace BL to validate_payload_and_manifest with mov w0,#0.

        Instead of stubbing _handle_fsioc_graft at entry, find the specific
        BL that calls AppleImage4 validation and neutralize just that call.
        """
        self._log("\n[15] _handle_fsioc_graft: mov w0,#0 (validate BL)")

        exact = self.raw.find(b"\x00handle_fsioc_graft\x00")
        if exact < 0:
            self._log("  [-] 'handle_fsioc_graft' string not found")
            return False
        str_off = exact + 1

        refs = self.find_string_refs(str_off, *self.apfs_text)
        if not refs:
            self._log("  [-] no code refs")
            return False

        fsioc_start = self.find_function_start(refs[0][0])
        if fsioc_start < 0:
            self._log("  [-] function start not found")
            return False

        # Find the validation function
        val_func = self._find_validate_payload_manifest_func()
        if val_func < 0:
            self._log("  [-] validate_payload_and_manifest not found")
            return False

        # Scan _handle_fsioc_graft for BL to validation function
        for scan in range(fsioc_start, min(fsioc_start + 0x400, self.size), 4):
            insns = self._disas_at(scan)
            if not insns:
                continue
            if scan > fsioc_start + 8 and insns[0].mnemonic == "pacibsp":
                break
            bl_target = self._is_bl(scan)
            if bl_target == val_func:
                self.emit(scan, MOV_W0_0, "mov w0,#0 [_handle_fsioc_graft]")
                return True

        self._log("  [-] BL to validate_payload_and_manifest not found")
        return False

    # ── Sandbox MACF hooks ───────────────────────────────────────

    def _find_sandbox_ops_table_via_conf(self):
        """Find Sandbox mac_policy_ops table via mac_policy_conf struct."""
        self._log("\n[*] Finding Sandbox mac_policy_ops via mac_policy_conf...")

        seatbelt_off = self.find_string(b"Seatbelt sandbox policy")
        sandbox_raw = self.raw.find(b"\x00Sandbox\x00")
        sandbox_off = sandbox_raw + 1 if sandbox_raw >= 0 else -1
        if seatbelt_off < 0 or sandbox_off < 0:
            self._log("  [-] Sandbox/Seatbelt strings not found")
            return None
        self._log(f"  [*] Sandbox string at foff 0x{sandbox_off:X}, "
                  f"Seatbelt at 0x{seatbelt_off:X}")

        data_ranges = []
        for name, vmaddr, fileoff, filesize, prot in self.all_segments:
            if name in ("__DATA_CONST", "__DATA") and filesize > 0:
                data_ranges.append((fileoff, fileoff + filesize))

        for d_start, d_end in data_ranges:
            for i in range(d_start, d_end - 40, 8):
                val = _rd64(self.raw, i)
                if val == 0 or (val & (1 << 63)):
                    continue
                if (val & 0x7FFFFFFFFFF) != sandbox_off:
                    continue
                val2 = _rd64(self.raw, i + 8)
                if (val2 & (1 << 63)) or (val2 & 0x7FFFFFFFFFF) != seatbelt_off:
                    continue
                val_ops = _rd64(self.raw, i + 32)
                if not (val_ops & (1 << 63)):
                    ops_off = val_ops & 0x7FFFFFFFFFF
                    self._log(f"  [+] mac_policy_conf at foff 0x{i:X}, "
                              f"mpc_ops -> 0x{ops_off:X}")
                    return ops_off

        self._log("  [-] mac_policy_conf not found")
        return None

    def _read_ops_entry(self, table_off, index):
        """Read a function pointer from the ops table, handling chained fixups."""
        off = table_off + index * 8
        if off + 8 > self.size:
            return -1
        val = _rd64(self.raw, off)
        if val == 0:
            return 0
        return self._decode_chained_ptr(val)

    def patch_sandbox_hooks(self):
        """Patches 16-25: Stub Sandbox MACF hooks with mov x0,#0; ret.

        Uses mac_policy_ops struct indices from XNU source (xnu-11215+).
        """
        self._log("\n[16-25] Sandbox MACF hooks")

        ops_table = self._find_sandbox_ops_table_via_conf()
        if ops_table is None:
            return False

        HOOK_INDICES = {
            "file_check_mmap":     36,
            "mount_check_mount":   87,
            "mount_check_remount": 88,
            "mount_check_umount":  91,
            "vnode_check_rename":  120,
        }

        sb_start, sb_end = self.sandbox_text
        patched_count = 0

        for hook_name, idx in HOOK_INDICES.items():
            func_off = self._read_ops_entry(ops_table, idx)
            if func_off is None or func_off <= 0:
                self._log(f"  [-] ops[{idx}] {hook_name}: NULL or invalid")
                continue
            if not (sb_start <= func_off < sb_end):
                self._log(f"  [-] ops[{idx}] {hook_name}: foff 0x{func_off:X} "
                          f"outside Sandbox (0x{sb_start:X}-0x{sb_end:X})")
                continue

            self.emit(func_off, MOV_X0_0, f"mov x0,#0 [_hook_{hook_name}]")
            self.emit(func_off + 4, RET, f"ret [_hook_{hook_name}]")
            self._log(f"  [+] ops[{idx}] {hook_name} at foff 0x{func_off:X}")
            patched_count += 1

        return patched_count > 0

    # ═══════════════════════════════════════════════════════════════
    # Main entry point
    # ═══════════════════════════════════════════════════════════════

    def find_all(self):
        """Find and record all kernel patches.  Returns list of (offset, bytes, desc)."""
        self.patch_apfs_root_snapshot()               #  1
        self.patch_apfs_seal_broken()                  #  2
        self.patch_bsd_init_rootvp()                   #  3
        self.patch_proc_check_launch_constraints()     #  4-5
        self.patch_PE_i_can_has_debugger()             #  6-7
        self.patch_post_validation_nop()               #  8
        self.patch_post_validation_cmp()               #  9
        self.patch_check_dyld_policy()                 # 10-11
        self.patch_apfs_graft()                        # 12
        self.patch_apfs_vfsop_mount_cmp()              # 13
        self.patch_apfs_mount_upgrade_checks()         # 14
        self.patch_handle_fsioc_graft()                # 15
        self.patch_sandbox_hooks()                     # 16-25
        return self.patches

    def apply(self):
        """Find all patches and apply them to self.data.  Returns patch count."""
        patches = self.find_all()
        for off, patch_bytes, desc in patches:
            self.data[off:off + len(patch_bytes)] = patch_bytes

        if self.verbose and patches:
            self._log(f"\n{'═'*60}")
            self._log(f"VERIFICATION: {len(patches)} patches applied")
            self._log(f"{'═'*60}")
            for off, patch_bytes, desc in sorted(patches):
                insns = self._disas_n(self.data, off, len(patch_bytes) // 4)
                if insns:
                    dis_str = "; ".join(f"{i.mnemonic} {i.op_str}" for i in insns)
                else:
                    dis_str = "???"
                self._log(f"  0x{off:08X}: {dis_str:40s} — {desc}")

        return len(patches)


# ── CLI entry point ──────────────────────────────────────────────
if __name__ == "__main__":
    import sys, argparse

    parser = argparse.ArgumentParser(
        description="Dynamic kernel patcher — find & apply patches on iOS kernelcaches")
    parser.add_argument("kernelcache", help="Path to raw or IM4P kernelcache")
    parser.add_argument("-c", "--context", type=int, default=5,
                        help="Instructions of context before/after each patch (default: 5)")
    parser.add_argument("-q", "--quiet", action="store_true",
                        help="Suppress index-building progress (only show patches)")
    args = parser.parse_args()

    path = args.kernelcache
    print(f"Loading {path}...")
    file_raw = open(path, "rb").read()

    # Auto-detect IM4P vs raw Mach-O
    if file_raw[:4] == b"\xcf\xfa\xed\xfe":
        payload = file_raw
        print(f"  format: raw Mach-O")
    else:
        try:
            from pyimg4 import IM4P
            im4p = IM4P(file_raw)
            if im4p.payload.compression:
                im4p.payload.decompress()
            payload = im4p.payload.data
            print(f"  format: IM4P (fourcc={im4p.fourcc})")
        except Exception:
            payload = file_raw
            print(f"  format: unknown (treating as raw)")

    data = bytearray(payload)
    print(f"  size:   {len(data)} bytes ({len(data)/1024/1024:.1f} MB)\n")

    kp = KernelPatcher(data, verbose=not args.quiet)
    patches = kp.find_all()

    # ── Print ranged before / after disassembly for every patch ──
    ctx = args.context

    print(f"\n{'═'*72}")
    print(f"  {len(patches)} PATCHES — before / after disassembly (context={ctx})")
    print(f"{'═'*72}")

    # Apply patches to get the "after" image
    after = bytearray(kp.raw)  # start from original
    for off, pb, _ in patches:
        after[off:off + len(pb)] = pb

    for i, (off, patch_bytes, desc) in enumerate(sorted(patches), 1):
        n_insns = len(patch_bytes) // 4
        start = max(off - ctx * 4, 0)
        end = off + n_insns * 4 + ctx * 4
        total = (end - start) // 4

        before_insns = kp._disas_n(kp.raw, start, total)
        after_insns  = kp._disas_n(after,   start, total)

        print(f"\n  ┌{'─'*70}")
        print(f"  │ [{i:2d}] 0x{off:08X}: {desc}")
        print(f"  ├{'─'*34}┬{'─'*35}")
        print(f"  │ {'BEFORE':^33}│ {'AFTER':^34}")
        print(f"  ├{'─'*34}┼{'─'*35}")

        # Build line pairs
        max_lines = max(len(before_insns), len(after_insns))
        for j in range(max_lines):
            def fmt(insn):
                if insn is None:
                    return " " * 33
                h = insn.bytes.hex()
                return f"0x{insn.address:07X} {h:8s} {insn.mnemonic:6s} {insn.op_str}"

            bi = before_insns[j] if j < len(before_insns) else None
            ai = after_insns[j]  if j < len(after_insns)  else None

            bl = fmt(bi)
            al = fmt(ai)

            # Mark if this address is inside the patched range
            addr = (bi.address if bi else ai.address) if (bi or ai) else 0
            in_patch = off <= addr < off + len(patch_bytes)
            marker = " ◄" if in_patch else "  "

            print(f"  │ {bl:33s}│ {al:33s}{marker}")

        print(f"  └{'─'*34}┴{'─'*35}")

#!/usr/bin/env python3
"""
patch_cfw.py — Dynamic binary patching for CFW installation on vphone600.

Uses capstone for disassembly-based anchoring and keystone for instruction
assembly, producing reliable, upgrade-proof patches.

Called by install_cfw.sh during CFW installation.

Commands:
    cryptex-paths <BuildManifest.plist>
        Print SystemOS and AppOS DMG paths from BuildManifest.

    patch-seputil <binary>
        Patch seputil gigalocker UUID to "AA".

    patch-launchd-cache-loader <binary>
        NOP the cache validation check in launchd_cache_loader.

    patch-mobileactivationd <binary>
        Patch -[DeviceType should_hactivate] to always return true.

    patch-launchd-jetsam <binary>
        Patch launchd jetsam panic guard to avoid initproc crash loop.

    inject-daemons <launchd.plist> <daemon_dir>
        Inject bash/dropbear/trollvnc into launchd.plist.

    inject-dylib <binary> <dylib_path>
        Inject LC_LOAD_DYLIB into Mach-O binary (thin or universal).
        Equivalent to: optool install -c load -p <dylib_path> -t <binary>

Dependencies:
    pip install capstone keystone-engine
"""

import os
import plistlib
import struct
import subprocess
import sys

from capstone import Cs, CS_ARCH_ARM64, CS_MODE_LITTLE_ENDIAN
from capstone.arm64_const import ARM64_OP_IMM
from keystone import Ks, KS_ARCH_ARM64, KS_MODE_LITTLE_ENDIAN as KS_MODE_LE

# ══════════════════════════════════════════════════════════════════
# ARM64 assembler / disassembler
# ══════════════════════════════════════════════════════════════════

_cs = Cs(CS_ARCH_ARM64, CS_MODE_LITTLE_ENDIAN)
_cs.detail = True
_ks = Ks(KS_ARCH_ARM64, KS_MODE_LE)


def asm(s):
    enc, _ = _ks.asm(s)
    if not enc:
        raise RuntimeError(f"asm failed: {s}")
    return bytes(enc)


def asm_at(s, addr):
    enc, _ = _ks.asm(s, addr=addr)
    if not enc:
        raise RuntimeError(f"asm failed at 0x{addr:X}: {s}")
    return bytes(enc)


NOP = asm("nop")
MOV_X0_1 = asm("mov x0, #1")
RET = asm("ret")


def rd32(data, off):
    return struct.unpack_from("<I", data, off)[0]


def wr32(data, off, val):
    struct.pack_into("<I", data, off, val)


def disasm_at(data, off, n=8):
    """Disassemble n instructions at file offset."""
    return list(_cs.disasm(bytes(data[off : off + n * 4]), off))


def _log_asm(data, offset, count=5, marker_off=-1):
    """Log disassembly of `count` instructions at file offset for before/after comparison."""
    insns = disasm_at(data, offset, count)
    for insn in insns:
        tag = " >>>" if insn.address == marker_off else "    "
        print(f"  {tag} 0x{insn.address:08X}: {insn.mnemonic:8s} {insn.op_str}")


# ══════════════════════════════════════════════════════════════════
# Mach-O helpers
# ══════════════════════════════════════════════════════════════════


def parse_macho_sections(data):
    """Parse Mach-O 64-bit to extract section info.

    Returns dict: "segment,section" -> (vm_addr, size, file_offset)
    """
    magic = struct.unpack_from("<I", data, 0)[0]
    if magic != 0xFEEDFACF:
        raise ValueError(f"Not a 64-bit Mach-O (magic=0x{magic:X})")

    ncmds = struct.unpack_from("<I", data, 16)[0]
    sections = {}
    offset = 32  # sizeof(mach_header_64)

    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from("<II", data, offset)
        if cmd == 0x19:  # LC_SEGMENT_64
            segname = data[offset + 8 : offset + 24].split(b"\x00")[0].decode()
            nsects = struct.unpack_from("<I", data, offset + 64)[0]
            sect_off = offset + 72
            for _ in range(nsects):
                sectname = (
                    data[sect_off : sect_off + 16].split(b"\x00")[0].decode()
                )
                addr = struct.unpack_from("<Q", data, sect_off + 32)[0]
                size = struct.unpack_from("<Q", data, sect_off + 40)[0]
                file_off = struct.unpack_from("<I", data, sect_off + 48)[0]
                sections[f"{segname},{sectname}"] = (addr, size, file_off)
                sect_off += 80
        offset += cmdsize
    return sections


def va_to_foff(data, va):
    """Convert virtual address to file offset using LC_SEGMENT_64 commands."""
    ncmds = struct.unpack_from("<I", data, 16)[0]
    offset = 32

    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from("<II", data, offset)
        if cmd == 0x19:  # LC_SEGMENT_64
            vmaddr = struct.unpack_from("<Q", data, offset + 24)[0]
            vmsize = struct.unpack_from("<Q", data, offset + 32)[0]
            fileoff = struct.unpack_from("<Q", data, offset + 40)[0]
            if vmaddr <= va < vmaddr + vmsize:
                return fileoff + (va - vmaddr)
        offset += cmdsize
    return -1


def find_section(sections, *candidates):
    """Find the first matching section from candidates."""
    for name in candidates:
        if name in sections:
            return sections[name]
    return None


def find_symtab(data):
    """Parse LC_SYMTAB from Mach-O header.

    Returns (symoff, nsyms, stroff, strsize) or None.
    """
    ncmds = struct.unpack_from("<I", data, 16)[0]
    offset = 32
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from("<II", data, offset)
        if cmd == 0x02:  # LC_SYMTAB
            symoff = struct.unpack_from("<I", data, offset + 8)[0]
            nsyms = struct.unpack_from("<I", data, offset + 12)[0]
            stroff = struct.unpack_from("<I", data, offset + 16)[0]
            strsize = struct.unpack_from("<I", data, offset + 20)[0]
            return symoff, nsyms, stroff, strsize
        offset += cmdsize
    return None


def find_symbol_va(data, name_fragment):
    """Search Mach-O symbol table for a symbol containing name_fragment.

    Returns the symbol's VA, or -1 if not found.
    """
    st = find_symtab(data)
    if not st:
        return -1
    symoff, nsyms, stroff, strsize = st

    for i in range(nsyms):
        entry_off = symoff + i * 16  # sizeof(nlist_64)
        n_strx = struct.unpack_from("<I", data, entry_off)[0]
        n_value = struct.unpack_from("<Q", data, entry_off + 8)[0]

        if n_strx >= strsize or n_value == 0:
            continue

        # Read null-terminated symbol name
        end = data.index(0, stroff + n_strx)
        sym_name = data[stroff + n_strx : end].decode("ascii", errors="replace")

        if name_fragment in sym_name:
            return n_value

    return -1


# ══════════════════════════════════════════════════════════════════
# 1. seputil — Gigalocker UUID patch
# ══════════════════════════════════════════════════════════════════


def patch_seputil(filepath):
    """Dynamically find and patch the gigalocker path format string in seputil.

    Anchor: The format string "/%s.gl" used by seputil to construct the
    gigalocker file path as "{mountpoint}/{uuid}.gl".

    Patching "%s" to "AA" in "/%s.gl" makes it "/AA.gl", so the
    full path becomes /mnt7/AA.gl regardless of the device's UUID.
    The actual .gl file on disk is also renamed to AA.gl.
    """
    data = bytearray(open(filepath, "rb").read())

    # Search for the format string "/%s.gl\0" — this is the gigalocker
    # filename pattern where %s gets replaced with the device UUID.
    anchor = b"/%s.gl\x00"
    offset = data.find(anchor)

    if offset < 0:
        print("  [-] Format string '/%s.gl' not found in seputil")
        return False

    # The %s is at offset+1 (2 bytes: 0x25 0x73)
    pct_s_off = offset + 1
    original = bytes(data[offset : offset + len(anchor)])
    print(f"  Found format string at 0x{offset:X}: {original!r}")

    print(f"  Before: {bytes(data[offset:offset+7]).hex(' ')}")

    # Replace %s (2 bytes) with AA — turns "/%s.gl" into "/AA.gl"
    data[pct_s_off] = ord("A")
    data[pct_s_off + 1] = ord("A")

    print(f"  After:  {bytes(data[offset:offset+7]).hex(' ')}")

    open(filepath, "wb").write(data)
    print(f"  [+] Patched at 0x{pct_s_off:X}: %s -> AA")
    print(f"      /{anchor[1:-1].decode()} -> /AA.gl")
    return True


# ══════════════════════════════════════════════════════════════════
# 2. launchd_cache_loader — Unsecure cache bypass
# ══════════════════════════════════════════════════════════════════


def patch_launchd_cache_loader(filepath):
    """NOP the cache validation check in launchd_cache_loader.

    Anchor strategy:
    Search for "unsecure_cache" substring, resolve to full null-terminated
    string start, find ADRP+ADD xref to it, NOP the nearby cbz/cbnz branch.

    The binary checks boot-arg "launchd_unsecure_cache=" — if not found,
    it skips the unsecure path via a conditional branch. NOPping that branch
    allows modified launchd.plist to be loaded.
    """
    data = bytearray(open(filepath, "rb").read())
    sections = parse_macho_sections(data)

    text_sec = find_section(sections, "__TEXT,__text")
    if not text_sec:
        print("  [-] __TEXT,__text not found")
        return False

    text_va, text_size, text_foff = text_sec

    # Strategy 1: Search for anchor strings in __cstring
    # Code always references the START of a C string, so after finding a
    # substring match, back-scan to the enclosing string's first byte.
    cstring_sec = find_section(sections, "__TEXT,__cstring")
    anchor_strings = [
        b"unsecure_cache",
        b"unsecure",
        b"cache_valid",
        b"validation",
    ]

    for anchor_str in anchor_strings:
        anchor_off = data.find(anchor_str)
        if anchor_off < 0:
            continue

        # Find which section this belongs to and compute VA
        anchor_sec_foff = -1
        anchor_sec_va = -1
        for sec_name, (sva, ssz, sfoff) in sections.items():
            if sfoff <= anchor_off < sfoff + ssz:
                anchor_sec_foff = sfoff
                anchor_sec_va = sva
                break

        if anchor_sec_foff < 0:
            continue

        # Back-scan to the start of the enclosing null-terminated C string.
        # Code loads strings from their beginning, not from a substring.
        str_start_off = _find_cstring_start(data, anchor_off, anchor_sec_foff)
        str_start_va = anchor_sec_va + (str_start_off - anchor_sec_foff)
        substr_va = anchor_sec_va + (anchor_off - anchor_sec_foff)

        if str_start_off != anchor_off:
            end = data.index(0, str_start_off)
            full_str = data[str_start_off:end].decode("ascii", errors="replace")
            print(f"  Found anchor '{anchor_str.decode()}' inside \"{full_str}\"")
            print(f"    String start: va:0x{str_start_va:X}  (match at va:0x{substr_va:X})")
        else:
            print(f"  Found anchor '{anchor_str.decode()}' at va:0x{str_start_va:X}")

        # Search __TEXT for ADRP+ADD that resolves to the string START VA
        code = bytes(data[text_foff : text_foff + text_size])
        ref_off = _find_adrp_add_ref(code, text_va, str_start_va)

        if ref_off < 0:
            # Also try the exact substring VA as fallback
            ref_off = _find_adrp_add_ref(code, text_va, substr_va)

        if ref_off < 0:
            continue

        ref_foff = text_foff + (ref_off - text_va)
        print(f"  Found string ref at 0x{ref_foff:X}")

        # Find conditional branch AFTER the string ref (within +32 instructions).
        # The pattern is: ADRP+ADD (load string) -> BL (call check) -> CBZ/CBNZ (branch on result)
        # So only search forward from the ref, not backwards.
        branch_foff = _find_nearby_branch(data, ref_foff, text_foff, text_size)
        if branch_foff >= 0:
            ctx_start = max(text_foff, branch_foff - 8)
            print(f"  Before:")
            _log_asm(data, ctx_start, 5, branch_foff)

            data[branch_foff : branch_foff + 4] = NOP

            print(f"  After:")
            _log_asm(data, ctx_start, 5, branch_foff)

            open(filepath, "wb").write(data)
            print(f"  [+] NOPped at 0x{branch_foff:X}")
            return True

    print("  [-] Dynamic anchor not found — all strategies exhausted")
    return False


def _find_cstring_start(data, match_off, section_foff):
    """Find the start of the null-terminated C string containing match_off.

    Scans backwards from match_off to find the previous null byte (or section
    start). Returns the file offset of the first byte of the enclosing string.
    This is needed because code always references the start of a string, not
    a substring within it.
    """
    pos = match_off - 1
    while pos >= section_foff and data[pos] != 0:
        pos -= 1
    return pos + 1


def _find_adrp_add_ref(code, base_va, target_va):
    """Find ADRP+ADD pair that computes target_va in code.

    Handles non-adjacent pairs: tracks recent ADRP results per register
    and matches them with ADD instructions up to 8 instructions later.
    """
    target_page = target_va & ~0xFFF
    target_pageoff = target_va & 0xFFF

    # Track recent ADRP instructions: reg -> (insn_va, page_value, instruction_index)
    adrp_cache = {}

    for off in range(0, len(code) - 4, 4):
        insns = list(_cs.disasm(code[off : off + 4], base_va + off))
        if not insns:
            continue
        insn = insns[0]
        idx = off // 4

        if insn.mnemonic == "adrp" and len(insn.operands) >= 2:
            reg = insn.operands[0].reg
            page = insn.operands[1].imm
            adrp_cache[reg] = (insn.address, page, idx)

        elif insn.mnemonic == "add" and len(insn.operands) >= 3:
            src_reg = insn.operands[1].reg
            imm = insn.operands[2].imm
            if src_reg in adrp_cache:
                adrp_va, page, adrp_idx = adrp_cache[src_reg]
                # Only match if ADRP was within 8 instructions
                if page == target_page and imm == target_pageoff and idx - adrp_idx <= 8:
                    return adrp_va

    return -1


def _find_nearby_branch(data, ref_foff, text_foff, text_size):
    """Find a conditional branch after a BL (function call) near ref_foff.

    The typical pattern is:
        ADRP+ADD  (load string argument)  ← ref_foff points here
        ...       (setup other args)
        BL        (call check function)
        CBZ/CBNZ  (branch on return value)

    Searches forward from ref_foff for a BL, then finds the first
    conditional branch after it (within 8 instructions of the BL).
    Falls back to first conditional branch within +32 instructions.
    """
    branch_mnemonics = {"cbz", "cbnz", "tbz", "tbnz"}

    # Strategy A: find BL → then first conditional branch after it
    for delta in range(0, 16):
        check_foff = ref_foff + delta * 4
        if check_foff >= text_foff + text_size:
            break
        insns = disasm_at(data, check_foff, 1)
        if not insns:
            continue
        if insns[0].mnemonic == "bl":
            # Found a function call; scan the next 8 instructions for a branch
            for d2 in range(1, 9):
                br_foff = check_foff + d2 * 4
                if br_foff >= text_foff + text_size:
                    break
                br_insns = disasm_at(data, br_foff, 1)
                if not br_insns:
                    continue
                mn = br_insns[0].mnemonic
                if mn in branch_mnemonics or mn.startswith("b."):
                    return br_foff
            break  # Found BL but no branch after it

    # Strategy B: fallback — first conditional branch forward within 32 insns
    for delta in range(1, 33):
        check_foff = ref_foff + delta * 4
        if check_foff >= text_foff + text_size:
            break
        insns = disasm_at(data, check_foff, 1)
        if not insns:
            continue
        mn = insns[0].mnemonic
        if mn in branch_mnemonics or mn.startswith("b."):
            return check_foff

    return -1


# ══════════════════════════════════════════════════════════════════
# 3. mobileactivationd — Hackivation bypass
# ══════════════════════════════════════════════════════════════════


def patch_mobileactivationd(filepath):
    """Dynamically find -[DeviceType should_hactivate] and patch to return YES.

    Anchor strategies (in order):
    1. Search LC_SYMTAB for symbol containing "should_hactivate"
    2. Parse ObjC metadata: methnames -> selrefs -> method_list -> IMP

    The method determines if the device should self-activate (hackivation).
    Patching it to always return YES bypasses activation lock.
    """
    data = bytearray(open(filepath, "rb").read())

    imp_foff = -1

    # Strategy 1: Symbol table lookup (most reliable)
    imp_va = find_symbol_va(bytes(data), "should_hactivate")
    if imp_va > 0:
        imp_foff = va_to_foff(bytes(data), imp_va)
        if imp_foff >= 0:
            print(f"  Found via symtab: va:0x{imp_va:X} -> foff:0x{imp_foff:X}")

    # Strategy 2: ObjC metadata chain
    if imp_foff < 0:
        imp_foff = _find_via_objc_metadata(data)

    # All dynamic strategies exhausted
    if imp_foff < 0:
        print("  [-] Dynamic anchor not found — all strategies exhausted")
        return False

    # Verify the target looks like code
    if imp_foff + 8 > len(data):
        print(f"  [-] IMP offset 0x{imp_foff:X} out of bounds")
        return False

    print(f"  Before:")
    _log_asm(data, imp_foff, 4, imp_foff)

    # Patch to: mov x0, #1; ret
    data[imp_foff : imp_foff + 4] = MOV_X0_1
    data[imp_foff + 4 : imp_foff + 8] = RET

    print(f"  After:")
    _log_asm(data, imp_foff, 4, imp_foff)

    open(filepath, "wb").write(data)
    print(f"  [+] Patched at 0x{imp_foff:X}: mov x0, #1; ret")
    return True


# ══════════════════════════════════════════════════════════════════
# 4. launchd — Jetsam panic bypass
# ══════════════════════════════════════════════════════════════════


def _extract_branch_target_off(insn):
    for op in reversed(insn.operands):
        if op.type == ARM64_OP_IMM:
            return op.imm
    return -1


def _is_return_block(data, foff, text_foff, text_size):
    """Check if foff points to a function return sequence (ret/retab within 8 insns)."""
    for i in range(8):
        check = foff + i * 4
        if check >= text_foff + text_size:
            break
        insns = disasm_at(data, check, 1)
        if not insns:
            continue
        if insns[0].mnemonic in ("ret", "retab"):
            return True
        # Stop at unconditional branches (different block)
        if insns[0].mnemonic in ("b", "bl", "br", "blr"):
            break
    return False


def patch_launchd_jetsam(filepath):
    """Bypass launchd jetsam panic path via dynamic string-xref branch rewrite.

    Anchor strategy:
    1. Find jetsam panic string in cstring-like data.
    2. Find ADRP+ADD xref to the string start in __TEXT,__text.
    3. Search backward for a conditional branch whose target is the function's
       return/success path (basic block containing ret/retab).
    4. Rewrite that conditional branch to unconditional `b <same_target>`,
       so the function always returns success and never reaches the panic.
    """
    data = bytearray(open(filepath, "rb").read())
    sections = parse_macho_sections(data)

    text_sec = find_section(sections, "__TEXT,__text")
    if not text_sec:
        print("  [-] __TEXT,__text not found")
        return False

    text_va, text_size, text_foff = text_sec
    code = bytes(data[text_foff : text_foff + text_size])

    cond_mnemonics = {
        "b.eq", "b.ne", "b.cs", "b.hs", "b.cc", "b.lo",
        "b.mi", "b.pl", "b.vs", "b.vc", "b.hi", "b.ls",
        "b.ge", "b.lt", "b.gt", "b.le",
        "cbz", "cbnz", "tbz", "tbnz",
    }

    anchors = [
        b"jetsam property category (Daemon) is not initialized",
        b"jetsam property category",
        b"initproc exited -- exit reason namespace 7 subcode 0x1",
    ]

    for anchor in anchors:
        hit_off = data.find(anchor)
        if hit_off < 0:
            continue

        sec_foff = -1
        sec_va = -1
        for _, (sva, ssz, sfoff) in sections.items():
            if sfoff <= hit_off < sfoff + ssz:
                sec_foff = sfoff
                sec_va = sva
                break
        if sec_foff < 0:
            continue

        str_start_off = _find_cstring_start(data, hit_off, sec_foff)
        str_start_va = sec_va + (str_start_off - sec_foff)

        ref_va = _find_adrp_add_ref(code, text_va, str_start_va)
        if ref_va < 0:
            continue
        ref_foff = text_foff + (ref_va - text_va)

        print(f"  Found jetsam anchor '{anchor.decode(errors='ignore')}'")
        print(f"    string start: va:0x{str_start_va:X}")
        print(f"    xref at foff:0x{ref_foff:X}")

        # Search backward from xref for conditional branches targeting
        # the function's return path (block containing ret/retab).
        # Pick the earliest (farthest back) one — it skips the most
        # jetsam-related code and matches the upstream patch strategy.
        scan_lo = max(text_foff, ref_foff - 0x300)
        patch_off = -1
        patch_target = -1

        for back in range(ref_foff - 4, scan_lo - 1, -4):
            insns = disasm_at(data, back, 1)
            if not insns:
                continue
            insn = insns[0]
            if insn.mnemonic not in cond_mnemonics:
                continue

            tgt = _extract_branch_target_off(insn)
            if tgt < 0:
                continue
            # Target must be a valid file offset within __text
            if tgt < text_foff or tgt >= text_foff + text_size:
                continue
            # Target must be a return block (contains ret/retab)
            if _is_return_block(data, tgt, text_foff, text_size):
                patch_off = back
                patch_target = tgt
                # Don't break — keep scanning for an earlier match

        if patch_off < 0:
            continue

        ctx_start = max(text_foff, patch_off - 8)
        print(f"  Before:")
        _log_asm(data, ctx_start, 5, patch_off)

        data[patch_off : patch_off + 4] = asm_at(f"b #0x{patch_target:X}", patch_off)

        print(f"  After:")
        _log_asm(data, ctx_start, 5, patch_off)

        open(filepath, "wb").write(data)
        print(f"  [+] Patched at 0x{patch_off:X}: jetsam panic guard bypass")
        return True

    print("  [-] Dynamic jetsam anchor/xref not found")
    return False


def _find_via_objc_metadata(data):
    """Find method IMP through ObjC runtime metadata."""
    sections = parse_macho_sections(data)

    # Find "should_hactivate\0" string
    selector = b"should_hactivate\x00"
    sel_foff = data.find(selector)
    if sel_foff < 0:
        print("  [-] Selector 'should_hactivate' not found in binary")
        return -1

    # Compute selector VA
    sel_va = -1
    for sec_name, (sva, ssz, sfoff) in sections.items():
        if sfoff <= sel_foff < sfoff + ssz:
            sel_va = sva + (sel_foff - sfoff)
            break

    if sel_va < 0:
        print(f"  [-] Could not compute VA for selector at foff:0x{sel_foff:X}")
        return -1

    print(f"  Selector at foff:0x{sel_foff:X} va:0x{sel_va:X}")

    # Find selref that points to this selector
    selrefs = find_section(
        sections,
        "__DATA_CONST,__objc_selrefs",
        "__DATA,__objc_selrefs",
        "__AUTH_CONST,__objc_selrefs",
    )

    selref_foff = -1
    selref_va = -1

    if selrefs:
        sr_va, sr_size, sr_foff = selrefs
        for i in range(0, sr_size, 8):
            ptr = struct.unpack_from("<Q", data, sr_foff + i)[0]
            # Handle chained fixups: try exact and masked match
            if ptr == sel_va or (ptr & 0x0000FFFFFFFFFFFF) == sel_va:
                selref_foff = sr_foff + i
                selref_va = sr_va + i
                break

            # Also try: lower 32 bits might encode the target in chained fixups
            if (ptr & 0xFFFFFFFF) == (sel_va & 0xFFFFFFFF):
                selref_foff = sr_foff + i
                selref_va = sr_va + i
                break

    if selref_foff < 0:
        print("  [-] Selref not found (chained fixups may obscure pointers)")
        return -1

    print(f"  Selref at foff:0x{selref_foff:X} va:0x{selref_va:X}")

    # Search for relative method list entry pointing to this selref
    # Relative method entries: { int32 name_rel, int32 types_rel, int32 imp_rel }
    # name_field_va + name_rel = selref_va

    objc_const = find_section(
        sections,
        "__DATA_CONST,__objc_const",
        "__DATA,__objc_const",
        "__AUTH_CONST,__objc_const",
    )

    if objc_const:
        oc_va, oc_size, oc_foff = objc_const

        for i in range(0, oc_size - 12, 4):
            entry_foff = oc_foff + i
            entry_va = oc_va + i
            rel_name = struct.unpack_from("<i", data, entry_foff)[0]
            target_va = entry_va + rel_name

            if target_va == selref_va:
                # Found the method entry! Read IMP relative offset
                imp_field_foff = entry_foff + 8
                imp_field_va = entry_va + 8
                rel_imp = struct.unpack_from("<i", data, imp_field_foff)[0]
                imp_va = imp_field_va + rel_imp
                imp_foff = va_to_foff(bytes(data), imp_va)

                if imp_foff >= 0:
                    print(
                        f"  Found via relative method list: IMP va:0x{imp_va:X} foff:0x{imp_foff:X}"
                    )
                    return imp_foff
                else:
                    print(
                        f"  [!] IMP va:0x{imp_va:X} could not be mapped to file offset"
                    )

    return -1


# ══════════════════════════════════════════════════════════════════
# 5. Mach-O dylib injection (optool replacement)
# ══════════════════════════════════════════════════════════════════


def _align(n, alignment):
    return (n + alignment - 1) & ~(alignment - 1)


def _find_first_section_offset(data):
    """Find the file offset of the earliest section data in the Mach-O.

    This tells us how much space is available after load commands.
    For fat/universal binaries, we operate on the first slice.
    """
    magic = struct.unpack_from("<I", data, 0)[0]
    if magic != 0xFEEDFACF:
        return -1

    ncmds = struct.unpack_from("<I", data, 16)[0]
    offset = 32  # sizeof(mach_header_64)
    earliest = len(data)

    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from("<II", data, offset)
        if cmd == 0x19:  # LC_SEGMENT_64
            nsects = struct.unpack_from("<I", data, offset + 64)[0]
            sect_off = offset + 72
            for _ in range(nsects):
                file_off = struct.unpack_from("<I", data, sect_off + 48)[0]
                size = struct.unpack_from("<Q", data, sect_off + 40)[0]
                if file_off > 0 and size > 0 and file_off < earliest:
                    earliest = file_off
                sect_off += 80
        offset += cmdsize
    return earliest


def _get_fat_slices(data):
    """Parse FAT (universal) binary header and return list of (offset, size) tuples.

    Returns [(0, len(data))] for thin binaries.
    """
    magic = struct.unpack_from(">I", data, 0)[0]
    if magic == 0xCAFEBABE:  # FAT_MAGIC
        nfat = struct.unpack_from(">I", data, 4)[0]
        slices = []
        for i in range(nfat):
            off = 8 + i * 20
            slice_off = struct.unpack_from(">I", data, off + 8)[0]
            slice_size = struct.unpack_from(">I", data, off + 12)[0]
            slices.append((slice_off, slice_size))
        return slices
    elif magic == 0xBEBAFECA:  # FAT_MAGIC_64
        nfat = struct.unpack_from(">I", data, 4)[0]
        slices = []
        for i in range(nfat):
            off = 8 + i * 32
            slice_off = struct.unpack_from(">Q", data, off + 8)[0]
            slice_size = struct.unpack_from(">Q", data, off + 16)[0]
            slices.append((slice_off, slice_size))
        return slices
    else:
        return [(0, len(data))]


def _check_existing_dylib(data, base, dylib_path):
    """Check if the dylib is already loaded in this Mach-O slice."""
    magic = struct.unpack_from("<I", data, base)[0]
    if magic != 0xFEEDFACF:
        return False

    ncmds = struct.unpack_from("<I", data, base + 16)[0]
    offset = base + 32

    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from("<II", data, offset)
        if cmd in (0xC, 0xD, 0x18, 0x1F, 0x80000018):
            # LC_LOAD_DYLIB, LC_LOAD_WEAK_DYLIB, LC_LAZY_LOAD_DYLIB,
            # LC_REEXPORT_DYLIB, LC_LOAD_UPWARD_DYLIB
            name_offset = struct.unpack_from("<I", data, offset + 8)[0]
            name_end = data.index(0, offset + name_offset)
            name = data[offset + name_offset : name_end].decode("ascii", errors="replace")
            if name == dylib_path:
                return True
        offset += cmdsize
    return False


def _strip_codesig(data, base):
    """Strip LC_CODE_SIGNATURE if it's the last load command.

    Zeros out the command bytes and decrements ncmds/sizeofcmds.
    Returns the cmdsize of the removed command, or 0 if not stripped.
    Since the binary will be re-signed by ldid, this is always safe.
    """
    ncmds = struct.unpack_from("<I", data, base + 16)[0]
    sizeofcmds = struct.unpack_from("<I", data, base + 20)[0]

    offset = base + 32
    last_offset = -1
    last_cmd = 0
    last_cmdsize = 0

    for i in range(ncmds):
        cmd, cmdsize = struct.unpack_from("<II", data, offset)
        if i == ncmds - 1:
            last_offset = offset
            last_cmd = cmd
            last_cmdsize = cmdsize
        offset += cmdsize

    if last_cmd != 0x1D:  # LC_CODE_SIGNATURE
        return 0

    # Zero out the LC_CODE_SIGNATURE command
    data[last_offset : last_offset + last_cmdsize] = b"\x00" * last_cmdsize

    # Update header
    struct.pack_into("<I", data, base + 16, ncmds - 1)
    struct.pack_into("<I", data, base + 20, sizeofcmds - last_cmdsize)

    print(f"  Stripped LC_CODE_SIGNATURE ({last_cmdsize} bytes freed)")
    return last_cmdsize


def _inject_lc_load_dylib(data, base, dylib_path):
    """Inject LC_LOAD_DYLIB into a single Mach-O slice starting at `base`.

    Strategy (matches optool/insert_dylib behavior):
    1. Try to fit new LC in existing zero-padding after load commands.
    2. If not enough space, strip LC_CODE_SIGNATURE (re-signed by ldid anyway).
    3. If still not enough, allow header to overflow into section data
       (same approach as optool — the overwritten bytes are typically stub
       code that the jailbreak hook replaces).

    Returns True on success.
    """
    magic = struct.unpack_from("<I", data, base)[0]
    if magic != 0xFEEDFACF:
        print(f"  [-] Not a 64-bit Mach-O at offset 0x{base:X}")
        return False

    ncmds = struct.unpack_from("<I", data, base + 16)[0]
    sizeofcmds = struct.unpack_from("<I", data, base + 20)[0]

    # Build the LC_LOAD_DYLIB command
    name_bytes = dylib_path.encode("ascii") + b"\x00"
    name_offset_in_cmd = 24  # sizeof(dylib_command) header
    cmd_size = _align(name_offset_in_cmd + len(name_bytes), 8)
    lc_data = bytearray(cmd_size)

    struct.pack_into("<I", lc_data, 0, 0xC)  # cmd = LC_LOAD_DYLIB
    struct.pack_into("<I", lc_data, 4, cmd_size)  # cmdsize
    struct.pack_into("<I", lc_data, 8, name_offset_in_cmd)  # name offset
    struct.pack_into("<I", lc_data, 12, 2)  # timestamp
    struct.pack_into("<I", lc_data, 16, 0)  # current_version
    struct.pack_into("<I", lc_data, 20, 0)  # compat_version
    lc_data[name_offset_in_cmd : name_offset_in_cmd + len(name_bytes)] = name_bytes

    # Check available space
    header_end = base + 32 + sizeofcmds  # end of current load commands
    first_section = _find_first_section_offset(data[base:])
    if first_section < 0:
        print(f"  [-] Could not determine section offsets")
        return False
    first_section_abs = base + first_section
    available = first_section_abs - header_end

    print(f"  Header end: 0x{header_end:X}, first section: 0x{first_section_abs:X}, "
          f"available: {available}, need: {cmd_size}")

    if available < cmd_size:
        # Strip LC_CODE_SIGNATURE to reclaim header space (re-signed by ldid)
        freed = _strip_codesig(data, base)
        if freed > 0:
            ncmds = struct.unpack_from("<I", data, base + 16)[0]
            sizeofcmds = struct.unpack_from("<I", data, base + 20)[0]
            header_end = base + 32 + sizeofcmds
            available = first_section_abs - header_end
            print(f"  After strip: available={available}, need={cmd_size}")

    if available < cmd_size:
        overflow = cmd_size - available
        # Allow up to 256 bytes overflow (same behavior as optool/insert_dylib)
        if overflow > 256:
            print(f"  [-] Would overflow {overflow} bytes into section data (too much)")
            return False
        print(f"  [!] Header overflow: {overflow} bytes into section data "
              f"(same as optool — binary will be re-signed)")

    # Write the new load command at the end of existing commands
    data[header_end : header_end + cmd_size] = lc_data

    # Update header: ncmds += 1, sizeofcmds += cmd_size
    struct.pack_into("<I", data, base + 16, ncmds + 1)
    struct.pack_into("<I", data, base + 20, sizeofcmds + cmd_size)

    return True


def inject_dylib(filepath, dylib_path):
    """Inject LC_LOAD_DYLIB into a Mach-O binary (thin or universal/FAT).

    Equivalent to: optool install -c load -p <dylib_path> -t <filepath>
    """
    data = bytearray(open(filepath, "rb").read())
    slices = _get_fat_slices(bytes(data))

    injected = 0
    for slice_off, slice_size in slices:
        if _check_existing_dylib(data, slice_off, dylib_path):
            print(f"  [!] Dylib already loaded in slice at 0x{slice_off:X}, skipping")
            injected += 1
            continue

        if _inject_lc_load_dylib(data, slice_off, dylib_path):
            print(f"  [+] Injected LC_LOAD_DYLIB '{dylib_path}' at slice 0x{slice_off:X}")
            injected += 1

    if injected == len(slices):
        open(filepath, "wb").write(data)
        print(f"  [+] Wrote {filepath} ({injected} slice(s) patched)")
        return True
    else:
        print(f"  [-] Only {injected}/{len(slices)} slices patched")
        return False


# ══════════════════════════════════════════════════════════════════
# BuildManifest parsing
# ══════════════════════════════════════════════════════════════════


def parse_cryptex_paths(manifest_path):
    """Extract Cryptex DMG paths from BuildManifest.plist.

    Searches ALL BuildIdentities for:
    - Cryptex1,SystemOS -> Info -> Path
    - Cryptex1,AppOS -> Info -> Path

    vResearch IPSWs may have Cryptex entries in a non-first identity.
    """
    with open(manifest_path, "rb") as f:
        manifest = plistlib.load(f)

    # Search all BuildIdentities for Cryptex paths
    for bi in manifest.get("BuildIdentities", []):
        m = bi.get("Manifest", {})
        sysos = m.get("Cryptex1,SystemOS", {}).get("Info", {}).get("Path", "")
        appos = m.get("Cryptex1,AppOS", {}).get("Info", {}).get("Path", "")
        if sysos and appos:
            return sysos, appos

    print("[-] Cryptex1,SystemOS/AppOS paths not found in any BuildIdentity",
          file=sys.stderr)
    sys.exit(1)


# ══════════════════════════════════════════════════════════════════
# LaunchDaemon injection
# ══════════════════════════════════════════════════════════════════


def inject_daemons(plist_path, daemon_dir):
    """Inject bash/dropbear/trollvnc entries into launchd.plist."""
    # Convert to XML first (macOS binary plist -> XML)
    subprocess.run(["plutil", "-convert", "xml1", plist_path],
                   capture_output=True)

    with open(plist_path, "rb") as f:
        target = plistlib.load(f)

    for name in ("bash", "dropbear", "trollvnc"):
        src = os.path.join(daemon_dir, f"{name}.plist")
        if not os.path.exists(src):
            print(f"  [!] Missing {src}, skipping")
            continue

        with open(src, "rb") as f:
            daemon = plistlib.load(f)

        key = f"/System/Library/LaunchDaemons/{name}.plist"
        target.setdefault("LaunchDaemons", {})[key] = daemon
        print(f"  [+] Injected {name}")

    with open(plist_path, "wb") as f:
        plistlib.dump(target, f, sort_keys=False)


# ══════════════════════════════════════════════════════════════════
# CLI
# ══════════════════════════════════════════════════════════════════


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)

    cmd = sys.argv[1]

    if cmd == "cryptex-paths":
        if len(sys.argv) < 3:
            print("Usage: patch_cfw.py cryptex-paths <BuildManifest.plist>")
            sys.exit(1)
        sysos, appos = parse_cryptex_paths(sys.argv[2])
        print(sysos)
        print(appos)

    elif cmd == "patch-seputil":
        if len(sys.argv) < 3:
            print("Usage: patch_cfw.py patch-seputil <binary>")
            sys.exit(1)
        if not patch_seputil(sys.argv[2]):
            sys.exit(1)

    elif cmd == "patch-launchd-cache-loader":
        if len(sys.argv) < 3:
            print("Usage: patch_cfw.py patch-launchd-cache-loader <binary>")
            sys.exit(1)
        if not patch_launchd_cache_loader(sys.argv[2]):
            sys.exit(1)

    elif cmd == "patch-mobileactivationd":
        if len(sys.argv) < 3:
            print("Usage: patch_cfw.py patch-mobileactivationd <binary>")
            sys.exit(1)
        if not patch_mobileactivationd(sys.argv[2]):
            sys.exit(1)

    elif cmd == "patch-launchd-jetsam":
        if len(sys.argv) < 3:
            print("Usage: patch_cfw.py patch-launchd-jetsam <binary>")
            sys.exit(1)
        if not patch_launchd_jetsam(sys.argv[2]):
            sys.exit(1)

    elif cmd == "inject-daemons":
        if len(sys.argv) < 4:
            print("Usage: patch_cfw.py inject-daemons <launchd.plist> <daemon_dir>")
            sys.exit(1)
        inject_daemons(sys.argv[2], sys.argv[3])

    elif cmd == "inject-dylib":
        if len(sys.argv) < 4:
            print("Usage: patch_cfw.py inject-dylib <binary> <dylib_path>")
            sys.exit(1)
        if not inject_dylib(sys.argv[2], sys.argv[3]):
            sys.exit(1)

    else:
        print(f"Unknown command: {cmd}")
        print("Commands: cryptex-paths, patch-seputil, patch-launchd-cache-loader,")
        print("          patch-mobileactivationd, patch-launchd-jetsam,")
        print("          inject-daemons, inject-dylib")
        sys.exit(1)


if __name__ == "__main__":
    main()

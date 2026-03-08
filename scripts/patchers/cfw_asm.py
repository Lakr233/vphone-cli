"""Shared helpers for CFW patch modules."""
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
                sectname = data[sect_off : sect_off + 16].split(b"\x00")[0].decode()
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


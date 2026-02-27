#!/usr/bin/env python3
"""
patch_firmware.py — Patch all boot-chain components for vphone600.

Run this AFTER prepare_firmware.sh from the VM directory.

Usage:
    python3 patch_firmware.py [vm_directory]

    vm_directory defaults to the current working directory.
    The script auto-discovers the iPhone*_Restore directory and all
    firmware files by searching for known patterns.

Components patched:
  1. AVPBooter        — DGST validation bypass (mov x0, #0)
  2. iBSS             — serial labels + image4 callback bypass
  3. iBEC             — serial labels + image4 callback + boot-args
  4. LLB              — serial labels + image4 callback + boot-args + rootfs + panic
  5. TXM              — trustcache bypass (mov x0, #0)
  6. kernelcache      — 25 patches (APFS, MAC, debugger, launch constraints, etc.)

Dependencies:
    pip install keystone-engine capstone pyimg4

    If keystone fails to import, you may need the native library:
        brew install cmake && pip install keystone-engine
"""

import struct, sys, os, glob, subprocess, tempfile

from capstone import Cs, CS_ARCH_ARM64, CS_MODE_LITTLE_ENDIAN
from keystone import Ks, KS_ARCH_ARM64, KS_MODE_LITTLE_ENDIAN as KS_MODE_LE
from pyimg4 import IM4P
from kernel_patcher import KernelPatcher

# ══════════════════════════════════════════════════════════════════
# Assembler / disassembler helpers
# ══════════════════════════════════════════════════════════════════

_ks = Ks(KS_ARCH_ARM64, KS_MODE_LE)


def asm(s):
    enc, _ = _ks.asm(s)
    if not enc:
        raise RuntimeError(f"asm failed: {s}")
    return bytes(enc)


def u32(val):
    return struct.pack("<I", val)


NOP = asm("nop")
MOV_X0_0 = asm("mov x0, #0")

CHUNK_SIZE, OVERLAP = 0x2000, 0x100


def chunked_disasm(buf, base=0):
    md = Cs(CS_ARCH_ARM64, CS_MODE_LITTLE_ENDIAN)
    md.detail = True
    off = 0
    while off < len(buf):
        insns = list(md.disasm(buf[off:min(off + CHUNK_SIZE, len(buf))], base + off))
        yield insns
        off += CHUNK_SIZE - OVERLAP


def disasm_at(buf, off, n=12, base=0):
    md = Cs(CS_ARCH_ARM64, CS_MODE_LITTLE_ENDIAN)
    md.skipdata = True
    return list(md.disasm(buf[off:min(off + n * 4, len(buf))], base + off))


def disasm_one(buf, off):
    md = Cs(CS_ARCH_ARM64, CS_MODE_LITTLE_ENDIAN)
    md.skipdata = True
    insns = list(md.disasm(buf[off:off + 4], off))
    return f"{insns[0].mnemonic} {insns[0].op_str}" if insns else "???"


def rd32(buf, off):
    return struct.unpack_from("<I", buf, off)[0]


def wr32(buf, off, v):
    struct.pack_into("<I", buf, off, v)


# ══════════════════════════════════════════════════════════════════
# IM4P / raw file helpers — auto-detect format
# ══════════════════════════════════════════════════════════════════

def is_im4p(data):
    """Check if data is an IM4P container (ASN.1 DER with IM4P tag)."""
    try:
        IM4P(data)
        return True
    except Exception:
        return False


def load_firmware(path):
    """Load firmware file, auto-detecting IM4P vs raw.

    Returns (im4p_or_None, raw_bytearray, is_im4p_bool, original_bytes).
    """
    with open(path, "rb") as f:
        raw = f.read()

    try:
        im4p = IM4P(raw)
        if im4p.payload.compression:
            im4p.payload.decompress()
        return im4p, bytearray(im4p.payload.data), True, raw
    except Exception:
        return None, bytearray(raw), False, raw


def save_firmware(path, im4p_obj, patched_data, was_im4p, original_raw=None):
    """Save patched firmware, repackaging as IM4P if the original was IM4P.

    When original_raw is provided (preserve_payp=True), uses pyimg4 CLI to
    recompress with lzfse and then appends the PAYP structure from the original.
    This matches the approach used by the known-working patch_fw.py.
    """
    if was_im4p and im4p_obj is not None:
        if original_raw is not None:
            # Use pyimg4 CLI + lzfse recompression + PAYP preservation
            # (matches the working patch_fw.py approach exactly)
            _save_im4p_with_payp(path, im4p_obj.fourcc, patched_data, original_raw)
        else:
            # Simple IM4P repackage (no PAYP needed — boot chain components)
            new_im4p = IM4P(
                fourcc=im4p_obj.fourcc,
                description=im4p_obj.description,
                payload=bytes(patched_data),
            )
            with open(path, "wb") as f:
                f.write(new_im4p.output())
    else:
        with open(path, "wb") as f:
            f.write(patched_data)


def _save_im4p_with_payp(path, fourcc, patched_data, original_raw):
    """Repackage as lzfse-compressed IM4P and append PAYP from original."""
    with tempfile.NamedTemporaryFile(suffix=".raw", delete=False) as tmp_raw, \
         tempfile.NamedTemporaryFile(suffix=".im4p", delete=False) as tmp_im4p:
        tmp_raw_path = tmp_raw.name
        tmp_im4p_path = tmp_im4p.name
        tmp_raw.write(bytes(patched_data))

    try:
        # Recompress with lzfse via pyimg4 CLI
        subprocess.run(
            ["pyimg4", "im4p", "create",
             "-i", tmp_raw_path, "-o", tmp_im4p_path,
             "-f", fourcc, "--lzfse"],
            check=True, capture_output=True,
        )
        output = bytearray(open(tmp_im4p_path, "rb").read())
    finally:
        os.unlink(tmp_raw_path)
        os.unlink(tmp_im4p_path)

    # Append PAYP from original
    payp_offset = original_raw.rfind(b"PAYP")
    if payp_offset >= 0:
        payp_data = original_raw[payp_offset - 10:]
        output.extend(payp_data)
        # Fix outer DER SEQUENCE length at bytes[2:5]
        old_len = int.from_bytes(output[2:5], "big")
        output[2:5] = (old_len + len(payp_data)).to_bytes(3, "big")
        print(f"  [+] preserved PAYP ({len(payp_data)} bytes)")

    with open(path, "wb") as f:
        f.write(output)


# ══════════════════════════════════════════════════════════════════
# Shared patch primitives
# ══════════════════════════════════════════════════════════════════

# ── image4_validate_property_callback ─────────────────────────────

def find_image4_callback(buf, base):
    candidates = []
    for insns in chunked_disasm(buf, base):
        for i in range(len(insns) - 1):
            if insns[i].mnemonic != "b.ne":
                continue
            if not (insns[i + 1].mnemonic == "mov" and insns[i + 1].op_str == "x0, x22"):
                continue
            addr = insns[i].address
            if not any(insns[j].mnemonic == "cmp" for j in range(max(0, i - 8), i)):
                continue
            neg1 = any(
                (insns[j].mnemonic == "movn" and insns[j].op_str.startswith("w22,"))
                or (
                    insns[j].mnemonic == "mov"
                    and "w22" in insns[j].op_str
                    and ("#-1" in insns[j].op_str or "#0xffffffff" in insns[j].op_str)
                )
                for j in range(max(0, i - 64), i)
            )
            candidates.append((addr, neg1))
    if not candidates:
        return -1
    for a, n in candidates:
        if n:
            return a - base
    return candidates[-1][0] - base


def patch_image4_callback(data, base):
    off = find_image4_callback(bytes(data), base)
    if off < 0:
        print("  [-] image4 callback not found!")
        return False
    data[off:off + 4] = NOP
    data[off + 4:off + 8] = MOV_X0_0
    print(f"  0x{off:X}: b.ne -> nop, mov x0,x22 -> mov x0,#0")
    return True


# ── serial labels ─────────────────────────────────────────────────

SERIAL_OFFSETS = [0x84349, 0x843F4]


def patch_serial_labels(data, label):
    for off in SERIAL_OFFSETS:
        data[off:off + len(label)] = label
    print(f'  serial labels -> "{label.decode()}"')


# ── boot-args ─────────────────────────────────────────────────────

def encode_adrp(rd, pc, target):
    imm = ((target & ~0xFFF) - (pc & ~0xFFF)) >> 12
    imm &= (1 << 21) - 1
    return 0x90000000 | ((imm & 3) << 29) | ((imm >> 2) << 5) | (rd & 0x1F)


def encode_add(rd, rn, imm12):
    return 0x91000000 | ((imm12 & 0xFFF) << 10) | ((rn & 0x1F) << 5) | (rd & 0x1F)


def find_boot_args_fmt(buf):
    """Find the standalone '%s' format string near boot-args data."""
    anchor = buf.find(b"rd=md0")
    if anchor < 0:
        anchor = buf.find(b"BootArgs")
    if anchor < 0:
        return -1
    off = anchor
    while off < anchor + 0x40:
        off = buf.find(b"%s", off)
        if off < 0 or off >= anchor + 0x40:
            return -1
        if buf[off - 1] == 0 and buf[off + 2] == 0:
            return off
        off += 1
    return -1


def find_boot_args_adrp(buf, fmt_off, base):
    """Find ADRP+ADD x2 that loads the boot-args format string."""
    target_va = base + fmt_off
    for insns in chunked_disasm(buf, base):
        for i in range(len(insns) - 1):
            a, b = insns[i], insns[i + 1]
            if a.mnemonic != "adrp" or b.mnemonic != "add":
                continue
            if a.op_str.split(",")[0].strip() != "x2":
                continue
            if a.operands[0].reg != b.operands[1].reg:
                continue
            if len(b.operands) < 3:
                continue
            if a.operands[1].imm + b.operands[2].imm == target_va:
                return a.address - base, b.address - base
    return -1, -1


def find_string_slot(buf, string_len, search_start=0x14000):
    """Find a NUL-filled slot for the new boot-args string.

    Scans for zero regions >= 64 bytes, returns the first 16-byte-aligned
    offset with at least 8 bytes of zero padding before it.
    """
    off = search_start
    while off < len(buf):
        if buf[off] == 0:
            run_start = off
            while off < len(buf) and buf[off] == 0:
                off += 1
            if off - run_start >= 64:
                write_off = (run_start + 8 + 15) & ~15
                if write_off + string_len <= off:
                    return write_off
        else:
            off += 1
    return -1


BOOT_ARGS = b"serial=3 -v debug=0x2014e %s"


def patch_boot_args(data, base, new_args=BOOT_ARGS):
    fmt_off = find_boot_args_fmt(data)
    if fmt_off < 0:
        print("  [-] boot-args fmt not found")
        return False
    adrp_off, add_off = find_boot_args_adrp(bytes(data), fmt_off, base)
    if adrp_off < 0:
        print("  [-] ADRP+ADD x2 not found")
        return False
    new_off = find_string_slot(data, len(new_args))
    if new_off < 0:
        print("  [-] no NUL slot")
        return False
    new_va = base + new_off
    data[new_off:new_off + len(new_args)] = new_args
    wr32(data, adrp_off, encode_adrp(2, base + adrp_off, new_va))
    wr32(data, add_off, encode_add(2, 2, new_va & 0xFFF))
    print(f'  boot-args -> "{new_args.decode()}" at 0x{new_off:X}')
    return True


# ── fixed-offset patches ─────────────────────────────────────────

def apply_fixed_patches(data, patches):
    for off, val, desc in patches:
        if off + 4 > len(data):
            print(f"  SKIP 0x{off:X}: out of range")
            continue
        new = asm(val) if isinstance(val, str) else u32(val)
        data[off:off + 4] = new
        print(f"  0x{off:08X}: {desc}")


# ══════════════════════════════════════════════════════════════════
# Per-component patch functions
# ══════════════════════════════════════════════════════════════════

# ── 1. AVPBooter ──────────────────────────────────────────────────

AVP_BASE = 0x100000
AVP_SEARCH = "0x4447"
RET_MNEMONICS = {"ret", "retaa", "retab"}


def patch_avpbooter(data):
    md = Cs(CS_ARCH_ARM64, CS_MODE_LITTLE_ENDIAN)
    md.skipdata = True
    insns = list(md.disasm(bytes(data), AVP_BASE))

    hits = [i for i in insns if AVP_SEARCH in f"{i.mnemonic} {i.op_str}"]
    if not hits:
        print("  [-] DGST constant not found")
        return False

    addr2idx = {insn.address: i for i, insn in enumerate(insns)}
    idx = addr2idx[hits[0].address]

    ret_idx = None
    for i in range(idx, min(idx + 512, len(insns))):
        if insns[i].mnemonic in RET_MNEMONICS:
            ret_idx = i
            break
    if ret_idx is None:
        print("  [-] epilogue not found")
        return False

    x0_idx = None
    for i in range(ret_idx - 1, max(ret_idx - 32, -1), -1):
        op, mn = insns[i].op_str, insns[i].mnemonic
        if mn == "mov" and op.startswith(("x0,", "w0,")):
            x0_idx = i
            break
        if mn in ("cset", "csinc", "csinv", "csneg") and op.startswith(("x0,", "w0,")):
            x0_idx = i
            break
        if mn in RET_MNEMONICS or mn in ("b", "bl", "br", "blr"):
            break
    if x0_idx is None:
        print("  [-] x0 setter not found")
        return False

    target = insns[x0_idx]
    file_off = target.address - AVP_BASE
    data[file_off:file_off + 4] = MOV_X0_0
    print(f"  0x{file_off:X}: {target.mnemonic} {target.op_str} -> mov x0, #0")
    return True


# ── 2. iBSS ──────────────────────────────────────────────────────

IBOOT_BASE = 0x7006C000


def patch_ibss(data):
    patch_serial_labels(data, b"Loaded iBSS")
    return patch_image4_callback(data, IBOOT_BASE)


# ── 3. iBEC ──────────────────────────────────────────────────────

def patch_ibec(data):
    patch_serial_labels(data, b"Loaded iBEC")
    if not patch_image4_callback(data, IBOOT_BASE):
        return False
    return patch_boot_args(data, IBOOT_BASE)


# ── 4. LLB ───────────────────────────────────────────────────────

LLB_FIXED_PATCHES = [
    (0x2AFE8, 0x1400000B, "b +0x2c: skip sig check"),
    (0x2ACA0, "nop", "NOP sig verify"),
    (0x2B03C, 0x17FFFF6A, "b -0x258"),
    (0x2ECEC, "nop", "NOP verify"),
    (0x2EEE8, 0x14000009, "b +0x24"),
    (0x1A64C, "nop", "NOP: bypass panic"),
]


def patch_llb(data):
    patch_serial_labels(data, b"Loaded LLB")
    if not patch_image4_callback(data, IBOOT_BASE):
        return False
    if not patch_boot_args(data, IBOOT_BASE):
        return False
    apply_fixed_patches(data, LLB_FIXED_PATCHES)
    return True


# ── 5. TXM ───────────────────────────────────────────────────────

TXM_PATCHES = [
    (0x2C1F8, "mov x0, #0", "trustcache bypass"),
]


def patch_txm(data):
    apply_fixed_patches(data, TXM_PATCHES)
    return True


# ── 6. Kernelcache ───────────────────────────────────────────────

def patch_kernelcache(data):
    """Dynamically patch kernelcache using KernelPatcher — no hardcoded offsets."""
    kp = KernelPatcher(data)
    n = kp.apply()
    print(f"  [+] {n} kernel patches applied dynamically")
    return n > 0


# ══════════════════════════════════════════════════════════════════
# File discovery
# ══════════════════════════════════════════════════════════════════

def find_restore_dir(base_dir):
    """Auto-detect the iPhone restore directory."""
    for entry in sorted(os.listdir(base_dir)):
        full = os.path.join(base_dir, entry)
        if os.path.isdir(full) and "Restore" in entry:
            return full
    return None


def find_file(base_dir, patterns, label):
    """Search for a file matching any of the given glob patterns.

    Returns the first match, or exits with error if none found.
    """
    for pattern in patterns:
        matches = sorted(glob.glob(os.path.join(base_dir, pattern)))
        if matches:
            return matches[0]
    print(f"[-] {label} not found. Searched patterns:")
    for p in patterns:
        print(f"    {os.path.join(base_dir, p)}")
    sys.exit(1)


# ══════════════════════════════════════════════════════════════════
# Main
# ══════════════════════════════════════════════════════════════════

COMPONENTS = [
    # (name, search_base_is_restore, search_patterns, patch_function, preserve_payp)
    # search_base_is_restore: False = search in vm_dir, True = search in restore_dir
    # preserve_payp: True only for TXM/kernelcache (key constraints).
    #   iBSS/iBEC/LLB PAYP is compression metadata — appending it to an
    #   uncompressed IM4P causes "Memory image not valid".
    # Patterns are tried in order; first match wins. Most-specific first to avoid
    # picking d47/release/iphone17 variants that sort alphabetically before the
    # vresearch101/research.vphone600 variants we actually need.
    ("AVPBooter", False, ["AVPBooter*.bin"], patch_avpbooter, False),
    ("iBSS", True, [
        "Firmware/dfu/iBSS.vresearch101.RELEASE.im4p",
        "Firmware/dfu/iBSS.vresearch101*.im4p",
        "Firmware/dfu/iBSS*.im4p",
        "Firmware/dfu/iBSS*.raw",
    ], patch_ibss, False),
    ("iBEC", True, [
        "Firmware/dfu/iBEC.vresearch101.RELEASE.im4p",
        "Firmware/dfu/iBEC.vresearch101*.im4p",
        "Firmware/dfu/iBEC*.im4p",
        "Firmware/dfu/iBEC*.raw",
    ], patch_ibec, False),
    ("LLB", True, [
        "Firmware/all_flash/LLB.vresearch101.RELEASE.im4p",
        "Firmware/all_flash/LLB.vresearch101*.im4p",
        "Firmware/all_flash/LLB*.im4p",
        "Firmware/all_flash/LLB*.raw",
    ], patch_llb, False),
    ("TXM", True, [
        "Firmware/txm.iphoneos.research.im4p",
        "Firmware/txm*research*.im4p",
        "Firmware/txm*.im4p",
        "Firmware/txm*.raw",
    ], patch_txm, True),
    ("kernelcache", True, [
        "kernelcache.research.vphone600",
        "kernelcache.research.vresearch101",
        "kernelcache.research.v*",
        "kernelcache*",
    ], patch_kernelcache, True),
]


def patch_component(path, patch_fn, name, preserve_payp):
    """Load firmware (auto-detect IM4P vs raw), patch, save."""
    print(f"\n{'=' * 60}")
    print(f"  {name}: {path}")
    print(f"{'=' * 60}")

    im4p, data, was_im4p, original_raw = load_firmware(path)
    fmt = "IM4P" if was_im4p else "raw"
    extra = ""
    if was_im4p and im4p:
        extra = f", fourcc={im4p.fourcc}"
    print(f"  format: {fmt}{extra}, {len(data)} bytes")

    if not patch_fn(data):
        print(f"  [-] FAILED: {name}")
        sys.exit(1)

    save_firmware(path, im4p, data, was_im4p,
                  original_raw if preserve_payp else None)
    print(f"  [+] saved ({fmt})")


def main():
    vm_dir = sys.argv[1] if len(sys.argv) > 1 else os.getcwd()
    vm_dir = os.path.abspath(vm_dir)

    if not os.path.isdir(vm_dir):
        print(f"[-] Not a directory: {vm_dir}")
        sys.exit(1)

    restore_dir = find_restore_dir(vm_dir)
    if not restore_dir:
        print(f"[-] No *Restore* directory found in {vm_dir}")
        print("    Run prepare_firmware_v2.sh first.")
        sys.exit(1)

    print(f"[*] VM directory:      {vm_dir}")
    print(f"[*] Restore directory: {restore_dir}")
    print(f"[*] Patching {len(COMPONENTS)} boot-chain components ...")

    for name, in_restore, patterns, patch_fn, preserve_payp in COMPONENTS:
        search_base = restore_dir if in_restore else vm_dir
        path = find_file(search_base, patterns, name)
        patch_component(path, patch_fn, name, preserve_payp)

    print(f"\n{'=' * 60}")
    print(f"  All {len(COMPONENTS)} components patched successfully!")
    print(f"{'=' * 60}")


if __name__ == "__main__":
    main()

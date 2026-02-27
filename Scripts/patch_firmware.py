#!/usr/bin/env python3
"""
patch_firmware.py — Patch all boot-chain components for vphone600.

Run this AFTER prepare_firmware.sh from the VM directory.

Usage:
    python3 patch_firmware.py [vm_directory]

    vm_directory defaults to the current working directory.
    The script auto-discovers the iPhone*_Restore directory and all
    firmware files by searching for known patterns.

Components patched (ALL dynamically — no hardcoded offsets):
  1. AVPBooter        — DGST validation bypass (mov x0, #0)
  2. iBSS             — serial labels + image4 callback bypass
  3. iBEC             — serial labels + image4 callback + boot-args
  4. LLB              — serial labels + image4 callback + boot-args + rootfs + panic
  5. TXM              — trustcache bypass (mov x0, #0)
  6. kernelcache      — 25 patches (APFS, MAC, debugger, launch constraints, etc.)

Dependencies:
    pip install keystone-engine capstone pyimg4
"""

import sys, os, glob, subprocess, tempfile

from capstone import Cs, CS_ARCH_ARM64, CS_MODE_LITTLE_ENDIAN
from keystone import Ks, KS_ARCH_ARM64, KS_MODE_LITTLE_ENDIAN as KS_MODE_LE
from pyimg4 import IM4P

from kernel_patcher import KernelPatcher
from iboot_patcher import IBootPatcher
from txm_patcher import TXMPatcher

# ══════════════════════════════════════════════════════════════════
# Assembler helpers (for AVPBooter only — iBoot/TXM/kernel are
# handled by their own patcher classes)
# ══════════════════════════════════════════════════════════════════

_ks = Ks(KS_ARCH_ARM64, KS_MODE_LE)


def _asm(s):
    enc, _ = _ks.asm(s)
    if not enc:
        raise RuntimeError(f"asm failed: {s}")
    return bytes(enc)


MOV_X0_0 = _asm("mov x0, #0")
RET_MNEMONICS = {"ret", "retaa", "retab"}


# ══════════════════════════════════════════════════════════════════
# IM4P / raw file helpers — auto-detect format
# ══════════════════════════════════════════════════════════════════

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
    """Save patched firmware, repackaging as IM4P if the original was IM4P."""
    if was_im4p and im4p_obj is not None:
        if original_raw is not None:
            _save_im4p_with_payp(path, im4p_obj.fourcc, patched_data, original_raw)
        else:
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

    payp_offset = original_raw.rfind(b"PAYP")
    if payp_offset >= 0:
        payp_data = original_raw[payp_offset - 10:]
        output.extend(payp_data)
        old_len = int.from_bytes(output[2:5], "big")
        output[2:5] = (old_len + len(payp_data)).to_bytes(3, "big")
        print(f"  [+] preserved PAYP ({len(payp_data)} bytes)")

    with open(path, "wb") as f:
        f.write(output)


# ══════════════════════════════════════════════════════════════════
# Per-component patch functions
# ══════════════════════════════════════════════════════════════════

# ── 1. AVPBooter ──────────────────────────────────────────────────
# Already dynamic — finds DGST constant, locates x0 setter before
# ret, replaces with mov x0, #0.  Base address is irrelevant
# (cancels out in the offset calculation).

AVP_SEARCH = "0x4447"


def patch_avpbooter(data):
    md = Cs(CS_ARCH_ARM64, CS_MODE_LITTLE_ENDIAN)
    md.skipdata = True
    insns = list(md.disasm(bytes(data), 0))

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
    file_off = target.address
    data[file_off:file_off + 4] = MOV_X0_0
    print(f"  0x{file_off:X}: {target.mnemonic} {target.op_str} -> mov x0, #0")
    return True


# ── 2–4. iBSS / iBEC / LLB ───────────────────────────────────────
# Fully dynamic via IBootPatcher — no hardcoded offsets.

def patch_ibss(data):
    p = IBootPatcher(data, mode='ibss', label="Loaded iBSS")
    n = p.apply()
    print(f"  [+] {n} iBSS patches applied dynamically")
    return n > 0


def patch_ibec(data):
    p = IBootPatcher(data, mode='ibec', label="Loaded iBEC")
    n = p.apply()
    print(f"  [+] {n} iBEC patches applied dynamically")
    return n > 0


def patch_llb(data):
    p = IBootPatcher(data, mode='llb', label="Loaded LLB")
    n = p.apply()
    print(f"  [+] {n} LLB patches applied dynamically")
    return n > 0


# ── 5. TXM ───────────────────────────────────────────────────────
# Fully dynamic via TXMPatcher — no hardcoded offsets.

def patch_txm(data):
    p = TXMPatcher(data)
    n = p.apply()
    print(f"  [+] {n} TXM patches applied dynamically")
    return n > 0


# ── 6. Kernelcache ───────────────────────────────────────────────
# Fully dynamic via KernelPatcher — no hardcoded offsets.

def patch_kernelcache(data):
    kp = KernelPatcher(data)
    n = kp.apply()
    print(f"  [+] {n} kernel patches applied dynamically")
    return n > 0


# ══════════════════════════════════════════════════════════════════
# File discovery
# ══════════════════════════════════════════════════════════════════

def find_restore_dir(base_dir):
    for entry in sorted(os.listdir(base_dir)):
        full = os.path.join(base_dir, entry)
        if os.path.isdir(full) and "Restore" in entry:
            return full
    return None


def find_file(base_dir, patterns, label):
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
    ("AVPBooter", False, ["AVPBooter*.bin"], patch_avpbooter, False),
    ("iBSS", True, ["Firmware/dfu/iBSS.vresearch101.RELEASE.im4p"], patch_ibss, False),
    ("iBEC", True, ["Firmware/dfu/iBEC.vresearch101.RELEASE.im4p"], patch_ibec, False),
    ("LLB", True, ["Firmware/all_flash/LLB.vresearch101.RELEASE.im4p"], patch_llb, False),
    ("TXM", True, ["Firmware/txm.iphoneos.research.im4p"], patch_txm, True),
    ("kernelcache", True, ["kernelcache.release.vphone600"], patch_kernelcache, True),
]


def patch_component(path, patch_fn, name, preserve_payp):
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

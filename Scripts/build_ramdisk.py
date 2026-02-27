#!/usr/bin/env python3
"""
build_ramdisk.py — Build a signed SSH ramdisk for vphone600.

Expects firmware already patched by patch_firmware.py.
Extracts patched components, signs with SHSH, and builds SSH ramdisk.

Usage:
    python3 build_ramdisk.py [vm_directory]

Directory structure:
    ./shsh/              — SHSH blobs (auto-discovered)
    ./ramdisk_input/     — Tools and SSH resources (auto-setup from CFW)
    ./ramdisk_builder_temp/ — Intermediate .raw files (cleaned up)
    ./Ramdisk/           — Final signed IMG4 output

Prerequisites:
    pip install keystone-engine capstone pyimg4
    Run patch_firmware.py first to patch boot-chain components.
"""

import gzip
import glob
import os
import shutil
import struct
import subprocess
import sys
import tempfile

# Ensure sibling modules (patch_firmware) are importable when run from any CWD
_SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
if _SCRIPT_DIR not in sys.path:
    sys.path.insert(0, _SCRIPT_DIR)

from keystone import Ks, KS_ARCH_ARM64, KS_MODE_LITTLE_ENDIAN as KS_MODE_LE
from pyimg4 import IM4P

from patch_firmware import (
    load_firmware,
    _save_im4p_with_payp,
    patch_txm,
    find_restore_dir,
    find_file,
)
from iboot_patcher import IBootPatcher

# ══════════════════════════════════════════════════════════════════
# ARM64 assembler
# ══════════════════════════════════════════════════════════════════

_ks = Ks(KS_ARCH_ARM64, KS_MODE_LE)


def asm(s, addr=0):
    """Assemble an ARM64 instruction string to bytes."""
    enc, _ = _ks.asm(s, addr)
    if not enc:
        raise RuntimeError(f"asm failed: {s}")
    return bytes(enc)


def asm_u32(s, addr=0):
    """Assemble an ARM64 instruction and return as little-endian u32."""
    return struct.unpack("<I", asm(s, addr))[0]


# ══════════════════════════════════════════════════════════════════
# Configuration
# ══════════════════════════════════════════════════════════════════

OUTPUT_DIR = "Ramdisk"
TEMP_DIR = "ramdisk_builder_temp"
INPUT_DIR = "ramdisk_input"

# Default location to copy resources from
CFW_DIR = os.path.expanduser(
    "~/Documents/GitHub/super-tart-vphone-private/CFW"
)

# Ramdisk boot-args
RAMDISK_BOOT_ARGS = b"serial=3 rd=md0 debug=0x2014e -v wdt=-1 %s"

# IM4P fourccs for restore mode
TXM_FOURCC = "trxm"
KERNEL_FOURCC = "rkrn"

# Files to remove from ramdisk to save space
RAMDISK_REMOVE = [
    "usr/bin/img4tool", "usr/bin/img4",
    "usr/sbin/dietappleh13camerad", "usr/sbin/dietappleh16camerad",
    "usr/local/bin/wget", "usr/local/bin/procexp",
]

# Directories to re-sign in ramdisk
SIGN_DIRS = [
    "usr/local/bin/*", "usr/local/lib/*",
    "usr/bin/*", "bin/*",
    "usr/lib/*", "sbin/*", "usr/sbin/*", "usr/libexec/*",
]

# Compressed archive of ramdisk_input/ (located next to this script)
INPUT_ARCHIVE = "ramdisk_input.tar.zst"


# ══════════════════════════════════════════════════════════════════
# Setup — extract ramdisk_input/ from zstd archive if needed
# ══════════════════════════════════════════════════════════════════

def setup_input(vm_dir):
    """Ensure ramdisk_input/ exists, extracting from .tar.zst if needed."""
    input_dir = os.path.join(vm_dir, INPUT_DIR)

    if os.path.isdir(input_dir):
        return input_dir

    # Look for archive next to this script, then in vm_dir
    for search_dir in (_SCRIPT_DIR, vm_dir):
        archive = os.path.join(search_dir, INPUT_ARCHIVE)
        if os.path.isfile(archive):
            print(f"  Extracting {INPUT_ARCHIVE}...")
            subprocess.run(
                ["tar", "--zstd", "-xf", archive, "-C", vm_dir],
                check=True,
            )
            return input_dir

    print(f"[-] Neither {INPUT_DIR}/ nor {INPUT_ARCHIVE} found.")
    print(f"    Place {INPUT_ARCHIVE} next to this script or in the VM directory.")
    sys.exit(1)


# ══════════════════════════════════════════════════════════════════
# SHSH / signing helpers
# ══════════════════════════════════════════════════════════════════

def find_shsh(shsh_dir):
    """Find first SHSH blob in directory."""
    for ext in ("*.shsh", "*.shsh2"):
        matches = sorted(glob.glob(os.path.join(shsh_dir, ext)))
        if matches:
            return matches[0]
    return None


def extract_im4m(shsh_path, im4m_path):
    """Extract IM4M manifest from SHSH blob (handles gzip-compressed)."""
    raw = open(shsh_path, "rb").read()
    if raw[:2] == b"\x1f\x8b":
        raw = gzip.decompress(raw)
    tmp = shsh_path + ".tmp"
    try:
        open(tmp, "wb").write(raw)
        subprocess.run(
            ["pyimg4", "im4m", "extract", "-i", tmp, "-o", im4m_path],
            check=True, capture_output=True,
        )
    finally:
        if os.path.exists(tmp):
            os.remove(tmp)


def sign_img4(im4p_path, img4_path, im4m_path, tag=None, input_dir="."):
    """Create IMG4 from IM4P + IM4M. Uses tools/img4 for tag override."""
    if tag:
        img4_tool = os.path.join(input_dir, "tools/img4")
        subprocess.run(
            [img4_tool, "-i", im4p_path, "-o", img4_path,
             "-M", im4m_path, "-T", tag],
            check=True, capture_output=True,
        )
    else:
        subprocess.run(
            ["pyimg4", "img4", "create",
             "-p", im4p_path, "-o", img4_path, "-m", im4m_path],
            check=True, capture_output=True,
        )


def run(cmd, **kwargs):
    """Run a command, raising on failure."""
    return subprocess.run(cmd, check=True, **kwargs)


# ══════════════════════════════════════════════════════════════════
# Firmware extraction and IM4P creation
# ══════════════════════════════════════════════════════════════════

def extract_to_raw(src_path, raw_path):
    """Extract IM4P payload to .raw file. Returns (im4p_obj, data, original_raw)."""
    im4p, data, was_im4p, original_raw = load_firmware(src_path)
    with open(raw_path, "wb") as f:
        f.write(bytes(data))
    return im4p, data, original_raw


def create_im4p_uncompressed(raw_data, fourcc, description, output_path):
    """Create uncompressed IM4P from raw data."""
    new_im4p = IM4P(
        fourcc=fourcc,
        description=description,
        payload=bytes(raw_data),
    )
    with open(output_path, "wb") as f:
        f.write(new_im4p.output())


# ══════════════════════════════════════════════════════════════════
# iBEC boot-args patching
# ══════════════════════════════════════════════════════════════════

def patch_ibec_bootargs(data):
    """Replace normal boot-args with ramdisk boot-args in already-patched iBEC.

    Finds the boot-args string written by patch_firmware.py (via IBootPatcher)
    and overwrites it in-place. No hardcoded offsets needed — the ADRP+ADD
    instructions already point to the string location.
    """
    normal_args = IBootPatcher.BOOT_ARGS
    off = data.find(normal_args)
    if off < 0:
        print(f"  [-] boot-args: existing string not found ({normal_args.decode()!r})")
        return False

    args = RAMDISK_BOOT_ARGS + b"\x00"
    data[off:off + len(args)] = args

    # Zero out any leftover from the previous string
    end = off + len(args)
    while end < len(data) and data[end] != 0:
        data[end] = 0
        end += 1

    print(f'  boot-args -> "{RAMDISK_BOOT_ARGS.decode()}" at 0x{off:X}')
    return True


# ══════════════════════════════════════════════════════════════════
# Ramdisk DMG building
# ══════════════════════════════════════════════════════════════════

def build_ramdisk(restore_dir, im4m_path, vm_dir, input_dir, output_dir, temp_dir):
    """Build custom SSH ramdisk from restore DMG."""
    ramdisk_src = find_file(restore_dir, ["043-53775-129.dmg"], "ramdisk DMG")
    mountpoint = os.path.join(vm_dir, "SSHRD")
    ramdisk_raw = os.path.join(temp_dir, "ramdisk.raw.dmg")
    ramdisk_custom = os.path.join(temp_dir, "ramdisk1.dmg")

    # Extract base ramdisk
    print("  Extracting base ramdisk...")
    run(["pyimg4", "im4p", "extract", "-i", ramdisk_src, "-o", ramdisk_raw],
        capture_output=True)

    os.makedirs(mountpoint, exist_ok=True)

    try:
        # Mount, create expanded copy
        print("  Mounting base ramdisk...")
        run(["sudo", "hdiutil", "attach", "-mountpoint", mountpoint,
             ramdisk_raw, "-owners", "off"])

        print("  Creating expanded ramdisk (254 MB)...")
        run(["sudo", "hdiutil", "create", "-size", "254m",
             "-imagekey", "diskimage-class=CRawDiskImage",
             "-format", "UDZO", "-fs", "APFS", "-layout", "NONE",
             "-srcfolder", mountpoint, "-copyuid", "root",
             ramdisk_custom])
        run(["sudo", "hdiutil", "detach", "-force", mountpoint])

        # Mount expanded, inject SSH
        print("  Mounting expanded ramdisk...")
        run(["sudo", "hdiutil", "attach", "-mountpoint", mountpoint,
             ramdisk_custom, "-owners", "off"])

        print("  Injecting SSH tools...")
        gtar = os.path.join(input_dir, "tools/gtar")
        ssh_tar = os.path.join(input_dir, "ssh.tar.gz")
        run(["sudo", gtar, "-x", "--no-overwrite-dir",
             "-f", ssh_tar, "-C", mountpoint])

        # Remove unnecessary files
        for rel_path in RAMDISK_REMOVE:
            full = os.path.join(mountpoint, rel_path)
            if os.path.exists(full):
                os.remove(full)

        # Re-sign Mach-O binaries
        print("  Re-signing Mach-O binaries...")
        ldid = os.path.join(input_dir, "tools/ldid_macosx_arm64")
        signcert = os.path.join(input_dir, "signcert.p12")

        for pattern in SIGN_DIRS:
            for path in glob.glob(os.path.join(mountpoint, pattern)):
                if os.path.isfile(path) and not os.path.islink(path):
                    if "Mach-O" in subprocess.getoutput(f'file "{path}"'):
                        subprocess.run(
                            [ldid, "-S", "-M", f"-K{signcert}", path],
                            capture_output=True,
                        )

        # Fix sftp-server entitlements
        sftp_ents = os.path.join(input_dir, "sftp_server_ents.plist")
        sftp_server = os.path.join(mountpoint, "usr/libexec/sftp-server")
        if os.path.exists(sftp_server):
            run([ldid, f"-S{sftp_ents}", "-M", f"-K{signcert}", sftp_server])

        # Build trustcache
        print("  Building trustcache...")
        tc_tool = os.path.join(input_dir, "tools/trustcache_macos_arm64")
        tc_raw = os.path.join(temp_dir, "sshrd.raw.tc")
        tc_im4p = os.path.join(temp_dir, "trustcache.im4p")

        run([tc_tool, "create", tc_raw, mountpoint])
        run(["pyimg4", "im4p", "create", "-i", tc_raw, "-o", tc_im4p,
             "-f", "rtsc"], capture_output=True)
        sign_img4(tc_im4p, os.path.join(output_dir, "trustcache.img4"),
                  im4m_path, input_dir=input_dir)
        print(f"  [+] trustcache.img4")

    finally:
        subprocess.run(["sudo", "hdiutil", "detach", "-force", mountpoint],
                       capture_output=True)

    # Shrink and sign ramdisk
    run(["sudo", "hdiutil", "resize", "-sectors", "min", ramdisk_custom])

    print("  Signing ramdisk...")
    rd_im4p = os.path.join(temp_dir, "ramdisk.im4p")
    run(["pyimg4", "im4p", "create", "-i", ramdisk_custom, "-o", rd_im4p,
         "-f", "rdsk"], capture_output=True)
    sign_img4(rd_im4p, os.path.join(output_dir, "ramdisk.img4"),
              im4m_path, input_dir=input_dir)
    print(f"  [+] ramdisk.img4")


# ══════════════════════════════════════════════════════════════════
# Main
# ══════════════════════════════════════════════════════════════════

def main():
    vm_dir = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else os.getcwd())

    if not os.path.isdir(vm_dir):
        print(f"[-] Not a directory: {vm_dir}")
        sys.exit(1)

    # Find SHSH
    shsh_dir = os.path.join(vm_dir, "shsh")
    shsh_path = find_shsh(shsh_dir)
    if not shsh_path:
        print(f"[-] No SHSH blob found in {shsh_dir}/")
        print("    Place your .shsh file in the shsh/ directory.")
        sys.exit(1)

    # Find restore directory
    restore_dir = find_restore_dir(vm_dir)
    if not restore_dir:
        print(f"[-] No *Restore* directory found in {vm_dir}")
        sys.exit(1)

    # Check pyimg4 CLI
    try:
        subprocess.run(["pyimg4", "--help"], capture_output=True, check=True)
    except (FileNotFoundError, subprocess.CalledProcessError):
        print("[-] pyimg4 CLI not found. Install with: pip install pyimg4")
        sys.exit(1)

    # Setup input resources (copy from CFW if needed)
    print(f"[*] Setting up {INPUT_DIR}/...")
    input_dir = setup_input(vm_dir)

    # Create temp and output directories
    temp_dir = os.path.join(vm_dir, TEMP_DIR)
    output_dir = os.path.join(vm_dir, OUTPUT_DIR)
    for d in (temp_dir, output_dir):
        if os.path.exists(d):
            shutil.rmtree(d)
        os.makedirs(d)

    print(f"[*] VM directory:      {vm_dir}")
    print(f"[*] Restore directory: {restore_dir}")
    print(f"[*] SHSH blob:         {shsh_path}")

    # Extract IM4M from SHSH
    im4m_path = os.path.join(temp_dir, "vphone.im4m")
    print(f"\n[*] Extracting IM4M from SHSH...")
    extract_im4m(shsh_path, im4m_path)

    # ── 1. iBSS (already patched by patch_firmware.py) ───────────
    print(f"\n{'=' * 60}")
    print(f"  1. iBSS (already patched — extract & sign)")
    print(f"{'=' * 60}")
    ibss_src = find_file(restore_dir, [
        "Firmware/dfu/iBSS.vresearch101.RELEASE.im4p",
    ], "iBSS")
    ibss_raw = os.path.join(temp_dir, "iBSS.raw")
    ibss_im4p = os.path.join(temp_dir, "iBSS.im4p")
    im4p_obj, data, _ = extract_to_raw(ibss_src, ibss_raw)
    create_im4p_uncompressed(data, im4p_obj.fourcc, im4p_obj.description, ibss_im4p)
    sign_img4(ibss_im4p, os.path.join(output_dir, "iBSS.vresearch101.RELEASE.img4"),
              im4m_path, input_dir=input_dir)
    print(f"  [+] iBSS.vresearch101.RELEASE.img4")

    # ── 2. iBEC (already patched — just fix boot-args for ramdisk)
    print(f"\n{'=' * 60}")
    print(f"  2. iBEC (patch boot-args for ramdisk)")
    print(f"{'=' * 60}")
    ibec_src = find_file(restore_dir, [
        "Firmware/dfu/iBEC.vresearch101.RELEASE.im4p",
    ], "iBEC")
    ibec_raw = os.path.join(temp_dir, "iBEC.raw")
    ibec_im4p = os.path.join(temp_dir, "iBEC.im4p")
    im4p_obj, data, _ = extract_to_raw(ibec_src, ibec_raw)
    patch_ibec_bootargs(data)
    create_im4p_uncompressed(data, im4p_obj.fourcc, im4p_obj.description, ibec_im4p)
    sign_img4(ibec_im4p, os.path.join(output_dir, "iBEC.vresearch101.RELEASE.img4"),
              im4m_path, input_dir=input_dir)
    print(f"  [+] iBEC.vresearch101.RELEASE.img4")

    # ── 3. SPTM (sign only) ─────────────────────────────────────
    print(f"\n{'=' * 60}")
    print(f"  3. SPTM (sign only)")
    print(f"{'=' * 60}")
    sptm_src = find_file(restore_dir, [
        "Firmware/sptm.vresearch1.release.im4p",
    ], "SPTM")
    sign_img4(sptm_src, os.path.join(output_dir, "sptm.vresearch1.release.img4"),
              im4m_path, tag="sptm", input_dir=input_dir)
    print(f"  [+] sptm.vresearch1.release.img4")

    # ── 4. DeviceTree (sign only) ────────────────────────────────
    print(f"\n{'=' * 60}")
    print(f"  4. DeviceTree (sign only)")
    print(f"{'=' * 60}")
    dt_src = find_file(restore_dir, [
        "Firmware/all_flash/DeviceTree.vphone600ap.im4p",
    ], "DeviceTree")
    sign_img4(dt_src, os.path.join(output_dir, "DeviceTree.vphone600ap.img4"),
              im4m_path, tag="rdtr", input_dir=input_dir)
    print(f"  [+] DeviceTree.vphone600ap.img4")

    # ── 5. SEP (sign only) ───────────────────────────────────────
    print(f"\n{'=' * 60}")
    print(f"  5. SEP (sign only)")
    print(f"{'=' * 60}")
    sep_src = find_file(restore_dir, [
        "Firmware/all_flash/sep-firmware.vresearch101.RELEASE.im4p",
    ], "SEP")
    sign_img4(sep_src, os.path.join(output_dir, "sep-firmware.vresearch101.RELEASE.img4"),
              im4m_path, tag="rsep", input_dir=input_dir)
    print(f"  [+] sep-firmware.vresearch101.RELEASE.img4")

    # ── 6. TXM (release variant — needs patching) ────────────────
    print(f"\n{'=' * 60}")
    print(f"  6. TXM (patch release variant)")
    print(f"{'=' * 60}")
    txm_src = find_file(restore_dir, [
        "Firmware/txm.iphoneos.release.im4p",
    ], "TXM")
    txm_raw = os.path.join(temp_dir, "txm.raw")
    im4p_obj, data, original_raw = extract_to_raw(txm_src, txm_raw)
    patch_txm(data)
    txm_im4p = os.path.join(temp_dir, "txm.im4p")
    _save_im4p_with_payp(txm_im4p, TXM_FOURCC, data, original_raw)
    sign_img4(txm_im4p, os.path.join(output_dir, "txm.img4"),
              im4m_path, input_dir=input_dir)
    print(f"  [+] txm.img4")

    # ── 7. Kernelcache (already patched — repack with rkrn) ──────
    print(f"\n{'=' * 60}")
    print(f"  7. Kernelcache (already patched — repack as rkrn)")
    print(f"{'=' * 60}")
    kc_src = find_file(restore_dir, [
        "kernelcache.research.vphone600",
    ], "kernelcache")
    kc_raw = os.path.join(temp_dir, "kcache.raw")
    im4p_obj, data, original_raw = extract_to_raw(kc_src, kc_raw)
    print(f"  format: IM4P, {len(data)} bytes")
    kc_im4p = os.path.join(temp_dir, "krnl.im4p")
    _save_im4p_with_payp(kc_im4p, KERNEL_FOURCC, data, original_raw)
    sign_img4(kc_im4p, os.path.join(output_dir, "krnl.img4"),
              im4m_path, input_dir=input_dir)
    print(f"  [+] krnl.img4")

    # ── 8. Ramdisk + Trustcache ──────────────────────────────────
    print(f"\n{'=' * 60}")
    print(f"  8. Ramdisk + Trustcache")
    print(f"{'=' * 60}")
    build_ramdisk(restore_dir, im4m_path, vm_dir, input_dir, output_dir, temp_dir)

    # ── Cleanup ──────────────────────────────────────────────────
    print(f"\n[*] Cleaning up {TEMP_DIR}/...")
    shutil.rmtree(temp_dir, ignore_errors=True)
    sshrd_dir = os.path.join(vm_dir, "SSHRD")
    if os.path.exists(sshrd_dir):
        shutil.rmtree(sshrd_dir, ignore_errors=True)

    # ── Summary ──────────────────────────────────────────────────
    print(f"\n{'=' * 60}")
    print(f"  Ramdisk build complete!")
    print(f"  Output: {output_dir}/")
    print(f"{'=' * 60}")
    for f in sorted(os.listdir(output_dir)):
        size = os.path.getsize(os.path.join(output_dir, f))
        print(f"    {f:45s} {size:>10,} bytes")


if __name__ == "__main__":
    main()

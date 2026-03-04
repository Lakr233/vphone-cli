#!/usr/bin/env python3
"""
fw_patch_jb.py — Patch boot-chain components using dev patches + JB extensions.

Usage:
    python3 fw_patch_jb.py [vm_directory]

This script extends fw_patch_dev with additional JB-oriented patches.
"""

import os
import sys

from fw_patch import (
    find_file,
    find_restore_dir,
    patch_avpbooter,
    patch_ibec,
    patch_ibss,
    patch_kernelcache,
    patch_llb,
    patch_component,
)
from fw_patch_dev import patch_txm_dev
from patchers.iboot_jb import IBootJBPatcher
from patchers.kernel_jb import KernelJBPatcher


def patch_ibss_jb(data):
    p = IBootJBPatcher(data, mode="ibss", label="Loaded iBSS")
    n = p.apply()
    print(f"  [+] {n} iBSS JB patches applied dynamically")
    return n > 0


def patch_kernelcache_jb(data):
    kp = KernelJBPatcher(data)
    n = kp.apply()
    print(f"  [+] {n} kernel JB patches applied dynamically")
    return n > 0


# Base components — same as fw_patch_dev (dev TXM includes selector24 bypass).
COMPONENTS = [
    # (name, search_base_is_restore, search_patterns, patch_function, preserve_payp)
    ("AVPBooter", False, ["AVPBooter*.bin"], patch_avpbooter, False),
    ("iBSS", True, ["Firmware/dfu/iBSS.vresearch101.RELEASE.im4p"], patch_ibss, False),
    ("iBEC", True, ["Firmware/dfu/iBEC.vresearch101.RELEASE.im4p"], patch_ibec, False),
    (
        "LLB",
        True,
        ["Firmware/all_flash/LLB.vresearch101.RELEASE.im4p"],
        patch_llb,
        False,
    ),
    ("TXM", True, ["Firmware/txm.iphoneos.research.im4p"], patch_txm_dev, True),
    ("kernelcache", True, ["kernelcache.research.vphone600"], patch_kernelcache, True),
]

# JB extension components — applied AFTER base components on the same files.
JB_COMPONENTS = [
    # (name, search_base_is_restore, search_patterns, patch_function, preserve_payp)
    ("iBSS (JB)", True, ["Firmware/dfu/iBSS.vresearch101.RELEASE.im4p"], patch_ibss_jb, False),
    # (
    #     "kernelcache (JB)",
    #     True,
    #     ["kernelcache.research.vphone600"],
    #     patch_kernelcache_jb,
    #     True,
    # ),
]


def main():
    vm_dir = sys.argv[1] if len(sys.argv) > 1 else os.getcwd()
    vm_dir = os.path.abspath(vm_dir)

    if not os.path.isdir(vm_dir):
        print(f"[-] Not a directory: {vm_dir}")
        sys.exit(1)

    restore_dir = find_restore_dir(vm_dir)
    if not restore_dir:
        print(f"[-] No *Restore* directory found in {vm_dir}")
        sys.exit(1)

    print(f"[*] VM directory:      {vm_dir}")
    print(f"[*] Restore directory: {restore_dir}")
    print(f"[*] Patching {len(COMPONENTS)} boot-chain components (jailbreak mode) ...")

    for name, in_restore, patterns, patch_fn, preserve_payp in COMPONENTS:
        search_base = restore_dir if in_restore else vm_dir
        path = find_file(search_base, patterns, name)
        patch_component(path, patch_fn, name, preserve_payp)

    if JB_COMPONENTS:
        print(f"\n[*] Applying {len(JB_COMPONENTS)} JB extension patches ...")
        for name, in_restore, patterns, patch_fn, preserve_payp in JB_COMPONENTS:
            search_base = restore_dir if in_restore else vm_dir
            path = find_file(search_base, patterns, name)
            patch_component(path, patch_fn, name, preserve_payp)

    print(f"\n{'=' * 60}")
    print(f"  All components patched successfully (jailbreak mode)!")
    print(f"{'=' * 60}")


if __name__ == "__main__":
    main()

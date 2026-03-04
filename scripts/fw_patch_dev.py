#!/usr/bin/env python3
"""
fw_patch_dev.py — Patch boot-chain components using dev TXM patch set.

Usage:
    python3 fw_patch_dev.py [vm_directory]
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
from patchers.txm_dev import TXMPatcher


def patch_txm_dev(data):
    p = TXMPatcher(data)
    n = p.apply()
    print(f"  [+] {n} TXM dev patches applied dynamically")
    return n > 0


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
    print(f"[*] Patching {len(COMPONENTS)} boot-chain components (dev mode) ...")

    for name, in_restore, patterns, patch_fn, preserve_payp in COMPONENTS:
        search_base = restore_dir if in_restore else vm_dir
        path = find_file(search_base, patterns, name)
        patch_component(path, patch_fn, name, preserve_payp)

    print(f"\n{'=' * 60}")
    print(f"  All {len(COMPONENTS)} components patched successfully (dev mode)!")
    print(f"{'=' * 60}")


if __name__ == "__main__":
    main()

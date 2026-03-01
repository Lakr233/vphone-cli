#!/usr/bin/env python3
"""
fw_patch_jb.py — Apply jailbreak extension patches after base fw_patch.

Usage:
    python3 fw_patch_jb.py [vm_directory]

This script runs base `fw_patch.py` first, then applies additional JB-oriented
patches found dynamically.
"""

import os
import subprocess
import sys

from fw_patch import (
    find_file,
    find_restore_dir,
    load_firmware,
    save_firmware,
)
from patchers.iboot_jb import IBootJBPatcher
from patchers.kernel_jb import KernelJBPatcher
from patchers.txm_jb import TXMJBPatcher


def patch_ibss_jb(data):
    p = IBootJBPatcher(data, mode="ibss", label="Loaded iBSS", verbose=True)
    n = p.apply()
    print(f"  [+] {n} iBSS JB patches applied dynamically")
    return n > 0


def patch_kernelcache_jb(data):
    kp = KernelJBPatcher(data, verbose=True)
    n = kp.apply()
    print(f"  [+] {n} kernel JB patches applied dynamically")
    return n > 0


def patch_txm_jb(data):
    p = TXMJBPatcher(data, verbose=True)
    n = p.apply()
    print(f"  [+] {n} TXM JB patches applied dynamically")
    return n > 0


COMPONENTS = [
    # (name, search_base_is_restore, search_patterns, patch_function, preserve_payp)
    ("iBSS (JB)", True,
     ["Firmware/dfu/iBSS.vresearch101.RELEASE.im4p"],
     patch_ibss_jb, False),
    ("TXM (JB)", True,
     ["Firmware/txm.iphoneos.research.im4p"],
     patch_txm_jb, True),
    ("kernelcache (JB)", True,
     ["kernelcache.research.vphone600"],
     patch_kernelcache_jb, True),
]


def patch_component(path, patch_fn, name, preserve_payp):
    print(f"\n{'=' * 60}")
    print(f"  {name}: {path}")
    print(f"{'=' * 60}")

    im4p, data, was_im4p, original_raw = load_firmware(path)
    fmt = "IM4P" if was_im4p else "raw"
    extra = f", fourcc={im4p.fourcc}" if was_im4p and im4p else ""
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

    script_dir = os.path.dirname(os.path.abspath(__file__))
    fw_patch_script = os.path.join(script_dir, "fw_patch.py")

    print("[*] Running base fw_patch first ...", flush=True)
    subprocess.run([sys.executable, fw_patch_script, vm_dir], check=True)

    restore_dir = find_restore_dir(vm_dir)
    if not restore_dir:
        print(f"[-] No *Restore* directory found in {vm_dir}")
        sys.exit(1)

    print(f"[*] VM directory:      {vm_dir}")
    print(f"[*] Restore directory: {restore_dir}")
    print(f"[*] Applying {len(COMPONENTS)} JB extension components ...")

    for name, in_restore, patterns, patch_fn, preserve_payp in COMPONENTS:
        search_base = restore_dir if in_restore else vm_dir
        path = find_file(search_base, patterns, name)
        patch_component(path, patch_fn, name, preserve_payp)

    print(f"\n{'=' * 60}")
    print("  JB extension patching complete!")
    print(f"{'=' * 60}")


if __name__ == "__main__":
    main()

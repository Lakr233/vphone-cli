#!/usr/bin/env python3
"""
fw_patch_test.py — apply a single JB kernel patch method onto a dev-patched image.

Usage:
    PATCH=patch_xxx python3 fw_patch_test.py [vm_directory]
"""

import os
import sys

from fw_patch import find_file, find_restore_dir, load_firmware, save_firmware
from patchers.kernel_jb import KernelJBPatcher


def _build_single_patch_plan(patcher, method_name):
    all_methods = getattr(KernelJBPatcher, "_PATCH_METHODS", ())
    if method_name not in all_methods:
        available = "\n".join(f"  - {name}" for name in all_methods)
        raise ValueError(
            f"Unknown JB patch method: {method_name}\nAvailable methods:\n{available}"
        )
    if not callable(getattr(patcher, method_name, None)):
        raise ValueError(f"Method is not callable on patcher: {method_name}")
    return (method_name,)


def patch_kernelcache_single(data, method_name):
    patcher = KernelJBPatcher(data)
    plan = _build_single_patch_plan(patcher, method_name)
    original_plan = patcher._PATCH_METHODS
    patcher._PATCH_METHODS = plan
    try:
        patches = list(patcher.find_all())
    finally:
        patcher._PATCH_METHODS = original_plan

    if not patches:
        print(f"  [-] No patches emitted by method: {method_name}")
        return False

    for off, patch_bytes, _ in patches:
        data[off : off + len(patch_bytes)] = patch_bytes

    print(f"  [+] {len(patches)} patch(es) emitted by {method_name}")
    return True


def main():
    method_name = os.environ.get("PATCH", "").strip()
    if not method_name:
        print("[-] PATCH environment variable is required (example: PATCH=<jb_patch_method>)")
        sys.exit(1)

    vm_dir = sys.argv[1] if len(sys.argv) > 1 else os.getcwd()
    vm_dir = os.path.abspath(vm_dir)
    if not os.path.isdir(vm_dir):
        print(f"[-] Not a directory: {vm_dir}")
        sys.exit(1)

    restore_dir = find_restore_dir(vm_dir)
    if not restore_dir:
        print(f"[-] No *Restore* directory found in {vm_dir}")
        sys.exit(1)

    kernel_path = find_file(restore_dir, ["kernelcache.research.vphone600"], "kernelcache")

    print(f"[*] VM directory:      {vm_dir}")
    print(f"[*] Restore directory: {restore_dir}")
    print(f"[*] Testing JB method: {method_name}")
    print(f"[*] Target file:       {kernel_path}")

    im4p, data, was_im4p, original_raw = load_firmware(kernel_path)
    if not patch_kernelcache_single(data, method_name):
        sys.exit(1)

    save_firmware(kernel_path, im4p, data, was_im4p, original_raw)
    print("[+] Single JB patch test applied successfully")


if __name__ == "__main__":
    main()

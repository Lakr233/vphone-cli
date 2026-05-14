#!/usr/bin/env python3
"""cfw_patch_build_version.py — rewrite ProductBuildVersion in SystemVersion.plist.

iOS displays the build identifier (e.g. "23B85") in Settings → General →
About → "Build Version", and most userland frameworks (libMobileGestalt,
CoreFoundation's `_CFCopyServerVersionDictionary`, App Store telemetry,
etc.) read it from `/System/Library/CoreServices/SystemVersion.plist` —
the `ProductBuildVersion` key. A copy of the same plist also lives at
`/private/preboot/Cryptexes/OS/System/Library/CoreServices/SystemVersion.plist`
for Cryptex-side OS-version queries.

This patcher takes a plist path and rewrites `ProductBuildVersion` to a
target value (e.g. "23F77"). It auto-detects XML vs binary plist format
and writes back in the same format.

The change DOES NOT affect:
  - `sysctl kern.osversion` — populated at boot from a kernel global
    initialized from boot args; the kernel image itself doesn't carry
    "23B85" as a const cstring. (The kernel for vphone600 was built
    against "23B78", visible in kext Info.plist embedded blobs.)
  - `ProductVersion` (e.g. "26.1") — left at the iOS marketing version.
  - DSC dylib internal constants — `23B85` doesn't appear in any DSC
    chunk as a build identifier; the one apparent hit is a Swift
    mangled-name UUID-uniquing substring.

Idempotent: a re-run on an already-patched plist exits without rewriting.
"""

import plistlib
import sys


KEY = "ProductBuildVersion"


def patch_plist(path: str, target: str, *, dry_run: bool = False) -> bool:
    """Rewrite the ProductBuildVersion key. Returns True if the file was
    rewritten, False if it was already in the target state.
    """
    with open(path, "rb") as f:
        data = f.read()

    # Detect format: XML plists start with '<?xml' or '<plist', binary
    # plists start with the magic 'bplist00' (or similar).
    is_xml = data.lstrip().startswith(b"<")
    fmt = plistlib.FMT_XML if is_xml else plistlib.FMT_BINARY

    try:
        plist = plistlib.loads(data)
    except Exception as e:
        raise ValueError(f"{path}: cannot parse as plist: {e}")

    if not isinstance(plist, dict):
        raise ValueError(
            f"{path}: top-level plist is {type(plist).__name__}, expected dict"
        )

    current = plist.get(KEY)
    if current is None:
        raise ValueError(f"{path}: no {KEY!r} key present")
    if not isinstance(current, str):
        raise ValueError(
            f"{path}: {KEY!r} is {type(current).__name__}, expected str"
        )

    if current == target:
        print(f"  [.] {path}: {KEY} already = {target!r}")
        return False

    print(f"  [+] {path}: {KEY} {current!r} -> {target!r}")
    plist[KEY] = target

    if dry_run:
        print(f"  [.] dry-run — not writing back")
        return False

    new_data = plistlib.dumps(plist, fmt=fmt, sort_keys=False)
    with open(path, "wb") as f:
        f.write(new_data)
    return True


def _main(argv):
    if len(argv) < 3:
        print(
            "Usage: cfw_patch_build_version.py <plist> <new_build_version> [--dry-run]",
            file=sys.stderr,
        )
        return 2
    path, target = argv[1], argv[2]
    dry_run = "--dry-run" in argv[3:]
    try:
        patch_plist(path, target, dry_run=dry_run)
    except Exception as e:
        print(f"[-] {type(e).__name__}: {e}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(_main(sys.argv))

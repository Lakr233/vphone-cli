"""DSC-side orchestrator for the hv_vmm_present user-mode patch
(blacklist-flip design).

Design summary
--------------
This module works in tandem with `KernelJBPatchHvVmmRename` (Swift
kernel patcher) which renames the kernel's sysctl OID from
`hv_vmm_present` to `Xv_vmm_present`. After the kernel patch:

  - `sysctlbyname("kern.hv_vmm_present", ...)` returns ENOENT.
  - `sysctlbyname("kern.Xv_vmm_present", ...)` returns 1 (the OID's
    real int value, since this device is in fact a VM).

This module's job is to selectively rewrite cstrings inside DSC
dylibs so each dylib queries either the original (now ENOENT-returning)
name or the new (truthful-1-returning) name. Byte 5 of the
`"kern.hv_vmm_present\\0"` cstring is flipped from `'h'` (0x68) to
`'X'` (0x58), producing `"kern.Xv_vmm_present\\0"` — the same name the
kernel OID now answers to. The `kern.` namespace prefix is preserved
(byte-0 mangle would have produced `Xern.hv_vmm_present` which can
never resolve because `Xern` isn't a registered top-level).

Blacklist semantics
-------------------
The `DONT_PATCH_INSTALL_NAMES` list names dylibs whose cstring stays
ORIGINAL — they query `kern.hv_vmm_present`, get ENOENT, and the
caller's defensive post-call check leaves the cached `is_vmm` byte
at BSS-zero (0). Those libs end up thinking "not in a VM" — which is
what we want for sign-in / device-likeness consumers.

Every OTHER dylib that contains the cstring gets the byte-5 mangle —
they query `kern.Xv_vmm_present`, get 1, cache 1, and think "in a VM"
— exactly the value they would have seen on a stock device. This
keeps the graphics path (libMobileGestalt, PhotoFoundation,
AirPlaySupport, VisionKitCore, CoreVideo) and compute/accel fast
paths (CoreML, Espresso, AppleNeuralEngine, …) intact, because they
keep getting their original answer.

"""

import os
import struct
import sys

from .cfw_patch_hv_vmm import (
    NEEDLE,
    MANGLED_NEEDLE,
    MANGLE_OFFSET,
    ORIGINAL_BYTE,
    MANGLED_BYTE,
)
from .cfw_dsc_chunks import DSCChunks
from .cfw_dsc_codesign import reattest_modified_pages
from . import cfw_records as records


# ─────────────────────────────────────────────────────────────────────
# Blacklist of DSC dylibs to LEAVE UNPATCHED.
#
# A dylib in this list keeps its cstring as `"kern.hv_vmm_present\0"`.
# With the kernel-rename patch in place, that name resolves to ENOENT,
# the dylib's defensive `cbnz w0, skip` takes the skip path, and the
# cached `is_vmm` byte stays at BSS-zero (0). The dylib thinks the
# device is not a VM.
#
# A dylib NOT in this list has its cstring rewritten to
# `"kern.Xv_vmm_present\0"` (byte 5 mangle, 'h' → 'X'). That name
# resolves to the renamed OID on the kernel side and returns 1. The
# dylib thinks the device IS a VM — same as stock.
#
# Comment a single line out (re-enabling the patch for that dylib —
# i.e., MOVING IT OUT of the blacklist) to bisect which consumer
# regressed an observable.
#
# Order is grouped by why each entry needs to lie about VM presence;
# the order itself doesn't affect patching.
# ─────────────────────────────────────────────────────────────────────
DONT_PATCH_INSTALL_NAMES = (
    # ── Identity / activation / anti-abuse.
    "/System/Library/PrivateFrameworks/AAAFoundation.framework/AAAFoundation",
    "/System/Library/PrivateFrameworks/AuthKit.framework/AuthKit",
    "/System/Library/PrivateFrameworks/IDSFoundation.framework/IDSFoundation",
    "/System/Library/PrivateFrameworks/DeviceIdentity.framework/DeviceIdentity",
    "/System/Library/PrivateFrameworks/DeviceCheckInternal.framework/DeviceCheckInternal",
    "/System/Library/PrivateFrameworks/MobileActivation.framework/MobileActivation",
    "/System/Library/PrivateFrameworks/ApplePushService.framework/ApplePushService",

    # ── Store / IAP.
    "/System/Library/PrivateFrameworks/AppStoreUtilities.framework/AppStoreUtilities",

    # ── Consumer services.
    "/System/Library/PrivateFrameworks/CorePrescription.framework/CorePrescription",
    "/System/Library/PrivateFrameworks/CoreCDP.framework/CoreCDP",
    "/System/Library/PrivateFrameworks/EmailFoundation.framework/EmailFoundation",
    "/System/Library/PrivateFrameworks/FindMyBase.framework/FindMyBase",
    "/System/Library/PrivateFrameworks/TrialServer.framework/TrialServer",
    "/System/Library/PrivateFrameworks/DVTInstrumentsUtilities.framework/DVTInstrumentsUtilities",
    "/System/Library/PrivateFrameworks/WatchdogServiceManagement.framework/WatchdogServiceManagement",
)
_DONT_PATCH_SET: frozenset[str] = frozenset(DONT_PATCH_INSTALL_NAMES)


def _classify(chunks, string_vma):
    """Walk back from `string_vma` to find the containing Mach-O header
    and return its install name (LC_ID_DYLIB), or None if not found.
    """
    header_vma = chunks.find_macho_header_before(string_vma)
    if header_vma is None:
        return None
    return chunks.read_install_name_at(header_vma)


def patch_hv_vmm_in_dsc(chunks_dir, *, dry_run=False):
    """Apply the blacklist-flip mangle inside the DSC chunks at
    `chunks_dir`.

    For every occurrence of `"kern.hv_vmm_present\\0"` in any
    executable DSC mapping, resolve the containing dylib's install
    name; if the install name is NOT in `DONT_PATCH_INSTALL_NAMES`,
    rewrite byte 5 of the cstring from 'h' to 'X'.

    Returns {install_name: count_of_cstring_sites_mangled}.
    """
    records.set_group("hv_vmm_dsc")
    chunks = DSCChunks(chunks_dir)
    print(f"  [.] {chunks!r}")

    print(f"  [.] locating cstring \"kern.hv_vmm_present\\0\"...")
    string_vmas = chunks.find_string_vmas(NEEDLE)
    # Also pick up cstrings already mangled by a prior run — we still
    # need their 16 KiB pages added to the re-attestation set so a
    # re-run on a previously-patched DSC keeps slot hashes in sync.
    already_mangled_vmas = chunks.find_string_vmas(MANGLED_NEEDLE)
    if not string_vmas and not already_mangled_vmas:
        print(f"  [-] cstring not present in any executable mapping; "
              f"nothing to do (either patched already or absent)")
        return {}
    print(f"  [.] {len(string_vmas)} pristine + {len(already_mangled_vmas)} "
          f"already-mangled cstring occurrence(s) found")

    print(f"  [.] resolving containing dylib for each occurrence "
          f"(blacklist has {len(_DONT_PATCH_SET)} entries — these stay "
          f"unpatched)...")
    results = {}
    patched_total = 0
    skipped_in_blacklist = 0
    skipped_unclassified = 0
    refused = 0
    # Track every vmaddr we actually mangled so the re-attestation pass
    # at the end recomputes exactly the affected 16 KiB pages.
    modified_vmas: list[int] = []

    for vma in sorted(string_vmas):
        try:
            install_name = _classify(chunks, vma)
        except Exception as e:
            print(f"      [-] could not classify string@0x{vma:X}: "
                  f"{type(e).__name__}: {e}")
            install_name = None
        label = install_name or "<unknown dylib>"

        if install_name is None:
            # Unknown dylibs are NOT in the blacklist → would normally
            # be patched. Refuse here because we can't audit them.
            print(f"      [.] SKIP (no install name resolvable)  "
                  f"string@0x{vma:X}")
            skipped_unclassified += 1
            results[label] = results.get(label, 0)
            continue

        if install_name in _DONT_PATCH_SET:
            print(f"      [.] SKIP (blacklisted — stays unpatched, "
                  f"will hit ENOENT): {install_name}  string@0x{vma:X}")
            skipped_in_blacklist += 1
            results[label] = results.get(label, 0)
            continue

        # Sanity: the byte at vma must currently look like the pristine cstring.
        try:
            current = chunks.read_at_vma(vma, len(NEEDLE))
        except (KeyError, IOError) as e:
            print(f"      [-] read failed at 0x{vma:X}: {e}")
            refused += 1
            continue
        if current[MANGLE_OFFSET:MANGLE_OFFSET + 1] == MANGLED_BYTE:
            # Already mangled by a prior run; nothing to write, but
            # the re-attest pass below picks it up via already_mangled_vmas.
            print(f"      [.] already mangled at byte {MANGLE_OFFSET}: "
                  f"{label}  string@0x{vma:X}")
            results[label] = results.get(label, 0)
            continue
        if current != NEEDLE:
            print(f"      [-] unexpected bytes at 0x{vma:X} "
                  f"({current!r}); refusing  ({label})")
            refused += 1
            continue

        action = "would mangle" if dry_run else "mangled"
        if not dry_run:
            # Write the single byte at vma + MANGLE_OFFSET.
            records.next_site(
                f"hv_vmm_dsc.mangle@0x{vma:X}",
                f"'kern.hv_vmm_present' byte {MANGLE_OFFSET} "
                f"{ORIGINAL_BYTE.decode()} -> {MANGLED_BYTE.decode()} in {install_name}",
            )
            chunks.write_at_vma(vma + MANGLE_OFFSET, MANGLED_BYTE)
        print(f"      [+] {action} {label}  string@0x{vma:X}  "
              f"byte {MANGLE_OFFSET} "
              f"({ORIGINAL_BYTE.decode()} -> {MANGLED_BYTE.decode()})  "
              f"now queries kern.Xv_vmm_present, will see 1 (in a VM)")
        results[label] = results.get(label, 0) + 1
        patched_total += 1
        modified_vmas.append(vma)

    # Second pass: previously-mangled cstrings. Add their pages to the
    # re-attestation set so a re-run brings slot hashes into sync.
    # IMPORTANT: we INTENTIONALLY do not refuse a mangled cstring whose
    # install_name is in the blacklist — that's an out-of-band action
    # (someone re-enabled patching for that dylib in a prior run and
    # then commented it back into the blacklist). We log it loudly.
    reattest_only_count = 0
    blacklist_drift_count = 0
    for vma in sorted(already_mangled_vmas):
        try:
            install_name = _classify(chunks, vma)
        except Exception:
            install_name = None
        if install_name is None:
            continue
        if install_name in _DONT_PATCH_SET:
            # This dylib is supposed to be unpatched but appears mangled.
            # Most likely the operator mangled and then re-added it to
            # the blacklist; we surface this and still re-attest the
            # page so the slot hash matches the current bytes.
            print(f"      [!] drift: {install_name} is in the blacklist "
                  f"but already mangled at string@0x{vma:X} — slot will "
                  f"be re-attested to current bytes; consider whether "
                  f"you actually want this dylib re-patched")
            modified_vmas.append(vma)
            blacklist_drift_count += 1
            continue
        modified_vmas.append(vma)
        reattest_only_count += 1
    if reattest_only_count:
        print(f"  [.] also queueing {reattest_only_count} already-mangled "
              f"cstring page(s) for re-attestation")
    if blacklist_drift_count:
        print(f"  [.] {blacklist_drift_count} blacklisted dylib(s) found "
              f"mangled on disk — see drift warnings above")

    # Page-hash re-attestation. On hardware with TXM enforcement
    # (`codeSigningMonitor == 2` — iPhone17,3 / iOS 26.1), the kernel
    # defers per-page validation to TXM (vm_fault.c:2763-2780). TXM has
    # the original SHA-256 slot hashes baked in via the DSC's chunk-
    # level CS_CodeDirectory, so a byte-mangle alone causes
    # `KERN_PROTECTION_FAILURE` / `CODESIGNING / Invalid Page` SIGKILL
    # of any process that demand-pages the patched page. Recomputing
    # the slot hash makes the modified (content, hash) pair consistent.
    # The CDHash of the CD blob changes as a side-effect but TXM
    # accepts it at DSC mount time on this build (verified empirically).
    if modified_vmas and not dry_run:
        print(f"  [.] re-attesting {len(modified_vmas)} modified page(s)...")
        reattest_modified_pages(chunks, modified_vmas, dry_run=False)
    elif modified_vmas and dry_run:
        print(f"  [.] dry-run: would re-attest {len(modified_vmas)} "
              f"modified page(s)")
        reattest_modified_pages(chunks, modified_vmas, dry_run=True)

    print(f"  [+] DSC patch complete: {patched_total} cstring(s) mangled, "
          f"{skipped_in_blacklist} in-blacklist (left unpatched), "
          f"{skipped_unclassified} unclassified, "
          f"{refused} refused/error")
    return results

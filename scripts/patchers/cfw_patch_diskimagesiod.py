"""diskimagesiod patch module — iOS 27 DDI (/System/Developer) auto-mount fix.

Forces -[DIDiskArb isMountCompleteWithExpectedCount:diskTracker:] to return YES.

Why: `pymobiledevice3 mounter auto-mount` attaches the personalized DDI, then
MobileStorageMounter waits on diskimagesiod's -[DIDiskArb
waitForDAMountWithExpectedCount:diskTracker:] before it performs the real
(nobrowse) mount of the DDI volume at /System/Developer. That wait loops until
`isMountComplete` returns YES, which is
`callbackReached || (appearedDiskCount >= expectedCount && mountedDiskCount >= mountableDiskCount)`.
On the iOS-27-userland / 26.4-vphone600-kernel hybrid this never becomes true:
only some of the DMG's IOMedia ever "appear" to diskimagesiod's DiskArbitration
session (appearedDiskCount < expectedCount), and diskarbitrationd never
auto-mounts the volume (mountedDiskCount stays 0), so the wait hangs forever and
pmd3 times out. diskimagesiod itself does NOT mount the DDI (its
-[DIDiskArb mountWithDeviceName:...] is dead code); it only gates
MobileStorageMounter. Forcing isMountComplete to YES lets the wait return
immediately so MobileStorageMounter proceeds and mounts the DDI.

Pairs with the JB kernel patches that make the DDI attachable + mountable:
  - DiskImages2 ABI pokes (KernelJBPatchDiskImages2*) — the v9-kernel accepts the
    v11 userland attach.
  - Sandbox mac_policy_ops[124] (mpo_proc_check_syscall_unix) → allow stub
    (KernelJBPatchSandboxExtended) — lets MobileStorageMounter's mount_apfs make
    the mount(2) syscall (unix 167), otherwise the kernel Sandbox denies it
    ("Protobox: mount_apfs deny(1) syscall-unix 167").

No-op-in-effect on version-matched userlands (there the wait completes on its
own, so returning YES early changes nothing observable).
"""

from .cfw_asm import *
from .cfw_asm import _log_asm

_SELECTOR = "isMountCompleteWithExpectedCount:diskTracker:"


def _find_imp_via_objc_metadata(data):
    """Resolve the method IMP through ObjC runtime metadata (relative method lists).

    selector cstring -> __objc_selrefs entry -> relative method-list entry -> IMP.
    """
    sections = parse_macho_sections(data)

    sel_foff = data.find(_SELECTOR.encode() + b"\x00")
    if sel_foff < 0:
        print(f"  [-] Selector '{_SELECTOR}' not found in binary")
        return -1

    sel_va = -1
    for _sec_name, (sva, ssz, sfoff) in sections.items():
        if sfoff <= sel_foff < sfoff + ssz:
            sel_va = sva + (sel_foff - sfoff)
            break
    if sel_va < 0:
        print(f"  [-] Could not compute VA for selector at foff:0x{sel_foff:X}")
        return -1
    print(f"  Selector at foff:0x{sel_foff:X} va:0x{sel_va:X}")

    selrefs = find_section(
        sections,
        "__DATA_CONST,__objc_selrefs",
        "__DATA,__objc_selrefs",
        "__AUTH_CONST,__objc_selrefs",
    )
    selref_va = -1
    if selrefs:
        sr_va, sr_size, sr_foff = selrefs
        for i in range(0, sr_size, 8):
            ptr = struct.unpack_from("<Q", data, sr_foff + i)[0]
            # Handle chained fixups: exact, 48-bit-masked, or low-32-bit match.
            if (ptr == sel_va
                    or (ptr & 0x0000FFFFFFFFFFFF) == sel_va
                    or (ptr & 0xFFFFFFFF) == (sel_va & 0xFFFFFFFF)):
                selref_va = sr_va + i
                break
    if selref_va < 0:
        print("  [-] Selref not found (chained fixups may obscure pointers)")
        return -1
    print(f"  Selref va:0x{selref_va:X}")

    # Relative method lists live in __TEXT,__objc_methlist on modern toolchains
    # (older layouts keep them in __objc_const — try both).
    objc_const = find_section(
        sections,
        "__TEXT,__objc_methlist",
        "__DATA_CONST,__objc_const",
        "__DATA,__objc_const",
        "__AUTH_CONST,__objc_const",
    )
    if objc_const:
        oc_va, oc_size, oc_foff = objc_const
        # Relative method entry: { int32 name_rel, int32 types_rel, int32 imp_rel }.
        # name_rel may resolve to the selref (uniqued SEL*) or, in "direct
        # selector" method lists, straight to the selector cstring — accept both.
        for i in range(0, oc_size - 12, 4):
            entry_foff = oc_foff + i
            entry_va = oc_va + i
            rel_name = struct.unpack_from("<i", data, entry_foff)[0]
            if entry_va + rel_name in (selref_va, sel_va):
                imp_field_foff = entry_foff + 8
                imp_field_va = entry_va + 8
                rel_imp = struct.unpack_from("<i", data, imp_field_foff)[0]
                imp_va = imp_field_va + rel_imp
                imp_foff = va_to_foff(bytes(data), imp_va)
                if imp_foff >= 0:
                    print(f"  Found via relative method list: IMP va:0x{imp_va:X} foff:0x{imp_foff:X}")
                    return imp_foff
                print(f"  [!] IMP va:0x{imp_va:X} could not be mapped to file offset")
    return -1


def patch_diskimagesiod(filepath):
    """Force -[DIDiskArb isMountCompleteWithExpectedCount:diskTracker:] → YES.

    Anchor strategies (in order):
      1. LC_SYMTAB symbol containing "isMountCompleteWithExpectedCount".
      2. ObjC metadata: selector -> selref -> relative method list -> IMP.
    Then overwrite the method prologue with `mov x0,#1 ; ret`.
    """
    data = bytearray(open(filepath, "rb").read())

    imp_foff = -1
    imp_va = find_symbol_va(bytes(data), "isMountCompleteWithExpectedCount")
    if imp_va > 0:
        imp_foff = va_to_foff(bytes(data), imp_va)
        if imp_foff >= 0:
            print(f"  Found via symtab: va:0x{imp_va:X} -> foff:0x{imp_foff:X}")

    if imp_foff < 0:
        imp_foff = _find_imp_via_objc_metadata(data)

    if imp_foff < 0:
        print("  [-] Dynamic anchor not found — all strategies exhausted")
        return False

    if imp_foff + 8 > len(data):
        print(f"  [-] IMP offset 0x{imp_foff:X} out of bounds")
        return False

    print("  Before:")
    _log_asm(data, imp_foff, 4, imp_foff)

    # Return YES immediately. Overwriting the prologue (pacibsp; stp...) is safe:
    # the function returns to the caller's (unsigned) LR without ever pushing a
    # frame. Mirrors patch_mobileactivationd.
    data[imp_foff:imp_foff + 4] = MOV_X0_1
    data[imp_foff + 4:imp_foff + 8] = RET

    print("  After:")
    _log_asm(data, imp_foff, 4, imp_foff)

    open(filepath, "wb").write(data)
    print(f"  [+] Patched isMountComplete at 0x{imp_foff:X}: mov x0, #1; ret")
    return True

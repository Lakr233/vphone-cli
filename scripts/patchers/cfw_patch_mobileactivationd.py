"""mobileactivationd patch module."""

from .cfw_asm import *
from .cfw_asm import _log_asm
from . import cfw_records as records

def _find_via_objc_metadata(data):
    """Find method IMP through ObjC runtime metadata."""
    sections = parse_macho_sections(data)

    # Find "should_hactivate\0" string
    selector = b"should_hactivate\x00"
    sel_foff = data.find(selector)
    if sel_foff < 0:
        print("  [-] Selector 'should_hactivate' not found in binary")
        return -1

    # Compute selector VA
    sel_va = -1
    for sec_name, (sva, ssz, sfoff) in sections.items():
        if sfoff <= sel_foff < sfoff + ssz:
            sel_va = sva + (sel_foff - sfoff)
            break

    if sel_va < 0:
        print(f"  [-] Could not compute VA for selector at foff:0x{sel_foff:X}")
        return -1

    print(f"  Selector at foff:0x{sel_foff:X} va:0x{sel_va:X}")

    # Find selref that points to this selector
    selrefs = find_section(
        sections,
        "__DATA_CONST,__objc_selrefs",
        "__DATA,__objc_selrefs",
        "__AUTH_CONST,__objc_selrefs",
    )

    selref_foff = -1
    selref_va = -1

    if selrefs:
        sr_va, sr_size, sr_foff = selrefs
        for i in range(0, sr_size, 8):
            ptr = struct.unpack_from("<Q", data, sr_foff + i)[0]
            # Handle chained fixups: try exact and masked match
            if ptr == sel_va or (ptr & 0x0000FFFFFFFFFFFF) == sel_va:
                selref_foff = sr_foff + i
                selref_va = sr_va + i
                break

            # Also try: lower 32 bits might encode the target in chained fixups
            if (ptr & 0xFFFFFFFF) == (sel_va & 0xFFFFFFFF):
                selref_foff = sr_foff + i
                selref_va = sr_va + i
                break

    if selref_foff < 0:
        print("  [-] Selref not found (chained fixups may obscure pointers)")
        return -1

    print(f"  Selref at foff:0x{selref_foff:X} va:0x{selref_va:X}")

    # Search for relative method list entry pointing to this selref
    # Relative method entries: { int32 name_rel, int32 types_rel, int32 imp_rel }
    # name_field_va + name_rel = selref_va

    objc_const = find_section(
        sections,
        "__DATA_CONST,__objc_const",
        "__DATA,__objc_const",
        "__AUTH_CONST,__objc_const",
    )

    if objc_const:
        oc_va, oc_size, oc_foff = objc_const

        for i in range(0, oc_size - 12, 4):
            entry_foff = oc_foff + i
            entry_va = oc_va + i
            rel_name = struct.unpack_from("<i", data, entry_foff)[0]
            target_va = entry_va + rel_name

            if target_va == selref_va:
                # Found the method entry! Read IMP relative offset
                imp_field_foff = entry_foff + 8
                imp_field_va = entry_va + 8
                rel_imp = struct.unpack_from("<i", data, imp_field_foff)[0]
                imp_va = imp_field_va + rel_imp
                imp_foff = va_to_foff(bytes(data), imp_va)

                if imp_foff >= 0:
                    print(
                        f"  Found via relative method list: IMP va:0x{imp_va:X} foff:0x{imp_foff:X}"
                    )
                    return imp_foff
                else:
                    print(
                        f"  [!] IMP va:0x{imp_va:X} could not be mapped to file offset"
                    )

    return -1


def patch_mobileactivationd(filepath):
    """Dynamically find -[DeviceType should_hactivate] and patch to return YES.

    Anchor strategies (in order):
    1. Search LC_SYMTAB for symbol containing "should_hactivate"
    2. Parse ObjC metadata: methnames -> selrefs -> method_list -> IMP

    The method determines if the device should self-activate (hackivation).
    Patching it to always return YES bypasses activation lock.
    """
    data = bytearray(open(filepath, "rb").read())

    imp_foff = -1

    # Strategy 1: Symbol table lookup (most reliable)
    imp_va = find_symbol_va(bytes(data), "should_hactivate")
    if imp_va > 0:
        imp_foff = va_to_foff(bytes(data), imp_va)
        if imp_foff >= 0:
            print(f"  Found via symtab: va:0x{imp_va:X} -> foff:0x{imp_foff:X}")

    # Strategy 2: ObjC metadata chain
    if imp_foff < 0:
        imp_foff = _find_via_objc_metadata(data)

    # All dynamic strategies exhausted
    if imp_foff < 0:
        print("  [-] Dynamic anchor not found — all strategies exhausted")
        return False

    # Verify the target looks like code
    if imp_foff + 8 > len(data):
        print(f"  [-] IMP offset 0x{imp_foff:X} out of bounds")
        return False

    print(f"  Before:")
    _log_asm(data, imp_foff, 4, imp_foff)

    # Patch to: mov x0, #1; ret
    data[imp_foff : imp_foff + 4] = MOV_X0_1
    data[imp_foff + 4 : imp_foff + 8] = RET

    print(f"  After:")
    _log_asm(data, imp_foff, 4, imp_foff)

    records.set_group("mobileactivationd")
    records.record_file_write(filepath, data, component="mobileactivationd", sites=[
        records.site(imp_foff, 8, "mobileactivationd.should_hactivate",
                     "-[DeviceType should_hactivate] -> mov x0, #1; ret",
                     virtual_address=imp_va if imp_va > 0 else None),
    ])
    open(filepath, "wb").write(data)
    print(f"  [+] Patched at 0x{imp_foff:X}: mov x0, #1; ret")
    return True

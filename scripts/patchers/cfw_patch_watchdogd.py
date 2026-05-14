"""watchdogd surgical patch — force the cached "am I a VM?" byte to 1.

Background
----------
After the kernel-side rename of the `kern.hv_vmm_present` sysctl OID
(see `KernelJBPatchHvVmmRename.swift`), every userland caller that
queries `kern.hv_vmm_present` now receives `ENOENT`. `/usr/libexec/
watchdogd` initialises a private "am I a VM?" cache from that sysctl
during startup:

    adrp x0, <page>
    add  x0, x0, #<off>          ; "kern.hv_vmm_present"
    sub  x1, x29, #4             ; &oldval
    mov  x2, sp                  ; &oldlen
    mov  x3, #0
    mov  x4, #0
    bl   _sysctlbyname           ; auth stub
    cbnz w0, <skip>              ; on ENOENT: w0 != 0 -> jump past the store
    ldur w8, [x29, #-4]
    cmp  w8, #0
    cset w8, ne                  ; w8 = (oldval != 0) ? 1 : 0
    adrp x9, <page>
    strb w8, [x9, #<off>]        ; cached byte

A downstream accessor returns that cached byte; a `cbz w0, ...` at
`+0x58e0` reads it; on `cbz`-taken it falls into a call to a
`_os_crash` wrapper that does `brk #1`. Because the cstring rename
makes the sysctl return `ENOENT`, the `cbnz w0, <skip>` path is taken,
the store is skipped, the cached byte stays at its BSS-zero default
(0), the downstream `cbz` takes the trap branch, and launchd's
`_PanicOnCrash` knob escalates the resulting SIGTRAP to a kernel
panic.

Patch
-----
Two-instruction surgical edit at the originating site. We do NOT touch
the cstring (the kernel rename approach deliberately keeps every
`kern.hv_vmm_present` consumer queriying the now-ENOENT name, except
where we specifically opt them out). What we change instead is the
caching logic so that, regardless of the sysctl result, the cached
byte ends up at 1:

    cbnz w0, <skip>     ->  nop                  (don't skip the store)
    cset wN, ne         ->  mov wN, #1           (store 1, not oldval-truthiness)

Net effect: the strb writes 1 into the cached "am I a VM?" byte every
time, the downstream accessor returns 1, the `cbz w0, ...` at +0x58e0
falls through to the clean-exit branch that logs "detected virtual
machine environment and no watchdog KEXT found, exiting...". No trap,
no panic.

Anchoring
---------
We anchor on the canonical shape rather than file offsets. For each
`adrp/add` xref in `__TEXT,__text` that resolves to the file VA of
the `"kern.hv_vmm_present\0"` cstring, we require:

  1. A `bl <stub>` within the next 20 instructions of the `add`.
  2. The instruction immediately after that `bl` is `cbnz w0, <imm>`.
  3. Within 8 instructions after the `cbnz` there is a `cset wN, <cond>`
     (capstone alias for `csinc wN, wzr, wzr, !cond`).
  4. Within 8 instructions after the `cset` there is a `strb wM,
     [xR, #imm]` (the store into the cached-byte global).

Watchdogd contains two functions that match this shape (verified
empirically on `iPhone17,3_26.1_23B85`). Both are "cache the VM
presence" routines; one feeds the accessor at `+0x8cdc` (the path
that leads to the trap), the other feeds a separate consumer at a
different global. Both want the same answer (cached byte = 1), so we
patch every match the anchor finds. Idempotent: after patching, the
matcher no longer finds a `cbnz w0` at the expected slot, so a
re-run reports "already patched" and exits cleanly.

Code signing
------------
A byte edit inside `__TEXT,__text` invalidates the SHA-256 slot hash
of the containing 4 KiB page in the binary's own `CS_CodeDirectory`.
On `codeSigningMonitor == 2` hardware (iPhone17,3 / iOS 26.1), TXM
rejects the page on demand-page-in unless the slot hash matches the
on-disk page bytes. After the in-place byte patch we recompute and
write the slot hash via `cfw_macho_codesign.reattest_modified_offsets`.

The resulting CD mutation also changes the binary's cdHash, which
would normally cause AMFI to reject the image at execve. The existing
JB kernel patch `patch_amfi_cdhash_in_trustcache` short-circuits that
trust-cache check unconditionally — same property the DSC reattest
already relies on.

We do NOT re-sign with `ldid`. Re-signing would default the code-signing
identifier to the local filename, which trips launchd's boot-task
identity check (the same failure mode we observed on mobile_obliterator
before the previous attempt was reverted).
"""

import struct
import sys

from .cfw_asm import (
    NOP,
    _cs,
    _log_asm,
    asm,
    disasm_at,
    find_section,
    parse_macho_sections,
    wr32,
)
from .cfw_macho_codesign import reattest_modified_offsets

from capstone.arm64_const import ARM64_OP_IMM


NEEDLE = b"kern.hv_vmm_present\x00"
PATTERN_NAME = "watchdogd hv_vmm_present sysctl cache"

# Scan windows (in instructions, not bytes).
SCAN_ADRP_TO_ADD = 8       # ADRP and its paired ADD may be up to 8 insns apart
SCAN_ADD_TO_BL = 20        # from the cstring-loading ADD forward to the bl _sysctlbyname
SCAN_BL_TO_CSET = 12       # from cbnz forward to the cset
SCAN_CSET_TO_STRB = 8      # from cset forward to the strb


def _find_cstring_va(data, sections):
    """Locate "kern.hv_vmm_present\0" in any cstring-like section.

    Returns (va, file_offset, section_name) or None.
    """
    for sec_name, (vma, size, foff) in sections.items():
        _, _, sect = sec_name.partition(",")
        if sect not in ("__cstring", "__objc_methname", "__objc_classname"):
            continue
        buf = bytes(data[foff : foff + size])
        i = 0
        while True:
            p = buf.find(NEEDLE, i)
            if p < 0:
                break
            # Must be at a cstring boundary (preceded by NUL or start of section).
            if p == 0 or buf[p - 1] == 0:
                return (vma + p, foff + p, sec_name)
            i = p + 1
    return None


def _find_adrp_add_xrefs(code, base_va, target_va):
    """Yield the (adrp_va, add_va) of every ADRP+ADD pair that resolves to
    target_va.

    Tracks recent ADRP results per destination register; pairs them with
    a subsequent ADD where the ADD's first source reg matches the ADRP's
    destination and the ADRP and ADD are within `SCAN_ADRP_TO_ADD`
    instructions of each other.
    """
    target_page = target_va & ~0xFFF
    target_pageoff = target_va & 0xFFF

    adrp_cache = {}  # dst_reg -> (adrp_va, page_value, idx)

    insns = list(_cs.disasm(code, base_va))
    insn_by_idx = {i: ins for i, ins in enumerate(insns)}

    for idx, ins in enumerate(insns):
        if ins.mnemonic == "adrp" and len(ins.operands) >= 2:
            dst = ins.operands[0].reg
            page = ins.operands[1].imm
            adrp_cache[dst] = (ins.address, page, idx)

        elif ins.mnemonic == "add" and len(ins.operands) >= 3:
            src = ins.operands[1].reg
            imm_op = ins.operands[2]
            if imm_op.type != ARM64_OP_IMM:
                continue
            if src not in adrp_cache:
                continue
            adrp_va, page, adrp_idx = adrp_cache[src]
            if idx - adrp_idx > SCAN_ADRP_TO_ADD:
                continue
            if page == target_page and imm_op.imm == target_pageoff:
                yield (adrp_va, ins.address)


def _next_branch(insns, start_idx, mnemonics, max_scan):
    """Return (idx, insn) of the first insn at or after start_idx whose
    mnemonic is in `mnemonics`, within `max_scan` instructions. None if
    not found.
    """
    end = min(len(insns), start_idx + max_scan)
    for i in range(start_idx, end):
        if insns[i].mnemonic in mnemonics:
            return i, insns[i]
    return None


def _operand_reg_name(insn, op_index):
    """Return the lowercase register name of the op_index-th operand of
    insn (e.g. 'w8', 'x9'), or None.
    """
    if len(insn.operands) <= op_index:
        return None
    op = insn.operands[op_index]
    name = insn.reg_name(op.reg)
    return name.lower() if name else None


def _scan_pattern_from_add(insns, add_idx):
    """From the ADD that completes a cstring xref, scan forward for the
    canonical shape:

        add  x0, ...                  ; insns[add_idx]
        ... (arg setup, up to SCAN_ADD_TO_BL insns) ...
        bl   <stub>
        cbnz w0, <skip>               ; MUST be at bl_idx+1
        ... (up to SCAN_BL_TO_CSET) ...
        cset wN, <cond>
        ... (up to SCAN_CSET_TO_STRB) ...
        strb wM, [xR, #imm]

    Returns a dict with the file-relative VAs and the cset destination
    register name on success, or None on miss.
    """
    bl = _next_branch(insns, add_idx + 1, ("bl",), SCAN_ADD_TO_BL)
    if bl is None:
        return None
    bl_idx, bl_insn = bl

    if bl_idx + 1 >= len(insns):
        return None
    cbnz_insn = insns[bl_idx + 1]
    if cbnz_insn.mnemonic != "cbnz":
        return None
    # First operand of cbnz must be w0 — sysctlbyname's return value.
    if _operand_reg_name(cbnz_insn, 0) != "w0":
        return None

    cset = _next_branch(insns, bl_idx + 2, ("cset",), SCAN_BL_TO_CSET)
    if cset is None:
        return None
    cset_idx, cset_insn = cset
    cset_reg = _operand_reg_name(cset_insn, 0)
    if cset_reg is None or not cset_reg.startswith("w"):
        return None

    strb = _next_branch(insns, cset_idx + 1, ("strb",), SCAN_CSET_TO_STRB)
    if strb is None:
        return None
    _strb_idx, strb_insn = strb

    return {
        "bl_va": bl_insn.address,
        "cbnz_va": cbnz_insn.address,
        "cset_va": cset_insn.address,
        "cset_reg": cset_reg,
        "strb_va": strb_insn.address,
    }


def _va_to_foff(text_va, text_foff, va):
    return text_foff + (va - text_va)


def _already_patched_at(data, cbnz_foff, cset_foff):
    """Return True iff the cbnz slot is already a NOP and the cset slot
    is already a `mov wN, #1` (any wN). Used for idempotence.
    """
    cbnz_word = struct.unpack_from("<I", data, cbnz_foff)[0]
    if cbnz_word != struct.unpack("<I", NOP)[0]:
        return False

    cset_word = struct.unpack_from("<I", data, cset_foff)[0]
    # arm64 `mov wN, #1` encodes as MOVZ wN, #1, lsl #0
    #   31:23 = 0b010100101  (MOVZ-W, hw=0)
    #   22:21 = 00
    #   20:5  = imm16 (=1)
    #    4:0  = Rd
    # → top 16 bits = 0x5280, imm = 0x0001, low 5 = N
    high = cset_word >> 16
    mid = (cset_word >> 5) & 0xFFFF
    if high == 0x5280 and mid == 0x0001:
        return True
    return False


def patch_watchdogd(filepath, *, dry_run=False):
    """Apply the surgical patch to a watchdogd Mach-O.

    Returns the number of sites patched (>=1 on success, 0 if the
    binary was already patched). Raises on a malformed binary or on
    failure to find any matching site (the binary isn't what we
    expect).
    """
    with open(filepath, "rb") as f:
        data = bytearray(f.read())

    sections = parse_macho_sections(data)
    text_sec = find_section(sections, "__TEXT,__text")
    if text_sec is None:
        raise ValueError(f"{filepath}: no __TEXT,__text section")
    text_va, text_size, text_foff = text_sec

    cstring_hit = _find_cstring_va(data, sections)
    if cstring_hit is None:
        raise ValueError(
            f"{filepath}: '{NEEDLE.rstrip(chr(0).encode()).decode()}' cstring "
            f"not present"
        )
    cstring_va, cstring_foff, cstring_sec = cstring_hit
    print(
        f"  cstring at va:0x{cstring_va:X} (foff:0x{cstring_foff:X}, "
        f"sect={cstring_sec})"
    )

    code = bytes(data[text_foff : text_foff + text_size])
    insns = list(_cs.disasm(code, text_va))
    add_va_to_idx = {ins.address: i for i, ins in enumerate(insns) if ins.mnemonic == "add"}

    matches = []
    already_patched = []
    for adrp_va, add_va in _find_adrp_add_xrefs(code, text_va, cstring_va):
        add_idx = add_va_to_idx.get(add_va)
        if add_idx is None:
            continue
        m = _scan_pattern_from_add(insns, add_idx)
        if m is None:
            # Check whether this xref looks like an already-patched site.
            # Heuristic: look for the strb forward; if found, check the
            # canonical-slot offsets relative to the bl for the patched
            # form.
            continue
        m["adrp_va"] = adrp_va
        m["add_va"] = add_va
        m["cbnz_foff"] = _va_to_foff(text_va, text_foff, m["cbnz_va"])
        m["cset_foff"] = _va_to_foff(text_va, text_foff, m["cset_va"])
        matches.append(m)

    # Also detect an already-patched form by walking xrefs that DID find
    # the bl + strb but where the cbnz slot is now a NOP.
    # We do this as a second pass over the xrefs.
    for adrp_va, add_va in _find_adrp_add_xrefs(code, text_va, cstring_va):
        add_idx = add_va_to_idx.get(add_va)
        if add_idx is None:
            continue
        bl = _next_branch(insns, add_idx + 1, ("bl",), SCAN_ADD_TO_BL)
        if bl is None:
            continue
        bl_idx, bl_insn = bl
        if bl_idx + 1 >= len(insns):
            continue
        slot_after_bl = insns[bl_idx + 1]
        if slot_after_bl.mnemonic != "nop":
            continue
        # Try to find a strb after the bl so we know this is the same
        # function shape.
        strb = _next_branch(insns, bl_idx + 1, ("strb",), SCAN_BL_TO_CSET + SCAN_CSET_TO_STRB)
        if strb is None:
            continue
        # Find a candidate mov wN, #1 between the nop and the strb.
        mov_idx = None
        for j in range(bl_idx + 2, strb[0]):
            if insns[j].mnemonic == "mov" and _operand_reg_name(insns[j], 0) is not None:
                # Check it's a mov wN, #1.
                imm = insns[j].operands[1].imm if len(insns[j].operands) > 1 else -1
                if imm == 1:
                    mov_idx = j
                    break
        if mov_idx is None:
            continue
        already_patched.append({
            "add_va": add_va,
            "cbnz_va": slot_after_bl.address,
            "cset_va": insns[mov_idx].address,
        })

    if not matches and already_patched:
        print(
            f"  [.] {filepath}: all {len(already_patched)} matching site(s) "
            f"already patched — nothing to do"
        )
        return 0

    if not matches:
        raise ValueError(
            f"{filepath}: no '{PATTERN_NAME}' site found. Expected an "
            f"adrp+add xref to the cstring followed by bl/cbnz w0/cset/strb."
        )

    print(f"  [+] found {len(matches)} '{PATTERN_NAME}' site(s)")
    touched_offsets = []
    n_applied = 0
    for m in matches:
        cbnz_foff = m["cbnz_foff"]
        cset_foff = m["cset_foff"]

        if _already_patched_at(data, cbnz_foff, cset_foff):
            print(
                f"    [.] site @ add 0x{m['add_va']:X}: already in patched "
                f"form (cbnz=nop, cset=mov #1) — skipping"
            )
            continue

        new_cset = asm(f"mov {m['cset_reg']}, #1")
        if len(new_cset) != 4:
            raise RuntimeError(
                f"asm('mov {m['cset_reg']}, #1') returned {len(new_cset)} bytes"
            )

        ctx_start = max(text_foff, cbnz_foff - 8)
        print(
            f"    site @ add 0x{m['add_va']:X}  "
            f"(bl 0x{m['bl_va']:X}, cbnz 0x{m['cbnz_va']:X}, "
            f"cset {m['cset_reg']} 0x{m['cset_va']:X}, strb 0x{m['strb_va']:X})"
        )
        print(f"    Before:")
        _log_asm(data, ctx_start, 8, cbnz_foff)

        old_cbnz = bytes(data[cbnz_foff : cbnz_foff + 4])
        old_cset = bytes(data[cset_foff : cset_foff + 4])

        data[cbnz_foff : cbnz_foff + 4] = NOP
        data[cset_foff : cset_foff + 4] = new_cset

        print(
            f"    Patched: cbnz->{NOP.hex()} (was {old_cbnz.hex()}), "
            f"cset->{new_cset.hex()} (was {old_cset.hex()})"
        )
        print(f"    After:")
        _log_asm(data, ctx_start, 8, cbnz_foff)

        touched_offsets.append(cbnz_foff)
        touched_offsets.append(cset_foff)
        n_applied += 1

    if n_applied == 0:
        print(f"  [.] {filepath}: nothing applied")
        return 0

    # Write the patched bytes to disk BEFORE re-attest, because the
    # re-attest helper opens the file from disk to compute SHA-256 of
    # the modified page.
    if dry_run:
        print(f"  [.] dry-run — not writing patched bytes")
    else:
        with open(filepath, "wb") as f:
            f.write(data)
        print(f"  [+] {filepath}: wrote {n_applied} site(s)")

    # Re-attest the modified page(s).
    diagnostics = reattest_modified_offsets(
        filepath, touched_offsets, dry_run=dry_run, verbose=True
    )
    print(
        f"  [+] {filepath}: re-attest updated {len(diagnostics)} slot(s) "
        f"across {len(set((d['cd_off'], d['page_index']) for d in diagnostics))} "
        f"unique (CD, page) pair(s)"
    )

    return n_applied

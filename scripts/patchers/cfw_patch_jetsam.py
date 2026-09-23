"""launchd jetsam patch module."""

from .cfw_asm import *
from .cfw_asm import _log_asm
from .cfw_patch_cache_loader import _find_adrp_add_ref, _find_cstring_start
from . import cfw_records as records

def _extract_branch_target_off(insn):
    for op in reversed(insn.operands):
        if op.type == ARM64_OP_IMM:
            return op.imm
    return -1


def _is_return_block(data, foff, text_foff, text_size):
    """Check if foff points to a function return sequence (ret/retab within 8 insns)."""
    for i in range(8):
        check = foff + i * 4
        if check >= text_foff + text_size:
            break
        insns = disasm_at(data, check, 1)
        if not insns:
            continue
        if insns[0].mnemonic in ("ret", "retab"):
            return True
        # Stop at unconditional branches (different block)
        if insns[0].mnemonic in ("b", "bl", "br", "blr"):
            break
    return False


def patch_launchd_jetsam(filepath):
    """Bypass launchd jetsam panic path via dynamic string-xref branch rewrite.

    Anchor strategy:
    1. Find jetsam panic string in cstring-like data.
    2. Find ADRP+ADD xref to the string start in __TEXT,__text.
    3. Search backward for a conditional branch whose target is the function's
       return/success path (basic block containing ret/retab).
    4. Rewrite that conditional branch to unconditional `b <same_target>`,
       so the function always returns success and never reaches the panic.
    """
    data = bytearray(open(filepath, "rb").read())
    sections = parse_macho_sections(data)

    text_sec = find_section(sections, "__TEXT,__text")
    if not text_sec:
        print("  [-] __TEXT,__text not found")
        return False

    text_va, text_size, text_foff = text_sec
    code = bytes(data[text_foff : text_foff + text_size])

    cond_mnemonics = {
        "b.eq",
        "b.ne",
        "b.cs",
        "b.hs",
        "b.cc",
        "b.lo",
        "b.mi",
        "b.pl",
        "b.vs",
        "b.vc",
        "b.hi",
        "b.ls",
        "b.ge",
        "b.lt",
        "b.gt",
        "b.le",
        "cbz",
        "cbnz",
        "tbz",
        "tbnz",
    }

    anchors = [
        b"jetsam property category (Daemon) is not initialized",
        b"jetsam property category",
        b"initproc exited -- exit reason namespace 7 subcode 0x1",
    ]

    for anchor in anchors:
        hit_off = data.find(anchor)
        if hit_off < 0:
            continue

        sec_foff = -1
        sec_va = -1
        for _, (sva, ssz, sfoff) in sections.items():
            if sfoff <= hit_off < sfoff + ssz:
                sec_foff = sfoff
                sec_va = sva
                break
        if sec_foff < 0:
            continue

        str_start_off = _find_cstring_start(data, hit_off, sec_foff)
        str_start_va = sec_va + (str_start_off - sec_foff)

        ref_va = _find_adrp_add_ref(code, text_va, str_start_va)
        if ref_va < 0:
            continue
        ref_foff = text_foff + (ref_va - text_va)

        print(f"  Found jetsam anchor '{anchor.decode(errors='ignore')}'")
        print(f"    string start: va:0x{str_start_va:X}")
        print(f"    xref at foff:0x{ref_foff:X}")

        # Search backward from xref for conditional branches targeting
        # the function's return path (block containing ret/retab).
        # Pick the earliest (farthest back) one — it skips the most
        # jetsam-related code and matches the upstream patch strategy.
        scan_lo = max(text_foff, ref_foff - 0x300)
        patch_off = -1
        patch_target = -1

        for back in range(ref_foff - 4, scan_lo - 1, -4):
            insns = disasm_at(data, back, 1)
            if not insns:
                continue
            insn = insns[0]
            if insn.mnemonic not in cond_mnemonics:
                continue

            tgt = _extract_branch_target_off(insn)
            if tgt < 0:
                continue
            # Target must be a valid file offset within __text
            if tgt < text_foff or tgt >= text_foff + text_size:
                continue
            # Target must be a return block (contains ret/retab)
            if _is_return_block(data, tgt, text_foff, text_size):
                patch_off = back
                patch_target = tgt
                # Don't break — keep scanning for an earlier match

        if patch_off < 0:
            continue

        ctx_start = max(text_foff, patch_off - 8)
        print(f"  Before:")
        _log_asm(data, ctx_start, 5, patch_off)

        data[patch_off : patch_off + 4] = asm_at(f"b #0x{patch_target:X}", patch_off)

        print(f"  After:")
        _log_asm(data, ctx_start, 5, patch_off)

        records.set_group("launchd_jetsam")
        records.record_file_write(filepath, data, component="launchd_jetsam", sites=[
            records.site(patch_off, 4, "launchd_jetsam.panic_guard_bypass",
                         f"conditional branch -> unconditional b 0x{patch_target:X} "
                         f"(jetsam panic guard bypass)",
                         virtual_address=text_va + (patch_off - text_foff)),
        ])
        open(filepath, "wb").write(data)
        print(f"  [+] Patched at 0x{patch_off:X}: jetsam panic guard bypass")
        return True

    print("  [-] Dynamic jetsam anchor/xref not found")
    return False


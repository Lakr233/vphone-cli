"""launchd cache loader patch module."""

from .cfw_asm import *
from .cfw_asm import _log_asm, _cs
from . import cfw_records as records


def patch_launchd_cache_loader(filepath):
    """NOP the cache validation check in launchd_cache_loader.

    Anchor strategy:
    Search for "unsecure_cache" substring, resolve to full null-terminated
    string start, find ADRP+ADD xref to it, NOP the nearby cbz/cbnz branch.

    The binary checks boot-arg "launchd_unsecure_cache=" — if not found,
    it skips the unsecure path via a conditional branch. NOPping that branch
    allows modified launchd.plist to be loaded.
    """
    data = bytearray(open(filepath, "rb").read())
    sections = parse_macho_sections(data)

    text_sec = find_section(sections, "__TEXT,__text")
    if not text_sec:
        print("  [-] __TEXT,__text not found")
        return False

    text_va, text_size, text_foff = text_sec

    # Strategy 1: Search for anchor strings in __cstring
    # Code always references the START of a C string, so after finding a
    # substring match, back-scan to the enclosing string's first byte.
    anchor_strings = [
        b"unsecure_cache",
        b"unsecure",
        b"cache_valid",
        b"validation",
    ]

    for anchor_str in anchor_strings:
        anchor_off = data.find(anchor_str)
        if anchor_off < 0:
            continue

        # Find which section this belongs to and compute VA
        anchor_sec_foff = -1
        anchor_sec_va = -1
        for sec_name, (sva, ssz, sfoff) in sections.items():
            if sfoff <= anchor_off < sfoff + ssz:
                anchor_sec_foff = sfoff
                anchor_sec_va = sva
                break

        if anchor_sec_foff < 0:
            continue

        # Back-scan to the start of the enclosing null-terminated C string.
        # Code loads strings from their beginning, not from a substring.
        str_start_off = _find_cstring_start(data, anchor_off, anchor_sec_foff)
        str_start_va = anchor_sec_va + (str_start_off - anchor_sec_foff)
        substr_va = anchor_sec_va + (anchor_off - anchor_sec_foff)

        if str_start_off != anchor_off:
            end = data.index(0, str_start_off)
            full_str = data[str_start_off:end].decode("ascii", errors="replace")
            print(f"  Found anchor '{anchor_str.decode()}' inside \"{full_str}\"")
            print(
                f"    String start: va:0x{str_start_va:X}  (match at va:0x{substr_va:X})"
            )
        else:
            print(f"  Found anchor '{anchor_str.decode()}' at va:0x{str_start_va:X}")

        # Search __TEXT for ADRP+ADD that resolves to the string START VA
        code = bytes(data[text_foff : text_foff + text_size])
        ref_off = _find_adrp_add_ref(code, text_va, str_start_va)

        if ref_off < 0:
            # Also try the exact substring VA as fallback
            ref_off = _find_adrp_add_ref(code, text_va, substr_va)

        if ref_off < 0:
            continue

        ref_foff = text_foff + (ref_off - text_va)
        print(f"  Found string ref at 0x{ref_foff:X}")

        # Find conditional branch AFTER the string ref (within +32 instructions).
        # The pattern is: ADRP+ADD (load string) -> BL (call check) -> CBZ/CBNZ (branch on result)
        # So only search forward from the ref, not backwards.
        branch_foff = _find_nearby_branch(data, ref_foff, text_foff, text_size)
        if branch_foff >= 0:
            ctx_start = max(text_foff, branch_foff - 8)
            print(f"  Before:")
            _log_asm(data, ctx_start, 5, branch_foff)

            data[branch_foff : branch_foff + 4] = NOP

            print(f"  After:")
            _log_asm(data, ctx_start, 5, branch_foff)

            records.set_group("launchd_cache_loader")
            records.record_file_write(filepath, data, component="launchd_cache_loader", sites=[
                records.site(branch_foff, 4, "launchd_cache_loader.unsecure_cache_gate",
                             f"NOP the cache-validation branch gated on "
                             f"'{anchor_str.decode()}'",
                             virtual_address=text_va + (branch_foff - text_foff)),
            ])
            open(filepath, "wb").write(data)
            print(f"  [+] NOPped at 0x{branch_foff:X}")
            return True

    print("  [-] Dynamic anchor not found — all strategies exhausted")
    return False


def _find_cstring_start(data, match_off, section_foff):
    """Find the start of the null-terminated C string containing match_off.

    Scans backwards from match_off to find the previous null byte (or section
    start). Returns the file offset of the first byte of the enclosing string.
    This is needed because code always references the start of a string, not
    a substring within it.
    """
    pos = match_off - 1
    while pos >= section_foff and data[pos] != 0:
        pos -= 1
    return pos + 1


def _find_adrp_add_ref(code, base_va, target_va):
    """Find ADRP+ADD pair that computes target_va in code.

    Handles non-adjacent pairs: tracks recent ADRP results per register
    and matches them with ADD instructions up to 8 instructions later.
    """
    target_page = target_va & ~0xFFF
    target_pageoff = target_va & 0xFFF

    # Track recent ADRP instructions: reg -> (insn_va, page_value, instruction_index)
    adrp_cache = {}

    for off in range(0, len(code) - 4, 4):
        insns = list(_cs.disasm(code[off : off + 4], base_va + off))
        if not insns:
            continue
        insn = insns[0]
        idx = off // 4

        if insn.mnemonic == "adrp" and len(insn.operands) >= 2:
            reg = insn.operands[0].reg
            page = insn.operands[1].imm
            adrp_cache[reg] = (insn.address, page, idx)

        elif insn.mnemonic == "add" and len(insn.operands) >= 3:
            src_reg = insn.operands[1].reg
            imm = insn.operands[2].imm
            if src_reg in adrp_cache:
                adrp_va, page, adrp_idx = adrp_cache[src_reg]
                # Only match if ADRP was within 8 instructions
                if (
                    page == target_page
                    and imm == target_pageoff
                    and idx - adrp_idx <= 8
                ):
                    return adrp_va

    return -1


def _find_nearby_branch(data, ref_foff, text_foff, text_size):
    """Find a conditional branch after a BL (function call) near ref_foff.

    The typical pattern is:
        ADRP+ADD  (load string argument)  ← ref_foff points here
        ...       (setup other args)
        BL        (call check function)
        CBZ/CBNZ  (branch on return value)

    Searches forward from ref_foff for a BL, then finds the first
    conditional branch after it (within 8 instructions of the BL).
    Falls back to first conditional branch within +32 instructions.
    """
    branch_mnemonics = {"cbz", "cbnz", "tbz", "tbnz"}

    # Strategy A: find BL → then first conditional branch after it
    for delta in range(0, 16):
        check_foff = ref_foff + delta * 4
        if check_foff >= text_foff + text_size:
            break
        insns = disasm_at(data, check_foff, 1)
        if not insns:
            continue
        if insns[0].mnemonic == "bl":
            # Found a function call; scan the next 8 instructions for a branch
            for d2 in range(1, 9):
                br_foff = check_foff + d2 * 4
                if br_foff >= text_foff + text_size:
                    break
                br_insns = disasm_at(data, br_foff, 1)
                if not br_insns:
                    continue
                mn = br_insns[0].mnemonic
                if mn in branch_mnemonics or mn.startswith("b."):
                    return br_foff
            break  # Found BL but no branch after it

    # Strategy B: fallback — first conditional branch forward within 32 insns
    for delta in range(1, 33):
        check_foff = ref_foff + delta * 4
        if check_foff >= text_foff + text_size:
            break
        insns = disasm_at(data, check_foff, 1)
        if not insns:
            continue
        mn = insns[0].mnemonic
        if mn in branch_mnemonics or mn.startswith("b."):
            return check_foff

    return -1

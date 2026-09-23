"""Patch libxpc so the Lightweight Code Requirement (LWCR) self-check can't
abort on our JB.

iOS 27 introduced XPC "lightweight code requirements": a server pins a code
requirement on its listener (via `xpc_connection_set_peer_lightweight_code_
requirement`, or the Swift `XPCPeerRequirement.hasEntitlement(_:)` wrapper),
and libxpc evaluates whether a token satisfies it in `_xpc_token_satisfies_
lwcr`. That function calls an internal matcher which returns two things — a
`matched` bool and a `match_result.error_code` — and then hard-asserts they
agree:

    bl      <matcher>            ; w0 = matched
    ldr     wC, [xR]             ; wC = match_result.error_code
    cmp     wC, #0               ; AICMR_MATCH == 0
    cset    wC, ne               ; wC = (error_code != 0)
    eor     wE, w0, wC           ; wE = matched ^ (error_code != 0)
    tbz     wE, #0, <abort>      ; abort (brk #1) when they disagree

On stock iOS the two always agree. On our JB the matcher's code-signing query
writes error_code = MATCH(0) but then returns a failure status, yielding the
forbidden combination (matched=0, error_code=0). libxpc `brk #1`-aborts, so
every daemon that pins an entitlement peer-requirement at startup
(intelligencetasksd, searchpartyd, transparencyd, bluetoothd, ...) crash-loops
— which in turn churns the SpringBoard/backboardd group into resprings.

Fix: make `matched` consistent with `error_code` by construction and drop the
abort. Derive the return from error_code (the matcher's own verdict) and NOP
the xor + the conditional branch:

    cset    wC, ne   ->  cset w0, eq   ; w0 = matched = (error_code == 0)
    eor     wE,...    ->  nop
    tbz     wE,#0,..  ->  nop           ; falls through to the normal return

Real allow/deny is preserved (error_code drives it, exactly as stock does when
the two agree); only the internally-contradictory case is resolved — toward
"satisfied" when error_code says MATCH — instead of aborting.

Nothing is hardcoded: `_xpc_token_satisfies_lwcr` is resolved from the DSC's
own local-symbol table, disassembled with Capstone, and the check located by
control-flow shape (the `cset wC,ne; eor wE,w0,wC; tbz wE,#0` idiom).
Replacements come from Keystone. The modified 16 KiB page is re-attested (TXM
enforces per-page); the CDHash change is accepted by the JB's always-true AMFI
cdhash-trust patch.
"""

from capstone.arm64_const import ARM64_OP_REG, ARM64_OP_IMM

try:
    from .cfw_asm import asm
    from .cfw_dsc_chunks import DSCChunks, resolve_local_symbol, _disasm_function
    from .cfw_dsc_codesign import reattest_modified_pages
    from . import cfw_records as records
except ImportError:  # direct self-test / standalone execution
    from cfw_asm import asm
    from cfw_dsc_chunks import DSCChunks, resolve_local_symbol, _disasm_function
    from cfw_dsc_codesign import reattest_modified_pages
    import cfw_records as records


SYMBOL = "_xpc_token_satisfies_lwcr"
# Mach-O mangles the leading-underscore source name to a double underscore.
SYMBOL_CANDIDATES = ("__xpc_token_satisfies_lwcr", SYMBOL)


def _rn(insn, idx):
    ops = insn.operands
    if idx >= len(ops) or ops[idx].type != ARM64_OP_REG:
        return None
    return insn.reg_name(ops[idx].reg)


def _find_consistency_check(insns):
    """Locate the LWCR self-consistency idiom and return the (cset, eor, tbz)
    instructions.

    Shape:
        cset  wC, ne
        eor   wE, w0, wC
        tbz   wE, #0, <abort>
    """
    for i in range(len(insns) - 1):
        eor = insns[i]
        if eor.mnemonic != "eor":
            continue
        wE, w0, wC = _rn(eor, 0), _rn(eor, 1), _rn(eor, 2)
        if w0 != "w0" or wE is None or wC is None:
            continue
        tbz = insns[i + 1]
        if tbz.mnemonic != "tbz":
            continue
        if _rn(tbz, 0) != wE:
            continue
        tops = tbz.operands
        if len(tops) < 2 or tops[1].type != ARM64_OP_IMM or tops[1].imm != 0:
            continue
        # Walk back for `cset wC, ne` feeding the eor.
        cset = None
        for j in range(i - 1, max(-1, i - 6), -1):
            cand = insns[j]
            if cand.mnemonic == "cset" and _rn(cand, 0) == wC:
                # capstone renders the condition as an operand imm code;
                # use op_str to confirm it is `ne`.
                if cand.op_str.strip().endswith("ne"):
                    cset = cand
                break
        if cset is None:
            continue
        return cset, eor, tbz
    return None


def _find_patched_shape(insns):
    """Locate the shape this patch itself leaves behind, so a re-run reports a
    no-op instead of failing.

    The per-edit `already patched` check below cannot cover this: it compares
    bytes at addresses that `_find_consistency_check` has to supply first, and
    that search looks for the `eor`/`tbz` the patch has already replaced. On a
    second pass over an installed cache the idiom is gone by construction.

    Shape:
        cmp   wX, #0     ; error_code == AICMR_MATCH
        cset  w0, eq     ; the replacement for `cset wC, ne`
        nop              ; was eor wE, w0, wC
        nop              ; was tbz wE, #0, <abort>
    """
    for i in range(len(insns) - 2):
        cset = insns[i]
        if cset.mnemonic != "cset" or _rn(cset, 0) != "w0":
            continue
        if not cset.op_str.strip().endswith("eq"):
            continue
        if insns[i + 1].mnemonic != "nop" or insns[i + 2].mnemonic != "nop":
            continue
        # The `cmp wX, #0` feeding it keeps this from matching an unrelated
        # `cset w0, eq` that happens to precede padding.
        for j in range(i - 1, max(-1, i - 5), -1):
            cand = insns[j]
            if cand.mnemonic != "cmp":
                continue
            ops = cand.operands
            if len(ops) == 2 and ops[1].type == ARM64_OP_IMM and ops[1].imm == 0:
                return cset
            break
    return None


def patch_xpc_lwcr(chunks_dir, *, dry_run=False):
    records.set_group("xpc_lwcr")
    chunks = DSCChunks(chunks_dir)
    print(f"  [.] {chunks!r}")

    # Self-gating: the LWCR path only exists on iOS 27+ libxpc. On older
    # userlands the symbol is absent, so this is a no-op there.
    fn_vma = None
    resolved_name = None
    for candidate in SYMBOL_CANDIDATES:
        try:
            fn_vma = resolve_local_symbol(chunks_dir, candidate)
            resolved_name = candidate
            break
        except RuntimeError:
            continue
    if fn_vma is None:
        print(f"      [=] {SYMBOL} not present (pre-iOS-27 userland); nothing to patch")
        return 0
    print(f"  [.] {resolved_name} @ 0x{fn_vma:X}")

    insns = _disasm_function(chunks, fn_vma, 160)
    found = _find_consistency_check(insns)
    if found is None:
        already = _find_patched_shape(insns)
        if already is not None:
            print(f"      [=] already patched at 0x{already.address:X} "
                  f"(cset w0,eq; nop; nop); nothing to patch/re-attest")
            print(f"  [+] libxpc LWCR self-check patch complete")
            return 0
        raise ValueError(
            f"{SYMBOL}: LWCR consistency idiom (cset wC,ne; eor wE,w0,wC; "
            f"tbz wE,#0) not found"
        )
    cset, eor, tbz = found
    print(f"      [.] cset @ 0x{cset.address:X}: {cset.mnemonic} {cset.op_str}")
    print(f"      [.] eor  @ 0x{eor.address:X}: {eor.mnemonic} {eor.op_str}")
    print(f"      [.] tbz  @ 0x{tbz.address:X}: {tbz.mnemonic} {tbz.op_str}")

    nop = asm("nop")
    cset_new = asm("cset w0, eq")  # w0 = matched = (error_code == 0)
    edits = [
        (cset.address, cset_new, "cset w0, eq"),
        (eor.address, nop, "nop"),
        (tbz.address, nop, "nop"),
    ]

    modified = []
    for vma, new_bytes, label in edits:
        cur = chunks.bytes_at_vma(vma, 4)
        if cur == new_bytes:
            print(f"      [=] already patched at 0x{vma:X} ({label})")
            continue
        action = "would write" if dry_run else "wrote"
        print(f"      [+] {action} {label} at 0x{vma:X} ({cur.hex()} -> {new_bytes.hex()})")
        if not dry_run:
            records.next_site(
                f"xpc_lwcr.{label.split()[0]}@0x{vma:X}",
                f"{SYMBOL}: `{label}` — derive matched from error_code and drop the abort",
            )
            chunks.write_at_vma(vma, new_bytes)
        modified.append(vma)

    if not dry_run and modified:
        print(f"  [.] re-attesting modified page(s)...")
        reattest_modified_pages(chunks, modified, dry_run=False)
        for vma, new_bytes, _ in edits:
            if chunks.bytes_at_vma(vma, 4) != new_bytes:
                raise RuntimeError(f"post-write verify failed at 0x{vma:X}")
    elif dry_run:
        print(f"  [.] dry-run: would re-attest page for {[hex(v) for v in modified]}")

    print(f"  [+] libxpc LWCR self-check patch complete")
    return 1


if __name__ == "__main__":
    import sys
    dry = "--apply" not in sys.argv
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    d = args[0] if args else "/private/tmp/cryptex27/System/Library/Caches/com.apple.dyld"
    patch_xpc_lwcr(d, dry_run=dry)

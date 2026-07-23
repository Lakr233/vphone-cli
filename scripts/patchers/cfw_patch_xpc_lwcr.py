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

import os
import struct

from capstone.arm64_const import ARM64_OP_REG, ARM64_OP_IMM

try:
    from .cfw_asm import asm, _cs
    from .cfw_dsc_chunks import DSCChunks
    from .cfw_dsc_codesign import reattest_modified_pages
except ImportError:  # direct self-test / standalone execution
    from cfw_asm import asm, _cs
    from cfw_dsc_chunks import DSCChunks
    from cfw_dsc_codesign import reattest_modified_pages


SYMBOL = "_xpc_token_satisfies_lwcr"


def _resolve_local_symbol(chunks_dir, name):
    """Resolve a symbol to its vmaddr via the DSC's own `.symbols` local-symbol
    table (in-image; no repo-exported dumps)."""
    sym = os.path.join(chunks_dir, "dyld_shared_cache_arm64e.symbols")
    with open(sym, "rb") as f:
        hdr = f.read(0x100)
        if hdr[:15] != b"dyld_v1  arm64e":
            raise RuntimeError(f"unexpected .symbols magic in {sym}")
        local_off = struct.unpack_from("<Q", hdr, 72)[0]
        f.seek(local_off)
        nlist_off, nlist_cnt, str_off, str_sz, _eo, _ec = struct.unpack("<IIIIII", f.read(24))
        f.seek(local_off + str_off)
        strings = f.read(str_sz)
        f.seek(local_off + nlist_off)
        nl = f.read(nlist_cnt * 16)
    want = name.encode()
    for i in range(nlist_cnt):
        n_strx, _t, _s, _d, n_value = struct.unpack_from("<IBBHQ", nl, i * 16)
        if n_strx >= len(strings):
            continue
        end = strings.find(b"\x00", n_strx)
        if strings[n_strx:end] == want:
            return n_value
    raise RuntimeError(f"could not resolve {name!r} in .symbols")


def _disasm_function(chunks, vma, max_insns=160):
    buf = chunks.bytes_at_vma(vma, max_insns * 4)
    insns = []
    for insn in _cs.disasm(buf, vma):
        insns.append(insn)
        if insn.mnemonic in ("ret", "retab"):
            break
    return insns


def _rn(insn, idx):
    ops = insn.operands
    if idx >= len(ops) or ops[idx].type != ARM64_OP_REG:
        return None
    return insn.reg_name(ops[idx].reg)


def _find_consistency_check(insns):
    """Locate the LWCR self-consistency idiom and return the (cset, eor, tbz)
    instructions plus the error_code register.

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
                cops = cand.operands
                if len(cops) >= 2 and cops[1].type == ARM64_OP_IMM:
                    # capstone renders the condition as an operand imm code;
                    # use op_str to confirm it is `ne`.
                    pass
                if cand.op_str.strip().endswith("ne"):
                    cset = cand
                break
        if cset is None:
            continue
        return cset, eor, tbz, wC
    return None


def patch_xpc_lwcr(chunks_dir, *, dry_run=False):
    chunks = DSCChunks(chunks_dir)
    print(f"  [.] {chunks!r}")

    # Self-gating: the LWCR path only exists on iOS 27+ libxpc. On older
    # userlands the symbol is absent, so this is a no-op there.
    try:
        fn_vma = _resolve_local_symbol(chunks_dir, SYMBOL)
    except RuntimeError:
        print(f"      [=] {SYMBOL} not present (pre-iOS-27 userland); nothing to patch")
        return 0
    print(f"  [.] {SYMBOL} @ 0x{fn_vma:X}")

    insns = _disasm_function(chunks, fn_vma)
    found = _find_consistency_check(insns)
    if found is None:
        raise ValueError(
            f"{SYMBOL}: LWCR consistency idiom (cset wC,ne; eor wE,w0,wC; "
            f"tbz wE,#0) not found"
        )
    cset, eor, tbz, wC = found
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

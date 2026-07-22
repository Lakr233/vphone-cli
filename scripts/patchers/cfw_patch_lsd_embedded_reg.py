"""Patch LaunchServices so lsd allows app (re)registration from any client.

iOS 27's lsd gates `-[_LSDModifyClient performPostInstallationRegistration:...]`
(and the sibling containerized/rebuild registration paths) behind
`-[_LSDModifyClient clientIsEntitledForEmbeddedRegistrationOperations]`, which
does `xpc_connection_copy_entitlement_value` on the XPC PEER for any of three
privileged entitlements (com.apple.private.coreservices.lsaw /
com.apple.private.installcoordinationd.daemon /
com.apple.private.coreservices.can-register-install-results). A client without
one gets NSError NSOSStatusErrorDomain -54 (permErr) from LSDModifyService.mm,
so `registerApplicationDictionary:` returns NO. This blocks JB app registration
(uicache/Sileo), vphoned's IPA installer, and TrollStore alike.

The entitlement route is a dead end on this stack: even a launchd-spawned
platform daemon (vphoned) with all three entitlements in its VALIDATED csblob
(csops CS_OPS_ENTITLEMENTS_BLOB confirms) is still rejected, because the XPC
peer lsd inspects is not the registering process (LS registration is proxied).

So force the check to always succeed. `clientIsEntitledForEmbeddedRegistration
Operations` ORs three entitlement checks:

    bl  <check ent1> ; cbnz w0, entitled
    bl  <check ent2> ; cbnz w0, entitled
    bl  <check ent3> ; cbz  w0, not_entitled   <- gate: NOP this
  entitled:
    mov w20, #1                                 <- YES result (returned)
    ... ; mov x0, x20 ; retab
  not_entitled:
    mov w20, #0 -> returns 0

NOP'ing the final `cbz w0, <not_entitled>` (the one whose fall-through is the
`mov w<result>, #1`) makes every path reach the YES result. One instruction.

Nothing is hardcoded: the method is resolved from the DSC's own local-symbol
table (in-image), disassembled with Capstone, and the gate located by
control-flow shape (the conditional branch immediately preceding the `mov
w<reg>,#1` that becomes the return value). The replacement is Keystone `nop`.
Modifying a DSC page invalidates its 16 KiB slot hash, so the page is
re-attested (TXM enforces per-page); the resulting CDHash change is accepted by
the JB's always-true AMFI cdhash-trust patch.
"""

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


LAUNCHSERVICES = "/System/Library/Frameworks/CoreServices.framework/CoreServices"
METHOD = "-[_LSDModifyClient clientIsEntitledForEmbeddedRegistrationOperations]"


def _resolve_local_symbol(chunks_dir, name):
    """Resolve an ObjC method symbol to its vmaddr via the DSC's own
    `.symbols` local-symbol table (in-image; no repo-exported dumps). ipsw
    `symaddr -a` times out on this cache, so parse the table directly."""
    import os
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


def _mov_reg_imm(insn):
    if insn.mnemonic != "mov":
        return None
    ops = insn.operands
    if len(ops) != 2 or ops[0].type != ARM64_OP_REG or ops[1].type != ARM64_OP_IMM:
        return None
    return insn.reg_name(ops[0].reg), ops[1].imm


def _disasm_function(chunks, vma, max_insns=96):
    buf = chunks.bytes_at_vma(vma, max_insns * 4)
    insns = []
    for insn in _cs.disasm(buf, vma):
        insns.append(insn)
        if insn.mnemonic in ("ret", "retab"):
            break
    return insns


def _find_gate(insns):
    """Locate the conditional branch that gates the entitled result: the
    `cbz` on w0 whose fall-through instruction is `mov w<reg>,#1`
    (the YES value later moved to x0). Returns (insn, result_reg) or None."""
    for i in range(len(insns) - 1):
        ins = insns[i]
        # Gate is always cbz ("if NOT entitled, fail").
        # cbnz to success is the entitlement check, not the gate.
        if ins.mnemonic != "cbz":
            continue
        ops = ins.operands
        if not ops or ops[0].type != ARM64_OP_REG or ins.reg_name(ops[0].reg) != "w0":
            continue
        nxt = _mov_reg_imm(insns[i + 1])
        if nxt is not None and nxt[1] == 1 and nxt[0].startswith("w"):
            return ins, nxt[0]
    return None
def patch_lsd_embedded_reg(chunks_dir, *, dry_run=False):
    chunks = DSCChunks(chunks_dir)
    print(f"  [.] {chunks!r}")

    # Self-gating: the gate method only exists on iOS 27+ LaunchServices. On
    # older userlands (26.x/18.x) it is absent, so this is a no-op there.
    try:
        fn_vma = _resolve_local_symbol(chunks_dir, METHOD)
    except RuntimeError:
        print(f"      [=] {METHOD} not present (pre-iOS-27 userland); nothing to patch")
        return 0
    print(f"  [.] {METHOD} @ 0x{fn_vma:X}")

    insns = _disasm_function(chunks, fn_vma)
    found = _find_gate(insns)
    if found is None:
        # iOS 27 (build 24A5390f+): the three entitlement checks all use
        # cbnz -> success with no cbz gate.  The function already always
        # returns YES, so no patch is needed.
        # Positive assertion: confirm at least one cbnz w0 exists (proves
        # the function has entitlement-check structure).  If neither cbz
        # nor cbnz on w0 is found, the function shape is unrecognizable.
        has_cbnz_check = any(
            ins.mnemonic == "cbnz"
            for ins in insns
            if ins.op_str.startswith("w0,")
        )
        if has_cbnz_check:
            print(f"      [=] no cbz gate; function uses all-cbnz pattern (iOS 27+), already always returns YES; skipping")
            return 0
        raise ValueError(
            f"{METHOD}: no cbz/cbnz on w0 found; unrecognized function shape"
        )
    print(f"      [.] gate: {gate.mnemonic} {gate.op_str} @ 0x{insn_vma:X} "
          f"(fall-through sets {result_reg}=1)")

    nop = asm("nop")
    if len(nop) != 4:
        raise RuntimeError(f"expected 4 nop bytes, got {len(nop)}")

    cur = chunks.bytes_at_vma(insn_vma, 4)
    if cur == nop:
        print(f"      [=] already NOP at 0x{insn_vma:X}; re-attesting page only")
    else:
        action = "would NOP" if dry_run else "NOP'd"
        print(f"      [+] {action} gate {gate.mnemonic} -> nop at 0x{insn_vma:X} "
              f"(bytes {cur.hex()} -> {nop.hex()})")
        if not dry_run:
            chunks.write_at_vma(insn_vma, nop)

    if not dry_run:
        print(f"  [.] re-attesting modified page...")
        reattest_modified_pages(chunks, [insn_vma], dry_run=False)
        if chunks.bytes_at_vma(insn_vma, 4) != nop:
            raise RuntimeError(f"post-write verify failed at 0x{insn_vma:X}")
    else:
        print(f"  [.] dry-run: would re-attest page for 0x{insn_vma:X}")

    print(f"  [+] lsd embedded-registration gate patch complete")
    return 1


if __name__ == "__main__":
    import sys
    dry = "--apply" not in sys.argv
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    d = args[0] if args else "/private/tmp/cryptex27/System/Library/Caches/com.apple.dyld"
    patch_lsd_embedded_reg(d, dry_run=dry)

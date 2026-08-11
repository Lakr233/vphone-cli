"""Stop libSystem's `os_lockdown_mode_enabled` from crashing on the vphone kernel.

iOS 27's `os_lockdown_mode_enabled()` resolves Lockdown Mode once via
`sysctlbyname("security.mac.lockdown_mode_state_public", ...)` and, if the
sysctl call returns -1, calls `os_crash` (lockdown_mode.c). The vphone base
kernel (cloudOS 26.x) does not implement that MAC sysctl, so the call fails
with ENOENT and every process that queries Lockdown Mode aborts — including
launchd (pid 1), which panics the system right after "Continuing system boot".

The block pre-zeroes its output buffer (`stp x8, xzr, [sp]`), so dropping the
error branch makes the failure path fall through to the normal path, read 0,
and record "Lockdown Mode disabled". On a kernel that does implement the sysctl
the branch is never taken, so the patch is behavior-neutral there.

Shape (in `___os_lockdown_mode_enabled_block_invoke`):

    bl      <sysctlbyname>
    cmn     w0, #1            ; w0 == -1 ?
    b.eq    <os_crash>        ; -> NOP

Anchored on the in-image local symbol; the sysctl-error idiom is located by
control-flow shape via Capstone; the NOP comes from Keystone; the modified page
is re-attested (`cfw_dsc_codesign.py`).
"""

from capstone.arm64_const import ARM64_OP_IMM

try:
    from .cfw_asm import asm, _cs
    from .cfw_dsc_chunks import DSCChunks
    from .cfw_dsc_codesign import reattest_modified_pages
    from .cfw_patch_xpc_lwcr import _resolve_local_symbol
except ImportError:
    from cfw_asm import asm, _cs
    from cfw_dsc_chunks import DSCChunks
    from cfw_dsc_codesign import reattest_modified_pages
    from cfw_patch_xpc_lwcr import _resolve_local_symbol

SYMBOL_CANDIDATES = (
    "___os_lockdown_mode_enabled_block_invoke",
    "__os_lockdown_mode_enabled_block_invoke",
)


def _imm(insn, idx):
    ops = insn.operands
    return ops[idx].imm if idx < len(ops) and ops[idx].type == ARM64_OP_IMM else None


def _disasm(chunks, vma, n=60):
    buf = chunks.bytes_at_vma(vma, n * 4)
    out = []
    for insn in _cs.disasm(buf, vma):
        out.append(insn)
        if insn.mnemonic in ("ret", "retab"):
            break
    return out


def _find_error_gate(insns):
    """The `cmn wR, #1; b.eq` sysctl-error idiom, preceded by a bl."""
    saw_bl = False
    for i in range(len(insns) - 1):
        if insns[i].mnemonic == "bl":
            saw_bl = True
        if not saw_bl:
            continue
        if insns[i].mnemonic == "cmn" and _imm(insns[i], 1) == 1:
            beq = insns[i + 1]
            if beq.mnemonic == "b.eq":
                return beq
    return None


def patch_lockdown_mode(chunks_dir, *, dry_run=False):
    chunks = DSCChunks(chunks_dir)
    print(f"  [.] {chunks!r}")

    fn_vma = None
    for name in SYMBOL_CANDIDATES:
        try:
            fn_vma = _resolve_local_symbol(chunks_dir, name)
            break
        except RuntimeError:
            continue
    if fn_vma is None:
        print("      [=] os_lockdown_mode_enabled not present (pre-iOS-27 userland); nothing to patch")
        return 0
    print(f"  [.] {name} @ 0x{fn_vma:X}")

    gate = _find_error_gate(_disasm(chunks, fn_vma))
    if gate is None:
        raise ValueError("lockdown_mode: `cmn wR,#1; b.eq <crash>` sysctl-error gate not found")
    print(f"      [.] gate @ 0x{gate.address:X}: {gate.mnemonic} {gate.op_str}")

    nop = asm("nop")
    cur = chunks.bytes_at_vma(gate.address, 4)
    if cur == nop:
        print("      [=] already patched")
        return 1
    action = "would write" if dry_run else "wrote"
    print(f"      [+] {action} nop at 0x{gate.address:X} ({cur.hex()} -> {nop.hex()})")
    if not dry_run:
        chunks.write_at_vma(gate.address, nop)
        reattest_modified_pages(chunks, [gate.address], dry_run=False)
        if chunks.bytes_at_vma(gate.address, 4) != nop:
            raise RuntimeError(f"post-write verify failed at 0x{gate.address:X}")
    print("  [+] lockdown-mode crash patch complete")
    return 1


if __name__ == "__main__":
    import sys
    dry = "--apply" not in sys.argv
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    d = args[0] if args else "/private/tmp/cryptex27/System/Library/Caches/com.apple.dyld"
    patch_lockdown_mode(d, dry_run=dry)

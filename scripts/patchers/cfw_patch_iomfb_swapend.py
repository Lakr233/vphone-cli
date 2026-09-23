"""Patch IOMobileFramebuffer SwapEnd payload size to match the base kernel.

The SwapEnd input-state size is enforced kernel-side: the PCC vphone600
kernel's IOMobileFramebufferUserClient external method 5 (SwapEnd /
swap_submit) does an exact `checkStructureInputSize` check. A userland whose
`_kern_SwapEnd` sends a different size gets kIOReturnBadArgument, so no frame
is presented and the host VZ display stays black (the guest still renders —
the Apple logo is visible over VNC, just not in the vphone-cli view).

The accepted size is a property of the BASE KERNEL, not the userland:
  - 26.1 base (older): userclient expects 0x560.
  - 26.4 base (xnu-12377, current): userclient expects 0x588. Confirmed two
    ways: the sole dispatch-shaped entry in kernelcache.*.vphone600 with
    checkStructureInputSize==0x588 (scalarIn=0, scalarOut=0, structOut=0,
    preceded by a ptrauth code ptr), and empirically — native 26.5 userland
    sends 0x588 and displays correctly on this stack.

Known userland-sent sizes: 18.6.2 -> 0x514, 26.0/26.0.1 -> 0x548,
26.5 -> 0x588 (native match on 26.4), 27.0 (24A5380h) -> 0x6e0.

`_kern_SwapEnd` sets up an external-method-5 call:

    ldr w0, [x0,#0x14]
    add x2, x19,#0x18
    mov w1,#5          <- external method selector 5
    mov w3,#<size>     <- input-state size (source; version-specific)
    mov x4,#0
    mov x5,#0
    bl  _io_connect_method

The `mov w3,#<size>` immediate is what this patcher rewrites to the target
size (default 0x588 for the 26.4 base; override via `target_size`). The site
is located dynamically: resolve `_kern_SwapEnd`, disassemble it with Capstone,
and anchor on the semantic call-setup shape (selector `mov w1,#5` then
`mov w3,#imm` then the zeroed `mov x4,#0`/`mov x5,#0` and the `bl`). Nothing
about the source size is hardcoded — it is discovered, never matched — so this
fires on any userland; the replacement immediate comes from the
Keystone-backed `asm()` helper.
"""

import os
import re
import shutil
import subprocess

try:
    from .cfw_asm import asm, _cs, _mov_reg_imm
    from .cfw_dsc_chunks import DSCChunks, _disasm_function
    from .cfw_dsc_codesign import reattest_modified_pages
    from . import cfw_records as records
except ImportError:  # direct self-test execution
    from cfw_asm import asm, _cs, _mov_reg_imm
    from cfw_dsc_chunks import DSCChunks, _disasm_function
    from cfw_dsc_codesign import reattest_modified_pages
    import cfw_records as records


IOMFB = "/System/Library/PrivateFrameworks/IOMobileFramebuffer.framework/IOMobileFramebuffer"
SWAPEND_SYMBOL = "_kern_SwapEnd"

# External-method selector for SwapEnd, and the input-state size the 26.4
# vphone600 userclient accepts (checkStructureInputSize). TARGET_SIZE is the
# semantic goal, not an anchor — the source immediate (e.g. 0x6e0 on 27.0) is
# discovered, never matched. Override via patch_iomfb_swapend(target_size=...)
# when building against a different base kernel (26.1 base wants 0x560).
SWAPEND_SELECTOR = 5
TARGET_SIZE = 0x588


def _resolve_symbol(dsc_path, image, symbol):
    """Resolve a single symbol's vmaddr in `image` via `ipsw dyld symaddr`.
    Returns the vmaddr, or raises if unresolved. Mirrors the resolution
    idiom in cfw_patch_camera_dsc."""
    ipsw_bin = shutil.which("ipsw")
    if not ipsw_bin:
        raise RuntimeError("`ipsw` not in PATH")
    cmd = [ipsw_bin, "dyld", "symaddr", dsc_path, "--image", image, symbol]
    out = subprocess.run(cmd, capture_output=True, text=True, check=True).stdout
    for line in out.splitlines():
        line = re.sub(r"\x1b\[[0-9;]*m", "", line).rstrip()
        m = re.match(r"\s*(0x[0-9A-Fa-f]+):.*\b" + re.escape(symbol) + r"\b", line)
        if m:
            return int(m.group(1), 16)
    raise RuntimeError(f"could not resolve {symbol} in {image}")


def _find_swap_size_insn(insns):
    """Locate the `mov w3,#imm` that sets the SwapEnd input-state size.

    Anchored on the external-method call setup: `mov w1,#5` (selector),
    immediately followed by `mov w3,#imm`, then `mov x4,#0`, `mov x5,#0`,
    and a `bl`. Returns that insn, or None if the shape isn't found.
    """
    for i in range(len(insns) - 4):
        sel = _mov_reg_imm(insns[i])
        if sel != ("w1", SWAPEND_SELECTOR):
            continue
        size = _mov_reg_imm(insns[i + 1])
        if size is None or size[0] != "w3":
            continue
        if _mov_reg_imm(insns[i + 2]) != ("x4", 0):
            continue
        if _mov_reg_imm(insns[i + 3]) != ("x5", 0):
            continue
        if insns[i + 4].mnemonic != "bl":
            continue
        return insns[i + 1]
    return None


def patch_iomfb_swapend(chunks_dir, *, dsc_path=None, target_size=TARGET_SIZE,
                        dry_run=False):
    records.set_group("iomfb_swapend")
    chunks = DSCChunks(chunks_dir)
    print(f"  [.] {chunks!r}")

    if dsc_path is None:
        dsc_path = os.path.join(chunks_dir, "dyld_shared_cache_arm64e")

    fn_vma = _resolve_symbol(dsc_path, IOMFB, SWAPEND_SYMBOL)
    print(f"  [.] {SWAPEND_SYMBOL} @ 0x{fn_vma:X}")

    insns = _disasm_function(chunks, fn_vma, 64)
    target = _find_swap_size_insn(insns)
    if target is None:
        raise ValueError(
            f"{SWAPEND_SYMBOL} SwapEnd size site (mov w1,#{SWAPEND_SELECTOR} "
            f"-> mov w3,#imm -> ... -> bl) not found"
        )

    _reg, cur_size = _mov_reg_imm(target)
    insn_vma = target.address
    new_bytes = asm(f"mov w3, #{target_size}")
    if len(new_bytes) != 4:
        raise RuntimeError(f"expected 4 bytes, got {len(new_bytes)}")

    if cur_size == target_size:
        print(f"      [=] already 0x{target_size:X} at 0x{insn_vma:X}; "
              f"re-attesting page only")
    else:
        action = "would patch" if dry_run else "patched"
        print(f"      [+] {action} {IOMFB} {SWAPEND_SYMBOL} size "
              f"0x{cur_size:X} -> 0x{target_size:X} at 0x{insn_vma:X}")
        if not dry_run:
            records.next_site(
                "iomfb_swapend.payload_size",
                f"{IOMFB} {SWAPEND_SYMBOL} external-method payload size "
                f"0x{cur_size:X} -> 0x{target_size:X}",
            )
            chunks.write_at_vma(insn_vma, new_bytes)

    if not dry_run:
        print(f"  [.] re-attesting modified page...")
        reattest_modified_pages(chunks, [insn_vma], dry_run=False)
        if chunks.bytes_at_vma(insn_vma, 4) != new_bytes:
            raise RuntimeError(f"post-write verify failed at 0x{insn_vma:X}")
    else:
        print(f"  [.] dry-run: would re-attest page for 0x{insn_vma:X}")

    print(f"  [+] IOMFB SwapEnd patch complete")
    return 1


def _self_test():
    """Validate the finder against a synthetic call-setup sequence built
    from the assembler, with a source size (0x548) unlike the target."""
    seq = (
        asm("ldr w0, [x0, #0x14]")
        + asm("add x2, x19, #0x18")
        + asm("mov w1, #5")
        + asm("mov w3, #0x548")
        + asm("mov x4, #0")
        + asm("mov x5, #0")
        + asm("bl #0x40")
    )
    insns = list(_cs.disasm(seq, 0x1000))
    target = _find_swap_size_insn(insns)
    assert target is not None, "finder failed to locate size insn"
    reg, imm = _mov_reg_imm(target)
    assert (reg, imm) == ("w3", 0x548), (reg, hex(imm))
    assert target.address == 0x1000 + 12, hex(target.address)
    assert TARGET_SIZE == 0x588, hex(TARGET_SIZE)
    assert asm(f"mov w3, #{TARGET_SIZE}") == bytes.fromhex("03b18052")
    print("self-test OK")


if __name__ == "__main__":
    _self_test()

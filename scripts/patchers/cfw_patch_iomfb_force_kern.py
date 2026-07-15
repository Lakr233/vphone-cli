"""Force IOMobileFramebuffer to present through the kern (userclient method-5)
path instead of the virt (in-process callback) path.

Why: on the vphone600 26.x kernel the host VZ display is fed by the guest
AppleParavirtGPU scanout, which is driven ONLY by the IOMFB userclient swap
methods — the `_kern_Swap*` family (`_kern_SwapEnd` == external method 5).
26.x userlands presented via `_kern_*` (which is why the SwapEnd size patch,
cfw_patch_iomfb_swapend, fixed the VZ view on 26.0/18.x). iOS 27 routes the
paravirt display's present through the PARALLEL `_virt_Swap*` family instead —
`_virt_SwapEnd` performs no userclient call; it invokes an in-process callback
and hands the composited IOSurface to a virtual-display consumer. Those frames
never enter the kernel userclient, so the paravirt GPU never scans out and the
host VZ window stays black (the guest still composites — the GUI is visible
over the in-guest TrollVNC capturer, and AppleParavirtGPU's scheduler sits idle).

The public `_IOMobileFramebufferSwap*` entrypoints are thin dispatch
trampolines that tail-call a per-connection function pointer:

    cbz   x0, <fail>
    ldr   xN, [x0, #<slot>]     ; the connection's swap fp (kern or virt impl)
    cbz   xN, <fail>
    braaz xN                    ; tail-call, all argument registers intact

This patcher rewrites the FIRST instruction of each such trampoline to an
unconditional `b _kern_Swap<Name>`. Because the trampoline tail-calls with the
argument registers untouched, `b _kern_Swap<Name>` is behaviourally identical
to the connection having selected the kern fp — every present call now routes
through the kern/method-5 implementation regardless of how iOS 27 classified
the display.

Companion kernel patch (KernelJBPatchIomfbSwap): make the 26.4 userclient
accept iOS 27's native 0x6e0 SwapEnd struct (26.x sent 0x588). Both are
required together — forcing kern without the kernel size-accept makes method 5
return kIOReturnBadArgument.

Nothing is hardcoded: the public entrypoints and their `_kern_` counterparts
are resolved by NAME via `ipsw dyld symaddr`, the trampoline shape is verified
by Capstone decode, and the replacement branch bytes come from the
Keystone-backed `asm_at()` helper. The modified DSC code page(s) are re-attested.
"""

import os
import re
import shutil
import subprocess

try:
    from .cfw_asm import asm_at, _cs
    from .cfw_dsc_chunks import DSCChunks
    from .cfw_dsc_codesign import reattest_modified_pages
except ImportError:  # direct execution
    from cfw_asm import asm_at, _cs
    from cfw_dsc_chunks import DSCChunks
    from cfw_dsc_codesign import reattest_modified_pages


IOMFB = "/System/Library/PrivateFrameworks/IOMobileFramebuffer.framework/IOMobileFramebuffer"

# The present transaction the render server drives; each public entrypoint is
# retargeted to its `_kern_` sibling if (and only if) it is a thin dispatch
# trampoline. The set is discovered at runtime — this is the minimum that MUST
# be present for the patch to be meaningful (else we raise, rather than ship a
# half-forced, incoherent swap path).
REQUIRED = ("SwapBegin", "SwapEnd", "SwapSetLayer")


def _all_symbols(dsc_path, image):
    """Return {symbol_name: vmaddr} for every symbol `ipsw` reports in `image`."""
    ipsw_bin = shutil.which("ipsw")
    if not ipsw_bin:
        raise RuntimeError("`ipsw` not in PATH")
    out = subprocess.run(
        [ipsw_bin, "dyld", "symaddr", dsc_path, "--image", image],
        capture_output=True, text=True, check=True,
    ).stdout
    syms = {}
    for line in out.splitlines():
        line = re.sub(r"\x1b\[[0-9;]*m", "", line)
        m = re.match(r"\s*(0x[0-9A-Fa-f]+):\s+\([^)]*\)\s+(\S+)", line)
        if m:
            syms.setdefault(m.group(2), int(m.group(1), 16))
    return syms


def _is_dispatch_trampoline(chunks, va):
    """True iff the 4 insns at `va` are `cbz x0,.. ; ldr xN,[x0,#imm] ; cbz xN,.. ; braaz xN`."""
    insns = list(_cs.disasm(chunks.bytes_at_vma(va, 4 * 4), va))
    if len(insns) < 4:
        return False
    i0, i1, i2, i3 = insns[:4]
    if i0.mnemonic != "cbz" or not i0.op_str.startswith("x0,"):
        return False
    if i1.mnemonic != "ldr" or "[x0, #" not in i1.op_str:
        return False
    reg = i1.op_str.split(",")[0].strip()      # scratch reg the fp is loaded into
    if i2.mnemonic != "cbz" or not i2.op_str.startswith(reg + ","):
        return False
    if i3.mnemonic not in ("braaz", "braa", "br") or not i3.op_str.startswith(reg):
        return False
    return True


def patch_iomfb_force_kern(chunks_dir, *, dsc_path=None, dry_run=False):
    chunks = DSCChunks(chunks_dir)
    print(f"  [.] {chunks!r}")

    if dsc_path is None:
        dsc_path = os.path.join(chunks_dir, "dyld_shared_cache_arm64e")

    syms = _all_symbols(dsc_path, IOMFB)

    # Every public swap entrypoint with a `_kern_` sibling.
    pub_prefix = "_IOMobileFramebufferSwap"
    candidates = []
    for name, va in syms.items():
        if not name.startswith(pub_prefix):
            continue
        suffix = "Swap" + name[len(pub_prefix):]        # e.g. "SwapEnd"
        kern = "_kern_" + suffix
        if kern in syms:
            candidates.append((suffix, name, va, kern, syms[kern]))
    candidates.sort()

    modified = []
    forced = set()
    already = set()
    for suffix, pub_name, pub_va, kern_name, kern_va in candidates:
        first = next(_cs.disasm(chunks.bytes_at_vma(pub_va, 4), pub_va), None)
        # Idempotent: a prior run already rewrote this entrypoint to `b _kern_*`.
        if first is not None and first.mnemonic == "b":
            m = re.match(r"#(0x[0-9a-fA-F]+)$", first.op_str.strip())
            if m and int(m.group(1), 16) == kern_va:
                print(f"      [=] {pub_name} already -> b {kern_name} (idempotent)")
                already.add(suffix)
                continue
        if not _is_dispatch_trampoline(chunks, pub_va):
            print(f"      [=] {pub_name} not a thin trampoline; leaving on virt path")
            continue
        b_bytes = asm_at(f"b #{kern_va}", pub_va)
        if len(b_bytes) != 4:
            raise RuntimeError(f"expected 4 bytes for b, got {len(b_bytes)}")
        print(f"      [+] {pub_name} @ 0x{pub_va:X}: "
              f"'{first.mnemonic} {first.op_str}' -> 'b {kern_name}' (0x{kern_va:X})")
        if not dry_run:
            chunks.write_at_vma(pub_va, b_bytes)
        modified.append(pub_va)
        forced.add(suffix)

    covered = forced | already
    missing = [s for s in REQUIRED if s not in covered]
    if missing:
        raise ValueError(
            f"force-kern did not cover required entrypoints {missing} "
            f"(newly forced: {sorted(forced)}; already forced: {sorted(already)})"
        )

    if dry_run:
        print(f"  [.] dry-run: would re-attest {len(set(modified))} page(s)")
    elif modified:
        print(f"  [.] re-attesting {len(set(modified))} modified page(s)...")
        reattest_modified_pages(chunks, modified, dry_run=False)
        for va in modified:
            ins = next(_cs.disasm(chunks.bytes_at_vma(va, 4), va))
            if ins.mnemonic != "b":
                raise RuntimeError(f"post-write verify failed at 0x{va:X} ({ins.mnemonic})")
    else:
        print(f"  [=] all {len(already)} entrypoint(s) already forced; nothing to patch/re-attest")

    print(f"  [+] IOMFB force-kern complete: {len(forced)} newly forced, {len(already)} already -> _kern_*")
    return len(modified)

"""Patch iOS 26.0 and 26.0.1 IOMobileFramebuffer SwapEnd payload size.

The PCC vphone600 26.1 kernel-side IOMobileFramebuffer external method 5
expects the newer 0x560-byte swap state. iOS 26.0 and 26.0.1 userland send 0x548,
so SwapEnd returns kIOReturnBadArgument and the VM display stays black.
"""

try:
    from .cfw_dsc_chunks import DSCChunks
    from .cfw_dsc_codesign import reattest_modified_pages
except ImportError:  # direct self-test execution
    from cfw_dsc_chunks import DSCChunks
    from cfw_dsc_codesign import reattest_modified_pages


IOMFB = "/System/Library/PrivateFrameworks/IOMobileFramebuffer.framework/IOMobileFramebuffer"

# _kern_SwapEnd:
#   ldr w0, [x0,#0x14]
#   add x2, x19,#0x18
#   mov w1,#5
#   mov w3,#0x548   <-- patch to 0x560
#   mov x4,#0
#   mov x5,#0
OLD = bytes.fromhex("001440b962620091a100805203a98052040080d2050080d2")
NEW_INSN = bytes.fromhex("03ac8052")


def patch_iomfb_swapend(chunks_dir, *, dry_run=False):
    chunks = DSCChunks(chunks_dir)
    print(f"  [.] {chunks!r}")
    modified = []
    already = 0
    refused = 0

    for _cp, _foff, vma_start, buf in chunks.iter_executable_mapping_bytes():
        i = 0
        while True:
            p = buf.find(OLD, i)
            if p < 0:
                break
            insn_vma = vma_start + p + 12
            header = chunks.find_macho_header_before(insn_vma)
            install = chunks.read_install_name_at(header) if header is not None else None
            if install != IOMFB:
                refused += 1
                print(f"      [-] refusing non-IOMFB hit at 0x{insn_vma:X}: {install}")
            else:
                if not dry_run:
                    chunks.write_at_vma(insn_vma, NEW_INSN)
                modified.append(insn_vma)
                print(f"      [+] {'would patch' if dry_run else 'patched'} {IOMFB} _kern_SwapEnd size 0x548 -> 0x560 at 0x{insn_vma:X}")
            i = p + 4

        # Idempotent rerun support.
        patched = OLD[:12] + NEW_INSN + OLD[16:]
        i = 0
        while True:
            p = buf.find(patched, i)
            if p < 0:
                break
            insn_vma = vma_start + p + 12
            header = chunks.find_macho_header_before(insn_vma)
            install = chunks.read_install_name_at(header) if header is not None else None
            if install == IOMFB:
                already += 1
                modified.append(insn_vma)
                print(f"      [=] already patched at 0x{insn_vma:X}")
            i = p + 4

    if not modified:
        raise ValueError("IOMobileFramebuffer 26.0/26.0.1 SwapEnd size site not found")
    if modified and not dry_run:
        print(f"  [.] re-attesting {len(set(modified))} modified page(s)...")
        reattest_modified_pages(chunks, sorted(set(modified)), dry_run=False)
    elif modified:
        print(f"  [.] dry-run: would re-attest {len(set(modified))} page(s)")

    print(f"  [+] IOMFB SwapEnd patch complete: {len(modified) - already} patched, {already} already, {refused} refused")
    return len(modified)


def _self_test():
    assert OLD[12:16] == bytes.fromhex("03a98052")
    assert NEW_INSN == bytes.fromhex("03ac8052")
    patched = OLD[:12] + NEW_INSN + OLD[16:]
    assert patched == bytes.fromhex("001440b962620091a100805203ac8052040080d2050080d2")


if __name__ == "__main__":
    _self_test()

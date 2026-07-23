"""Clamp the dyld shared cache maxSlide so a large userland cache fits the
PCC vphone600 26.x kernel's fixed 6 GiB shared region.

The vphone600 26.x kernel reserves SHARED_REGION_SIZE_ARM64 = 0x180000000 (6 GiB)
at SHARED_REGION_BASE_ARM64 = 0x180000000 (verified by disassembling the arm64 case
of the kernel's shared_region_create). At map time the kernel needs room for the
cache's mapped span PLUS the cache-header maxSlide (the ASLR range). A newer userland
whose cache nearly fills the region overflows it:

    iOS 27.0 (24A5380h): span 0x17c830000 (~5.95 GiB) + maxSlide 0x20000000 (512 MiB)
                         = 0x19c830000 (~6.46 GiB)  >  0x180000000 (6 GiB)

-> _shared_region_map_and_slide returns ENOMEM -> dyld cannot map libSystem ->
launchd (pid 1) panics ("initproc failed to start -- Library not loaded:
/usr/lib/libSystem.B.dylib"). Older userlands (e.g. 26.x/18.x) fit with full slide
and are unaffected.

Fix: zero maxSlide in the cache header so the cache maps at slide 0 and fits (iOS 27.0
leaves ~58 MiB spare). Only the main chunk `dyld_shared_cache_arm64e` carries the
dyld_cache_header. maxSlide is a plain metadata field the kernel reads during map
setup, NOT a cs_validate'd dylib code page — so, unlike cfw_patch_iomfb_swapend, NO
page re-attestation is required (confirmed empirically: a live-poked cache with
maxSlide=0 booted with "dyld cache mapped system-wide", 0 panics).

Self-gating: no-op unless span + maxSlide overflows the region. force=True
(CLI --force) zeroes maxSlide unconditionally, for non-27 bases that opt in.

dyld_cache_header offsets (little-endian u64, stable across recent iOS):
    sharedRegionStart @0xE0,  sharedRegionSize @0xE8,  maxSlide @0xF0
"""

import os
import struct

MAIN_CHUNK = "dyld_shared_cache_arm64e"

OFF_SHARED_REGION_START = 0xE0
OFF_SHARED_REGION_SIZE = 0xE8
OFF_MAX_SLIDE = 0xF0

# SHARED_REGION_SIZE_ARM64 baked into the PCC vphone600 26.x kernel. The cache's
# span + maxSlide must fit within this or the shared_region map ENOMEMs.
KERNEL_SHARED_REGION_SIZE = 0x180000000


def patch_dsc_maxslide(chunks_dir, *, kernel_region_size=KERNEL_SHARED_REGION_SIZE, dry_run=False, force=False):
    main = os.path.join(chunks_dir, MAIN_CHUNK)
    if not os.path.isfile(main):
        raise FileNotFoundError(f"main DSC chunk not found: {main}")

    with open(main, "r+b") as f:
        hdr = f.read(0x100)
        if hdr[:7] != b"dyld_v1":
            raise RuntimeError(f"{main}: not a dyld shared cache (magic={hdr[:16]!r})")
        srstart = struct.unpack_from("<Q", hdr, OFF_SHARED_REGION_START)[0]
        srsize = struct.unpack_from("<Q", hdr, OFF_SHARED_REGION_SIZE)[0]
        maxslide = struct.unpack_from("<Q", hdr, OFF_MAX_SLIDE)[0]
        print(f"  [.] {MAIN_CHUNK}: start=0x{srstart:X} size=0x{srsize:X} maxSlide=0x{maxslide:X}")

        fits = srsize + maxslide <= kernel_region_size
        if fits and not force:
            print(f"      [=] fits: span+maxSlide 0x{srsize + maxslide:X} <= "
                  f"region 0x{kernel_region_size:X}; no change")
            return 0
        if maxslide == 0:
            print("      [=] maxSlide already 0; no change")
            return 0

        # Set maxSlide to 0 so the cache maps at slide 0 within the region.
        new_maxslide = 0
        reason = (f"forced: span+maxSlide 0x{srsize + maxslide:X} fits region "
                  f"0x{kernel_region_size:X} but --force set" if fits
                  else f"overflow: span+maxSlide 0x{srsize + maxslide:X} > "
                       f"region 0x{kernel_region_size:X}")
        action = "would set" if dry_run else "set"
        print(f"      [+] {reason}; {action} maxSlide 0x{maxslide:X} -> 0x{new_maxslide:X}")
        if not dry_run:
            f.seek(OFF_MAX_SLIDE)
            f.write(struct.pack("<Q", new_maxslide))
            f.flush()
            os.fsync(f.fileno())
            f.seek(OFF_MAX_SLIDE)
            back = struct.unpack("<Q", f.read(8))[0]
            if back != new_maxslide:
                raise RuntimeError(f"maxSlide write verify failed: 0x{back:X}")

    print("  [+] DSC maxSlide patch complete")
    return 1


def _self_test():
    """Gate logic: a cache that overflows gets clamped; one that fits is untouched."""
    import tempfile

    def mkcache(size, maxslide, path):
        hdr = bytearray(0x100)
        hdr[0:16] = b"dyld_v1  arm64e\x00"
        struct.pack_into("<Q", hdr, OFF_SHARED_REGION_START, 0x180000000)
        struct.pack_into("<Q", hdr, OFF_SHARED_REGION_SIZE, size)
        struct.pack_into("<Q", hdr, OFF_MAX_SLIDE, maxslide)
        open(path, "wb").write(hdr)

    with tempfile.TemporaryDirectory() as d:
        c = os.path.join(d, MAIN_CHUNK)
        # overflow (iOS 27.0-like): 0x17c830000 + 0x20000000 > 0x180000000 -> clamp
        mkcache(0x17C830000, 0x20000000, c)
        assert patch_dsc_maxslide(d) == 1
        with open(c, "rb") as f:
            f.seek(OFF_MAX_SLIDE)
            assert struct.unpack("<Q", f.read(8))[0] == 0
        # fits (26.4-like): 0x140904000 + 0x20000000 <= 0x180000000 -> untouched
        mkcache(0x140904000, 0x20000000, c)
        assert patch_dsc_maxslide(d) == 0
        with open(c, "rb") as f:
            f.seek(OFF_MAX_SLIDE)
            assert struct.unpack("<Q", f.read(8))[0] == 0x20000000
        # fits + force: opt-in zeroes maxSlide even though it fits
        assert patch_dsc_maxslide(d, force=True) == 1
        with open(c, "rb") as f:
            f.seek(OFF_MAX_SLIDE)
            assert struct.unpack("<Q", f.read(8))[0] == 0
        # force + already 0: idempotent no-op
        assert patch_dsc_maxslide(d, force=True) == 0
    print("self-test OK")


if __name__ == "__main__":
    _self_test()

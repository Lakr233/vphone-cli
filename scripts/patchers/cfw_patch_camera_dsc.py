"""Camera-related DSC patches for the vphone EXP firmware.

Two patch families:

1. NeutrinoCore short-circuit — replace the five
   `+[_NUStyleTransfer*Processor processWithInputs:arguments:output:error:]`
   class methods with `mov w0, #0; ret`. Together with the DT `/product/camera`
   node (added by `DeviceTreePatcher.swift`), this lets Camera.app launch and
   reach the viewfinder UI on this VM build without crashing in NeutrinoCore.

2. AVCaptureDevice authorization gate — replace
   `+[AVCaptureDevice authorizationStatusForMediaType:]` in `AVFCapture` with
   `mov w0, #3; ret` (AVAuthorizationStatusAuthorized = 3). Any process that
   probes camera (or any other media type) authorization gets "Authorized"
   without going through TCC. Stage 0 of the vcam stack — makes apps stop
   bailing on the auth check; downstream pipeline still needs Stages 1+2 to
   actually deliver frames.
"""

import os
import re
import shutil
import subprocess

try:
    from .cfw_asm import asm
    from .cfw_dsc_chunks import DSCChunks
    from .cfw_dsc_codesign import reattest_modified_pages
except ImportError:
    from cfw_asm import asm
    from cfw_dsc_chunks import DSCChunks
    from cfw_dsc_codesign import reattest_modified_pages


NU_STYLE_TRANSFER_SYMBOLS = [
    "+[_NUStyleTransferProcessor processWithInputs:arguments:output:error:]",
    "+[_NUStyleTransferThumbnailProcessor processWithInputs:arguments:output:error:]",
    "+[_NUStyleTransferApplyProcessor processWithInputs:arguments:output:error:]",
    "+[_NUStyleTransferLearnProcessor processWithInputs:arguments:output:error:]",
    "+[_NUStyleTransferInterpolateProcessor processWithInputs:arguments:output:error:]",
]

AVF_AUTH_STATUS_SYMBOL = (
    "+[AVCaptureDevice authorizationStatusForMediaType:]"
)


def _resolve_symbols_in_image(dsc_path, image_path, wanted_symbols):
    """Resolve a set of ObjC method symbols in `image_path` against `dsc_path`
    via `ipsw dyld symaddr`. Returns {symbol: vmaddr}. Raises if any are missing.
    """
    ipsw_bin = shutil.which("ipsw")
    if not ipsw_bin:
        raise RuntimeError("`ipsw` not in PATH")
    cmd = [
        ipsw_bin, "dyld", "symaddr", dsc_path,
        "--image", image_path,
    ]
    out = subprocess.run(cmd, capture_output=True, text=True, check=True).stdout
    wanted = set(wanted_symbols)
    results = {}
    for line in out.splitlines():
        line = re.sub(r"\x1b\[[0-9;]*m", "", line).rstrip()
        m = re.match(r"\s*(0x[0-9A-Fa-f]+):\s*\([^)]+\)\s*(.+)$", line)
        if not m:
            continue
        addr, rest = m.group(1), m.group(2)
        sym = rest.rsplit("\t", 1)[0].strip() if "\t" in rest else rest.strip()
        if sym in wanted:
            results[sym] = int(addr, 16)
    missing = [s for s in wanted_symbols if s not in results]
    if missing:
        raise RuntimeError(
            f"could not resolve symbols in {image_path}: {missing}"
        )
    return results


def resolve_nu_symbols(dsc_path):
    """Resolve the five NeutrinoCore symbols."""
    return _resolve_symbols_in_image(
        dsc_path,
        "/System/Library/PrivateFrameworks/NeutrinoCore.framework/NeutrinoCore",
        NU_STYLE_TRANSFER_SYMBOLS,
    )


def resolve_avf_auth_symbol(dsc_path):
    """Resolve +[AVCaptureDevice authorizationStatusForMediaType:] in AVFCapture."""
    return _resolve_symbols_in_image(
        dsc_path,
        "/System/Library/PrivateFrameworks/AVFCapture.framework/AVFCapture",
        [AVF_AUTH_STATUS_SYMBOL],
    )


def patch_nu_styletransfer_short_circuit(chunks, vmas, *, dry_run=False, force=False):
    """Replace each `+[_NUStyleTransfer*Processor processWithInputs:...]` with
    `mov w0, #0; ret`. Camera's style-thumbnail pipeline then short-circuits
    before reaching `_NUStyleEngineMemoryResource init:`, which would otherwise
    assert on a nil descriptor and SIGABRT on first viewfinder render.
    """
    new_bytes = asm("mov w0, #0\nret")
    if len(new_bytes) != 8:
        raise RuntimeError(f"expected 8 bytes, got {len(new_bytes)}")

    patched = []
    for sym, vma in sorted(vmas.items()):
        orig = chunks.bytes_at_vma(vma, 8)
        print(f"  {sym}  @ 0x{vma:X}")
        print(f"    {orig.hex()} → {new_bytes.hex()}")
        if orig[:4] != b"\x7f\x23\x03\xd5" and not force:
            raise RuntimeError(
                f"{sym}: prologue not pacibsp (got {orig[:4].hex()}); use --force to override"
            )
        if not dry_run:
            chunks.write_at_vma(vma, new_bytes)
            patched.append(vma)

    if dry_run:
        print("  [DRY RUN]")
        return

    diags = reattest_modified_pages(chunks, patched, verbose=True)
    print(f"  re-attested {len(diags)} page(s)")
    for vma in patched:
        if chunks.bytes_at_vma(vma, 8) != new_bytes:
            raise RuntimeError(f"post-write verify failed at 0x{vma:X}")


def patch_avf_authorization_always_authorized(
    chunks, vmas, *, dry_run=False, force=False
):
    """Replace `+[AVCaptureDevice authorizationStatusForMediaType:]` with
    `mov w0, #3; ret`. Authorized = 3 across every media type — broader than
    just video, but the VM doesn't service audio capture either, so any app
    probing audio auth would have failed downstream regardless.
    """
    new_bytes = asm("mov w0, #3\nret")
    if len(new_bytes) != 8:
        raise RuntimeError(f"expected 8 bytes, got {len(new_bytes)}")

    patched = []
    for sym, vma in sorted(vmas.items()):
        orig = chunks.bytes_at_vma(vma, 8)
        print(f"  {sym}  @ 0x{vma:X}")
        print(f"    {orig.hex()} → {new_bytes.hex()}")
        if orig[:4] != b"\x7f\x23\x03\xd5" and not force:
            raise RuntimeError(
                f"{sym}: prologue not pacibsp (got {orig[:4].hex()}); use --force to override"
            )
        if not dry_run:
            chunks.write_at_vma(vma, new_bytes)
            patched.append(vma)

    if dry_run:
        print("  [DRY RUN]")
        return

    diags = reattest_modified_pages(chunks, patched, verbose=True)
    print(f"  re-attested {len(diags)} page(s)")
    for vma in patched:
        if chunks.bytes_at_vma(vma, 8) != new_bytes:
            raise RuntimeError(f"post-write verify failed at 0x{vma:X}")


def apply_all_camera_patches(chunks_dir, dsc_path, *, dry_run=False, force=False):
    """Apply every camera DSC patch against `chunks_dir`, resolving symbols
    against `dsc_path`."""
    chunks = DSCChunks(chunks_dir)
    print(f"  [.] DSC: {chunks!r}")

    print(f"  [.] resolving NeutrinoCore symbols against {dsc_path}...")
    nu_vmas = resolve_nu_symbols(dsc_path)
    print(f"  [.] resolving AVFCapture authorization symbol against {dsc_path}...")
    avf_vmas = resolve_avf_auth_symbol(dsc_path)

    print(f"\n  [1/2] +[_NUStyleTransfer*Processor processWithInputs:...] → return NO")
    patch_nu_styletransfer_short_circuit(chunks, nu_vmas, dry_run=dry_run, force=force)

    print(f"\n  [2/2] +[AVCaptureDevice authorizationStatusForMediaType:] → return Authorized")
    patch_avf_authorization_always_authorized(chunks, avf_vmas, dry_run=dry_run, force=force)

    print(f"\n  [+] camera DSC patches applied: 2/2")
    return 2


def apply_avf_auth_only(chunks_dir, dsc_path, *, dry_run=False, force=False):
    """Apply only the AVFCapture authorization gate patch. Useful when running
    on a chunk pulled from a device that already has the NU patches applied
    (composition mode in `vphone-dsc-chunk-ramdisk-deploy`)."""
    chunks = DSCChunks(chunks_dir)
    print(f"  [.] DSC: {chunks!r}")
    print(f"  [.] resolving AVFCapture authorization symbol against {dsc_path}...")
    avf_vmas = resolve_avf_auth_symbol(dsc_path)
    print(f"\n  [1/1] +[AVCaptureDevice authorizationStatusForMediaType:] → return Authorized")
    patch_avf_authorization_always_authorized(chunks, avf_vmas, dry_run=dry_run, force=force)
    print(f"\n  [+] AVF-only camera DSC patch applied: 1/1")
    return 1


def patch_camera_in_dsc(chunks_dir, dsc_path=None):
    """Entry point used by `cfw.py patch-camera-dsc`."""
    if not dsc_path:
        raise RuntimeError("dsc_path is required (pass --dsc-header on the CLI)")
    return apply_all_camera_patches(chunks_dir, dsc_path)


if __name__ == "__main__":
    import argparse
    ap = argparse.ArgumentParser(description="Camera DSC patcher")
    ap.add_argument("chunks_dir", help="directory containing dyld_shared_cache_arm64e.* files")
    ap.add_argument("dsc_header", help="path to the dyld_shared_cache_arm64e header (no suffix)")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--force", action="store_true")
    ap.add_argument("--avf-only", action="store_true",
                    help="Apply only the AVFCapture authorization gate patch (composition mode)")
    args = ap.parse_args()
    if args.avf_only:
        apply_avf_auth_only(args.chunks_dir, args.dsc_header,
                            dry_run=args.dry_run, force=args.force)
    else:
        apply_all_camera_patches(args.chunks_dir, args.dsc_header,
                                 dry_run=args.dry_run, force=args.force)

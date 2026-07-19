#!/usr/bin/env python3
"""
cfw.py — Dynamic binary patching for CFW installation on vphone600.

Uses capstone for disassembly-based anchoring and keystone for instruction
assembly, producing reliable, upgrade-proof patches.

Called by cfw_install.sh during CFW installation.

Commands:
    cryptex-paths <BuildManifest.plist>
        Print SystemOS and AppOS DMG paths from BuildManifest.

    patch-seputil <binary>
        Patch seputil gigalocker UUID to "AA".

    patch-launchd-cache-loader <binary>
        NOP the cache validation check in launchd_cache_loader.

    patch-mobileactivationd <binary>
        Patch -[DeviceType should_hactivate] to always return true.

    patch-launchd-jetsam <binary>
        Patch launchd jetsam panic guard to avoid initproc crash loop.

    patch-hv-vmm-dsc <chunks_dir> [--dry-run]
        Same patch, applied in place to the DSC chunks under
        <chunks_dir> (e.g. /System/Library/Caches/com.apple.dyld inside
        the mounted SystemOS Cryptex). Targets a fixed list of identity,
        store, and consumer-service dylibs; skips compute/accel libs.

    patch-iomfb-swapend <chunks_dir> [--dry-run]
        Patch iOS 26.0 and 26.0.1 IOMobileFramebuffer's _kern_SwapEnd external-method
        payload size from 0x548 to 0x560 for the PCC vphone600 userclient,
        then re-attest the modified DSC page hash.

    patch-iomfb-force-kern <chunks_dir> [--dry-run]
        iOS 27 VZ-view fix: retarget IOMobileFramebuffer's public
        _IOMobileFramebufferSwap* dispatch trampolines to their _kern_Swap*
        siblings, forcing present onto the userclient method-5 path the 26.4
        paravirt GPU scans out to the host (27 defaults to the _virt_* callback
        path the paravirt GPU never receives). Re-attests modified DSC pages.
        Pairs with the KernelJBPatchIomfbSwap kernel patches (accept 27's 0x6e0
        SwapEnd struct).

    patch-dsc-maxslide <chunks_dir> [--dry-run]
        Zero the dyld_cache_header maxSlide when the userland cache would overflow
        the vphone600 26.x kernel's 6 GiB shared region (cache span + maxSlide >
        0x180000000, e.g. iOS 27.0). Lets the cache map at slide 0 so launchd's dyld
        can map libSystem. Self-gating (no-op if it already fits); no re-attest needed
        (header field, not a cs_validate'd code page).

    patch-lsd-embedded-reg <chunks_dir> [--dry-run]
        Force lsd's -[_LSDModifyClient clientIsEntitledForEmbeddedRegistrationOperations]
        to always succeed (NOP its entitlement gate + re-attest the page), so app
        (re)registration works on iOS 27 without the three privileged entitlements it
        otherwise demands from the XPC peer. Unblocks vphoned/TrollStore/uicache app
        installs. Self-gating (no-op on pre-iOS-27 userlands where the method is absent).

    patch-camera-dsc <chunks_dir> <dsc_header> [--dry-run] [--force]
        Apply the 10-patch set to the DSC chunks that makes Camera.app
        launch-survivable on a vphone VM: synthesises a single
        `vphone-cam` AVCaptureDevice through `cameracaptured`'s
        device-list / discovery-session / serializer paths and stubs out
        the AVFoundation init-time validation that would otherwise crash
        on the synthetic device. <dsc_header> is the
        dyld_shared_cache_arm64e file (not a chunk) used for
        `ipsw dyld symaddr` symbol resolution.

    patch-watchdogd <binary> [--dry-run]
        Surgical 2-instruction patch of /usr/libexec/watchdogd's
        sysctlbyname("kern.hv_vmm_present", ...) caching block so the
        cached "am I a VM?" byte is forced to 1 regardless of the
        sysctl result. Necessary because the kernel-side OID rename
        makes that sysctl return ENOENT, which would otherwise drive
        watchdogd into a trap path that launchd's _PanicOnCrash
        escalates to a kernel panic. Also recomputes the affected
        CodeDirectory slot hash via cfw_macho_codesign.

    patch-diskimagesiod <binary>
        Force -[DIDiskArb isMountCompleteWithExpectedCount:diskTracker:] to return
        YES so MobileStorageMounter proceeds to mount the iOS-27 personalized DDI at
        /System/Developer (its waitForDAMount otherwise hangs forever on the 26.4
        vphone600 hybrid). Pairs with the DiskImages2 ABI + sandbox
        mac_policy_ops[124] JB kernel patches. No-op-in-effect on matched userlands.

    inject-daemons <launchd.plist> <daemon_dir>
        Inject bash/dropbear/trollvnc into launchd.plist.

    patch-dropbear-plist <dropbear.plist>
        Rewrite dropbear ProgramArguments to use /var/dropbear host keys.

    inject-dylib <binary> <dylib_path>
        Inject LC_LOAD_DYLIB into Mach-O binary (thin or universal).
        Equivalent to: optool install -c load -p <dylib_path> -t <binary>

Dependencies:
    pip install capstone keystone-engine
    ipsw CLI in $PATH (only required for patch-hv-vmm-dsc, experimental variant only)
"""

import os
import sys

# When run as `python3 scripts/patchers/cfw.py`, __name__ is "__main__" and
# relative imports fail. Add the parent directory to sys.path so we can import
# from the patchers package using absolute imports.
if __name__ == "__main__":
    sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    from patchers.cfw_patch_seputil import patch_seputil
    from patchers.cfw_patch_cache_loader import patch_launchd_cache_loader
    from patchers.cfw_patch_mobileactivationd import patch_mobileactivationd
    from patchers.cfw_patch_jetsam import patch_launchd_jetsam
    from patchers.cfw_patch_hv_vmm_dsc import patch_hv_vmm_in_dsc
    from patchers.cfw_patch_iomfb_swapend import patch_iomfb_swapend
    from patchers.cfw_patch_iomfb_force_kern import patch_iomfb_force_kern
    from patchers.cfw_patch_dsc_maxslide import patch_dsc_maxslide
    from patchers.cfw_patch_lsd_embedded_reg import patch_lsd_embedded_reg
    from patchers.cfw_patch_camera_dsc import apply_all_camera_patches
    from patchers.cfw_patch_watchdogd import patch_watchdogd
    from patchers.cfw_patch_diskimagesiod import patch_diskimagesiod
    from patchers.cfw_daemons import parse_cryptex_paths, inject_daemons, patch_dropbear_plist
else:
    from .cfw_patch_seputil import patch_seputil
    from .cfw_patch_cache_loader import patch_launchd_cache_loader
    from .cfw_patch_mobileactivationd import patch_mobileactivationd
    from .cfw_patch_jetsam import patch_launchd_jetsam
    from .cfw_patch_hv_vmm_dsc import patch_hv_vmm_in_dsc
    from .cfw_patch_iomfb_swapend import patch_iomfb_swapend
    from .cfw_patch_iomfb_force_kern import patch_iomfb_force_kern
    from .cfw_patch_dsc_maxslide import patch_dsc_maxslide
    from .cfw_patch_lsd_embedded_reg import patch_lsd_embedded_reg
    from .cfw_patch_camera_dsc import apply_all_camera_patches
    from .cfw_patch_watchdogd import patch_watchdogd
    from .cfw_patch_diskimagesiod import patch_diskimagesiod
    from .cfw_daemons import parse_cryptex_paths, inject_daemons, patch_dropbear_plist


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)

    cmd = sys.argv[1]

    if cmd == "cryptex-paths":
        if len(sys.argv) < 3:
            print("Usage: patch_cfw.py cryptex-paths <BuildManifest.plist>")
            sys.exit(1)
        sysos, appos = parse_cryptex_paths(sys.argv[2])
        print(sysos)
        print(appos)

    elif cmd == "patch-seputil":
        if len(sys.argv) < 3:
            print("Usage: patch_cfw.py patch-seputil <binary>")
            sys.exit(1)
        if not patch_seputil(sys.argv[2]):
            sys.exit(1)

    elif cmd == "patch-launchd-cache-loader":
        if len(sys.argv) < 3:
            print("Usage: patch_cfw.py patch-launchd-cache-loader <binary>")
            sys.exit(1)
        if not patch_launchd_cache_loader(sys.argv[2]):
            sys.exit(1)

    elif cmd == "patch-mobileactivationd":
        if len(sys.argv) < 3:
            print("Usage: patch_cfw.py patch-mobileactivationd <binary>")
            sys.exit(1)
        if not patch_mobileactivationd(sys.argv[2]):
            sys.exit(1)

    elif cmd == "patch-launchd-jetsam":
        if len(sys.argv) < 3:
            print("Usage: patch_cfw.py patch-launchd-jetsam <binary>")
            sys.exit(1)
        if not patch_launchd_jetsam(sys.argv[2]):
            sys.exit(1)

    elif cmd == "patch-hv-vmm-dsc":
        if len(sys.argv) < 3:
            print("Usage: patch_cfw.py patch-hv-vmm-dsc <chunks_dir> [--dry-run]")
            sys.exit(1)
        dry_run = "--dry-run" in sys.argv[3:]
        results = patch_hv_vmm_in_dsc(sys.argv[2], dry_run=dry_run)
        sys.exit(0)

    elif cmd == "patch-iomfb-swapend":
        if len(sys.argv) < 3:
            print("Usage: patch_cfw.py patch-iomfb-swapend <chunks_dir> "
                  "[--target-size <hex|int>] [--dry-run]")
            sys.exit(1)
        dry_run = "--dry-run" in sys.argv[3:]
        kwargs = {}
        if "--target-size" in sys.argv:
            i = sys.argv.index("--target-size")
            kwargs["target_size"] = int(sys.argv[i + 1], 0)
        try:
            patch_iomfb_swapend(sys.argv[2], dry_run=dry_run, **kwargs)
        except ValueError as e:
            print(f"[-] {e}")
            sys.exit(1)
        sys.exit(0)

    elif cmd == "patch-iomfb-force-kern":
        if len(sys.argv) < 3:
            print("Usage: patch_cfw.py patch-iomfb-force-kern <chunks_dir> [--dry-run]")
            sys.exit(1)
        dry_run = "--dry-run" in sys.argv[3:]
        try:
            patch_iomfb_force_kern(sys.argv[2], dry_run=dry_run)
        except ValueError as e:
            print(f"[-] {e}")
            sys.exit(1)
        sys.exit(0)

    elif cmd == "patch-dsc-maxslide":
        if len(sys.argv) < 3:
            print("Usage: patch_cfw.py patch-dsc-maxslide <chunks_dir> [--dry-run]")
            sys.exit(1)
        dry_run = "--dry-run" in sys.argv[3:]
        patch_dsc_maxslide(sys.argv[2], dry_run=dry_run)
        sys.exit(0)

    elif cmd == "patch-lsd-embedded-reg":
        if len(sys.argv) < 3:
            print("Usage: patch_cfw.py patch-lsd-embedded-reg <chunks_dir> [--dry-run]")
            sys.exit(1)
        dry_run = "--dry-run" in sys.argv[3:]
        patch_lsd_embedded_reg(sys.argv[2], dry_run=dry_run)
        sys.exit(0)

    elif cmd == "patch-camera-dsc":
        if len(sys.argv) < 4:
            print("Usage: patch_cfw.py patch-camera-dsc <chunks_dir> <dsc_header> [--dry-run] [--force]")
            sys.exit(1)
        dry_run = "--dry-run" in sys.argv[4:]
        force   = "--force"   in sys.argv[4:]
        apply_all_camera_patches(sys.argv[2], sys.argv[3], dry_run=dry_run, force=force)
        sys.exit(0)

    elif cmd == "patch-watchdogd":
        if len(sys.argv) < 3:
            print("Usage: patch_cfw.py patch-watchdogd <binary> [--dry-run]")
            sys.exit(1)
        dry_run = "--dry-run" in sys.argv[3:]
        try:
            n = patch_watchdogd(sys.argv[2], dry_run=dry_run)
        except ValueError as e:
            print(f"[-] {e}")
            sys.exit(1)
        # Exit 0 on both "patched N>0" and "already patched (N==0)".
        # The install script treats both as success; only a raised
        # exception (unparseable binary / no anchor) is fatal.
        sys.exit(0)

    elif cmd == "patch-diskimagesiod":
        if len(sys.argv) < 3:
            print("Usage: patch_cfw.py patch-diskimagesiod <binary>")
            sys.exit(1)
        if not patch_diskimagesiod(sys.argv[2]):
            sys.exit(1)

    elif cmd == "inject-daemons":
        if len(sys.argv) < 4:
            print("Usage: patch_cfw.py inject-daemons <launchd.plist> <daemon_dir>")
            sys.exit(1)
        inject_daemons(sys.argv[2], sys.argv[3])

    elif cmd == "patch-dropbear-plist":
        if len(sys.argv) < 3:
            print("Usage: patch_cfw.py patch-dropbear-plist <dropbear.plist>")
            sys.exit(1)
        patch_dropbear_plist(sys.argv[2])

    elif cmd == "inject-dylib":
        if len(sys.argv) < 4:
            print("Usage: patch_cfw.py inject-dylib <binary> <dylib_path>")
            sys.exit(1)
        import subprocess, shutil
        insert_dylib_bin = shutil.which("insert_dylib")
        if not insert_dylib_bin:
            # Check .tools/bin/ relative to project root
            project_root = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
            candidate = os.path.join(project_root, ".tools", "bin", "insert_dylib")
            if os.path.isfile(candidate) and os.access(candidate, os.X_OK):
                insert_dylib_bin = candidate
        if not insert_dylib_bin:
            print("[-] insert_dylib not found. Run: make setup_tools")
            sys.exit(1)
        rc = subprocess.run(
            [insert_dylib_bin, "--weak", "--inplace", "--all-yes", sys.argv[3], sys.argv[2]],
        ).returncode
        if rc != 0:
            sys.exit(rc)

    else:
        print(f"Unknown command: {cmd}")
        print("Commands: cryptex-paths, patch-seputil, patch-launchd-cache-loader, patch-camera-dsc,")
        print("          patch-mobileactivationd, patch-launchd-jetsam,")
        print("          patch-hv-vmm-dsc, patch-iomfb-swapend, patch-iomfb-force-kern, patch-dsc-maxslide, patch-lsd-embedded-reg, patch-watchdogd,")
        print("          patch-diskimagesiod, inject-daemons, patch-dropbear-plist, inject-dylib")
        sys.exit(1)


if __name__ == "__main__":
    main()

// FirmwareKernelBasePatchSet.swift — Manifest for the base kernel patches.
//
// What every research VM needs to mount a patched, unsealed root filesystem and
// run unsigned code from it. `KernelJailbreakPatcher` builds on this set, so the
// jailbreak set requires the capability declared here.
//
// The Mach port guard patch is the one entry with a version gate. It is required
// on an iOS 18 base, where runningboardd trips a flavor-10 guard and crash-loops
// the UI, and it is off elsewhere — where disabling the guard only hides
// violations a researcher may want to see.

import Foundation
import VPhonePatchKit

public enum FirmwareKernelBasePatchSet {
    public static let identifier = "com.vphone.patchset.kernel.base"

    public static let manifest = VPhonePatchSetManifest(
        identifier: identifier,
        name: "Kernel Base",
        summary: "APFS, code-signing policy and sandbox patches every research VM needs",
        patches: [
            // MARK: APFS

            VPhonePatchDeclaration(
                identifier: "kernel-boot-apfs_root_snapshot",
                title: "APFS root snapshot",
                summary: "Boots the live root volume instead of its sealed snapshot.",
                target: .firmware(.kernelcache),
                bootEssential: true,
            ),
            VPhonePatchDeclaration(
                identifier: "kernel-boot-apfs_seal_broken",
                title: "APFS broken seal",
                summary: "Accepts a root volume whose seal the patches broke.",
                target: .firmware(.kernelcache),
                bootEssential: true,
            ),
            VPhonePatchDeclaration(
                identifier: "kernel-boot-apfs_graft",
                title: "APFS graft",
                summary: "Allows grafting so the cryptex payload mounts.",
                target: .firmware(.kernelcache),
                bootEssential: true,
            ),
            VPhonePatchDeclaration(
                identifier: "kernel-boot-apfs_vfsop_mount",
                title: "APFS mount entry check",
                summary: "Drops the vfsop_mount refusal for an unsealed volume.",
                target: .firmware(.kernelcache),
                bootEssential: true,
            ),
            VPhonePatchDeclaration(
                identifier: "kernel-boot-apfs_mount_upgrade_checks",
                title: "APFS mount upgrade checks",
                summary: "Lets a read-only root be remounted writable.",
                target: .firmware(.kernelcache),
                bootEssential: true,
            ),
            VPhonePatchDeclaration(
                identifier: "kernel-boot-handle_fsioc_graft",
                title: "APFS graft ioctl",
                summary: "Lets the graft ioctl succeed from the guest.",
                target: .firmware(.kernelcache),
                bootEssential: true,
            ),
            VPhonePatchDeclaration(
                identifier: "kernel-boot-handle_get_dev_by_role",
                title: "APFS device-by-role gates",
                summary: "Resolves volume roles for the patched container layout.",
                target: .firmware(.kernelcache),
                bootEssential: true,
            ),

            // MARK: Startup

            VPhonePatchDeclaration(
                identifier: "kernel-boot-bsd_init_rootvp",
                title: "bsd_init root vnode",
                summary: "Keeps bsd_init going when the root vnode is the patched image.",
                target: .firmware(.kernelcache),
                bootEssential: true,
            ),

            // MARK: Code Signing

            VPhonePatchDeclaration(
                identifier: "kernel-boot-post_validation",
                title: "Post-validation checks",
                summary: "Accepts signatures the patched trust cache vouches for.",
                target: .firmware(.kernelcache),
                bootEssential: true,
            ),
            VPhonePatchDeclaration(
                identifier: "kernel-boot-launch_constraints",
                title: "Launch constraints",
                summary: "Stops launch constraints refusing a relocated system binary.",
                target: .firmware(.kernelcache),
                bootEssential: true,
            ),
            VPhonePatchDeclaration(
                identifier: "kernel-boot-dyld_policy",
                title: "dyld loading policy",
                summary: "Lets dyld load a library from outside the sealed image.",
                target: .firmware(.kernelcache),
                bootEssential: true,
            ),
            VPhonePatchDeclaration(
                identifier: "kernel-cfw-debugger",
                title: "Debugger check",
                summary: "Reports the kernel as debuggable so task_for_pid works.",
                target: .firmware(.kernelcache),
            ),

            // MARK: Sandbox MACF Hooks

            VPhonePatchDeclaration(
                identifier: "kernel-cfw-sandbox_file_check_mmap",
                title: "Sandbox: file_check_mmap",
                summary: "Stubs the mmap sandbox check to allow.",
                target: .firmware(.kernelcache),
            ),
            VPhonePatchDeclaration(
                identifier: "kernel-boot-sandbox_mount_check_mount",
                title: "Sandbox: mount_check_mount",
                summary: "Stubs the mount sandbox check to allow.",
                target: .firmware(.kernelcache),
                bootEssential: true,
            ),
            VPhonePatchDeclaration(
                identifier: "kernel-boot-sandbox_mount_check_remount",
                title: "Sandbox: mount_check_remount",
                summary: "Stubs the remount sandbox check to allow.",
                target: .firmware(.kernelcache),
                bootEssential: true,
            ),
            VPhonePatchDeclaration(
                identifier: "kernel-cfw-sandbox_mount_check_umount",
                title: "Sandbox: mount_check_umount",
                summary: "Stubs the umount sandbox check to allow.",
                target: .firmware(.kernelcache),
            ),
            VPhonePatchDeclaration(
                identifier: "kernel-cfw-sandbox_vnode_check_rename",
                title: "Sandbox: vnode_check_rename",
                summary: "Stubs the rename sandbox check to allow.",
                target: .firmware(.kernelcache),
            ),

            // MARK: Mach Port Guard

            VPhonePatchDeclaration(
                identifier: "kernel-boot-thread_guard_violation",
                title: "Mach port guard violation",
                summary: """
                Turns a fatal EXC_GUARD port violation into a continue. Required on an iOS 18 \
                base, whose runningboardd and SpringBoard trip a flavor-10 guard and crash-loop \
                the UI.
                """,
                target: .firmware(.kernelcache),
                applicability: VPhonePatchApplicability(iOSBase: .major(18)),
                bootEssential: true,
            ),
        ],
        provides: ["vphone.kernel.base"],
    )
}

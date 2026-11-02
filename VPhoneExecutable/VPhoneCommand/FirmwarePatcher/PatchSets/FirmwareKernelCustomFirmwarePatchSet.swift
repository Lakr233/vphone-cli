// FirmwareKernelCustomFirmwarePatchSet.swift — Manifest for the custom-firmware kernel patches.
//
// The patches that make the guest a usable phone rather than a research VM
// that merely boots: an admitted trust cache, a writable root, task ports, and the
// syscall surface `vphoned` and the package manager need.
//
// Version gates here are structural, not preference. The iOS-27 entries target a
// 27 userland — its DiskImages2 client ABI, its container-manager upcall, its
// IOMFB swap sizes — and applying them under a 26.x userland would patch the
// wrong shapes. They carry `iOSBase: .major(27)` so one preset covers every base.

import Foundation
import VPhonePatchKit

public enum FirmwareKernelCustomFirmwarePatchSet {
    public static let identifier = "com.vphone.patchset.kernel.cfw"

    public static let tvTPROPagers = "kernel-exp-tv_tpro_pagers"
    public static let cssc = "kernel-boot-cssc_emulation"

    /// Only applies to an iOS 27 userland.
    private static let ios27 = VPhonePatchApplicability(iOSBase: .major(27))

    public static let manifest = VPhonePatchSetManifest(
        identifier: identifier,
        name: "Kernel Custom Firmware",
        summary: "Trust cache admission, writable root, task ports and the guest's extra syscall surface",
        patches: [
            VPhonePatchDeclaration(
                identifier: tvTPROPagers,
                title: "TV TPRO pager compatibility",
                summary: "Defaults sprr_tpro_pagers to zero so plain-arm64 tvOS dyld can make DATA_CONST writable. Pair with the TV dyld TPRO patch.",
                target: .firmware(.kernelcache),
                applicability: VPhonePatchApplicability(iOSBase: .major(26), cloudOS: .release(major: 26, minor: 4)),
            ),
            // MARK: Trust Cache and Code Signing

            VPhonePatchDeclaration(
                identifier: "kernel-boot-amfi_trustcache",
                title: "AMFI trust cache",
                summary: "Admits the guest's own trust cache so unsigned binaries run.",
                target: .firmware(.kernelcache),
                bootEssential: true,
            ),
            VPhonePatchDeclaration(
                identifier: "kernel-boot-post_validation_unsigned",
                title: "Unsigned post-validation",
                summary: "Completes the base post-validation patch for unsigned pages.",
                target: .firmware(.kernelcache),
                bootEssential: true,
            ),
            VPhonePatchDeclaration(
                identifier: "kernel-boot-cred_label_update_execve",
                title: "Credential label on execve",
                summary: "Grants the platform label to every binary the guest executes.",
                target: .firmware(.kernelcache),
                bootEssential: true,
            ),
            VPhonePatchDeclaration(
                identifier: "kernel-boot-hook_cred_label",
                title: "Credential label hook",
                summary: "Retargets the MACF credential hook to the patched handler.",
                target: .firmware(.kernelcache),
                bootEssential: true,
            ),
            VPhonePatchDeclaration(
                identifier: "kernel-boot-amfi_execve",
                title: "AMFI execve kill",
                summary: "Stops AMFI killing a process whose signature it dislikes.",
                target: .firmware(.kernelcache),
                bootEssential: true,
            ),
            VPhonePatchDeclaration(
                identifier: "kernel-boot-load_dylinker",
                title: "Dynamic linker policy",
                summary: "Lets a binary name a dynamic linker outside the sealed image.",
                target: .firmware(.kernelcache),
                bootEssential: true,
            ),

            // MARK: Task and Process

            VPhonePatchDeclaration(
                identifier: "kernel-boot-task_conversion_eval",
                title: "Task conversion evaluation",
                summary: "Allows converting a task port the caller would not normally get.",
                target: .firmware(.kernelcache),
                bootEssential: true,
            ),
            VPhonePatchDeclaration(
                identifier: "kernel-cfw-task_for_pid",
                title: "task_for_pid",
                summary: "Lets task_for_pid return a port for any process.",
                target: .firmware(.kernelcache),
            ),
            VPhonePatchDeclaration(
                identifier: "kernel-boot-port_to_map",
                title: "Port to map conversion",
                summary: "Skips the panic when a port is converted to a vm_map.",
                target: .firmware(.kernelcache),
                bootEssential: true,
            ),
            VPhonePatchDeclaration(
                identifier: "kernel-cfw-proc_pidinfo",
                title: "proc_pidinfo guards",
                summary: "Lets proc_pidinfo report on processes the caller does not own.",
                target: .firmware(.kernelcache),
            ),
            VPhonePatchDeclaration(
                identifier: "kernel-boot-proc_security_policy",
                title: "Process security policy",
                summary: "Stubs the per-process security policy check to allow.",
                target: .firmware(.kernelcache),
                bootEssential: true,
            ),
            VPhonePatchDeclaration(
                identifier: "kernel-boot-spawn_validate_persona",
                title: "Spawn persona validation",
                summary: "Lets a process spawn under a persona it did not inherit.",
                target: .firmware(.kernelcache),
                bootEssential: true,
            ),
            VPhonePatchDeclaration(
                identifier: "kernel-boot-thid_should_crash",
                title: "Thread identity crash",
                summary: "Stops a thread-identity mismatch killing the process.",
                target: .firmware(.kernelcache),
                bootEssential: true,
            ),

            // MARK: Memory

            VPhonePatchDeclaration(
                identifier: "kernel-boot-vm_map_protect",
                title: "vm_map_protect",
                summary: "Allows making an executable mapping writable.",
                target: .firmware(.kernelcache),
                bootEssential: true,
            ),
            VPhonePatchDeclaration(
                identifier: "kernel-boot-vm_fault_enter_prepare",
                title: "vm_fault_enter_prepare",
                summary: "Lets a fault install an unsigned executable page.",
                target: .firmware(.kernelcache),
                bootEssential: true,
            ),
            VPhonePatchDeclaration(
                identifier: "kernel-boot-shared_region_map",
                title: "Shared region mapping",
                summary: "Lets the patched dyld shared cache be mapped.",
                target: .firmware(.kernelcache),
                bootEssential: true,
            ),
            VPhonePatchDeclaration(
                identifier: "kernel-boot-shared_region_size",
                title: "Shared region size",
                summary: "Widens the arm64 shared region from 6 GiB to 7 GiB so an iOS 27 cache spans it.",
                target: .firmware(.kernelcache),
                applicability: ios27,
                bootEssential: true,
            ),

            // MARK: Filesystem

            VPhonePatchDeclaration(
                identifier: "kernel-boot-bsd_init_auth",
                title: "bsd_init imageboot gate",
                summary: "Skips the imageboot authentication branch during startup.",
                target: .firmware(.kernelcache),
                bootEssential: true,
            ),
            VPhonePatchDeclaration(
                identifier: "kernel-boot-io_secure_bsd_root",
                title: "Secure BSD root",
                summary: "Reports the root device as not security-locked.",
                target: .firmware(.kernelcache),
                bootEssential: true,
            ),
            VPhonePatchDeclaration(
                identifier: "kernel-boot-mac_mount",
                title: "MACF mount flags",
                summary: "Lets the guest mount writable over a sealed path.",
                target: .firmware(.kernelcache),
                bootEssential: true,
            ),
            VPhonePatchDeclaration(
                identifier: "kernel-boot-dounmount",
                title: "dounmount cleanup",
                summary: "Skips the unmount cleanup call that would undo the bind mounts.",
                target: .firmware(.kernelcache),
                bootEssential: true,
            ),
            VPhonePatchDeclaration(
                identifier: "kernel-cfw-nvram_verify_permission",
                title: "NVRAM permission check",
                summary: "Lets the guest write the NVRAM variables the bootstrap reads.",
                target: .firmware(.kernelcache),
            ),

            // MARK: Sandbox and IOUserClient

            VPhonePatchDeclaration(
                identifier: "kernel-boot-sandbox_ext",
                title: "Extended sandbox hooks",
                summary: "Retargets the remaining vnode and mount sandbox hooks to an allow stub.",
                target: .firmware(.kernelcache),
                bootEssential: true,
            ),
            VPhonePatchDeclaration(
                identifier: "kernel-boot-iouc_macf_gate",
                title: "IOUserClient MACF gate",
                summary: "Lets the guest open user clients MACF would refuse.",
                target: .firmware(.kernelcache),
                bootEssential: true,
            ),
            VPhonePatchDeclaration(
                identifier: "kernel-boot-iouc_sandbox_gate",
                title: "IOUserClient sandbox gate",
                summary: "Lets a sandboxed process open a user client, as a 27 userland expects.",
                target: .firmware(.kernelcache),
                applicability: ios27,
                bootEssential: true,
            ),

            // MARK: Syscall Surface

            VPhonePatchDeclaration(
                identifier: "kernel-boot-kcall10",
                title: "Kernel call syscall",
                summary: "Installs the syscall the guest tooling uses to call into the kernel.",
                target: .firmware(.kernelcache),
                bootEssential: true,
            ),
            VPhonePatchDeclaration(
                identifier: "kernel-boot-syscallmask",
                title: "Per-process syscall mask",
                summary: "Widens the syscall mask a process inherits.",
                target: .firmware(.kernelcache),
                bootEssential: true,
            ),

            // MARK: iOS 27 Userland

            VPhonePatchDeclaration(
                identifier: cssc,
                title: "CSSC instruction compatibility",
                summary: "Emulates scalar CSSC instructions in user-mode exception handling, including before launchd starts, on hosts without native CSSC.",
                target: .firmware(.kernelcache),
                applicability: VPhonePatchApplicability(iOSBase: .major(27), cloudOS: .release(major: 26, minor: 4)),
                bootEssential: true,
            ),

            VPhonePatchDeclaration(
                identifier: "kernel-boot-arm64e_x1",
                title: "ARM64E_X1 admission",
                summary: "Admits subtype-12 binaries, enables exec PAC and selects the ARM64E authenticated shared region required by the iOS 27 userland.",
                target: .firmware(.kernelcache),
                applicability: ios27,
                bootEssential: true,
            ),

            VPhonePatchDeclaration(
                identifier: "kernel-boot-di2",
                title: "DiskImages2 client ABI",
                summary: "Matches the DiskImages2 client ABI a 27 userland calls with.",
                target: .firmware(.kernelcache),
                applicability: ios27,
                bootEssential: true,
            ),
            VPhonePatchDeclaration(
                identifier: "kernel-boot-exec_security_policy_kill",
                title: "Exec security policy kill",
                summary: "Stops the 27 exec security policy killing the process.",
                target: .firmware(.kernelcache),
                applicability: ios27,
                bootEssential: true,
            ),
            VPhonePatchDeclaration(
                identifier: "kernel-boot-container_manager_upcall_force_success",
                title: "Container manager upcall",
                summary: "Forces the container-manager upcall to succeed.",
                target: .firmware(.kernelcache),
                applicability: ios27,
                bootEssential: true,
            ),
            VPhonePatchDeclaration(
                identifier: "kernel-boot-iomfb_swapend",
                title: "IOMFB swap-end sizes",
                summary: "Accepts the 27 display driver's swap-end structure sizes.",
                target: .firmware(.kernelcache),
                applicability: ios27,
                bootEssential: true,
            ),
            VPhonePatchDeclaration(
                identifier: "kernel-boot-fpfs_scoped_open",
                title: "FileProvider scoped open",
                summary: "Scopes the vnode-open check to FileProvider so respring does not loop.",
                target: .firmware(.kernelcache),
                applicability: ios27,
                bootEssential: true,
            ),
            VPhonePatchDeclaration(
                identifier: "kernel-cfw-aks_unlock_bag",
                title: "Keybag unlock arguments",
                summary: "Accepts the five-argument keybag unlock an iOS 26.6-or-newer userland sends, so escrow unlock and encrypted backups work on the 26.4 kernel.",
                target: .firmware(.kernelcache),
                // iOS 26.6 is where Apple's keybag-unlock external method began
                // sending inputScalarCount == 5 (26.5 and earlier send 4); the
                // anchor self-guards on a kernel that already accepts 5, so no
                // cloudOS bound is needed.
                applicability: VPhonePatchApplicability(iOSBase: .atLeast(major: 26, minor: 6)),
            ),

            VPhonePatchDeclaration(
                identifier: FirmwarePatchSetCatalog.paravirtUserClientsPatch,
                title: "Paravirtual device access",
                summary: """
                Lets a process outside an app sandbox open the paravirtual GPU, video decoder, \
                Neural Engine and IOSurface scaler, so daemons and command-line tools get Metal \
                and WebKit decodes video in hardware. Allows only those four device classes by \
                name; every other sandbox denial stays. Without it cameracaptured cannot \
                prewarm its shaders and crash-loops at every boot.
                """,
                target: .firmware(.kernelcache),
                applicability: VPhonePatchApplicability(iOSBase: .oneOf([.major(26), .major(18), .major(17)])),
            ),

            // MARK: Display

            VPhonePatchDeclaration(
                identifier: FirmwarePatchSetCatalog.proMotionPatch,
                title: "ProMotion",
                summary: """
                Makes the paravirtual display advertise 120 Hz, as a ProMotion panel does, \
                instead of the host's fixed 60 Hz mode. While it animates the guest renders \
                twice as often, so the host spends up to twice the CPU and GPU on it; turn it \
                off to keep 60 Hz.
                """,
                target: .firmware(.kernelcache),
            ),

            // MARK: Paravirtual GPU

            VPhonePatchDeclaration(
                identifier: FirmwarePatchSetCatalog.paravirtTask3Patch,
                title: "GPU Task3 shader cache",
                summary: """
                The guest GPU driver asks the host for binary version 252 \
                (Task3) while keeping its own features, and writes the owning \
                executable's code-signing hash into each task root. The host \
                retains a separate shader cache for each executable across boots.
                """,
                target: .firmware(.kernelcache),
                // The task initializer and owning-task anchors differ on the
                // cloudOS 26.1–26.3 kernels; discovery fails there.
                applicability: VPhonePatchApplicability(cloudOS: .release(major: 26, minor: 4)),
            ),
        ],
        requires: ["vphone.kernel.base"],
        provides: ["vphone.kernel.cfw"],
        after: ["vphone.kernel.base"],
    )
}

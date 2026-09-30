// FirmwareKernelJailbreakPatchSet.swift — Manifest for the jailbreak kernel patches.
//
// The patches that make the guest a jailbroken phone rather than a research VM
// that boots: an admitted trust cache, a writable root, task ports, and the
// syscall surface `vphoned` and the package manager need.
//
// Version gates here are structural, not preference. The iOS-27 entries target a
// 27 userland — its DiskImages2 client ABI, its container-manager upcall, its
// IOMFB swap sizes — and applying them under a 26.x userland would patch the
// wrong shapes. They carry `iOSBase: .major(27)` so one preset covers every base.

import Foundation
import VPhonePatchKit

public enum FirmwareKernelJailbreakPatchSet {
    public static let identifier = "com.vphone.patchset.kernel.jailbreak"

    /// Only applies to an iOS 27 userland.
    private static let ios27 = VPhonePatchApplicability(iOSBase: .major(27))

    public static let manifest = VPhonePatchSetManifest(
        identifier: identifier,
        name: "Kernel Jailbreak",
        summary: "Trust cache admission, writable root, task ports and the jailbreak syscall surface",
        patches: [
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
                title: "Jailbreak post-validation",
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
                summary: "Lets the guest write the NVRAM variables the jailbreak reads.",
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
                summary: "Installs the syscall the jailbreak uses to call into the kernel.",
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
        ],
        requires: ["vphone.kernel.base"],
        provides: ["vphone.kernel.jailbreak"],
        after: ["vphone.kernel.base"],
    )
}

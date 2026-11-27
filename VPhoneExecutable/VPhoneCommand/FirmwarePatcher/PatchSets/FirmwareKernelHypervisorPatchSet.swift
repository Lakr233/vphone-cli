// FirmwareKernelHypervisorPatchSet.swift — Manifest for the hv_vmm rename.
//
// The guest runs under a hypervisor and the research kernel says so through an
// `hv_vmm_present` sysctl. Renaming the OID and mangling its internal caller hides
// that from userland checks that would otherwise refuse to run.
//
// **Off in `standard`, and it is not a preference.** On a freshly restored 26.4
// guest the rename bricks the boot: `bluetoothd` caches its
// `sysctlbyname("kern.hv_vmm_present")` answer in a `dispatch_once`, gets ENOENT,
// caches 0, and picks its Bluetooth transport from `MGIsDeviceOneOfType` instead —
// nothing matches, its transport singleton stays NULL, and it faults and
// crash-loops until launchd throttles `com.apple.bluetoothd`. `locationd` then
// blocks on a synchronous call to the throttled Bluetooth XPC service, the
// `com.apple.locationd.migrator` data-migrator plugin hangs for over an hour, and
// SpringBoard waits on migration — black screen, no panic. `--preset extended` or a
// per-VM checkmark turns it back on, together with `dyld-exp-hv_vmm` and
// `system-watchdogd-exp-hv_vmm_cache`.
//
// Its own set because it is the one kernel change that is about hiding the
// hypervisor rather than about running custom firmware, so a preset can take it or leave it
// without giving up the rest.

import Foundation
import VPhonePatchKit

public enum FirmwareKernelHypervisorPatchSet {
    public static let identifier = "com.vphone.patchset.kernel.hypervisor"

    public static let manifest = VPhonePatchSetManifest(
        identifier: identifier,
        name: "Hypervisor Concealment",
        summary: "Renames the hv_vmm_present sysctl so userland does not see the hypervisor",
        patches: [
            VPhonePatchDeclaration(
                identifier: "kernel-exp-hv_vmm",
                title: "hv_vmm_present sysctl",
                summary: """
                Renames the hv_vmm_present OID, mangles its internal callers, and makes the \
                handler answer ENOENT to any process that asks (the rename alone is not \
                concealment: sysctl.next walks the MIB for everyone). Kernel callers still \
                read the truth; bluetoothd and watchdogd are userland and need their \
                cache patches just as they did for the rename. Off by default: the rename leaves a freshly restored 26.4 \
                guest on a black screen. Enable it together with dyld-exp-hv_vmm and \
                system-watchdogd-exp-hv_vmm_cache, never alone.
                """,
                target: .firmware(.kernelcache),
            ),
            VPhonePatchDeclaration(
                identifier: "kernel-exp-bootargs",
                title: "Empty kern.bootargs",
                summary: """
                Makes the kern.bootargs sysctl answer an empty string, as a stock iPhone does, \
                instead of the vphone command line. The kernel keeps the arguments for its \
                serial console. Shape-checked against the 27.2 / iPhone17,3 kernelcache; on \
                another build it is not applied.
                """,
                target: .firmware(.kernelcache),
            ),
            VPhonePatchDeclaration(
                identifier: "kernel-exp-cpu_topology",
                title: "Phone CPU topology",
                summary: """
                Makes hw.ncpu, hw.activecpu, hw.physicalcpu, hw.physicalcpu_max, hw.logicalcpu and \
                hw.logicalcpu_max answer 6, as every iPhone since the iPhone 8 does, instead of \
                the VM's vCPU count. The kernel's own scheduler and the Mach host_info trap keep \
                the real counts. Shape-checked against the 27.2 / iPhone17,3 kernelcache; on \
                another build it is not applied.
                """,
                target: .firmware(.kernelcache),
            ),
        ],
        requires: ["vphone.kernel.base"],
        provides: ["vphone.kernel.hypervisor"],
        after: ["vphone.kernel.cfw"],
    )
}

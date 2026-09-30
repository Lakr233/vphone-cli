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
// hypervisor rather than about jailbreaking, so a preset can take it or leave it
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
                Renames the hv_vmm_present OID and mangles its internal caller, so a userland \
                check for the hypervisor finds nothing. Off by default: it leaves a freshly \
                restored 26.4 guest on a black screen. Enable it together with dyld-exp-hv_vmm \
                and system-watchdogd-exp-hv_vmm_cache, never alone.
                """,
                target: .firmware(.kernelcache),
            ),
        ],
        requires: ["vphone.kernel.base"],
        provides: ["vphone.kernel.hypervisor"],
        after: ["vphone.kernel.jailbreak"],
    )
}

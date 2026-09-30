// FirmwareGuestIdentityPatchSet.swift — Manifest for what the guest sees of itself.
//
// The shared-cache half of the hypervisor concealment that the kernel set starts,
// the watchdogd patch that goes with it, the Preboot device tree identity rewrite,
// plus the camera symbols the virtual camera is published through. These pair with
// `com.vphone.patchset.kernel.hypervisor` and the device tree's identity and camera
// nodes: on their own, each half leaves the guest inconsistent with itself.
//
// Everything here came from the former EXP variant. Only `dyld-cfw-camera` is on in
// `standard`. `dyld-exp-hv_vmm` is off for exactly the reason its kernel half is — see
// `FirmwareKernelHypervisorPatchSet` for what a 26.4 guest does when the OID is
// renamed. The watchdogd patch only matters once the hypervisor is hidden, so it
// moves with that pair (`FirmwarePatchSetCatalog.hypervisorConcealmentPatches`).
// The Preboot rewrite belongs with the device tree identity patches
// (`FirmwarePatchSetCatalog.experimentalIdentityPatches`).

import Foundation
import VPhonePatchKit

public enum FirmwareGuestIdentityPatchSet {
    public static let identifier = "com.vphone.patchset.guest.identity"

    /// The root `model`, `target-type` and `compatible` rewrite in the restored
    /// Preboot device tree, run by `cfw install`.
    public static let prebootDeviceTreeIdentity = "preboot-exp-devicetree_identity"

    public static let manifest = VPhonePatchSetManifest(
        identifier: identifier,
        name: "Guest Identity",
        summary: "Hypervisor concealment in the shared cache and watchdog, the Preboot identity, and the virtual camera symbols",
        patches: [
            VPhonePatchDeclaration(
                identifier: "dyld-exp-hv_vmm",
                title: "Shared cache hypervisor strings",
                summary: """
                Mangles the hv_vmm_present references in the shared cache, so a userland check \
                finds nothing where the kernel set renamed the sysctl. Off by default, and \
                pointless without kernel-exp-hv_vmm: enable the two together or neither.
                """,
                target: .dyldSharedCache,
            ),
            VPhonePatchDeclaration(
                identifier: "system-watchdogd-exp-hv_vmm_cache",
                title: "watchdogd hypervisor cache",
                summary: """
                Forces watchdogd's cached hypervisor answer to true. Without it, watchdogd \
                panics the guest once kernel-exp-hv_vmm renames the sysctl, so it is \
                off by default with the concealment and must be enabled with it.
                """,
                target: .guestExecutable(path: "/usr/libexec/watchdogd"),
            ),
            VPhonePatchDeclaration(
                identifier: prebootDeviceTreeIdentity,
                title: "Preboot device tree identity",
                summary: """
                Rewrites the restored device tree's root model, target-type and compatible \
                entries to iPhone17,3 / D47. Off by default with the other identity rewrites.
                """,
                target: .prebootDeviceTree,
            ),
            VPhonePatchDeclaration(
                identifier: "dyld-cfw-camera",
                title: "Camera shared cache symbols",
                summary: "Redirects the camera symbols the virtual camera publishes frames through.",
                target: .dyldSharedCache,
            ),
        ],
        requires: ["vphone.guest.system"],
        provides: ["vphone.guest.identity"],
        after: ["vphone.guest.system"],
    )
}

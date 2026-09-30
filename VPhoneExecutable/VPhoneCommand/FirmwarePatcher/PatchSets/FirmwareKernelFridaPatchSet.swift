// FirmwareKernelFridaPatchSet.swift — Manifest for the Frida Stalker relaxations.
//
// Two kernel checks stand between Frida's Stalker and a working trace: the
// entitlement flag thread_set_state wants, and the immutability vm_map_delete
// enforces over code pages. Neither is needed to boot, and both widen what any
// process in the guest can do, so this set is opt-in — no preset that a VM gets
// by default includes it.
//
// Gated to cloudOS 26.4 and newer, where these shapes were verified.

import Foundation
import VPhonePatchKit

public enum FirmwareKernelFridaPatchSet {
    public static let identifier = "com.vphone.patchset.kernel.frida"

    private static let fridaCapable = VPhonePatchApplicability(cloudOS: .atLeast(major: 26, minor: 4))

    public static let manifest = VPhonePatchSetManifest(
        identifier: identifier,
        name: "Frida Stalker",
        summary: "Kernel relaxations Frida's Stalker needs to trace and rewrite code pages",
        patches: [
            VPhonePatchDeclaration(
                identifier: "kernel-exp-frida_thread_set_state_entitlement_flag",
                title: "thread_set_state entitlement",
                summary: "Drops the entitlement flag thread_set_state checks, so Stalker can set thread state.",
                target: .firmware(.kernelcache),
                applicability: fridaCapable,
            ),
            VPhonePatchDeclaration(
                identifier: "kernel-exp-frida_vm_map_delete_immutable_code",
                title: "Immutable code deletion",
                summary: "Lets vm_map_delete remove an immutable code mapping, which Stalker rewrites over.",
                target: .firmware(.kernelcache),
                applicability: fridaCapable,
            ),
        ],
        requires: ["vphone.kernel.jailbreak"],
        provides: ["vphone.kernel.frida"],
        after: ["vphone.kernel.jailbreak"],
    )
}

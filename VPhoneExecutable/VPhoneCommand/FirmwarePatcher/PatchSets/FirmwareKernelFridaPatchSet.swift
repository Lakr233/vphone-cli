// FirmwareKernelFridaPatchSet.swift — Manifest for the Frida Stalker relaxations.
//
// Two kernel checks stand between Frida's Stalker and a working trace: the
// entitlement flag thread_set_state wants, and the immutability vm_map_delete
// enforces over code pages. Two more stand between Frida and some targets: the
// TPRO state dyld asserts on entry, which aborts spawned apps, and the per-process
// syscall filters, which deny the agent inside filtered daemons. The last two are
// ported from mowisec/frida_patches_srd. None is needed to boot, and all widen
// what any process in the guest can do, so this set is opt-in — no preset that a
// VM gets by default includes it.
//
// Gated to cloudOS 26.4 and newer, where these shapes were verified. The
// thread_set_state flag and the syscall filters also have their shape on the
// iOS 18 research board kernels (cloudOS 18.x); TPRO and the immutable-code
// check do not exist there in this form.

import Foundation
import VPhonePatchKit

public enum FirmwareKernelFridaPatchSet {
    public static let identifier = "com.vphone.patchset.kernel.frida"

    private static let fridaCapable = VPhonePatchApplicability(cloudOS: .atLeast(major: 26, minor: 4))
    private static let fridaCapableWithIOS18 = VPhonePatchApplicability(
        cloudOS: .oneOf([.atLeast(major: 26, minor: 4), .major(18)]),
    )

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
                applicability: fridaCapableWithIOS18,
            ),
            VPhonePatchDeclaration(
                identifier: "kernel-exp-frida_vm_map_delete_immutable_code",
                title: "Immutable code deletion",
                summary: "Lets vm_map_delete remove an immutable code mapping, which Stalker rewrites over.",
                target: .firmware(.kernelcache),
                applicability: fridaCapable,
            ),
            VPhonePatchDeclaration(
                identifier: "kernel-exp-frida_tpro_off",
                title: "TPRO off",
                summary: "Turns TPRO off system-wide, so dyld's TPRO entry check cannot abort an app Frida spawns.",
                target: .firmware(.kernelcache),
                applicability: fridaCapable,
            ),
            VPhonePatchDeclaration(
                identifier: "kernel-exp-frida_syscall_filter_off",
                title: "Syscall filters off",
                summary: "Ignores per-process syscall filters, so Frida's agent survives inside filtered daemons such as trustd or backboardd.",
                target: .firmware(.kernelcache),
                // 26.1 for the iOS 16/17 experimental pairings, 26.4+ and iOS 18
                // for the Frida-capable standard presets; union of #802 and #808.
                applicability: VPhonePatchApplicability(cloudOS: .oneOf([
                    .release(major: 26, minor: 1), .atLeast(major: 26, minor: 4), .major(18),
                ])),
            ),
        ],
        requires: ["vphone.kernel.cfw"],
        provides: ["vphone.kernel.frida"],
        after: ["vphone.kernel.cfw"],
    )
}

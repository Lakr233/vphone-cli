// FirmwareGuestDisplayPatchSet.swift — Manifest for the guest display path.
//
// IOMFB talks to a framebuffer that does not exist on a research board. Which
// patch is needed depends on the userland: a 27 base routes the swap through the
// kernel, while 26.0 and 18.x only need the swap-end structure resized. The two
// are mutually exclusive by version, so one set covers both. The resize is for a
// 26.x kernel: an 18.x userland on its own release's research board kernel
// submits the structure that kernel expects, and the resized one fails
// (`swap_end returned error e00002c2`, a black screen).
//
// The paravirtual GPU reports no framebuffer compression, so a 27 iPad in
// landscape would scan out of a rotated framebuffer texture that loses
// shape-layer content (the pointer's arrow). The QuartzCore patch keeps the
// framebuffer panel-native, as on real devices.

import Foundation
import VPhonePatchKit

public enum FirmwareGuestDisplayPatchSet {
    public static let identifier = "com.vphone.patchset.guest.display"

    public static let manifest = VPhonePatchSetManifest(
        identifier: identifier,
        name: "Guest Display",
        summary: "IOMFB patches that let the guest present a frame on the virtual display, and keep its framebuffer panel-native",
        patches: [
            VPhonePatchDeclaration(
                identifier: "dyld-boot-iomfb_force_kern",
                title: "IOMFB force kernel swap",
                summary: "Routes the 27 display swap through the kernel, where the virtual framebuffer lives.",
                target: .dyldSharedCache,
                applicability: VPhonePatchApplicability(iOSBase: .major(27)),
                bootEssential: true,
            ),
            VPhonePatchDeclaration(
                identifier: quartzCoreUnrotatedFramebuffer,
                title: "Panel-native framebuffer in landscape",
                summary: "Keeps the render server's framebuffer in the panel's native orientation, as on devices with framebuffer compression. The paravirtual GPU drops shape-layer content from a rotated framebuffer, which hides the iPad pointer in landscape.",
                target: .dyldSharedCache,
                applicability: VPhonePatchApplicability(iOSBase: .major(27)),
            ),
            VPhonePatchDeclaration(
                identifier: "dyld-boot-iomfb_swapend",
                title: "IOMFB swap-end size",
                summary: "Resizes the swap-end structure a 26.0, 18.x or experimental 17.7 userland submits to a 26.x kernel.",
                target: .dyldSharedCache,
                applicability: VPhonePatchApplicability(
                    iOSBase: .oneOf([.release(major: 26, minor: 0), .major(18), .major(17), .major(16)]),
                    cloudOS: .atLeast(major: 26, minor: 0),
                ),
                bootEssential: true,
            ),
        ],
        requires: ["vphone.guest.system"],
        provides: ["vphone.guest.display"],
        after: ["vphone.guest.system"],
    )

    /// QuartzCore: no rotated framebuffer texture on a GPU without compression.
    public static let quartzCoreUnrotatedFramebuffer = "dyld-cfw-quartzcore_unrotated_framebuffer"

    /// The swap-end target size the verb is invoked with.
    public static let swapEndTargetSize = "0x560"
}

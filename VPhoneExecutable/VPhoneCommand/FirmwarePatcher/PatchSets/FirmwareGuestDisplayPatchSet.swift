// FirmwareGuestDisplayPatchSet.swift — Manifest for the guest display path.
//
// IOMFB talks to a framebuffer that does not exist on a research board. Which
// patch is needed depends on the userland: a 27 base routes the swap through the
// kernel, while 26.0 and 18.x only need the swap-end structure resized. The two
// are mutually exclusive by version, so one set covers both.

import Foundation
import VPhonePatchKit

public enum FirmwareGuestDisplayPatchSet {
    public static let identifier = "com.vphone.patchset.guest.display"

    public static let manifest = VPhonePatchSetManifest(
        identifier: identifier,
        name: "Guest Display",
        summary: "IOMFB patches that let the guest present a frame on the virtual display",
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
                identifier: "dyld-boot-iomfb_swapend",
                title: "IOMFB swap-end size",
                summary: "Resizes the swap-end structure a 26.0 or 18.x userland submits.",
                target: .dyldSharedCache,
                applicability: VPhonePatchApplicability(
                    iOSBase: .oneOf([.release(major: 26, minor: 0), .major(18)]),
                ),
                bootEssential: true,
            ),
        ],
        requires: ["vphone.guest.system"],
        provides: ["vphone.guest.display"],
        after: ["vphone.guest.system"],
    )

    /// The swap-end target size the verb is invoked with.
    public static let swapEndTargetSize = "0x560"
}

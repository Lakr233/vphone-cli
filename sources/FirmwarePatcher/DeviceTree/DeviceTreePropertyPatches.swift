// DeviceTreePropertyPatches.swift — DeviceTree property patch catalogue.
//
// The property rewrites `DeviceTreePatcher` applies: the base set every
// firmware variant receives, and the experimental identity-rewrite set
// gated behind `includeIdentityPatches` (the `.exp` variant only).
//
// Historical note: derived from the legacy Python firmware patcher during the Swift migration.

import Foundation

extension DeviceTreePatcher {
    /// Multi-string `compatible` blob used by patch #3 (root `compatible`).
    ///
    /// Original layout (48 bytes):
    ///   "VPHONE600AP\0" "iPhone99,11\0" "AppleVirtualPlatformARM\0"
    ///        11 + 1         11 + 1            23 + 1            = 48
    ///
    /// Patched layout (48 bytes, surgical change of the middle string only):
    ///   "VPHONE600AP\0" "iPhone17,3\0" "AppleVirtualPlatformARM\0\0"
    ///        11 + 1         10 + 1            23 + 2            = 48
    ///
    /// `VPHONE600AP` stays as the FIRST entry so IOKit's platform-expert
    /// matching at boot still binds against the kext that claims it. The
    /// SECOND entry, which userland walks of the compatible list see when
    /// iterating to enumerate alternate identifiers, is flipped to
    /// `iPhone17,3`. The trailing `AppleVirtualPlatformARM` shifts one byte
    /// earlier (now starts at byte 23 instead of 24), but every consumer of
    /// `compatible` walks by NUL-terminator — none depend on a fixed byte
    /// offset within the blob — so the shift is harmless.
    static let compatibleRewrite: Data = {
        var d = Data()
        d.append(contentsOf: Array("VPHONE600AP".utf8))
        d.append(0)
        d.append(contentsOf: Array("iPhone17,3".utf8))
        d.append(0)
        d.append(contentsOf: Array("AppleVirtualPlatformARM".utf8))
        d.append(0)
        // 11+1 + 10+1 + 23+1 = 47 bytes so far; pad with one NUL to 48.
        d.append(0)
        return d
    }()

    /// Base device-tree property patches, applied for every variant.
    /// Matches the pre-experimental set (serial-number, home-button-type,
    /// artwork-device-subtype, island-notch-location) inherited from
    /// scripts/dtree.py PATCHES.
    static let basePropertyPatches: [PropertyPatch] = [
        PropertyPatch(
            nodePath: ["device-tree"],
            property: "serial-number",
            length: 12,
            flags: 0,
            value: .string("vphone-1337"),
            patchID: "devicetree.serial_number",
            description: "Set serial number to vphone-1337",
        ),
        PropertyPatch(
            nodePath: ["device-tree", "buttons"],
            property: "home-button-type",
            length: 4,
            flags: 0,
            value: .integer(2),
            patchID: "devicetree.home_button_type",
            description: "Set home button type to 2",
        ),
        PropertyPatch(
            nodePath: ["device-tree", "product"],
            property: "artwork-device-subtype",
            length: 4,
            flags: 0,
            value: .integer(2556),
            patchID: "devicetree.artwork_device_subtype",
            description: "Set artwork device subtype to 2556",
        ),
        PropertyPatch(
            nodePath: ["device-tree", "product"],
            property: "island-notch-location",
            length: 4,
            flags: 0,
            value: .integer(144),
            patchID: "devicetree.island_notch_location",
            description: "Set island notch location to 144",
        ),
    ]

    /// Experimental identity-rewrite property patches. Applied only when
    /// `includeIdentityPatches` is true — currently set only by the `.exp`
    /// firmware variant. Other variants (regular, dev, jb, less) skip these.
    ///
    /// Risk categories:
    ///   - LOW   (#3 compatible[1], #11 sub-product-type, #12 unique-model):
    ///     read by userland identity APIs; not in the restore-signed path.
    ///   - HIGHER (#2 target-sub-type, #10 fdr-product-type):
    ///     same family as `target-type` (which broke restore in a prior
    ///     attempt) and FDR-related. If restore fails after a build that
    ///     enables these, remove just those two and retry.
    ///   - MEDIUM (#6 arm-io device_type, #7 arm-io soc-generation):
    ///     IOKit secondary matchers; the real iPhone17,3 DT carries these
    ///     exact values so they match the genuine D47AP.
    ///   - LOW-MEDIUM (#13 gestalt-variants rename): some MG-equivalent
    ///     code may look up the subtree by literal node name.
    /// Patches for root `model` and root `target-type` are deliberately
    /// NOT included here — both were tried, both broke restore. They are
    /// applied post-restore by EXP-JB-6 (`cfw_patch_post_restore_dt.py`)
    /// in the EXP install pipeline.
    static let identityPropertyPatches: [PropertyPatch] = [
        // ── Identity rewrite (Tier 1b) ────────────────────────────────
        // 5 properties from the 13-entry DT inventory chosen as
        // userland-facing identity surfaces. NONE of root `model` or root
        // `target-type` are included — both already proven to break restore.

        // #2 — root `target-sub-type` "VPHONE600AP" -> "D47AP".
        // RISK: HIGHER. Same family as `target-type`; if restore fails
        // after enabling this, remove this entry first.
        PropertyPatch(
            nodePath: ["device-tree"],
            property: "target-sub-type",
            length: 12,
            flags: 0,
            value: .string("D47AP"),
            patchID: "devicetree.target_sub_type",
            description: "Set target-sub-type to D47AP (was VPHONE600AP)",
        ),

        // #3 — root `compatible` surgical mangle. Keep VPHONE600AP as first
        // entry (platform-expert binding intact), rewrite iPhone99,11 (the
        // secondary entry) to iPhone17,3, keep AppleVirtualPlatformARM as
        // third entry. See `compatibleRewrite` above for byte layout.
        // RISK: LOW. Iterators of compatible[] read by userland will pick
        // up the new identity; the kernel's platform-expert bind still
        // matches the first entry, so boot is unaffected.
        PropertyPatch(
            nodePath: ["device-tree"],
            property: "compatible",
            length: 48,
            flags: 0,
            value: .bytes(compatibleRewrite),
            patchID: "devicetree.compatible_secondary",
            description: "Surgical rewrite of compatible[1]: iPhone99,11 -> iPhone17,3",
        ),

        // #10 — device-tree/product/fdr-product-type "iPhone99,11" -> "iPhone17,3".
        // RISK: HIGHER. FDR = Factory Data Restore; some restore-time code
        // reads this field. If restore breaks, remove this entry.
        PropertyPatch(
            nodePath: ["device-tree", "product"],
            property: "fdr-product-type",
            length: 12,
            flags: 0,
            value: .string("iPhone17,3"),
            patchID: "devicetree.product.fdr_product_type",
            description: "Set product/fdr-product-type to iPhone17,3 (was iPhone99,11)",
        ),

        // #11 — device-tree/product/sub-product-type "iPhone99,11" -> "iPhone17,3".
        // RISK: LOW. Read by userland classification code; not in
        // restore-signed path.
        PropertyPatch(
            nodePath: ["device-tree", "product"],
            property: "sub-product-type",
            length: 12,
            flags: 0,
            value: .string("iPhone17,3"),
            patchID: "devicetree.product.sub_product_type",
            description: "Set product/sub-product-type to iPhone17,3 (was iPhone99,11)",
        ),

        // #12 — device-tree/product/unique-model "VPHONE600AP" -> "D47AP".
        // RISK: LOW. Read by libMobileGestalt and "unique device class"
        // queries; not in restore-signed path.
        PropertyPatch(
            nodePath: ["device-tree", "product"],
            property: "unique-model",
            length: 12,
            flags: 0,
            value: .string("D47AP"),
            patchID: "devicetree.product.unique_model",
            description: "Set product/unique-model to D47AP (was VPHONE600AP)",
        ),

        // ── Identity rewrite (Tier 1c) ────────────────────────────────
        // Three more candidates from the inventory that haven't been
        // empirically shown to break restore. Each may still affect kernel
        // boot if a kext relies on the specific value.

        // #6 — device-tree/arm-io/device_type "vresearch1-io" -> "t8140-io".
        // RISK: MEDIUM. device_type is a secondary IOKit matcher; many
        // kexts only use compatible[] for binding, but some require both.
        // The actual d47ap DT carries "t8140-io" here, so this is the
        // genuine iPhone17,3 value (not a fabricated one).
        PropertyPatch(
            nodePath: ["device-tree", "arm-io"],
            property: "device_type",
            length: 14,
            flags: 0,
            value: .string("t8140-io"),
            patchID: "devicetree.arm_io.device_type",
            description: "Set arm-io/device_type to t8140-io (was vresearch1-io)",
        ),

        // #7 — device-tree/arm-io/soc-generation "VResearch1" -> "H17".
        // RISK: MEDIUM-LOW. soc-generation is typically a capability /
        // SoC-family descriptor read by kexts to select code paths.
        // d47ap (iPhone17,3) uses "H17" so we match that exactly.
        PropertyPatch(
            nodePath: ["device-tree", "arm-io"],
            property: "soc-generation",
            length: 11,
            flags: 0,
            value: .string("H17"),
            patchID: "devicetree.arm_io.soc_generation",
            description: "Set arm-io/soc-generation to H17 (was VResearch1)",
        ),

        // #13 — rename node device-tree/product/vphone600-gestalt-variants
        // to "d47-gestalt-variants" by rewriting its `name` property.
        // RISK: LOW-MEDIUM. Some libMobileGestalt-equivalent code may look
        // up the subtree by literal node name. d47 doesn't have a
        // `*-gestalt-variants` node at all (its product children are
        // camera/facetime/maps/haptics/audio), so iOS handles missing
        // gestalt-variants gracefully on real iPhone 17,3 devices anyway.
        // Renaming should be at-worst-equivalent to that "missing node"
        // path. The DTNode patcher walks by current name, so the nodePath
        // here uses the OLD name; the patch rewrites the `name` property
        // inside that node to the new value.
        PropertyPatch(
            nodePath: ["device-tree", "product", "vphone600-gestalt-variants"],
            property: "name",
            length: 27,
            flags: 0,
            value: .string("d47-gestalt-variants"),
            patchID: "devicetree.product.gestalt_variants_rename",
            description: "Rename node vphone600-gestalt-variants -> d47-gestalt-variants",
        ),

        // ── Camera physical-offset rewrites (Tier B) ──────────────────
        // vphone600 ships these as 12-byte `'syscfg/fcof'` / `'syscfg/rcof'`
        // cstring placeholders. d47ap carries 20-byte little-endian
        // blobs describing the physical mm offset from screen center
        // for each camera. Consumed by Camera.app / ARKit / FaceTime
        // for image-centering math. Replacing the placeholder with the
        // real d47ap blob (length 12 → 20) keeps the consuming code on
        // a real number rather than reading the literal `'syscfg/...'`
        // cstring as junk geometry.
        PropertyPatch(
            nodePath: ["device-tree", "product"],
            property: "front-cam-offset-from-center",
            length: 20,
            flags: 0,
            value: .bytes(Data([
                0x61, 0x00, 0x01, 0x00, 0x92, 0x1C, 0x00, 0x00,
                0xD8, 0x13, 0x00, 0x00, 0xE8, 0x03, 0x00, 0x00,
                0x00, 0x00, 0x00, 0x00,
            ])),
            patchID: "devicetree.product.front_cam_offset",
            description: "Set product/front-cam-offset-from-center to d47ap geometry (was syscfg/fcof)",
        ),
        PropertyPatch(
            nodePath: ["device-tree", "product"],
            property: "rear-cam-offset-from-center",
            length: 20,
            flags: 0,
            value: .bytes(Data([
                0xED, 0xA5, 0x00, 0x00, 0xB2, 0x56, 0x00, 0x00,
                0x59, 0x08, 0x00, 0x00, 0xE8, 0x03, 0x00, 0x00,
                0x00, 0x00, 0x00, 0x00,
            ])),
            patchID: "devicetree.product.rear_cam_offset",
            description: "Set product/rear-cam-offset-from-center to d47ap geometry (was syscfg/rcof)",
        ),
    ]
}

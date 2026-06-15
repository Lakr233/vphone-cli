// DeviceTreePatcher.swift — DeviceTree payload patcher.
//
// Historical note: derived from the legacy Python firmware patcher during the Swift migration.
//
// Strategy:
//   1. Parse the flat device tree binary into a node/property tree.
//   2. Apply a fixed set of property patches (serial-number, home-button-type,
//      artwork-device-subtype, island-notch-location).
//   3. Serialize the modified tree back to flat binary.

import Foundation

/// Patcher for DeviceTree payloads.
public final class DeviceTreePatcher: Patcher {
    public let component = "devicetree"
    public let verbose: Bool

    /// Whether to apply the 8 identity-rewrite property patches (Tier 1b + 1c)
    /// that flip device identity towards iPhone17,3 / D47AP. Enabled only for
    /// the `.exp` variant; all other variants run the base 4 patches only so
    /// they remain unaffected by the experimental identity rewrites.
    let includeIdentityPatches: Bool

    let buffer: BinaryBuffer
    var patches: [PatchRecord] = []
    var rebuiltData: Data?

    // MARK: - Patch Definitions

    /// A single property patch specification.
    struct PropertyPatch {
        let nodePath: [String]
        let property: String
        let length: Int
        let flags: UInt16
        let value: PropertyValue
        let patchID: String
        let description: String
    }

    /// A patch that adds a brand-new child node under an existing parent.
    /// Used when iPhone17,3 carries a node that vphone600 does not — e.g.
    /// `/device-tree/product/camera`, which `libMobileGestalt` requires to
    /// answer `MGGetBoolAnswer("still-camera")` truthfully.
    struct AddChildNodePatch {
        let parentPath: [String]
        let nodeName: String
        /// Properties to place inside the new node. The `name` property is
        /// added automatically from `nodeName`; do not include it here.
        let properties: [PropertySpec]
        let patchID: String
        let description: String

        struct PropertySpec {
            let name: String
            let length: Int
            let flags: UInt16
            let value: PropertyValue
        }
    }

    /// The value to write into a device tree property.
    enum PropertyValue {
        case string(String)
        case integer(UInt64)
        /// Raw bytes — used when the property holds a multi-string blob
        /// (NUL-delimited cstrings packed back-to-back, e.g. `compatible`)
        /// where Swift String escaping of embedded NULs is awkward.
        case bytes(Data)
    }

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
            description: "Set serial number to vphone-1337"
        ),
        PropertyPatch(
            nodePath: ["device-tree", "buttons"],
            property: "home-button-type",
            length: 4,
            flags: 0,
            value: .integer(2),
            patchID: "devicetree.home_button_type",
            description: "Set home button type to 2"
        ),
        PropertyPatch(
            nodePath: ["device-tree", "product"],
            property: "artwork-device-subtype",
            length: 4,
            flags: 0,
            value: .integer(2556),
            patchID: "devicetree.artwork_device_subtype",
            description: "Set artwork device subtype to 2556"
        ),
        PropertyPatch(
            nodePath: ["device-tree", "product"],
            property: "island-notch-location",
            length: 4,
            flags: 0,
            value: .integer(144),
            patchID: "devicetree.island_notch_location",
            description: "Set island notch location to 144"
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
            description: "Set target-sub-type to D47AP (was VPHONE600AP)"
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
            description: "Surgical rewrite of compatible[1]: iPhone99,11 -> iPhone17,3"
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
            description: "Set product/fdr-product-type to iPhone17,3 (was iPhone99,11)"
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
            description: "Set product/sub-product-type to iPhone17,3 (was iPhone99,11)"
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
            description: "Set product/unique-model to D47AP (was VPHONE600AP)"
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
            description: "Set arm-io/device_type to t8140-io (was vresearch1-io)"
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
            description: "Set arm-io/soc-generation to H17 (was VResearch1)"
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
            description: "Rename node vphone600-gestalt-variants -> d47-gestalt-variants"
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
                0x61, 0x00, 0x01, 0x00, 0x92, 0x1c, 0x00, 0x00,
                0xd8, 0x13, 0x00, 0x00, 0xe8, 0x03, 0x00, 0x00,
                0x00, 0x00, 0x00, 0x00,
            ])),
            patchID: "devicetree.product.front_cam_offset",
            description: "Set product/front-cam-offset-from-center to d47ap geometry (was syscfg/fcof)"
        ),
        PropertyPatch(
            nodePath: ["device-tree", "product"],
            property: "rear-cam-offset-from-center",
            length: 20,
            flags: 0,
            value: .bytes(Data([
                0xed, 0xa5, 0x00, 0x00, 0xb2, 0x56, 0x00, 0x00,
                0x59, 0x08, 0x00, 0x00, 0xe8, 0x03, 0x00, 0x00,
                0x00, 0x00, 0x00, 0x00,
            ])),
            patchID: "devicetree.product.rear_cam_offset",
            description: "Set product/rear-cam-offset-from-center to d47ap geometry (was syscfg/rcof)"
        ),
    ]

    /// Experimental child-node additions. Adds nodes that exist on real
    /// iPhone17,3 but not on vphone600 — so the userland answer surface
    /// matches the spoofed identity. Gated by `includeIdentityPatches`
    /// (EXP variant only).
    ///
    /// `/device-tree/product/camera` is required for
    /// `MGGetBoolAnswer("still-camera")` to return YES — without it,
    /// SpringBoard's SBAppTags filter hides `Camera.app`'s icon and
    /// blocks launch. The d47ap DT carries this node with 64 capability
    /// properties; the subset here is the minimum that backs the
    /// `cameraCapability` / `aggregateCameraCapability` /
    /// `autoFocusCameraCapability` getters in libMobileGestalt and the
    /// `still-camera` answer the SBAppTags consumer hits.
    static let experimentalNodeAdditions: [AddChildNodePatch] = [
        // Replicates the full `/product/camera` property set carried by the
        // iPhone17,3 D47AP DT (62 props in the reference build, all integers
        // or zero-length placeholders). The minimal 11-property version
        // wasn't enough — `PurpleBuddy` and other first-boot consumers
        // re-evaluate camera capability via `MGGetBoolAnswer` reading
        // additional DT properties (front-flash-capability,
        // live-photo-capture, rear-cam-superwide-capability, etc.) and
        // hide the Camera icon if any return nil/absent.
        //
        // Values copied byte-for-byte from
        // `ipsws/iPhone17,3_26.5_23F77_Restore_extracted/Firmware/all_flash/DeviceTree.d47ap.im4p`
        // post-LZFSE-decompression. Sorted alphabetically for diff stability.
        // The `"<"` / `"d"` / `"x"` values that ipsw dtree shows are 4-byte
        // little-endian ints whose first byte happens to print:
        //   "<" = 0x3C = 60   (60 fps cap)
        //   "d" = 0x64 = 100  (100-ms burst duration)
        //   "x" = 0x78 = 120  (120 fps slomo cap)
        // `<nil>` properties are 0-length placeholders (the name exists but
        // there's no value blob); MGGetBoolAnswer treats those as YES too.
        AddChildNodePatch(
            parentPath: ["device-tree", "product"],
            nodeName: "camera",
            properties: [
                .init(name: "aggregate-cam-photo-zoom", length: 4, flags: 0, value: .integer(0x7d0)),
                .init(name: "aggregate-cam-video-zoom", length: 4, flags: 0, value: .integer(0x4b0)),
                .init(name: "aggregate-camera", length: 4, flags: 0, value: .integer(1)),
                .init(name: "auto-focus", length: 4, flags: 0, value: .integer(1)),
                .init(name: "auto-low-light-video", length: 4, flags: 0, value: .integer(1)),
                .init(name: "camera-hdr-version", length: 4, flags: 0, value: .integer(3)),
                .init(name: "camera-ui-version", length: 4, flags: 0, value: .integer(2)),
                .init(name: "deferred-processing", length: 4, flags: 0, value: .integer(1)),
                .init(name: "flash", length: 4, flags: 0, value: .integer(1)),
                .init(name: "front-auto-focus", length: 4, flags: 0, value: .integer(1)),
                .init(name: "front-auto-hdr", length: 4, flags: 0, value: .integer(1)),
                .init(name: "front-burst", length: 4, flags: 0, value: .integer(1)),
                .init(name: "front-burst-image-duration", length: 4, flags: 0, value: .integer(100)),
                .init(name: "front-flash-capability", length: 4, flags: 0, value: .integer(1)),
                .init(name: "front-hdr", length: 4, flags: 0, value: .integer(1)),
                .init(name: "front-hdr-on", length: 4, flags: 0, value: .integer(1)),
                .init(name: "front-low-light-photo", length: 4, flags: 0, value: .integer(1)),
                .init(name: "front-max-burst-length", length: 4, flags: 0, value: .integer(600)),
                .init(name: "front-max-slomo-video-fps-1080p", length: 4, flags: 0, value: .integer(120)),
                .init(name: "front-max-slomo-video-fps-720p", length: 4, flags: 0, value: .integer(120)),
                .init(name: "front-max-video-fps-1080p", length: 4, flags: 0, value: .integer(60)),
                .init(name: "front-max-video-fps-4k", length: 4, flags: 0, value: .integer(60)),
                .init(name: "front-max-video-fps-720p", length: 4, flags: 0, value: .integer(60)),
                .init(name: "front-max-video-zoom", length: 4, flags: 0, value: .integer(1)),
                .init(name: "front-slowmo", length: 4, flags: 0, value: .integer(1)),
                .init(name: "front-stage-light-portrait", length: 0, flags: 0, value: .bytes(Data())),
                .init(name: "front-variable-frame-rate", length: 4, flags: 0, value: .integer(1)),
                .init(name: "live-effects", length: 4, flags: 0, value: .integer(1)),
                .init(name: "live-photo-auto", length: 4, flags: 0, value: .integer(1)),
                .init(name: "live-photo-capture", length: 4, flags: 0, value: .integer(1)),
                .init(name: "moment-capture", length: 4, flags: 0, value: .integer(1)),
                .init(name: "p3-color-space-video-recording", length: 4, flags: 0, value: .integer(1)),
                .init(name: "panorama", length: 4, flags: 0, value: .integer(1)),
                .init(name: "pearl-camera", length: 4, flags: 0, value: .integer(1)),
                .init(name: "photo-capture-on-touch-down", length: 4, flags: 0, value: .integer(1)),
                .init(name: "photos-live-video-rendering", length: 0, flags: 0, value: .bytes(Data())),
                .init(name: "pipelined-stillimage-capability", length: 4, flags: 0, value: .integer(1)),
                .init(name: "portrait-lighting-strength", length: 4, flags: 0, value: .integer(1)),
                .init(name: "post-effects", length: 4, flags: 0, value: .integer(1)),
                .init(name: "rear-auto-hdr", length: 4, flags: 0, value: .integer(1)),
                .init(name: "rear-burst", length: 4, flags: 0, value: .integer(1)),
                .init(name: "rear-burst-image-duration", length: 4, flags: 0, value: .integer(100)),
                .init(name: "rear-cam-sup-wide-af-capability", length: 4, flags: 0, value: .integer(1)),
                .init(name: "rear-cam-superwide-capability", length: 4, flags: 0, value: .integer(1)),
                .init(name: "rear-hdr", length: 4, flags: 0, value: .integer(1)),
                .init(name: "rear-hdr-on", length: 4, flags: 0, value: .integer(1)),
                .init(name: "rear-low-light-photo", length: 4, flags: 0, value: .integer(1)),
                .init(name: "rear-max-burst-length", length: 4, flags: 0, value: .integer(600)),
                .init(name: "rear-max-slomo-video-fps-1080p", length: 4, flags: 0, value: .integer(240)),
                .init(name: "rear-max-slomo-video-fps-720p", length: 4, flags: 0, value: .integer(240)),
                .init(name: "rear-max-video-fps-1080p", length: 4, flags: 0, value: .integer(60)),
                .init(name: "rear-max-video-fps-4k", length: 4, flags: 0, value: .integer(60)),
                .init(name: "rear-max-video-fps-720p", length: 4, flags: 0, value: .integer(60)),
                .init(name: "rear-max-video-frame_rate", length: 4, flags: 0, value: .integer(60)),
                .init(name: "rear-max-video-zoom", length: 4, flags: 0, value: .integer(3)),
                .init(name: "rear-slowmo", length: 4, flags: 0, value: .integer(1)),
                .init(name: "rear-stage-light-portrait", length: 0, flags: 0, value: .bytes(Data())),
                .init(name: "rear-variable-frame-rate", length: 4, flags: 0, value: .integer(1)),
                .init(name: "spatial-over-capture", length: 4, flags: 0, value: .integer(1)),
                .init(name: "stage-light-portrait-preview", length: 4, flags: 0, value: .integer(1)),
                .init(name: "video-cap", length: 4, flags: 0, value: .integer(2)),
                .init(name: "video-stills", length: 4, flags: 0, value: .integer(1)),
            ],
            patchID: "devicetree.product.camera_node",
            description: "Add /product/camera node with full iPhone17,3 D47AP property set (62 props)"
        ),

        // ── /product/facetime (Tier C — front-camera video-call config) ──
        // d47ap carries this 11-property node (excluding AAPL,phandle).
        // FaceTime reads bitrate-{2g,3g,lte,wifi}, decoding/encoding
        // codec parameters, pref-decoding, and tnr-mode-{back,front}
        // (temporal noise reduction) at app launch. Values byte-for-byte
        // from the d47ap DT.
        AddChildNodePatch(
            parentPath: ["device-tree", "product"],
            nodeName: "facetime",
            properties: [
                .init(name: "bitrate-2g", length: 4, flags: 0, value: .integer(100)),
                .init(name: "bitrate-3g", length: 4, flags: 0, value: .integer(228)),
                .init(name: "bitrate-lte", length: 4, flags: 0, value: .integer(228)),
                .init(name: "bitrate-wifi", length: 4, flags: 0, value: .integer(2000)),
                .init(name: "decoding", length: 48, flags: 0, value: .bytes(Data([
                    0x40, 0x01, 0x00, 0x00, 0x0f, 0x00, 0xf0, 0x00,
                    0x40, 0x01, 0x00, 0x00, 0x1e, 0x00, 0xf0, 0x00,
                    0xe0, 0x01, 0x00, 0x00, 0x0f, 0x00, 0x70, 0x01,
                    0xe0, 0x01, 0x00, 0x00, 0x1e, 0x00, 0x70, 0x01,
                    0x80, 0x02, 0x00, 0x00, 0x1e, 0x00, 0xe0, 0x01,
                    0x00, 0x04, 0x00, 0x00, 0x1e, 0x00, 0x00, 0x03,
                ]))),
                .init(name: "encoding", length: 56, flags: 0, value: .bytes(Data([
                    0x40, 0x01, 0x00, 0x00, 0x0f, 0x00, 0xf0, 0x00,
                    0x40, 0x01, 0x00, 0x00, 0x1e, 0x00, 0xf0, 0x00,
                    0xe0, 0x01, 0x00, 0x00, 0x0f, 0x00, 0x70, 0x01,
                    0xe0, 0x01, 0x00, 0x00, 0x1e, 0x00, 0x70, 0x01,
                    0x80, 0x02, 0x00, 0x00, 0x1e, 0x00, 0xe0, 0x01,
                    0x00, 0x04, 0x00, 0x00, 0x1e, 0x00, 0x00, 0x03,
                    0x00, 0x05, 0x00, 0x00, 0x1e, 0x00, 0xd0, 0x02,
                ]))),
                .init(name: "pref-decoding", length: 8, flags: 0, value: .integer(0x0300_001e_0000_0400)),
                .init(name: "tnr-mode-back", length: 4, flags: 0, value: .integer(10)),
                .init(name: "tnr-mode-front", length: 4, flags: 0, value: .integer(10)),
            ],
            patchID: "devicetree.product.facetime_node",
            description: "Add /product/facetime node with full iPhone17,3 D47AP property set (9 props)"
        ),

        // ── /product/audio (Tier C — audio + spatial-capture flags) ──
        // d47ap carries this 31-property node (excluding AAPL,phandle).
        // Two camera-joint flags live here: `supports-spatial-audio-capture`
        // and `supports-spatial-facetime` — needed for spatial-video and
        // spatial-photo capture pipelines that combine camera + audio.
        // The remaining 29 properties are pure audio config (mic gains,
        // speaker cpms, voice trigger, channel layout, codec use-case
        // formats). Calibration cstrings (`mic-trim-gains-*`,
        // `speaker-thiele-small-*`, `speaker-trim-gains-*`) keep their
        // syscfg-reference form — replacing them with concrete values
        // from d47 wouldn't make the VM's actual mic/speaker hardware
        // match, but downstream code already handles missing-syscfg
        // gracefully.
        AddChildNodePatch(
            parentPath: ["device-tree", "product"],
            nodeName: "audio",
            properties: [
                .init(name: "acoustic-id", length: 4, flags: 0, value: .integer(8018)),
                .init(name: "actuator-cpms-bgd_100ms", length: 8, flags: 0, value: .integer(0x0000_0eef_0000_01f4)),
                .init(name: "actuator-cpms-bgd_inst", length: 8, flags: 0, value: .integer(0x0000_1db0_0000_06d6)),
                .init(name: "enabledChannels", length: 4, flags: 0, value: .integer(15)),
                .init(name: "historyChannels", length: 4, flags: 0, value: .integer(15)),
                .init(name: "mic-trim-gains-0", length: 12, flags: 0, value: .string("syscfg/MiGH")),
                .init(name: "mic-trim-gains-2", length: 12, flags: 0, value: .string("syscfg/MiGB")),
                .init(name: "mic-trim-gains-key-cnt", length: 4, flags: 0, value: .integer(2)),
                .init(name: "speaker-cpms-bgd_100ms", length: 8, flags: 0, value: .integer(0x0000_2328_0000_04b0)),
                .init(name: "speaker-cpms-bgd_1s", length: 8, flags: 0, value: .integer(0x0000_2328_0000_04b0)),
                .init(name: "speaker-cpms-bgd_inst", length: 8, flags: 0, value: .integer(0x0000_2328_0000_04b0)),
                .init(name: "speaker-thiele-small-0", length: 12, flags: 0, value: .string("syscfg/SpPH")),
                .init(name: "speaker-thiele-small-key-cnt", length: 4, flags: 0, value: .integer(1)),
                .init(name: "speaker-trim-gains-0", length: 12, flags: 0, value: .string("syscfg/SpGH")),
                .init(name: "speaker-trim-gains-key-cnt", length: 4, flags: 0, value: .integer(1)),
                .init(name: "stereo-sound-recording", length: 4, flags: 0, value: .integer(1)),
                .init(name: "supportedChannels", length: 4, flags: 0, value: .integer(15)),
                .init(name: "supports-advanced-vp-chatflavor", length: 4, flags: 0, value: .integer(1)),
                .init(name: "supports-always-listening", length: 4, flags: 0, value: .integer(1)),
                .init(name: "supports-audio-mix", length: 4, flags: 0, value: .integer(1)),
                .init(name: "supports-auto-mic-mode", length: 4, flags: 0, value: .integer(1)),
                .init(name: "supports-barge-in", length: 4, flags: 0, value: .integer(1)),
                .init(name: "supports-concurrent-hp-lp-mics", length: 4, flags: 0, value: .integer(1)),
                .init(name: "supports-mic-modes-telephony", length: 4, flags: 0, value: .integer(1)),
                .init(name: "supports-spatial-audio-capture", length: 4, flags: 0, value: .integer(1)),
                .init(name: "supports-spatial-facetime", length: 4, flags: 0, value: .integer(1)),
                .init(name: "use-case-client-format", length: 96, flags: 0, value: .bytes(Data([
                    0x61, 0x64, 0x6e, 0x73, 0x80, 0xbb, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00,
                    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                    0x69, 0x72, 0x69, 0x73, 0x80, 0x3e, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00,
                    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                    0x73, 0x74, 0x70, 0x6c, 0x80, 0x3e, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00,
                    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                ]))),
                .init(name: "use-case-dsp-in-format", length: 160, flags: 0, value: .bytes(Data([
                    0x64, 0x6b, 0x74, 0x6d, 0x80, 0xbb, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00,
                    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                    0x61, 0x64, 0x6e, 0x73, 0x80, 0xbb, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00,
                    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                    0x64, 0x76, 0x70, 0x73, 0x80, 0xbb, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00,
                    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                    0x69, 0x72, 0x69, 0x73, 0x80, 0x3e, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00,
                    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                    0x73, 0x74, 0x70, 0x6c, 0x80, 0x3e, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00,
                    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                ]))),
                .init(name: "use-case-struct-version", length: 4, flags: 0, value: .integer(1)),
                .init(name: "voiceTriggerChannels", length: 4, flags: 0, value: .integer(1)),
                .init(name: "wireless-splitter", length: 4, flags: 0, value: .integer(1)),
            ],
            patchID: "devicetree.product.audio_node",
            description: "Add /product/audio node with full iPhone17,3 D47AP property set (31 props)"
        ),

        // ── /product/iopm (Tier C — always-on technology) ────────────
        // d47ap carries this 2-property node (excluding AAPL,phandle).
        // `aot-mode = 13` enables Always-On Technology — drives wake
        // policy and always-on-display behavior. POTENTIAL DISPLAY
        // RISK: if the VM display can't service the AOT init path,
        // this may need to be reverted in isolation. Test this batch
        // alongside facetime + audio + Tier B; if display breaks,
        // remove this AddChildNodePatch entry first before bisecting
        // the rest.
        AddChildNodePatch(
            parentPath: ["device-tree", "product"],
            nodeName: "iopm",
            properties: [
                .init(name: "aot-linger-time-ms", length: 4, flags: 0, value: .integer(0)),
                .init(name: "aot-mode", length: 4, flags: 0, value: .integer(13)),
            ],
            patchID: "devicetree.product.iopm_node",
            description: "Add /product/iopm node with aot-mode=13 + aot-linger-time-ms=0 (2 props)"
        ),

        // ── ISP / SMC camera-flag stubs (Tier F — /arm-io subtree) ──
        // Adds minimal stub nodes carrying ONLY the camera-related
        // properties that libMobileGestalt / SpringBoard / Camera.app
        // userland code walks under `/arm-io/isp`, `/arm-io/ispRtb`,
        // and `/arm-io/smc/iop-smc-nub/smc-ext-charger`.
        //
        // d47ap carries these as full hardware-attach nodes (65/53/14
        // properties). We deliberately do NOT replicate the full set
        // — they describe a real ISP / SMC chip with MMIO regions,
        // interrupts, DART/IOMMU bindings, kext-`compatible` strings
        // etc., and the VM has no such hardware. Stubbing only the
        // camera-* properties + the mandatory `name` (no `compatible`,
        // no `device_type`, no `reg`, no `interrupts`) means:
        //
        //   - IOKit registry sees these nodes appear under `/arm-io`.
        //   - No kext (`AppleH16CamIn`, AppleSMC, etc.) finds a
        //     matching `compatible` and binds, so no driver probe
        //     can fail-and-panic on missing hardware.
        //   - Userland code that resolves these paths via
        //     `IORegistryEntryFromPath` + `IORegistryEntryGetProperty`
        //     still finds the camera-* properties on the empty stub.
        //
        // RISK: still untested. If an IOKit walker reports the empty
        // node and a userland daemon (e.g. cameracaptured) takes the
        // node's presence as "real ISP attached" and then crashes
        // trying to talk to it, the symptom is likely a boot stall or
        // a camera-daemon respawn loop visible in logs. Bisect by
        // removing /arm-io/isp + /arm-io/ispRtb first if so.
        //
        // The three nodes are added in dependency order: each parent
        // before its children. The patcher walks `experimentalNodeAdditions`
        // in array order against the in-memory tree, so later entries
        // can resolve parents added by earlier entries.

        // /arm-io/smc — empty stub (parent for iop-smc-nub).
        AddChildNodePatch(
            parentPath: ["device-tree", "arm-io"],
            nodeName: "smc",
            properties: [],
            patchID: "devicetree.arm_io.smc_stub",
            description: "Add /arm-io/smc empty stub (parent for smc-ext-charger chain)"
        ),

        // /arm-io/smc/iop-smc-nub — empty stub (parent for smc-ext-charger).
        AddChildNodePatch(
            parentPath: ["device-tree", "arm-io", "smc"],
            nodeName: "iop-smc-nub",
            properties: [],
            patchID: "devicetree.arm_io.smc.iop_smc_nub_stub",
            description: "Add /arm-io/smc/iop-smc-nub empty stub (parent for smc-ext-charger)"
        ),

        // /arm-io/smc/iop-smc-nub/smc-ext-charger — carries camera-driver.
        AddChildNodePatch(
            parentPath: ["device-tree", "arm-io", "smc", "iop-smc-nub"],
            nodeName: "smc-ext-charger",
            properties: [
                .init(name: "camera-driver", length: 14, flags: 0, value: .string("AppleH16CamIn")),
            ],
            patchID: "devicetree.arm_io.smc.smc_ext_charger_camera_driver",
            description: "Add /arm-io/smc/iop-smc-nub/smc-ext-charger with camera-driver='AppleH16CamIn'"
        ),

        // /arm-io/isp — minimal stub carrying camera-front + camera-rear.
        AddChildNodePatch(
            parentPath: ["device-tree", "arm-io"],
            nodeName: "isp",
            properties: [
                .init(name: "camera-front", length: 4, flags: 0, value: .integer(1)),
                .init(name: "camera-rear", length: 4, flags: 0, value: .integer(1)),
            ],
            patchID: "devicetree.arm_io.isp_camera_flags",
            description: "Add /arm-io/isp stub with camera-front=1 + camera-rear=1"
        ),

        // /arm-io/ispRtb — minimal stub carrying camera-front + camera-rear.
        AddChildNodePatch(
            parentPath: ["device-tree", "arm-io"],
            nodeName: "ispRtb",
            properties: [
                .init(name: "camera-front", length: 4, flags: 0, value: .integer(1)),
                .init(name: "camera-rear", length: 4, flags: 0, value: .integer(1)),
            ],
            patchID: "devicetree.arm_io.ispRtb_camera_flags",
            description: "Add /arm-io/ispRtb stub with camera-front=1 + camera-rear=1"
        ),
    ]

    // MARK: - Device Tree Structures

    /// A single property in a device tree node.
    final class DTProperty {
        var name: String
        var length: Int
        var flags: UInt16
        var value: Data
        /// File offset of the property value within the flat binary.
        let valueOffset: Int

        init(name: String, length: Int, flags: UInt16, value: Data, valueOffset: Int) {
            self.name = name
            self.length = length
            self.flags = flags
            self.value = value
            self.valueOffset = valueOffset
        }
    }

    /// A node in the device tree containing properties and child nodes.
    final class DTNode {
        var properties: [DTProperty] = []
        var children: [DTNode] = []
    }

    // MARK: - Init

    public init(data: Data, verbose: Bool = true, includeIdentityPatches: Bool = false) {
        buffer = BinaryBuffer(data)
        self.verbose = verbose
        self.includeIdentityPatches = includeIdentityPatches
    }

    // MARK: - Patcher

    public func findAll() throws -> [PatchRecord] {
        patches = []
        rebuiltData = nil
        let root = try parsePayload(buffer.data)
        try applyPatches(root: root)
        rebuiltData = serializePayload(root)
        return patches
    }

    @discardableResult
    public func apply() throws -> Int {
        if patches.isEmpty, rebuiltData == nil {
            let _ = try findAll()
        }
        if let rebuiltData {
            buffer.data = rebuiltData
        } else {
            for record in patches {
                buffer.writeBytes(at: record.fileOffset, bytes: record.patchedBytes)
            }
        }
        if verbose, !patches.isEmpty {
            print("\n  [\(patches.count) DeviceTree patch(es) applied]")
        }
        return patches.count
    }

    public var patchedData: Data {
        rebuiltData ?? buffer.data
    }

    // MARK: - Parsing

    /// Align a value up to the next 4-byte boundary.
    private static func align4(_ n: Int) -> Int {
        (n + 3) & ~3
    }

    /// Decode a null-terminated C string from raw bytes.
    private static func decodeCString(_ data: Data) -> String {
        if let nullIndex = data.firstIndex(of: 0) {
            let slice = data[data.startIndex ..< nullIndex]
            return String(bytes: slice, encoding: .utf8) ?? ""
        }
        return String(bytes: data, encoding: .utf8) ?? ""
    }

    /// Parse a device tree node from the flat binary at the given offset.
    /// Returns the parsed node and the offset past the end of the node.
    private func parseNode(_ blob: Data, offset: Int) throws -> (DTNode, Int) {
        guard offset + 8 <= blob.count else {
            throw PatcherError.invalidFormat("DeviceTree: truncated node header at offset \(offset)")
        }

        let nProps = blob.loadLE(UInt32.self, at: offset)
        let nChildren = blob.loadLE(UInt32.self, at: offset + 4)
        var pos = offset + 8

        let node = DTNode()

        for _ in 0 ..< nProps {
            guard pos + 36 <= blob.count else {
                throw PatcherError.invalidFormat("DeviceTree: truncated property header at offset \(pos)")
            }

            let nameData = blob[blob.startIndex.advanced(by: pos) ..< blob.startIndex.advanced(by: pos + 32)]
            let name = Self.decodeCString(Data(nameData))
            let length = Int(blob.loadLE(UInt16.self, at: pos + 32))
            let flags = blob.loadLE(UInt16.self, at: pos + 34)
            pos += 36

            guard pos + length <= blob.count else {
                throw PatcherError.invalidFormat("DeviceTree: truncated property value '\(name)' at offset \(pos)")
            }

            let value = Data(blob[blob.startIndex.advanced(by: pos) ..< blob.startIndex.advanced(by: pos + length)])
            let valueOffset = pos
            pos += Self.align4(length)

            node.properties.append(DTProperty(
                name: name, length: length, flags: flags,
                value: value, valueOffset: valueOffset
            ))
        }

        for _ in 0 ..< nChildren {
            let (child, nextPos) = try parseNode(blob, offset: pos)
            node.children.append(child)
            pos = nextPos
        }

        return (node, pos)
    }

    /// Parse the entire device tree payload.
    private func parsePayload(_ blob: Data) throws -> DTNode {
        let (root, end) = try parseNode(blob, offset: 0)
        guard end == blob.count else {
            throw PatcherError.invalidFormat(
                "DeviceTree: unexpected trailing bytes (\(blob.count - end) extra)"
            )
        }
        return root
    }

    private func serializeNode(_ node: DTNode) -> Data {
        var out = Data()
        out.append(contentsOf: withUnsafeBytes(of: UInt32(node.properties.count).littleEndian) { Data($0) })
        out.append(contentsOf: withUnsafeBytes(of: UInt32(node.children.count).littleEndian) { Data($0) })

        for prop in node.properties {
            var name = Data(prop.name.utf8)
            if name.count >= 32 {
                name = Data(name.prefix(31))
            }
            name.append(contentsOf: [UInt8](repeating: 0, count: 32 - name.count))
            out.append(name)

            out.append(contentsOf: withUnsafeBytes(of: UInt16(prop.length).littleEndian) { Data($0) })
            out.append(contentsOf: withUnsafeBytes(of: prop.flags.littleEndian) { Data($0) })
            out.append(prop.value)

            let pad = Self.align4(prop.length) - prop.length
            if pad > 0 {
                out.append(Data(repeating: 0, count: pad))
            }
        }

        for child in node.children {
            out.append(serializeNode(child))
        }
        return out
    }

    private func serializePayload(_ root: DTNode) -> Data {
        serializeNode(root)
    }

    // MARK: - Node Navigation

    /// Get the "name" property value from a node.
    private func nodeName(_ node: DTNode) -> String {
        for prop in node.properties {
            if prop.name == "name" {
                return Self.decodeCString(prop.value)
            }
        }
        return ""
    }

    /// Find a direct child node by name.
    private func findChild(_ node: DTNode, name: String) throws -> DTNode {
        for child in node.children {
            if nodeName(child) == name {
                return child
            }
        }
        throw PatcherError.patchSiteNotFound("DeviceTree: missing child node '\(name)'")
    }

    /// Resolve a node path like ["device-tree", "buttons"] from the root.
    private func resolveNode(_ root: DTNode, path: [String]) throws -> DTNode {
        guard !path.isEmpty, path[0] == "device-tree" else {
            throw PatcherError.patchSiteNotFound("DeviceTree: invalid node path \(path)")
        }
        var node = root
        for name in path.dropFirst() {
            node = try findChild(node, name: name)
        }
        return node
    }

    /// Find a property by name within a node.
    private func findProperty(_ node: DTNode, name: String) throws -> DTProperty {
        for prop in node.properties {
            if prop.name == name {
                return prop
            }
        }
        throw PatcherError.patchSiteNotFound("DeviceTree: missing property '\(name)'")
    }

    // MARK: - Value Encoding

    /// Encode a string value with null termination, padded/truncated to a fixed length.
    private static func encodeFixedString(_ text: String, length: Int) -> Data {
        var raw = Data(text.utf8)
        raw.append(0) // null terminator
        if raw.count > length {
            return Data(raw.prefix(length))
        }
        raw.append(contentsOf: [UInt8](repeating: 0, count: length - raw.count))
        return raw
    }

    /// Encode raw bytes for a property whose layout the caller has prepared
    /// (typically a multi-string NUL-delimited blob like `compatible`).
    /// Truncates if longer than the slot, pads with NULs if shorter.
    private static func encodeFixedBytes(_ data: Data, length: Int) -> Data {
        if data.count > length {
            return Data(data.prefix(length))
        }
        var out = Data(data)
        out.append(contentsOf: [UInt8](repeating: 0, count: length - out.count))
        return out
    }

    /// Encode an integer value as little-endian bytes.
    private static func encodeInteger(_ value: UInt64, length: Int) throws -> Data {
        var data = Data(count: length)
        switch length {
        case 1:
            data[0] = UInt8(value & 0xFF)
        case 2:
            let v = UInt16(value & 0xFFFF)
            data.withUnsafeMutableBytes { $0.storeBytes(of: v.littleEndian, as: UInt16.self) }
        case 4:
            let v = UInt32(value & 0xFFFF_FFFF)
            data.withUnsafeMutableBytes { $0.storeBytes(of: v.littleEndian, as: UInt32.self) }
        case 8:
            data.withUnsafeMutableBytes { $0.storeBytes(of: value.littleEndian, as: UInt64.self) }
        default:
            throw PatcherError.invalidFormat("DeviceTree: unsupported integer length \(length)")
        }
        return data
    }

    // MARK: - Patch Application

    /// Apply all property patches and record each change.
    ///
    /// Always runs `basePropertyPatches`. Additionally runs
    /// `identityPropertyPatches` + `experimentalNodeAdditions` when
    /// `includeIdentityPatches` is true (the `.exp` firmware variant) —
    /// other variants leave the device's identity properties untouched.
    private func applyPatches(root: DTNode) throws {
        var patchesToApply = Self.basePropertyPatches
        if includeIdentityPatches {
            patchesToApply.append(contentsOf: Self.identityPropertyPatches)
        }
        for patch in patchesToApply {
            let node = try resolveNode(root, path: patch.nodePath)
            let prop = try findProperty(node, name: patch.property)

            let originalBytes = Data(prop.value.prefix(patch.length))

            let newValue: Data = switch patch.value {
            case let .string(s):
                Self.encodeFixedString(s, length: patch.length)
            case let .integer(v):
                try Self.encodeInteger(v, length: patch.length)
            case let .bytes(d):
                Self.encodeFixedBytes(d, length: patch.length)
            }

            prop.length = patch.length
            prop.flags = patch.flags
            prop.value = newValue

            let record = PatchRecord(
                patchID: patch.patchID,
                component: component,
                fileOffset: prop.valueOffset,
                virtualAddress: nil,
                originalBytes: originalBytes,
                patchedBytes: newValue,
                description: patch.description
            )
            patches.append(record)

            if verbose {
                print(String(format: "  0x%06X: %@ → %@  [%@]",
                             prop.valueOffset,
                             originalBytes.hex,
                             newValue.hex,
                             patch.patchID))
            }
        }

        if includeIdentityPatches {
            for nodeAdd in Self.experimentalNodeAdditions {
                try applyNodeAddition(root: root, patch: nodeAdd)
            }
        }
    }

    /// Apply a single `AddChildNodePatch`: construct the new `DTNode`,
    /// fill its `name` + caller-supplied properties, attach to the
    /// parent's `children`, and record a `PatchRecord` for the change.
    ///
    /// Skips if a child with the same name already exists under the
    /// parent — keeps the patch idempotent so re-runs against an
    /// already-patched DT don't double-add.
    private func applyNodeAddition(root: DTNode, patch: AddChildNodePatch) throws {
        let parent = try resolveNode(root, path: patch.parentPath)

        for existing in parent.children {
            if nodeName(existing) == patch.nodeName {
                if verbose {
                    print("  -      : /\(patch.parentPath.joined(separator: "/"))/\(patch.nodeName) already present, skipping  [\(patch.patchID)]")
                }
                return
            }
        }

        let newNode = DTNode()

        // The `name` property is mandatory and matches the conventional
        // shape of every other DT node — fixed length = strlen(name)+1.
        let nameValue = Self.encodeFixedString(patch.nodeName, length: patch.nodeName.utf8.count + 1)
        newNode.properties.append(DTProperty(
            name: "name",
            length: nameValue.count,
            flags: 0,
            value: nameValue,
            valueOffset: 0
        ))

        for spec in patch.properties {
            let value: Data = switch spec.value {
            case let .string(s):
                Self.encodeFixedString(s, length: spec.length)
            case let .integer(v):
                try Self.encodeInteger(v, length: spec.length)
            case let .bytes(d):
                Self.encodeFixedBytes(d, length: spec.length)
            }
            newNode.properties.append(DTProperty(
                name: spec.name,
                length: spec.length,
                flags: spec.flags,
                value: value,
                valueOffset: 0
            ))
        }

        parent.children.append(newNode)

        // Serialize the new node so the patch record carries the bytes
        // we conceptually added. fileOffset = 0 because the rebuilt
        // payload is what actually lands on disk (apply() prefers
        // `rebuiltData` over per-record byte writes).
        let serialized = serializeNode(newNode)
        patches.append(PatchRecord(
            patchID: patch.patchID,
            component: component,
            fileOffset: 0,
            virtualAddress: nil,
            originalBytes: Data(),
            patchedBytes: serialized,
            description: patch.description
        ))

        if verbose {
            print("  +node  : /\(patch.parentPath.joined(separator: "/"))/\(patch.nodeName)  (\(newNode.properties.count) props, \(serialized.count)B)  [\(patch.patchID)]")
        }
    }
}

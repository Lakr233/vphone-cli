// DeviceTreeGuestDevicePatches.swift — The board presentation of the vphone600 tree.
//
// vphone600ap is a virtual iPhone: `artwork-device-idiom` is "phone", the root
// `model` is iPhone99,11, and most `/product` properties are `syscfg/xxxx`
// placeholders (flag 0x8000) that no syscfg on a VM ever fills. An iPadOS
// userland reads the same nodes, so a guest restored from an iPad IPSW lays
// itself out as a phone unless the tree it boots says otherwise, and one
// restored from another iPhone's IPSW finds placeholders where its own panel
// size, buttons and audio tunings should be.
//
// The answers come from the board's own device tree, `DeviceTree.<board>.im4p`,
// which the IPSW carries and the restore tree keeps. Every guest device but the
// iPhone XS Max gets them (`VPhoneGuestDevice.presentsBoard`); the patch IDs keep
// the `ipad_` names they were introduced with, because presets list them.
//
//   - the `/product` properties in `copiedProductProperties` take the board's
//     values, and are removed where the board has none — so an iPad mini keeps
//     `disable-chamois` and an M-series iPad, which has Stage Manager, does not;
//   - the phone-only placeholders (Dynamic Island, reachability, ringer
//     switch, volume-button geometry, CarPlay, Watch pairing) take the board's
//     values, and are removed where it has none (every one on an iPad), which
//     is what "absent" means to MobileGestalt;
//   - the root and `/product` identity becomes the board's, with VPHONE600AP
//     kept second in `compatible` so the platform expert still binds.
//
// What stays vphone600: everything that describes the virtual hardware —
// `graphics-featureset-class` (the paravirtual GPU is APPLE7, not the board's),
// `framebuffer-identifier`, `has-virtualization`, the guest agent port, memory
// class and boot flags.
//
// Only the installed tree carries these. Restore boots `RestoreDeviceTree`,
// which keeps the iPhone99,11 identity `restored_external` checks against the
// manifest; see `FirmwareManifest.separateGuestDeviceTree`.
//
// One edit here is every guest's, not only an iPad's: `/product/haptics` goes
// from every tree of every role, because no VM has the actuator or the haptic
// server the node promises. See `removeHaptics(from:)`.

import Foundation
import Img4tool
import VPhoneCoreKit
import VPhonePatchKit

extension DeviceTreePatcher {
    // MARK: - Role

    /// Which of the VM's device trees a patcher is rewriting.
    public enum TreeRole: Sendable {
        /// The one file an iPhone guest restores and boots with.
        case shared
        /// An iPad guest's `RestoreDeviceTree`: patched exactly as an iPhone
        /// guest's tree, so restore sees the board it always has.
        case restore
        /// An iPad guest's installed `DeviceTree`, which carries its identity.
        case installed
    }

    // MARK: - Patch IDs

    static let iPadArtworkPatch = "devicetree-cfw-ipad_artwork"
    static let iPadProductPatch = "devicetree-cfw-ipad_product"
    static let iPadButtonsPatch = "devicetree-cfw-ipad_buttons"
    static let iPadIdentityPatch = "devicetree-cfw-ipad_identity"
    static let iPadAudioPatch = "devicetree-cfw-ipad_audio"
    static let tvAppArchitecturePatch = "devicetree-cfw-tv_app_architecture"
    static let homeViewTouchPatch = "devicetree-cfw-homeview_touch"
    static let homePodProductPatch = "devicetree-cfw-homepod_product"
    static let watchPresentationPatch = "devicetree-cfw-watch_presentation"
    static let watchDriverKitPatch = "devicetree-cfw-watch_driverkit"
    static let watchCompanionPatch = "devicetree-cfw-watch_companion"
    static let hapticsPatch = "devicetree-cfw-product_haptics_node"
    static let microphoneArrayPatch = "devicetree-cfw-product_audio_microphone_array"

    // MARK: - What Is Copied

    /// `/product` properties taken from the board's tree, by patch.
    static let copiedProductProperties: [(name: String, patchID: String)] = [
        // What UIKit and SpringBoard lay out against.
        ("artwork-device-idiom", iPadArtworkPatch),
        ("artwork-device-subtype", iPadArtworkPatch),
        ("artwork-scale-factor", iPadArtworkPatch),
        // The device MobileGestalt reports.
        ("fdr-product-type", iPadIdentityPatch),
        ("sub-product-type", iPadIdentityPatch),
        ("unique-model", iPadIdentityPatch),
        // Name, chrome, and the panel and camera geometry.
        ("product-name", iPadProductPatch),
        ("product-description", iPadProductPatch),
        ("chrome-identifier", iPadProductPatch),
        ("compatible-device-fallback", iPadProductPatch),
        ("display-corner-radius", iPadProductPatch),
        ("display-mirroring", iPadProductPatch),
        ("side-button-location", iPadProductPatch),
        ("front-cam-offset-from-center", iPadProductPatch),
        ("rear-cam-offset-from-center", iPadProductPatch),
        ("thin-bezel", iPadProductPatch),
        ("ui-pip", iPadProductPatch),
        ("ui-background-quality", iPadProductPatch),
        ("ui-weather-quality", iPadProductPatch),
        ("assistant", iPadProductPatch),
        ("dictation", iPadProductPatch),
        ("offline-dictation", iPadProductPatch),
        ("builtin-mics", iPadProductPatch),
        // Multitasking: Slide Over, the overlay and pinned app slots, and
        // `disable-chamois`, which turns Stage Manager off where the board has it.
        ("medusa-overlay-app-capability", iPadProductPatch),
        ("ui-floating-live-app", iPadProductPatch),
        ("ui-overlay-app", iPadProductPatch),
        ("ui-pinned-app", iPadProductPatch),
        ("disable-chamois", iPadProductPatch),
        ("natural-volume-arrangement", iPadProductPatch),
    ]

    /// vphone600 `/product` properties that describe a phone. Removed unless the
    /// board's tree has them too.
    static let iPhoneOnlyProductProperties = [
        "island-notch-location",
        "large-format-phone",
        "ui-reachability",
        "oled-display",
        "siri-gesture",
        "hme-in-arkit",
        "location-reminders",
        "volume-up-button-location",
        "volume-down-button-location",
        "watch-companion",
        "carplay-2",
        "car-integration",
    ]

    /// Root properties taken from the board's tree. `compatible` is rebuilt.
    static let copiedRootProperties = ["model", "target-type", "target-sub-type"]

    /// The placeholder bit in a property's flags: the value is a `syscfg/` key,
    /// not data.
    static let placeholderFlag: UInt16 = 0x8000

    // MARK: - Edits

    /// One change to an existing node: a property set (added when missing) or
    /// removed.
    struct GuestEdit {
        enum Action {
            case set(Data)
            case remove
        }

        let nodePath: [String]
        let property: String
        let action: Action
        let patchID: String
    }

    /// The edits that make the vphone600 tree present the board whose tree is
    /// `source`.
    static func guestEdits(from source: DTNode) throws -> [GuestEdit] {
        let product = ["device-tree", "product"]
        let sourceProduct = try child(of: source, named: "product")
        var edits: [GuestEdit] = []

        func value(_ node: DTNode, _ name: String) -> Data? {
            guard let property = node.properties.first(where: { $0.name == name }),
                  property.flags & placeholderFlag == 0
            else { return nil }
            return property.value
        }

        // J42d's tvOS tree declares arm64 apps. Keep the source's concrete
        // value rather than the virtual phone's architecture; this edit is TV
        // presentation only and must not change existing phone or pad output.
        if let idiom = value(sourceProduct, "artwork-device-idiom"),
           ["tv", "home"].contains(String(decoding: idiom.prefix { $0 != 0 }, as: UTF8.self))
        {
            guard let architecture = value(sourceProduct, "app-macho-architecture"), !architecture.isEmpty else {
                throw PatcherError.patchSiteNotFound("DeviceTree: the TV board's tree has no concrete app-macho-architecture")
            }
            edits.append(GuestEdit(nodePath: product, property: "app-macho-architecture",
                                   action: .set(architecture), patchID: tvAppArchitecturePatch))
        }

        // HomeView's physical SPI touch controller is not present in the VM.
        // Keep USB touch and start driverkitd for its HID dext, as on watchOS.
        if let model = value(source, "model"),
           ["HomeAccessory17,1", "HomeAccessory17,2"].contains(String(decoding: model.prefix { $0 != 0 }, as: UTF8.self)) {
            edits.append(GuestEdit(nodePath: product, property: "supports-driverkit",
                                   action: .set(Data([1, 0, 0, 0])), patchID: homeViewTouchPatch))
        }

        // B520's accessory identity is independent of its artwork idiom,
        // which is a syscfg placeholder rather than "tv". HomePod services
        // query these capabilities through MobileGestalt.
        if let model = value(source, "model"),
           String(decoding: model.prefix { $0 != 0 }, as: UTF8.self) == "AudioAccessory5,1"
        {
            for name in ["horseman", "siri-hub", "app-macho-architecture"] {
                let action: GuestEdit.Action = value(sourceProduct, name).map { .set($0) } ?? .remove
                edits.append(GuestEdit(nodePath: product, property: name,
                                       action: action, patchID: homePodProductPatch))
            }
            // Keep the VM product token. Audio uses VirtualAudio's local
            // ProductIDOverride; a donor token changes unrelated MG clients.
        }

        if let idiom = value(sourceProduct, "artwork-device-idiom"),
           String(decoding: idiom.prefix { $0 != 0 }, as: UTF8.self) == "watch"
        {
            edits += watchEdits(product: product, value: { value(sourceProduct, $0) })
        }

        for (name, patchID) in copiedProductProperties {

            let action: GuestEdit.Action = value(sourceProduct, name).map { .set($0) } ?? .remove
            edits.append(GuestEdit(nodePath: product, property: name, action: action, patchID: patchID))
        }
        for name in iPhoneOnlyProductProperties {
            if let board = value(sourceProduct, name) {
                edits.append(GuestEdit(nodePath: product, property: name, action: .set(board), patchID: iPadProductPatch))
            } else {
                edits.append(GuestEdit(nodePath: product, property: name, action: .remove, patchID: iPadProductPatch))
            }
        }

        // An iPad has no ring/silent switch; nor does a board whose tree lacks one.
        let sourceButtons = try? child(of: source, named: "buttons")
        if sourceButtons.flatMap({ value($0, "function-button_ringeren") }) == nil {
            edits.append(GuestEdit(nodePath: ["device-tree", "buttons"], property: "function-button_ringeren",
                                   action: .remove, patchID: iPadButtonsPatch))
        }

        for name in copiedRootProperties {
            guard let board = value(source, name) else {
                throw PatcherError.patchSiteNotFound("DeviceTree: the board's tree has no root \(name)")
            }
            edits.append(GuestEdit(nodePath: ["device-tree"], property: name, action: .set(board), patchID: iPadIdentityPatch))
        }
        guard let compatible = value(source, "compatible"),
              let first = compatible.split(separator: 0, omittingEmptySubsequences: true).first
        else {
            throw PatcherError.patchSiteNotFound("DeviceTree: the board's tree has no root compatible")
        }
        edits.append(GuestEdit(nodePath: ["device-tree"], property: "compatible",
                               action: .set(Self.compatible(board: Data(first))), patchID: iPadIdentityPatch))
        return edits
    }

    // MARK: - Watch

    /// `/product` properties a watch's display is described by, beyond those
    /// every board copies.
    static let watchDisplayProperties = ["artwork-display-gamut", "artwork-dynamic-displaymode", "framebuffer-identifier"]

    /// The gestalt variant tags MobileGestalt reads in place of syscfg on the
    /// VM, and the board's `/product` property each stands for. vphone600's
    /// carry the D47's values; a watch whose tags still describe a phone shows
    /// no UI ("unsupported screen class"). A property the board lacks is a
    /// boolean it does not have: 0.
    static let watchVariantTags: [(tag: String, property: String)] = [
        ("tag-ards", "artwork-device-subtype"),
        ("tag-arsf", "artwork-scale-factor"),
        ("tag-codf", "compatible-device-fallback"),
        ("tag-tprt", "sub-product-type"),
        ("tag-crid", "chrome-identifier"),
        ("tag-dcrd", "display-corner-radius"),
        ("tag-fbid", "framebuffer-identifier"),
        ("tag-prde", "product-description"),
        ("tag-isnl", "island-notch-location"),
        ("tag-waco", "watch-companion"),
    ]

    static let watchVariantNode = ["device-tree", "product", "vphone600-gestalt-variants", "d47vm2025vre-variant"]

    /// The edits a watch board needs besides the common copy: its display
    /// properties, the variant tags, and `supports-driverkit`. The VM's touch
    /// screen is a USB device whose HID driver is a dext, and launchd starts
    /// driverkitd only on a device tree that says so; a real watch has no USB
    /// touch screen, so N227b's tree does not.
    static func watchEdits(product: [String], value: (String) -> Data?) -> [GuestEdit] {
        var edits: [GuestEdit] = []
        for name in watchDisplayProperties {
            let action: GuestEdit.Action = value(name).map { .set($0) } ?? .remove
            edits.append(GuestEdit(nodePath: product, property: name, action: action, patchID: watchPresentationPatch))
        }
        let absent = Data(count: 4)
        for (tag, property) in watchVariantTags {
            edits.append(GuestEdit(nodePath: watchVariantNode, property: tag,
                                   action: .set(value(property) ?? absent), patchID: watchPresentationPatch))
        }
        edits.append(GuestEdit(nodePath: product, property: "supports-driverkit",
                               action: .set(Data([1, 0, 0, 0])), patchID: watchDriverKitPatch))
        return edits
    }

    /// `compatible` with the board first, so `hw.model` reads it, and
    /// VPHONE600AP kept for the platform expert's AppleVMApple1IO match.
    static func compatible(board: Data) -> Data {
        board + Data("\0VPHONE600AP\0AppleVirtualPlatformARM\0".utf8)
    }

    private static func child(of node: DTNode, named name: String) throws -> DTNode {
        guard let child = optionalChild(of: node, named: name) else {
            throw PatcherError.patchSiteNotFound("DeviceTree: the board's tree has no \(name) node")
        }
        return child
    }

    private static func optionalChild(of node: DTNode, named name: String) -> DTNode? {
        node.children.first { child in
            child.properties.contains { $0.name == "name" && $0.value.prefix(while: { $0 != 0 }) == Data(name.utf8) }
        }
    }

    // MARK: - Audio

    /// AppleImage4's uint32 identity callback reads this exact four-byte
    /// property from /product. The research kernel's iOS value rejects a tvOS
    /// DDI's signed CLAS before APFS can mount it. Keep equality verification
    /// and supply the native HomePod class instead. See developer_disk_images.md.
    static func presentHomePodCryptexClass(in root: DTNode) throws -> (before: Data?, after: Data)? {
        try requireHomePodMini(root)
        let product = try child(of: root, named: "product")
        let values = product.properties.filter { $0.name == "cryptex1-product-class" }
        guard values.count <= 1 else {
            throw PatcherError.invalidFormat("HomePod cryptex class: duplicated product class")
        }
        var value = UInt32(0xf4).littleEndian
        let bytes = withUnsafeBytes(of: &value) { Data($0) }
        // TempPod's restored tree omits this property and the running kernel
        // reports the research iOS class. Supply the native class explicitly.
        guard let property = values.first else {
            product.properties.append(DTProperty(name: "cryptex1-product-class", flags: 0, value: bytes, valueOffset: 0))
            return (nil, bytes)
        }
        guard property.flags == 0, property.value.count == 4,
              [UInt32(0xf2), UInt32(0xf4)].contains(property.value.loadLE(UInt32.self, at: 0)) else {
            throw PatcherError.invalidFormat("HomePod cryptex class: expected one concrete iOS or tvOS uint32 product class")
        }
        guard property.value.loadLE(UInt32.self, at: 0) != 0xf4 else { return nil }
        let before = property.value
        property.value = bytes
        return (before, property.value)
    }

    /// MobileGestalt matches this exact 20-byte donor token against its product
    /// table; VirtualAudio uses that result to select the HomePod mini's enum 4
    /// routing. Root model strings alone do not select the native audio family.
    /// Accept a retained donor IM4P or its decoded flat payload, never a payload
    /// invented from the product name or an iPhone ProductIDOverride.
    public static func homePodAudioProductID(from data: Data) throws -> Data {
        let payload: Data
        if let im4p = try? IM4P(data) {
            guard im4p.fourcc == "dtre", !im4p.isEncrypted else {
                throw PatcherError.invalidFormat("HomePod audio product: expected an unencrypted dtre IM4P")
            }
            payload = try im4p.payload()
        } else {
            payload = data
        }
        let parser = DeviceTreePatcher(data: payload, verbose: false)
        return try homePodAudioProductID(from: parser.parsePayload(payload))
    }

    private static func requireHomePodMini(_ root: DTNode) throws {
        let models = root.properties.filter { $0.name == "model" }
        guard models.count == 1, let model = models.first, model.flags == 0,
              String(decoding: model.value.prefix { $0 != 0 }, as: UTF8.self) == "AudioAccessory5,1"
        else {
            throw PatcherError.invalidFormat("HomePod audio product: expected the AudioAccessory5,1 board tree")
        }
    }

    static func homePodAudioProductID(from source: DTNode) throws -> Data {
        try requireHomePodMini(source)
        let product = try child(of: source, named: "product")
        let properties = product.properties.filter { $0.name == "product-id" }
        guard properties.count == 1, let property = properties.first,
              property.flags == 0, property.value.count == 20
        else {
            throw PatcherError.invalidFormat("HomePod audio product: donor product-id must be one concrete 20-byte value")
        }
        return property.value
    }

    /// Replace only the HomePod's audio product token. The Preboot repair uses
    /// this independently of the board-audio-node repair and keeps the VM's
    /// virtual audio hardware and unrelated product capabilities unchanged.
    static func presentHomePodAudioProduct(in root: DTNode, from source: DTNode) throws -> (before: Data?, after: Data)? {
        try requireHomePodMini(root)
        let value = try homePodAudioProductID(from: source)
        let product = try child(of: root, named: "product")
        guard product.properties.filter({ $0.name == "product-id" }).count <= 1 else {
            throw PatcherError.invalidFormat("HomePod audio product: installed product-id is duplicated")
        }
        if let existing = product.properties.first(where: { $0.name == "product-id" }) {
            guard existing.value != value || existing.flags != 0 else { return nil }
            let before = existing.value
            existing.value = value
            existing.flags = 0
            return (before, value)
        }
        product.properties.append(DTProperty(name: "product-id", flags: 0, value: value, valueOffset: 0))
        return (nil, value)
    }

    // MARK: - Foldable product identity

    /// The 20-byte product token of a foldable board's own tree. CoreMotion
    /// selects its motion capabilities from this token — the hinge-angle
    /// manager among them — and the frameworks' `isV68` checks key on it; the
    /// VM platform's token selects none. Accept a retained donor IM4P or its
    /// decoded flat payload, never a token invented from the product name.
    public static func foldableProductID(from data: Data) throws -> Data {
        let payload: Data
        if let im4p = try? IM4P(data) {
            guard im4p.fourcc == "dtre", !im4p.isEncrypted else {
                throw PatcherError.invalidFormat("Foldable product: expected an unencrypted dtre IM4P")
            }
            payload = try im4p.payload()
        } else {
            payload = data
        }
        let parser = DeviceTreePatcher(data: payload, verbose: false)
        return try foldableProductID(from: parser.parsePayload(payload))
    }

    static func foldableProductID(from source: DTNode) throws -> Data {
        let subtypes = rootSubtypes(of: source)
        guard subtypes.count == 1,
              CustomFirmwarePostRestoreDeviceTree.foldableVMSubtypes.keys.contains(subtypes[0])
        else {
            throw PatcherError.invalidFormat(
                "Foldable product: expected a foldable board tree, not \(subtypes.isEmpty ? "no sub-type" : subtypes.joined(separator: ", "))",
            )
        }
        let product = try child(of: source, named: "product")
        let properties = product.properties.filter { $0.name == "product-id" }
        guard properties.count == 1, let property = properties.first,
              property.flags == 0, property.value.count == 20
        else {
            throw PatcherError.invalidFormat("Foldable product: donor product-id must be one concrete 20-byte value")
        }
        return property.value
    }

    /// Replace the installed tree's product token with the foldable board's
    /// own. The installed tree must itself be a foldable guest — the board's
    /// own sub-type or the VM value the sub-type repair writes — so a
    /// foldable board's token never reaches another guest. A tree that
    /// already carries the token, or is not a foldable guest, comes back
    /// unchanged.
    static func presentFoldableProductID(in root: DTNode, from source: DTNode) throws -> (before: Data?, after: Data)? {
        let subtypes = rootSubtypes(of: root)
        guard subtypes.count == 1,
              CustomFirmwarePostRestoreDeviceTree.foldableSubtypes.contains(subtypes[0])
        else { return nil }
        let value = try foldableProductID(from: source)
        let product = try child(of: root, named: "product")
        guard product.properties.filter({ $0.name == "product-id" }).count <= 1 else {
            throw PatcherError.invalidFormat("Foldable product: installed product-id is duplicated")
        }
        if let existing = product.properties.first(where: { $0.name == "product-id" }) {
            guard existing.value != value || existing.flags != 0 else { return nil }
            let before = existing.value
            existing.value = value
            existing.flags = 0
            return (before, value)
        }
        product.properties.append(DTProperty(name: "product-id", flags: 0, value: value, valueOffset: 0))
        return (nil, value)
    }

    private static func rootSubtypes(of node: DTNode) -> [String] {
        node.properties
            .filter { $0.name == "target-sub-type" }
            .compactMap { String(data: $0.value.prefix { $0 != 0 }, encoding: .utf8) }
    }

    /// What `presentBoardAudio` changed: the audio node's serialized bytes
    /// before and after, empty when there was no node.
    struct BoardAudioChange {
        let before: Data
        let after: Data
    }

    /// Give `root`'s `/product/audio` the properties of the board's.
    ///
    /// The tree's audio node, when there is one, came from
    /// `devicetree-cfw-product_audio_node`, which copies the D47 iPhone's. Its
    /// `acoustic-id` (8018) names `/Library/Audio/Tunings/AID8018`, which an iPad
    /// image does not ship; VirtualAudio then builds no microphone sub-ports, and
    /// on an iPad, whose board answers yes to stereo and webcam recording, it
    /// throws `PRECONDITION FAILURE` in `RoutingSettings_J98` and never
    /// initializes, so the guest has no audio route at all. The board's own node
    /// names the tunings its image carries (AID2029 on J820).
    ///
    /// Every property is copied as the board has it, placeholders included,
    /// except `AAPL,phandle`, which is the board tree's and could collide in
    /// this one; a property the board's node lacks is removed. The node is
    /// added under `/product` when the tree has none. Returns nil when the
    /// board has no audio node or the tree already matches it.
    static func presentBoardAudio(in root: DTNode, from source: DTNode) -> BoardAudioChange? {
        guard
            let sourceProduct = optionalChild(of: source, named: "product"),
            let sourceAudio = optionalChild(of: sourceProduct, named: "audio"),
            let product = optionalChild(of: root, named: "product")
        else { return nil }

        let copied = sourceAudio.properties.filter { $0.name != "AAPL,phandle" }
        func describe(_ properties: [DTProperty]) -> [String: (UInt16, Data)] {
            Dictionary(properties.map { ($0.name, ($0.flags, $0.value)) }, uniquingKeysWith: { first, _ in first })
        }
        let existing = optionalChild(of: product, named: "audio")
        if let existing {
            let lhs = describe(existing.properties.filter { $0.name != "AAPL,phandle" })
            let rhs = describe(copied)
            if lhs.count == rhs.count, lhs.allSatisfy({ name, entry in
                rhs[name].map { $0.0 == entry.0 && $0.1 == entry.1 } ?? false
            }) {
                return nil
            }
        }

        let before = existing.map(serialize) ?? Data()
        let node = existing ?? DTNode()
        let phandle = node.properties.filter { $0.name == "AAPL,phandle" }
        node.properties = copied.map {
            DTProperty(name: $0.name, flags: $0.flags, value: $0.value, valueOffset: 0)
        } + phandle
        if existing == nil {
            product.children.append(node)
        }
        return BoardAudioChange(before: before, after: serialize(node))
    }

    // MARK: - Haptics

    /// Remove `root`'s `/product/haptics`. Returns the node's serialized bytes,
    /// or nil when the tree has none.
    ///
    /// vphone600 carries the node (`closed-loop`, `supports-3rd-party-haptics`),
    /// so MobileGestalt answers yes to `DeviceSupportsHaptics` and
    /// `DeviceSupportsClosedLoopHaptics`. ToneLibrary reads the pair as
    /// "synchronized vibrations", sets `playHapticTracks` on every tone's player
    /// item, and mediaplaybackd then builds a `CHHapticEngine` beside the audio
    /// queue. A VM has no haptic server behind `com.apple.audio.hapticd`: the
    /// engine's XPC setup times out six times, `FigHapticEngineCreate` fails
    /// with 4099, and `itemfig_rebuildRenderPipelinesAndBoss` fails the whole
    /// item with it — the tone's audio never starts. That was measured on an
    /// iPad guest and on an iPhone guest alike. An iPad's own tree has no
    /// haptics node and an iPhone's has one, so what the guest's board carries
    /// does not decide it: no VM has the actuator or the server, so no guest
    /// tree keeps the node, whatever its role.
    static func removeHaptics(from root: DTNode) -> Data? {
        guard
            let product = optionalChild(of: root, named: "product"),
            let haptics = optionalChild(of: product, named: "haptics")
        else { return nil }
        product.children.removeAll { $0 === haptics }
        return serialize(haptics)
    }

    // MARK: - Microphone Array

    /// `/product/audio` properties that promise processing built on the
    /// board's microphone array.
    static let microphoneArrayProperties = ["supports-spatial-audio-capture", "supports-audio-mix"]

    /// Remove `microphoneArrayProperties` from `root`'s `/product/audio`.
    /// Returns each removed property with its value, in that order; empty when
    /// the tree has no audio node or none of them.
    ///
    /// The iPhone guest's audio node is the D47's, and an iPad guest's is its
    /// board's; either can say the device captures spatial audio and analyses
    /// an Audio Mix. A VM's microphone is the Mac's, one or two channels
    /// through virtio-snd, not the four-microphone array those answers stand
    /// for. With them iOS 27's Voice Memos records through the SpatialCapture
    /// route, whose DSP graph (`flexible_video_recording`, four microphones in,
    /// first-order ambisonics out) gives silence for the two real channels,
    /// and through the Audio Mix analysis, whose neural net faults in
    /// cameracaptured. See `Research/Guest/ios27_capture_microphone_source.md`.
    static func removeMicrophoneArrayClaims(from root: DTNode) -> [(name: String, value: Data)] {
        guard
            let product = optionalChild(of: root, named: "product"),
            let audio = optionalChild(of: product, named: "audio")
        else { return [] }
        var removed: [(name: String, value: Data)] = []
        for name in microphoneArrayProperties {
            guard let index = audio.properties.firstIndex(where: { $0.name == name }) else { continue }
            removed.append((name, audio.properties[index].value))
            audio.properties.remove(at: index)
        }
        return removed
    }

    // MARK: - iPhone Product

    /// `/product` properties an iPhone guest takes from its board's tree when
    /// its own holds a `syscfg/` placeholder for them.
    ///
    /// On vphone600 these are placeholders no syscfg fills, and MobileGestalt
    /// reads a placeholder as absent. Settings then has no Siri page (`assistant`),
    /// no Model Name (`product-name`), no dictation (`dictation`), and the
    /// button geometry SpringBoard lays out against is missing. Measured on a
    /// 26.6.2 iPhone17,3 guest: with these from D47AP, Siri opens from the side
    /// button, dictation appears, and Camera Control and the Action Button are
    /// in Settings (with `iPhoneAddedProductProperties` and
    /// `iPhoneButtonProperties`).
    ///
    /// Only what describes the product to userland is listed. Properties that
    /// promise hardware the VM does not have — Bluetooth, baseband, NFC,
    /// exclaves, `has-*`, the graphics feature set, `framebuffer-identifier`,
    /// display calibration — stay as vphone600 has them.
    static let iPhoneProductProperties = [
        // What Settings and MobileGestalt name the device.
        "product-name", "product-description",
        // Siri and dictation.
        "assistant", "siri-gesture", "dictation", "offline-dictation", "builtin-mics",
        // Buttons SpringBoard and Settings lay out against.
        "side-button-location", "volume-up-button-location", "volume-down-button-location",
        // Display and chrome.
        "artwork-scale-factor", "chrome-identifier", "compatible-device-fallback",
        "display-corner-radius", "display-mirroring", "oled-display", "thin-bezel", "large-format-phone",
        // UI and feature switches.
        "ui-pip", "ui-reachability", "ui-background-quality", "ui-weather-quality",
        "hme-in-arkit", "carplay-2", "location-reminders", "watch-companion",
    ]

    /// `/product` properties vphone600 lacks altogether, added from the board:
    /// the Action Button's and Camera Control's geometry, and Camera Control
    /// itself, without which Settings has no Camera Control page.
    static let iPhoneAddedProductProperties = [
        "ringer-button-location", "camera-button-location", "supports-camera-button",
    ]

    /// `/buttons` properties taken from the board when they are placeholders.
    /// `function-button_ringeren` is what MobileGestalt reads for the Action
    /// Button. vphone600's `/buttons` has no `compatible`, so no button driver
    /// binds to the node and the board's function reference is never followed.
    static let iPhoneButtonProperties = ["function-button_ringeren"]

    /// One property `presentPhoneProduct` set: where, and its value before
    /// (nil when it was added).
    struct PhoneProductChange {
        let path: String
        let before: Data?
        let after: Data
    }

    /// Give an iPhone guest's `/product` and `/buttons` the board's values for
    /// `iPhoneProductProperties`, `iPhoneAddedProductProperties` and
    /// `iPhoneButtonProperties`.
    ///
    /// A listed property is copied only when the guest's is a placeholder (or,
    /// for the added ones, missing) and the board's is a real value, so a tree
    /// that already has them, or a board that lacks one, is left as it is.
    /// Returns what changed, empty when nothing did.
    static func presentPhoneProduct(in root: DTNode, from source: DTNode) -> [PhoneProductChange] {
        var changes: [PhoneProductChange] = []
        func fill(_ names: [String], node: String, add: Bool) {
            guard
                let target = optionalChild(of: root, named: node),
                let board = optionalChild(of: source, named: node)
            else { return }
            for name in names {
                guard let value = board.properties.first(where: { $0.name == name }),
                      value.flags & placeholderFlag == 0
                else { continue }
                if let existing = target.properties.first(where: { $0.name == name }) {
                    guard existing.flags & placeholderFlag != 0 else { continue }
                    changes.append(PhoneProductChange(path: "\(node)/\(name)", before: existing.value, after: value.value))
                    existing.flags = 0
                    existing.value = value.value
                } else if add {
                    target.properties.append(DTProperty(name: name, flags: 0, value: value.value, valueOffset: 0))
                    changes.append(PhoneProductChange(path: "\(node)/\(name)", before: nil, after: value.value))
                }
            }
        }
        fill(iPhoneProductProperties, node: "product", add: false)
        fill(iPhoneAddedProductProperties, node: "product", add: true)
        fill(iPhoneButtonProperties, node: "buttons", add: false)
        return changes
    }

    /// The flat encoding of one node and its children, for the patch record.
    private static func serialize(_ node: DTNode) -> Data {
        var out = Data()
        func append(_ value: UInt32) {
            withUnsafeBytes(of: value.littleEndian) { out.append(contentsOf: $0) }
        }
        append(UInt32(node.properties.count))
        append(UInt32(node.children.count))
        for property in node.properties {
            var name = Data(property.name.utf8.prefix(31))
            name.append(contentsOf: [UInt8](repeating: 0, count: 32 - name.count))
            out.append(name)
            withUnsafeBytes(of: UInt16(property.length).littleEndian) { out.append(contentsOf: $0) }
            withUnsafeBytes(of: property.flags.littleEndian) { out.append(contentsOf: $0) }
            out.append(property.value)
            out.append(contentsOf: [UInt8](repeating: 0, count: (4 - property.length % 4) % 4))
        }
        for child in node.children {
            out.append(serialize(child))
        }
        return out
    }

    // MARK: - Application

    /// Applies `guestEdits(from:)` to the parsed tree and records each change.
    func applyGuestEdits(root: DTNode) throws {
        guard let sourceTree else {
            throw PatcherError.fileNotFound(
                "DeviceTree: \(device.productType)'s own device tree (\(device.boardDeviceTreePath)) is needed to present it",
            )
        }
        let source = try parsePayload(sourceTree)
        if gateAllows(Self.iPadAudioPatch), let change = Self.presentBoardAudio(in: root, from: source) {
            patches.append(PatchRecord(
                patchID: Self.iPadAudioPatch,
                component: component,
                fileOffset: 0,
                virtualAddress: nil,
                originalBytes: change.before,
                patchedBytes: change.after,
                description: "Set /device-tree/product/audio as on \(device.productType)",
            ))
            if verbose {
                print("  =node  : /product/audio as on \(device.productType) (\(change.after.count)B)  [\(Self.iPadAudioPatch)]")
            }
        }
        for edit in try Self.guestEdits(from: source) {
            guard gateAllows(edit.patchID) else { continue }
            let node = try resolveNode(root, path: edit.nodePath)
            let index = node.properties.firstIndex { $0.name == edit.property }
            let before = index.map { node.properties[$0].value } ?? Data()

            let after: Data?
            switch edit.action {
            case .remove:
                guard let index else { continue }
                node.properties.remove(at: index)
                after = nil
            case let .set(value):
                if let index {
                    let property = node.properties[index]
                    guard property.value != value || property.flags != 0 else { continue }
                    property.value = value
                    property.flags = 0
                } else {
                    node.properties.append(DTProperty(name: edit.property, flags: 0, value: value, valueOffset: 0))
                }
                after = value
            }

            let path = (edit.nodePath + [edit.property]).joined(separator: "/")
            let description = switch edit.action {
            case .remove: "Remove \(path) (not on \(device.productType))"
            case .set: "Set \(path) as on \(device.productType)"
            }
            patches.append(PatchRecord(
                patchID: edit.patchID,
                component: component,
                fileOffset: 0,
                virtualAddress: nil,
                originalBytes: before,
                patchedBytes: after ?? Data(),
                description: description,
            ))
            if verbose {
                print("  \(after == nil ? "-prop " : "=prop "): /\(path) \(before.hex) → \((after ?? Data()).hex)  [\(edit.patchID)]")
            }
        }
    }

    /// Applies `removeHaptics(from:)` to the parsed tree, whichever guest and
    /// role it is for, and records the removal.
    func applyHapticsRemoval(root: DTNode) {
        guard gateAllows(Self.hapticsPatch), let removed = Self.removeHaptics(from: root) else { return }
        patches.append(PatchRecord(
            patchID: Self.hapticsPatch,
            component: component,
            fileOffset: 0,
            virtualAddress: nil,
            originalBytes: removed,
            patchedBytes: Data(),
            description: "Remove /device-tree/product/haptics, which no VM has the hardware for",
        ))
        if verbose {
            print("  -node  : /product/haptics, no actuator or haptic server on a VM (\(removed.count)B)  [\(Self.hapticsPatch)]")
        }
    }

    // MARK: - Notched iPhone

    static let islandNotchLocationPatch = "devicetree-cfw-island_notch_location"

    /// Removes `/product/island-notch-location` for a guest whose userland has
    /// no Dynamic Island layout (`VPhoneGuestDevice.notchedArtworkSubtype`),
    /// under the patch that otherwise sets it.
    func removeIslandNotchLocation(root: DTNode) throws {
        guard gateAllows(Self.islandNotchLocationPatch),
              let product = Self.optionalChild(of: root, named: "product"),
              let index = product.properties.firstIndex(where: { $0.name == "island-notch-location" })
        else { return }
        let removed = product.properties.remove(at: index)
        patches.append(PatchRecord(
            patchID: Self.islandNotchLocationPatch,
            component: component,
            fileOffset: removed.valueOffset,
            virtualAddress: nil,
            originalBytes: removed.value,
            patchedBytes: Data(),
            description: "Remove the island notch location: \(device.productName) has no Dynamic Island",
        ))
        if verbose {
            print("  -prop  : /product/island-notch-location, no Dynamic Island on \(device.productName)  [\(Self.islandNotchLocationPatch)]")
        }
    }

    // MARK: - Watch Companion

    /// Give an iPhone guest's `/product/watch-companion` the value 1, adding it
    /// where the board copy removed it. Returns its value before (nil when it
    /// was absent), or nil changes when it already is a plain 1.
    ///
    /// vphone600's is `syscfg/waco`, which the VM's syscfg does not have, so
    /// iBoot drops the property and MobileGestalt answers that the phone pairs
    /// with no watch: the Watch app has no icon, and NanoRegistry's clients
    /// never see the watch nanoregistryd discovers.
    static func presentWatchCompanion(in root: DTNode) -> (before: Data?, after: Data)? {
        guard let product = optionalChild(of: root, named: "product") else { return nil }
        let value = Data([1, 0, 0, 0])
        if let existing = product.properties.first(where: { $0.name == "watch-companion" }) {
            guard existing.flags & placeholderFlag != 0 || existing.value != value else { return nil }
            let before = existing.value
            existing.flags = 0
            existing.value = value
            return (before, value)
        }
        product.properties.append(DTProperty(name: "watch-companion", flags: 0, value: value, valueOffset: 0))
        return (nil, value)
    }

    /// Applies `presentWatchCompanion(in:)` to an iPhone guest's tree.
    func applyWatchCompanion(root: DTNode) {
        guard device.family == .iPhone, gateAllows(Self.watchCompanionPatch),
              let change = Self.presentWatchCompanion(in: root)
        else { return }
        patches.append(PatchRecord(
            patchID: Self.watchCompanionPatch,
            component: component,
            fileOffset: 0,
            virtualAddress: nil,
            originalBytes: change.before ?? Data(),
            patchedBytes: change.after,
            description: "Set /device-tree/product/watch-companion = 1",
        ))
        if verbose {
            print("  =prop  : /product/watch-companion = 1, the VM syscfg has no waco  [\(Self.watchCompanionPatch)]")
        }
    }

    /// Applies `removeMicrophoneArrayClaims(from:)` to the parsed tree,
    /// whichever guest and role it is for, and records each removal.
    func applyMicrophoneArrayRemoval(root: DTNode) {
        guard gateAllows(Self.microphoneArrayPatch) else { return }
        for (name, value) in Self.removeMicrophoneArrayClaims(from: root) {
            patches.append(PatchRecord(
                patchID: Self.microphoneArrayPatch,
                component: component,
                fileOffset: 0,
                virtualAddress: nil,
                originalBytes: value,
                patchedBytes: Data(),
                description: "Remove /device-tree/product/audio/\(name), which needs a microphone array no VM has",
            ))
            if verbose {
                print("  -prop  : /product/audio/\(name) \(value.hex) → absent  [\(Self.microphoneArrayPatch)]")
            }
        }
    }
}

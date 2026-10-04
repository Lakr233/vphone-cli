// DeviceTreeGuestDevicePatches.swift — The iPad presentation of the vphone600 tree.
//
// vphone600ap is a virtual iPhone: `artwork-device-idiom` is "phone", the root
// `model` is iPhone99,11, and most `/product` properties are `syscfg/xxxx`
// placeholders (flag 0x8000) that no syscfg on a VM ever fills. An iPadOS
// userland reads the same nodes, so a guest restored from an iPad IPSW lays
// itself out as a phone unless the tree it boots says otherwise.
//
// The answers come from the iPad's own device tree, `DeviceTree.<board>.im4p`,
// which the IPSW carries and the restore tree keeps:
//
//   - the `/product` properties in `copiedProductProperties` take the board's
//     values, and are removed where the board has none — so an iPad mini keeps
//     `disable-chamois` and an M-series iPad, which has Stage Manager, does not;
//   - the phone-only placeholders no iPad carries (Dynamic Island,
//     reachability, ringer switch, volume-button geometry, CarPlay, Watch
//     pairing) are removed, which is what "absent" means to MobileGestalt;
//   - the root and `/product` identity becomes the board's, with VPHONE600AP
//     kept second in `compatible` so the platform expert still binds.
//
// What stays vphone600: everything that describes the virtual hardware —
// `graphics-featureset-class` (the paravirtual GPU is APPLE7, not the iPad's),
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
    static let hapticsPatch = "devicetree-cfw-product_haptics_node"

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

        // An iPad has no ring/silent switch.
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
}

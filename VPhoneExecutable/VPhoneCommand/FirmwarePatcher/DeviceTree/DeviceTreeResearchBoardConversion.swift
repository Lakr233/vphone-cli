// DeviceTreeResearchBoardConversion.swift — vresearch101 → vphone600.
//
// Only the 26.1–26.4 beta cloudOS releases carry a vphone600ap device tree.
// Every other one has the research board's alone, which describes a compute
// module: no buttons, touch screen or Bluetooth, no phone product properties,
// and `ComputeModule14,2` where the userland looks for `iPhone99,11`. This
// rewrites it as the vphone600 tree of the same release, before any other
// device tree patch runs, so those see the tree they were written for.
//
// Checked against Apple's own trees: converting the vresearch101 tree of the
// 26.1 and 26.4 beta cloudOS gives their vphone600 tree, property for property,
// apart from the build time-stamp and the order properties are stored in.
//
// Nodes the research board lacks go where vphone600 has them, each with a
// fresh `AAPL,phandle`. The existing phandles are left alone, so every
// `interrupt-parent` and `serial-device` reference keeps pointing where it did.

import Foundation
import VPhonePatchKit

extension DeviceTreePatcher {
    // MARK: - What Is Converted

    /// A property value, encoded as the vphone600 tree stores it.
    enum ResearchBoardValue {
        case string(String)
        case strings([String])
        case integer(UInt32)
        case bytes(Data)
        /// A `syscfg/<key>` placeholder: iBoot fills it from the VM's syscfg,
        /// or drops the property when the syscfg has no such key.
        case syscfg(String)
        case empty
    }

    /// A node the research board lacks, inserted after `after` (first when nil).
    struct ResearchBoardNode {
        let parent: [String]
        let name: String
        let after: String?
    }

    struct ResearchBoardProperty {
        let path: [String]
        let name: String
        let value: ResearchBoardValue
    }

    /// In vphone600's order, so a node is added before its children.
    static let researchBoardNodes: [ResearchBoardNode] = [
        ResearchBoardNode(parent: [], name: "buttons", after: nil),
        ResearchBoardNode(parent: ["arm-io"], name: "multi-touch", after: "gfx"),
        ResearchBoardNode(parent: ["arm-io"], name: "bluetooth", after: "cpu-debug-interface"),
        ResearchBoardNode(parent: ["product"], name: "vphone600-gestalt-variants", after: nil),
        ResearchBoardNode(parent: ["product", "vphone600-gestalt-variants"], name: "d47vm2025vre-variant", after: nil),
        ResearchBoardNode(parent: ["product"], name: "maps", after: "vphone600-gestalt-variants"),
        ResearchBoardNode(parent: ["product"], name: "haptics", after: "maps"),
    ]

    /// Research board properties vphone600 does not have.
    static let researchBoardRemovals: [(path: [String], name: String)] = [
        (["defaults"], "pmap-max-asids"),
        (["product"], "kernel-core-dump-location"),
    ]

    static let researchBoardProperties: [ResearchBoardProperty] = {
        func set(_ path: [String], _ name: String, _ value: ResearchBoardValue) -> ResearchBoardProperty {
            ResearchBoardProperty(path: path, name: name, value: value)
        }
        let variant = ["product", "vphone600-gestalt-variants", "d47vm2025vre-variant"]
        return [
            // MARK: Identity

            set([], "compatible", .strings(["VPHONE600AP", "iPhone99,11", "AppleVirtualPlatformARM"])),
            set([], "model", .string("iPhone99,11")),
            set([], "target-sub-type", .string("VPHONE600AP")),
            set([], "target-type", .string("VPHONE600")),

            // MARK: Buttons, Touch, Bluetooth

            set(["buttons"], "function-button_ringeren", .syscfg("rgen")),
            set(["buttons"], "home-button-type", .syscfg("home")),
            set(["arm-io", "multi-touch"], "device_type", .string("multi-touch")),
            set(["arm-io", "multi-touch"], "ttw-supported", .empty),
            set(["arm-io", "bluetooth"], "device_type", .string("bluetooth")),
            set(["arm-io", "bluetooth"], "local-mac-address", .syscfg("BMac/6,zeroes/6")),
            set(["arm-io", "bluetooth"], "transport-encoding", .integer(10)),

            // MARK: Filesystems and Defaults

            set(["filesystems"], "e-apfs", .integer(1)),
            set(["defaults"], "kern.entitled_max_task_pmem", .syscfg("ketp")),
            set(["defaults"], "kern.max_task_pmem", .syscfg("kmtp")),
            set(["defaults"], "kern.maxkfsevents", .integer(1024)),
            set(["defaults"], "kern.maxvnodes", .integer(14000)),
            set(["defaults"], "kern.vm_compressor", .integer(32)),

            // MARK: Product

            set(["product"], "artwork-device-idiom", .string("phone")),
            set(["product"], "artwork-device-subtype", .syscfg("ards")),
            set(["product"], "artwork-display-gamut", .string("P3")),
            set(["product"], "artwork-scale-factor", .syscfg("arsf")),
            set(["product"], "assistant", .syscfg("assi")),
            set(["product"], "builtin-mics", .syscfg("mics")),
            set(["product"], "car-integration", .integer(1)),
            set(["product"], "carplay-2", .syscfg("car2")),
            set(["product"], "chrome-identifier", .syscfg("crid")),
            set(["product"], "compatible-device-fallback", .syscfg("codf")),
            set(["product"], "device-perf-memory-class", .integer(8)),
            set(["product"], "dictation", .syscfg("dict")),
            set(["product"], "display-corner-radius", .syscfg("dcrd")),
            set(["product"], "display-mirroring", .syscfg("dimi")),
            set(["product"], "ephemeral-data-mode", .integer(0)),
            set(["product"], "fdr-product-type", .string("iPhone99,11")),
            set(["product"], "framebuffer-identifier", .syscfg("fbid")),
            set(["product"], "front-cam-offset-from-center", .syscfg("fcof")),
            set(["product"], "gestalt-variant-id", .syscfg("gvid")),
            set(["product"], "hme-in-arkit", .syscfg("hmei")),
            set(["product"], "island-notch-location", .syscfg("isnl")),
            set(["product"], "jetsam-properties-product-type", .syscfg("jppt")),
            set(["product"], "large-format-phone", .syscfg("larg")),
            set(["product"], "location-reminders", .syscfg("lore")),
            set(["product"], "offline-dictation", .syscfg("odct")),
            set(["product"], "oled-display", .syscfg("oled")),
            set(["product"], "product-description", .syscfg("prde")),
            set(["product"], "product-id", .bytes(Data(base64Encoded: "UT13EFwE1E/xcpFIvIZC6UYOjpc=")!)),
            set(["product"], "product-name", .syscfg("prde")),
            set(["product"], "rear-cam-offset-from-center", .syscfg("rcof")),
            set(["product"], "side-button-location", .syscfg("sblo")),
            set(["product"], "siri-gesture", .syscfg("sige")),
            set(["product"], "sub-product-type", .string("iPhone99,11")),
            set(["product"], "supports-recoveryos", .integer(1)),
            set(["product"], "sw-pro-res", .integer(1)),
            set(["product"], "thin-bezel", .syscfg("thin")),
            set(["product"], "thinning-product-type", .syscfg("tprt")),
            set(["product"], "ui-background-quality", .syscfg("uiba")),
            set(["product"], "ui-pip", .syscfg("uipi")),
            set(["product"], "ui-reachability", .syscfg("uire")),
            set(["product"], "ui-weather-quality", .syscfg("uiwe")),
            set(["product"], "unique-model", .string("VPHONE600AP")),
            set(["product"], "variant-name", .syscfg("vana")),
            set(["product"], "vm-supports-generative-models", .syscfg("vsgm")),
            set(["product"], "volume-down-button-location", .syscfg("vdbl")),
            set(["product"], "volume-up-button-location", .syscfg("vubl")),
            set(["product"], "watch-companion", .syscfg("waco")),
            set(["product", "maps"], "3d-imagery", .syscfg("3dim")),
            set(["product", "maps"], "3d-maps", .syscfg("3dma")),
            set(["product", "maps"], "navigation", .syscfg("navi")),
            set(["product", "haptics"], "closed-loop", .integer(1)),
            set(["product", "haptics"], "supports-3rd-party-haptics", .integer(1)),
            set(["product", "usb-device"], "product-string", .string("iPhone Research Environment Virtual Machine")),

            // MARK: Gestalt Variant
            //
            // The values the placeholders above resolve to on this variant.

            set(["product", "vphone600-gestalt-variants"], "compatible", .string("gestalt-variant-list")),
            set(variant, "tag-3dim", .integer(0)),
            set(variant, "tag-3dma", .integer(0)),
            set(variant, "tag-WMac", .integer(0)),
            set(variant, "tag-ards", .integer(2556)),
            set(variant, "tag-arsf", .integer(3)),
            set(variant, "tag-assi", .integer(1)),
            set(variant, "tag-bumi", .integer(1)),
            set(variant, "tag-car2", .integer(1)),
            set(variant, "tag-codf", .string("iPhone17,3")),
            set(variant, "tag-crid", .string("com.apple.dt.devicekit.chrome.phone11")),
            set(variant, "tag-dcrd", .bytes(Data(base64Encoded: "NwAAAAEAAAA=")!)),
            set(variant, "tag-dict", .integer(1)),
            set(variant, "tag-dimi", .integer(1)),
            set(variant, "tag-fbid", .string("A6AC96E7-C5D3-47A6-8967-A8B2D02F1C66")),
            set(variant, "tag-fcof", .bytes(Data(base64Encoded: "YQABAJIcAADYEwAA6AMAAAAAAAA=")!)),
            set(variant, "tag-gvid", .integer(134_369_303)),
            set(variant, "tag-hmei", .integer(1)),
            set(variant, "tag-home", .integer(2)),
            set(variant, "tag-isnl", .integer(144)),
            set(variant, "tag-jppt", .string("D47")),
            set(variant, "tag-ketp", .integer(6144)),
            set(variant, "tag-kmtp", .integer(0x0D30)),
            set(variant, "tag-larg", .integer(0)),
            set(variant, "tag-lore", .integer(1)),
            set(variant, "tag-mics", .integer(1)),
            set(variant, "tag-navi", .integer(0)),
            set(variant, "tag-odct", .integer(1)),
            set(variant, "tag-oled", .integer(1)),
            set(variant, "tag-prde", .string("iPhone 16 Research Device")),
            set(variant, "tag-rcof", .bytes(Data(base64Encoded: "7aUAALJWAABZCAAA6AMAAAAAAAA=")!)),
            set(variant, "tag-rgen", .empty),
            set(variant, "tag-sblo", .bytes(Data(base64Encoded: "Ou4JAF6HFQDulwYANrMCABAnAAA=")!)),
            set(variant, "tag-sige", .integer(1)),
            set(variant, "tag-thin", .integer(1)),
            set(variant, "tag-tprt", .string("iPhone17,3")),
            set(variant, "tag-uiba", .integer(0x64)),
            set(variant, "tag-uipi", .integer(1)),
            set(variant, "tag-uire", .integer(1)),
            set(variant, "tag-uiwe", .integer(0x64)),
            set(variant, "tag-vana", .string("D47VM2025VRE")),
            set(variant, "tag-vdbl", .bytes(Data(base64Encoded: "Ou4JAF6HFQAXLAgAgLUBABAnAAA=")!)),
            set(variant, "tag-vsgm", .integer(1)),
            set(variant, "tag-vubl", .bytes(Data(base64Encoded: "Ou4JAF6HFQBxAQYAgLUBABAnAAA=")!)),
            set(variant, "tag-waco", .integer(1)),
            set(variant, "valid-tags", .bytes(Data(base64Encoded: "ZGl2Z29sYnNmb2NmZm9jcmRyY2RncmFsYWJpdWVyaXVpcGl1dm9pdWVnaXNpZW1oZXJvbGV3aXVpbXVidGNpZHRjZG9pc3NhbmlodGRlbG9lZHJwZnNyYXNkcmFmZG9jYW5hdmVtb2hvY29yc2NpbWltaWRsYnV2bGJkdmNhTVdhbWQzbWlkMzJyYWNvY2F3cHRta3B0ZWt0cnB0ZGlyY2RpYmZuZWdydHBwaml2YW5sbnNpbWdzdg==")!)),
        ]
    }()

    // MARK: - Detection

    /// Whether `root` is the research board's tree, by its root `target-type`.
    static func isResearchBoardTree(_ root: DTNode) -> Bool {
        guard let targetType = root.properties.first(where: { $0.name == "target-type" }) else { return false }
        return String(decoding: targetType.value.prefix { $0 != 0 }, as: UTF8.self) == "VRESEARCH101"
    }

    // MARK: - Conversion

    /// Rewrites a research board tree as vphone600 and records one change.
    /// Leaves any other tree alone, so a cloudOS that has vphone600 components
    /// records nothing.
    func applyResearchBoardConversion(root: DTNode) throws {
        let patchID = FirmwareResearchBoardPatchSet.deviceTreeConversion
        guard convertsResearchBoard, Self.isResearchBoardTree(root), gateAllows(patchID) else { return }

        func node(_ path: [String]) throws -> DTNode {
            try resolveNode(root, path: ["device-tree"] + path)
        }

        var removed = 0
        for (path, name) in Self.researchBoardRemovals {
            let target = try node(path)
            let before = target.properties.count
            target.properties.removeAll { $0.name == name }
            removed += before - target.properties.count
        }

        var phandle = Self.maximumPhandle(in: root)
        var added = 0
        for spec in Self.researchBoardNodes {
            let parent = try node(spec.parent)
            guard !parent.children.contains(where: { Self.name(of: $0) == spec.name }) else { continue }
            phandle += 1
            let child = DTNode()
            child.properties = [
                DTProperty(name: "name", flags: 0, value: Self.researchBoardEncoding(.string(spec.name)), valueOffset: 0),
                DTProperty(name: "AAPL,phandle", flags: 0, value: Self.researchBoardEncoding(.integer(phandle)), valueOffset: 0),
            ]
            // After its vphone600 sibling, or last when a release has none.
            var index = 0
            if let after = spec.after {
                index = parent.children.firstIndex { Self.name(of: $0) == after }.map { $0 + 1 } ?? parent.children.count
            }
            parent.children.insert(child, at: index)
            added += 1
        }

        for spec in Self.researchBoardProperties {
            let target = try node(spec.path)
            let value = Self.researchBoardEncoding(spec.value)
            let flags: UInt16 = if case .syscfg = spec.value { Self.placeholderFlag } else { 0 }
            if let existing = target.properties.first(where: { $0.name == spec.name }) {
                existing.value = value
                existing.flags = flags
            } else {
                target.properties.append(DTProperty(name: spec.name, flags: flags, value: value, valueOffset: 0))
            }
        }

        patches.append(PatchRecord(
            patchID: patchID,
            component: component,
            fileOffset: 0,
            virtualAddress: nil,
            originalBytes: Data(),
            patchedBytes: Data(),
            description: "Convert the vresearch101 device tree into vphone600",
        ))
        if verbose {
            print("  vresearch101 → vphone600: \(added) nodes added, \(Self.researchBoardProperties.count) properties set, \(removed) removed  [\(patchID)]")
        }
    }

    // MARK: - Helpers

    static func researchBoardEncoding(_ value: ResearchBoardValue) -> Data {
        func cString(_ text: String) -> Data {
            Data(text.utf8) + [0]
        }
        return switch value {
        case let .string(text): cString(text)
        case let .strings(texts): texts.map(cString).reduce(Data(), +)
        case let .integer(number): withUnsafeBytes(of: number.littleEndian) { Data($0) }
        case let .bytes(data): data
        case let .syscfg(key): cString("syscfg/" + key)
        case .empty: Data()
        }
    }

    private static func name(of node: DTNode) -> String {
        guard let property = node.properties.first(where: { $0.name == "name" }) else { return "" }
        return String(decoding: property.value.prefix { $0 != 0 }, as: UTF8.self)
    }

    static func maximumPhandle(in node: DTNode) -> UInt32 {
        let own = node.properties.first { $0.name == "AAPL,phandle" && $0.value.count == 4 }
            .map { $0.value.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)) } } ?? 0
        return node.children.map(maximumPhandle(in:)).reduce(own, max)
    }
}

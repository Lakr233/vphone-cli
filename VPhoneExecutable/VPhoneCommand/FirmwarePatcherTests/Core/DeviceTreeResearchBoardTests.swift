@testable import FirmwarePatcher
import Foundation
import Testing
import VPhoneCoreKit
import VPhonePatchKit

/// The vresearch101 → vphone600 conversion: against a small research board
/// tree, and against Apple's own pair of trees when an IPSW in `ipsws/`
/// carries both.
@Suite("Device tree research board conversion")
struct DeviceTreeResearchBoardTests {
    // MARK: - Fixture

    static func string(_ text: String) -> Data {
        Data((text + "\0").utf8)
    }

    static func phandle(_ number: UInt32) -> (String, Data) {
        ("AAPL,phandle", FlatDeviceTreeNode.uint32(number))
    }

    static func researchTree(targetType: String = "VRESEARCH101") -> Data {
        FlatDeviceTreeNode("device-tree", [
            ("target-type", string(targetType)),
            ("model", string("ComputeModule14,2")),
            phandle(1),
        ], children: [
            FlatDeviceTreeNode("filesystems", [phandle(2)]),
            FlatDeviceTreeNode("arm-io", [phandle(3)], children: [
                FlatDeviceTreeNode("uart0", [phandle(4)]),
                FlatDeviceTreeNode("gfx", [phandle(5), ("interrupt-parent", FlatDeviceTreeNode.uint32(4))]),
                FlatDeviceTreeNode("cpu-debug-interface", [phandle(6)]),
                FlatDeviceTreeNode("sep", [phandle(7)]),
            ]),
            FlatDeviceTreeNode("defaults", [
                phandle(8),
                ("pmap-max-asids", FlatDeviceTreeNode.uint32(4)),
                ("serial-device", FlatDeviceTreeNode.uint32(4)),
            ]),
            FlatDeviceTreeNode("product", [phandle(9), ("kernel-core-dump-location", string("x"))], children: [
                FlatDeviceTreeNode("usb-device", [phandle(10)]),
            ]),
        ]).serialized
    }

    /// Only the conversion on, so the vphone600 patches that follow it do not
    /// need their properties in this small tree.
    static let conversionOnly = VPhonePatchGate(
        declared: Set((FirmwareResearchBoardPatchSet.manifest.patches + FirmwareDeviceTreePatchSet.manifest.patches).map(\.identifier)),
        enabled: [FirmwareResearchBoardPatchSet.deviceTreeConversion],
    )

    static func convert(_ data: Data, converting: Bool = true) throws -> (DeviceTreePatcher, DeviceTreePatcher.DTNode, [PatchRecord]) {
        let patcher = DeviceTreePatcher(data: data, verbose: false)
        patcher.gate = conversionOnly
        patcher.convertsResearchBoard = converting
        let records = try patcher.findAll()
        return (patcher, try patcher.parsePayload(patcher.patchedData), records)
    }

    static func name(_ node: DeviceTreePatcher.DTNode) -> String {
        String(decoding: (node.properties.first { $0.name == "name" }?.value ?? Data()).prefix { $0 != 0 }, as: UTF8.self)
    }

    static func value(_ node: DeviceTreePatcher.DTNode, _ property: String) -> Data? {
        node.properties.first { $0.name == property }?.value
    }

    // MARK: - Small Tree

    @Test("A research board tree becomes vphone600, with new nodes in vphone600's places")
    func convertsResearchBoard() throws {
        let (patcher, root, records) = try Self.convert(Self.researchTree())
        #expect(records.map(\.patchID) == [FirmwareResearchBoardPatchSet.deviceTreeConversion])
        #expect(Self.value(root, "target-type") == Self.string("VPHONE600"))
        #expect(Self.value(root, "model") == Self.string("iPhone99,11"))

        #expect(root.children.map(Self.name) == ["buttons", "filesystems", "arm-io", "defaults", "product"])
        let armIO = try patcher.resolveNode(root, path: ["device-tree", "arm-io"])
        #expect(armIO.children.map(Self.name) == ["uart0", "gfx", "multi-touch", "cpu-debug-interface", "bluetooth", "sep"])
        let product = try patcher.resolveNode(root, path: ["device-tree", "product"])
        #expect(product.children.map(Self.name) == ["vphone600-gestalt-variants", "maps", "haptics", "usb-device"])

        let defaults = try patcher.resolveNode(root, path: ["device-tree", "defaults"])
        #expect(Self.value(defaults, "pmap-max-asids") == nil)
        #expect(Self.value(product, "kernel-core-dump-location") == nil)
        let placeholder = try #require(product.properties.first { $0.name == "artwork-device-subtype" })
        #expect(placeholder.flags == DeviceTreePatcher.placeholderFlag)
        #expect(placeholder.value == Self.string("syscfg/ards"))
    }

    @Test("Existing phandles and the references to them are kept; new nodes get unused ones")
    func keepsPhandles() throws {
        let (patcher, root, _) = try Self.convert(Self.researchTree())
        let gfx = try patcher.resolveNode(root, path: ["device-tree", "arm-io", "gfx"])
        #expect(Self.value(gfx, "AAPL,phandle") == FlatDeviceTreeNode.uint32(5))
        #expect(Self.value(gfx, "interrupt-parent") == FlatDeviceTreeNode.uint32(4))

        var phandles: [Data] = []
        func collect(_ node: DeviceTreePatcher.DTNode) {
            phandles += node.properties.filter { $0.name == "AAPL,phandle" }.map(\.value)
            node.children.forEach(collect)
        }
        collect(root)
        #expect(phandles.count == 17)
        #expect(Set(phandles).count == phandles.count)
    }

    // MARK: - Syscfg Placeholder Values

    static let conversionAndPlaceholders = VPhonePatchGate(
        declared: Set((FirmwareResearchBoardPatchSet.manifest.patches + FirmwareDeviceTreePatchSet.manifest.patches).map(\.identifier)),
        enabled: [FirmwareResearchBoardPatchSet.deviceTreeConversion, DeviceTreePatcher.syscfgPlaceholdersPatch],
    )

    static func resolve(
        _ data: Data,
        device: VPhoneGuestDevice = .default,
        role: DeviceTreePatcher.TreeRole = .shared,
    ) throws -> (DeviceTreePatcher, DeviceTreePatcher.DTNode, [PatchRecord]) {
        let patcher = DeviceTreePatcher(data: data, verbose: false, device: device, role: role)
        patcher.gate = conversionAndPlaceholders
        let records = try patcher.findAll()
        return (patcher, try patcher.parsePayload(patcher.patchedData), records)
    }

    /// Every placeholder left in the tree, as `node property syscfg/key`.
    static func placeholders(_ root: DeviceTreePatcher.DTNode) -> Set<String> {
        var found = Set<String>()
        func walk(_ node: DeviceTreePatcher.DTNode, _ path: String) {
            for property in node.properties where property.flags & DeviceTreePatcher.placeholderFlag != 0 {
                found.insert("\(path) \(property.name) " + String(decoding: property.value.prefix { $0 != 0 }, as: UTF8.self))
            }
            node.children.forEach { walk($0, path + "/" + name($0)) }
        }
        walk(root, "")
        return found
    }

    /// The syscfg keys vphone600's D47 variant has no value for: the unit's
    /// own identity, colours and addresses, and `rgen`, whose tag is empty.
    static let untaggedKeys: Set<String> = [
        "rgen", "CLBG", "BGMt", "CGMt", "CLCG", "EnMt", "CLHS", "MkBH", "MkBS", "RCHL", "rpcp", "SwBh", "SBVr",
        "gsrp", "BMac", "CFG#", "Coor", "MLB#", "MdlC", "Mod#", "Regn", "RMd#", "SrNm",
    ]

    static func key(_ line: String) -> String {
        String(line.split(separator: " ").last!.dropFirst("syscfg/".count).prefix { $0 != "/" })
    }

    /// A board tree as `DeviceTree.<board>.im4p` has it: no jetsam product
    /// type of its own unless `jetsamType` is given.
    static func boardTree(
        targetType: String,
        jetsamType: String? = nil,
        maxTaskPmem: UInt32? = nil,
    ) throws -> DeviceTreePatcher.DTNode {
        let tree = FlatDeviceTreeNode("device-tree", [("target-type", string(targetType))], children: [
            FlatDeviceTreeNode("defaults", maxTaskPmem.map { [("kern.max_task_pmem", FlatDeviceTreeNode.uint32($0))] } ?? []),
            FlatDeviceTreeNode("product", jetsamType.map { [("jetsam-properties-product-type", string($0))] } ?? []),
        ]).serialized
        return try DeviceTreePatcher(data: tree, verbose: false).parsePayload(tree)
    }

    @Test("The iPhone17,3 takes the variant's answers; untagged and empty keys stay")
    func resolvesTheVariantsDevice() throws {
        let (patcher, root, records) = try Self.resolve(Self.researchTree())
        let product = try patcher.resolveNode(root, path: ["device-tree", "product"])
        let jetsam = try #require(product.properties.first { $0.name == "jetsam-properties-product-type" })
        #expect(jetsam.flags == 0)
        #expect(jetsam.value == Self.string("D47"))
        #expect(Self.value(product, "product-name") == Self.string("iPhone 16 Research Device"))

        let defaults = try patcher.resolveNode(root, path: ["device-tree", "defaults"])
        #expect(Self.value(defaults, "kern.max_task_pmem") == FlatDeviceTreeNode.uint32(3376))
        #expect(Self.value(defaults, "kern.entitled_max_task_pmem") == FlatDeviceTreeNode.uint32(6144))

        #expect(Self.placeholders(root) == [
            "/buttons function-button_ringeren syscfg/rgen",
            "/arm-io/bluetooth local-mac-address syscfg/BMac/6,zeroes/6",
        ])
        #expect(records.filter { $0.patchID == DeviceTreePatcher.syscfgPlaceholdersPatch }.count == 42)
    }

    @Test("Another iPhone without its board tree gets only the jetsam product type, from its board name")
    func resolvesAnotherIPhoneByName() throws {
        let (patcher, root, records) = try Self.resolve(Self.researchTree(), device: .iPhone11_6)
        let resolved = records.filter { $0.patchID == DeviceTreePatcher.syscfgPlaceholdersPatch }
        #expect(resolved.count == 1)
        let product = try patcher.resolveNode(root, path: ["device-tree", "product"])
        #expect(Self.value(product, "jetsam-properties-product-type") == Self.string("D331p"))
        let left = Self.placeholders(root)
        #expect(left.contains("/defaults kern.max_task_pmem syscfg/kmtp"))
        #expect(left.contains("/product product-name syscfg/prde"))
    }

    @Test("A board tree answers the jetsam product type and limits; the variant answers nothing for another device")
    func resolvesFromTheBoard() throws {
        let (_, converted, _) = try Self.convert(Self.researchTree())
        let changes = DeviceTreePatcher.resolveSyscfgPlaceholders(
            in: converted, board: try Self.boardTree(targetType: "D49", maxTaskPmem: 2000), device: .iPhone14_6,
        )
        #expect(Set(changes.map(\.property)) == ["jetsam-properties-product-type", "kern.max_task_pmem"])
        #expect(changes.first { $0.property == "jetsam-properties-product-type" }?.after == Self.string("D49"))
        #expect(changes.first { $0.property == "kern.max_task_pmem" }?.after == FlatDeviceTreeNode.uint32(2000))
        #expect(changes.allSatisfy { $0.source == "D49's device tree" })

        // The board's own property wins over its target type; for the variant's
        // device the board still answers its keys, and the variant the rest.
        let (_, d47, _) = try Self.convert(Self.researchTree())
        let own = DeviceTreePatcher.resolveSyscfgPlaceholders(
            in: d47, board: try Self.boardTree(targetType: "D47", jetsamType: "D47x"), device: .iPhone17_3,
        )
        #expect(own.count == 40)
        #expect(own.first { $0.property == "jetsam-properties-product-type" }?.after == Self.string("D47x"))
        #expect(!own.contains { $0.property.hasPrefix("kern.") })
    }

    @Test("Restore trees, watches and a closed gate keep their placeholders")
    func leavesOthersAlone() throws {
        let (_, restore, restoreRecords) = try Self.resolve(Self.researchTree(), role: .restore)
        #expect(!restoreRecords.contains { $0.patchID == DeviceTreePatcher.syscfgPlaceholdersPatch })
        #expect(Self.placeholders(restore).contains("/product jetsam-properties-product-type syscfg/jppt"))

        let (_, converted, _) = try Self.convert(Self.researchTree())
        #expect(DeviceTreePatcher.resolveSyscfgPlaceholders(in: converted, board: nil, device: .watch7_18).isEmpty)

        let (_, root, records) = try Self.convert(Self.researchTree())
        #expect(!records.contains { $0.patchID == DeviceTreePatcher.syscfgPlaceholdersPatch })
        #expect(Self.placeholders(root).contains("/product jetsam-properties-product-type syscfg/jppt"))
    }

    @Test("A vphone600 tree, or a preset without the set, is left alone")
    func leavesOtherTreesAlone() throws {
        let vphone = Self.researchTree(targetType: "VPHONE600")
        let (_, _, records) = try Self.convert(vphone)
        #expect(records.isEmpty)

        let research = Self.researchTree()
        let (patcher, _, unconverted) = try Self.convert(research, converting: false)
        #expect(unconverted.isEmpty)
        #expect(patcher.patchedData == research)
    }

    // MARK: - Board Target Type

    static let withBoardTargetType = VPhonePatchGate(
        declared: Set((FirmwareResearchBoardPatchSet.manifest.patches + FirmwareDeviceTreePatchSet.manifest.patches).map(\.identifier)),
        enabled: [
            FirmwareResearchBoardPatchSet.deviceTreeConversion,
            DeviceTreePatcher.syscfgPlaceholdersPatch,
            DeviceTreePatcher.boardTargetTypePatch,
        ],
    )

    static func installed(
        _ data: Data,
        device: VPhoneGuestDevice = .iPhone11_6,
        role: DeviceTreePatcher.TreeRole = .installed,
        board: Data? = nil,
        gate: VPhonePatchGate = withBoardTargetType,
    ) throws -> (DeviceTreePatcher, DeviceTreePatcher.DTNode, [PatchRecord]) {
        let patcher = try DeviceTreePatcher(data: data, verbose: false, device: device, role: role, sourceTree: board)
        patcher.gate = gate
        let records = try patcher.findAll()
        return (patcher, try patcher.parsePayload(patcher.patchedData), records)
    }

    @Test("The XS Max's installed tree takes its board's target type, and the jetsam answers with it")
    func presentsTheBoardsTargetType() throws {
        let board = FlatDeviceTreeNode("device-tree", [("target-type", Self.string("D331p"))], children: [
            FlatDeviceTreeNode("defaults", [
                ("kern.max_task_pmem", FlatDeviceTreeNode.uint32(2098)),
                ("kern.entitled_max_task_pmem", FlatDeviceTreeNode.uint32(2348)),
            ]),
        ]).serialized
        let (patcher, root, records) = try Self.installed(Self.researchTree(), board: board)
        #expect(Self.value(root, "target-type") == Self.string("D331p"))
        let record = try #require(records.first { $0.patchID == DeviceTreePatcher.boardTargetTypePatch })
        #expect(record.patchDescription == "Set /device-tree/target-type from iPhone11,6's device tree")
        #expect(records.filter { $0.patchID == DeviceTreePatcher.boardTargetTypePatch }.count == 1)

        let product = try patcher.resolveNode(root, path: ["device-tree", "product"])
        #expect(Self.value(product, "jetsam-properties-product-type") == Self.string("D331p"))
        let defaults = try patcher.resolveNode(root, path: ["device-tree", "defaults"])
        #expect(Self.value(defaults, "kern.max_task_pmem") == FlatDeviceTreeNode.uint32(2098))
        #expect(Self.value(defaults, "kern.entitled_max_task_pmem") == FlatDeviceTreeNode.uint32(2348))

        // Without the board's tree, its name gives the same type.
        let (_, named, namedRecords) = try Self.installed(Self.researchTree())
        #expect(Self.value(named, "target-type") == Self.string("D331p"))
        #expect(namedRecords.first { $0.patchID == DeviceTreePatcher.boardTargetTypePatch }?.patchDescription
            == "Set /device-tree/target-type from the board name d331pap")
    }

    @Test("Restore and shared trees, board-presenting guests, an identity rewrite and a closed gate keep the target type")
    func keepsOtherTargetTypes() throws {
        for role in [DeviceTreePatcher.TreeRole.shared, .restore] {
            let (_, root, records) = try Self.installed(Self.researchTree(), role: role)
            #expect(Self.value(root, "target-type") == Self.string("VPHONE600"))
            #expect(!records.contains { $0.patchID == DeviceTreePatcher.boardTargetTypePatch })
        }
        let (_, closed, closedRecords) = try Self.installed(Self.researchTree(), gate: Self.conversionAndPlaceholders)
        #expect(Self.value(closed, "target-type") == Self.string("VPHONE600"))
        #expect(!closedRecords.contains { $0.patchID == DeviceTreePatcher.boardTargetTypePatch })

        let (_, converted, _) = try Self.convert(Self.researchTree())
        for device in [VPhoneGuestDevice.iPhone17_3, .iPhone14_6, .watch7_18] {
            #expect(DeviceTreePatcher.presentBoardTargetType(in: converted, board: nil, device: device) == nil)
        }
        let property = try #require(converted.properties.first { $0.name == "target-type" })
        property.value = Self.string("D47")
        #expect(DeviceTreePatcher.presentBoardTargetType(in: converted, board: nil, device: .iPhone11_6) == nil)
    }

    // MARK: - Apple's Trees

    static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    static let researchEntry = "Firmware/all_flash/DeviceTree.vresearch101ap.im4p"
    static let vphoneEntry = "Firmware/all_flash/DeviceTree.vphone600ap.im4p"

    /// The cloudOS IPSWs in `ipsws/` with both trees: 26.1 to the 26.4 beta.
    static var pairedIPSWs: [URL] {
        let candidates = (try? FileManager.default.contentsOfDirectory(
            at: repoRoot.appending(path: "ipsws"),
            includingPropertiesForKeys: nil,
        )) ?? []
        return candidates.filter { candidate in
            guard candidate.pathExtension == "ipsw" else { return false }
            let listing = (try? CustomFirmwarePatchFixtures.run("/usr/bin/unzip", ["-l", candidate.path, researchEntry, vphoneEntry]))?.output ?? ""
            return listing.contains(researchEntry) && listing.contains(vphoneEntry)
        }
    }

    /// Every property as `path name flags value`, with phandles left out and
    /// phandle references given as the path they name: the two trees number
    /// their nodes differently.
    static func describe(_ root: DeviceTreePatcher.DTNode) -> Set<String> {
        var paths: [Data: String] = [:]
        var nodes: [(String, DeviceTreePatcher.DTNode)] = []
        func walk(_ node: DeviceTreePatcher.DTNode, _ path: String) {
            nodes.append((path, node))
            if let phandle = value(node, "AAPL,phandle") { paths[phandle] = path }
            var seen: [String: Int] = [:]
            for child in node.children {
                let childName = name(child)
                let index = seen[childName, default: 0]
                seen[childName] = index + 1
                walk(child, path + "/" + childName + (index > 0 ? "#\(index)" : ""))
            }
        }
        walk(root, "")
        let references: Set<String> = ["interrupt-parent", "device-interrupt-parent", "serial-device"]
        var lines = Set<String>()
        for (path, node) in nodes {
            for property in node.properties where property.name != "AAPL,phandle" && property.name != "time-stamp" {
                let shown = references.contains(property.name)
                    ? "-> " + (paths[property.value] ?? "dangling")
                    : property.value.map { String(format: "%02x", $0) }.joined()
                lines.insert("\(path) \(property.name) \(property.flags) \(shown)")
            }
        }
        return lines
    }

    @Test(
        "Apple's research board tree converts into Apple's vphone600 tree of the same release",
        .enabled(if: !pairedIPSWs.isEmpty, "needs a cloudOS IPSW with both device trees in ipsws/"),
    )
    func matchesApplesTree() throws {
        for ipsw in Self.pairedIPSWs {
            let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let result = try CustomFirmwarePatchFixtures.run("/usr/bin/unzip", ["-o", "-j", ipsw.path, Self.researchEntry, Self.vphoneEntry, "-d", directory.path])
            try #require(result.status == 0)

            let research = try IM4PHandler.load(contentsOf: directory.appending(path: "DeviceTree.vresearch101ap.im4p")).payload
            let vphone = try IM4PHandler.load(contentsOf: directory.appending(path: "DeviceTree.vphone600ap.im4p")).payload
            let (_, converted, _) = try Self.convert(research)
            let (_, expected, _) = try Self.convert(vphone)

            let produced = Self.describe(converted)
            let apple = Self.describe(expected)
            #expect(produced.subtracting(apple).sorted() == [], "\(ipsw.lastPathComponent): not in vphone600")
            #expect(apple.subtracting(produced).sorted() == [], "\(ipsw.lastPathComponent): missing from the conversion")
        }
    }

    @Test(
        "On Apple's vphone600 tree the iPhone17,3 answers all but the untagged keys, each with its tag's bytes",
        .enabled(if: !pairedIPSWs.isEmpty, "needs a cloudOS IPSW with both device trees in ipsws/"),
    )
    func resolvesApplesTree() throws {
        for ipsw in Self.pairedIPSWs {
            let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let result = try CustomFirmwarePatchFixtures.run("/usr/bin/unzip", ["-o", "-j", ipsw.path, Self.vphoneEntry, "-d", directory.path])
            try #require(result.status == 0)
            let vphone = try IM4PHandler.load(contentsOf: directory.appending(path: "DeviceTree.vphone600ap.im4p")).payload

            let (patcher, original, _) = try Self.convert(vphone)
            let variant = try patcher.resolveNode(original, path: ["device-tree", "product", "vphone600-gestalt-variants", "d47vm2025vre-variant"])
            var tags: [String: Data] = [:]
            for property in variant.properties where property.name.hasPrefix("tag-") {
                tags[String(property.name.dropFirst(4))] = property.value
            }
            let (resolver, resolved, records) = try Self.resolve(vphone)

            let before = Self.placeholders(original)
            let after = Self.placeholders(resolved)
            // Placeholders other than syscfg ones are the boot chain's alone.
            let syscfg = after.filter { $0.split(separator: " ").last!.hasPrefix("syscfg/") }
            #expect(Set(syscfg.map(Self.key)) == Self.untaggedKeys, "\(ipsw.lastPathComponent)")
            #expect(records.filter { $0.patchID == DeviceTreePatcher.syscfgPlaceholdersPatch }.count == 42)

            // Each resolved property holds its tag's bytes and nothing else changed.
            let changed = Self.describe(resolved).subtracting(Self.describe(original))
            #expect(changed.count == before.count - after.count)
            for line in before.subtracting(after) {
                let parts = line.split(separator: " ")
                let tag = try #require(tags[Self.key(line)])
                let hex = tag.map { String(format: "%02x", $0) }.joined()
                #expect(changed.contains("\(parts[0]) \(parts[1]) 0 \(hex)"), "\(line)")
            }
            let product = try resolver.resolveNode(resolved, path: ["device-tree", "product"])
            #expect(Self.value(product, "jetsam-properties-product-type") == Self.string("D47"))
        }
    }
}

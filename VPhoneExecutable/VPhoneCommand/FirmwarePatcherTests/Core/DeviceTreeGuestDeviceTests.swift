@testable import FirmwarePatcher
import Foundation
import Testing
import VPhoneCoreKit
import VPhonePatchKit

/// The iPad presentation of the vphone600 device tree, against a small tree
/// shaped like the shipped one: the root identity, a `/product` node with
/// `syscfg/` placeholders (flag 0x8000) and a `/buttons` node.
@Suite("Device tree guest device")
struct DeviceTreeGuestDeviceTests {
    // MARK: - Fixture

    struct Property {
        let name: String
        let flags: UInt16
        let value: Data

        static func string(_ name: String, _ text: String, flags: UInt16 = 0) -> Property {
            Property(name: name, flags: flags, value: Data((text + "\0").utf8))
        }

        static func integer(_ name: String, _ number: UInt32) -> Property {
            var little = number.littleEndian
            return Property(name: name, flags: 0, value: Data(bytes: &little, count: 4))
        }

        static func placeholder(_ name: String, _ key: String) -> Property {
            .string(name, "syscfg/\(key)", flags: 0x8000)
        }
    }

    struct Node {
        let properties: [Property]
        let children: [Node]

        func serialized() -> Data {
            var out = Data()
            out.append(littleEndian: UInt32(properties.count))
            out.append(littleEndian: UInt32(children.count))
            for property in properties {
                var name = Data(property.name.utf8)
                name.append(contentsOf: [UInt8](repeating: 0, count: 32 - name.count))
                out.append(name)
                out.append(littleEndian: UInt16(property.value.count))
                out.append(littleEndian: property.flags)
                out.append(property.value)
                let pad = (4 - property.value.count % 4) % 4
                out.append(contentsOf: [UInt8](repeating: 0, count: pad))
            }
            for child in children {
                out.append(child.serialized())
            }
            return out
        }
    }

    static let tree = Node(
        properties: [
            .string("name", "device-tree"),
            .string("model", "iPhone99,11"),
            .string("target-type", "VPHONE600"),
            .string("target-sub-type", "VPHONE600AP"),
            Property(name: "compatible", flags: 0, value: Data("VPHONE600AP\0iPhone99,11\0AppleVirtualPlatformARM\0".utf8)),
            .string("serial-number", "syscfg/SrNm"),
        ],
        children: [
            Node(
                properties: [
                    .string("name", "product"),
                    .string("artwork-device-idiom", "phone"),
                    .placeholder("artwork-device-subtype", "ards"),
                    .placeholder("artwork-scale-factor", "arsf"),
                    .placeholder("island-notch-location", "isnl"),
                    .placeholder("ui-pip", "uipi"),
                    .placeholder("product-name", "prde"),
                    .integer("car-integration", 1),
                    .string("fdr-product-type", "iPhone99,11"),
                    .string("sub-product-type", "iPhone99,11"),
                    .string("unique-model", "VPHONE600AP"),
                    .string("graphics-featureset-class", "APPLE7"),
                ],
                children: [],
            ),
            Node(
                properties: [
                    .string("name", "buttons"),
                    .placeholder("home-button-type", "home"),
                    .placeholder("function-button_ringeren", "rgen"),
                ],
                children: [],
            ),
        ],
    )

    /// vphone600's `/product/haptics`, which no VM can back.
    static let haptics = Node(
        properties: [
            .string("name", "haptics"),
            .integer("closed-loop", 1),
            .integer("supports-3rd-party-haptics", 1),
            .integer("AAPL,phandle", 100),
        ],
        children: [],
    )

    /// `tree` with `/product` children `maps`, then `haptics` when given, then
    /// `util`: the node sits between siblings, as it does on vphone600.
    static func guestTree(haptics: Node?) -> Node {
        let product = tree.children[0]
        let children = [Node(properties: [.string("name", "maps"), .integer("regulatory", 1)], children: [])]
            + (haptics.map { [$0] } ?? [])
            + [Node(properties: [.string("name", "util"), .integer("ramdisk", 0)], children: [])]
        return Node(
            properties: tree.properties,
            children: [Node(properties: product.properties, children: children)] + tree.children.dropFirst(),
        )
    }

    /// A board tree shaped like `DeviceTree.j410ap.im4p`: iPad mini (A17 Pro).
    static func board(
        model: String = "iPad16,1",
        unique: String = "J410AP",
        subtype: UInt32 = 2266,
        disablesStageManager: Bool = true,
    ) -> Node {
        var product: [Property] = [
            .string("name", "product"),
            .string("artwork-device-idiom", "pad"),
            .integer("artwork-device-subtype", subtype),
            .integer("artwork-scale-factor", 2),
            .string("product-name", "iPad"),
            .string("fdr-product-type", model),
            .string("sub-product-type", model),
            .string("unique-model", unique),
            Property(name: "ui-pip", flags: 0, value: Data()),
            .integer("medusa-overlay-app-capability", 1),
            Property(name: "ui-pinned-app", flags: 0, value: Data()),
            // A board placeholder is a syscfg key, not data: not copied, so the
            // vphone600 placeholder it would replace is removed instead.
            .placeholder("product-description", "prde"),
        ]
        if disablesStageManager {
            product.append(.integer("disable-chamois", 1))
        }
        let target = String(unique.dropLast(2))
        return Node(
            properties: [
                .string("name", "device-tree"),
                .string("model", model),
                .string("target-type", target),
                .string("target-sub-type", unique),
                Property(name: "compatible", flags: 0, value: Data("\(unique)\0\(model)\0AppleARM\0".utf8)),
            ],
            children: [
                Node(properties: product, children: []),
                Node(properties: [.string("name", "buttons"), .string("button-names", "volup")], children: []),
            ],
        )
    }

    // MARK: - Reading the result

    /// `node -> property -> (flags, value)` for the two levels the fixture has.
    static func read(_ data: Data) -> [String: [String: (UInt16, Data)]] {
        var result: [String: [String: (UInt16, Data)]] = [:]
        func node(at offset: Int, path: String) -> Int {
            let propertyCount = Int(data.loadLE(UInt32.self, at: offset))
            let childCount = Int(data.loadLE(UInt32.self, at: offset + 4))
            var pos = offset + 8
            var properties: [String: (UInt16, Data)] = [:]
            for _ in 0 ..< propertyCount {
                let nameBytes = data[data.startIndex + pos ..< data.startIndex + pos + 32].prefix { $0 != 0 }
                let name = String(decoding: nameBytes, as: UTF8.self)
                let length = Int(data.loadLE(UInt16.self, at: pos + 32))
                let flags = data.loadLE(UInt16.self, at: pos + 34)
                let start = data.startIndex + pos + 36
                properties[name] = (flags, Data(data[start ..< start + length]))
                pos += 36 + ((length + 3) & ~3)
            }
            let ownName = properties["name"].map { String(decoding: $0.1.prefix { $0 != 0 }, as: UTF8.self) } ?? ""
            let here = path.isEmpty ? ownName : "\(path)/\(ownName)"
            result[here] = properties
            for _ in 0 ..< childCount {
                pos = node(at: pos, path: here)
            }
            return pos
        }
        _ = node(at: 0, path: "")
        return result
    }

    static func string(_ value: (UInt16, Data)?) -> String? {
        value.map { String(decoding: $0.1.prefix { $0 != 0 }, as: UTF8.self) }
    }

    static func integer(_ value: (UInt16, Data)?) -> UInt32? {
        guard let value, value.1.count == 4 else { return nil }
        return value.1.loadLE(UInt32.self, at: 0)
    }

    static func patch(
        device: VPhoneGuestDevice,
        role: DeviceTreePatcher.TreeRole,
        board: Node = board(),
    ) throws -> [String: [String: (UInt16, Data)]] {
        let patcher = DeviceTreePatcher(
            data: tree.serialized(),
            verbose: false,
            includeIdentityPatches: false,
            device: device,
            role: role,
            sourceTree: board.serialized(),
        )
        _ = try patcher.findAll()
        return read(patcher.patchedData)
    }

    /// The trees a guest is patched in: an iPhone guest's one shared tree, and
    /// an iPad guest's installed tree and restore tree.
    enum Guest: CaseIterable, Sendable {
        case iPhone
        case iPad
        case iPadRestore

        var device: VPhoneGuestDevice {
            self == .iPhone ? .default : .iPad16_1
        }

        var role: DeviceTreePatcher.TreeRole {
            switch self {
            case .iPhone: .shared
            case .iPad: .installed
            case .iPadRestore: .restore
            }
        }
    }

    /// Run the patcher on `guest`'s tree, returning the tree it writes and its
    /// records.
    static func patched(
        _ tree: Data,
        as guest: Guest,
        gate: VPhonePatchGate = .unrestricted,
    ) throws -> (data: Data, records: [PatchRecord]) {
        let patcher = DeviceTreePatcher(
            data: tree, verbose: false, device: guest.device, role: guest.role,
            sourceTree: board().serialized(),
        )
        patcher.gate = gate
        let records = try patcher.findAll()
        return (patcher.patchedData, records)
    }

    /// The `name` of each child of the node at `path` in a parsed tree.
    static func childNames(_ node: DeviceTreePatcher.DTNode, at path: [String] = []) -> [String] {
        func name(_ node: DeviceTreePatcher.DTNode) -> String {
            node.properties.first { $0.name == "name" }.map { String(decoding: $0.value.prefix { $0 != 0 }, as: UTF8.self) } ?? ""
        }
        var current = node
        for component in path {
            guard let child = current.children.first(where: { name($0) == component }) else { return [] }
            current = child
        }
        return current.children.map(name)
    }

    // MARK: - Tests

    @Test func `an iPad's installed tree presents the iPad`() throws {
        let tree = try Self.patch(device: .iPad16_1, role: .installed)
        let root = try #require(tree["device-tree"])
        let product = try #require(tree["device-tree/product"])
        let buttons = try #require(tree["device-tree/buttons"])

        #expect(Self.string(root["model"]) == "iPad16,1")
        #expect(Self.string(root["target-type"]) == "J410")
        #expect(Self.string(root["target-sub-type"]) == "J410AP")
        #expect(root["compatible"]?.1 == Data("J410AP\0VPHONE600AP\0AppleVirtualPlatformARM\0".utf8))

        #expect(Self.string(product["artwork-device-idiom"]) == "pad")
        #expect(Self.integer(product["artwork-device-subtype"]) == 2266)
        #expect(Self.integer(product["artwork-scale-factor"]) == 2)
        #expect(product["artwork-scale-factor"]?.0 == 0, "a filled placeholder loses its flag")
        #expect(Self.string(product["product-name"]) == "iPad")
        #expect(product["product-description"] == nil)
        #expect(Self.string(product["sub-product-type"]) == "iPad16,1")
        #expect(Self.string(product["unique-model"]) == "J410AP")
        #expect(product["ui-pip"].map { $0.1.isEmpty && $0.0 == 0 } == true)
        #expect(product["medusa-overlay-app-capability"] != nil)
        #expect(product["ui-pinned-app"]?.1.isEmpty == true)
        #expect(Self.integer(product["disable-chamois"]) == 1)

        #expect(product["island-notch-location"] == nil)
        #expect(product["car-integration"] == nil)
        #expect(buttons["function-button_ringeren"] == nil)

        // The virtual hardware stays as vphone600 describes it.
        #expect(Self.string(product["graphics-featureset-class"]) == "APPLE7")
    }

    @Test func `an iPad's restore tree keeps the board restore expects`() throws {
        let tree = try Self.patch(device: .iPad16_1, role: .restore)
        let root = try #require(tree["device-tree"])
        let product = try #require(tree["device-tree/product"])
        #expect(Self.string(root["model"]) == "iPhone99,11")
        #expect(Self.string(product["artwork-device-idiom"]) == "phone")
        #expect(product["medusa-overlay-app-capability"] == nil)
    }

    @Test func `an iPhone tree is patched as it always was`() throws {
        let shared = try Self.patch(device: .iPhone17_3, role: .shared)
        let product = try #require(shared["device-tree/product"])
        #expect(Self.integer(product["artwork-device-subtype"]) == 2556)
        #expect(Self.integer(product["island-notch-location"]) == 144)
        #expect(Self.string(product["artwork-device-idiom"]) == "phone")

        // A `.installed` role means nothing without an iPad.
        let installed = try Self.patch(device: .iPhone17_3, role: .installed)
        #expect(Self.integer(installed["device-tree/product"]?["island-notch-location"]) == 144)
    }

    @Test func `a 13-inch M-series board keeps Stage Manager and its own identity`() throws {
        let board = Self.board(model: "iPad17,3", unique: "J820AP", subtype: 2752, disablesStageManager: false)
        let tree = try Self.patch(device: .iPad17_3, role: .installed, board: board)
        let root = try #require(tree["device-tree"])
        let product = try #require(tree["device-tree/product"])
        #expect(Self.string(root["model"]) == "iPad17,3")
        #expect(Self.string(root["target-type"]) == "J820")
        #expect(root["compatible"]?.1 == Data("J820AP\0VPHONE600AP\0AppleVirtualPlatformARM\0".utf8))
        #expect(Self.integer(product["artwork-device-subtype"]) == 2752)
        #expect(product["disable-chamois"] == nil)
    }

    @Test func `an iPad's installed tree needs the board's tree`() {
        let patcher = DeviceTreePatcher(
            data: Self.tree.serialized(), verbose: false, device: .iPad16_1, role: .installed,
        )
        #expect(throws: (any Error).self) { try patcher.findAll() }
    }

    @Test func `the iPad edits are declared by the device tree patch set`() throws {
        let declared = Set(FirmwareDeviceTreePatchSet.manifest.patches.map(\.identifier))
        let parser = DeviceTreePatcher(data: Data(), verbose: false)
        let board = try parser.parsePayload(Self.board().serialized())
        let used = try Set(DeviceTreePatcher.guestEdits(from: board).map(\.patchID))
        #expect(!used.isEmpty)
        #expect(used.isSubset(of: declared))
    }

    @Test func `patching an iPad tree twice changes nothing more`() throws {
        let once = DeviceTreePatcher(
            data: Self.tree.serialized(), verbose: false, device: .iPad16_1, role: .installed,
            sourceTree: Self.board().serialized(),
        )
        _ = try once.findAll()
        let twice = DeviceTreePatcher(
            data: once.patchedData, verbose: false, device: .iPad16_1, role: .installed,
            sourceTree: Self.board().serialized(),
        )
        _ = try twice.findAll()
        #expect(twice.patchedData == once.patchedData)
    }

    // MARK: - Haptics

    @Test(arguments: Guest.allCases)
    func `every guest's tree loses the haptics node`(guest: Guest) throws {
        let tree = Self.guestTree(haptics: Self.haptics).serialized()
        let (patched, records) = try Self.patched(tree, as: guest)

        #expect(Self.read(patched)["device-tree/product/haptics"] == nil)
        let parser = DeviceTreePatcher(data: Data(), verbose: false)
        let root = try parser.parsePayload(patched)
        #expect(Self.childNames(root) == ["product", "buttons"])
        #expect(Self.childNames(root, at: ["product"]) == ["maps", "util"])

        // The same tree without the node patches to the same bytes: nothing
        // around it moved, and the length is the node's shorter.
        let (without, _) = try Self.patched(Self.guestTree(haptics: nil).serialized(), as: guest)
        #expect(patched == without)
        #expect(tree.count - Self.guestTree(haptics: nil).serialized().count == Self.haptics.serialized().count)

        let haptics = records.filter { $0.patchID == "devicetree-cfw-product_haptics_node" }
        #expect(haptics.count == 1)
        #expect(haptics.first?.originalBytes == Self.haptics.serialized())
        #expect(haptics.first?.patchedBytes.isEmpty == true)
    }

    @Test(arguments: Guest.allCases)
    func `the haptics node stays when its patch is off`(guest: Guest) throws {
        let declared = Set(FirmwareDeviceTreePatchSet.manifest.patches.map(\.identifier))
        #expect(declared.contains("devicetree-cfw-product_haptics_node"))
        let gate = VPhonePatchGate(declared: declared, enabled: declared.subtracting(["devicetree-cfw-product_haptics_node"]))
        let (patched, records) = try Self.patched(Self.guestTree(haptics: Self.haptics).serialized(), as: guest, gate: gate)

        #expect(!records.contains { $0.patchID == "devicetree-cfw-product_haptics_node" })
        #expect(!records.isEmpty, "the other edits still apply")
        let root = try DeviceTreePatcher(data: Data(), verbose: false).parsePayload(patched)
        #expect(Self.childNames(root, at: ["product"]) == ["maps", "haptics", "util"])
        #expect(Self.integer(Self.read(patched)["device-tree/product/haptics"]?["closed-loop"]) == 1)
    }

    @Test(arguments: Guest.allCases)
    func `removing the haptics node a second time changes nothing`(guest: Guest) throws {
        let (once, _) = try Self.patched(Self.guestTree(haptics: Self.haptics).serialized(), as: guest)
        let (twice, records) = try Self.patched(once, as: guest)
        #expect(twice == once)
        #expect(!records.contains { $0.patchID == "devicetree-cfw-product_haptics_node" })
    }
}

private extension Data {
    mutating func append<T: FixedWidthInteger>(littleEndian value: T) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }
}

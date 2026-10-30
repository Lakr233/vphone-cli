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
        idiom: String = "pad",
        scale: UInt32 = 2,
        appArchitecture: Property? = nil,
    ) -> Node {
        var product: [Property] = [
            .string("name", "product"),
            .string("artwork-device-idiom", idiom),
            .integer("artwork-device-subtype", subtype),
            .integer("artwork-scale-factor", scale),
            .string("product-name", idiom == "tv" ? "Apple TV" : "iPad"),
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
        if let appArchitecture {
            product.append(appArchitecture)
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

    /// J42d's TV idiom, scale and app architecture from the 23L243/23L5208m trees.
    static func tvBoard() -> Node {
        board(model: "AppleTV5,3", unique: "J42dAP", subtype: 0,
              disablesStageManager: false, idiom: "tv", scale: 1,
              appArchitecture: .string("app-macho-architecture", "arm64"))
    }

    /// B520 declares its accessory capabilities through concrete properties;
    /// its artwork values are syscfg placeholders, not a TV panel identity.
    /// Its app architecture remains "arm64" even though 27.0's dyld is arm64e.
    static func homePodBoard(model: String = "AudioAccessory5,1", placeholderCapabilities: Bool = false) -> Node {
        let root = board(model: model, unique: "B520AP", disablesStageManager: false)
        return Node(properties: root.properties, children: [Node(properties: [
            .string("name", "product"),
            .placeholder("artwork-device-idiom", "ardi"),
            .placeholder("artwork-device-subtype", "ards"),
            .placeholder("artwork-scale-factor", "arsf"),
            .string("product-name", "HomePod mini"),
            .string("fdr-product-type", model),
            .string("sub-product-type", model),
            .string("unique-model", "B520AP"),
            Property(name: "product-id", flags: 0, value: Data(base64Encoded: "l2aw/kQAaW9zNqWJvWMfJJjJKt0=")!),
            placeholderCapabilities ? .placeholder("horseman", "hrsm")
                : .integer("horseman", 1),
            placeholderCapabilities ? .placeholder("siri-hub", "shub")
                : Property(name: "siri-hub", flags: 0, value: Data()),
            placeholderCapabilities ? .placeholder("app-macho-architecture", "arch")
                : .string("app-macho-architecture", "arm64"),
        ], children: [])])
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
        case appleTV
        case appleTVRestore

        var device: VPhoneGuestDevice {
            switch self {
            case .iPhone: .default
            case .iPad, .iPadRestore: .iPad16_1
            case .appleTV, .appleTVRestore: .appleTV5_3
            }
        }

        var role: DeviceTreePatcher.TreeRole {
            switch self {
            case .iPhone: .shared
            case .iPad, .appleTV: .installed
            case .iPadRestore, .appleTVRestore: .restore
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
            sourceTree: (guest.device.family == .appleTV ? tvBoard() : board()).serialized(),
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

    @Test(arguments: ["HomeAccessory17,1", "HomeAccessory17,2"])
    func `HomeView copies the home idiom and enables the virtual USB touch driver`(model: String) throws {
        let board = Self.board(model: model, unique: model.hasSuffix("1") ? "J490AP" : "J491AP", subtype: 1088,
                               disablesStageManager: false, idiom: "home", scale: 2,
                               appArchitecture: .string("app-macho-architecture", "arm64"))
        let parser = DeviceTreePatcher(data: board.serialized(), verbose: false)
        let edits = try DeviceTreePatcher.guestEdits(from: parser.parsePayload(board.serialized()))
        #expect(edits.contains { $0.property == "app-macho-architecture" && $0.patchID == DeviceTreePatcher.tvAppArchitecturePatch })
        #expect(edits.contains { $0.property == "supports-driverkit" && $0.patchID == DeviceTreePatcher.homeViewTouchPatch })
        #expect(Set(edits.map(\.patchID)).isSubset(of: Set(FirmwareDeviceTreePatchSet.manifest.patches.map(\.identifier))))
    }

    @Test func `HomePod installed identity copies accessory capabilities and removes placeholder artwork`() throws {
        let originalToken = Data(0..<20)
        let originalProduct = Self.tree.children[0]
        let tree = Node(properties: Self.tree.properties, children: [
            Node(properties: originalProduct.properties + [Property(name: "product-id", flags: 0, value: originalToken)], children: originalProduct.children),
        ] + Self.tree.children.dropFirst())
        let patcher = DeviceTreePatcher(
            data: tree.serialized(), verbose: false, device: .audioAccessory5_1,
            role: .installed, sourceTree: Self.homePodBoard().serialized(),
        )
        let records = try patcher.findAll()
        let installed = Self.read(patcher.patchedData)
        let product = try #require(installed["device-tree/product"])
        #expect(Self.string(installed["device-tree"]?["model"]) == "AudioAccessory5,1")
        #expect(Self.string(installed["device-tree"]?["target-sub-type"]) == "B520AP")
        #expect(Self.string(product["product-name"]) == "HomePod mini")
        for name in ["artwork-device-idiom", "artwork-device-subtype", "artwork-scale-factor"] {
            #expect(product[name] == nil, "\(name) must not retain a syscfg placeholder")
        }
        #expect(Self.integer(product["horseman"]) == 1)
        #expect(product["horseman"]?.0 == 0)
        let hub = try #require(product["siri-hub"])
        #expect(hub.0 == 0 && hub.1.isEmpty)
        #expect(Self.string(product["app-macho-architecture"]) == "arm64")
        #expect(product["app-macho-architecture"]?.0 == 0)
        #expect(product["product-id"]?.1 == originalToken)
        #expect(product["product-id"]?.0 == 0)
        #expect(records.filter { $0.patchID == DeviceTreePatcher.homePodProductPatch }.count == 3)
        #expect(!records.contains { $0.patchID == DeviceTreePatcher.tvAppArchitecturePatch })
        // Restore sees the same virtual board and product as before HomePod support.
        let restore = DeviceTreePatcher(
            data: Self.tree.serialized(), verbose: false, device: .audioAccessory5_1,
            role: .restore, sourceTree: Self.homePodBoard().serialized(),
        )
        let baseline = DeviceTreePatcher(
            data: Self.tree.serialized(), verbose: false, device: .appleTV5_3,
            role: .restore, sourceTree: Self.tvBoard().serialized(),
        )
        let restoreRecords = try restore.findAll()
        _ = try baseline.findAll()
        #expect(restore.patchedData == baseline.patchedData)
        #expect(!restoreRecords.contains { $0.patchID == DeviceTreePatcher.homePodProductPatch })
    }

    @Test func `HomePod capability patch is declared and its gate leaves capabilities untouched`() throws {
        let identifier = DeviceTreePatcher.homePodProductPatch
        let declared = Set(FirmwareDeviceTreePatchSet.manifest.patches.map(\.identifier))
        #expect(declared.contains(identifier))
        let patcher = DeviceTreePatcher(
            data: Self.tree.serialized(), verbose: false, device: .audioAccessory5_1,
            role: .installed, sourceTree: Self.homePodBoard().serialized(),
        )
        patcher.gate = VPhonePatchGate(declared: declared, enabled: declared.subtracting([identifier]))
        let records = try patcher.findAll()
        let product = try #require(Self.read(patcher.patchedData)["device-tree/product"])
        for name in ["horseman", "siri-hub", "app-macho-architecture", "product-id"] {
            #expect(product[name] == nil)
        }
        #expect(!records.contains { $0.patchID == identifier })
    }

    @Test func `HomePod capabilities require the inspected model and concrete donor values`() throws {
        for donor in [Self.homePodBoard(model: "AudioAccessory6,1"), Self.homePodBoard(placeholderCapabilities: true)] {
            let installed = try Self.patch(device: .audioAccessory5_1, role: .installed, board: donor)
            for name in ["horseman", "siri-hub", "app-macho-architecture"] {
                #expect(installed["device-tree/product"]?[name] == nil)
            }
        }
    }

    @Test func `a TV installed tree takes its donor app architecture while restore keeps the virtual board`() throws {
        let (installedData, records) = try Self.patched(Self.tree.serialized(), as: .appleTV)
        let installed = Self.read(installedData)
        #expect(Self.string(installed["device-tree"]?["model"]) == "AppleTV5,3")
        #expect(Self.string(installed["device-tree/product"]?["artwork-device-idiom"]) == "tv")
        #expect(Self.integer(installed["device-tree/product"]?["artwork-scale-factor"]) == 1)
        #expect(Self.string(installed["device-tree/product"]?["app-macho-architecture"]) == "arm64")
        #expect(records.filter { $0.patchID == DeviceTreePatcher.tvAppArchitecturePatch }.count == 1)

        let (restoreData, restoreRecords) = try Self.patched(Self.tree.serialized(), as: .appleTVRestore)
        let restore = Self.read(restoreData)
        #expect(Self.string(restore["device-tree"]?["model"]) == "iPhone99,11")
        #expect(Self.string(restore["device-tree/product"]?["artwork-device-idiom"]) == "phone")
        #expect(restore["device-tree/product"]?["app-macho-architecture"] == nil)
        #expect(!restoreRecords.contains { $0.patchID == DeviceTreePatcher.tvAppArchitecturePatch })
    }

    @Test func `the TV architecture edit is declared and obeys its gate`() throws {
        let declared = Set(FirmwareDeviceTreePatchSet.manifest.patches.map(\.identifier))
        #expect(declared.contains(DeviceTreePatcher.tvAppArchitecturePatch))
        let gate = VPhonePatchGate(declared: declared, enabled: declared.subtracting([DeviceTreePatcher.tvAppArchitecturePatch]))
        let (data, records) = try Self.patched(Self.tree.serialized(), as: .appleTV, gate: gate)
        #expect(Self.read(data)["device-tree/product"]?["app-macho-architecture"] == nil)
        #expect(!records.contains { $0.patchID == DeviceTreePatcher.tvAppArchitecturePatch })
        #expect(Self.string(Self.read(data)["device-tree/product"]?["artwork-device-idiom"]) == "tv")
    }

    @Test func `non-TV board presentation never edits app architecture`() throws {
        let parser = DeviceTreePatcher(data: Data(), verbose: false)
        for idiom in ["phone", "pad"] {
            let source = Self.board(idiom: idiom, appArchitecture: .string("app-macho-architecture", "arm64"))
            let edits = try DeviceTreePatcher.guestEdits(from: parser.parsePayload(source.serialized()))
            #expect(!edits.contains { $0.patchID == DeviceTreePatcher.tvAppArchitecturePatch })
            #expect(!edits.contains { $0.property == "app-macho-architecture" })
        }
    }

    @Test func `a TV board architecture placeholder cannot be copied as data`() throws {
        let source = Self.board(idiom: "tv", appArchitecture: .placeholder("app-macho-architecture", "arch"))
        let parser = DeviceTreePatcher(data: Data(), verbose: false)
        let parsed = try parser.parsePayload(source.serialized())
        #expect(throws: (any Error).self) { try DeviceTreePatcher.guestEdits(from: parsed) }
    }

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

    @Test func `an iPhone17,3 shared tree is patched as it always was`() throws {
        let shared = try Self.patch(device: .iPhone17_3, role: .shared)
        let product = try #require(shared["device-tree/product"])
        #expect(Self.integer(product["artwork-device-subtype"]) == 2556)
        #expect(Self.integer(product["island-notch-location"]) == 144)
        #expect(Self.string(product["artwork-device-idiom"]) == "phone")

        // Its installed tree presents D47AP, as every other board is presented.
        let d47 = Self.board(model: "iPhone17,3", unique: "D47AP", subtype: 2556, disablesStageManager: false, idiom: "phone", scale: 3)
        let installed = try Self.patch(device: .iPhone17_3, role: .installed, board: d47)
        #expect(Self.string(installed["device-tree"]?["model"]) == "iPhone17,3")
        #expect(Self.string(installed["device-tree"]?["target-type"]) == "D47")
        #expect(Self.integer(installed["device-tree/product"]?["artwork-device-subtype"]) == 2556)
    }

    @Test func `an iPhone XS Max keeps the iPhone17,3 presentation with its own artwork and no island`() throws {
        #expect(!VPhoneGuestDevice.iPhone11_6.presentsBoard)
        #expect(VPhoneGuestDevice.named("iPhone11,4") == .iPhone11_6)
        let shared = try Self.patch(device: .iPhone11_6, role: .shared)
        let product = try #require(shared["device-tree/product"])
        #expect(Self.integer(product["artwork-device-subtype"]) == 2688)
        #expect(product["island-notch-location"] == nil)
        #expect(Self.string(product["artwork-device-idiom"]) == "phone")

        let patcher = DeviceTreePatcher(data: Self.tree.serialized(), verbose: false, device: .iPhone11_6, role: .shared)
        let records = try patcher.findAll()
        #expect(records.contains { $0.patchID == "devicetree-cfw-island_notch_location" && $0.patchedBytes.isEmpty })

        // The island patch's gate decides the removal, as it decides the value.
        let gated = DeviceTreePatcher(data: Self.tree.serialized(), verbose: false, device: .iPhone11_6, role: .shared)
        let declared = Set(FirmwareDeviceTreePatchSet.manifest.patches.map(\.identifier))
        gated.gate = VPhonePatchGate(declared: declared, enabled: declared.subtracting(["devicetree-cfw-island_notch_location"]))
        _ = try gated.findAll()
        #expect(Self.read(gated.patchedData)["device-tree/product"]?["island-notch-location"] != nil)
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

    // MARK: - Watch Companion

    @Test(arguments: Guest.allCases)
    func `only an iPhone guest says it pairs with a watch`(guest: Guest) throws {
        let (patched, records) = try Self.patched(Self.tree.serialized(), as: guest)
        let property = Self.read(patched)["device-tree/product"]?["watch-companion"]
        if guest == .iPhone {
            #expect(property?.0 == 0)
            #expect(property?.1 == Data([1, 0, 0, 0]))
            #expect(records.contains { $0.patchID == "devicetree-cfw-watch_companion" })
        } else {
            #expect(!records.contains { $0.patchID == "devicetree-cfw-watch_companion" })
        }
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

    // MARK: - Microphone array

    /// The claims among the properties around them on the D47 audio node.
    static let audio = Node(
        properties: [
            .string("name", "audio"),
            .integer("acoustic-id", 8018),
            .integer("stereo-sound-recording", 1),
            .integer("supports-audio-mix", 1),
            .integer("supports-spatial-audio-capture", 1),
            .integer("supports-spatial-facetime", 1),
        ],
        children: [],
    )

    static let microphoneArrayPatch = "devicetree-cfw-product_audio_microphone_array"

    @Test(arguments: Guest.allCases)
    func `every guest's audio node loses the microphone array claims`(guest: Guest) throws {
        // The node stands where the haptics node does in the other fixture.
        let tree = Self.guestTree(haptics: Self.audio).serialized()
        let (patched, records) = try Self.patched(tree, as: guest)

        let audio = try #require(Self.read(patched)["device-tree/product/audio"])
        #expect(audio["supports-spatial-audio-capture"] == nil)
        #expect(audio["supports-audio-mix"] == nil)
        // Its neighbours stay, the other spatial answer among them.
        #expect(Self.integer(audio["acoustic-id"]) == 8018)
        #expect(Self.integer(audio["stereo-sound-recording"]) == 1)
        #expect(Self.integer(audio["supports-spatial-facetime"]) == 1)

        let removed = records.filter { $0.patchID == Self.microphoneArrayPatch }
        #expect(removed.count == 2)
        #expect(removed.allSatisfy { $0.patchedBytes.isEmpty && $0.originalBytes == Data([1, 0, 0, 0]) })
    }

    @Test(arguments: Guest.allCases)
    func `the claims stay when their patch is off`(guest: Guest) throws {
        let declared = Set(FirmwareDeviceTreePatchSet.manifest.patches.map(\.identifier))
        #expect(declared.contains(Self.microphoneArrayPatch))
        let gate = VPhonePatchGate(declared: declared, enabled: declared.subtracting([Self.microphoneArrayPatch]))
        let (patched, records) = try Self.patched(Self.guestTree(haptics: Self.audio).serialized(), as: guest, gate: gate)

        #expect(!records.contains { $0.patchID == Self.microphoneArrayPatch })
        let audio = try #require(Self.read(patched)["device-tree/product/audio"])
        #expect(Self.integer(audio["supports-spatial-audio-capture"]) == 1)
        #expect(Self.integer(audio["supports-audio-mix"]) == 1)
    }

    @Test(arguments: Guest.allCases)
    func `removing the claims a second time changes nothing`(guest: Guest) throws {
        let (once, _) = try Self.patched(Self.guestTree(haptics: Self.audio).serialized(), as: guest)
        let (twice, records) = try Self.patched(once, as: guest)
        #expect(twice == once)
        #expect(!records.contains { $0.patchID == Self.microphoneArrayPatch })
    }
}

private extension Data {
    mutating func append(littleEndian value: some FixedWidthInteger) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }
}

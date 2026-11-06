// CustomFirmwareBoardAudioTests.swift — an iPad guest takes the board's audio node.
//
// `withBoardAudio` (the Preboot repair) and `DeviceTreePatcher.presentBoardAudio`
// (what `fw patch` runs for an iPad's installed tree) replace `/product/audio`
// with the board tree's. The trees here are built in the flat format the
// restored tree uses, so the parse, the edit and the serialization all run.

@testable import FirmwarePatcher
import Foundation
import Img4tool
import Testing

@Suite("iPad audio node from the board tree")
struct CustomFirmwareBoardAudioTests {
    private typealias Node = FlatDeviceTreeNode

    private static func tree(audio: Node?) -> Data {
        let product = Node(
            "product",
            [("product-name", Data("iPad\0".utf8))],
            children: audio.map { [$0] } ?? [],
        )
        return Node("device-tree", [("model", Data("iPad17,3\0\0".utf8))], children: [
            Node("chosen"),
            product,
        ]).serialized
    }

    /// The D47 node `devicetree-cfw-product_audio_node` adds.
    private static let iPhoneAudio = Node("audio", [
        ("acoustic-id", Node.uint32(8018)),
        ("stereo-sound-recording", Node.uint32(1)),
        ("supports-spatial-audio-capture", Node.uint32(1)),
    ])

    /// J820's, trimmed: its own acoustic ID, a placeholder, and the board's phandle.
    private static let boardAudio = Node("audio", [
        ("AAPL,phandle", Node.uint32(395)),
        ("acoustic-id", Node.uint32(2029)),
        ("speaker-thiele-small", Data("syscfg/SpTS\0".utf8)),
        ("stereo-sound-recording", Node.uint32(1)),
    ], flags: ["speaker-thiele-small": 0x8000])

    /// What the guest's node should become: the board's, without its phandle.
    private static let presentedAudio = Node("audio", [
        ("acoustic-id", Node.uint32(2029)),
        ("speaker-thiele-small", Data("syscfg/SpTS\0".utf8)),
        ("stereo-sound-recording", Node.uint32(1)),
    ], flags: ["speaker-thiele-small": 0x8000])

    // MARK: - Tests

    @Test func `replaces the iPhone node with the board's`() throws {
        let original = Self.tree(audio: Self.iPhoneAudio)
        let board = Self.tree(audio: Self.boardAudio)
        let (patched, changes, delta) = try CustomFirmwarePostRestoreDeviceTree.withBoardAudio(original, board: board)
        #expect(changes.map(\.property) == ["product/audio"])
        #expect(changes.first?.before == "acoustic-id 8018")
        #expect(changes.first?.after.hasPrefix("acoustic-id 2029") == true)
        #expect(patched.count == original.count + delta)
        #expect(patched == Self.tree(audio: Self.presentedAudio))
    }

    @Test func `keeps the guest's own phandle`() throws {
        var iPhone = Self.iPhoneAudio
        iPhone.properties.append(("AAPL,phandle", 0, Node.uint32(77)))
        let (patched, _, _) = try CustomFirmwarePostRestoreDeviceTree.withBoardAudio(
            Self.tree(audio: iPhone),
            board: Self.tree(audio: Self.boardAudio),
        )
        var expected = Self.presentedAudio
        expected.properties.append(("AAPL,phandle", 0, Node.uint32(77)))
        #expect(patched == Self.tree(audio: expected))
    }

    @Test func `adds the node when the guest has none`() throws {
        let original = Self.tree(audio: nil)
        let (patched, changes, delta) = try CustomFirmwarePostRestoreDeviceTree.withBoardAudio(
            original,
            board: Self.tree(audio: Self.boardAudio),
        )
        #expect(changes.first?.before == "acoustic-id none")
        #expect(patched.count == original.count + delta)
        #expect(patched == Self.tree(audio: Self.presentedAudio))
    }

    @Test func `a presented tree is left alone`() throws {
        let board = Self.tree(audio: Self.boardAudio)
        let (once, _, _) = try CustomFirmwarePostRestoreDeviceTree.withBoardAudio(Self.tree(audio: Self.iPhoneAudio), board: board)
        let (twice, changes, delta) = try CustomFirmwarePostRestoreDeviceTree.withBoardAudio(once, board: board)
        #expect(changes.isEmpty)
        #expect(delta == 0)
        #expect(twice == once)
    }

    @Test func `a board without an audio node changes nothing`() throws {
        let original = Self.tree(audio: Self.iPhoneAudio)
        let (patched, changes, _) = try CustomFirmwarePostRestoreDeviceTree.withBoardAudio(
            original,
            board: Self.tree(audio: nil),
        )
        #expect(changes.isEmpty)
        #expect(patched == original)
    }

    @Test func `a truncated tree is refused`() {
        let original = Self.tree(audio: Self.iPhoneAudio)
        #expect(throws: (any Error).self) {
            try CustomFirmwarePostRestoreDeviceTree.withBoardAudio(
                original.prefix(original.count - 4),
                board: Self.tree(audio: Self.boardAudio),
            )
        }
    }
}

@Suite("HomePod donor top-cap metadata")
struct HomePodDisplayMetadataTests {
    private typealias Node = FlatDeviceTreeNode

    // B520AP / AudioAccessory5,1 27.0 (24J361), captured from the physical
    // display node. These bytes are evidence fixtures, not runtime defaults.
    private static let donor: [String: Data] = [
        "MDXCoords": Data(base64Encoded: "KE0AAACAAADXsgAAENgAAK/lAAAQ2AAA2LIAAACAAAApTQAA8CcAAFEaAADwJwAAyFoAAKCNAADYsgAAOKUAAGByAAAoTQAAAIAAAA==")!,
        "MDYCoords": Data(base64Encoded: "ENgAAK/lAAAQ2AAA2LIAAACAAAApTQAA8CcAAFEaAADwJwAAKE0AAACAAADXsgAAOKUAANiyAACgjQAAyFoAAChNAABgcgAAAIAAAA==")!,
        "MDRingCoords": Data(base64Encoded: "AgAAAAIAAAACAAAAAgAAAAIAAAACAAAAAgAAAAIAAAACAAAAAgAAAAIAAAACAAAAAQAAAAEAAAABAAAAAQAAAAEAAAABAAAAAAAAAA==")!,
        "MDBitDepth": Node.uint32(12),
        "MDHWVersion": Node.uint32(3),
    ]

    private static func tree(_ properties: [String: Data]) -> Data {
        Node("device-tree", children: [
            Node("arm-io", children: [
                Node("dockchannel-rtp", children: [
                    Node("rtp-transport", children: [
                        Node("display", properties.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }),
                    ]),
                ]),
            ]),
        ]).serialized
    }

    @Test func `extracts all nineteen LEDs in donor order from raw and IM4P trees`() throws {
        let raw = Self.tree(Self.donor)
        #expect(try DeviceTreePatcher.homePodDisplayProperties(from: raw) == Self.donor)
        let im4p = try IM4P(fourcc: "dtre", description: "HomePod metadata test", payload: raw)
        let extracted = try DeviceTreePatcher.homePodDisplayProperties(from: im4p.data)
        #expect(extracted == Self.donor)
        #expect(extracted["MDXCoords"]?.count == 19 * 4)
    }

    @Test func `requires the physical display node instead of inventing a layout`() {
        #expect(throws: (any Error).self) {
            try DeviceTreePatcher.homePodDisplayProperties(from: Node("device-tree").serialized)
        }
    }

    @Test func `rejects truncated and incompatible donor properties`() {
        for (name, replacement) in [
            ("MDYCoords", Data([0])),
            ("MDXCoords", Node.uint32(0x10001)),
            ("MDBitDepth", Node.uint32(8)),
            ("MDHWVersion", Node.uint32(4)),
        ] {
            var properties = Self.donor
            properties[name] = replacement
            #expect(throws: (any Error).self) {
                try DeviceTreePatcher.homePodDisplayProperties(from: Self.tree(properties))
            }
        }
        var incomplete = Self.donor
        incomplete.removeValue(forKey: "MDRingCoords")
        #expect(throws: (any Error).self) {
            try DeviceTreePatcher.homePodDisplayProperties(from: Self.tree(incomplete))
        }
    }
}

@Suite("HomePod native audio product identity")
struct HomePodAudioProductTests {
    private typealias Node = FlatDeviceTreeNode

    // B520AP / AudioAccessory5,1 27.0 (24J361) /product/product-id.
    // MobileGestalt table row 17 maps these bytes to 0xc79439ac; VirtualAudio
    // maps that to its native enum 4. Runtime code always reads the donor.
    private static let donorID = Data(base64Encoded: "l2aw/kQAaW9zNqWJvWMfJJjJKt0=")!
    private static let virtualID = Data(repeating: 0xA5, count: 20)

    private static func tree(model: String = "AudioAccessory5,1", token: Data? = donorID,
                             flags: UInt16 = 0, acousticID: UInt32 = 0) -> Data {
        var properties: [(String, Data)] = [("graphics-featureset-class", Data("APPLE7\0".utf8))]
        if let token { properties.append(("product-id", token)) }
        return Node("device-tree", [("model", Data((model + "\0").utf8))], children: [
            Node("product", properties, flags: ["product-id": flags], children: [
                Node("audio", [("acoustic-id", Node.uint32(acousticID))]),
            ]),
            Node("arm-io", [("virtual-hardware", Node.uint32(1))]),
        ]).serialized
    }

    @Test func `copies exactly the donor token and leaves virtual audio hardware unchanged`() throws {
        let original = Self.tree(token: Self.virtualID)
        let board = Self.tree(acousticID: 99)
        let (patched, changes, delta) = try CustomFirmwarePostRestoreDeviceTree.withHomePodAudioProduct(original, board: board)
        #expect(patched == Self.tree())
        #expect(delta == 0 && patched.count == original.count)
        #expect(changes.map(\.property) == ["product/product-id"])
        #expect(changes.first?.before == Self.virtualID.map { String(format: "%02x", $0) }.joined())
        #expect(try DeviceTreePatcher.homePodAudioProductID(from: patched) == Self.donorID)
        let (again, noChanges, noDelta) = try CustomFirmwarePostRestoreDeviceTree.withHomePodAudioProduct(patched, board: board)
        #expect(again == patched && noChanges.isEmpty && noDelta == 0)
    }

    @Test func `adds a missing token and clears only its placeholder flag`() throws {
        let board = Self.tree()
        let missing = Self.tree(token: nil)
        let (added, changes, delta) = try CustomFirmwarePostRestoreDeviceTree.withHomePodAudioProduct(missing, board: board)
        #expect(added == board && delta == 56 && changes.first?.before == "absent")
        let placeholder = Self.tree(token: Self.donorID, flags: 0x8000)
        let (filled, flaggedChanges, flaggedDelta) = try CustomFirmwarePostRestoreDeviceTree.withHomePodAudioProduct(placeholder, board: board)
        #expect(filled == board && flaggedChanges.count == 1 && flaggedDelta == 0)
    }

    @Test func `rejects uninspected families malformed and unresolved donor tokens`() throws {
        let original = Self.tree(token: Self.virtualID)
        for donor in [Self.tree(model: "iPhone17,3"), Self.tree(model: "AudioAccessory6,1"),
                      Self.tree(token: nil), Self.tree(token: Data(repeating: 0, count: 19)),
                      Self.tree(token: Data(repeating: 0, count: 21)), Self.tree(flags: 0x8000)] {
            #expect(throws: (any Error).self) {
                try CustomFirmwarePostRestoreDeviceTree.withHomePodAudioProduct(original, board: donor)
            }
            #expect(throws: (any Error).self) { try DeviceTreePatcher.homePodAudioProductID(from: donor) }
        }
        for model in ["iPhone99,11", "iPhone17,3", "AppleTV14,1", "AudioAccessory6,1"] {
            #expect(throws: (any Error).self) {
                try CustomFirmwarePostRestoreDeviceTree.withHomePodAudioProduct(Self.tree(model: model), board: Self.tree())
            }
        }
        let duplicate = Node("device-tree", [("model", Data("AudioAccessory5,1\0".utf8))], children: [
            Node("product", [("product-id", Self.donorID), ("product-id", Self.donorID)]),
        ]).serialized
        #expect(throws: (any Error).self) { try DeviceTreePatcher.homePodAudioProductID(from: duplicate) }
        #expect(throws: (any Error).self) {
            try CustomFirmwarePostRestoreDeviceTree.withHomePodAudioProduct(duplicate, board: Self.tree())
        }
    }

    @Test func `shared repair backup composes audio node and identity independently in both directions`() throws {
        let backup = Self.tree(token: Self.virtualID)
        let board = Self.tree(acousticID: 99)
        let (audioOnly, _, _) = try CustomFirmwarePostRestoreDeviceTree.withBoardAudio(backup, board: board)
        let (both, _, _) = try CustomFirmwarePostRestoreDeviceTree.withHomePodAudioProduct(audioOnly, board: board)
        #expect(both == board)
        // Opt out of identity: rebuild from the same clean inverse and keep the
        // still-selected audio-node repair. No previous repaired output is its own inverse.
        let (identityOff, _, _) = try CustomFirmwarePostRestoreDeviceTree.withBoardAudio(backup, board: board)
        #expect(identityOff == Self.tree(token: Self.virtualID, acousticID: 99))
        let (reenabled, _, _) = try CustomFirmwarePostRestoreDeviceTree.withHomePodAudioProduct(identityOff, board: board)
        #expect(reenabled == both)
        // Opt out of audio-node repair while retaining identity.
        let (audioOff, _, _) = try CustomFirmwarePostRestoreDeviceTree.withHomePodAudioProduct(backup, board: board)
        #expect(audioOff == Self.tree())
        #expect(backup == Self.tree(token: Self.virtualID))
    }

    @Test func `installed IMG4 retains personalized metadata and supports dry run and repeat application`() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("devicetree.img4")
        let donor = directory.appendingPathComponent("donor.im4p")
        let oldPayload = Self.tree(token: Self.virtualID)
        let im4p = try IM4P(fourcc: "dtre", description: "HomePod native identity test", payload: oldPayload).data
        let manifest = DERTestEncoder.element(tag: 0xA0, value: Data(repeating: 0x71, count: 47))
        let restoreInfo = DERTestEncoder.element(tag: 0xA1, value: Data(repeating: 0x29, count: 19))
        let original = DERTestEncoder.sequence([DERTestEncoder.ia5String("IMG4"), im4p, manifest, restoreInfo])
        try original.write(to: target)
        try IM4P(fourcc: "dtre", description: "B520 donor", payload: Self.tree()).data.write(to: donor)
        #expect(try DeviceTreePatcher.homePodAudioProductID(from: Data(contentsOf: donor)) == Self.donorID)
        let dry = try CustomFirmwarePostRestoreDeviceTree.presentHomePodAudioProduct(at: target, board: donor, dryRun: true, verbose: false)
        let afterDryRun = try Data(contentsOf: target)
        #expect(!dry.wrote && dry.changes.count == 1 && afterDryRun == original)
        let applied = try CustomFirmwarePostRestoreDeviceTree.presentHomePodAudioProduct(at: target, board: donor, verbose: false)
        #expect(applied.wrote)
        let output = try Data(contentsOf: target)
        let children = try DERTestEncoder.children(of: output)
        #expect(children[2] == manifest && children[3] == restoreInfo)
        #expect(try IM4P(children[1]).payload() == Self.tree())
        let repeatOutcome = try CustomFirmwarePostRestoreDeviceTree.presentHomePodAudioProduct(at: target, board: donor, verbose: false)
        #expect(!repeatOutcome.wrote && repeatOutcome.changes.isEmpty)
        #expect(try Data(contentsOf: target) == output)
    }
}

@Suite("visionOS virtual display product")
struct VisionOSVirtualProductTests {
    private typealias Node = FlatDeviceTreeNode
    private let generic = Data(base64Encoded: "UT13EFwE1E/xcpFIvIZC6UYOjpc=")!

    private func tree(model: String = "RealityDevice14,1", token: Data? = nil, flags: UInt16 = 0) -> Data {
        Node("device-tree", [("model", Data((model + "\0").utf8)), ("compatible", Data("N301AP\0VPHONE600AP\0".utf8))], children: [
            Node("product", [("product-id", token ?? generic), ("unrelated", Node.uint32(42))], flags: ["product-id": flags]),
            Node("arm-io", [("virtual-hardware", Node.uint32(1))]),
        ]).serialized
    }

    @Test func changesOnlyTheKnownVirtualTokenAndIsIdempotent() throws {
        let before = tree()
        let (after, changes) = try CustomFirmwarePostRestoreDeviceTree.withVisionOSVirtualProduct(before)
        #expect(after == tree(token: CustomFirmwarePostRestoreDeviceTree.visionOSVirtualProductID))
        #expect(after.count == before.count)
        #expect(changes.map(\.property) == ["product/product-id"])
        let (again, noChanges) = try CustomFirmwarePostRestoreDeviceTree.withVisionOSVirtualProduct(after)
        #expect(again == after && noChanges.isEmpty)
    }

    @Test func rejectsOtherFamiliesPhysicalTokensAndMalformedProperties() {
        for bad in [tree(model: "iPhone17,3"), tree(model: "RealityDevice17,1"),
                    tree(token: Data(repeating: 0xa5, count: 20)), tree(token: Data([1])), tree(flags: 0x8000)] {
            #expect(throws: (any Error).self) {
                try CustomFirmwarePostRestoreDeviceTree.withVisionOSVirtualProduct(bad)
            }
        }
    }
}

@Suite("HomePod Cryptex product class")
struct HomePodCryptexClassTests {
    private typealias Node = FlatDeviceTreeNode

    private func tree(model: String = "AudioAccessory5,1", value: Data? = Node.uint32(0xf2), flags: UInt16 = 0) -> Data {
        var properties: [(String, Data)] = [("product-id", Data(repeating: 0xA5, count: 20))]
        if let value { properties.append(("cryptex1-product-class", value)) }
        return Node("device-tree", [("model", Data((model + "\0").utf8))], children: [
            Node("product", properties, flags: ["cryptex1-product-class": flags], children: [
                Node("audio", [("acoustic-id", Node.uint32(99))]),
            ]),
            Node("arm-io", [("virtual-hardware", Node.uint32(1))]),
        ]).serialized
    }

    @Test func `sets only native Cryptex identity and is idempotent`() throws {
        let original = tree()
        let (patched, changes, delta) = try CustomFirmwarePostRestoreDeviceTree.withHomePodCryptexClass(original)
        #expect(patched == tree(value: Node.uint32(0xf4)))
        #expect(patched.count == original.count && delta == 0)
        #expect(changes.map(\.property) == ["product/cryptex1-product-class"])
        let (again, noChanges, noDelta) = try CustomFirmwarePostRestoreDeviceTree.withHomePodCryptexClass(patched)
        #expect(again == patched && noChanges.isEmpty && noDelta == 0)
        let missing = tree(value: nil)
        let (added, addedChanges, addedDelta) = try CustomFirmwarePostRestoreDeviceTree.withHomePodCryptexClass(missing)
        #expect(added == patched && addedDelta == 40 && added.count == missing.count + 40)
        #expect(addedChanges.first?.before == "absent")
    }

    @Test func `rejects other families malformed and unexpected classes`() {
        for malformed in [tree(model: "AppleTV14,1"), tree(value: Data([0xf2])),
                          tree(value: Node.uint32(0xf3)), tree(flags: 0x8000)] {
            #expect(throws: (any Error).self) {
                try CustomFirmwarePostRestoreDeviceTree.withHomePodCryptexClass(malformed)
            }
        }
    }
}

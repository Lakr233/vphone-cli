// CustomFirmwareBoardAudioTests.swift — an iPad guest takes the board's audio node.
//
// `withBoardAudio` (the Preboot repair) and `DeviceTreePatcher.presentBoardAudio`
// (what `fw patch` runs for an iPad's installed tree) replace `/product/audio`
// with the board tree's. The trees here are built in the flat format the
// restored tree uses, so the parse, the edit and the serialization all run.

@testable import FirmwarePatcher
import Foundation
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

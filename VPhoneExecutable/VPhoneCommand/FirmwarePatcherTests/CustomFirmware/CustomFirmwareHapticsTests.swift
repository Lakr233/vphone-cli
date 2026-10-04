// CustomFirmwareHapticsTests.swift — no guest keeps the haptics node.
//
// `withoutHaptics` (the Preboot repair) and `DeviceTreePatcher.removeHaptics`
// (what `fw patch` runs for every guest's tree) remove `/product/haptics`: no
// VM has the actuator or the haptic server it promises, iPhone or iPad. The
// trees here are built in the flat format the restored tree uses, so the
// parse, the edit and the serialization all run.

@testable import FirmwarePatcher
import Foundation
import Testing

@Suite("Haptics node removal")
struct CustomFirmwareHapticsTests {
    private typealias Node = FlatDeviceTreeNode

    /// A tree whose `/product` holds `maps`, then `haptics` when given, then
    /// `util` — the node sits between siblings, as it does on vphone600.
    private static func tree(haptics: Node?) -> Data {
        let product = Node(
            "product",
            [("product-name", Data("iPhone\0".utf8))],
            children: [Node("maps", [("regulatory", Node.uint32(1))])]
                + (haptics.map { [$0] } ?? [])
                + [Node("util", [("ramdisk", Node.uint32(0))])],
        )
        return Node("device-tree", [("model", Data("iPhone99,11\0".utf8))], children: [product]).serialized
    }

    /// What vphone600 carries.
    private static let haptics = Node("haptics", [
        ("closed-loop", Node.uint32(1)),
        ("supports-3rd-party-haptics", Node.uint32(1)),
        ("AAPL,phandle", Node.uint32(100)),
    ])

    // MARK: - Tests

    @Test func `removes the node`() throws {
        let original = Self.tree(haptics: Self.haptics)
        let (patched, changes, delta) = try CustomFirmwarePostRestoreDeviceTree.withoutHaptics(original)
        #expect(changes.map(\.property) == ["product/haptics"])
        #expect(changes.first?.before == "present, \(Self.haptics.serialized.count)B")
        #expect(changes.first?.after == "absent")
        #expect(delta == -Self.haptics.serialized.count)
        #expect(patched.count == original.count + delta)
        // The siblings on either side survive, in order.
        #expect(patched == Self.tree(haptics: nil))
    }

    @Test func `a tree with no node is left alone`() throws {
        let original = Self.tree(haptics: nil)
        let (patched, changes, delta) = try CustomFirmwarePostRestoreDeviceTree.withoutHaptics(original)
        #expect(changes.isEmpty)
        #expect(delta == 0)
        #expect(patched == original)
    }

    @Test func `removing twice changes nothing the second time`() throws {
        let (once, _, _) = try CustomFirmwarePostRestoreDeviceTree.withoutHaptics(Self.tree(haptics: Self.haptics))
        let (twice, changes, _) = try CustomFirmwarePostRestoreDeviceTree.withoutHaptics(once)
        #expect(changes.isEmpty)
        #expect(twice == once)
    }

    @Test func `a haptics node outside product is not touched`() throws {
        let original = Node(
            "device-tree",
            [("model", Data("iPhone99,11\0".utf8))],
            children: [Node("product"), Node("arm-io", children: [Self.haptics])],
        ).serialized
        let (patched, changes, _) = try CustomFirmwarePostRestoreDeviceTree.withoutHaptics(original)
        #expect(changes.isEmpty)
        #expect(patched == original)
    }

    @Test func `a truncated tree is refused`() {
        let original = Self.tree(haptics: Self.haptics)
        #expect(throws: (any Error).self) {
            try CustomFirmwarePostRestoreDeviceTree.withoutHaptics(original.prefix(original.count - 4))
        }
    }
}

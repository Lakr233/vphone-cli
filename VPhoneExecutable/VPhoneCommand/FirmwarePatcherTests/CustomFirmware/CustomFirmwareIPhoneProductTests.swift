// CustomFirmwareIPhoneProductTests.swift — an iPhone guest takes D47AP's product description.
//
// `withPhoneProduct` (the Preboot repair) fills vphone600's `/product`
// placeholders from the board tree, adds the Camera Control and Action Button
// properties vphone600 lacks, and fills `/buttons/function-button_ringeren`.
// The trees here are built in the flat format the restored tree uses, so the
// parse, the edit and the serialization all run.

@testable import FirmwarePatcher
import Foundation
import Testing

@Suite("iPhone product description from the board tree")
struct CustomFirmwareIPhoneProductTests {
    private typealias Node = FlatDeviceTreeNode

    private static let placeholder: UInt16 = 0x8000

    private static func tree(product: Node, buttons: Node) -> Data {
        Node("device-tree", [("model", Data("iPhone17,3\0\0".utf8))], children: [
            Node("chosen"),
            product,
            buttons,
        ]).serialized
    }

    /// vphone600's, trimmed: placeholders, a real value, and a VM-only property.
    private static let guestProduct = Node("product", [
        ("product-name", Data("syscfg/prde\0".utf8)),
        ("assistant", Data("syscfg/assi\0".utf8)),
        ("framebuffer-identifier", Data("syscfg/fbid\0".utf8)),
        ("graphics-featureset-class", Data("APPLE7\0".utf8)),
    ], flags: ["product-name": placeholder, "assistant": placeholder, "framebuffer-identifier": placeholder])

    private static let guestButtons = Node("buttons", [
        ("function-button_ringeren", Data("syscfg/rgen\0".utf8)),
        ("home-button-type", Node.uint32(2)),
    ], flags: ["function-button_ringeren": placeholder])

    /// D47AP's, trimmed: real values, hardware the VM lacks, and its phandle.
    private static let boardProduct = Node("product", [
        ("AAPL,phandle", Node.uint32(363)),
        ("product-name", Data("iPhone 16\0".utf8)),
        ("assistant", Node.uint32(1)),
        ("framebuffer-identifier", Data("A6AC96E7\0".utf8)),
        ("graphics-featureset-class", Data("APPLE9\0".utf8)),
        ("supports-camera-button", Node.uint32(1)),
        ("ringer-button-location", Data(repeating: 7, count: 20)),
        ("nfc-express", Node.uint32(1)),
    ])

    private static let boardButtons = Node("buttons", [
        ("function-button_ringeren", Data("w\0\0\0RntbNIRb".utf8)),
        ("compatible", Data("buttons\0".utf8)),
        ("home-button-type", Node.uint32(2)),
    ])

    /// What the guest's nodes should become.
    private static let presentedProduct = Node("product", [
        ("product-name", Data("iPhone 16\0".utf8)),
        ("assistant", Node.uint32(1)),
        ("framebuffer-identifier", Data("syscfg/fbid\0".utf8)),
        ("graphics-featureset-class", Data("APPLE7\0".utf8)),
        ("ringer-button-location", Data(repeating: 7, count: 20)),
        ("supports-camera-button", Node.uint32(1)),
    ], flags: ["framebuffer-identifier": placeholder])

    private static let presentedButtons = Node("buttons", [
        ("function-button_ringeren", Data("w\0\0\0RntbNIRb".utf8)),
        ("home-button-type", Node.uint32(2)),
    ])

    // MARK: - Tests

    @Test func `fills the placeholders and adds the missing button properties`() throws {
        let original = Self.tree(product: Self.guestProduct, buttons: Self.guestButtons)
        let board = Self.tree(product: Self.boardProduct, buttons: Self.boardButtons)
        let (patched, changes, delta) = try CustomFirmwarePostRestoreDeviceTree.withPhoneProduct(original, board: board)
        #expect(changes.map(\.property) == [
            "product/product-name", "product/assistant",
            "product/ringer-button-location", "product/supports-camera-button",
            "buttons/function-button_ringeren",
        ])
        #expect(changes.first?.before == "syscfg/prde")
        #expect(changes.first?.after == "iPhone 16")
        #expect(changes[2].before == "absent")
        #expect(patched.count == original.count + delta)
        #expect(patched == Self.tree(product: Self.presentedProduct, buttons: Self.presentedButtons))
    }

    @Test func `leaves hardware the VM lacks and the board's phandle alone`() throws {
        let original = Self.tree(product: Self.guestProduct, buttons: Self.guestButtons)
        let board = Self.tree(product: Self.boardProduct, buttons: Self.boardButtons)
        let (patched, _, _) = try CustomFirmwarePostRestoreDeviceTree.withPhoneProduct(original, board: board)
        let text = String(decoding: patched, as: UTF8.self)
        #expect(!text.contains("nfc-express"))
        #expect(!text.contains("A6AC96E7"))
        #expect(!text.contains("APPLE9"))
        #expect(!text.contains("compatible"))
    }

    @Test func `a tree that already has them is unchanged`() throws {
        let presented = Self.tree(product: Self.presentedProduct, buttons: Self.presentedButtons)
        let board = Self.tree(product: Self.boardProduct, buttons: Self.boardButtons)
        let (patched, changes, delta) = try CustomFirmwarePostRestoreDeviceTree.withPhoneProduct(presented, board: board)
        #expect(changes.isEmpty)
        #expect(delta == 0)
        #expect(patched == presented)
    }
}

@Suite("Foldable VM sub-type")
struct CustomFirmwareFoldableVMSubtypeTests {
    private typealias Node = FlatDeviceTreeNode

    private static func tree(subtype: String) -> Data {
        Node("device-tree", [
            ("model", Data("iPhone19,4\0".utf8)),
            ("target-sub-type", Data("\(subtype)\0".utf8)),
            ("target-type", Data("V68\0".utf8)),
        ], children: [Node("product", [("product-name", Data("iPhone\0".utf8))])]).serialized
    }

    @Test func `a foldable board takes Apple's VM sub-type`() throws {
        let original = Self.tree(subtype: "V68AP")
        let (patched, changes, delta) = try CustomFirmwarePostRestoreDeviceTree.withFoldableVMSubtype(original)
        #expect(changes.map(\.property) == ["target-sub-type"])
        #expect(changes.first?.before == "V68AP")
        #expect(changes.first?.after == "V68VM2025")
        #expect(patched.count == original.count + delta)
        #expect(patched == Self.tree(subtype: "V68VM2025"))
    }

    @Test func `other boards and a second run are left alone`() throws {
        for subtype in ["D47AP", "V63AP", "V68VM2025"] {
            let original = Self.tree(subtype: subtype)
            let (patched, changes, delta) = try CustomFirmwarePostRestoreDeviceTree.withFoldableVMSubtype(original)
            #expect(changes.isEmpty)
            #expect(delta == 0)
            #expect(patched == original)
        }
    }
}

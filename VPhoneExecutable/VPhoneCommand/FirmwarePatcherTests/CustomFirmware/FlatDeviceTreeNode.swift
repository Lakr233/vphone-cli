// FlatDeviceTreeNode.swift — device trees for tests, in the flat format a restored tree uses.
//
// Per node: u32 property count, u32 child count, then each property as a
// 32-byte name, u16 length, u16 flags and the value padded to four bytes, then
// each child. Built here so a test runs the patcher's parse, edit and
// serialization on real bytes.

import Foundation

struct FlatDeviceTreeNode {
    var properties: [(name: String, flags: UInt16, value: Data)]
    var children: [FlatDeviceTreeNode] = []

    /// A node called `name`, with `properties` in order after its `name`
    /// property; `flags` gives the ones that are not 0.
    init(
        _ name: String,
        _ properties: [(String, Data)] = [],
        flags: [String: UInt16] = [:],
        children: [FlatDeviceTreeNode] = [],
    ) {
        self.properties = [("name", 0, Data((name + "\0").utf8))]
            + properties.map { ($0.0, flags[$0.0] ?? 0, $0.1) }
        self.children = children
    }

    static func uint32(_ value: UInt32) -> Data {
        withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }

    var serialized: Data {
        var out = Self.uint32(UInt32(properties.count)) + Self.uint32(UInt32(children.count))
        for (name, flags, value) in properties {
            var field = Data(name.utf8)
            field.append(contentsOf: [UInt8](repeating: 0, count: 32 - field.count))
            out.append(field)
            out.append(contentsOf: withUnsafeBytes(of: UInt16(value.count).littleEndian) { Array($0) })
            out.append(contentsOf: withUnsafeBytes(of: flags.littleEndian) { Array($0) })
            out.append(value)
            out.append(contentsOf: [UInt8](repeating: 0, count: (4 - value.count % 4) % 4))
        }
        for child in children {
            out.append(child.serialized)
        }
        return out
    }
}

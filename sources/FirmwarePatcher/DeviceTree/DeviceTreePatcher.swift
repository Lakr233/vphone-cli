// DeviceTreePatcher.swift — DeviceTree payload patcher.
//
// Historical note: derived from the legacy Python firmware patcher during the Swift migration.
//
// Strategy:
//   1. Parse the flat device tree binary into a node/property tree.
//   2. Apply a fixed set of property patches (serial-number, home-button-type,
//      artwork-device-subtype, island-notch-location).
//   3. Serialize the modified tree back to flat binary.

import Foundation

/// Patcher for DeviceTree payloads.
public final class DeviceTreePatcher: Patcher {
    public let component = "devicetree"
    public let verbose: Bool

    /// Whether to apply the 8 identity-rewrite property patches (Tier 1b + 1c)
    /// that flip device identity towards iPhone17,3 / D47AP. Enabled only for
    /// the `.exp` variant; all other variants run the base 4 patches only so
    /// they remain unaffected by the experimental identity rewrites.
    let includeIdentityPatches: Bool

    let buffer: BinaryBuffer
    var patches: [PatchRecord] = []
    var rebuiltData: Data?

    // MARK: - Device Tree Structures

    /// A single property in a device tree node.
    final class DTProperty {
        var name: String
        var length: Int {
            value.count
        }

        var flags: UInt16
        var value: Data
        /// File offset of the property value within the flat binary.
        let valueOffset: Int

        init(name: String, flags: UInt16, value: Data, valueOffset: Int) {
            self.name = name
            self.flags = flags
            self.value = value
            self.valueOffset = valueOffset
        }
    }

    /// A node in the device tree containing properties and child nodes.
    final class DTNode {
        var properties: [DTProperty] = []
        var children: [DTNode] = []
    }

    // MARK: - Init

    public init(data: Data, verbose: Bool = true, includeIdentityPatches: Bool = false) {
        buffer = BinaryBuffer(data)
        self.verbose = verbose
        self.includeIdentityPatches = includeIdentityPatches
    }

    // MARK: - Patcher

    public func findAll() throws -> [PatchRecord] {
        patches = []
        rebuiltData = nil
        let root = try parsePayload(buffer.data)
        try applyPatches(root: root)
        rebuiltData = serializeNode(root)
        return patches
    }

    @discardableResult
    public func apply() throws -> Int {
        if patches.isEmpty, rebuiltData == nil {
            let _ = try findAll()
        }
        // `findAll()` always ends by rebuilding the payload, and node additions are
        // emitted with `fileOffset: 0`, so the rebuilt payload is the only thing that
        // can land on disk.
        if let rebuiltData {
            buffer.data = rebuiltData
        }
        if verbose, !patches.isEmpty {
            print("\n  [\(patches.count) DeviceTree patch(es) applied]")
        }
        return patches.count
    }

    public var patchedData: Data {
        rebuiltData ?? buffer.data
    }

    // MARK: - Parsing

    /// Align a value up to the next 4-byte boundary.
    private static func align4(_ n: Int) -> Int {
        (n + 3) & ~3
    }

    /// Decode a null-terminated C string from raw bytes.
    private static func decodeCString(_ data: Data) -> String {
        if let nullIndex = data.firstIndex(of: 0) {
            let slice = data[data.startIndex ..< nullIndex]
            return String(bytes: slice, encoding: .utf8) ?? ""
        }
        return String(bytes: data, encoding: .utf8) ?? ""
    }

    /// Parse a device tree node from the flat binary at the given offset.
    /// Returns the parsed node and the offset past the end of the node.
    private func parseNode(_ blob: Data, offset: Int) throws -> (DTNode, Int) {
        guard offset + 8 <= blob.count else {
            throw PatcherError.invalidFormat("DeviceTree: truncated node header at offset \(offset)")
        }

        let nProps = blob.loadLE(UInt32.self, at: offset)
        let nChildren = blob.loadLE(UInt32.self, at: offset + 4)
        var pos = offset + 8

        let node = DTNode()

        for _ in 0 ..< nProps {
            guard pos + 36 <= blob.count else {
                throw PatcherError.invalidFormat("DeviceTree: truncated property header at offset \(pos)")
            }

            let nameData = blob[blob.startIndex.advanced(by: pos) ..< blob.startIndex.advanced(by: pos + 32)]
            let name = Self.decodeCString(Data(nameData))
            let length = Int(blob.loadLE(UInt16.self, at: pos + 32))
            let flags = blob.loadLE(UInt16.self, at: pos + 34)
            pos += 36

            guard pos + length <= blob.count else {
                throw PatcherError.invalidFormat("DeviceTree: truncated property value '\(name)' at offset \(pos)")
            }

            let value = Data(blob[blob.startIndex.advanced(by: pos) ..< blob.startIndex.advanced(by: pos + length)])
            let valueOffset = pos
            pos += Self.align4(length)

            node.properties.append(DTProperty(
                name: name,
                flags: flags,
                value: value,
                valueOffset: valueOffset,
            ))
        }

        for _ in 0 ..< nChildren {
            let (child, nextPos) = try parseNode(blob, offset: pos)
            node.children.append(child)
            pos = nextPos
        }

        return (node, pos)
    }

    /// Parse the entire device tree payload.
    private func parsePayload(_ blob: Data) throws -> DTNode {
        let (root, end) = try parseNode(blob, offset: 0)
        guard end == blob.count else {
            throw PatcherError.invalidFormat(
                "DeviceTree: unexpected trailing bytes (\(blob.count - end) extra)",
            )
        }
        return root
    }

    private func serializeNode(_ node: DTNode) -> Data {
        var out = Data()
        out.append(contentsOf: withUnsafeBytes(of: UInt32(node.properties.count).littleEndian) { Data($0) })
        out.append(contentsOf: withUnsafeBytes(of: UInt32(node.children.count).littleEndian) { Data($0) })

        for prop in node.properties {
            var name = Data(prop.name.utf8)
            if name.count >= 32 {
                name = Data(name.prefix(31))
            }
            name.append(contentsOf: [UInt8](repeating: 0, count: 32 - name.count))
            out.append(name)

            out.append(contentsOf: withUnsafeBytes(of: UInt16(prop.length).littleEndian) { Data($0) })
            out.append(contentsOf: withUnsafeBytes(of: prop.flags.littleEndian) { Data($0) })
            out.append(prop.value)

            let pad = Self.align4(prop.length) - prop.length
            if pad > 0 {
                out.append(Data(repeating: 0, count: pad))
            }
        }

        for child in node.children {
            out.append(serializeNode(child))
        }
        return out
    }

    // MARK: - Node Navigation

    /// Get the "name" property value from a node.
    private func nodeName(_ node: DTNode) -> String {
        for prop in node.properties {
            if prop.name == "name" {
                return Self.decodeCString(prop.value)
            }
        }
        return ""
    }

    /// Find a direct child node by name.
    private func findChild(_ node: DTNode, name: String) throws -> DTNode {
        for child in node.children {
            if nodeName(child) == name {
                return child
            }
        }
        throw PatcherError.patchSiteNotFound("DeviceTree: missing child node '\(name)'")
    }

    /// Resolve a node path like ["device-tree", "buttons"] from the root.
    private func resolveNode(_ root: DTNode, path: [String]) throws -> DTNode {
        guard !path.isEmpty, path[0] == "device-tree" else {
            throw PatcherError.patchSiteNotFound("DeviceTree: invalid node path \(path)")
        }
        var node = root
        for name in path.dropFirst() {
            node = try findChild(node, name: name)
        }
        return node
    }

    /// Find a property by name within a node.
    private func findProperty(_ node: DTNode, name: String) throws -> DTProperty {
        for prop in node.properties {
            if prop.name == name {
                return prop
            }
        }
        throw PatcherError.patchSiteNotFound("DeviceTree: missing property '\(name)'")
    }

    // MARK: - Value Encoding

    /// Encode a string value with null termination, padded/truncated to a fixed length.
    private static func encodeFixedString(_ text: String, length: Int) -> Data {
        var raw = Data(text.utf8)
        raw.append(0) // null terminator
        if raw.count > length {
            return Data(raw.prefix(length))
        }
        raw.append(contentsOf: [UInt8](repeating: 0, count: length - raw.count))
        return raw
    }

    /// Encode raw bytes for a property whose layout the caller has prepared
    /// (typically a multi-string NUL-delimited blob like `compatible`).
    /// Truncates if longer than the slot, pads with NULs if shorter.
    private static func encodeFixedBytes(_ data: Data, length: Int) -> Data {
        if data.count > length {
            return Data(data.prefix(length))
        }
        var out = Data(data)
        out.append(contentsOf: [UInt8](repeating: 0, count: length - out.count))
        return out
    }

    /// Encode an integer value as little-endian bytes.
    private static func encodeInteger(_ value: UInt64, length: Int) throws -> Data {
        var data = Data(count: length)
        switch length {
        case 1:
            data[0] = UInt8(value & 0xFF)
        case 2:
            let v = UInt16(value & 0xFFFF)
            data.withUnsafeMutableBytes { $0.storeBytes(of: v.littleEndian, as: UInt16.self) }
        case 4:
            let v = UInt32(value & 0xFFFF_FFFF)
            data.withUnsafeMutableBytes { $0.storeBytes(of: v.littleEndian, as: UInt32.self) }
        case 8:
            data.withUnsafeMutableBytes { $0.storeBytes(of: value.littleEndian, as: UInt64.self) }
        default:
            throw PatcherError.invalidFormat("DeviceTree: unsupported integer length \(length)")
        }
        return data
    }

    // MARK: - Patch Application

    /// Apply all property patches and record each change.
    ///
    /// Always runs `basePropertyPatches`. Additionally runs
    /// `identityPropertyPatches` + `experimentalNodeAdditions` when
    /// `includeIdentityPatches` is true (the `.exp` firmware variant) —
    /// other variants leave the device's identity properties untouched.
    private func applyPatches(root: DTNode) throws {
        var patchesToApply = Self.basePropertyPatches
        if includeIdentityPatches {
            patchesToApply.append(contentsOf: Self.identityPropertyPatches)
        }
        for patch in patchesToApply {
            let node = try resolveNode(root, path: patch.nodePath)
            let prop = try findProperty(node, name: patch.property)

            let originalBytes = Data(prop.value.prefix(patch.length))

            let newValue: Data = switch patch.value {
            case let .string(s):
                Self.encodeFixedString(s, length: patch.length)
            case let .integer(v):
                try Self.encodeInteger(v, length: patch.length)
            case let .bytes(d):
                Self.encodeFixedBytes(d, length: patch.length)
            }

            prop.flags = patch.flags
            prop.value = newValue

            let record = PatchRecord(
                patchID: patch.patchID,
                component: component,
                fileOffset: prop.valueOffset,
                virtualAddress: nil,
                originalBytes: originalBytes,
                patchedBytes: newValue,
                description: patch.description,
            )
            patches.append(record)

            if verbose {
                print(String(
                    format: "  0x%06X: %@ → %@  [%@]",
                    prop.valueOffset,
                    originalBytes.hex,
                    newValue.hex,
                    patch.patchID,
                ))
            }
        }

        if includeIdentityPatches {
            for nodeAdd in Self.experimentalNodeAdditions {
                try applyNodeAddition(root: root, patch: nodeAdd)
            }
        }
    }

    /// Apply a single `AddChildNodePatch`: construct the new `DTNode`,
    /// fill its `name` + caller-supplied properties, attach to the
    /// parent's `children`, and record a `PatchRecord` for the change.
    ///
    /// Skips if a child with the same name already exists under the
    /// parent — keeps the patch idempotent so re-runs against an
    /// already-patched DT don't double-add.
    private func applyNodeAddition(root: DTNode, patch: AddChildNodePatch) throws {
        let parent = try resolveNode(root, path: patch.parentPath)

        for existing in parent.children {
            if nodeName(existing) == patch.nodeName {
                if verbose {
                    print("  -      : /\(patch.parentPath.joined(separator: "/"))/\(patch.nodeName) already present, skipping  [\(patch.patchID)]")
                }
                return
            }
        }

        let newNode = DTNode()

        // The `name` property is mandatory and matches the conventional
        // shape of every other DT node — fixed length = strlen(name)+1.
        let nameValue = Self.encodeFixedString(patch.nodeName, length: patch.nodeName.utf8.count + 1)
        newNode.properties.append(DTProperty(
            name: "name",
            flags: 0,
            value: nameValue,
            valueOffset: 0,
        ))

        for spec in patch.properties {
            let value: Data = switch spec.value {
            case let .string(s):
                Self.encodeFixedString(s, length: spec.length)
            case let .integer(v):
                try Self.encodeInteger(v, length: spec.length)
            case let .bytes(d):
                Self.encodeFixedBytes(d, length: spec.length)
            }
            newNode.properties.append(DTProperty(
                name: spec.name,
                flags: spec.flags,
                value: value,
                valueOffset: 0,
            ))
        }

        parent.children.append(newNode)

        // Serialize the new node so the patch record carries the bytes
        // we conceptually added. fileOffset = 0 because the rebuilt
        // payload is what actually lands on disk (apply() prefers
        // `rebuiltData` over per-record byte writes).
        let serialized = serializeNode(newNode)
        patches.append(PatchRecord(
            patchID: patch.patchID,
            component: component,
            fileOffset: 0,
            virtualAddress: nil,
            originalBytes: Data(),
            patchedBytes: serialized,
            description: patch.description,
        ))

        if verbose {
            print("  +node  : /\(patch.parentPath.joined(separator: "/"))/\(patch.nodeName)  (\(newNode.properties.count) props, \(serialized.count)B)  [\(patch.patchID)]")
        }
    }
}

// CFWPostRestoreDeviceTree.swift — post-restore DT identity rewrite.
//
// Swift port of scripts/patchers/cfw_patch_post_restore_dt.py (EXP-JB-6).
//
// Three root properties of the restored device tree, and only three:
//
//     root/model        "iPhone99,11"  -> "iPhone17,3"
//     root/target-type  "VPHONE600"    -> "D47"
//     root/compatible   ["VPHONE600AP", "iPhone99,11", "AppleVirtualPlatformARM"]
//                       -> ["D47AP", "VPHONE600AP", "AppleVirtualPlatformARM"]
//
// They are restore-time fatal, which is why they are not in
// `DeviceTreePatcher.identityPropertyPatches` with the other eight:
// `restored_external` and iBoot's restore mode cross-check DT root `model`
// and `target-type` against the BuildManifest's signed identity and reject
// the device on mismatch. Both were tried at fw_patch time, both broke
// restore. They are not boot-time fatal — after restore, the iBSS / iBEC /
// LLB `image4_validate_property_callback` bypass accepts any IM4P contents
// — so the install pipeline re-patches the DT offline, on the host-mounted
// restored filesystem, before the device boots into the rootfs.
//
// The `compatible` rewrite is a reorder, not a replacement: VPHONE600AP
// stays in the list, now second, so IOKit's platform-expert binding to
// AppleVMApple1IO still works. The first entry — the one userland reads for
// `hw.model` — becomes D47AP.
//
// Every property keeps its original slot length, so the serialized tree is
// the same size as the one parsed. That is asserted, not assumed.

import Foundation
import Img4tool

/// Rewrites the three restore-fatal identity properties in a
/// `devicetree.img4` (or bare `.im4p`), in place, preserving the container's
/// compression, manifest and restore info.
public enum CFWPostRestoreDeviceTree {
    // MARK: - Targets

    static let targetModel = "iPhone17,3"
    static let targetTargetType = "D47"

    /// The reordered `compatible` body, NUL-delimited, before slot padding.
    static let targetCompatibleBody = Data(
        "D47AP\0VPHONE600AP\0AppleVirtualPlatformARM\0".utf8
    )

    // MARK: - Results

    /// One property rewrite, as the log line describes it.
    public struct Change: Sendable, Equatable {
        public let property: String
        public let before: String
        public let after: String
    }

    /// What a patch attempt did.
    public struct Outcome: Sendable, Equatable {
        public let changes: [Change]
        /// Bytes landed on disk. False when the DT was already in the target
        /// state, or when `dryRun` suppressed the write.
        public let wrote: Bool
        /// Size of the rebuilt container, or the original's when nothing changed.
        public let outputSize: Int
    }

    // MARK: - File-level patching

    /// Patch a `devicetree.img4` (preferred) or bare `devicetree.im4p` in place.
    @discardableResult
    public static func patch(
        at url: URL,
        dryRun: Bool = false,
        verbose: Bool = true
    ) throws -> Outcome {
        let data: Data
        do {
            data = try Data(contentsOfFileToRewrite: url)
        } catch {
            throw PatcherError.fileNotFound(url.path)
        }

        let container = try Container(data)
        let im4p = try IM4P(container.im4pBytes)
        guard im4p.fourcc == "dtre" else {
            throw PatcherError.invalidFormat(
                "expected DT payload (fourcc='dtre'), got fourcc='\(im4p.fourcc)'"
            )
        }
        guard !im4p.isEncrypted else {
            throw PatcherError.invalidFormat("DT payload is encrypted (KBAG present): \(url.path)")
        }

        let compression = try container.payloadCompression()
        let kind = container.isIMG4 ? "IMG4" : "IM4P"
        if verbose {
            print("  [.] \(url.path): \(kind)  desc='\(im4p.description)'  "
                + "payload_compression=\(compression.rawValue)")
        }

        let blob = try im4p.payload()
        // Img4tool finds the uncompressed size in the IM4P's compression-info
        // element rather than in the bvx2 stream, so a container that carries
        // the magic but not the element comes back still compressed. Refuse
        // it: the alternative is parsing compressed bytes as a device tree.
        guard compression == .none || !compression.isStillCompressed(blob) else {
            throw PatcherError.invalidFormat(
                "IM4P payload is \(compression) but did not decompress — no compression-info element?"
            )
        }
        if verbose { print("  [.] DT blob: \(blob.count) bytes") }

        let (newBlob, changes) = try patchedDeviceTree(blob)
        guard !changes.isEmpty else {
            if verbose { print("  [.] \(url.path): DT already in target state — no change") }
            return Outcome(changes: [], wrote: false, outputSize: data.count)
        }
        if verbose {
            for change in changes {
                print("  [+] \(change.property): '\(change.before)' -> '\(change.after)'")
            }
        }
        // Every patch writes into the property's existing slot, so a size
        // change means the parser and the serializer have drifted apart —
        // and an IM4P whose payload no longer matches its recorded
        // uncompressed size will not load.
        guard newBlob.count == blob.count else {
            throw PatcherError.patchVerificationFailed(
                "DT size changed: \(blob.count) -> \(newBlob.count) bytes (would break IM4P offsets)"
            )
        }

        let newIM4P = try IM4P(
            fourcc: im4p.fourcc,
            description: im4p.description,
            payload: newBlob,
            compression: compression.img4toolName
        )
        let output = try container.rebuilt(im4pBytes: newIM4P.data)

        if verbose { print("  [.] output size: \(output.count) bytes (was \(data.count))") }
        if dryRun {
            if verbose { print("  [.] dry-run — not writing back") }
            return Outcome(changes: changes, wrote: false, outputSize: output.count)
        }

        try output.write(to: url)
        if verbose { print("  [+] wrote \(url.path)") }
        return Outcome(changes: changes, wrote: true, outputSize: output.count)
    }

    // MARK: - Device tree patching

    /// Apply the three identity rewrites to a flat device tree blob.
    /// Returns the blob unchanged and no changes when it is already in the
    /// target state.
    public static func patchedDeviceTree(_ blob: Data) throws -> (Data, [Change]) {
        let (root, end) = try parseNode(blob, at: 0)
        guard end == blob.count else {
            throw PatcherError.invalidFormat(
                "DT parse length mismatch: ended at \(end), blob is \(blob.count)"
            )
        }
        guard nodeName(root) == "device-tree" else {
            throw PatcherError.invalidFormat(
                "expected root node 'device-tree', got '\(nodeName(root))'"
            )
        }

        var changes: [Change] = []

        let model = try property(root, named: "model")
        let newModel = encodeFixedString(targetModel, length: model.length)
        if model.value != newModel {
            changes.append(Change(
                property: "model",
                before: cString(model.value),
                after: targetModel
            ))
            model.value = newModel
        }

        let targetType = try property(root, named: "target-type")
        let newTargetType = encodeFixedString(targetTargetType, length: targetType.length)
        if targetType.value != newTargetType {
            changes.append(Change(
                property: "target-type",
                before: cString(targetType.value),
                after: targetTargetType
            ))
            targetType.value = newTargetType
        }

        let compatible = try property(root, named: "compatible")
        guard targetCompatibleBody.count <= compatible.length else {
            throw PatcherError.invalidFormat(
                "compatible body \(targetCompatibleBody.count)B > slot \(compatible.length)B"
            )
        }
        var newCompatible = targetCompatibleBody
        newCompatible.append(
            contentsOf: [UInt8](repeating: 0, count: compatible.length - newCompatible.count)
        )
        if compatible.value != newCompatible {
            changes.append(Change(
                property: "compatible",
                before: "[\(cStringList(compatible.value).joined(separator: ", "))]",
                after: "[D47AP, VPHONE600AP, AppleVirtualPlatformARM]"
            ))
            compatible.value = newCompatible
        }

        guard !changes.isEmpty else { return (blob, []) }
        return (serializeNode(root), changes)
    }

    // MARK: - Flat device tree format
    //
    // Per node: u32 nProps, u32 nChildren, then each property as
    // char[32] name, u16 length, u16 flags, u8[length] value, padded to a
    // 4-byte boundary; then each child node, recursively.
    //
    // The top bit of the length field is XNU's out-of-line "placeholder"
    // flag and is masked off for the real size. `DeviceTreePatcher` parses
    // the same layout at fw_patch time; this is a second reader only because
    // its own parse/serialize pair is file-private. See `integrationNeeded`
    // in the migration notes.

    private static func align4(_ n: Int) -> Int { (n + 3) & ~3 }

    private static func parseNode(
        _ blob: Data,
        at offset: Int
    ) throws -> (DeviceTreePatcher.DTNode, Int) {
        guard offset + 8 <= blob.count else {
            throw PatcherError.invalidFormat("DT truncated at offset 0x\(String(offset, radix: 16))")
        }
        let propertyCount = Int(blob.loadLE(UInt32.self, at: offset))
        let childCount = Int(blob.loadLE(UInt32.self, at: offset + 4))
        var pos = offset + 8
        let node = DeviceTreePatcher.DTNode()

        for _ in 0 ..< propertyCount {
            guard pos + 36 <= blob.count else {
                throw PatcherError.invalidFormat(
                    "DT property header truncated at 0x\(String(pos, radix: 16))"
                )
            }
            let name = cString(slice(blob, pos, 32))
            let length = Int(blob.loadLE(UInt16.self, at: pos + 32) & 0x7FFF)
            let flags = blob.loadLE(UInt16.self, at: pos + 34)
            let valueOffset = pos + 36
            guard valueOffset + length <= blob.count else {
                throw PatcherError.invalidFormat(
                    "DT property value '\(name)' truncated at 0x\(String(valueOffset, radix: 16))"
                )
            }
            node.properties.append(DeviceTreePatcher.DTProperty(
                name: name,
                length: length,
                flags: flags,
                value: slice(blob, valueOffset, length),
                valueOffset: valueOffset
            ))
            pos = valueOffset + align4(length)
        }

        for _ in 0 ..< childCount {
            let (child, next) = try parseNode(blob, at: pos)
            node.children.append(child)
            pos = next
        }
        return (node, pos)
    }

    private static func serializeNode(_ node: DeviceTreePatcher.DTNode) -> Data {
        var out = Data()
        out.append(littleEndian: UInt32(node.properties.count))
        out.append(littleEndian: UInt32(node.children.count))
        for property in node.properties {
            var name = Data(property.name.utf8)
            if name.count >= 32 { name = Data(name.prefix(31)) }
            name.append(contentsOf: [UInt8](repeating: 0, count: 32 - name.count))
            out.append(name)
            out.append(littleEndian: UInt16(property.length))
            out.append(littleEndian: property.flags)
            out.append(property.value)
            let pad = align4(property.length) - property.length
            if pad > 0 { out.append(Data(repeating: 0, count: pad)) }
        }
        for child in node.children {
            out.append(serializeNode(child))
        }
        return out
    }

    private static func nodeName(_ node: DeviceTreePatcher.DTNode) -> String {
        for property in node.properties where property.name == "name" {
            return cString(property.value)
        }
        return ""
    }

    private static func property(
        _ node: DeviceTreePatcher.DTNode,
        named name: String
    ) throws -> DeviceTreePatcher.DTProperty {
        for property in node.properties where property.name == name {
            return property
        }
        throw PatcherError.patchSiteNotFound(
            "property '\(name)' not found in node '\(nodeName(node))'"
        )
    }

    // MARK: - Value helpers

    /// A NUL-terminated string padded (or truncated) to a fixed slot.
    private static func encodeFixedString(_ text: String, length: Int) -> Data {
        var raw = Data(text.utf8)
        raw.append(0)
        if raw.count > length { return Data(raw.prefix(length)) }
        raw.append(contentsOf: [UInt8](repeating: 0, count: length - raw.count))
        return raw
    }

    private static func cString(_ data: Data) -> String {
        let body = data.prefix(while: { $0 != 0 })
        return String(decoding: body, as: UTF8.self)
    }

    /// Split a NUL-delimited multi-string property into its non-empty parts.
    private static func cStringList(_ data: Data) -> [String] {
        data.split(separator: 0, omittingEmptySubsequences: true)
            .map { String(decoding: $0, as: UTF8.self) }
    }

    private static func slice(_ data: Data, _ offset: Int, _ count: Int) -> Data {
        let start = data.startIndex.advanced(by: offset)
        return Data(data[start ..< start.advanced(by: count)])
    }
}

// MARK: - Image4 container

extension CFWPostRestoreDeviceTree {
    /// How the IM4P payload is stored. The raw values are pyimg4's
    /// `Compression` enum, so the log line reads the same either side.
    enum PayloadCompression: Int, Sendable {
        case none = 0
        case lzss = 1
        case lzfse = 2

        var img4toolName: String? {
            switch self {
            case .none: nil
            case .lzss: "lzss"
            case .lzfse: "lzfse"
            }
        }

        var magic: Data? {
            switch self {
            case .none: nil
            case .lzss: Data("complzss".utf8)
            case .lzfse: Data("bvx2".utf8)
            }
        }

        func isStillCompressed(_ payload: Data) -> Bool {
            guard let magic else { return false }
            return payload.starts(with: magic)
        }
    }

    /// An IMG4 or bare IM4P, split so the IM4P can be replaced without
    /// touching anything else.
    ///
    /// For an IMG4 the manifest ([0] IM4M) and restore info ([1] IM4R) are
    /// carried over as their original bytes. pyimg4 re-encodes the IM4M from
    /// its parsed fields instead; preserving the signed bytes verbatim is the
    /// safer of the two, and the difference is invisible for any manifest
    /// that was DER-canonical to begin with.
    struct Container {
        let isIMG4: Bool
        /// Raw DER of the IM4P element.
        let im4pBytes: Data
        /// The IMG4 elements around the IM4P, in order, as raw DER.
        private let leading: Data
        private let trailing: [Data]

        init(_ data: Data) throws {
            let outer = try DER.parse(data, at: 0)
            guard outer.tag == DER.sequence, outer.range.upperBound == data.count else {
                throw PatcherError.invalidFormat("not an Image4 container: trailing or short DER")
            }
            let children = try DER.children(data, of: outer)
            guard let first = children.first, first.tag == DER.ia5String else {
                throw PatcherError.invalidFormat("Image4 container has no type tag")
            }

            switch DER.string(data, first) {
            case "IMG4":
                guard children.count >= 3, children[1].tag == DER.sequence else {
                    throw PatcherError.invalidFormat("IMG4 does not contain an IM4P")
                }
                guard children[2].tag == DER.contextConstructed(0) else {
                    throw PatcherError.invalidFormat("IMG4 does not contain an IM4M")
                }
                isIMG4 = true
                leading = DER.raw(data, first)
                im4pBytes = DER.raw(data, children[1])
                trailing = children[2...].map { DER.raw(data, $0) }
            case "IM4P":
                isIMG4 = false
                leading = Data()
                im4pBytes = data
                trailing = []
            default:
                throw PatcherError.invalidFormat("unrecognized Image4 container type")
            }
        }

        /// Which compression the stored payload uses, sniffed from the
        /// payload's own magic exactly as pyimg4 does.
        func payloadCompression() throws -> PayloadCompression {
            let element = try DER.parse(im4pBytes, at: 0)
            let children = try DER.children(im4pBytes, of: element)
            guard children.count >= 4 else {
                throw PatcherError.invalidFormat("malformed IM4P structure")
            }
            let payload = DER.value(im4pBytes, children[3])
            for candidate in [PayloadCompression.lzss, .lzfse]
                where candidate.isStillCompressed(payload) { return candidate }
            return .none
        }

        /// Reassemble the container around a replacement IM4P.
        func rebuilt(im4pBytes newIM4P: Data) throws -> Data {
            guard isIMG4 else { return newIM4P }
            var body = leading
            body.append(newIM4P)
            for element in trailing { body.append(element) }
            var out = DER.sequenceHeader(bodyCount: body.count)
            out.append(body)
            return out
        }
    }
}

// MARK: - Minimal DER reader
//
// Enough of DER to walk an Image4 container and splice one element: tags
// are single-byte here, lengths are definite. Img4tool's own DER helpers are
// internal to that module, so this stays private to this file.

private enum DER {
    static let sequence: UInt8 = 0x30
    static let ia5String: UInt8 = 0x16

    static func contextConstructed(_ number: UInt8) -> UInt8 { 0xA0 | number }

    struct Element {
        let tag: UInt8
        let valueRange: Range<Int>
        let range: Range<Int>
    }

    static func parse(_ data: Data, at offset: Int) throws -> Element {
        guard offset + 2 <= data.count else {
            throw PatcherError.invalidFormat("DER truncated at \(offset)")
        }
        let tag = data[data.startIndex + offset]
        let lengthByte = data[data.startIndex + offset + 1]
        var cursor = offset + 2
        let length: Int

        if lengthByte & 0x80 == 0 {
            length = Int(lengthByte)
        } else {
            let byteCount = Int(lengthByte & 0x7F)
            guard byteCount > 0, byteCount <= 8, cursor + byteCount <= data.count else {
                throw PatcherError.invalidFormat("DER length field at \(offset) is not definite")
            }
            var accumulated = 0
            for index in 0 ..< byteCount {
                accumulated = (accumulated << 8) | Int(data[data.startIndex + cursor + index])
            }
            length = accumulated
            cursor += byteCount
        }

        guard cursor + length <= data.count else {
            throw PatcherError.invalidFormat("DER element at \(offset) runs past the buffer")
        }
        return Element(
            tag: tag,
            valueRange: cursor ..< (cursor + length),
            range: offset ..< (cursor + length)
        )
    }

    static func children(_ data: Data, of element: Element) throws -> [Element] {
        var out: [Element] = []
        var offset = element.valueRange.lowerBound
        while offset < element.valueRange.upperBound {
            let child = try parse(data, at: offset)
            out.append(child)
            offset = child.range.upperBound
        }
        return out
    }

    static func raw(_ data: Data, _ element: Element) -> Data {
        subdata(data, element.range)
    }

    static func value(_ data: Data, _ element: Element) -> Data {
        subdata(data, element.valueRange)
    }

    static func string(_ data: Data, _ element: Element) -> String {
        String(decoding: value(data, element), as: UTF8.self)
    }

    /// A SEQUENCE tag plus a minimal definite-length header.
    static func sequenceHeader(bodyCount: Int) -> Data {
        var out = Data([sequence])
        if bodyCount < 0x80 {
            out.append(UInt8(bodyCount))
            return out
        }
        var bytes: [UInt8] = []
        var remaining = bodyCount
        while remaining > 0 {
            bytes.append(UInt8(remaining & 0xFF))
            remaining >>= 8
        }
        bytes.reverse()
        out.append(0x80 | UInt8(bytes.count))
        out.append(contentsOf: bytes)
        return out
    }

    private static func subdata(_ data: Data, _ range: Range<Int>) -> Data {
        let start = data.startIndex.advanced(by: range.lowerBound)
        return Data(data[start ..< start.advanced(by: range.count)])
    }
}

// MARK: - Little-endian append

private extension Data {
    mutating func append<T: FixedWidthInteger>(littleEndian value: T) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}

// IM4PHandler.swift — Wrapper around Img4tool for IM4P firmware container handling.

import Foundation
import Img4tool

/// Handles loading, extracting, and re-packaging IM4P firmware containers.
public enum IM4PHandler {
    private static let paypPreservingFourCCs: Set<String> = ["trxm", "krnl"]

    /// Load a firmware file as IM4P or raw data.
    ///
    /// - Parameter url: Path to the firmware file.
    /// - Returns: Tuple of (extracted payload data, original IM4P if applicable).
    public static func load(contentsOf url: URL) throws -> (payload: Data, im4p: IM4P?) {
        // READ, not mapped, and the asymmetry is deliberate. `save` writes the
        // patched container back over the same path this loaded from — see
        // `FirmwarePipeline.ContainerFirmwareLoader`, whose `save` re-loads the
        // original to keep its metadata and then writes to that very url. A
        // mapping of a file being replaced is a SIGBUS on the next fault; see
        // InPlaceRewrite.swift.
        let fileData = try Data(contentsOfFileToRewrite: url)

        // Try to parse as IM4P first
        if let im4p = try? IM4P(fileData) {
            let payload = try im4p.payload()
            return (payload, im4p)
        }

        // Fall back to raw data
        return (fileData, nil)
    }

    /// Save patched data back to an IM4P container or as raw data.
    ///
    /// If the original was IM4P, re-packages with the same fourcc and LZFSE compression.
    /// Otherwise, writes raw bytes.
    ///
    /// - Parameters:
    ///   - patchedData: The patched payload bytes.
    ///   - originalIM4P: The original IM4P container (nil for raw files).
    ///   - url: Output file path.
    public static func save(
        patchedData: Data,
        originalIM4P: IM4P?,
        to url: URL,
    ) throws {
        if let original = originalIM4P {
            // Rebuild the IM4P container with the patched payload. Do not force
            // a new compression mode here; the Python pipeline currently writes
            // these patched payloads back uncompressed and preserves any PAYP
            // metadata tail from the original container.
            let newIM4P = try IM4P(
                fourcc: original.fourcc,
                description: original.description,
                payload: patchedData,
            )
            let output: Data = if paypPreservingFourCCs.contains(original.fourcc) {
                try appendPAYPIfPresent(from: original.data, to: newIM4P.data)
            } else {
                newIM4P.data
            }
            try output.write(to: url)
        } else {
            try patchedData.write(to: url)
        }
    }

    private static func appendPAYPIfPresent(from original: Data, to rebuilt: Data) throws -> Data {
        let marker = Data("PAYP".utf8)
        guard let markerRange = original.range(of: marker, options: .backwards),
              markerRange.lowerBound >= 10
        else {
            return rebuilt
        }

        let payp = original[(markerRange.lowerBound - 10) ..< original.endIndex]
        var output = rebuilt
        try updateTopLevelDERLength(of: &output, adding: payp.count)
        output.append(payp)
        return output
    }

    private static func updateTopLevelDERLength(of data: inout Data, adding extraBytes: Int) throws {
        guard data.count >= 2, data[0] == 0x30 else {
            throw Img4Error.invalidFormat("rebuilt IM4P missing top-level DER sequence")
        }

        let lengthByte = data[1]
        let headerRange: Range<Int>
        let currentLength: Int

        if lengthByte & 0x80 == 0 {
            headerRange = 1 ..< 2
            currentLength = Int(lengthByte)
        } else {
            let lengthOfLength = Int(lengthByte & 0x7F)
            let start = 2
            let end = start + lengthOfLength
            guard end <= data.count else {
                throw Img4Error.invalidFormat("invalid DER length field")
            }
            headerRange = 1 ..< end
            currentLength = data[start ..< end].reduce(0) { ($0 << 8) | Int($1) }
        }

        let replacement = derLengthBytes(currentLength + extraBytes)
        data.replaceSubrange(headerRange, with: replacement)
    }

    private static func derLengthBytes(_ length: Int) -> Data {
        precondition(length >= 0)
        if length < 0x80 {
            return Data([UInt8(length)])
        }

        var value = length
        var encoded: [UInt8] = []
        while value > 0 {
            encoded.append(UInt8(value & 0xFF))
            value >>= 8
        }
        encoded.reverse()
        return Data([0x80 | UInt8(encoded.count)] + encoded)
    }
}

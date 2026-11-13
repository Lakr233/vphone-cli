// IM4PHandler.swift — Wrapper around Img4tool for IM4P firmware container handling.

import Foundation
import Img4tool

/// Handles loading, extracting, and re-packaging IM4P firmware containers.
public enum IM4PHandler {
    /// Their `PAYP` properties (`arms`/`tz0s` for the SEP) describe how the
    /// image is loaded, so a rebuilt container keeps them.
    private static let paypPreservingFourCCs: Set<String> = ["trxm", "sptm", "krnl", "sepi"]
    /// Written back LZFSE-compressed: the image the boot ROM decodes itself.
    static let lzfseFourCCs: Set<String> = ["ibss"]

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
            //
            // iBSS is the exception: the boot ROM unpacks it, and OpenAVB
            // decodes only LZFSE (Apple's AVPBooter takes either), so it goes
            // back compressed the way Apple ships it.
            let newIM4P = try IM4P(
                fourcc: original.fourcc,
                description: original.description,
                payload: patchedData,
                compression: lzfseFourCCs.contains(original.fourcc) ? "lzfse" : nil,
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
        guard let start = paypStart(in: original) else {
            return rebuilt
        }

        let payp = original[start ..< original.endIndex]
        var output = rebuilt
        try updateTopLevelDERLength(of: &output, adding: payp.count)
        output.append(payp)
        return output
    }

    /// Where the `[0]` element carrying the `PAYP` properties starts: the one
    /// whose DER length runs exactly to the end of the container. Its headers
    /// (`A0 len`, `30 len`, `16 04`) take 10 bytes with two-byte lengths (TXM,
    /// kernel) and 6 with short ones (SEP).
    static func paypStart(in data: Data) -> Int? {
        guard let marker = data.range(of: Data("PAYP".utf8), options: .backwards) else { return nil }
        for start in stride(from: marker.lowerBound - 6, through: max(data.startIndex, marker.lowerBound - 16), by: -1) {
            guard data[start] == 0xA0,
                  let (length, size) = derLength(in: data, at: start + 1),
                  start + 1 + size + length == data.endIndex
            else { continue }
            return start
        }
        return nil
    }

    /// A DER length at `index`, and how many bytes it takes.
    private static func derLength(in data: Data, at index: Int) -> (length: Int, size: Int)? {
        guard index < data.endIndex else { return nil }
        let first = data[index]
        if first & 0x80 == 0 {
            return (Int(first), 1)
        }
        let count = Int(first & 0x7F)
        guard (1 ... 4).contains(count), index + count < data.endIndex else { return nil }
        return (data[index + 1 ... index + count].reduce(0) { ($0 << 8) | Int($1) }, 1 + count)
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

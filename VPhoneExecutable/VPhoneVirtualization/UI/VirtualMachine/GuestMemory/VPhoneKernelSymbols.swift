import Compression
import Foundation

// MARK: - Kernel Symbols

/// The few kernel symbols the host needs to read a guest's process list,
/// taken from the symbol map of the kernel the guest booted.
///
/// Every kernel a guest can boot has a map in `kernelcache_recipes`: research
/// board bases (`bases/`), the vphone600 kernels of the beta cloudOS
/// (`donors/`, `kernels/`). Each manifest names the kernel's LC_UUID
/// (`kernelUUID`) and its segments (`kernelSegments`) in the map's address
/// space. A mixed kernelcache moves the kernel's segments, so an address is
/// carried over as segment plus offset.
struct VPhoneKernelSymbols {
    struct Segment {
        let name: String
        let address: UInt64
        let size: UInt64
    }

    enum Failure: LocalizedError, CustomStringConvertible {
        case noRecipes
        case unknownKernel(String)
        case unreadableMap(String)
        case missingSymbol(String, String)

        var errorDescription: String? {
            switch self {
            case .noRecipes:
                "This VPhone.bundle has no kernelcache recipes."
            case let .unknownKernel(uuid):
                "No symbol map matches the guest's kernel (UUID \(uuid))."
            case let .unreadableMap(id):
                "The symbol map of \(id) cannot be read."
            case let .missingSymbol(name, id):
                "The symbol map of \(id) has no \(name)."
            }
        }

        var description: String { errorDescription ?? "kernel symbols unavailable" }
    }

    /// The recipe directory, such as `27.2_24B119`.
    let id: String
    let segments: [Segment]
    let addresses: [String: UInt64]

    static let required = ["_kernproc", "_kernel_pmap"]

    static var recipesDirectory: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("kernelcache_recipes", isDirectory: true)
    }

    /// The map whose manifest names `kernelUUID`.
    static func load(kernelUUID: String, root: URL? = recipesDirectory) throws -> VPhoneKernelSymbols {
        guard let root else { throw Failure.noRecipes }
        let manager = FileManager.default
        for group in ["bases", "kernels", "donors"] {
            let directory = root.appendingPathComponent(group, isDirectory: true)
            let entries = (try? manager.contentsOfDirectory(atPath: directory.path)) ?? []
            for entry in entries.sorted() {
                let folder = directory.appendingPathComponent(entry, isDirectory: true)
                guard let data = try? Data(contentsOf: folder.appendingPathComponent("manifest.json")),
                      let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      (manifest["kernelUUID"] as? String)?.uppercased() == kernelUUID.uppercased(),
                      let segmentTable = manifest["kernelSegments"] as? [String: [NSNumber]]
                else { continue }
                let segments = segmentTable.compactMap { name, pair -> Segment? in
                    guard pair.count == 2 else { return nil }
                    return Segment(name: name, address: pair[0].uint64Value, size: pair[1].uint64Value)
                }
                let mapName = manifest["symbols"] as? String ?? "symbols.json.gz"
                let addresses = try symbolAddresses(
                    required, map: folder.appendingPathComponent(mapName), id: entry,
                )
                return VPhoneKernelSymbols(id: entry, segments: segments, addresses: addresses)
            }
        }
        throw Failure.unknownKernel(kernelUUID)
    }

    /// The segment-relative position of a symbol: segment name and offset.
    func location(of name: String) throws -> (segment: String, offset: UInt64) {
        guard let address = addresses[name] else { throw Failure.missingSymbol(name, id) }
        guard let segment = segments.first(where: { $0.address <= address && address < $0.address + $0.size }) else {
            throw Failure.missingSymbol(name, id)
        }
        return (segment.name, address - segment.address)
    }

    // MARK: - Map

    /// Reads `symbols.json.gz`, decimal address to a name or list of names,
    /// keeping only `names`.
    static func symbolAddresses(_ names: [String], map: URL, id: String) throws -> [String: UInt64] {
        guard let compressed = try? Data(contentsOf: map),
              let json = gunzip(compressed),
              let table = try? JSONSerialization.jsonObject(with: json) as? [String: Any]
        else { throw Failure.unreadableMap(id) }
        let wanted = Set(names)
        var result: [String: UInt64] = [:]
        for (key, value) in table {
            let labels = (value as? [String]) ?? [(value as? String)].compactMap(\.self)
            for label in labels where wanted.contains(label) && result[label] == nil {
                if let address = UInt64(key) { result[label] = address }
            }
        }
        for name in names where result[name] == nil {
            throw Failure.missingSymbol(name, id)
        }
        return result
    }

    /// Inflates a gzip file (RFC 1952): the Compression framework's ZLIB
    /// algorithm is raw DEFLATE, so the header and trailer are stepped over.
    static func gunzip(_ data: Data) -> Data? {
        let bytes = [UInt8](data)
        guard bytes.count > 18, bytes[0] == 0x1F, bytes[1] == 0x8B, bytes[2] == 8 else { return nil }
        let flags = bytes[3]
        var offset = 10
        if flags & 0x04 != 0 {  // FEXTRA
            guard offset + 2 <= bytes.count else { return nil }
            offset += 2 + (Int(bytes[offset]) | Int(bytes[offset + 1]) << 8)
        }
        for flag in [UInt8(0x08), 0x10] where flags & flag != 0 {  // FNAME, FCOMMENT
            while offset < bytes.count, bytes[offset] != 0 { offset += 1 }
            offset += 1
        }
        if flags & 0x02 != 0 { offset += 2 }  // FHCRC
        guard offset < bytes.count - 8 else { return nil }
        let expected = Int(bytes[bytes.count - 4]) | Int(bytes[bytes.count - 3]) << 8
            | Int(bytes[bytes.count - 2]) << 16 | Int(bytes[bytes.count - 1]) << 24
        var output = Data(count: max(expected, 1))
        let written = output.withUnsafeMutableBytes { destination in
            bytes[offset ..< bytes.count - 8].withUnsafeBytes { source in
                compression_decode_buffer(
                    destination.bindMemory(to: UInt8.self).baseAddress!, destination.count,
                    source.bindMemory(to: UInt8.self).baseAddress!, source.count,
                    nil, COMPRESSION_ZLIB,
                )
            }
        }
        // The trailer's size is modulo 2^32; the maps are far smaller.
        guard written == expected else { return nil }
        output.count = written
        return output
    }
}

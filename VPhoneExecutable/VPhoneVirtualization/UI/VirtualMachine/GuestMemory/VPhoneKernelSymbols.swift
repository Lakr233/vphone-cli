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
    /// Read when the map has them: the accessors whose code says where a
    /// thread keeps its ID, TSD pointer and name (`VPhoneGuestThreads`).
    static let optional = ["_thread_tid", "_thread_dispatchqaddr", "_thread_has_thread_name"]

    static var recipesDirectory: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("kernelcache_recipes", isDirectory: true)
    }

    /// What has been read, by recipes folder: the manifests' kernel UUIDs, and
    /// each map once it is used. A map is unzipped and parsed once per process,
    /// so later dumps of a guest pause it for less time, and a kernel UUID
    /// without a map is refused without reading anything.
    private static let cache = Cache()

    private struct Entry {
        let id: String
        let folder: URL
        let segments: [Segment]
        let mapName: String
    }

    private final class Cache: @unchecked Sendable {
        private let lock = NSLock()
        private var indexes: [String: [String: Entry]] = [:]
        private var maps: [String: VPhoneKernelSymbols] = [:]

        func index(_ root: URL) -> [String: Entry] {
            if let hit = lock.withLock({ indexes[root.path] }) { return hit }
            let index = VPhoneKernelSymbols.readIndex(root)
            lock.withLock { indexes[root.path] = index }
            return index
        }

        func map(_ key: String, _ make: () throws -> VPhoneKernelSymbols) throws -> VPhoneKernelSymbols {
            if let hit = lock.withLock({ maps[key] }) { return hit }
            let value = try make()
            lock.withLock { maps[key] = value }
            return value
        }
    }

    /// Whether a recipe names `kernelUUID`; reads only the manifests, once.
    static func hasMap(kernelUUID: String, root: URL? = recipesDirectory) -> Bool {
        guard let root else { return false }
        return cache.index(root)[kernelUUID.uppercased()] != nil
    }

    /// The map whose manifest names `kernelUUID`.
    static func load(kernelUUID: String, root: URL? = recipesDirectory) throws -> VPhoneKernelSymbols {
        guard let root else { throw Failure.noRecipes }
        guard let entry = cache.index(root)[kernelUUID.uppercased()] else {
            throw Failure.unknownKernel(kernelUUID)
        }
        return try cache.map("\(kernelUUID.uppercased())|\(root.path)") {
            let addresses = try symbolAddresses(
                required, optional: optional, map: entry.folder.appendingPathComponent(entry.mapName), id: entry.id,
            )
            return VPhoneKernelSymbols(id: entry.id, segments: entry.segments, addresses: addresses)
        }
    }

    /// Kernel UUID (uppercase) to its recipe, from every manifest that has
    /// `kernelUUID` and `kernelSegments`; the first in `bases`, `kernels`,
    /// `donors` order wins.
    private static func readIndex(_ root: URL) -> [String: Entry] {
        let manager = FileManager.default
        var index: [String: Entry] = [:]
        for group in ["bases", "kernels", "donors"] {
            let directory = root.appendingPathComponent(group, isDirectory: true)
            let entries = (try? manager.contentsOfDirectory(atPath: directory.path)) ?? []
            for entry in entries.sorted() {
                let folder = directory.appendingPathComponent(entry, isDirectory: true)
                guard let data = try? Data(contentsOf: folder.appendingPathComponent("manifest.json")),
                      let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let uuid = (manifest["kernelUUID"] as? String)?.uppercased(),
                      let segmentTable = manifest["kernelSegments"] as? [String: [NSNumber]],
                      index[uuid] == nil
                else { continue }
                let segments = segmentTable.compactMap { name, pair -> Segment? in
                    guard pair.count == 2 else { return nil }
                    return Segment(name: name, address: pair[0].uint64Value, size: pair[1].uint64Value)
                }
                index[uuid] = Entry(
                    id: entry, folder: folder, segments: segments,
                    mapName: manifest["symbols"] as? String ?? "symbols.json.gz",
                )
            }
        }
        return index
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
    /// keeping only `names`, which must be there, and `optional`.
    static func symbolAddresses(
        _ names: [String], optional: [String] = [], map: URL, id: String,
    ) throws -> [String: UInt64] {
        guard let compressed = try? Data(contentsOf: map),
              let json = gunzip(compressed),
              let table = try? JSONSerialization.jsonObject(with: json) as? [String: Any]
        else { throw Failure.unreadableMap(id) }
        let wanted = Set(names + optional)
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

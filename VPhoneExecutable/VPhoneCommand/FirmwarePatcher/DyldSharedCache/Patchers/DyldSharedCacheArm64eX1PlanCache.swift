// DyldSharedCacheArm64eX1PlanCache.swift — Whole-cache X1 plans kept on the host.

import CryptoKit
import Foundation
import MachO
import VPhoneCoreKit
import VPhonePatchKit

/// The X1 lowering's plans, kept in the invoking user's data root so the next
/// machine restored from the same build does not plan again.
///
/// Planning is what the lowering costs: a decode-driven walk of every cache
/// image took 38 s of the 43 s whole-cache pass on the iPhone19,4 27.2 cache
/// (M5 Pro), against under 5 s to write and re-attest its 25 million
/// rewrites. Its result depends only on the bytes it reads and on the code
/// that reads them, and the key holds both:
///
/// * every chunk's name, size and code directory. The slots hash every page
///   of the chunk, and every cache patch here re-attests what it writes, so a
///   changed page is a changed key. The bootstrap pass and an earlier patch
///   are therefore part of what the whole-cache pass is keyed on.
/// * the LC_UUID of the image holding the planner and of VPhonePatchKit,
///   which holds Capstone and the replacement table. Any rebuild of either
///   plans again, so a planner change can never meet an old plan.
/// * the patch identifier, which decides the images the pass selects.
///
/// A chunk without a code directory leaves the pass uncached. Plans are never
/// evicted; each is one file of tens of megabytes per build and planner, and
/// the directory can be removed at any time.
public struct DyldSharedCacheArm64eX1PlanCache: Sendable {
    typealias ImagePlan = DyldSharedCacheArm64eX1BootstrapPatcher.ImagePlan
    typealias Write = DyldSharedCacheArm64eX1BootstrapPatcher.Write

    /// One selected image's outcome: its writes, or why the planner gave up
    /// on it (the whole-cache pass leaves such an image to the on-demand
    /// handler and says so).
    enum Image {
        case planned(ImagePlan)
        case skipped(String)
    }

    /// A skipped image's error as the planner described it, replayed.
    struct ReplayedError: Error, CustomStringConvertible {
        let description: String
    }

    static let formatVersion: UInt32 = 1
    static let magic = Data("VPX1PLAN".utf8)

    public let root: URL

    public init(root: URL = VPhoneResources.userDataRoot().appending(path: "x1-plans")) {
        self.root = root
    }

    // MARK: - Key

    /// The plan's file name. Throws, and the pass plans as before, when this
    /// build or cache cannot be keyed.
    static func key(for chunks: DyldSharedCacheChunkSet, patchID: String) throws -> String {
        guard let planner = imageUUID(header: #dsohandle),
              let patchKit = imageUUID(containing: unsafeBitCast(ARM64Disassembler.self as AnyClass, to: UnsafeRawPointer.self))
        else { throw PatcherError.invalidFormat("the planner's images carry no LC_UUID") }
        var hasher = SHA256()
        func add(_ text: String) {
            hasher.update(data: Data(text.utf8))
            hasher.update(data: Data([0]))
        }
        add("x1-plan \(formatVersion)")
        add(patchID)
        add(planner)
        add(patchKit)
        let mapped = Set(chunks.mappings.map(\.chunkURL))
        // A file with no mapping (the `.atlas`) holds no address the planner
        // can read, so it is not part of the key.
        for url in chunks.chunkURLs where mapped.contains(url) {
            let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int ?? -1
            add(url.lastPathComponent)
            add(String(size))
            guard let directory = try DyldSharedCacheCodeSignature.readCodeDirectory(ofChunk: url) else {
                // No slots to stand for its pages: the pages themselves.
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                while let block = try autoreleasepool(invoking: { try handle.read(upToCount: 4 << 20) }), !block.isEmpty {
                    hasher.update(data: block)
                }
                continue
            }
            let blob = try DyldSharedCacheChunkSet.read(
                url: url, offset: UInt64(directory.blobOffset), length: directory.blobLength,
            )
            guard blob.count == directory.blobLength else {
                throw PatcherError.invalidFormat("short code directory read in \(url.lastPathComponent)")
            }
            hasher.update(data: blob)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func imageUUID(containing address: UnsafeRawPointer) -> String? {
        var info = Dl_info()
        guard dladdr(address, &info) != 0, let base = info.dli_fbase else { return nil }
        return imageUUID(header: UnsafeRawPointer(base))
    }

    /// LC_UUID of the loaded 64-bit image whose header is at `header`.
    static func imageUUID(header: UnsafeRawPointer) -> String? {
        guard header.load(as: UInt32.self) == MH_MAGIC_64 else { return nil }
        let count = header.load(fromByteOffset: 16, as: UInt32.self)
        var command = header + MemoryLayout<mach_header_64>.size
        for _ in 0 ..< count {
            let kind = command.load(as: UInt32.self)
            let size = Int(command.load(fromByteOffset: 4, as: UInt32.self))
            if kind == LC_UUID {
                return UnsafeRawBufferPointer(start: command + 8, count: 16).map { String(format: "%02x", $0) }.joined()
            }
            guard size >= 8 else { return nil }
            command += size
        }
        return nil
    }

    // MARK: - Reading and writing

    func url(for key: String) -> URL {
        root.appending(path: key + ".plan")
    }

    /// The stored plan for `paths`, in their order, or nil when there is none.
    /// A file that does not decode, or holds other images, is a miss. Under
    /// root the file is opened without following a link and must belong to
    /// root or the invoking user, as the kernelcache mix is.
    func load(key: String, paths: [String]) throws -> [Image]? {
        let data: Data
        do {
            let directory = try VPhoneConfinedDirectory.pin(absolutePath: root.path)
            let file = try directory.openRegularFile(key + ".plan", requireSingleLink: true)
            let uid = VPhoneInvokingUser.current?.uid ?? getuid()
            guard file.owner == 0 || file.owner == uid else {
                throw PatcherError.invalidFormat("The cached X1 plan belongs to another user.")
            }
            data = try withExtendedLifetime(file) {
                try FileHandle(fileDescriptor: file.descriptor, closeOnDealloc: false).readToEnd() ?? Data()
            }
        } catch VPhoneConfinedDirectoryError.missing {
            return nil
        }
        return Self.decode(data, paths: paths)
    }

    /// Store `images` under `key`, in a 0777 folder that belongs to the user.
    /// `cfw install` runs as root under Launchpad, so root may add the plan
    /// folder, but only below a data root that already exists, one component
    /// at a time with no link followed; the folder and file are then handed
    /// to the invoking user. Returns false when there was nowhere to put it.
    @discardableResult
    func store(_ images: [Image], paths: [String], key: String) throws -> Bool {
        guard let data = Self.encode(images, paths: paths) else { return false }
        let owner = VPhoneInvokingUser.current.map { ($0.uid, $0.gid) }
        let directory: VPhoneConfinedDirectory
        if geteuid() == 0 {
            do {
                let parent = try VPhoneConfinedDirectory.pin(absolutePath: root.deletingLastPathComponent().path)
                directory = try parent.directory(root.lastPathComponent, create: true, mode: 0o777)
            } catch VPhoneConfinedDirectoryError.missing {
                return false
            }
        } else {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            directory = try VPhoneConfinedDirectory.pin(absolutePath: root.path)
        }
        try directory.setPermissions(mode: 0o777, owner: owner)
        try directory.writeFile(key + ".plan", contents: data, mode: 0o644, owner: owner)
        return true
    }

    // MARK: - Format

    // magic, format version, then LZFSE of: image count; per image its path,
    // and either 0 + unvisited + write count, or 1 + the skip reason; then,
    // per planned image, its first address, the rest as deltas, and its words.
    // Columns compress: the deltas are small and a few dozen words recur.

    static func encode(_ images: [Image], paths: [String]) -> Data? {
        guard images.count == paths.count else { return nil }
        var head = Data()
        var deltas: [UInt32] = []
        var bases: [UInt64] = []
        var words: [UInt32] = []
        head.appendLE(UInt32(images.count))
        for (image, path) in zip(images, paths) {
            head.appendString(path)
            switch image {
            case let .planned(plan):
                head.append(0)
                head.appendLE(UInt64(plan.unvisitedCandidates))
                head.appendLE(UInt32(plan.writes.count))
                guard let first = plan.writes.first else { continue }
                bases.append(first.address)
                var previous = first.address
                for write in plan.writes {
                    guard write.address >= previous, write.address - previous <= UInt64(UInt32.max) else { return nil }
                    deltas.append(UInt32(write.address - previous))
                    words.append(write.word)
                    previous = write.address
                }
            case let .skipped(reason):
                head.append(1)
                head.appendString(reason)
            }
        }
        var payload = head
        for base in bases { payload.appendLE(base) }
        deltas.withUnsafeBytes { payload.append(contentsOf: $0) }
        words.withUnsafeBytes { payload.append(contentsOf: $0) }
        guard let packed = try? (payload as NSData).compressed(using: .lzfse) as Data else { return nil }
        var file = magic
        file.appendLE(formatVersion)
        file.append(packed)
        return file
    }

    static func decode(_ file: Data, paths: [String]) -> [Image]? {
        guard file.count > magic.count + 4, file.prefix(magic.count) == magic,
              file.loadLE(UInt32.self, at: magic.count) == formatVersion,
              let payload = try? (file.dropFirst(magic.count + 4) as NSData).decompressed(using: .lzfse) as Data
        else { return nil }
        var reader = Reader(data: payload)
        guard let count = reader.u32(), Int(count) == paths.count else { return nil }
        var shapes: [(unvisited: Int, writes: Int)?] = []
        var reasons: [String?] = []
        for path in paths {
            guard reader.string() == path, let kind = reader.u8() else { return nil }
            switch kind {
            case 0:
                guard let unvisited = reader.u64(), let writes = reader.u32() else { return nil }
                shapes.append((Int(unvisited), Int(writes)))
                reasons.append(nil)
            case 1:
                guard let reason = reader.string() else { return nil }
                shapes.append(nil)
                reasons.append(reason)
            default:
                return nil
            }
        }
        let total = shapes.reduce(0) { $0 + ($1?.writes ?? 0) }
        let withWrites = shapes.filter { ($0?.writes ?? 0) > 0 }.count
        guard let bases = reader.array(UInt64.self, count: withWrites),
              let deltas = reader.array(UInt32.self, count: total),
              let words = reader.array(UInt32.self, count: total),
              reader.isAtEnd
        else { return nil }
        var images: [Image] = []
        var position = 0
        var baseIndex = 0
        for (shape, reason) in zip(shapes, reasons) {
            guard let shape else {
                images.append(.skipped(reason!))
                continue
            }
            var writes: [Write] = []
            writes.reserveCapacity(shape.writes)
            if shape.writes > 0 {
                var address = bases[baseIndex]
                baseIndex += 1
                for index in position ..< position + shape.writes {
                    address += UInt64(deltas[index])
                    writes.append(Write(address: address, word: words[index]))
                }
                position += shape.writes
            }
            images.append(.planned(ImagePlan(writes: writes, unvisitedCandidates: shape.unvisited)))
        }
        return images
    }

    private struct Reader {
        let data: Data
        var offset = 0

        var isAtEnd: Bool { offset == data.count }

        mutating func u8() -> UInt8? {
            guard offset < data.count else { return nil }
            defer { offset += 1 }
            return data[data.startIndex + offset]
        }

        mutating func u32() -> UInt32? { fixed() }
        mutating func u64() -> UInt64? { fixed() }

        private mutating func fixed<T: FixedWidthInteger>() -> T? {
            guard offset + MemoryLayout<T>.size <= data.count else { return nil }
            defer { offset += MemoryLayout<T>.size }
            return data.loadLE(T.self, at: offset)
        }

        mutating func string() -> String? {
            guard let length = u32(), offset + Int(length) <= data.count else { return nil }
            defer { offset += Int(length) }
            return String(data: data[(data.startIndex + offset) ..< (data.startIndex + offset + Int(length))], encoding: .utf8)
        }

        mutating func array<T: FixedWidthInteger>(_: T.Type, count: Int) -> [T]? {
            let length = count * MemoryLayout<T>.size
            guard offset + length <= data.count else { return nil }
            defer { offset += length }
            var values = [T](repeating: 0, count: count)
            values.withUnsafeMutableBytes { target in
                data.withUnsafeBytes { source in
                    target.copyMemory(from: UnsafeRawBufferPointer(rebasing: source[offset ..< offset + length]))
                }
            }
            return values.map { T(littleEndian: $0) }
        }
    }
}

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }

    mutating func appendString(_ text: String) {
        let bytes = Data(text.utf8)
        appendLE(UInt32(bytes.count))
        append(bytes)
    }
}

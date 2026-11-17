// DyldSharedCache.swift — A reader for an arm64e dyld shared cache, enough to lift one dylib out.
//
// Reads the main cache and its subcaches (memory-mapped), their mappings and
// slide info (version 5, the format of macOS 14 and later), the image list,
// and each image's load commands and export trie. `DyldCacheDylibExtractor`
// uses it to rebuild `libKernelCollectionBuilder.dylib` of another macOS as a
// standalone dylib.

import Foundation
import VPhonePatchKit

final class DyldSharedCache {
    struct Mapping {
        let file: Int
        let address: UInt64
        let size: UInt64
        let fileOffset: UInt64
        let slideInfoOffset: UInt64
        let slideInfoSize: UInt64
    }

    /// A pointer the slide info describes, decoded.
    struct Pointer {
        let target: UInt64
        let auth: Bool
        /// Only for an authenticated pointer.
        let diversity: UInt16
        let addressDiversity: Bool
        let keyIsData: Bool
        /// Only for a plain pointer.
        let high8: UInt8

        /// The pointer's PAC schema: (auth, key, address diversity, diversity).
        var schema: DyldCacheDylibExtractor.PointerSchema {
            .init(auth: auth, key: keyIsData ? 2 : 0, addressDiversity: addressDiversity, diversity: diversity)
        }
    }

    let path: URL
    private(set) var files: [Data] = []
    private(set) var mappings: [Mapping] = []
    private(set) var images: [(address: UInt64, path: String)] = []
    private var slides: [Int: (valueAdd: UInt64, pointers: [UInt64: UInt64])] = [:]
    private var imageCache: [UInt64: DyldCacheImage] = [:]

    init(path: URL) throws {
        self.path = path
        let main = try open(path)
        guard let magic = String(bytes: main.prefix(16).prefix { $0 != 0 }, encoding: .ascii), magic.hasPrefix("dyld_v1") else {
            throw PatcherError.invalidFormat("\(path.path) is not a dyld shared cache")
        }
        let mappingOffset = Int(main.le32(0x10))
        try addMappings(of: 0)
        let subcacheOffset = Int(main.le32(0x188))
        let subcacheCount = Int(main.le32(0x18C))
        if subcacheCount > 0 {
            let entrySize = mappingOffset <= 0x1C8 ? 24 : 56
            for index in 0 ..< subcacheCount {
                let entry = subcacheOffset + entrySize * index
                let suffix = entrySize == 56 ? main.cStringLE(at: entry + 24) : ".\(index + 1)"
                _ = try open(URL(fileURLWithPath: path.path + suffix))
                try addMappings(of: files.count - 1)
            }
        }
        var imagesOffset = Int(main.le32(0x1C0))
        var imagesCount = Int(main.le32(0x1C4))
        if imagesOffset == 0 {
            imagesOffset = Int(main.le32(0x18))
            imagesCount = Int(main.le32(0x1C))
        }
        for index in 0 ..< imagesCount {
            let entry = imagesOffset + 32 * index
            images.append((main.le64(entry), main.cStringLE(at: Int(main.le32(entry + 24)))))
        }
        mappings.sort { $0.address < $1.address }
    }

    private func open(_ url: URL) throws -> Data {
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        files.append(data)
        return data
    }

    private func addMappings(of fileIndex: Int) throws {
        let file = files[fileIndex]
        var offset = Int(file.le32(0x138))
        var count = Int(file.le32(0x13C))
        if offset == 0 {
            offset = Int(file.le32(0x10))
            count = Int(file.le32(0x14))
            for index in 0 ..< count {
                let entry = offset + 32 * index
                mappings.append(.init(
                    file: fileIndex, address: file.le64(entry), size: file.le64(entry + 8), fileOffset: file.le64(entry + 16),
                    slideInfoOffset: 0, slideInfoSize: 0,
                ))
            }
            return
        }
        for index in 0 ..< count {
            let entry = offset + 56 * index
            mappings.append(.init(
                file: fileIndex, address: file.le64(entry), size: file.le64(entry + 8), fileOffset: file.le64(entry + 16),
                slideInfoOffset: file.le64(entry + 24), slideInfoSize: file.le64(entry + 32),
            ))
        }
    }

    func mappingIndex(for address: UInt64) -> Int? {
        mappings.firstIndex { $0.address <= address && address < $0.address + $0.size }
    }

    func read(_ address: UInt64, _ size: Int) throws -> Data {
        guard let index = mappingIndex(for: address) else {
            throw PatcherError.invalidFormat(String(format: "unmapped cache address 0x%llx", address))
        }
        let mapping = mappings[index]
        let start = Int(mapping.fileOffset + address - mapping.address)
        let available = Int(mapping.address + mapping.size - address)
        let file = files[mapping.file]
        if size <= available {
            return file.subdata(in: file.startIndex + start ..< file.startIndex + start + size)
        }
        return try file.subdata(in: file.startIndex + start ..< file.startIndex + start + available)
            + read(address + UInt64(available), size - available)
    }

    func image(_ path: String) throws -> DyldCacheImage? {
        guard let entry = images.first(where: { $0.path == path }) else { return nil }
        if let image = imageCache[entry.address] {
            return image
        }
        let image = try DyldCacheImage(cache: self, address: entry.address, path: entry.path)
        imageCache[entry.address] = image
        return image
    }

    // MARK: - Slide info v5

    private func slide(_ index: Int) throws -> (valueAdd: UInt64, pointers: [UInt64: UInt64]) {
        if let slide = slides[index] {
            return slide
        }
        let mapping = mappings[index]
        guard mapping.slideInfoSize > 0 else {
            slides[index] = (0, [:])
            return (0, [:])
        }
        let file = files[mapping.file]
        let info = Int(mapping.slideInfoOffset)
        let version = file.le32(info)
        guard version == 5 else {
            throw PatcherError.invalidFormat("dyld cache slide info version \(version) is not supported (only 5)")
        }
        let pageSize = UInt64(file.le32(info + 4))
        let pageCount = Int(file.le32(info + 8))
        let valueAdd = file.le64(info + 16)
        var pointers: [UInt64: UInt64] = [:]
        for page in 0 ..< pageCount {
            let start = file.le16(info + 24 + 2 * page)
            if start == 0xFFFF {
                continue
            }
            var offset = UInt64(page) * pageSize + UInt64(start)
            while true {
                let raw = file.le64(Int(mapping.fileOffset + offset))
                pointers[mapping.address + offset] = raw
                let next = (raw >> 52) & 0x7FF
                if next == 0 {
                    break
                }
                offset += next * 8
            }
        }
        slides[index] = (valueAdd, pointers)
        return (valueAdd, pointers)
    }

    static func decode(_ raw: UInt64, valueAdd: UInt64) -> Pointer {
        let target = valueAdd + (raw & ((1 << 34) - 1))
        if raw >> 63 != 0 {
            return Pointer(
                target: target, auth: true, diversity: UInt16((raw >> 34) & 0xFFFF),
                addressDiversity: (raw >> 50) & 1 != 0, keyIsData: (raw >> 51) & 1 != 0, high8: 0,
            )
        }
        return Pointer(target: target, auth: false, diversity: 0, addressDiversity: false, keyIsData: false, high8: UInt8((raw >> 34) & 0xFF))
    }

    /// The pointer the slide info puts at `address`, if any.
    func pointer(at address: UInt64) throws -> Pointer? {
        guard let index = mappingIndex(for: address) else { return nil }
        let slide = try slide(index)
        return slide.pointers[address].map { Self.decode($0, valueAdd: slide.valueAdd) }
    }

    /// Every pointer in `[start, end)`, by address.
    func pointers(in range: Range<UInt64>) throws -> [(address: UInt64, pointer: Pointer)] {
        var out: [(UInt64, Pointer)] = []
        for (index, mapping) in mappings.enumerated() where mapping.address + mapping.size > range.lowerBound && mapping.address < range.upperBound {
            let slide = try slide(index)
            for (address, raw) in slide.pointers where range.contains(address) {
                out.append((address, Self.decode(raw, valueAdd: slide.valueAdd)))
            }
        }
        return out.sorted { $0.0 < $1.0 }
    }
}

/// A Mach-O image inside the cache.
final class DyldCacheImage {
    static let segment64: UInt32 = 0x19
    static let symtab: UInt32 = 0x2
    static let dysymtab: UInt32 = 0xB
    static let idDylib: UInt32 = 0xD
    static let loadDylib: UInt32 = 0xC
    static let loadWeakDylib: UInt32 = 0x8000_0018
    static let reexportDylib: UInt32 = 0x8000_001F
    static let loadUpwardDylib: UInt32 = 0x8000_0023
    static let exportsTrie: UInt32 = 0x8000_0033
    static let dyldInfoOnly: UInt32 = 0x8000_0022

    struct Section {
        let name: String
        let segment: String
        let address: UInt64
        let size: UInt64
        let offset: UInt32
        let align: UInt32
        let flags: UInt32
    }

    final class Segment {
        let name: String
        let address: UInt64
        let size: UInt64
        let sections: [Section]
        /// The 4 KiB-aligned range this segment covers, so each address keeps
        /// its offset in an ADRP page.
        var coverStart: UInt64 = 0
        var coverEnd: UInt64 = 0
        /// Where it goes in the standalone dylib, and how large it is there.
        var newOffset: UInt64 = 0
        var newSize: UInt64 = 0

        init(name: String, address: UInt64, size: UInt64, sections: [Section]) {
            self.name = name
            self.address = address
            self.size = size
            self.sections = sections
        }
    }

    struct Export {
        let flags: UInt64
        /// The offset from the image, or the ordinal of a re-export, or the stub of a resolver.
        let value: UInt64
        /// The resolver, or a function variant's table.
        let other: UInt64?
        let importName: String?
    }

    let address: UInt64
    let path: String
    let cpuType: UInt32
    let cpuSubtype: UInt32
    let fileType: UInt32
    let flags: UInt32
    private(set) var loadCommands: [(command: UInt32, body: Data)] = []
    private(set) var segments: [Segment] = []
    /// Every dylib it links, in ordinal order.
    private(set) var dependencies: [(command: UInt32, path: String)] = []
    private(set) var exportsTrie: (offset: UInt32, size: UInt32)?
    private(set) var symtab: [UInt32]?
    private(set) var dysymtab: [UInt32]?
    private unowned let cache: DyldSharedCache
    private var exportList: [(name: String, export: Export)]?

    init(cache: DyldSharedCache, address: UInt64, path: String) throws {
        self.cache = cache
        self.address = address
        self.path = path
        let header = try cache.read(address, 32)
        guard header.le32(0) == 0xFEED_FACF else {
            throw PatcherError.invalidFormat("\(path) in the dyld cache is not a 64-bit Mach-O")
        }
        cpuType = header.le32(4)
        cpuSubtype = header.le32(8)
        fileType = header.le32(12)
        let count = Int(header.le32(16))
        let size = Int(header.le32(20))
        flags = header.le32(24)
        let commands = try cache.read(address + 32, size)
        var offset = 0
        for _ in 0 ..< count {
            let command = commands.le32(offset)
            let length = Int(commands.le32(offset + 4))
            let body = commands.subdata(in: commands.startIndex + offset ..< commands.startIndex + offset + length)
            loadCommands.append((command, body))
            switch command {
            case Self.segment64:
                var sections: [Section] = []
                for index in 0 ..< Int(body.le32(64)) {
                    let base = 72 + 80 * index
                    sections.append(Section(
                        name: body.cStringLE(at: base, limit: 16), segment: body.cStringLE(at: base + 16, limit: 16),
                        address: body.le64(base + 32), size: body.le64(base + 40), offset: body.le32(base + 48),
                        align: body.le32(base + 52), flags: body.le32(base + 64),
                    ))
                }
                segments.append(Segment(name: body.cStringLE(at: 8, limit: 16), address: body.le64(24), size: body.le64(32), sections: sections))
            case Self.loadDylib, Self.loadWeakDylib, Self.reexportDylib, Self.loadUpwardDylib:
                dependencies.append((command, body.cStringLE(at: Int(body.le32(8)))))
            case Self.exportsTrie:
                exportsTrie = (body.le32(8), body.le32(12))
            case Self.dyldInfoOnly:
                if body.le32(44) != 0 {
                    exportsTrie = (body.le32(40), body.le32(44))
                }
            case Self.symtab:
                symtab = (0 ..< 4).map { body.le32(8 + 4 * $0) }
            case Self.dysymtab:
                dysymtab = (0 ..< 18).map { body.le32(8 + 4 * $0) }
            default:
                break
            }
            offset += length
        }
    }

    func segment(_ name: String) -> Segment? {
        segments.first { $0.name == name }
    }

    /// A `__LINKEDIT` file offset, as a cached image's load commands give it, as an address.
    func linkeditAddress(_ fileOffset: UInt32) throws -> UInt64 {
        guard let linkedit = segment("__LINKEDIT") else {
            throw PatcherError.invalidFormat("\(path) has no __LINKEDIT")
        }
        let segmentFileOffset = try loadCommands.first {
            $0.command == Self.segment64 && $0.body.cStringLE(at: 8, limit: 16) == "__LINKEDIT"
        }.map { $0.body.le64(40) } ?? { throw PatcherError.invalidFormat("\(path) has no __LINKEDIT") }()
        return linkedit.address + UInt64(fileOffset) - segmentFileOffset
    }

    func linkedit(_ fileOffset: UInt32, _ size: UInt32) throws -> Data {
        try cache.read(linkeditAddress(fileOffset), Int(size))
    }

    /// The export trie, in the order a depth-first walk with a stack finds the
    /// entries (the order decides which alias names an address).
    func exports() throws -> [(name: String, export: Export)] {
        if let exportList {
            return exportList
        }
        var list: [(String, Export)] = []
        defer { exportList = list }
        guard let trie = exportsTrie, trie.size > 0 else { return [] }
        let bytes = [UInt8](try linkedit(trie.offset, trie.size))
        var stack: [(node: Int, prefix: [UInt8])] = [(0, [])]
        var seen = Set<Int>()
        while let (node, prefix) = stack.popLast() {
            guard seen.insert(node).inserted else { continue }
            var cursor = node
            let terminalSize = Int(try ULEB.read(bytes, &cursor))
            if terminalSize > 0 {
                var at = cursor
                let flags = try ULEB.read(bytes, &at)
                let name = String(decoding: prefix, as: UTF8.self)
                if flags & 0x8 != 0 {
                    let ordinal = try ULEB.read(bytes, &at)
                    let end = bytes[at...].firstIndex(of: 0) ?? bytes.endIndex
                    list.append((name, Export(flags: flags, value: ordinal, other: nil, importName: String(decoding: bytes[at ..< end], as: UTF8.self))))
                } else if flags & 0x10 != 0 {
                    let stub = try ULEB.read(bytes, &at)
                    let resolver = try ULEB.read(bytes, &at)
                    list.append((name, Export(flags: flags, value: stub, other: resolver, importName: nil)))
                } else {
                    let value = try ULEB.read(bytes, &at)
                    let other = flags & 0x20 != 0 ? try ULEB.read(bytes, &at) : nil
                    list.append((name, Export(flags: flags, value: value, other: other, importName: nil)))
                }
            }
            cursor += terminalSize
            let children = Int(bytes[cursor])
            cursor += 1
            for _ in 0 ..< children {
                let end = bytes[cursor...].firstIndex(of: 0) ?? bytes.endIndex
                let edge = Array(bytes[cursor ..< end])
                cursor = end + 1
                let child = Int(try ULEB.read(bytes, &cursor))
                stack.append((child, prefix + edge))
            }
        }
        return list
    }

    func export(_ name: String) throws -> Export? {
        try exportIndex()[name]
    }

    private var exportMap: [String: Export]?

    private func exportIndex() throws -> [String: Export] {
        if let exportMap {
            return exportMap
        }
        var map: [String: Export] = [:]
        for (name, export) in try exports() where map[name] == nil {
            map[name] = export
        }
        exportMap = map
        return map
    }
}

enum ULEB {
    static func read(_ bytes: [UInt8], _ cursor: inout Int) throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while true {
            guard cursor < bytes.count, shift < 64 else {
                throw PatcherError.invalidFormat("truncated ULEB128")
            }
            let byte = bytes[cursor]
            cursor += 1
            result |= UInt64(byte & 0x7F) << shift
            shift += 7
            if byte < 0x80 {
                return result
            }
        }
    }

    static func encode(_ value: UInt64) -> [UInt8] {
        var value = value
        var out: [UInt8] = []
        repeat {
            var byte = UInt8(value & 0x7F)
            value >>= 7
            if value != 0 {
                byte |= 0x80
            }
            out.append(byte)
        } while value != 0
        return out
    }
}

extension Data {
    func le16(_ offset: Int) -> UInt16 {
        withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt16.self) }
    }

    func le32(_ offset: Int) -> UInt32 {
        withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }
    }

    func le64(_ offset: Int) -> UInt64 {
        withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt64.self) }
    }

    /// The NUL-terminated string at `offset`, at most `limit` bytes.
    func cStringLE(at offset: Int, limit: Int = .max) -> String {
        let start = startIndex + offset
        let bound = limit == .max ? endIndex : Swift.min(endIndex, start + limit)
        let end = self[start ..< bound].firstIndex(of: 0) ?? bound
        return String(decoding: self[start ..< end], as: UTF8.self)
    }
}

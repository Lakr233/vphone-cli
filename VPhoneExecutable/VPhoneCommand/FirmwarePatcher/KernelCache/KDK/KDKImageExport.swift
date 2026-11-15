// Standalone fileset writer, ported from blacktop/go-macho#94, export.go
// a8b76580904cdec5a634a9bbc9e8e976d80ddf06 (MIT). See Research/Kernel/native_kdk_export.md.
// References and extra symbols are supplied by the caller; this layer does
// not recover references or synthesize names from a kernel collection.
import CryptoKit
import Foundation
import VPhonePatchKit

struct KDKReference: Codable, Hashable {
    var kind: UInt8
    var source: UInt64
    var target: UInt64
    var extra: UInt64 = 0

    enum CodingKeys: String, CodingKey { case kind, source, target, extra }
    init(kind: UInt8, source: UInt64, target: UInt64, extra: UInt64 = 0) {
        self.kind = kind
        self.source = source
        self.target = target
        self.extra = extra
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(UInt8.self, forKey: .kind)
        source = try c.decode(UInt64.self, forKey: .source)
        target = try c.decode(UInt64.self, forKey: .target)
        extra = try c.decodeIfPresent(UInt64.self, forKey: .extra) ?? 0
    }
}

struct KDKSegmentMapping {
    var original: KDKMachO.Segment
    var fileStart: UInt64
    var fileEnd: UInt64
    var start: UInt64
    var end: UInt64
}

/// One export owns all mutable state; the collection and input image are never
/// changed. The supported input is a stripped, little-endian ARM64 collection
/// with address-only synthetic binds (the own-cloudOS extraction path).
struct KDKImageExport {
    let collection: KDKKernelCollection
    let source: KDKImage
    let symbols: [KDKSymbol]
    let references: [KDKReference]
    var header: KDKMachO.Header
    var commands: [KDKMachO.LoadCommand] = []
    var mappings: [KDKSegmentMapping] = []
    var data: [UInt8] = []
    var binds: [UInt64: KDKSymbol] = [:]
    var rebases: [UInt64: UInt64] = [:]
    var others: [UInt64: UInt64] = [:]
    /// Original PAC fields, bits 32...50; no next/bind/auth bits.
    var auths: [UInt64: UInt64] = [:]
    let baseAddress: UInt64
    var packed: Bool {
        !references.isEmpty
    }

    var segments: [KDKMachO.Segment] {
        commands.compactMap(\.segment)
    }

    var sections: [KDKMachO.Section] {
        segments.flatMap(\.sections)
    }

    init(collection: KDKKernelCollection, image: KDKImage, baseAddress: UInt64,
         symbols: [KDKSymbol], references: [KDKReference], addressOnlyBinds: Bool) throws
    {
        guard image.header.cpuType == 0x0100_000C else {
            throw PatcherError.invalidFormat("native KDK writer requires ARM64")
        }
        guard addressOnlyBinds else {
            throw PatcherError.invalidFormat("native KDK writer currently requires address-only binds for stripped collections")
        }
        self.collection = collection
        source = image
        self.baseAddress = baseAddress
        self.symbols = symbols
        self.references = references
        header = image.header
    }

    mutating func export() throws -> Data {
        header = source.header
        mappings.removeAll(keepingCapacity: true)
        commands.removeAll(keepingCapacity: true)
        binds.removeAll(keepingCapacity: true)
        rebases.removeAll(keepingCapacity: true)
        others.removeAll(keepingCapacity: true)
        auths.removeAll(keepingCapacity: true)
        try layout()
        data = header.bytes
        writeCommands(to: &data)
        let loadsEnd = data.count
        for mapping in mappings where mapping.original.fileSize > 0 {
            data.padTo(Int(mapping.fileStart))
            let content = try collection.read(Int(min(mapping.original.fileSize, mapping.fileEnd - mapping.fileStart)), at: mapping.original.address)
            if mapping.original.name == "__TEXT" {
                guard loadsEnd <= content.count else { throw invalid("load commands exceed __TEXT") }
                data += content[loadsEnd...]
            } else {
                data += content
            }
            data.padTo(Int(mapping.fileEnd))
        }
        if source.isInCache {
            if packed {
                try writeAuthStubs()
                try adjustReferences()
                try restoreCacheFields()
            }
            try rebuildLinkedit()
        }
        return Data(data)
    }

    func invalid(_ message: String) -> PatcherError {
        .invalidFormat("KDK export \(source.identifier): \(message)")
    }

    static func aligned(_ value: UInt64, to alignment: UInt64 = KDKMachO.pageSize) -> UInt64 {
        (value + alignment - 1) / alignment * alignment
    }

    func remap(_ value: UInt64, file: Bool = false, linkedit: Bool = false) throws -> UInt64 {
        if linkedit, let m = mappings.first(where: { $0.original.name == "__LINKEDIT" }),
           value >= m.original.fileOffset, value - m.original.fileOffset <= m.original.fileSize
        {
            return m.fileStart + (value - m.original.fileOffset)
        }
        // Containing ranges win over adjacent one-past-the-end ranges.
        for allowEnd in [false, true] {
            for m in mappings {
                let start = file ? m.original.fileOffset : m.original.address
                let size = file ? m.original.fileSize : m.original.memorySize
                if value >= start, value - start < size || (allowEnd && value - start == size) {
                    return (file ? m.fileStart : m.start) + (value - start)
                }
            }
        }
        throw invalid("cannot remap \(file ? "offset" : "address") 0x\(String(value, radix: 16))")
    }

    func offset(_ address: UInt64) throws -> Int {
        guard let seg = segments.first(where: { $0.contains(address) }),
              let value = Int(exactly: seg.fileOffset + (address - seg.address))
        else {
            throw invalid("address 0x\(String(address, radix: 16)) is outside exported segments")
        }
        return value
    }

    func section(_ segment: String, _ name: String) -> KDKMachO.Section? {
        sections.first { $0.segmentName == segment && $0.name == name }
    }

    func check(_ offset: Int, _ count: Int) throws {
        guard offset >= 0, count >= 0, offset <= data.count, count <= data.count - offset else {
            throw invalid("write/read outside export at \(offset), length \(count)")
        }
    }

    mutating func write(_ instruction: Data?, at offset: Int) throws {
        guard let instruction else { throw invalid("instruction cannot encode relocated target") }
        try check(offset, instruction.count)
        data.replaceSubrange(offset ..< offset + instruction.count, with: instruction)
    }

    func writeCommands(to out: inout [UInt8]) {
        for command in commands {
            if let segment = command.segment {
                KDKMachO.write(segment, to: &out)
            } else {
                out += command.bytes
            }
        }
    }

    mutating func layout() throws {
        var file: UInt64 = 0
        var address = baseAddress
        for seg in source.segments {
            let size = Self.aligned(seg.fileSize)
            let memory = Self.aligned(seg.memorySize)
            mappings.append(.init(original: seg, fileStart: file, fileEnd: file + size,
                                  start: packed ? address : seg.address,
                                  end: (packed ? address : seg.address) + memory))
            file += size
            address += memory
        }
        var sourceCommands = source.commands
        if packed, let got = source.segments.flatMap(\.sections).first(where: { $0.segmentName == "__DATA_CONST" && $0.name == "__auth_got" }),
           let index = sourceCommands.firstIndex(where: { $0.segment?.name == "__TEXT_EXEC" }),
           var segment = sourceCommands[index].segment,
           let stub = segment.sections.firstIndex(where: { $0.name == "__auth_stubs" }),
           let map = mappings.firstIndex(where: { $0.original.name == "__TEXT_EXEC" })
        {
            let size = got.size / 8 * 16
            segment.sections[stub].size = size
            sourceCommands[index].segment = segment
            mappings[map].fileEnd = mappings[map].fileStart + Self.aligned(segment.fileSize + size)
            mappings[map].end = mappings[map].start + Self.aligned(max(segment.memorySize, segment.fileSize + size))
            var last: UInt64 = 0
            for i in mappings.indices {
                if mappings[i].fileStart < last {
                    let shift = last - mappings[i].fileStart
                    mappings[i].fileStart += shift
                    mappings[i].fileEnd += shift
                    mappings[i].start += shift
                    mappings[i].end += shift
                }
                last = mappings[i].fileEnd
            }
        }
        for var load in sourceCommands {
            if var seg = load.segment, let m = mappings.first(where: { $0.original.name == seg.name }) {
                seg.fileOffset = m.fileStart
                seg.fileSize = m.fileEnd - m.fileStart
                seg.address = m.start
                seg.memorySize = m.end - m.start
                for i in seg.sections.indices {
                    var s = seg.sections[i]
                    if s.offset != 0 {
                        let off = UInt64(s.offset)
                        s.offset = try UInt32(off >= m.original.fileOffset && off - m.original.fileOffset <= m.original.fileSize
                            ? m.fileStart + (off - m.original.fileOffset) : remap(off, file: true))
                    }
                    s.address = try s.address >= m.original.address && s.address - m.original.address <= m.original.memorySize
                        ? m.start + (s.address - m.original.address) : remap(s.address)
                    if s.offset == 0, s.size != 0, !s.isZerofill {
                        s.offset = UInt32(seg.fileOffset + (s.address - seg.address))
                    }
                    seg.sections[i] = s
                }
                load.segment = seg
            } else {
                let cmd = load.command
                if cmd == KDKMachO.lcSegmentSplitInfo || cmd == KDKMachO.lcMain {
                    continue
                }
                var fields: [Int] = []
                var skipZero = false
                switch cmd {
                case KDKMachO.lcSymtab: fields = [8, 16]
                case KDKMachO.lcDysymtab: fields = [32, 40, 48, 56, 64, 72]
                    skipZero = true
                case KDKMachO.lcDyldInfo, KDKMachO.lcDyldInfoOnly: fields = [8, 16, 24, 32, 40]
                    skipZero = true
                case KDKMachO.lcDyldChainedFixups, KDKMachO.lcFunctionVariants:
                    if !source.isInCache {
                        fields = [8]
                    }
                case KDKMachO.lcCodeSignature, KDKMachO.lcEncryptionInfo, KDKMachO.lcEncryptionInfo64,
                     KDKMachO.lcFunctionStarts, KDKMachO.lcDataInCode, KDKMachO.lcFunctionVariantFixups,
                     KDKMachO.lcDylibCodeSignDRs, KDKMachO.lcLinkerOptimizationHint, KDKMachO.lcDyldExportsTrie:
                    fields = [8]
                case KDKMachO.lcFilesetEntry:
                    try load.bytes.setLE(remap(load.bytes.le(UInt64.self, 16), file: true), at: 16)
                case KDKMachO.lcUnixThread:
                    var pos = 8
                    while pos < load.bytes.count {
                        guard pos + 8 <= load.bytes.count,
                              load.bytes.le(UInt32.self, pos) == KDKMachO.armThreadState64,
                              load.bytes.le(UInt32.self, pos + 4) == 68,
                              pos + 8 + 272 <= load.bytes.count else { throw invalid("unexpected ARM thread state") }
                        let registers = pos + 8
                        // An iOS 27 collection's thread also carries x16, the start of the kernel's
                        // __TEXT_EXEC (the kmutil of macOS 27 writes it). A standalone kernel has
                        // none, and kmutil refuses one that keeps the collection's addresses
                        // ("LC_UNIXTHREAD entry is out of range"): clear it and remap pc.
                        let x16 = registers + 16 * 8
                        let textExec = mappings.first { $0.original.name == "__TEXT_EXEC" }?.original.address
                        let x16Value = load.bytes.le(UInt64.self, x16)
                        if load.bytes[registers ..< x16].allSatisfy({ $0 == 0 }),
                           load.bytes[x16 + 8 ..< registers + 256].allSatisfy({ $0 == 0 }),
                           load.bytes[registers + 264 ..< registers + 272].allSatisfy({ $0 == 0 }),
                           x16Value == 0 || x16Value == textExec,
                           let pc = try? remap(load.bytes.le(UInt64.self, registers + 256))
                        {
                            load.bytes.setLE(pc, at: registers + 256)
                            load.bytes.setLE(UInt64(0), at: x16)
                        }
                        pos += 280
                    }
                default: break
                }
                for field in fields {
                    guard field + 4 <= load.bytes.count else { throw invalid("short load command") }
                    let old = load.bytes.le(UInt32.self, field)
                    if !skipZero || old != 0 {
                        try load.bytes.setLE(UInt32(remap(UInt64(old), file: true, linkedit: true)), at: field)
                    }
                }
            }
            commands.append(load)
        }
        header.flags &= ~KDKMachO.mhDylibInCache
        if packed {
            addLinkeditCommand(KDKMachO.lcDyldChainedFixups)
            addLinkeditCommand(KDKMachO.lcSegmentSplitInfo)
            let chained = commands.first { $0.command == KDKMachO.lcDyldChainedFixups }!
            let split = commands.first { $0.command == KDKMachO.lcSegmentSplitInfo }!
            commands.removeAll { $0.command == chained.command || $0.command == split.command }
            let last = commands.lastIndex { $0.segment != nil }
            if let last {
                commands.insert(chained, at: last + 1)
            } else {
                commands.append(chained)
            }
            let before = commands.firstIndex { $0.command == KDKMachO.lcFunctionStarts } ?? commands.count
            commands.insert(split, at: before)
        } else if source.isInCache, let i = commands.firstIndex(where: { $0.command == KDKMachO.lcDyldChainedFixups }) {
            header.commandCount -= 1
            header.commandsSize -= UInt32(commands[i].size)
            commands.remove(at: i)
        }
        // Deliberately keep the source header's counts, with only the explicit
        // add/remove adjustments above, matching the reference File.Export.
    }

    mutating func addLinkeditCommand(_ command: UInt32) {
        if let i = commands.firstIndex(where: { $0.command == command }) {
            header.commandCount -= 1
            header.commandsSize -= UInt32(commands[i].size)
            commands.remove(at: i)
        }
        var raw: [UInt8] = []
        for word: UInt32 in [command, 16, 0, 0] {
            raw.appendLE(word)
        }
        commands.append(.init(command: command, bytes: raw, segment: nil))
        header.commandCount += 1
        header.commandsSize += 16
    }

    mutating func writeAuthStubs() throws {
        guard let got = section("__DATA_CONST", "__auth_got"), let stubs = section("__TEXT_EXEC", "__auth_stubs"),
              got.size > 0, stubs.size > 0 else { return }
        for i in 0 ..< got.size / 8 {
            let pc = stubs.address + i * 16, target = got.address + i * 8
            let off = try offset(pc)
            try write(ARM64Encoder.encodeADRP(rd: 17, pc: pc, target: target), at: off)
            try write(ARM64Encoder.encodeAddImm12(rd: 17, rn: 17, imm12: UInt32(target & 0xFFF)), at: off + 4)
            try write(ARM64Encoder.encodeLdrXUnsignedOffset(rt: 16, rn: 17, offset: 0), at: off + 8)
            try write(ARM64Encoder.encodeBRAA(rn: 16, rm: 17), at: off + 12)
        }
    }

    mutating func restoreCacheFields() throws {
        if let symbol = (source.symbols + symbols).first(where: { $0.name == "_kmod_info" && $0.isDefinedInSection }) {
            let start = try offset(remap(symbol.value)) + 0x9C
            try check(start, 16)
            data.replaceSubrange(start ..< start + 16, with: repeatElement(UInt8(0), count: 16))
        }
        if let seal = section("__TEXT", "__fips_hmacs") {
            guard seal.size >= 32, let text = section("__TEXT", "__text") ?? section("__TEXT_EXEC", "__text") else {
                throw invalid("cannot restore FIPS HMAC")
            }
            let off = Int(text.offset), count = Int(text.size)
            try check(off, count)
            try check(Int(seal.offset), 32)
            let mac = HMAC<SHA256>.authenticationCode(for: Data(data[off ..< off + count]), using: SymmetricKey(data: Data([0])))
            data.replaceSubrange(Int(seal.offset) ..< Int(seal.offset) + 32, with: Array(mac))
        }
    }
}

extension [UInt8] {
    mutating func padTo(_ end: Int) {
        if count < end {
            append(contentsOf: repeatElement(0, count: end - count))
        }
    }
}

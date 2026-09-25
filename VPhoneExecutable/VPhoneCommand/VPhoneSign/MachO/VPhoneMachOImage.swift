import Foundation
import MachO

// MARK: - One Mach-O slice

/// A single architecture's image and the few facts a signer needs from it.
///
/// The parse is deliberately its own rather than a library's: everything
/// below is read from offsets the file itself supplies, so each one is
/// bounds-checked before it is used. A signer that trusts a malformed header
/// writes a signature over the wrong bytes, which is worse than refusing.
struct VPhoneMachOImage {
    struct Segment {
        /// Where the command sits among the load commands, counted from the
        /// first byte after the header.
        let commandOffset: Int
        let name: String
        let fileOffset: UInt64
        let fileSize: UInt64
        let initialProtection: Int32
        /// File offsets and sizes of the segment's sections.
        let sections: [(name: String, offset: UInt32, size: UInt64)]
    }

    /// Where this slice lives in the file it came from. A thin file is one
    /// slice covering everything.
    let range: Range<Int>
    /// The slice's own bytes, header first.
    let image: Data
    let cpuType: cpu_type_t
    let fileType: UInt32
    let commandCount: UInt32
    let commandsSize: Int
    let segments: [Segment]
    /// Every load command, in file order: the signature is written by laying
    /// the command area out again, so each one's bytes have to be carried
    /// over whether or not this signer understands it.
    let commands: [(command: UInt32, offset: Int, size: Int)]
    /// Where the existing signature starts and the command that points at
    /// it, or nil for a file that was never signed.
    let signature: (commandOffset: Int, dataOffset: Int, dataSize: Int)?
    /// One past the end of the string table, which is where ldid ends the
    /// code. nil when the slice has no symbol table, or an empty one.
    let stringTableEnd: UInt64?
    /// Which CodeDirectories ldid would write for this slice, from its
    /// deployment target (see `digests(in:command:at:size:)`).
    let digests: [VPhoneCodeSignature.Digest]

    private static let headerSize = MemoryLayout<mach_header_64>.size
    private static let linkedit = "__LINKEDIT"

    // MARK: Parsing

    /// Parses the slice at `range` of `file`.
    /// What `init` accepts. `CPU_TYPE_ARM` is 32-bit and cannot get past the
    /// MH_MAGIC_64 check above it; it is here so the set reads as "ARM",
    /// rather than as a list someone has to work out the gaps in.
    static let armCPUTypes: Set<cpu_type_t> = [CPU_TYPE_ARM, CPU_TYPE_ARM64, CPU_TYPE_ARM64_32]

    init(file: Data, range: Range<Int>) throws {
        guard file.holds(range.lowerBound, range.count), range.count >= Self.headerSize else {
            throw VPhoneSignError.malformed("slice at \(range.lowerBound) runs past the end of the file")
        }
        let image = file.subdata(in: range)
        let magic: UInt32 = image.littleEndianValue(at: 0)
        guard magic == MH_MAGIC_64 else {
            guard magic == MH_MAGIC || magic == MH_CIGAM || magic == MH_CIGAM_64 else {
                throw VPhoneSignError.notMachO("slice at \(range.lowerBound) has magic 0x\(String(magic, radix: 16))")
            }
            throw VPhoneSignError.unsupportedSlice("slice at \(range.lowerBound) is not 64-bit little-endian")
        }

        self.range = range
        self.image = image
        cpuType = cpu_type_t(bitPattern: image.littleEndianValue(at: 4) as UInt32)
        // ARM only, deliberately. Everything this signs is either a guest
        // binary — iOS arm64, out of an IPSW — or one of this project's own
        // host products, which are arm64 because the host has to be an Apple
        // silicon Mac to run a virtual iPhone at all. An x86 slice reaching
        // here is a file that came from somewhere unexpected, and signing it
        // on a guess is worse than saying so: page size, the `__LINKEDIT`
        // alignment and the deployment-target load commands all differ, and
        // none of that is exercised by anything.
        guard Self.armCPUTypes.contains(cpuType) else {
            throw VPhoneSignError.unsupportedSlice(
                "slice at \(range.lowerBound) is cputype \(cpuType); this signer is ARM only",
            )
        }
        fileType = image.littleEndianValue(at: 12)
        commandCount = image.littleEndianValue(at: 16)
        commandsSize = Int(image.littleEndianValue(at: 20) as UInt32)
        guard Self.headerSize + commandsSize <= image.count else {
            throw VPhoneSignError.malformed("load commands run past the end of the slice")
        }

        var segments: [Segment] = []
        var commands: [(command: UInt32, offset: Int, size: Int)] = []
        var signature: (Int, Int, Int)?
        var stringTableEnd: UInt64?
        var digests: [VPhoneCodeSignature.Digest]?
        var cursor = 0
        for _ in 0 ..< commandCount {
            guard cursor + 8 <= commandsSize else {
                throw VPhoneSignError.malformed("a load command starts past the end of the command area")
            }
            let start = Self.headerSize + cursor
            let command: UInt32 = image.littleEndianValue(at: start)
            let size = Int(image.littleEndianValue(at: start + 4) as UInt32)
            guard size >= 8, size % 8 == 0, cursor + size <= commandsSize else {
                throw VPhoneSignError.malformed("load command 0x\(String(command, radix: 16)) has size \(size)")
            }
            commands.append((command, cursor, size))
            if let choice = try Self.digests(in: image, command: command, at: start, size: size) {
                // ldid lets the last one it reads decide
                digests = choice
            }
            switch command {
            case UInt32(LC_CODE_SIGNATURE):
                guard size >= MemoryLayout<linkedit_data_command>.size else {
                    throw VPhoneSignError.malformed("LC_CODE_SIGNATURE is \(size) bytes")
                }
                signature = (
                    cursor,
                    Int(image.littleEndianValue(at: start + 8) as UInt32),
                    Int(image.littleEndianValue(at: start + 12) as UInt32),
                )
            case UInt32(LC_SYMTAB):
                guard size >= MemoryLayout<symtab_command>.size else {
                    throw VPhoneSignError.malformed("LC_SYMTAB is \(size) bytes")
                }
                let offset: UInt32 = image.littleEndianValue(at: start + 16)
                let length: UInt32 = image.littleEndianValue(at: start + 20)
                // an all-zero symbol table is no symbol table, as ldid reads it
                stringTableEnd = offset == 0 && length == 0 ? nil : UInt64(offset) + UInt64(length)
            case UInt32(LC_SEGMENT_64):
                try segments.append(Self.segment(in: image, at: start, commandOffset: cursor, size: size))
            default:
                break
            }
            cursor += size
        }
        self.segments = segments
        self.commands = commands
        self.signature = signature
        self.stringTableEnd = stringTableEnd
        self.digests = digests ?? [.sha1, .sha256]

        if let signature {
            guard image.holds(signature.1, signature.2) else {
                throw VPhoneSignError.malformed("the existing signature runs past the end of the slice")
            }
            guard signature.1 + signature.2 == image.count else {
                // ldid rewrites the file from the old signature's offset on,
                // so anything after it would be dropped without notice
                throw VPhoneSignError.malformed("the existing signature does not end the slice")
            }
        }
        guard segments.contains(where: { $0.name == Self.linkedit }) else {
            throw VPhoneSignError.malformed("no __LINKEDIT segment")
        }
    }

    private static func segment(in image: Data, at start: Int, commandOffset: Int, size: Int) throws -> Segment {
        guard size >= MemoryLayout<segment_command_64>.size else {
            throw VPhoneSignError.malformed("LC_SEGMENT_64 is \(size) bytes")
        }
        let fileOffset: UInt64 = image.littleEndianValue(at: start + 40)
        let fileSize: UInt64 = image.littleEndianValue(at: start + 48)
        guard fileOffset <= UInt64(image.count), fileSize <= UInt64(image.count) - fileOffset else {
            throw VPhoneSignError.malformed("a segment runs past the end of the slice")
        }
        let count = Int(image.littleEndianValue(at: start + 64) as UInt32)
        let sectionSize = MemoryLayout<section_64>.size
        guard MemoryLayout<segment_command_64>.size + count * sectionSize <= size else {
            throw VPhoneSignError.malformed("a segment claims \(count) sections it has no room for")
        }
        var sections: [(String, UInt32, UInt64)] = []
        for index in 0 ..< count {
            let section = start + MemoryLayout<segment_command_64>.size + index * sectionSize
            sections.append((
                Self.name(in: image, at: section),
                image.littleEndianValue(at: section + 48),
                image.littleEndianValue(at: section + 40),
            ))
        }
        return Segment(
            commandOffset: commandOffset,
            name: Self.name(in: image, at: start + 8),
            fileOffset: fileOffset,
            fileSize: fileSize,
            initialProtection: Int32(bitPattern: image.littleEndianValue(at: start + 60) as UInt32),
            sections: sections,
        )
    }

    /// Which CodeDirectories ldid writes, decided by a deployment-target
    /// load command, or nil for a command that is not one.
    ///
    /// ldid drops SHA-1 for a target new enough to have stopped needing it,
    /// and its test is `major >= 10 && minor >= 12` — written for macOS
    /// 10.12 and never revisited, so a target of macOS 11 or later fails the
    /// `minor` half and keeps SHA-1. That is not what the test means, but it
    /// is what ldid does, and a signature that differs from ldid's in its
    /// number of CodeDirectories has a different CDHash. So it is
    /// reproduced, not corrected.
    private static func digests(
        in image: Data,
        command: UInt32,
        at start: Int,
        size: Int,
    ) throws -> [VPhoneCodeSignature.Digest]? {
        /// A packed version: patch, minor, then major in the high 16 bits.
        func version(_ value: UInt32) -> (major: UInt32, minor: UInt32) {
            (value >> 16, (value >> 8) & 0xFF)
        }
        switch command {
        case UInt32(LC_BUILD_VERSION):
            guard size >= MemoryLayout<build_version_command>.size else {
                throw VPhoneSignError.malformed("LC_BUILD_VERSION is \(size) bytes")
            }
            let platform: UInt32 = image.littleEndianValue(at: start + 8)
            let (major, minor) = version(image.littleEndianValue(at: start + 12))
            switch platform {
            case UInt32(PLATFORM_MACOS) where major >= 10 && minor >= 12,
                 UInt32(PLATFORM_IOS) where major >= 11,
                 UInt32(PLATFORM_TVOS) where major >= 11:
                return [.sha256]
            default:
                return [.sha1, .sha256]
            }
        // LC_VERSION_MIN_MACOSX is not read. It is the load command that
        // predates LC_BUILD_VERSION, and arm64 macOS starts at 11.0, which is
        // years after the changeover — so on an ARM-only signer the pair
        // (this command, a slice we accept) does not occur.
        case UInt32(LC_VERSION_MIN_IPHONEOS), UInt32(LC_VERSION_MIN_TVOS):
            guard size >= MemoryLayout<version_min_command>.size else {
                throw VPhoneSignError.malformed("a version command is \(size) bytes")
            }
            return version(image.littleEndianValue(at: start + 8)).major >= 11 ? [.sha256] : [.sha1, .sha256]
        default:
            return nil
        }
    }

    /// A 16-byte name field, which is NUL-padded and need not be terminated.
    private static func name(in image: Data, at offset: Int) -> String {
        String(decoding: image[offset ..< offset + 16].prefix { $0 != 0 }, as: UTF8.self)
    }

    // MARK: Facts the signer asks for

    /// ldid's executable segment: from the first byte of any segment that
    /// maps code to the last, in its own unsigned arithmetic.
    var executableSegment: (base: UInt64, limit: UInt64) {
        var base = UInt64.max
        var end: UInt64 = 0
        for segment in segments where segment.initialProtection & VM_PROT_EXECUTE != 0 {
            base = min(base, segment.fileOffset)
            end = max(end, segment.fileOffset &+ segment.fileSize)
        }
        return (base, end &- base)
    }

    /// `__TEXT,__info_plist`, which ldid hashes into the info slot of
    /// whatever carries one. The last one wins, as it does there.
    var infoPlist: Data? {
        var found: (UInt64, UInt64)?
        for segment in segments where segment.name == "__TEXT" {
            for section in segment.sections where section.name == "__info_plist" {
                found = (segment.fileOffset &+ UInt64(section.offset), section.size)
            }
        }
        // ldid cuts the offset to 32 bits before it reads there
        guard let found else { return nil }
        let start = Int(UInt32(truncatingIfNeeded: found.0))
        guard image.holds(start, Int(found.1)) else { return nil }
        return image.subdata(in: start ..< start + Int(found.1))
    }

    /// The XML in the old signature's entitlements slot, read as ldid reads
    /// it: the last blob in slot 5, nothing where there is none, and the
    /// SuperBlob's own magic unchecked.
    var embeddedEntitlements: Data? {
        guard let signature, signature.dataSize >= 12 else { return nil }
        let blob = image.subdata(in: signature.dataOffset ..< signature.dataOffset + signature.dataSize)
        return VPhoneCodeSignature.entitlementsXML(in: blob)
    }

    /// How far ldid lets the code reach: the end of the string table, or the
    /// start of the signature it is replacing.
    func codeEnd() throws -> Int {
        let signatureStart = signature.map(\.dataOffset) ?? image.count
        guard let stringTableEnd else { return signatureStart }
        // ldid adds the string table up in 32 bits and asserts it is not
        // past the old signature
        guard stringTableEnd <= UInt64(UInt32.max), stringTableEnd <= UInt64(signatureStart) else {
            throw VPhoneSignError.malformed("the string table ends past the signature")
        }
        return Int(stringTableEnd)
    }

    /// The alignment ldid rounds `__LINKEDIT`'s vmsize to: the slice's own
    /// in a fat file, and in a thin one what it takes the CPU's page to be.
    /// ldid's table has an entry per CPU; only the ARM one can be reached
    /// here, because `init` refuses everything else.
    var linkeditAlignment: Int {
        14
    }

    // MARK: Rewriting

    /// The slice with `makeSignature` laid over it, `__LINKEDIT` grown to
    /// hold it and the load command pointing at it.
    ///
    /// The signature's length has to be known before anything is hashed —
    /// the load commands carry it and are themselves hashed — so the caller
    /// supplies a size first and the bytes second.
    func signed(
        alignment: Int,
        signatureSize: (_ codeLimit: Int) -> Int,
        makeSignature: (_ code: Data, _ codeLimit: Int) throws -> Data,
    ) throws -> Data {
        let codeEnd = try codeEnd()
        let codeLimit = codeEnd.aligned(to: 16)
        let size = signatureSize(codeLimit).aligned(to: 16)

        // ldid drops the old LC_CODE_SIGNATURE and puts a fresh one after
        // every other command, so the command area is laid out again rather
        // than patched in place. For a linker-produced file the command was
        // last anyway and nothing moves.
        var carried = commands.filter { $0.command != UInt32(LC_CODE_SIGNATURE) }
        let commandSize = MemoryLayout<linkedit_data_command>.size
        var rebuilt = carried.reduce(0) { $0 + $1.size } + commandSize

        // Whatever holds content has to start after the commands. The check
        // comes before anything is written: a section over them is exactly
        // what a command area that grew would overwrite.
        let content = segments.flatMap { segment in
            segment.sections.map { UInt64($0.offset) }
                + (segment.sections.isEmpty && segment.fileSize > 0 ? [segment.fileOffset] : [])
        }
        let firstContent = content.filter { $0 > 0 }.min() ?? 0
        // An earlier pipeline step may have spent the header padding already:
        // the CFW launchd injection does exactly that on iOS 18.6.2, where 16
        // bytes of slack leave no room for the fresh LC_CODE_SIGNATURE once
        // LC_LOAD_WEAK_DYLIB is in. LC_SOURCE_VERSION is 16 informational
        // bytes nothing loads — drop it and lay the area out again.
        if UInt64(Self.headerSize + max(rebuilt, commandsSize)) > firstContent,
           carried.contains(where: { $0.command == UInt32(LC_SOURCE_VERSION) })
        {
            carried.removeAll { $0.command == UInt32(LC_SOURCE_VERSION) }
            rebuilt = carried.reduce(0) { $0 + $1.size } + commandSize
        }
        guard UInt64(Self.headerSize + max(rebuilt, commandsSize)) <= firstContent,
              firstContent <= UInt64(codeEnd)
        else {
            throw VPhoneSignError.noRoom(
                "content starts at \(firstContent), \(Self.headerSize + rebuilt) bytes of commands",
            )
        }

        var area = Data()
        for command in carried {
            var bytes = image.subdata(
                in: Self.headerSize + command.offset ..< Self.headerSize + command.offset + command.size,
            )
            // ldid sets the size of every __LINKEDIT there is
            if command.command == UInt32(LC_SEGMENT_64), Self.name(in: bytes, at: 8) == Self.linkedit {
                let start: UInt64 = bytes.littleEndianValue(at: 40)
                let end = UInt64(codeLimit + size)
                guard start < end else {
                    throw VPhoneSignError.malformed("__LINKEDIT starts past the end of the signature")
                }
                let grown = Int(end - start)
                bytes.storeLittleEndian(UInt64(grown.aligned(to: 1 << alignment)), at: 32)
                bytes.storeLittleEndian(UInt64(grown), at: 48)
            }
            area.append(bytes)
        }
        var signatureCommand = Data(count: commandSize)
        signatureCommand.storeLittleEndian(UInt32(LC_CODE_SIGNATURE), at: 0)
        signatureCommand.storeLittleEndian(UInt32(commandSize), at: 4)
        signatureCommand.storeLittleEndian(UInt32(codeLimit), at: 8)
        signatureCommand.storeLittleEndian(UInt32(size), at: 12)
        area.append(signatureCommand)
        // a command area that shrank is padded back out, as ldid pads it, so
        // that what follows stays where the rest of the file expects it
        area.append(Data(count: max(0, commandsSize - rebuilt)))

        var code = image.prefix(codeEnd) + Data(count: codeLimit - codeEnd)
        guard code.holds(Self.headerSize, area.count) else {
            throw VPhoneSignError.noRoom("the slice ends inside the command area")
        }
        code.replaceSubrange(Self.headerSize ..< Self.headerSize + area.count, with: area)
        code.storeLittleEndian(UInt32(carried.count + 1), at: 16)
        code.storeLittleEndian(UInt32(rebuilt), at: 20)

        let blob = try makeSignature(code, codeLimit)
        guard blob.count <= size else {
            throw VPhoneSignError.malformed("the signature grew between being measured and being written")
        }
        return code + blob + Data(count: size - blob.count)
    }
}

// MARK: - A whole file

/// A Mach-O file, thin or fat, and the slices to sign.
struct VPhoneMachOFile {
    /// A fat slice's architecture as the fat header spells it, which is what
    /// the file is laid out again from.
    struct Architecture {
        let cpuType: UInt32
        let cpuSubtype: UInt32
        let alignment: UInt32
    }

    let slices: [VPhoneMachOImage]
    /// nil for a thin file.
    let architectures: [Architecture]?

    init(data: Data) throws {
        // Every offset below is counted from the start of the file, so a
        // slice whose indices do not start at zero has to be copied first:
        // Data keeps the parent's indices, and reading `data[0]` of one
        // would either trap or read the wrong byte.
        let data = data.startIndex == 0 ? data : Data(data)
        guard data.count >= 8 else {
            throw VPhoneSignError.notMachO("the file is \(data.count) bytes")
        }
        let magic: UInt32 = data.littleEndianValue(at: 0)
        switch magic {
        case FAT_CIGAM:
            let count = Int(data.bigEndianValue(at: 4) as UInt32)
            let size = MemoryLayout<fat_arch>.size
            // A Java class file opens with the same four bytes, and its next
            // two hold a version rather than a count. ldid's own bound is 20
            // architectures; past that this is not a fat Mach-O.
            guard (1 ..< 20).contains(count) else {
                throw VPhoneSignError.notMachO("a fat header claiming \(count) architectures")
            }
            guard data.holds(8, count * size) else {
                throw VPhoneSignError.malformed("a fat header of \(count) architectures does not fit")
            }
            var architectures: [Architecture] = []
            var slices: [VPhoneMachOImage] = []
            for index in 0 ..< count {
                let entry = 8 + index * size
                let offset = Int(data.bigEndianValue(at: entry + 8) as UInt32)
                let length = Int(data.bigEndianValue(at: entry + 12) as UInt32)
                let alignment: UInt32 = data.bigEndianValue(at: entry + 16)
                guard data.holds(offset, length) else {
                    throw VPhoneSignError.malformed("architecture \(index) runs past the end of the file")
                }
                guard alignment <= 30 else {
                    throw VPhoneSignError.malformed("architecture \(index) is aligned to 2^\(alignment)")
                }
                architectures.append(Architecture(
                    cpuType: data.bigEndianValue(at: entry),
                    cpuSubtype: data.bigEndianValue(at: entry + 4),
                    alignment: alignment,
                ))
                try slices.append(VPhoneMachOImage(file: data, range: offset ..< offset + length))
            }
            self.architectures = architectures
            self.slices = slices
        case FAT_MAGIC, FAT_CIGAM_64, FAT_MAGIC_64:
            throw VPhoneSignError.unsupportedSlice("a fat file this signer does not read")
        default:
            architectures = nil
            slices = try [VPhoneMachOImage(file: data, range: 0 ..< data.count)]
        }
    }

    /// The file rebuilt from `images`, one per slice. ldid lays the slices
    /// out again, each on its own alignment.
    func assembled(_ images: [Data]) throws -> Data {
        guard let architectures else { return images[0] }
        var header = Data()
        header.appendBigEndian(FAT_MAGIC)
        header.appendBigEndian(UInt32(images.count))
        var body = Data()
        let bodyStart = 8 + images.count * MemoryLayout<fat_arch>.size
        for (architecture, image) in zip(architectures, images) {
            let offset = (bodyStart + body.count).aligned(to: 1 << Int(architecture.alignment))
            body.append(Data(count: offset - bodyStart - body.count))
            body.append(image)
            // a fat header counts in 32 bits, so a file this size has none
            guard let start = UInt32(exactly: offset), let size = UInt32(exactly: image.count) else {
                throw VPhoneSignError.malformed("a slice does not fit a 32-bit fat header")
            }
            for field in [architecture.cpuType, architecture.cpuSubtype, start, size, architecture.alignment] {
                header.appendBigEndian(field)
            }
        }
        return header + body
    }
}

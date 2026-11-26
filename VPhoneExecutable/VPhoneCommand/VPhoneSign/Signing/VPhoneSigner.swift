import Foundation
import MachO

// MARK: - What ldid was called for

/// The identity `-K` signs with. The CMS half is behind a protocol so the
/// ad-hoc path, which is nearly every call, needs nothing from Security.
public protocol VPhoneSigningIdentity: Sendable {
    /// The leaf certificate's common name, which goes in the designated
    /// requirement.
    var commonName: String { get }
    /// The leaf certificate's organizational unit, which is the team ID and
    /// goes in the CodeDirectory.
    var teamIdentifier: String { get }
    /// A detached CMS SignedData over `codeDirectory`, carrying the cdhashes
    /// of every CodeDirectory in the signature.
    func cms(codeDirectory: Data, cdHashes: [Data]) throws -> Data
}

/// How to sign.
public struct VPhoneSignOptions {
    /// What shape of signature to write.
    public enum Style: Sendable {
        /// Byte for byte what `ldid` writes, which is what the guest's AMFI
        /// is known to accept and what every call site in this repository
        /// has always produced. `codesign --verify` rejects it — it rejects
        /// ldid's own output too, because there is no CMS blob and the
        /// ad-hoc flag is not set.
        case ldid
        /// An ad-hoc signature in Apple's shape: the ad-hoc flag set, no
        /// designated requirement, and the empty CMS wrapper. This is what
        /// `codesign --sign -` writes and what `codesign --verify` accepts.
        case appleAdHoc
    }

    /// `-I`. The file's name when nil, as ldid defaults it.
    public var identifier: String?
    /// `-S<file>`: the entitlements to embed, as the file holds them.
    public var entitlements: Data?
    /// `-M`: merge over whatever the file is already signed with.
    public var mergesExisting = false
    public var style = Style.ldid
    /// `-K`: sign for real rather than ad-hoc.
    public var identity: (any VPhoneSigningIdentity)?

    public init(
        identifier: String? = nil,
        entitlements: Data? = nil,
        mergesExisting: Bool = false,
        style: Style = .ldid,
        identity: (any VPhoneSigningIdentity)? = nil,
    ) {
        self.identifier = identifier
        self.entitlements = entitlements
        self.mergesExisting = mergesExisting
        self.style = style
        self.identity = identity
    }
}

/// Signs Mach-O files the way `ldid` does, and reads entitlements back out
/// the way `ldid -e` does.
///
/// This exists because `ldid` is the one program this project ships that
/// links Homebrew — `libcrypto.3` and `libplist-2.0.4` — and so the one
/// thing that fails the self-contained admission rule. Nothing here is
/// outside the system frameworks.
public enum VPhoneSigner {
    /// ldid's `certificate`: "a sufficiently large number" of bytes kept for
    /// the CMS blob, which has to be reserved before it can be made.
    static let cmsReservation = 0x3000

    // MARK: Signing

    /// Signs the file in place, keeping its mode.
    @discardableResult
    public static func sign(fileAt url: URL, options: VPhoneSignOptions = .init()) throws -> Data {
        var options = options
        options.identifier = options.identifier ?? url.lastPathComponent
        // Mapping is safe HERE specifically, and only because of how the write
        // below works: a temporary beside the file, then `rename(2)`. Rename
        // does not truncate the original inode, and a mapping keeps that inode
        // alive, so nothing pulls the bytes out from under this buffer. A
        // patcher that wrote back with `Data.write(to:)` could not map — see
        // FirmwarePatcher's InPlaceRewrite.swift.
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let signed = try sign(data, options: options)
        // The same path ldid takes: a temporary beside the file, its mode
        // copied over, then rename(2). It has to be rename and not
        // replaceItemAt because a great many of the files this signs are
        // mode 444 — anything unpacked out of an IPSW is — and replacing
        // one needs write permission on the file, where renaming over it
        // needs it only on the directory. It is also why an interrupted run
        // leaves the original untouched rather than half written.
        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).vphonesign.\(getpid()).\(UUID().uuidString)")
        try signed.write(to: temporary, options: .atomic)
        var info = stat()
        if lstat(url.path, &info) == 0 {
            _ = chmod(temporary.path, info.st_mode & 0o7777)
            // Preserve ownership when running as root (e.g. vphoned); ignore EPERM otherwise.
            _ = chown(temporary.path, info.st_uid, info.st_gid)
        }
        guard rename(temporary.path, url.path) == 0 else {
            let reason = String(cString: strerror(errno))
            try? FileManager.default.removeItem(at: temporary)
            throw VPhoneSignError.signingFailed("cannot replace \(url.path): \(reason)")
        }
        return signed
    }

    /// Signs `data`. `options.identifier` must be set; the file-based entry
    /// point fills it in from the name. In mixed ARM fat files, signing
    /// options apply only to supported slices; 32-bit ARM slices are preserved.
    public static func sign(_ data: Data, options: VPhoneSignOptions) throws -> Data {
        guard let identifier = options.identifier else {
            throw VPhoneSignError.signingFailed("no identifier, and no file name to take one from")
        }
        let file = try VPhoneMachOFile(data: data)

        // ldid works out the hashes once, from the first slice it reads, and
        // keeps them for the rest of the run. Every other slice inherits
        // that decision however new its own deployment target is. Preserved
        // legacy ARM slices do not participate in signing or digest choice.
        let digests = options.style == .appleAdHoc ? [.sha256] : file.slices[0].digests
        let architectures = file.architectures?.filter { $0.preservedImage == nil }

        var images: [Data] = []
        for (index, slice) in file.slices.enumerated() {
            let alignment = architectures.map { Int($0[index].alignment) } ?? slice.linkeditAlignment
            let signature = try signature(
                for: slice,
                identifier: identifier,
                digests: digests,
                options: options,
            )
            let executable = slice.executableSegment
            try images.append(slice.signed(
                alignment: alignment,
                signatureSize: { signature.allocation(codeLimit: $0) },
                makeSignature: { code, codeLimit in
                    try signature.blob(
                        code: code,
                        codeLimit: codeLimit,
                        executable: executable,
                        cms: cmsBuilder(options: options),
                    )
                },
            ))
        }
        return try file.assembled(images)
    }

    private static func cmsBuilder(
        options: VPhoneSignOptions,
    ) -> ((Data, [Data]) throws -> Data)? {
        if let identity = options.identity {
            return { try identity.cms(codeDirectory: $0, cdHashes: $1) }
        }
        // codesign writes the wrapper with nothing in it, and its absence is
        // one of the two reasons codesign --verify calls ldid's output
        // unsigned
        return options.style == .appleAdHoc ? { _, _ in Data() } : nil
    }

    private static func signature(
        for slice: VPhoneMachOImage,
        identifier: String,
        digests: [VPhoneCodeSignature.Digest],
        options: VPhoneSignOptions,
    ) throws -> VPhoneCodeSignature {
        var signature = VPhoneCodeSignature(identifier: identifier)
        signature.digests = digests
        signature.infoPlist = slice.infoPlist

        let mainBinary = slice.fileType == UInt32(MH_EXECUTE)
        switch options.style {
        case .ldid:
            signature.teamIdentifier = options.identity?.teamIdentifier ?? ""
            signature.requirementsBlob = VPhoneCodeSignature.requirements(
                identifier: identifier,
                commonName: options.identity?.commonName ?? "",
            )
            signature.cmsReservation = options.identity == nil ? nil : cmsReservation
        case .appleAdHoc:
            signature.requirementsBlob = VPhoneCodeSignature.emptyRequirements
            signature.flags = 0x2 // kSecCodeSignatureAdhoc
            signature.cmsReservation = 0
        }

        let existing = options.mergesExisting ? slice.embeddedEntitlements : nil
        if existing?.isEmpty == false || options.entitlements?.isEmpty == false {
            var combined = try VPhoneSignEntitlements(xml: existing ?? Data())
            try combined.merge(VPhoneSignEntitlements(xml: options.entitlements ?? Data()))
            signature.entitlements = try (combined.xml(), combined.der)
            signature.executableSegmentFlags = combined.executableSegmentFlags(mainBinary: mainBinary)
        } else {
            signature.executableSegmentFlags = mainBinary ? 1 : 0
        }
        return signature
    }

    // MARK: Reading signatures back

    public static func identifier(ofFileAt url: URL) throws -> String? {
        try identifier(in: Data(contentsOf: url, options: .mappedIfSafe))
    }

    public static func identifier(in data: Data) throws -> String? {
        let identifiers = try VPhoneMachOFile(data: data).slices.compactMap { try $0.embeddedIdentifier() }
        guard let identifier = identifiers.first else { return nil }
        guard identifiers.allSatisfy({ $0 == identifier }) else {
            throw VPhoneSignError.malformed("the slices have different CodeDirectory identifiers")
        }
        return identifier
    }

    /// The entitlements of each supported slice that carries any, in slice
    /// order, exactly as the signature stores them. A slice
    /// with none contributes nothing, so a file with no entitlements at all
    /// gives an empty array.
    public static func entitlements(ofFileAt url: URL) throws -> [Data] {
        try entitlements(in: Data(contentsOf: url, options: .mappedIfSafe))
    }

    public static func entitlements(in data: Data) throws -> [Data] {
        try VPhoneMachOFile(data: data).slices.compactMap(\.embeddedEntitlements)
    }

    /// Returns whether `url` is a Mach-O shared library or loadable bundle
    /// (`MH_DYLIB` / `MH_BUNDLE`) whose signature lacks both a real CMS blob
    /// and `CS_ADHOC` (`0x2`), so TXM would classify it as type 5 under
    /// `/private/var/containers/Bundle/` and reject it in higher-trust hosts.
    public static func needsAdHocLibraryResign(fileAt url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return false }
        return needsAdHocLibraryResign(in: data)
    }

    public static func needsAdHocLibraryResign(in data: Data) -> Bool {
        guard data.count >= 8 else { return false }
        let magic: UInt32 = data.littleEndianValue(at: 0)
        var sliceRanges: [Range<Int>] = []
        switch magic {
        case FAT_CIGAM:
            let count = Int(data.bigEndianValue(at: 4) as UInt32)
            let entrySize = MemoryLayout<fat_arch>.size
            guard (1 ..< 20).contains(count), data.holds(8, count * entrySize) else { return false }
            for index in 0 ..< count {
                let entry = 8 + index * entrySize
                let cpuType = cpu_type_t(bitPattern: data.bigEndianValue(at: entry) as UInt32)
                if cpuType == CPU_TYPE_ARM { continue }
                guard VPhoneMachOImage.armCPUTypes.contains(cpuType) else { return false }
                let offset = Int(data.bigEndianValue(at: entry + 8) as UInt32)
                let length = Int(data.bigEndianValue(at: entry + 12) as UInt32)
                guard data.holds(offset, length) else { return false }
                sliceRanges.append(offset ..< offset + length)
            }
            guard !sliceRanges.isEmpty else { return false }
        case MH_MAGIC_64:
            sliceRanges.append(0 ..< data.count)
        default:
            return false
        }

        let headerSize = MemoryLayout<mach_header_64>.size
        let libraryTypes: Set<UInt32> = [UInt32(MH_DYLIB), UInt32(MH_BUNDLE)]
        for range in sliceRanges {
            guard range.count >= headerSize else { return false }
            let base = range.lowerBound
            guard data.littleEndianValue(at: base) as UInt32 == MH_MAGIC_64 else { return false }
            let cpuType = cpu_type_t(bitPattern: data.littleEndianValue(at: base + 4) as UInt32)
            guard VPhoneMachOImage.armCPUTypes.contains(cpuType) else { return false }
            let fileType: UInt32 = data.littleEndianValue(at: base + 12)
            guard libraryTypes.contains(fileType) else { continue }

            let commandCount: UInt32 = data.littleEndianValue(at: base + 16)
            let commandsSize = Int(data.littleEndianValue(at: base + 20) as UInt32)
            guard headerSize + commandsSize <= range.count else { return false }

            var signature: (offset: Int, size: Int)?
            var hasLinkedit = false
            var cursor = 0
            for _ in 0 ..< commandCount {
                guard cursor + 8 <= commandsSize else { return false }
                let start = base + headerSize + cursor
                let command: UInt32 = data.littleEndianValue(at: start)
                let size = Int(data.littleEndianValue(at: start + 4) as UInt32)
                guard size >= 8, size % 8 == 0, cursor + size <= commandsSize else { return false }
                if command == UInt32(LC_CODE_SIGNATURE), size >= MemoryLayout<linkedit_data_command>.size {
                    signature = (
                        Int(data.littleEndianValue(at: start + 8) as UInt32),
                        Int(data.littleEndianValue(at: start + 12) as UInt32),
                    )
                } else if command == UInt32(LC_SEGMENT_64), size >= MemoryLayout<segment_command_64>.size {
                    let segName = data[data.startIndex + start + 8 ..< data.startIndex + start + 24]
                        .prefix { $0 != 0 }
                    if segName.elementsEqual("__LINKEDIT".utf8) {
                        hasLinkedit = true
                    }
                }
                cursor += size
            }
            guard hasLinkedit else { return false }
            guard let signature else { return true }
            guard signature.offset >= 0, signature.size >= 0,
                  signature.offset <= range.count, signature.size <= range.count - signature.offset,
                  signature.offset + signature.size == range.count
            else { return false }
            let blobStart = data.startIndex + base + signature.offset
            let blob = data[blobStart ..< blobStart + signature.size]
            if VPhoneCodeSignature.needsAdHocUpgrade(in: blob) {
                return true
            }
        }
        return false
    }
}

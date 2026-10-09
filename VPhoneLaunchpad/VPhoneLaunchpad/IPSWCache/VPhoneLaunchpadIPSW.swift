import Compression
import CryptoKit
import Foundation

// MARK: - IPSW facts

/// What an IPSW is for, read from its BuildManifest (the same fields
/// `VPhoneIPSWCache.inspect` reads), or guessed from its file name when the
/// manifest cannot be read.
nonisolated struct VPhoneLaunchpadIPSW: Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        case iPhone, iPad, cloudOS, unknown

        /// The system the IPSW installs: the first word of its title.
        var systemName: String? {
            switch self {
            case .iPhone: "iOS"
            case .iPad: "iPadOS"
            case .cloudOS: "cloudOS"
            case .unknown: nil
            }
        }
    }

    /// The cloudOS build identity vphone boots the guest's hardware from
    /// (`VPhoneIPSWCache.cloudOSDeviceClass`).
    static let cloudOSDeviceClass = "vresearch101ap"

    var version: String
    var build: String
    /// `SupportedProductTypes`, such as `iPhone17,3`.
    var productTypes: [String]
    /// Every build identity's `Info.DeviceClass`, lowercased. Empty when the
    /// facts come from the file name.
    var deviceClasses: Set<String>
    /// False when the facts were guessed from the file name.
    var fromManifest: Bool

    var kind: Kind {
        if deviceClasses.contains(Self.cloudOSDeviceClass) {
            return .cloudOS
        }
        if productTypes.contains(where: { $0.hasPrefix("iPad") }) {
            return .iPad
        }
        if productTypes.contains(where: { $0.hasPrefix("iPhone") }) {
            return .iPhone
        }
        return .unknown
    }

    /// `iOS 26.6.2 (23G90)`; nil for a kind it cannot name.
    var title: String? {
        kind.systemName.map { "\($0) \(version) (\(build))" }
    }

    // MARK: Manifest

    init(version: String, build: String, productTypes: [String], deviceClasses: Set<String>, fromManifest: Bool) {
        self.version = version
        self.build = build
        self.productTypes = productTypes
        self.deviceClasses = deviceClasses
        self.fromManifest = fromManifest
    }

    /// The facts in a parsed BuildManifest; nil without a version and build.
    init?(manifest plist: [String: Any]) {
        guard let version = plist["ProductVersion"] as? String, !version.isEmpty,
              let build = plist["ProductBuildVersion"] as? String, !build.isEmpty
        else {
            return nil
        }
        let identities = plist["BuildIdentities"] as? [[String: Any]] ?? []
        let classes = identities.compactMap { identity in
            ((identity["Info"] as? [String: Any])?["DeviceClass"] as? String)?.lowercased()
        }
        self.init(
            version: version,
            build: build,
            productTypes: plist["SupportedProductTypes"] as? [String] ?? [],
            deviceClasses: Set(classes),
            fromManifest: true,
        )
    }

    /// Reads `BuildManifest.plist` out of the archive without unpacking
    /// anything else: the central directory at the end of the file, then the
    /// one member.
    static func read(_ file: URL) throws -> VPhoneLaunchpadIPSW {
        let data = try VPhoneLaunchpadZipReader.readMember("BuildManifest.plist", from: file)
        guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let facts = VPhoneLaunchpadIPSW(manifest: plist)
        else {
            throw VPhoneLaunchpadZipReader.Failure.malformed
        }
        return facts
    }

    // MARK: File name

    /// The facts an IPSW's name carries: `iPhone17,3_27.0_24A435_Restore.ipsw`,
    /// `iPad16,1,iPad16,2_26.6.2_23G90_Restore.ipsw`, and the cache's spelling
    /// of either, `iPhone17_3_27.0_24A435_Restore-3c6d6dc0803d.ipsw`.
    init?(fileName: String) {
        var stem = fileName
        if stem.lowercased().hasSuffix(".ipsw") {
            stem = String(stem.dropLast(5))
        }
        // The cache appends a dash and twelve hex digits of the URL's digest.
        if let dash = stem.lastIndex(of: "-") {
            let digest = stem[stem.index(after: dash)...]
            if digest.count == 12, digest.allSatisfy(\.isHexDigit) {
                stem = String(stem[..<dash])
            }
        }
        let fields = stem.split(separator: "_", omittingEmptySubsequences: false).map(String.init)
        guard let restore = fields.lastIndex(where: { $0.caseInsensitiveCompare("Restore") == .orderedSame }),
              restore >= 3
        else {
            return nil
        }
        let build = fields[restore - 1]
        let version = fields[restore - 2]
        guard !build.isEmpty, version.first?.isNumber == true, version.allSatisfy({ $0.isNumber || $0 == "." }) else {
            return nil
        }
        let products = Self.productTypes(in: fields[..<(restore - 2)].joined(separator: "_"))
        let isCloud = stem.localizedCaseInsensitiveContains("cloudOS")
        self.init(
            version: version,
            build: build,
            productTypes: products,
            deviceClasses: isCloud ? [Self.cloudOSDeviceClass] : [],
            fromManifest: false,
        )
    }

    /// `iPad16,1,iPad16,2` or the cache's `iPad16_1_iPad16_2` as product types.
    static func productTypes(in text: String) -> [String] {
        var types: [String] = []
        var remaining = Substring(text)
        while let start = remaining.firstIndex(where: \.isLetter) {
            remaining = remaining[start...]
            let letters = remaining.prefix(while: \.isLetter)
            let afterLetters = remaining[letters.endIndex...]
            let major = afterLetters.prefix(while: \.isNumber)
            guard !major.isEmpty else {
                remaining = afterLetters
                continue
            }
            var rest = afterLetters[major.endIndex...]
            var type = "\(letters)\(major)"
            if let separator = rest.first, separator == "," || separator == "_" {
                let minor = rest.dropFirst().prefix(while: \.isNumber)
                if !minor.isEmpty {
                    type += ",\(minor)"
                    rest = rest.dropFirst().dropFirst(minor.count)
                }
            }
            types.append(type)
            remaining = rest
        }
        return types
    }

    // MARK: Cache names

    /// The name `fw prepare` gives the file it downloads from `url`
    /// (`VPhoneIPSWCache.cacheName`): the URL's last component made safe, a
    /// dash and twelve hex digits of the URL's SHA-256.
    static func cacheName(for url: URL) -> String {
        let base = url.lastPathComponent
        let stem = base.lowercased().hasSuffix(".ipsw") ? String(base.dropLast(5)) : base
        let safe = String(stem.prefix(48).unicodeScalars.map { scalar in
            let value = scalar.value
            return (value >= 48 && value <= 57) || (value >= 65 && value <= 90)
                || (value >= 97 && value <= 122) || value == 45 || value == 46 || value == 95
                ? Character(scalar) : "_"
        })
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        let suffix = digest.prefix(6).map { String(format: "%02x", $0) }.joined()
        return "\(safe.isEmpty ? "firmware" : safe)-\(suffix).ipsw"
    }

    /// The cache file a download in progress becomes:
    /// `.<cache name>.<UUID>.partial` is `<cache name>`.
    static func finalName(ofPartial name: String) -> String? {
        guard name.hasPrefix("."), name.hasSuffix(".partial") else {
            return nil
        }
        let inner = name.dropFirst().dropLast(".partial".count)
        guard let dot = inner.lastIndex(of: "."), UUID(uuidString: String(inner[inner.index(after: dot)...])) != nil else {
            return nil
        }
        let final = String(inner[..<dot])
        return final.isEmpty ? nil : final
    }
}

// MARK: - Zip

/// Reads one member of a zip archive, ZIP64 included, the way an IPSW is laid
/// out: stored or deflated members, a central directory at the end.
nonisolated enum VPhoneLaunchpadZipReader {
    enum Failure: Error {
        case notZip
        case missing(String)
        case unsupported(UInt16)
        case malformed
        case tooLarge
    }

    /// A manifest is a few megabytes; refuse anything absurd rather than
    /// allocate it.
    static let memberLimit: UInt64 = 64 << 20
    static let directoryLimit: UInt64 = 64 << 20

    static func readMember(_ name: String, from file: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        let directory = try centralDirectory(handle, size: size)
        guard let entry = try find(name, in: directory) else {
            throw Failure.missing(name)
        }
        guard entry.compressedSize <= memberLimit, entry.uncompressedSize <= memberLimit else {
            throw Failure.tooLarge
        }
        let local = try read(handle, at: entry.localHeaderOffset, count: 30)
        guard local.u32(0) == 0x0403_4B50 else {
            throw Failure.malformed
        }
        let start = entry.localHeaderOffset + 30 + UInt64(local.u16(26)) + UInt64(local.u16(28))
        let stored = try read(handle, at: start, count: Int(entry.compressedSize))
        switch entry.method {
        case 0:
            return stored
        case 8:
            return try inflate(stored, expected: Int(entry.uncompressedSize))
        default:
            throw Failure.unsupported(entry.method)
        }
    }

    struct Entry {
        var method: UInt16
        var compressedSize: UInt64
        var uncompressedSize: UInt64
        var localHeaderOffset: UInt64
    }

    /// The central directory's bytes, found through the end record and, for
    /// archives over 4 GB, its ZIP64 counterpart.
    static func centralDirectory(_ handle: FileHandle, size: UInt64) throws -> Data {
        let tailLength = min(size, 65535 + 22 + 20)
        let tail = try read(handle, at: size - tailLength, count: Int(tailLength))
        guard tail.count >= 22 else {
            throw Failure.notZip
        }
        var end: Int?
        var index = tail.count - 22
        while index >= 0 {
            if tail.u32(index) == 0x0605_4B50 {
                end = index
                break
            }
            index -= 1
        }
        guard let end else {
            throw Failure.notZip
        }
        var directorySize = UInt64(tail.u32(end + 12))
        var directoryOffset = UInt64(tail.u32(end + 16))
        let locator = end - 20
        if locator >= 0, tail.u32(locator) == 0x0706_4B50 {
            let recordOffset = tail.u64(locator + 8)
            let record = try read(handle, at: recordOffset, count: 56)
            guard record.u32(0) == 0x0606_4B50 else {
                throw Failure.malformed
            }
            directorySize = record.u64(40)
            directoryOffset = record.u64(48)
        }
        guard directorySize <= directoryLimit, directoryOffset + directorySize <= size else {
            throw Failure.malformed
        }
        return try read(handle, at: directoryOffset, count: Int(directorySize))
    }

    static func find(_ name: String, in directory: Data) throws -> Entry? {
        let wanted = Data(name.utf8)
        var offset = 0
        while offset + 46 <= directory.count, directory.u32(offset) == 0x0201_4B50 {
            let nameLength = Int(directory.u16(offset + 28))
            let extraLength = Int(directory.u16(offset + 30))
            let commentLength = Int(directory.u16(offset + 32))
            let next = offset + 46 + nameLength + extraLength + commentLength
            guard next <= directory.count else {
                throw Failure.malformed
            }
            let nameRange = (offset + 46) ..< (offset + 46 + nameLength)
            if directory[directory.startIndex + nameRange.lowerBound ..< directory.startIndex + nameRange.upperBound] == wanted {
                var entry = Entry(
                    method: directory.u16(offset + 10),
                    compressedSize: UInt64(directory.u32(offset + 20)),
                    uncompressedSize: UInt64(directory.u32(offset + 24)),
                    localHeaderOffset: UInt64(directory.u32(offset + 42)),
                )
                applyZIP64(&entry, extra: directory, from: nameRange.upperBound, length: extraLength)
                return entry
            }
            offset = next
        }
        return nil
    }

    /// Sizes and the offset that do not fit 32 bits are 0xFFFFFFFF in the
    /// entry and follow, in that order, in the ZIP64 extra field (id 1).
    static func applyZIP64(_ entry: inout Entry, extra data: Data, from start: Int, length: Int) {
        let marker = UInt64(UInt32.max)
        var offset = start
        let end = start + length
        while offset + 4 <= end {
            let id = data.u16(offset)
            let size = Int(data.u16(offset + 2))
            if id == 1 {
                var field = offset + 4
                let fieldEnd = min(field + size, end)
                if entry.uncompressedSize == marker, field + 8 <= fieldEnd {
                    entry.uncompressedSize = data.u64(field)
                    field += 8
                }
                if entry.compressedSize == marker, field + 8 <= fieldEnd {
                    entry.compressedSize = data.u64(field)
                    field += 8
                }
                if entry.localHeaderOffset == marker, field + 8 <= fieldEnd {
                    entry.localHeaderOffset = data.u64(field)
                }
                return
            }
            offset += 4 + size
        }
    }

    static func inflate(_ data: Data, expected: Int) throws -> Data {
        guard expected > 0 else {
            return Data()
        }
        var output = Data(count: expected)
        let written = output.withUnsafeMutableBytes { destination in
            data.withUnsafeBytes { source in
                // COMPRESSION_ZLIB is raw deflate, as zip stores it.
                compression_decode_buffer(
                    destination.bindMemory(to: UInt8.self).baseAddress!, expected,
                    source.bindMemory(to: UInt8.self).baseAddress!, data.count,
                    nil, COMPRESSION_ZLIB,
                )
            }
        }
        guard written == expected else {
            throw Failure.malformed
        }
        return output
    }

    static func read(_ handle: FileHandle, at offset: UInt64, count: Int) throws -> Data {
        try handle.seek(toOffset: offset)
        let data = try handle.read(upToCount: count) ?? Data()
        guard data.count == count else {
            throw Failure.malformed
        }
        return data
    }
}

private extension Data {
    nonisolated func u16(_ offset: Int) -> UInt16 {
        let base = startIndex + offset
        return UInt16(self[base]) | UInt16(self[base + 1]) << 8
    }

    nonisolated func u32(_ offset: Int) -> UInt32 {
        UInt32(u16(offset)) | UInt32(u16(offset + 2)) << 16
    }

    nonisolated func u64(_ offset: Int) -> UInt64 {
        UInt64(u32(offset)) | UInt64(u32(offset + 4)) << 32
    }
}

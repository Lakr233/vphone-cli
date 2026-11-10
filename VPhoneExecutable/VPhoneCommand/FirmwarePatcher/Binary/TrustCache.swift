// TrustCache.swift — The payload of a static trust cache, versions 1 and 2.
//
// Both versions start with a version, a UUID and an entry count, all little
// endian, and list their entries sorted by CDHash:
//
//   version 1: cdhash[20] hash_type flags                              (22 bytes)
//   version 2: cdhash[20] hash_type flags constraint_category reserved (24 bytes)
//
// Apple's iOS trust caches (the OS, and the System and App OS cryptexes) are
// version 2; `cryptexctl generate-trust-cache` writes version 1, which has no
// constraint category.

import CryptoKit
import Foundation
import VPhonePatchKit

struct TrustCache: Equatable {
    struct Entry: Equatable {
        var cdHash: Data
        var hashType: UInt8
        var flags: UInt8
        /// The launch-constraint category; 0 is none, and the only value version 1 has.
        var constraintCategory: UInt8 = 0
    }

    static let headerSize = 24
    static let cdHashSize = 20

    var version: UInt32
    var uuid: Data
    var entries: [Entry]

    static func entrySize(version: UInt32) -> Int? {
        switch version {
        case 1: 22
        case 2: 24
        default: nil
        }
    }

    init(version: UInt32, uuid: Data, entries: [Entry]) {
        self.version = version
        self.uuid = uuid
        self.entries = entries
    }

    init(payload data: Data) throws {
        let data = data.startIndex == 0 ? data : Data(data)
        guard data.count >= Self.headerSize else {
            throw PatcherError.invalidFormat("trust cache is \(data.count) bytes, shorter than its header")
        }
        version = data.loadLE(UInt32.self, at: 0)
        guard let entrySize = Self.entrySize(version: version) else {
            throw PatcherError.invalidFormat("trust cache version \(version) is neither 1 nor 2")
        }
        uuid = data[4 ..< 20]
        let count = Int(data.loadLE(UInt32.self, at: 20))
        guard Self.headerSize + count * entrySize == data.count else {
            throw PatcherError.invalidFormat(
                "trust cache size \(data.count) does not match its \(count) version \(version) entries",
            )
        }
        entries = (0 ..< count).map { index in
            let offset = Self.headerSize + index * entrySize
            return Entry(
                cdHash: data[offset ..< offset + Self.cdHashSize],
                hashType: data[offset + 20],
                flags: data[offset + 21],
                constraintCategory: entrySize == 24 ? data[offset + 22] : 0,
            )
        }
    }

    var payload: Data {
        let entrySize = Self.entrySize(version: version)!
        var data = Data(capacity: Self.headerSize + entries.count * entrySize)
        withUnsafeBytes(of: version.littleEndian) { data.append(contentsOf: $0) }
        data.append(uuid)
        withUnsafeBytes(of: UInt32(entries.count).littleEndian) { data.append(contentsOf: $0) }
        for entry in entries {
            data.append(entry.cdHash)
            data.append(entry.hashType)
            data.append(entry.flags)
            if version == 2 {
                data.append(entry.constraintCategory)
                data.append(0)
            }
        }
        return data
    }

    // MARK: - Constraint Categories

    /// This cache as version 2, every entry with the category Apple's own
    /// caches give its CDHash.
    ///
    /// A binary the merge left alone has the CDHash it had in the IPSW, so its
    /// category is in `originals`. A binary the merge patched and signed again
    /// has a new CDHash; `inherited` maps it to the CDHashes it had before, and
    /// it gets their category. Anything else — vphoned, the GPU driver, an
    /// Apple binary Apple left out of its caches — keeps 0, as before.
    /// Entries, their order, flags and the UUID stay as they are.
    func withConstraintCategories(from originals: [TrustCache], inherited: [Data: [Data]] = [:]) -> TrustCache {
        var categories: [Data: UInt8] = [:]
        for original in originals {
            for entry in original.entries where categories[entry.cdHash] == nil {
                categories[entry.cdHash] = entry.constraintCategory
            }
        }
        func category(_ cdHash: Data) -> UInt8 {
            if let category = categories[cdHash] { return category }
            // Every slice of a binary has the same category.
            let previous = Set((inherited[cdHash] ?? []).compactMap { categories[$0] })
            return previous.count == 1 ? previous.first! : 0
        }
        return TrustCache(version: 2, uuid: uuid, entries: entries.map { entry in
            var entry = entry
            entry.constraintCategory = category(entry.cdHash)
            return entry
        })
    }

    // MARK: - Restricted Execution Mode

    /// Flags of an entry that may run before (`0x40`) and after (`0x80`) the
    /// system enters Restricted Execution Mode. `cryptexctl generate-trust-cache
    /// --restricted-exec-mode-default` writes `0x40` for before, `0x80` for
    /// after, `0xC0` for both, which is also what it writes with no option
    /// (its help says "before"), and `0x00` for none.
    static let restrictedExecutionBothPhases: UInt8 = 0xC0

    /// Every entry allowed in both REM phases, each CDHash once.
    ///
    /// A trusted darwinOS guest enforces REM: AMFI kills launchd itself if its
    /// entry has neither bit ("not allowed for Restricted Execution Mode
    /// state"). cryptexctl gives the binaries its scan finds `0xC0`, but copies
    /// each `--base-trust-cache` entry as it is, and Apple's iOS entries are
    /// `0x00`; the same CDHash is then in the cache twice, once allowed and once
    /// not. One entry per CDHash, allowed, is what is left.
    func allowingBothRestrictedExecutionPhases() -> TrustCache {
        var seen = Set<Data>()
        var allowed: [Entry] = []
        for entry in entries where seen.insert(entry.cdHash + [entry.hashType]).inserted {
            var entry = entry
            entry.flags |= Self.restrictedExecutionBothPhases
            allowed.append(entry)
        }
        return TrustCache(version: version, uuid: uuid, entries: allowed)
    }

    // MARK: - CDHashes

    /// The CDHash of each CodeDirectory in each slice of a Mach-O, which is
    /// what a trust cache lists for it. Empty for anything without a signature.
    static func cdHashes(ofMachO data: Data) -> [Data] {
        let data = data.startIndex == 0 ? data : Data(data)
        var slices = [data]
        if MachOFatSlice.isFat(data) {
            let count = Int(UInt32(bigEndian: data.loadLE(UInt32.self, at: 4)))
            slices = (0 ..< count).compactMap { index in
                let entry = 8 + index * 20
                guard entry + 20 <= data.count else { return nil }
                let offset = Int(UInt32(bigEndian: data.loadLE(UInt32.self, at: entry + 8)))
                let size = Int(UInt32(bigEndian: data.loadLE(UInt32.self, at: entry + 12)))
                guard offset + size <= data.count else { return nil }
                return data.subdata(in: offset ..< offset + size)
            }
        }
        return slices.flatMap { slice in
            (CustomFirmwareMachOCodeSignature.codeDirectories(in: slice) ?? []).compactMap { directory in
                let blob = slice[directory.offset ..< directory.offset + directory.length]
                let digest: Data
                switch directory.hashType {
                case CustomFirmwareMachOCodeSignature.hashTypeSHA1:
                    digest = Data(Insecure.SHA1.hash(data: blob))
                case CustomFirmwareMachOCodeSignature.hashTypeSHA256,
                     CustomFirmwareMachOCodeSignature.hashTypeSHA256Truncated:
                    digest = Data(SHA256.hash(data: blob))
                case CustomFirmwareMachOCodeSignature.hashTypeSHA384:
                    digest = Data(SHA384.hash(data: blob))
                default:
                    return nil
                }
                return digest.prefix(cdHashSize)
            }
        }
    }
}

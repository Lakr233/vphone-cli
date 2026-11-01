// CustomFirmwareDetachedSignature.swift — the detached signature that makes launchd.plist the secure cache.
//
// What the stock loader checks. `/usr/libexec/launchd_cache_loader` (libxpc-2894,
// iOS 18.6 22G86) hands launchd `/System/Library/xpc/launchd.plist` only after:
//
//   1. `SecStaticCodeCreateWithPath(launchd.plist)` and
//      `SecCodeSetDetachedSignature(launchd.plist.sig)`;
//   2. `SecStaticCodeCheckValidity(…, 6)` (skip executable and resources; the
//      one error it tolerates is errSecCSSignatureNotVerifiable, an ad hoc
//      signature has no anchor to verify);
//   3. `SecCodeCopySigningInformation` → `kSecCodeInfoUnique`, the cdhash, which
//      it asks AMFI about (`IOConnectCallMethod` selector 6 on the
//      `AppleMobileFileIntegrity` user client): "cdhash: %s is trusted" or
//      "… is not in trust cache", which aborts;
//   4. `SecCodeMapMemory`, which pushes the signature to the kernel, so every
//      page the loader then `mmap`s and copies into launchd is checked against
//      the code directory's page hashes ("Failed to push signature to kernel").
//
// The `launchd_unsecure_cache=` boot-arg skips all four. The stock static trust
// cache carries both cdhashes of Apple's `launchd.plist.sig`, so a stock system
// passes. Rewriting `launchd.plist` (vphoned's entry) leaves Apple's signature
// describing the old bytes, which is why `minimal` used to NOP the boot-arg
// gate instead. Re-signing the edited file the way Apple signs it, and adding
// the new cdhashes to the static trust cache the restore already rebuilds and
// TSS already signs, gets the same file through the secure path with the
// loader stock.
//
// The shape is Apple's, byte for byte: Apple's `extensions.plist.sig` from
// 22G86 is what `sign(_:identifierStem:)` produces for that file. A SuperBlob of
// five slots: a SHA-1 code directory, empty requirements, a SHA-256 alternate
// code directory, an empty CMS wrapper and an identification wrapper holding the
// file's SHA-1. Both code directories are version 0x20500, ad hoc with the
// runtime flag (0x10002) and runtime version 11.0.0, 4 KiB pages, two special slots (no Info.plist, the
// requirements hash) and the identifier `<stem>-<sha1 of the file>`.
// `codesign -s - -o runtime --pagesize 4096 --detached` writes the same thing
// except for a 0x20100 code directory header, so its cdhashes differ.

import CryptoKit
import Foundation

public enum CustomFirmwareDetachedSignature {
    // MARK: - Constants

    static let superBlobMagic: UInt32 = 0xFADE_0CC0
    static let codeDirectoryMagic: UInt32 = 0xFADE_0C02
    static let requirementsMagic: UInt32 = 0xFADE_0C01
    static let blobWrapperMagic: UInt32 = 0xFADE_0B01

    static let codeDirectoryVersion: UInt32 = 0x20500
    /// `CS_ADHOC | CS_RUNTIME`, as in Apple's xpc signatures.
    static let codeDirectoryFlags: UInt32 = 0x0001_0002
    /// Fixed header of a 0x20500 code directory; the identifier follows it.
    static let codeDirectoryHeaderSize = 0x60
    static let pageShift: UInt8 = 12
    /// Where the 0x20500 header keeps the hardened-runtime version, and the
    /// version Apple's xpc signatures carry there (11.0.0).
    static let runtimeVersionOffset = 0x58
    static let runtimeVersion: UInt32 = 0x000B_0000

    static let slotCodeDirectory: UInt32 = 0
    static let slotRequirements: UInt32 = 2
    static let slotAlternateCodeDirectory: UInt32 = 0x1000
    static let slotSignature: UInt32 = 0x10000
    static let slotIdentification: UInt32 = 0x10001

    /// `CS_HASHTYPE_SHA1` and `CS_HASHTYPE_SHA256`, which are also the trust
    /// cache entries' hash types.
    public static let hashTypeSHA1: UInt8 = 1
    public static let hashTypeSHA256: UInt8 = 2

    /// Apple's file next to the cache it signs.
    public static let launchdCachePath = "System/Library/xpc/launchd.plist"
    public static let launchdCacheSignaturePath = "System/Library/xpc/launchd.plist.sig"

    // MARK: - Signing

    /// The detached signature Apple ships beside an xpc cache plist.
    ///
    /// - Parameter identifierStem: the file name without `.plist`, as Apple's
    ///   identifiers have it (`launchd`, `extensions`).
    public static func sign(_ file: Data, identifierStem: String) -> Data {
        let fileSHA1 = Data(Insecure.SHA1.hash(data: file))
        let identifier = "\(identifierStem)-\(fileSHA1.map { String(format: "%02x", $0) }.joined())"

        var requirements = Data()
        requirements.appendBE32(requirementsMagic)
        requirements.appendBE32(UInt32(12))
        requirements.appendBE32(UInt32(0))

        let primary = codeDirectory(file, identifier: identifier, requirements: requirements, hashType: hashTypeSHA1)
        let alternate = codeDirectory(file, identifier: identifier, requirements: requirements, hashType: hashTypeSHA256)

        let blobs: [(UInt32, Data)] = [
            (slotCodeDirectory, primary),
            (slotRequirements, requirements),
            (slotAlternateCodeDirectory, alternate),
            (slotSignature, wrapper(Data())),
            (slotIdentification, wrapper(fileSHA1)),
        ]

        let headerSize = 12 + 8 * blobs.count
        var index = Data()
        var payload = Data()
        for (slot, blob) in blobs {
            index.appendBE32(slot)
            index.appendBE32(UInt32(headerSize + payload.count))
            payload.append(blob)
        }
        var superBlob = Data()
        superBlob.appendBE32(superBlobMagic)
        superBlob.appendBE32(UInt32(headerSize + payload.count))
        superBlob.appendBE32(UInt32(blobs.count))
        superBlob.append(index)
        superBlob.append(payload)
        return superBlob
    }

    static func codeDirectory(_ file: Data, identifier: String, requirements: Data, hashType: UInt8) -> Data {
        let hash: (Data) -> Data = hashType == hashTypeSHA1
            ? { Data(Insecure.SHA1.hash(data: $0)) }
            : { Data(SHA256.hash(data: $0)) }
        let hashSize = hashType == hashTypeSHA1 ? 20 : 32
        let pageSize = 1 << Int(pageShift)
        let pages = (file.count + pageSize - 1) / pageSize

        let identifierBytes = Data(identifier.utf8) + [0]
        let hashOffset = codeDirectoryHeaderSize + identifierBytes.count + 2 * hashSize

        var directory = Data()
        directory.appendBE32(codeDirectoryMagic)
        directory.appendBE32(UInt32(hashOffset + pages * hashSize))
        directory.appendBE32(codeDirectoryVersion)
        directory.appendBE32(codeDirectoryFlags)
        directory.appendBE32(UInt32(hashOffset))
        directory.appendBE32(UInt32(codeDirectoryHeaderSize))
        directory.appendBE32(UInt32(2)) // special slots: Info.plist, requirements
        directory.appendBE32(UInt32(pages))
        directory.appendBE32(UInt32(file.count))
        directory.append(contentsOf: [UInt8(hashSize), hashType, 0, pageShift])
        // spare2, scatter, team, spare3, codeLimit64 and the exec segment are
        // zero for a data file; the runtime version is Apple's 11.0.0, and
        // there is no pre-encryption offset.
        directory.append(Data(count: runtimeVersionOffset - directory.count))
        directory.appendBE32(runtimeVersion)
        directory.append(Data(count: codeDirectoryHeaderSize - directory.count))
        directory.append(identifierBytes)
        directory.append(hash(requirements)) // slot -2
        directory.append(Data(count: hashSize)) // slot -1: no Info.plist
        let base = file.startIndex
        for page in 0 ..< pages {
            let start = base + page * pageSize
            directory.append(hash(file[start ..< min(start + pageSize, file.endIndex)]))
        }
        return directory
    }

    static func wrapper(_ content: Data) -> Data {
        var blob = Data()
        blob.appendBE32(blobWrapperMagic)
        blob.appendBE32(UInt32(8 + content.count))
        blob.append(content)
        return blob
    }

    // MARK: - Reading

    /// One trust cache entry: a code directory's hash truncated to 20 bytes and
    /// the hash type it was computed with.
    public struct CodeDirectoryHash: Hashable, Sendable {
        public let cdhash: Data
        public let hashType: UInt8
    }

    /// The cdhash of every code directory in a signature SuperBlob — what a
    /// trust cache has to hold for AMFI to call the signature trusted.
    public static func codeDirectoryHashes(in signature: Data) throws -> [CodeDirectoryHash] {
        let signature = Data(signature)
        guard signature.count >= 12, signature.be32(at: 0) == superBlobMagic else {
            throw CustomFirmwareDetachedSignatureError.malformed("not a code signature SuperBlob")
        }
        let count = Int(signature.be32(at: 8))
        guard 12 + 8 * count <= signature.count else {
            throw CustomFirmwareDetachedSignatureError.malformed("SuperBlob index runs past the end")
        }
        var hashes: [CodeDirectoryHash] = []
        for entry in 0 ..< count {
            let offset = Int(signature.be32(at: 12 + 8 * entry + 4))
            guard offset + 8 <= signature.count,
                  signature.be32(at: offset) == codeDirectoryMagic
            else { continue }
            let length = Int(signature.be32(at: offset + 4))
            guard length >= 0x28, offset + length <= signature.count else {
                throw CustomFirmwareDetachedSignatureError.malformed("code directory at \(offset) runs past the end")
            }
            let directory = signature[offset ..< offset + length]
            let hashType = signature[offset + 0x25]
            let digest: Data = switch hashType {
            case hashTypeSHA1: Data(Insecure.SHA1.hash(data: directory))
            case hashTypeSHA256: Data(SHA256.hash(data: directory))
            default:
                throw CustomFirmwareDetachedSignatureError.malformed("code directory hash type \(hashType)")
            }
            hashes.append(CodeDirectoryHash(cdhash: digest.prefix(20), hashType: hashType))
        }
        return hashes
    }

    // MARK: - Trust cache

    /// A raw version 1 trust cache holding `hashes`, sorted as AMFI's binary
    /// search needs them. `cryptexctl generate-trust-cache` takes it as one more
    /// `--base-trust-cache` and merges it into the static one.
    public static func trustCache(_ hashes: [CodeDirectoryHash], uuid: UUID = UUID()) -> Data {
        let entries = Set(hashes).sorted { $0.cdhash.lexicographicallyPrecedes($1.cdhash) }
        var data = Data()
        data.appendLE32(UInt32(1))
        data.append(contentsOf: withUnsafeBytes(of: uuid.uuid) { Array($0) })
        data.appendLE32(UInt32(entries.count))
        for entry in entries {
            data.append(entry.cdhash)
            data.append(contentsOf: [entry.hashType, 0]) // flags: none
        }
        return data
    }
}

public enum CustomFirmwareDetachedSignatureError: Error, CustomStringConvertible {
    case malformed(String)

    public var description: String {
        switch self {
        case let .malformed(reason): "Detached signature: \(reason)"
        }
    }
}

// MARK: - Bytes

private extension Data {
    mutating func appendBE32(_ value: UInt32) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }

    mutating func appendLE32(_ value: UInt32) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }

    func be32(at offset: Int) -> UInt32 {
        let start = startIndex + offset
        return self[start ..< start + 4].reduce(0) { $0 << 8 | UInt32($1) }
    }
}

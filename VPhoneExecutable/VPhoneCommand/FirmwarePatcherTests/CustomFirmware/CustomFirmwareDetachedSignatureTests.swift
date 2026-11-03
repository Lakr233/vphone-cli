import CryptoKit
@testable import FirmwarePatcher
import Foundation
import Security
import Testing

/// Security exports it on macOS too, but only declares it in a private header:
/// it is the call `launchd_cache_loader` makes.
@_silgen_name("SecCodeSetDetachedSignature")
private func secCodeSetDetachedSignature(_ code: SecStaticCode, _ signature: CFData, _ flags: SecCSFlags) -> OSStatus

@Suite("launchd.plist detached signature")
struct CustomFirmwareDetachedSignatureTests {
    /// A plist-sized input whose last page is partial, so the page hashing and
    /// the code limit are both exercised.
    static let cache: Data = {
        var bytes = Data(count: 3 * 4096 + 123)
        for index in bytes.indices {
            bytes[index] = UInt8(truncatingIfNeeded: index &* 31 &+ 7)
        }
        return bytes
    }()

    static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    @Test
    func `has Apple's five slots and identifier`() throws {
        let signature = CustomFirmwareDetachedSignature.sign(Self.cache, identifierStem: "launchd")
        let sha1 = Data(Insecure.SHA1.hash(data: Self.cache))
        let identifier = "launchd-\(Self.hex(sha1))"
        #expect(signature.range(of: Data(identifier.utf8)) != nil)
        // The identification slot is the last blob: a wrapper of the file's SHA-1.
        #expect(signature.suffix(20) == sha1)

        let hashes = try CustomFirmwareDetachedSignature.codeDirectoryHashes(in: signature)
        #expect(hashes.map(\.hashType) == [CustomFirmwareDetachedSignature.hashTypeSHA1, CustomFirmwareDetachedSignature.hashTypeSHA256])
        #expect(hashes.allSatisfy { $0.cdhash.count == 20 })
        // Same bytes, same signature: the restore image stays reproducible.
        #expect(CustomFirmwareDetachedSignature.sign(Self.cache, identifierStem: "launchd") == signature)
        // A changed byte moves both cdhashes.
        var edited = Self.cache
        edited[5000] ^= 1
        let editedHashes = try CustomFirmwareDetachedSignature.codeDirectoryHashes(
            in: CustomFirmwareDetachedSignature.sign(edited, identifierStem: "launchd"),
        )
        #expect(Set(editedHashes).isDisjoint(with: hashes))
    }

    /// What `launchd_cache_loader` does with the pair, through the same
    /// Security calls on the host: attach the detached signature, check it with
    /// flags 6, and read the cdhash it then asks AMFI about.
    @Test
    func `passes the loader's Security checks with the cdhash the trust cache holds`() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("launchd.plist")
        try Self.cache.write(to: file)
        let signature = CustomFirmwareDetachedSignature.sign(Self.cache, identifierStem: "launchd")

        var code: SecStaticCode?
        #expect(SecStaticCodeCreateWithPath(file as CFURL, [], &code) == errSecSuccess)
        let staticCode = try #require(code)
        #expect(secCodeSetDetachedSignature(staticCode, signature as CFData, []) == errSecSuccess)
        let validity = SecStaticCodeCheckValidity(staticCode, SecCSFlags(rawValue: 6), nil)
        // The loader lets errSecCSSignatureNotVerifiable (-67060) through.
        #expect(validity == errSecSuccess || validity == -67060, "SecStaticCodeCheckValidity: \(validity)")
        // Full validation, page hashes included, holds as well.
        #expect(SecStaticCodeCheckValidity(staticCode, [], nil) == errSecSuccess)

        var information: CFDictionary?
        #expect(SecCodeCopySigningInformation(staticCode, [], &information) == errSecSuccess)
        let unique = try #require((information as? [String: Any])?[kSecCodeInfoUnique as String] as? Data)
        let hashes = try CustomFirmwareDetachedSignature.codeDirectoryHashes(in: signature)
        #expect(hashes.map(\.cdhash).contains(unique.prefix(20)))
    }

    @Test
    func `writes a sorted version 1 trust cache without duplicates`() throws {
        let hashes = try CustomFirmwareDetachedSignature.codeDirectoryHashes(
            in: CustomFirmwareDetachedSignature.sign(Self.cache, identifierStem: "launchd"),
        )
        let uuid = UUID()
        let cache = CustomFirmwareDetachedSignature.trustCache(hashes + hashes, uuid: uuid)
        #expect(cache.count == 24 + 2 * 22)
        #expect(cache.prefix(4) == Data([1, 0, 0, 0]))
        #expect(cache[4 ..< 20] == withUnsafeBytes(of: uuid.uuid) { Data($0) })
        #expect(cache[20 ..< 24] == Data([2, 0, 0, 0]))
        let first = cache[24 ..< 44]
        let second = cache[46 ..< 66]
        #expect(first.lexicographicallyPrecedes(second))
        for (offset, cdhash) in [(24, first), (46, second)] {
            let entry = try #require(hashes.first { $0.cdhash == cdhash })
            #expect(cache[offset + 20] == entry.hashType)
            #expect(cache[offset + 21] == 0)
        }
    }

    @Test
    func `rejects what is not a signature`() {
        #expect(throws: CustomFirmwareDetachedSignatureError.self) {
            try CustomFirmwareDetachedSignature.codeDirectoryHashes(in: Data("<plist/>".utf8))
        }
    }
}

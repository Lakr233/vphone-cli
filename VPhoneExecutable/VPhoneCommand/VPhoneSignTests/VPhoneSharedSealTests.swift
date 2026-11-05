import CryptoKit
import Foundation
import Testing
@testable import VPhoneSign

/// The resource seal a signature records, and the empty seal the iOS image
/// shares among the bundles that seal nothing — what the installer checks
/// before it writes the shared one back into a guest.
@Suite("Shared seal")
struct VPhoneSharedSealTests {
    // MARK: - Special slot 3

    /// Every CodeDirectory records the seal in its own hash: a SHA-1 one and
    /// a SHA-256 one side by side each give theirs, with their hash type.
    @Test func `the resource seal is read from every CodeDirectory`() throws {
        let sha1 = Data(repeating: 0x11, count: 20)
        let sha256 = Data(repeating: 0x22, count: 32)
        let blob = Self.superBlob([
            .init(hashType: 1, slot3: sha1, specialSlots: 5),
            .init(hashType: 2, slot3: sha256, specialSlots: 7),
        ])
        let recorded = VPhoneCodeSignature.resourceDirectoryHashes(in: blob)
        #expect(recorded.map(\.hashType) == [1, 2])
        #expect(recorded.map(\.hash) == [sha1, sha256])
    }

    /// Fewer than three special slots, or zeros in the third, is a signature
    /// that seals no resources; so is something that is not a SuperBlob.
    @Test func `a signature that seals no resources records nothing`() throws {
        #expect(VPhoneCodeSignature.resourceDirectoryHashes(in: Self.superBlob([
            .init(hashType: 2, slot3: Data(repeating: 0x33, count: 32), specialSlots: 2),
        ])).isEmpty)
        #expect(VPhoneCodeSignature.resourceDirectoryHashes(in: Self.superBlob([
            .init(hashType: 2, slot3: Data(count: 32), specialSlots: 5),
        ])).isEmpty)
        #expect(VPhoneCodeSignature.resourceDirectoryHashes(in: Data("not a signature".utf8)).isEmpty)
    }

    /// What vphone's own signer writes seals no bundle, so it records none.
    @Test func `a binary signed outside a bundle records no resource seal`() throws {
        let directory = try VPhoneSignFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let signed = try VPhoneSignFixtures.sign(VPhoneSignFixtures.url("hello-ios"), in: directory)
        #expect(try VPhoneSigner.resourceDirectoryHashes(in: Data(contentsOf: signed)).isEmpty)
    }

    // MARK: - The empty seal

    /// Byte for byte the file the 23G90 image hard-links into 5,503 bundles:
    /// this digest is what their CodeDirectories record in slot 3.
    @Test func `the empty seal is the one the image shares`() throws {
        let seal = try VPhoneSharedSeal.empty()
        #expect(Self.hex(SHA256.hash(data: seal)) == "3c727b0f043e463c0227db49cef54c5567715986d08a46c98923c9bb73585e5a")
        #expect(!VPhoneSharedSeal.listsFiles(seal))
    }

    /// The seal codesign wrote for one bundle lists that bundle's files.
    @Test func `a seal written for one bundle lists files`() throws {
        var dictionary = try #require(
            PropertyListSerialization.propertyList(from: VPhoneSharedSeal.empty(), format: nil) as? [String: Any],
        )
        dictionary["files2"] = ["VirtualAudio.bak": ["hash2": Data(repeating: 0x44, count: 32)]]
        let written = try PropertyListSerialization.data(fromPropertyList: dictionary, format: .xml, options: 0)
        #expect(VPhoneSharedSeal.listsFiles(written))
        #expect(!VPhoneSharedSeal.listsFiles(Data("not a plist".utf8)))
    }

    /// A seal matches a recorded hash only under that hash's own type.
    @Test func `a seal matches a recorded hash of its own type`() throws {
        typealias Recorded = [(hashType: UInt8, hash: Data)]
        let seal = try VPhoneSharedSeal.empty()
        let sha1 = Data(Insecure.SHA1.hash(data: seal))
        let sha256 = Data(SHA256.hash(data: seal))
        let bySHA1: Recorded = [(1, sha1)]
        let bySHA256: Recorded = [(2, sha256)]
        let byTruncatedSHA256: Recorded = [(3, sha256.prefix(20))]
        let wrongType: Recorded = [(2, sha1)]
        let unknownType: Recorded = [(9, sha256)]
        #expect(VPhoneSharedSeal.matches(seal, recorded: bySHA1))
        #expect(VPhoneSharedSeal.matches(seal, recorded: bySHA256))
        #expect(VPhoneSharedSeal.matches(seal, recorded: byTruncatedSHA256))
        #expect(!VPhoneSharedSeal.matches(seal, recorded: wrongType))
        #expect(!VPhoneSharedSeal.matches(seal + Data("\n".utf8), recorded: bySHA256))
        #expect(!VPhoneSharedSeal.matches(seal, recorded: unknownType))
        #expect(!VPhoneSharedSeal.matches(seal, recorded: Recorded()))
    }

    // MARK: - Building signatures

    struct Directory {
        var hashType: UInt8
        var slot3: Data
        var specialSlots: Int
    }

    /// A SuperBlob holding one CodeDirectory per entry (the first in slot 0,
    /// the rest in the alternate slots), each with no code slots, the given
    /// number of special slots, and `slot3` in the third; the other special
    /// slots hold 0xee so a read from the wrong one shows.
    static func superBlob(_ directories: [Directory]) -> Data {
        let blobs = directories.map { directory -> Data in
            let size = directory.slot3.count
            let header = 44
            let identifier = Data("t\0".utf8)
            let hashOffset = header + identifier.count + directory.specialSlots * size
            var blob = Data()
            blob.appendBigEndian(0xFADE_0C02 as UInt32)
            blob.appendBigEndian(UInt32(hashOffset))
            blob.appendBigEndian(0x20400 as UInt32)
            blob.appendBigEndian(0 as UInt32) // flags
            blob.appendBigEndian(UInt32(hashOffset))
            blob.appendBigEndian(UInt32(header)) // identifier
            blob.appendBigEndian(UInt32(directory.specialSlots))
            blob.appendBigEndian(0 as UInt32) // code slots
            blob.appendBigEndian(0 as UInt32) // code limit
            blob.append(contentsOf: [UInt8(size), directory.hashType, 0, 12])
            blob.appendBigEndian(0 as UInt32) // spare2
            blob.append(identifier)
            // Special slots are stored highest first, down to slot 1 just
            // before the code slots.
            for slot in stride(from: directory.specialSlots, through: 1, by: -1) {
                blob.append(slot == 3 ? directory.slot3 : Data(repeating: 0xEE, count: size))
            }
            return blob
        }
        var superBlob = Data()
        let indexEnd = 12 + 8 * blobs.count
        superBlob.appendBigEndian(0xFADE_0CC0 as UInt32)
        superBlob.appendBigEndian(UInt32(indexEnd + blobs.reduce(0) { $0 + $1.count }))
        superBlob.appendBigEndian(UInt32(blobs.count))
        var offset = indexEnd
        for (index, blob) in blobs.enumerated() {
            superBlob.appendBigEndian(index == 0 ? 0 as UInt32 : UInt32(0x1000 + index - 1))
            superBlob.appendBigEndian(UInt32(offset))
            offset += blob.count
        }
        for blob in blobs {
            superBlob.append(blob)
        }
        return superBlob
    }

    static func hex(_ digest: some Sequence<UInt8>) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}

import CryptoKit
@testable import FirmwarePatcher
import Foundation
import Testing

@Suite("Shared bundle seal")
struct CustomFirmwareBundleSealTests {
    /// A thin Mach-O whose one CodeDirectory has `resourceSlot` in special
    /// slot 3 (when it has three special slots) and `hashType` hashes.
    static func signed(resourceSlot: Data, specialSlots: UInt32 = 3, hashType: UInt8 = 2) -> Data {
        func le(_ value: UInt32) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
        func be(_ value: UInt32) -> Data { withUnsafeBytes(of: value.bigEndian) { Data($0) } }
        let hashSize = 32
        let identity = Data("com.apple.audio.VirtualAudio\0".utf8)
        let codeLimit = 0x1000
        var image = le(0xFEED_FACF) + le(0x0100_000C) + le(0x8000_0002) + le(8)
        image += le(1) + le(16) + le(0) + le(0)
        let hashOffset = 44 + identity.count + Int(specialSlots) * hashSize
        let directoryLength = hashOffset + hashSize
        let signatureLength = 20 + directoryLength
        image += le(0x1D) + le(16) + le(UInt32(codeLimit)) + le(UInt32(signatureLength))
        image += Data(count: codeLimit - image.count)
        var directory = be(0xFADE_0C02) + be(UInt32(directoryLength)) + be(0x20400) + be(0x2)
        directory += be(UInt32(hashOffset)) + be(44) + be(specialSlots) + be(1) + be(UInt32(codeLimit))
        directory += Data([UInt8(hashSize), hashType, 0, 12]) + be(0) + identity
        for slot in stride(from: Int(specialSlots), to: 0, by: -1) {
            directory += slot == 3 ? resourceSlot : Data(count: hashSize)
        }
        directory += Data(SHA256.hash(data: image.prefix(codeLimit)))
        return image + be(0xFADE_0CC0) + be(UInt32(signatureLength)) + be(1) + be(0) + be(20) + directory
    }

    @Test func `the rebuilt seal is the file iOS ships`() {
        let digest = Insecure.SHA1.hash(data: CustomFirmwareBundleSeal.empty)
        #expect(digest.map { String(format: "%02x", $0) }.joined() == "c0c8a907e2663ee1dc33a137fbfb55f253bcf464")
    }

    @Test func `an executable signed over the seal is recognized`() {
        let seal = CustomFirmwareBundleSeal.empty
        let executable = Self.signed(resourceSlot: Data(SHA256.hash(data: seal)))
        #expect(CustomFirmwareBundleSeal.executable(executable, isSealedWith: seal))
        #expect(!CustomFirmwareBundleSeal.executable(executable, isSealedWith: Data("<plist/>".utf8)))
    }

    @Test func `a signature without the resource slot or a known hash type tells nothing`() {
        let seal = CustomFirmwareBundleSeal.empty
        let hash = Data(SHA256.hash(data: seal))
        #expect(!CustomFirmwareBundleSeal.executable(Self.signed(resourceSlot: hash, specialSlots: 2), isSealedWith: seal))
        #expect(!CustomFirmwareBundleSeal.executable(Self.signed(resourceSlot: hash, hashType: 9), isSealedWith: seal))
        #expect(!CustomFirmwareBundleSeal.executable(Data(count: 64), isSealedWith: seal))
    }
}

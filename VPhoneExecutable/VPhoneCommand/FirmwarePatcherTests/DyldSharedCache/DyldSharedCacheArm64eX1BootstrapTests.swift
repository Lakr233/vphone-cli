@testable import FirmwarePatcher
import Foundation
import Testing
import VPhonePatchKit

@Suite("X1 shared-cache bootstrap")
struct DyldSharedCacheArm64eX1BootstrapTests {
    @Test func `V5 authenticated pointers retain key discriminator and cache base`() throws {
        let word: UInt64 = 0x8010_4D60_01C6_C73C
        #expect(try DyldSharedCacheArm64eX1BootstrapPatcher.authenticatedTargetV5(
            word: word,
            base: 0x1_8000_0000,
            diversity: 0x1358,
        ) == 0x1_81C6_C73C)
        for invalid in [word ^ (1 << 63), word | (1 << 50), word | (1 << 51)] {
            #expect(try DyldSharedCacheArm64eX1BootstrapPatcher.authenticatedTargetV5(
                word: invalid,
                base: 0x1_8000_0000,
                diversity: 0x1358,
            ) == nil)
        }
        #expect(try DyldSharedCacheArm64eX1BootstrapPatcher.authenticatedTargetV5(
            word: word,
            base: 0,
            diversity: 0x1359,
        ) == nil)
        #expect(throws: (any Error).self) {
            try DyldSharedCacheArm64eX1BootstrapPatcher.authenticatedTargetV5(
                word: word,
                base: UInt64.max,
                diversity: 0x1358,
            )
        }
    }

    @Test func `cached metadata produces VM-addressed bootstrap writes`() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let base: UInt64 = 0x1_8000_0000
        let imageAddress = base + 0x1000
        var cache = Data(repeating: 0, count: 0x5000)
        func put32(_ value: UInt32, _ offset: Int) {
            cache.replaceSubrange(offset ..< offset + 4, with: ARM64.encodeU32(value))
        }
        func put64(_ value: UInt64, _ offset: Int) {
            withUnsafeBytes(of: value.littleEndian) {
                cache.replaceSubrange(offset ..< offset + 8, with: $0)
            }
        }
        cache.replaceSubrange(0 ..< 15, with: Data("dyld_v1arm64ex1".utf8))
        put32(0x200, 0x10)
        put32(1, 0x14)
        put64(base, 0x200)
        put64(0x5000, 0x208)
        put64(0, 0x210)
        put32(5, 0x218)
        put32(5, 0x21C)

        let code: [UInt32] = [
            0xDAC1_A7FE, 0x9A0B_2909, 0xDA04_2063, 0xF3A0_007F, 0x5520_009F,
        ]
        var image = CustomFirmwareArm64eX1Tests.fixture(code)
        func word(_ value: UInt32, _ offset: Int) {
            image.replaceSubrange(offset ..< offset + 4, with: ARM64.encodeU32(value))
        }
        func quad(_ value: UInt64, _ offset: Int) {
            withUnsafeBytes(of: value.littleEndian) {
                image.replaceSubrange(offset ..< offset + 8, with: $0)
            }
        }
        word(3, 16)
        word(240, 20)
        quad(imageAddress, 56)
        quad(0x1000, 64)
        quad(0x1000, 72)
        quad(0x1000, 80)
        quad(imageAddress + 0x200, 136)
        word(0x1200, 152)
        word(0x3300, 192)
        word(0x19, 200)
        word(72, 204)
        image.replaceSubrange(
            208 ..< 224,
            with: Data("__LINKEDIT".utf8) + Data(repeating: 0, count: 6),
        )
        quad(base + 0x3000, 224)
        quad(0x1000, 232)
        quad(0x3000, 240)
        quad(0x1000, 248)
        cache.replaceSubrange(0x1000 ..< 0x1110, with: image[0 ..< 272])
        cache.replaceSubrange(0x1200 ..< 0x1214, with: image[0x200 ..< 0x214])
        cache.replaceSubrange(0x3300 ..< 0x3303, with: Data([0x80, 0x04, 0]))
        let url = directory.appendingPathComponent("dyld_shared_cache_arm64e_x1")
        try cache.write(to: url)

        let chunks = try DyldSharedCacheChunkSet(directory: directory)
        let plan = try DyldSharedCacheArm64eX1BootstrapPatcher.planImage(
            at: imageAddress,
            in: chunks,
        )
        #expect(plan.records.count == 5)
        #expect(plan.records.first?.fileOffset == Int(imageAddress + 0x200))
        #expect(plan.records.first?.patchedBytes == ARM64.pacibsp)
        #expect(plan.records.last?.patchedBytes == ARM64.retab)
        #expect(plan.records.allSatisfy { $0.patchID.hasPrefix(FirmwareGuestSystemPatchSet.arm64eX1CacheBootstrap + ".") })
        let remaining = try DyldSharedCacheArm64eX1BootstrapPatcher.planImage(
            at: imageAddress,
            in: chunks,
            identifier: FirmwareGuestSystemPatchSet.arm64eX1CacheRemaining,
        )
        #expect(remaining.records.map(\.patchedBytes) == plan.records.map(\.patchedBytes))
        #expect(remaining.records.allSatisfy { $0.patchID.hasPrefix(FirmwareGuestSystemPatchSet.arm64eX1CacheRemaining + ".") })
        #expect(try Data(contentsOf: url) == cache)

        put32(0x9000, 0x1000 + 192)
        try cache.write(to: url)
        #expect(throws: (any Error).self) {
            try DyldSharedCacheArm64eX1BootstrapPatcher.planImage(at: imageAddress, in: chunks)
        }
        #expect(try Data(contentsOf: url) == cache)
    }
}

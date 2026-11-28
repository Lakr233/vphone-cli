@testable import FirmwarePatcher
import Foundation
import MachO
import Testing
import VPhonePatchKit

@Suite("PV video decoder metadata")
struct VideoDecodeMetadataTests {
    typealias Metadata = DyldSharedCacheVideoDecodeMetadata
    let base: UInt64 = 0x2000
    let lock: UInt64 = 0x7000
    let unlock: UInt64 = 0x7010
    let storage: UInt64 = 0x7100
    let message: UInt64 = 0x7200
    let emit: UInt64 = 0x7300

    @Test func `standard enables PV repair across releases and preserves an old explicit opt-out`() throws {
        let patch = FirmwareGuestSystemPatchSet.videoDecoderFlow
        for version in ["16.7", "18.6", "26.6.1", "26.6.2", "27.0", "27.1", "27.2", "99.0", "unknown"] {
            for preset in FirmwarePatchSetCatalog.builtInPresets {
                let plan = try VPhonePatchPlan.resolve(
                    preset: preset, patchSets: FirmwarePatchSetCatalog.bundled,
                    iOSBase: VPhoneVersion(version), cloudOS: VPhoneVersion("26.4"))
                let enabled = [VPhonePatchPreset.standardIdentifier, "experimental"]
                    .contains(preset.identifier)
                #expect(plan.isEnabled(patch) == enabled, "\(preset.identifier) on \(version)")
            }
            let plan = try VPhonePatchPlan.resolve(
                preset: FirmwarePatchSetCatalog.standardPreset, patchSets: FirmwarePatchSetCatalog.bundled,
                iOSBase: VPhoneVersion(version), cloudOS: VPhoneVersion("26.4"),
                blocked: Set(FirmwarePatchSetCatalog.currentIdentifiers(["system-videocodecd-exp-pv_decoder_flow"])))
            #expect(!plan.isEnabled(patch))
        }
    }

    @Test func `unsupported layout skips never swallow corrupt caches or IO failures`() {
        let unsupported: [any Error] = [
            PatcherError.patchSiteNotFound("changed function"),
            DyldSharedCacheError.symbolNotFound(symbol: "private symbol", image: nil),
            DyldSharedCacheError.imageNotFound("VideoToolbox"),
            DyldSharedCacheError.localSymbolsMissing(path: "cache.symbols"),
        ]
        for error in unsupported { #expect(Metadata.isUnsupportedLayout(error)) }
        let failures: [any Error] = [
            PatcherError.patchVerificationFailed("malformed load command"),
            PatcherError.invalidFormat("invalid cache"),
            PatcherError.fileNotFound("cache"),
            DyldSharedCacheError.noChunksFound(directory: "cache"),
            DyldSharedCacheError.noMappingsParsed(directory: "cache"),
            DyldSharedCacheError.addressNotMapped(base),
            DyldSharedCacheError.addressSpanCrossesChunk(vma: base, length: 16),
            DyldSharedCacheError.shortRead(vma: base, wanted: 16, got: 8),
            CocoaError(.fileReadNoPermission),
            CocoaError(.fileWriteOutOfSpace),
        ]
        for error in failures { #expect(!Metadata.isUnsupportedLayout(error)) }
    }

    @Test func `image admission checks the runtime ABI independently of OS version`() throws {
        let uuid = Data(0..<16)
        func image(platform: UInt32 = MachOBuildPlatform.iOS, subtype: UInt32 = 2,
                   version: UInt32 = 16 << 16) -> Data {
            let words: [UInt32] = [MH_MAGIC_64, UInt32(CPU_TYPE_ARM64), subtype, UInt32(MH_DYLIB),
                                   2, 48, 0, 0, UInt32(LC_UUID), 24]
            return words.reduce(into: Data()) { $0 += ARM64.encodeU32($1) } + uuid +
                [UInt32(LC_BUILD_VERSION), 24, platform, version, version, 0]
                .reduce(into: Data()) { $0 += ARM64.encodeU32($1) }
        }
        for subtype: UInt32 in [2, 0x8000_0002, 12] {
            for version: UInt32 in [16 << 16, 26 << 16, 27 << 16, 99 << 16] {
                #expect(try Metadata.imageUUID(image(subtype: subtype, version: version)) == uuid)
            }
        }
        for platform: UInt32 in [1, MachOBuildPlatform.tvOS, MachOBuildPlatform.watchOS, 7, MachOBuildPlatform.visionOS] {
            #expect(throws: (any Error).self) {
                do { _ = try Metadata.imageUUID(image(platform: platform)) }
                catch { #expect(Metadata.isUnsupportedLayout(error)); throw error }
            }
        }
        for subtype: UInt32 in [0, 1, 13] {
            #expect(throws: (any Error).self) {
                do { _ = try Metadata.imageUUID(image(subtype: subtype)) }
                catch { #expect(Metadata.isUnsupportedLayout(error)); throw error }
            }
        }
        for length in [0, 31, 55, 79] {
            #expect(throws: (any Error).self) {
                do { _ = try Metadata.imageUUID(Data(image().prefix(length))) }
                catch { #expect(!Metadata.isUnsupportedLayout(error)); throw error }
            }
        }
        var missingPlatform = image()
        missingPlatform.replaceSubrange(56..<60, with: ARM64.encodeU32(UInt32(LC_SOURCE_VERSION)))
        #expect(throws: (any Error).self) { try Metadata.imageUUID(missingPlatform) }
    }

    func decode(_ data: Data) -> [ARM64Instruction] { ARM64Disassembler().disassemble(data, at: base) }
    func call(_ index: Int, _ target: UInt64) throws -> Data {
        try #require(ARM64Encoder.encodeBL(from: Int(base) + index * 4, to: Int(target)))
    }
    func add(_ destination: UInt32, _ source: UInt32, _ offset: UInt32) throws -> Data {
        try #require(ARM64Encoder.encodeAddImm12(rd: destination, rn: source, imm12: offset))
    }
    func load(_ destination: UInt32, _ source: UInt32, _ offset: UInt32) throws -> Data {
        try #require(ARM64Encoder.encodeLdrXUnsignedOffset(rt: destination, rn: source, offset: offset))
    }

    func invalidation(lockOffset: UInt32 = 16, uuidOffset: UInt32 = 32) throws -> Data {
        try call(0, storage) + ARM64Encoder.encodeMovX(rd: 21, rm: 0) + add(2, 0, uuidOffset) +
            call(3, message) + add(0, 21, lockOffset) + call(5, lock) +
            #require(ARM64Encoder.encodeStpX(rt1: 31, rt2: 31, rn: 21, offset: 0)) +
            add(0, 21, lockOffset) + call(8, unlock) + ARM64.ret
    }

    func fields(_ data: Data) throws -> (lock: UInt32, uuid: UInt32) {
        try Metadata.storageFields(decode(data), lock: lock, unlock: unlock, getStorage: storage,
                                   makeMessage: message, target: Metadata.directTarget)
    }

    @Test func `function bounds require an exact start and include paths after early returns`() throws {
        let starts: [UInt64] = [base, base + 80, base + 144]
        #expect(try Metadata.functionLength(base, starts: starts, limit: 256) == 80)
        #expect(try Metadata.functionLength(base + 80, starts: starts, limit: 256) == 64)
        for start in [base + 4, base + 144] {
            #expect(throws: (any Error).self) { try Metadata.functionLength(start, starts: starts, limit: 256) }
        }
        #expect(throws: (any Error).self) { try Metadata.functionLength(base, starts: starts, limit: 64) }
    }

    @Test func `authenticated import stubs name a GOT slot and require matching authentication registers`() throws {
        let slot: UInt64 = 0x182408
        let page = try #require(ARM64Encoder.encodeADRP(rd: 17, pc: base, target: slot))
        let jump = try #require(ARM64Encoder.encodeBRAA(rn: 16, rm: 17))
        let stub = try page + add(17, 17, UInt32(slot & 0xfff)) + load(16, 17, 0) + jump
        #expect(Metadata.authenticatedStubSlot(decode(stub)) == slot)
        #expect(Metadata.stubTarget(decode(stub)) == nil)
        var wrong = stub
        wrong.replaceSubrange(12..<16, with: try #require(ARM64Encoder.encodeBRAA(rn: 16, rm: 18)))
        #expect(Metadata.authenticatedStubSlot(decode(wrong)) == nil)
        wrong = stub
        wrong.replaceSubrange(8..<12, with: try load(16, 17, 8))
        #expect(Metadata.authenticatedStubSlot(decode(wrong)) == nil)
    }

    @Test func `storage layout follows the invalidation data flow and refuses changed gates`() throws {
        let original = try invalidation()
        #expect(try fields(original).lock == 16)
        #expect(try fields(original).uuid == 32)
        let moved = try invalidation(lockOffset: 24, uuidOffset: 48)
        #expect(try fields(moved).lock == 24)
        #expect(try fields(moved).uuid == 48)
        for index in 0...8 {
            var changed = original
            changed.replaceSubrange(index * 4..<index * 4 + 4, with: ARM64.nop)
            #expect(throws: (any Error).self) { try fields(changed) }
        }
        var wrongOwner = original
        wrongOwner.replaceSubrange(7 * 4..<8 * 4, with: try add(0, 22, 16))
        #expect(throws: (any Error).self) { try fields(wrongOwner) }
        for (index, target) in [(5, lock), (8, unlock)] {
            var tailCall = original
            tailCall.replaceSubrange(index * 4..<index * 4 + 4,
                with: try #require(ARM64Encoder.encodeB(from: Int(base) + index * 4, to: Int(target))))
            #expect(throws: (any Error).self) { try fields(tailCall) }
        }
    }

    func output() throws -> Data {
        var data = try add(0, 26, 16) + call(1, lock) + load(0, 26, 0)
        data += try #require(ARM64Encoder.encodeCompareBranch(nonzero: false, register: 0,
                                                              from: Int(base) + 12, to: Int(base) + 64, width64: true))
        for (destination, source) in [(1, 22), (2, 25), (3, 23), (4, 24)] {
            data += ARM64Encoder.encodeMovX(rd: UInt32(destination), rm: UInt32(source))
        }
        data += try call(8, emit)
        data += ARM64Encoder.encodeMovX(rd: 28, rm: 0)
        data += try #require(ARM64Encoder.encodeB(from: Int(base) + 40, to: Int(base) + 68))
        for _ in 11..<16 { data += ARM64.nop }
        data += ARM64Encoder.encodeMovX(rd: 28, rm: 31)
        data += try add(0, 26, 16) + call(18, unlock) + ARM64.ret
        return data
    }

    @Test func `output admission requires matching acquire emit and release`() throws {
        let original = try output()
        func admitted(_ data: Data) throws -> Bool {
            try Metadata.verifiesOutputLock(decode(data), offset: 16, lock: lock, unlock: unlock,
                                             emit: emit, target: Metadata.directTarget)
        }
        #expect(try admitted(original))
        for index in [0, 1, 2, 8, 10, 17, 18] {
            var changed = original
            changed.replaceSubrange(index * 4..<index * 4 + 4, with: ARM64.nop)
            #expect(try !admitted(changed))
        }
        var tile = original
        tile.replaceSubrange(8..<12, with: try load(0, 26, 8))
        #expect(try !admitted(tile))
        for (index, target) in [(1, lock), (18, unlock)] {
            var tailCall = original
            tailCall.replaceSubrange(index * 4..<index * 4 + 4,
                with: try #require(ARM64Encoder.encodeB(from: Int(base) + index * 4, to: Int(target))))
            #expect(try !admitted(tailCall))
        }
    }

    @Test func `block captures are recovered for paired and separate loads`() throws {
        // Clang-assembled input: ldr x8,[x0,#32]; ldp x1,x2,[x0,#40];
        // ldr x3,[x8,#16]; mov x0,x8; ret. Not replacement instructions.
        let paired = [UInt32(0xf9401008), 0xa9428801, 0xf9400903, 0xaa0803e0, 0xd65f03c0]
            .reduce(into: Data()) { $0 += ARM64.encodeU32($1) }
        #expect(try Metadata.blockMessageOffset(decode(paired)) == 40)
        let separate = try load(8, 0, 48) + load(1, 0, 56) + load(2, 0, 64) + ARM64.ret
        #expect(try Metadata.blockMessageOffset(decode(separate)) == 56)
        let wrongHolder = try load(8, 0, 48) + load(1, 0, 56) + load(2, 0, 72) + ARM64.ret
        #expect(throws: (any Error).self) { try Metadata.blockMessageOffset(decode(wrongHolder)) }
        let missingHandler = try load(1, 0, 56) + load(2, 0, 64) + ARM64.ret
        #expect(throws: (any Error).self) { try Metadata.blockMessageOffset(decode(missingHandler)) }
        let overwritten = ARM64Encoder.encodeMovX(rd: 0, rm: 9) + separate
        #expect(throws: (any Error).self) { try Metadata.blockMessageOffset(decode(overwritten)) }
        let clobbered = try call(0, message) + separate
        #expect(throws: (any Error).self) { try Metadata.blockMessageOffset(decode(clobbered)) }
        let preserved = try ARM64Encoder.encodeMovX(rd: 20, rm: 0) + call(1, message)
            + load(8, 20, 48) + load(1, 20, 56) + load(2, 20, 64) + ARM64.ret
        #expect(try Metadata.blockMessageOffset(decode(preserved)) == 56)
    }

    @Test func `metadata binds the image and original bytes and refuses incomplete reads`() throws {
        let uuid = Data(0..<16)
        let addresses = (0..<11).map { base + UInt64(64 + $0 * 32) }
        let result = try Metadata.encode(header: base, uuid: uuid, lock: 16, uuidOffset: 32,
                                          message: 40, entries: addresses, read: { address, count in
            Data(repeating: UInt8((address - base) / 32), count: count)
        })
        #expect(result.count == 304)
        #expect(result.prefix(8) == Data("VPVD\u{1}\0\0\0".utf8))
        #expect(result.subdata(in: 8..<24) == uuid)
        #expect(result.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 40, as: UInt64.self).littleEndian } == 64)
        #expect(throws: (any Error).self) {
            try Metadata.encode(header: base, uuid: uuid, lock: 16, uuidOffset: 32, message: 40,
                                entries: addresses, read: { _, _ in Data(repeating: 0, count: 15) })
        }
        #expect(throws: (any Error).self) {
            try Metadata.encode(header: base + 1024, uuid: uuid, lock: 16, uuidOffset: 32, message: 40,
                                entries: addresses, read: { _, count in Data(repeating: 0, count: count) })
        }
        #expect(!Metadata.safePrologue(decode(try call(0, emit) + ARM64.nop + ARM64.nop + ARM64.nop)))
        #expect(Metadata.safePrologue(decode(ARM64.pacibsp + ARM64.nop + ARM64.nop + ARM64.nop)))
        // Existing MISFixDetour/X1LoweringTests input, not replacement bytes.
        let pcBound = ARM64.encodeU32(0xdac1a7fe)
        #expect(Metadata.safePrologue(decode(pcBound + ARM64.nop + ARM64.nop + ARM64.nop)))
        #expect(!Metadata.safePrologue(decode(ARM64.nop + pcBound + ARM64.nop + ARM64.nop)))
        #expect(!Metadata.safePrologue(decode(ARM64.pacibsp + ARM64Encoder.encodeMovX(rd: 16, rm: 0)
            + ARM64.nop + ARM64.nop)))
    }

    @Test func `local symbol candidates preserve duplicate names without crossing images`() throws {
        let name = "_DecompressionOutputCallback"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("symbols")
        var data = Data(repeating: 0, count: 512)
        func put<T: FixedWidthInteger>(_ offset: Int, _ value: T) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.replaceSubrange(offset..<offset + $0.count, with: $0) }
        }
        data.replaceSubrange(0..<7, with: Data("dyld_v1".utf8))
        put(0x48, UInt64(0x80))
        for (offset, value) in [(0, 24), (4, 3), (8, 72), (12, name.utf8.count + 2), (16, 128), (20, 2)] {
            put(0x80 + offset, UInt32(value))
        }
        data.replaceSubrange(0x80 + 73..<0x80 + 73 + name.utf8.count, with: Data(name.utf8))
        for index in 0..<3 {
            put(0x80 + 24 + index * 16, UInt32(1))
            put(0x80 + 32 + index * 16, UInt64(0x5000 + index * 0x1000))
        }
        put(0x100, UInt64(0x2000)); put(0x108, UInt32(0)); put(0x10c, UInt32(2))
        put(0x110, UInt64(0x3000)); put(0x118, UInt32(2)); put(0x11c, UInt32(1))
        try data.write(to: file)
        let table = try DyldSharedCacheLocalSymbolTable(url: file)
        let entry = try #require(table.entry(forDylibOffset: 0x2000))
        #expect(table.symbols(in: entry)[name] == 0x5000)
        #expect(table.addresses(of: name, in: entry) == [0x5000, 0x6000])
    }
}

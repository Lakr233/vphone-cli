@testable import FirmwarePatcher
import Foundation
import Testing
import VPhonePatchKit

/// Calls through the auth stubs macOS 27's kmutil keeps, made direct again.
@Suite("Kernel collection stub calls")
struct KernelCollectionStubCallsTests {
    static let base: UInt64 = 0xFFFF_FE00_0700_0000
    static let target: UInt64 = base + 0x4100

    /// A collection with one kext whose __text calls its only auth stub with a
    /// BL and a B, and calls `target` directly once. The stub's __auth_got slot
    /// is a DYLD_CHAINED_PTR_64_KERNEL_CACHE pointer to `target`, in the
    /// collection's `codeSegment`.
    /// `fipsSeal` adds `__TEXT,__fips_hmacs` at 0x1800, sealing __text correctly
    /// (`.valid`) or with zeros (`.wrong`).
    enum FIPS { case none, valid, wrong }

    static func collection(stubSize: UInt64 = 16, slot: UInt64 = (1 << 63) | 0x4100, pointerFormat: UInt16 = 8, fipsSeal: FIPS = .none, codeSegment: String = "__TEXT_EXEC") throws -> [UInt8] {
        let base = Self.base
        func section(_ segment: String, _ name: String, _ off: UInt64, _ size: UInt64, flags: UInt32) -> KDKMachO.Section {
            .init(name: name, segmentName: segment, address: base + off, size: size, offset: UInt32(off),
                  align: 2, relocationOffset: 0, relocationCount: 0, flags: flags, reserved1: 0, reserved2: 0, reserved3: 0)
        }
        func segment(_ name: String, _ off: UInt64, _ size: UInt64, _ sections: [KDKMachO.Section] = []) -> [UInt8] {
            var bytes: [UInt8] = []
            KDKMachO.write(.init(command: KDKMachO.lcSegment64, commandSize: UInt32(72 + 80 * sections.count), name: name,
                                 address: base + off, memorySize: size, fileOffset: off, fileSize: size,
                                 maxProtection: 5, initialProtection: 5, sectionCount: UInt32(sections.count), flags: 0, sections: sections), to: &bytes)
            return bytes
        }
        func header(_ type: UInt32, _ loads: [[UInt8]]) -> [UInt8] {
            KDKMachO.Header(magic: KDKMachO.magic64, cpuType: 0x0100_000C, cpuSubtype: 2, fileType: type,
                            commandCount: UInt32(loads.count), commandsSize: UInt32(loads.flatMap(\.self).count),
                            flags: type == KDKMachO.mhFileset ? 0 : KDKMachO.mhDylibInCache, reserved: 0).bytes + loads.flatMap(\.self)
        }
        var entry: [UInt8] = []
        entry.appendLE(KDKMachO.lcFilesetEntry)
        entry.appendLE(UInt32(56))
        entry.appendLE(base + 0x1000)
        entry.appendLE(UInt64(0x1000))
        entry.appendLE(UInt32(32))
        entry.appendLE(UInt32(0))
        entry += Array("com.test.kext\0".utf8)
        entry += [UInt8](repeating: 0, count: 56 - entry.count)
        var fixups: [UInt8] = []
        fixups.appendLE(KDKMachO.lcDyldChainedFixups)
        fixups.appendLE(UInt32(16))
        fixups.appendLE(UInt32(0xC000))
        fixups.appendLE(UInt32(0x40))

        var bytes = [UInt8](repeating: 0, count: 0xD000)
        let top = header(KDKMachO.mhFileset, [
            segment("__TEXT", 0, 0x4000), segment(codeSegment, 0x4000, 0x4000),
            segment("__DATA_CONST", 0x8000, 0x4000), segment("__LINKEDIT", 0xC000, 0x1000), entry, fixups,
        ])
        bytes.replaceSubrange(0 ..< top.count, with: top)
        let image = header(0xB, [
            segment("__TEXT", 0x1000, 0x1000, fipsSeal == .none ? [] : [section("__TEXT", "__fips_hmacs", 0x1800, 32, flags: 0)]),
            segment("__TEXT_EXEC", 0x4000, 0x1000, [
                section("__TEXT_EXEC", "__text", 0x4000, 0x10, flags: 0x8000_0400),
                section("__TEXT_EXEC", "__auth_stubs", 0x4800, stubSize, flags: 0x8000_0408),
            ]),
            segment("__DATA_CONST", 0x8000, 0x1000, [section("__DATA_CONST", "__auth_got", 0x8000, 8, flags: 6)]),
        ])
        bytes.replaceSubrange(0x1000 ..< 0x1000 + image.count, with: image)

        let stub = base + 0x4800
        var code = Data()
        code += try #require(ARM64Encoder.encodeBL(from: Int(bitPattern: UInt(base + 0x4000)), to: Int(bitPattern: UInt(stub))))
        code += try #require(ARM64Encoder.encodeB(from: Int(bitPattern: UInt(base + 0x4004)), to: Int(bitPattern: UInt(stub))))
        code += try #require(ARM64Encoder.encodeBL(from: Int(bitPattern: UInt(base + 0x4008)), to: Int(bitPattern: UInt(target))))
        code += ARM64.nop
        bytes.replaceSubrange(0x4000 ..< 0x4010, with: code)
        var stubCode = Data()
        stubCode += try #require(ARM64Encoder.encodeADRP(rd: 17, pc: stub, target: base + 0x8000))
        stubCode += try #require(ARM64Encoder.encodeAddImm12(rd: 17, rn: 17, imm12: 0))
        stubCode += try #require(ARM64Encoder.encodeLdrXUnsignedOffset(rt: 16, rn: 17, offset: 0))
        stubCode += try #require(ARM64Encoder.encodeBRAA(rn: 16, rm: 17))
        bytes.replaceSubrange(0x4800 ..< 0x4810, with: stubCode)
        bytes.setLE(slot, at: 0x8000)

        // dyld_chained_fixups_header, starts_in_image (one segment), starts_in_segment.
        bytes.setLE(UInt32(0x20), at: 0xC004)
        bytes.setLE(UInt32(0x40), at: 0xC008)
        bytes.setLE(UInt32(0x40), at: 0xC00C)
        bytes.setLE(UInt32(1), at: 0xC014)
        bytes.setLE(UInt32(1), at: 0xC020)
        bytes.setLE(UInt32(8), at: 0xC024)
        bytes.setLE(UInt32(24), at: 0xC028)
        bytes.setLE(UInt16(0x4000), at: 0xC02C)
        bytes.setLE(pointerFormat, at: 0xC02E)
        bytes.setLE(UInt64(0x8000), at: 0xC030)
        bytes.setLE(UInt16(1), at: 0xC03C)
        bytes.setLE(UInt16(0), at: 0xC03E)
        if fipsSeal == .valid {
            bytes.replaceSubrange(0x1800 ..< 0x1820, with: KernelCollectionStubCalls.FIPSSeal.hmac(bytes[0x4000 ..< 0x4010]))
        }
        return bytes
    }

    @Test("rewritten code is sealed again for the FIPS self test")
    func resealsFIPS() throws {
        let result = try KernelCollectionStubCalls.directCalls(in: Data(Self.collection(fipsSeal: .valid)))
        #expect(result.branches == 2)
        #expect(result.resealed == 1)
        let bytes = [UInt8](result.payload)
        #expect(Array(bytes[0x1800 ..< 0x1820]) == KernelCollectionStubCalls.FIPSSeal.hmac(bytes[0x4000 ..< 0x4010]))
        #expect(Array(bytes[0x1800 ..< 0x1820]) != Array(try Self.collection(fipsSeal: .valid)[0x1800 ..< 0x1820]))
    }

    @Test("a seal that does not match the code is refused")
    func refusesUnknownSeal() throws {
        #expect(throws: PatcherError.self) {
            try KernelCollectionStubCalls.directCalls(in: Data(Self.collection(fipsSeal: .wrong)))
        }
    }

    static func branch(_ bytes: [UInt8], at offset: Int, address: UInt64) throws -> ARM64Instruction {
        try #require(ARM64Disassembler().disassembleOne(Data(bytes[offset ..< offset + 4]), at: address))
    }

    @Test("calls through an auth stub branch to its target")
    func retargetsStubCalls() throws {
        let result = try KernelCollectionStubCalls.directCalls(in: Data(Self.collection()))
        #expect(result.stubs == 1)
        #expect(result.branches == 2)
        let bytes = [UInt8](result.payload)
        for (offset, mnemonic) in [(0x4000, "bl"), (0x4004, "b"), (0x4008, "bl")] {
            let insn = try Self.branch(bytes, at: offset, address: Self.base + UInt64(offset))
            #expect(insn.mnemonic == mnemonic)
            let operand = try #require(insn.detail?.operands.first)
            #expect(UInt64(bitPattern: operand.imm) == Self.target, "\(insn) at 0x\(String(offset, radix: 16))")
        }
        // The stub itself is left as it was.
        #expect(Array(bytes[0x4800 ..< 0x4810]) == Array(try Self.collection()[0x4800 ..< 0x4810]))
    }

    @Test("an import from the kernel's boot code branches there directly")
    func retargetsBootCode() throws {
        let result = try KernelCollectionStubCalls.directCalls(in: Data(Self.collection(codeSegment: "__TEXT_BOOT_EXEC")))
        #expect(result.stubs == 1)
        #expect(result.branches == 2)
    }

    @Test("a collection without stubs is unchanged")
    func noStubs() throws {
        let original = try Data(Self.collection(stubSize: 0))
        let result = try KernelCollectionStubCalls.directCalls(in: original)
        #expect(result.branches == 0)
        #expect(result.payload == original)
    }

    @Test("an import from another collection or format is refused")
    func refusesUnknownPointers() throws {
        #expect(throws: PatcherError.self) {
            try KernelCollectionStubCalls.directCalls(in: Data(Self.collection(slot: (1 << 63) | (1 << 30) | 0x4100)))
        }
        #expect(throws: PatcherError.self) {
            try KernelCollectionStubCalls.directCalls(in: Data(Self.collection(pointerFormat: 1)))
        }
        #expect(throws: PatcherError.self) {
            try KernelCollectionStubCalls.directCalls(in: Data(Self.collection(slot: (1 << 63) | 0x8000)))
        }
    }

    /// A mix kmutil linked on macOS 27, decompressed. Xcode passes
    /// TEST_RUNNER_KC_STUB_MIX to the test process as KC_STUB_MIX.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["KC_STUB_MIX"] != nil))
    func realMixFindsCallSitePatches() throws {
        let path = try #require(ProcessInfo.processInfo.environment["KC_STUB_MIX"])
        let linked = try Data(contentsOf: URL(fileURLWithPath: path))
        let result = try KernelCollectionStubCalls.directCalls(in: linked)
        #expect(result.branches > 0)
        #expect(try KernelCollectionStubCalls.directCalls(in: result.payload).branches == 0, "a call still goes through a stub")
        // The second pass also checked every FIPS seal against the rewritten code.
        #expect(result.resealed >= 1, "corecrypto was not sealed again")
        let rewritten = try KDKKernelCollection(result.payload)
        let corecrypto = try rewritten.image("com.apple.kec.corecrypto")
        #expect(try KernelCollectionStubCalls.FIPSSeal(image: corecrypto, in: rewritten, bytes: [UInt8](result.payload)) != nil)

        func found(_ data: Data) throws -> Set<String> {
            let base = try Set(KernelPatcher(data: data, verbose: false).findAll().map(\.patchID))
            let cfw = try Set(KernelCustomFirmwarePatcher(data: data, verbose: false).findAll().map(\.patchID))
            return base.union(cfw)
        }
        let before = try found(linked)
        let after = try found(result.payload)
        #expect(before.isSubset(of: after), "lost: \(before.subtracting(after).sorted())")
        #expect(after.contains("kernel-boot-apfs_seal_broken"))
        print("stub calls: \(result.stubs) stubs, \(result.branches) branches; patches gained: \(after.subtracting(before).sorted())")
    }
}

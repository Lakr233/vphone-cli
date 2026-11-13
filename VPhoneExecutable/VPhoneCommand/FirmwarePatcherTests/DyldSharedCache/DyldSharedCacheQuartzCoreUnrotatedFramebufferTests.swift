import Darwin
@testable import FirmwarePatcher
import Foundation
import Testing
import VPhonePatchKit

@Suite("QuartzCore unrotated framebuffer cache")
struct DyldSharedCacheQuartzCoreUnrotatedFramebufferTests {
    private let decoder = ARM64Disassembler()
    private let base: UInt64 = 0x1_8446_3B00
    private let compression: UInt64 = 0x1_8446_0000

    /// The shape of `get_surface` around the gate:
    ///
    ///     +0   bl    _CADeviceUseFramebufferCompression
    ///     +4   mov   x26, x0
    ///     +8   ldrb  w8, [x24, #0x110]
    ///     +12  tbnz  w8, #bit, rotated        (nop when patched)
    ///     +16  nop                            (normal surface path)
    ///     +20  b     +48                      (optional second branch to rotated)
    ///     +24  ret
    ///     +28  rotated: ldrh w8, [x0, #0x2c8]
    ///     +32  mov   w9, #mask
    ///     +36  and   w8, w8, w9
    ///     +40  cmp   w8, #1
    ///     +44  cset  w19, eq
    ///     +48  ret
    private func code(
        at address: UInt64? = nil, patched: Bool = false, bit: UInt32 = 2,
        gateTarget: UInt64? = nil, mask: UInt16 = 0xFD, secondBranch: Bool = false,
    ) throws -> [ARM64Instruction] {
        let start = address ?? base
        let rotated = start + 28
        var head = Data()
        func append(_ instruction: Data?) throws { head += try #require(instruction) }
        try append(ARM64Encoder.encodeBL(from: Int(start), to: Int(compression)))
        head += ARM64Encoder.encodeMovX(rd: 26, rm: 0)
        try append(ARM64Encoder.encodeLdrBUnsignedOffset(rt: 8, rn: 24, offset: 0x110))
        if patched {
            head += ARM64.nop
        } else {
            try append(ARM64Encoder.encodeTestBitBranch(
                nonzero: true, register: 8, bit: bit,
                from: Int(start + 12), to: Int(gateTarget ?? rotated),
            ))
        }
        head += ARM64.nop
        if secondBranch {
            try append(ARM64Encoder.encodeB(from: Int(start + 20), to: Int(rotated)))
        } else {
            head += ARM64.nop
        }
        head += ARM64.ret

        // ldrh and the register-register and have no encoder; the patcher reads
        // only their decoded operands, so describe those directly.
        var instructions = decoder.disassemble(head, at: start)
        instructions.append(instruction(rotated, "ldrh", [
            register(.w(8)), memory(base: .x(0), disp: 0x2C8),
        ]))
        var tail = Data()
        tail += try #require(ARM64Encoder.encodeMovzW(rd: 9, imm16: mask))
        let maskInstructions = decoder.disassemble(tail, at: rotated + 4)
        instructions += maskInstructions
        instructions.append(instruction(rotated + 8, "and", [
            register(.w(8)), register(.w(8)), register(.w(9)),
        ]))
        var rest = Data()
        rest += try #require(ARM64Encoder.encodeCmpWImmediate(rn: 8, imm12: 1))
        rest += try #require(ARM64Encoder.encodeCsetW(rd: 19, condition: .eq))
        rest += ARM64.ret
        instructions += decoder.disassemble(rest, at: rotated + 12)
        return instructions
    }

    private func register(_ reg: ARM64Register) -> ARM64Operand {
        .init(type: .register, reg: reg, imm: 0, mem: .init(base: .invalid, index: .invalid, disp: 0))
    }

    private func memory(base: ARM64Register, disp: Int32) -> ARM64Operand {
        .init(type: .memory, reg: .invalid, imm: 0, mem: .init(base: base, index: .invalid, disp: disp))
    }

    private func instruction(_ address: UInt64, _ mnemonic: String, _ operands: [ARM64Operand]) -> ARM64Instruction {
        ARM64Instruction(
            isDecoded: true, address: address, size: 4, bytes: [], mnemonic: mnemonic, operandString: "",
            detail: .init(conditionCode: nil, updatesFlags: false, postIndex: false, operands: operands),
            isJump: false, isCall: false, isReturn: false,
        )
    }

    private func sites(_ code: [ARM64Instruction], compression: UInt64? = nil)
        -> [DyldSharedCacheQuartzCoreUnrotatedFramebufferPatcher.Site]
    {
        DyldSharedCacheQuartzCoreUnrotatedFramebufferPatcher.findSites(
            in: code, compression: compression ?? self.compression,
        )
    }

    @Test func `the surface-flag gate is selected and the patched form is rediscovered`() throws {
        let original = try code()
        #expect(original.count == 13)
        let site = try DyldSharedCacheQuartzCoreUnrotatedFramebufferPatcher.uniqueSite(sites(original))
        #expect(site.address == base + 12)
        #expect(!site.alreadyPatched)
        #expect(site.before == Data(original[3].bytes))
        #expect(site.replacement == ARM64.nop)
        let repeated = try DyldSharedCacheQuartzCoreUnrotatedFramebufferPatcher.uniqueSite(sites(code(patched: true)))
        #expect(repeated.address == site.address)
        #expect(repeated.alreadyPatched)
    }

    @Test func `a different call, bit, target or orientation test is refused`() throws {
        #expect(sites(try code(), compression: compression + 4).isEmpty)
        #expect(sites(try code(bit: 1)).isEmpty)
        #expect(sites(try code(gateTarget: base + 24)).isEmpty)
        #expect(sites(try code(mask: 0xFE)).isEmpty)
        // A nop is only the patched form when nothing else still reaches the
        // rotated path.
        #expect(sites(try code(patched: true, secondBranch: true)).isEmpty)
    }

    @Test func `multiple matching gates are refused`() throws {
        let matches = sites(try code() + code(at: base + 0x100))
        #expect(matches.count == 2)
        #expect(throws: DyldSharedCacheQuartzCoreUnrotatedFramebufferPatcher.Failure.self) {
            _ = try DyldSharedCacheQuartzCoreUnrotatedFramebufferPatcher.uniqueSite(matches)
        }
    }

    /// A full iOS 27 iPad cache directory, `.symbols` included, e.g. the
    /// extracted iPad16,1 24A446 cache.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["VPHONE_IPAD27_CACHE_FIXTURE"] != nil))
    func `iPad 27 fixture dry run repeat and undo`() throws {
        let source = try URL(fileURLWithPath: #require(ProcessInfo.processInfo.environment["VPHONE_IPAD27_CACHE_FIXTURE"]))
        let fm = FileManager.default
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0 ..< 5 { root.deleteLastPathComponent() }
        let work = root.appendingPathComponent(".build/tmp/quartzcore-cache-test-\(UUID().uuidString)")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }
        for url in try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)
            where url.lastPathComponent.hasPrefix("dyld_shared_cache_arm64e")
        {
            guard clonefile(url.path, work.appendingPathComponent(url.lastPathComponent).path, 0) == 0 else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        let chunks = try DyldSharedCacheChunkSet(directory: work, captureUndo: true)
        let dry = try DyldSharedCacheQuartzCoreUnrotatedFramebufferPatcher.patch(in: chunks, dryRun: true)
        // Reviewed iPad16,1 24A446 fixture, not a discovery offset in the patcher.
        #expect(dry.address == 0x184463b54)
        #expect(!dry.alreadyPatched)
        #expect(decoder.disassembleOne(dry.before)?.mnemonic == "tbnz")
        #expect(chunks.takeUndoLog()?.records.isEmpty == true)
        let (file, _) = try chunks.fileRange(of: .init(vma: dry.address, length: 4))
        let original = try Data(contentsOf: file)
        _ = try DyldSharedCacheQuartzCoreUnrotatedFramebufferPatcher.patch(in: chunks)
        let patched = try Data(contentsOf: file)
        #expect(patched != original)
        #expect(try chunks.readAtVMA(dry.address, length: 4) == ARM64.nop)
        var undo = try #require(chunks.takeUndoLog())
        #expect(undo.records.count == 1)
        undo.stamp(patchID: FirmwareGuestDisplayPatchSet.quartzCoreUnrotatedFramebuffer)
        let repeated = try DyldSharedCacheQuartzCoreUnrotatedFramebufferPatcher.patch(in: chunks)
        #expect(repeated.alreadyPatched)
        #expect(repeated.address == dry.address)
        #expect(chunks.takeUndoLog()?.records.isEmpty == true)
        #expect(try Data(contentsOf: file) == patched)
        let spans = try undo.restore(patchIDs: undo.patchIDs, in: work)
        #expect(try DyldSharedCacheCodeSignature.reattest(in: chunks, modifiedSpans: spans).isFullyAttested)
        #expect(try Data(contentsOf: file) == original)
    }
}

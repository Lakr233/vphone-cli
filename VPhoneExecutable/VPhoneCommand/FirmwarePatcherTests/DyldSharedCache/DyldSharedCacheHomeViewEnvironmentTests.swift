import Darwin
@testable import FirmwarePatcher
import Foundation
import Testing
import VPhonePatchKit

@Suite("HomeView environment service cache")
struct DyldSharedCacheHomeViewEnvironmentTests {
    private let decoder = ARM64Disassembler()
    private let base: UInt64 = 0x1_8010_0000
    private let getter: UInt64 = 0x1_8010_4000
    private let entitlement: UInt64 = 0x1_8020_0100
    private let notEntitled: UInt64 = 0x1_8020_0200
    private let unavailable: UInt64 = 0x1_8020_0300

    private func code(at address: UInt64? = nil, patched: Bool = false, bit: UInt32 = 0) throws -> [ARM64Instruction] {
        let start = address ?? base
        var bytes = Data()
        func append(_ instruction: Data?) throws { bytes += try #require(instruction) }
        func reference(_ target: UInt64, register: UInt32 = 3) throws {
            try append(ARM64Encoder.encodeADRP(rd: register, pc: start + UInt64(bytes.count), target: target))
            try append(ARM64Encoder.encodeAddImm12(rd: register, rn: register, imm12: UInt32(target & 4095)))
        }
        try reference(entitlement, register: 8)
        try append(ARM64Encoder.encodeBL(from: Int(start + 8), to: Int(getter + 4)))
        bytes += ARM64Encoder.encodeMovX(rd: 19, rm: 0)
        try append(ARM64Encoder.encodeBL(from: Int(start + 16), to: Int(getter + 8)))
        try append(ARM64Encoder.encodeBL(from: Int(start + 20), to: Int(getter + 8)))
        try append(ARM64Encoder.encodeCompareBranch(nonzero: false, register: 19, from: Int(start + 24), to: Int(start + 44)))
        try append(ARM64Encoder.encodeBL(from: Int(start + 28), to: Int(getter)))
        if patched { bytes += ARM64.nop }
        else { try append(ARM64Encoder.encodeTestBitBranch(nonzero: false, register: 0, bit: bit, from: Int(start + 32), to: Int(start + 52))) }
        bytes += ARM64.nop
        try append(ARM64Encoder.encodeB(from: Int(start + 40), to: Int(start + 60)))
        try reference(notEntitled)
        try reference(unavailable)
        bytes += ARM64.ret
        return decoder.disassemble(bytes, at: start)
    }

    private func sites(_ code: [ARM64Instruction], getter: UInt64? = nil, unavailable: UInt64? = nil) -> [DyldSharedCacheHomeViewEnvironmentPatcher.Site] {
        DyldSharedCacheHomeViewEnvironmentPatcher.findSites(
            in: code, getter: getter ?? self.getter, entitlement: entitlement,
            notEntitled: notEntitled, unavailable: unavailable ?? self.unavailable,
            readStub: { _ in [] },
        )
    }

    @Test func `only availability gate is selected and patched form is rediscovered`() throws {
        let original = try code()
        let site = try DyldSharedCacheHomeViewEnvironmentPatcher.uniqueSite(sites(original))
        #expect(site.address == base + 32)
        #expect(!site.alreadyPatched)
        #expect(site.before == Data(original[8].bytes))
        #expect(site.replacement == ARM64.nop)
        let repeatSite = try DyldSharedCacheHomeViewEnvironmentPatcher.uniqueSite(sites(code(patched: true)))
        #expect(repeatSite.address == site.address)
        #expect(repeatSite.alreadyPatched)
    }

    @Test func `wrong getter bit or rejection anchor is refused`() throws {
        #expect(sites(try code(), getter: getter + 12).isEmpty)
        #expect(sites(try code(bit: 1)).isEmpty)
        #expect(sites(try code(), unavailable: unavailable + 4).isEmpty)
        var damaged = try code()
        damaged[6] = try #require(decoder.disassembleOne(ARM64.nop, at: base + 24))
        #expect(sites(damaged).isEmpty)
        damaged = try code()
        damaged[3] = try #require(decoder.disassembleOne(ARM64Encoder.encodeMovX(rd: 20, rm: 0), at: base + 12))
        #expect(sites(damaged).isEmpty)
    }

    @Test func `multiple matching services are refused`() throws {
        let matches = sites(try code() + code(at: base + 0x100))
        #expect(matches.count == 2)
        #expect(throws: DyldSharedCacheHomeViewEnvironmentPatcher.Failure.self) {
            _ = try DyldSharedCacheHomeViewEnvironmentPatcher.uniqueSite(matches)
        }
    }

    @Test func `import stub must branch through the materialized x16 address`() throws {
        let stub: UInt64 = base + 0x200
        var pair = decoder.disassemble(
            try #require(ARM64Encoder.encodeADRP(rd: 16, pc: stub, target: getter))
                + #require(ARM64Encoder.encodeAddImm12(rd: 16, rn: 16, imm12: UInt32(getter & 4095))),
            at: stub,
        )
        func branch(_ register: ARM64Register) -> ARM64Instruction {
            // Semantic fixture for the indirect branch; real-cache coverage below
            // exercises Capstone decoding of the actual imported stub's BR word.
            ARM64Instruction(
                isDecoded: true, address: stub + 8, size: 4, bytes: [], mnemonic: "br", operandString: "",
                detail: .init(conditionCode: nil, updatesFlags: false, postIndex: false, operands: [
                    .init(type: .register, reg: register, imm: 0, mem: .init(base: .invalid, index: .invalid, disp: 0)),
                ]), isJump: true, isCall: false, isReturn: false,
            )
        }
        pair.append(branch(.x(16)))
        #expect(DyldSharedCacheHomeViewEnvironmentPatcher.stubDestination(pair) == getter)
        pair[2] = branch(.x(17))
        #expect(DyldSharedCacheHomeViewEnvironmentPatcher.stubDestination(pair) == nil)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["VPHONE_HOMEVIEW_CACHE_FIXTURE"] != nil))
    func `HomeView 27_2 fixture dry run repeat and undo`() throws {
        let source = try URL(fileURLWithPath: #require(ProcessInfo.processInfo.environment["VPHONE_HOMEVIEW_CACHE_FIXTURE"]))
        let fm = FileManager.default
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0 ..< 5 { root.deleteLastPathComponent() }
        let work = root.appendingPathComponent(".build/tmp/homeview-cache-test-\(UUID().uuidString)")
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
        let dry = try DyldSharedCacheHomeViewEnvironmentPatcher.patch(in: chunks, dryRun: true)
        // Reviewed 24V514 fixture, not a discovery offset in the patcher.
        #expect(dry.address == 0x251269fec)
        #expect(!dry.alreadyPatched)
        #expect(chunks.takeUndoLog()?.records.isEmpty == true)
        let (file, _) = try chunks.fileRange(of: .init(vma: dry.address, length: 4))
        let original = try Data(contentsOf: file)
        let entitlementGate = try chunks.readAtVMA(dry.address - 8, length: 4)
        #expect(decoder.disassembleOne(entitlementGate)?.mnemonic == "cbz")
        _ = try DyldSharedCacheHomeViewEnvironmentPatcher.patch(in: chunks)
        let patched = try Data(contentsOf: file)
        #expect(patched != original)
        #expect(try chunks.readAtVMA(dry.address - 8, length: 4) == entitlementGate)
        var undo = try #require(chunks.takeUndoLog())
        #expect(undo.records.count == 1)
        undo.stamp(patchID: "dyld-exp-homeview_environment_service")
        let repeated = try DyldSharedCacheHomeViewEnvironmentPatcher.patch(in: chunks)
        #expect(repeated.alreadyPatched)
        #expect(chunks.takeUndoLog()?.records.isEmpty == true)
        #expect(try Data(contentsOf: file) == patched)
        let spans = try undo.restore(patchIDs: undo.patchIDs, in: work)
        #expect(try DyldSharedCacheCodeSignature.reattest(in: chunks, modifiedSpans: spans).isFullyAttested)
        #expect(try Data(contentsOf: file) == original)
    }
}

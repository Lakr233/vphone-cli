// CustomFirmwareWatchAudioBudgetTests.swift — the watch MediaExperience budget classifier.
//
// A wrong instruction here panics boot rather than failing an assertion, so the
// addresses the patcher must find are frozen in `FrozenReference`, named against the
// disassembly in `Research/Guest/watch_audio.md`. The fixture-backed tests resolve
// their image/cache like the other patcher suites (an in-repo `ipsws/ref_extract/`
// path, or a `VPHONE_WATCH_*` override) and fail when it is absent unless
// `VPHONE_WATCH_AUDIO_FIXTURE_OPTIONAL=1`, so a green run cannot mean the fixture was
// missing. The cache test patches a throwaway copy.

@testable import FirmwarePatcher
import Foundation
import Testing
import VPhonePatchKit

// MARK: - The frozen reference

/// Unslid 23T240 cache addresses, read from the running guest's arm64e cache.
private enum FrozenReference {
    /// `_CMSMDeviceState_UpdateDeviceClass` — the classifier that sets the byte.
    static let classifierVMA: UInt64 = 0x1_89A3_4620

    /// `b.ne 0x189a34754` at `0x189a34710`: the first token mismatch, which
    /// skips the existing virtual-device log-and-set block. This is the patch.
    static let gateVMA: UInt64 = 0x1_89A3_4710

    /// The equivalent branch for the second token comparison. Forcing this one
    /// too is not an input the patch produces, so discovery must refuse it.
    static let secondGateVMA: UInt64 = 0x1_89A3_4764

    /// `strb w8, [x20, #0x258]` at `0x189a34750`, after `mov w8, #1` at
    /// `0x189a3474c`: the flag store the gate must be shown to reach.
    static let flagStoreVMA: UInt64 = 0x1_89A3_4750

    /// `dyld_cache_header.codeSignatureOffset`, which bounds the code the patch
    /// may touch. Documented at `@0x28` in `DyldSharedCacheCodeSignature.swift`.
    static let codeSignatureOffset = 0x28

    /// The chunks the cache test needs: index, the `.03` code subcache the site
    /// lives in, and the local-symbol file the patcher resolves names through.
    static let cacheChunks = [
        "dyld_shared_cache_arm64e",
        "dyld_shared_cache_arm64e.03",
        "dyld_shared_cache_arm64e.symbols",
    ]
}

// MARK: - Fixtures

private enum Fixture {
    static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    /// The reviewed 23T240 MediaExperience Mach-O. The env var overrides the
    /// in-repo extract path, as with the other patcher fixtures.
    static var image: URL? {
        let url = ProcessInfo.processInfo.environment["VPHONE_WATCH_MEDIAEXPERIENCE_FIXTURE"]
            .map { URL(fileURLWithPath: $0) }
            ?? repoRoot.appendingPathComponent("ipsws/ref_extract/watch_macho_pristine/MediaExperience")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// The 23T240 arm64e watch cache chunk directory. The env var overrides the
    /// in-repo extract path.
    static var cache: URL? {
        let directory = ProcessInfo.processInfo.environment["VPHONE_WATCH_AUDIO_CACHE_FIXTURE"]
            .map { URL(fileURLWithPath: $0) }
            ?? repoRoot.appendingPathComponent("ipsws/ref_extract/watch_dsc_pristine")
        let main = directory.appendingPathComponent("dyld_shared_cache_arm64e")
        return FileManager.default.fileExists(atPath: main.path) ? directory : nil
    }

    /// Opt-out for a machine that does not carry the extracted watch IPSW.
    static var isOptional: Bool {
        ProcessInfo.processInfo.environment["VPHONE_WATCH_AUDIO_FIXTURE_OPTIONAL"] == "1"
    }

    /// A test runs unless its fixture is absent *and* the caller opted out.
    static var imageRuns: Bool { image != nil || !isOptional }
    static var cacheRuns: Bool { cache != nil || !isOptional }

    static let missingImage: Comment = """
    the 23T240 MediaExperience Mach-O is required — put it at \
    ipsws/ref_extract/watch_macho_pristine/MediaExperience, point \
    VPHONE_WATCH_MEDIAEXPERIENCE_FIXTURE at one, or set \
    VPHONE_WATCH_AUDIO_FIXTURE_OPTIONAL=1 to skip this test instead of failing
    """

    static let missingCache: Comment = """
    the 23T240 arm64e watch shared cache is required — put its chunks at \
    ipsws/ref_extract/watch_dsc_pristine, point VPHONE_WATCH_AUDIO_CACHE_FIXTURE \
    at their directory, or set VPHONE_WATCH_AUDIO_FIXTURE_OPTIONAL=1 to skip this \
    test instead of failing
    """
}

// MARK: - Tests

@Suite("Watch audio power budget")
struct CustomFirmwareWatchAudioBudgetTests {
    @Test
    func budgetVersionGate() {
        for version in ["26.4", "26.4.1"] {
            #expect(CustomFirmwareWatchAudioBudget.supports(VPhoneVersion(version)))
        }
        for version in ["26.3", "26.5", "26.40", "27.0", "unknown"] {
            #expect(!CustomFirmwareWatchAudioBudget.supports(VPhoneVersion(version)))
        }
        #expect(!CustomFirmwareWatchAudioBudget.supports(nil))
    }

    @Test func missingSymbolsRefuse() {
        #expect(throws: PatcherError.self) {
            try CustomFirmwareWatchAudioBudget.discover(symbols: [:]) { _, _ in Data() }
        }
    }

    /// Discovery against a synthetic stand-in, so the control-flow matching runs
    /// everywhere and not only where the real cache is present. The stand-in is a
    /// flat MediaExperience laid out at base 0x10000 with the reviewed shape: two
    /// token comparisons (halves 0xfc319ad9 / 0x71c6787b), each a `bl`-prefixed
    /// `cmp x0,x8` + `b.ne` that skips a `mov w8,#1; strb w8,[x9]` flag store; an
    /// `adrp`/`ldrb`/`ret` getter; and two consumers that each `bl` the getter.
    @Test func discoversAgainstSyntheticImage() throws {
        let base: UInt64 = 0x10000
        let getter: UInt64 = 0x10040
        let gate: UInt64 = 0x10014, secondGate: UInt64 = 0x10030, flagStore: UInt64 = 0x1001c
        let image = try Self.makeStandIn()
        let symbols: [String: UInt64] = [
            "_CMSMDeviceState_UpdateDeviceClass": base,
            "_CMSMDeviceState_IsAVirtualDevice": getter,
            "_cmsmSystemSoundNeedsMediaBudget": 0x10080,
            "_CMSUtility_DoesSessionNeedAudioBudget": 0x10100,
        ]
        func discover(_ data: Data) throws -> CustomFirmwareWatchAudioBudget.Site {
            try CustomFirmwareWatchAudioBudget.discover(symbols: symbols) { address, count in
                let start = Int(address - base)
                return data.subdata(in: start..<start + count)
            }
        }
        func nop(_ data: inout Data, at vma: UInt64) {
            let start = Int(vma - base)
            data.replaceSubrange(start..<start + 4, with: ARM64.nop)
        }

        let site = try discover(image)
        #expect(site.address == gate)
        #expect(!site.alreadyPatched)

        // Exactly one word changes, and it is the gate.
        var patched = image
        nop(&patched, at: gate)
        #expect(zip(image, patched).enumerated().filter { $0.element.0 != $0.element.1 }.allSatisfy {
            (Int(gate - base)..<Int(gate - base) + 4).contains($0.offset)
        })

        // Idempotence: the same gate is found again and reported patched.
        let repeated = try discover(patched)
        #expect(repeated.address == gate && repeated.alreadyPatched)

        // A second forced classification is not an input this patch produces.
        var both = patched
        nop(&both, at: secondGate)
        #expect(throws: PatcherError.self) { try discover(both) }

        // Without the flag store the gate reaches, the anchor set is incomplete.
        var broken = image
        nop(&broken, at: flagStore)
        #expect(throws: PatcherError.self) { try discover(broken) }
    }

    /// Keep the original addresses so each mutation below still tests the same site.
    static func makeStandIn() throws -> Data {
        let base = 0x10000
        let getter = 0x10040
        let flag: UInt64 = 0x14000
        var code = Data()

        func append(_ instruction: Data?) throws {
            code.append(try #require(instruction))
        }
        func pad(to address: Int) throws {
            try #require(base + code.count <= address && (address - base - code.count) % 4 == 0)
            while base + code.count < address { code.append(ARM64.nop) }
        }

        // Classifier: each token mismatch skips its flag store.
        try append(ARM64Encoder.encodeADRP(rd: 9, pc: UInt64(base), target: flag))
        let tokens: [(UInt16, UInt16, Int)] = [
            (0x9AD9, 0xFC31, 0x10020),
            (0x787B, 0x71C6, 0x1003c),
        ]
        for (low, high, next) in tokens {
            try append(ARM64Encoder.encodeBL(from: base + code.count, to: getter))
            try append(ARM64Encoder.encodeMovzW(rd: 8, imm16: low))
            try append(ARM64Encoder.encodeMovkW(rd: 8, imm16: high, shift: 16))
            try append(ARM64Encoder.encodeCmpX(rn: 0, rm: 8))
            try append(ARM64Encoder.encodeBCond(from: base + code.count, to: next, condition: .ne))
            try append(ARM64Encoder.encodeMovzW(rd: 8, imm16: 1))
            try append(ARM64Encoder.encodeStrBUnsignedOffset(rt: 8, rn: 9, offset: 0))
        }
        code.append(ARM64.ret)

        // Getter: read the byte both classifier stores target.
        try pad(to: getter)
        try append(ARM64Encoder.encodeADRP(rd: 0, pc: UInt64(getter), target: flag))
        try append(ARM64Encoder.encodeLdrBUnsignedOffset(rt: 0, rn: 0, offset: 0))
        code.append(ARM64.ret)

        // Both budget consumers call the getter; discovery reads 64 bytes each.
        for consumer in [0x10080, 0x10100] {
            try pad(to: consumer)
            try append(ARM64Encoder.encodeBL(from: consumer, to: getter))
            code.append(ARM64.ret)
        }
        try pad(to: 0x10140)
        return code
    }

    @Test(.enabled(if: Fixture.imageRuns))
    func reviewedClassifier() throws {
        let data = try Data(contentsOf: #require(Fixture.image, Fixture.missingImage))
        let symbols = try Self.fixtureSymbols(data)
        let segments = MachOParser.parseSegments(from: data)
        func offset(_ address: UInt64, _ count: Int) throws -> Int {
            guard let segment = segments.first(where: {
                address >= $0.vmAddr && address - $0.vmAddr + UInt64(count) <= $0.fileSize
            }) else { throw PatcherError.invalidFormat("Fixture address is not file backed") }
            return Int(segment.fileOffset + address - segment.vmAddr)
        }
        func discover(_ input: Data) throws -> CustomFirmwareWatchAudioBudget.Site {
            try CustomFirmwareWatchAudioBudget.discover(symbols: symbols) { address, count in
                let start = try offset(address, count)
                return input.subdata(in: start..<start + count)
            }
        }
        let site = try discover(data)
        #expect(site.address == FrozenReference.gateVMA)
        #expect(!site.alreadyPatched)

        // Exactly one word changes, and it is the gate.
        var patched = data
        let start = try offset(site.address, 4)
        patched.replaceSubrange(start..<start + 4, with: ARM64.nop)
        #expect(zip(data, patched).enumerated().filter { $0.element.0 != $0.element.1 }.allSatisfy {
            (start..<start + 4).contains($0.offset)
        })

        // Idempotence: the same site is found again and reported patched.
        let repeated = try discover(patched)
        #expect(repeated.address == site.address && repeated.alreadyPatched)

        // A second forced classification is not an input this patch produced.
        let other = try offset(FrozenReference.secondGateVMA, 4)
        patched.replaceSubrange(other..<other + 4, with: ARM64.nop)
        #expect(throws: PatcherError.self) { try discover(patched) }

        // Without the flag store the gate reaches, the anchor set is incomplete.
        var broken = data
        let setter = try offset(FrozenReference.flagStoreVMA, 4)
        broken.replaceSubrange(setter..<setter + 4, with: ARM64.nop)
        #expect(throws: PatcherError.self) { try discover(broken) }

        #expect(try discover(data).original == site.original)
    }

    @Test(.enabled(if: Fixture.cacheRuns))
    func cachePatchAndSignature() throws {
        let fixture = try #require(Fixture.cache, Fixture.missingCache)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for name in FrozenReference.cacheChunks {
            let source = fixture.appendingPathComponent(name).resolvingSymlinksInPath()
            try FileManager.default.copyItem(at: source, to: directory.appendingPathComponent(name))
        }
        let codeURL = directory.appendingPathComponent("dyld_shared_cache_arm64e.03")
        let before = try Data(contentsOf: codeURL)
        let chunks = try DyldSharedCacheChunkSet(directory: directory, architecture: "arm64e")

        // A dry run reports the site and writes nothing.
        let preview = try CustomFirmwareWatchAudioBudget.patchCache(in: chunks, dryRun: true, log: nil)
        #expect(preview.outcome == .wouldPatch && preview.records.isEmpty)
        #expect(try Data(contentsOf: codeURL) == before)

        let report = try CustomFirmwareWatchAudioBudget.patchCache(in: chunks, log: nil)
        #expect(report.outcome == .patched)
        let record = try #require(report.records.first)
        #expect(report.records.count == 1)
        #expect(record.patchID == "\(CustomFirmwareWatchAudioBudget.patchID).budget_device_class")
        #expect(record.virtualAddress == report.site.address)
        #expect(record.originalBytes == report.site.original && record.patchedBytes == ARM64.nop)

        // Exactly the four bytes of the gate change inside the signed code.
        let after = try Data(contentsOf: codeURL)
        #expect(after != before)
        let codeEnd = Int(before.loadLE(UInt64.self, at: FrozenReference.codeSignatureOffset))
        let site = try chunks.fileRange(
            of: DyldSharedCacheWriteSpan(vma: FrozenReference.gateVMA, length: 4),
        )
        let changed = zip(before.prefix(codeEnd), after.prefix(codeEnd)).enumerated().filter {
            $0.element.0 != $0.element.1
        }
        #expect(changed.count == 4)
        #expect(changed.allSatisfy { site.range.contains($0.offset) })
        #expect(try chunks.bytesAtVMA(FrozenReference.gateVMA, length: 4) == ARM64.nop)

        // Idempotence on the cache: a second run writes nothing more.
        let repeated = try CustomFirmwareWatchAudioBudget.patchCache(in: chunks, log: nil)
        #expect(repeated.outcome == .alreadyPatched && repeated.records.isEmpty)
        #expect(try Data(contentsOf: codeURL) == after)
    }

    private static func fixtureSymbols(_ data: Data) throws -> [String: UInt64] {
        let table = try #require(MachOParser.parseSymtab(from: data))
        var symbols: [String: UInt64] = [:]
        for index in 0..<table.nsyms {
            let entry = table.symoff + index * 16
            let offset = table.stroff + Int(data.loadLE(UInt32.self, at: entry))
            let end = try #require(data[offset..<table.stroff + table.strsize].firstIndex(of: 0))
            let name = try #require(String(data: data[offset..<end], encoding: .utf8))
            symbols[name] = data.loadLE(UInt64.self, at: entry + 8)
        }
        return symbols
    }
}

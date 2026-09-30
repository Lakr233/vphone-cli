// DyldSharedCacheMISTrustAuthPatcherTests.swift — Idempotence and shape tests for
// the MIS trust/authorization patch.
//
// These run on a *synthetic* cache rather than on the 24A435 fixture the other
// DSC suites clone, so they run everywhere, with no `ipsws/ref_extract`.
//
// That is deliberate, and for this patch it is not the weaker test. What has to
// be pinned is what happens on the **second** run, and the second run's input
// is this patch's own output — the same three words (`pacibsp ; mov x0, #0 ;
// retab`) whatever cache they came from. The one thing that does vary between
// caches is *where the compiler put the seed*, and that is exactly what the
// fixture cannot vary: the real 26.6.2 cache puts
// `mov w21, #0x8026 ; movk w21, #0xe800, lsl #16` at `functionVMA + 0x4C`,
// where a write at `functionVMA + 4` leaves it standing, so it can only
// demonstrate the case that already worked. The 27.0 guest in issue #532 had
// the seed in the two words this patch overwrites; the first run destroyed it
// and every later `cfw install` died with
//
//     Patch site not found: checkTrustAndAuthorization: the prologue at
//     0x22406F814 does not seed 0xE8008026 — MIS has been rewritten
//
// Both layouts are built here, so both are covered.
//
// The cache is small but real: a `dyld_cache_header` with a mapping table, a
// Mach-O whose `LC_ID_DYLIB` says `/usr/lib/libmis.dylib`, the naming literal
// in an RX mapping, an ADRP+ADD pair that materialises it, and a
// `CS_SuperBlob`/`CS_CodeDirectory` with real SHA-256 page slots — so
// `locateSite` walks the same four steps it walks on the real cache and
// `DyldSharedCacheCodeSignature` re-attests a page it can actually hash.

import CryptoKit
@testable import FirmwarePatcher
import Foundation
import Testing
import VPhonePatchKit

// MARK: - The synthetic cache

/// Builds a one-chunk `dyld_shared_cache_arm64e` around a stand-in
/// `checkTrustAndAuthorization`.
private enum MISFixture {
    /// SHARED_REGION_BASE_ARM64, where the real cache also starts.
    static let base: UInt64 = 0x1_8000_0000
    /// Bytes of the chunk the code directory covers. Two 16 KiB pages.
    static let codeLimit = 0x8000
    static let pageSize = 0x4000

    static let machHeaderOffset = 0x1000
    static let functionOffset = 0x2000
    static let literalOffset = 0x3000

    static var machHeaderVMA: UInt64 { base + UInt64(machHeaderOffset) }
    static var functionVMA: UInt64 { base + UInt64(functionOffset) }
    static var literalVMA: UInt64 { base + UInt64(literalOffset) }

    static let chunkName = "dyld_shared_cache_arm64e"

    /// Where the seed sits relative to the function start.
    enum SeedPlacement {
        /// `functionVMA + 0x4C`, as on the real 26.6.2 cache: far enough in
        /// that the write at `+4` leaves it standing.
        case afterPrologue
        /// `functionVMA + 4`, the 27.0 shape from issue #532: the two words
        /// this patch overwrites *are* the seed.
        case inTheWordsWeOverwrite
    }

    /// What to put in the function when the point of the test is that neither
    /// accepted shape is there.
    enum Damage {
        case none
        /// Prologue present, seed absent, and not this patch's output either.
        case seedRemoved
    }

    /// `movk w<rd>, #<imm16>, lsl #<shift>`.
    ///
    /// Derived from `ARM64Encoder.encodeMovzW`, which is keystone-checked:
    /// MOVZ and MOVK differ only in `opc`, so the MOVK word is the MOVZ word
    /// with bit 29 set. `A derived movk word disassembles as movk` asserts the
    /// derivation against Capstone rather than trusting it. This is fixture
    /// input; nothing the patcher writes comes from here.
    static func movkW(rd: UInt32, imm16: UInt16, shift: UInt32) -> Data {
        guard let movz = ARM64Encoder.encodeMovzW(rd: rd, imm16: imm16, shift: shift) else {
            return Data()
        }
        let word = movz.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        return withUnsafeBytes(of: (UInt32(littleEndian: word) | 0x2000_0000).littleEndian) {
            Data($0)
        }
    }

    /// The two-instruction seed, `mov w21, #0x8026 ; movk w21, #0xe800, lsl #16`.
    static var seed: Data {
        (ARM64Encoder.encodeMovzW(rd: 21, imm16: 0x8026, shift: 0) ?? Data())
            + movkW(rd: 21, imm16: 0xE800, shift: 16)
    }

    /// The stand-in function's instruction stream, from `functionVMA`.
    static func functionWords(seedAt placement: SeedPlacement, damage: Damage) -> Data {
        var code = ARM64.pacibsp

        if case .inTheWordsWeOverwrite = placement, case .none = damage {
            code += seed
        } else {
            // Stands in for `sub sp, sp, #0xa0 ; stp x28, x27, [sp, #0x40]`.
            code += ARM64.nop
            code += ARM64.nop
        }

        // Filler out to +0x4C, where the real cache puts the seed.
        while code.count < 0x4C {
            code += ARM64.nop
        }
        if case .afterPrologue = placement, case .none = damage {
            code += seed
        }

        // The ADRP+ADD pair that materialises the naming literal, then the
        // return. `locateSite` walks back from the ADD to the `pacibsp`.
        let adrpVMA = functionVMA + UInt64(code.count)
        code += ARM64Encoder.encodeADRP(rd: 8, pc: adrpVMA, target: literalVMA) ?? Data()
        code += ARM64Encoder.encodeAddImm12(rd: 8, rn: 8, imm12: UInt32(literalVMA & 0xFFF)) ?? Data()
        code += ARM64.retab
        return code
    }

    /// Write a complete cache into `directory`.
    ///
    /// - Parameter literal: the naming literal to plant, or `nil` for a cache
    ///   whose `libmis` does not carry it.
    @discardableResult
    static func makeCache(
        at directory: URL,
        seedAt placement: SeedPlacement = .afterPrologue,
        damage: Damage = .none,
        literal: String? = DyldSharedCacheMISTrustAuthPatcher.anchorString,
        installName: String = DyldSharedCacheMISTrustAuthPatcher.image,
    ) throws -> URL {
        try? FileManager.default.removeItem(at: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var bytes = [UInt8](repeating: 0, count: codeLimit)

        func put(_ data: Data, at offset: Int) {
            for (index, byte) in data.enumerated() {
                bytes[offset + index] = byte
            }
        }
        func put32(_ value: UInt32, at offset: Int) {
            put(withUnsafeBytes(of: value.littleEndian) { Data($0) }, at: offset)
        }
        func put64(_ value: UInt64, at offset: Int) {
            put(withUnsafeBytes(of: value.littleEndian) { Data($0) }, at: offset)
        }

        // dyld_cache_header, and the one mapping that covers the whole chunk.
        put(Data("dyld_v1  arm64e".utf8), at: 0)
        let mappingOffset = 0x238
        put32(UInt32(mappingOffset), at: 0x10)
        put32(1, at: 0x14)
        put64(base, at: mappingOffset)
        put64(UInt64(codeLimit), at: mappingOffset + 8)
        put64(0, at: mappingOffset + 16)
        put32(5, at: mappingOffset + 24) // maxProt
        put32(5, at: mappingOffset + 28) // initProt r-x, where cstrings live

        // mach_header_64 + LC_ID_DYLIB, page aligned so findMachOHeaderBefore
        // accepts it.
        var name = Data(installName.utf8)
        name.append(0)
        while name.count % 8 != 0 { name.append(0) }
        let commandSize = 24 + name.count
        put32(0xFEED_FACF, at: machHeaderOffset)
        put32(0x0100_000C, at: machHeaderOffset + 4) // CPU_TYPE_ARM64
        put32(2, at: machHeaderOffset + 8) // CPU_SUBTYPE_ARM64E
        put32(6, at: machHeaderOffset + 12) // MH_DYLIB
        put32(1, at: machHeaderOffset + 16) // ncmds
        put32(UInt32(commandSize), at: machHeaderOffset + 20) // sizeofcmds
        put32(0xD, at: machHeaderOffset + 32) // LC_ID_DYLIB
        put32(UInt32(commandSize), at: machHeaderOffset + 36)
        put32(24, at: machHeaderOffset + 40) // dylib.name.offset
        put(name, at: machHeaderOffset + 32 + 24)

        put(functionWords(seedAt: placement, damage: damage), at: functionOffset)
        if let literal {
            var data = Data(literal.utf8)
            data.append(0)
            put(data, at: literalOffset)
        }

        // CS_SuperBlob + CS_CodeDirectory, big-endian, with real page slots so
        // a run that re-attests has something to compare against.
        let slotCount = codeLimit / pageSize
        let hashOffset = 0x30
        let blobLength = hashOffset + slotCount * 32
        var codeDirectory = Data(repeating: 0, count: blobLength)
        func putBE32(_ value: UInt32, at offset: Int) {
            for (index, byte) in withUnsafeBytes(of: value.bigEndian, Array.init).enumerated() {
                codeDirectory[offset + index] = byte
            }
        }
        putBE32(0xFADE_0C02, at: 0) // CS_CodeDirectory magic
        putBE32(UInt32(blobLength), at: 4)
        putBE32(0x0002_0400, at: 8) // version
        putBE32(UInt32(hashOffset), at: 16)
        putBE32(UInt32(slotCount), at: 28) // nCodeSlots
        putBE32(UInt32(codeLimit), at: 32)
        codeDirectory[36] = 32 // hashSize
        codeDirectory[37] = 2 // CS_HASHTYPE_SHA256
        codeDirectory[39] = 14 // log2(16384)
        for page in 0 ..< slotCount {
            let start = page * pageSize
            let hash = Data(SHA256.hash(data: Data(bytes[start ..< start + pageSize])))
            for (index, byte) in hash.enumerated() {
                codeDirectory[hashOffset + page * 32 + index] = byte
            }
        }

        var signature = Data()
        for value: UInt32 in [0xFADE_0CC0, UInt32(20 + blobLength), 1, 0, 20] {
            signature += withUnsafeBytes(of: value.bigEndian) { Data($0) }
        }
        signature += codeDirectory

        put64(UInt64(codeLimit), at: 0x28) // codeSignatureOffset
        put64(UInt64(signature.count), at: 0x30) // codeSignatureSize

        let chunk = directory.appendingPathComponent(chunkName)
        try (Data(bytes) + signature).write(to: chunk)
        return chunk
    }

    /// A fresh directory under the test's own scratch root.
    static func scratch(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("vphone_dsc_mistrustauth")
            .appendingPathComponent(name)
    }

    static func discard(_ directory: URL) {
        try? FileManager.default.removeItem(at: directory)
        let root = directory.deletingLastPathComponent()
        if ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).isEmpty {
            try? FileManager.default.removeItem(at: root)
        }
    }

    /// The whole chunk file, for a byte-for-byte before/after comparison.
    static func chunkBytes(in directory: URL) throws -> Data {
        try Data(contentsOf: directory.appendingPathComponent(chunkName))
    }

    /// The stored slot hash of the page a VMA lands in, and what that page
    /// currently hashes to.
    static func pageHashes(in directory: URL, forVMA vma: UInt64) throws -> (computed: Data, stored: Data) {
        let chunk = directory.appendingPathComponent(chunkName)
        let cd = try #require(try DyldSharedCacheCodeSignature.readCodeDirectory(ofChunk: chunk))
        let page = Int(vma - base) / cd.pageSize
        return try DyldSharedCacheCodeSignature.pageHashes(
            chunkURL: chunk,
            pageIndex: page,
            directory: cd,
        )
    }
}

// MARK: - The fixture is the cache the patcher expects

@Suite(.serialized)
struct DyldSharedCacheMISTrustAuthFixtureTests {
    @Test
    func `A derived movk word disassembles as movk w21, #0xe800, lsl #16`() throws {
        let word = MISFixture.movkW(rd: 21, imm16: 0xE800, shift: 16)
        let decoded = try #require(ARM64Disassembler().disassembleOne(word, at: 0))
        #expect(decoded.mnemonic == "movk")
        let operands = try #require(decoded.detail?.operands)
        #expect(operands.count >= 2)
        #expect(operands[0].reg.name == "w21")
        #expect(operands[1].imm == 0xE800)
    }

    @Test
    func `The synthetic function decodes as the prologue the patcher looks for`() throws {
        let directory = MISFixture.scratch("shape_in")
        defer { MISFixture.discard(directory) }
        try MISFixture.makeCache(at: directory)

        let chunks = try DyldSharedCacheChunkSet(directory: directory)
        let site = try #require(try DyldSharedCacheMISTrustAuthPatcher.locateSite(in: chunks))
        #expect(site.functionVMA == MISFixture.functionVMA)
        #expect(site.shape == .seedsFailure(
            seedVMA: MISFixture.functionVMA + 0x4C,
            resultRegister: "w21",
        ))
        #expect(site.seedVMA == MISFixture.functionVMA + 0x4C)
        #expect(site.resultRegister == "w21")
        // The literal was reached through libmis's own header, not by luck.
        #expect(chunks.readInstallName(atHeaderVMA: MISFixture.machHeaderVMA)
            == DyldSharedCacheMISTrustAuthPatcher.image)
        #expect(try chunks.findStringVMAs(
            Data(DyldSharedCacheMISTrustAuthPatcher.anchorString.utf8) + Data([0]),
        ) == [MISFixture.literalVMA])
    }
}

// MARK: - One run

@Suite(.serialized)
struct DyldSharedCacheMISTrustAuthPatchTests {
    @Test
    func `The two words after the prologue become mov x0,#0 ; retab`() throws {
        let directory = MISFixture.scratch("patch")
        defer { MISFixture.discard(directory) }
        try MISFixture.makeCache(at: directory)

        let report = try DyldSharedCacheMISTrustAuthPatcher.patch(
            chunksDirectory: directory,
            log: nil,
        )
        #expect(report.outcome == .patched)
        #expect(report.sitesWritten == 1)
        let record = try #require(report.record)
        #expect(record.patchID == DyldSharedCacheMISTrustAuthPatcher.patchID)
        #expect(record.virtualAddress == MISFixture.functionVMA + 4)
        #expect(record.patchedBytes == ARM64.movX0_0 + ARM64.retab)

        let chunks = try DyldSharedCacheChunkSet(directory: directory)
        #expect(try chunks.bytesAtVMA(MISFixture.functionVMA, length: 4) == ARM64.pacibsp)
        #expect(try chunks.bytesAtVMA(MISFixture.functionVMA + 4, length: 8)
            == ARM64.movX0_0 + ARM64.retab)
    }

    @Test
    func `The page the write dirtied is re-attested`() throws {
        let directory = MISFixture.scratch("attest")
        defer { MISFixture.discard(directory) }
        try MISFixture.makeCache(at: directory)

        try DyldSharedCacheMISTrustAuthPatcher.patch(chunksDirectory: directory, log: nil)
        let hashes = try MISFixture.pageHashes(in: directory, forVMA: MISFixture.functionVMA)
        #expect(hashes.computed == hashes.stored)
    }

    @Test
    func `A dry run reports the site and writes nothing`() throws {
        let directory = MISFixture.scratch("dry")
        defer { MISFixture.discard(directory) }
        try MISFixture.makeCache(at: directory)
        let before = try MISFixture.chunkBytes(in: directory)

        let report = try DyldSharedCacheMISTrustAuthPatcher.patch(
            chunksDirectory: directory,
            dryRun: true,
            log: nil,
        )
        #expect(report.outcome == .wouldPatch)
        #expect(report.sitesWritten == 0)
        #expect(try MISFixture.chunkBytes(in: directory) == before)
    }

    @Test
    func `A cache whose libmis lacks the naming literal is left alone`() throws {
        let directory = MISFixture.scratch("absent")
        defer { MISFixture.discard(directory) }
        try MISFixture.makeCache(at: directory, literal: nil)
        let before = try MISFixture.chunkBytes(in: directory)

        let report = try DyldSharedCacheMISTrustAuthPatcher.patch(
            chunksDirectory: directory,
            log: nil,
        )
        #expect(report.outcome == .functionAbsent)
        #expect(!report.functionIsPresent)
        #expect(report.site == nil)
        #expect(try MISFixture.chunkBytes(in: directory) == before)
    }

    @Test
    func `A prologue that is neither shape still stops the install`() throws {
        let directory = MISFixture.scratch("rewritten")
        defer { MISFixture.discard(directory) }
        try MISFixture.makeCache(at: directory, damage: .seedRemoved)

        #expect(throws: PatcherError.self) {
            try DyldSharedCacheMISTrustAuthPatcher.patch(chunksDirectory: directory, log: nil)
        }
    }
}

// MARK: - The second run — issue #532

/// A second `cfw install` over a VM that already carries this patch must be a
/// no-op, whichever of the two seed layouts the userland had.
@Suite(.serialized)
struct DyldSharedCacheMISTrustAuthIdempotenceTests {
    /// Patch twice and require the second run to change nothing.
    private func expectSecondRunIsANoOp(
        named name: String,
        seedAt placement: MISFixture.SeedPlacement,
    ) throws {
        let directory = MISFixture.scratch(name)
        defer { MISFixture.discard(directory) }
        try MISFixture.makeCache(at: directory, seedAt: placement)

        let first = try DyldSharedCacheMISTrustAuthPatcher.patch(
            chunksDirectory: directory,
            log: nil,
        )
        #expect(first.outcome == .patched)
        let afterFirst = try MISFixture.chunkBytes(in: directory)

        // The run that used to throw `patchSiteNotFound` on a 27.0 guest.
        let second = try DyldSharedCacheMISTrustAuthPatcher.patch(
            chunksDirectory: directory,
            log: nil,
        )
        #expect(second.outcome == .alreadyPatched)
        #expect(second.sitesWritten == 0)
        #expect(second.record == nil)
        #expect(second.site?.functionVMA == MISFixture.functionVMA)
        #expect(try MISFixture.chunkBytes(in: directory) == afterFirst)

        // …and a third, because "re-attest the page" must also be a no-op.
        let third = try DyldSharedCacheMISTrustAuthPatcher.patch(
            chunksDirectory: directory,
            log: nil,
        )
        #expect(third.outcome == .alreadyPatched)
        #expect(try MISFixture.chunkBytes(in: directory) == afterFirst)
        let hashes = try MISFixture.pageHashes(in: directory, forVMA: MISFixture.functionVMA)
        #expect(hashes.computed == hashes.stored)
    }

    @Test
    func `A second run is a no-op when the seed outlives the write`() throws {
        // The 26.6.2 layout: the seed sits at +0x4C and is still there
        // afterwards, so `findSeededError` keeps matching.
        try expectSecondRunIsANoOp(named: "twice_seed_survives", seedAt: .afterPrologue)
    }

    @Test
    func `A second run is a no-op when the write destroyed the seed`() throws {
        // The 27.0 layout from issue #532: the seed *was* the two words this
        // patch overwrites. Before the fix this threw `patchSiteNotFound` and
        // took the whole `cfw install` down with it.
        try expectSecondRunIsANoOp(named: "twice_seed_destroyed", seedAt: .inTheWordsWeOverwrite)
    }

    @Test
    func `A dry run over a patched cache reports alreadyPatched, not wouldPatch`() throws {
        let directory = MISFixture.scratch("dry_twice")
        defer { MISFixture.discard(directory) }
        try MISFixture.makeCache(at: directory, seedAt: .inTheWordsWeOverwrite)
        try DyldSharedCacheMISTrustAuthPatcher.patch(chunksDirectory: directory, log: nil)
        let afterFirst = try MISFixture.chunkBytes(in: directory)

        let report = try DyldSharedCacheMISTrustAuthPatcher.patch(
            chunksDirectory: directory,
            dryRun: true,
            log: nil,
        )
        #expect(report.outcome == .alreadyPatched)
        #expect(try MISFixture.chunkBytes(in: directory) == afterFirst)
    }

    @Test
    func `locateSite reports the patched shape once the seed is gone`() throws {
        let directory = MISFixture.scratch("locate_twice")
        defer { MISFixture.discard(directory) }
        try MISFixture.makeCache(at: directory, seedAt: .inTheWordsWeOverwrite)
        try DyldSharedCacheMISTrustAuthPatcher.patch(chunksDirectory: directory, log: nil)

        let chunks = try DyldSharedCacheChunkSet(directory: directory)
        let site = try #require(try DyldSharedCacheMISTrustAuthPatcher.locateSite(in: chunks))
        #expect(site.shape == .alreadyShortCircuited)
        #expect(site.seedVMA == nil)
        #expect(site.resultRegister == nil)
        // The seed really is gone — this is not the other branch matching.
        #expect(try DyldSharedCacheMISTrustAuthPatcher.findSeededError(
            at: site.functionVMA,
            in: chunks,
        ) == nil)
    }
}

// MARK: - The shape detector on its own

@Suite
struct DyldSharedCacheMISTrustAuthShapeDetectorTests {
    private func decode(_ words: [Data]) -> [ARM64Instruction] {
        ARM64Disassembler().disassemble(words.reduce(Data(), +), at: MISFixture.functionVMA)
    }

    @Test
    func `pacibsp ; mov x0,#0 ; retab is this patch's own output`() {
        #expect(DyldSharedCacheMISTrustAuthPatcher.isShortCircuited(
            decode([ARM64.pacibsp, ARM64.movX0_0, ARM64.retab]),
        ))
    }

    @Test
    func `The stock prologue is not mistaken for it`() {
        #expect(!DyldSharedCacheMISTrustAuthPatcher.isShortCircuited(
            decode([ARM64.pacibsp] + [Data](repeating: ARM64.nop, count: 2)),
        ))
        #expect(!DyldSharedCacheMISTrustAuthPatcher.isShortCircuited(
            decode([ARM64.pacibsp, MISFixture.seed]),
        ))
    }

    @Test
    func `Each of the three words has to be the right one`() {
        // `mov w0, #0` is not `mov x0, #0`: a 32-bit return would leave the
        // top half of x0 undefined, and it is not what this patch writes.
        #expect(!DyldSharedCacheMISTrustAuthPatcher.isShortCircuited(
            decode([ARM64.pacibsp, ARM64.movW0_0, ARM64.retab]),
        ))
        // `mov x0, #1` returns the wrong thing.
        #expect(!DyldSharedCacheMISTrustAuthPatcher.isShortCircuited(
            decode([ARM64.pacibsp, ARM64.movX0_1, ARM64.retab]),
        ))
        // `retaa` authenticates with the wrong key for a `pacibsp`.
        #expect(!DyldSharedCacheMISTrustAuthPatcher.isShortCircuited(
            decode([ARM64.pacibsp, ARM64.movX0_0, ARM64.retaa]),
        ))
        // A plain `ret` is not what this patch leaves either.
        #expect(!DyldSharedCacheMISTrustAuthPatcher.isShortCircuited(
            decode([ARM64.pacibsp, ARM64.movX0_0, ARM64.ret]),
        ))
        // No prologue at all.
        #expect(!DyldSharedCacheMISTrustAuthPatcher.isShortCircuited(
            decode([ARM64.nop, ARM64.movX0_0, ARM64.retab]),
        ))
    }

    @Test
    func `A stream shorter than three instructions is not a match`() {
        #expect(!DyldSharedCacheMISTrustAuthPatcher.isShortCircuited([]))
        #expect(!DyldSharedCacheMISTrustAuthPatcher.isShortCircuited(
            decode([ARM64.pacibsp, ARM64.movX0_0]),
        ))
    }
}

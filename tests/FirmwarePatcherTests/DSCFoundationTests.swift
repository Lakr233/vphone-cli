// DSCFoundationTests.swift — Cross-checks for the DSC foundation layer.
//
// `codesign -v` does not apply to a dyld shared cache chunk, so the only
// independent reference for any of this was the Python in `scripts/patchers/`
// — `cfw_dsc_chunks` and `cfw_dsc_codesign`. That Python has been removed, so
// what it produced on the real cache is frozen in `FrozenReference` below.
//
// The small answers — a symbol address, a slot hash, an install name — are
// frozen literally. The big tables (103 mappings, 416 probe reads, 78 code
// directories, 44 string hits) are frozen as the SHA-256 of a canonical text
// form, which `Canonical` below rebuilds from the Swift side. A digest is not
// a number this repo invented: it is the reference's whole answer, and any
// single field that moves changes it.
//
// The tests need the real cache. Point `VPHONE_DSC_PRISTINE` at a directory of
// `dyld_shared_cache_arm64e*` chunks, or leave the default
// `ipsws/ref_extract/dsc_pristine` in place.
//
// Without it they FAIL. They used to open with `guard let pristine = … else
// { return }`, and a bare `return` is reported by Swift Testing as a pass — so
// "13 tests passed" was equally compatible with "13 tests did nothing", on any
// machine that had not extracted the 5.3 GB cache. A machine that genuinely
// cannot carry the fixture sets `VPHONE_DSC_FIXTURE_OPTIONAL=1`, which turns
// the failure into a visible *skip*. There is no configuration in which a green
// run means the cache was absent.
//
// Nothing here writes to the pristine directory. The re-signing tests clone it
// — `clonefile`, so instant and free on APFS — and work in the copy.

import CryptoKit
@testable import FirmwarePatcher
import Foundation
import Testing

// MARK: - The frozen reference

/// What `cfw_dsc_chunks` and `cfw_dsc_codesign` answered on the real 24A435
/// arm64e cache.
///
/// Recorded at commit 78cbeea by importing those modules from
/// `.venv/bin/python3` and driving them over `ipsws/ref_extract/dsc_pristine`
/// (and, for the writes, over clones of it). Each constant names the call.
private enum FrozenReference {
    // MARK: Layout

    /// `len(_enumerate_chunks(dir))` and `len(DSCChunks(dir).mappings())`.
    static let chunkCount = 79
    static let mappingCount = 103

    /// The first and last rows of `Canonical.mappings`, spelled out so a
    /// digest mismatch has something human to sit next to.
    static let firstMappingRow = "180000000 1800bc000 0 5 dyld_shared_cache_arm64e"
    static let lastMappingRow =
        "2d4fa8000 2fd500000 4000 1 dyld_shared_cache_arm64e.77.dyldlinkedit"

    /// SHA-256 of `Canonical.mappings` — all 103 rows of
    /// `(address, end, file_offset, init_prot, chunk)`.
    static let mappingsSHA256 =
        "8edc4100e0df480815d9cd3fff5855211a91b772996d771fd619713c818ee9dd"

    // MARK: Reads

    /// How many probe reads `Canonical.probes` covers: four per mapping
    /// (start, last eight bytes, last byte, midpoint) plus four real code
    /// sites.
    static let probeCount = 416

    /// SHA-256 of `Canonical.probes` — every probe's
    /// `(vma, length, chunk, file_offset, bytes)`, so the address-to-file
    /// translation and the bytes are frozen together.
    static let probesSHA256 =
        "1ab5b5a7d5bea1a4560d9b5b51415a92bbebaff4d6e0f6e8535bf70ff93174eb"

    /// Four bytes before the end of the main chunk's first mapping. The next
    /// mapping starts at 0x180400000 — a 3.3 MB hole — so bytes 4..63 of a
    /// 64-byte read correspond to no virtual address.
    static let overrunVMA: UInt64 = 0x1_800B_BFFC

    /// `DSCChunks.bytes_at_vma(0x1800BBFFC, 64).hex()`. The reference
    /// bounds-checked only the first byte, so it returned all 64 without
    /// complaint — bytes 4.. are the chunk's own `CS_SuperBlob` (`fade0cc0`),
    /// presented as if they lived at those addresses. The Swift refuses the
    /// read instead; this is the one deliberate divergence in the layer.
    static let overrunBytes = """
    00000000fade0cc0000006d600000003000000000000002400000002000006c2\
    00010000000006cefade0c020000069e0002040000000002000000be00000058
    """

    // MARK: Symbols, strings and images

    /// `resolve_local_symbol(dir, "_kern_SwapEnd")`.
    static let kernSwapEndVMA: UInt64 = 0x2_2AC0_C334

    /// `DSCChunks.find_string_vmas(b"kern.hv_vmm_present")`: 44 hits across the
    /// executable mappings, first and last as spelled here, all of them frozen
    /// together as the SHA-256 of `Canonical.addresses`.
    static let hvVMMStringCount = 44
    static let hvVMMStringFirst: UInt64 = 0x1_8C2D_B790
    static let hvVMMStringLast: UInt64 = 0x2_C08F_0F67
    static let hvVMMStringsSHA256 =
        "746e7059ae67f7b5ac1e083efebf1647d2090db28ffccddabf93dd873323902a"

    /// `find_macho_header_before(site)` and `read_install_name_at(header)` for
    /// three real code sites — one per image the DSC patchers touch.
    static let images: [(site: UInt64, header: UInt64, installName: String)] = [
        (0x2_2AC0_C334, 0x2_2AC0_B000,
         "/System/Library/PrivateFrameworks/IOMobileFramebuffer.framework/IOMobileFramebuffer"),
        (0x1_BF43_3BD0, 0x1_BF14_3000,
         "/System/Library/PrivateFrameworks/NeutrinoCore.framework/NeutrinoCore"),
        (0x1_AD8A_12D8, 0x1_AD84_B000,
         "/System/Library/PrivateFrameworks/AVFCapture.framework/AVFCapture"),
    ]

    // MARK: Code directories

    /// How many of the 79 chunks `_read_chunk_cd_blob` found a code directory
    /// in. The one without is the `.atlas` side file.
    static let codeDirectoryCount = 78

    /// SHA-256 of `Canonical.codeDirectories` — every chunk's
    /// `(blobOffset, blobLength, hashOffset, hashSize, codeSlotCount,
    /// codeLimit, pageSize)`, or `none`.
    static let codeDirectoriesSHA256 =
        "cba2286b4310e7b4cc45b8655e020df6c95042075f6d2a95647d5c0b92d4cca1"

    /// The main chunk's row, spelled out for the same reason as the mapping
    /// rows above.
    static let mainChunkDirectoryRow =
        "dyld_shared_cache_arm64e 770084 1694 190 32 47 770048 16384"

    // MARK: Re-signing

    /// The site the re-signing tests patch: inside `IOMobileFramebuffer`'s
    /// `__text`, a real executable page whose slot a real patch has to re-sign.
    static let patchSite: UInt64 = 0x2_2AC0_C334

    /// `bytes_at_vma(0x22AC0C334, 4).hex()` before anything is written —
    /// `pacibsp`.
    static let patchSiteOriginalBytes = "7f2303d5"

    /// The one diagnostic `reattest_modified_pages` returned after writing
    /// `mov w3, #0x588` (`03b18052`) at that site.
    static let resignChunk = "dyld_shared_cache_arm64e.38"
    static let resignPageIndex = 2563
    static let resignChunkOffset = 41_992_192
    static let resignSlotOffset = 130_892_098
    static let resignHashBefore =
        "5351489bc2d838a51a66a62e42ff7743457107335a35ddc82d3de4620e0c3e05"
    static let resignHashAfter =
        "f901fd7dd3ca8226722ebce5653d066a134c83c9925812957fc01d7b086dd31e"

    // MARK: The page-straddling write

    /// 0x22AC0FFFC is file offset 0x280FFFC of chunk .38 — the last four bytes
    /// of page 2563. The eight-byte stub `mov w0, #0; ret` (what
    /// `cfw_patch_camera_dsc` writes at a function entry) ends four bytes into
    /// page 2564.
    static let straddleVMA: UInt64 = 0x2_2AC0_FFFC
    static let straddleFirstPage = 2563
    static let straddleSecondPage = 2564

    /// Told that address, the reference re-attested page 2563 and stopped: its
    /// diagnostics named `[2563]`, page 2563 came out attested, and page 2564
    /// was left with its original slot while its bytes had moved —
    /// `computed dfe38096…` against `stored 7ccd65fa…`. The guest dies on the
    /// first demand-page-in of such a page, which is why the Swift covers both.
    static let straddleReferencePages = [2563]
    static let straddlePage2563Hash =
        "977f5abb356687af28158070c182b3017cfd5e90ccc82ef2eba8941d43d8020c"
    static let straddlePage2564Computed =
        "dfe38096f5ee7aaabeab6897f37e431eeacc0e9df589243abbb577877a1061c2"
    static let straddlePage2564Stored =
        "7ccd65fad32f1ee09d49a463dccc1226459a3b3bc2e6a45175b9a04c0e1e5423"

    // MARK: The mapping seam

    /// 0x1E00DFFFE is two bytes before the end of the first mapping of
    /// `.25.dylddata`; the next mapping continues at file offset 0x4000 of the
    /// same file. Four bytes therefore cross both a mapping seam and a 16 KiB
    /// page boundary. `write_at_vma` accepted it and the four bytes landed at
    /// file offset 0x3FFE.
    static let seamVMA: UInt64 = 0x1_E00D_FFFE
    static let seamChunk = "dyld_shared_cache_arm64e.25.dylddata"
    static let seamFileOffset: UInt64 = 0x3FFE
    static let seamBytes = "11223344"
}

// MARK: - Canonical forms

/// The text forms the frozen digests were taken over.
///
/// Each row is exactly what the reference printed: lowercase hex without
/// padding for addresses and file offsets, decimal for everything else, single
/// spaces between fields, one trailing newline at the end of the table.
private enum Canonical {
    static func hex(_ value: UInt64) -> String {
        String(value, radix: 16)
    }

    static func sha256(of text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// `address end file_offset init_prot chunk`, in mapping-table order.
    static func mappings(_ chunks: DSCChunkSet) -> String {
        chunks.mappings.map {
            "\(hex($0.address)) \(hex($0.endAddress)) \(hex($0.fileOffset)) "
                + "\($0.initProt) \($0.chunkURL.lastPathComponent)"
        }.joined(separator: "\n") + "\n"
    }

    /// `vma length chunk file_offset bytes`, in request order.
    static func probes(
        _ chunks: DSCChunkSet,
        _ requests: [(UInt64, Int)],
    ) throws -> String {
        try requests.map { vma, length in
            let located = try #require(chunks.findChunk(forVMA: vma))
            let bytes = try chunks.bytesAtVMA(vma, length: length)
            return "\(hex(vma)) \(length) \(located.chunkURL.lastPathComponent) "
                + "\(hex(UInt64(located.fileOffset))) \(bytes.hex)"
        }.joined(separator: "\n") + "\n"
    }

    /// One address per row, sorted ascending.
    static func addresses(_ values: [UInt64]) -> String {
        values.sorted().map(hex).joined(separator: "\n") + "\n"
    }

    /// `chunk blobOffset blobLength hashOffset hashSize codeSlotCount
    /// codeLimit pageSize`, or `chunk none`, in chunk order.
    static func codeDirectories(_ chunks: DSCChunkSet) throws -> [String] {
        try chunks.chunkURLs.map { url in
            let name = url.lastPathComponent
            guard let directory = try DSCCodeSignature.readCodeDirectory(ofChunk: url) else {
                return "\(name) none"
            }
            return "\(name) \(directory.blobOffset) \(directory.blobLength) "
                + "\(directory.hashOffset) \(directory.hashSize) "
                + "\(directory.codeSlotCount) \(directory.codeLimit) \(directory.pageSize)"
        }
    }
}

// MARK: - Fixture discovery

private enum DSCFixture {
    static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    /// The read-only reference cache.
    static var pristine: URL? {
        let url = ProcessInfo.processInfo.environment["VPHONE_DSC_PRISTINE"]
            .map { URL(fileURLWithPath: $0) }
            ?? repoRoot.appendingPathComponent("ipsws/ref_extract/dsc_pristine")
        let main = url.appendingPathComponent("dyld_shared_cache_arm64e")
        return FileManager.default.fileExists(atPath: main.path) ? url : nil
    }

    /// Opt-out for a machine that cannot carry the fixture. Set it and the
    /// suites report as skipped; leave it unset and a missing cache is a
    /// failure, which is the only reading of "green" this layer can afford.
    static var isOptional: Bool {
        ProcessInfo.processInfo.environment["VPHONE_DSC_FIXTURE_OPTIONAL"] == "1"
    }

    /// The suites run unless the cache is absent *and* the caller opted out.
    static var runs: Bool {
        pristine != nil || !isOptional
    }

    static let missing: Comment = """
    the real 24A435 arm64e shared cache is required — put it at \
    ipsws/ref_extract/dsc_pristine, point VPHONE_DSC_PRISTINE at it, or set \
    VPHONE_DSC_FIXTURE_OPTIONAL=1 to skip these tests instead of failing
    """

    static let skipReason: Comment =
        "VPHONE_DSC_FIXTURE_OPTIONAL=1 and no dyld_shared_cache_arm64e fixture present"

    /// Where clones are made. Same filesystem as the pristine copy, so
    /// `cp -c` is a clone rather than 6.7 GB of reads.
    ///
    /// Deliberately a sibling of `ref_extract/`, not a child of it. This used
    /// to sit at `ref_extract/scratch_dscfoundation`, inside the pristine tree
    /// the whole suite compares against: the cleanup works, but any run that
    /// is interrupted leaves multi-GB clones in there, and a reference tree
    /// with scratch in it is no longer a reference. `ipsws/` is the same
    /// filesystem, so the clone is still a clone.
    static var scratchRoot: URL {
        repoRoot.appendingPathComponent("ipsws/scratch_dscfoundation")
    }

    static var ipsw: URL? {
        let url = URL(fileURLWithPath: "/opt/homebrew/bin/ipsw")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Clone the pristine cache into a fresh directory the caller may write to.
    static func cloneCache(named name: String) throws -> URL {
        guard let pristine else { throw CocoaError(.fileNoSuchFile) }
        let destination = scratchRoot.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.createDirectory(
            at: destination,
            withIntermediateDirectories: true,
        )
        let result = try Subprocess.run(
            executable: URL(fileURLWithPath: "/bin/cp"),
            arguments: ["-c", "-R"]
                + (FileManager.default.contentsOfDirectory(atPath: pristine.path))
                .sorted()
                .map { pristine.appendingPathComponent($0).path }
                + [destination.path],
        )
        guard result.status == 0 else {
            throw CocoaError(.fileWriteUnknown)
        }
        return destination
    }

    /// Discard a clone, and the scratch root with it once the last clone is
    /// gone — the suite used to leave an empty `scratch_dscfoundation/` behind
    /// on every run, so the working tree was not left as found.
    static func discard(_ clones: URL...) {
        for clone in clones {
            try? FileManager.default.removeItem(at: clone)
        }
        let remaining = (try? FileManager.default
            .contentsOfDirectory(atPath: scratchRoot.path)) ?? []
        if remaining.isEmpty {
            try? FileManager.default.removeItem(at: scratchRoot)
        }
    }
}

// MARK: - Subprocess helper

private enum Subprocess {
    struct Result {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    @discardableResult
    static func run(
        executable: URL,
        arguments: [String],
        currentDirectory: URL? = nil,
    ) throws -> Result {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let currentDirectory {
            process.currentDirectoryURL = currentDirectory
        }
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        // Drain before waiting: a full pipe buffer would deadlock a symbol dump.
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Result(
            status: process.terminationStatus,
            stdout: String(decoding: outData, as: UTF8.self),
            stderr: String(decoding: errData, as: UTF8.self),
        )
    }
}

// MARK: - Slot state, read the way the reference read it

/// What one 16 KiB page hashes to now, and what its code slot claims it hashes
/// to — the two numbers `cfw_dsc_codesign` compared, read straight out of the
/// chunk's own code directory rather than from a patcher's bookkeeping.
private enum SlotState {
    static func read(
        directory: URL,
        chunk: String,
        page: Int,
    ) throws -> (computed: String, stored: String, isAttested: Bool) {
        let url = directory.appendingPathComponent(chunk)
        let cd = try #require(
            try DSCCodeSignature.readCodeDirectory(ofChunk: url),
            "\(chunk) carries no code directory",
        )
        let (computed, stored) = try DSCCodeSignature.pageHashes(
            chunkURL: url,
            pageIndex: page,
            directory: cd,
        )
        return (computed.hex, stored.hex, computed == stored)
    }
}

// MARK: - 3.1 · Flat addressing

@Suite(.serialized, .enabled(if: DSCFixture.runs, DSCFixture.skipReason))
struct DSCFlatAddressingTests {
    @Test
    func `Chunk enumeration and mapping table match the reference`() throws {
        let pristine = try #require(DSCFixture.pristine, DSCFixture.missing)

        let chunks = try DSCChunkSet(directory: pristine)
        #expect(chunks.chunkURLs.count == FrozenReference.chunkCount)
        #expect(chunks.mappings.count == FrozenReference.mappingCount)

        let rows = Canonical.mappings(chunks).split(separator: "\n").map(String.init)
        #expect(rows.first == FrozenReference.firstMappingRow)
        #expect(rows.last == FrozenReference.lastMappingRow)
        #expect(
            Canonical.sha256(of: Canonical.mappings(chunks))
                == FrozenReference.mappingsSHA256,
            "the mapping table no longer matches the reference's",
        )
        print(
            "[layout] \(chunks.chunkURLs.count) chunks, \(chunks.mappings.count) mappings, "
                + "vm 0x\(String(chunks.addressRange.lowerBound, radix: 16, uppercase: true))"
                + "..0x\(String(chunks.addressRange.upperBound, radix: 16, uppercase: true))",
        )
    }

    /// Reads spread across every mapping, including the first and last bytes of
    /// each one — the spots where an off-by-one in the boundary test would
    /// silently read out of the neighbouring chunk.
    private func probeRequests(for chunks: DSCChunkSet) -> [(UInt64, Int)] {
        var requests: [(UInt64, Int)] = []
        for mapping in chunks.mappings {
            requests.append((mapping.address, 16))
            requests.append((mapping.endAddress - 8, 8))
            requests.append((mapping.endAddress - 1, 1))
            if mapping.size >= 256 {
                let middle = (mapping.address + mapping.size / 2) & ~7
                requests.append((middle, 64))
            }
        }
        // Real code sites, not just mapping arithmetic.
        for site: UInt64 in [0x2_2AC0_C334, 0x1_BF43_3BD0, 0x1_AD8A_12D8, 0x2_2AC0_C1B0] {
            requests.append((site, 32))
        }
        return requests
    }

    @Test
    func `bytesAtVMA matches the reference across every mapping and boundary`() throws {
        let pristine = try #require(DSCFixture.pristine, DSCFixture.missing)

        let chunks = try DSCChunkSet(directory: pristine)
        let requests = probeRequests(for: chunks)
        #expect(requests.count == FrozenReference.probeCount)

        // Every probe's chunk, file offset and bytes, in one digest — the whole
        // of what the reference answered for these 416 reads.
        #expect(
            try Canonical.sha256(of: Canonical.probes(chunks, requests))
                == FrozenReference.probesSHA256,
            "a read, or its address-to-file translation, no longer matches the reference",
        )

        var boundaryChecks = 0
        for (vma, length) in requests {
            if let mapping = chunks.mapping(forVMA: vma),
               vma + UInt64(length) == mapping.endAddress
            {
                boundaryChecks += 1
            }
        }
        print("[bytes] \(requests.count) reads agreed, \(boundaryChecks) of them ending exactly on a mapping boundary")
        #expect(boundaryChecks >= 2)
    }

    @Test
    func `A read or write that leaves its chunk is refused, not truncated`() throws {
        let pristine = try #require(DSCFixture.pristine, DSCFixture.missing)
        let chunks = try DSCChunkSet(directory: pristine)
        let mapping = try #require(chunks.mappings.first { $0.size > 64 })
        let lastFour = mapping.endAddress - 4

        // Reading past the end of a mapping is not a short read, it is a
        // different chunk's bytes. Every API has to say so.
        #expect(throws: DSCError.self) {
            _ = try chunks.readAtVMA(lastFour, length: 64)
        }
        let short = try chunks.readAtVMA(lastFour, length: 64, allowShort: true)
        #expect(short.count == 4)

        #expect(throws: DSCError.self) {
            _ = try chunks.write(at: lastFour, Data(repeating: 0, count: 64))
        }
        #expect(throws: DSCError.self) {
            _ = try chunks.bytesAtVMA(chunks.addressRange.upperBound + 0x1000, length: 4)
        }
        // And `bytesAtVMA` itself, at the same boundary — the case the suite
        // used to name but never exercise.
        #expect(throws: DSCError.self) {
            _ = try chunks.bytesAtVMA(lastFour, length: 64)
        }
        #expect(try chunks.bytesAtVMA(lastFour, length: 4).count == 4)
    }

    /// The reference bounds-checked only the first byte of a read, then read
    /// `length` raw bytes from the file. So a read that starts near the end of
    /// a mapping came back padded with whatever follows in the file, presented
    /// as the bytes at those virtual addresses. This is the one place the Swift
    /// deliberately diverges, and the test pins both halves: what the reference
    /// returned, and that the Swift refuses it.
    @Test
    func `An over-running read returned the chunk's signature; here it throws`() throws {
        let pristine = try #require(DSCFixture.pristine, DSCFixture.missing)

        let chunks = try DSCChunkSet(directory: pristine)
        let overrun = FrozenReference.overrunVMA
        let mapping = try #require(chunks.mapping(forVMA: overrun))
        #expect(mapping.endAddress == overrun + 4)

        #expect(throws: DSCError.self) {
            _ = try chunks.bytesAtVMA(overrun, length: 64)
        }

        let referenceBytes = FrozenReference.overrunBytes
        #expect(referenceBytes.count == 128, "the reference returned all 64 bytes")
        // Bytes 4.. are the chunk's own CS_SuperBlob, not code.
        #expect(referenceBytes.contains("fade0cc0"))

        // The four bytes that really are at that address still read fine, and
        // they are the four the reference's answer opens with.
        let inBounds = try chunks.bytesAtVMA(overrun, length: 4)
        #expect(referenceBytes.hasPrefix(inBounds.hex))
        print("[overrun] swift threw; its in-bounds 4 bytes are \(inBounds.hex)")
    }

    @Test
    func `resolveLocalSymbol matches the reference and ipsw`() throws {
        let pristine = try #require(DSCFixture.pristine, DSCFixture.missing)

        let chunks = try DSCChunkSet(directory: pristine)
        let name = "_kern_SwapEnd"
        let mine = try #require(try chunks.resolveLocalSymbol(name))
        #expect(mine == FrozenReference.kernSwapEndVMA)
        print("[local symbol] \(name) = 0x\(String(mine, radix: 16))")

        // A name that is not in the table is `nil`, and that is a different
        // answer from the table not being there — see
        // `missingLocalSymbolTableIsNotAMissingSymbol`.
        #expect(try chunks.resolveLocalSymbol("_definitely_not_a_symbol_xyz") == nil)
    }

    /// The `try?` this replaced spelled "I could not open the table" and "that
    /// symbol does not exist" the same way, as `nil`. The reference raised
    /// `FileNotFoundError`; so does this, in its own vocabulary.
    @Test
    func `A missing local symbol table is not the same answer as a missing symbol`() throws {
        _ = try #require(DSCFixture.pristine, DSCFixture.missing)

        let clone = try DSCFixture.cloneCache(named: "symbols_removed")
        defer { DSCFixture.discard(clone) }
        try FileManager.default.removeItem(
            at: clone.appendingPathComponent("dyld_shared_cache_arm64e.symbols"),
        )

        let chunks = try DSCChunkSet(directory: clone)
        #expect(throws: DSCError.self) {
            _ = try chunks.resolveLocalSymbol("_kern_SwapEnd")
        }
        #expect(throws: DSCError.self) {
            _ = try chunks.resolveLocalSymbol("_definitely_not_a_symbol_xyz")
        }

        // And the resolver built on the same cache says so rather than
        // reporting entry points with no siblings.
        let resolver = try DSCSymbolResolver(
            mainCacheURL: clone.appendingPathComponent("dyld_shared_cache_arm64e"),
        )
        #expect(!resolver.hasLocalSymbols)
        #expect(throws: DSCError.self) { try resolver.requireLocalSymbols() }
        #expect(throws: DSCError.self) {
            _ = try resolver.address(
                of: "_kern_SwapEnd",
                inImage: "/System/Library/PrivateFrameworks/IOMobileFramebuffer.framework/IOMobileFramebuffer",
            )
        }
        print("[symbols missing] resolveLocalSymbol and the resolver both report the absent table")
    }

    /// The two helpers P1.3's `hv_vmm` and canonical-site finders are built on:
    /// a C-string sweep of the executable mappings, and the walk back from an
    /// address to the image that owns it.
    @Test
    func `String search and image lookup match the reference`() throws {
        let pristine = try #require(DSCFixture.pristine, DSCFixture.missing)

        let chunks = try DSCChunkSet(directory: pristine)

        let needle = "kern.hv_vmm_present"
        let mine = try chunks.findStringVMAs(Data(needle.utf8)).sorted()
        #expect(mine.count == FrozenReference.hvVMMStringCount)
        #expect(mine.first == FrozenReference.hvVMMStringFirst)
        #expect(mine.last == FrozenReference.hvVMMStringLast)
        #expect(
            Canonical.sha256(of: Canonical.addresses(mine))
                == FrozenReference.hvVMMStringsSHA256,
            "the string sweep no longer finds the reference's hits",
        )
        print("[strings] \"\(needle)\": \(mine.count) hits, first 0x\(String(mine[0], radix: 16))")

        for expected in FrozenReference.images {
            let header = try #require(try chunks.findMachOHeaderBefore(expected.site))
            let name = chunks.readInstallName(atHeaderVMA: header)
            #expect(header == expected.header)
            #expect(name == expected.installName)
            print("[image] 0x\(String(expected.site, radix: 16)) -> "
                + "0x\(String(header, radix: 16)) \(name ?? "<none>")")
        }
    }
}

// MARK: - 3.2 · Code-signature page-hash re-signing, DSC path

@Suite(.serialized, .enabled(if: DSCFixture.runs, DSCFixture.skipReason))
struct DSCCodeSignatureTests {
    /// A site inside `IOMobileFramebuffer`'s `__text` — a real executable page
    /// whose slot a real patch would have to re-sign.
    private let patchSite = FrozenReference.patchSite

    @Test
    func `Chunk code directories match the reference`() throws {
        let pristine = try #require(DSCFixture.pristine, DSCFixture.missing)

        let chunks = try DSCChunkSet(directory: pristine)
        let rows = try Canonical.codeDirectories(chunks)
        let found = rows.filter { !$0.hasSuffix(" none") }.count
        #expect(found == FrozenReference.codeDirectoryCount)
        #expect(rows.first == FrozenReference.mainChunkDirectoryRow)
        #expect(
            Canonical.sha256(of: rows.joined(separator: "\n") + "\n")
                == FrozenReference.codeDirectoriesSHA256,
            "a chunk's code directory no longer parses the way the reference parsed it",
        )
        print("[code directories] \(found) chunk signatures agreed with the reference")
    }

    /// The DSC path's stated invariants: 16 KiB pages, a single SHA-256 code
    /// directory, and no short tail slot.
    @Test
    func `Every signed chunk is 16 KiB paged, SHA-256, and chunk-aligned`() throws {
        let pristine = try #require(DSCFixture.pristine, DSCFixture.missing)
        let chunks = try DSCChunkSet(directory: pristine)
        var checked = 0
        for url in chunks.chunkURLs {
            guard let directory = try DSCCodeSignature.readCodeDirectory(ofChunk: url) else {
                continue
            }
            #expect(directory.pageSize == 16384, "\(url.lastPathComponent) page size")
            #expect(directory.hashSize == 32, "\(url.lastPathComponent) hash size")
            // Chunk-aligned: the last slot covers a whole page, so unlike the
            // independent Mach-O path there is no short tail to special-case.
            let covered = directory.codeSlotCount * directory.pageSize
            #expect(
                covered == directory.codeLimit,
                "\(url.lastPathComponent) has a short tail slot: codeLimit \(directory.codeLimit), slots cover \(covered)",
            )
            checked += 1
        }
        print("[shape] \(checked) chunks: 16 KiB pages, SHA-256, no short tail slot")
        #expect(checked > 70)
    }

    /// The gate from the plan: patch one byte, re-sign, and require the page
    /// and its slot to come out as the reference's did.
    @Test
    func `Re-signing produces the reference's slot hashes`() throws {
        _ = try #require(DSCFixture.pristine, DSCFixture.missing)

        let swiftSide = try DSCFixture.cloneCache(named: "resign_swift")
        defer { DSCFixture.discard(swiftSide) }

        // The replacement is a real instruction shape — `mov w3, #0x588`, the
        // immediate `cfw_patch_iomfb_swapend` writes — not a byte pattern
        // chosen to be easy.
        let replacement = Data([0x03, 0xB1, 0x80, 0x52])

        // Same write, same re-sign — and the re-sign is driven by what the
        // write itself recorded, not by an address repeated by hand.
        let chunks = try DSCChunkSet(directory: swiftSide)
        let originalBytes = try chunks.bytesAtVMA(patchSite, length: replacement.count)
        #expect(originalBytes.hex == FrozenReference.patchSiteOriginalBytes)
        let span = try chunks.write(at: patchSite, replacement)
        #expect(span == DSCWriteSpan(vma: patchSite, length: 4))
        #expect(chunks.recordedWrites == [span])

        var log: [String] = []
        let result = try DSCCodeSignature.reattestRecordedWrites(
            in: chunks,
            log: { log.append($0) },
        )
        #expect(result.updated.count == 1)
        #expect(result.isFullyAttested)
        let mine = try #require(result.updated.first)

        // The hashes themselves — the reference's single diagnostic, field for
        // field.
        #expect(mine.chunkURL.lastPathComponent == FrozenReference.resignChunk)
        #expect(mine.pageIndex == FrozenReference.resignPageIndex)
        #expect(mine.chunkOffset == FrozenReference.resignChunkOffset)
        #expect(mine.slotOffset == FrozenReference.resignSlotOffset)
        #expect(mine.hashBefore.hex == FrozenReference.resignHashBefore)
        #expect(mine.hashAfter.hex == FrozenReference.resignHashAfter)

        // And the bytes on disk, which is the claim that actually matters: the
        // stored slot has to be the digest of the page as it now stands.
        let chunkName = mine.chunkURL.lastPathComponent
        let directory = try #require(
            try DSCCodeSignature.readCodeDirectory(ofChunk: mine.chunkURL),
        )
        let (computed, stored) = try DSCCodeSignature.pageHashes(
            chunkURL: mine.chunkURL,
            pageIndex: mine.pageIndex,
            directory: directory,
        )
        #expect(computed == stored)
        #expect(stored.hex == FrozenReference.resignHashAfter)

        print("[re-sign] chunk \(chunkName) page \(mine.pageIndex) slot @0x\(String(mine.slotOffset, radix: 16))")
        print("[re-sign] swift     \(mine.hashAfter.hex)")
        print("[re-sign] reference \(FrozenReference.resignHashAfter)")
        for line in log {
            print(line)
        }
    }

    /// The finding all three verifiers reached independently, pinned.
    ///
    /// Eight bytes — `mov w0, #0; ret`, exactly what `cfw_patch_camera_dsc.py`
    /// wrote at each of its six function entries — placed so four of them land
    /// on page 2563 and four on page 2564. Re-attesting the address alone
    /// covers one page; the other keeps its original slot hash, and the guest
    /// dies on the first demand-page-in of it. The reference did exactly that;
    /// this checks the Swift no longer can.
    @Test
    func `A write across a page boundary re-attests both pages, where the reference attested one`() throws {
        _ = try #require(DSCFixture.pristine, DSCFixture.missing)

        let swiftSide = try DSCFixture.cloneCache(named: "straddle_swift")
        defer { DSCFixture.discard(swiftSide) }

        let straddle = FrozenReference.straddleVMA
        let stub = Data([0x00, 0x00, 0x80, 0x52, 0xC0, 0x03, 0x5F, 0xD6])
        let chunkName = FrozenReference.resignChunk
        let firstPage = FrozenReference.straddleFirstPage
        let secondPage = FrozenReference.straddleSecondPage

        // Swift: write, then re-attest from what the write recorded.
        let chunks = try DSCChunkSet(directory: swiftSide)
        let span = try chunks.write(at: straddle, stub)
        #expect(span.length == 8)
        let (writtenChunk, writtenRange) = try chunks.fileRange(of: span)
        #expect(writtenChunk.lastPathComponent == chunkName)
        #expect(writtenRange == 0x280FFFC ..< 0x2810004)

        var log: [String] = []
        let result = try DSCCodeSignature.reattestRecordedWrites(
            in: chunks,
            log: { log.append($0) },
        )
        #expect(result.updated.map(\.pageIndex) == [firstPage, secondPage])
        #expect(result.isFullyAttested)

        // Both pages, read back out of the chunk's own code directory rather
        // than from the patcher's bookkeeping.
        for page in [firstPage, secondPage] {
            let state = try SlotState.read(directory: swiftSide, chunk: chunkName, page: page)
            #expect(state.isAttested, "swift left page \(page) stale: \(state.stored)")
            print("[straddle swift] page \(page) stored \(state.stored.prefix(16))… == computed")
        }

        // Page 2563 comes out with the hash the reference also computed for it
        // — the reference covered that one page and stopped.
        #expect(FrozenReference.straddleReferencePages == [firstPage])
        let first = try SlotState.read(directory: swiftSide, chunk: chunkName, page: firstPage)
        #expect(first.computed == FrozenReference.straddlePage2563Hash)

        // Page 2564 is the divergence, on the record: the reference left it
        // holding `7ccd65fa…` while its bytes hashed to `dfe38096…`. The Swift
        // rewrote it, so the two now agree — and the value it agrees on is the
        // one the reference computed but did not store.
        let second = try SlotState.read(directory: swiftSide, chunk: chunkName, page: secondPage)
        #expect(second.computed == FrozenReference.straddlePage2564Computed)
        #expect(second.stored == FrozenReference.straddlePage2564Computed)
        #expect(
            FrozenReference.straddlePage2564Stored != FrozenReference.straddlePage2564Computed,
            "the reference's own second page was stale, which is why this test exists",
        )
        print("[straddle reference] page \(secondPage) was left stored "
            + "\(FrozenReference.straddlePage2564Stored.prefix(16))… vs computed "
            + "\(FrozenReference.straddlePage2564Computed.prefix(16))… — STALE")

        // The bytes themselves are the stub, at the file offset the reference
        // wrote them to.
        let swiftBytes = try DSCChunkSet.read(
            url: swiftSide.appendingPathComponent(chunkName),
            offset: 0x280FFFC,
            length: 8,
        )
        #expect(swiftBytes == stub)
        for line in log {
            print(line)
        }
    }

    /// A span may cross from one mapping into the next when the two are
    /// contiguous in address *and* in file offset inside the same chunk — 19 of
    /// the 62 adjacent mapping pairs on this cache are. The old guard compared
    /// mapping start addresses and refused all of them, where the reference
    /// wrote them happily. This one is accepted, and lands where the reference
    /// landed; the case where the file offsets break is still refused.
    @Test
    func `A write across contiguous mappings of one chunk lands where the reference put it`() throws {
        _ = try #require(DSCFixture.pristine, DSCFixture.missing)

        let swiftSide = try DSCFixture.cloneCache(named: "seam_swift")
        defer { DSCFixture.discard(swiftSide) }

        let seam = FrozenReference.seamVMA
        let value = Data([0x11, 0x22, 0x33, 0x44])
        let chunkName = FrozenReference.seamChunk

        let chunks = try DSCChunkSet(directory: swiftSide)
        let mapping = try #require(chunks.mapping(forVMA: seam))
        let next = try #require(chunks.mapping(forVMA: mapping.endAddress))
        #expect(next.chunkURL.lastPathComponent == chunkName)
        #expect(next.fileOffset == mapping.fileOffset + mapping.size)

        let span = try chunks.write(at: seam, value)
        let result = try DSCCodeSignature.reattestRecordedWrites(in: chunks, log: nil)
        #expect(span.length == 4)
        #expect(result.isFullyAttested)
        // 0x3FFE..0x4001 spans pages 0 and 1 of the chunk.
        #expect(result.updated.map(\.pageIndex) + result.alreadyAttested.map(\.pageIndex) == [0, 1])

        // The reference's `write_at_vma` put these four bytes at file offset
        // 0x3FFE of this chunk. So must this one.
        let mine = try DSCChunkSet.read(
            url: swiftSide.appendingPathComponent(chunkName),
            offset: FrozenReference.seamFileOffset,
            length: 4,
        )
        #expect(mine.hex == FrozenReference.seamBytes)
        #expect(mine == value)
        print("[seam] 0x\(String(seam, radix: 16)) -> \(chunkName)@0x3ffe: \(mine.hex)")

        for page in [0, 1] {
            let state = try SlotState.read(directory: swiftSide, chunk: chunkName, page: page)
            #expect(state.isAttested, "page \(page) left stale")
        }

        // A seam where the file offsets do not continue is still a refusal.
        let crossChunk = try #require(
            chunks.mappings.first { mapping in
                guard let next = chunks.mapping(forVMA: mapping.endAddress) else { return false }
                return next.chunkURL != mapping.chunkURL
            },
        )
        #expect(throws: DSCError.self) {
            _ = try chunks.write(at: crossChunk.endAddress - 2, Data([0, 0, 0, 0]))
        }
    }

    /// `8eb6c8b` fixed a patcher that did not recognise its own output. The
    /// same trap applies here: a second re-sign of an already-attested page has
    /// to be a no-op, not a rewrite and not an error.
    @Test
    func `Re-signing twice is a no-op the second time`() throws {
        _ = try #require(DSCFixture.pristine, DSCFixture.missing)

        let clone = try DSCFixture.cloneCache(named: "resign_idempotent")
        defer { DSCFixture.discard(clone) }

        let chunks = try DSCChunkSet(directory: clone)
        let span = try chunks.write(at: patchSite, Data([0x03, 0xB1, 0x80, 0x52]))

        let first = try DSCCodeSignature.reattest(in: chunks, modifiedSpans: [span], log: nil)
        #expect(first.updated.count == 1)
        #expect(first.alreadyAttested.isEmpty)

        let second = try DSCCodeSignature.reattest(in: chunks, modifiedSpans: [span], log: nil)
        #expect(second.updated.isEmpty, "a second re-sign rewrote a slot that already matched")
        #expect(second.alreadyAttested.count == 1, "and it has to say so, not just return nothing")
        #expect(second.isFullyAttested)

        // Several addresses inside one page still cost exactly one slot.
        let third = try DSCCodeSignature.reattest(
            in: chunks,
            modifiedSpans: [patchSite, patchSite + 4, patchSite + 8].map(DSCWriteSpan.byte(at:)),
            log: nil,
        )
        #expect(third.updated.isEmpty)
        #expect(third.alreadyAttested.count == 1)
        print("[idempotence] first run rewrote 1 slot; second and third rewrote 0 and reported 1 already correct")
    }

    /// Every early return used to yield `[]` under the default `log: nil`, so
    /// "I skipped an address I could not map", "everything already matched" and
    /// "you passed me nothing" were the same value. They are three different
    /// values now, and the default log is no longer silent.
    @Test
    func `A skipped page is distinguishable from nothing to do`() throws {
        let pristine = try #require(DSCFixture.pristine, DSCFixture.missing)
        let chunks = try DSCChunkSet(directory: pristine)

        let stray = try DSCCodeSignature.reattest(
            in: chunks,
            modifiedSpans: [DSCWriteSpan.byte(at: 0xDEAD_0000_0000)],
            dryRun: true,
            log: nil,
        )
        #expect(stray.updated.isEmpty)
        #expect(stray.skipped.count == 1)
        #expect(!stray.isFullyAttested, "an unmapped address is not a clean run")
        if case let .addressNotMapped(vma) = stray.skipped[0].reason {
            #expect(vma == 0xDEAD_0000_0000)
        } else {
            Issue.record("wrong skip reason: \(stray.skipped[0].reason)")
        }

        let nothing = try DSCCodeSignature.reattest(
            in: chunks,
            modifiedSpans: [] as [DSCWriteSpan],
            dryRun: true,
            log: nil,
        )
        #expect(nothing.skipped.isEmpty)
        #expect(nothing.isFullyAttested, "nothing to do is a clean run")

        // A span that runs off the end of its chunk is its own reason.
        let mapping = try #require(chunks.mappings.first { $0.size > 64 })
        let overrun = try DSCCodeSignature.reattest(
            in: chunks,
            modifiedSpans: [DSCWriteSpan(vma: mapping.endAddress - 2, length: 64)],
            dryRun: true,
            log: nil,
        )
        #expect(overrun.skipped.count == 1)
        if case .spanNotAddressable = overrun.skipped[0].reason {} else {
            Issue.record("wrong skip reason: \(overrun.skipped[0].reason)")
        }

        // And the default log says all of it out loud, as the reference's
        // verbose=True did.
        var spoken: [String] = []
        _ = try DSCCodeSignature.reattest(
            in: chunks,
            modifiedSpans: [DSCWriteSpan.byte(at: 0xDEAD_0000_0000)],
            dryRun: true,
            log: { spoken.append($0) },
        )
        #expect(spoken.contains { $0.contains("not mapped in any chunk") })
        for line in spoken {
            print("[skip log] \(line)")
        }
    }

    @Test
    func `A dry run computes the same hash it would have written, and writes nothing`() throws {
        _ = try #require(DSCFixture.pristine, DSCFixture.missing)

        let clone = try DSCFixture.cloneCache(named: "resign_dryrun")
        defer { DSCFixture.discard(clone) }

        let chunks = try DSCChunkSet(directory: clone)
        try chunks.write(at: patchSite, Data([0x03, 0xB1, 0x80, 0x52]))

        let dry = try DSCCodeSignature.reattestRecordedWrites(
            in: chunks,
            dryRun: true,
            log: nil,
        )
        #expect(dry.updated.count == 1)
        let record = try #require(dry.updated.first)

        let directory = try #require(
            try DSCCodeSignature.readCodeDirectory(ofChunk: record.chunkURL),
        )
        let (_, storedAfterDryRun) = try DSCCodeSignature.pageHashes(
            chunkURL: record.chunkURL,
            pageIndex: record.pageIndex,
            directory: directory,
        )
        #expect(storedAfterDryRun == record.hashBefore, "a dry run must not touch the slot")

        let wet = try DSCCodeSignature.reattestRecordedWrites(in: chunks, log: nil)
        #expect(wet.updated.first?.hashAfter == record.hashAfter)
    }
}

// MARK: - 3.3 · Symbol resolution

@Suite(.serialized, .enabled(if: DSCFixture.runs, DSCFixture.skipReason))
struct DSCSymbolResolverTests {
    private static let neutrinoCore =
        "/System/Library/PrivateFrameworks/NeutrinoCore.framework/NeutrinoCore"
    private static let avfCapture =
        "/System/Library/PrivateFrameworks/AVFCapture.framework/AVFCapture"
    private static let ioMobileFramebuffer =
        "/System/Library/PrivateFrameworks/IOMobileFramebuffer.framework/IOMobileFramebuffer"

    /// The complete set the three patchers look up.
    ///
    /// `cfw_patch_camera_dsc.py` names six ObjC methods; `cfw_patch_iomfb_swapend.py`
    /// names `_kern_SwapEnd`; `cfw_patch_iomfb_force_kern.py` does not name any,
    /// it discovers every `_IOMobileFramebufferSwap*` with a `_kern_` sibling,
    /// so the four pairs that discovery finds on this cache are listed here.
    private static let required: [(image: String, symbols: [String])] = [
        (neutrinoCore, [
            "+[_NUStyleTransferProcessor processWithInputs:arguments:output:error:]",
            "+[_NUStyleTransferThumbnailProcessor processWithInputs:arguments:output:error:]",
            "+[_NUStyleTransferApplyProcessor processWithInputs:arguments:output:error:]",
            "+[_NUStyleTransferLearnProcessor processWithInputs:arguments:output:error:]",
            "+[_NUStyleTransferInterpolateProcessor processWithInputs:arguments:output:error:]",
        ]),
        (avfCapture, [
            "+[AVCaptureDevice authorizationStatusForMediaType:]",
        ]),
        (ioMobileFramebuffer, [
            "_kern_SwapEnd",
            "_kern_SwapBegin",
            "_kern_SwapSetLayer",
            "_kern_SwapSetLayerEDRCompensation",
            "_IOMobileFramebufferSwapBegin",
            "_IOMobileFramebufferSwapEnd",
            "_IOMobileFramebufferSwapSetLayer",
            "_IOMobileFramebufferSwapSetLayerEDRCompensation",
        ]),
    ]

    /// `ipsw dyld symaddr <cache> --image <image>` for one image, parsed into
    /// name → address. The per-symbol form of that command is what times out on
    /// this cache; the whole-image dump answers in under a second.
    private func ipswSymbols(image: String, cache: URL) throws -> [String: UInt64] {
        guard let ipsw = DSCFixture.ipsw else { return [:] }
        let result = try Subprocess.run(
            executable: ipsw,
            arguments: [
                "dyld", "symaddr",
                cache.appendingPathComponent("dyld_shared_cache_arm64e").path,
                "--image", image,
            ],
        )
        guard result.status == 0 else { return [:] }

        var symbols: [String: UInt64] = [:]
        for rawLine in result.stdout.split(separator: "\n") {
            // Strip SGR colour codes, then split "0xADDR:\t(kind)\tname\timage".
            let line = rawLine.replacing(/\u{1B}\[[0-9;]*m/, with: "")
            guard let colon = line.firstIndex(of: ":") else { continue }
            let addressText = line[line.startIndex ..< colon].trimmingCharacters(in: .whitespaces)
            guard addressText.hasPrefix("0x"),
                  let address = UInt64(addressText.dropFirst(2), radix: 16)
            else { continue }
            var rest = line[line.index(after: colon)...]
                .trimmingCharacters(in: .whitespaces)
            guard rest.hasPrefix("("), let close = rest.firstIndex(of: ")") else { continue }
            rest = String(rest[rest.index(after: close)...]).trimmingCharacters(in: .whitespaces)
            // The name may be followed by a tab and the image name; ObjC method
            // names contain spaces, so split on tabs only.
            let name = rest.split(separator: "\t").first.map(String.init) ?? rest
            if symbols[name] == nil {
                symbols[name] = address
            }
        }
        return symbols
    }

    @Test
    func `Every symbol the three DSC patchers look up resolves, and agrees with ipsw`() throws {
        let pristine = try #require(DSCFixture.pristine, DSCFixture.missing)
        let resolver = try DSCSymbolResolver(
            mainCacheURL: pristine.appendingPathComponent("dyld_shared_cache_arm64e"),
        )
        #expect(resolver.hasLocalSymbols)

        var agreed = 0
        var unconfirmed: [String] = []
        for (image, wanted) in Self.required {
            let resolved = try resolver.addresses(of: wanted, inImage: image)
            #expect(resolved.count == wanted.count)

            let reference = try ipswSymbols(image: image, cache: pristine)
            for name in wanted {
                let mine = try #require(resolved[name])
                #expect(mine != 0)
                if let theirs = reference[name] {
                    #expect(
                        mine == theirs,
                        "\(name): swift 0x\(String(mine, radix: 16)) vs ipsw 0x\(String(theirs, radix: 16))",
                    )
                    agreed += 1
                    print("[symbol] \(name) = 0x\(String(mine, radix: 16)) (ipsw agrees)")
                } else {
                    unconfirmed.append(name)
                    print("[symbol] \(name) = 0x\(String(mine, radix: 16)) (ipsw did not report it)")
                }
            }
        }
        print("[symbols] \(agreed) confirmed against ipsw, \(unconfirmed.count) unconfirmed")
        #expect(agreed >= 13, "ipsw confirmed only \(agreed) symbols")
    }

    @Test
    func `The force-kern discovery shape is reproduced without ipsw`() throws {
        let pristine = try #require(DSCFixture.pristine, DSCFixture.missing)
        let resolver = try DSCSymbolResolver(
            mainCacheURL: pristine.appendingPathComponent("dyld_shared_cache_arm64e"),
        )
        try resolver.requireLocalSymbols()

        let publicPrefix = "_IOMobileFramebufferSwap"
        let all = try resolver.symbols(inImage: Self.ioMobileFramebuffer)
        let entryPoints = try resolver.symbols(
            inImage: Self.ioMobileFramebuffer,
            withPrefix: publicPrefix,
        )

        var pairs: [(String, UInt64, String, UInt64)] = []
        for (name, address) in entryPoints.sorted(by: { $0.key < $1.key }) {
            let sibling = "_kern_Swap" + name.dropFirst(publicPrefix.count)
            guard let kern = all[sibling] else { continue }
            pairs.append((name, address, sibling, kern.address))
        }

        // `cfw_patch_iomfb_force_kern.py` refuses to ship unless these three
        // are covered, so the resolver has to find all three without ipsw.
        for required in ["SwapBegin", "SwapEnd", "SwapSetLayer"] {
            #expect(
                pairs.contains { $0.0 == publicPrefix + required.dropFirst(4) },
                "missing entry point for \(required)",
            )
        }
        for pair in pairs {
            print("[force-kern] \(pair.0) 0x\(String(pair.1, radix: 16)) -> \(pair.2) 0x\(String(pair.3, radix: 16))")
        }
        #expect(pairs.count >= 3)
    }

    @Test
    func `A missing symbol and a missing image both fail loudly`() throws {
        let pristine = try #require(DSCFixture.pristine, DSCFixture.missing)
        let resolver = try DSCSymbolResolver(
            mainCacheURL: pristine.appendingPathComponent("dyld_shared_cache_arm64e"),
        )
        #expect(throws: DSCError.self) {
            _ = try resolver.address(
                of: "_this_symbol_does_not_exist",
                inImage: Self.ioMobileFramebuffer,
            )
        }
        #expect(throws: DSCError.self) {
            _ = try resolver.symbols(inImage: "/System/Library/Nope.framework/Nope")
        }
    }
}

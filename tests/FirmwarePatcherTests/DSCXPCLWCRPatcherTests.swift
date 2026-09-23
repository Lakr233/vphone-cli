// DSCXPCLWCRPatcherTests.swift — Parity for the libxpc LWCR patch.
//
// The only independent reference for this patch was
// `scripts/patchers/cfw_patch_xpc_lwcr.py`, driven through `cfw.py
// patch-xpc-lwcr`. That Python is gone, so what it produced on the real cache
// is frozen in `FrozenReference` below — the three sites, the six instruction
// words, and the SHA-256 of the one chunk it changed. `DSCXPCLWCRPatcher` runs
// on a clone and is graded against those. A port that writes the right
// instruction at the wrong address, or re-attests a different page, lands on a
// different digest.
//
// Fixture: `VPHONE_DSC_PRISTINE`, or `ipsws/ref_extract/dsc_pristine` by
// default. Without it these FAIL. A bare `guard let … else { return }` is
// reported by Swift Testing as a pass, so "all green" on a machine that never
// extracted the 6.7 GB cache would mean nothing. A machine that genuinely
// cannot carry the fixture sets `VPHONE_DSC_FIXTURE_OPTIONAL=1` and gets a
// visible *skip* instead.
//
// Nothing here writes to the pristine directory. Clones are made with
// `cp -c` — APFS `clonefile`, so instant and near-free — under the system
// temporary directory, or `VPHONE_DSC_SCRATCH` when it is set.

@testable import FirmwarePatcher
import Capstone
import CryptoKit
import Foundation
import Testing

// MARK: - The frozen reference

/// What the reference Python wrote on the real 24A435 arm64e shared cache.
///
/// Recorded from live runs at commit 78cbeea, each line below quoting the log
/// the run printed:
///
///     .venv/bin/python3 scripts/patchers/cfw.py \
///         patch-xpc-lwcr <clone of ipsws/ref_extract/dsc_pristine>
private enum FrozenReference {
    /// Python: `[.] __xpc_token_satisfies_lwcr @ 0x1805DD5BC`.
    static let functionVMA: UInt64 = 0x1_805D_D5BC

    /// Python: the three `[+] wrote …` lines, in the order it printed them —
    /// `cset w0, eq at 0x1805DD644`, `nop at 0x1805DD648`, `nop at 0x1805DD64C`.
    static let writtenVMAs: [UInt64] = [0x1_805D_D644, 0x1_805D_D648, 0x1_805D_D64C]

    /// Python: the left half of each `(… -> …)` on those same lines.
    static let originalWords: [Data] = [
        Data([0xE8, 0x07, 0x9F, 0x1A]),
        Data([0x08, 0x00, 0x08, 0x4A]),
        Data([0x88, 0x01, 0x00, 0x36]),
    ]

    /// Python: the right half — `cset w0, eq`, then two `nop`s.
    static let patchedWords: [Data] = [
        Data([0xE0, 0x17, 0x9F, 0x1A]),
        Data([0x1F, 0x20, 0x03, 0xD5]),
        Data([0x1F, 0x20, 0x03, 0xD5]),
    ]

    /// Python: the instruction text on the three `[.]` lines that precede the
    /// writes — `cset w8, ne`, `eor w8, w0, w8`, `tbz w8, #0, #0x1805dd67c`.
    static let idiomMnemonics = ["cset", "eor", "tbz"]

    /// `cmp -s` against the pristine tree after the run: exactly one chunk
    /// moved, to this digest, from `shasum -a 256 <output>/…arm64e.01`.
    ///
    /// The digest covers the re-attestation as well as the three words — the
    /// Python logged `re-attest: wrote slot 119 of dyld_shared_cache_arm64e.01`
    /// (`e19e728a.. -> 7a87ce53..`), `updated 1 slot hash(es) across 1
    /// chunk(s)`.
    ///
    /// Two further runs pinned the edges. Re-run over its own output: `already
    /// patched at 0x1805DD644 (cset w0,eq; nop; nop); nothing to
    /// patch/re-attest`, no `wrote` line, digest unchanged. `--dry-run` on a
    /// fresh clone: three `would write` lines at the same three addresses, and
    /// no chunk changed at all.
    static let changedChunks: [String: String] = [
        "dyld_shared_cache_arm64e.01":
            "94ab6599c12bb8f12ef7f19dc8fde081b55a91cf40992a23444741b3e9d43309",
    ]
}

// MARK: - Fixture

private enum LWCRFixture {
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

    /// Opt-out for a machine that cannot carry the fixture.
    static var isOptional: Bool {
        ProcessInfo.processInfo.environment["VPHONE_DSC_FIXTURE_OPTIONAL"] == "1"
    }

    /// The suites run unless the cache is absent *and* the caller opted out.
    static var runs: Bool { pristine != nil || !isOptional }

    static let missing: Comment = """
    the real 24A435 arm64e shared cache is required — put it at \
    ipsws/ref_extract/dsc_pristine, point VPHONE_DSC_PRISTINE at it, or set \
    VPHONE_DSC_FIXTURE_OPTIONAL=1 to skip these tests instead of failing
    """

    static let skipReason: Comment =
        "VPHONE_DSC_FIXTURE_OPTIONAL=1 and no dyld_shared_cache_arm64e fixture present"

    /// Where clones go. Must be on the same APFS volume as the pristine copy
    /// or `cp -c` degrades from a clone into 6.7 GB of reads; the system
    /// temporary directory is, and `VPHONE_DSC_SCRATCH` is there for a layout
    /// where it is not.
    static var scratchRoot: URL {
        // The override names a *base*, not this suite's directory. Six DSC
        // suites honour the same variable and they all clone under the same
        // handful of names ("swift", "dryrun", "idempotent"); only ordering
        // *within* a suite is serialized, so sharing one directory lets one
        // suite's `discard` delete a clone another is still creating. The leaf
        // therefore has to be per-suite on both branches, not just the default.
        let base = ProcessInfo.processInfo.environment["VPHONE_DSC_SCRATCH"]
            .map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("vphone_dsc_xpclwcr")
    }

    /// Clone the pristine cache into a fresh directory the caller may write to.
    static func cloneCache(named name: String) throws -> URL {
        guard let pristine else { throw CocoaError(.fileNoSuchFile) }
        let destination = scratchRoot.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.createDirectory(
            at: destination,
            withIntermediateDirectories: true
        )
        let entries = try FileManager.default.contentsOfDirectory(atPath: pristine.path).sorted()
        let result = try Shell.run(
            executable: URL(fileURLWithPath: "/bin/cp"),
            arguments: ["-c", "-R"]
                + entries.map { pristine.appendingPathComponent($0).path }
                + [destination.path]
        )
        guard result.status == 0 else {
            Issue.record("cp -c failed: \(result.stderr)")
            throw CocoaError(.fileWriteUnknown)
        }
        return destination
    }

    /// Discard clones, and the scratch root with them once the last one is
    /// gone, so the run leaves the filesystem as it found it.
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

    /// Byte-compare two cache directories, file by file.
    ///
    /// Returns the names of files that differ, plus the names present in one
    /// directory and not the other. Empty means the two trees are identical.
    static func differences(between left: URL, and right: URL) throws -> [String] {
        let leftNames = Set(try FileManager.default.contentsOfDirectory(atPath: left.path))
        let rightNames = Set(try FileManager.default.contentsOfDirectory(atPath: right.path))
        var differing = Array(leftNames.symmetricDifference(rightNames))

        for name in leftNames.intersection(rightNames).sorted() {
            let a = left.appendingPathComponent(name)
            let b = right.appendingPathComponent(name)
            // `cmp -s` streams both files; loading two 5 GB chunks into Data
            // to compare them is not a thing this test can afford.
            let result = try Shell.run(
                executable: URL(fileURLWithPath: "/usr/bin/cmp"),
                arguments: ["-s", a.path, b.path]
            )
            if result.status != 0 { differing.append(name) }
        }
        return differing.sorted()
    }

    /// Which chunk files a run moved away from the pristine tree.
    static func changedFiles(in directory: URL) throws -> [String] {
        let pristine = try #require(self.pristine, missing)
        return try differences(between: pristine, and: directory)
    }
}

// MARK: - Digests

/// SHA-256 of a cache chunk, streamed so a 131 MB file never lands in memory
/// whole. The hex spelling matches `shasum -a 256`, which produced the frozen
/// digests.
private enum Digest {
    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let block = try handle.read(upToCount: 4 << 20), !block.isEmpty {
            hasher.update(data: block)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Assert that `directory` holds exactly the chunks the reference changed,
    /// with exactly the reference's bytes.
    static func expectMatchesReference(_ directory: URL) throws {
        let changed = try LWCRFixture.changedFiles(in: directory)
        #expect(changed == FrozenReference.changedChunks.keys.sorted())
        for name in changed {
            let digest = try sha256(of: directory.appendingPathComponent(name))
            let frozen = FrozenReference.changedChunks[name] ?? "(not a chunk the Python moved)"
            #expect(digest == frozen, "\(name): Swift \(digest), reference \(frozen)")
        }
    }
}

// MARK: - Subprocess helper

private enum Shell {
    struct Result {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    @discardableResult
    static func run(executable: URL, arguments: [String]) throws -> Result {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        // Drain before waiting: a full pipe buffer would deadlock the run.
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Result(
            status: process.terminationStatus,
            stdout: String(decoding: outData, as: UTF8.self),
            stderr: String(decoding: errData, as: UTF8.self)
        )
    }
}

// MARK: - Parity against the frozen reference, on the real cache

@Suite(.serialized, .enabled(if: LWCRFixture.runs, LWCRFixture.skipReason))
struct DSCXPCLWCRParityTests {
    @Test("Swift patches the reference's three sites, to the reference's bytes")
    func patchedCloneMatchesTheReference() throws {
        _ = try #require(LWCRFixture.pristine, LWCRFixture.missing)

        let swiftClone = try LWCRFixture.cloneCache(named: "swift")
        defer { LWCRFixture.discard(swiftClone) }

        let outcome = try DSCXPCLWCRPatcher.apply(directory: swiftClone, log: nil)
        #expect(outcome.status == .patched)
        #expect(outcome.siteCount == 3, "swift wrote \(outcome.siteCount) sites")
        #expect(outcome.records.compactMap(\.virtualAddress) == FrozenReference.writtenVMAs)
        #expect(outcome.records.map(\.originalBytes) == FrozenReference.originalWords)
        #expect(outcome.records.map(\.patchedBytes) == FrozenReference.patchedWords)

        try Digest.expectMatchesReference(swiftClone)
    }

    @Test("The replacement words are exactly cset w0,eq / nop / nop")
    func replacementWordsComeFromTheEncoders() throws {
        _ = try #require(LWCRFixture.pristine, LWCRFixture.missing)
        let clone = try LWCRFixture.cloneCache(named: "words")
        defer { LWCRFixture.discard(clone) }

        let outcome = try DSCXPCLWCRPatcher.apply(directory: clone, log: nil)
        #expect(outcome.siteCount == 3)

        let expectedCset = try #require(ARM64Encoder.encodeCsetW(rd: 0, condition: .eq))
        #expect(outcome.records[0].patchedBytes == expectedCset)
        #expect(outcome.records[1].patchedBytes == ARM64.nop)
        #expect(outcome.records[2].patchedBytes == ARM64.nop)

        // …and the encoders agree with the words the reference actually wrote.
        #expect(expectedCset == FrozenReference.patchedWords[0])
        #expect(ARM64.nop == FrozenReference.patchedWords[1])

        // The three sites are consecutive words of one function.
        let addresses = outcome.records.compactMap(\.virtualAddress)
        #expect(addresses.count == 3)
        #expect(addresses[1] == addresses[0] + 4)
        #expect(addresses[2] == addresses[1] + 4)
    }

    @Test("A dry run reports the same three sites and writes nothing")
    func dryRunWritesNothing() throws {
        _ = try #require(LWCRFixture.pristine, LWCRFixture.missing)

        let clone = try LWCRFixture.cloneCache(named: "dry")
        defer { LWCRFixture.discard(clone) }

        let outcome = try DSCXPCLWCRPatcher.apply(directory: clone, dryRun: true, log: nil)
        #expect(outcome.status == .patched)
        #expect(outcome.siteCount == 3)
        // The reference's own dry run named these three and changed no chunk.
        #expect(outcome.records.compactMap(\.virtualAddress) == FrozenReference.writtenVMAs)

        let changed = try LWCRFixture.changedFiles(in: clone)
        #expect(changed.isEmpty, "a dry run modified \(changed)")
    }

    @Test("Re-running over a patched cache is a no-op")
    func secondRunIsANoOp() throws {
        _ = try #require(LWCRFixture.pristine, LWCRFixture.missing)

        let swiftClone = try LWCRFixture.cloneCache(named: "swift_twice")
        defer { LWCRFixture.discard(swiftClone) }

        _ = try DSCXPCLWCRPatcher.apply(directory: swiftClone, log: nil)

        // Second pass. It may not raise, and it may not write — the reference
        // printed `already patched … nothing to patch/re-attest` here and left
        // its own digest standing, so the bytes must still be the frozen ones.
        let outcome = try DSCXPCLWCRPatcher.apply(directory: swiftClone, log: nil)
        #expect(outcome.status == .alreadyPatched)
        #expect(outcome.siteCount == 0)

        try Digest.expectMatchesReference(swiftClone)
    }

    @Test("Every page the writes dirtied is re-attested")
    func patchedPagesAreAttested() throws {
        _ = try #require(LWCRFixture.pristine, LWCRFixture.missing)
        let clone = try LWCRFixture.cloneCache(named: "attest")
        defer { LWCRFixture.discard(clone) }

        let chunks = try DSCChunkSet(directory: clone)
        let outcome = try DSCXPCLWCRPatcher.apply(chunks: chunks, log: nil)
        #expect(outcome.siteCount == 3)

        // Re-attesting again must find every touched page already correct —
        // which is only true if the patcher's own call covered all of them.
        let again = try DSCCodeSignature.reattestRecordedWrites(in: chunks, log: nil)
        #expect(again.updated.isEmpty, "a page was left stale: \(again.updated.count) slots")
        #expect(!again.alreadyAttested.isEmpty)
        #expect(again.skipped.isEmpty)
    }

    @Test("A missing local symbol table is not the same answer as a missing symbol")
    func missingSymbolTableThrows() throws {
        _ = try #require(LWCRFixture.pristine, LWCRFixture.missing)
        let clone = try LWCRFixture.cloneCache(named: "nosymbols")
        defer { LWCRFixture.discard(clone) }

        try FileManager.default.removeItem(
            at: clone.appendingPathComponent("dyld_shared_cache_arm64e.symbols")
        )
        #expect(throws: DSCError.self) {
            try DSCXPCLWCRPatcher.apply(directory: clone, dryRun: true, log: nil)
        }
    }
}

// MARK: - The two shape detectors, on real instruction streams

@Suite(.serialized, .enabled(if: LWCRFixture.runs, LWCRFixture.skipReason))
struct DSCXPCLWCRShapeTests {
    /// `_xpc_token_satisfies_lwcr` as it is disassembled out of a cache.
    private func functionStream(in directory: URL) throws -> [Instruction] {
        let chunks = try DSCChunkSet(directory: directory)
        var address: UInt64?
        for candidate in DSCXPCLWCRPatcher.symbolCandidates {
            if let found = try chunks.resolveLocalSymbol(candidate) {
                address = found
                break
            }
        }
        let vma = try #require(address, "\(DSCXPCLWCRPatcher.symbol) is not in this cache")
        return try DSCXPCLWCRPatcher.disassembleFunction(
            in: chunks,
            at: vma,
            disassembler: ARM64Disassembler()
        )
    }

    @Test("The symbol resolves under its mangled spelling, at a function prologue")
    func symbolResolvesToAFunctionStart() throws {
        let pristine = try #require(LWCRFixture.pristine, LWCRFixture.missing)
        let chunks = try DSCChunkSet(directory: pristine)

        let mangledAddress = try chunks.resolveLocalSymbol("__xpc_token_satisfies_lwcr")
        let mangled = try #require(
            mangledAddress,
            "the double-underscore spelling is the one Mach-O stores"
        )
        // The reference resolved the same symbol to the same address.
        #expect(mangled == FrozenReference.functionVMA)
        // The single-underscore source spelling is a miss, which is why the
        // patcher tries both rather than only the obvious one.
        let sourceSpelling = try chunks.resolveLocalSymbol(DSCXPCLWCRPatcher.symbol)
        #expect(sourceSpelling == nil)

        let stream = try DSCXPCLWCRPatcher.disassembleFunction(
            in: chunks,
            at: mangled,
            disassembler: ARM64Disassembler()
        )
        #expect(stream.first?.mnemonic == "pacibsp")
        #expect(stream.last?.mnemonic == "retab")
        #expect(stream.count < DSCXPCLWCRPatcher.maxInstructions)
    }

    @Test("On a pristine stream the idiom matches and the patched shape does not")
    func pristineStreamMatchesTheIdiomOnly() throws {
        let pristine = try #require(LWCRFixture.pristine, LWCRFixture.missing)
        let disassembler = ARM64Disassembler()
        let stream = try functionStream(in: pristine)

        let site = try #require(
            DSCXPCLWCRPatcher.findConsistencyCheck(in: stream, disassembler: disassembler)
        )
        #expect(site.cset.mnemonic == "cset")
        #expect(site.cset.aarch64?.conditionCode == AArch64CC_NE)
        #expect(site.eor.mnemonic == "eor")
        #expect(site.tbz.mnemonic == "tbz")
        #expect(site.eor.address == site.cset.address + 4)
        #expect(site.tbz.address == site.eor.address + 4)
        // The same three instructions, at the same three addresses, the
        // reference printed before it wrote.
        #expect([site.cset.mnemonic, site.eor.mnemonic, site.tbz.mnemonic]
            == FrozenReference.idiomMnemonics)
        #expect([site.cset.address, site.eor.address, site.tbz.address]
            == FrozenReference.writtenVMAs)
        // The xor's left operand is the matcher's return register, and its
        // right operand is what the cset wrote — the dataflow that makes the
        // match unambiguous.
        #expect(DSCXPCLWCRPatcher.register(site.eor, 1, disassembler) == "w0")
        #expect(
            DSCXPCLWCRPatcher.register(site.eor, 2, disassembler)
                == DSCXPCLWCRPatcher.register(site.cset, 0, disassembler)
        )

        #expect(DSCXPCLWCRPatcher.findPatchedShape(in: stream, disassembler: disassembler) == nil)
    }

    @Test("On a patched stream the patched shape matches and the idiom does not")
    func patchedStreamMatchesThePatchedShapeOnly() throws {
        _ = try #require(LWCRFixture.pristine, LWCRFixture.missing)
        let clone = try LWCRFixture.cloneCache(named: "shape")
        defer { LWCRFixture.discard(clone) }

        let disassembler = ARM64Disassembler()
        let outcome = try DSCXPCLWCRPatcher.apply(directory: clone, log: nil)
        #expect(outcome.siteCount == 3)

        let stream = try functionStream(in: clone)
        #expect(DSCXPCLWCRPatcher.findConsistencyCheck(in: stream, disassembler: disassembler) == nil)

        let already = try #require(
            DSCXPCLWCRPatcher.findPatchedShape(in: stream, disassembler: disassembler)
        )
        #expect(already.mnemonic == "cset")
        #expect(already.aarch64?.conditionCode == AArch64CC_EQ)
        #expect(already.address == outcome.records[0].virtualAddress)
    }

    @Test("Neither detector matches a stream that stops before the check")
    func aTruncatedStreamMatchesNothing() throws {
        let pristine = try #require(LWCRFixture.pristine, LWCRFixture.missing)
        let disassembler = ARM64Disassembler()
        let stream = try functionStream(in: pristine)
        let site = try #require(
            DSCXPCLWCRPatcher.findConsistencyCheck(in: stream, disassembler: disassembler)
        )
        let csetIndex = try #require(stream.firstIndex { $0.address == site.cset.address })

        // Everything before the `cset` — the prologue and the matcher call.
        let truncated = Array(stream[..<csetIndex])
        #expect(DSCXPCLWCRPatcher.findConsistencyCheck(in: truncated, disassembler: disassembler) == nil)
        #expect(DSCXPCLWCRPatcher.findPatchedShape(in: truncated, disassembler: disassembler) == nil)

        // And an empty stream, which is what a symbol pointing into data looks
        // like. Both detectors index backwards, so this is the bounds check.
        #expect(DSCXPCLWCRPatcher.findConsistencyCheck(in: [], disassembler: disassembler) == nil)
        #expect(DSCXPCLWCRPatcher.findPatchedShape(in: [], disassembler: disassembler) == nil)
    }

    @Test("The idiom needs the cset that feeds the xor, not just any cset")
    func aStrandedXorDoesNotMatch() throws {
        let pristine = try #require(LWCRFixture.pristine, LWCRFixture.missing)
        let disassembler = ARM64Disassembler()
        let stream = try functionStream(in: pristine)
        let site = try #require(
            DSCXPCLWCRPatcher.findConsistencyCheck(in: stream, disassembler: disassembler)
        )
        let csetIndex = try #require(stream.firstIndex { $0.address == site.cset.address })

        // Drop the `cset` and keep the `eor`/`tbz`: without the instruction
        // that defines the xor's right operand there is no verdict to rewrite,
        // and matching anyway would patch a function this does not understand.
        var withoutCset = stream
        withoutCset.remove(at: csetIndex)
        #expect(
            DSCXPCLWCRPatcher.findConsistencyCheck(in: withoutCset, disassembler: disassembler) == nil
        )
    }
}

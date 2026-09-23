// DSCMaxSlidePatcherTests.swift — Parity cross-checks for `DSCMaxSlidePatcher`.
//
// There is no `codesign -v` for a dyld shared cache chunk and no second
// implementation of this patch anywhere. The only independent reference was
// `scripts/patchers/cfw_patch_dsc_maxslide.py`, driven through the CLI the
// install scripts use: `cfw.py patch-dsc-maxslide <dir> [--dry-run] [--force]`.
// That Python has been removed, so what it produced is frozen in
// `FrozenReference` below — for the real cache, and for each of the five
// synthetic gate cases, the digest of the input it saw and the digest of the
// file it left behind. Every claim here is "the Swift, given the bytes the
// reference was given, produces the bytes the reference produced".
//
// The tests need the real cache. Point `VPHONE_DSC_PRISTINE` at a directory of
// `dyld_shared_cache_arm64e*` chunks, or leave the default
// `ipsws/ref_extract/dsc_pristine` in place.
//
// Without it they FAIL, following `DSCFoundationTests`: a `guard … else
// { return }` is reported by Swift Testing as a pass, so a green run on a
// machine with no fixture would be indistinguishable from a green run that
// proved something. A machine that genuinely cannot carry the 5.3 GB cache sets
// `VPHONE_DSC_FIXTURE_OPTIONAL=1`, which turns the failure into a visible skip.
//
// Nothing here writes to the pristine directory, and nothing here writes
// anywhere under `ipsws/ref_extract/` at all: clones land in
// `ipsws/scratch_dscmaxslide/`, on the same filesystem, so `cp -c` is a
// `clonefile` rather than 10 GB of copying.

@testable import FirmwarePatcher
import CryptoKit
import Foundation
import Testing

// MARK: - The frozen reference

/// What the reference Python produced, recorded from live runs at commit
/// 78cbeea:
///
///     .venv/bin/python3 scripts/patchers/cfw.py \
///         patch-dsc-maxslide <input> [--dry-run] [--force]
///
/// The real-cache input was a clone of `ipsws/ref_extract/dsc_pristine`. The
/// synthetic inputs were rebuilt byte for byte from
/// `DSCMaxSlideGateTests.writeCache`, which is why each case carries the digest
/// of its input as well as of its output: a test that fed the Swift something
/// else would fail on the input digest rather than quietly compare nothing.
private enum FrozenReference {
    // MARK: The real 24A435 arm64e cache

    /// Python: `dyld_shared_cache_arm64e: start=0x180000000 size=0x17D504000
    /// maxSlide=0x20000000`.
    static let realStart: UInt64 = 0x1_8000_0000
    static let realSize: UInt64 = 0x1_7D50_4000
    static let realMaxSlide: UInt64 = 0x2000_0000

    /// Python: `overflow: span+maxSlide 0x19D504000 > region 0x180000000; set
    /// maxSlide 0x20000000 -> 0x0`, then `DSC maxSlide patch complete`.
    ///
    /// `cmp -s` against the pristine tree afterwards: exactly one file moved,
    /// the main chunk, to this digest (`shasum -a 256 <output>/…arm64e`). The
    /// other 79 files were untouched — this patch deliberately does not
    /// re-attest, so no code-directory slot moves.
    static let realChangedChunks: [String: String] = [
        "dyld_shared_cache_arm64e":
            "3d7197cc0714e95c0e49434ab8bbb6311952a96d5b0425b10f87d2cc060c0110",
    ]

    /// Re-running the Python over its own output printed `fits: span+maxSlide
    /// 0x17D504000 <= region 0x180000000; no change` — the *fits* gate, not the
    /// already-zero one — and left the digest above standing. A third run with
    /// `--force` skipped that gate and printed `maxSlide already 0; no change`,
    /// also writing nothing. A `--dry-run` on a fresh clone printed `would set
    /// maxSlide 0x20000000 -> 0x0` and changed no byte.

    // MARK: The synthetic gate cases

    /// One synthetic case: the digest of the cache handed to the patcher, and
    /// the digest of what it held afterwards.
    struct GateCase {
        let inputSHA256: String
        let outputSHA256: String
        /// The branch word the Python printed: `overflow`, `fits`, `forced` or
        /// `maxSlide already 0`.
        let branch: String
    }

    /// `writeCache(regionSize: 0x17C830000, maxSlide: 0x20000000)`, no flags.
    /// Python: `overflow: span+maxSlide 0x19C830000 > region 0x180000000; set
    /// maxSlide 0x20000000 -> 0x0`.
    static let overflow = GateCase(
        inputSHA256: "0eeb86dc953aa43a29df533a0c151cb1d8ce7f322f8fa77232d5c97733984ab3",
        outputSHA256: "93e9ee632ab259a245f37e224e52e7f5671c8b323d04ba541483335c0d94bc6c",
        branch: "overflow"
    )

    /// `writeCache(regionSize: 0x140904000, maxSlide: 0x20000000)`, no flags.
    /// Python: `fits: span+maxSlide 0x160904000 <= region 0x180000000; no
    /// change` — input and output digests are the same file.
    static let fits = GateCase(
        inputSHA256: "88c50a6f8304c87bca21e6c01da193d8022673c12d03d4d0dfd52340b3fca718",
        outputSHA256: "88c50a6f8304c87bca21e6c01da193d8022673c12d03d4d0dfd52340b3fca718",
        branch: "fits"
    )

    /// The same input as `fits`, with `--force`. Python: `forced: span+maxSlide
    /// 0x160904000 fits region 0x180000000 but --force set; set maxSlide
    /// 0x20000000 -> 0x0`.
    static let forced = GateCase(
        inputSHA256: "88c50a6f8304c87bca21e6c01da193d8022673c12d03d4d0dfd52340b3fca718",
        outputSHA256: "73e12cacf1350c07ad38991f4e845e51f64199815061e0ea1889d19f53f4beda",
        branch: "forced"
    )

    /// `writeCache(regionSize: 0x140904000, maxSlide: 0)` with `--force`.
    /// Python: `maxSlide already 0; no change`.
    static let forcedZero = GateCase(
        inputSHA256: "73e12cacf1350c07ad38991f4e845e51f64199815061e0ea1889d19f53f4beda",
        outputSHA256: "73e12cacf1350c07ad38991f4e845e51f64199815061e0ea1889d19f53f4beda",
        branch: "maxSlide already 0"
    )

    /// `writeCache(regionSize: 0x190000000, maxSlide: 0)`, no flags — a span
    /// that overruns the region with no slide left to give back. Python:
    /// `maxSlide already 0; no change`.
    static let overflowWithZeroSlide = GateCase(
        inputSHA256: "f2543eb53f0f69a25c72045311292c9c428798a53683aeebd5b051509126d4b9",
        outputSHA256: "f2543eb53f0f69a25c72045311292c9c428798a53683aeebd5b051509126d4b9",
        branch: "maxSlide already 0"
    )

    /// The Python's own self-test fixture — a bare 0x100-byte header with no
    /// mapping table — is the one input where the two implementations
    /// deliberately disagree, so it has no `GateCase` above. The reference
    /// patched it (`overflow: … set maxSlide 0x20000000 -> 0x0`, the field
    /// reading back as 0 afterwards); the Swift refuses it, because every write
    /// here goes through `DSCChunkSet`, which has nothing to address such a
    /// file with. See `noMappingTableIsRefused`.
}

// MARK: - Fixture discovery

private enum MaxSlideFixture {
    static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    static let mainChunkName = "dyld_shared_cache_arm64e"

    /// The read-only reference cache.
    static var pristine: URL? {
        let url = ProcessInfo.processInfo.environment["VPHONE_DSC_PRISTINE"]
            .map { URL(fileURLWithPath: $0) }
            ?? repoRoot.appendingPathComponent("ipsws/ref_extract/dsc_pristine")
        let main = url.appendingPathComponent(mainChunkName)
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

    /// Where clones are made. Same filesystem as the repo, and deliberately
    /// *not* under `ipsws/ref_extract/`, which is the pristine reference the
    /// whole suite compares against.
    static var scratchRoot: URL {
        repoRoot.appendingPathComponent("ipsws/scratch_dscmaxslide")
    }

    /// Clone the whole pristine cache into a fresh directory the caller may
    /// write to. `cp -c` is `clonefile(2)`: instant, and near-zero disk until
    /// something is written.
    static func cloneCache(named name: String) throws -> URL {
        guard let pristine else { throw CocoaError(.fileNoSuchFile) }
        let destination = scratchRoot.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.createDirectory(
            at: destination,
            withIntermediateDirectories: true
        )
        let sources = try FileManager.default
            .contentsOfDirectory(atPath: pristine.path)
            .sorted()
            .map { pristine.appendingPathComponent($0).path }

        var result = try Subprocess.run(
            executable: URL(fileURLWithPath: "/bin/cp"),
            arguments: ["-c", "-R"] + sources + [destination.path]
        )
        if result.status != 0 {
            // A fixture pointed at another volume cannot be cloned. Copying is
            // slow but correct, and a refusal here would look like a patch bug.
            result = try Subprocess.run(
                executable: URL(fileURLWithPath: "/bin/cp"),
                arguments: ["-R"] + sources + [destination.path]
            )
        }
        guard result.status == 0 else { throw CocoaError(.fileWriteUnknown) }
        return destination
    }

    /// Clone only the chunk this patcher touches — enough for a
    /// `DSCChunkSet`, and cheap enough for the gate-logic tests to make many.
    static func cloneMainChunk(named name: String) throws -> URL {
        guard let pristine else { throw CocoaError(.fileNoSuchFile) }
        let destination = scratchRoot.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.createDirectory(
            at: destination,
            withIntermediateDirectories: true
        )
        try FileManager.default.copyItem(
            at: pristine.appendingPathComponent(mainChunkName),
            to: destination.appendingPathComponent(mainChunkName)
        )
        return destination
    }

    /// Discard clones, and the scratch root with them once the last one is
    /// gone, so a test run leaves the working tree as it found it.
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
    static func run(executable: URL, arguments: [String]) throws -> Result {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        // Drain before waiting, or a full pipe buffer deadlocks the child.
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

// MARK: - Digests

/// SHA-256 of a file, streamed so a 131 MB chunk never lands in memory whole.
/// The hex spelling matches `shasum -a 256`, which produced the frozen digests.
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
}

// MARK: - Byte comparison

private enum Bytes {
    /// `cmp -s`, which is a C memcmp over two files and does not need either of
    /// them in this process's memory. Returns true when the two are identical.
    static func identical(_ lhs: URL, _ rhs: URL) throws -> Bool {
        try Subprocess.run(
            executable: URL(fileURLWithPath: "/usr/bin/cmp"),
            arguments: ["-s", lhs.path, rhs.path]
        ).status == 0
    }

    /// Every file in `lhs` compared with its namesake in `rhs`.
    ///
    /// - Returns: how many files matched, and the names that did not.
    static func compareTrees(_ lhs: URL, _ rhs: URL) throws -> (matched: Int, differing: [String]) {
        let leftNames = try FileManager.default.contentsOfDirectory(atPath: lhs.path).sorted()
        let rightNames = try FileManager.default.contentsOfDirectory(atPath: rhs.path).sorted()
        #expect(leftNames == rightNames, "the two clones do not even hold the same files")

        var matched = 0
        var differing: [String] = []
        for name in leftNames {
            if try identical(
                lhs.appendingPathComponent(name),
                rhs.appendingPathComponent(name)
            ) {
                matched += 1
            } else {
                differing.append(name)
            }
        }
        return (matched, differing)
    }

    static func read(_ url: URL, offset: UInt64, length: Int) throws -> Data {
        try DSCChunkSet.read(url: url, offset: offset, length: length)
    }

    /// The `maxSlide` field of a chunk on disk.
    static func maxSlide(of chunk: URL) throws -> UInt64 {
        try read(chunk, offset: UInt64(DSCMaxSlidePatcher.HeaderField.maxSlide), length: 8)
            .loadLE(UInt64.self, at: 0)
    }
}

// MARK: - The real cache

@Suite(.serialized, .enabled(if: MaxSlideFixture.runs, MaxSlideFixture.skipReason))
struct DSCMaxSlideRealCacheTests {
    /// The gate this cache trips, stated once: 24A435's arm64e cache records a
    /// 0x17D504000 span and a 0x20000000 slide, which together overrun the
    /// kernel's 0x180000000 region by 0x1D504000.
    @Test("The pristine cache is one that overflows the kernel's shared region")
    func pristineCacheOverflowsTheRegion() throws {
        let pristine = try #require(MaxSlideFixture.pristine, MaxSlideFixture.missing)

        let chunks = try DSCChunkSet(directory: pristine)
        let headerVMA = try DSCMaxSlidePatcher.headerVMA(of: chunks)
        let header = try DSCMaxSlidePatcher.readHeader(
            from: chunks,
            at: headerVMA,
            chunkName: MaxSlideFixture.mainChunkName
        )

        #expect(header.sharedRegionStart == chunks.addressRange.lowerBound)
        #expect(header.maxSlide != 0, "the fixture is already patched; re-extract it")
        #expect(
            header.sharedRegionSize + header.maxSlide > DSCMaxSlidePatcher.kernelSharedRegionSize,
            "this fixture does not exercise the patch: it fits the region as it stands"
        )
        // The three numbers the reference read out of this same header.
        #expect(header.sharedRegionStart == FrozenReference.realStart)
        #expect(header.sharedRegionSize == FrozenReference.realSize)
        #expect(header.maxSlide == FrozenReference.realMaxSlide)
        print(
            "[pristine] start=0x\(String(header.sharedRegionStart, radix: 16, uppercase: true)) "
                + "size=0x\(String(header.sharedRegionSize, radix: 16, uppercase: true)) "
                + "maxSlide=0x\(String(header.maxSlide, radix: 16, uppercase: true))"
        )
    }

    /// The gate from the task: run the patcher on a clone of the real cache and
    /// require the result to be the bytes the reference left behind, over every
    /// one of the 79 chunks and the symbol side file — not just over the eight
    /// bytes the patch is about.
    @Test("Swift patches the real cache into the reference's bytes")
    func realCacheMatchesTheReference() throws {
        let pristine = try #require(MaxSlideFixture.pristine, MaxSlideFixture.missing)

        let swiftSide = try MaxSlideFixture.cloneCache(named: "parity_swift")
        defer { MaxSlideFixture.discard(swiftSide) }

        let mine = try DSCMaxSlidePatcher.patch(chunksDirectory: swiftSide)
        #expect(mine.siteCount == 1, "the Swift did not patch the real cache")
        #expect(mine.didWrite)
        #expect(mine.outcome == .overflow(
            combined: mine.sharedRegionSize + mine.maxSlide,
            region: DSCMaxSlidePatcher.kernelSharedRegionSize
        ))
        #expect(mine.writtenSpan?.length == 8, "one site, one u64")

        // Exactly the file the reference moved, with exactly its bytes.
        let (unchanged, changed) = try Bytes.compareTrees(pristine, swiftSide)
        #expect(changed == FrozenReference.realChangedChunks.keys.sorted())
        #expect(unchanged >= 79, "only \(unchanged) files were left alone")
        for name in changed {
            let digest = try Digest.sha256(of: swiftSide.appendingPathComponent(name))
            let frozen = FrozenReference.realChangedChunks[name] ?? "(not a file the Python moved)"
            #expect(digest == frozen, "\(name): Swift \(digest), reference \(frozen)")
        }

        // …and the change is the eight bytes of the field and nothing else.
        let pristineMain = pristine.appendingPathComponent(MaxSlideFixture.mainChunkName)
        let head = DSCMaxSlidePatcher.HeaderField.maxSlide
        let tailOffset = UInt64(head + 8)
        let tailLength = 0x100 - head - 8
        let main = swiftSide.appendingPathComponent(MaxSlideFixture.mainChunkName)
        #expect(try Bytes.maxSlide(of: main) == 0)
        #expect(try Bytes.read(main, offset: 0, length: head)
            == Bytes.read(pristineMain, offset: 0, length: head))
        #expect(try Bytes.read(main, offset: tailOffset, length: tailLength)
            == Bytes.read(pristineMain, offset: tailOffset, length: tailLength))
    }

    /// The deliberate divergence from every other DSC patcher, pinned so nobody
    /// "fixes" it: the header page's code slot is left stale on purpose, because
    /// `maxSlide` is kernel-read cache metadata rather than a `cs_validate`'d
    /// code page. The code directory must come out of the patch untouched.
    @Test("The patch leaves the code directory alone and the header page unattested")
    func headerPageIsDeliberatelyNotReattested() throws {
        let pristine = try #require(MaxSlideFixture.pristine, MaxSlideFixture.missing)

        let clone = try MaxSlideFixture.cloneMainChunk(named: "noreattest")
        defer { MaxSlideFixture.discard(clone) }
        let main = clone.appendingPathComponent(MaxSlideFixture.mainChunkName)
        let pristineMain = pristine.appendingPathComponent(MaxSlideFixture.mainChunkName)

        let directory = try #require(
            try DSCCodeSignature.readCodeDirectory(ofChunk: main),
            "the main chunk should carry a code directory"
        )
        let before = try DSCCodeSignature.pageHashes(
            chunkURL: main,
            pageIndex: 0,
            directory: directory
        )
        #expect(before.computed == before.stored, "page 0 was not attested before the patch")

        let result = try DSCMaxSlidePatcher.patch(chunksDirectory: clone)
        #expect(result.siteCount == 1)

        // The blob itself: byte-identical to pristine, so no slot moved.
        let mineBlob = try Bytes.read(
            main,
            offset: UInt64(directory.blobOffset),
            length: directory.blobLength
        )
        let pristineBlob = try Bytes.read(
            pristineMain,
            offset: UInt64(directory.blobOffset),
            length: directory.blobLength
        )
        #expect(mineBlob == pristineBlob, "the patch rewrote a code slot it must not rewrite")

        let after = try DSCCodeSignature.pageHashes(
            chunkURL: main,
            pageIndex: 0,
            directory: directory
        )
        #expect(after.stored == before.stored)
        #expect(
            after.computed != after.stored,
            "page 0's slot still matches, so something re-attested it"
        )
        print("[no re-attest] page 0 stored \(after.stored.hex.prefix(16))… "
            + "computed \(after.computed.hex.prefix(16))… — stale on purpose")
    }

    /// The reference's `--dry-run` printed `would set maxSlide 0x20000000 ->
    /// 0x0` — one site reported, no byte written. So must this one.
    @Test("A dry run reports the reference's site, and writes nothing")
    func dryRunReportsTheSiteAndWritesNothing() throws {
        let pristine = try #require(MaxSlideFixture.pristine, MaxSlideFixture.missing)

        let swiftSide = try MaxSlideFixture.cloneMainChunk(named: "dryrun_swift")
        defer { MaxSlideFixture.discard(swiftSide) }

        let mine = try DSCMaxSlidePatcher.patch(chunksDirectory: swiftSide, dryRun: true)
        #expect(mine.siteCount == 1, "a dry run still reports the site, as the reference did")
        #expect(!mine.didWrite)
        #expect(mine.record?.patchID == DSCMaxSlidePatcher.patchID)
        #expect(mine.record?.patchedBytes == Data(count: 8))
        #expect(mine.record?.originalBytes.loadLE(UInt64.self, at: 0) == mine.maxSlide)
        #expect(mine.maxSlide == FrozenReference.realMaxSlide)

        let untouched = try Bytes.identical(
            swiftSide.appendingPathComponent(MaxSlideFixture.mainChunkName),
            pristine.appendingPathComponent(MaxSlideFixture.mainChunkName)
        )
        #expect(untouched, "a dry run wrote to the chunk")
    }

    /// `8eb6c8b`'s lesson again: a patcher has to recognise its own output. A
    /// second pass over a clamped cache is a no-op, not an error and not a
    /// second write.
    @Test("A second pass over an already-clamped cache is a no-op")
    func secondPassIsANoOp() throws {
        _ = try #require(MaxSlideFixture.pristine, MaxSlideFixture.missing)

        let swiftSide = try MaxSlideFixture.cloneMainChunk(named: "idem_swift")
        defer { MaxSlideFixture.discard(swiftSide) }

        let first = try DSCMaxSlidePatcher.patch(chunksDirectory: swiftSide)
        let afterFirst = try Digest.sha256(
            of: swiftSide.appendingPathComponent(MaxSlideFixture.mainChunkName)
        )

        let mineAgain = try DSCMaxSlidePatcher.patch(chunksDirectory: swiftSide)
        #expect(mineAgain.siteCount == 0)
        #expect(!mineAgain.didWrite)
        // Which gate stops the second pass is worth being precise about. Once
        // the slide is gone this cache's span fits the region on its own
        // (0x17D504000 <= 0x180000000) — that is the whole point of the patch —
        // so the *fits* gate is what returns, and the already-zero gate behind
        // it is never reached. The reference said the same thing in words: its
        // second run printed "fits: … no change", not "maxSlide already 0".
        #expect(mineAgain.outcome == .fits(
            combined: first.sharedRegionSize,
            region: DSCMaxSlidePatcher.kernelSharedRegionSize
        ))

        // `--force` skips the fits gate, so it is the one path that does reach
        // the already-zero check — and it still writes nothing. The reference's
        // third run printed "maxSlide already 0; no change" and left its file
        // alone, which is what the unchanged digest below has to show.
        let mineForced = try DSCMaxSlidePatcher.patch(chunksDirectory: swiftSide, force: true)
        #expect(mineForced.siteCount == 0)
        #expect(mineForced.outcome == .alreadyZero)

        let afterThird = try Digest.sha256(
            of: swiftSide.appendingPathComponent(MaxSlideFixture.mainChunkName)
        )
        #expect(afterThird == afterFirst, "a no-op pass rewrote the chunk")
        #expect(afterThird == FrozenReference.realChangedChunks[MaxSlideFixture.mainChunkName])
    }
}

// MARK: - The gate, on synthetic caches

/// The four branches `cfw_patch_dsc_maxslide._self_test` covered, replayed on
/// the same synthetic caches the reference was given — see `FrozenReference`
/// for the digests of each one, before and after.
///
/// Synthetic rather than real because the real cache can only exercise one of
/// the four: it overflows. A cache that *fits* — an 18.x or 26.x base, the case
/// the self-gate exists to protect — cannot be demonstrated with the fixture on
/// hand, so it is built.
@Suite(.serialized, .enabled(if: MaxSlideFixture.runs, MaxSlideFixture.skipReason))
struct DSCMaxSlideGateTests {
    /// A minimal but *real* cache: header plus a one-entry mapping table that
    /// covers it. The Python's own self-test fixture has no mapping table at
    /// all, which the Swift refuses — see `noMappingTableIsRefused`.
    ///
    /// - Parameters:
    ///   - regionSize: what the header records as `sharedRegionSize`.
    ///   - maxSlide: what the header records as `maxSlide`.
    static func writeCache(
        into directory: URL,
        regionSize: UInt64,
        maxSlide: UInt64,
        mappingOffset: Int = 0x238,
        magic: String = "dyld_v1  arm64e"
    ) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var bytes = [UInt8](repeating: 0, count: 0x4000)

        func put(_ value: UInt64, at offset: Int) {
            withUnsafeBytes(of: value.littleEndian) { source in
                for (index, byte) in source.enumerated() { bytes[offset + index] = byte }
            }
        }
        func put32(_ value: UInt32, at offset: Int) {
            withUnsafeBytes(of: value.littleEndian) { source in
                for (index, byte) in source.enumerated() { bytes[offset + index] = byte }
            }
        }

        for (index, byte) in Array(magic.utf8).prefix(16).enumerated() { bytes[index] = byte }
        put32(UInt32(mappingOffset), at: 0x10)
        put32(1, at: 0x14) // mappingCount

        // dyld_cache_mapping_info: address, size, fileOffset, maxProt, initProt.
        put(Self.mappingAddress, at: mappingOffset)
        put(0x4000, at: mappingOffset + 8)
        put(0, at: mappingOffset + 16)
        put32(5, at: mappingOffset + 24)
        put32(5, at: mappingOffset + 28)

        put(Self.mappingAddress, at: 0xE0) // sharedRegionStart
        put(regionSize, at: 0xE8) // sharedRegionSize
        put(maxSlide, at: 0xF0) // maxSlide

        try Data(bytes).write(
            to: directory.appendingPathComponent(MaxSlideFixture.mainChunkName)
        )
    }

    /// SHARED_REGION_BASE_ARM64, which is also where the real cache starts.
    static let mappingAddress: UInt64 = 0x1_8000_0000

    /// Build the synthetic cache the reference was given, hand it to the Swift,
    /// and require the file to come out with the reference's digest.
    ///
    /// The input digest is checked first. Without it a change to `writeCache`
    /// would silently move the comparison onto some other cache, and the output
    /// digest would then be measuring the wrong thing.
    private func compare(
        named name: String,
        regionSize: UInt64,
        maxSlide: UInt64,
        force: Bool = false,
        reference: FrozenReference.GateCase,
        expectedSites: Int,
        expectedOutcome: DSCMaxSlidePatcher.Outcome,
        expectedMaxSlideAfter: UInt64
    ) throws {
        let swiftSide = MaxSlideFixture.scratchRoot.appendingPathComponent("\(name)_swift")
        defer { MaxSlideFixture.discard(swiftSide) }
        try Self.writeCache(into: swiftSide, regionSize: regionSize, maxSlide: maxSlide)

        let swiftMain = swiftSide.appendingPathComponent(MaxSlideFixture.mainChunkName)
        let inputDigest = try Digest.sha256(of: swiftMain)
        #expect(
            inputDigest == reference.inputSHA256,
            "\(name): this is not the cache the reference saw — \(inputDigest)"
        )

        let mine = try DSCMaxSlidePatcher.patch(chunksDirectory: swiftSide, force: force)
        #expect(mine.siteCount == expectedSites)
        #expect(mine.outcome == expectedOutcome)

        let outputDigest = try Digest.sha256(of: swiftMain)
        #expect(
            outputDigest == reference.outputSHA256,
            "\(name): Swift \(outputDigest), reference \(reference.outputSHA256)"
        )
        #expect(try Bytes.maxSlide(of: swiftMain) == expectedMaxSlideAfter)
        print("[gate \(name)] \(expectedSites) site(s) on the reference's \(reference.branch) "
            + "branch; maxSlide now 0x\(String(expectedMaxSlideAfter, radix: 16, uppercase: true))")
    }

    @Test("An overflowing cache is clamped, as the reference clamped it")
    func overflowIsClamped() throws {
        // iOS 27.0-like: 0x17C830000 + 0x20000000 > 0x180000000.
        try compare(
            named: "overflow",
            regionSize: 0x1_7C83_0000,
            maxSlide: 0x2000_0000,
            reference: FrozenReference.overflow,
            expectedSites: 1,
            expectedOutcome: .overflow(
                combined: 0x1_9C83_0000,
                region: DSCMaxSlidePatcher.kernelSharedRegionSize
            ),
            expectedMaxSlideAfter: 0
        )
    }

    @Test("A cache that fits is left alone, as the reference left it")
    func fittingCacheIsUntouched() throws {
        // 26.4-like: 0x140904000 + 0x20000000 <= 0x180000000.
        try compare(
            named: "fits",
            regionSize: 0x1_4090_4000,
            maxSlide: 0x2000_0000,
            reference: FrozenReference.fits,
            expectedSites: 0,
            expectedOutcome: .fits(
                combined: 0x1_6090_4000,
                region: DSCMaxSlidePatcher.kernelSharedRegionSize
            ),
            expectedMaxSlideAfter: 0x2000_0000
        )
    }

    @Test("--force clamps a cache that fits, to the reference's bytes")
    func forceClampsAFittingCache() throws {
        try compare(
            named: "forced",
            regionSize: 0x1_4090_4000,
            maxSlide: 0x2000_0000,
            force: true,
            reference: FrozenReference.forced,
            expectedSites: 1,
            expectedOutcome: .forced(
                combined: 0x1_6090_4000,
                region: DSCMaxSlidePatcher.kernelSharedRegionSize
            ),
            expectedMaxSlideAfter: 0
        )
    }

    @Test("--force over an already-zero cache is a no-op, as it was for the reference")
    func forceOverZeroIsANoOp() throws {
        try compare(
            named: "forced_zero",
            regionSize: 0x1_4090_4000,
            maxSlide: 0,
            force: true,
            reference: FrozenReference.forcedZero,
            expectedSites: 0,
            expectedOutcome: .alreadyZero,
            expectedMaxSlideAfter: 0
        )
    }

    /// The fourth branch, and the only one that needs no `--force` to reach the
    /// already-zero check: a span that overruns the region on its own, with no
    /// slide left to give back. Both implementations report the cache as
    /// unpatchable rather than writing a zero over a zero.
    ///
    /// The span has to exceed the region by itself — a 0x17C830000 span with a
    /// zero slide *fits*, and takes the fits branch instead, which is what both
    /// implementations do and what an earlier version of this test got wrong.
    @Test("A cache that overruns the region with no slide left is left alone")
    func overflowWithZeroSlideIsANoOp() throws {
        try compare(
            named: "overflow_zero",
            regionSize: 0x1_9000_0000,
            maxSlide: 0,
            reference: FrozenReference.overflowWithZeroSlide,
            expectedSites: 0,
            expectedOutcome: .alreadyZero,
            expectedMaxSlideAfter: 0
        )
    }

    // MARK: - Refusals

    @Test("A missing main chunk is a named failure, not a crash")
    func missingMainChunkThrows() throws {
        let empty = MaxSlideFixture.scratchRoot.appendingPathComponent("empty")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        defer { MaxSlideFixture.discard(empty) }

        #expect(throws: PatcherError.self) {
            _ = try DSCMaxSlidePatcher.patch(chunksDirectory: empty, verbose: false)
        }
    }

    /// The Python checks `hdr[:7] != b"dyld_v1"`; so does this. A `dyld_v2`
    /// header still parses as a cache far enough to reach the check, which is
    /// what makes the check worth having.
    @Test("A file that is not a dyld_v1 cache is refused")
    func wrongMagicIsRefused() throws {
        let directory = MaxSlideFixture.scratchRoot.appendingPathComponent("badmagic")
        defer { MaxSlideFixture.discard(directory) }
        try Self.writeCache(
            into: directory,
            regionSize: 0x1_7C83_0000,
            maxSlide: 0x2000_0000,
            magic: "dyld_v2  arm64e"
        )

        #expect(throws: PatcherError.self) {
            _ = try DSCMaxSlidePatcher.patch(chunksDirectory: directory, verbose: false)
        }
    }

    /// dyld's own field-presence rule: the header struct ends where the mapping
    /// table begins, so a `mappingOffset` that does not reach past `maxSlide`
    /// means this cache version has no such field. The reference had no
    /// equivalent gate and would write eight zero bytes into whatever is at
    /// 0xF0 — here that is a `dyld_cache_mapping_info.fileOffset`.
    @Test("A header too short to hold maxSlide is refused, where the reference would write")
    func truncatedHeaderIsRefused() throws {
        let directory = MaxSlideFixture.scratchRoot.appendingPathComponent("shortheader")
        defer { MaxSlideFixture.discard(directory) }
        // Mapping table at 0xC0: the header struct then ends at 0xC0, well
        // before the 0xF0 these offsets want to write at. The mapping itself is
        // still valid, so the run gets as far as the version gate.
        try Self.writeCache(
            into: directory,
            regionSize: 0x1_7C83_0000,
            maxSlide: 0x2000_0000,
            mappingOffset: 0xC0
        )

        #expect(throws: PatcherError.self) {
            _ = try DSCMaxSlidePatcher.patch(chunksDirectory: directory, verbose: false)
        }
    }

    /// The corroboration check: a header whose `sharedRegionStart` is not the
    /// cache's lowest mapped address is not laid out the way these offsets
    /// assume, so the write is refused rather than aimed at an unknown field.
    @Test("A header that disagrees with the mapping table is refused")
    func headerDisagreeingWithMappingsIsRefused() throws {
        let directory = MaxSlideFixture.scratchRoot.appendingPathComponent("mismatch")
        defer { MaxSlideFixture.discard(directory) }
        try Self.writeCache(
            into: directory,
            regionSize: 0x1_7C83_0000,
            maxSlide: 0x2000_0000
        )
        // Move sharedRegionStart away from the mapping's address.
        let main = directory.appendingPathComponent(MaxSlideFixture.mainChunkName)
        let handle = try FileHandle(forUpdating: main)
        try handle.seek(toOffset: 0xE0)
        try handle.write(contentsOf: withUnsafeBytes(of: UInt64(0x1_9000_0000).littleEndian) {
            Data($0)
        })
        try handle.close()

        #expect(throws: PatcherError.self) {
            _ = try DSCMaxSlidePatcher.patch(chunksDirectory: directory, verbose: false)
        }
    }

    /// The Python's own self-test fixture: a bare 0x100-byte header with no
    /// mapping table. The reference patched it — it printed `overflow: … set
    /// maxSlide 0x20000000 -> 0x0` and the field read back as 0. This refuses
    /// it, because every write here goes through `DSCChunkSet`, which has
    /// nothing to address such a file with. A documented divergence, and a
    /// strictly safer one — the input is not a shared cache.
    @Test("A header with no mapping table is refused, where the reference patched it")
    func noMappingTableIsRefused() throws {
        let swiftSide = MaxSlideFixture.scratchRoot.appendingPathComponent("headeronly_swift")
        defer { MaxSlideFixture.discard(swiftSide) }

        try FileManager.default.createDirectory(at: swiftSide, withIntermediateDirectories: true)
        var bytes = [UInt8](repeating: 0, count: 0x100)
        for (index, byte) in Array("dyld_v1  arm64e".utf8).enumerated() { bytes[index] = byte }
        func put(_ value: UInt64, at offset: Int) {
            withUnsafeBytes(of: value.littleEndian) { source in
                for (index, byte) in source.enumerated() { bytes[offset + index] = byte }
            }
        }
        put(Self.mappingAddress, at: 0xE0)
        put(0x1_7C83_0000, at: 0xE8)
        put(0x2000_0000, at: 0xF0)
        try Data(bytes).write(
            to: swiftSide.appendingPathComponent(MaxSlideFixture.mainChunkName)
        )

        #expect(throws: DSCError.self) {
            _ = try DSCMaxSlidePatcher.patch(chunksDirectory: swiftSide, verbose: false)
        }
        let untouchedSlide = try Bytes.maxSlide(
            of: swiftSide.appendingPathComponent(MaxSlideFixture.mainChunkName)
        )
        #expect(untouchedSlide == 0x2000_0000, "the refusal still wrote")
    }
}

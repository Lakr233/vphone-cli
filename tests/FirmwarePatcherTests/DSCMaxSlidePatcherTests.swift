// DSCMaxSlidePatcherTests.swift — Parity cross-checks for `DSCMaxSlidePatcher`.
//
// There is no `codesign -v` for a dyld shared cache chunk and no second
// implementation of this patch anywhere, so the only independent reference is
// `scripts/patchers/cfw_patch_dsc_maxslide.py` — driven here through the exact
// CLI the install scripts use, `cfw.py patch-dsc-maxslide <dir> [--dry-run]
// [--force]`. Every claim below is "the Python did X on one clone, the Swift
// did X on another, and the two clones are the same bytes".
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
import Foundation
import Testing

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

    static let venvMissing: Comment = """
    the project venv is required: these tests are a comparison against \
    scripts/patchers/cfw_patch_dsc_maxslide.py, and without it there is nothing \
    to compare against — run `make setup_venv`
    """

    /// Where clones are made. Same filesystem as the repo, and deliberately
    /// *not* under `ipsws/ref_extract/`, which is the pristine reference the
    /// whole suite compares against.
    static var scratchRoot: URL {
        repoRoot.appendingPathComponent("ipsws/scratch_dscmaxslide")
    }

    /// The project venv, which is where the reference Python lives.
    static var python: URL? {
        let url = repoRoot.appendingPathComponent(".venv/bin/python3")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
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

// MARK: - The reference Python, driven through its real CLI

/// `cfw.py patch-dsc-maxslide <chunks_dir> [--dry-run] [--force]` — the exact
/// contract `scripts/cfw_install.sh` and `cfw-kit/lib/base_stages.sh` call.
private enum PythonReference {
    struct Run {
        let stdout: String

        /// The Python's return value, recovered from the lines it prints: it
        /// returns 1 once it has decided the cache needs the clamp (including
        /// on a dry run), and 0 from either "no change" branch.
        var siteCount: Int { stdout.contains("[+] DSC maxSlide patch complete") ? 1 : 0 }
        var saidNoChange: Bool { stdout.contains("no change") }
        var saidWouldSet: Bool { stdout.contains("would set maxSlide") }
    }

    static func patch(
        directory: URL,
        dryRun: Bool = false,
        force: Bool = false
    ) throws -> Run {
        let python = try #require(MaxSlideFixture.python, MaxSlideFixture.venvMissing)
        var arguments = [
            MaxSlideFixture.repoRoot.appendingPathComponent("scripts/patchers/cfw.py").path,
            "patch-dsc-maxslide",
            directory.path,
        ]
        if dryRun { arguments.append("--dry-run") }
        if force { arguments.append("--force") }

        let result = try Subprocess.run(executable: python, arguments: arguments)
        guard result.status == 0 else {
            Issue.record("cfw.py patch-dsc-maxslide failed: \(result.stderr)")
            throw CocoaError(.fileReadUnknown)
        }
        return Run(stdout: result.stdout)
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
        print(
            "[pristine] start=0x\(String(header.sharedRegionStart, radix: 16, uppercase: true)) "
                + "size=0x\(String(header.sharedRegionSize, radix: 16, uppercase: true)) "
                + "maxSlide=0x\(String(header.maxSlide, radix: 16, uppercase: true))"
        )
    }

    /// The gate from the task: run each implementation on its own clone of the
    /// real cache and require the two clones to come out byte-identical, over
    /// every one of the 79 chunks and the symbol side file — not just over the
    /// eight bytes the patch is about.
    @Test("Swift and the Python patch the real cache into byte-identical clones")
    func realCacheParityWithPython() throws {
        let pristine = try #require(MaxSlideFixture.pristine, MaxSlideFixture.missing)
        _ = try #require(MaxSlideFixture.python, MaxSlideFixture.venvMissing)

        let pythonSide = try MaxSlideFixture.cloneCache(named: "parity_python")
        let swiftSide = try MaxSlideFixture.cloneCache(named: "parity_swift")
        defer { MaxSlideFixture.discard(pythonSide, swiftSide) }

        let theirs = try PythonReference.patch(directory: pythonSide)
        #expect(theirs.siteCount == 1, "the Python did not patch the real cache")
        #expect(!theirs.saidNoChange)

        let mine = try DSCMaxSlidePatcher.patch(chunksDirectory: swiftSide)
        #expect(mine.siteCount == 1, "the Swift did not patch the real cache")
        #expect(mine.didWrite)
        #expect(mine.outcome == .overflow(
            combined: mine.sharedRegionSize + mine.maxSlide,
            region: DSCMaxSlidePatcher.kernelSharedRegionSize
        ))
        #expect(mine.writtenSpan?.length == 8, "one site, one u64")

        let (matched, differing) = try Bytes.compareTrees(pythonSide, swiftSide)
        #expect(differing.isEmpty, "clones differ in: \(differing.joined(separator: ", "))")
        #expect(matched >= 79, "only \(matched) files compared")
        print("[parity] \(matched) files byte-identical between the two patched clones")

        // And both differ from pristine in exactly one file, by exactly the
        // eight bytes of the field.
        let pristineMain = pristine.appendingPathComponent(MaxSlideFixture.mainChunkName)
        let head = DSCMaxSlidePatcher.HeaderField.maxSlide
        let tailOffset = UInt64(head + 8)
        let tailLength = 0x100 - head - 8
        let pristineHead = try Bytes.read(pristineMain, offset: 0, length: head)
        let pristineTail = try Bytes.read(pristineMain, offset: tailOffset, length: tailLength)
        for side in [pythonSide, swiftSide] {
            let main = side.appendingPathComponent(MaxSlideFixture.mainChunkName)
            let differsFromPristine = try !Bytes.identical(main, pristineMain)
            #expect(differsFromPristine)
            let slide = try Bytes.maxSlide(of: main)
            #expect(slide == 0)

            // Everything either side of the field is untouched.
            let patchedHead = try Bytes.read(main, offset: 0, length: head)
            let patchedTail = try Bytes.read(main, offset: tailOffset, length: tailLength)
            #expect(patchedHead == pristineHead)
            #expect(patchedTail == pristineTail)
        }

        let (unchanged, changed) = try Bytes.compareTrees(pristine, swiftSide)
        #expect(changed == [MaxSlideFixture.mainChunkName])
        print("[parity] \(unchanged) files unchanged from pristine; only \(changed) differs")
        print("[parity] python: \(theirs.siteCount) site, swift: \(mine.siteCount) site")
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

    @Test("A dry run reports the site the Python reports, and writes nothing")
    func dryRunMatchesPythonAndWritesNothing() throws {
        let pristine = try #require(MaxSlideFixture.pristine, MaxSlideFixture.missing)
        _ = try #require(MaxSlideFixture.python, MaxSlideFixture.venvMissing)

        let pythonSide = try MaxSlideFixture.cloneMainChunk(named: "dryrun_python")
        let swiftSide = try MaxSlideFixture.cloneMainChunk(named: "dryrun_swift")
        defer { MaxSlideFixture.discard(pythonSide, swiftSide) }

        let theirs = try PythonReference.patch(directory: pythonSide, dryRun: true)
        #expect(theirs.siteCount == 1)
        #expect(theirs.saidWouldSet)

        let mine = try DSCMaxSlidePatcher.patch(chunksDirectory: swiftSide, dryRun: true)
        #expect(mine.siteCount == 1, "a dry run still reports the site, as the Python does")
        #expect(!mine.didWrite)
        #expect(mine.record?.patchID == DSCMaxSlidePatcher.patchID)
        #expect(mine.record?.patchedBytes == Data(count: 8))
        #expect(mine.record?.originalBytes.loadLE(UInt64.self, at: 0) == mine.maxSlide)

        let pristineMain = pristine.appendingPathComponent(MaxSlideFixture.mainChunkName)
        for side in [pythonSide, swiftSide] {
            let untouched = try Bytes.identical(
                side.appendingPathComponent(MaxSlideFixture.mainChunkName),
                pristineMain
            )
            #expect(untouched, "a dry run wrote to the chunk")
        }
        print("[dry run] python and swift both report 1 site and leave the chunk pristine")
    }

    /// `8eb6c8b`'s lesson again: a patcher has to recognise its own output. A
    /// second pass over a clamped cache is a no-op, not an error and not a
    /// second write.
    @Test("A second pass over an already-clamped cache is a no-op")
    func secondPassIsANoOp() throws {
        _ = try #require(MaxSlideFixture.pristine, MaxSlideFixture.missing)
        _ = try #require(MaxSlideFixture.python, MaxSlideFixture.venvMissing)

        let pythonSide = try MaxSlideFixture.cloneMainChunk(named: "idem_python")
        let swiftSide = try MaxSlideFixture.cloneMainChunk(named: "idem_swift")
        defer { MaxSlideFixture.discard(pythonSide, swiftSide) }

        _ = try PythonReference.patch(directory: pythonSide)
        let theirsAgain = try PythonReference.patch(directory: pythonSide)
        #expect(theirsAgain.siteCount == 0)
        #expect(theirsAgain.saidNoChange)

        let first = try DSCMaxSlidePatcher.patch(chunksDirectory: swiftSide)
        let mineAgain = try DSCMaxSlidePatcher.patch(chunksDirectory: swiftSide)
        #expect(mineAgain.siteCount == 0)
        #expect(!mineAgain.didWrite)
        // Which gate stops the second pass is worth being precise about. Once
        // the slide is gone this cache's span fits the region on its own
        // (0x17D504000 <= 0x180000000) — that is the whole point of the patch —
        // so the *fits* gate is what returns, and the already-zero gate behind
        // it is never reached. The Python says the same thing in words: its
        // second run prints "fits: … no change", not "maxSlide already 0".
        #expect(mineAgain.outcome == .fits(
            combined: first.sharedRegionSize,
            region: DSCMaxSlidePatcher.kernelSharedRegionSize
        ))

        // `--force` skips the fits gate, so it is the one path that does reach
        // the already-zero check — and it still writes nothing.
        let theirsForced = try PythonReference.patch(directory: pythonSide, force: true)
        #expect(theirsForced.siteCount == 0)
        let mineForced = try DSCMaxSlidePatcher.patch(chunksDirectory: swiftSide, force: true)
        #expect(mineForced.siteCount == 0)
        #expect(mineForced.outcome == .alreadyZero)

        let (_, differing) = try Bytes.compareTrees(pythonSide, swiftSide)
        #expect(differing.isEmpty)
        print("[idempotence] both implementations report 0 sites on the second and third pass")
    }
}

// MARK: - The gate, on synthetic caches

/// The four branches `cfw_patch_dsc_maxslide._self_test` covers, run against
/// both implementations on identical synthetic caches.
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

    /// Build the same synthetic cache twice, hand one to each implementation,
    /// and require the two files to come out identical.
    private func compare(
        named name: String,
        regionSize: UInt64,
        maxSlide: UInt64,
        force: Bool = false,
        expectedSites: Int,
        expectedOutcome: DSCMaxSlidePatcher.Outcome,
        expectedMaxSlideAfter: UInt64
    ) throws {
        _ = try #require(MaxSlideFixture.python, MaxSlideFixture.venvMissing)

        let pythonSide = MaxSlideFixture.scratchRoot.appendingPathComponent("\(name)_python")
        let swiftSide = MaxSlideFixture.scratchRoot.appendingPathComponent("\(name)_swift")
        defer { MaxSlideFixture.discard(pythonSide, swiftSide) }
        for side in [pythonSide, swiftSide] {
            try Self.writeCache(into: side, regionSize: regionSize, maxSlide: maxSlide)
        }

        let theirs = try PythonReference.patch(directory: pythonSide, force: force)
        let mine = try DSCMaxSlidePatcher.patch(chunksDirectory: swiftSide, force: force)

        #expect(theirs.siteCount == expectedSites, "python: \(theirs.stdout)")
        #expect(mine.siteCount == expectedSites)
        #expect(mine.outcome == expectedOutcome)

        let pythonMain = pythonSide.appendingPathComponent(MaxSlideFixture.mainChunkName)
        let swiftMain = swiftSide.appendingPathComponent(MaxSlideFixture.mainChunkName)
        let same = try Bytes.identical(pythonMain, swiftMain)
        #expect(same, "\(name): the two caches differ")
        let swiftSlide = try Bytes.maxSlide(of: swiftMain)
        let pythonSlide = try Bytes.maxSlide(of: pythonMain)
        #expect(swiftSlide == expectedMaxSlideAfter)
        #expect(pythonSlide == expectedMaxSlideAfter)
        print("[gate \(name)] both wrote \(expectedSites) site(s); maxSlide now "
            + "0x\(String(expectedMaxSlideAfter, radix: 16, uppercase: true))")
    }

    @Test("An overflowing cache is clamped by both implementations")
    func overflowIsClamped() throws {
        // iOS 27.0-like: 0x17C830000 + 0x20000000 > 0x180000000.
        try compare(
            named: "overflow",
            regionSize: 0x1_7C83_0000,
            maxSlide: 0x2000_0000,
            expectedSites: 1,
            expectedOutcome: .overflow(
                combined: 0x1_9C83_0000,
                region: DSCMaxSlidePatcher.kernelSharedRegionSize
            ),
            expectedMaxSlideAfter: 0
        )
    }

    @Test("A cache that fits is left alone by both implementations")
    func fittingCacheIsUntouched() throws {
        // 26.4-like: 0x140904000 + 0x20000000 <= 0x180000000.
        try compare(
            named: "fits",
            regionSize: 0x1_4090_4000,
            maxSlide: 0x2000_0000,
            expectedSites: 0,
            expectedOutcome: .fits(
                combined: 0x1_6090_4000,
                region: DSCMaxSlidePatcher.kernelSharedRegionSize
            ),
            expectedMaxSlideAfter: 0x2000_0000
        )
    }

    @Test("--force clamps a cache that fits, on both implementations")
    func forceClampsAFittingCache() throws {
        try compare(
            named: "forced",
            regionSize: 0x1_4090_4000,
            maxSlide: 0x2000_0000,
            force: true,
            expectedSites: 1,
            expectedOutcome: .forced(
                combined: 0x1_6090_4000,
                region: DSCMaxSlidePatcher.kernelSharedRegionSize
            ),
            expectedMaxSlideAfter: 0
        )
    }

    @Test("--force over an already-zero cache is a no-op on both implementations")
    func forceOverZeroIsANoOp() throws {
        try compare(
            named: "forced_zero",
            regionSize: 0x1_4090_4000,
            maxSlide: 0,
            force: true,
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
    /// means this cache version has no such field. The Python has no equivalent
    /// gate and would write eight zero bytes into whatever is at 0xF0 — here
    /// that is a `dyld_cache_mapping_info.fileOffset`.
    @Test("A header too short to hold maxSlide is refused, where the Python would write")
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
    /// mapping table. The Python patches it; this refuses it, because every
    /// write here goes through `DSCChunkSet`, which has nothing to address it
    /// with. A documented divergence, and a strictly safer one — the input is
    /// not a shared cache.
    @Test("A header with no mapping table is refused, where the Python patches it")
    func noMappingTableIsRefused() throws {
        _ = try #require(MaxSlideFixture.python, MaxSlideFixture.venvMissing)

        let pythonSide = MaxSlideFixture.scratchRoot.appendingPathComponent("headeronly_python")
        let swiftSide = MaxSlideFixture.scratchRoot.appendingPathComponent("headeronly_swift")
        defer { MaxSlideFixture.discard(pythonSide, swiftSide) }

        for side in [pythonSide, swiftSide] {
            try FileManager.default.createDirectory(at: side, withIntermediateDirectories: true)
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
                to: side.appendingPathComponent(MaxSlideFixture.mainChunkName)
            )
        }

        let theirs = try PythonReference.patch(directory: pythonSide)
        #expect(theirs.siteCount == 1, "the Python patches a mapping-less header")

        #expect(throws: DSCError.self) {
            _ = try DSCMaxSlidePatcher.patch(chunksDirectory: swiftSide, verbose: false)
        }
        let untouchedSlide = try Bytes.maxSlide(
            of: swiftSide.appendingPathComponent(MaxSlideFixture.mainChunkName)
        )
        #expect(untouchedSlide == 0x2000_0000, "the refusal still wrote")
        print("[no mappings] python clamped it; swift refused and left it alone")
    }
}

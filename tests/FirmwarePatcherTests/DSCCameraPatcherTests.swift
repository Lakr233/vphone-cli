// DSCCameraPatcherTests.swift — Parity gate for the camera DSC patcher.
//
// The claim these tests exist to defend is narrow and checkable: running
// `DSCCameraPatcher` over a clone of the real shared cache leaves exactly the
// bytes `scripts/patchers/cfw_patch_camera_dsc.py` left — patched instructions,
// rewritten code slots and everything neither touched.
//
// That Python has been removed, so the numbers it produced are frozen in
// `FrozenReference` below: the six sites with the address, the prologue and the
// replacement for each, the code slots it re-attested, the SHA-256 of the two
// chunks it changed, the patch ids its `_sym_slug` derived, and the bytes
// keystone assembled for both replacements. Each carries the run that produced
// it.
//
// The tests need the real cache. `VPHONE_DSC_PRISTINE` points at a directory of
// `dyld_shared_cache_arm64e*` chunks, defaulting to
// `ipsws/ref_extract/dsc_pristine`.
//
// Without it they FAIL. A bare `return` in place of a fixture is reported by
// Swift Testing as a pass, so "the camera port is green" would be equally
// compatible with "the camera port was never run". A machine that genuinely
// cannot carry the 6.7 GB fixture sets `VPHONE_DSC_FIXTURE_OPTIONAL=1`, which
// turns the failure into a visible *skip*.
//
// Nothing here writes into the pristine directory, or anywhere else in the
// working tree. Clones go to the system temp directory — `clonefile`, so
// instant and near-free on APFS — and are discarded afterwards.
// `VPHONE_DSC_SCRATCH` moves them somewhere else on the same volume.

@testable import FirmwarePatcher
import CryptoKit
import Foundation
import Testing

// MARK: - The frozen reference

/// What the reference Python did on the real 24A435 arm64e shared cache.
///
/// Recorded from a live run at commit 78cbeea:
///
///     PATH=/opt/homebrew/bin:… .venv/bin/python3 \
///         scripts/patchers/cfw_patch_camera_dsc.py <clone> <clone>/dyld_shared_cache_arm64e
///
/// (`/opt/homebrew/bin` because the reference shelled out to `ipsw` for symbol
/// resolution; the Swift port resolves from the cache's own tables.)
private enum FrozenReference {
    /// One entry point, as the reference printed it:
    ///
    ///     +[_NUStyleTransferApplyProcessor processWithInputs:…]  @ 0x1BF430C04
    ///       7f2303d5ef3bb66d → 00008052c0035fd6
    struct Site {
        let symbol: String
        let vma: UInt64
        /// The eight prologue bytes it read, as it printed them.
        let before: String
        /// The eight it wrote in their place.
        let after: String
    }

    /// `[1/2] +[_NUStyleTransfer*Processor processWithInputs:…] → return NO`,
    /// then `[2/2] +[AVCaptureDevice authorizationStatusForMediaType:] →
    /// return Authorized`. Six sites, in the order the reference listed them.
    static let sites: [Site] = [
        Site(symbol: "+[_NUStyleTransferApplyProcessor processWithInputs:arguments:output:error:]",
             vma: 0x1_BF43_0C04, before: "7f2303d5ef3bb66d", after: "00008052c0035fd6"),
        Site(symbol: "+[_NUStyleTransferInterpolateProcessor processWithInputs:arguments:output:error:]",
             vma: 0x1_BF43_A3A8, before: "7f2303d5ff0303d1", after: "00008052c0035fd6"),
        Site(symbol: "+[_NUStyleTransferLearnProcessor processWithInputs:arguments:output:error:]",
             vma: 0x1_BF42_EC54, before: "7f2303d5ff0304d1", after: "00008052c0035fd6"),
        Site(symbol: "+[_NUStyleTransferProcessor processWithInputs:arguments:output:error:]",
             vma: 0x1_BF43_3BD0, before: "7f2303d5ffc306d1", after: "00008052c0035fd6"),
        Site(symbol: "+[_NUStyleTransferThumbnailProcessor processWithInputs:arguments:output:error:]",
             vma: 0x1_BF43_5DB4, before: "7f2303d5ff8303d1", after: "00008052c0035fd6"),
        Site(symbol: "+[AVCaptureDevice authorizationStatusForMediaType:]",
             vma: 0x1_AD8A_12D8, before: "7f2303d5ffc301d1", after: "60008052c0035fd6"),
    ]

    static var sitesBySymbol: [String: Site] {
        Dictionary(uniqueKeysWithValues: sites.map { ($0.symbol, $0) })
    }

    /// The `re-attest: wrote slot N of <chunk>` lines, as `<chunk>:<slot>`:
    /// four pages for the NeutrinoCore family, one for AVFCapture.
    static let reattestedPages: Set<String> = [
        "dyld_shared_cache_arm64e.15:7179",
        "dyld_shared_cache_arm64e.15:7180",
        "dyld_shared_cache_arm64e.15:7181",
        "dyld_shared_cache_arm64e.15:7182",
        "dyld_shared_cache_arm64e.11:5416",
    ]

    /// `cmp -s` against the pristine tree afterwards: two chunks moved, one per
    /// family, with these digests (`shasum -a 256`). They cover the six writes
    /// and the five re-attested slots together.
    static let changedChunks: [String: String] = [
        "dyld_shared_cache_arm64e.11":
            "3a2cfbecd7eb029d74d930d9c8fc6d6d6066019691cf9f267a2089ac73685575",
        "dyld_shared_cache_arm64e.15":
            "4d7e5737d3d66725c59e0321410d05d501449301b269d7a6e25447c68ebc8cb0",
    ]

    /// `_sym_slug` from `cfw_patch_camera_dsc`, for the five style-transfer
    /// symbols and the AVF one, in `DSCCameraPatcher`'s declaration order.
    /// These key `cfw_records`, so a port that renames them writes records that
    /// line up with nothing.
    static let symbolSlugs: [String] = [
        "NUStyleTransferProcessor_processWithInputs_arguments_output_error",
        "NUStyleTransferThumbnailProcessor_processWithInputs_arguments_output_error",
        "NUStyleTransferApplyProcessor_processWithInputs_arguments_output_error",
        "NUStyleTransferLearnProcessor_processWithInputs_arguments_output_error",
        "NUStyleTransferInterpolateProcessor_processWithInputs_arguments_output_error",
        "AVCaptureDevice_authorizationStatusForMediaType",
    ]

    /// `cfw_asm.asm("mov w0, #0\nret").hex()` and the `#3` spelling, through
    /// the keystone the patchers assembled with.
    static let keystoneReturningZero = "00008052c0035fd6"
    static let keystoneReturningThree = "60008052c0035fd6"
}

// MARK: - Fixture discovery

private enum CameraFixture {
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

    /// Opt-out for a machine that cannot carry the fixture. Set it and the suite
    /// reports as skipped; leave it unset and a missing cache is a failure,
    /// which is the only reading of "green" a byte-parity gate can afford.
    static var isOptional: Bool {
        ProcessInfo.processInfo.environment["VPHONE_DSC_FIXTURE_OPTIONAL"] == "1"
    }

    static var runs: Bool { pristine != nil || !isOptional }

    static let missing: Comment = """
    the real 24A435 arm64e shared cache is required — put it at \
    ipsws/ref_extract/dsc_pristine, point VPHONE_DSC_PRISTINE at it, or set \
    VPHONE_DSC_FIXTURE_OPTIONAL=1 to skip these tests instead of failing
    """

    static let skipReason: Comment =
        "VPHONE_DSC_FIXTURE_OPTIONAL=1 and no dyld_shared_cache_arm64e fixture present"

    /// Where clones are made. Outside the working tree by default: the
    /// reference extract is what every other DSC suite compares against, and a
    /// scratch directory has no business living inside it.
    static var scratchRoot: URL {
        // Per-suite leaf on BOTH branches: the override is a base shared with
        // the other DSC suites, and they reuse the same clone names.
        let base = ProcessInfo.processInfo.environment["VPHONE_DSC_SCRATCH"]
            .map { URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("vphone-dsc-camera")
    }

    /// Clone the pristine cache into a fresh directory the caller may write to.
    static func cloneCache(named name: String) throws -> URL {
        let pristine = try #require(pristine, missing)
        let destination = scratchRoot.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.createDirectory(
            at: destination,
            withIntermediateDirectories: true
        )
        let result = try CameraSubprocess.run(
            executable: URL(fileURLWithPath: "/bin/cp"),
            arguments: ["-c", "-R"]
                + (try FileManager.default.contentsOfDirectory(atPath: pristine.path))
                .sorted()
                .map { pristine.appendingPathComponent($0).path }
                + [destination.path]
        )
        #expect(result.status == 0, "cp -c failed: \(result.stderr)")
        return destination
    }

    /// Discard clones, and the scratch root with them once the last one is gone.
    ///
    /// `VPHONE_DSC_KEEP_CLONES=1` leaves them behind, so the same comparison
    /// this suite makes with SHA-256 can be redone from a shell with `cmp`.
    /// They are clones, so keeping them costs only what the patches changed.
    static func discard(_ clones: URL...) {
        guard ProcessInfo.processInfo.environment["VPHONE_DSC_KEEP_CLONES"] != "1" else {
            return
        }
        for clone in clones {
            try? FileManager.default.removeItem(at: clone)
        }
        let remaining = (try? FileManager.default
            .contentsOfDirectory(atPath: scratchRoot.path)) ?? []
        if remaining.isEmpty {
            try? FileManager.default.removeItem(at: scratchRoot)
        }
    }

    /// SHA-256 of every file in a cache directory, keyed by name.
    ///
    /// Streamed, because the cache is 6.7 GB and reading it into `Data` would
    /// be a different kind of test failure.
    static func digests(of directory: URL) throws -> [String: String] {
        var result: [String: String] = [:]
        for name in try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted() {
            let handle = try FileHandle(forReadingFrom: directory.appendingPathComponent(name))
            defer { try? handle.close() }
            var hasher = SHA256()
            while let block = try handle.read(upToCount: 8 * 1024 * 1024), !block.isEmpty {
                hasher.update(data: block)
            }
            result[name] = Data(hasher.finalize()).hex
        }
        return result
    }
}

// MARK: - Subprocess helper

private enum CameraSubprocess {
    struct Result {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    @discardableResult
    static func run(
        executable: URL,
        arguments: [String],
        environment: [String: String]? = nil
    ) throws -> Result {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let environment { process.environment = environment }
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        // Drain before waiting: a full pipe buffer would deadlock the patcher.
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

// MARK: - The parity gate

@Suite(.serialized, .enabled(if: CameraFixture.runs, CameraFixture.skipReason))
struct DSCCameraPatcherParityTests {
    /// The gate. One clone, one run, one byte-for-byte comparison against the
    /// digests the reference left on every chunk file in the cache.
    @Test("Swift leaves the real cache in the reference's bytes")
    func matchesTheReferenceByteForByte() throws {
        let pristine = try #require(CameraFixture.pristine, CameraFixture.missing)

        let swiftSide = try CameraFixture.cloneCache(named: "camera_swift")
        defer { CameraFixture.discard(swiftSide) }

        var log: [String] = []
        let result = try DSCCameraPatcher.applyAll(
            chunksDirectory: swiftSide,
            log: { log.append($0) }
        )
        #expect(result.siteCount == 6, "the port wrote \(result.siteCount) sites, not 6")
        #expect(result.isComplete)
        #expect(result.sites.allSatisfy { !$0.wasAlreadyPatched })

        // Same addresses, same bytes before, same bytes after — checked against
        // what the reference printed, not against what the port believes.
        let reference = FrozenReference.sitesBySymbol
        #expect(Set(result.sites.map(\.symbol)) == Set(reference.keys))
        for site in result.sites {
            let theirs = try #require(
                reference[site.symbol],
                "the reference did not report \(site.symbol)"
            )
            #expect(site.vma == theirs.vma, "\(site.symbol) address")
            #expect(site.originalBytes.hex == theirs.before, "\(site.symbol) original bytes")
            #expect(site.patchedBytes.hex == theirs.after, "\(site.symbol) patched bytes")
        }

        // And the caches themselves, whole: exactly the two chunks the
        // reference moved, each to the bytes it left there.
        let mine = try CameraFixture.digests(of: swiftSide)
        #expect(mine.count >= 79, "only \(mine.count) chunk files were compared")
        let pristineDigests = try CameraFixture.digests(of: pristine)
        let changed = mine.filter { pristineDigests[$0.key] != $0.value }.keys.sorted()
        #expect(changed == FrozenReference.changedChunks.keys.sorted())
        for name in changed {
            let frozen = FrozenReference.changedChunks[name] ?? "(not a chunk the Python moved)"
            #expect(mine[name] == frozen, "\(name): Swift \(mine[name] ?? "—"), reference \(frozen)")
        }

        print("[camera parity] \(result.siteCount) sites, "
            + "\(result.reattestation?.updated.count ?? 0) slots rewritten, "
            + "\(mine.count) chunk files, \(changed.count) with the reference's digests")
        for line in log where line.contains("re-attest: wrote") { print(line) }
    }

    /// The reference re-attested per family off bare addresses; this re-attests
    /// once at the end off recorded spans. Same pages on this cache — which is
    /// worth checking rather than assuming, because it is the only reason the
    /// two runs can come out identical.
    @Test("The port re-attests exactly the pages the reference did")
    func reattestedPagesMatchTheReference() throws {
        _ = try #require(CameraFixture.pristine, CameraFixture.missing)

        let swiftSide = try CameraFixture.cloneCache(named: "camera_pages_swift")
        defer { CameraFixture.discard(swiftSide) }

        let result = try DSCCameraPatcher.applyAll(chunksDirectory: swiftSide, log: nil)
        let minePages = Set(
            (result.reattestation?.updated ?? []).map {
                "\($0.chunkURL.lastPathComponent):\($0.pageIndex)"
            }
        )
        #expect(
            minePages == FrozenReference.reattestedPages,
            "swift \(minePages.sorted()) vs reference \(FrozenReference.reattestedPages.sorted())"
        )
        print("[camera pages] \(minePages.sorted().joined(separator: ", "))")
    }

    /// Patch ids feed `cfw_records`, which is what a captured reference is
    /// keyed on. A port that renames them writes records nothing lines up with.
    @Test("Patch ids match the reference's _sym_slug")
    func patchIDsMatchTheReference() throws {
        let symbols = DSCCameraPatcher.styleTransferSymbols
            + [DSCCameraPatcher.authorizationStatusSymbol]
        let mine = symbols.map(DSCCameraPatcher.symbolSlug)
        #expect(mine == FrozenReference.symbolSlugs)
        print("[camera slugs] \(mine.count) ids agreed, e.g. camera_dsc.nu_styletransfer.\(mine[0])")
    }

    /// Both replacements come out of the Keystone-checked encoders, and both
    /// have to be what keystone itself assembled.
    @Test("Both replacements are the bytes keystone assembled")
    func replacementsMatchKeystone() throws {
        let styleTransfer = try DSCCameraPatcher.replacement(
            returning: DSCCameraPatcher.Family.neutrinoStyleTransfer.returnValue
        )
        let authorization = try DSCCameraPatcher.replacement(
            returning: DSCCameraPatcher.Family.avfAuthorization.returnValue
        )
        #expect(styleTransfer.hex == FrozenReference.keystoneReturningZero)
        #expect(authorization.hex == FrozenReference.keystoneReturningThree)
        #expect(styleTransfer.count == 8)
        #expect(authorization.count == 8)
        print("[camera bytes] mov w0,#0;ret = \(styleTransfer.hex), mov w0,#3;ret = \(authorization.hex)")
    }
}

// MARK: - Behaviour the reference does not pin

@Suite(.serialized, .enabled(if: CameraFixture.runs, CameraFixture.skipReason))
struct DSCCameraPatcherBehaviourTests {
    @Test("A dry run finds every site and writes nothing")
    func dryRunWritesNothing() throws {
        let pristine = try #require(CameraFixture.pristine, CameraFixture.missing)

        let clone = try CameraFixture.cloneCache(named: "camera_dryrun")
        defer { CameraFixture.discard(clone) }

        let result = try DSCCameraPatcher.applyAll(
            chunksDirectory: clone,
            dryRun: true,
            log: nil
        )
        #expect(result.siteCount == 6)
        #expect(result.dryRun)
        #expect(result.reattestation == nil)
        #expect(!result.isComplete, "a dry run is never a completed patch")

        let after = try CameraFixture.digests(of: clone)
        let before = try CameraFixture.digests(of: pristine)
        #expect(after == before, "a dry run touched the cache")
        print("[camera dry run] \(result.siteCount) sites reported, \(after.count) files unchanged")
    }

    @Test("AVF-only mode patches one site and leaves NeutrinoCore alone")
    func avfOnlyPatchesOneSite() throws {
        let pristine = try #require(CameraFixture.pristine, CameraFixture.missing)

        let clone = try CameraFixture.cloneCache(named: "camera_avf_only")
        defer { CameraFixture.discard(clone) }

        let result = try DSCCameraPatcher.applyAVFAuthorizationOnly(
            chunksDirectory: clone,
            log: nil
        )
        #expect(result.siteCount == 1)
        #expect(result.sites.first?.family == .avfAuthorization)
        #expect(result.sites.first?.symbol == DSCCameraPatcher.authorizationStatusSymbol)
        #expect(result.isComplete)

        // Exactly one chunk moved — the one AVFCapture lives in.
        let after = try CameraFixture.digests(of: clone)
        let before = try CameraFixture.digests(of: pristine)
        let changed = after.filter { before[$0.key] != $0.value }.keys.sorted()
        #expect(changed.count == 1, "avf-only changed \(changed)")

        // And the NeutrinoCore entry points still carry their signed prologue.
        let chunks = try DSCChunkSet(directory: clone)
        let resolver = try DSCSymbolResolver(chunks: chunks)
        let untouched = try resolver.addresses(
            of: DSCCameraPatcher.styleTransferSymbols,
            inImage: DSCCameraPatcher.Family.neutrinoStyleTransfer.imagePath
        )
        for (symbol, vma) in untouched {
            let head = try chunks.bytesAtVMA(vma, length: 4)
            #expect(head == ARM64.pacibsp, "\(symbol) was rewritten by avf-only mode")
        }
        print("[camera avf-only] 1 site, chunk \(changed[0]), 5 NeutrinoCore prologues intact")
    }

    /// Three sibling DSC gates shipped a version that raised on their own
    /// output. This one recognises it.
    @Test("A second run over an already-patched cache is inert, not an error")
    func reRunIsIdempotent() throws {
        _ = try #require(CameraFixture.pristine, CameraFixture.missing)

        let clone = try CameraFixture.cloneCache(named: "camera_idempotent")
        defer { CameraFixture.discard(clone) }

        let first = try DSCCameraPatcher.applyAll(chunksDirectory: clone, log: nil)
        #expect(first.siteCount == 6)
        #expect(first.sites.allSatisfy { !$0.wasAlreadyPatched })
        let afterFirst = try CameraFixture.digests(of: clone)

        let second = try DSCCameraPatcher.applyAll(chunksDirectory: clone, log: nil)
        #expect(second.siteCount == 6)
        #expect(
            second.sites.allSatisfy { $0.wasAlreadyPatched },
            "a re-run did not recognise its own output"
        )
        #expect(second.reattestation?.updated.isEmpty == true, "a re-run rewrote slot hashes")
        #expect(second.isComplete)

        let afterSecond = try CameraFixture.digests(of: clone)
        #expect(afterSecond == afterFirst, "a re-run changed the cache")
        // …and what it left standing is still the reference's bytes.
        for (name, digest) in FrozenReference.changedChunks {
            #expect(afterSecond[name] == digest, "\(name) drifted across the re-run")
        }
        print("[camera idempotence] second run: 6 sites recognised as already patched, 0 slots rewritten")
    }

    /// A failure in the second family must not leave the first family's writes
    /// on disk, because nothing would have re-attested the pages they dirtied.
    ///
    /// This is the shape that was real: `apply` wrote each site as it
    /// classified it and re-attested once at the end, so a throw in the AVF
    /// family left the five NeutrinoCore sites written with their code-signature
    /// slots still describing the old bytes. TXM checks those per page on
    /// `codeSigningMonitor == 2`, so the result was a cache that was both
    /// half-patched and unloadable — it SIGKILLs on the first demand-page-in of
    /// a modified page. `apply` now plans every family before it writes any of
    /// them, so a failure writes nothing at all.
    @Test("A failure part-way through leaves the cache untouched")
    func failureWritesNothing() throws {
        _ = try #require(CameraFixture.pristine, CameraFixture.missing)

        let clone = try CameraFixture.cloneCache(named: "camera_midrun_failure")
        defer { CameraFixture.discard(clone) }

        // Break only the AVF entry point — the family that runs second. The
        // five NeutrinoCore sites are pristine and would patch cleanly, which
        // is what makes this a half-patch rather than a no-op.
        let chunks = try DSCChunkSet(directory: clone)
        let resolver = try DSCSymbolResolver(chunks: chunks)
        let avf = try resolver.address(
            of: DSCCameraPatcher.authorizationStatusSymbol,
            inImage: DSCCameraPatcher.Family.avfAuthorization.imagePath
        )
        try chunks.write(at: avf, ARM64.nop)
        try DSCCodeSignature.reattestRecordedWrites(in: chunks, log: nil)

        let before = try CameraFixture.digests(of: clone)

        #expect(throws: PatcherError.self) {
            _ = try DSCCameraPatcher.applyAll(chunksDirectory: clone, log: nil)
        }

        let after = try CameraFixture.digests(of: clone)
        let changed = before.keys.filter { after[$0] != before[$0] }.sorted()
        #expect(changed.isEmpty, "a failed run wrote to \(changed.joined(separator: ", "))")
        print(
            changed.isEmpty
                ? "[camera failure] applyAll threw and wrote nothing — \(before.count) files unchanged"
                : "[camera failure] applyAll threw AFTER writing \(changed.joined(separator: ", "))"
        )
    }

    /// The reference's `--force`, and what it is a guard against.
    @Test("An unexpected prologue is refused unless forced")
    func unexpectedPrologueIsRefused() throws {
        _ = try #require(CameraFixture.pristine, CameraFixture.missing)

        let clone = try CameraFixture.cloneCache(named: "camera_force")
        defer { CameraFixture.discard(clone) }

        // Put something that is neither pacibsp nor the replacement at one of
        // the six entry points, without going through the patcher.
        let chunks = try DSCChunkSet(directory: clone)
        let resolver = try DSCSymbolResolver(chunks: chunks)
        let vma = try resolver.address(
            of: DSCCameraPatcher.authorizationStatusSymbol,
            inImage: DSCCameraPatcher.Family.avfAuthorization.imagePath
        )
        try chunks.write(at: vma, ARM64.nop)
        try DSCCodeSignature.reattestRecordedWrites(in: chunks, log: nil)

        #expect(throws: PatcherError.self) {
            _ = try DSCCameraPatcher.applyAVFAuthorizationOnly(
                chunksDirectory: clone,
                log: nil
            )
        }

        var log: [String] = []
        let forced = try DSCCameraPatcher.applyAVFAuthorizationOnly(
            chunksDirectory: clone,
            force: true,
            log: { log.append($0) }
        )
        #expect(forced.siteCount == 1)
        #expect(forced.sites.first?.wasAlreadyPatched == false)
        #expect(log.contains { $0.contains("forced") })

        let fresh = try DSCChunkSet(directory: clone)
        let written = try fresh.bytesAtVMA(vma, length: 8)
        let expected = try DSCCameraPatcher.replacement(returning: 3)
        #expect(written == expected)
        print("[camera force] a nop prologue was refused, then accepted under force")
    }

    /// The prologue classifier decides whether a site may be written at all, so
    /// it is worth exercising away from the cache too — including the shape a
    /// byte comparison would get right only by coincidence.
    @Test("The prologue classifier reads instructions, not bytes")
    func prologueClassifierIsSemantic() throws {
        let disassembler = ARM64Disassembler()
        let replacement = try DSCCameraPatcher.replacement(returning: 3)

        func classify(_ bytes: Data, force: Bool = false) throws -> Bool {
            try DSCCameraPatcher.classifyPrologue(
                bytes,
                at: 0x1_0000_0000,
                symbol: "test",
                returning: 3,
                disassembler: disassembler,
                force: force,
                log: nil
            )
        }

        // pacibsp — pristine, and not already patched.
        let pristinePrologue = try classify(ARM64.pacibsp + ARM64.nop)
        #expect(pristinePrologue == false)

        // The replacement itself — already patched.
        let ownOutput = try classify(replacement)
        #expect(ownOutput == true)

        // The *other* family's replacement returns a different constant, so it
        // is not this family's output and must not pass as one.
        let otherFamily = try DSCCameraPatcher.replacement(returning: 0)
        #expect(throws: PatcherError.self) { _ = try classify(otherFamily) }

        // `mov w0, #3` without the `ret` is not the replacement either.
        let movOnly = try #require(ARM64Encoder.encodeMovzW(rd: 0, imm16: 3)) + ARM64.nop
        #expect(throws: PatcherError.self) { _ = try classify(movOnly) }

        // And `mov x0, #3; ret` writes the 64-bit register, which is a
        // different instruction with the same shape.
        let wrongWidth = try #require(ARM64Encoder.encodeMovzX(rd: 0, imm16: 3)) + ARM64.ret
        #expect(throws: PatcherError.self) { _ = try classify(wrongWidth) }

        // Under force, all of them are accepted and none is "already patched".
        for bytes in [movOnly, wrongWidth, ARM64.nop + ARM64.nop] {
            let forced = try classify(bytes, force: true)
            #expect(forced == false)
        }
        print("[camera prologue] pacibsp, replacement, near-misses and force all classified")
    }

    /// A cache with no `.symbols` side file cannot resolve an ObjC method, and
    /// has to say so rather than reporting six renamed symbols.
    @Test("A cache without local symbols fails loudly")
    func missingLocalSymbolsFailsLoudly() throws {
        _ = try #require(CameraFixture.pristine, CameraFixture.missing)

        let clone = try CameraFixture.cloneCache(named: "camera_no_symbols")
        defer { CameraFixture.discard(clone) }
        try FileManager.default.removeItem(
            at: clone.appendingPathComponent("dyld_shared_cache_arm64e.symbols")
        )

        #expect(throws: DSCError.self) {
            _ = try DSCCameraPatcher.applyAll(chunksDirectory: clone, dryRun: true, log: nil)
        }
        print("[camera symbols] a cache with no .symbols table is refused, not silently empty")
    }
}

// DSCCameraPatcherTests.swift — Parity gate for the camera DSC patcher.
//
// The claim these tests exist to defend is narrow and checkable: running
// `scripts/patchers/cfw_patch_camera_dsc.py` on one clone of the real shared
// cache and `DSCCameraPatcher` on another leaves the two clones byte for byte
// identical, across all 79 chunk files — patched instructions, rewritten code
// slots and everything neither touched. Nothing here asserts against a number
// this repo wrote down once; the Python is run for real and its output is the
// reference.
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
        ProcessInfo.processInfo.environment["VPHONE_DSC_SCRATCH"]
            .map { URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vphone-dsc-camera")
    }

    /// The project venv, which is where the reference Python lives.
    static var python: URL? {
        let url = repoRoot.appendingPathComponent(".venv/bin/python3")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// `ipsw`, which the reference Python shells out to for symbol resolution.
    /// The Swift port does not need it; running the reference does.
    static var ipswDirectory: String? {
        for candidate in ["/opt/homebrew/bin", "/usr/local/bin"]
            where FileManager.default.isExecutableFile(atPath: candidate + "/ipsw")
        {
            return candidate
        }
        return nil
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

// MARK: - The reference Python, run for real

private enum CameraReference {
    /// Run `cfw_patch_camera_dsc.py` over `cache`, exactly as
    /// `patch_camera_userland.sh dsc` does.
    @discardableResult
    static func run(on cache: URL, extraArguments: [String] = []) throws -> CameraSubprocess.Result {
        let python = try #require(CameraFixture.python, "project venv is required for the cross-check")
        let ipswDirectory = try #require(
            CameraFixture.ipswDirectory,
            "`ipsw` is required to run the reference Python (the Swift port does not use it)"
        )
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = ipswDirectory + ":/usr/bin:/bin:/usr/sbin:/sbin"
        let result = try CameraSubprocess.run(
            executable: python,
            arguments: [
                CameraFixture.repoRoot
                    .appendingPathComponent("scripts/patchers/cfw_patch_camera_dsc.py").path,
                cache.path,
                cache.appendingPathComponent("dyld_shared_cache_arm64e").path,
            ] + extraArguments,
            environment: environment
        )
        #expect(result.status == 0, "reference Python failed: \(result.stderr)")
        return result
    }

    /// The sites the reference reported, as `symbol -> "before → after"`.
    ///
    /// Parsed off the two lines it prints per site rather than off a count, so
    /// a run that silently patched five of six cannot pass as six.
    static func sites(in output: String) -> [String: (before: String, after: String)] {
        var sites: [String: (String, String)] = [:]
        var pendingSymbol: String?
        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("+["), let at = trimmed.range(of: "  @ 0x") {
                pendingSymbol = String(trimmed[trimmed.startIndex ..< at.lowerBound])
                continue
            }
            if let symbol = pendingSymbol, trimmed.contains("→") {
                let halves = trimmed.components(separatedBy: "→")
                if halves.count == 2 {
                    sites[symbol] = (
                        halves[0].trimmingCharacters(in: .whitespaces),
                        halves[1].trimmingCharacters(in: .whitespaces)
                    )
                }
                pendingSymbol = nil
            }
        }
        return sites
    }

    /// `_sym_slug` from the reference module, for the six real symbols.
    static func symbolSlugs(for symbols: [String]) throws -> [String] {
        let python = try #require(CameraFixture.python)
        let result = try CameraSubprocess.run(
            executable: python,
            arguments: [
                "-c",
                """
                import json, sys
                sys.path.insert(0, sys.argv[1])
                from cfw_patch_camera_dsc import _sym_slug
                print(json.dumps([_sym_slug(s) for s in json.loads(sys.argv[2])]))
                """,
                CameraFixture.repoRoot.appendingPathComponent("scripts/patchers").path,
                String(decoding: try JSONSerialization.data(withJSONObject: symbols), as: UTF8.self),
            ]
        )
        #expect(result.status == 0, "python _sym_slug failed: \(result.stderr)")
        return try JSONDecoder().decode([String].self, from: Data(result.stdout.utf8))
    }

    /// What keystone assembles for a source string, through the module the
    /// patchers use.
    static func assemble(_ source: String) throws -> String {
        let python = try #require(CameraFixture.python)
        let result = try CameraSubprocess.run(
            executable: python,
            arguments: [
                "-c",
                """
                import sys
                sys.path.insert(0, sys.argv[1])
                from cfw_asm import asm
                print(asm(sys.argv[2]).hex())
                """,
                CameraFixture.repoRoot.appendingPathComponent("scripts/patchers").path,
                source,
            ]
        )
        #expect(result.status == 0, "keystone failed: \(result.stderr)")
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - The parity gate

@Suite(.serialized, .enabled(if: CameraFixture.runs, CameraFixture.skipReason))
struct DSCCameraPatcherParityTests {
    /// The gate. Two clones, two implementations, one byte-for-byte comparison
    /// across every chunk file in the cache.
    @Test("Swift and Python leave the real cache byte-identical")
    func swiftAndPythonAgreeByteForByte() throws {
        _ = try #require(CameraFixture.pristine, CameraFixture.missing)

        let swiftSide = try CameraFixture.cloneCache(named: "camera_swift")
        let pythonSide = try CameraFixture.cloneCache(named: "camera_python")
        defer { CameraFixture.discard(swiftSide, pythonSide) }

        // The reference, run for real.
        let referenceOutput = try CameraReference.run(on: pythonSide).stdout
        let referenceSites = CameraReference.sites(in: referenceOutput)
        #expect(
            referenceSites.count == 6,
            "the reference reported \(referenceSites.count) sites, not 6"
        )

        // The port.
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
        for site in result.sites {
            let theirs = try #require(
                referenceSites[site.symbol],
                "the reference did not report \(site.symbol)"
            )
            #expect(site.originalBytes.hex == theirs.before, "\(site.symbol) original bytes")
            #expect(site.patchedBytes.hex == theirs.after, "\(site.symbol) patched bytes")
            #expect(
                referenceOutput.contains("@ 0x\(String(site.vma, radix: 16, uppercase: true))"),
                "the reference did not report \(site.symbol) at the port's address"
            )
        }

        // And the caches themselves, whole.
        let mine = try CameraFixture.digests(of: swiftSide)
        let theirs = try CameraFixture.digests(of: pythonSide)
        #expect(mine.keys.sorted() == theirs.keys.sorted())
        var differing: [String] = []
        for (name, digest) in mine.sorted(by: { $0.key < $1.key })
            where theirs[name] != digest
        {
            differing.append(name)
        }
        #expect(differing.isEmpty, "chunks differ after patching: \(differing)")
        #expect(mine.count >= 79, "only \(mine.count) chunk files were compared")

        // The comparison is only worth anything if the two caches moved at all.
        let pristineDigests = try CameraFixture.digests(
            of: try #require(CameraFixture.pristine)
        )
        let changed = mine.filter { pristineDigests[$0.key] != $0.value }.keys.sorted()
        #expect(
            changed.count == 2,
            "expected both families to land in their own chunk; changed: \(changed)"
        )

        print("[camera parity] \(result.siteCount) sites, "
            + "\(result.reattestation?.updated.count ?? 0) slots rewritten, "
            + "\(mine.count) chunk files identical to the Python's")
        print("[camera parity] chunks that changed: \(changed.joined(separator: ", "))")
        for line in log where line.contains("re-attest: wrote") { print(line) }
    }

    /// The reference re-attests per family off bare addresses; this re-attests
    /// once at the end off recorded spans. Same pages on this cache — which is
    /// worth checking rather than assuming, because it is the only reason the
    /// two runs can come out identical.
    @Test("The port re-attests exactly the pages the reference does")
    func reattestedPagesMatchTheReference() throws {
        _ = try #require(CameraFixture.pristine, CameraFixture.missing)

        let swiftSide = try CameraFixture.cloneCache(named: "camera_pages_swift")
        let pythonSide = try CameraFixture.cloneCache(named: "camera_pages_python")
        defer { CameraFixture.discard(swiftSide, pythonSide) }

        let referenceOutput = try CameraReference.run(on: pythonSide).stdout
        var referencePages: Set<String> = []
        for rawLine in referenceOutput.split(separator: "\n") {
            let line = String(rawLine)
            guard line.contains("re-attest: wrote slot ") else { continue }
            let parts = line.components(separatedBy: "re-attest: wrote slot ")
            guard parts.count == 2 else { continue }
            let fields = parts[1].split(separator: " ")
            guard fields.count >= 3 else { continue }
            referencePages.insert("\(fields[2]):\(fields[0])")
        }
        #expect(!referencePages.isEmpty, "the reference re-attested nothing")

        let result = try DSCCameraPatcher.applyAll(chunksDirectory: swiftSide, log: nil)
        let minePages = Set(
            (result.reattestation?.updated ?? []).map {
                "\($0.chunkURL.lastPathComponent):\($0.pageIndex)"
            }
        )
        #expect(minePages == referencePages, "swift \(minePages.sorted()) vs python \(referencePages.sorted())")
        print("[camera pages] \(minePages.sorted().joined(separator: ", "))")
    }

    /// Patch ids feed `cfw_records`, which is what a captured reference is
    /// keyed on. A port that renames them writes records nothing lines up with.
    @Test("Patch ids match the reference's _sym_slug")
    func patchIDsMatchTheReference() throws {
        _ = try #require(CameraFixture.pristine, CameraFixture.missing)

        let symbols = DSCCameraPatcher.styleTransferSymbols
            + [DSCCameraPatcher.authorizationStatusSymbol]
        let theirs = try CameraReference.symbolSlugs(for: symbols)
        let mine = symbols.map(DSCCameraPatcher.symbolSlug)
        #expect(mine == theirs)
        #expect(
            mine.first == "NUStyleTransferProcessor_processWithInputs_arguments_output_error"
        )
        print("[camera slugs] \(mine.count) ids agreed, e.g. camera_dsc.nu_styletransfer.\(mine[0])")
    }

    /// Both replacements come out of the Keystone-checked encoders, and both
    /// have to be what keystone itself assembles.
    @Test("Both replacements are the bytes keystone assembles")
    func replacementsMatchKeystone() throws {
        _ = try #require(CameraFixture.python, "project venv is required for the cross-check")

        let styleTransfer = try DSCCameraPatcher.replacement(
            returning: DSCCameraPatcher.Family.neutrinoStyleTransfer.returnValue
        )
        let authorization = try DSCCameraPatcher.replacement(
            returning: DSCCameraPatcher.Family.avfAuthorization.returnValue
        )
        let keystoneStyleTransfer = try CameraReference.assemble("mov w0, #0\nret")
        let keystoneAuthorization = try CameraReference.assemble("mov w0, #3\nret")
        #expect(styleTransfer.hex == keystoneStyleTransfer)
        #expect(authorization.hex == keystoneAuthorization)
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

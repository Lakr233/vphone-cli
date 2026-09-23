// DSCIOMFBForceKernTests.swift — Parity for the IOMFB force-kern DSC patcher.
//
// There is no independent oracle for a patched dyld shared cache: `codesign -v`
// does not apply to a cache chunk, and nothing but the guest kernel reads the
// slot hashes. The only reference is `scripts/patchers/cfw_patch_iomfb_force_kern.py`,
// so the central test here runs THAT on one clone of the real cache, runs the
// Swift on a second clone, and compares the two byte for byte — every chunk,
// every code-directory slot, the `.symbols` side file, all of it. A port that
// writes a different number of sites, or the same number in different places,
// or re-attests a different set of pages, fails.
//
// The tests need the real cache. Point `VPHONE_DSC_PRISTINE` at a directory of
// `dyld_shared_cache_arm64e*` chunks, or leave the default
// `ipsws/ref_extract/dsc_pristine` in place.
//
// Without it they FAIL. There is no bare `return` anywhere below, because Swift
// Testing reports one as a pass — "all tests passed" would then be equally
// compatible with "the cache was never there". A machine that genuinely cannot
// carry the 6.7 GB fixture sets `VPHONE_DSC_FIXTURE_OPTIONAL=1`, which turns the
// failure into a visible skip.
//
// Nothing here writes into the pristine directory. Clones are made with
// `cp -c` — an APFS clone, so instant and near-free — into
// `ipsws/scratch_dsc_forcekern`, and removed again at the end.

@testable import FirmwarePatcher
import Foundation
import Testing

// MARK: - Fixture discovery

private enum ForceKernFixture {
    static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    static let imagePath =
        "/System/Library/PrivateFrameworks/IOMobileFramebuffer.framework/IOMobileFramebuffer"

    /// The read-only reference cache. Never written to.
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

    /// The suite runs unless the cache is absent *and* the caller opted out.
    static var runs: Bool { pristine != nil || !isOptional }

    static let missing: Comment = """
    the real arm64e shared cache is required — put it at \
    ipsws/ref_extract/dsc_pristine, point VPHONE_DSC_PRISTINE at it, or set \
    VPHONE_DSC_FIXTURE_OPTIONAL=1 to skip these tests instead of failing
    """

    static let skipReason: Comment =
        "VPHONE_DSC_FIXTURE_OPTIONAL=1 and no dyld_shared_cache_arm64e fixture present"

    /// Where clones are made. Deliberately NOT under `ipsws/ref_extract`: that
    /// tree is the pristine reference the whole suite compares against, and a
    /// clone left behind in it is a corrupted reference for every later run.
    /// Same filesystem, so `cp -c` is still a clone rather than 6.7 GB of I/O.
    static var scratchRoot: URL {
        ProcessInfo.processInfo.environment["VPHONE_DSC_SCRATCH"]
            .map { URL(fileURLWithPath: $0) }
            ?? repoRoot.appendingPathComponent("ipsws/scratch_dsc_forcekern")
    }

    /// The project venv, which is where the reference Python lives.
    static var python: URL? {
        let url = repoRoot.appendingPathComponent(".venv/bin/python3")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    static var cfwDriver: URL {
        repoRoot.appendingPathComponent("scripts/patchers/cfw.py")
    }

    static func cloneCache(named name: String) throws -> URL {
        guard let pristine else { throw CocoaError(.fileNoSuchFile) }
        let destination = scratchRoot.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.createDirectory(
            at: destination,
            withIntermediateDirectories: true
        )
        let result = try ForceKernShell.run(
            executable: URL(fileURLWithPath: "/bin/cp"),
            arguments: ["-c", "-R"]
                + (try FileManager.default.contentsOfDirectory(atPath: pristine.path))
                .sorted()
                .map { pristine.appendingPathComponent($0).path }
                + [destination.path]
        )
        guard result.status == 0 else {
            throw CocoaError(.fileWriteUnknown)
        }
        return destination
    }

    /// Drop clones, and the scratch root with them once the last one is gone —
    /// the working tree has to be left as it was found.
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

private enum ForceKernShell {
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
        // Drain before waiting: a full pipe buffer would deadlock the patcher's
        // per-site log.
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Result(
            status: process.terminationStatus,
            stdout: String(decoding: outData, as: UTF8.self),
            stderr: String(decoding: errData, as: UTF8.self)
        )
    }

    /// Run the reference patcher through the CLI the install scripts use.
    static func runReference(on chunks: URL, dryRun: Bool) throws -> Result {
        guard let python = ForceKernFixture.python else { throw CocoaError(.fileNoSuchFile) }
        return try run(
            executable: python,
            arguments: [
                ForceKernFixture.cfwDriver.path,
                "patch-iomfb-force-kern",
                chunks.path,
            ] + (dryRun ? ["--dry-run"] : [])
        )
    }

    /// `N` out of the reference's `complete: N newly forced, M already -> _kern_*`.
    static func newlyForced(in output: String) -> Int? {
        guard let line = output.split(separator: "\n").last(where: {
            $0.contains("IOMFB force-kern complete:")
        }) else { return nil }
        let after = line.split(separator: ":").last ?? ""
        return Int(after.trimmingCharacters(in: .whitespaces).split(separator: " ").first ?? "")
    }

    /// Byte-compare two cache directories, file by file. Returns the paths that
    /// differ, plus the count compared.
    static func diffTrees(_ left: URL, _ right: URL) throws -> (differing: [String], compared: Int) {
        let manager = FileManager.default
        let leftNames = try manager.contentsOfDirectory(atPath: left.path).sorted()
        let rightNames = try manager.contentsOfDirectory(atPath: right.path).sorted()
        guard leftNames == rightNames else {
            return (Array(Set(leftNames).symmetricDifference(rightNames)).sorted(), 0)
        }
        var differing: [String] = []
        for name in leftNames {
            let result = try run(
                executable: URL(fileURLWithPath: "/usr/bin/cmp"),
                arguments: [
                    "-s",
                    left.appendingPathComponent(name).path,
                    right.appendingPathComponent(name).path,
                ]
            )
            if result.status != 0 { differing.append(name) }
        }
        return (differing, leftNames.count)
    }
}

// MARK: - Parity against the reference Python

@Suite(.serialized, .enabled(if: ForceKernFixture.runs, ForceKernFixture.skipReason))
struct DSCIOMFBForceKernParityTests {
    /// The one test that decides whether this port is done.
    @Test("Python and Swift force-kern produce byte-identical caches")
    func matchesReferenceByteForByte() throws {
        _ = try #require(ForceKernFixture.pristine, ForceKernFixture.missing)
        try #require(
            ForceKernFixture.python != nil,
            "project venv is required to run the reference patcher"
        )

        let pythonClone = try ForceKernFixture.cloneCache(named: "python")
        let swiftClone = try ForceKernFixture.cloneCache(named: "swift")
        defer { ForceKernFixture.discard(pythonClone, swiftClone) }

        // Both clones start identical — otherwise the comparison below proves
        // nothing at all.
        let before = try ForceKernShell.diffTrees(pythonClone, swiftClone)
        #expect(before.differing.isEmpty, "clones differed before patching: \(before.differing)")
        #expect(before.compared > 1)

        let reference = try ForceKernShell.runReference(on: pythonClone, dryRun: false)
        #expect(reference.status == 0, "reference patcher failed:\n\(reference.stderr)")
        let referenceSites = try #require(
            ForceKernShell.newlyForced(in: reference.stdout),
            "could not read the reference's site count from:\n\(reference.stdout)"
        )

        let outcome = try DSCIOMFBForceKernPatcher.patch(
            chunksDirectory: swiftClone,
            log: nil
        )

        print("[force-kern] python wrote \(referenceSites) site(s), swift wrote \(outcome.writtenSiteCount)")
        #expect(
            outcome.writtenSiteCount == referenceSites,
            "swift wrote \(outcome.writtenSiteCount) sites, python wrote \(referenceSites)"
        )
        #expect(referenceSites > 0, "the reference patched nothing — the fixture is not force-kernable")

        let after = try ForceKernShell.diffTrees(pythonClone, swiftClone)
        #expect(
            after.differing.isEmpty,
            "patched clones differ in: \(after.differing)"
        )
        #expect(after.compared == before.compared)
        print("[force-kern] \(after.compared) file(s) compared byte for byte, all identical")

        // And the other direction: the reference must recognise the Swift's
        // output as already forced. That is a sharper check than the byte
        // comparison — it says the branch this port encodes is the one the
        // reference's own idempotence test decodes and accepts, rather than
        // some other encoding that happens to hash the same.
        let reRun = try ForceKernShell.runReference(on: swiftClone, dryRun: false)
        #expect(reRun.status == 0, "reference re-run failed:\n\(reRun.stderr)")
        #expect(
            ForceKernShell.newlyForced(in: reRun.stdout) == 0,
            "the reference re-forced sites the Swift had already written:\n\(reRun.stdout)"
        )
        let afterReRun = try ForceKernShell.diffTrees(pythonClone, swiftClone)
        #expect(afterReRun.differing.isEmpty, "the reference's re-run changed bytes")
    }

    /// The reference's own idempotence claim, applied across implementations:
    /// the Swift run over a cache the Python already patched must write nothing
    /// and leave every byte alone.
    @Test("Swift is a no-op on a cache the Python already forced")
    func swiftIsIdempotentOverPythonOutput() throws {
        _ = try #require(ForceKernFixture.pristine, ForceKernFixture.missing)
        try #require(ForceKernFixture.python != nil, "project venv is required")

        let clone = try ForceKernFixture.cloneCache(named: "idempotence")
        defer { ForceKernFixture.discard(clone) }

        let reference = try ForceKernShell.runReference(on: clone, dryRun: false)
        #expect(reference.status == 0, "reference patcher failed:\n\(reference.stderr)")

        let hashesBefore = try Self.chunkDigests(of: clone)
        let second = try DSCIOMFBForceKernPatcher.patch(chunksDirectory: clone, log: nil)

        #expect(second.writtenSiteCount == 0, "a second pass rewrote \(second.writtenSiteCount) site(s)")
        #expect(second.reattestation == nil, "a second pass re-attested pages it did not dirty")
        #expect(!second.alreadyForced.isEmpty)
        let hashesAfter = try Self.chunkDigests(of: clone)
        #expect(hashesAfter == hashesBefore, "a no-op run changed bytes")
    }

    /// A dry run must classify everything and touch nothing.
    @Test("A dry run reports the same sites and writes no bytes")
    func dryRunWritesNothing() throws {
        _ = try #require(ForceKernFixture.pristine, ForceKernFixture.missing)

        let clone = try ForceKernFixture.cloneCache(named: "dryrun")
        defer { ForceKernFixture.discard(clone) }

        let hashesBefore = try Self.chunkDigests(of: clone)
        let dry = try DSCIOMFBForceKernPatcher.patch(
            chunksDirectory: clone,
            dryRun: true,
            log: nil
        )
        #expect(dry.writtenSiteCount > 0, "the dry run classified no forcible site")
        #expect(dry.records.isEmpty)
        #expect(dry.reattestation == nil)
        let hashesAfter = try Self.chunkDigests(of: clone)
        #expect(hashesAfter == hashesBefore, "a dry run wrote to the cache")

        let wet = try DSCIOMFBForceKernPatcher.patch(chunksDirectory: clone, log: nil)
        #expect(wet.writtenSiteCount == dry.writtenSiteCount)
    }

    /// SHA-256 of every chunk file, so "nothing changed" is checkable without
    /// keeping a second copy around.
    private static func chunkDigests(of directory: URL) throws -> [String: String] {
        var digests: [String: String] = [:]
        for name in try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted() {
            let result = try ForceKernShell.run(
                executable: URL(fileURLWithPath: "/usr/bin/shasum"),
                arguments: ["-a", "256", directory.appendingPathComponent(name).path]
            )
            guard result.status == 0 else { throw CocoaError(.fileReadUnknown) }
            digests[name] = String(result.stdout.prefix(64))
        }
        return digests
    }
}

// MARK: - Discovery and classification

@Suite(.serialized, .enabled(if: ForceKernFixture.runs, ForceKernFixture.skipReason))
struct DSCIOMFBForceKernDiscoveryTests {
    /// Discovery has to agree with the reference's, which reads the same image
    /// through `ipsw dyld symaddr`. Compared here without `ipsw`: the pairs the
    /// resolver finds are the pairs the reference logs.
    @Test("Every discovered pair matches the reference's, name and address")
    func discoveryMatchesReference() throws {
        let pristine = try #require(ForceKernFixture.pristine, ForceKernFixture.missing)
        try #require(ForceKernFixture.python != nil, "project venv is required")

        let resolver = try DSCSymbolResolver(
            mainCacheURL: pristine.appendingPathComponent("dyld_shared_cache_arm64e")
        )
        let entries = try DSCIOMFBForceKernPatcher.discoverEntryPoints(resolver: resolver)
        #expect(entries.count >= DSCIOMFBForceKernPatcher.requiredSuffixes.count)

        // The reference names every pair it considers in its dry-run log, as
        // either a `[+] <public> @ 0xVA: … -> 'b <kern>' (0xVA)` or a
        // `[=] <public> not a thin trampoline` line.
        let clone = try ForceKernFixture.cloneCache(named: "discovery")
        defer { ForceKernFixture.discard(clone) }
        let reference = try ForceKernShell.runReference(on: clone, dryRun: true)
        #expect(reference.status == 0, "reference dry run failed:\n\(reference.stderr)")

        var referencePairs: [String: UInt64] = [:]
        var referenceNames: Set<String> = []
        for line in reference.stdout.split(separator: "\n") {
            guard let name = line.split(separator: " ").first(where: {
                $0.hasPrefix(DSCIOMFBForceKernPatcher.publicPrefix)
            }) else { continue }
            referenceNames.insert(String(name))
            // "… @ 0x22AC0C1B0: …" — the public address it decided to rewrite.
            guard let at = line.range(of: " @ 0x") else { continue }
            let rest = line[at.upperBound...].prefix { $0.isHexDigit }
            if let address = UInt64(rest, radix: 16) { referencePairs[String(name)] = address }
        }

        let discovered = Set(entries.map(\.publicName))
        let disagreement = discovered.symmetricDifference(referenceNames).sorted()
        #expect(discovered == referenceNames, "discovery differs from the reference: \(disagreement)")
        for entry in entries {
            guard let referenceAddress = referencePairs[entry.publicName] else { continue }
            let mine = String(entry.publicAddress, radix: 16)
            let theirs = String(referenceAddress, radix: 16)
            #expect(
                referenceAddress == entry.publicAddress,
                "\(entry.publicName): swift 0x\(mine) vs reference 0x\(theirs)"
            )
        }
    }

    /// The three the reference refuses to ship without.
    @Test("The required entry points are present and forcible")
    func requiredEntryPointsAreForcible() throws {
        let pristine = try #require(ForceKernFixture.pristine, ForceKernFixture.missing)
        let chunks = try DSCChunkSet(directory: pristine)
        let resolver = try DSCSymbolResolver(chunks: chunks)
        let entries = try DSCIOMFBForceKernPatcher.discoverEntryPoints(resolver: resolver)

        let disassembler = ARM64Disassembler()
        for required in DSCIOMFBForceKernPatcher.requiredSuffixes {
            let entry = try #require(
                entries.first { $0.suffix == required },
                "no entry point discovered for \(required)"
            )
            let instructions = disassembler.disassemble(
                try chunks.bytesAtVMA(entry.publicAddress, length: 16),
                at: entry.publicAddress,
                count: 4
            )
            #expect(
                DSCIOMFBForceKernPatcher.isDispatchTrampoline(instructions),
                "\(entry.publicName) is not a thin dispatch trampoline"
            )
        }
    }

    /// The shape check has to be discriminating, not a rubber stamp: the
    /// reference leaves several entry points on the virt path on this cache, and
    /// so must this. A matcher that accepted everything would still pass the
    /// byte comparison only if it happened to agree — it does not, so pin it.
    @Test("Non-trampoline entry points are recognised and left alone")
    func nonTrampolinesAreLeftAlone() throws {
        let pristine = try #require(ForceKernFixture.pristine, ForceKernFixture.missing)

        let clone = try ForceKernFixture.cloneCache(named: "shapes")
        defer { ForceKernFixture.discard(clone) }
        let dry = try DSCIOMFBForceKernPatcher.patch(
            chunksDirectory: clone,
            dryRun: true,
            log: nil
        )

        #expect(!dry.notTrampolines.isEmpty, "every discovered entry point matched the shape")
        #expect(dry.forced.count + dry.notTrampolines.count + dry.alreadyForced.count == dry.sites.count)

        // And each rejection is a real one: its first instruction is not the
        // trampoline's `cbz x0`, or the three that follow are not the load,
        // null-check and tail-call.
        let chunks = try DSCChunkSet(directory: pristine)
        let disassembler = ARM64Disassembler()
        for site in dry.notTrampolines {
            let instructions = disassembler.disassemble(
                try chunks.bytesAtVMA(site.entry.publicAddress, length: 16),
                at: site.entry.publicAddress,
                count: 4
            )
            #expect(!DSCIOMFBForceKernPatcher.isDispatchTrampoline(instructions))
            print("[force-kern] left on virt: \(site.entry.publicName) — \(site.originalDisassembly)")
        }
    }

    /// Each written site is a 4-byte `b` at the public entry point, aimed at the
    /// kern sibling — checked from the record the patcher emits, which is what
    /// the record-comparison harness consumes.
    @Test("Every record is a four-byte branch to the paired kern implementation")
    func recordsDescribeTheBranches() throws {
        _ = try #require(ForceKernFixture.pristine, ForceKernFixture.missing)

        let clone = try ForceKernFixture.cloneCache(named: "records")
        defer { ForceKernFixture.discard(clone) }
        let outcome = try DSCIOMFBForceKernPatcher.patch(chunksDirectory: clone, log: nil)

        #expect(outcome.records.count == outcome.writtenSiteCount)
        let chunks = try DSCChunkSet(directory: clone)
        let disassembler = ARM64Disassembler()
        for record in outcome.records {
            #expect(record.patchID.hasPrefix("\(DSCIOMFBForceKernPatcher.recordGroup)."))
            #expect(record.patchedBytes.count == 4)
            #expect(record.originalBytes.count == 4)
            #expect(record.originalBytes != record.patchedBytes)
            let address = try #require(record.virtualAddress)
            let instruction = try #require(
                disassembler.disassembleOne(
                    try chunks.bytesAtVMA(address, length: 4),
                    at: address
                )
            )
            #expect(instruction.mnemonic == "b")
        }
    }
}

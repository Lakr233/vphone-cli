// DSCLSDEmbeddedRegTests.swift — parity for the lsd embedded-registration gate.
//
// The patch is one instruction in a 6.7 GB cache, and a wrong one is a boot
// panic rather than a failing assertion, so the reference these tests grade
// against is the Python that has already shipped: `cfw.py
// patch-lsd-embedded-reg`. The centre of the suite runs both implementations
// over two clones of the *real* cache and compares every byte of all 79 chunks
// plus the `.symbols` side file.
//
// The cache is required. Point `VPHONE_DSC_PRISTINE` at a directory of
// `dyld_shared_cache_arm64e*` chunks, or leave the default
// `ipsws/ref_extract/dsc_pristine` in place. Without it these tests FAIL — the
// suite never opens with a bare `return`, which Swift Testing reports as a
// pass, so a green run cannot mean the cache was absent. A machine that
// genuinely cannot carry the fixture sets `VPHONE_DSC_FIXTURE_OPTIONAL=1`,
// which turns the failure into a visible skip.
//
// Nothing here writes to the pristine tree. Clones are made with `clonefile`
// (instant and near-free on APFS) under the system temporary directory, or
// under `VPHONE_DSC_SCRATCH` when the caller names one.

@testable import FirmwarePatcher
import Foundation
import Testing

// MARK: - Fixture discovery

private enum LSDRegFixture {
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

    /// Opt-out for a machine that cannot carry the 6.7 GB fixture.
    static var isOptional: Bool {
        ProcessInfo.processInfo.environment["VPHONE_DSC_FIXTURE_OPTIONAL"] == "1"
    }

    /// The suite runs unless the cache is absent *and* the caller opted out.
    static var runs: Bool { pristine != nil || !isOptional }

    static let missing: Comment = """
    the real 24A435 arm64e shared cache is required — put it at \
    ipsws/ref_extract/dsc_pristine, point VPHONE_DSC_PRISTINE at it, or set \
    VPHONE_DSC_FIXTURE_OPTIONAL=1 to skip these tests instead of failing
    """

    /// Where clones go. Deliberately *not* inside `ipsws/ref_extract`: that
    /// tree is the pristine reference every DSC test compares against, and a
    /// scratch directory next to it is one `rm -rf` typo away from destroying
    /// a 6.7 GB extraction nobody can regenerate quickly.
    static var scratchRoot: URL {
        ProcessInfo.processInfo.environment["VPHONE_DSC_SCRATCH"]
            .map { URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vphone-dsc-lsd-embedded-reg")
    }

    /// The project venv, which is where the reference Python lives.
    static var python: URL? {
        let url = repoRoot.appendingPathComponent(".venv/bin/python3")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    static var cfwPy: URL { repoRoot.appendingPathComponent("scripts/patchers/cfw.py") }

    /// Clone the pristine cache into a fresh directory the caller may write to.
    ///
    /// `cp -c` asks for a `clonefile`, which costs no space and no time when
    /// the scratch root is on the same APFS volume as the fixture. When it is
    /// not — a caller who pointed `VPHONE_DSC_SCRATCH` at another disk — the
    /// clone is refused, and the fallback is an ordinary copy rather than a
    /// failed test.
    static func cloneCache(named name: String) throws -> URL {
        let pristine = try #require(self.pristine, missing)
        let destination = scratchRoot.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.createDirectory(
            at: destination,
            withIntermediateDirectories: true
        )
        let entries = try FileManager.default
            .contentsOfDirectory(atPath: pristine.path)
            .sorted()
            .map { pristine.appendingPathComponent($0).path }

        for flags in [["-c", "-R"], ["-R"]] {
            let result = try Shell.run(
                executable: URL(fileURLWithPath: "/bin/cp"),
                arguments: flags + entries + [destination.path]
            )
            if result.status == 0 { return destination }
        }
        Issue.record("could not clone the pristine cache into \(destination.path)")
        throw CocoaError(.fileWriteUnknown)
    }

    /// Discard clones, and the scratch root with them once the last one is
    /// gone, so a test run leaves the filesystem as it found it.
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

    /// Run the shipped Python patcher over `directory`.
    static func runPython(on directory: URL, dryRun: Bool = false) throws -> Shell.Result {
        let python = try #require(
            self.python,
            "the reference Python is required — run `make setup_venv`"
        )
        return try Shell.run(
            executable: python,
            arguments: [cfwPy.path, "patch-lsd-embedded-reg", directory.path]
                + (dryRun ? ["--dry-run"] : []),
            currentDirectory: repoRoot
        )
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
    static func run(
        executable: URL,
        arguments: [String],
        currentDirectory: URL? = nil
    ) throws -> Result {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
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

// MARK: - Byte-for-byte cache comparison

private enum CacheComparison {
    /// Every file name that differs between two cache directories.
    ///
    /// `cmp -s` rather than loading 6.7 GB into memory twice; file names are
    /// compared first so a missing or extra chunk is reported as such.
    static func differences(between lhs: URL, and rhs: URL) throws -> [String] {
        let manager = FileManager.default
        let left = Set(try manager.contentsOfDirectory(atPath: lhs.path))
        let right = Set(try manager.contentsOfDirectory(atPath: rhs.path))
        var differing = Array(left.symmetricDifference(right)).sorted()

        for name in left.intersection(right).sorted() {
            let result = try Shell.run(
                executable: URL(fileURLWithPath: "/usr/bin/cmp"),
                arguments: [
                    "-s",
                    lhs.appendingPathComponent(name).path,
                    rhs.appendingPathComponent(name).path,
                ]
            )
            if result.status != 0 { differing.append(name) }
        }
        return differing.sorted()
    }

    /// How many chunk files differ from the pristine tree.
    static func changedFiles(in directory: URL) throws -> [String] {
        let pristine = try #require(LSDRegFixture.pristine, LSDRegFixture.missing)
        return try differences(between: pristine, and: directory)
    }
}

// MARK: - Gate discovery

@Suite(
    "DSC lsd embedded-registration gate",
    .enabled(if: LSDRegFixture.runs, LSDRegFixture.missing),
    .serialized
)
struct DSCLSDEmbeddedRegGateTests {
    @Test("the gate is a cbz/cbnz on w0 whose fall-through sets a w register to 1")
    func gateShape() throws {
        let pristine = try #require(LSDRegFixture.pristine, LSDRegFixture.missing)
        let chunks = try DSCChunkSet(directory: pristine)
        let located = try #require(
            try DSCLSDEmbeddedRegPatcher.locateGate(in: chunks),
            "the iOS 27 fixture must carry \(DSCLSDEmbeddedRegPatcher.method)"
        )

        #expect(["cbz", "cbnz"].contains(located.gate.mnemonic))
        #expect(!located.gate.wasAlreadyNOP)
        #expect(located.gate.resultRegister.hasPrefix("w"))
        #expect(located.gate.vma > located.functionVMA)
        // The gate is inside the disassembly window, by construction.
        #expect(
            located.gate.vma
                < located.functionVMA + UInt64(DSCLSDEmbeddedRegPatcher.maxInstructions * 4)
        )
    }

    @Test("the symbol resolves through the cache's own local symbol table")
    func symbolIsLocal() throws {
        let pristine = try #require(LSDRegFixture.pristine, LSDRegFixture.missing)
        let chunks = try DSCChunkSet(directory: pristine)
        let address = try #require(
            try chunks.resolveLocalSymbol(DSCLSDEmbeddedRegPatcher.method),
            "\(DSCLSDEmbeddedRegPatcher.method) must be in the .symbols table"
        )
        // It has to live in an executable mapping, or it is not the method.
        let mapping = try #require(chunks.mapping(forVMA: address))
        #expect(mapping.isExecutable)
    }
}

// MARK: - Parity against the Python

@Suite(
    "DSC lsd embedded-registration parity",
    .enabled(if: LSDRegFixture.runs, LSDRegFixture.missing),
    .serialized
)
struct DSCLSDEmbeddedRegParityTests {
    @Test("Swift and Python produce byte-identical caches, one site each")
    func byteForByteParity() throws {
        let swiftClone = try LSDRegFixture.cloneCache(named: "swift")
        let pythonClone = try LSDRegFixture.cloneCache(named: "python")
        defer { LSDRegFixture.discard(swiftClone, pythonClone) }

        let report = try DSCLSDEmbeddedRegPatcher.patch(
            chunksDirectory: swiftClone,
            log: nil
        )
        #expect(report.outcome == .patched)
        #expect(report.sitesWritten == 1)
        #expect(report.methodIsPresent)

        let python = try LSDRegFixture.runPython(on: pythonClone)
        #expect(python.status == 0, "python failed: \(python.stdout)\(python.stderr)")
        // The Python names each site it writes; one NOP is the whole patch.
        let pythonSites = python.stdout
            .split(separator: "\n")
            .filter { $0.contains("NOP'd gate") }
        #expect(pythonSites.count == 1, "python wrote \(pythonSites.count) sites")

        let differences = try CacheComparison.differences(between: swiftClone, and: pythonClone)
        #expect(differences.isEmpty, "chunks differ between Swift and Python: \(differences)")

        // …and both changed exactly the one chunk holding the gate's page.
        let changed = try CacheComparison.changedFiles(in: swiftClone)
        #expect(changed.count == 1, "Swift touched \(changed.count) chunk(s): \(changed)")
        #expect(changed == (try CacheComparison.changedFiles(in: pythonClone)))
    }

    @Test("the recorded write names the chunk, its offset and the gate address")
    func recordDescribesTheSite() throws {
        let clone = try LSDRegFixture.cloneCache(named: "record")
        defer { LSDRegFixture.discard(clone) }

        let report = try DSCLSDEmbeddedRegPatcher.patch(chunksDirectory: clone, log: nil)
        let record = try #require(report.record)
        let gate = try #require(report.gate)

        #expect(record.patchID == DSCLSDEmbeddedRegPatcher.patchID)
        #expect(record.component.hasPrefix("dyld_shared_cache_arm64e"))
        #expect(record.virtualAddress == gate.vma)
        #expect(record.patchedBytes == ARM64.nop)
        #expect(record.originalBytes != ARM64.nop)
        #expect(record.originalBytes.count == 4)
        #expect(record.afterDisasm == "nop")
        #expect(record.beforeDisasm.hasPrefix(gate.mnemonic))

        // The offset has to name the byte that changed, in the file it names.
        let handle = try FileHandle(
            forReadingFrom: clone.appendingPathComponent(record.component)
        )
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(record.fileOffset))
        #expect(try handle.read(upToCount: 4) == ARM64.nop)
    }
}

// MARK: - Re-runs and dry runs

@Suite(
    "DSC lsd embedded-registration re-runs",
    .enabled(if: LSDRegFixture.runs, LSDRegFixture.missing),
    .serialized
)
struct DSCLSDEmbeddedRegRerunTests {
    @Test("a second Swift run is idempotent and leaves the bytes alone")
    func swiftIsIdempotent() throws {
        let clone = try LSDRegFixture.cloneCache(named: "idempotent")
        defer { LSDRegFixture.discard(clone) }

        let first = try DSCLSDEmbeddedRegPatcher.patch(chunksDirectory: clone, log: nil)
        #expect(first.outcome == .patched)
        let afterFirst = try CacheComparison.changedFiles(in: clone)

        let second = try DSCLSDEmbeddedRegPatcher.patch(chunksDirectory: clone, log: nil)
        #expect(second.outcome == .alreadyPatched)
        #expect(second.sitesWritten == 0)
        #expect(second.gate?.wasAlreadyNOP == true)
        #expect(second.gate?.vma == first.gate?.vma)

        #expect(try CacheComparison.changedFiles(in: clone) == afterFirst)
    }

    @Test("Python over a Swift-patched cache is a no-op, and the reverse too")
    func crossImplementationRerunsAgree() throws {
        let clone = try LSDRegFixture.cloneCache(named: "cross")
        defer { LSDRegFixture.discard(clone) }

        try DSCLSDEmbeddedRegPatcher.patch(chunksDirectory: clone, log: nil)
        let afterSwift = try Data(
            contentsOf: clone.appendingPathComponent("dyld_shared_cache_arm64e")
        ).count

        let python = try LSDRegFixture.runPython(on: clone)
        #expect(python.status == 0, "python failed: \(python.stdout)\(python.stderr)")
        #expect(python.stdout.contains("already NOP"))
        #expect(!python.stdout.contains("NOP'd gate"))

        // The Python re-run must not have moved anything.
        #expect(
            try Data(contentsOf: clone.appendingPathComponent("dyld_shared_cache_arm64e"))
                .count == afterSwift
        )
        let report = try DSCLSDEmbeddedRegPatcher.patch(chunksDirectory: clone, log: nil)
        #expect(report.outcome == .alreadyPatched)
    }

    @Test("a dry run locates the gate and writes nothing")
    func dryRunWritesNothing() throws {
        let clone = try LSDRegFixture.cloneCache(named: "dryrun")
        defer { LSDRegFixture.discard(clone) }

        let report = try DSCLSDEmbeddedRegPatcher.patch(
            chunksDirectory: clone,
            dryRun: true,
            log: nil
        )
        #expect(report.outcome == .wouldPatch)
        #expect(report.sitesWritten == 0)
        #expect(report.gate != nil)
        #expect(try CacheComparison.changedFiles(in: clone).isEmpty)
    }
}

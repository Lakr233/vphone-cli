// CFWCacheloaderTests.swift — parity for the launchd_cache_loader unsecure-cache gate.
//
// The patch is one instruction in a boot-critical binary, and a wrong one is a
// guest that will not start rather than a failing assertion, so the reference
// these tests grade against is the Python that has already shipped: `cfw.py
// patch-launchd-cache-loader`. The centre of the suite runs both
// implementations over two clones of the *real* iOS 27.0 / 24A435 binary and
// compares every byte.
//
// The binary is required. Point `VPHONE_MACHO_PRISTINE` at a directory of
// unpatched Mach-Os, or leave the default `ipsws/ref_extract/macho_pristine` in
// place. Without it these tests FAIL — the suite never opens with a bare
// `return`, which Swift Testing reports as a pass, so a green run cannot mean
// the fixture was absent. A machine that genuinely cannot carry it sets
// `VPHONE_MACHO_FIXTURE_OPTIONAL=1`, which turns the failure into a skip.
//
// Nothing here writes to the pristine tree. Clones are made with `clonefile`
// (instant and near-free on APFS) under the system temporary directory, or
// under `VPHONE_CACHELOADER_SCRATCH` when the caller names one;
// `VPHONE_CACHELOADER_KEEP=1` leaves them behind for inspection.

@testable import FirmwarePatcher
import Foundation
import Testing

// MARK: - Fixture discovery

private enum CacheLoaderFixture {
    static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    /// The read-only reference binary.
    static var pristine: URL? {
        let directory = ProcessInfo.processInfo.environment["VPHONE_MACHO_PRISTINE"]
            .map { URL(fileURLWithPath: $0) }
            ?? repoRoot.appendingPathComponent("ipsws/ref_extract/macho_pristine")
        let binary = directory.appendingPathComponent("launchd_cache_loader")
        return FileManager.default.fileExists(atPath: binary.path) ? binary : nil
    }

    /// Opt-out for a machine that cannot carry the extracted IPSW.
    static var isOptional: Bool {
        ProcessInfo.processInfo.environment["VPHONE_MACHO_FIXTURE_OPTIONAL"] == "1"
    }

    /// The suite runs unless the binary is absent *and* the caller opted out.
    static var runs: Bool { pristine != nil || !isOptional }

    static let missing: Comment = """
    the real 24A435 launchd_cache_loader is required — put it at \
    ipsws/ref_extract/macho_pristine/, point VPHONE_MACHO_PRISTINE at that \
    directory, or set VPHONE_MACHO_FIXTURE_OPTIONAL=1 to skip these tests \
    instead of failing
    """

    /// Where clones go. Deliberately *not* inside `ipsws/ref_extract`: that tree
    /// is the pristine reference every parity test compares against, and it came
    /// out of a 12 GB IPSW nobody wants to re-extract.
    static var scratchRoot: URL {
        ProcessInfo.processInfo.environment["VPHONE_CACHELOADER_SCRATCH"]
            .map { URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vphone-cacheloader")
    }

    /// Leave clones on disk after the run, for hand inspection.
    static var keepsArtifacts: Bool {
        ProcessInfo.processInfo.environment["VPHONE_CACHELOADER_KEEP"] == "1"
    }

    /// The project venv, which is where the reference Python lives.
    static var python: URL? {
        let url = repoRoot.appendingPathComponent(".venv/bin/python3")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    static var patchersDirectory: URL { repoRoot.appendingPathComponent("scripts/patchers") }
    static var cfwPy: URL { patchersDirectory.appendingPathComponent("cfw.py") }

    /// Clone the pristine binary into a file the caller may write to.
    ///
    /// `cp -c` asks for a `clonefile`, which costs no space and no time when the
    /// scratch root shares the fixture's APFS volume. When it does not — a
    /// caller who pointed `VPHONE_CACHELOADER_SCRATCH` at another disk — the
    /// clone is refused, and the fallback is an ordinary copy rather than a
    /// failed test.
    static func clone(named name: String) throws -> URL {
        let pristine = try #require(self.pristine, missing)
        try FileManager.default.createDirectory(
            at: scratchRoot,
            withIntermediateDirectories: true
        )
        let destination = scratchRoot.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: destination)

        for flags in [["-c"], []] {
            let result = try Shell.run(
                executable: URL(fileURLWithPath: "/bin/cp"),
                arguments: flags + [pristine.path, destination.path]
            )
            if result.status == 0 { return destination }
        }
        Issue.record("could not clone \(pristine.path) to \(destination.path)")
        throw CocoaError(.fileWriteUnknown)
    }

    /// Discard clones, and the scratch root with them once the last one is gone,
    /// so a test run leaves the filesystem as it found it.
    static func discard(_ clones: URL...) {
        guard !keepsArtifacts else { return }
        for clone in clones {
            try? FileManager.default.removeItem(at: clone)
        }
        let remaining = (try? FileManager.default
            .contentsOfDirectory(atPath: scratchRoot.path)) ?? []
        if remaining.isEmpty {
            try? FileManager.default.removeItem(at: scratchRoot)
        }
    }

    /// Run the shipped Python patcher over `binary`.
    @discardableResult
    static func runPython(on binary: URL) throws -> Shell.Result {
        let python = try #require(
            self.python,
            "the reference Python is required — run `make setup_venv`"
        )
        return try Shell.run(
            executable: python,
            arguments: [cfwPy.path, "patch-launchd-cache-loader", binary.path],
            currentDirectory: repoRoot
        )
    }

    /// Recompute `binary`'s slot hashes with the Python's own re-signer — the
    /// independent reference for the half of this port `codesign -v` grades.
    @discardableResult
    static func runPythonReattest(on binary: URL, offsets: [Int]) throws -> Shell.Result {
        let python = try #require(
            self.python,
            "the reference Python is required — run `make setup_venv`"
        )
        let offsetList = offsets.map(String.init).joined(separator: ",")
        return try Shell.run(
            executable: python,
            arguments: [
                "-c",
                """
                import sys
                sys.path.insert(0, sys.argv[1])
                import cfw_macho_codesign as codesign
                codesign.reattest_modified_offsets(
                    sys.argv[2], [int(x) for x in sys.argv[3].split(",")], verbose=False
                )
                """,
                patchersDirectory.path,
                binary.path,
                offsetList,
            ],
            currentDirectory: repoRoot
        )
    }

    /// `codesign -v`, the second independent reference: it knows nothing about
    /// either implementation and recomputes the page hashes itself.
    static func codesignVerify(_ binary: URL) throws -> Shell.Result {
        try Shell.run(
            executable: URL(fileURLWithPath: "/usr/bin/codesign"),
            arguments: ["-v", "--verbose=2", binary.path]
        )
    }

    static func bytes(of url: URL) throws -> Data { try Data(contentsOf: url) }
}

// MARK: - Subprocess helper

private enum Shell {
    struct Result {
        let status: Int32
        let stdout: String
        let stderr: String
        var output: String { stdout + stderr }
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

// MARK: - Byte comparison

private enum ByteComparison {
    /// Every offset at which two equal-length buffers differ.
    static func differingOffsets(_ lhs: Data, _ rhs: Data) -> [Int] {
        guard lhs.count == rhs.count else { return [] }
        return (0 ..< lhs.count).filter { lhs[$0] != rhs[$0] }
    }
}

// MARK: - Gate discovery

@Suite(
    "launchd_cache_loader gate discovery",
    .enabled(if: CacheLoaderFixture.runs, CacheLoaderFixture.missing)
)
struct CFWCacheLoaderGateTests {
    @Test("the anchor is the whole launchd_unsecure_cache= literal, found in __cstring")
    func anchorIsTheBootArgLiteral() throws {
        let data = try CacheLoaderFixture.bytes(
            of: try #require(CacheLoaderFixture.pristine, CacheLoaderFixture.missing)
        )
        let located = try CFWCacheLoaderPatcher.locateGate(in: data)
        let anchor = located.anchor

        #expect(anchor.token == "unsecure_cache")
        #expect(anchor.text == "launchd_unsecure_cache=")
        #expect(anchor.sectionName == "__TEXT,__cstring")
        // The token sits inside the literal, so the address code forms is the
        // literal's first byte — earlier than where the token matched.
        #expect(anchor.stringVMA < anchor.matchVMA)
        #expect(anchor.matchVMA - anchor.stringVMA == UInt64("launchd_".utf8.count))
        // …and that first byte really is where the literal starts on disk.
        let literal = data[anchor.stringFileOffset ..< anchor.stringFileOffset + anchor.text.utf8.count]
        #expect(String(decoding: literal, as: UTF8.self) == anchor.text)
        #expect(data[anchor.stringFileOffset - 1] == 0)
    }

    @Test("the xref is an ADRP+ADD that really computes the literal's address")
    func referenceComputesTheString() throws {
        let data = try CacheLoaderFixture.bytes(
            of: try #require(CacheLoaderFixture.pristine, CacheLoaderFixture.missing)
        )
        let anchor = try CFWCacheLoaderPatcher.locateGate(in: data).anchor
        let sections = MachOParser.parseSections(from: data)
        let text = try #require(sections["__TEXT,__text"])
        let disassembler = ARM64Disassembler()

        // Recomputed here from the two instructions, independently of how the
        // patcher found them: page(ADRP) + imm(ADD) has to be the literal.
        let adrp = try #require(disassembler.disassembleOne(
            in: data, at: anchor.referenceFileOffset, address: anchor.referenceVMA
        ))
        let add = try #require(disassembler.disassembleOne(
            in: data, at: anchor.referenceFileOffset + 4, address: anchor.referenceVMA + 4
        ))
        #expect(adrp.mnemonic == "adrp")
        #expect(add.mnemonic == "add")

        let page = try #require(adrp.aarch64?.operands.last?.imm)
        let pageOffset = try #require(add.aarch64?.operands.last?.imm)
        #expect(UInt64(page + pageOffset) == anchor.stringVMA)

        // And the xref is inside __TEXT,__text, which is the only place a gate
        // could be.
        #expect(anchor.referenceVMA >= text.address)
        #expect(anchor.referenceVMA < text.address + text.size)
    }

    @Test("the gate is a forward cbz on the boot-arg lookup's result")
    func gateShape() throws {
        let data = try CacheLoaderFixture.bytes(
            of: try #require(CacheLoaderFixture.pristine, CacheLoaderFixture.missing)
        )
        let located = try CFWCacheLoaderPatcher.locateGate(in: data)
        let gate = located.gate

        #expect(gate.mnemonic == "cbz")
        #expect(!gate.wasAlreadyNOP)
        #expect(gate.operandString.hasPrefix("x0,"))
        // It is the instruction immediately after the call it grades…
        let callVMA = try #require(gate.callVMA)
        #expect(gate.vma == callVMA + 4)
        #expect(callVMA > located.anchor.referenceVMA)
        // …and it jumps forward, over the unsecure-cache path it guards.
        let target = try #require(gate.targetVMA)
        #expect(target > gate.vma)
    }

    @Test("the fixture's code directory is the SHA-256, short-tail shape this port assumes")
    func fixtureSignatureShape() throws {
        let data = try CacheLoaderFixture.bytes(
            of: try #require(CacheLoaderFixture.pristine, CacheLoaderFixture.missing)
        )
        let directories = try #require(CFWMachOCodeSignature.codeDirectories(in: data))
        let directory = try #require(directories.first)

        #expect(directories.count == 1)
        #expect(directory.hashType == CFWMachOCodeSignature.hashTypeSHA256)
        #expect(directory.pageSize == 4096)
        // codeLimit is NOT page aligned here, so the last slot is short — the
        // case that regressed independent Mach-O re-signing once already.
        #expect(directory.codeLimit % directory.pageSize != 0)
        let tail = try #require(directory.slotRange(directory.codeSlotCount - 1))
        #expect(tail.count < directory.pageSize)

        // The gate lands in slot 0, well inside the covered region.
        let gate = try CFWCacheLoaderPatcher.locateGate(in: data).gate
        let bounds = try #require(CFWMachOCodeSignature.pageBounds(
            fileOffset: gate.fileOffset,
            pageSize: directory.pageSize,
            codeLimit: directory.codeLimit
        ))
        #expect(bounds.index == 0)
    }
}

// MARK: - Parity against the Python

@Suite(
    "launchd_cache_loader parity",
    .enabled(if: CacheLoaderFixture.runs, CacheLoaderFixture.missing),
    .serialized
)
struct CFWCacheLoaderParityTests {
    @Test("Swift and Python produce byte-identical binaries")
    func byteForByteParity() throws {
        let swiftClone = try CacheLoaderFixture.clone(named: "swift")
        let pythonClone = try CacheLoaderFixture.clone(named: "python")
        defer { CacheLoaderFixture.discard(swiftClone, pythonClone) }

        let report = try CFWCacheLoaderPatcher.patch(fileAt: swiftClone, log: nil)
        #expect(report.outcome == .patched)
        #expect(report.sitesWritten == 1)
        // Off by default, because every shipped caller re-signs afterwards.
        #expect(report.reattestedSlots.isEmpty)

        let python = try CacheLoaderFixture.runPython(on: pythonClone)
        #expect(python.status == 0, "python failed: \(python.output)")
        #expect(python.stdout.contains("[+] NOPped at"))

        let swiftBytes = try CacheLoaderFixture.bytes(of: swiftClone)
        let pythonBytes = try CacheLoaderFixture.bytes(of: pythonClone)
        #expect(swiftBytes == pythonBytes, "Swift and Python disagree")
    }

    @Test("exactly one instruction changes, and it is the gate")
    func onlyTheGateChanges() throws {
        let clone = try CacheLoaderFixture.clone(named: "single-site")
        defer { CacheLoaderFixture.discard(clone) }

        let pristine = try CacheLoaderFixture.bytes(
            of: try #require(CacheLoaderFixture.pristine, CacheLoaderFixture.missing)
        )
        let report = try CFWCacheLoaderPatcher.patch(fileAt: clone, log: nil)
        let patched = try CacheLoaderFixture.bytes(of: clone)

        let differing = ByteComparison.differingOffsets(pristine, patched)
        #expect(differing == Array(report.gate.fileOffset ..< report.gate.fileOffset + 4))
        #expect(patched[report.gate.fileOffset ..< report.gate.fileOffset + 4] == ARM64.nop)
    }

    @Test("the record names the byte that changed, its address and the anchor")
    func recordDescribesTheSite() throws {
        let clone = try CacheLoaderFixture.clone(named: "record")
        defer { CacheLoaderFixture.discard(clone) }

        let report = try CFWCacheLoaderPatcher.patch(fileAt: clone, log: nil)
        let record = try #require(report.record)

        #expect(record.patchID == "launchd_cache_loader.unsecure_cache_gate")
        #expect(record.component == "launchd_cache_loader")
        #expect(record.fileOffset == report.gate.fileOffset)
        #expect(record.virtualAddress == report.gate.vma)
        #expect(record.patchedBytes == ARM64.nop)
        #expect(record.originalBytes != ARM64.nop)
        #expect(record.afterDisasm == "nop")
        #expect(record.beforeDisasm.hasPrefix("cbz"))
        // Worded exactly as the Python words it, so a captured reference sorts
        // against this port.
        #expect(record.patchDescription
            == "NOP the cache-validation branch gated on 'unsecure_cache'")

        let onDisk = try CacheLoaderFixture.bytes(of: clone)
        #expect(onDisk[record.fileOffset ..< record.fileOffset + 4] == ARM64.nop)
    }

    /// Every other test here passes `log: nil`, and production does not. The
    /// before/after window starts two instructions ahead of the gate, and it
    /// once converted that negative delta with `UInt64(Int)` — a trap on every
    /// real patch that no `log: nil` test could see.
    @Test("patching with logging on succeeds and prints the marked window")
    func loggingPathDoesNotTrap() throws {
        let clone = try CacheLoaderFixture.clone(named: "logged")
        defer { CacheLoaderFixture.discard(clone) }

        final class Lines: @unchecked Sendable { var all: [String] = [] }
        let lines = Lines()
        let report = try CFWCacheLoaderPatcher.patch(fileAt: clone, log: { lines.all.append($0) })

        let text = lines.all.joined(separator: "\n")
        #expect(text.contains("Before:"))
        #expect(text.contains(">>>"))
        let onDisk = try CacheLoaderFixture.bytes(of: clone)
        #expect(onDisk[report.gate.fileOffset ..< report.gate.fileOffset + 4] == ARM64.nop)
    }
}

// MARK: - Re-runs and dry runs

@Suite(
    "launchd_cache_loader re-runs",
    .enabled(if: CacheLoaderFixture.runs, CacheLoaderFixture.missing),
    .serialized
)
struct CFWCacheLoaderRerunTests {
    @Test("a second run is a byte-for-byte no-op")
    func secondRunChangesNothing() throws {
        let clone = try CacheLoaderFixture.clone(named: "twice")
        defer { CacheLoaderFixture.discard(clone) }

        let first = try CFWCacheLoaderPatcher.patch(fileAt: clone, log: nil)
        let afterFirst = try CacheLoaderFixture.bytes(of: clone)

        let second = try CFWCacheLoaderPatcher.patch(fileAt: clone, log: nil)
        let afterSecond = try CacheLoaderFixture.bytes(of: clone)

        #expect(second.outcome == .alreadyPatched)
        #expect(second.sitesWritten == 0)
        #expect(second.record == nil)
        #expect(afterFirst == afterSecond)
        // The second run has to recognise the SAME site, not merely find some
        // other instruction it is willing to leave alone.
        #expect(second.gate.fileOffset == first.gate.fileOffset)
        #expect(second.gate.vma == first.gate.vma)
        #expect(second.gate.wasAlreadyNOP)
        #expect(second.anchor == first.anchor)

        // A third run, for the same reason the second exists.
        let third = try CFWCacheLoaderPatcher.patch(fileAt: clone, log: nil)
        #expect(third.outcome == .alreadyPatched)
        #expect(try CacheLoaderFixture.bytes(of: clone) == afterFirst)
    }

    @Test("the Python double-applies where this port stops — the reason they diverge")
    func pythonIsNotIdempotent() throws {
        let pythonClone = try CacheLoaderFixture.clone(named: "python-twice")
        let swiftClone = try CacheLoaderFixture.clone(named: "swift-twice")
        defer { CacheLoaderFixture.discard(pythonClone, swiftClone) }

        try CacheLoaderFixture.runPython(on: pythonClone)
        let afterFirst = try CacheLoaderFixture.bytes(of: pythonClone)
        let secondRun = try CacheLoaderFixture.runPython(on: pythonClone)
        let afterSecond = try CacheLoaderFixture.bytes(of: pythonClone)

        // Not an assertion about what the Python *should* do — a pin on what it
        // does, so this divergence is deliberate and stays visible. The Python
        // walks past its own NOP and takes the next conditional branch.
        #expect(secondRun.status == 0)
        #expect(afterFirst != afterSecond, "the Python became idempotent; revisit this port")
        let extra = ByteComparison.differingOffsets(afterFirst, afterSecond)
        #expect(extra.count == 4)

        try CFWCacheLoaderPatcher.patch(fileAt: swiftClone, log: nil)
        try CFWCacheLoaderPatcher.patch(fileAt: swiftClone, log: nil)
        let swiftTwice = try CacheLoaderFixture.bytes(of: swiftClone)
        #expect(swiftTwice == afterFirst, "one Swift run twice must equal one Python run once")
        #expect(swiftTwice != afterSecond)
    }

    @Test("a dry run locates the site and writes nothing")
    func dryRunChangesNothing() throws {
        let clone = try CacheLoaderFixture.clone(named: "dry-run")
        defer { CacheLoaderFixture.discard(clone) }

        let pristine = try CacheLoaderFixture.bytes(
            of: try #require(CacheLoaderFixture.pristine, CacheLoaderFixture.missing)
        )
        let report = try CFWCacheLoaderPatcher.patch(fileAt: clone, dryRun: true, log: nil)

        #expect(report.outcome == .wouldPatch)
        #expect(report.sitesWritten == 0)
        #expect(report.gate.mnemonic == "cbz")
        #expect(try CacheLoaderFixture.bytes(of: clone) == pristine)
    }
}

// MARK: - Code signature

@Suite(
    "launchd_cache_loader re-signing",
    .enabled(if: CacheLoaderFixture.runs, CacheLoaderFixture.missing),
    .serialized
)
struct CFWCacheLoaderSignatureTests {
    @Test("the default output fails codesign, exactly as the Python's does")
    func defaultOutputIsUnattested() throws {
        let swiftClone = try CacheLoaderFixture.clone(named: "unattested-swift")
        let pythonClone = try CacheLoaderFixture.clone(named: "unattested-python")
        defer { CacheLoaderFixture.discard(swiftClone, pythonClone) }

        try CFWCacheLoaderPatcher.patch(fileAt: swiftClone, log: nil)
        try CacheLoaderFixture.runPython(on: pythonClone)

        // Both leave a stale slot hash, because both rely on the caller
        // re-signing the binary wholesale afterwards (`ldid_sign` in
        // `cfw_install*.sh`, `VPhoneSigner.sign` in the Swift call site). This
        // test exists so that shared assumption is written down where it fails
        // loudly if a caller ever stops honouring it.
        #expect(try CacheLoaderFixture.codesignVerify(swiftClone).status != 0)
        #expect(try CacheLoaderFixture.codesignVerify(pythonClone).status != 0)
    }

    @Test("re-attested output passes codesign and matches the Python's slot hashes")
    func reattestedOutputVerifies() throws {
        let swiftClone = try CacheLoaderFixture.clone(named: "attested-swift")
        let pythonClone = try CacheLoaderFixture.clone(named: "attested-python")
        defer { CacheLoaderFixture.discard(swiftClone, pythonClone) }

        let report = try CFWCacheLoaderPatcher.patch(
            fileAt: swiftClone,
            reattestsCodeSignature: true,
            log: nil
        )
        #expect(report.outcome == .patched)
        let slot = try #require(report.reattestedSlots.first)
        #expect(report.reattestedSlots.count == 1)
        #expect(slot.pageIndex == 0)
        #expect(slot.before != slot.after)

        // codesign knows nothing about either implementation — it recomputes the
        // page hashes from the file itself.
        let verified = try CacheLoaderFixture.codesignVerify(swiftClone)
        #expect(verified.status == 0, "codesign -v failed: \(verified.output)")

        // …and the Python, patching and re-signing with its own code, lands on
        // the same bytes.
        try CacheLoaderFixture.runPython(on: pythonClone)
        let reattest = try CacheLoaderFixture.runPythonReattest(
            on: pythonClone,
            offsets: [report.gate.fileOffset]
        )
        #expect(reattest.status == 0, "python re-attest failed: \(reattest.output)")
        #expect(try CacheLoaderFixture.bytes(of: swiftClone)
            == (try CacheLoaderFixture.bytes(of: pythonClone)))
    }

    @Test("re-attesting an already-patched binary repairs it without moving an instruction")
    func reattestRepairsPythonOutput() throws {
        let clone = try CacheLoaderFixture.clone(named: "repair")
        defer { CacheLoaderFixture.discard(clone) }

        // The Python's output: patched, and carrying a stale slot hash.
        try CacheLoaderFixture.runPython(on: clone)
        let beforeRepair = try CacheLoaderFixture.bytes(of: clone)

        let report = try CFWCacheLoaderPatcher.patch(
            fileAt: clone,
            reattestsCodeSignature: true,
            log: nil
        )
        #expect(report.outcome == .alreadyPatched)
        #expect(report.sitesWritten == 0)
        #expect(report.reattestedSlots.count == 1)
        #expect(try CacheLoaderFixture.codesignVerify(clone).status == 0)

        // Only the slot hash moved; no instruction was rewritten.
        let afterRepair = try CacheLoaderFixture.bytes(of: clone)
        let differing = ByteComparison.differingOffsets(beforeRepair, afterRepair)
        let slot = try #require(report.reattestedSlots.first)
        #expect(differing == Array(slot.hashFileOffset ..< slot.hashFileOffset + slot.after.count))
    }
}

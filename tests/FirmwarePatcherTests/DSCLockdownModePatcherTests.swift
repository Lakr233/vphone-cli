// DSCLockdownModePatcherTests.swift — Parity for the lockdown-mode DSC patch.
//
// The only independent reference for this patch is
// `scripts/patchers/cfw_patch_lockdown_mode.py`, driven exactly as
// `cfw_install.sh` drives it: `cfw.py patch-lockdown-mode <chunks_dir>`. So the
// central test here clones the real cache twice, runs the Python on one clone
// and `DSCLockdownModePatcher` on the other, and compares the two patched
// directories byte for byte — chunk bytes and re-attested code slots alike.
//
// The tests need the real cache. Point `VPHONE_DSC_PRISTINE` at a directory of
// `dyld_shared_cache_arm64e*` chunks, or leave the default
// `ipsws/ref_extract/dsc_pristine` in place.
//
// Without it they FAIL. They do not open with a bare `return` on a missing
// fixture: Swift Testing reports that as a pass, so "all tests passed" would be
// equally compatible with "no test touched a cache". A machine that genuinely
// cannot carry the 6.7 GB fixture sets `VPHONE_DSC_FIXTURE_OPTIONAL=1`, which
// turns the failure into a visible *skip*.
//
// Nothing here writes into the pristine directory, or anywhere else in the
// working tree. Clones are made with `clonefile` under the system temp
// directory — instant and near-free on APFS — and removed again.

import Capstone
@testable import FirmwarePatcher
import Foundation
import Testing

// MARK: - Fixture discovery

private enum LockdownFixture {
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
    /// suite reports as skipped; leave it unset and a missing cache is a
    /// failure, which is the only reading of "green" this patch can afford.
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

    static let skipReason: Comment =
        "VPHONE_DSC_FIXTURE_OPTIONAL=1 and no dyld_shared_cache_arm64e fixture present"

    /// The project venv, which is where the reference Python lives.
    static var python: URL? {
        let url = repoRoot.appendingPathComponent(".venv/bin/python3")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// `scripts/patchers/cfw.py`, the entry point `cfw_install.sh` calls.
    static var cfwCLI: URL { repoRoot.appendingPathComponent("scripts/patchers/cfw.py") }

    /// Where clones go. Deliberately outside the working tree: the reference
    /// cache's directory is what the whole DSC suite compares against, and a
    /// scratch clone has no business living inside it.
    static var scratchRoot: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("vphone-dsc-lockdown", isDirectory: true)
    }

    /// Clone the pristine cache into a fresh directory the caller may write to.
    ///
    /// `cp -c` is `clonefile(2)`: the copy shares the original's blocks until
    /// something writes to one, so this costs neither time nor 6.7 GB.
    static func cloneCache(named name: String) throws -> URL {
        let pristine = try #require(Self.pristine, missing)
        let destination = scratchRoot.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.createDirectory(
            at: destination,
            withIntermediateDirectories: true
        )
        let entries = try FileManager.default.contentsOfDirectory(atPath: pristine.path).sorted()
        let result = try Subprocess.run(
            executable: URL(fileURLWithPath: "/bin/cp"),
            arguments: ["-c", "-R"]
                + entries.map { pristine.appendingPathComponent($0).path }
                + [destination.path]
        )
        guard result.status == 0 else {
            Issue.record("clone failed: \(result.stderr)")
            throw CocoaError(.fileWriteUnknown)
        }
        return destination
    }

    /// Discard clones, and the scratch root with them once the last one is
    /// gone, so a test run leaves nothing behind.
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

// MARK: - The reference Python, driven the way the installer drives it

private enum PythonReference {
    struct Run {
        let stdout: String
        /// Sites the Python says it wrote, counted off its own log lines.
        let sitesWritten: Int
        /// Sites it reached at all — written, already patched, or (on a dry
        /// run) would-be-written.
        let sitesFound: Int
        /// The gate address it reported, if any.
        let gateVMA: UInt64?
        /// The block address it resolved, if any.
        let functionVMA: UInt64?
    }

    /// `cfw.py patch-lockdown-mode <chunks_dir> [--dry-run]`, which is the
    /// exact contract `cfw_install.sh` and `cfw-kit/lib/base_stages.sh` use.
    static func patchLockdownMode(directory: URL, dryRun: Bool) throws -> Run {
        let python = try #require(LockdownFixture.python, "project venv is required")
        let result = try Subprocess.run(
            executable: python,
            arguments: [LockdownFixture.cfwCLI.path, "patch-lockdown-mode", directory.path]
                + (dryRun ? ["--dry-run"] : [])
        )
        guard result.status == 0 else {
            Issue.record("cfw.py patch-lockdown-mode failed: \(result.stdout)\n\(result.stderr)")
            throw CocoaError(.fileReadUnknown)
        }
        let lines = result.stdout.split(separator: "\n").map(String.init)
        return Run(
            stdout: result.stdout,
            sitesWritten: lines.filter { $0.contains("wrote nop at 0x") }.count,
            sitesFound: lines.filter {
                $0.contains("wrote nop at 0x")
                    || $0.contains("would write nop at 0x")
                    || $0.contains("already patched at 0x")
            }.count,
            gateVMA: lines.compactMap { line in
                line.contains("gate @ 0x") ? hexAddress(after: "gate @ 0x", in: line) : nil
            }.first,
            functionVMA: lines.compactMap { line in
                line.contains("_block_invoke @ 0x")
                    ? hexAddress(after: "_block_invoke @ 0x", in: line) : nil
            }.first
        )
    }

    private static func hexAddress(after marker: String, in line: String) -> UInt64? {
        guard let range = line.range(of: marker) else { return nil }
        let digits = line[range.upperBound...].prefix { $0.isHexDigit }
        return UInt64(digits, radix: 16)
    }
}

// MARK: - Byte-for-byte directory comparison

private enum DirectoryComparison {
    /// Every file that differs between two cache directories, by name.
    ///
    /// Compared with `cmp(1)` per file rather than by digest, so a mismatch is
    /// reported as the first differing byte and not merely as "these hashes
    /// differ".
    static func differences(between lhs: URL, and rhs: URL) throws -> [String] {
        let manager = FileManager.default
        let left = try manager.contentsOfDirectory(atPath: lhs.path).sorted()
        let right = try manager.contentsOfDirectory(atPath: rhs.path).sorted()
        guard left == right else {
            return ["directory listings differ: \(left.count) vs \(right.count) entries"]
        }
        var differing: [String] = []
        for name in left {
            let result = try Subprocess.run(
                executable: URL(fileURLWithPath: "/usr/bin/cmp"),
                arguments: [
                    lhs.appendingPathComponent(name).path,
                    rhs.appendingPathComponent(name).path,
                ]
            )
            if result.status != 0 {
                differing.append("\(name): \(result.stdout)\(result.stderr)".trimmingCharacters(
                    in: .whitespacesAndNewlines
                ))
            }
        }
        return differing
    }

    /// A digest of every file in a cache directory, for before/after checks
    /// that only need to know whether anything moved.
    static func fingerprint(of directory: URL) throws -> [String: String] {
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        var digests: [String: String] = [:]
        for name in names {
            let result = try Subprocess.run(
                executable: URL(fileURLWithPath: "/sbin/md5"),
                arguments: ["-q", directory.appendingPathComponent(name).path]
            )
            digests[name] = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return digests
    }
}

// MARK: - Parity against the Python

@Suite(.serialized, .enabled(if: LockdownFixture.runs, LockdownFixture.skipReason))
struct DSCLockdownModeParityTests {
    /// The one that matters: same cache, both patchers, identical bytes out.
    @Test("Swift and Python produce byte-identical patched caches")
    func patchedCachesAreIdentical() throws {
        _ = try #require(LockdownFixture.pristine, LockdownFixture.missing)
        _ = try #require(LockdownFixture.python, "project venv is required for the cross-check")

        let pythonClone = try LockdownFixture.cloneCache(named: "python")
        let swiftClone = try LockdownFixture.cloneCache(named: "swift")
        defer { LockdownFixture.discard(pythonClone, swiftClone) }

        let reference = try PythonReference.patchLockdownMode(directory: pythonClone, dryRun: false)
        let outcome = try DSCLockdownModePatcher.patch(chunksDirectory: swiftClone, log: nil)

        #expect(outcome.verdict == .patched)
        #expect(outcome.sitesWritten == 1)
        #expect(reference.sitesWritten == 1)
        #expect(
            outcome.sitesWritten == reference.sitesWritten,
            "site counts must match: Swift \(outcome.sitesWritten), Python \(reference.sitesWritten)"
        )
        #expect(outcome.gateVMA == reference.gateVMA)
        #expect(outcome.functionVMA == reference.functionVMA)

        let differences = try DirectoryComparison.differences(between: pythonClone, and: swiftClone)
        #expect(differences.isEmpty, "patched caches differ: \(differences.joined(separator: "; "))")

        let fileCount = try FileManager.default
            .contentsOfDirectory(atPath: swiftClone.path).count
        print(
            "[lockdown] 1 site @ 0x"
                + String(outcome.gateVMA ?? 0, radix: 16, uppercase: true)
                + " — \(fileCount) files byte-identical to the Python's output"
        )
    }

    /// The write has to be covered by exactly one re-attested page, or the
    /// guest takes a `KERN_PROTECTION_FAILURE` the first time it faults the
    /// page in. The Python re-attests one slot here; so must this.
    @Test("The write is re-attested, and only the page it dirtied")
    func reattestationCoversTheWrite() throws {
        _ = try #require(LockdownFixture.pristine, LockdownFixture.missing)

        let clone = try LockdownFixture.cloneCache(named: "reattest")
        defer { LockdownFixture.discard(clone) }

        let outcome = try DSCLockdownModePatcher.patch(chunksDirectory: clone, log: nil)
        let reattestation = try #require(outcome.reattestation)
        #expect(reattestation.updated.count == 1)
        #expect(reattestation.isFullyAttested)
        #expect(reattestation.skipped.isEmpty)
    }

    /// A second pass over an installed cache is how this patch is actually met
    /// in the field — `cfw_install` re-runs. It must report a no-op rather than
    /// raise, and must not move a byte.
    @Test("A second run is a no-op on an already-patched cache")
    func secondRunIsANoOp() throws {
        _ = try #require(LockdownFixture.pristine, LockdownFixture.missing)

        let clone = try LockdownFixture.cloneCache(named: "idempotence")
        defer { LockdownFixture.discard(clone) }

        let first = try DSCLockdownModePatcher.patch(chunksDirectory: clone, log: nil)
        #expect(first.verdict == .patched)
        let afterFirst = try DirectoryComparison.fingerprint(of: clone)

        let second = try DSCLockdownModePatcher.patch(chunksDirectory: clone, log: nil)
        #expect(second.verdict == .alreadyPatched)
        #expect(second.sitesWritten == 0)
        #expect(second.sitesFound == 1)
        #expect(second.gateVMA == first.gateVMA)
        #expect(second.record == nil)

        let afterSecond = try DirectoryComparison.fingerprint(of: clone)
        #expect(afterFirst == afterSecond, "a no-op run still rewrote something")
    }

    /// The Python's dry run is the cheapest oracle for the reveal, and it runs
    /// against the pristine cache without touching it.
    @Test("Symbol and gate resolve to the same addresses as the Python")
    func revealMatchesTheReference() throws {
        let pristine = try #require(LockdownFixture.pristine, LockdownFixture.missing)
        _ = try #require(LockdownFixture.python, "project venv is required for the cross-check")

        let reference = try PythonReference.patchLockdownMode(directory: pristine, dryRun: true)
        #expect(reference.sitesWritten == 0, "a dry run must not write")
        #expect(reference.sitesFound == 1)

        let chunks = try DSCChunkSet(directory: pristine)
        let resolved = try DSCLockdownModePatcher.resolveBlockInvoke(in: chunks)
        let block = try #require(
            resolved,
            "the cache must carry an os_lockdown_mode_enabled block to compare against"
        )
        #expect(block.vma == reference.functionVMA)
        #expect(block.name == DSCLockdownModePatcher.symbolCandidates.first)

        let instructions = try DSCLockdownModePatcher.disassembleBlock(in: chunks, at: block.vma)
        let gate = try #require(DSCLockdownModePatcher.findErrorGate(instructions))
        #expect(gate.address == reference.gateVMA)
        #expect(gate.mnemonic == "b.eq")

        // The decode stops at the block's own return, not at the ceiling.
        #expect(instructions.count < DSCLockdownModePatcher.maxInstructions)
        let last = try #require(instructions.last)
        #expect(last.mnemonic == "ret" || last.mnemonic == "retab")
    }
}

// MARK: - What the gate search must and must not match

@Suite(.serialized, .enabled(if: LockdownFixture.runs, LockdownFixture.skipReason))
struct DSCLockdownModeGateTests {
    /// The real instruction stream, and the index of the real gate in it.
    private struct Stream {
        let instructions: [Instruction]
        let gateIndex: Int
        let comparisonIndex: Int
    }

    private func realStream() throws -> Stream {
        let pristine = try #require(LockdownFixture.pristine, LockdownFixture.missing)
        let chunks = try DSCChunkSet(directory: pristine)
        let resolved = try DSCLockdownModePatcher.resolveBlockInvoke(in: chunks)
        let block = try #require(resolved)
        let instructions = try DSCLockdownModePatcher.disassembleBlock(in: chunks, at: block.vma)
        let gate = try #require(DSCLockdownModePatcher.findErrorGate(instructions))
        let gateIndex = try #require(instructions.firstIndex { $0.address == gate.address })
        #expect(gateIndex > 0)
        return Stream(
            instructions: instructions,
            gateIndex: gateIndex,
            comparisonIndex: gateIndex - 1
        )
    }

    /// Rebuild an ADD/SUB-immediate instruction with a different `imm12`.
    ///
    /// The word comes from a real decoded `cmn` in the cache; only the
    /// documented `[21:10]` immediate field (see `ARM64Inst.addSubImm12`) is
    /// rewritten, so this is derived test data rather than a hand-written
    /// encoding.
    private func word(of insn: Instruction, withImmediate imm12: UInt32) -> Data {
        let original = insn.bytes.enumerated().reduce(UInt32(0)) { accumulated, byte in
            accumulated | (UInt32(byte.element) << (8 * UInt32(byte.offset)))
        }
        let rewritten = (original & ~(0xFFF << 10)) | ((imm12 & 0xFFF) << 10)
        return ARM64.encodeU32(rewritten)
    }

    @Test("The live b.eq gate is found, and it is the one the patch NOPs")
    func findsTheLiveGate() throws {
        let stream = try realStream()
        let comparison = stream.instructions[stream.comparisonIndex]
        #expect(comparison.mnemonic == "cmn")
        #expect(DSCLockdownModePatcher.immediate(of: comparison, at: 1) == 1)
        #expect(stream.instructions[stream.gateIndex].mnemonic == "b.eq")
        // Something before the comparison has to be the sysctl call.
        #expect(stream.instructions[..<stream.comparisonIndex].contains { $0.mnemonic == "bl" })
    }

    @Test("A cmn with no preceding call is not a gate")
    func rejectsComparisonWithoutACall() throws {
        let stream = try realStream()
        let withoutCalls = stream.instructions.filter { $0.mnemonic != "bl" }
        #expect(DSCLockdownModePatcher.findErrorGate(withoutCalls) == nil)
    }

    @Test("A cmn with the wrong immediate is not a gate")
    func rejectsWrongImmediate() throws {
        let stream = try realStream()
        let comparison = stream.instructions[stream.comparisonIndex]
        let disassembler = ARM64Disassembler()
        let mutated = try #require(disassembler.disassembleOne(
            word(of: comparison, withImmediate: 2),
            at: comparison.address
        ))
        #expect(mutated.mnemonic == "cmn")
        #expect(DSCLockdownModePatcher.immediate(of: mutated, at: 1) == 2)

        var instructions = stream.instructions
        instructions[stream.comparisonIndex] = mutated
        #expect(DSCLockdownModePatcher.findErrorGate(instructions) == nil)
    }

    @Test("An unrelated instruction in the branch slot is not a gate")
    func rejectsUnrelatedBranchSlot() throws {
        let stream = try realStream()
        let filler = try #require(
            stream.instructions.first { $0.mnemonic != "b.eq" && $0.mnemonic != "nop" },
            "the block must contain some instruction that is neither b.eq nor nop"
        )
        var instructions = stream.instructions
        instructions[stream.gateIndex] = filler
        #expect(DSCLockdownModePatcher.findErrorGate(instructions) == nil)
    }

    @Test("A truncated stream that ends on the cmn is not a gate")
    func rejectsTruncatedStream() throws {
        let stream = try realStream()
        let truncated = Array(stream.instructions[...stream.comparisonIndex])
        #expect(DSCLockdownModePatcher.findErrorGate(truncated) == nil)
    }

    /// The already-patched shape, read off a cache this code actually patched
    /// rather than off a synthesised stream.
    @Test("A NOPed gate is still recognised, at the same address")
    func findsAnAlreadyNOPedGate() throws {
        _ = try #require(LockdownFixture.pristine, LockdownFixture.missing)
        let clone = try LockdownFixture.cloneCache(named: "nopedgate")
        defer { LockdownFixture.discard(clone) }

        let outcome = try DSCLockdownModePatcher.patch(chunksDirectory: clone, log: nil)
        let gateVMA = try #require(outcome.gateVMA)

        let chunks = try DSCChunkSet(directory: clone)
        let resolved = try DSCLockdownModePatcher.resolveBlockInvoke(in: chunks)
        let block = try #require(resolved)
        let instructions = try DSCLockdownModePatcher.disassembleBlock(in: chunks, at: block.vma)
        let gate = try #require(DSCLockdownModePatcher.findErrorGate(instructions))
        #expect(gate.address == gateVMA)
        #expect(gate.mnemonic == "nop")
    }
}

// DyldSharedCacheLockdownModePatcherTests.swift — Parity for the lockdown-mode DSC patch.
//
// The only independent reference for this patch was
// `scripts/patchers/cfw_patch_lockdown_mode.py`, driven exactly as
// `cfw_install.sh` drove it: `cfw.py patch-lockdown-mode <chunks_dir>`. That
// Python has been removed, so what it produced on the real cache is frozen in
// `FrozenReference` below — the block and gate addresses, the instruction word
// on each side of the write, and the SHA-256 of the one chunk it changed. The
// central test clones the cache, runs `DyldSharedCacheLockdownModePatcher` on the clone and
// grades it against those, chunk bytes and re-attested code slot alike.
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
import CryptoKit
@testable import FirmwarePatcher
import Foundation
import Testing

// MARK: - The frozen reference

/// What the reference Python wrote on the real 24A435 arm64e shared cache.
///
/// Recorded from live runs at commit 78cbeea, each constant quoting the log
/// line it came from:
///
///     .venv/bin/python3 scripts/patchers/cfw.py \
///         patch-lockdown-mode <clone of ipsws/ref_extract/dsc_pristine>
private enum FrozenReference {
    /// Python: `[.] ___os_lockdown_mode_enabled_block_invoke @ 0x237EF2260`.
    static let functionVMA: UInt64 = 0x2_37EF_2260

    /// Python: `[.] gate @ 0x237EF2298: b.eq #0x237ef22bc`.
    static let gateVMA: UInt64 = 0x2_37EF_2298

    /// The same line's disassembly, which is what the gate search must find.
    static let gateMnemonic = "b.eq"

    /// Python: `[+] wrote nop at 0x237EF2298 (20010054 -> 1f2003d5)`.
    static let originalWord = Data([0x20, 0x01, 0x00, 0x54])
    static let patchedWord = Data([0x1F, 0x20, 0x03, 0xD5])

    /// Python: one `wrote nop` line, so one site written.
    static let sitesWritten = 1

    /// `cmp -s` against the pristine tree afterwards: exactly one chunk moved,
    /// to this digest, from `shasum -a 256 <output>/…arm64e.40`.
    ///
    /// The digest covers the re-attestation as well as the NOP — the Python
    /// logged `re-attest: wrote slot 7868 of dyld_shared_cache_arm64e.40`
    /// (`c33cc701.. -> 43ba8896..`), `updated 1 slot hash(es) across 1
    /// chunk(s)`.
    ///
    /// Two further runs pinned the edges. Re-run over its own output: `[.] gate
    /// @ 0x237EF2298: nop`, `already patched at 0x237EF2298; nothing to
    /// patch/re-attest`, digest unchanged. `--dry-run` on a fresh clone: `would
    /// write nop at 0x237EF2298 (20010054 -> 1f2003d5)` and no chunk changed.
    static let changedChunks: [String: String] = [
        "dyld_shared_cache_arm64e.40":
            "7f8ba74581e37fbd433d42851578d4faa7e30ab2959b1d466f0ff3b9a39f6e56",
    ]
}

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
            withIntermediateDirectories: true,
        )
        let entries = try FileManager.default.contentsOfDirectory(atPath: pristine.path).sorted()
        let result = try Subprocess.run(
            executable: URL(fileURLWithPath: "/bin/cp"),
            arguments: ["-c", "-R"]
                + entries.map { pristine.appendingPathComponent($0).path }
                + [destination.path],
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
            stderr: String(decoding: errData, as: UTF8.self),
        )
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
        let pristine = try #require(LockdownFixture.pristine, LockdownFixture.missing)
        let changed = try DirectoryComparison.changedNames(in: directory, against: pristine)
        #expect(changed == FrozenReference.changedChunks.keys.sorted())
        for name in changed {
            let digest = try sha256(of: directory.appendingPathComponent(name))
            let frozen = FrozenReference.changedChunks[name] ?? "(not a chunk the Python moved)"
            #expect(digest == frozen, "\(name): Swift \(digest), reference \(frozen)")
        }
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
                ],
            )
            if result.status != 0 {
                differing.append("\(name): \(result.stdout)\(result.stderr)".trimmingCharacters(
                    in: .whitespacesAndNewlines,
                ))
            }
        }
        return differing
    }

    /// The names of the files in `directory` that differ from `reference`.
    static func changedNames(in directory: URL, against reference: URL) throws -> [String] {
        let manager = FileManager.default
        let left = try Set(manager.contentsOfDirectory(atPath: reference.path))
        let right = try Set(manager.contentsOfDirectory(atPath: directory.path))
        var differing = Array(left.symmetricDifference(right))
        for name in left.intersection(right) {
            let result = try Subprocess.run(
                executable: URL(fileURLWithPath: "/usr/bin/cmp"),
                arguments: [
                    "-s",
                    reference.appendingPathComponent(name).path,
                    directory.appendingPathComponent(name).path,
                ],
            )
            if result.status != 0 {
                differing.append(name)
            }
        }
        return differing.sorted()
    }

    /// A digest of every file in a cache directory, for before/after checks
    /// that only need to know whether anything moved.
    static func fingerprint(of directory: URL) throws -> [String: String] {
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        var digests: [String: String] = [:]
        for name in names {
            let result = try Subprocess.run(
                executable: URL(fileURLWithPath: "/sbin/md5"),
                arguments: ["-q", directory.appendingPathComponent(name).path],
            )
            digests[name] = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return digests
    }
}

// MARK: - Parity against the frozen reference

@Suite(.serialized, .enabled(if: LockdownFixture.runs, LockdownFixture.skipReason))
struct DyldSharedCacheLockdownModeParityTests {
    /// The one that matters: the real cache in, the reference's bytes out.
    @Test
    func `Swift reproduces the reference's patched cache byte for byte`() throws {
        _ = try #require(LockdownFixture.pristine, LockdownFixture.missing)

        let swiftClone = try LockdownFixture.cloneCache(named: "swift")
        defer { LockdownFixture.discard(swiftClone) }

        let outcome = try DyldSharedCacheLockdownModePatcher.patch(chunksDirectory: swiftClone, log: nil)

        #expect(outcome.verdict == .patched)
        #expect(outcome.sitesWritten == FrozenReference.sitesWritten)
        #expect(outcome.gateVMA == FrozenReference.gateVMA)
        #expect(outcome.functionVMA == FrozenReference.functionVMA)

        let record = try #require(outcome.record)
        #expect(record.originalBytes == FrozenReference.originalWord)
        #expect(record.patchedBytes == FrozenReference.patchedWord)

        try Digest.expectMatchesReference(swiftClone)
    }

    /// The write has to be covered by exactly one re-attested page, or the
    /// guest takes a `KERN_PROTECTION_FAILURE` the first time it faults the
    /// page in. The Python re-attests one slot here; so must this.
    @Test
    func `The write is re-attested, and only the page it dirtied`() throws {
        _ = try #require(LockdownFixture.pristine, LockdownFixture.missing)

        let clone = try LockdownFixture.cloneCache(named: "reattest")
        defer { LockdownFixture.discard(clone) }

        let outcome = try DyldSharedCacheLockdownModePatcher.patch(chunksDirectory: clone, log: nil)
        let reattestation = try #require(outcome.reattestation)
        #expect(reattestation.updated.count == 1)
        #expect(reattestation.isFullyAttested)
        #expect(reattestation.skipped.isEmpty)
    }

    /// A second pass over an installed cache is how this patch is actually met
    /// in the field — `cfw_install` re-runs. It must report a no-op rather than
    /// raise, and must not move a byte.
    @Test
    func `A second run is a no-op on an already-patched cache`() throws {
        _ = try #require(LockdownFixture.pristine, LockdownFixture.missing)

        let clone = try LockdownFixture.cloneCache(named: "idempotence")
        defer { LockdownFixture.discard(clone) }

        let first = try DyldSharedCacheLockdownModePatcher.patch(chunksDirectory: clone, log: nil)
        #expect(first.verdict == .patched)
        let afterFirst = try DirectoryComparison.fingerprint(of: clone)

        let second = try DyldSharedCacheLockdownModePatcher.patch(chunksDirectory: clone, log: nil)
        #expect(second.verdict == .alreadyPatched)
        #expect(second.sitesWritten == 0)
        #expect(second.sitesFound == 1)
        #expect(second.gateVMA == first.gateVMA)
        #expect(second.record == nil)

        let afterSecond = try DirectoryComparison.fingerprint(of: clone)
        #expect(afterFirst == afterSecond, "a no-op run still rewrote something")
        // The reference was a no-op on its own output too, so the bytes here
        // must still be the ones it left behind.
        try Digest.expectMatchesReference(clone)
    }

    /// The reference's `--dry-run` named the gate and changed no chunk. So
    /// must this one — an install script that asks what would happen must not
    /// be the thing that makes it happen.
    @Test
    func `A dry run names the reference's gate and writes nothing`() throws {
        let pristine = try #require(LockdownFixture.pristine, LockdownFixture.missing)

        let clone = try LockdownFixture.cloneCache(named: "dryrun")
        defer { LockdownFixture.discard(clone) }

        let outcome = try DyldSharedCacheLockdownModePatcher.patch(
            chunksDirectory: clone,
            dryRun: true,
            log: nil,
        )
        #expect(outcome.sitesWritten == 0)
        #expect(outcome.sitesFound == 1)
        #expect(outcome.gateVMA == FrozenReference.gateVMA)

        let changed = try DirectoryComparison.changedNames(in: clone, against: pristine)
        #expect(changed.isEmpty, "a dry run modified \(changed)")
    }

    /// The reveal — symbol, then gate — read off the pristine cache without
    /// touching it, and checked against the addresses the reference printed.
    @Test
    func `Symbol and gate resolve to the reference's addresses`() throws {
        let pristine = try #require(LockdownFixture.pristine, LockdownFixture.missing)

        let chunks = try DyldSharedCacheChunkSet(directory: pristine)
        let resolved = try DyldSharedCacheLockdownModePatcher.resolveBlockInvoke(in: chunks)
        let block = try #require(
            resolved,
            "the cache must carry an os_lockdown_mode_enabled block to compare against",
        )
        #expect(block.vma == FrozenReference.functionVMA)
        #expect(block.name == DyldSharedCacheLockdownModePatcher.symbolCandidates.first)

        let instructions = try DyldSharedCacheLockdownModePatcher.disassembleBlock(in: chunks, at: block.vma)
        let gate = try #require(DyldSharedCacheLockdownModePatcher.findErrorGate(instructions))
        #expect(gate.address == FrozenReference.gateVMA)
        #expect(gate.mnemonic == FrozenReference.gateMnemonic)

        // The decode stops at the block's own return, not at the ceiling.
        #expect(instructions.count < DyldSharedCacheLockdownModePatcher.maxInstructions)
        let last = try #require(instructions.last)
        #expect(last.mnemonic == "ret" || last.mnemonic == "retab")
    }
}

// MARK: - What the gate search must and must not match

@Suite(.serialized, .enabled(if: LockdownFixture.runs, LockdownFixture.skipReason))
struct DyldSharedCacheLockdownModeGateTests {
    /// The real instruction stream, and the index of the real gate in it.
    private struct Stream {
        let instructions: [Instruction]
        let gateIndex: Int
        let comparisonIndex: Int
    }

    private func realStream() throws -> Stream {
        let pristine = try #require(LockdownFixture.pristine, LockdownFixture.missing)
        let chunks = try DyldSharedCacheChunkSet(directory: pristine)
        let resolved = try DyldSharedCacheLockdownModePatcher.resolveBlockInvoke(in: chunks)
        let block = try #require(resolved)
        let instructions = try DyldSharedCacheLockdownModePatcher.disassembleBlock(in: chunks, at: block.vma)
        let gate = try #require(DyldSharedCacheLockdownModePatcher.findErrorGate(instructions))
        let gateIndex = try #require(instructions.firstIndex { $0.address == gate.address })
        #expect(gateIndex > 0)
        return Stream(
            instructions: instructions,
            gateIndex: gateIndex,
            comparisonIndex: gateIndex - 1,
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

    @Test
    func `The live b.eq gate is found, and it is the one the patch NOPs`() throws {
        let stream = try realStream()
        let comparison = stream.instructions[stream.comparisonIndex]
        #expect(comparison.mnemonic == "cmn")
        #expect(DyldSharedCacheLockdownModePatcher.immediate(of: comparison, at: 1) == 1)
        #expect(stream.instructions[stream.gateIndex].mnemonic == "b.eq")
        // Something before the comparison has to be the sysctl call.
        #expect(stream.instructions[..<stream.comparisonIndex].contains { $0.mnemonic == "bl" })
    }

    @Test
    func `A cmn with no preceding call is not a gate`() throws {
        let stream = try realStream()
        let withoutCalls = stream.instructions.filter { $0.mnemonic != "bl" }
        #expect(DyldSharedCacheLockdownModePatcher.findErrorGate(withoutCalls) == nil)
    }

    @Test
    func `A cmn with the wrong immediate is not a gate`() throws {
        let stream = try realStream()
        let comparison = stream.instructions[stream.comparisonIndex]
        let disassembler = ARM64Disassembler()
        let mutated = try #require(disassembler.disassembleOne(
            word(of: comparison, withImmediate: 2),
            at: comparison.address,
        ))
        #expect(mutated.mnemonic == "cmn")
        #expect(DyldSharedCacheLockdownModePatcher.immediate(of: mutated, at: 1) == 2)

        var instructions = stream.instructions
        instructions[stream.comparisonIndex] = mutated
        #expect(DyldSharedCacheLockdownModePatcher.findErrorGate(instructions) == nil)
    }

    @Test
    func `An unrelated instruction in the branch slot is not a gate`() throws {
        let stream = try realStream()
        let filler = try #require(
            stream.instructions.first { $0.mnemonic != "b.eq" && $0.mnemonic != "nop" },
            "the block must contain some instruction that is neither b.eq nor nop",
        )
        var instructions = stream.instructions
        instructions[stream.gateIndex] = filler
        #expect(DyldSharedCacheLockdownModePatcher.findErrorGate(instructions) == nil)
    }

    @Test
    func `A truncated stream that ends on the cmn is not a gate`() throws {
        let stream = try realStream()
        let truncated = Array(stream.instructions[...stream.comparisonIndex])
        #expect(DyldSharedCacheLockdownModePatcher.findErrorGate(truncated) == nil)
    }

    /// The already-patched shape, read off a cache this code actually patched
    /// rather than off a synthesised stream.
    @Test
    func `A NOPed gate is still recognised, at the same address`() throws {
        _ = try #require(LockdownFixture.pristine, LockdownFixture.missing)
        let clone = try LockdownFixture.cloneCache(named: "nopedgate")
        defer { LockdownFixture.discard(clone) }

        let outcome = try DyldSharedCacheLockdownModePatcher.patch(chunksDirectory: clone, log: nil)
        let gateVMA = try #require(outcome.gateVMA)

        let chunks = try DyldSharedCacheChunkSet(directory: clone)
        let resolved = try DyldSharedCacheLockdownModePatcher.resolveBlockInvoke(in: chunks)
        let block = try #require(resolved)
        let instructions = try DyldSharedCacheLockdownModePatcher.disassembleBlock(in: chunks, at: block.vma)
        let gate = try #require(DyldSharedCacheLockdownModePatcher.findErrorGate(instructions))
        #expect(gate.address == gateVMA)
        #expect(gate.mnemonic == "nop")
    }
}

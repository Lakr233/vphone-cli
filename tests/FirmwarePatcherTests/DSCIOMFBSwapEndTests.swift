// DSCIOMFBSwapEndTests.swift — Parity for the IOMFB SwapEnd payload-size patch.
//
// There is no independent checker for a patched dyld shared cache: `codesign -v`
// does not apply to a cache chunk, and the only other implementation of this
// patch was `scripts/patchers/cfw_patch_iomfb_swapend.py`, driven through
// `cfw.py patch-iomfb-swapend` exactly as `cfw_install*.sh` and `cfw-kit`
// invoked it. That Python has been removed, so what it produced on the real
// 24A435 arm64e cache — at each of the three target sizes — is frozen in
// `FrozenReference` below: the site it landed on, the size it found there, and
// the SHA-256 of the one chunk it changed. `DSCIOMFBSwapEndPatcher` runs on a
// clone and is graded against those. A patch that lands in the right place but
// re-attests a different page lands on a different digest.
//
// The cache is required. `VPHONE_DSC_PRISTINE` points at it, defaulting to
// `ipsws/ref_extract/dsc_pristine`, and its absence FAILS rather than passing
// quietly: a `guard let … else { return }` is reported by Swift Testing as a
// pass, so "the tests are green" would be equally compatible with "the tests did
// nothing". A machine that genuinely cannot carry the 6.7 GB fixture sets
// `VPHONE_DSC_FIXTURE_OPTIONAL=1` and gets a visible *skip* instead.
//
// Nothing here writes into the pristine directory. Clones are made with
// `clonefile` (`cp -c`) into `ipsws/scratch_dsciomfbswapend`, which is on the
// same filesystem, so a clone is instant and costs only the pages that change.
// Override the location with `VPHONE_DSC_SCRATCH`.
//
// The shape tests below need none of that: they assemble the call set-up with
// `ARM64Encoder` — the same instructions `cfw_patch_iomfb_swapend._self_test()`
// builds with keystone — and run the finder over it, so the anchor's semantics
// are pinned on every machine, fixture or no fixture.

import Capstone
import CryptoKit
@testable import FirmwarePatcher
import Foundation
import Testing

// MARK: - The frozen reference

/// What the reference Python did on the real 24A435 arm64e shared cache.
///
/// Recorded from live runs at commit 78cbeea, one per target size:
///
///     .venv/bin/python3 scripts/patchers/cfw.py patch-iomfb-swapend \
///         <clone of ipsws/ref_extract/dsc_pristine> --target-size <size>
private enum FrozenReference {
    /// Python: `[.] _kern_SwapEnd @ 0x22AC0C334`.
    static let functionVMA: UInt64 = 0x2_2AC0_C334

    /// Python: the `at 0x22AC0C358` on every `patched`/`already` line — the
    /// `mov w3, #imm` of the external-method call set-up.
    static let siteVMA: UInt64 = 0x2_2AC0_C358

    /// Python: the left half of `size 0x6E0 -> …`, i.e. what this cache's own
    /// userland sends today.
    static let originalSize: UInt32 = 0x6E0

    /// What one target size produced.
    struct SizeRun {
        /// Sites the Python's `[+] patched … size … at …` lines counted.
        let sitesWritten: Int
        /// Whether it reported `[=] already 0x… at 0x22AC0C358` instead.
        let wasAlreadyCorrect: Bool
        /// The chunks `cmp -s` found moved against the pristine tree, with the
        /// SHA-256 `shasum -a 256` read off each afterwards.
        let changedChunks: [String: String]
    }

    /// `--target-size 0x588` (the 26.4 base). Python: `patched … _kern_SwapEnd
    /// size 0x6E0 -> 0x588 at 0x22AC0C358`, then `re-attest: wrote slot 2563 of
    /// dyld_shared_cache_arm64e.38` and `updated 1 slot hash(es) across 1
    /// chunk(s)`.
    ///
    /// `--target-size 0x560` (the 26.1 base) is the same story with a different
    /// immediate, and so a different digest for the same chunk.
    ///
    /// `--target-size 0x6E0` is the size the cache already sends: Python
    /// printed `already 0x6E0 at 0x22AC0C358; re-attesting page only`, the
    /// re-attestation was a no-op (`slot already matches`), and no chunk moved
    /// at all.
    ///
    /// Re-running any of the three over its own output printed `already 0x… at
    /// 0x22AC0C358`, wrote no site, and left the digest below standing.
    static let bySize: [UInt32: SizeRun] = [
        0x588: SizeRun(
            sitesWritten: 1,
            wasAlreadyCorrect: false,
            changedChunks: [
                "dyld_shared_cache_arm64e.38":
                    "b49bbe7872273242c73973a451d9dac1a7ec803da8efeb5dcd1e04c7b5292f1d",
            ]
        ),
        0x560: SizeRun(
            sitesWritten: 1,
            wasAlreadyCorrect: false,
            changedChunks: [
                "dyld_shared_cache_arm64e.38":
                    "72f07ea587a523ed602d30f8f9a3508d291451a75ab90a0c578313d208b8a0e4",
            ]
        ),
        0x6E0: SizeRun(sitesWritten: 0, wasAlreadyCorrect: true, changedChunks: [:]),
    ]
}

// MARK: - Fixture discovery

private enum SwapEndFixture {
    static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    /// The read-only reference cache. Never written to.
    static var pristine: URL? {
        let url = ProcessInfo.processInfo.environment["VPHONE_DSC_PRISTINE"]
            .map { URL(fileURLWithPath: $0) }
            ?? repoRoot.appendingPathComponent("ipsws/ref_extract/dsc_pristine")
        let main = url.appendingPathComponent("dyld_shared_cache_arm64e")
        return FileManager.default.fileExists(atPath: main.path) ? url : nil
    }

    /// Opt-out for a machine that cannot carry the fixture. Set it and the
    /// parity suite reports as skipped; leave it unset and a missing cache is a
    /// failure, which is the only reading of "green" this patch can afford.
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

    /// Where clones go. Deliberately *not* under `ipsws/ref_extract`: that tree
    /// is the pristine reference the rest of the suite compares against, and
    /// nothing here may leave anything in it.
    static var scratchRoot: URL {
        ProcessInfo.processInfo.environment["VPHONE_DSC_SCRATCH"]
            .map { URL(fileURLWithPath: $0) }
            ?? repoRoot.appendingPathComponent("ipsws/scratch_dsciomfbswapend")
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
        let result = try SwapEndSubprocess.run(
            executable: URL(fileURLWithPath: "/bin/cp"),
            arguments: ["-c", "-R"]
                + (try FileManager.default.contentsOfDirectory(atPath: pristine.path))
                .sorted()
                .map { pristine.appendingPathComponent($0).path }
                + [destination.path]
        )
        guard result.status == 0 else { throw CocoaError(.fileWriteUnknown) }
        return destination
    }

    /// Discard clones, and the scratch root with them once the last one is
    /// gone, so a green run leaves the working tree exactly as it found it.
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

private enum SwapEndSubprocess {
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
}

// MARK: - Byte-for-byte cache comparison

private enum CacheComparison {
    /// Every file in `left` that is not byte-identical to its twin in `right`.
    ///
    /// `cmp` rather than a hash: it stops at the first differing byte, so an
    /// identical pair of 6.7 GB trees costs one streaming read and a mismatch
    /// costs almost nothing.
    static func differingFiles(_ left: URL, _ right: URL) throws -> [String] {
        let leftNames = try FileManager.default.contentsOfDirectory(atPath: left.path).sorted()
        let rightNames = try FileManager.default.contentsOfDirectory(atPath: right.path).sorted()
        guard leftNames == rightNames else {
            return Array(Set(leftNames).symmetricDifference(rightNames)).sorted()
        }
        var differing: [String] = []
        for name in leftNames {
            let result = try SwapEndSubprocess.run(
                executable: URL(fileURLWithPath: "/usr/bin/cmp"),
                arguments: [
                    "-s",
                    left.appendingPathComponent(name).path,
                    right.appendingPathComponent(name).path,
                ]
            )
            if result.status != 0 { differing.append(name) }
        }
        return differing
    }
}

// MARK: - The call-setup shape, assembled rather than transcribed

/// The `_kern_SwapEnd` external-method call set-up, built out of `ARM64Encoder`.
///
/// This is `cfw_patch_iomfb_swapend._self_test()`'s sequence, instruction for
/// instruction, with the source size (0x548) deliberately unlike the target —
/// so a finder that accidentally anchored on the *target* size would fail here.
private enum SwapEndCallSetup {
    static let baseAddress: UInt64 = 0x1000
    static let sourceSize: UInt16 = 0x548
    /// Where the `mov w3, #imm` sits: three instructions in.
    static let sizeIndex = 3

    static func assemble(
        selector: UInt16 = 5,
        size: UInt16 = sourceSize,
        terminator: Data? = nil
    ) -> Data? {
        let branchPC = Int(baseAddress) + 24
        guard let ldr = ARM64Encoder.encodeLdrWUnsignedOffset(rt: 0, rn: 0, offset: 0x14),
              let add = ARM64Encoder.encodeAddImm12(rd: 2, rn: 19, imm12: 0x18),
              let selectorMove = ARM64Encoder.encodeMovzW(rd: 1, imm16: selector),
              let sizeMove = ARM64Encoder.encodeMovzW(rd: 3, imm16: size),
              let zeroX4 = ARM64Encoder.encodeMovzX(rd: 4, imm16: 0),
              let zeroX5 = ARM64Encoder.encodeMovzX(rd: 5, imm16: 0),
              let call = ARM64Encoder.encodeBL(from: branchPC, to: branchPC + 0x40)
        else { return nil }
        return ldr + add + selectorMove + sizeMove + zeroX4 + zeroX5 + (terminator ?? call)
    }

    static func disassemble(_ code: Data, _ disassembler: ARM64Disassembler) -> [Instruction] {
        disassembler.disassemble(code, at: baseAddress, count: code.count / 4)
    }
}

// MARK: - 1 · The anchor, with no cache in sight

@Suite
struct DSCIOMFBSwapEndShapeTests {
    @Test("The finder lands on the size move of the external-method call set-up")
    func findsTheSizeMove() throws {
        let disassembler = ARM64Disassembler()
        let code = try #require(SwapEndCallSetup.assemble())
        let instructions = SwapEndCallSetup.disassemble(code, disassembler)
        #expect(instructions.count == 7)

        let site = try #require(
            DSCIOMFBSwapEndPatcher.findSizeInstruction(
                in: instructions,
                disassembler: disassembler
            )
        )
        #expect(site.index == SwapEndCallSetup.sizeIndex)
        #expect(
            site.instruction.address
                == SwapEndCallSetup.baseAddress + UInt64(SwapEndCallSetup.sizeIndex * 4)
        )

        let decoded = try #require(
            DSCIOMFBSwapEndPatcher.movRegisterImmediate(
                site.instruction,
                disassembler: disassembler
            )
        )
        #expect(decoded.register == DSCIOMFBSwapEndPatcher.sizeRegister)
        #expect(decoded.immediate == Int64(SwapEndCallSetup.sourceSize))
        print("[shape] size move at index \(site.index): \(site.instruction)")
    }

    @Test("A different selector is not this call, and is not patched")
    func rejectsAnotherSelector() throws {
        let disassembler = ARM64Disassembler()
        // Selector 6 is some other external method of the same userclient; the
        // size it passes is none of this patcher's business.
        let code = try #require(SwapEndCallSetup.assemble(selector: 6))
        let instructions = SwapEndCallSetup.disassemble(code, disassembler)
        #expect(
            DSCIOMFBSwapEndPatcher.findSizeInstruction(
                in: instructions,
                disassembler: disassembler
            ) == nil
        )
    }

    @Test("Without the call itself the shape is not a call set-up")
    func rejectsASequenceThatNeverCalls() throws {
        let disassembler = ARM64Disassembler()
        let code = try #require(SwapEndCallSetup.assemble(terminator: ARM64.nop))
        let instructions = SwapEndCallSetup.disassemble(code, disassembler)
        #expect(
            DSCIOMFBSwapEndPatcher.findSizeInstruction(
                in: instructions,
                disassembler: disassembler
            ) == nil
        )
    }

    @Test("The replacement is the encoder's MOVZ, for every size a base kernel wants")
    func replacementComesFromTheEncoder() throws {
        // 0x560 is the 26.1 base, 0x588 the 26.4 one; both are passed by
        // `cfw_install*.sh` / `cfw-kit` today.
        for size: UInt16 in [0x560, 0x588] {
            let encoded = try #require(ARM64Encoder.encodeMovzW(rd: 3, imm16: size))
            #expect(encoded.count == 4)
            let decoded = try #require(
                ARM64Disassembler().disassembleOne(encoded, at: SwapEndCallSetup.baseAddress)
            )
            let move = try #require(
                DSCIOMFBSwapEndPatcher.movRegisterImmediate(
                    decoded,
                    disassembler: ARM64Disassembler()
                )
            )
            #expect(move.register == DSCIOMFBSwapEndPatcher.sizeRegister)
            #expect(move.immediate == Int64(size))
        }
    }

    @Test("A size that will not fit a MOVZ immediate is refused, not truncated")
    func oversizedTargetIsRefused() throws {
        #expect(throws: PatcherError.self) {
            _ = try DSCIOMFBSwapEndPatcher.replacement(forTargetSize: 0x1_0000)
        }
        // And it is refused before the 6.7 GB cache is opened, so the caller
        // gets "that size cannot be encoded" rather than whatever the cache
        // would have said first. A path that does not exist proves the order:
        // if the guard moved after the open, this would throw a DSCError.
        var thrown: (any Error)?
        do {
            _ = try DSCIOMFBSwapEndPatcher.patch(
                chunksDirectory: URL(fileURLWithPath: "/nonexistent-dyld-cache"),
                targetSize: 0x1_0000,
                dryRun: true,
                log: nil
            )
        } catch {
            thrown = error
        }
        let error = try #require(thrown)
        #expect("\(error)".contains("MOVZ"), "unexpected error: \(error)")
    }
}

// MARK: - 2 · Parity against the frozen reference, on the real cache

@Suite(.serialized, .enabled(if: SwapEndFixture.runs, SwapEndFixture.skipReason))
struct DSCIOMFBSwapEndParityTests {
    /// The three sizes that matter: the 26.4 base's, the 26.1 base's, and the
    /// size this cache's own userland already sends — which is the case where
    /// the right answer is to write nothing at all.
    ///
    /// 0x6e0 is not an anchor and the patcher never compares against it; it is
    /// here because a cache that already agrees with the target is the one
    /// shape where "wrote one site" and "wrote none" are both plausible bugs.
    static let targetSizes: [UInt32] = [0x588, 0x560, 0x6E0]

    @Test(
        "Swift patches the real cache to the reference's bytes",
        arguments: targetSizes
    )
    func matchesTheReferenceByteForByte(targetSize: UInt32) throws {
        let pristine = try #require(SwapEndFixture.pristine, SwapEndFixture.missing)
        let suffix = String(targetSize, radix: 16)
        let reference = try #require(
            FrozenReference.bySize[targetSize],
            "no frozen reference run for this target size"
        )

        let swiftClone = try SwapEndFixture.cloneCache(named: "swift_\(suffix)")
        defer { SwapEndFixture.discard(swiftClone) }

        let mine = try DSCIOMFBSwapEndPatcher.patch(
            chunksDirectory: swiftClone,
            targetSize: targetSize,
            log: nil
        )

        // Same number of sites, at the same address, from the same source size.
        #expect(
            mine.sitesWritten == reference.sitesWritten,
            "swift wrote \(mine.sitesWritten) site(s), reference \(reference.sitesWritten)"
        )
        #expect(mine.wasAlreadyCorrect == reference.wasAlreadyCorrect)
        #expect(mine.siteVMA == FrozenReference.siteVMA)
        #expect(mine.originalSize == FrozenReference.originalSize)
        #expect(mine.targetSize == targetSize)

        // And, the part that actually matters: the reference's chunks, with the
        // reference's bytes.
        let touched = try CacheComparison.differingFiles(pristine, swiftClone)
        #expect(touched.sorted() == reference.changedChunks.keys.sorted())
        for name in touched {
            let digest = try Digest.sha256(of: swiftClone.appendingPathComponent(name))
            let frozen = reference.changedChunks[name] ?? "(not a chunk the Python moved)"
            #expect(digest == frozen, "\(name): Swift \(digest), reference \(frozen)")
        }

        if mine.sitesWritten > 0 {
            let reattested = try #require(mine.reattestation)
            #expect(reattested.updated.count == 1)
            #expect(reattested.isFullyAttested)
        }

        print(
            "[parity 0x\(suffix)] \(mine.sitesWritten) site(s) "
                + "(0x\(String(mine.originalSize, radix: 16, uppercase: true)) -> "
                + "0x\(String(mine.targetSize, radix: 16, uppercase: true)) at "
                + "0x\(String(mine.siteVMA, radix: 16, uppercase: true))); "
                + "chunks changed: \(touched) — digests match the reference"
        )
    }

    @Test("A dry run reports the site and leaves every chunk untouched")
    func dryRunWritesNothing() throws {
        let pristine = try #require(SwapEndFixture.pristine, SwapEndFixture.missing)
        let clone = try SwapEndFixture.cloneCache(named: "dry")
        defer { SwapEndFixture.discard(clone) }

        let mine = try DSCIOMFBSwapEndPatcher.patch(
            chunksDirectory: clone,
            targetSize: 0x588,
            dryRun: true,
            log: nil
        )
        #expect(mine.sitesWritten == 0)
        #expect(mine.reattestation == nil)
        #expect(mine.siteVMA == FrozenReference.siteVMA)
        #expect(mine.originalSize == FrozenReference.originalSize)

        let touched = try CacheComparison.differingFiles(pristine, clone)
        #expect(touched.isEmpty, "a dry run wrote to \(touched)")
        print(
            "[dry-run] would patch 0x\(String(mine.originalSize, radix: 16, uppercase: true)) "
                + "-> 0x588 at 0x\(String(mine.siteVMA, radix: 16, uppercase: true)); "
                + "0 chunks changed"
        )
    }

    @Test("Patching an already-patched cache is a no-op, not a second write")
    func secondRunChangesNothing() throws {
        try #require(SwapEndFixture.pristine != nil, SwapEndFixture.missing)
        let clone = try SwapEndFixture.cloneCache(named: "idempotent")
        let afterFirst = try SwapEndFixture.cloneCache(named: "idempotent_snapshot")
        defer { SwapEndFixture.discard(clone, afterFirst) }

        let first = try DSCIOMFBSwapEndPatcher.patch(
            chunksDirectory: clone,
            targetSize: 0x588,
            log: nil
        )
        #expect(first.sitesWritten == 1)
        #expect(!first.wasAlreadyCorrect)

        // Snapshot the patched cache, then run again over it.
        try? FileManager.default.removeItem(at: afterFirst)
        let copy = try SwapEndSubprocess.run(
            executable: URL(fileURLWithPath: "/bin/cp"),
            arguments: ["-c", "-R", clone.path, afterFirst.path]
        )
        #expect(copy.status == 0)

        let second = try DSCIOMFBSwapEndPatcher.patch(
            chunksDirectory: clone,
            targetSize: 0x588,
            log: nil
        )
        #expect(second.wasAlreadyCorrect)
        #expect(second.sitesWritten == 0)
        #expect(second.siteVMA == first.siteVMA)
        #expect(second.originalSize == second.targetSize)

        let differing = try CacheComparison.differingFiles(afterFirst, clone)
        #expect(differing.isEmpty, "a second run rewrote \(differing)")

        // The reference was a no-op on its own output too, so the bytes here
        // must still be the ones it left behind for 0x588.
        let frozen = try #require(FrozenReference.bySize[0x588])
        for (name, digest) in frozen.changedChunks {
            #expect(try Digest.sha256(of: clone.appendingPathComponent(name)) == digest)
        }
        print("[idempotent] second run wrote 0 sites and changed 0 chunks")
    }

    @Test("The symbol and the site are found without `ipsw` on the patch path")
    func resolvesWithoutIpsw() throws {
        let pristine = try #require(SwapEndFixture.pristine, SwapEndFixture.missing)
        let chunks = try DSCChunkSet(directory: pristine)
        let resolver = try DSCSymbolResolver(chunks: chunks)
        try resolver.requireLocalSymbols()

        let functionVMA = try resolver.address(
            of: DSCIOMFBSwapEndPatcher.symbolName,
            inImage: DSCIOMFBSwapEndPatcher.imagePath
        )
        #expect(functionVMA == FrozenReference.functionVMA)

        let disassembler = ARM64Disassembler()
        let instructions = try DSCIOMFBSwapEndPatcher.disassembleFunction(
            in: chunks,
            at: functionVMA,
            maximumInstructions: DSCIOMFBSwapEndPatcher.maximumInstructions,
            disassembler: disassembler
        )
        #expect(!instructions.isEmpty)

        let site = try #require(
            DSCIOMFBSwapEndPatcher.findSizeInstruction(
                in: instructions,
                disassembler: disassembler
            ),
            "the SwapEnd call set-up was not found in \(DSCIOMFBSwapEndPatcher.symbolName)"
        )
        // The shape, on the real function: selector, size, two zeros, the call.
        let selector = try #require(
            DSCIOMFBSwapEndPatcher.movRegisterImmediate(
                instructions[site.index - 1],
                disassembler: disassembler
            )
        )
        #expect(selector.register == "w1")
        #expect(selector.immediate == DSCIOMFBSwapEndPatcher.selector)
        #expect(instructions[site.index + 3].mnemonic == "bl")

        let size = try #require(
            DSCIOMFBSwapEndPatcher.movRegisterImmediate(
                site.instruction,
                disassembler: disassembler
            )
        )
        // The reference resolved the same function and landed on the same move.
        #expect(site.instruction.address == FrozenReference.siteVMA)
        #expect(size.immediate == Int64(FrozenReference.originalSize))
        print(
            "[resolve] \(DSCIOMFBSwapEndPatcher.symbolName) @ "
                + "0x\(String(functionVMA, radix: 16, uppercase: true)), size move "
                + "0x\(String(size.immediate, radix: 16, uppercase: true)) @ "
                + "0x\(String(site.instruction.address, radix: 16, uppercase: true))"
        )
    }
}

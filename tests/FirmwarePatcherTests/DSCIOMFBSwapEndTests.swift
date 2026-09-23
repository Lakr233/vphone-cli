// DSCIOMFBSwapEndTests.swift — Parity for the IOMFB SwapEnd payload-size patch.
//
// There is no independent checker for a patched dyld shared cache: `codesign -v`
// does not apply to a cache chunk, and the only other implementation of this
// patch is `scripts/patchers/cfw_patch_iomfb_swapend.py`. So the parity test is
// literal. Two clones of the real 24A435 arm64e cache; the Python patches one
// through its own CLI (`cfw.py patch-iomfb-swapend`, exactly as
// `cfw_install*.sh` and `cfw-kit` invoke it), `DSCIOMFBSwapEndPatcher` patches
// the other, and then all 79 chunk files are compared byte for byte. Anything
// short of byte-identical is a failing port, including a patch that lands in the
// right place but re-attests a different page.
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
@testable import FirmwarePatcher
import Foundation
import Testing

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

    static let venvMissing: Comment = """
    the project venv is required for the cross-check against \
    scripts/patchers/cfw_patch_iomfb_swapend.py — run `make setup_venv`
    """

    /// Where clones go. Deliberately *not* under `ipsws/ref_extract`: that tree
    /// is the pristine reference the rest of the suite compares against, and
    /// nothing here may leave anything in it.
    static var scratchRoot: URL {
        ProcessInfo.processInfo.environment["VPHONE_DSC_SCRATCH"]
            .map { URL(fileURLWithPath: $0) }
            ?? repoRoot.appendingPathComponent("ipsws/scratch_dsciomfbswapend")
    }

    /// The project venv, which is where the reference Python lives.
    static var python: URL? {
        let url = repoRoot.appendingPathComponent(".venv/bin/python3")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// The CLI the install scripts call, which is the contract being preserved.
    static var patcherCLI: URL {
        repoRoot.appendingPathComponent("scripts/patchers/cfw.py")
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

// MARK: - What the reference Python did, read back off its own output

/// The Python prints one line per site it writes. Parsing that is how the test
/// learns the *number of sites* and the address the reference chose, without
/// this file writing either of them down.
private struct PythonSwapEndRun {
    /// Addresses the Python said it wrote.
    let siteVMAs: [UInt64]
    /// The address it reported when it found the size already correct.
    let alreadyCorrectVMA: UInt64?
    let output: String

    var sitesWritten: Int { siteVMAs.count }
    var alreadyCorrect: Bool { alreadyCorrectVMA != nil }
    /// The site the Python landed on, whether or not it wrote to it.
    var siteVMA: UInt64? { siteVMAs.first ?? alreadyCorrectVMA }

    init(output: String) {
        self.output = output
        var written: [UInt64] = []
        var already: UInt64?
        for line in output.split(separator: "\n") {
            if line.contains("[+] patched"), line.contains("_kern_SwapEnd size"),
               let match = line.firstMatch(of: /\bat 0x([0-9A-Fa-f]+)\b/),
               let vma = UInt64(match.1, radix: 16)
            {
                written.append(vma)
            }
            if line.contains("[=] already"),
               let match = line.firstMatch(of: /\bat 0x([0-9A-Fa-f]+)\b/),
               let vma = UInt64(match.1, radix: 16)
            {
                already = vma
            }
        }
        siteVMAs = written
        alreadyCorrectVMA = already
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

// MARK: - 2 · Parity against the Python, on the real cache

@Suite(.serialized, .enabled(if: SwapEndFixture.runs, SwapEndFixture.skipReason))
struct DSCIOMFBSwapEndParityTests {
    /// Run the reference Python through the CLI the install scripts use.
    private func runPython(on directory: URL, targetSize: UInt32) throws -> PythonSwapEndRun {
        let python = try #require(SwapEndFixture.python, SwapEndFixture.venvMissing)
        let result = try SwapEndSubprocess.run(
            executable: python,
            arguments: [
                SwapEndFixture.patcherCLI.path,
                "patch-iomfb-swapend",
                directory.path,
                "--target-size",
                "0x" + String(targetSize, radix: 16),
            ]
        )
        #expect(result.status == 0, "python patcher failed: \(result.stdout)\(result.stderr)")
        return PythonSwapEndRun(output: result.stdout)
    }

    /// The three sizes that matter: the 26.4 base's, the 26.1 base's, and the
    /// size this cache's own userland already sends — which is the case where
    /// the right answer is to write nothing at all.
    ///
    /// 0x6e0 is not an anchor and the patcher never compares against it; it is
    /// here because a cache that already agrees with the target is the one
    /// shape where "wrote one site" and "wrote none" are both plausible bugs.
    static let targetSizes: [UInt32] = [0x588, 0x560, 0x6E0]

    @Test(
        "Swift and Python patch the real cache to the same bytes",
        arguments: targetSizes
    )
    func matchesPythonByteForByte(targetSize: UInt32) throws {
        let pristine = try #require(SwapEndFixture.pristine, SwapEndFixture.missing)
        let suffix = String(targetSize, radix: 16)

        let pythonClone = try SwapEndFixture.cloneCache(named: "python_\(suffix)")
        let swiftClone = try SwapEndFixture.cloneCache(named: "swift_\(suffix)")
        defer { SwapEndFixture.discard(pythonClone, swiftClone) }

        let reference = try runPython(on: pythonClone, targetSize: targetSize)
        let mine = try DSCIOMFBSwapEndPatcher.patch(
            chunksDirectory: swiftClone,
            targetSize: targetSize,
            log: nil
        )

        // Same number of sites, at the same address, from the same source size.
        #expect(
            mine.sitesWritten == reference.sitesWritten,
            "swift wrote \(mine.sitesWritten) site(s), python wrote \(reference.sitesWritten)"
        )
        #expect(mine.wasAlreadyCorrect == reference.alreadyCorrect)
        let referenceVMA = try #require(
            reference.siteVMA,
            "the Python reported no SwapEnd site at all: \(reference.output)"
        )
        #expect(mine.siteVMA == referenceVMA)
        #expect(mine.targetSize == targetSize)

        // And, the part that actually matters: identical caches.
        let differing = try CacheComparison.differingFiles(pythonClone, swiftClone)
        #expect(differing.isEmpty, "chunks differ between Swift and Python: \(differing)")

        // A patch that changed nothing would also pass the comparison above, so
        // pin what changed relative to the untouched cache.
        let touched = try CacheComparison.differingFiles(pristine, swiftClone)
        if mine.sitesWritten == 0 {
            #expect(touched.isEmpty, "nothing should have been written, but \(touched) changed")
        } else {
            #expect(
                touched.count == 1,
                "expected exactly one chunk to change, got \(touched)"
            )
            let reattested = try #require(mine.reattestation)
            #expect(reattested.updated.count == 1)
            #expect(reattested.isFullyAttested)
        }

        print(
            "[parity 0x\(suffix)] python \(reference.sitesWritten) site(s), "
                + "swift \(mine.sitesWritten) site(s) "
                + "(0x\(String(mine.originalSize, radix: 16, uppercase: true)) -> "
                + "0x\(String(mine.targetSize, radix: 16, uppercase: true)) at "
                + "0x\(String(mine.siteVMA, radix: 16, uppercase: true))); "
                + "chunks changed: \(touched); swift vs python: identical"
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
        #expect(mine.siteVMA != 0)
        #expect(mine.originalSize != 0)

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
        #expect(functionVMA != 0)

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
        print(
            "[resolve] \(DSCIOMFBSwapEndPatcher.symbolName) @ "
                + "0x\(String(functionVMA, radix: 16, uppercase: true)), size move "
                + "0x\(String(size.immediate, radix: 16, uppercase: true)) @ "
                + "0x\(String(site.instruction.address, radix: 16, uppercase: true))"
        )
    }
}

// DSCIOMFBForceKernTests.swift — Parity for the IOMFB force-kern DSC patcher.
//
// There is no independent oracle for a patched dyld shared cache: `codesign -v`
// does not apply to a cache chunk, and nothing but the guest kernel reads the
// slot hashes. The only reference was
// `scripts/patchers/cfw_patch_iomfb_force_kern.py`, and that Python has been
// removed — so what it did on the real cache is frozen in `FrozenReference`
// below: the 35 entry points it discovered, the address it resolved for each,
// which four it refused to touch, and the SHA-256 of the one chunk it changed.
// The Swift runs on a clone and is graded against those. A port that writes a
// different number of sites, or the same number in different places, or
// re-attests a different set of pages, lands on a different digest.
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
import CryptoKit
import Foundation
import Testing

// MARK: - The frozen reference

/// What the reference Python found and wrote on the real 24A435 arm64e shared
/// cache.
///
/// Recorded from two live runs at commit 78cbeea:
///
///     .venv/bin/python3 scripts/patchers/cfw.py \
///         patch-iomfb-force-kern <clone of ipsws/ref_extract/dsc_pristine> [--dry-run]
private enum FrozenReference {
    /// One entry point, as the dry run named it:
    ///
    ///     [+] _IOMobileFramebufferSwapBegin @ 0x22AC0C1B0: \
    ///         'cbz x0, #0x22ac0c1c0' -> 'b _kern_SwapBegin' (0x22AC0C1CC)
    struct Pair {
        let publicName: String
        let publicAddress: UInt64
        let kernName: String
        let kernAddress: UInt64
    }

    /// The 31 `[+]` lines of the dry run, in the order it printed them, each
    /// giving the public entry point, its address, the kern sibling it would
    /// branch to and that sibling's address.
    static let forcedPairs: [Pair] = [
        Pair(publicName: "_IOMobileFramebufferSwapBegin",
             publicAddress: 0x2_2AC0_C1B0,
             kernName: "_kern_SwapBegin", kernAddress: 0x2_2AC0_C1CC),
        Pair(publicName: "_IOMobileFramebufferSwapCancel",
             publicAddress: 0x2_2AC1_23C8,
             kernName: "_kern_SwapCancel", kernAddress: 0x2_2AC3_D4AC),
        Pair(publicName: "_IOMobileFramebufferSwapCancelAll",
             publicAddress: 0x2_2AC1_24F4,
             kernName: "_kern_SwapCancelAll", kernAddress: 0x2_2AC1_2510),
        Pair(publicName: "_IOMobileFramebufferSwapCancelAllGetCurrent",
             publicAddress: 0x2_2AC1_2468,
             kernName: "_kern_SwapCancelAllGetCurrent", kernAddress: 0x2_2AC1_2484),
        Pair(publicName: "_IOMobileFramebufferSwapDebugInfo",
             publicAddress: 0x2_2AC0_C734,
             kernName: "_kern_SwapDebugInfo", kernAddress: 0x2_2AC0_C328),
        Pair(publicName: "_IOMobileFramebufferSwapEnd",
             publicAddress: 0x2_2AC0_C750,
             kernName: "_kern_SwapEnd", kernAddress: 0x2_2AC0_C334),
        Pair(publicName: "_IOMobileFramebufferSwapGetCurrent",
             publicAddress: 0x2_2AC3_A85C,
             kernName: "_kern_SwapGetCurrent", kernAddress: 0x2_2AC3_D518),
        Pair(publicName: "_IOMobileFramebufferSwapSecureLayer",
             publicAddress: 0x2_2AC3_A528,
             kernName: "_kern_SwapSecureLayer", kernAddress: 0x2_2AC3_CB9C),
        Pair(publicName: "_IOMobileFramebufferSwapSetAmbientLux",
             publicAddress: 0x2_2AC0_D0F4,
             kernName: "_kern_SwapSetAmbientLux", kernAddress: 0x2_2AC0_D110),
        Pair(publicName: "_IOMobileFramebufferSwapSetBrightness",
             publicAddress: 0x2_2AC0_D214,
             kernName: "_kern_SwapSetBrightness", kernAddress: 0x2_2AC0_D230),
        Pair(publicName: "_IOMobileFramebufferSwapSetBrightnessLimit",
             publicAddress: 0x2_2AC1_25B0,
             kernName: "_kern_SwapSetBrightnessLimit", kernAddress: 0x2_2AC1_25CC),
        Pair(publicName: "_IOMobileFramebufferSwapSetColorMatrix",
             publicAddress: 0x2_2AC3_A800,
             kernName: "_kern_SwapSetColorMatrix", kernAddress: 0x2_2AC3_D2E0),
        Pair(publicName: "_IOMobileFramebufferSwapSetDisplayEdr",
             publicAddress: 0x2_2AC1_2634,
             kernName: "_kern_SwapSetDisplayEdr", kernAddress: 0x2_2AC1_2650),
        Pair(publicName: "_IOMobileFramebufferSwapSetDisplayEdrHeadroom",
             publicAddress: 0x2_2AC1_278C,
             kernName: "_kern_SwapSetDisplayEdrHeadroom", kernAddress: 0x2_2AC1_2724),
        Pair(publicName: "_IOMobileFramebufferSwapSetEventSignal",
             publicAddress: 0x2_2AC0_BE50,
             kernName: "_kern_SwapSetEventSignal", kernAddress: 0x2_2AC0_CEBC),
        Pair(publicName: "_IOMobileFramebufferSwapSetEventSignalOnGlass",
             publicAddress: 0x2_2AC3_A560,
             kernName: "_kern_SwapSetEventSignalOnGlass", kernAddress: 0x2_2AC3_CDB0),
        Pair(publicName: "_IOMobileFramebufferSwapSetEventWait",
             publicAddress: 0x2_2AC0_BE6C,
             kernName: "_kern_SwapSetEventWait", kernAddress: 0x2_2AC0_BF58),
        Pair(publicName: "_IOMobileFramebufferSwapSetIndicatorBrightnessLimit",
             publicAddress: 0x2_2AC1_2594,
             kernName: "_kern_SwapSetIndicatorBrightnessLimit", kernAddress: 0x2_2AC1_26B8),
        Pair(publicName: "_IOMobileFramebufferSwapSetLFCTimestamps",
             publicAddress: 0x2_2AC3_A7AC,
             kernName: "_kern_SwapSetLFCTimestamps", kernAddress: 0x2_2AC3_DA6C),
        Pair(publicName: "_IOMobileFramebufferSwapSetLayer",
             publicAddress: 0x2_2AC0_CEA0,
             kernName: "_kern_SwapSetLayer", kernAddress: 0x2_2AC0_C8F4),
        Pair(publicName: "_IOMobileFramebufferSwapSetLayerEDRCompensation",
             publicAddress: 0x2_2AC0_C194,
             kernName: "_kern_SwapSetLayerEDRCompensation", kernAddress: 0x2_2AC0_BE88),
        Pair(publicName: "_IOMobileFramebufferSwapSetPostBlendLayer",
             publicAddress: 0x2_2AC3_A544,
             kernName: "_kern_SwapSetPostBlendLayer", kernAddress: 0x2_2AC3_CC3C),
        Pair(publicName: "_IOMobileFramebufferSwapSetPostBlendLayerEventSignal",
             publicAddress: 0x2_2AC3_A5B4,
             kernName: "_kern_SwapSetPostBlendLayerEventSignal", kernAddress: 0x2_2AC3_CE98),
        Pair(publicName: "_IOMobileFramebufferSwapSetPostBlendLayerEventSignalOnGlass",
             publicAddress: 0x2_2AC3_A598,
             kernName: "_kern_SwapSetPostBlendLayerEventSignalOnGlass",
             kernAddress: 0x2_2AC3_CE58),
        Pair(publicName: "_IOMobileFramebufferSwapSetPostBlendLayerEventWait",
             publicAddress: 0x2_2AC3_A57C,
             kernName: "_kern_SwapSetPostBlendLayerEventWait", kernAddress: 0x2_2AC3_CDE8),
        Pair(publicName: "_IOMobileFramebufferSwapSetPulseWidthMaximization",
             publicAddress: 0x2_2AC4_1AC0,
             kernName: "_kern_SwapSetPulseWidthMaximization", kernAddress: 0x2_2AC3_D1F4),
        Pair(publicName: "_IOMobileFramebufferSwapSetResTransitionStrength",
             publicAddress: 0x2_2AC4_1ADC,
             kernName: "_kern_SwapSetResTransitionStrength", kernAddress: 0x2_2AC3_D238),
        Pair(publicName: "_IOMobileFramebufferSwapSetSecureAnimation",
             publicAddress: 0x2_2AC0_F354,
             kernName: "_kern_SwapSetSecureAnimation", kernAddress: 0x2_2AC0_F370),
        Pair(publicName: "_IOMobileFramebufferSwapSubtitleRegion",
             publicAddress: 0x2_2AC3_A720,
             kernName: "_kern_SwapSubtitleRegion", kernAddress: 0x2_2AC3_CF08),
        Pair(publicName: "_IOMobileFramebufferSwapWait",
             publicAddress: 0x2_2AC0_C298,
             kernName: "_kern_SwapWait", kernAddress: 0x2_2AC0_C2B4),
        Pair(publicName: "_IOMobileFramebufferSwapWaitWithTimeout",
             publicAddress: 0x2_2AC3_A840,
             kernName: "_kern_SwapWaitWithTimeout", kernAddress: 0x2_2AC3_D420),
    ]

    /// The four `[=] … not a thin trampoline; leaving on virt path` lines. The
    /// reference discovered these and deliberately declined to rewrite them, so
    /// a shape check that accepted everything would disagree here.
    static let leftOnVirtPath: [String] = [
        "_IOMobileFramebufferSwapSetBlit",
        "_IOMobileFramebufferSwapSetIndicatorBrightness",
        "_IOMobileFramebufferSwapSetParams",
        "_IOMobileFramebufferSwapSignal",
    ]

    /// Python: `IOMFB force-kern complete: 31 newly forced, 0 already -> _kern_*`.
    static let newlyForced = 31

    /// Every entry point the reference considered — the 31 it forced plus the
    /// four it left alone.
    static var discoveredNames: Set<String> {
        Set(forcedPairs.map(\.publicName)).union(leftOnVirtPath)
    }

    static var publicAddressesByName: [String: UInt64] {
        Dictionary(uniqueKeysWithValues: forcedPairs.map { ($0.publicName, $0.publicAddress) })
    }

    /// `cmp -s` against the pristine tree after the wet run: exactly one chunk
    /// moved, to this digest, from `shasum -a 256 <output>/…arm64e.38`.
    ///
    /// The digest covers the re-attestation as well as the 31 branches — the
    /// Python logged `re-attesting 31 modified page(s)…` and then `re-attest:
    /// updated 5 slot hash(es) across 1 chunk(s)` (slots 2562, 2563, 2564,
    /// 2574 and 2576 of `dyld_shared_cache_arm64e.38`).
    ///
    /// Two further runs pinned the edges. Re-run over its own output: `all 31
    /// entrypoint(s) already forced; nothing to patch/re-attest`, `0 newly
    /// forced, 31 already`, and this digest unchanged. `--dry-run` on a fresh
    /// clone: the 31 `[+]` lines above, `would re-attest 31 page(s)`, and no
    /// chunk changed at all.
    static let changedChunks: [String: String] = [
        "dyld_shared_cache_arm64e.38":
            "7cb82d8c33f1949197cf95aaf2286c76c4ecb85826d40f66437d33e707e3f879",
    ]
}

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
        // Per-suite leaf on BOTH branches: the override is a base shared with
        // the other DSC suites, and they reuse the same clone names.
        if let override = ProcessInfo.processInfo.environment["VPHONE_DSC_SCRATCH"] {
            return URL(fileURLWithPath: override).appendingPathComponent("scratch_dsc_forcekern")
        }
        return repoRoot.appendingPathComponent("ipsws/scratch_dsc_forcekern")
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

    /// SHA-256 of every chunk file, so "nothing changed" is checkable without
    /// keeping a second copy around.
    static func chunkDigests(of directory: URL) throws -> [String: String] {
        var digests: [String: String] = [:]
        for name in try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted() {
            digests[name] = try sha256(of: directory.appendingPathComponent(name))
        }
        return digests
    }

    /// Assert that `directory` holds exactly the chunks the reference changed,
    /// with exactly the reference's bytes.
    static func expectMatchesReference(_ directory: URL) throws {
        let pristine = try #require(ForceKernFixture.pristine, ForceKernFixture.missing)
        let pristineDigests = try chunkDigests(of: pristine)
        let mine = try chunkDigests(of: directory)
        let changed = mine.filter { pristineDigests[$0.key] != $0.value }.keys.sorted()
        #expect(changed == FrozenReference.changedChunks.keys.sorted())
        for name in changed {
            let frozen = FrozenReference.changedChunks[name] ?? "(not a chunk the Python moved)"
            #expect(mine[name] == frozen, "\(name): Swift \(mine[name] ?? "—"), reference \(frozen)")
        }
    }
}

// MARK: - Parity against the frozen reference

@Suite(.serialized, .enabled(if: ForceKernFixture.runs, ForceKernFixture.skipReason))
struct DSCIOMFBForceKernParityTests {
    /// The one test that decides whether this port is done.
    @Test("Swift force-kern reproduces the reference cache byte for byte")
    func matchesReferenceByteForByte() throws {
        _ = try #require(ForceKernFixture.pristine, ForceKernFixture.missing)

        let swiftClone = try ForceKernFixture.cloneCache(named: "swift")
        defer { ForceKernFixture.discard(swiftClone) }

        let outcome = try DSCIOMFBForceKernPatcher.patch(
            chunksDirectory: swiftClone,
            log: nil
        )

        #expect(
            outcome.writtenSiteCount == FrozenReference.newlyForced,
            "swift wrote \(outcome.writtenSiteCount) sites, reference \(FrozenReference.newlyForced)"
        )
        // The same entry points, not merely the same count.
        #expect(
            Set(outcome.forced.map(\.entry.publicName))
                == Set(FrozenReference.forcedPairs.map(\.publicName))
        )
        #expect(Set(outcome.notTrampolines.map(\.entry.publicName))
            == Set(FrozenReference.leftOnVirtPath))

        try Digest.expectMatchesReference(swiftClone)
    }

    /// The reference's own idempotence claim: a second pass over a cache this
    /// patch already forced must write nothing and leave every byte alone. The
    /// Python printed `all 31 entrypoint(s) already forced; nothing to
    /// patch/re-attest` here, with its digest unchanged.
    @Test("A second run is a no-op on an already-forced cache")
    func secondRunIsANoOp() throws {
        _ = try #require(ForceKernFixture.pristine, ForceKernFixture.missing)

        let clone = try ForceKernFixture.cloneCache(named: "idempotence")
        defer { ForceKernFixture.discard(clone) }

        let first = try DSCIOMFBForceKernPatcher.patch(chunksDirectory: clone, log: nil)
        #expect(first.writtenSiteCount == FrozenReference.newlyForced)

        let hashesBefore = try Digest.chunkDigests(of: clone)
        let second = try DSCIOMFBForceKernPatcher.patch(chunksDirectory: clone, log: nil)

        #expect(second.writtenSiteCount == 0, "a second pass rewrote \(second.writtenSiteCount) site(s)")
        #expect(second.reattestation == nil, "a second pass re-attested pages it did not dirty")
        #expect(second.alreadyForced.count == FrozenReference.newlyForced)
        let hashesAfter = try Digest.chunkDigests(of: clone)
        #expect(hashesAfter == hashesBefore, "a no-op run changed bytes")

        try Digest.expectMatchesReference(clone)
    }

    /// A dry run must classify everything and touch nothing.
    @Test("A dry run reports the reference's sites and writes no bytes")
    func dryRunWritesNothing() throws {
        _ = try #require(ForceKernFixture.pristine, ForceKernFixture.missing)

        let clone = try ForceKernFixture.cloneCache(named: "dryrun")
        defer { ForceKernFixture.discard(clone) }

        let hashesBefore = try Digest.chunkDigests(of: clone)
        let dry = try DSCIOMFBForceKernPatcher.patch(
            chunksDirectory: clone,
            dryRun: true,
            log: nil
        )
        #expect(dry.writtenSiteCount == FrozenReference.newlyForced)
        #expect(dry.records.isEmpty)
        #expect(dry.reattestation == nil)
        let hashesAfter = try Digest.chunkDigests(of: clone)
        #expect(hashesAfter == hashesBefore, "a dry run wrote to the cache")

        let wet = try DSCIOMFBForceKernPatcher.patch(chunksDirectory: clone, log: nil)
        #expect(wet.writtenSiteCount == dry.writtenSiteCount)
    }
}

// MARK: - Discovery and classification

@Suite(.serialized, .enabled(if: ForceKernFixture.runs, ForceKernFixture.skipReason))
struct DSCIOMFBForceKernDiscoveryTests {
    /// Discovery has to agree with the reference's, which read the same image
    /// through `ipsw dyld symaddr`. Compared here without `ipsw`: the pairs the
    /// resolver finds are the pairs the reference logged.
    @Test("Every discovered pair matches the reference's, name and address")
    func discoveryMatchesReference() throws {
        let pristine = try #require(ForceKernFixture.pristine, ForceKernFixture.missing)

        let resolver = try DSCSymbolResolver(
            mainCacheURL: pristine.appendingPathComponent("dyld_shared_cache_arm64e")
        )
        let entries = try DSCIOMFBForceKernPatcher.discoverEntryPoints(resolver: resolver)
        #expect(entries.count >= DSCIOMFBForceKernPatcher.requiredSuffixes.count)

        let discovered = Set(entries.map(\.publicName))
        let expected = FrozenReference.discoveredNames
        let disagreement = discovered.symmetricDifference(expected).sorted()
        #expect(discovered == expected, "discovery differs from the reference: \(disagreement)")

        // The 31 the reference resolved an address for — it printed no address
        // for the four it left on the virt path.
        let byName = Dictionary(uniqueKeysWithValues: entries.map { ($0.publicName, $0) })
        for pair in FrozenReference.forcedPairs {
            let entry = try #require(byName[pair.publicName], "\(pair.publicName) was not discovered")
            let mine = String(entry.publicAddress, radix: 16, uppercase: true)
            let theirs = String(pair.publicAddress, radix: 16, uppercase: true)
            #expect(
                entry.publicAddress == pair.publicAddress,
                "\(pair.publicName): swift 0x\(mine) vs reference 0x\(theirs)"
            )
            // …and the sibling it would branch to, which is the half of the
            // pair a name-only comparison would miss.
            #expect(entry.kernName == pair.kernName)
            #expect(entry.kernAddress == pair.kernAddress)
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
    /// reference left four entry points on the virt path on this cache, and so
    /// must this. A matcher that accepted everything would still pass the byte
    /// comparison only if it happened to agree — it does not, so pin it.
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

        #expect(
            dry.notTrampolines.map(\.entry.publicName).sorted()
                == FrozenReference.leftOnVirtPath.sorted()
        )
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
        let kernAddresses = Dictionary(
            uniqueKeysWithValues: FrozenReference.forcedPairs.map { ($0.publicAddress, $0.kernAddress) }
        )
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
            // …and it lands on the kern sibling the reference named for this
            // entry point, rather than merely on some branch.
            let target = try #require(kernAddresses[address], "0x\(String(address, radix: 16)) is not a reference site")
            let expected = "0x\(String(target, radix: 16))"
            let site = "0x\(String(address, radix: 16))"
            #expect(
                instruction.operandString == expected,
                "\(site) branches to \(instruction.operandString), reference paired it with \(expected)"
            )
        }
    }
}

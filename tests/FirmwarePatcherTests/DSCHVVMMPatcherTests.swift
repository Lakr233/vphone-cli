// DSCHVVMMPatcherTests.swift — Python-vs-Swift parity for the hv_vmm_present
// user-mode cstring mangle.
//
// There is no external oracle for this patch. `codesign -v` does not apply to a
// dyld shared cache chunk, and the only statement of what the patch should do is
// `scripts/patchers/cfw_patch_hv_vmm_dsc.py` plus the module it imports its
// constants from, `cfw_patch_hv_vmm.py`. So the test is not "does the Swift
// write 29 sites" — that number is this repo's own claim. It is: run the
// reference on one clone of the real cache, the Swift on another, and require
// the two 6.7 GB trees to come out byte for byte identical, chunk files and
// re-attested code directories alike.
//
// The fixture is the real 24A435 arm64e cache. Point `VPHONE_DSC_PRISTINE` at a
// directory of `dyld_shared_cache_arm64e*` chunks, or leave the default
// `ipsws/ref_extract/dsc_pristine` in place.
//
// Without it these tests FAIL. A `guard … else { return }` would be reported by
// Swift Testing as a pass, so on a machine that never extracted the cache a
// green run would mean nothing. A machine that genuinely cannot carry the
// fixture sets `VPHONE_DSC_FIXTURE_OPTIONAL=1` and gets a visible *skip*
// instead.
//
// Nothing here writes to the pristine directory, or anywhere else inside it.
// Clones go to `VPHONE_DSC_SCRATCH`, or to the system temporary directory, and
// are made with `clonefile` so a 6.7 GB copy is instant and costs almost no
// disk.

@testable import FirmwarePatcher
import Foundation
import Testing

// MARK: - Fixture discovery

private enum HVVMMFixture {
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

    /// Pristine standalone Mach-Os, for the other half of the port.
    static func machO(_ name: String) -> URL? {
        let url = repoRoot
            .appendingPathComponent("ipsws/ref_extract/macho_pristine")
            .appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Opt-out for a machine that cannot carry the fixture. Set it and the
    /// suites report as skipped; leave it unset and a missing cache is a
    /// failure, which is the only reading of "green" this layer can afford.
    static var isOptional: Bool {
        ProcessInfo.processInfo.environment["VPHONE_DSC_FIXTURE_OPTIONAL"] == "1"
    }

    /// The suites run unless the cache is absent *and* the caller opted out.
    static var runs: Bool { pristine != nil || !isOptional }

    /// Same rule for the standalone Mach-O fixtures, which live under the same
    /// gitignored `ipsws/` tree and are therefore absent on a fresh clone.
    static var machORuns: Bool {
        (machO("watchdogd") != nil && machO("mobileactivationd") != nil) || !isOptional
    }

    static let machOSkipReason: Comment =
        "VPHONE_DSC_FIXTURE_OPTIONAL=1 and no ipsws/ref_extract/macho_pristine binaries present"

    static let missing: Comment = """
    the real 24A435 arm64e shared cache is required — put it at \
    ipsws/ref_extract/dsc_pristine, point VPHONE_DSC_PRISTINE at it, or set \
    VPHONE_DSC_FIXTURE_OPTIONAL=1 to skip these tests instead of failing
    """

    static let skipReason: Comment =
        "VPHONE_DSC_FIXTURE_OPTIONAL=1 and no dyld_shared_cache_arm64e fixture present"

    /// Where clones are made.
    ///
    /// Deliberately NOT inside `ipsws/ref_extract/`: that tree is the pristine
    /// reference the whole suite compares against, and a scratch directory next
    /// to it is one `rm -rf` typo away from destroying a 6.7 GB extraction
    /// nobody wants to redo. `VPHONE_DSC_SCRATCH` overrides, for a host whose
    /// temporary directory is on a different volume from the cache and would
    /// therefore turn `clonefile` into a real copy.
    static var scratchRoot: URL {
        if let override = ProcessInfo.processInfo.environment["VPHONE_DSC_SCRATCH"] {
            return URL(fileURLWithPath: override)
        }
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("vphone-hvvmm-parity")
    }

    /// The project venv, which is where the reference Python lives.
    static var python: URL? {
        let url = repoRoot.appendingPathComponent(".venv/bin/python3")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    static let pythonMissing: Comment = """
    the project venv is required — the reference implementation is the only \
    oracle this patch has. Create it with `make setup_venv`.
    """

    /// Clone the pristine cache into a fresh directory the caller may write to.
    static func cloneCache(named name: String) throws -> URL {
        guard let pristine else { throw CocoaError(.fileNoSuchFile) }
        let destination = scratchRoot.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.createDirectory(
            at: destination,
            withIntermediateDirectories: true
        )
        let sources = try FileManager.default
            .contentsOfDirectory(atPath: pristine.path)
            .sorted()
            .map { pristine.appendingPathComponent($0).path }

        // `-c` asks for clonefile. On a host where the scratch directory is on
        // another volume that fails outright, so fall back to a real copy rather
        // than reporting a fixture problem as a patch failure.
        var result = try Subprocess.run(
            executable: URL(fileURLWithPath: "/bin/cp"),
            arguments: ["-c", "-R"] + sources + [destination.path]
        )
        if result.status != 0 {
            result = try Subprocess.run(
                executable: URL(fileURLWithPath: "/bin/cp"),
                arguments: ["-R"] + sources + [destination.path]
            )
        }
        guard result.status == 0 else { throw CocoaError(.fileWriteUnknown) }
        return destination
    }

    /// Copy one file into scratch under a fresh name.
    static func copyFile(_ source: URL, named name: String) throws -> URL {
        try FileManager.default.createDirectory(
            at: scratchRoot,
            withIntermediateDirectories: true
        )
        let destination = scratchRoot.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.copyItem(at: source, to: destination)
        return destination
    }

    /// Discard clones, and the scratch root with them once the last one is gone,
    /// so a test run leaves the tree as it found it.
    static func discard(_ items: URL...) {
        for item in items {
            try? FileManager.default.removeItem(at: item)
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
        // Drain before waiting: the reference prints a line per site, and a full
        // pipe buffer would deadlock the run.
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

// MARK: - Byte-for-byte tree comparison

private enum TreeComparison {
    /// Files present in one tree but not the other, and files whose bytes differ.
    struct Difference: CustomStringConvertible {
        var onlyInLeft: [String] = []
        var onlyInRight: [String] = []
        var differingBytes: [String] = []

        var isEmpty: Bool {
            onlyInLeft.isEmpty && onlyInRight.isEmpty && differingBytes.isEmpty
        }

        var description: String {
            var parts: [String] = []
            if !onlyInLeft.isEmpty { parts.append("only in left: \(onlyInLeft)") }
            if !onlyInRight.isEmpty { parts.append("only in right: \(onlyInRight)") }
            if !differingBytes.isEmpty { parts.append("bytes differ: \(differingBytes)") }
            return parts.isEmpty ? "identical" : parts.joined(separator: "; ")
        }
    }

    /// Compare two directories file by file, byte by byte.
    ///
    /// `cmp` rather than a digest: it stops at the first differing byte, so a
    /// tree that really does differ is reported in milliseconds instead of after
    /// hashing 6.7 GB twice.
    static func compare(_ left: URL, _ right: URL) throws -> Difference {
        let leftNames = Set(try FileManager.default.contentsOfDirectory(atPath: left.path))
        let rightNames = Set(try FileManager.default.contentsOfDirectory(atPath: right.path))

        var difference = Difference()
        difference.onlyInLeft = leftNames.subtracting(rightNames).sorted()
        difference.onlyInRight = rightNames.subtracting(leftNames).sorted()

        for name in leftNames.intersection(rightNames).sorted() {
            let result = try Subprocess.run(
                executable: URL(fileURLWithPath: "/usr/bin/cmp"),
                arguments: [
                    "-s",
                    left.appendingPathComponent(name).path,
                    right.appendingPathComponent(name).path,
                ]
            )
            if result.status != 0 { difference.differingBytes.append(name) }
        }
        return difference
    }
}

// MARK: - The reference Python, driven as an oracle

/// A driver around `cfw_patch_hv_vmm_dsc` / `cfw_patch_hv_vmm`, written to a
/// temp file at test time.
///
/// It adds no logic of its own: it calls the reference entry points and prints
/// what they return. That is the point — the comparison has to be against that
/// code running, not against a transcription of it.
private enum PythonOracle {
    static let source = #"""
import contextlib
import json
import os
import sys

sys.path.insert(0, os.path.join(sys.argv[1], "scripts"))

from patchers.cfw_patch_hv_vmm import (
    NEEDLE, MANGLED_NEEDLE, MANGLE_OFFSET, ORIGINAL_BYTE, MANGLED_BYTE,
    find_string_sites, patch_hv_vmm,
)
from patchers.cfw_patch_hv_vmm_dsc import (
    DONT_PATCH_INSTALL_NAMES, patch_hv_vmm_in_dsc,
)

command = sys.argv[2]

if command == "constants":
    print(json.dumps({
        "needle": NEEDLE.hex(),
        "mangled_needle": MANGLED_NEEDLE.hex(),
        "mangle_offset": MANGLE_OFFSET,
        "original_byte": ORIGINAL_BYTE.hex(),
        "mangled_byte": MANGLED_BYTE.hex(),
        "blacklist": list(DONT_PATCH_INSTALL_NAMES),
    }))

elif command == "patch_dsc":
    # argv[3] = chunks dir, argv[4] = "1" for a dry run.
    dry_run = len(sys.argv) > 4 and sys.argv[4] == "1"
    # The patcher narrates to stdout; keep that on stderr so stdout is JSON.
    with contextlib.redirect_stdout(sys.stderr):
        results = patch_hv_vmm_in_dsc(sys.argv[3], dry_run=dry_run)
    print(json.dumps({"results": results}))

elif command == "macho_sites":
    with open(sys.argv[3], "rb") as f:
        data = f.read()
    print(json.dumps({"sites": find_string_sites(data)}))

elif command == "patch_macho":
    with contextlib.redirect_stdout(sys.stderr):
        count = patch_hv_vmm(sys.argv[3], dry_run=False)
    print(json.dumps({"count": count}))

else:
    raise SystemExit(f"unknown command {command}")
"""#

    static func scriptURL() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "hv_vmm_oracle_\(ProcessInfo.processInfo.processIdentifier).py"
            )
        if !FileManager.default.fileExists(atPath: url.path) {
            try source.write(to: url, atomically: true, encoding: .utf8)
        }
        return url
    }

    static func run(_ command: String, _ extra: [String] = []) throws -> Data {
        guard let python = HVVMMFixture.python else { throw CocoaError(.fileNoSuchFile) }
        let script = try scriptURL()
        let result = try Subprocess.run(
            executable: python,
            arguments: [script.path, HVVMMFixture.repoRoot.path, command] + extra
        )
        guard result.status == 0 else {
            Issue.record("python oracle \(command) failed: \(result.stderr)")
            throw CocoaError(.fileReadUnknown)
        }
        return Data(result.stdout.utf8)
    }

    struct Constants: Decodable {
        let needle: String
        let mangled_needle: String
        let mangle_offset: Int
        let original_byte: String
        let mangled_byte: String
        let blacklist: [String]
    }

    struct DSCRun: Decodable {
        let results: [String: Int]
    }

    struct MachOSites: Decodable {
        struct Site: Decodable {
            let string_vma: UInt64
            let file_offset: Int
            let section: String
        }

        let sites: [Site]
    }

    struct MachORun: Decodable {
        let count: Int
    }
}

// MARK: - Constants

/// No cache fixture here, so no fixture gate: the only thing this suite needs is
/// the venv that holds the reference modules, and a missing venv has to fail
/// rather than skip — without it there is no oracle and nothing was checked.
@Suite(.serialized)
struct DSCHVVMMConstantsTests {
    @Test("The cstring, its mangle and the blacklist match the reference modules")
    func constantsMatchPython() throws {
        try #require(HVVMMFixture.python != nil, HVVMMFixture.pythonMissing)
        let reference = try JSONDecoder().decode(
            PythonOracle.Constants.self,
            from: PythonOracle.run("constants")
        )

        #expect(DSCHVVMMPatcher.needle.hex == reference.needle)
        #expect(DSCHVVMMPatcher.mangledNeedle.hex == reference.mangled_needle)
        #expect(DSCHVVMMPatcher.mangleOffset == reference.mangle_offset)
        #expect(Data([DSCHVVMMPatcher.originalByte]).hex == reference.original_byte)
        #expect(Data([DSCHVVMMPatcher.mangledByte]).hex == reference.mangled_byte)
        #expect(DSCHVVMMPatcher.dontPatchInstallNames == reference.blacklist)

        // The mangle has to preserve the namespace prefix, or the name cannot
        // resolve to any OID — see the patcher's file comment. This is the one
        // property of the patch that is not a transcription of the reference.
        let prefix = Data(DSCHVVMMPatcher.sysctlNamespace.utf8)
        #expect(DSCHVVMMPatcher.needle.prefix(prefix.count) == prefix)
        #expect(DSCHVVMMPatcher.mangledNeedle.prefix(prefix.count) == prefix)
        #expect(DSCHVVMMPatcher.needle.count == DSCHVVMMPatcher.mangledNeedle.count)
        let differing = zip(DSCHVVMMPatcher.needle, DSCHVVMMPatcher.mangledNeedle)
            .enumerated()
            .filter { $0.element.0 != $0.element.1 }
            .map(\.offset)
        #expect(differing == [DSCHVVMMPatcher.mangleOffset])
    }
}

// MARK: - The real cache

@Suite(.serialized, .enabled(if: HVVMMFixture.runs, HVVMMFixture.skipReason))
struct DSCHVVMMCacheParityTests {
    /// The parity gate.
    ///
    /// Reference on one clone, Swift on another, then require the two trees to
    /// be byte identical — every chunk file, including the code directories the
    /// re-attestation pass rewrote. A port that writes a different number of
    /// sites, or the same number in different places, or the right bytes with
    /// the wrong page re-hashed, fails here.
    ///
    /// The idempotence and blacklist checks ride on the same clones rather than
    /// cloning 6.7 GB again for each: they are assertions about the state this
    /// test has already produced.
    @Test("The Swift patch and the Python reference produce identical caches")
    func swiftMatchesPythonOnTheRealCache() throws {
        _ = try #require(HVVMMFixture.pristine, HVVMMFixture.missing)
        try #require(HVVMMFixture.python != nil, HVVMMFixture.pythonMissing)

        let pythonClone = try HVVMMFixture.cloneCache(named: "python")
        let swiftClone = try HVVMMFixture.cloneCache(named: "swift")
        defer { HVVMMFixture.discard(pythonClone, swiftClone) }

        let reference = try JSONDecoder().decode(
            PythonOracle.DSCRun.self,
            from: PythonOracle.run("patch_dsc", [pythonClone.path])
        )
        let result = try DSCHVVMMPatcher.patch(chunksDirectory: swiftClone, log: nil)

        // Same verdict per dylib, including the zero-count entries that record
        // "seen and deliberately left alone".
        #expect(result.mangledCountByInstallName == reference.results)

        let referenceTotal = reference.results.values.reduce(0, +)
        #expect(result.mangled == referenceTotal)
        #expect(result.mangled > 0, "the reference patched nothing — wrong fixture?")
        #expect(result.skippedInBlacklist == DSCHVVMMPatcher.dontPatchInstallNames.count)
        #expect(result.skippedUnclassified == 0)
        #expect(result.refused == 0)
        #expect(result.isFullyAttested)
        // One slot per dirtied page, and no site left unattested. Sites can in
        // principle share a page, so this is a bound rather than an equality —
        // the tree comparison below is what actually pins the code directories.
        let slotsRewritten = result.reattestation?.updated.count ?? 0
        #expect(slotsRewritten > 0)
        #expect(slotsRewritten <= result.mangled)
        print(
            "[hv_vmm] python \(referenceTotal) site(s), swift \(result.mangled) site(s), "
                + "\(result.skippedInBlacklist) blacklisted, "
                + "\(slotsRewritten) slot(s) re-attested"
        )

        let difference = try TreeComparison.compare(pythonClone, swiftClone)
        #expect(difference.isEmpty, "patched caches differ: \(difference)")

        // Idempotence, on the cache the Swift run just produced. A second pass
        // finds no pristine cstring left, queues the mangled ones so their slots
        // stay in sync, and must not move a byte.
        let second = try DSCHVVMMPatcher.patch(chunksDirectory: swiftClone, log: nil)
        #expect(second.mangled == 0)
        #expect(second.pristineSiteCount == result.skippedInBlacklist)
        #expect(second.alreadyMangledSiteCount == result.mangled)
        #expect(second.reattestOnly == result.mangled)
        #expect(second.blacklistDrift == 0)
        #expect(second.reattestation?.updated.isEmpty == true)
        let afterRerun = try TreeComparison.compare(pythonClone, swiftClone)
        #expect(afterRerun.isEmpty, "a second run moved bytes: \(afterRerun)")

        // The blacklist is the whole point of the design, so check it against
        // the bytes rather than against the run's own bookkeeping: every
        // blacklisted dylib in the cache must still hold the pristine cstring.
        let chunks = try DSCChunkSet(directory: swiftClone)
        var blacklistedSitesSeen = 0
        for vma in try chunks.findStringVMAs(DSCHVVMMPatcher.needle) {
            let installName = try #require(
                DSCHVVMMPatcher.classify(vma, in: chunks),
                "a pristine cstring survived in a dylib that cannot be named"
            )
            #expect(
                DSCHVVMMPatcher.dontPatchSet.contains(installName),
                "\(installName) is not blacklisted but kept the original cstring"
            )
            blacklistedSitesSeen += 1
        }
        #expect(blacklistedSitesSeen == result.skippedInBlacklist)

        for vma in try chunks.findStringVMAs(DSCHVVMMPatcher.mangledNeedle) {
            let installName = try #require(DSCHVVMMPatcher.classify(vma, in: chunks))
            #expect(
                !DSCHVVMMPatcher.dontPatchSet.contains(installName),
                "\(installName) is blacklisted but was mangled"
            )
        }
    }

    @Test("A dry run reports the same sites and leaves every byte alone")
    func dryRunTouchesNothing() throws {
        let pristine = try #require(HVVMMFixture.pristine, HVVMMFixture.missing)
        try #require(HVVMMFixture.python != nil, HVVMMFixture.pythonMissing)

        let clone = try HVVMMFixture.cloneCache(named: "dryrun")
        defer { HVVMMFixture.discard(clone) }

        let result = try DSCHVVMMPatcher.patch(
            chunksDirectory: clone,
            dryRun: true,
            log: nil
        )
        #expect(result.mangled > 0)
        // A dry run writes nothing, so every page still hashes to exactly what
        // its slot says and no slot would be rewritten. What has to be true is
        // that the pass REACHED every page the patch would dirty — otherwise a
        // dry run would be quietly narrower than the real thing.
        #expect(result.reattestation?.updated.isEmpty == true)
        let pagesReached = result.reattestation?.pagesAttested ?? 0
        #expect(pagesReached > 0)
        #expect(pagesReached <= result.mangled)
        #expect(result.isFullyAttested)

        let difference = try TreeComparison.compare(pristine, clone)
        #expect(difference.isEmpty, "a dry run wrote to the cache: \(difference)")

        // And the same for the reference, so "dry run changes nothing" is a
        // property of both implementations and not just of this one.
        _ = try PythonOracle.run("patch_dsc", [clone.path, "1"])
        let afterPython = try TreeComparison.compare(pristine, clone)
        #expect(afterPython.isEmpty, "the reference dry run wrote too: \(afterPython)")
    }

    /// The drift branch, which is the one deliberate behaviour in this patch that
    /// a port could plausibly get backwards.
    ///
    /// A blacklisted dylib found already mangled means somebody took it out of
    /// the blacklist, ran the patch, and put it back. The reference does NOT
    /// revert the byte and does NOT refuse: it says so loudly and re-attests the
    /// page to the bytes that are actually there, because reverting would leave
    /// the page hash right and the operator's intent wrong. A port that "fixed"
    /// this by reverting, or by treating it as an error, would pass every other
    /// test in this file.
    @Test("A blacklisted dylib found mangled is reported as drift, not reverted")
    func blacklistDriftIsReportedNotReverted() throws {
        _ = try #require(HVVMMFixture.pristine, HVVMMFixture.missing)
        try #require(HVVMMFixture.python != nil, HVVMMFixture.pythonMissing)

        let pythonClone = try HVVMMFixture.cloneCache(named: "drift-python")
        let swiftClone = try HVVMMFixture.cloneCache(named: "drift-swift")
        defer { HVVMMFixture.discard(pythonClone, swiftClone) }

        // The lowest-addressed site inside a blacklisted dylib, so the choice is
        // the same on every run.
        let probe = try DSCChunkSet(directory: swiftClone)
        let driftVMA = try #require(
            try probe.findStringVMAs(DSCHVVMMPatcher.needle).sorted().first {
                guard let name = DSCHVVMMPatcher.classify($0, in: probe) else { return false }
                return DSCHVVMMPatcher.dontPatchSet.contains(name)
            },
            "no blacklisted dylib carries the cstring in this cache"
        )
        let driftedDylib = try #require(DSCHVVMMPatcher.classify(driftVMA, in: probe))

        // Mangle it by hand in both clones, without re-attesting — exactly the
        // state a prior out-of-band run would have left behind.
        for clone in [pythonClone, swiftClone] {
            let chunks = try DSCChunkSet(directory: clone)
            try chunks.write(
                at: driftVMA &+ UInt64(DSCHVVMMPatcher.mangleOffset),
                Data([DSCHVVMMPatcher.mangledByte])
            )
        }

        _ = try PythonOracle.run("patch_dsc", [pythonClone.path])
        let result = try DSCHVVMMPatcher.patch(chunksDirectory: swiftClone, log: nil)

        #expect(result.blacklistDrift == 1)
        #expect(result.alreadyMangledSiteCount == 1)
        #expect(result.reattestOnly == 0)
        #expect(result.refused == 0)
        #expect(
            result.skippedInBlacklist == DSCHVVMMPatcher.dontPatchInstallNames.count - 1,
            "the drifted site is no longer pristine, so it is not counted as skipped"
        )
        #expect(result.mangledCountByInstallName[driftedDylib] == nil)
        #expect(result.isFullyAttested)

        // Not reverted: the byte is still mangled afterwards.
        let after = try DSCChunkSet(directory: swiftClone)
            .bytesAtVMA(driftVMA, length: DSCHVVMMPatcher.needle.count)
        #expect(after == DSCHVVMMPatcher.mangledNeedle)

        let difference = try TreeComparison.compare(pythonClone, swiftClone)
        #expect(difference.isEmpty, "drift handling differs from the reference: \(difference)")
        print("[hv_vmm] drift on \(driftedDylib) at 0x\(String(driftVMA, radix: 16, uppercase: true))")
    }
}

// MARK: - Standalone Mach-O

@Suite(.serialized, .enabled(if: HVVMMFixture.machORuns, HVVMMFixture.machOSkipReason))
struct DSCHVVMMStandaloneTests {
    /// The other half of `cfw_patch_hv_vmm.py`, against the binaries the repo
    /// keeps pristine copies of.
    ///
    /// `watchdogd` carries one occurrence of the cstring and `mobileactivationd`
    /// two, so between them they cover the single-site and multi-site paths.
    @Test(
        "Standalone Mach-O mangling matches the reference",
        arguments: ["watchdogd", "mobileactivationd"]
    )
    func standaloneMatchesPython(name: String) throws {
        let pristine = try #require(
            HVVMMFixture.machO(name),
            """
            ipsws/ref_extract/macho_pristine/\(name) is required — it is the \
            only standalone Mach-O oracle this half of the port has
            """
        )
        try #require(HVVMMFixture.python != nil, HVVMMFixture.pythonMissing)

        let pythonCopy = try HVVMMFixture.copyFile(pristine, named: "\(name).python")
        let swiftCopy = try HVVMMFixture.copyFile(pristine, named: "\(name).swift")
        defer { HVVMMFixture.discard(pythonCopy, swiftCopy) }

        // Same sites, in the same order, before anything is written.
        let referenceSites = try JSONDecoder().decode(
            PythonOracle.MachOSites.self,
            from: PythonOracle.run("macho_sites", [pristine.path])
        ).sites
        let sites = try DSCHVVMMPatcher.findStringSites(
            inMachO: Data(contentsOf: pristine)
        )
        #expect(sites.count == referenceSites.count)
        #expect(!sites.isEmpty, "\(name) holds no kern.hv_vmm_present cstring")
        for (mine, theirs) in zip(sites, referenceSites) {
            #expect(mine.stringVMA == theirs.string_vma)
            #expect(mine.fileOffset == theirs.file_offset)
            #expect(mine.section == theirs.section)
        }

        let referenceCount = try JSONDecoder().decode(
            PythonOracle.MachORun.self,
            from: PythonOracle.run("patch_macho", [pythonCopy.path])
        ).count
        let count = try DSCHVVMMPatcher.patchStandaloneMachO(at: swiftCopy, log: nil)
        #expect(count == referenceCount)
        #expect(count == sites.count)

        let pristineBytes = try Data(contentsOf: pristine)
        let patchedByPython = try Data(contentsOf: pythonCopy)
        let patchedBySwift = try Data(contentsOf: swiftCopy)
        #expect(patchedByPython == patchedBySwift, "\(name): patched bytes differ")
        #expect(patchedBySwift != pristineBytes, "\(name): nothing was written")

        // Idempotent: the pristine literal is gone, so a second pass is a no-op.
        let rerun = try DSCHVVMMPatcher.patchStandaloneMachO(at: swiftCopy, log: nil)
        let afterRerun = try Data(contentsOf: swiftCopy)
        #expect(rerun == 0)
        #expect(afterRerun == patchedBySwift)
        print("[hv_vmm] \(name): \(count) standalone cstring site(s), bytes match")
    }
}

// DyldSharedCacheHypervisorVirtualMachinePatcherTests.swift — parity for the hv_vmm_present user-mode cstring
// mangle.
//
// There is no external oracle for this patch. `codesign -v` does not apply to a
// dyld shared cache chunk, and the only statement of what the patch should do
// was `scripts/patchers/cfw_patch_hv_vmm_dsc.py` plus the module it imported
// its constants from, `cfw_patch_hv_vmm.py`. Those have been removed, so what
// they produced on the real 24A435 arm64e cache is frozen in `FrozenReference`
// below: the constants, the blacklist, the per-dylib verdict for all 44 dylibs
// that carry the cstring, the SHA-256 of each of the 17 chunks that moved, the
// drift scenario's own digests, and the two standalone Mach-O runs.
//
// So the test is still not "does the Swift write 29 sites" as a number this
// repo invented — it is "does the Swift leave the bytes the reference left",
// chunk files and re-attested code directories alike.
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

import CryptoKit
@testable import FirmwarePatcher
import Foundation
import Testing

// MARK: - The frozen reference

/// What the reference modules held, and what they did to the real cache.
///
/// Recorded at commit 78cbeea by driving `cfw_patch_hv_vmm` and
/// `cfw_patch_hv_vmm_dsc` from `.venv/bin/python3` over a clone of
/// `ipsws/ref_extract/dsc_pristine` and over the pristine binaries in
/// `ipsws/ref_extract/macho_pristine`. Each constant names the call behind it.
private enum FrozenReference {
    // MARK: Constants, straight out of cfw_patch_hv_vmm

    /// `NEEDLE.hex()` — `"kern.hv_vmm_present\0"`.
    static let needleHex = "6b65726e2e68765f766d6d5f70726573656e7400"

    /// `MANGLED_NEEDLE.hex()` — `"kern.Xv_vmm_present\0"`.
    static let mangledNeedleHex = "6b65726e2e58765f766d6d5f70726573656e7400"

    /// `MANGLE_OFFSET`, `ORIGINAL_BYTE.hex()`, `MANGLED_BYTE.hex()`.
    static let mangleOffset = 5
    static let originalByteHex = "68"
    static let mangledByteHex = "58"

    /// `list(DONT_PATCH_INSTALL_NAMES)` from `cfw_patch_hv_vmm_dsc`, in
    /// declaration order — identity and activation first, then store, then the
    /// consumer services.
    static let blacklist: [String] = [
        "/System/Library/PrivateFrameworks/AAAFoundation.framework/AAAFoundation",
        "/System/Library/PrivateFrameworks/AuthKit.framework/AuthKit",
        "/System/Library/PrivateFrameworks/IDSFoundation.framework/IDSFoundation",
        "/System/Library/PrivateFrameworks/DeviceIdentity.framework/DeviceIdentity",
        "/System/Library/PrivateFrameworks/DeviceCheckInternal.framework/DeviceCheckInternal",
        "/System/Library/PrivateFrameworks/MobileActivation.framework/MobileActivation",
        "/System/Library/PrivateFrameworks/ApplePushService.framework/ApplePushService",
        "/System/Library/PrivateFrameworks/AppStoreUtilities.framework/AppStoreUtilities",
        "/System/Library/PrivateFrameworks/CorePrescription.framework/CorePrescription",
        "/System/Library/PrivateFrameworks/CoreCDP.framework/CoreCDP",
        "/System/Library/PrivateFrameworks/EmailFoundation.framework/EmailFoundation",
        "/System/Library/PrivateFrameworks/FindMyBase.framework/FindMyBase",
        "/System/Library/PrivateFrameworks/TrialServer.framework/TrialServer",
        "/System/Library/PrivateFrameworks/DVTInstrumentsUtilities.framework/DVTInstrumentsUtilities",
        "/System/Library/PrivateFrameworks/WatchdogServiceManagement.framework/WatchdogServiceManagement",
    ]

    // MARK: The real cache

    /// The dictionary `patch_hv_vmm_in_dsc(<clone>)` returned: every dylib that
    /// carries the cstring, mapped to how many of its sites were mangled. The
    /// zeros are the blacklist — seen, classified, and deliberately left with
    /// the pristine name so they get ENOENT and conclude "not a VM".
    static let mangledCountByInstallName: [String: Int] = [
        "/System/Library/Frameworks/CoreML.framework/CoreML": 1,
        "/System/Library/Frameworks/CoreVideo.framework/CoreVideo": 1,
        "/System/Library/Frameworks/MediaToolbox.framework/MediaToolbox": 1,
        "/System/Library/Frameworks/MetalPerformanceShadersGraph.framework/MetalPerformanceShadersGraph": 1,
        "/System/Library/Frameworks/SoundAnalysis.framework/SoundAnalysis": 1,
        "/System/Library/PrivateFrameworks/AAAFoundation.framework/AAAFoundation": 0,
        "/System/Library/PrivateFrameworks/AirPlaySupport.framework/AirPlaySupport": 1,
        "/System/Library/PrivateFrameworks/AppStoreUtilities.framework/AppStoreUtilities": 0,
        "/System/Library/PrivateFrameworks/AppleNeuralEngine.framework/AppleNeuralEngine": 1,
        "/System/Library/PrivateFrameworks/ApplePushService.framework/ApplePushService": 0,
        "/System/Library/PrivateFrameworks/AuthKit.framework/AuthKit": 0,
        "/System/Library/PrivateFrameworks/CMCapture.framework/CMCapture": 1,
        "/System/Library/PrivateFrameworks/CloudSubscriptionFeatures.framework/CloudSubscriptionFeatures": 1,
        "/System/Library/PrivateFrameworks/CoreCDP.framework/CoreCDP": 0,
        "/System/Library/PrivateFrameworks/CorePrescription.framework/CorePrescription": 0,
        "/System/Library/PrivateFrameworks/CoreRE.framework/CoreRE": 1,
        "/System/Library/PrivateFrameworks/DVTInstrumentsUtilities.framework/DVTInstrumentsUtilities": 0,
        "/System/Library/PrivateFrameworks/DesignLibrary.framework/DesignLibrary": 1,
        "/System/Library/PrivateFrameworks/DeviceCheckInternal.framework/DeviceCheckInternal": 0,
        "/System/Library/PrivateFrameworks/DeviceIdentity.framework/DeviceIdentity": 0,
        "/System/Library/PrivateFrameworks/EmailFoundation.framework/EmailFoundation": 0,
        "/System/Library/PrivateFrameworks/Espresso.framework/Espresso": 1,
        "/System/Library/PrivateFrameworks/FindMyBase.framework/FindMyBase": 0,
        "/System/Library/PrivateFrameworks/HomeAI.framework/HomeAI": 1,
        "/System/Library/PrivateFrameworks/IDSFoundation.framework/IDSFoundation": 0,
        "/System/Library/PrivateFrameworks/IOSurfaceAccelerator.framework/IOSurfaceAccelerator": 1,
        "/System/Library/PrivateFrameworks/IntelligenceFlowShared.framework/IntelligenceFlowShared": 1,
        "/System/Library/PrivateFrameworks/MagnifierSupport.framework/MagnifierSupport": 1,
        "/System/Library/PrivateFrameworks/MobileActivation.framework/MobileActivation": 0,
        "/System/Library/PrivateFrameworks/MobileAssetDaemon.framework/MobileAssetDaemon": 1,
        "/System/Library/PrivateFrameworks/NeuralNetworks.framework/NeuralNetworks": 1,
        "/System/Library/PrivateFrameworks/PhotoFoundation.framework/PhotoFoundation": 1,
        "/System/Library/PrivateFrameworks/Recon3D.framework/Recon3D": 1,
        "/System/Library/PrivateFrameworks/RenderBox.framework/RenderBox": 1,
        "/System/Library/PrivateFrameworks/TrialServer.framework/TrialServer": 0,
        "/System/Library/PrivateFrameworks/VFX.framework/VFX": 1,
        "/System/Library/PrivateFrameworks/VisionKitCore.framework/VisionKitCore": 1,
        "/System/Library/PrivateFrameworks/WatchdogServiceManagement.framework/WatchdogServiceManagement": 0,
        "/System/Library/PrivateFrameworks/WebGPU.framework/WebGPU": 1,
        "/System/Library/PrivateFrameworks/caulk.framework/caulk": 1,
        "/System/Library/SubFrameworks/CoreAIRuntime.framework/CoreAIRuntime": 1,
        "/System/Library/SubFrameworks/RealityCoreRenderer.framework/RealityCoreRenderer": 1,
        "/usr/lib/libMobileGestalt.dylib": 1,
        "/usr/lib/libafc.dylib": 1,
    ]

    /// 29 sites across 29 dylibs; the other 15 entries above are the blacklist.
    static var totalMangled: Int {
        mangledCountByInstallName.values.reduce(0, +)
    }

    /// `cmp -s` against the pristine tree after the run: 17 chunks moved, with
    /// these digests (`shasum -a 256`). The Python logged 29 `re-attest: wrote
    /// slot …` lines and then `re-attest: updated 29 slot hash(es) across 17
    /// chunk(s)`, so these digests cover the mangles and the slot hashes alike.
    ///
    /// Re-running it over its own output wrote nothing and left them standing;
    /// a dry run on a fresh clone changed no byte at all.
    static let changedChunks: [String: String] = [
        "dyld_shared_cache_arm64e.03":
            "fa2647de6433a45269aeb7988338ba615c280e742fb7319f887df402fdd4526e",
        "dyld_shared_cache_arm64e.05":
            "fa58f42ad70af3c20e081c1f19c36121e27d3150a81856f7ef9a3264e1ef0d81",
        "dyld_shared_cache_arm64e.11":
            "f5614f3fb7147a0ee251becd1d6dc8a815849b879376c74d25dde04a982414b3",
        "dyld_shared_cache_arm64e.13":
            "5be2f71398d2c0e905d361e3b6619b338cdb7ccdb5f140f747a8fe50a0abbc64",
        "dyld_shared_cache_arm64e.15":
            "bbbd7d80035ee4b5496860eee91ce53762ee3c3fb7b6cd69a372763e12ee8269",
        "dyld_shared_cache_arm64e.19":
            "30a0167148dbe1884a6afc3332656501f5931967a0a0f881f2bd98b7ef0132b7",
        "dyld_shared_cache_arm64e.30":
            "383bad0df1c10be753d98263bed3913e0ec247fc1152b4b3b9122c089692c902",
        "dyld_shared_cache_arm64e.36":
            "00ffb7b9dd847203358afb1aafad0e8b6fb219c04bde44b632267fdabcb0fc27",
        "dyld_shared_cache_arm64e.38":
            "607dd2ffa643e7efcb0f8fd048a4f2b6d0834658fb1f252dc0c936416a368048",
        "dyld_shared_cache_arm64e.40":
            "294c4445e0c99955390374a60ac9c7aa2feab8d79fe9b7df96dc016888df3944",
        "dyld_shared_cache_arm64e.42":
            "d82b6cf13553ced34061ed555edb646d0f197f4fe4ee41a0a5c04ee221159a5b",
        "dyld_shared_cache_arm64e.46":
            "d44fc4f5d4caf1f85fac3c8f60cc8b53d3ceddd92abe47eeb468323b8afb467d",
        "dyld_shared_cache_arm64e.57":
            "f133e1624116214f3d794da136081478de3b6e3fb1485128c44ccb3e64b81c1d",
        "dyld_shared_cache_arm64e.59":
            "8133b4a774accd23e4682cdf3803479527d2a5025d47a675ca3a2eac844cc08d",
        "dyld_shared_cache_arm64e.63":
            "4ff96a186146fa1ef029d40c55de44bcd066c38b8040b5b726b5a12ea800c4e6",
        "dyld_shared_cache_arm64e.71":
            "701cf056e817fb25da8b1f74f9a2d92728941012e51fd4a5f9fa69c765d66251",
        "dyld_shared_cache_arm64e.73":
            "a56c1e720372456224a01ab06ab593c41966b50f1c24c6168cf2ab76788b5627",
    ]

    // MARK: The drift scenario

    /// The lowest-addressed pristine site inside a blacklisted dylib, which is
    /// what the drift test mangles by hand before running the patch. Found by
    /// walking `chunks.find_string_vmas(NEEDLE)` in order and classifying each.
    static let driftVMA: UInt64 = 0x1_97CF_0A98
    static let driftedInstallName =
        "/System/Library/PrivateFrameworks/IDSFoundation.framework/IDSFoundation"

    /// With that one byte pre-mangled, the reference printed `[!] drift:
    /// …IDSFoundation is in the blacklist but already mangled at
    /// string@0x197CF0A98 — slot will be re-attested to current bytes`, then
    /// `1 blacklisted dylib(s) found mangled on disk` and `re-attest: updated
    /// 30 slot hash(es) across 17 chunk(s)`.
    ///
    /// It did not revert the byte: the same 17 chunks moved, and only
    /// `…arm64e.05` — the chunk IDSFoundation's cstring lives in — came out
    /// different from the ordinary run above.
    static let driftChangedChunks: [String: String] = changedChunks.merging([
        "dyld_shared_cache_arm64e.05":
            "b5483cb22495048a99437a944f761c3bc36fa4c564789d9bd345f2a5dd2b59aa",
    ]) { _, new in new }

    // MARK: Standalone Mach-O

    /// One `find_string_sites` result.
    struct MachOSite {
        let stringVMA: UInt64
        let fileOffset: Int
        let section: String
    }

    /// What `patch_hv_vmm` did to one pristine binary.
    struct MachORun {
        /// `find_string_sites(open(<pristine>,"rb").read())`.
        let sites: [MachOSite]
        /// `shasum -a 256 <pristine>`, so a test that fed it something else
        /// fails on the input rather than comparing nothing.
        let pristineSHA256: String
        /// `shasum -a 256` of the copy afterwards. A second `patch_hv_vmm` over
        /// that copy returned 0 and left this digest unchanged.
        let patchedSHA256: String
    }

    /// The two binaries `ipsws/ref_extract/macho_pristine` keeps. Each carries
    /// exactly one occurrence of the cstring on this build.
    static let machO: [String: MachORun] = [
        "watchdogd": MachORun(
            sites: [MachOSite(
                stringVMA: 0x1_0001_1453,
                fileOffset: 70739,
                section: "__TEXT,__cstring",
            )],
            pristineSHA256:
            "0309b868a214f9841279db3e2ef901f26e8c05b2dc616eeb551f2b2f0e06207f",
            patchedSHA256:
            "95c9c25c89d20ee1d46b20ee8fd7a7b90c674ef57247a666e6cb19db123220e4",
        ),
        "mobileactivationd": MachORun(
            sites: [MachOSite(
                stringVMA: 0x1_003B_BE2A,
                fileOffset: 3_915_306,
                section: "__TEXT,__cstring",
            )],
            pristineSHA256:
            "89233513ce696cd01285f3432f3bcadd065cee07ac73bc5714836d13f24702d8",
            patchedSHA256:
            "29814c1318b40cd1afc8ea021604f1b165c6ce3775e3a4f02106891b84ff4129",
        ),
    ]
}

// MARK: - Fixture discovery

private enum HypervisorVirtualMachineFixture {
    static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
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
    static var runs: Bool {
        pristine != nil || !isOptional
    }

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
        // Per-suite leaf on BOTH branches: the override is a base shared with
        // the other DSC suites, and they reuse the same clone names.
        if let override = ProcessInfo.processInfo.environment["VPHONE_DSC_SCRATCH"] {
            return URL(fileURLWithPath: override).appendingPathComponent("vphone-hvvmm-parity")
        }
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("vphone-hvvmm-parity")
    }

    /// Clone the pristine cache into a fresh directory the caller may write to.
    static func cloneCache(named name: String) throws -> URL {
        guard let pristine else { throw CocoaError(.fileNoSuchFile) }
        let destination = scratchRoot.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.createDirectory(
            at: destination,
            withIntermediateDirectories: true,
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
            arguments: ["-c", "-R"] + sources + [destination.path],
        )
        if result.status != 0 {
            result = try Subprocess.run(
                executable: URL(fileURLWithPath: "/bin/cp"),
                arguments: ["-R"] + sources + [destination.path],
            )
        }
        guard result.status == 0 else { throw CocoaError(.fileWriteUnknown) }
        return destination
    }

    /// Copy one file into scratch under a fresh name.
    static func copyFile(_ source: URL, named name: String) throws -> URL {
        try FileManager.default.createDirectory(
            at: scratchRoot,
            withIntermediateDirectories: true,
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
        // Drain before waiting: `cp` of a 6.7 GB tree can fill a pipe buffer,
        // and a full buffer would deadlock the run.
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

// MARK: - Byte-for-byte tree comparison

private enum TreeComparison {
    /// Every file in `directory` whose bytes differ from its twin in
    /// `reference`, plus any file present in one and not the other.
    ///
    /// `cmp` rather than a digest: it stops at the first differing byte, so a
    /// tree that really does differ is reported in milliseconds instead of
    /// after hashing 6.7 GB twice.
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
}

// MARK: - Digests

/// SHA-256 of a file, streamed so a 131 MB chunk never lands in memory whole.
/// The hex spelling matches `shasum -a 256`, which produced the frozen digests.
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
    static func expectMatches(_ directory: URL, _ frozen: [String: String]) throws {
        let pristine = try #require(HypervisorVirtualMachineFixture.pristine, HypervisorVirtualMachineFixture.missing)
        let changed = try TreeComparison.changedNames(in: directory, against: pristine)
        #expect(changed == frozen.keys.sorted())
        for name in changed {
            let digest = try sha256(of: directory.appendingPathComponent(name))
            let expected = frozen[name] ?? "(not a chunk the Python moved)"
            #expect(digest == expected, "\(name): Swift \(digest), reference \(expected)")
        }
    }
}

// MARK: - Constants

/// No fixture needed: these are the reference modules' own constants, which the
/// port has to carry verbatim for anything else here to mean anything.
@Suite(.serialized)
struct DyldSharedCacheHypervisorVirtualMachineConstantsTests {
    @Test
    func `The cstring, its mangle and the blacklist match the reference modules`() {
        #expect(DyldSharedCacheHypervisorVirtualMachinePatcher.needle.hex == FrozenReference.needleHex)
        #expect(DyldSharedCacheHypervisorVirtualMachinePatcher.mangledNeedle.hex == FrozenReference.mangledNeedleHex)
        #expect(DyldSharedCacheHypervisorVirtualMachinePatcher.mangleOffset == FrozenReference.mangleOffset)
        #expect(Data([DyldSharedCacheHypervisorVirtualMachinePatcher.originalByte]).hex == FrozenReference.originalByteHex)
        #expect(Data([DyldSharedCacheHypervisorVirtualMachinePatcher.mangledByte]).hex == FrozenReference.mangledByteHex)
        #expect(DyldSharedCacheHypervisorVirtualMachinePatcher.dontPatchInstallNames == FrozenReference.blacklist)

        // The mangle has to preserve the namespace prefix, or the name cannot
        // resolve to any OID — see the patcher's file comment. This is the one
        // property of the patch that is not a transcription of the reference.
        let prefix = Data(DyldSharedCacheHypervisorVirtualMachinePatcher.sysctlNamespace.utf8)
        #expect(DyldSharedCacheHypervisorVirtualMachinePatcher.needle.prefix(prefix.count) == prefix)
        #expect(DyldSharedCacheHypervisorVirtualMachinePatcher.mangledNeedle.prefix(prefix.count) == prefix)
        #expect(DyldSharedCacheHypervisorVirtualMachinePatcher.needle.count == DyldSharedCacheHypervisorVirtualMachinePatcher.mangledNeedle.count)
        let differing = zip(DyldSharedCacheHypervisorVirtualMachinePatcher.needle, DyldSharedCacheHypervisorVirtualMachinePatcher.mangledNeedle)
            .enumerated()
            .filter { $0.element.0 != $0.element.1 }
            .map(\.offset)
        #expect(differing == [DyldSharedCacheHypervisorVirtualMachinePatcher.mangleOffset])
    }
}

// MARK: - The real cache

@Suite(.serialized, .enabled(if: HypervisorVirtualMachineFixture.runs, HypervisorVirtualMachineFixture.skipReason))
struct DyldSharedCacheHypervisorVirtualMachineCacheParityTests {
    /// The parity gate.
    ///
    /// One clone, one run, then require the tree to hold exactly the chunks the
    /// reference moved with exactly the bytes it left — code directories and
    /// all. A port that writes a different number of sites, or the same number
    /// in different places, or the right bytes with the wrong page re-hashed,
    /// fails here.
    ///
    /// The idempotence and blacklist checks ride on the same clone rather than
    /// cloning 6.7 GB again for each: they are assertions about the state this
    /// test has already produced.
    @Test
    func `The Swift patch reproduces the reference's cache`() throws {
        _ = try #require(HypervisorVirtualMachineFixture.pristine, HypervisorVirtualMachineFixture.missing)

        let swiftClone = try HypervisorVirtualMachineFixture.cloneCache(named: "swift")
        defer { HypervisorVirtualMachineFixture.discard(swiftClone) }

        let result = try DyldSharedCacheHypervisorVirtualMachinePatcher.patch(chunksDirectory: swiftClone, log: nil)

        // Same verdict per dylib, including the zero-count entries that record
        // "seen and deliberately left alone".
        #expect(result.mangledCountByInstallName == FrozenReference.mangledCountByInstallName)

        #expect(result.mangled == FrozenReference.totalMangled)
        #expect(result.mangled > 0, "the reference patched nothing — wrong fixture?")
        #expect(result.skippedInBlacklist == DyldSharedCacheHypervisorVirtualMachinePatcher.dontPatchInstallNames.count)
        #expect(result.skippedUnclassified == 0)
        #expect(result.refused == 0)
        #expect(result.isFullyAttested)
        // One slot per dirtied page, and no site left unattested. Sites can in
        // principle share a page, so this is a bound rather than an equality —
        // the digests below are what actually pin the code directories.
        let slotsRewritten = result.reattestation?.updated.count ?? 0
        #expect(slotsRewritten > 0)
        #expect(slotsRewritten <= result.mangled)
        print(
            "[hv_vmm] \(result.mangled) site(s), "
                + "\(result.skippedInBlacklist) blacklisted, "
                + "\(slotsRewritten) slot(s) re-attested",
        )

        try Digest.expectMatches(swiftClone, FrozenReference.changedChunks)

        // Idempotence, on the cache the Swift run just produced. A second pass
        // finds no pristine cstring left, queues the mangled ones so their slots
        // stay in sync, and must not move a byte. The reference behaved the same
        // way, so the frozen digests have to survive it.
        let second = try DyldSharedCacheHypervisorVirtualMachinePatcher.patch(chunksDirectory: swiftClone, log: nil)
        #expect(second.mangled == 0)
        #expect(second.pristineSiteCount == result.skippedInBlacklist)
        #expect(second.alreadyMangledSiteCount == result.mangled)
        #expect(second.reattestOnly == result.mangled)
        #expect(second.blacklistDrift == 0)
        #expect(second.reattestation?.updated.isEmpty == true)
        try Digest.expectMatches(swiftClone, FrozenReference.changedChunks)

        // The blacklist is the whole point of the design, so check it against
        // the bytes rather than against the run's own bookkeeping: every
        // blacklisted dylib in the cache must still hold the pristine cstring.
        let chunks = try DyldSharedCacheChunkSet(directory: swiftClone)
        var blacklistedSitesSeen = 0
        for vma in try chunks.findStringVMAs(DyldSharedCacheHypervisorVirtualMachinePatcher.needle) {
            let installName = try #require(
                DyldSharedCacheHypervisorVirtualMachinePatcher.classify(vma, in: chunks),
                "a pristine cstring survived in a dylib that cannot be named",
            )
            #expect(
                DyldSharedCacheHypervisorVirtualMachinePatcher.dontPatchSet.contains(installName),
                "\(installName) is not blacklisted but kept the original cstring",
            )
            blacklistedSitesSeen += 1
        }
        #expect(blacklistedSitesSeen == result.skippedInBlacklist)

        for vma in try chunks.findStringVMAs(DyldSharedCacheHypervisorVirtualMachinePatcher.mangledNeedle) {
            let installName = try #require(DyldSharedCacheHypervisorVirtualMachinePatcher.classify(vma, in: chunks))
            #expect(
                !DyldSharedCacheHypervisorVirtualMachinePatcher.dontPatchSet.contains(installName),
                "\(installName) is blacklisted but was mangled",
            )
        }
    }

    @Test
    func `A dry run reports the same sites and leaves every byte alone`() throws {
        let pristine = try #require(HypervisorVirtualMachineFixture.pristine, HypervisorVirtualMachineFixture.missing)

        let clone = try HypervisorVirtualMachineFixture.cloneCache(named: "dryrun")
        defer { HypervisorVirtualMachineFixture.discard(clone) }

        let result = try DyldSharedCacheHypervisorVirtualMachinePatcher.patch(
            chunksDirectory: clone,
            dryRun: true,
            log: nil,
        )
        #expect(result.mangled == FrozenReference.totalMangled)
        // A dry run writes nothing, so every page still hashes to exactly what
        // its slot says and no slot would be rewritten. What has to be true is
        // that the pass REACHED every page the patch would dirty — otherwise a
        // dry run would be quietly narrower than the real thing.
        #expect(result.reattestation?.updated.isEmpty == true)
        let pagesReached = result.reattestation?.pagesAttested ?? 0
        #expect(pagesReached > 0)
        #expect(pagesReached <= result.mangled)
        #expect(result.isFullyAttested)

        // The reference's dry run wrote nothing either.
        let changed = try TreeComparison.changedNames(in: clone, against: pristine)
        #expect(changed.isEmpty, "a dry run wrote to the cache: \(changed)")
    }

    /// The drift branch, which is the one deliberate behaviour in this patch that
    /// a port could plausibly get backwards.
    ///
    /// A blacklisted dylib found already mangled means somebody took it out of
    /// the blacklist, ran the patch, and put it back. The reference did NOT
    /// revert the byte and did NOT refuse: it said so loudly and re-attested the
    /// page to the bytes that are actually there, because reverting would leave
    /// the page hash right and the operator's intent wrong. A port that "fixed"
    /// this by reverting, or by treating it as an error, would pass every other
    /// test in this file.
    @Test
    func `A blacklisted dylib found mangled is reported as drift, not reverted`() throws {
        _ = try #require(HypervisorVirtualMachineFixture.pristine, HypervisorVirtualMachineFixture.missing)

        let swiftClone = try HypervisorVirtualMachineFixture.cloneCache(named: "drift-swift")
        defer { HypervisorVirtualMachineFixture.discard(swiftClone) }

        // The lowest-addressed site inside a blacklisted dylib, so the choice is
        // the same on every run — and the same one the reference was given.
        let probe = try DyldSharedCacheChunkSet(directory: swiftClone)
        let driftVMA = try #require(
            try probe.findStringVMAs(DyldSharedCacheHypervisorVirtualMachinePatcher.needle).sorted().first {
                guard let name = DyldSharedCacheHypervisorVirtualMachinePatcher.classify($0, in: probe) else { return false }
                return DyldSharedCacheHypervisorVirtualMachinePatcher.dontPatchSet.contains(name)
            },
            "no blacklisted dylib carries the cstring in this cache",
        )
        let driftedDylib = try #require(DyldSharedCacheHypervisorVirtualMachinePatcher.classify(driftVMA, in: probe))
        #expect(driftVMA == FrozenReference.driftVMA)
        #expect(driftedDylib == FrozenReference.driftedInstallName)

        // Mangle it by hand, without re-attesting — exactly the state a prior
        // out-of-band run would have left behind, and what the reference saw.
        let chunks = try DyldSharedCacheChunkSet(directory: swiftClone)
        try chunks.write(
            at: driftVMA &+ UInt64(DyldSharedCacheHypervisorVirtualMachinePatcher.mangleOffset),
            Data([DyldSharedCacheHypervisorVirtualMachinePatcher.mangledByte]),
        )

        let result = try DyldSharedCacheHypervisorVirtualMachinePatcher.patch(chunksDirectory: swiftClone, log: nil)

        #expect(result.blacklistDrift == 1)
        #expect(result.alreadyMangledSiteCount == 1)
        #expect(result.reattestOnly == 0)
        #expect(result.refused == 0)
        #expect(
            result.skippedInBlacklist == DyldSharedCacheHypervisorVirtualMachinePatcher.dontPatchInstallNames.count - 1,
            "the drifted site is no longer pristine, so it is not counted as skipped",
        )
        #expect(result.mangledCountByInstallName[driftedDylib] == nil)
        #expect(result.isFullyAttested)

        // Not reverted: the byte is still mangled afterwards.
        let after = try DyldSharedCacheChunkSet(directory: swiftClone)
            .bytesAtVMA(driftVMA, length: DyldSharedCacheHypervisorVirtualMachinePatcher.needle.count)
        #expect(after == DyldSharedCacheHypervisorVirtualMachinePatcher.mangledNeedle)

        // The same 17 chunks as the ordinary run, differing only in the one the
        // drifted dylib lives in — which is what the reference left behind.
        try Digest.expectMatches(swiftClone, FrozenReference.driftChangedChunks)
        print("[hv_vmm] drift on \(driftedDylib) at 0x\(String(driftVMA, radix: 16, uppercase: true))")
    }
}

// MARK: - Standalone Mach-O

@Suite(.serialized, .enabled(if: HypervisorVirtualMachineFixture.machORuns, HypervisorVirtualMachineFixture.machOSkipReason))
struct DyldSharedCacheHypervisorVirtualMachineStandaloneTests {
    /// The other half of `cfw_patch_hv_vmm.py`, against the binaries the repo
    /// keeps pristine copies of. Each carries one occurrence of the cstring on
    /// this build.
    @Test(
        arguments: ["watchdogd", "mobileactivationd"],
    )
    func `Standalone Mach-O mangling matches the reference`(name: String) throws {
        let pristine = try #require(
            HypervisorVirtualMachineFixture.machO(name),
            """
            ipsws/ref_extract/macho_pristine/\(name) is required — it is the \
            only standalone Mach-O fixture this half of the port has
            """,
        )
        let reference = try #require(
            FrozenReference.machO[name],
            "no frozen reference run for this binary",
        )
        // The reference saw this exact file; if it has been replaced, nothing
        // below is a comparison.
        #expect(try Digest.sha256(of: pristine) == reference.pristineSHA256)

        let swiftCopy = try HypervisorVirtualMachineFixture.copyFile(pristine, named: "\(name).swift")
        defer { HypervisorVirtualMachineFixture.discard(swiftCopy) }

        // Same sites, in the same order, before anything is written.
        let sites = try DyldSharedCacheHypervisorVirtualMachinePatcher.findStringSites(
            inMachO: Data(contentsOf: pristine),
        )
        #expect(sites.count == reference.sites.count)
        #expect(!sites.isEmpty, "\(name) holds no kern.hv_vmm_present cstring")
        for (mine, theirs) in zip(sites, reference.sites) {
            #expect(mine.stringVMA == theirs.stringVMA)
            #expect(mine.fileOffset == theirs.fileOffset)
            #expect(mine.section == theirs.section)
        }

        let count = try DyldSharedCacheHypervisorVirtualMachinePatcher.patchStandaloneMachO(at: swiftCopy, log: nil)
        #expect(count == sites.count)
        #expect(try Digest.sha256(of: swiftCopy) == reference.patchedSHA256)

        // Idempotent: the pristine literal is gone, so a second pass is a no-op.
        // The reference's own second pass returned 0 and left its digest alone.
        let rerun = try DyldSharedCacheHypervisorVirtualMachinePatcher.patchStandaloneMachO(at: swiftCopy, log: nil)
        #expect(rerun == 0)
        #expect(try Digest.sha256(of: swiftCopy) == reference.patchedSHA256)
        print("[hv_vmm] \(name): \(count) standalone cstring site(s), bytes match")
    }
}

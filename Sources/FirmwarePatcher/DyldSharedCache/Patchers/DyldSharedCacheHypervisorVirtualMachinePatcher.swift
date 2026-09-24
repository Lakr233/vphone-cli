// DyldSharedCacheHypervisorVirtualMachinePatcher.swift — the `kern.hv_vmm_present` user-mode cstring mangle.
//
// Port of BOTH `scripts/patchers/cfw_patch_hv_vmm_dsc.py` (the DSC orchestrator)
// and `scripts/patchers/cfw_patch_hv_vmm.py` (the cstring definition and the
// standalone-Mach-O patcher it exports). The two are one patch, split across two
// files only because Python needed somewhere to keep the shared constants: the
// DSC module imports `NEEDLE` / `MANGLED_NEEDLE` / `MANGLE_OFFSET` /
// `ORIGINAL_BYTE` / `MANGLED_BYTE` from the other one at import time. Porting the
// orchestrator alone would have left this file restating those five values from
// memory, with nothing tying them back to the module that defines them — so both
// halves live here, in one type, and the constants have exactly one definition.
//
// What the patch is
// -----------------
// This is the user-mode half of the EXP blacklist-flip. The kernel half —
// `KernelExperimentalPatcher.patchHvVmmRename`, in
// `Kernel/EXPPatches/KernelExperimentalPatchHvVmmRename.swift` — renames the sysctl OID
// from `hv_vmm_present` to `Xv_vmm_present`. After it:
//
//   * `sysctlbyname("kern.hv_vmm_present", …)` returns ENOENT, and the canonical
//     defensive post-call check (`cbnz w0, skip`) leaves the caller's cached
//     `is_vmm` byte at its BSS zero. The caller concludes it is NOT in a VM.
//   * `sysctlbyname("kern.Xv_vmm_present", …)` returns 1 — the OID's real int
//     value, because this device really is a VM. The caller concludes it IS in a
//     VM, exactly as it would on stock.
//
// So which answer a dylib gets is decided entirely by which name its cstring
// asks for, and this patcher decides that per dylib: flip byte 5 of
// `"kern.hv_vmm_present\0"` from `'h'` to `'X'` and the dylib sees 1; leave it
// alone and the dylib sees ENOENT and caches 0.
//
// Byte 5 and not byte 0
// ---------------------
// Byte 5 is the first byte after the `kern.` namespace prefix. Mangling byte 0
// would produce `Xern.hv_vmm_present`, which can never resolve, because `Xern`
// is not a registered top-level sysctl namespace — the name-to-MIB walk fails
// before it ever reaches an OID. Keeping `kern.` intact is what lets the mangled
// name route to the renamed OID.
//
// Blacklist semantics — the list names what stays ORIGINAL
// --------------------------------------------------------
// `dontPatchInstallNames` holds the dylibs that must believe they are on real
// hardware: identity, activation, anti-abuse, store, and the consumer services
// that refuse to sign in from a VM. Those keep the pristine cstring.
//
// Every OTHER dylib carrying the cstring gets the mangle, which is what keeps
// the graphics path (libMobileGestalt, CoreVideo, PhotoFoundation,
// AirPlaySupport, VisionKitCore) and the compute/accel fast paths (CoreML,
// Espresso, AppleNeuralEngine, caulk, IOSurfaceAccelerator) on the answer they
// were written against. A lib that thinks it is on bare metal when it is not
// will try to talk to silicon that is not there.
//
// TXM and the page hashes
// -----------------------
// On `codeSigningMonitor == 2` hardware the mangled byte is not enough on its
// own: TXM holds the SHA-256 slot hash the page was registered with, and the
// first process to demand-page that 16 KiB page dies with
// `KERN_PROTECTION_FAILURE` / `CODESIGNING / Invalid Page`. Every site written
// here is therefore followed by `DyldSharedCacheCodeSignature`, which re-hashes the pages
// that were actually dirtied. This patcher never names those pages itself —
// `DyldSharedCacheChunkSet` records each write and the re-attestation pass consumes the
// record, so a site cannot be written and left unattested.
//
// One deliberate divergence from the reference
// --------------------------------------------
// `cfw_patch_hv_vmm_dsc.py` queues the address of the cstring's FIRST byte for
// re-attestation, although the byte it wrote is five bytes further on. The two
// are in the same 16 KiB page for all 44 occurrences on the 24A435 arm64e cache,
// so the reference is right there by margin — but a cstring whose first byte
// falls in the last five bytes of a page would have the wrong page re-hashed and
// the patched one left stale, reported as success. Here the span comes from the
// write itself, so it is the page that changed by construction.

import Foundation

/// The user-mode `kern.hv_vmm_present` cstring mangle, over a chunked dyld
/// shared cache and over standalone Mach-Os.
public enum DyldSharedCacheHypervisorVirtualMachinePatcher {
    // MARK: - The cstring and its mangle

    //
    // Port of the five constants `cfw_patch_hv_vmm.py` exports. They are derived
    // from the sysctl name rather than written out as bytes, so "byte 5" is the
    // length of the namespace prefix and cannot drift away from it.

    /// The top-level sysctl namespace the name lives under. Preserved by the
    /// mangle — see the file comment.
    public static let sysctlNamespace = "kern."

    /// The OID's own name, as userland spells it.
    public static let sysctlOIDName = "hv_vmm_present"

    /// `"kern.hv_vmm_present\0"` — the pristine cstring, NUL included, because a
    /// match has to cover the terminator to be the whole literal.
    public static let needle = Data((sysctlNamespace + sysctlOIDName + "\0").utf8)

    /// Index of the mangled byte within ``needle``: the first byte after
    /// `kern.`, which is the `'h'` of `hv_vmm_present`.
    public static let mangleOffset = sysctlNamespace.utf8.count

    /// What that byte is before the patch.
    public static let originalByte = UInt8(ascii: "h")

    /// What it becomes — the same letter `KernelExperimentalPatchHvVmmRename` renames the
    /// OID to, which is the only reason the mangled name resolves at all.
    public static let mangledByte = UInt8(ascii: "X")

    /// `"kern.Xv_vmm_present\0"` — what a patched site reads as.
    public static let mangledNeedle: Data = {
        var mangled = needle
        mangled[mangled.startIndex + mangleOffset] = mangledByte
        return mangled
    }()

    /// Mach-O sections a cstring literal can live in.
    ///
    /// `__cstring` is where the linker puts unique C string literals. The ObjC
    /// name pools could in principle hold the same bytes, and the reference
    /// scans them too, so this does as well.
    static let cstringSectionNames: Set<String> = [
        "__cstring", "__objc_methname", "__objc_classname",
    ]

    // MARK: - Blacklist

    //
    // A dylib named here keeps `"kern.hv_vmm_present\0"`. With the kernel rename
    // in place that name is ENOENT, the dylib's defensive check takes the skip
    // path, its cached `is_vmm` byte stays at BSS zero, and it concludes the
    // device is not a VM.
    //
    // A dylib NOT named here is mangled to `"kern.Xv_vmm_present\0"`, resolves to
    // the renamed OID, reads 1, and concludes the device is a VM — the same
    // answer it would get on stock hardware.
    //
    // Commenting out a single line moves that dylib OUT of the blacklist and
    // back into the patched set, which is how you bisect which consumer
    // regressed an observable. The grouping is for the reader; order does not
    // affect what is patched.

    /// The dylibs that stay unpatched, by `LC_ID_DYLIB` install name.
    public static let dontPatchInstallNames: [String] = [
        // ── Identity / activation / anti-abuse.
        "/System/Library/PrivateFrameworks/AAAFoundation.framework/AAAFoundation",
        "/System/Library/PrivateFrameworks/AuthKit.framework/AuthKit",
        "/System/Library/PrivateFrameworks/IDSFoundation.framework/IDSFoundation",
        "/System/Library/PrivateFrameworks/DeviceIdentity.framework/DeviceIdentity",
        "/System/Library/PrivateFrameworks/DeviceCheckInternal.framework/DeviceCheckInternal",
        "/System/Library/PrivateFrameworks/MobileActivation.framework/MobileActivation",
        "/System/Library/PrivateFrameworks/ApplePushService.framework/ApplePushService",

        // ── Store / IAP.
        "/System/Library/PrivateFrameworks/AppStoreUtilities.framework/AppStoreUtilities",

        // ── Consumer services.
        "/System/Library/PrivateFrameworks/CorePrescription.framework/CorePrescription",
        "/System/Library/PrivateFrameworks/CoreCDP.framework/CoreCDP",
        "/System/Library/PrivateFrameworks/EmailFoundation.framework/EmailFoundation",
        "/System/Library/PrivateFrameworks/FindMyBase.framework/FindMyBase",
        "/System/Library/PrivateFrameworks/TrialServer.framework/TrialServer",
        "/System/Library/PrivateFrameworks/DVTInstrumentsUtilities.framework/DVTInstrumentsUtilities",
        "/System/Library/PrivateFrameworks/WatchdogServiceManagement.framework/WatchdogServiceManagement",
    ]

    /// Set form, for the per-site membership test.
    public static let dontPatchSet = Set(dontPatchInstallNames)

    /// What a site with no resolvable install name is called in the result map,
    /// matching the reference's `"<unknown dylib>"`.
    public static let unknownDylibLabel = "<unknown dylib>"

    // MARK: - Result

    /// What one DSC run did, site by site and in total.
    ///
    /// `mangledCountByInstallName` is the reference's return value: every dylib
    /// the scan reached, mapped to how many of its cstring sites this run
    /// mangled. A blacklisted, unclassified or already-mangled dylib appears
    /// with a count of zero, which is how the caller can tell "seen and left
    /// alone" from "never seen".
    public struct Result: Sendable {
        /// Occurrences of the pristine cstring found in executable mappings.
        public let pristineSiteCount: Int
        /// Occurrences of the already-mangled cstring found alongside them.
        public let alreadyMangledSiteCount: Int
        /// Per-dylib count of sites this run mangled.
        public let mangledCountByInstallName: [String: Int]
        /// Sites mangled (or, on a dry run, that would have been).
        public let mangled: Int
        /// Sites left pristine because their dylib is blacklisted.
        public let skippedInBlacklist: Int
        /// Sites whose containing dylib could not be named, so were not touched.
        public let skippedUnclassified: Int
        /// Sites refused: unreadable, or bytes that are neither form.
        public let refused: Int
        /// Already-mangled sites queued only so their page hash is brought back
        /// into sync.
        public let reattestOnly: Int
        /// Blacklisted dylibs found already mangled on disk — an out-of-band
        /// edit, reported loudly and re-attested rather than reverted.
        public let blacklistDrift: Int
        /// The re-attestation pass, or `nil` when there were no pages to cover.
        public let reattestation: DyldSharedCacheReattestation?

        /// True when nothing was left in a state the guest would fault on: every
        /// page this run touched carries a slot hash that matches its bytes.
        public var isFullyAttested: Bool {
            reattestation?.isFullyAttested ?? true
        }

        static let empty = Result(
            pristineSiteCount: 0,
            alreadyMangledSiteCount: 0,
            mangledCountByInstallName: [:],
            mangled: 0,
            skippedInBlacklist: 0,
            skippedUnclassified: 0,
            refused: 0,
            reattestOnly: 0,
            blacklistDrift: 0,
            reattestation: nil,
        )
    }

    // MARK: - The DSC patch

    /// Apply the blacklist-flip mangle to the cache under `chunksDirectory`.
    ///
    /// This is `cfw.py patch-hv-vmm-dsc <chunks_dir> [--dry-run]`, which
    /// `scripts/patch_hv_vmm_userland.sh dsc` wraps and `cfw_install_exp.sh`
    /// calls while the SystemOS cryptex is still mounted on the host.
    @discardableResult
    public static func patch(
        chunksDirectory: URL,
        dryRun: Bool = false,
        log: ((String) -> Void)? = DyldSharedCacheCodeSignature.stderrLog,
    ) throws -> Result {
        let chunks = try DyldSharedCacheChunkSet(directory: chunksDirectory)
        log?(
            "  [.] \(chunksDirectory.path): \(chunks.chunkURLs.count) chunk(s), "
                + "\(chunks.mappings.count) mapping(s), "
                + "vm 0x\(hex(chunks.addressRange.lowerBound))"
                + "..0x\(hex(chunks.addressRange.upperBound))",
        )
        return try patch(in: chunks, dryRun: dryRun, log: log)
    }

    /// Apply the mangle to an already-open cache.
    ///
    /// Split out so a caller that has other DSC work to do on the same chunk set
    /// can share it, and so tests can inspect the chunk set afterwards.
    ///
    /// A shared chunk set's earlier writes are re-attested along with this
    /// patch's, since the re-attestation pass reads the set's whole write log. A
    /// page whose slot is already correct is skipped, so that costs one hash and
    /// never the wrong answer — and the alternative, filtering the log down to
    /// this patch's own spans, is how a page ends up written and unattested.
    @discardableResult
    public static func patch(
        in chunks: DyldSharedCacheChunkSet,
        dryRun: Bool = false,
        log: ((String) -> Void)? = DyldSharedCacheCodeSignature.stderrLog,
    ) throws -> Result {
        log?("  [.] locating cstring \"kern.hv_vmm_present\\0\"…")
        let pristineSites = try chunks.findStringVMAs(needle).sorted()
        // Sites a previous run already mangled. Nothing is written for these,
        // but their pages still have to join the re-attestation set: a re-run
        // over a cache patched by an older pass (or by the Python) has to leave
        // the slot hashes in sync with the bytes on disk.
        let alreadyMangledSites = try chunks.findStringVMAs(mangledNeedle).sorted()

        guard !pristineSites.isEmpty || !alreadyMangledSites.isEmpty else {
            log?(
                "  [-] cstring not present in any executable mapping; nothing to "
                    + "do (either patched already or absent)",
            )
            return .empty
        }
        log?(
            "  [.] \(pristineSites.count) pristine + \(alreadyMangledSites.count) "
                + "already-mangled cstring occurrence(s) found",
        )
        log?(
            "  [.] resolving containing dylib for each occurrence (blacklist has "
                + "\(dontPatchSet.count) entries — these stay unpatched)…",
        )

        var mangledCountByInstallName: [String: Int] = [:]
        var mangled = 0
        var skippedInBlacklist = 0
        var skippedUnclassified = 0
        var refused = 0
        // Stand-ins for the writes, used on a dry run where `DyldSharedCacheChunkSet` has no
        // record because nothing was written. On a live run the record is the
        // authority and these are not consulted.
        var plannedSpans: [DyldSharedCacheWriteSpan] = []
        // Pages that need re-hashing although this run wrote nothing to them.
        var reattestOnlySpans: [DyldSharedCacheWriteSpan] = []

        for vma in pristineSites {
            let installName = classify(vma, in: chunks)
            let label = installName ?? unknownDylibLabel

            guard let installName else {
                // An unnamed dylib is not in the blacklist, so it would normally
                // be patched. Refuse it instead: a site nobody can audit is not
                // a site worth flipping.
                log?("      [.] SKIP (no install name resolvable)  string@0x\(hex(vma))")
                skippedUnclassified += 1
                note(label, in: &mangledCountByInstallName)
                continue
            }

            if dontPatchSet.contains(installName) {
                log?(
                    "      [.] SKIP (blacklisted — stays unpatched, will hit "
                        + "ENOENT): \(installName)  string@0x\(hex(vma))",
                )
                skippedInBlacklist += 1
                note(label, in: &mangledCountByInstallName)
                continue
            }

            // The bytes have to still look like the cstring we matched.
            let current: Data
            do {
                current = try chunks.bytesAtVMA(vma, length: needle.count)
            } catch {
                log?("      [-] read failed at 0x\(hex(vma)): \(error)")
                refused += 1
                continue
            }

            if current[current.startIndex + mangleOffset] == mangledByte {
                // Mangled by an earlier run. Nothing to write; the second pass
                // below picks the page up through `alreadyMangledSites`.
                log?(
                    "      [.] already mangled at byte \(mangleOffset): \(label)  "
                        + "string@0x\(hex(vma))",
                )
                note(label, in: &mangledCountByInstallName)
                continue
            }
            guard current == needle else {
                log?(
                    "      [-] unexpected bytes at 0x\(hex(vma)) (\(current.hex)); "
                        + "refusing  (\(label))",
                )
                refused += 1
                continue
            }

            let writeVMA = vma &+ UInt64(mangleOffset)
            if dryRun {
                plannedSpans.append(DyldSharedCacheWriteSpan.byte(at: writeVMA))
            } else {
                try chunks.write(at: writeVMA, Data([mangledByte]))
            }
            log?(
                "      [+] \(dryRun ? "would mangle" : "mangled") \(label)  "
                    + "string@0x\(hex(vma))  byte \(mangleOffset) "
                    + "(\(Character(UnicodeScalar(originalByte))) -> "
                    + "\(Character(UnicodeScalar(mangledByte))))  now queries "
                    + "kern.Xv_vmm_present, will see 1 (in a VM)",
            )
            mangledCountByInstallName[label, default: 0] += 1
            mangled += 1
        }

        // Second pass: cstrings a previous run already mangled. Their pages join
        // the re-attestation set so a re-run brings the slot hashes back into
        // sync with what is on disk.
        //
        // A mangled cstring inside a BLACKLISTED dylib is deliberately not
        // refused. It means someone took that dylib out of the blacklist, ran
        // the patch, and put it back — an out-of-band action this code cannot
        // undo safely, since reverting the byte would leave the page hash right
        // and the operator's intent wrong. It is reported loudly and the page is
        // re-attested to the bytes that are actually there.
        var reattestOnly = 0
        var blacklistDrift = 0
        for vma in alreadyMangledSites {
            guard let installName = classify(vma, in: chunks) else { continue }
            // The whole cstring, not just the mangled byte: nothing was written
            // this run, so there is no write span to inherit, and a literal that
            // straddles a page boundary needs both of its pages.
            let span = DyldSharedCacheWriteSpan(vma: vma, length: needle.count)
            if dontPatchSet.contains(installName) {
                log?(
                    "      [!] drift: \(installName) is in the blacklist but "
                        + "already mangled at string@0x\(hex(vma)) — slot will be "
                        + "re-attested to current bytes; consider whether you "
                        + "actually want this dylib re-patched",
                )
                reattestOnlySpans.append(span)
                blacklistDrift += 1
                continue
            }
            reattestOnlySpans.append(span)
            reattestOnly += 1
        }
        if reattestOnly > 0 {
            log?(
                "  [.] also queueing \(reattestOnly) already-mangled cstring "
                    + "page(s) for re-attestation",
            )
        }
        if blacklistDrift > 0 {
            log?(
                "  [.] \(blacklistDrift) blacklisted dylib(s) found mangled on "
                    + "disk — see drift warnings above",
            )
        }

        // Page-hash re-attestation. On `codeSigningMonitor == 2` hardware TXM
        // holds the slot hashes the cache was registered with, so a mangled byte
        // without a re-hash is a SIGKILL on the first demand-page-in of that
        // page, with nothing pointing back at this patch. The CD blob's own
        // cdHash changes as a side effect; that is survivable only because the
        // JB kernel patch `KernelJailbreakPatchAmfiTrustcache` short-circuits AMFI's
        // per-image trust-cache lookup.
        //
        // The write spans come from `DyldSharedCacheChunkSet` itself rather than from a list
        // this function keeps, so a site cannot be written and left out.
        let spans = (dryRun ? plannedSpans : chunks.recordedWrites) + reattestOnlySpans
        var reattestation: DyldSharedCacheReattestation?
        if !spans.isEmpty {
            log?(
                "  [.] \(dryRun ? "dry-run: would re-attest" : "re-attesting") "
                    + "\(spans.count) modified page span(s)…",
            )
            reattestation = try DyldSharedCacheCodeSignature.reattest(
                in: chunks,
                modifiedSpans: spans,
                dryRun: dryRun,
                log: log,
            )
        }

        log?(
            "  [+] DSC patch complete: \(mangled) cstring(s) mangled, "
                + "\(skippedInBlacklist) in-blacklist (left unpatched), "
                + "\(skippedUnclassified) unclassified, \(refused) refused/error",
        )
        return Result(
            pristineSiteCount: pristineSites.count,
            alreadyMangledSiteCount: alreadyMangledSites.count,
            mangledCountByInstallName: mangledCountByInstallName,
            mangled: mangled,
            skippedInBlacklist: skippedInBlacklist,
            skippedUnclassified: skippedUnclassified,
            refused: refused,
            reattestOnly: reattestOnly,
            blacklistDrift: blacklistDrift,
            reattestation: reattestation,
        )
    }

    /// Name the dylib that contains `vma`, by walking back to its Mach-O header
    /// and reading `LC_ID_DYLIB`.
    ///
    /// `nil` covers both "no header found" and "the walk-back threw", which is
    /// what the reference's blanket `except Exception` does: a site whose dylib
    /// cannot be named is left alone either way, so the two cases lead to the
    /// same place.
    static func classify(_ vma: UInt64, in chunks: DyldSharedCacheChunkSet) -> String? {
        let headerVMA: UInt64?
        do {
            headerVMA = try chunks.findMachOHeaderBefore(vma)
        } catch {
            return nil
        }
        guard let headerVMA else { return nil }
        return chunks.readInstallName(atHeaderVMA: headerVMA)
    }

    /// Put `label` in the per-dylib map at zero if it is not there yet.
    ///
    /// A dylib the scan reached but did not patch still belongs in the result,
    /// with a count of zero — that is what separates "seen and deliberately left
    /// alone" from "never seen", and the reference's `results.get(label, 0)`
    /// spelling of it is easy to mistake for a no-op.
    private static func note(_ label: String, in counts: inout [String: Int]) {
        if counts[label] == nil {
            counts[label] = 0
        }
    }

    // MARK: - Standalone Mach-O

    //
    // The other half of `cfw_patch_hv_vmm.py`: the same mangle applied to a
    // Mach-O on disk rather than to a dylib inside the cache. No caller in this
    // repo reaches it today — `patch_hv_vmm_userland.sh` lost its `standalone`
    // op when the rootfs patcher was removed, and the one standalone binary that
    // still carries its own copy of the cstring (`watchdogd`) is handled by a
    // dedicated two-instruction patch instead. It is here because it is the rest
    // of the module this file ports, it is the only way to check the cstring
    // definition above against a real Mach-O, and the EXP rootfs list in
    // `Research/0_binary_patch_comparison.md` still names six files it applies
    // to.

    /// Mangle every cstring site in the Mach-O at `url`.
    ///
    /// - Returns: how many sites were mangled. Idempotent: a second run finds
    ///   the pristine literal gone and returns 0.
    @discardableResult
    public static func patchStandaloneMachO(
        at url: URL,
        dryRun: Bool = false,
        log: ((String) -> Void)? = DyldSharedCacheCodeSignature.stderrLog,
    ) throws -> Int {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw PatcherError.fileNotFound(url.path)
        }
        var data = try Data(contentsOfFileToRewrite: url)
        let sites = try findStringSites(inMachO: data)
        guard !sites.isEmpty else {
            if isAlreadyMangled(data) {
                log?(
                    "  [.] \(url.path): already mangled (no original "
                        + "'kern.hv_vmm_present' cstring present)",
                )
            } else {
                log?(
                    "  [.] \(url.path): 'kern.hv_vmm_present' cstring not "
                        + "present — nothing to do",
                )
            }
            return 0
        }

        log?("  [+] \(sites.count) cstring occurrence(s) in \(url.path)")
        var patched = 0
        for site in sites {
            let range = site.fileOffset ..< (site.fileOffset + needle.count)
            guard range.upperBound <= data.count else { continue }
            let original = data[range]
            if original[original.startIndex + mangleOffset] == mangledByte {
                log?(
                    "  [.] string@0x\(hex(site.stringVMA)) already mangled "
                        + "(byte \(mangleOffset) is already "
                        + "'\(Character(UnicodeScalar(mangledByte)))')",
                )
                continue
            }
            guard original == needle else {
                log?(
                    "  [-] string@0x\(hex(site.stringVMA)) bytes look unexpected "
                        + "(\(Data(original).hex)); skipping",
                )
                continue
            }
            log?(
                "  patching string@0x\(hex(site.stringVMA)) (sect=\(site.section)): "
                    + "byte \(mangleOffset) "
                    + "'\(Character(UnicodeScalar(originalByte)))' -> "
                    + "'\(Character(UnicodeScalar(mangledByte)))'  "
                    + "('kern.hv_vmm_present' -> 'kern.Xv_vmm_present')",
            )
            data[data.startIndex + site.fileOffset + mangleOffset] = mangledByte
            patched += 1
        }

        if dryRun {
            log?("  [.] dry-run — not writing back")
            return patched
        }
        if patched > 0 {
            try data.write(to: url)
            log?("  [+] \(url.path): mangled \(patched) cstring occurrence(s)")
        }
        return patched
    }

    // MARK: - Formatting

    private static func hex(_ value: UInt64) -> String {
        String(value, radix: 16, uppercase: true)
    }
}

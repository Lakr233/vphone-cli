// DSCCameraPatcher.swift — The two camera DSC patch families, EXP only.
//
// Port of `scripts/patchers/cfw_patch_camera_dsc.py`, which stays the
// independent reference: the parity gate is the Python run on one clone of the
// real cache and this run on another, with the two clones compared byte for
// byte.
//
// Two families, six sites
// -----------------------
//
//  1. **NeutrinoCore short-circuit** — the five
//     `+[_NUStyleTransfer*Processor processWithInputs:arguments:output:error:]`
//     class methods become `mov w0, #0; ret`. Together with the DT
//     `/product/camera` node (`DeviceTreePatcher`), this lets Camera.app reach
//     the viewfinder: the style-thumbnail pipeline returns NO before it can
//     reach `_NUStyleEngineMemoryResource init…`, which asserts on a nil
//     descriptor when ANE detection comes back NO on this VM and SIGABRTs on
//     the first viewfinder render.
//
//  2. **AVCaptureDevice authorization gate** — `+[AVCaptureDevice
//     authorizationStatusForMediaType:]` in `AVFCapture` becomes
//     `mov w0, #3; ret`, `AVAuthorizationStatusAuthorized`. Every media type,
//     not just video: the VM does not service audio capture either, so an app
//     probing audio auth would have failed downstream regardless. Stage 0 of
//     the vcam stack — apps stop bailing on the auth check; frame delivery is
//     still owed by the downstream pipeline.
//
// What this port does not inherit
// -------------------------------
//
//   * **`ipsw dyld symaddr`.** The Python shells out to the Go tool and parses
//     its coloured output. Here the six symbols come from `DSCSymbolResolver`,
//     which reads the cache's own `.symbols` table. `DSCSymbolResolverTests`
//     pins all six against `ipsw` on the real cache, so the addresses are the
//     same addresses.
//   * **The raw-byte prologue test.** The Python compares the first four bytes
//     against `7f 23 03 d5`. Here the first instruction is decoded and its
//     mnemonic checked, per the patcher guardrails — an encoding of `pacibsp`
//     is recognised as `pacibsp`, not as four bytes.
//   * **Re-attesting per family.** The Python re-attests after each family, off
//     a list of bare addresses. Here every write is recorded by `DSCChunkSet`
//     and `reattestRecordedWrites` runs once at the end, off spans. Same pages
//     on this cache — the six sites are 8 bytes each and none is within 8 bytes
//     of a 16 KiB boundary — but a site that did straddle one would be fully
//     covered here and half-covered there.
//
// It does inherit the idempotence lesson the DSC gates taught three times
// (`cfw_patch_lsd_embedded_reg`, `cfw_patch_xpc_lwcr`,
// `cfw_patch_lockdown_mode` all raised on their own output). A prologue that is
// already the replacement is recognised as such and rewritten inertly, so a
// second install re-attests rather than throwing.
//
// CLI contract preserved from the Python
// --------------------------------------
//
//     cfw.py patch-camera-dsc <chunks_dir> <dsc_header> [--dry-run] [--force]
//     cfw_patch_camera_dsc.py <chunks_dir> <dsc_header> [--dry-run] [--force]
//                             [--avf-only]
//
// `patch_camera_userland.sh dsc <chunks_dir> <dsc_header>` is the shape
// `cfw_install_exp.sh` calls, and it passes neither flag. `<chunks_dir>` is the
// directory of `dyld_shared_cache_arm64e*` files; `<dsc_header>` is the
// unsuffixed chunk inside it, which the Python needed only because `ipsw` wants
// a file rather than a directory. `applyAll` therefore takes the directory
// alone and finds the header itself; `symbolCacheURL` still lets a caller name
// the header separately, which is the only part of the two-argument shape a CLI
// wrapper has to keep accepting.
//
// `--avf-only` is `applyAVFAuthorizationOnly`: the composition mode for a chunk
// pulled off a device that already carries the NeutrinoCore patches.

import Capstone
import Foundation

/// The camera-related patches applied to the SystemOS cryptex's shared cache.
public enum DSCCameraPatcher {
    // MARK: - Targets

    /// Which of the two patch families a site belongs to.
    public enum Family: String, Sendable, CaseIterable {
        case neutrinoStyleTransfer = "nu_styletransfer"
        case avfAuthorization = "avf_authorization"

        /// The image the family's symbols live in.
        public var imagePath: String {
            switch self {
            case .neutrinoStyleTransfer:
                "/System/Library/PrivateFrameworks/NeutrinoCore.framework/NeutrinoCore"
            case .avfAuthorization:
                "/System/Library/PrivateFrameworks/AVFCapture.framework/AVFCapture"
            }
        }

        /// The symbols the family rewrites, in the Python's order.
        public var symbols: [String] {
            switch self {
            case .neutrinoStyleTransfer: DSCCameraPatcher.styleTransferSymbols
            case .avfAuthorization: [DSCCameraPatcher.authorizationStatusSymbol]
            }
        }

        /// The `w0` value the rewritten method returns.
        ///
        /// `0` is `NO` — the style-transfer processors report "did not
        /// process". `3` is `AVAuthorizationStatusAuthorized`.
        public var returnValue: UInt16 {
            switch self {
            case .neutrinoStyleTransfer: 0
            case .avfAuthorization: 3
            }
        }

        var headline: String {
            switch self {
            case .neutrinoStyleTransfer:
                "+[_NUStyleTransfer*Processor processWithInputs:...] → return NO"
            case .avfAuthorization:
                "+[AVCaptureDevice authorizationStatusForMediaType:] → return Authorized"
            }
        }
    }

    /// The five NeutrinoCore class methods, in the reference's order.
    public static let styleTransferSymbols: [String] = [
        "+[_NUStyleTransferProcessor processWithInputs:arguments:output:error:]",
        "+[_NUStyleTransferThumbnailProcessor processWithInputs:arguments:output:error:]",
        "+[_NUStyleTransferApplyProcessor processWithInputs:arguments:output:error:]",
        "+[_NUStyleTransferLearnProcessor processWithInputs:arguments:output:error:]",
        "+[_NUStyleTransferInterpolateProcessor processWithInputs:arguments:output:error:]",
    ]

    /// The AVFCapture authorization entry point.
    public static let authorizationStatusSymbol =
        "+[AVCaptureDevice authorizationStatusForMediaType:]"

    // MARK: - Results

    /// One method entry point rewritten.
    public struct Site: Sendable {
        public let family: Family
        public let symbol: String
        /// `camera_dsc.<family>.<slug>` — the id `cfw_records.next_site` gives
        /// the same write, so a capture taken either side of this port lines up.
        public let patchID: String
        public let vma: UInt64
        public let originalBytes: Data
        public let patchedBytes: Data
        /// True when the entry point already held the replacement and the write
        /// was inert. Never true on a pristine cache.
        public let wasAlreadyPatched: Bool

        public var patchDescription: String {
            switch family {
            case .neutrinoStyleTransfer:
                "\(symbol) -> mov w0, #0; ret"
            case .avfAuthorization:
                "\(symbol) -> mov w0, #3 (AVAuthorizationStatusAuthorized); ret"
            }
        }
    }

    /// What one run of the patcher did.
    public struct Result: Sendable {
        /// Every entry point the run covered, in the order it covered them.
        public let sites: [Site]
        /// The re-attestation pass, or `nil` on a dry run, which does not write
        /// and so has nothing to re-attest.
        public let reattestation: DSCReattestation?
        public let dryRun: Bool

        public var siteCount: Int { sites.count }

        /// True when every site was written and every page they dirtied now
        /// carries a matching slot hash. A dry run is never complete.
        public var isComplete: Bool {
            !dryRun && (reattestation?.isFullyAttested ?? false)
        }
    }

    // MARK: - Entry points

    /// Where diagnostics go when the caller does not say. The Python prints its
    /// progress to stdout and `cfw_install_exp.sh` logs it, so silence is not
    /// the default here either.
    public static let stdoutLog: @Sendable (String) -> Void = { print($0) }

    /// Apply both families — the `cfw.py patch-camera-dsc` path.
    ///
    /// - Parameters:
    ///   - chunksDirectory: the directory of `dyld_shared_cache_arm64e*` files.
    ///   - symbolCacheURL: the unsuffixed chunk symbols are resolved against.
    ///     Defaults to the one inside `chunksDirectory`, which is what every
    ///     caller passes; the Python takes it separately only because `ipsw`
    ///     wants a file.
    ///   - dryRun: report the sites and write nothing.
    ///   - force: accept an entry point whose prologue is neither `pacibsp` nor
    ///     the replacement. The Python's `--force`.
    @discardableResult
    public static func applyAll(
        chunksDirectory: URL,
        symbolCacheURL: URL? = nil,
        dryRun: Bool = false,
        force: Bool = false,
        log: ((String) -> Void)? = stdoutLog
    ) throws -> Result {
        try apply(
            families: Family.allCases,
            chunksDirectory: chunksDirectory,
            symbolCacheURL: symbolCacheURL,
            dryRun: dryRun,
            force: force,
            log: log
        )
    }

    /// Apply only the AVFCapture authorization gate — the Python's
    /// `--avf-only`, for a chunk pulled off a device that already carries the
    /// NeutrinoCore short-circuits.
    @discardableResult
    public static func applyAVFAuthorizationOnly(
        chunksDirectory: URL,
        symbolCacheURL: URL? = nil,
        dryRun: Bool = false,
        force: Bool = false,
        log: ((String) -> Void)? = stdoutLog
    ) throws -> Result {
        try apply(
            families: [.avfAuthorization],
            chunksDirectory: chunksDirectory,
            symbolCacheURL: symbolCacheURL,
            dryRun: dryRun,
            force: force,
            log: log
        )
    }

    // MARK: - The run

    static func apply(
        families: [Family],
        chunksDirectory: URL,
        symbolCacheURL: URL?,
        dryRun: Bool,
        force: Bool,
        log: ((String) -> Void)?
    ) throws -> Result {
        let chunks = try DSCChunkSet(directory: chunksDirectory)
        let resolver = try DSCSymbolResolver(
            mainCacheURL: symbolCacheURL ?? chunks.mainCacheURL
        )
        // Every symbol here is an ObjC class method, and those live only in the
        // stripped local-symbol table. Without it the six lookups would each
        // report "not found", which reads as "this build renamed them".
        try resolver.requireLocalSymbols()

        let disassembler = ARM64Disassembler()
        var sites: [Site] = []

        // Plan every family before writing any of them. Nothing in this loop
        // touches the cache.
        //
        // This used to write each site as it was classified, with one
        // re-attestation pass after the last family. Anything that threw after
        // the first write — a renamed AVF symbol, a prologue that is neither
        // `pacibsp` nor `mov w0,#3; ret` — left the NeutrinoCore sites on disk
        // with their code-signature slot hashes still describing the old bytes.
        // On `codeSigningMonitor == 2` hardware TXM checks those hashes per
        // page, so that cache SIGKILLs on the first demand-page-in of a
        // modified page: a half-patched cache that also fails to load.
        // Reproduced on two identical clones by nop-ing only the AVF entry
        // point — both patchers throw, but the old Swift left four pages of
        // `dyld_shared_cache_arm64e.15` stale where the Python left none.
        //
        // The Python avoids it by resolving both families up front and
        // re-attesting after each one. Planning everything first is stronger:
        // a failure here leaves the cache untouched rather than patched and
        // re-signed up to the failure point.
        for (index, family) in families.enumerated() {
            log?("")
            log?("  [\(index + 1)/\(families.count)] \(family.headline)")

            let replacement = try replacement(returning: family.returnValue)
            log?("    resolving \(family.symbols.count) symbol(s) in \(family.imagePath)")
            let addresses = try resolver.addresses(
                of: family.symbols,
                inImage: family.imagePath
            )

            // Sorted by symbol, as the Python's `sorted(vmas.items())` is. Only
            // the report order depends on it — the bytes do not.
            for symbol in addresses.keys.sorted() {
                // `addresses` is keyed by the names just asked for, so the
                // lookup cannot miss; `addresses(of:inImage:)` throws first.
                guard let vma = addresses[symbol] else { continue }
                let original = try chunks.bytesAtVMA(vma, length: replacement.count)

                log?("  \(symbol)  @ 0x\(String(vma, radix: 16, uppercase: true))")
                log?("    \(original.hex) → \(replacement.hex)")

                let alreadyPatched = try classifyPrologue(
                    original,
                    at: vma,
                    symbol: symbol,
                    returning: family.returnValue,
                    disassembler: disassembler,
                    force: force,
                    log: log
                )

                sites.append(
                    Site(
                        family: family,
                        symbol: symbol,
                        patchID: "camera_dsc.\(family.rawValue).\(symbolSlug(symbol))",
                        vma: vma,
                        originalBytes: original,
                        patchedBytes: replacement,
                        wasAlreadyPatched: alreadyPatched
                    )
                )
            }
        }

        guard !dryRun else {
            log?("  [DRY RUN] \(sites.count) site(s) would be written")
            return Result(sites: sites, reattestation: nil, dryRun: true)
        }

        // Commit. Every fallible step is behind us, so the only thing between
        // the first write and the re-attestation below is more writes.
        for site in sites {
            try chunks.write(at: site.vma, site.patchedBytes)
        }

        // One pass, off the spans the writes recorded. Nothing has to tell it
        // which addresses were touched, so nothing can under-attest.
        let reattestation = try DSCCodeSignature.reattestRecordedWrites(
            in: chunks,
            log: log
        )
        log?("  re-attested \(reattestation.pagesAttested) page(s)")

        // Read the bytes back through the chunk set rather than trusting the
        // write: a site that landed in the wrong chunk would otherwise only
        // show up as a page fault in the guest.
        for site in sites {
            let written = try chunks.bytesAtVMA(site.vma, length: site.patchedBytes.count)
            guard written == site.patchedBytes else {
                throw PatcherError.patchVerificationFailed(
                    "post-write verify failed at 0x\(String(site.vma, radix: 16, uppercase: true)): "
                        + "read back \(written.hex), expected \(site.patchedBytes.hex)"
                )
            }
        }

        log?("")
        log?("  [+] camera DSC patches applied: \(families.count)/\(families.count), "
            + "\(sites.count) site(s)")
        return Result(sites: sites, reattestation: reattestation, dryRun: false)
    }

    // MARK: - The replacement

    /// `mov w0, #<value>; ret`, both halves from the Keystone-checked encoders.
    static func replacement(returning value: UInt16) throws -> Data {
        guard let mov = ARM64Encoder.encodeMovzW(rd: 0, imm16: value) else {
            throw PatcherError.patchVerificationFailed("could not encode mov w0, #\(value)")
        }
        let bytes = mov + ARM64.ret
        guard bytes.count == 8 else {
            throw PatcherError.patchVerificationFailed("expected 8 bytes, got \(bytes.count)")
        }
        return bytes
    }

    // MARK: - The prologue

    /// Decide whether an entry point may be rewritten, and whether it already was.
    ///
    /// Three shapes are acceptable, and the difference matters:
    ///
    ///   * `pacibsp` — a pristine signed-prologue method. The expected case, and
    ///     the only one the Python accepts without `--force`.
    ///   * the replacement itself — this patcher's own output, so the run is a
    ///     re-install. Reported, rewritten inertly, and re-attested, rather than
    ///     raising the way three sibling DSC patchers used to on their own work.
    ///   * anything at all, under `force`.
    ///
    /// - Returns: true when the entry point already held the replacement.
    static func classifyPrologue(
        _ bytes: Data,
        at vma: UInt64,
        symbol: String,
        returning value: UInt16,
        disassembler: ARM64Disassembler,
        force: Bool,
        log: ((String) -> Void)?
    ) throws -> Bool {
        let decoded = disassembler.disassemble(bytes, at: vma, count: 2)

        if decoded.first?.mnemonic == "pacibsp" { return false }

        if isReturnConstantShape(decoded, returning: value, disassembler: disassembler) {
            log?("    [=] already `mov w0, #\(value); ret` — re-install, rewriting inertly")
            return true
        }

        guard force else {
            let head = decoded.first
                .map { "\($0.mnemonic) \($0.operandString)".trimmingCharacters(in: .whitespaces) }
                ?? "<undecodable>"
            throw PatcherError.patchVerificationFailed(
                "\(symbol) @ 0x\(String(vma, radix: 16, uppercase: true)): prologue is not "
                    + "pacibsp (got \(head), bytes \(bytes.prefix(4).hex)); pass force to override"
            )
        }
        log?("    [!] prologue is not pacibsp — forced")
        return false
    }

    /// Is this decode `mov w0, #<value>; ret`?
    ///
    /// Matched on the decode, not on the bytes: the question is "does this
    /// method already return that constant", and a byte comparison would answer
    /// a narrower one that only happens to coincide. `movz` is accepted
    /// alongside its `mov` alias so the answer does not depend on which of the
    /// two Capstone prints.
    static func isReturnConstantShape(
        _ decoded: [Instruction],
        returning value: UInt16,
        disassembler: ARM64Disassembler
    ) -> Bool {
        guard decoded.count == 2,
              decoded[1].mnemonic == "ret",
              decoded[0].mnemonic == "mov" || decoded[0].mnemonic == "movz",
              let operands = decoded[0].aarch64?.operands,
              operands.count == 2,
              operands[0].type == AARCH64_OP_REG,
              operands[1].type == AARCH64_OP_IMM,
              disassembler.firstRegisterName(decoded[0]) == "w0"
        else { return false }
        return operands[1].imm == Int64(value)
    }

    // MARK: - Patch ids

    /// `cfw_patch_camera_dsc._sym_slug` — every run of non-alphanumerics
    /// becomes one underscore, and the ends are trimmed.
    static func symbolSlug(_ symbol: String) -> String {
        var slug = ""
        var pendingSeparator = false
        for character in symbol {
            if character.isASCII, character.isLetter || character.isNumber {
                if pendingSeparator, !slug.isEmpty { slug.append("_") }
                pendingSeparator = false
                slug.append(character)
            } else {
                pendingSeparator = true
            }
        }
        return slug
    }
}

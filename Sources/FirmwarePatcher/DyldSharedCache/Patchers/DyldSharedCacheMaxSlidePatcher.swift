// DyldSharedCacheMaxSlidePatcher.swift — Clamp the dyld shared cache's recorded maxSlide so
// a large userland cache fits the PCC vphone600 26.x kernel's fixed 6 GiB
// shared region.
//
// Swift port of `scripts/patchers/cfw_patch_dsc_maxslide.py`, driven by
// `cfw.py patch-dsc-maxslide <chunks_dir> [--dry-run] [--force]` from
// `cfw_install.sh` and `cfw-kit/lib/base_stages.sh`.
//
// Why the patch exists
// --------------------
// The vphone600 26.x kernel reserves SHARED_REGION_SIZE_ARM64 = 0x180000000
// (6 GiB) at SHARED_REGION_BASE_ARM64 = 0x180000000 (verified by disassembling
// the arm64 case of the kernel's `shared_region_create`). At map time the kernel
// needs room for the cache's mapped span PLUS the cache header's `maxSlide` —
// the ASLR range it will pick a slide from. A newer userland whose cache nearly
// fills the region overflows it:
//
//     iOS 27.0 (24A5380h): span 0x17C830000 (~5.95 GiB)
//                        + maxSlide 0x20000000 (512 MiB)
//                        = 0x19C830000 (~6.46 GiB) > 0x180000000 (6 GiB)
//
// `_shared_region_map_and_slide` then returns ENOMEM, dyld cannot map
// libSystem, and launchd (pid 1) panics: "initproc failed to start -- Library
// not loaded: /usr/lib/libSystem.B.dylib". Older userlands (26.x / 18.x) fit
// with their full slide and are unaffected.
//
// The fix is to zero `maxSlide`, so the cache maps at slide 0 and fits — iOS
// 27.0 leaves ~58 MiB spare. ASLR of the shared cache is lost; nothing else is.
//
// This patcher does NOT re-attest, and that is deliberate
// -------------------------------------------------------
// Every other DSC patcher in this module rewrites an instruction inside a
// dylib's `__TEXT` and has to repair the 16 KiB page slot that covers it, or
// the guest takes a KERN_PROTECTION_FAILURE on the first demand-page-in.
//
// `maxSlide` is not that. It is a field of `dyld_cache_header`, read by the
// kernel while it is setting the mapping up — not a `cs_validate`'d code page.
// The Python reference states the same thing and backs it with a live test: a
// cache poked to maxSlide=0 booted with "dyld cache mapped system-wide" and 0
// panics, and `research/0_binary_patch_comparison.md` row 10 records the
// on-device validation on `17,3_27.0_24A5380h` + cloudOS 26.4.
//
// So `DyldSharedCacheCodeSignature.reattestRecordedWrites(in:)` is *not* called here, and
// after this patcher runs the main chunk's page 0 hashes to something its code
// slot no longer claims. `DyldSharedCacheMaxSlidePatcherTests` pins that state rather than
// leaving it as a thing someone has to remember.
//
// To keep a later batch re-attestation from silently undoing that decision,
// this patcher opens its own `DyldSharedCacheChunkSet` over the directory instead of
// borrowing the caller's. Its write is recorded in a chunk set that goes out of
// scope with the call, so no caller's `reattestRecordedWrites(in:)` can sweep
// the header page up with the code pages it legitimately owns.
//
// On the CLAUDE.md patcher guardrails
// -----------------------------------
// There is no instruction here to decode and none to assemble: the patch writes
// a little-endian u64 metadata field, so Capstone and the Keystone-backed
// `ARM64Encoder` have nothing to contribute. What replaces them is the
// structural check in `readHeader`: the field offsets come from
// `dyld_cache_header` in dyld's `dyld_cache_format.h`, and before they are
// trusted this code applies dyld's own version gate (`mappingOffset` must reach
// past the field) and cross-checks the values it reads against the mapping
// table it parsed independently. A cache whose header does not corroborate the
// layout is refused rather than written into blind.

import Foundation

/// Zeroes `dyld_cache_header.maxSlide` when the cache would otherwise overflow
/// the kernel's fixed shared region.
public enum DyldSharedCacheMaxSlidePatcher {
    // MARK: - Constants

    /// `SHARED_REGION_SIZE_ARM64` as baked into the PCC vphone600 26.x kernel.
    /// A cache's span plus its `maxSlide` must fit inside this or the shared
    /// region map ENOMEMs.
    public static let kernelSharedRegionSize: UInt64 = 0x1_8000_0000

    /// Byte offsets of the `dyld_cache_header` fields this patcher reads, from
    /// dyld's `dyld_cache_format.h`. Stable across every iOS this project
    /// targets, and corroborated at run time — see ``readHeader(from:)``.
    enum HeaderField {
        /// `char magic[16]` — "dyld_v1" followed by the architecture.
        static let magic = 0x00
        /// `uint32_t mappingOffset` — also dyld's own "is this field present"
        /// gate: a field is present when `mappingOffset` reaches past it.
        static let mappingOffset = 0x10
        /// `uint64_t sharedRegionStart`.
        static let sharedRegionStart = 0xE0
        /// `uint64_t sharedRegionSize`.
        static let sharedRegionSize = 0xE8
        /// `uint64_t maxSlide` — the one field this patcher writes.
        static let maxSlide = 0xF0
    }

    /// The `dyld_v1` prefix, checked exactly as the Python checks it: the first
    /// seven bytes, so any architecture suffix passes.
    static let magicPrefix = Data("dyld_v1".utf8)

    /// The patch identifier the reference capture records under.
    public static let patchID = "dsc_maxslide.zero"

    // MARK: - Result

    /// What the gate decided.
    public enum Outcome: Sendable, Equatable {
        /// Span + maxSlide already fits the region, and `force` was not set.
        case fits(combined: UInt64, region: UInt64)
        /// `maxSlide` was already 0, so there is nothing left to clamp.
        case alreadyZero
        /// The cache overflows the region: the patch applies.
        case overflow(combined: UInt64, region: UInt64)
        /// The cache fits but `force` was set, so the patch applies anyway.
        case forced(combined: UInt64, region: UInt64)

        /// True when this outcome means bytes are (or would be) written.
        public var patches: Bool {
            switch self {
            case .fits, .alreadyZero: false
            case .overflow, .forced: true
            }
        }

        /// The sentence the Python prints as its reason, reproduced verbatim so
        /// the two implementations' logs diff cleanly.
        var reason: String? {
            switch self {
            case .fits, .alreadyZero:
                nil
            case let .overflow(combined, region):
                "overflow: span+maxSlide \(DyldSharedCacheMaxSlidePatcher.hex(combined)) > "
                    + "region \(DyldSharedCacheMaxSlidePatcher.hex(region))"
            case let .forced(combined, region):
                "forced: span+maxSlide \(DyldSharedCacheMaxSlidePatcher.hex(combined)) fits "
                    + "region \(DyldSharedCacheMaxSlidePatcher.hex(region)) but --force set"
            }
        }
    }

    /// Everything one run learned and did.
    public struct Result: Sendable {
        /// What the gate decided.
        public let outcome: Outcome
        /// `dyld_cache_header.sharedRegionStart`, as found.
        public let sharedRegionStart: UInt64
        /// `dyld_cache_header.sharedRegionSize`, as found.
        public let sharedRegionSize: UInt64
        /// `dyld_cache_header.maxSlide`, as found — before any write.
        public let maxSlide: UInt64
        /// The patch, when one applies. Present on a dry run too: the Python
        /// returns 1 in that case, meaning "this cache needs the patch".
        public let record: PatchRecord?
        /// The span that landed on disk, or `nil` on a dry run or a no-op.
        public let writtenSpan: DyldSharedCacheWriteSpan?

        /// Sites patched — the Python function's return value, which is 0 or 1.
        public var siteCount: Int {
            record == nil ? 0 : 1
        }

        /// Whether bytes actually reached the chunk file.
        public var didWrite: Bool {
            writtenSpan != nil
        }
    }

    // MARK: - Patching

    /// Clamp `maxSlide` in the cache under `chunksDirectory`.
    ///
    /// Self-gating, exactly as the Python is: a cache whose span plus slide
    /// already fits `kernelRegionSize` is left alone unless `force` is set, and
    /// a cache already at `maxSlide == 0` is left alone either way. That keeps
    /// an 18.x / 26.x base untouched even when the install-side `27.*` gate is
    /// removed, and makes a re-run over an already-patched cache a no-op rather
    /// than an error.
    ///
    /// - Parameters:
    ///   - chunksDirectory: the directory of `dyld_shared_cache_<arch>*` chunks.
    ///   - architecture: cache architecture suffix; `arm64e` on every device
    ///     this project targets.
    ///   - kernelRegionSize: the guest kernel's `SHARED_REGION_SIZE_ARM64`.
    ///   - dryRun: decide and report, but write nothing.
    ///   - force: clamp even when the cache already fits — the `--force` flag
    ///     behind `FORCE_DSC_MAXSLIDE=1`.
    ///   - verbose: print the Python's log lines.
    @discardableResult
    public static func patch(
        chunksDirectory: URL,
        architecture: String = "arm64e",
        kernelRegionSize: UInt64 = kernelSharedRegionSize,
        dryRun: Bool = false,
        force: Bool = false,
        verbose: Bool = true,
    ) throws -> Result {
        let mainChunkName = "dyld_shared_cache_\(architecture)"
        let mainChunk = chunksDirectory.appendingPathComponent(mainChunkName)
        // Checked before the chunk set is built so the error names the file the
        // Python's FileNotFoundError names, rather than the directory.
        guard FileManager.default.fileExists(atPath: mainChunk.path) else {
            throw PatcherError.fileNotFound("main DSC chunk not found: \(mainChunk.path)")
        }

        // The patcher's own chunk set: see the note at the top of the file about
        // why its write log must not be the caller's.
        let chunks = try DyldSharedCacheChunkSet(directory: chunksDirectory, architecture: architecture)
        let headerVMA = try headerVMA(of: chunks)
        let header = try readHeader(from: chunks, at: headerVMA, chunkName: mainChunkName)

        if verbose {
            print(
                "  [.] \(mainChunkName): start=\(hex(header.sharedRegionStart)) "
                    + "size=\(hex(header.sharedRegionSize)) maxSlide=\(hex(header.maxSlide))",
            )
        }

        // Python does this in arbitrary-precision arithmetic. A u64 header where
        // the two fields sum past 2^64 is not a cache, and clamping a field we
        // evidently cannot parse is worse than saying so.
        let (combined, overflowed) = header.sharedRegionSize
            .addingReportingOverflow(header.maxSlide)
        guard !overflowed else {
            throw PatcherError.invalidFormat(
                "\(mainChunk.path): sharedRegionSize \(hex(header.sharedRegionSize)) + maxSlide "
                    + "\(hex(header.maxSlide)) overflows 64 bits; header is not a dyld_cache_header",
            )
        }

        let fits = combined <= kernelRegionSize
        if fits, !force {
            if verbose {
                print(
                    "      [=] fits: span+maxSlide \(hex(combined)) <= "
                        + "region \(hex(kernelRegionSize)); no change",
                )
            }
            return Result(
                outcome: .fits(combined: combined, region: kernelRegionSize),
                sharedRegionStart: header.sharedRegionStart,
                sharedRegionSize: header.sharedRegionSize,
                maxSlide: header.maxSlide,
                record: nil,
                writtenSpan: nil,
            )
        }
        guard header.maxSlide != 0 else {
            if verbose {
                print("      [=] maxSlide already 0; no change")
            }
            return Result(
                outcome: .alreadyZero,
                sharedRegionStart: header.sharedRegionStart,
                sharedRegionSize: header.sharedRegionSize,
                maxSlide: header.maxSlide,
                record: nil,
                writtenSpan: nil,
            )
        }

        let outcome: Outcome = fits
            ? .forced(combined: combined, region: kernelRegionSize)
            : .overflow(combined: combined, region: kernelRegionSize)
        let reason = outcome.reason ?? ""
        if verbose {
            print(
                "      [+] \(reason); \(dryRun ? "would set" : "set") "
                    + "maxSlide \(hex(header.maxSlide)) -> 0x0",
            )
        }

        let fieldVMA = headerVMA &+ UInt64(HeaderField.maxSlide)
        let originalBytes = littleEndianBytes(header.maxSlide)
        let patchedBytes = littleEndianBytes(0)
        let record = PatchRecord(
            patchID: patchID,
            component: mainChunkName,
            fileOffset: HeaderField.maxSlide,
            virtualAddress: fieldVMA,
            originalBytes: originalBytes,
            patchedBytes: patchedBytes,
            description: "dyld_cache_header maxSlide \(hex(header.maxSlide)) -> 0 (\(reason))",
        )

        guard !dryRun else {
            // The Python prints its completion line on a dry run too — the run
            // did complete, it just wrote nothing. Every log line in this
            // function is kept identical to the Python's, so a `--dry-run` of
            // one can be diffed against a `--dry-run` of the other.
            if verbose {
                print("  [+] DSC maxSlide patch complete")
            }
            return Result(
                outcome: outcome,
                sharedRegionStart: header.sharedRegionStart,
                sharedRegionSize: header.sharedRegionSize,
                maxSlide: header.maxSlide,
                record: record,
                writtenSpan: nil,
            )
        }

        let span = try chunks.write(at: fieldVMA, patchedBytes)

        // Read the field back through the same addressing the write used, the
        // way the Python re-reads and unpacks it. A write that reported success
        // and left the old value is the one failure mode that would boot into
        // the panic this patch exists to prevent.
        let readBack = try chunks.bytesAtVMA(fieldVMA, length: 8).loadLE(UInt64.self, at: 0)
        guard readBack == 0 else {
            throw PatcherError.patchVerificationFailed(
                "maxSlide write verify failed: \(hex(readBack))",
            )
        }

        // No `DyldSharedCacheCodeSignature.reattestRecordedWrites(in: chunks)` here. See the
        // file header: this field is kernel-read cache metadata, not a
        // cs_validate'd code page, and leaving the slot alone is the behaviour
        // that was validated on device.

        if verbose {
            print("  [+] DSC maxSlide patch complete")
        }
        return Result(
            outcome: outcome,
            sharedRegionStart: header.sharedRegionStart,
            sharedRegionSize: header.sharedRegionSize,
            maxSlide: header.maxSlide,
            record: record,
            writtenSpan: span,
        )
    }

    // MARK: - Header

    /// The three header fields the gate runs on.
    struct Header: Sendable, Equatable {
        let sharedRegionStart: UInt64
        let sharedRegionSize: UInt64
        let maxSlide: UInt64
    }

    /// The address the main chunk's byte 0 is mapped at.
    ///
    /// Derived from the mapping table rather than written down: the header lives
    /// at file offset 0 of the unsuffixed chunk, so the mapping that carries
    /// file offset 0 of that chunk is the one that carries the header.
    static func headerVMA(of chunks: DyldSharedCacheChunkSet) throws -> UInt64 {
        let main = chunks.mainCacheURL
        guard let mapping = chunks.mappings.first(where: {
            $0.chunkURL == main && $0.fileOffset == 0
        }) else {
            throw PatcherError.invalidFormat(
                "\(main.path): no mapping covers the cache header at file offset 0",
            )
        }
        return mapping.address
    }

    /// Read and corroborate the header fields.
    ///
    /// Three checks stand in for the Capstone decode a code patcher would do:
    ///
    /// * the `dyld_v1` magic, checked over seven bytes as the Python checks it;
    /// * dyld's own field-presence gate — `mappingOffset` is where the mapping
    ///   table starts, so the header struct runs out at that offset, and a field
    ///   only exists in this cache version if `mappingOffset` reaches past it;
    /// * agreement with the mapping table this code parsed on its own:
    ///   `sharedRegionStart` has to be the lowest address the cache maps, and
    ///   `sharedRegionSize` has to cover everything it maps. Both hold on the
    ///   24A435 arm64e cache (start 0x180000000, size 0x17D504000 against a
    ///   0x17D500000 span). If they did not, the offsets would be describing
    ///   some other struct and the write would land in an unknown field.
    static func readHeader(
        from chunks: DyldSharedCacheChunkSet,
        at headerVMA: UInt64,
        chunkName: String,
    ) throws -> Header {
        let header = try chunks.bytesAtVMA(headerVMA, length: 0x100)

        guard header.prefix(magicPrefix.count) == magicPrefix else {
            let magic = header.subdata(in: HeaderField.magic ..< (HeaderField.magic + 16))
            throw PatcherError.invalidFormat(
                "\(chunkName): not a dyld shared cache (magic=\(magic.hex))",
            )
        }

        let mappingOffset = Int(header.loadLE(UInt32.self, at: HeaderField.mappingOffset))
        let fieldEnd = HeaderField.maxSlide + MemoryLayout<UInt64>.size
        guard mappingOffset >= fieldEnd else {
            throw PatcherError.invalidFormat(
                "\(chunkName): dyld_cache_header ends at \(hex(UInt64(mappingOffset))), before "
                    + "maxSlide at \(hex(UInt64(HeaderField.maxSlide))); this cache version has no "
                    + "maxSlide field",
            )
        }

        let parsed = Header(
            sharedRegionStart: header.loadLE(UInt64.self, at: HeaderField.sharedRegionStart),
            sharedRegionSize: header.loadLE(UInt64.self, at: HeaderField.sharedRegionSize),
            maxSlide: header.loadLE(UInt64.self, at: HeaderField.maxSlide),
        )

        let mapped = chunks.addressRange
        guard parsed.sharedRegionStart == mapped.lowerBound else {
            throw PatcherError.invalidFormat(
                "\(chunkName): sharedRegionStart \(hex(parsed.sharedRegionStart)) is not the "
                    + "cache's lowest mapped address \(hex(mapped.lowerBound)); the header layout "
                    + "is not the one these offsets describe",
            )
        }
        let span = mapped.upperBound &- mapped.lowerBound
        guard parsed.sharedRegionSize >= span else {
            throw PatcherError.invalidFormat(
                "\(chunkName): sharedRegionSize \(hex(parsed.sharedRegionSize)) is smaller than "
                    + "the \(hex(span)) the cache actually maps; the header layout is not the one "
                    + "these offsets describe",
            )
        }
        return parsed
    }

    // MARK: - Formatting

    /// The 8 bytes a little-endian `uint64_t` field holds for `value`.
    ///
    /// Spelled as a value conversion rather than a byte literal: nothing here is
    /// an instruction, and nothing here should read like one.
    static func littleEndianBytes(_ value: UInt64) -> Data {
        withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }

    /// `0x%X`, matching the Python's f-strings so the two logs diff cleanly.
    static func hex(_ value: UInt64) -> String {
        "0x" + String(value, radix: 16, uppercase: true)
    }
}

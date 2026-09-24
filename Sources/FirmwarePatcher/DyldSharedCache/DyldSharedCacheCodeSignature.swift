// DyldSharedCacheCodeSignature.swift — Page-hash re-signing for dyld shared cache chunks.
//
// Why this exists
// ---------------
// On iPhone17,3 / iOS 26+ the kernel runs with `codeSigningMonitor == 2`: it
// hands per-page hash validation to TXM, and TXM holds the slot hashes the
// cache was registered with. So a byte changed inside an executable mapping
// does not fail at patch time, or at boot; it fails the first time that 16 KiB
// page is demand-paged in, as a `KERN_PROTECTION_FAILURE` / SIGKILL on
// whichever process touched it. Every DSC edit has to be followed by re-hashing
// the affected page's slot, or the guest panics on a page fault nobody can
// trace back to the patch.
//
// This is the DSC path and it is not the Mach-O path
// --------------------------------------------------
// The two must not share an implementation. Here:
//
//   * the signature is found through the chunk header's
//     `codeSignatureOffset` @0x28 / `codeSignatureSize` @0x30 — a DSC image
//     carries no `LC_CODE_SIGNATURE` of its own, only the chunk-level one
//   * pages are 16 KiB (`pageSize` log2 == 14), not 4 KiB
//   * there is a single code directory, no alternate SHA-1 CD to skip past
//   * chunks are page-aligned, so `nCodeSlots * pageSize == codeLimit` and
//     there is no short tail slot. The independent Mach-O path does have one,
//     and getting it wrong is what regressed re-signing once already.
//
// Side effect, by design
// ----------------------
// Rewriting slot hashes changes the code directory's contents and therefore its
// cdHash. That is only survivable because the JB kernel patch
// `patch_amfi_cdhash_in_trustcache` — `KernelJailbreakPatchAmfiTrustcache` in this
// repo — short-circuits AMFI's per-image trust-cache lookup to return 1. This
// file must not be used on a firmware that does not carry that patch.
//
// Port of `scripts/patchers/cfw_dsc_codesign.py`, which stays the independent
// reference for the slot hashes computed here.
//
// It is not a port of how the reference chooses *which* pages to hash. The
// Python takes bare addresses and hashes one page each, so a write that crosses
// a 16 KiB boundary leaves the following page's slot stale and still reports
// success — reproduced on the 24A435 cache with an 8-byte write at
// 0x22AC0FFFC, which dirties pages 2563 and 2564 and gets 2563 re-signed. The
// six sites `cfw_patch_camera_dsc.py` writes miss that by 1072 bytes, so the
// reference is safe by margin rather than by construction. Here the page set is
// derived from the spans that were actually written, and `DyldSharedCacheChunkSet` records
// those itself.

import CryptoKit
import Foundation

/// The `CS_CodeDirectory` of one chunk, reduced to what re-signing needs.
public struct DyldSharedCacheChunkCodeDirectory: Sendable {
    /// Offset of the CD blob within the chunk file.
    public let blobOffset: Int
    /// Byte length of the CD blob.
    public let blobLength: Int
    /// Offset of slot 0 within the CD blob.
    public let hashOffset: Int
    /// Bytes per slot — 32 for SHA-256.
    public let hashSize: Int
    /// Number of code slots.
    public let codeSlotCount: Int
    /// Chunk byte range the signature covers.
    public let codeLimit: Int
    /// Bytes per slot's page — 16384 on this cache.
    public let pageSize: Int

    /// Chunk-file offset of slot `index`'s hash.
    public func slotOffset(forPage index: Int) -> Int {
        blobOffset + hashOffset + index * hashSize
    }
}

/// One slot rewritten, for logging and for cross-checking against the Python.
public struct DyldSharedCacheSlotReattestation: Sendable {
    public let chunkURL: URL
    public let pageIndex: Int
    /// Offset of the page's first byte in the chunk file.
    public let chunkOffset: Int
    /// Offset of the slot hash in the chunk file.
    public let slotOffset: Int
    public let hashBefore: Data
    public let hashAfter: Data
}

/// One page of one chunk.
public struct DyldSharedCachePageReference: Sendable, Hashable {
    public let chunkURL: URL
    public let pageIndex: Int
}

/// A page that re-attestation could not cover, and why.
///
/// Every one of these used to be an early `continue` that produced no record
/// and, under the default `log: nil`, no output either — so "I skipped it" came
/// back looking exactly like "there was nothing to do". The Python reference
/// prints each one, and so does this, but the caller also gets them as values
/// rather than as text it would have to have been listening for.
public struct DyldSharedCacheReattestationSkip: Sendable {
    public enum Reason: Sendable, CustomStringConvertible {
        case addressNotMapped(vma: UInt64)
        case spanNotAddressable(vma: UInt64, length: Int)
        case chunkHasNoCodeDirectory(chunk: String)
        case pageBeyondCodeSlots(chunk: String, page: Int, codeSlotCount: Int)
        case pageBeyondCodeLimit(chunk: String, page: Int, codeLimit: Int)
        case shortPageRead(chunk: String, page: Int, got: Int, wanted: Int)

        public var description: String {
            switch self {
            case let .addressNotMapped(vma):
                "vma 0x\(String(vma, radix: 16, uppercase: true)) not mapped in any chunk"
            case let .spanNotAddressable(vma, length):
                "span at vma 0x\(String(vma, radix: 16, uppercase: true)) length \(length) "
                    + "runs past the end of its chunk"
            case let .chunkHasNoCodeDirectory(chunk):
                "chunk \(chunk) has no recognised CS_SuperBlob/CD"
            case let .pageBeyondCodeSlots(chunk, page, codeSlotCount):
                "page \(page) of \(chunk) is past nCodeSlots (\(codeSlotCount))"
            case let .pageBeyondCodeLimit(chunk, page, codeLimit):
                "page \(page) of \(chunk) overruns codeLimit "
                    + "(0x\(String(codeLimit, radix: 16, uppercase: true)))"
            case let .shortPageRead(chunk, page, got, wanted):
                "short read at page \(page) of \(chunk) (got \(got) of \(wanted))"
            }
        }
    }

    public let reason: Reason
    public var description: String {
        reason.description
    }
}

/// What one re-attestation run did.
///
/// Three outcomes that used to share the empty array are separate here: no
/// pages were eligible, every page already matched, and some pages were
/// skipped. A caller that wants "the patch is fully covered" should check
/// `isFullyAttested`.
public struct DyldSharedCacheReattestation: Sendable {
    /// Slots whose stored hash was changed (or, on a dry run, would have been).
    public let updated: [DyldSharedCacheSlotReattestation]
    /// Pages whose stored slot already matched what the page hashes to.
    public let alreadyAttested: [DyldSharedCachePageReference]
    /// Pages that could not be covered at all.
    public let skipped: [DyldSharedCacheReattestationSkip]

    /// Pages the run actually reached — rewritten plus already-correct.
    public var pagesAttested: Int {
        updated.count + alreadyAttested.count
    }

    /// True when every page the caller's spans touched now carries a slot hash
    /// that matches its contents. False the moment anything was skipped.
    public var isFullyAttested: Bool {
        skipped.isEmpty
    }

    public var summary: String {
        "\(updated.count) slot(s) rewritten, \(alreadyAttested.count) already correct, "
            + "\(skipped.count) skipped"
    }
}

public enum DyldSharedCacheCodeSignature {
    static let superBlobMagic: UInt32 = 0xFADE_0CC0
    static let codeDirectoryMagic: UInt32 = 0xFADE_0C02
    static let codeDirectorySlot: UInt32 = 0
    static let hashTypeSHA256: UInt8 = 2

    // MARK: - Reading the chunk's code directory

    /// Locate a chunk's `CS_CodeDirectory`.
    ///
    /// Returns `nil` — rather than throwing — when the chunk simply has no
    /// signature to update. Several chunks in a cache are like that, and a
    /// patch that lands in one of them is not an error.
    public static func readCodeDirectory(ofChunk url: URL) throws -> DyldSharedCacheChunkCodeDirectory? {
        let head = try DyldSharedCacheChunkSet.read(url: url, offset: 0, length: 0x100)
        guard head.count >= 0x38, head.prefix(5) == Data("dyld_".utf8) else { return nil }

        let signatureOffset = head.loadLE(UInt64.self, at: 0x28)
        let signatureSize = head.loadLE(UInt64.self, at: 0x30)
        guard signatureOffset != 0, signatureSize != 0 else { return nil }

        // CS_SuperBlob, big-endian.
        let superHead = try DyldSharedCacheChunkSet.read(url: url, offset: signatureOffset, length: 12)
        guard superHead.count == 12 else { return nil }
        guard superHead.loadBE(UInt32.self, at: 0) == superBlobMagic else { return nil }
        let superLength = superHead.loadBE(UInt32.self, at: 4)
        let blobCount = superHead.loadBE(UInt32.self, at: 8)
        guard UInt64(superLength) <= signatureSize, blobCount <= 256 else { return nil }

        let indexData = try DyldSharedCacheChunkSet.read(
            url: url,
            offset: signatureOffset + 12,
            length: Int(blobCount) * 8,
        )
        guard indexData.count == Int(blobCount) * 8 else { return nil }

        var directoryOffsetInSuperBlob: UInt32?
        for index in 0 ..< Int(blobCount) {
            let slotType = indexData.loadBE(UInt32.self, at: index * 8)
            if slotType == codeDirectorySlot {
                directoryOffsetInSuperBlob = indexData.loadBE(UInt32.self, at: index * 8 + 4)
                break
            }
        }
        guard let directoryOffsetInSuperBlob else { return nil }
        let blobOffset = signatureOffset + UInt64(directoryOffsetInSuperBlob)

        // CS_CodeDirectory, big-endian.
        let directoryHead = try DyldSharedCacheChunkSet.read(url: url, offset: blobOffset, length: 44)
        guard directoryHead.count == 44 else { return nil }
        guard directoryHead.loadBE(UInt32.self, at: 0) == codeDirectoryMagic else { return nil }

        let blobLength = Int(directoryHead.loadBE(UInt32.self, at: 4))
        let hashOffset = Int(directoryHead.loadBE(UInt32.self, at: 16))
        let codeSlotCount = Int(directoryHead.loadBE(UInt32.self, at: 28))
        let codeLimit = Int(directoryHead.loadBE(UInt32.self, at: 32))
        let hashSize = Int(directoryHead[directoryHead.startIndex + 36])
        let hashType = directoryHead[directoryHead.startIndex + 37]
        let pageSizeLog2 = directoryHead[directoryHead.startIndex + 39]

        // Only SHA-256 slots are recomputable here. A cache signed with
        // anything else needs its own code path, and guessing would write
        // 32 bytes of the wrong digest into a 20-byte slot.
        guard hashType == hashTypeSHA256, hashSize == 32 else { return nil }
        let pageSize = 1 << Int(pageSizeLog2)
        guard pageSize > 0, pageSize <= (1 << 20) else { return nil }

        return DyldSharedCacheChunkCodeDirectory(
            blobOffset: Int(blobOffset),
            blobLength: blobLength,
            hashOffset: hashOffset,
            hashSize: hashSize,
            codeSlotCount: codeSlotCount,
            codeLimit: codeLimit,
            pageSize: pageSize,
        )
    }

    // MARK: - Re-signing

    /// Where diagnostics go when the caller does not say.
    ///
    /// `cfw_dsc_codesign.reattest_modified_pages` defaults to `verbose=True`
    /// and prints every skip it makes. Defaulting this to `nil` was how the
    /// port lost that: an unmapped address, an unsigned chunk and an empty
    /// input all came back as an empty array with nothing written anywhere.
    /// Callers that really want silence pass `log: nil` and read the returned
    /// `DyldSharedCacheReattestation` instead.
    public static let stderrLog: @Sendable (String) -> Void = { line in
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }

    /// Recompute and store the slot hash of every 16 KiB page any of
    /// `modifiedSpans` touched.
    ///
    /// Spans, not addresses, on purpose. A span knows its length, so an 8-byte
    /// write four bytes before a page boundary dirties two pages and both get
    /// re-hashed. The address-only version of this could not know that and
    /// silently left the second page stale — a `KERN_PROTECTION_FAILURE` the
    /// first time the guest demand-paged it in.
    ///
    /// Pages are coalesced, so patching four sites in one page costs one hash.
    /// A page whose stored slot already matches what the page hashes to is left
    /// alone and reported in `alreadyAttested`, which is what makes a second
    /// run over an already-patched cache a no-op rather than a rewrite.
    @discardableResult
    public static func reattest(
        in chunks: DyldSharedCacheChunkSet,
        modifiedSpans: some Sequence<DyldSharedCacheWriteSpan>,
        dryRun: Bool = false,
        log: ((String) -> Void)? = stderrLog,
    ) throws -> DyldSharedCacheReattestation {
        var pagesByChunk: [URL: Set<Int>] = [:]
        var directories: [URL: DyldSharedCacheChunkCodeDirectory?] = [:]
        var skipped: [DyldSharedCacheReattestationSkip] = []

        func skip(_ reason: DyldSharedCacheReattestationSkip.Reason) {
            skipped.append(DyldSharedCacheReattestationSkip(reason: reason))
            log?("      [-] re-attest: \(reason) — skipping")
        }

        for span in modifiedSpans {
            let chunkURL: URL
            let byteRange: Range<Int>
            do {
                (chunkURL, byteRange) = try chunks.fileRange(of: span)
            } catch DyldSharedCacheError.addressNotMapped {
                skip(.addressNotMapped(vma: span.vma))
                continue
            } catch DyldSharedCacheError.addressSpanCrossesChunk {
                skip(.spanNotAddressable(vma: span.vma, length: span.length))
                continue
            }

            let directory: DyldSharedCacheChunkCodeDirectory?
            if let cached = directories[chunkURL] {
                directory = cached
            } else {
                directory = try readCodeDirectory(ofChunk: chunkURL)
                directories[chunkURL] = directory
                if directory == nil {
                    skip(.chunkHasNoCodeDirectory(chunk: chunkURL.lastPathComponent))
                }
            }
            guard let directory else { continue }

            // Every page the span's bytes land in, not just the first.
            let firstPage = byteRange.lowerBound / directory.pageSize
            let lastPage = (byteRange.upperBound - 1) / directory.pageSize
            for pageIndex in firstPage ... lastPage {
                guard pageIndex < directory.codeSlotCount else {
                    skip(.pageBeyondCodeSlots(
                        chunk: chunkURL.lastPathComponent,
                        page: pageIndex,
                        codeSlotCount: directory.codeSlotCount,
                    ))
                    continue
                }
                guard (pageIndex + 1) * directory.pageSize <= directory.codeLimit else {
                    skip(.pageBeyondCodeLimit(
                        chunk: chunkURL.lastPathComponent,
                        page: pageIndex,
                        codeLimit: directory.codeLimit,
                    ))
                    continue
                }
                pagesByChunk[chunkURL, default: []].insert(pageIndex)
            }
        }

        guard !pagesByChunk.isEmpty else {
            log?(
                "      [.] re-attest: no eligible pages "
                    + "(\(skipped.count) skipped)",
            )
            return DyldSharedCacheReattestation(updated: [], alreadyAttested: [], skipped: skipped)
        }

        var records: [DyldSharedCacheSlotReattestation] = []
        var alreadyAttested: [DyldSharedCachePageReference] = []
        for chunkURL in pagesByChunk.keys.sorted(by: { $0.path < $1.path }) {
            guard let directory = directories[chunkURL] ?? nil else { continue }
            let handle = dryRun
                ? try FileHandle(forReadingFrom: chunkURL)
                : try FileHandle(forUpdating: chunkURL)
            defer { try? handle.close() }

            for pageIndex in pagesByChunk[chunkURL, default: []].sorted() {
                let pageOffset = pageIndex * directory.pageSize
                let slotOffset = directory.slotOffset(forPage: pageIndex)

                try handle.seek(toOffset: UInt64(pageOffset))
                let pageData = try handle.read(upToCount: directory.pageSize) ?? Data()
                guard pageData.count == directory.pageSize else {
                    skip(.shortPageRead(
                        chunk: chunkURL.lastPathComponent,
                        page: pageIndex,
                        got: pageData.count,
                        wanted: directory.pageSize,
                    ))
                    continue
                }
                let newHash = Data(SHA256.hash(data: pageData))

                try handle.seek(toOffset: UInt64(slotOffset))
                let oldHash = try handle.read(upToCount: directory.hashSize) ?? Data()

                guard oldHash != newHash else {
                    alreadyAttested.append(
                        DyldSharedCachePageReference(chunkURL: chunkURL, pageIndex: pageIndex),
                    )
                    log?(
                        "      [.] re-attest: page \(pageIndex) of "
                            + "\(chunkURL.lastPathComponent) slot already matches (no-op)",
                    )
                    continue
                }

                if !dryRun {
                    try handle.seek(toOffset: UInt64(slotOffset))
                    try handle.write(contentsOf: newHash)
                }
                log?(
                    "      [+] re-attest: \(dryRun ? "would write" : "wrote") slot "
                        + "\(pageIndex) of \(chunkURL.lastPathComponent)  "
                        + "(\(Data(oldHash.prefix(4)).hex).. -> \(Data(newHash.prefix(4)).hex)..)",
                )
                records.append(
                    DyldSharedCacheSlotReattestation(
                        chunkURL: chunkURL,
                        pageIndex: pageIndex,
                        chunkOffset: pageOffset,
                        slotOffset: slotOffset,
                        hashBefore: oldHash,
                        hashAfter: newHash,
                    ),
                )
            }
        }

        log?(
            "  [+] re-attest: \(dryRun ? "would update" : "updated") \(records.count) "
                + "slot hash(es) across \(pagesByChunk.count) chunk(s), "
                + "\(alreadyAttested.count) already correct, \(skipped.count) skipped",
        )
        return DyldSharedCacheReattestation(
            updated: records,
            alreadyAttested: alreadyAttested,
            skipped: skipped,
        )
    }

    /// Re-attest every page that `chunks`'s own writes dirtied.
    ///
    /// The path a patcher should take: write through `DyldSharedCacheChunkSet.write(at:_:)`
    /// as many times as it likes, then call this. Nothing has to be told which
    /// addresses were touched, so nothing can get it wrong.
    @discardableResult
    public static func reattestRecordedWrites(
        in chunks: DyldSharedCacheChunkSet,
        dryRun: Bool = false,
        log: ((String) -> Void)? = stderrLog,
    ) throws -> DyldSharedCacheReattestation {
        try reattest(
            in: chunks,
            modifiedSpans: chunks.recordedWrites,
            dryRun: dryRun,
            log: log,
        )
    }

    // MARK: - Inspection

    /// The SHA-256 a page currently hashes to, and the slot hash stored for it.
    ///
    /// Used by tests and by idempotence checks: when the two are equal the page
    /// is already attested, whether this code wrote the slot or the Python did.
    public static func pageHashes(
        chunkURL: URL,
        pageIndex: Int,
        directory: DyldSharedCacheChunkCodeDirectory,
    ) throws -> (computed: Data, stored: Data) {
        let page = try DyldSharedCacheChunkSet.read(
            url: chunkURL,
            offset: UInt64(pageIndex * directory.pageSize),
            length: directory.pageSize,
        )
        let stored = try DyldSharedCacheChunkSet.read(
            url: chunkURL,
            offset: UInt64(directory.slotOffset(forPage: pageIndex)),
            length: directory.hashSize,
        )
        return (Data(SHA256.hash(data: page)), stored)
    }
}

// MARK: - Big-endian load

// File-private: `CustomFirmwareMachOCodeSignature` declares the same helper for the
// independent Mach-O path. The two signature paths are deliberately separate
// implementations, and keeping their helpers file-scoped is what stops them
// drifting into a shared one.
private extension Data {
    /// Load a big-endian integer without assuming the buffer is aligned.
    ///
    /// Code-signing blobs are big-endian throughout, which is the one place in
    /// a Mach-O or a dyld cache where that is true.
    func loadBE<T: FixedWidthInteger>(_: T.Type, at offset: Int) -> T {
        precondition(offset >= 0 && offset + MemoryLayout<T>.size <= count)
        var value: T = .zero
        _ = Swift.withUnsafeMutableBytes(of: &value) { destination in
            copyBytes(to: destination, from: offset ..< offset + MemoryLayout<T>.size)
        }
        return T(bigEndian: value)
    }
}

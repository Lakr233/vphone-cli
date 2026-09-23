// CFWMachOCodeSignature.swift — Standalone Mach-O code-signature page-hash re-attestation.
//
// Port of `scripts/patchers/cfw_macho_codesign.py` (344 lines). The DSC-chunk
// half of the same technique lives elsewhere and deliberately does NOT share
// this code: the two differ in where the signature is found, in page size, in
// how many code directories exist, and — the part that bit us before — in
// whether the last slot covers a whole page.
//
// Why this exists at all: on iPhone17,3 / iOS 26.x `codeSigningMonitor == 2`,
// so the kernel hands per-page hash validation to TXM. TXM holds the original
// slot hashes, so any byte we change inside an executable mapping is a
// KERN_PROTECTION_FAILURE / SIGKILL the first time that page is demand-paged
// in. Recomputing the slot hash for every page we touched is what keeps a
// patched binary runnable.
//
// Side effect, unchanged from the Python: rewriting slot hashes mutates the
// CodeDirectory, and therefore the cdHash. The JB kernel patch
// `patch_amfi_cdhash_in_trustcache` short-circuits AMFI's trust-cache lookup so
// the mutated cdHash is not rejected at execve. That precondition still holds
// for this implementation — do not drop it.

import CryptoKit
import Foundation

// MARK: - Byte Reading

// The Mach-O header and load commands are little-endian; everything inside the
// CS_SuperBlob is big-endian. Data.loadLE covers the first half, so this file
// only needs the second.
private extension Data {
    func loadBE<T: FixedWidthInteger>(_: T.Type, at offset: Int) -> T {
        var value: T = .zero
        _ = Swift.withUnsafeMutableBytes(of: &value) { destination in
            copyBytes(to: destination, from: offset ..< offset + MemoryLayout<T>.size)
        }
        return T(bigEndian: value)
    }

    func fits(_ offset: Int, _ length: Int) -> Bool {
        offset >= 0 && length >= 0 && offset + length <= count
    }
}

// MARK: - Code Directory

/// One `CS_CodeDirectory` blob inside a Mach-O's embedded signature.
public struct CFWCodeDirectory: Sendable, Equatable {
    /// `CS_BlobIndex.type` this CD was reached through (0 = primary, 0x1000+ = alt).
    public let slotType: UInt32
    /// Absolute file offset of the CD blob.
    public let offset: Int
    public let length: Int
    /// Offset within the CD blob of code slot 0.
    public let hashOffset: Int
    public let hashSize: Int
    public let hashType: UInt8
    public let pageSize: Int
    public let pageSizeLog2: UInt8
    public let codeSlotCount: Int
    /// The CD covers `[0, codeLimit)` of the file. Rarely page-aligned.
    public let codeLimit: Int

    /// File offset of slot `index`'s hash.
    public func slotHashOffset(_ index: Int) -> Int {
        offset + hashOffset + index * hashSize
    }

    /// The byte range slot `index` hashes.
    ///
    /// Clamped to `codeLimit`, which is what makes the last slot SHORT. Getting
    /// this wrong is the known regression in independent Mach-O re-signing: the
    /// tail slot hashes `codeLimit - slotStart` bytes, not a full page, and a
    /// full-page hash there produces a binary that is SIGKILLed on first page-in.
    public func slotRange(_ index: Int) -> Range<Int>? {
        guard index >= 0, index < codeSlotCount else { return nil }
        let start = index * pageSize
        guard start < codeLimit else { return nil }
        return start ..< Swift.min(start + pageSize, codeLimit)
    }
}

// MARK: - Slot Rehash Record

/// One slot hash that re-attestation replaced.
public struct CFWSlotRehash: Sendable, Equatable {
    public let codeDirectoryOffset: Int
    public let slotType: UInt32
    public let pageIndex: Int
    public let pageStart: Int
    public let pageEnd: Int
    /// File offset the new hash was written to.
    public let hashFileOffset: Int
    public let before: Data
    public let after: Data
    /// Page size of the code directory this slot belongs to.
    public let pageSize: Int

    /// Bytes actually hashed. Less than `pageSize` for the tail slot.
    public var hashedLength: Int { pageEnd - pageStart }
    public var isTailSlot: Bool { hashedLength != pageSize }
}

extension CFWSlotRehash: CustomStringConvertible {
    public var description: String {
        let tail = isTailSlot ? " [tail, \(hashedLength)B]" : ""
        return String(
            format: "slot %d%@ @0x%X: %@.. -> %@..",
            pageIndex,
            tail,
            hashFileOffset,
            String(before.hex.prefix(8)),
            String(after.hex.prefix(8))
        )
    }
}

// MARK: - Re-attestation

public enum CFWMachOCodeSignature {
    // MARK: Constants

    static let superBlobMagic: UInt32 = 0xFADE_0CC0
    static let codeDirectoryMagic: UInt32 = 0xFADE_0C02

    public static let hashTypeSHA1: UInt8 = 1
    public static let hashTypeSHA256: UInt8 = 2
    public static let hashTypeSHA384: UInt8 = 3
    public static let hashTypeSHA256Truncated: UInt8 = 4

    static let lcCodeSignature: UInt32 = 0x1D
    static let machMagic64: UInt32 = 0xFEED_FACF

    /// A CD's own header is 44 bytes up to and including `codeLimit`.
    static let codeDirectoryHeaderSize = 44
    /// Guard against a runaway `count` in a corrupt SuperBlob. Matches the Python.
    static let maxSuperBlobEntries = 256

    // MARK: Parsing

    /// `(dataoff, datasize)` of the binary's LC_CODE_SIGNATURE, or nil.
    public static func codeSignatureCommand(in data: Data) -> (offset: Int, size: Int)? {
        let data = rebased(data)
        guard data.fits(0, 32), data.loadLE(UInt32.self, at: 0) == machMagic64 else { return nil }
        let ncmds = data.loadLE(UInt32.self, at: 16)
        var offset = 32 // sizeof(mach_header_64)
        for _ in 0 ..< ncmds {
            guard data.fits(offset, 8) else { return nil }
            let cmd = data.loadLE(UInt32.self, at: offset)
            let cmdsize = Int(data.loadLE(UInt32.self, at: offset + 4))
            if cmd == lcCodeSignature {
                guard data.fits(offset, 16) else { return nil }
                return (
                    Int(data.loadLE(UInt32.self, at: offset + 8)),
                    Int(data.loadLE(UInt32.self, at: offset + 12))
                )
            }
            guard cmdsize > 0 else { return nil }
            offset += cmdsize
        }
        return nil
    }

    /// Every `CS_CodeDirectory` in the embedded signature, in SuperBlob order.
    ///
    /// Returns nil when there is no signature or it is unparsable — the caller
    /// decides whether that is fatal. An empty array means a signature exists
    /// but holds no CodeDirectory, which is malformed.
    public static func codeDirectories(in data: Data) -> [CFWCodeDirectory]? {
        let data = rebased(data)
        guard let signature = codeSignatureCommand(in: data) else { return nil }
        guard let blobs = superBlobEntries(in: data, at: signature.offset) else { return nil }
        return blobs.compactMap { entry in
            guard entry.magic == codeDirectoryMagic else { return nil }
            return parseCodeDirectory(in: data, at: entry.offset, slotType: entry.slotType)
        }
    }

    static func superBlobEntries(
        in data: Data,
        at superBlobOffset: Int
    ) -> [(slotType: UInt32, offset: Int, magic: UInt32)]? {
        guard data.fits(superBlobOffset, 12) else { return nil }
        let magic = data.loadBE(UInt32.self, at: superBlobOffset)
        let length = Int(data.loadBE(UInt32.self, at: superBlobOffset + 4))
        let count = Int(data.loadBE(UInt32.self, at: superBlobOffset + 8))
        guard magic == superBlobMagic else { return nil }
        guard count <= maxSuperBlobEntries, data.fits(superBlobOffset, length) else { return nil }

        var entries: [(slotType: UInt32, offset: Int, magic: UInt32)] = []
        for index in 0 ..< count {
            let entryOffset = superBlobOffset + 12 + index * 8
            guard data.fits(entryOffset, 8) else { return nil }
            let slotType = data.loadBE(UInt32.self, at: entryOffset)
            let blobOffset = superBlobOffset + Int(data.loadBE(UInt32.self, at: entryOffset + 4))
            guard data.fits(blobOffset, 4) else { return nil }
            entries.append((slotType, blobOffset, data.loadBE(UInt32.self, at: blobOffset)))
        }
        return entries
    }

    static func parseCodeDirectory(in data: Data, at offset: Int, slotType: UInt32) -> CFWCodeDirectory? {
        guard data.fits(offset, codeDirectoryHeaderSize) else { return nil }
        guard data.loadBE(UInt32.self, at: offset) == codeDirectoryMagic else { return nil }

        let length = Int(data.loadBE(UInt32.self, at: offset + 4))
        let hashOffset = Int(data.loadBE(UInt32.self, at: offset + 16))
        let codeSlotCount = Int(data.loadBE(UInt32.self, at: offset + 28))
        // `codeLimit` is the 32-bit field. Binaries over 4 GiB carry the real
        // value in `codeLimit64` (version >= 0x20400) — the Python ignores that
        // too, and nothing in this pipeline is that large.
        let codeLimit = Int(data.loadBE(UInt32.self, at: offset + 32))
        let hashSize = Int(data[offset + 36])
        let hashType = data[offset + 37]
        let pageSizeLog2 = data[offset + 39]

        guard pageSizeLog2 > 0, pageSizeLog2 < 24 else { return nil }
        let pageSize = 1 << Int(pageSizeLog2)

        guard data.fits(offset, length) else { return nil }
        guard data.fits(offset + hashOffset, codeSlotCount * hashSize) else { return nil }

        return CFWCodeDirectory(
            slotType: slotType,
            offset: offset,
            length: length,
            hashOffset: hashOffset,
            hashSize: hashSize,
            hashType: hashType,
            pageSize: pageSize,
            pageSizeLog2: pageSizeLog2,
            codeSlotCount: codeSlotCount,
            codeLimit: codeLimit
        )
    }

    /// `(pageIndex, start, end)` of the slot covering `fileOffset`, or nil when
    /// the offset is past `codeLimit` and therefore covered by no slot.
    public static func pageBounds(
        fileOffset: Int,
        pageSize: Int,
        codeLimit: Int
    ) -> (index: Int, start: Int, end: Int)? {
        guard fileOffset >= 0, fileOffset < codeLimit, pageSize > 0 else { return nil }
        let index = fileOffset / pageSize
        let start = index * pageSize
        return (index, start, Swift.min(start + pageSize, codeLimit))
    }

    // MARK: Entry Points

    /// Code directories this module refuses to recompute, for the caller to warn
    /// about. A legacy SHA-1 alt-CD lands here: it is left byte-for-byte alone,
    /// so a consumer that trusts it will reject the patched binary.
    public static func unsupportedCodeDirectories(in data: Data) -> [CFWCodeDirectory] {
        (codeDirectories(in: data) ?? []).filter { $0.hashType != hashTypeSHA256 }
    }

    /// Recompute the slot hash of every page touched by `modifiedOffsets`.
    ///
    /// Only code directories with `hashType == SHA-256` are updated — see
    /// `unsupportedCodeDirectories(in:)` for what that leaves behind.
    ///
    /// Throws `PatcherError.invalidFormat` when the binary carries no usable
    /// signature — for every caller that is a hard error, because the binary was
    /// not the shape we were told it was.
    @discardableResult
    public static func reattest(
        _ data: inout Data,
        modifiedOffsets: some Sequence<Int>,
        dryRun: Bool = false
    ) throws -> [CFWSlotRehash] {
        let offsets = Array(modifiedOffsets)
        if offsets.isEmpty { return [] }

        if data.startIndex != 0 { data = Data(data) }

        guard let directories = codeDirectories(in: data) else {
            throw PatcherError.invalidFormat("no LC_CODE_SIGNATURE / CS_CodeDirectory found")
        }
        guard !directories.isEmpty else {
            throw PatcherError.invalidFormat("LC_CODE_SIGNATURE present but no CodeDirectory blobs")
        }

        // (cdIndex, pageIndex) -> byte range. Different CDs may in principle use
        // different page sizes, so the work is kept per-CD rather than merged.
        var work: [SlotKey: Range<Int>] = [:]
        for (cdIndex, directory) in directories.enumerated() {
            guard directory.hashType == hashTypeSHA256 else { continue }
            guard directory.hashSize == SHA256.byteCount else {
                throw PatcherError.invalidFormat(
                    "SHA-256 CodeDirectory at 0x\(String(directory.offset, radix: 16)) "
                        + "declares hashSize \(directory.hashSize), expected \(SHA256.byteCount)"
                )
            }
            for fileOffset in offsets {
                guard let bounds = pageBounds(
                    fileOffset: fileOffset,
                    pageSize: directory.pageSize,
                    codeLimit: directory.codeLimit
                ) else { continue }
                guard bounds.index < directory.codeSlotCount else { continue }
                work[SlotKey(cdIndex: cdIndex, pageIndex: bounds.index)] = bounds.start ..< bounds.end
            }
        }

        var records: [CFWSlotRehash] = []
        for (key, range) in work.sorted(by: { $0.key < $1.key }) {
            let directory = directories[key.cdIndex]
            let slotOffset = directory.slotHashOffset(key.pageIndex)
            guard data.fits(slotOffset, directory.hashSize), data.fits(range.lowerBound, range.count) else {
                throw PatcherError.invalidFormat("code directory slot \(key.pageIndex) falls outside the file")
            }

            let newHash = Data(SHA256.hash(data: data[range]))
            let oldHash = data[slotOffset ..< slotOffset + directory.hashSize]
            if oldHash == newHash { continue }

            if !dryRun {
                data.replaceSubrange(slotOffset ..< slotOffset + directory.hashSize, with: newHash)
            }
            records.append(CFWSlotRehash(
                codeDirectoryOffset: directory.offset,
                slotType: directory.slotType,
                pageIndex: key.pageIndex,
                pageStart: range.lowerBound,
                pageEnd: range.upperBound,
                hashFileOffset: slotOffset,
                before: Data(oldHash),
                after: newHash,
                pageSize: directory.pageSize
            ))
        }
        return records
    }

    /// File-backed form of `reattest(_:modifiedOffsets:)`.
    @discardableResult
    public static func reattest(
        fileAt url: URL,
        modifiedOffsets: some Sequence<Int>,
        dryRun: Bool = false
    ) throws -> [CFWSlotRehash] {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw PatcherError.fileNotFound(url.path)
        }
        var data = try Data(contentsOf: url)
        let records = try reattest(&data, modifiedOffsets: modifiedOffsets, dryRun: dryRun)
        if !dryRun, !records.isEmpty {
            try data.write(to: url)
        }
        return records
    }

    // MARK: Helpers

    struct SlotKey: Hashable, Comparable {
        let cdIndex: Int
        let pageIndex: Int

        static func < (lhs: Self, rhs: Self) -> Bool {
            (lhs.cdIndex, lhs.pageIndex) < (rhs.cdIndex, rhs.pageIndex)
        }
    }

    /// Zero-base a `Data` so the integer subscripts used throughout are valid.
    static func rebased(_ data: Data) -> Data {
        data.startIndex == 0 ? data : Data(data)
    }
}

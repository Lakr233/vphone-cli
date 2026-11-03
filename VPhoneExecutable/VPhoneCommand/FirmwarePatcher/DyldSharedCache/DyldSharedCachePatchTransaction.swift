// Small, verified transactions for multi-site shared-cache patches.
// Snapshot code and its CodeDirectory slots before any write; preserve
// pre-write recovery records when even rollback cannot complete.

import Foundation
import VPhonePatchKit

/// A failed write whose original bytes could not all be restored. The caller
/// must retain the recovery records even though the patch did not succeed.
public struct DyldSharedCachePatchRollbackError: LocalizedError {
    public let label: String
    public let operationError: String
    public let rollbackErrors: [String]
    public let recoveryUndo: DyldSharedCacheUndoLog

    public var errorDescription: String? {
        "\(label) failed: \(operationError). Rollback failed: "
            + rollbackErrors.joined(separator: "; ")
            + ". The cache may be partially modified; retain the undo log for recovery."
    }
}

enum DyldSharedCachePatchTransaction {
    static func headerPadding(in header: Data, at address: UInt64, minimumSize: Int, label: String) throws -> Range<UInt64> {
        guard minimumSize > 0, header.count >= 32, header.loadLE(UInt32.self, at: 0) == 0xFEED_FACF,
              Int(header.loadLE(UInt32.self, at: 20)) + 32 == header.count,
              let text = MachOParser.parseSegments(from: header).first(where: { $0.name == "__TEXT" }),
              text.vmAddr == address,
              let first = MachOParser.parseSections(from: header).values
                  .filter({ $0.segmentName == "__TEXT" && $0.size > 0 }).map(\.address).min()
        else { throw PatcherError.invalidFormat("\(label) has no bounded __TEXT header padding") }
        // Header padding is never a string, unwind record or another section.
        // The actual DSC mapping must also permit instruction fetches.
        let start = (address + UInt64(header.count) + 3) & ~UInt64(3)
        guard first >= start, first - start >= minimumSize,
              first <= text.vmAddr + text.vmSize
        else { throw PatcherError.patchSiteNotFound("\(label) has insufficient __TEXT header padding") }
        return start ..< first
    }

    // MARK: - Transactional writes

    struct Snapshot {
        let url: URL
        let offset: Int
        let original: Data
        /// Hash slots have no executable VMA and do not belong in the normal
        /// undo log: a later user-requested revert recomputes shared-page hashes.
        let vma: UInt64?

        var label: String { "\(url.lastPathComponent)@0x\(String(offset, radix: 16))" }
    }

    static func snapshots(for spans: [DyldSharedCacheWriteSpan], in chunks: DyldSharedCacheChunkSet) throws -> [Snapshot] {
        var result: [Snapshot] = []
        var slots: Set<String> = []
        for span in spans {
            let (url, range) = try chunks.fileRange(of: span)
            result.append(try snapshot(url: url, offset: range.lowerBound, length: range.count, vma: span.vma))
            guard let directory = try DyldSharedCacheCodeSignature.readCodeDirectory(ofChunk: url) else {
                throw PatcherError.patchVerificationFailed("Shared-cache patch chunk has no supported code directory: \(url.lastPathComponent)")
            }
            let first = range.lowerBound / directory.pageSize
            let last = (range.upperBound - 1) / directory.pageSize
            for page in first ... last {
                guard page < directory.codeSlotCount,
                      (page + 1) * directory.pageSize <= directory.codeLimit
                else { throw PatcherError.patchVerificationFailed("Shared-cache patch page is outside its code directory") }
                let offset = directory.slotOffset(forPage: page)
                guard offset >= directory.blobOffset,
                      offset + directory.hashSize <= directory.blobOffset + directory.blobLength
                else { throw PatcherError.patchVerificationFailed("Shared-cache patch hash slot is outside its code directory") }
                if slots.insert("\(url.path)@\(offset)").inserted {
                    result.append(try snapshot(url: url, offset: offset, length: directory.hashSize, vma: nil))
                }
            }
        }
        return result
    }

    static func snapshot(url: URL, offset: Int, length: Int, vma: UInt64?) throws -> Snapshot {
        let data = try DyldSharedCacheChunkSet.read(url: url, offset: UInt64(offset), length: length)
        guard data.count == length else {
            throw PatcherError.patchVerificationFailed("Short read while backing up a shared-cache patch")
        }
        return Snapshot(url: url, offset: offset, original: data, vma: vma)
    }

    static func restore(_ snapshot: Snapshot) throws {
        let handle = try FileHandle(forUpdating: snapshot.url)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(snapshot.offset))
        try handle.write(contentsOf: snapshot.original)
    }

    /// File-backed rollback, with a narrow restore injection for failure tests.
    /// Every range was captured before entering `operation`, so even a partial
    /// write which throws before being recorded can be restored. Attempt all
    /// restores and independently read every range back before claiming success.
    static func run<T>(
        snapshots: [Snapshot],
        label: String,
        log: ((String) -> Void)? = nil,
        restoring: ((Snapshot) throws -> Void)? = nil,
        operation: () throws -> T,
    ) throws -> T {
        do {
            return try operation()
        } catch {
            let operationError = error
            var failures: [String] = []
            // Restore the branch before its destination, then restore hashes.
            let ordered = snapshots.filter { $0.vma != nil }.reversed()
                + snapshots.filter { $0.vma == nil }.reversed()
            for item in ordered {
                do { try (restoring ?? restore)(item) }
                catch { failures.append("\(item.label): \(error.localizedDescription)") }
            }
            var verified = true
            for item in snapshots {
                do {
                    let actual = try DyldSharedCacheChunkSet.read(url: item.url, offset: UInt64(item.offset), length: item.original.count)
                    if actual != item.original {
                        verified = false
                        failures.append("\(item.label): original bytes did not read back")
                    }
                } catch {
                    verified = false
                    failures.append("\(item.label): cannot verify rollback: \(error.localizedDescription)")
                }
            }
            if verified {
                log?("  [=] \(label) failure rolled back; original code and hash bytes verified")
                throw operationError
            }
            let undo = DyldSharedCacheUndoLog(records: snapshots.compactMap { item in
                guard let vma = item.vma else { return nil }
                return .init(patchID: "", chunk: item.url.lastPathComponent, fileOffset: item.offset, vma: vma, original: item.original)
            })
            throw DyldSharedCachePatchRollbackError(
                label: label, operationError: operationError.localizedDescription, rollbackErrors: failures, recoveryUndo: undo,
            )
        }
    }
}

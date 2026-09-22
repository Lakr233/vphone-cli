import Foundation
import Testing
@testable import VPhoneCore

/// The acceptance criterion for this port is byte equivalence with
/// `tools/apfs_snap_rename.py`, because what it edits is a filesystem the
/// guest kernel then has to mount. A "close enough" rename is a VM that does
/// not boot.
///
/// The fixtures here are synthetic APFS-shaped blocks rather than a real
/// `Disk.img`: a real image is tens of gigabytes and is not in the repo, and
/// the two properties that matter — the fletcher64 and which hits get rewritten
/// — are exercised just as well by a handful of 4 KiB blocks. The end-to-end
/// byte gate against a real image is a separate, manual step.
@Suite("APFS snapshot rename")
struct APFSSnapshotTests {
    // MARK: - Helpers

    /// A 4 KiB block carrying `payload` at `offset`, with a correct checksum.
    static func makeValidBlock(payload: [UInt8], at offset: Int, filler: UInt8 = 0x41) -> [UInt8] {
        var block = [UInt8](repeating: filler, count: VPhoneAPFSSnapshot.blockSize)
        for k in 0..<8 { block[k] = 0 }
        for (k, byte) in payload.enumerated() { block[offset + k] = byte }

        let sum = block.withUnsafeBytes { VPhoneAPFSSnapshot.checksum($0) }
        withUnsafeBytes(of: sum.littleEndian) { bytes in
            for (k, byte) in bytes.enumerated() { block[k] = byte }
        }
        return block
    }

    static func snapshotName(hash: String) -> [UInt8] {
        VPhoneAPFSSnapshot.oldPrefix + Array(hash.utf8)
    }

    static let validHash = String(repeating: "ab12cd34", count: 8)  // 64 hex chars

    static func write(_ bytes: [UInt8]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("vphone-apfs-\(UUID().uuidString).img")
        try Data(bytes).write(to: url)
        return url
    }

    // MARK: - Checksum

    @Test("fletcher64 round-trips: a block we stamp verifies")
    func checksumVerifies() {
        let block = Self.makeValidBlock(payload: Self.snapshotName(hash: Self.validHash), at: 100)
        let stored = block.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }
        let computed = block.withUnsafeBytes { VPhoneAPFSSnapshot.checksum($0) }
        #expect(stored == computed)
    }

    @Test("fletcher64 uses modulus 0xFFFFFFFF, not 2^32")
    func checksumModulus() {
        // A block of all-0xFF words is the case where the two moduli diverge:
        // with 2^32 the sums wrap to 0, with 0xFFFFFFFF they do not. Getting
        // this "right" in the arithmetic sense would make every checksum wrong.
        var block = [UInt8](repeating: 0xFF, count: VPhoneAPFSSnapshot.blockSize)
        for k in 0..<8 { block[k] = 0 }
        let sum = block.withUnsafeBytes { VPhoneAPFSSnapshot.checksum($0) }
        #expect(sum != 0)
    }

    // MARK: - Scan

    @Test("finds a snapshot record in a valid block")
    func findsRecord() throws {
        let block = Self.makeValidBlock(payload: Self.snapshotName(hash: Self.validHash), at: 100)
        let report = block.withUnsafeBytes { VPhoneAPFSSnapshot.scan($0) }

        #expect(report.recordCount == 1)
        #expect(report.blocks.count == 1)
        #expect(report.blocks[0].blockOffset == 0)
        #expect(report.blocks[0].offsetsInBlock == [100])
        #expect(report.snapshotName == "com.apple.os.update-" + Self.validHash)
    }

    @Test("ignores a hit in a block that does not checksum")
    func ignoresNonMetadataBlock() throws {
        // This is the case that matters: the same string is baked into binaries
        // sitting on the volume. Those are file data, so the block they live in
        // is not an APFS object and must never be rewritten.
        var block = Self.makeValidBlock(payload: Self.snapshotName(hash: Self.validHash), at: 100)
        block[9] ^= 0xFF  // corrupt a byte the checksum covers

        let report = block.withUnsafeBytes { VPhoneAPFSSnapshot.scan($0) }
        #expect(report.isEmpty)
    }

    @Test("ignores a prefix not followed by 64 hex characters")
    func ignoresNonHexSuffix() throws {
        let notAHash = String(repeating: "zz", count: 32)  // 64 chars, not hex
        let block = Self.makeValidBlock(payload: Self.snapshotName(hash: notAHash), at: 100)
        let report = block.withUnsafeBytes { VPhoneAPFSSnapshot.scan($0) }
        #expect(report.isEmpty)
    }

    @Test("finds both records when they share one block")
    func findsTwoRecordsInOneBlock() throws {
        // The real layout: snap_metadata value and snap_name key, normally in
        // the same leaf node.
        var block = [UInt8](repeating: 0x41, count: VPhoneAPFSSnapshot.blockSize)
        for k in 0..<8 { block[k] = 0 }
        let name = Self.snapshotName(hash: Self.validHash)
        for (k, byte) in name.enumerated() { block[200 + k] = byte }
        for (k, byte) in name.enumerated() { block[1200 + k] = byte }
        let sum = block.withUnsafeBytes { VPhoneAPFSSnapshot.checksum($0) }
        withUnsafeBytes(of: sum.littleEndian) { bytes in
            for (k, byte) in bytes.enumerated() { block[k] = byte }
        }

        let report = block.withUnsafeBytes { VPhoneAPFSSnapshot.scan($0) }
        #expect(report.recordCount == 2)
        #expect(report.blocks.count == 1)
        #expect(report.blocks[0].offsetsInBlock == [200, 1200])
    }

    @Test("reports blocks in ascending order")
    func blocksAreOrdered() throws {
        let name = Self.snapshotName(hash: Self.validHash)
        let first = Self.makeValidBlock(payload: name, at: 100)
        let second = Self.makeValidBlock(payload: name, at: 300, filler: 0x42)
        let report = (first + second).withUnsafeBytes { VPhoneAPFSSnapshot.scan($0) }

        #expect(report.blocks.map(\.blockOffset) == [0, VPhoneAPFSSnapshot.blockSize])
    }

    // MARK: - Rename

    @Test("renames every record and leaves the block verifying")
    func renameKeepsBlockValid() throws {
        let name = Self.snapshotName(hash: Self.validHash)
        let url = try Self.write(Self.makeValidBlock(payload: name, at: 100))
        defer { try? FileManager.default.removeItem(at: url) }

        try VPhoneAPFSSnapshot.rename(imageAt: url, log: { _ in })

        let after = try [UInt8](Data(contentsOf: url))
        let renamed = String(decoding: after[100..<120], as: UTF8.self)
        #expect(renamed == VPhoneAPFSSnapshot.defaultNewPrefix)

        // The point of fixing the checksum: the block still reads as an APFS
        // object afterwards, or the volume is corrupt.
        let stored = after.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }
        let computed = after.withUnsafeBytes { VPhoneAPFSSnapshot.checksum($0) }
        #expect(stored == computed)
    }

    @Test("rename is idempotent: a second pass finds nothing")
    func renameIsIdempotent() throws {
        let name = Self.snapshotName(hash: Self.validHash)
        let url = try Self.write(Self.makeValidBlock(payload: name, at: 100))
        defer { try? FileManager.default.removeItem(at: url) }

        try VPhoneAPFSSnapshot.rename(imageAt: url, log: { _ in })
        let second = try VPhoneAPFSSnapshot.rename(imageAt: url, log: { _ in })
        #expect(second.isEmpty)
    }

    @Test("dry run changes nothing")
    func dryRunIsReadOnly() throws {
        let name = Self.snapshotName(hash: Self.validHash)
        let original = Self.makeValidBlock(payload: name, at: 100)
        let url = try Self.write(original)
        defer { try? FileManager.default.removeItem(at: url) }

        let report = try VPhoneAPFSSnapshot.rename(imageAt: url, dryRun: true, log: { _ in })
        #expect(report.recordCount == 1)
        #expect(try [UInt8](Data(contentsOf: url)) == original)
    }

    @Test("a differently sized prefix is refused")
    func rejectsWrongLengthPrefix() throws {
        let name = Self.snapshotName(hash: Self.validHash)
        let url = try Self.write(Self.makeValidBlock(payload: name, at: 100))
        defer { try? FileManager.default.removeItem(at: url) }

        // Same length is load-bearing, not cosmetic: a different length would
        // move every following byte in the b-tree node and invalidate name_len.
        #expect(throws: VPhoneAPFSSnapshotError.self) {
            try VPhoneAPFSSnapshot.rename(imageAt: url, newPrefix: "too-short-", log: { _ in })
        }
    }

    @Test("log lines match the Python the port replaces")
    func logLinesAreUnchanged() throws {
        let name = Self.snapshotName(hash: Self.validHash)
        let url = try Self.write(Self.makeValidBlock(payload: name, at: 100))
        defer { try? FileManager.default.removeItem(at: url) }

        var lines: [String] = []
        try VPhoneAPFSSnapshot.rename(imageAt: url, dryRun: true, log: { lines.append($0) })

        #expect(lines == [
            "Detected snapshot: com.apple.os.update-\(Self.validHash)",
            "Records: 1 in 1 block(s): ['0x0']",
            "Dry run: the prefix would be renamed to orig-fs.disabled.rn-.",
        ])
    }

    @Test("says so when there is nothing to rename")
    func reportsNothingFound() throws {
        let url = try Self.write([UInt8](repeating: 0x41, count: VPhoneAPFSSnapshot.blockSize))
        defer { try? FileManager.default.removeItem(at: url) }

        var lines: [String] = []
        let report = try VPhoneAPFSSnapshot.rename(imageAt: url, log: { lines.append($0) })
        #expect(report.isEmpty)
        #expect(lines == [
            "No com.apple.os.update-* root snapshot found. The snapshot may already be renamed.",
        ])
    }
}

import Foundation

// MARK: - VPhoneAPFSSnapshotError

public enum VPhoneAPFSSnapshotError: Error, CustomStringConvertible {
    case prefixLengthMismatch(given: Int, required: Int)
    case cannotOpen(URL, errno: Int32)
    case cannotMap(URL, errno: Int32)
    case cannotAccess(URL, operation: String, errno: Int32)

    public var description: String {
        switch self {
        case let .prefixLengthMismatch(given, required):
            "--new-prefix must be exactly \(required) bytes (got \(given))"
        case let .cannotOpen(url, err):
            "Could not open \(url.path): \(String(cString: strerror(err)))"
        case let .cannotMap(url, err):
            "Could not map \(url.path): \(String(cString: strerror(err)))"
        case let .cannotAccess(url, operation, err):
            "Could not \(operation) \(url.path): \(String(cString: strerror(err)))"
        }
    }
}

// MARK: - VPhoneAPFSSnapshot

/// Offline APFS root-snapshot rename for a vphone `Disk.img` (CFW boot-source flip).
///
/// Renames the `com.apple.os.update-<hash>` system snapshot in place so the
/// (seal-enforcement-patched) guest kernel cannot find the named root snapshot
/// and roots the live volume instead — the same effect as `snaputil` inside the
/// VM, done offline on the host: no mount, no `fs_snapshot` syscall, no kernel
/// CSR gate, no host security change.
///
/// The name is stored in exactly two b-tree records (the `snap_metadata` value
/// and the `snap_name` key), normally in one leaf node. A same-length rename
/// keeps `name_len` and the single-snapshot b-tree order intact, so only the
/// touched blocks' fletcher64 changes — which is why the new prefix is required
/// to be the same length rather than merely recommended to be.
///
/// Swift port of `tools/apfs_snap_rename.py`. Byte-for-byte equivalence is the
/// acceptance criterion: the same image through either version must produce the
/// same SHA-256.
public enum VPhoneAPFSSnapshot {
    public static let blockSize = 4096
    public static let oldPrefix = Array("com.apple.os.update-".utf8) // 20 bytes
    public static let defaultNewPrefix = "orig-fs.disabled.rn-"

    /// One `com.apple.os.update-*` record, and where it lives.
    public struct Record: Equatable, Sendable {
        /// Offset of the containing 4 KiB block within the image.
        public let blockOffset: Int
        /// Offset of the record within that block.
        public let offsetInBlock: Int
    }

    public struct Report: Sendable {
        /// The full snapshot name, prefix plus the 64 hex characters.
        public let snapshotName: String?
        /// Records grouped by block, in ascending block order.
        public let blocks: [(blockOffset: Int, offsetsInBlock: [Int])]

        public var recordCount: Int {
            blocks.reduce(0) { $0 + $1.offsetsInBlock.count }
        }

        public var isEmpty: Bool {
            blocks.isEmpty
        }
    }

    // MARK: - Checksum

    /// APFS's fletcher64 over a 4 KiB object block, excluding the 8-byte
    /// checksum field at its head.
    ///
    /// The modulus is 0xFFFFFFFF rather than 2^32; that is what APFS does, and
    /// getting it "right" would make every checksum wrong.
    public static func checksum(_ block: UnsafeRawBufferPointer) -> UInt64 {
        precondition(block.count == blockSize)
        var s1: UInt64 = 0
        var s2: UInt64 = 0
        let modulus: UInt64 = 0xFFFF_FFFF

        var offset = 8
        while offset < blockSize {
            let word = UInt64(block.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
            s1 = (s1 + word) % modulus
            s2 = (s2 + s1) % modulus
            offset += 4
        }

        let c1 = modulus - ((s1 + s2) % modulus)
        let c2 = modulus - ((s1 + c1) % modulus)
        return c1 | (c2 << 32)
    }

    private static func blockIsValid(_ block: UnsafeRawBufferPointer) -> Bool {
        let stored = block.loadUnaligned(fromByteOffset: 0, as: UInt64.self)
        return checksum(block) == stored
    }

    private static func isHexDigit(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "0") ... UInt8(ascii: "9"),
             UInt8(ascii: "a") ... UInt8(ascii: "f"),
             UInt8(ascii: "A") ... UInt8(ascii: "F"):
            true
        default:
            false
        }
    }

    // MARK: - Scan

    /// Find every snapshot-name record in the image.
    ///
    /// A hit has to be `com.apple.os.update-` followed by 64 hex characters AND
    /// sit inside a block whose fletcher64 verifies. The second condition is
    /// what keeps identical strings baked into on-volume binaries from being
    /// rewritten: they are file data, not metadata objects, so the block they
    /// live in does not checksum as one.
    public static func scan(_ image: UnsafeRawBufferPointer) -> Report {
        var order: [Int] = []
        var byBlock: [Int: [Int]] = [:]
        var name: String?

        let hashLength = 64
        let needLength = oldPrefix.count + hashLength
        guard image.count >= needLength else { return Report(snapshotName: nil, blocks: []) }

        // memmem, not a hand-rolled scan: these images run to tens of
        // gigabytes, and the Python this replaces got its speed from mmap.find
        // being memchr-driven. A byte-at-a-time loop here would turn a few
        // seconds into minutes.
        guard let imageBase = image.baseAddress else {
            return Report(snapshotName: nil, blocks: [])
        }

        var i = 0
        while i <= image.count - needLength {
            let found = oldPrefix.withUnsafeBytes { needle in
                memmem(imageBase + i, image.count - i, needle.baseAddress!, oldPrefix.count)
            }
            guard let found else { break }
            i = UnsafeRawPointer(found) - imageBase

            // A hit this close to the end cannot carry the 64-character hash.
            guard i <= image.count - needLength else { break }

            let hashStart = i + oldPrefix.count
            var allHex = true
            for k in 0 ..< hashLength {
                if !isHexDigit(image[hashStart + k]) {
                    allHex = false; break
                }
            }
            guard allHex else { i += 1; continue }

            let blockOffset = (i / blockSize) * blockSize
            guard blockOffset + blockSize <= image.count else { i += 1; continue }
            let block = UnsafeRawBufferPointer(rebasing: image[blockOffset ..< blockOffset + blockSize])
            guard blockIsValid(block) else { i += 1; continue }

            if name == nil {
                let bytes = (0 ..< needLength).map { image[i + $0] }
                name = String(decoding: bytes, as: UTF8.self)
            }
            if byBlock[blockOffset] == nil {
                order.append(blockOffset)
            }
            byBlock[blockOffset, default: []].append(i - blockOffset)
            i += 1
        }

        return Report(
            snapshotName: name,
            blocks: order.sorted().map { ($0, byBlock[$0]!) },
        )
    }

    // MARK: - Rename

    /// Rewrite the prefix of every record found, and fix each touched block's
    /// checksum.
    ///
    /// Returns the blocks it changed, in ascending order, so the caller can
    /// report them.
    @discardableResult
    public static func rename(
        imageAt url: URL,
        newPrefix: String = defaultNewPrefix,
        dryRun: Bool = false,
        log: (String) -> Void = { print($0) },
    ) throws -> Report {
        let newPrefixBytes = Array(newPrefix.utf8)
        guard newPrefixBytes.count == oldPrefix.count else {
            throw VPhoneAPFSSnapshotError.prefixLengthMismatch(
                given: newPrefixBytes.count, required: oldPrefix.count,
            )
        }

        let fd = open(url.path, dryRun ? O_RDONLY : O_RDWR)
        guard fd >= 0 else { throw VPhoneAPFSSnapshotError.cannotOpen(url, errno: errno) }
        defer { close(fd) }

        var stats = stat()
        guard fstat(fd, &stats) == 0 else {
            throw VPhoneAPFSSnapshotError.cannotOpen(url, errno: errno)
        }
        let length = Int(stats.st_size)

        // A Disk.img is commonly 64 GiB. Mapping and touching all of it at
        // once can fill host RAM, even though the file is sparse. Each window
        // starts on a page and APFS block boundary, so scan() still sees each
        // complete metadata block and returns the same records.
        let windowSize = 64 * 1024 * 1024
        var blocks: [(blockOffset: Int, offsetsInBlock: [Int])] = []
        var snapshotName: String?
        for offset in stride(from: 0, to: length, by: windowSize) {
            let count = min(windowSize, length - offset)
            guard let base = mmap(nil, count, PROT_READ, MAP_PRIVATE, fd, off_t(offset)),
                  base != MAP_FAILED
            else {
                throw VPhoneAPFSSnapshotError.cannotMap(url, errno: errno)
            }
            let part = scan(UnsafeRawBufferPointer(start: base, count: count))
            if snapshotName == nil {
                snapshotName = part.snapshotName
            }
            blocks.append(contentsOf: part.blocks.map {
                (blockOffset: offset + $0.blockOffset, offsetsInBlock: $0.offsetsInBlock)
            })
            _ = munmap(base, count)
        }
        let report = Report(snapshotName: snapshotName, blocks: blocks)

        guard !report.isEmpty else {
            log("No com.apple.os.update-* root snapshot found. The snapshot may already be renamed.")
            return report
        }

        log("Detected snapshot: \(report.snapshotName ?? "?")")
        let blockList = report.blocks.map { "'0x\(String($0.blockOffset, radix: 16))'" }
            .joined(separator: ", ")
        log("Records: \(report.recordCount) in \(report.blocks.count) block(s): [\(blockList)]")

        if dryRun {
            log("Dry run: the prefix would be renamed to \(newPrefix).")
            return report
        }

        for (blockOffset, offsets) in report.blocks {
            var block = Data(count: blockSize)
            let readCount = block.withUnsafeMutableBytes {
                pread(fd, $0.baseAddress, blockSize, off_t(blockOffset))
            }
            guard readCount == blockSize else {
                throw VPhoneAPFSSnapshotError.cannotAccess(url, operation: "read", errno: errno)
            }
            block.withUnsafeMutableBytes { raw in
                for within in offsets {
                    for (k, byte) in newPrefixBytes.enumerated() {
                        raw[within + k] = byte
                    }
                }
                let sum = checksum(UnsafeRawBufferPointer(raw))
                var littleEndian = sum.littleEndian
                withUnsafeBytes(of: &littleEndian) { bytes in
                    for (k, byte) in bytes.enumerated() {
                        raw[k] = byte
                    }
                }
            }
            let written = block.withUnsafeBytes {
                pwrite(fd, $0.baseAddress, blockSize, off_t(blockOffset))
            }
            guard written == blockSize else {
                throw VPhoneAPFSSnapshotError.cannotAccess(url, operation: "write", errno: errno)
            }
            log("Block 0x\(String(blockOffset, radix: 16)): renamed \(offsets.count) record(s) and fixed the checksum.")
        }

        guard fsync(fd) == 0 else {
            throw VPhoneAPFSSnapshotError.cannotAccess(url, operation: "sync", errno: errno)
        }
        log("Done. Root snapshot renamed to \(newPrefix)*. The VM will boot the live volume.")
        return report
    }
}

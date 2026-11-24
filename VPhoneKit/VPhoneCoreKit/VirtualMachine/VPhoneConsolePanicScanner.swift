import Darwin
import Foundation

// MARK: - VPhoneConsolePanicScanner

/// Watches a console log for a guest kernel panic. Each `hasPanic()` reads the
/// bytes written since the last call, so a long log is read once, and a line
/// split across two reads is matched once it is complete. A log that was
/// replaced, or truncated and written again since the last call, is read from
/// the start.
public struct VPhoneConsolePanicScanner {
    private static let maximumPartialLine = 4096
    private static let readSize = 64 * 1024
    private static let anchorSize = 64

    private struct FileID: Equatable {
        let device: dev_t
        let inode: ino_t
    }

    private let url: URL
    private var offset: UInt64 = 0
    private var partial = Data()
    private var fileID: FileID?
    /// The last bytes read before `offset`; they must still be there next time.
    private var anchor = Data()

    public init(url: URL) {
        self.url = url
    }

    /// True when a complete line read by this call holds a panic. A panic
    /// read by an earlier call is not reported again.
    public mutating func hasPanic() -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        var info = stat()
        guard fstat(handle.fileDescriptor, &info) == 0 else { return false }
        let id = FileID(device: info.st_dev, inode: info.st_ino)
        if id != fileID || !anchorIntact(handle) {
            offset = 0
            partial = Data()
            anchor = Data()
            fileID = id
        }
        guard (try? handle.seek(toOffset: offset)) != nil else { return false }

        var panicked = false
        while let chunk = try? handle.read(upToCount: Self.readSize), !chunk.isEmpty {
            offset += UInt64(chunk.count)
            anchor = Data((anchor + chunk).suffix(Self.anchorSize))
            var lines = (partial + chunk).split(separator: 0x0A, omittingEmptySubsequences: false)
            partial = Data(lines.removeLast().suffix(Self.maximumPartialLine))
            panicked = panicked || lines.contains {
                String(decoding: $0, as: UTF8.self).range(of: "(?i:\(VPhoneBootPatterns.panicRegex))", options: .regularExpression) != nil
            }
        }
        return panicked
    }

    /// True when the bytes just before `offset` are still the ones last read.
    private func anchorIntact(_ handle: FileHandle) -> Bool {
        guard !anchor.isEmpty else { return true }
        guard (try? handle.seek(toOffset: offset - UInt64(anchor.count))) != nil else { return false }
        return (try? handle.read(upToCount: anchor.count)) == anchor
    }
}

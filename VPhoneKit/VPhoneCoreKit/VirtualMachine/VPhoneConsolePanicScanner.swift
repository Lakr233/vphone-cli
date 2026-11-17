import Foundation

// MARK: - VPhoneConsolePanicScanner

/// Watches a console log for a guest kernel panic. Each `hasPanic()` reads the
/// bytes written since the last call, so a long log is read once, and a line
/// split across two reads is matched once it is complete.
public struct VPhoneConsolePanicScanner {
    private static let maximumPartialLine = 4096
    private static let readSize = 64 * 1024

    private let url: URL
    private var offset: UInt64 = 0
    private var partial = Data()

    public init(url: URL) {
        self.url = url
    }

    /// True when a complete line read by this call holds a panic. A panic
    /// read by an earlier call is not reported again.
    public mutating func hasPanic() -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        // A log truncated by a new launch starts over.
        if let size = try? handle.seekToEnd(), size < offset {
            offset = 0
            partial = Data()
        }
        guard (try? handle.seek(toOffset: offset)) != nil else { return false }

        var panicked = false
        while let chunk = try? handle.read(upToCount: Self.readSize), !chunk.isEmpty {
            offset += UInt64(chunk.count)
            var lines = (partial + chunk).split(separator: 0x0A, omittingEmptySubsequences: false)
            partial = Data(lines.removeLast().suffix(Self.maximumPartialLine))
            panicked = panicked || lines.contains {
                String(decoding: $0, as: UTF8.self).range(of: "(?i:\(VPhoneBootPatterns.panicRegex))", options: .regularExpression) != nil
            }
        }
        return panicked
    }
}

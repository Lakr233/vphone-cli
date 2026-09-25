import Foundation

/// Splits a child's output into display lines. `vphone-cli` redraws progress
/// with carriage returns and colours some output, so both `\r` and `\n` end a
/// line, ANSI escape sequences are dropped, and blank lines are skipped.
nonisolated struct VPhoneLaunchpadLineSplitter {
    private var buffer = Data()

    mutating func feed(_ data: Data, _ onLine: (String) -> Void) {
        buffer.append(data)
        while let end = buffer.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
            Self.emit(buffer[buffer.startIndex ..< end], onLine)
            buffer.removeSubrange(buffer.startIndex ... end)
        }
    }

    mutating func flush(_ onLine: (String) -> Void) {
        Self.emit(buffer, onLine)
        buffer.removeAll()
    }

    private static func emit(_ bytes: Data, _ onLine: (String) -> Void) {
        let text = String(decoding: bytes, as: UTF8.self)
            .replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[ -/]*[@-~]", with: "", options: .regularExpression)
        if !text.trimmingCharacters(in: .whitespaces).isEmpty {
            onLine(text)
        }
    }
}

nonisolated enum VPhoneLaunchpadLineReader {
    /// Reads `handle` until end of file on the calling thread.
    static func readLines(from handle: FileHandle, onLine: (String) -> Void) {
        var splitter = VPhoneLaunchpadLineSplitter()
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty {
                break
            }
            splitter.feed(chunk, onLine)
        }
        splitter.flush(onLine)
    }
}

import Foundation
import Testing
@testable import VPhoneCoreKit

/// Finding a guest panic in a console log that grows between reads.
struct ConsolePanicScannerTests {
    private func logFile() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        return url
    }

    private func append(_ text: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }

    @Test func `a panic line split across two reads is found once complete`() throws {
        let url = logFile()
        defer { try? FileManager.default.removeItem(at: url) }
        var scanner = VPhoneConsolePanicScanner(url: url)
        try append("booting\nkernel pa", to: url)
        let seen1 = scanner.hasPanic()
        #expect(!seen1)
        try append("nic: bad thing\n", to: url)
        let seen2 = scanner.hasPanic()
        #expect(seen2)
    }

    @Test func `ordinary serial lines are not a panic`() throws {
        let url = logFile()
        defer { try? FileManager.default.removeItem(at: url) }
        var scanner = VPhoneConsolePanicScanner(url: url)
        try append("AppleARMPE: boot\nvphoned: connected\nlaunchd: ready\n", to: url)
        let seen1 = scanner.hasPanic()
        #expect(!seen1)
    }

    @Test func `a missing file is not a panic`() {
        var scanner = VPhoneConsolePanicScanner(url: URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString).log"))
        let seen1 = scanner.hasPanic()
        #expect(!seen1)
    }

    @Test func `a panic that was already read is not reported again`() throws {
        let url = logFile()
        defer { try? FileManager.default.removeItem(at: url) }
        var scanner = VPhoneConsolePanicScanner(url: url)
        try append("panic: first\n", to: url)
        let seen1 = scanner.hasPanic()
        #expect(seen1)
        let seen2 = scanner.hasPanic()
        #expect(!seen2)
        try append("ordinary\n", to: url)
        let seen3 = scanner.hasPanic()
        #expect(!seen3)
    }

    @Test func `a 10 MiB log without a newline is not a panic and a later panic is still found`() throws {
        let url = logFile()
        defer { try? FileManager.default.removeItem(at: url) }
        var scanner = VPhoneConsolePanicScanner(url: url)
        try append(String(repeating: "x", count: 10 << 20), to: url)
        let seen1 = scanner.hasPanic()
        #expect(!seen1)
        try append("\nkernel panic\n", to: url)
        let seen2 = scanner.hasPanic()
        #expect(seen2)
    }

    @Test func `a panic after the log shrinks is found`() throws {
        let url = logFile()
        defer { try? FileManager.default.removeItem(at: url) }
        var scanner = VPhoneConsolePanicScanner(url: url)
        try append("panic: first\n", to: url)
        let seen1 = scanner.hasPanic()
        #expect(seen1)
        try FileHandle(forWritingTo: url).truncate(atOffset: 0)
        try append("ordinary\n", to: url)
        let seen2 = scanner.hasPanic()
        #expect(!seen2)
        try append("panic: second\n", to: url)
        let seen3 = scanner.hasPanic()
        #expect(seen3)
    }

    @Test func `a log truncated and regrown past the old offset is read again`() throws {
        let url = logFile()
        defer { try? FileManager.default.removeItem(at: url) }
        var scanner = VPhoneConsolePanicScanner(url: url)
        try append("ordinary line one\n", to: url)
        let seen1 = scanner.hasPanic()
        #expect(!seen1)
        // Same inode, different content, longer than before the next poll.
        try FileHandle(forWritingTo: url).truncate(atOffset: 0)
        try append("a fresh boot begins here, longer\npanic: after the rewrite\n", to: url)
        let seen2 = scanner.hasPanic()
        #expect(seen2)
    }

    @Test func `a replaced log is read from the start`() throws {
        let url = logFile()
        defer { try? FileManager.default.removeItem(at: url) }
        var scanner = VPhoneConsolePanicScanner(url: url)
        try append("ordinary line one\nordinary line two\n", to: url)
        let seen1 = scanner.hasPanic()
        #expect(!seen1)
        try FileManager.default.removeItem(at: url)
        try Data("ordinary line one\nordinary line two\npanic: new file\n".utf8).write(to: url)
        let seen2 = scanner.hasPanic()
        #expect(seen2)
    }
}

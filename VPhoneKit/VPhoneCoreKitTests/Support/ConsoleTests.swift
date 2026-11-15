import Foundation
import Testing
@testable import VPhoneCoreKit

struct ConsoleTests {
    final class Sink: @unchecked Sendable {
        private let lock = NSLock(); private var out = "", err = ""
        func write(_ s: String, _ stream: VPhoneConsoleStream) { lock.withLock { if stream == .output { out += s } else { err += s } } }
        var output: String { lock.withLock { out } }
        var error: String { lock.withLock { err } }
    }

    @Test func `phase prints the marker with a blank line before it`() {
        let sink = Sink(); let console = VPhoneConsole(write: sink.write)
        console.phase("fw patch")
        #expect(sink.output == "\n=== fw patch ===\n")
    }

    @Test func `a line is written verbatim whatever its kind`() {
        let sink = Sink(); let console = VPhoneConsole(write: sink.write)
        console.line("[*] Extracting cloudOS IPSW...", .step)
        console.line("  [+] Injected vphoned", .note)
        console.line("no newline", terminator: "")
        console.line("warning: x", .warning, to: .error)
        #expect(sink.output == "[*] Extracting cloudOS IPSW...\n  [+] Injected vphoned\nno newline")
        #expect(sink.error == "warning: x\n")
    }

    @Test func `activity writes nothing in plain mode`() {
        let sink = Sink(); let console = VPhoneConsole(write: sink.write)
        console.activity("upload filesystem", fraction: 0.5)
        console.activity("patch LLB", done: 1, of: 13)
        #expect(sink.output.isEmpty && sink.error.isEmpty)
    }

    @Test func `the log file receives the same bytes as both streams`() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let sink = Sink(); let console = VPhoneConsole(write: sink.write)
        try console.setLog(url)
        console.phase("vm new"); console.line("created /x"); console.line("oops", .failure, to: .error)
        try console.setLog(nil)
        #expect(try String(contentsOf: url, encoding: .utf8) == "\n=== vm new ===\ncreated /x\noops\n")
    }

    @Test func `lines from many threads all arrive whole`() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let sink = Sink(); let console = VPhoneConsole(write: sink.write)
        try console.setLog(url)
        DispatchQueue.concurrentPerform(iterations: 200) { console.line("line \($0)") }
        try console.setLog(nil)
        let lines = sink.output.split(separator: "\n")
        #expect(lines.count == 200 && Set(lines).count == 200)
        // The sink has its own lock, so the log file is what exercises the console's serialization.
        let logged = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
        #expect(logged.count == 200 && Set(logged).count == 200)
    }

    @Test func `the log file is private to its owner`() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let console = VPhoneConsole(write: { _, _ in })
        try console.setLog(url)
        try console.setLog(nil)
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
    }
}

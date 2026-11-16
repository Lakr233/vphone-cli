import Foundation
import Testing
@testable import VPhoneCommandKit

/// What `VPhoneProgressBar` writes. The bar renders to a terminal, so these
/// give it a pseudo-terminal (a real tty with output processing off) and read
/// back the bytes; the other modes use a pipe and an explicit environment.
struct ProgressBarDrawTests {
    /// A pty pair: the bar writes to `slave`, the test reads `master`.
    private final class Terminal {
        let master: Int32
        let slave: Int32
        let handle: FileHandle

        init() throws {
            var master: Int32 = -1
            var slave: Int32 = -1
            let opened = openpty(&master, &slave, nil, nil, nil)
            try #require(opened == 0)
            var attributes = termios()
            tcgetattr(slave, &attributes)
            attributes.c_oflag &= ~tcflag_t(OPOST) // no \n -> \r\n
            tcsetattr(slave, TCSANOW, &attributes)
            _ = fcntl(master, F_SETFL, fcntl(master, F_GETFL) | O_NONBLOCK)
            self.master = master
            self.slave = slave
            handle = FileHandle(fileDescriptor: slave, closeOnDealloc: false)
        }

        func drain() -> String {
            var bytes = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = read(master, &buffer, buffer.count)
                if count <= 0 { break }
                bytes.append(contentsOf: buffer[0 ..< count])
            }
            return String(decoding: bytes, as: UTF8.self)
        }

        func close() {
            Darwin.close(master)
            Darwin.close(slave)
        }
    }

    private static let clear = "\u{1B}[K"

    /// The 28-cell bar of the line `segment`.
    private func cells(_ filled: Int) -> String {
        String(repeating: "█", count: filled) + String(repeating: "░", count: 28 - filled)
    }

    @Test("at 0 percent the bar is 28 empty cells, with no rate and no eta")
    func zeroPercent() throws {
        let terminal = try Terminal()
        defer { terminal.close() }
        let bar = VPhoneProgressBar(label: "dl", output: terminal.handle, environment: [:])
        bar.update(done: 0, total: 100)
        #expect(terminal.drain() == "\rdl [\(cells(0))] 0%  0 B/100 B\(Self.clear)")
    }

    @Test("at 50 percent half the cells are full and the line carries a rate and an eta")
    func halfway() throws {
        let terminal = try Terminal()
        defer { terminal.close() }
        let bar = VPhoneProgressBar(label: "dl", output: terminal.handle, environment: [:])
        Thread.sleep(forTimeInterval: 0.02) // a measurable elapsed time, so a rate
        bar.update(done: 50, total: 100)
        let line = terminal.drain()
        let prefix = "\rdl [\(cells(14))] 50%  50 B/100 B  "
        #expect(line.hasPrefix(prefix))
        #expect(line.hasSuffix(Self.clear))
        let tail = String(line.dropFirst(prefix.count).dropLast(Self.clear.count))
        // "<n> <unit>/s  eta mm:ss".
        #expect(tail.range(of: #"^\d+(\.\d)? (B|KB|MB|GB)/s  eta \d\d:\d\d$"#, options: .regularExpression) != nil)
    }

    @Test("at 100 percent the bar is full with no eta, and finish redraws it and ends the line")
    func complete() throws {
        let terminal = try Terminal()
        defer { terminal.close() }
        let bar = VPhoneProgressBar(label: "dl", output: terminal.handle, environment: [:])
        Thread.sleep(forTimeInterval: 0.02)
        bar.update(done: 100, total: 100)
        let drawn = terminal.drain()
        let prefix = "\rdl [\(cells(28))] 100%  100 B/100 B  "
        #expect(drawn.hasPrefix(prefix))
        #expect(!drawn.contains("eta"))
        #expect(drawn.hasSuffix("/s\(Self.clear)"))
        #expect(!drawn.contains("\n"))

        bar.finish()
        let finished = terminal.drain()
        #expect(finished.hasPrefix(prefix))
        #expect(finished.hasSuffix("/s\(Self.clear)\n"))
    }

    @Test("a second update inside the redraw interval is skipped, and an unknown total draws an empty bar")
    func throttleAndUnknownTotal() throws {
        let terminal = try Terminal()
        defer { terminal.close() }
        let bar = VPhoneProgressBar(label: "dl", output: terminal.handle, environment: [:])
        bar.update(done: 0, total: 0)
        bar.update(done: 5, total: 100) // well inside 66 ms of the first
        // total 0: 0%, no "/total", and nothing for the skipped call.
        #expect(terminal.drain() == "\rdl [\(cells(0))] 0%  0 B\(Self.clear)")
    }

    @Test("finish without an update draws nothing: a download the cache already held")
    func finishWithoutUpdate() throws {
        let terminal = try Terminal()
        defer { terminal.close() }
        let bar = VPhoneProgressBar(label: "dl", output: terminal.handle, environment: [:])
        bar.finish()
        #expect(terminal.drain() == "")
    }

    @Test("with VPHONE_PROGRESS=lines and no tty it writes progress lines, at most a few a second")
    func linesMode() throws {
        let pipe = Pipe()
        let bar = VPhoneProgressBar(label: "dl", output: pipe.fileHandleForWriting, environment: ["VPHONE_PROGRESS": "lines"])
        bar.update(done: 0, total: 100)
        bar.update(done: 50, total: 100) // inside 250 ms: skipped
        bar.update(done: 100, total: 100) // the last report is never skipped
        bar.finish()
        try pipe.fileHandleForWriting.close()
        let data = try #require(try pipe.fileHandleForReading.readToEnd())
        let text = String(decoding: data, as: UTF8.self)
        #expect(text == "progress 0 100\nprogress 100 100\nprogress 100 100\n")
    }

    @Test("with no tty and no VPHONE_PROGRESS it draws nothing, including other values of the variable")
    func offMode() throws {
        for environment in [[:], ["VPHONE_PROGRESS": "bar"], ["VPHONE_PROGRESS": ""]] as [[String: String]] {
            let pipe = Pipe()
            let bar = VPhoneProgressBar(label: "dl", output: pipe.fileHandleForWriting, environment: environment)
            bar.update(done: 0, total: 100)
            bar.update(done: 100, total: 100)
            bar.finish()
            try pipe.fileHandleForWriting.close()
            let written = try pipe.fileHandleForReading.readToEnd() ?? Data()
            #expect(written.isEmpty)
        }
    }

    @Test("a tty wins over VPHONE_PROGRESS=lines")
    func ttyBeatsLines() throws {
        let terminal = try Terminal()
        defer { terminal.close() }
        let bar = VPhoneProgressBar(label: "dl", output: terminal.handle, environment: ["VPHONE_PROGRESS": "lines"])
        bar.update(done: 0, total: 100)
        #expect(terminal.drain().hasPrefix("\rdl ["))
    }
}

import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

private func withPipe(_ input: Data, eof: Bool = false, _ body: (Int32) -> Void) {
    var descriptors: [Int32] = [-1, -1]
    precondition(pipe(&descriptors) == 0)
    defer {
        close(descriptors[0])
        if descriptors[1] >= 0 { close(descriptors[1]) }
    }
    for descriptor in descriptors {
        let flags = fcntl(descriptor, F_GETFL)
        precondition(flags >= 0 && fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0)
    }
    if !input.isEmpty {
        let written = input.withUnsafeBytes { write(descriptors[1], $0.baseAddress, $0.count) }
        precondition(written == input.count, "fixture pipe could not hold its bounded input")
    }
    if eof {
        close(descriptors[1])
        descriptors[1] = -1
    }
    body(descriptors[0])
}

private func remaining(_ descriptor: Int32, maximum: Int) -> Data {
    var buffer = [UInt8](repeating: 0, count: maximum)
    let count = read(descriptor, &buffer, buffer.count)
    precondition(count >= 0)
    return Data(buffer.prefix(count))
}

@main
private enum ProcessOutputTests {
    static func main() {
        stopsWhilePipeIsStillReadable()
        capsTheLastReadToRemainingSpace()
        handlesShortEOF()
        leavesInputWhenBudgetIsExhausted()
        returnsWhenNoOutputIsAvailable()
        fileDrainStopsAtCeilingWithoutBlockingWriter()
        fileDrainCapturesEverythingUnderCeiling()
        fileDrainFailsPromptlyOnWriteError()
        print("process output capture: byte budget, remaining space, EOF, nonblocking reads and file drain passed")
    }

    private static func stopsWhilePipeIsStillReadable() {
        let input = Data((0..<1024).map { UInt8($0 % 251) })
        withPipe(input) { descriptor in
            var output = Data()
            GuestProcessOutput.drain(descriptor, into: &output, limit: 257)
            precondition(output == input.prefix(257), "continuously readable input exceeded its budget")
            precondition(remaining(descriptor, maximum: input.count) == input.dropFirst(257), "capture consumed output beyond its budget")
        }
    }

    private static func capsTheLastReadToRemainingSpace() {
        let input = Data((0..<6000).map { UInt8($0 % 251) })
        let prefix = Data("prefix".utf8)
        withPipe(input) { descriptor in
            var output = prefix
            GuestProcessOutput.drain(descriptor, into: &output, limit: 5003)
            let consumed = 5003 - prefix.count
            precondition(output == prefix + input.prefix(consumed), "the final read exceeded the remaining space")
            precondition(remaining(descriptor, maximum: input.count) == input.dropFirst(consumed))
        }
    }

    private static func handlesShortEOF() {
        let input = Data("short output".utf8)
        withPipe(input, eof: true) { descriptor in
            var output = Data("prefix".utf8)
            GuestProcessOutput.drain(descriptor, into: &output, limit: 64)
            precondition(output == Data("prefix".utf8) + input)
        }
    }

    private static func leavesInputWhenBudgetIsExhausted() {
        let input = Data("unread output".utf8)
        withPipe(input) { descriptor in
            let prefix = Data("full".utf8)
            var output = prefix
            GuestProcessOutput.drain(descriptor, into: &output, limit: prefix.count)
            precondition(output == prefix)
            precondition(remaining(descriptor, maximum: input.count) == input, "an exhausted capture consumed more input")
        }
    }

    private static func returnsWhenNoOutputIsAvailable() {
        withPipe(Data()) { descriptor in
            var output = Data()
            GuestProcessOutput.drain(descriptor, into: &output, limit: 64)
            precondition(output.isEmpty)
        }
    }

    /// Feeds `count` patterned bytes through a real pipe from a writer thread (so a reader that
    /// stops reading blocks it) and drains the nonblocking read end into `file`, as processes.spawn
    /// does. After a write error the drain continues with a ceiling of 0.
    private static func feed(_ count: Int, ceiling: Int, file: FileHandle) -> (written: Int, total: Int, failures: Int, finished: Bool) {
        var descriptors: [Int32] = [-1, -1]
        precondition(pipe(&descriptors) == 0)
        precondition(fcntl(descriptors[0], F_SETFL, fcntl(descriptors[0], F_GETFL) | O_NONBLOCK) == 0)
        let done = DispatchSemaphore(value: 0)
        let writeEnd = descriptors[1]
        DispatchQueue.global().async {
            let chunk = [UInt8]((0..<4096).map { UInt8($0 % 251) })
            var sent = 0
            while sent < count {
                let wrote = chunk.withUnsafeBytes { write(writeEnd, $0.baseAddress, min($0.count, count - sent)) }
                if wrote < 0 && errno == EINTR { continue }
                if wrote <= 0 { break }
                sent += wrote
            }
            close(writeEnd)
            done.signal()
        }
        var written = 0
        var total = 0
        var failures = 0
        var finished = false
        let deadline = Date().addingTimeInterval(5)
        func pump() -> Int {
            do {
                let counts = try GuestProcessOutput.drain(descriptors[0], to: file, ceiling: failures == 0 ? ceiling - written : 0)
                written += counts.written
                total += counts.total
                return counts.total
            } catch {
                failures += 1
                return 1
            }
        }
        while Date() < deadline {
            _ = pump()
            if done.wait(timeout: .now()) == .success {
                while pump() > 0 {}
                finished = true
                break
            }
            usleep(1000)
        }
        close(descriptors[0])
        return (written, total, failures, finished)
    }

    private static func spoolFile() -> (url: URL, handle: FileHandle) {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("vphone-drain-\(UUID().uuidString)")
        precondition(FileManager.default.createFile(atPath: url.path, contents: nil))
        return (url, FileHandle(forWritingAtPath: url.path)!)
    }

    private static func fileDrainStopsAtCeilingWithoutBlockingWriter() {
        let (url, handle) = spoolFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let result = feed(1 << 20, ceiling: 1000, file: handle)
        precondition(result.finished, "the writer of about 1 MiB was blocked by the drain")
        precondition(result.failures == 0)
        precondition(result.written == 1000 && result.total == 1 << 20, "the ceiling was not reported: \(result)")
        let kept = FileManager.default.contents(atPath: url.path)
        precondition(kept == Data((0..<1000).map { UInt8($0 % 251) }), "the file does not hold exactly the first 1000 bytes")
    }

    private static func fileDrainCapturesEverythingUnderCeiling() {
        let (url, handle) = spoolFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let size = (1 << 20) + 123
        let result = feed(size, ceiling: 2 << 20, file: handle)
        precondition(result.finished && result.failures == 0)
        precondition(result.written == size && result.total == size, "bytes were lost under the ceiling: \(result)")
        let expected = Data((0..<size).map { UInt8(($0 % 4096) % 251) })
        precondition(FileManager.default.contents(atPath: url.path) == expected, "captured bytes differ")
    }

    private static func fileDrainFailsPromptlyOnWriteError() {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("vphone-drain-\(UUID().uuidString)")
        precondition(FileManager.default.createFile(atPath: url.path, contents: nil))
        defer { try? FileManager.default.removeItem(at: url) }
        let readOnly = FileHandle(forReadingAtPath: url.path)!
        let result = feed(1 << 20, ceiling: 1 << 30, file: readOnly)
        precondition(result.finished, "a failing write blocked the writer")
        precondition(result.failures == 1, "the write error was not thrown once")
        precondition(result.written == 0)
    }
}

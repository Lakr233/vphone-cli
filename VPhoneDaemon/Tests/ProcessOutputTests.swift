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
        print("process output capture: byte budget, remaining space, EOF and nonblocking reads passed")
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
}

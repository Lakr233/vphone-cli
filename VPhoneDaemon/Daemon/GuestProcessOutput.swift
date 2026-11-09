import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

enum GuestProcessOutput {
    /// The caller configures the descriptor as nonblocking before draining it.
    static func drain(_ descriptor: Int32, into data: inout Data, limit: Int) {
        guard data.count < limit else { return }
        var buffer = [UInt8](repeating: 0, count: min(4096, limit - data.count))
        while data.count < limit {
            let count = read(descriptor, &buffer, min(buffer.count, limit - data.count))
            guard count > 0 else { break }
            data.append(contentsOf: buffer[0..<count])
        }
    }
}

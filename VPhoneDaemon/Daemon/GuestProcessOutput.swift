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

    /// Reads a nonblocking pipe until it has no more data now (or EOF), writing up to `ceiling`
    /// bytes to `file` and discarding the rest, so the child never blocks on a full pipe.
    /// `total` counts every byte read; `written < total` means the ceiling was hit. A write error
    /// is recorded, the pipe is still read dry, and the error is thrown after; the caller then
    /// passes a ceiling of 0 to keep discarding. One call reads at most 1 MiB, so a child that
    /// never stops writing cannot hold the caller past its timeout.
    static func drain(_ descriptor: Int32, to file: FileHandle, ceiling: Int) throws -> (written: Int, total: Int) {
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        var written = 0
        var total = 0
        var failure: Int32?
        while total < 1 << 20 {
            let count = read(descriptor, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { break }
            total += count
            let room = min(count, ceiling - written)
            guard room > 0, failure == nil else { continue }
            var offset = 0
            while offset < room {
                let result = buffer[offset ..< room].withUnsafeBytes { write(file.fileDescriptor, $0.baseAddress, $0.count) }
                if result < 0 {
                    if errno == EINTR { continue }
                    failure = errno
                    break
                }
                offset += result
            }
            written += offset
        }
        if let failure { throw POSIXError(POSIXErrorCode(rawValue: failure) ?? .EIO) }
        return (written, total)
    }
}

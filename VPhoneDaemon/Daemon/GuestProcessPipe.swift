import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

final class GuestProcessPipe {
    let readEnd: Int32
    private(set) var writeEnd: Int32

    init(create: (UnsafeMutablePointer<Int32>) -> Int32 = { pipe($0) }) throws {
        var descriptors: [Int32] = [-1, -1]
        guard create(&descriptors) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        readEnd = descriptors[0]
        writeEnd = descriptors[1]
    }

    deinit {
        close(readEnd)
        closeWriteEnd()
    }

    func closeWriteEnd() {
        guard writeEnd >= 0 else { return }
        let descriptor = writeEnd
        // The descriptor number can be reused as soon as close returns.
        writeEnd = -1
        close(descriptor)
    }
}

import CoreFoundation
import Darwin
import Foundation

/// Validates guest-controlled binary headers and receives bodies with bounded memory and time.
public enum VPhoneControlTransfer {
    public static let memoryLimit = 64 * 1024 * 1024
    public enum TransferError: Error { case invalidHeader, tooLarge, timedOut, truncated, writeFailed }

    public static func length(_ value: Any?) throws -> Int {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              !["f", "d"].contains(String(cString: number.objCType)),
              let result = Int(number.stringValue), result >= 0
        else { throw TransferError.invalidHeader }
        return result
    }

    public static func payloadLength(message: [String: Any], requestType: String, streaming: Bool) throws -> Int? {
        let type = message["t"] as? String
        if type == "file_data" {
            guard requestType == "file_get" else { throw TransferError.invalidHeader }
            let count = try length(message["size"])
            guard streaming || count <= memoryLimit else { throw TransferError.tooLarge }
            return count
        }
        if requestType == "file_get", type != "err" { throw TransferError.invalidHeader }
        if type == "clipboard_get" {
            guard requestType == "clipboard_get",
                  let image = message["has_image"] as? NSNumber,
                  CFGetTypeID(image) == CFBooleanGetTypeID()
            else { throw TransferError.invalidHeader }
            if image.boolValue {
                let count = try length(message["image_size"])
                guard count <= memoryLimit else { throw TransferError.tooLarge }
                return count
            }
        }
        return nil
    }

    /// Nonblocking sends keep a guest that stops reading from trapping a caller forever.
    public static func send(fd: Int32, bytes: UnsafeRawBufferPointer, deadline: TimeInterval) throws {
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw TransferError.writeFailed
        }
        var noSignal: Int32 = 1
        guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal,
                         socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            throw TransferError.writeFailed
        }
        var offset = 0
        while offset < bytes.count {
            let seconds = deadline - ProcessInfo.processInfo.systemUptime
            guard seconds > 0 else { throw TransferError.timedOut }
            var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            let ready = poll(&descriptor, 1, Int32(min(ceil(seconds * 1000), Double(Int32.max))))
            if ready < 0, errno == EINTR { continue }
            guard ready > 0 else { throw TransferError.timedOut }
            let written = Darwin.send(fd, bytes.baseAddress! + offset,
                                      min(bytes.count - offset, 64 * 1024), 0)
            if written < 0, errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK { continue }
            guard written > 0 else { throw TransferError.writeFailed }
            offset += written
        }
    }

    /// The caller owns both descriptors until this function returns. Files are streamed in 64 KiB chunks.
    public static func receive(fd: Int32, count: Int, deadline: TimeInterval,
                               output: Int32? = nil) throws -> Data {
        guard count >= 0 else { throw TransferError.invalidHeader }
        guard output != nil || count <= memoryLimit else { throw TransferError.tooLarge }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: min(count, 64 * 1024))
        var remaining = count
        while remaining > 0 {
            let seconds = deadline - ProcessInfo.processInfo.systemUptime
            guard seconds > 0 else { throw TransferError.timedOut }
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, Int32(min(ceil(seconds * 1000), Double(Int32.max))))
            if ready < 0, errno == EINTR { continue }
            guard ready > 0 else { throw TransferError.timedOut }
            let received = buffer.withUnsafeMutableBytes {
                Darwin.read(fd, $0.baseAddress!, min(remaining, $0.count))
            }
            if received < 0, errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK { continue }
            guard received > 0 else { throw TransferError.truncated }
            if let output {
                try buffer.withUnsafeBytes { bytes in
                    var offset = 0
                    while offset < received {
                        let written = Darwin.write(output, bytes.baseAddress! + offset, received - offset)
                        if written < 0, errno == EINTR { continue }
                        guard written > 0 else { throw TransferError.writeFailed }
                        offset += written
                    }
                }
            } else {
                data.append(contentsOf: buffer.prefix(received))
            }
            remaining -= received
        }
        return data
    }
}

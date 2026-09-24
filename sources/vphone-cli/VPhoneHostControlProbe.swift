import Darwin
import Foundation

/// Ask the GUI VM's local control socket to perform a real vphoned ping.
/// `vm create` uses this instead of parsing the VM process's buffered stdout.
enum VPhoneHostControlProbe {
    static func ping(socketPath: String) -> Bool {
        let path = socketPath.utf8CString
        var address = sockaddr_un()
        guard path.count <= MemoryLayout.size(ofValue: address.sun_path) else { return false }
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: path.count) { destination in
                for (index, byte) in path.enumerated() {
                    destination[index] = byte
                }
            }
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        _ = withUnsafePointer(to: &timeout) {
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, $0, socklen_t(MemoryLayout<timeval>.size))
        }
        var noSigPipe: Int32 = 1
        _ = withUnsafePointer(to: &noSigPipe) {
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, $0, socklen_t(MemoryLayout<Int32>.size))
        }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { return false }

        let request = Data("{\"t\":\"ping\",\"screen\":false}\n".utf8)
        let written = request.withUnsafeBytes { bytes in
            Darwin.write(fd, bytes.baseAddress, bytes.count)
        }
        guard written == request.count else { return false }

        var reply = Data()
        var buffer = [UInt8](repeating: 0, count: 512)
        while reply.count < 4096 {
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(fd, bytes.baseAddress, bytes.count)
            }
            guard count > 0 else { return false }
            reply.append(contentsOf: buffer.prefix(count))
            if let newline = reply.firstIndex(of: 0x0A),
               let json = try? JSONSerialization.jsonObject(with: Data(reply[..<newline])) as? [String: Any]
            {
                return json["ok"] as? Bool == true
            }
        }
        return false
    }
}

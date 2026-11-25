import Darwin
import Foundation
import VPhoneCoreKit

/// Requests to a running VM's control socket, `vphone.sock`. `vm create` pings
/// through it instead of parsing the VM process's buffered stdout, and
/// `vm network` drives the NIC through it.
enum VPhoneHostAutomationProbe {
    static func ping(socketPath: String) -> Bool {
        send(["t": "ping", "screen": false], socketPath: socketPath)?["ok"] as? Bool == true
    }

    /// One vphoned RPC through the VM process. A refusal from vphoned carries
    /// its error object as `detail`; anything else is a transport failure.
    static func rpc(_ method: String, params: [String: Any], socketPath: String, timeout: Int) throws -> [String: Any] {
        let request: [String: Any] = ["t": "rpc", "method": method, "params": params, "screen": false]
        guard let reply = send(request, socketPath: socketPath, timeout: timeout, maximumReply: 64 << 20) else {
            throw VPhoneGuestCallError(kind: .transport, message: "no answer from vphone.sock")
        }
        if reply["ok"] as? Bool == true {
            return reply["result"] as? [String: Any] ?? [:]
        }
        let message = reply["error"] as? String ?? "refused"
        if let detail = reply["guest_error"] as? [String: Any] {
            throw VPhoneGuestCallError(kind: .refused, message: message, detail: detail)
        }
        // The VM answered for the guest: not connected yet, or the request
        // to vphoned failed on the way.
        throw VPhoneGuestCallError(kind: .notConnected, message: message)
    }

    /// One request, one reply line. Nil when the socket is not there or the
    /// reply is not JSON. `timeout` bounds each read; `maximumReply` the
    /// reply (an `apps.list` or `processes.list` runs to a few hundred KB).
    static func send(
        _ request: [String: Any],
        socketPath: String,
        timeout seconds: Int = 2,
        maximumReply: Int = 1 << 20,
    ) -> [String: Any]? {
        guard case let .success(fd) = VPhoneUnixSocket.connect(to: socketPath) else { return nil }
        defer { close(fd) }

        var timeout = timeval(tv_sec: seconds, tv_usec: 0)
        _ = withUnsafePointer(to: &timeout) {
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, $0, socklen_t(MemoryLayout<timeval>.size))
        }
        var noSigPipe: Int32 = 1
        _ = withUnsafePointer(to: &noSigPipe) {
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, $0, socklen_t(MemoryLayout<Int32>.size))
        }
        guard var request = try? JSONSerialization.data(withJSONObject: request) else { return nil }
        request.append(0x0A)
        let written = request.withUnsafeBytes { bytes in
            Darwin.write(fd, bytes.baseAddress, bytes.count)
        }
        guard written == request.count else { return nil }

        var reply = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while reply.count < maximumReply {
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(fd, bytes.baseAddress, bytes.count)
            }
            guard count > 0 else { return nil }
            reply.append(contentsOf: buffer.prefix(count))
            if let newline = reply.firstIndex(of: 0x0A),
               let json = try? JSONSerialization.jsonObject(with: Data(reply[..<newline])) as? [String: Any]
            {
                return json
            }
        }
        return nil
    }
}

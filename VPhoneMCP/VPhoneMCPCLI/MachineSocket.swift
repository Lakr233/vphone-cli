import Darwin
import Foundation

/// Socket deadlines in seconds: `base` for each request, `long` for push and
/// pull, `rpc` for the rpc tool without `timeout_ms` (the host's rpc limit).
struct Deadlines {
    var base = 30.0
    var long = 600.0
    var rpc = 180.0
}

/// A socket failure. `message` is the text the client sees.
struct SocketError: Error {
    let message: String
}

/// The most bytes a reply line may hold, not counting its newline.
let replyLimit = 8_388_608

/// The most output a shell session returns, in bytes.
let shellOutputLimit = 1_048_576

/// The text of a shell session, and whether it is a failure.
struct ShellResult {
    let text: String
    let isError: Bool
}

func connectMessage(_ path: String) -> String {
    "cannot connect to \(path); check the VM is running"
}

func closedMessage(_ path: String) -> String {
    "connection to \(path) closed before a reply; check the VM is running"
}

func writeMessage(_ path: String) -> String {
    "write to \(path) failed; check the VM is running"
}

func noReplyMessage(_ path: String, _ seconds: Double) -> String {
    "no reply from \(path) after \(Int(seconds))s; check the VM is running"
}

func rpcNoReplyMessage(_ path: String, _ seconds: Double) -> String {
    "no reply from \(path) after \(Int(seconds))s; the guest call may still be running, so check its effect before calling again"
}

func malformedMessage(_ path: String) -> String {
    "malformed reply from \(path); check the VM is running and the socket is vphone.sock"
}

func noMessageMessage(_ path: String) -> String {
    "\(path) reported failure without a message; check the VM is running"
}

func tooLargeMessage() -> String {
    "reply too large (\(replyLimit + 1) bytes, limit \(replyLimit))"
}

/// The `guest-error` text for vphoned's error object: `<code>: <message>`, and a
/// `hint:` line when it has one. Nil unless `code` and `message` are non-empty strings.
func guestErrorMessage(_ guestError: Any?) -> String? {
    guard let object = guestError as? [String: Any],
          let code = object["code"] as? String, !code.isEmpty,
          let message = object["message"] as? String, !message.isEmpty else { return nil }
    guard let hint = object["hint"] as? String, !hint.isEmpty else { return "\(code): \(message)" }
    return "\(code): \(message)\nhint: \(hint)"
}

func unknownVMMessage(_ name: String, _ library: String) -> String {
    "unknown vm \(name); \(library) has no such directory; use the name of a directory in \(library)"
}

func notRunningMessage(_ name: String) -> String {
    "vm \(name) is not running; start it with vphone-cli vm launch \(name)"
}

func notInProfileMessage(_ tool: String, _ profile: String) -> String {
    "tool \(tool) is not available in profile \(profile); start vphone-mcp with a wider --profile"
}

func screenMessage(_ path: String, _ field: String, _ value: String) -> String {
    "invalid screen size from \(path): \(field) is \(value); check the guest is connected"
}

func unreadableMessage(_ capture: String) -> String {
    "screenshot unreadable: \(capture)"
}

func timeoutMessage(seconds: Int) -> String {
    seconds >= 600
        ? "timeout after 600s; the maximum is 600, so split the work into shorter commands"
        : "timeout after \(seconds)s; raise timeout_seconds (max 600)"
}

/// The VM's `vphone.sock`: one request and one reply per connection.
struct MachineSocket {
    let path: String
    var deadlines = Deadlines()

    /// Sends one request line and returns the reply object. An `ok:false`
    /// reply throws its `guest_error` text, or its `error`. The connect, the write and the read must
    /// together finish within `deadline` seconds; a miss throws `noReply`'s text.
    func send(_ request: [String: Any], deadline: Double,
              noReply: (String, Double) -> String = noReplyMessage) throws -> [String: Any] {
        var line = [UInt8](try JSONSerialization.data(withJSONObject: request))
        line.append(10)
        let end = ProcessInfo.processInfo.systemUptime + deadline
        let reply = try addressable(path) { socketPath in
            guard let fd = try connectSocket(socketPath, until: end) else {
                throw SocketError(message: noReply(path, deadline))
            }
            defer { close(fd) }
            try sendBytes(line, to: fd, until: end, noReply: noReply(path, deadline))
            return try readReply(from: fd, until: end, noReply: noReply(path, deadline))
        }
        return try parse(reply)
    }

    /// Runs a shell session: the request line, then `input` and a newline, then
    /// the input ends so the guest gets ^D. Reads until the guest closes, all
    /// within one deadline of `timeout` seconds. A connect failure throws; every
    /// other outcome is a result, with the output received so far.
    func shell(program: String?, input: String, timeout: Int) throws -> ShellResult {
        var request: [String: Any] = ["t": "shell"]
        if let program { request["program"] = program }
        var bytes = [UInt8](try JSONSerialization.data(withJSONObject: request))
        bytes.append(10)
        bytes.append(contentsOf: input.utf8)
        bytes.append(10)
        let end = ProcessInfo.processInfo.systemUptime + Double(timeout)
        return try addressable(path) { socketPath in
            guard let fd = try connectSocket(socketPath, until: end) else {
                return ShellResult(text: timeoutMessage(seconds: timeout), isError: true)
            }
            defer { close(fd) }
            return exchange(fd, bytes, end: end, timeout: timeout)
        }
    }

    /// Writes `request` and reads the session's output, interleaved, until the
    /// guest closes. Interleaving keeps a guest that echoes a large input from
    /// blocking the write.
    private func exchange(_ fd: Int32, _ request: [UInt8], end: Double, timeout: Int) -> ShellResult {
        var sent = 0
        var received: [UInt8] = []
        var eof = false
        var chunk = [UInt8](repeating: 0, count: 65_536)
        func failed(_ message: String) -> ShellResult {
            ShellResult(text: withOutput(received, message), isError: true)
        }
        while true {
            guard let wait = milliseconds(until: end) else {
                return failed(timeoutMessage(seconds: timeout))
            }
            if sent == request.count && eof { break }
            var events: Int16 = 0
            if sent < request.count { events |= Int16(POLLOUT) }
            if !eof { events |= Int16(POLLIN) }
            var pending = pollfd(fd: fd, events: events, revents: 0)
            let ready = poll(&pending, 1, wait)
            if ready < 0 && errno == EINTR { continue }
            if ready < 0 {
                if sent < request.count { return failed(writeMessage(path)) }
                eof = true
                continue
            }
            if ready == 0 { continue }
            if sent < request.count && pending.revents & Int16(POLLOUT | POLLERR | POLLHUP) != 0 {
                    guard let written = writeSome(fd, request, from: sent) else { return failed(writeMessage(path)) }
                if written == 0 { continue }
                sent += written
                if sent == request.count && shutdown(fd, SHUT_WR) != 0 { return failed(writeMessage(path)) }
            }
            if !eof && pending.revents & Int16(POLLIN | POLLERR | POLLHUP) != 0 {
                let count = read(fd, &chunk, chunk.count)
                if count < 0 && (errno == EAGAIN || errno == EINTR) { continue }
                if count <= 0 {
                    eof = true
                } else {
                    received.append(contentsOf: chunk[..<count])
                    if received.count > shellOutputLimit {
                        received.removeLast(received.count - shellOutputLimit)
                        return failed("output truncated at \(shellOutputLimit) bytes; print less output")
                    }
                }
            }
        }
        return finish(received)
    }

    /// The result once the guest has closed. The status line is the last line of
    /// the output (split on newlines, one trailing newline ignored, a trailing CR
    /// stripped). It must be a JSON object with a boolean `ok`. On success the
    /// output is returned as received; on failure only the bytes before the
    /// status line are.
    private func finish(_ output: [UInt8]) -> ShellResult {
        var stop = output.count
        if stop > 0 && output[stop - 1] == 10 { stop -= 1 }
        let start = output[..<stop].lastIndex(of: 10).map { $0 + 1 } ?? 0
        var line = output[start..<stop]
        if line.last == 13 { line = line.dropLast() }
        let status = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any]
        guard let status, isJSONBool(status["ok"]) else {
            return ShellResult(text: withOutput(output, "session ended without status"), isError: true)
        }
        if (status["ok"] as? Bool) == true {
            return ShellResult(text: String(decoding: output, as: UTF8.self), isError: false)
        }
        let message = (status["error"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? noMessageMessage(path)
        return ShellResult(text: withOutput(Array(output[..<start]), message), isError: true)
    }

    /// The output text, then a newline and `message`. One trailing newline of the
    /// output is dropped first. `message` alone when the output text is empty.
    private func withOutput(_ output: [UInt8], _ message: String) -> String {
        var bytes = output[...]
        if bytes.last == 10 { bytes = bytes.dropLast() }
        let text = String(decoding: bytes, as: UTF8.self)
        return text.isEmpty ? message : text + "\n" + message
    }

    /// Connects a new socket to `socketPath`, waiting until `end`. Nil when the
    /// deadline passes first. A connect that fails throws. Each attempt uses its
    /// own socket, so no socket is connected twice.
    private func connectSocket(_ socketPath: String, until end: Double) throws -> Int32? {
        let bytes = socketPath.utf8CString
        var address = sockaddr_un()
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            throw SocketError(message: connectMessage(path))
        }
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            for (index, byte) in bytes.enumerated() {
                buffer[index] = UInt8(bitPattern: byte)
            }
        }
        while true {
            guard milliseconds(until: end) != nil else { return nil }
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { throw SocketError(message: connectMessage(path)) }
            var noSigPipe: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            let connected = withUnsafePointer(to: address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            if connected == 0 { return fd }
            if errno == EAGAIN {
                close(fd)
                usleep(5_000)
                continue
            }
            guard errno == EINPROGRESS || errno == EINTR else {
                close(fd)
                throw SocketError(message: connectMessage(path))
            }
            guard let ready = waitFor(fd, Int16(POLLOUT), until: end) else {
                close(fd)
                return nil
            }
            var error: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            guard ready, getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length) == 0, error == 0 else {
                close(fd)
                throw SocketError(message: connectMessage(path))
            }
            return fd
        }
    }

    private func sendBytes(_ bytes: [UInt8], to fd: Int32, until end: Double, noReply: String) throws {
        var sent = 0
        while sent < bytes.count {
            guard let ready = waitFor(fd, Int16(POLLOUT), until: end) else {
                throw SocketError(message: noReply)
            }
            if !ready { throw SocketError(message: writeMessage(path)) }
            guard let written = writeSome(fd, bytes, from: sent) else { throw SocketError(message: writeMessage(path)) }
            sent += written
        }
    }

    /// Writes some of `bytes` from `offset`. Returns the count written, or 0 when
    /// the write would block or was interrupted. Nil on any other failure.
    private func writeSome(_ fd: Int32, _ bytes: [UInt8], from offset: Int) -> Int? {
        let written = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress! + offset, $0.count - offset) }
        if written < 0 && (errno == EAGAIN || errno == EINTR) { return 0 }
        return written > 0 ? written : nil
    }

    private func readReply(from fd: Int32, until end: Double, noReply: String) throws -> [UInt8] {
        var buffer: [UInt8] = []
        var scanned = 0
        var chunk = [UInt8](repeating: 0, count: 65_536)
        while true {
            if let newline = buffer[scanned...].firstIndex(of: 10) {
                guard newline <= replyLimit else { throw SocketError(message: tooLargeMessage()) }
                return Array(buffer[..<newline])
            }
            guard buffer.count <= replyLimit else { throw SocketError(message: tooLargeMessage()) }
            scanned = buffer.count
            guard let ready = waitFor(fd, Int16(POLLIN), until: end) else {
                throw SocketError(message: noReply)
            }
            if !ready { throw SocketError(message: closedMessage(path)) }
            let count = read(fd, &chunk, chunk.count)
            if count < 0 && (errno == EAGAIN || errno == EINTR) { continue }
            if count <= 0 { throw SocketError(message: closedMessage(path)) }
            buffer.append(contentsOf: chunk[..<count])
        }
    }

    private func parse(_ line: [UInt8]) throws -> [String: Any] {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
              isJSONBool(object["ok"]) else {
            throw SocketError(message: malformedMessage(path))
        }
        if (object["ok"] as? Bool) == true { return object }
        if let message = guestErrorMessage(object["guest_error"]) {
            throw SocketError(message: message)
        }
        if let message = object["error"] as? String, !message.isEmpty {
            throw SocketError(message: message)
        }
        throw SocketError(message: noMessageMessage(path))
    }
}

/// Waits until `fd` is ready for `events`. Nil when `end` passes first; false
/// when the poll reports an error or hang-up rather than readiness.
private func waitFor(_ fd: Int32, _ events: Int16, until end: Double) -> Bool? {
    while true {
        guard let wait = milliseconds(until: end) else { return nil }
        var pending = pollfd(fd: fd, events: events, revents: 0)
        let ready = poll(&pending, 1, wait)
        if ready < 0 && errno == EINTR { continue }
        if ready == 0 { return nil }
        return ready > 0 && pending.revents & events != 0
    }
}

/// Milliseconds left until `end` (a systemUptime), or nil once it has passed.
private func milliseconds(until end: Double) -> Int32? {
    let left = (end - ProcessInfo.processInfo.systemUptime) * 1000
    return left > 0 ? Int32(min(left.rounded(.up), Double(Int32.max))) : nil
}

/// True for a JSON boolean. JSONSerialization gives numbers and booleans both
/// as NSNumber, so the CoreFoundation type decides.
func isJSONBool(_ value: Any?) -> Bool {
    guard let number = value as? NSNumber else { return false }
    return CFGetTypeID(number) == CFBooleanGetTypeID()
}

/// Runs `body` with a path to the socket that fits `sun_path`. A long path is
/// reached through a symbolic link to its folder, in a private folder under
/// /tmp that is removed afterwards, as VPhoneUnixSocket does.
private func addressable<T>(_ path: String, _ body: (String) throws -> T) rethrows -> T {
    guard path.utf8CString.count > MemoryLayout.size(ofValue: sockaddr_un().sun_path) else {
        return try body(path)
    }
    var template = Array("/tmp/vphone.XXXXXX".utf8CString)
    let created = template.withUnsafeMutableBufferPointer { buffer in
        mkdtemp(buffer.baseAddress!).map { String(cString: $0) }
    }
    guard let folder = created else { return try body(path) }
    let link = folder + "/d"
    defer {
        unlink(link)
        rmdir(folder)
    }
    guard symlink((path as NSString).deletingLastPathComponent, link) == 0 else {
        return try body(path)
    }
    return try body(link + "/" + (path as NSString).lastPathComponent)
}

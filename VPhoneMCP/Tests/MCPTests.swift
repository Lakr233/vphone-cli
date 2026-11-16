import Compression
import CoreGraphics
import Darwin
import Foundation
import ImageIO

// Tests for vphone-mcp, built by Tests/MCPTests.sh with every VPhoneMCPCLI
// source except main.swift. Each failed check prints its label and exits 1.

/// An integer shared between a test and the threads of a fake.
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int

    init(_ value: Int = 0) {
        self.value = value
    }

    func get() -> Int { lock.withLock { value } }
    func set(_ new: Int) { lock.withLock { value = new } }
    func add(_ delta: Int) { lock.withLock { value += delta } }
}

/// A fake vphone.sock. It accepts on a background thread and runs `handler`
/// on a thread of its own per connection, so a hung connection does not block
/// the next one. With `accepts` false nothing is accepted, and `backlog` sets
/// how many clients wait unaccepted.
final class FakeSocket: @unchecked Sendable {
    let path: String
    let connections = Counter()

    init(path: String, backlog: Int32 = 16, accepts: Bool = true, handler: @escaping @Sendable (Int32) -> Void) {
        self.path = path
        unlink(path)
        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = path.utf8CString
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            for (index, byte) in bytes.enumerated() {
                buffer[index] = UInt8(bitPattern: byte)
            }
        }
        _ = withUnsafePointer(to: address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        listen(listener, backlog)
        guard accepts else { return }
        let connections = self.connections
        Thread.detachNewThread {
            while true {
                let client = accept(listener, nil, nil)
                guard client >= 0 else { continue }
                var noSigPipe: Int32 = 1
                setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
                connections.add(1)
                Thread.detachNewThread {
                    handler(client)
                    close(client)
                }
            }
        }
    }
}

/// One canned reply line, sent after `delay` seconds. `closes` hangs up instead.
struct Reply {
    let line: String
    var delay: Double = 0
    var closes = false
}

/// Every request line a fake receives, in order.
final class Log: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    func add(_ line: String) { lock.withLock { lines.append(line) } }

    func reset() { lock.withLock { lines = [] } }

    var requests: [String] { lock.withLock { lines } }

    /// The requests whose `t` is `type`, as objects.
    func sent(_ type: String) -> [[String: Any]] {
        requests.map { parse($0) }.filter { ($0["t"] as? String) == type }
    }
}

/// Reads one request line from a client, without its newline.
func readRequest(_ client: Int32) -> String {
    var bytes: [UInt8] = []
    var byte: UInt8 = 0
    while read(client, &byte, 1) == 1, byte != 10 {
        bytes.append(byte)
    }
    return String(decoding: bytes, as: UTF8.self)
}

/// Writes `bytes` and returns how many were accepted before an error.
func writeAll(_ client: Int32, _ bytes: [UInt8]) -> Int {
    var total = 0
    while total < bytes.count {
        let written = bytes.withUnsafeBytes { write(client, $0.baseAddress! + total, $0.count - total) }
        if written <= 0 { break }
        total += written
    }
    return total
}

/// The key a request is looked up by: its `t`, or `rpc:<method>` for rpc.
func requestKey(_ request: String) -> String {
    guard let object = (try? JSONSerialization.jsonObject(with: Data(request.utf8))) as? [String: Any],
          let type = object["t"] as? String else { return "" }
    if type == "rpc", let method = object["method"] as? String { return "rpc:\(method)" }
    return type
}

/// A handler that answers each request from `table`; unknown keys get ok:false.
/// Every request is logged.
func tableHandler(_ table: [String: Reply], log: Log = Log(),
                  screenshot: @escaping @Sendable (String) -> Reply = { _ in Reply(line: #"{"ok":true}"#) }) -> @Sendable (Int32) -> Void {
    { client in
        let request = readRequest(client)
        log.add(request)
        let key = requestKey(request)
        let reply = key == "screenshot"
            ? screenshot((parse(request)["path"] as? String) ?? "")
            : table[key] ?? Reply(line: "{\"ok\":false,\"error\":\"no table entry for \(key)\"}")
        if reply.closes { return }
        if reply.delay > 0 { Thread.sleep(forTimeInterval: reply.delay) }
        _ = writeAll(client, Array((reply.line + "\n").utf8))
    }
}

/// A JSON object line of exactly `length` bytes, without its newline.
func bigLine(_ length: Int) -> String {
    let prefix = #"{"ok":true,"pad":""#
    let suffix = #""}"#
    return prefix + String(repeating: "a", count: length - prefix.utf8.count - suffix.utf8.count) + suffix
}

/// The deadlines every test server uses: base 1 s, long 2 s, rpc 2 s.
let testDeadlines = Deadlines(base: 1, long: 2, rpc: 2)

func freshPath() -> String {
    "/tmp/vmcp-\(getpid())-\(UUID().uuidString.prefix(8)).sock"
}

func expect(_ condition: Bool, _ label: String) {
    if !condition {
        print("FAIL: \(label)")
        exit(1)
    }
}

/// Runs `body`, which must throw a SocketError with exactly `message`, in under 3 seconds.
func expectSocketError(_ label: String, _ message: String, _ body: () throws -> Void) {
    let start = ProcessInfo.processInfo.systemUptime
    var got = "nothing thrown"
    do {
        try body()
    } catch let error as SocketError {
        got = error.message
    } catch {
        got = "\(error)"
    }
    let elapsed = ProcessInfo.processInfo.systemUptime - start
    expect(got == message && elapsed < 3, "\(label): got \"\(got)\" after \(elapsed)s, want \"\(message)\"")
}

/// The canonical JSON text of a value, with sorted keys, for comparing objects.
func canonical(_ value: Any?) -> String {
    let data = try? JSONSerialization.data(withJSONObject: value ?? NSNull(), options: [.fragmentsAllowed, .sortedKeys])
    return data.map { String(decoding: $0, as: UTF8.self) } ?? "unencodable"
}

/// The reply line as a JSON object, or empty when there is no reply.
func parse(_ line: String?) -> [String: Any] {
    guard let line, let object = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else {
        return [:]
    }
    return object
}

/// Runs `body` with a SIGALRM handler, installed without SA_RESTART, that fires every 10 ms.
func withInterruptingTimer(_ body: () throws -> Void) rethrows {
    var action = sigaction()
    action.__sigaction_u.__sa_handler = { _ in }
    sigemptyset(&action.sa_mask)
    action.sa_flags = 0
    sigaction(SIGALRM, &action, nil)
    var timer = itimerval(it_interval: timeval(tv_sec: 0, tv_usec: 10_000), it_value: timeval(tv_sec: 0, tv_usec: 10_000))
    setitimer(ITIMER_REAL, &timer, nil)
    defer {
        var stop = itimerval()
        setitimer(ITIMER_REAL, &stop, nil)
    }
    try body()
}

func machineSocketTests() throws {
    let path = freshPath()
    let machine = MachineSocket(path: path)
    let table: [String: Reply] = [
        "ping": Reply(line: #"{"ok":true,"result":{"a":1}}"#),
        "bad": Reply(line: #"{"ok":false,"error":"guest not connected"}"#),
        "silent": Reply(line: #"{"ok":false}"#),
        "hang": Reply(line: "", delay: 5),
        "garbage": Reply(line: "garbage"),
        "array": Reply(line: "[1]"),
        "big": Reply(line: bigLine(8_388_608)),
        "huge": Reply(line: bigLine(8_388_609)),
    ]
    _ = FakeSocket(path: path, handler: tableHandler(table))

    let reply = try machine.send(["t": "ping"], deadline: 1)
    expect((reply["result"] as? [String: Any])?["a"] as? Int == 1, "ok:true returns its dictionary")

    expectSocketError("ok:false error", "guest not connected") {
        _ = try machine.send(["t": "bad"], deadline: 1)
    }
    expectSocketError("ok:false without error", "\(path) reported failure without a message; check the VM is running") {
        _ = try machine.send(["t": "silent"], deadline: 1)
    }
    expectSocketError("missing socket", "cannot connect to /tmp/vmcp-missing.sock; check the VM is running") {
        _ = try MachineSocket(path: "/tmp/vmcp-missing.sock").send(["t": "ping"], deadline: 1)
    }
    expectSocketError("no reply", "no reply from \(path) after 1s; check the VM is running") {
        _ = try machine.send(["t": "hang"], deadline: 1)
    }
    _ = try machine.send(["t": "ping"], deadline: 1)

    let stalled = freshPath()
    _ = FakeSocket(path: stalled, handler: { client in _ = readRequest(client); Thread.sleep(forTimeInterval: 5) })
    expectSocketError("unread 1 MiB request", "no reply from \(stalled) after 1s; check the VM is running") {
        _ = try MachineSocket(path: stalled).send(["t": "rpc", "method": "x", "pad": String(repeating: "a", count: 1_048_576)],
                                                 deadline: 1)
    }

    let full = freshPath()
    _ = FakeSocket(path: full, backlog: 0, accepts: false, handler: { _ in })
    let parked = socket(AF_UNIX, SOCK_STREAM, 0)
    var fullAddress = sockaddr_un()
    fullAddress.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &fullAddress.sun_path) { buffer in
        for (index, byte) in full.utf8CString.enumerated() { buffer[index] = UInt8(bitPattern: byte) }
    }
    _ = withUnsafePointer(to: fullAddress) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(parked, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    expectSocketError("backlog full", "no reply from \(full) after 1s; check the VM is running") {
        _ = try MachineSocket(path: full).send(["t": "ping"], deadline: 1)
    }

    let garbled = freshPath()
    _ = FakeSocket(path: garbled, handler: tableHandler([
        "garbage": Reply(line: "garbage"), "array": Reply(line: "[1]"),
    ]))
    let malformed = "malformed reply from \(garbled); check the VM is running and the socket is vphone.sock"
    expectSocketError("garbage reply", malformed) { _ = try MachineSocket(path: garbled).send(["t": "garbage"], deadline: 1) }
    expectSocketError("array reply", malformed) { _ = try MachineSocket(path: garbled).send(["t": "array"], deadline: 1) }

    let closedPath = freshPath()
    let closedCount = Counter()
    let closing = FakeSocket(path: closedPath, handler: { client in
        _ = readRequest(client)
        closedCount.add(1)
    })
    let closedMessage = "connection to \(closedPath) closed before a reply; check the VM is running"
    expectSocketError("closed before reply", closedMessage) { _ = try MachineSocket(path: closedPath).send(["t": "x"], deadline: 1) }
    expect(closedCount.get() == 1 && closing.connections.get() == 1, "a closed connection is sent exactly one request")

    let resetPath = freshPath()
    _ = FakeSocket(path: resetPath, handler: { client in
        _ = readRequest(client)
        var linger = linger(l_onoff: 1, l_linger: 0)
        setsockopt(client, SOL_SOCKET, SO_LINGER, &linger, socklen_t(MemoryLayout<linger>.size))
    })
    expectSocketError("reset before reply", "connection to \(resetPath) closed before a reply; check the VM is running") {
        _ = try MachineSocket(path: resetPath).send(["t": "x"], deadline: 1)
    }

    let writePath = freshPath()
    _ = FakeSocket(path: writePath, handler: { client in close(client) })
    expectSocketError("write after close", "write to \(writePath) failed; check the VM is running") {
        _ = try MachineSocket(path: writePath).send(["t": "pad", "pad": String(repeating: "a", count: 1_048_576)], deadline: 2)
    }

    let stalePath = freshPath()
    let staleFD = socket(AF_UNIX, SOCK_STREAM, 0)
    var staleAddress = fullAddress
    withUnsafeMutableBytes(of: &staleAddress.sun_path) { buffer in
        for (index, byte) in stalePath.utf8CString.enumerated() { buffer[index] = UInt8(bitPattern: byte) }
    }
    _ = withUnsafePointer(to: staleAddress) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(staleFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    close(staleFD)
    expectSocketError("stale socket file", "cannot connect to \(stalePath); check the VM is running") {
        _ = try MachineSocket(path: stalePath).send(["t": "ping"], deadline: 1)
    }

    let slowPath = freshPath()
    _ = FakeSocket(path: slowPath, handler: tableHandler([
        "ping": Reply(line: #"{"ok":true,"result":"slow"}"#, delay: 0.5),
    ]))
    withInterruptingTimer {
        let interrupted = try? MachineSocket(path: slowPath).send(["t": "ping"], deadline: 2)
        expect((interrupted?["result"] as? String) == "slow", "a signal during send does not lose the reply")
    }

    let big = try machine.send(["t": "big"], deadline: 2)
    expect((big["pad"] as? String)?.utf8.count ?? 0 > 8_000_000, "an 8388608-byte reply is accepted")
    expectSocketError("8 MiB + 1 reply", "reply too large (8388609 bytes, limit 8388608)") {
        _ = try machine.send(["t": "huge"], deadline: 2)
    }

    let written = Counter(-1)
    let streamPath = freshPath()
    _ = FakeSocket(path: streamPath, handler: { client in
        _ = readRequest(client)
        let chunk = [UInt8](repeating: 97, count: 65_536)
        var total = 0
        while total < 20 * 1_048_576 {
            let accepted = writeAll(client, chunk)
            total += accepted
            if accepted < chunk.count { break }
        }
        written.set(total)
    })
    expectSocketError("20 MiB without newline", "reply too large (8388609 bytes, limit 8388608)") {
        _ = try MachineSocket(path: streamPath).send(["t": "stream"], deadline: 5)
    }
    for _ in 0..<50 where written.get() < 0 {
        Thread.sleep(forTimeInterval: 0.1)
    }
    expect(written.get() >= 0 && written.get() < 20 * 1_048_576, "the reader stops the stream early (\(written.get()) bytes)")

    print("MachineSocket tests passed")
}

/// Feeds `bytes` through readLines on a pipe. Returns the reply lines and the failure, if any.
func feed(_ bytes: [UInt8], server: MCPServer) -> (replies: [String], failure: String?) {
    var fds: [Int32] = [0, 0]
    _ = pipe(&fds)
    let input = fds[0]
    let output = fds[1]
    Thread.detachNewThread {
        _ = writeAll(output, bytes)
        close(output)
    }
    var collected: [String] = []
    let failure = readLines(fd: input, handle: { server.handle(line: $0) }, write: {
        collected.append($0)
        return true
    })
    close(input)
    return (collected, failure)
}

/// A JSON object line of exactly `length` bytes that carries `id` and `method`, padded.
func paddedRequest(length: Int, id: Int) -> String {
    let prefix = #"{"id":\#(id),"method":"ping","pad":""#
    let suffix = #""}"#
    return prefix + String(repeating: "a", count: length - prefix.utf8.count - suffix.utf8.count) + suffix
}

func expectErrorReply(_ reply: String?, _ label: String, id: Any, code: Int, message: String) {
    let object = parse(reply)
    expect(canonical(object["error"]) == canonical(["code": code, "message": message] as [String: Any])
               && canonical(object["id"]) == canonical(id),
           "\(label): got \(reply ?? "no reply")")
}

func expectResultReply(_ reply: String?, _ label: String, id: Any, result: [String: Any]) {
    let object = parse(reply)
    expect(canonical(object["result"]) == canonical(result) && canonical(object["id"]) == canonical(id),
           "\(label): got \(reply ?? "no reply")")
}

func serverTests() throws {
    let path = freshPath()
    let connections = Counter()
    _ = FakeSocket(path: path, handler: { _ in connections.add(1) })
    let server = try! MCPServer(defaultSocket: path, allowed: Set(toolNames), deadlines: testDeadlines)

    expectResultReply(server.handle(line: #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#), "initialize", id: 1, result: [
        "protocolVersion": "2025-06-18",
        "capabilities": ["tools": [String: Any]()],
        "serverInfo": ["name": "vphone-mcp", "version": "1.0.0"],
    ])
    expectErrorReply(server.handle(line: #"{"id":2,"method":"nope"}"#), "unknown method", id: 2, code: -32601, message: "method nope not found")
    expectErrorReply(server.handle(line: "{nope"), "invalid JSON", id: NSNull(), code: -32700,
                     message: "parse error: line is not valid JSON")
    expectResultReply(server.handle(line: #"{"id":3,"method":"ping"}"#), "ping after a parse error", id: 3, result: [:])

    let invalid = "invalid request: expected an object with a string method"
    expectErrorReply(server.handle(line: "[]"), "array request", id: NSNull(), code: -32600, message: invalid)
    expectErrorReply(server.handle(line: #"{"method":5,"id":1}"#), "non-string method", id: NSNull(), code: -32600, message: invalid)
    expectErrorReply(server.handle(line: #"{"id":{},"method":"ping"}"#), "object id", id: NSNull(), code: -32600,
                     message: "invalid request: id must be a string, number or null")
    expectResultReply(server.handle(line: #"{"id":null,"method":"ping"}"#), "null id", id: NSNull(), result: [:])
    expect(server.handle(line: #"{"jsonrpc":"2.0","method":"ping"}"#) == nil, "a notification gets no reply")
    expect(server.handle(line: #"{"method":"tools/call","params":{"name":"screenshot","arguments":{}}}"#) == nil,
           "a notification tools/call gets no reply")

    let badCalls: [(String, String)] = [
        (#"{"id":4,"method":"tools/call","params":{}}"#, "invalid argument name: missing"),
        (#"{"id":4,"method":"tools/call","params":5}"#, "invalid argument name: missing"),
        (#"{"id":4,"method":"tools/call","params":{"name":5}}"#, "invalid argument name: must be a non-empty string"),
        (#"{"id":4,"method":"tools/call","params":{"name":"screenshot","arguments":[]}}"#, "invalid argument arguments: must be an object"),
        (#"{"id":4,"method":"tools/call"}"#, "invalid argument name: missing"),
    ]
    for (call, message) in badCalls {
        expectErrorReply(server.handle(line: call), call, id: 4, code: -32602, message: message)
    }
    expect(connections.get() == 0, "no socket connection for notifications or argument errors")
    expectResultReply(server.handle(line: #"{"id":6,"method":"ping"}"#), "ping after tools/call errors", id: 6, result: [:])

    let limited = try! MCPServer(defaultSocket: path, allowed: ["screenshot", "methods"], deadlines: testDeadlines)
    expectErrorReply(limited.handle(line: #"{"id":7,"method":"tools/call","params":{"name":"shell","arguments":{}}}"#), "disabled tool",
                     id: 7, code: -32602, message: "tool shell is not enabled; add it to --tools")
    expectErrorReply(limited.handle(line: #"{"id":8,"method":"tools/call","params":{"name":"bogus"}}"#), "unknown tool", id: 8,
                     code: -32602, message: "unknown tool bogus; call tools/list for the available names")
    expect(connections.get() == 0, "no socket connection for a disabled or unknown tool")

    let listed = parse(limited.handle(line: #"{"id":9,"method":"tools/list"}"#))["result"] as? [String: Any]
    expect(((listed?["tools"] as? [[String: Any]]) ?? []).compactMap { $0["name"] as? String } == ["screenshot", "methods"],
           "tools/list lists the allowed tools in toolNames order")

    let exact = feed(Array((paddedRequest(length: 1_048_576, id: 9) + "\n").utf8), server: server)
    expect(exact.replies.count == 1 && (parse(exact.replies.first)["id"] as? Int) == 9 && exact.failure == nil,
           "a 1 MiB line is processed")
    let over = feed(Array((paddedRequest(length: 1_048_577, id: 10) + "\n" + #"{"id":11,"method":"ping"}"# + "\n").utf8), server: server)
    expectErrorReply(over.replies.first, "a line over 1 MiB", id: NSNull(), code: -32600,
                     message: "invalid request: line over 1048576 bytes")
    expect(over.replies.count == 2 && (parse(over.replies.last)["id"] as? Int) == 11, "the line after an overlong line answers")
    let huge = feed(Array((String(repeating: "a", count: 64 << 20) + "\n" + #"{"method":"ping","id":1}"# + "\n").utf8), server: server)
    expect(huge.replies.count == 2 && (parse(huge.replies.last)["id"] as? Int) == 1, "a 64 MiB line is dropped and the next line answers")
    let tail = feed(Array(#"{"id":12,"method":"ping"}"#.utf8), server: server)
    expect(tail.replies.count == 1 && (parse(tail.replies.first)["id"] as? Int) == 12, "a final line with no newline gets a reply")
    let blanks = feed(Array("   \n\t\n{\"id\":13,\"method\":\"ping\"}\n".utf8), server: server)
    expect(blanks.replies.count == 1 && (parse(blanks.replies.first)["id"] as? Int) == 13, "a blank line gets no reply")
    let bad = feed([0xff, 0xfe, 10] + Array(#"{"id":14,"method":"ping"}"#.utf8) + [10], server: server)
    expectErrorReply(bad.replies.first, "invalid UTF-8", id: NSNull(), code: -32700, message: "parse error: line is not valid JSON")
    expect(bad.replies.count == 2 && (parse(bad.replies.last)["id"] as? Int) == 14, "invalid UTF-8 does not stop the server")

    let overflow = feed(Array((
        #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"methods","arguments":{"x":1e400}}}"# + "\n"
            + "1e400\n"
            + #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"rpc","arguments":{"method":"echo","params":{"v":-1e400}}}}"# + "\n"
            + #"{"id":1e400,"method":"ping"}"# + "\n"
            + #"{"id":16,"method":"ping"}"# + "\n").utf8), server: server)
    expect(overflow.replies.count == 5, "each non-finite line gets one reply and the server keeps reading")
    for index in 0..<4 {
        expectErrorReply(overflow.replies[index], "non-finite number line \(index + 1)", id: NSNull(), code: -32700,
                         message: "parse error: line is not valid JSON")
    }
    expect((parse(overflow.replies[4])["id"] as? Int) == 16 && parse(overflow.replies[4])["result"] != nil,
           "a ping after non-finite numbers answers")

    var pair: [Int32] = [0, 0]
    _ = pipe(&pair)
    _ = writeAll(pair[1], Array("{\"id\":1,\"method\":\"ping\"}\n".utf8))
    close(pair[1])
    let refused = readLines(fd: pair[0], handle: { server.handle(line: $0) }, write: { _ in false })
    close(pair[0])
    expect(refused?.hasPrefix("stdout write failed: ") == true, "readLines reports a failed write")

    var closed: [Int32] = [0, 0]
    _ = pipe(&closed)
    close(closed[0])
    close(closed[1])
    var closedWrites = 0
    let stdinFailure = readLines(fd: closed[0], handle: { server.handle(line: $0) }, write: { _ in
        closedWrites += 1
        return true
    })
    expect(stdinFailure == "stdin read failed: Bad file descriptor" && closedWrites == 0, "a closed stdin fails with its errno")

    print("MCPServer tests passed")
}

/// Bytes collected from a pipe by a reader thread.
final class Collected: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: [UInt8] = []

    func append(_ chunk: ArraySlice<UInt8>) { lock.withLock { bytes.append(contentsOf: chunk) } }

    var value: [UInt8] { lock.withLock { bytes } }
}

func stdioTests() throws {
    let server = try! MCPServer(defaultSocket: "/tmp/vmcp-unused.sock", allowed: Set(toolNames))

    var input: [Int32] = [0, 0]
    _ = pipe(&input)
    _ = writeAll(input[1], Array("{\"id\":1,\"method\":\"ping\"}\n".utf8))
    close(input[1])

    var output: [Int32] = [0, 0]
    _ = pipe(&output)
    let saved = dup(STDOUT_FILENO)
    dup2(output[1], STDOUT_FILENO)
    close(output[1])
    let drained = Collected()
    let finished = DispatchSemaphore(value: 0)
    let reader = output[0]
    Thread.detachNewThread {
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(reader, &chunk, chunk.count)
            if count < 0 && errno == EINTR { continue }
            if count <= 0 { break }
            drained.append(chunk[..<count])
            Thread.sleep(forTimeInterval: 0.0002)
        }
        finished.signal()
    }
    let reply = #"{"id":1,"result":""# + String(repeating: "b", count: 1 << 20) + #""}"#
    var failure: String? = "not run"
    withInterruptingTimer {
        failure = readLines(fd: input[0], handle: { _ in reply }, write: writeStdout)
    }
    dup2(saved, STDOUT_FILENO)
    close(saved)
    finished.wait()
    close(input[0])
    close(output[0])
    expect(failure == nil, "a full stdout pipe with signals still returns nil (\(failure ?? ""))")
    expect(drained.value == Array((reply + "\n").utf8), "the full reply reaches a slow reader through a full pipe")

    var empty: [Int32] = [0, 0]
    _ = pipe(&empty)
    let emptyRead = empty[0]
    let emptyWrite = empty[1]
    Thread.detachNewThread {
        Thread.sleep(forTimeInterval: 0.2)
        _ = writeAll(emptyWrite, Array("{\"id\":2,\"method\":\"ping\"}\n".utf8))
        close(emptyWrite)
    }
    var replies: [String] = []
    var emptyFailure: String? = "not run"
    withInterruptingTimer {
        emptyFailure = readLines(fd: emptyRead, handle: { server.handle(line: $0) }, write: {
            replies.append($0)
            return true
        })
    }
    close(emptyRead)
    expect(emptyFailure == nil && replies.count == 1 && (parse(replies.first)["id"] as? Int) == 2,
           "a signal before data arrives still returns the reply and nil")

    print("stdio tests passed")
}

/// A PNG of the given pixel size, encoded.
func pngData(width: Int, height: Int) -> Data {
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let image = context.makeImage()!
    let output = NSMutableData()
    let destination = CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    _ = CGImageDestinationFinalize(destination)
    return output as Data
}

/// A screenshot handler that writes a PNG of the given size to the requested path.
func writesPNG(_ width: Int, _ height: Int) -> @Sendable (String) -> Reply {
    { path in
        try? pngData(width: width, height: height).write(to: URL(fileURLWithPath: path))
        return Reply(line: #"{"ok":true}"#)
    }
}

/// The guest's answers: 1290 pixels over 430 points, so the scale is 3.
let defaultGuest: [String: Reply] = [
    "display.geometry": Reply(line: #"{"ok":true,"result":{"screenshot_pixels":[1290,2796]}}"#),
    "rpc:device.screen": Reply(line: #"{"ok":true,"result":{"width":430}}"#),
]

/// A server whose socket is a fake guest. `overrides` replace entries of `defaultGuest`.
func guestFake(_ overrides: [String: Reply] = [:], log: Log = Log(), catalog: String = catalogJSON,
               screenshot: @escaping @Sendable (String) -> Reply = writesPNG(1290, 2796)) -> (server: MCPServer, log: Log, fake: FakeSocket) {
    let path = freshPath()
    let table = defaultGuest.merging(overrides) { _, new in new }
    let fake = FakeSocket(path: path, handler: tableHandler(table, log: log, screenshot: screenshot))
    return (try! MCPServer(defaultSocket: path, allowed: Set(toolNames), deadlines: testDeadlines, catalog: catalog), log, fake)
}

/// A server whose guest geometry and width replies can be changed between calls.
func changingGuest() -> (server: MCPServer, geometry: Text, width: Text) {
    let path = freshPath()
    let geometry = Text()
    geometry.set(#"{"ok":true,"result":{"screenshot_pixels":[1290,2796]}}"#)
    let width = Text()
    width.set(#"{"ok":true,"result":{"width":430}}"#)
    _ = FakeSocket(path: path, handler: { client in
        let request = readRequest(client)
        let key = requestKey(request)
        if key == "screenshot", let path = parse(request)["path"] as? String {
            try? pngData(width: 1290, height: 2796).write(to: URL(fileURLWithPath: path))
        }
        let line: String
        switch key {
        case "display.geometry": line = geometry.get()
        case "rpc:device.screen": line = width.get()
        default: line = #"{"ok":true}"#
        }
        _ = writeAll(client, Array((line + "\n").utf8))
    })
    return (try! MCPServer(defaultSocket: path, allowed: Set(toolNames), deadlines: testDeadlines), geometry, width)
}

/// Test servers talk to one fake guest: a library with one VM, `t`, whose socket is the fake's path.
/// `call` adds `"vm":"t"` to a call that has no vm.
nonisolated(unsafe) var testLibraries = 0

extension MCPServer {
    convenience init(defaultSocket path: String, profile: Profile = .full, allowed: Set<String> = Set(toolNames),
                     deadlines: Deadlines = Deadlines(), catalog: String = catalogJSON) throws {
        testLibraries += 1
        let root = "/tmp/vmcp-t-\(getpid())-\(testLibraries)"
        try? FileManager.default.removeItem(atPath: root)
        try? FileManager.default.createDirectory(atPath: "\(root)/t", withIntermediateDirectories: true)
        let link = "\(root)/t/vphone.sock"
        if FileManager.default.fileExists(atPath: path) {
            try? FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: path)
        } else {
            FileManager.default.createFile(atPath: link, contents: nil)
        }
        try self.init(profile: profile, allowed: allowed, deadlines: deadlines,
                  env: ["VPHONE_LIBRARY_ROOT": root, "TEST_VM": "t"], catalogJSON: catalog)
    }

    /// The socket of the test VM.
    var defaultSocket: String? { vmSocketPath("t", env: env) }
}

/// The reply to a tools/call of `name` with `arguments` (JSON text), vm as given.
func callRaw(_ server: MCPServer, _ name: String, _ arguments: String) -> String? {
    server.handle(line: #"{"id":1,"method":"tools/call","params":{"name":"\#(name)","arguments":\#(arguments)}}"#)
}

/// The reply to a tools/call of `name` with `arguments` (JSON text); a test server's VM is added when no vm is given.
func call(_ server: MCPServer, _ name: String, _ arguments: String) -> String? {
    var arguments = arguments
    if let vm = server.env["TEST_VM"], !arguments.contains(#""vm""#) {
        arguments = arguments.replacingOccurrences(of: "{}", with: #"{"vm":"\#(vm)"}"#)
        if !arguments.contains(#""vm""#) { arguments = #"{"vm":"\#(vm)","#+arguments.dropFirst() }
    }
    return callRaw(server, name, arguments)
}

/// The text of a tool result, and its isError flag.
func outcome(_ reply: String?) -> (text: String, isError: Bool) {
    let result = parse(reply)["result"] as? [String: Any] ?? [:]
    let text = ((result["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
    return (text, result["isError"] as? Bool ?? false)
}

func expectTool(_ reply: String?, _ label: String, _ text: String, isError: Bool = false) {
    let got = outcome(reply)
    expect(got.text == text && got.isError == isError, "\(label): got \(got)")
}

/// True when `path` is directly inside `directory`.
func sameDirectory(_ path: String, _ directory: URL) -> Bool {
    let parent = URL(fileURLWithPath: path).deletingLastPathComponent().resolvingSymlinksInPath().path
    let temporary = directory.resolvingSymlinksInPath().path
    let trim = CharacterSet(charactersIn: "/")
    return parent.trimmingCharacters(in: trim) == temporary.trimmingCharacters(in: trim)
}

/// A string shared between a test and the thread of a fake.
final class Text: @unchecked Sendable {
    private let lock = NSLock()
    private var value = ""

    func set(_ new: String) { lock.withLock { value = new } }
    func get() -> String { lock.withLock { value } }
}

func scaleTests() throws {
    let (live, liveGeometry, liveWidth) = changingGuest()
    func size(_ server: MCPServer) -> String {
        let content = (parse(call(server, "screenshot", "{}"))["result"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
        return (content.last?["text"] as? String) ?? "no caption"
    }
    expect(size(live) == "430x932 points", "the screenshot at a 3x ratio: \(size(live))")
    liveWidth.set(#"{"ok":true,"result":{"width":215}}"#)
    expect(size(live) == "215x466 points", "the ratio is read again after the width changes")
    liveWidth.set(#"{"ok":true,"result":{"width":430}}"#)

    for key in ["display.geometry", "rpc:device.screen"] {
        let (broken, brokenLog, _) = guestFake([key: Reply(line: #"{"ok":false,"error":"no guest"}"#)])
        expectTool(call(broken, "screenshot", "{}"), "screenshot with failing \(key)", "no guest", isError: true)
        expect(brokenLog.sent("screenshot").isEmpty, "no capture after failing \(key)")
    }

    let cases: [(pixels: String, field: String, value: String)] = [
        ("[0,0]", "screenshot_pixels[0]", "0"),
        ("\"x\"", "screenshot_pixels", "\"x\""),
        ("[]", "screenshot_pixels[0]", "missing"),
        ("[\"a\"]", "screenshot_pixels[0]", "\"a\""),
    ]
    for item in cases {
        let (bad, badLog, _) = guestFake(["display.geometry": Reply(line: #"{"ok":true,"result":{"screenshot_pixels":\#(item.pixels)}}"#)])
        expectTool(call(bad, "screenshot", "{}"), "screenshot_pixels \(item.pixels)",
                   "invalid screen size from \(bad.defaultSocket!): \(item.field) is \(item.value); check the guest is connected",
                   isError: true)
        expect(badLog.sent("screenshot").isEmpty, "no capture for screenshot_pixels \(item.pixels)")
        expectResultReply(bad.handle(line: #"{"id":2,"method":"ping"}"#), "ping after screenshot_pixels \(item.pixels)", id: 2, result: [:])
    }
    for width in ["0", "-1", "\"430\"", "null"] {
        let (bad, _, _) = guestFake(["rpc:device.screen": Reply(line: #"{"ok":true,"result":{"width":\#(width)}}"#)])
        expectTool(call(bad, "screenshot", "{}"), "width \(width)",
                   "invalid screen size from \(bad.defaultSocket!): width is \(width); check the guest is connected", isError: true)
    }
    let (noWidth, _, _) = guestFake(["rpc:device.screen": Reply(line: #"{"ok":true,"result":{}}"#)])
    expectTool(call(noWidth, "screenshot", "{}"), "missing width",
               "invalid screen size from \(noWidth.defaultSocket!): width is missing; check the guest is connected", isError: true)
    let (nonFinite, nonFiniteLog, _) = guestFake([
        "display.geometry": Reply(line: #"{"ok":true,"result":{"screenshot_pixels":[1e308]}}"#),
        "rpc:device.screen": Reply(line: #"{"ok":true,"result":{"width":1e-10}}"#),
    ])
    expectTool(call(nonFinite, "screenshot", "{}"), "a non-finite ratio",
               "invalid screen size from \(nonFinite.defaultSocket!): width is 1e-10; check the guest is connected", isError: true)
    expect(nonFiniteLog.sent("screenshot").isEmpty, "no capture for a non-finite ratio")

    let (silent, silentLog, _) = guestFake(["rpc:device.screen": Reply(line: "", delay: 5)])
    let started = ProcessInfo.processInfo.systemUptime
    expectTool(call(silent, "screenshot", "{}"), "silent device.screen", "no reply from \(silent.defaultSocket!) after 1s; check the VM is running", isError: true)
    expect(ProcessInfo.processInfo.systemUptime - started < 3 && silentLog.sent("screenshot").isEmpty, "a silent device.screen gives no-reply without a capture")

    let (closing, closingLog, closingFake) = guestFake(["display.geometry": Reply(line: "", closes: true)])
    expectTool(call(closing, "screenshot", "{}"), "closed geometry",
               "connection to \(closing.defaultSocket!) closed before a reply; check the VM is running", isError: true)
    expect(closingFake.connections.get() == 1 && closingLog.sent("screenshot").isEmpty, "a closed request is not retried")

    let counted = guestFake()
    _ = call(counted.server, "screenshot", "{}")
    expect(counted.fake.connections.get() == 3, "screenshot makes exactly 3 socket requests")
    expect(counted.log.requests.prefix(2).map { requestKey($0) } == ["display.geometry", "rpc:device.screen"],
           "the geometry and device.screen requests come first")

    let (slow, _, _) = guestFake([
        "display.geometry": Reply(line: #"{"ok":true,"result":{"screenshot_pixels":[1290,2796]}}"#, delay: 0.9),
        "rpc:device.screen": Reply(line: #"{"ok":true,"result":{"width":430}}"#, delay: 0.9),
    ])
    let slowStart = ProcessInfo.processInfo.systemUptime
    expect(!outcome(call(slow, "screenshot", "{}")).isError, "screenshot with 0.9 s requests succeeds")
    expect(ProcessInfo.processInfo.systemUptime - slowStart < 3, "each request has its own deadline")

    print("scale tests passed")
}

func screenshotTests() throws {
    let (server, log, _) = guestFake()
    let reply = call(server, "screenshot", "{}")
    let content = (parse(reply)["result"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
    let imageData = Data(base64Encoded: (content.first?["data"] as? String) ?? "") ?? Data()
    expect(content.count == 2 && (content.first?["mimeType"] as? String) == "image/png", "the screenshot is a PNG image")
    expect(decodeImage(imageData).map { "\($0.width)x\($0.height)" } == "430x932", "the screenshot is scaled to points")
    let bare = parse(server.handle(line: #"{"id":1,"method":"tools/call","params":{"name":"screenshot","arguments":{"vm":"t"}}}"#))
    expect(((bare["result"] as? [String: Any])?["content"] as? [[String: Any]])?.count == 2,
           "screenshot with only vm returns the image")
    expect((content.last?["text"] as? String) == "430x932 points", "the caption gives the size in points")
    let capture = log.sent("screenshot").last?["path"] as? String ?? ""
    expect(!capture.isEmpty && !FileManager.default.fileExists(atPath: capture), "the capture file is removed")
    expect(sameDirectory(capture, FileManager.default.temporaryDirectory), "the capture is in the temporary directory")
    _ = call(server, "screenshot", "{}")
    let second = log.sent("screenshot").last?["path"] as? String ?? ""
    expect(!second.isEmpty && second != capture, "two captures get different paths")

    let failingSeen = Text()
    let (failing, _, _) = guestFake(screenshot: { path in
        failingSeen.set(path)
        try? pngData(width: 1290, height: 2796).write(to: URL(fileURLWithPath: path))
        return Reply(line: #"{"ok":false,"error":"busy"}"#)
    })
    expectTool(call(failing, "screenshot", "{}"), "a failing screenshot", "busy", isError: true)
    expect(!failingSeen.get().isEmpty && !FileManager.default.fileExists(atPath: failingSeen.get()),
           "a failing screenshot removes its capture")

    let silentSeen = Text()
    let (silent, _, _) = guestFake(screenshot: { path in
        silentSeen.set(path)
        try? pngData(width: 1290, height: 2796).write(to: URL(fileURLWithPath: path))
        return Reply(line: "", delay: 5)
    })
    expectTool(call(silent, "screenshot", "{}"), "a silent screenshot", "no reply from \(silent.defaultSocket!) after 1s; check the VM is running", isError: true)
    expect(!silentSeen.get().isEmpty && !FileManager.default.fileExists(atPath: silentSeen.get()),
           "a screenshot that never replies removes its capture")

    let garbageSeen = Text()
    let (garbage, _, _) = guestFake(screenshot: { path in
        garbageSeen.set(path)
        try? Data("garbage".utf8).write(to: URL(fileURLWithPath: path))
        return Reply(line: #"{"ok":true}"#)
    })
    expectTool(call(garbage, "screenshot", "{}"), "a garbage capture", "screenshot unreadable: \(garbageSeen.get())", isError: true)
    expect(!FileManager.default.fileExists(atPath: garbageSeen.get()), "a garbage capture is removed")

    let unwrittenSeen = Text()
    let (unwritten, _, _) = guestFake(screenshot: { path in
        unwrittenSeen.set(path)
        return Reply(line: #"{"ok":true}"#)
    })
    expectTool(call(unwritten, "screenshot", "{}"), "a capture never written", "screenshot unreadable: \(unwrittenSeen.get())", isError: true)
    expect(!unwrittenSeen.get().isEmpty && !FileManager.default.fileExists(atPath: unwrittenSeen.get()),
           "a capture never written leaves no file")

    let thinSeen = Text()
    let (thin, _, _) = guestFake(screenshot: { path in
        thinSeen.set(path)
        try? pngData(width: 1290, height: 1).write(to: URL(fileURLWithPath: path))
        return Reply(line: #"{"ok":true}"#)
    })
    expectTool(call(thin, "screenshot", "{}"), "a capture one pixel high", "screenshot unreadable: \(thinSeen.get())", isError: true)
    expect(!FileManager.default.fileExists(atPath: thinSeen.get()), "a thin capture is removed")

    print("screenshot tests passed")
}

func hostToolTests() throws {
    let overrides: [String: Reply] = [
        "push": Reply(line: #"{"ok":true,"result":{"bytes":3}}"#),
        "pull": Reply(line: #"{"ok":true,"result":{"bytes":3}}"#),
        "rpc:methods.list": Reply(line: #"{"ok":true,"result":[{"name":"tap"}]}"#),
        "rpc:order.a": Reply(line: #"{"ok":true,"result":{"b":1,"a":{"d":1,"c":2}}}"#),
        "rpc:order.b": Reply(line: #"{"ok":true,"result":{"a":{"c":2,"d":1},"b":1}}"#),
        "rpc:text": Reply(line: #"{"ok":true,"result":"s"}"#),
        "rpc:number": Reply(line: #"{"ok":true,"result":5}"#),
        "rpc:array": Reply(line: #"{"ok":true,"result":[1]}"#),
        "rpc:echo": Reply(line: #"{"ok":true}"#),
    ]
    let (server, log, _) = guestFake(overrides)

    expectTool(call(server, "push", #"{"local":"/a","path":"/b","mode":"755"}"#), "push with mode", #"{"bytes":3}"#)
    expect(canonical(log.sent("push").last) == canonical(["t": "push", "local": "/a", "path": "/b", "mode": "755"] as [String: Any]),
           "push sends its mode")
    expectTool(call(server, "push", #"{"local":"/a","path":"/b/"}"#), "push without mode", #"{"bytes":3}"#)
    expect(canonical(log.sent("push").last) == canonical(["t": "push", "local": "/a", "path": "/b/"] as [String: Any]),
           "push without mode sends no mode key")
    expectTool(call(server, "push", #"{"local":"/a","path":"/b","mode":"0755"}"#), "push with a 4-digit mode", #"{"bytes":3}"#)
    expect(log.sent("push").last?["mode"] as? String == "0755", "the 4-digit mode reaches the fake as 0755")
    expectTool(call(server, "pull", #"{"path":"/b","local":"/a"}"#), "pull", #"{"bytes":3}"#)
    expect(canonical(log.sent("pull").last) == canonical(["t": "pull", "path": "/b", "local": "/a"] as [String: Any]), "pull sends paths")
    expectTool(call(server, "methods", "{}"), "methods", #"[{"name":"tap"}]"#)
    expectTool(server.handle(line: #"{"id":1,"method":"tools/call","params":{"name":"methods","arguments":{"vm":"t"}}}"#), "methods with only vm",
               #"[{"name":"tap"}]"#)
    expect(canonical(log.sent("rpc").last) == canonical(["t": "rpc", "method": "methods.list"] as [String: Any]),
           "methods with only vm sends no params")
    expectTool(call(server, "rpc", #"{"method":"order.b"}"#), "rpc with a method", #"{"a":{"c":2,"d":1},"b":1}"#)
    expect(canonical(log.sent("rpc").last) == canonical(["t": "rpc", "method": "order.b"] as [String: Any]), "rpc without params")
    expectTool(call(server, "rpc", #"{"method":"echo","params":{"k":1}}"#), "rpc with params and no result", "{}")
    expect(canonical(log.sent("rpc").last) == canonical(
        ["t": "rpc", "method": "echo", "params": ["k": 1] as [String: Any]] as [String: Any]), "rpc sends params")
    expect(outcome(call(server, "rpc", #"{"method":"order.a"}"#)).text == #"{"a":{"c":2,"d":1},"b":1}"#,
           "object keys are sorted in the result text")

    expectTool(call(server, "rpc", #"{"method":"text"}"#), "a string result", #""s""#)
    expectTool(call(server, "rpc", #"{"method":"number"}"#), "a number result", "5")
    expectTool(call(server, "rpc", #"{"method":"array"}"#), "an array result", "[1]")

    let before = log.requests.count
    let invalid: [(String, String, String)] = [
        ("push", #"{"path":"/b"}"#, "invalid argument local: missing"),
        ("push", #"{"local":"a","path":"/b"}"#, "invalid argument local: must be an absolute path"),
        ("push", #"{"local":"/a","path":"b"}"#, "invalid argument path: must be an absolute path"),
        ("pull", #"{"path":"b","local":"/a"}"#, "invalid argument path: must be an absolute path"),
        ("push", #"{"local":"/a","path":"/b","mode":"9"}"#, "invalid argument mode: must be an octal mode of 3 or 4 digits"),
        ("push", #"{"local":"/a","path":"/b","mode":"77"}"#, "invalid argument mode: must be an octal mode of 3 or 4 digits"),
        ("push", #"{"local":"/a","path":"/b","mode":"77777"}"#, "invalid argument mode: must be an octal mode of 3 or 4 digits"),
        ("push", #"{"local":"/a","path":"/b","mode":"789"}"#, "invalid argument mode: must be an octal mode of 3 or 4 digits"),
        ("push", #"{"local":"/a","path":"/b","mode":"0abc"}"#, "invalid argument mode: must be an octal mode of 3 or 4 digits"),
        ("rpc", #"{"method":""}"#, "invalid argument method: must be a non-empty string"),
        ("rpc", #"{"method":"x","params":[]}"#, "invalid argument params: must be an object"),
    ]
    for (name, arguments, message) in invalid {
        expectErrorReply(call(server, name, arguments), "\(name) \(arguments)", id: 1, code: -32602, message: message)
    }
    expect(log.requests.count == before, "invalid arguments send no socket request")
    expectResultReply(server.handle(line: #"{"id":2,"method":"ping"}"#), "ping after invalid arguments", id: 2, result: [:])

    let gone = try! MCPServer(defaultSocket: "/tmp/vmcp-gone-\(getpid()).sock", allowed: Set(toolNames))
    expectTool(call(gone, "methods", "{}"), "methods with no socket",
               connectMessage(gone.defaultSocket!), isError: true)

    let (slowKey, _, _) = guestFake(["rpc:methods.list": Reply(line: #"{"ok":true}"#, delay: 1.5)])
    expectTool(call(slowKey, "methods", "{}"), "methods past 1 s", "no reply from \(slowKey.defaultSocket!) after 1s; check the VM is running",
               isError: true)

    let (slowPush, slowLog, _) = guestFake([
        "push": Reply(line: #"{"ok":true,"result":1}"#, delay: 1.5),
        "pull": Reply(line: #"{"ok":true,"result":2}"#, delay: 1.5),
    ])
    expectTool(call(slowPush, "push", #"{"local":"/a","path":"/b"}"#), "push with a long reply", "1")
    expectTool(call(slowPush, "pull", #"{"path":"/b","local":"/a"}"#), "pull with a long reply", "2")

    let (hungPush, _, _) = guestFake(["push": Reply(line: "", delay: 5), "pull": Reply(line: "", delay: 5)])
    expectTool(call(hungPush, "push", #"{"local":"/a","path":"/b"}"#), "push past 2 s",
               "no reply from \(hungPush.defaultSocket!) after 2s; check the VM is running", isError: true)
    expectTool(call(hungPush, "pull", #"{"path":"/b","local":"/a"}"#), "pull past 2 s",
               "no reply from \(hungPush.defaultSocket!) after 2s; check the VM is running", isError: true)

    let limited = try! MCPServer(defaultSocket: slowPush.defaultSocket!, allowed: ["push"], deadlines: testDeadlines)
    expect(outcome(call(limited, "push", #"{"local":"/a","path":"/b"}"#)).text == "1",
           "push under --tools push succeeds")
    expectErrorReply(call(limited, "push", #"{"local":"/a","path":"/b","t":"shell","program":"bash"}"#),
                     "push does not pass t or program on", id: 1, code: -32602,
                     message: "invalid argument program: unknown argument; push takes local, mode, path, vm")
    expect(canonical(parse(slowLog.requests.last)) == canonical(["local": "/a", "path": "/b", "t": "push"] as [String: Any]),
           "push sends only its own fields")

    print("push, pull, methods and rpc tests passed")
}

/// Reads from `client` until the peer shuts down its write side.
func readToEnd(_ client: Int32) -> [UInt8] {
    var bytes: [UInt8] = []
    var buffer = [UInt8](repeating: 0, count: 65_536)
    while true {
        let count = read(client, &buffer, buffer.count)
        if count <= 0 { break }
        bytes.append(contentsOf: buffer[..<count])
    }
    return bytes
}

/// A server whose socket is a fake shell session, with 1 s deadlines.
func shellServer(allowed: Set<String> = Set(toolNames), backlog: Int32 = 16, accepts: Bool = true,
                 _ handler: @escaping @Sendable (Int32) -> Void) -> (server: MCPServer, fake: FakeSocket) {
    let path = freshPath()
    let fake = FakeSocket(path: path, backlog: backlog, accepts: accepts, handler: handler)
    return (try! MCPServer(defaultSocket: path, allowed: allowed, deadlines: testDeadlines), fake)
}

/// A blocking client connected to `path` and never accepted by the listener.
func fillBacklog(_ path: String) -> Int32 {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = path.utf8CString
    withUnsafeMutableBytes(of: &address.sun_path) { buffer in
        for (index, byte) in bytes.enumerated() {
            buffer[index] = UInt8(bitPattern: byte)
        }
    }
    _ = withUnsafePointer(to: address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    return fd
}

/// The tools/list entries of a server, as objects.
func listedTools(_ server: MCPServer) -> [[String: Any]] {
    let reply = parse(server.handle(line: #"{"id":1,"method":"tools/list"}"#))
    return ((reply["result"] as? [String: Any])?["tools"] as? [[String: Any]]) ?? []
}

/// A shell call that must end with an isError result whose text is `text`, within 3 s of `start`.
func expectShellFailure(_ reply: String?, _ label: String, _ text: String, since start: Double) {
    let elapsed = ProcessInfo.processInfo.systemUptime - start
    let got = outcome(reply)
    expect(got.text == text && got.isError && elapsed < 3, "\(label): got \(got) after \(elapsed)s, want \(text)")
}

func shellTests() throws {
    let log = Log()
    let (echo, _) = shellServer { client in
        log.add(readRequest(client))
        let input = readToEnd(client)
        _ = writeAll(client, Array((String(decoding: input, as: UTF8.self) + #"{"ok":true,"exit":3}"# + "\n").utf8))
    }
    let echoed = outcome(call(echo, "shell", #"{"input":"echo hi","program":"bash"}"#))
    expect(!echoed.isError && echoed.text.contains("echo hi\n") && echoed.text.contains(#""exit":3"#),
           "shell echoes input and returns the status line: \(echoed)")
    expect(canonical(parse(log.requests.first)) == canonical(["t": "shell", "program": "bash"] as [String: Any]),
           "shell sends program in its request line")

    let slowLog = Log()
    let (slow, _) = shellServer { client in
        slowLog.add(readRequest(client))
        _ = readToEnd(client)
        Thread.sleep(forTimeInterval: 1.5)
        _ = writeAll(client, Array((#"{"ok":true,"exit":0}"# + "\n").utf8))
    }
    let slowStart = ProcessInfo.processInfo.systemUptime
    let slowReply = outcome(call(slow, "shell", #"{"input":"x","timeout_seconds":2}"#))
    let slowElapsed = ProcessInfo.processInfo.systemUptime - slowStart
    expect(!slowReply.isError && slowElapsed < 2.5, "timeout_seconds 2 allows a 1.5 s reply: \(slowReply) after \(slowElapsed)s")
    expect(slowLog.requests.first == #"{"t":"shell"}"#, "shell without program sends exactly {\"t\":\"shell\"}: \(slowLog.requests)")

    let start = ProcessInfo.processInfo.systemUptime
    let (writesThenHangs, _) = shellServer { client in
        _ = readRequest(client)
        _ = writeAll(client, Array("echo:x\n".utf8))
        Thread.sleep(forTimeInterval: 5)
    }
    expectShellFailure(call(writesThenHangs, "shell", #"{"input":"x","timeout_seconds":1}"#),
                       "output then a timeout", "echo:x\n" + timeoutMessage(seconds: 1), since: start)

    let defaultStart = ProcessInfo.processInfo.systemUptime
    let (neverReplies, _) = shellServer { client in
        _ = readRequest(client)
        Thread.sleep(forTimeInterval: 5)
    }
    expectShellFailure(call(neverReplies, "shell", #"{"input":"x"}"#),
                       "no timeout_seconds uses the 1 s base deadline", timeoutMessage(seconds: 1), since: defaultStart)

    let statusStart = ProcessInfo.processInfo.systemUptime
    let (statusNoClose, _) = shellServer { client in
        _ = readRequest(client)
        _ = writeAll(client, Array((#"{"ok":true,"exit":0}"# + "\n").utf8))
        Thread.sleep(forTimeInterval: 5)
    }
    expectShellFailure(call(statusNoClose, "shell", #"{"input":"x"}"#), "a status line but no close",
                       #"{"ok":true,"exit":0}"# + "\n" + timeoutMessage(seconds: 1), since: statusStart)

    // Tie-break: a valid ok:true status line that arrives at the deadline loses to the deadline.
    let tieStart = ProcessInfo.processInfo.systemUptime
    let (tieAtDeadline, _) = shellServer { client in
        _ = readRequest(client)
        _ = readToEnd(client)
        _ = writeAll(client, Array("echo:x\n".utf8))
        Thread.sleep(forTimeInterval: 1.0)
        _ = writeAll(client, Array((#"{"ok":true,"exit":0}"# + "\n").utf8))
        close(client)
    }
    // The status bytes may or may not be read before the deadline passes; either way the deadline wins.
    let tie = outcome(call(tieAtDeadline, "shell", #"{"input":"x","timeout_seconds":1}"#))
    let tieElapsed = ProcessInfo.processInfo.systemUptime - tieStart
    let tieTexts = ["echo:x\n", "echo:x\n" + #"{"ok":true,"exit":0}"# + "\n"].map { $0 + timeoutMessage(seconds: 1) }
    expect(tie.isError && tieTexts.contains(tie.text) && tieElapsed < 3,
           "an ok:true status at the deadline: got \(tie) after \(tieElapsed)s")

    let backlogStart = ProcessInfo.processInfo.systemUptime
    let (full, fullFake) = shellServer(backlog: 0, accepts: false) { _ in }
    let queued = fillBacklog(full.defaultSocket!)
    expectShellFailure(call(full, "shell", #"{"input":"x"}"#), "a full backlog",
                       timeoutMessage(seconds: 1), since: backlogStart)
    close(queued)
    expect(fullFake.connections.get() == 0, "a full backlog accepts nothing")

    let bigInput = String(repeating: "a", count: 1_048_576)
    let bigArguments = #"{"input":""# + bigInput + #""}"#
    let bigStart = ProcessInfo.processInfo.systemUptime
    let (neverReadsInput, _) = shellServer { client in
        _ = readRequest(client)
        Thread.sleep(forTimeInterval: 5)
    }
    expectShellFailure(call(neverReadsInput, "shell", bigArguments), "a 1 MiB input never read",
                       timeoutMessage(seconds: 1), since: bigStart)

    let (closesAtOnce, _) = shellServer { client in
        _ = readRequest(client)
        close(client)
    }
    expectTool(call(closesAtOnce, "shell", bigArguments), "a 1 MiB input to a session that closes at once",
               writeMessage(closesAtOnce.defaultSocket!), isError: true)

    let (exactLimit, _) = shellServer { client in
        _ = readRequest(client)
        _ = readToEnd(client)
        let status = #"{"ok":true,"exit":0}"#
        let body = String(repeating: "x", count: 1_048_576 - status.utf8.count - 1) + "\n" + status
        _ = writeAll(client, Array(body.utf8))
    }
    let exact = outcome(call(exactLimit, "shell", #"{"input":"x"}"#))
    expect(!exact.isError && exact.text.utf8.count == 1_048_576, "exactly 1 MiB with a status line succeeds")

    let (overLimit, _) = shellServer { client in
        _ = readRequest(client)
        _ = writeAll(client, Array(String(repeating: "x", count: 1_048_577).utf8))
    }
    expectTool(call(overLimit, "shell", #"{"input":"x"}"#), "1 MiB + 1 bytes with no status",
               String(repeating: "x", count: 1_048_576) + "\n" + "output truncated at 1048576 bytes; print less output", isError: true)

    let floodStart = ProcessInfo.processInfo.systemUptime
    let (flood, _) = shellServer { client in
        _ = readRequest(client)
        _ = writeAll(client, Array(String(repeating: "x", count: 2_097_152).utf8))
        _ = writeAll(client, Array((#"{"ok":true,"exit":0}"# + "\n").utf8))
    }
    let floodReply = outcome(call(flood, "shell", #"{"input":"x"}"#))
    expect(floodReply.isError && ProcessInfo.processInfo.systemUptime - floodStart < 3,
           "a stream past 1 MiB with a status line returns an error within its timeout")
    expect(floodReply.text == String(repeating: "x", count: 1_048_576) + "\n" + "output truncated at 1048576 bytes; print less output",
           "a flood keeps the first 1 MiB, then the truncated text")

    let (noSession, _) = shellServer { client in
        _ = readRequest(client)
        _ = writeAll(client, Array((#"{"ok":false,"error":"no session"}"# + "\n").utf8))
    }
    expectTool(call(noSession, "shell", #"{"input":"x"}"#), "ok:false with an error", "no session", isError: true)

    let missing = "/tmp/vmcp-gone-shell-\(getpid()).sock"
    let gone = try! MCPServer(defaultSocket: missing, allowed: Set(toolNames))
    expectTool(call(gone, "shell", #"{"input":"x"}"#), "a missing socket", connectMessage(gone.defaultSocket!), isError: true)

    let stale = freshPath()
    FileManager.default.createFile(atPath: stale, contents: nil)
    let staleServer = try! MCPServer(defaultSocket: stale, allowed: Set(toolNames))
    expectTool(call(staleServer, "shell", #"{"input":"x"}"#), "a stale socket file", connectMessage(staleServer.defaultSocket!), isError: true)
    unlink(stale)

    let (closesEmpty, _) = shellServer { client in
        _ = readRequest(client)
    }
    expectTool(call(closesEmpty, "shell", #"{"input":"x"}"#), "close with no output",
               "session ended without status", isError: true)

    let (echoNoStatus, _) = shellServer { client in
        _ = readRequest(client)
        _ = writeAll(client, Array("echo\n".utf8))
    }
    expectTool(call(echoNoStatus, "shell", #"{"input":"x"}"#), "echo then close with no status",
               "echo\nsession ended without status", isError: true)

    let (resets, _) = shellServer { client in
        _ = readRequest(client)
        _ = writeAll(client, Array("hi\n".utf8))
        // Reset only after the client's input has arrived, so a reset cannot discard output the client has not read.
        var input: UInt8 = 0
        _ = read(client, &input, 1)
        var option = linger(l_onoff: 1, l_linger: 0)
        setsockopt(client, SOL_SOCKET, SO_LINGER, &option, socklen_t(MemoryLayout<linger>.size))
    }
    expectTool(call(resets, "shell", #"{"input":"x"}"#), "a reset after output",
               "hi\nsession ended without status", isError: true)

    let (crlf, _) = shellServer { client in
        _ = readRequest(client)
        _ = writeAll(client, Array("out\r\n{\"ok\":true,\"exit\":0}\r\n".utf8))
    }
    let crlfReply = outcome(call(crlf, "shell", #"{"input":"x"}"#))
    expect(!crlfReply.isError && crlfReply.text.hasPrefix("out\r\n"), "a CRLF status line succeeds")

    let (nonBool, _) = shellServer { client in
        _ = readRequest(client)
        _ = writeAll(client, Array("{\"ok\":1}\n".utf8))
    }
    expectTool(call(nonBool, "shell", #"{"input":"x"}"#), "a status line with a non-boolean ok",
               "{\"ok\":1}\nsession ended without status", isError: true)

    let (noMessage, _) = shellServer { client in
        _ = readRequest(client)
        _ = writeAll(client, Array("out\n{\"ok\":false}\n".utf8))
    }
    expectTool(call(noMessage, "shell", #"{"input":"x"}"#), "ok:false with no error",
               "out\n" + noMessageMessage(noMessage.defaultSocket!), isError: true)

    expect(timeoutMessage(seconds: 600) == "timeout after 600s; the maximum is 600, so split the work into shorter commands",
           "the 600 s timeout text")
    expect(timeoutMessage(seconds: 30) == "timeout after 30s; raise timeout_seconds (max 600)", "the short timeout text")

    let guestLog = Log()
    let (guest, _, _) = guestFake(log: guestLog)
    let invalid: [(String, String, String)] = [
        (#"{"input":"x","timeout_seconds":0}"#, "timeout_seconds", "must be an integer from 1 to 600"),
        (#"{"input":"x","timeout_seconds":601}"#, "timeout_seconds", "must be an integer from 1 to 600"),
        (#"{"input":"x","timeout_seconds":1.5}"#, "timeout_seconds", "must be an integer from 1 to 600"),
        (#"{"input":"x","timeout_seconds":"30"}"#, "timeout_seconds", "must be an integer from 1 to 600"),
        (#"{"input":"x","timeout_seconds":true}"#, "timeout_seconds", "must be an integer from 1 to 600"),
        (#"{"input":""}"#, "input", "must be a non-empty string"),
        (#"{"input":"x","program":""}"#, "program", "must be a non-empty string"),
    ]
    for (arguments, name, rule) in invalid {
        expectErrorReply(call(guest, "shell", arguments), "shell \(arguments)", id: 1, code: -32602,
                         message: "invalid argument \(name): \(rule)")
    }
    expect(guestLog.sent("shell").isEmpty, "invalid shell arguments send no shell request")

    let (disabled, disabledFake) = shellServer(allowed: ["screenshot", "methods"]) { _ in }
    expectErrorReply(call(disabled, "shell", #"{"input":"x"}"#), "shell under --tools screenshot,methods",
                     id: 1, code: -32602, message: "tool shell is not enabled; add it to --tools")
    expect(disabledFake.connections.get() == 0, "a disabled shell makes no connection")

    let names = listedTools(try! MCPServer(defaultSocket: missing, allowed: Set(toolNames))).compactMap { $0["name"] as? String }
    expect(names == hostTools.map(\.name) + ["input", "ui", "apps", "files", "device"],
           "tools/list returns the host tools, then the group tools of the catalog, in order: \(names)")
    expect(hostTools.map(\.name) == ["screenshot", "push", "pull", "shell", "methods", "rpc"], "the host tools are in the documented order")
    let tools = listedTools(try! MCPServer(defaultSocket: missing, allowed: Set(toolNames)))
    expect(tools.allSatisfy { $0["inputSchema"] is [String: Any] }, "every tool has an inputSchema")
    for tool in tools {
        let schema = tool["inputSchema"] as? [String: Any]
        let vm = (schema?["properties"] as? [String: Any])?["vm"] as? [String: Any]
        expect(vm?["description"] as? String == "Name of a VM in the library (a directory under $VPHONE_LIBRARY_ROOT or ~/.vphone/machines)" && jsonNumber(vm?["minLength"]) == 1, "\(tool["name"] ?? "") takes vm")
        expect((schema?["required"] as? [String])?.contains("vm") == true, "\(tool["name"] ?? "") requires vm")
    }
    let described = Dictionary(uniqueKeysWithValues: tools.map { ($0["name"] as? String ?? "", $0["description"] as? String ?? "") })
    expect(described["screenshot"]?.contains("points") == true, "screenshot description mentions points")
    expect(described["shell"]?.contains("program") == true && described["shell"]?.contains("bash") == true,
           "shell description mentions program and bash")

    let narrow = listedTools(try! MCPServer(defaultSocket: missing, allowed: ["methods", "screenshot"])).compactMap { $0["name"] as? String }
    expect(narrow == ["screenshot", "methods"], "--tools methods,screenshot lists screenshot then methods")

    print("shell and tools/list tests passed")
}

/// vphoned's `guest_error` becomes `<code>: <message>` and a `hint:` line.
func guestErrorTests() throws {
    let error = #"{"code":"force_required","message":"pass force""#
    let cases: [(String, String, String)] = [
        ("hint", #"{"ok":false,"error":"refused","guest_error":\#(error),"hint":"add force:true"}}"#,
         "force_required: pass force\nhint: add force:true"),
        ("nohint", #"{"ok":false,"error":"refused","guest_error":\#(error)}}"#, "force_required: pass force"),
        ("emptyhint", #"{"ok":false,"error":"refused","guest_error":\#(error),"hint":""}}"#, "force_required: pass force"),
        ("numberhint", #"{"ok":false,"error":"refused","guest_error":\#(error),"hint":5}}"#, "force_required: pass force"),
        ("codeonly", #"{"ok":false,"error":"refused","guest_error":{"code":"x"}}"#, "refused"),
        ("messageonly", #"{"ok":false,"error":"refused","guest_error":{"message":"m"}}"#, "refused"),
        ("emptycode", #"{"ok":false,"error":"refused","guest_error":{"code":"","message":"m"}}"#, "refused"),
        ("numbercode", #"{"ok":false,"error":"refused","guest_error":{"code":1,"message":"m"}}"#, "refused"),
        ("string", #"{"ok":false,"error":"refused","guest_error":"text"}"#, "refused"),
    ]
    var table: [String: Reply] = [:]
    for (method, line, _) in cases { table["rpc:\(method)"] = Reply(line: line) }
    table["rpc:noerror"] = Reply(line: #"{"ok":false,"guest_error":{"code":"x"}}"#)
    table["rpc:badkey"] = Reply(line: #"{"ok":false,"error":"refused","guest_error":{"code":"bad_key","message":"no such key"}}"#)
    let (server, _, _) = guestFake(table)
    for (method, _, text) in cases {
        expectTool(call(server, "rpc", #"{"method":"\#(method)"}"#), "guest_error \(method)", text, isError: true)
    }
    expectTool(call(server, "rpc", #"{"method":"noerror"}"#), "guest_error without code and error",
               noMessageMessage(server.defaultSocket!), isError: true)
    expectTool(call(server, "rpc", #"{"method":"badkey"}"#), "rpc shows the guest_error text", "bad_key: no such key", isError: true)
    expectSocketError("send throws the guest_error text", "bad_key: no such key") {
        _ = try MachineSocket(path: server.defaultSocket!).send(["t": "rpc", "method": "badkey"], deadline: 1)
    }

    print("guest_error tests passed")
}

/// A tool call that must give `text` (with `isError`) within 3 s.
func expectToolWithin3s(_ label: String, _ text: String, isError: Bool = false, _ body: () -> String?) {
    let start = ProcessInfo.processInfo.systemUptime
    let got = outcome(body())
    let elapsed = ProcessInfo.processInfo.systemUptime - start
    expect(got.text == text && got.isError == isError && elapsed < 3, "\(label): got \(got) after \(elapsed)s, want \(text)")
}

/// The content blocks of a tools/call reply.
func contentBlocks(_ reply: String?) -> [[String: Any]] {
    ((parse(reply)["result"] as? [String: Any])?["content"] as? [[String: Any]]) ?? []
}

/// The rpc deadline, `timeout_ms`, the rpc-no-reply text, and image results.
func rpcDeadlineImageTests() throws {
    expect(Deadlines().base == 30 && Deadlines().long == 600 && Deadlines().rpc == 180, "Deadlines() has base 30, long 600, rpc 180")
    let (server, log, _) = guestFake([
        "rpc:slow": Reply(line: #"{"ok":true,"result":1}"#, delay: 1.5),
        "rpc:hung": Reply(line: #"{"ok":true,"result":1}"#, delay: 2.5),
        "rpc:d12": Reply(line: #"{"ok":true,"result":1}"#, delay: 1.2),
        "rpc:d18": Reply(line: #"{"ok":true,"result":1}"#, delay: 1.8),
        "rpc:fast": Reply(line: #"{"ok":true,"result":1}"#),
        "rpc:methods.list": Reply(line: #"{"ok":true}"#, delay: 1.5),
        "rpc:image": Reply(line: #"{"ok":true,"result":{"data":"AAEC","mime_type":"image/jpeg","width":2}}"#),
        "rpc:textmime": Reply(line: #"{"ok":true,"result":{"data":"AAEC","mime_type":"text/plain"}}"#),
        "rpc:emptydata": Reply(line: #"{"ok":true,"result":{"data":"","mime_type":"image/png"}}"#),
        "rpc:numberdata": Reply(line: #"{"ok":true,"result":{"data":5,"mime_type":"image/png"}}"#),
        "rpc:nomime": Reply(line: #"{"ok":true,"result":{"data":"AAEC"}}"#),
        "rpc:badbase64": Reply(line: #"{"ok":true,"result":{"data":"!!","mime_type":"image/png"}}"#),
    ])
    let path = server.defaultSocket!
    func rpcNoReply(_ seconds: Int) -> String {
        "no reply from \(path) after \(seconds)s; the guest call may still be running, so check its effect before calling again"
    }

    expectTool(call(server, "rpc", #"{"method":"slow"}"#), "rpc delayed 1.5 s with the rpc deadline of 2 s", "1")
    expectToolWithin3s("rpc delayed past 2 s", rpcNoReply(2), isError: true) {
        call(server, "rpc", #"{"method":"hung"}"#)
    }
    expectToolWithin3s("rpc timeout_ms 1000 against 1.5 s", rpcNoReply(1), isError: true) {
        call(server, "rpc", #"{"method":"slow","timeout_ms":1000}"#)
    }
    expectTool(call(server, "rpc", #"{"method":"d12","timeout_ms":1500}"#), "rpc timeout_ms 1500 against 1.2 s", "1")
    expectToolWithin3s("rpc timeout_ms 1500 against 1.8 s", rpcNoReply(1), isError: true) {
        call(server, "rpc", #"{"method":"d18","timeout_ms":1500}"#)
    }
    expectTool(call(server, "methods", "{}"), "methods past its deadline keeps no-reply",
               "no reply from \(path) after 1s; check the VM is running", isError: true)
    expectTool(call(server, "rpc", #"{"method":"hung","timeout_ms":3000}"#), "rpc timeout_ms 3000 against 2.5 s", "1")

    // A connect still pending at the rpc deadline gives rpc-no-reply too.
    let (full, fullFake) = shellServer(backlog: 0, accepts: false) { _ in }
    let queued = fillBacklog(full.defaultSocket!)
    expectToolWithin3s("rpc with a full backlog",
                       "no reply from \(full.defaultSocket!) after 1s; the guest call may still be running, so check its effect before calling again",
                       isError: true) {
        call(full, "rpc", #"{"method":"x","timeout_ms":1000}"#)
    }
    close(queued)
    expect(fullFake.connections.get() == 0, "a full backlog accepts no rpc")

    let before = log.requests.count
    for value in ["999", "180001", "1500.5", #""1000""#, "true"] {
        expectErrorReply(call(server, "rpc", #"{"method":"fast","timeout_ms":\#(value)}"#), "rpc timeout_ms \(value)", id: 1,
                         code: -32602, message: "invalid argument timeout_ms: must be an integer from 1000 to 180000")
    }
    expect(log.requests.count == before, "an invalid timeout_ms sends nothing")
    expectTool(call(server, "rpc", #"{"method":"fast","timeout_ms":1000}"#), "timeout_ms 1000 is accepted", "1")
    expectTool(call(server, "rpc", #"{"method":"fast","timeout_ms":180000}"#), "timeout_ms 180000 is accepted", "1")
    expect(log.sent("rpc").allSatisfy { $0["timeout_ms"] == nil }, "the fake receives no timeout_ms key")

    let image = contentBlocks(call(server, "rpc", #"{"method":"image"}"#))
    expect(canonical(image) == canonical([
        ["type": "image", "data": "AAEC", "mimeType": "image/jpeg"],
        ["type": "text", "text": #"{"mime_type":"image/jpeg","width":2}"#],
    ] as [[String: Any]]) && outcome(call(server, "rpc", #"{"method":"image"}"#)).isError == false,
           "an image rpc result is image content and a caption: \(image)")
    let plain: [(String, String)] = [
        ("textmime", #"{"data":"AAEC","mime_type":"text/plain"}"#),
        ("emptydata", #"{"data":"","mime_type":"image/png"}"#),
        ("numberdata", #"{"data":5,"mime_type":"image/png"}"#),
        ("nomime", #"{"data":"AAEC"}"#),
        ("badbase64", #"{"data":"!!","mime_type":"image/png"}"#),
    ]
    for (method, text) in plain {
        let reply = call(server, "rpc", #"{"method":"\#(method)"}"#)
        expect(contentBlocks(reply).count == 1, "\(method) has no image block")
        expectTool(reply, "\(method) returns the whole result as text", text)
    }

    let rpc = listedTools(server).first { $0["name"] as? String == "rpc" } ?? [:]
    let timeout = ((rpc["inputSchema"] as? [String: Any])?["properties"] as? [String: Any])?["timeout_ms"] as? [String: Any] ?? [:]
    expect(jsonNumber(timeout["minimum"]) == 1000 && jsonNumber(timeout["maximum"]) == 180000,
           "the rpc schema lists timeout_ms 1000 to 180000")
    let description = rpc["description"] as? String ?? ""
    expect(description.contains("timeout_ms") && description.contains("180000"), "the rpc description names timeout_ms and 180000")

    print("rpc deadline and image tests passed")
}

/// The `methods` filter by `prefix` and `method`, run in the server.
func methodsFilterTests() throws {
    let list = #"{"methods":[{"name":"ui.tap"},{"name":"ui.wait"},{"name":"device.screen"},5,{"name":7}]}"#
    let (server, log, _) = guestFake(["rpc:methods.list": Reply(line: #"{"ok":true,"result":\#(list)}"#)])
    expectTool(call(server, "methods", "{}"), "methods without a filter", list)
    let cases: [(String, String)] = [
        (#"{"prefix":"ui."}"#, #"{"methods":[{"name":"ui.tap"},{"name":"ui.wait"}]}"#),
        (#"{"method":"ui.wait"}"#, #"{"methods":[{"name":"ui.wait"}]}"#),
        (#"{"prefix":"ui.","method":"device.screen"}"#, #"{"methods":[]}"#),
        (#"{"prefix":"zz"}"#, #"{"methods":[]}"#),
    ]
    for (arguments, text) in cases {
        let before = log.requests.count
        expectTool(call(server, "methods", arguments), "methods \(arguments)", text)
        expect(log.requests.count == before + 1
               && canonical(parse(log.requests.last)) == canonical(["t": "rpc", "method": "methods.list"] as [String: Any]),
               "methods \(arguments) sends exactly methods.list")
    }

    let (flat, _, _) = guestFake(["rpc:methods.list": Reply(line: #"{"ok":true,"result":[{"name":"tap"}]}"#)])
    expectTool(call(flat, "methods", #"{"prefix":"t"}"#), "a result that is not an object is unchanged", #"[{"name":"tap"}]"#)

    let before = log.requests.count
    for (arguments, name) in [(#"{"prefix":""}"#, "prefix"), (#"{"prefix":5}"#, "prefix"), (#"{"method":""}"#, "method")] {
        expectErrorReply(call(server, "methods", arguments), "methods \(arguments)", id: 1, code: -32602,
                         message: "invalid argument \(name): must be a non-empty string")
    }
    expect(log.requests.count == before, "invalid methods arguments send nothing")

    let methods = listedTools(server).first { $0["name"] as? String == "methods" } ?? [:]
    let properties = (methods["inputSchema"] as? [String: Any])?["properties"] as? [String: Any] ?? [:]
    expect(properties["prefix"] != nil && properties["method"] != nil, "the methods schema lists prefix and method")
    expect((methods["description"] as? String)?.contains("prefix") == true, "the methods description names prefix")

    print("methods filter tests passed")
}

/// Each tools/list entry carries exactly its annotations.
func annotationTests() throws {
    let readOnly: [String: Bool] = ["readOnlyHint": true, "openWorldHint": false]
    let files: [String: Bool] = ["readOnlyHint": false, "destructiveHint": true, "openWorldHint": false]
    let guest: [String: Bool] = ["readOnlyHint": false, "destructiveHint": true, "idempotentHint": false, "openWorldHint": true]
    let mutating: [String: Bool] = ["readOnlyHint": false, "idempotentHint": false, "destructiveHint": false]
    let destructive: [String: Bool] = ["readOnlyHint": false, "idempotentHint": false, "destructiveHint": true]
    let want: [String: [String: Bool]] = [
        "screenshot": readOnly, "methods": readOnly, "push": files, "pull": files, "rpc": guest, "shell": guest,
        "input": mutating, "ui": readOnly, "apps": destructive, "files": destructive, "device": readOnly,
    ]
    let (_, _, fake) = guestFake(catalogTable)
    let tools = listedTools(try! MCPServer(defaultSocket: fake.path, allowed: Set(toolNames), deadlines: testDeadlines))
    expect(tools.count == 11, "tools/list lists eleven tools under the fixture catalog: \(tools.count)")
    for tool in tools {
        let name = tool["name"] as? String ?? ""
        expect(canonical(tool["annotations"]) == canonical(want[name]), "\(name) annotations: got \(canonical(tool["annotations"]))")
    }
    let narrow = listedTools(try! MCPServer(defaultSocket: fake.path, allowed: ["input", "screenshot"], deadlines: testDeadlines))
    expect(narrow.compactMap { $0["name"] as? String } == ["screenshot", "input"], "--tools input,screenshot lists screenshot then input")
    let reading = listedTools(try! MCPServer(defaultSocket: fake.path, profile: .readonly, deadlines: testDeadlines))
    expect(reading.first { $0["name"] as? String == "files" }.map { canonical($0["annotations"]) } == canonical(readOnly),
           "under readonly, files offers only its read action and is read-only")
    print("annotation tests passed")
}

/// Every tool rejects an argument its schema does not list, naming it, and sends nothing.
/// A coded error from a push or pull keeps its code and hint.
func unknownArgumentTests() throws {
    let log = Log()
    let (server, _, _) = guestFake(log: log)
    let cases: [(tool: String, arguments: String, unknown: String, takes: String)] = [
        ("screenshot", #"{"path":"/x"}"#, "path", "vm"),
        ("push", #"{"local":"/a","path":"/b","force":true}"#, "force", "local, mode, path, vm"),
        ("pull", #"{"path":"/a","local":"/b","mode":"755"}"#, "mode", "local, path, vm"),
        ("methods", #"{"prefx":"ui."}"#, "prefx", "method, prefix, vm"),
        ("rpc", #"{"method":"device.screen","param":1}"#, "param", "method, params, timeout_ms, vm"),
        ("shell", #"{"input":"ls","cwd":"/"}"#, "cwd", "input, program, timeout_seconds, vm"),
    ]
    for item in cases {
        expectErrorReply(call(server, item.tool, item.arguments), "\(item.tool) rejects \(item.unknown)", id: 1, code: -32602,
                         message: "invalid argument \(item.unknown): unknown argument; \(item.tool) takes \(item.takes)")
    }
    expect(log.requests.isEmpty, "no request is sent for an unknown argument: \(log.requests)")
    expectErrorReply(call(server, "rpc", #"{"param":1,"method":2,"also":3}"#), "the first unknown name in order", id: 1,
                     code: -32602, message: "invalid argument also: unknown argument; rpc takes method, params, timeout_ms, vm")

    let refusal = #"{"ok":false,"error":"refused","guest_error":{"code":"not_found","message":"no such file","hint":"check the path"}}"#
    let (coded, _, _) = guestFake(["pull": Reply(line: refusal), "push": Reply(line: refusal)])
    expectTool(call(coded, "pull", #"{"path":"/a","local":"/tmp/b"}"#), "pull keeps code and hint",
               "not_found: no such file\nhint: check the path", isError: true)
    expectTool(call(coded, "push", #"{"local":"/tmp/a","path":"/b"}"#), "push keeps code and hint",
               "not_found: no such file\nhint: check the path", isError: true)

    print("unknown argument tests passed")
}

/// A guest catalog: five usable areas, and entries the server must ignore (the two host-tool
/// methods, an unknown area, a missing access, an unknown parameter type).
let catalogJSON = #"""
{"methods":[
{"name":"input.tap","description":"Tap at a point.","area":"input","access":"mutating","force":"never","params":[{"name":"x","type":"number","required":true,"description":"X in points","minimum":0,"maximum":10000},{"name":"y","type":"number","required":true,"description":"Y in points","minimum":0,"maximum":10000},{"name":"observe","type":"boolean","required":false,"description":"Attach the screen"}],"result":[{"name":"sent","type":"boolean","required":true}]},
{"name":"input.type","description":"Type text.","area":"input","access":"mutating","force":"never","params":[{"name":"text","type":"string","required":true,"description":"Text to type"}]},
{"name":"ui.elements","description":"List elements.","area":"ui","access":"read","force":"never","params":[{"name":"limit","type":"integer","required":false,"description":"Rows","minimum":1,"maximum":100,"default":10},{"name":"mode","type":"string","required":false,"description":"Mode","enum":["tree","flat"]}],"result":[{"name":"total","type":"integer","required":true},{"name":"elements","type":"array","required":true}]},
{"name":"apps.uninstall","description":"Remove an app.","area":"apps","access":"destructive","force":"always","force_action":"Pass force true to remove the app.","params":[{"name":"bundle_id","type":"string","required":true,"description":"Bundle id"}]},
{"name":"files.list","description":"List a directory.","area":"files","access":"read","force":"never","params":[{"name":"path","type":"string","required":true,"description":"Directory"}]},
{"name":"files.delete","description":"Delete a path.","area":"files","access":"destructive","force":"when:recursive","force_action":"Pass force true to delete a directory.","params":[{"name":"path","type":"string","required":true,"description":"Path"},{"name":"recursive","type":"boolean","required":false,"description":"Recurse"}]},
{"name":"device.info","description":"Device info.","area":"device","access":"read","force":"never","params":[]},
{"name":"screen.screenshot","description":"x","area":"ui","access":"read","force":"never","params":[]},
{"name":"methods.list","description":"x","area":"system","access":"read","force":"never","params":[]},
{"name":"odd.area","description":"x","area":"bogus","access":"read","force":"never","params":[]},
{"name":"odd.access","description":"x","area":"system","force":"never","params":[]},
{"name":"odd.param","description":"x","area":"system","access":"read","force":"never","params":[{"name":"p","type":"weird"}]}
]}
"""#

let catalogTable: [String: Reply] = [
    "rpc:input.tap": Reply(line: #"{"ok":true,"result":{"sent":true}}"#),
    "rpc:input.type": Reply(line: #"{"ok":true,"result":{}}"#),
    "rpc:ui.elements": Reply(line: #"{"ok":true,"result":{"total":0,"elements":[]}}"#),
    "rpc:apps.uninstall": Reply(line: #"{"ok":true,"result":{"removed":true}}"#),
    "rpc:files.list": Reply(line: #"{"ok":true,"result":{"names":[]}}"#),
    "rpc:files.delete": Reply(line: #"{"ok":true,"result":{"deleted":true}}"#),
    "rpc:device.info": Reply(line: #"{"ok":true,"result":{"model":"x"}}"#),
]

func toolNamesListed(_ server: MCPServer) -> [String] {
    listedTools(server).compactMap { $0["name"] as? String }
}

/// The rpc requests a fake saw.
func guestRequests(_ log: Log) -> [[String: Any]] {
    log.sent("rpc")
}

func groupToolTests() throws {
    let log = Log()
    let (server, _, fake) = guestFake(catalogTable, log: log)
    let tools = listedTools(server)
    let names = tools.compactMap { $0["name"] as? String }
    expect(names == ["screenshot", "push", "pull", "shell", "methods", "rpc", "input", "ui", "apps", "files", "device"],
           "the group tools follow the host tools in area order, and empty areas are left out: \(names)")
    expect(fake.connections.get() == 0, "tools/list makes no socket request")

    let input = tools.first { $0["name"] as? String == "input" } ?? [:]
    let schema = input["inputSchema"] as? [String: Any] ?? [:]
    let properties = schema["properties"] as? [String: Any] ?? [:]
    let branches = schema["oneOf"] as? [[String: Any]] ?? []
    expect(Set(properties.keys) == ["action", "vm", "x", "y", "observe", "text"], "input lists every parameter: \(properties.keys.sorted())")
    expect(canonical((properties["action"] as? [String: Any])?["enum"]) == canonical(["input.tap", "input.type"]), "the action enum lists the actions")
    expect(canonical(schema["required"]) == canonical(["vm", "action"]) && (schema["additionalProperties"] as? Bool) == false,
           "vm and action are the only required properties, and unknown properties are refused")
    expect(branches.count == 2, "input has one branch per action")
    let tap = branches[0]
    let tapProperties = tap["properties"] as? [String: Any] ?? [:]
    expect(canonical(tapProperties["action"]) == canonical(["const": "input.tap"]), "a branch fixes its action")
    expect(canonical(tap["required"]) == canonical(["action", "x", "y"]), "a branch requires its required parameters")
    let x = properties["x"] as? [String: Any] ?? [:]
    expect(canonical(tapProperties["x"]) == "{}", "a parameter every action defines the same way is defined once, at the top level, and listed as {} in a branch")
    expect(x["type"] as? String == "number" && jsonNumber(x["minimum"]) == 0 && jsonNumber(x["maximum"]) == 10000
           && x["description"] as? String == "X in points", "x keeps its type, limits and description")
    expect(tapProperties["force"] == nil && (tap["additionalProperties"] as? Bool) == false, "a branch without force has no force property")

    let ui = (tools.first { $0["name"] as? String == "ui" }?["inputSchema"] as? [String: Any])?["properties"] as? [String: Any] ?? [:]
    let limit = ui["limit"] as? [String: Any] ?? [:]
    expect(limit["type"] as? String == "integer" && jsonNumber(limit["default"]) == 10 && jsonNumber(limit["minimum"]) == 1
           && jsonNumber(limit["maximum"]) == 100, "limit keeps type, default and limits")
    expect(canonical((ui["mode"] as? [String: Any])?["enum"]) == canonical(["tree", "flat"]), "mode keeps its enum")
    let uiDescription = tools.first { $0["name"] as? String == "ui" }?["description"] as? String ?? ""
    expect(uiDescription.contains("ui.elements: List elements.") && !uiDescription.contains("Returns"), "the description lists the action and no result keys")
    expect(!uiDescription.contains("screen.screenshot"), "screen.screenshot is not a group action")

    let apps = (tools.first { $0["name"] as? String == "apps" }?["inputSchema"] as? [String: Any])?["properties"] as? [String: Any] ?? [:]
    let force = apps["force"] as? [String: Any] ?? [:]
    expect(force["type"] as? String == "boolean" && force["description"] as? String == "Required to confirm a destructive action",
           "force is a boolean that says it confirms a destructive action")
    expect((tools.first { $0["name"] as? String == "apps" }?["description"] as? String ?? "").contains("apps.uninstall: Remove an app. Needs force."),
           "an action that needs force says so")
    expect((tools.first { $0["name"] as? String == "files" }?["description"] as? String ?? "").contains("files.delete: Delete a path. Needs force when recursive is true."),
           "a conditional force names the parameter")
    let filesProperties = (tools.first { $0["name"] as? String == "files" }?["inputSchema"] as? [String: Any])?["oneOf"] as? [[String: Any]] ?? []
    expect((filesProperties[1]["properties"] as? [String: Any])?["force"] == nil
           && (filesProperties[0]["properties"] as? [String: Any])?["force"] != nil, "force only appears in the branches of actions that take it")
    let uiProperties = ui
    expect(uiProperties["force"] == nil, "an area with no force action has no top-level force property")
    expect((tools.first { $0["name"] as? String == "files" }?["inputSchema"] as? [String: Any]).flatMap { ($0["properties"] as? [String: Any])?["force"] } != nil,
           "an area with a force action has a top-level force property")

    expectTool(call(server, "input", #"{"action":"input.tap","x":1,"y":2}"#), "a group call", #"{"sent":true}"#)
    expect(canonical(guestRequests(log).last) == canonical(
        ["t": "rpc", "method": "input.tap", "params": ["x": 1, "y": 2] as [String: Any]] as [String: Any]),
           "a group call sends the method and its parameters only")
    expectTool(call(server, "ui", #"{"action":"ui.elements","limit":5,"mode":"flat"}"#), "ui.elements", #"{"elements":[],"total":0}"#)
    expectTool(call(server, "apps", #"{"action":"apps.uninstall","bundle_id":"a.b","force":true}"#), "a forced call", #"{"removed":true}"#)
    expect(canonical(guestRequests(log).last) == canonical(
        ["t": "rpc", "method": "apps.uninstall", "params": ["bundle_id": "a.b", "force": true] as [String: Any]] as [String: Any]),
           "force goes to the guest with the parameters")
    expectTool(call(server, "device", #"{"action":"device.info"}"#), "an action without parameters", #"{"model":"x"}"#)
    expectTool(call(server, "files", #"{"action":"files.list","path":"/"}"#), "files.list", #"{"names":[]}"#)

    let before = guestRequests(log).count
    let allowedInput = "input.tap, input.type"
    let bad: [(String, String, String)] = [
        ("input", "{}", "invalid argument action: missing"),
        ("input", #"{"action":"nope"}"#, "invalid argument action: must be one of \(allowedInput)"),
        ("input", #"{"action":5}"#, "invalid argument action: must be one of \(allowedInput)"),
        ("input", #"{"action":"ui.elements"}"#, "invalid argument action: must be one of \(allowedInput)"),
        ("input", #"{"action":"input.tap","x":1}"#, "invalid argument y: missing for input.tap"),
        ("input", #"{"action":"input.tap","x":"1","y":2}"#, "invalid argument x: must be a number"),
        ("input", #"{"action":"input.tap","x":true,"y":2}"#, "invalid argument x: must be a number"),
        ("input", #"{"action":"input.tap","x":10001,"y":2}"#, "invalid argument x: must be from 0 to 10000"),
        ("input", #"{"action":"input.tap","x":-1,"y":2}"#, "invalid argument x: must be from 0 to 10000"),
        ("input", #"{"action":"input.tap","x":1,"y":2,"observe":1}"#, "invalid argument observe: must be a boolean"),
        ("input", #"{"action":"input.tap","x":1,"y":2,"z":3}"#,
         "invalid argument z: unknown argument for input.tap; input.tap takes action, observe, vm, x, y"),
        ("input", #"{"action":"input.type","text":"a","force":true}"#,
         "invalid argument force: unknown argument for input.type; input.type takes action, text, vm"),
        ("input", #"{"action":"input.type","text":5}"#, "invalid argument text: must be a string"),
        ("ui", #"{"action":"ui.elements","limit":1.5}"#, "invalid argument limit: must be an integer"),
        ("ui", #"{"action":"ui.elements","limit":0}"#, "invalid argument limit: must be from 1 to 100"),
        ("ui", #"{"action":"ui.elements","mode":"x"}"#, "invalid argument mode: must be one of tree, flat"),
        ("apps", #"{"action":"apps.uninstall","bundle_id":"a","force":"yes"}"#, "invalid argument force: must be a boolean"),
        ("files", #"{"action":"files.delete","path":"/x","recursive":"yes"}"#, "invalid argument recursive: must be a boolean"),
    ]
    for (name, arguments, message) in bad {
        expectErrorReply(call(server, name, arguments), "\(name) \(arguments)", id: 1, code: -32602, message: message)
    }
    expect(guestRequests(log).count == before, "invalid group arguments send no guest request")

    // A guest refusal passes through, so the guest stays the authority.
    let (refusing, _, _) = guestFake(catalogTable.merging([
        "rpc:input.tap": Reply(line: #"{"ok":false,"error":"refused","guest_error":{"code":"bad_point","message":"off screen","hint":"stay inside"}}"#),
    ]) { _, new in new })
    expectTool(call(refusing, "input", #"{"action":"input.tap","x":1,"y":2}"#), "a guest refusal", "bad_point: off screen\nhint: stay inside", isError: true)

    // The deadline: the rpc deadline, and a longer one for an action's own timeout_ms.
    let slowTable = catalogTable.merging([
        "rpc:input.type": Reply(line: #"{"ok":true,"result":{"slow":true}}"#, delay: 2.5),
    ]) { _, new in new }
    let (slow, _, _) = guestFake(slowTable)
    expectToolWithin3s("a group call past the rpc deadline", "no reply from \(slow.defaultSocket!) after 2s; the guest call may still be running, so check its effect before calling again", isError: true) {
        call(slow, "input", #"{"action":"input.type","text":"a"}"#)
    }

    // A method the guest build lacks is answered by the guest, not refused by the server.
    let (older, _, _) = guestFake(["rpc:input.tap": Reply(line: #"{"ok":false,"error":"refused","guest_error":{"code":"not_found","message":"Unknown method"}}"#)])
    expectTool(call(older, "input", #"{"action":"input.tap","x":1,"y":2}"#), "a guest without the method", "not_found: Unknown method", isError: true)
    print("group tool tests passed")
}

func profileTests() throws {
    let liar: [String: Any] = ["methods": [["name": "files.wipe", "area": "files", "access": "read", "force": "always"] as [String: Any]]]
    expect(Catalog.parse(liar)?.methods.first?.access == .destructive, "an entry with a force is destructive whatever access it reports")
    let log = Log()
    let (_, _, fake) = guestFake(catalogTable, log: log)
    func server(_ profile: Profile, allowed: Set<String> = Set(toolNames)) -> MCPServer {
        try! MCPServer(defaultSocket: fake.path, profile: profile, allowed: allowed, deadlines: testDeadlines)
    }
    expect(toolNamesListed(server(.full)) == ["screenshot", "push", "pull", "shell", "methods", "rpc", "input", "ui", "apps", "files", "device"],
           "full lists everything")
    expect(toolNamesListed(server(.standard)) == ["screenshot", "methods", "input", "ui", "files", "device"],
           "standard drops the destructive host tools and the tools with only destructive actions")
    expect(toolNamesListed(server(.readonly)) == ["screenshot", "methods", "ui", "files", "device"],
           "readonly keeps only the tools with a read action")
    expect(toolNamesListed(server(.standard, allowed: ["input", "shell"])) == ["input"], "--tools and the profile both apply")

    let filesActions = { (profile: Profile) -> [String] in
        let schema = listedTools(server(profile)).first { $0["name"] as? String == "files" }?["inputSchema"] as? [String: Any]
        return (((schema?["properties"] as? [String: Any])?["action"] as? [String: Any])?["enum"] as? [String]) ?? []
    }
    expect(filesActions(.full) == ["files.delete", "files.list"], "full offers both files actions, sorted by method name")
    expect(filesActions(.standard) == ["files.list"] && filesActions(.readonly) == ["files.list"], "files.delete is left out of standard and readonly")

    let before = log.requests.count
    let standard = server(.standard)
    let readonly = server(.readonly)
    let wider = "start vphone-mcp with a wider --profile"
    expectErrorReply(call(readonly, "shell", #"{"input":"x"}"#), "shell under readonly", id: 1, code: -32602,
                     message: "tool shell is not available in profile readonly; \(wider)")
    expectErrorReply(call(standard, "rpc", #"{"method":"x"}"#), "rpc under standard", id: 1, code: -32602,
                     message: "tool rpc is not available in profile standard; \(wider)")
    expectErrorReply(call(standard, "push", #"{"local":"/a","path":"/b"}"#), "push under standard", id: 1, code: -32602,
                     message: "tool push is not available in profile standard; \(wider)")
    expectErrorReply(call(standard, "apps", #"{"action":"apps.uninstall","bundle_id":"a","force":true}"#), "apps under standard", id: 1,
                     code: -32602, message: "tool apps is not available in profile standard; \(wider)")
    expectErrorReply(call(readonly, "input", #"{"action":"input.tap","x":1,"y":2}"#), "input under readonly", id: 1, code: -32602,
                     message: "tool input is not available in profile readonly; \(wider)")
    expectErrorReply(call(standard, "files", #"{"action":"files.delete","path":"/x"}"#), "files.delete under standard", id: 1, code: -32602,
                     message: "invalid argument action: must be one of files.list")
    expectErrorReply(call(readonly, "files", #"{"action":"files.delete","path":"/x"}"#), "files.delete under readonly", id: 1, code: -32602,
                     message: "invalid argument action: must be one of files.list")
    expectErrorReply(call(server(.full, allowed: ["files"]), "input", #"{"action":"input.tap"}"#), "input outside --tools", id: 1, code: -32602,
                     message: "tool input is not enabled; add it to --tools")
    expect(guestRequests(log).isEmpty && log.requests.count >= before, "a refused call sends nothing to the guest")
    expectTool(call(standard, "files", #"{"action":"files.list","path":"/"}"#), "a read action under standard", #"{"names":[]}"#)
    expectTool(call(standard, "input", #"{"action":"input.tap","x":1,"y":2}"#), "a mutating action under standard", #"{"sent":true}"#)
    print("profile tests passed")
}

func vmArgumentTests() throws {
    let root = "/tmp/vmcp-lib-\(getpid())"
    try? FileManager.default.removeItem(atPath: root)
    defer { try? FileManager.default.removeItem(atPath: root) }
    for name in ["a", "b", "c"] {
        try FileManager.default.createDirectory(atPath: "\(root)/\(name)", withIntermediateDirectories: true)
    }
    func guest(_ name: String) -> FakeSocket {
        let table: [String: Reply] = [
            "rpc:device.info": Reply(line: #"{"ok":true,"result":{"model":"\#(name)"}}"#),
            "rpc:input.tap": Reply(line: #"{"ok":true,"result":{"sent":"\#(name)"}}"#),
        ]
        return FakeSocket(path: "\(root)/\(name)/vphone.sock", handler: tableHandler(table))
    }
    let a = guest("a")
    let b = guest("b")
    let env = ["VPHONE_LIBRARY_ROOT": root]
    let server = try! MCPServer(deadlines: testDeadlines, env: env, catalogJSON: catalogJSON)
    let fresh0 = try! MCPServer(deadlines: testDeadlines, env: env, catalogJSON: catalogJSON)

    expect(toolNamesListed(server) == ["screenshot", "push", "pull", "shell", "methods", "rpc", "input", "ui", "apps", "files", "device"],
           "the tools come from the catalog")
    expect(a.connections.get() == 0 && b.connections.get() == 0, "tools/list contacted no VM")

    expectTool(call(server, "device", #"{"action":"device.info","vm":"a"}"#), "vm a", #"{"model":"a"}"#)
    expectTool(call(server, "device", #"{"action":"device.info","vm":"b"}"#), "vm b", #"{"model":"b"}"#)
    expectTool(call(server, "input", #"{"action":"input.tap","x":1,"y":2,"vm":"a"}"#), "vm with a mutating action", #"{"sent":"a"}"#)
    expectTool(call(server, "rpc", #"{"method":"device.info","vm":"b"}"#), "rpc with vm", #"{"model":"b"}"#)
    expectTool(call(server, "device", #"{"action":"device.info","vm":"c"}"#), "a VM that is not running", notRunningMessage("c"), isError: true)
    expectTool(call(server, "device", #"{"action":"device.info","vm":"zz"}"#), "an unknown VM", unknownVMMessage("zz", root), isError: true)
    expectTool(call(server, "screenshot", #"{"vm":"zz"}"#), "screenshot with an unknown VM", unknownVMMessage("zz", root), isError: true)
    for value in [#""../x""#, #""""#, "5", #"".""#, #""a/b""#] {
        expectErrorReply(call(server, "device", #"{"action":"device.info","vm":\#(value)}"#), "vm \(value)", id: 1, code: -32602,
                         message: "invalid argument vm: must be a valid vm name (one directory name, no /)")
    }

    // A call without vm is refused, for every tool, and no socket is contacted.
    let beforeMissing = a.connections.get() + b.connections.get()
    for name in toolNames {
        expectErrorReply(callRaw(fresh0, name, "{}"), "\(name) without vm", id: 1, code: -32602, message: "invalid argument vm: missing")
    }
    expect(a.connections.get() + b.connections.get() == beforeMissing, "no socket was contacted for a missing vm")

    // A bad or unknown vm is refused without contacting a socket.
    let fresh = try! MCPServer(deadlines: testDeadlines, env: env, catalogJSON: catalogJSON)
    let before = a.connections.get() + b.connections.get()
    expectErrorReply(call(fresh, "device", #"{"action":"device.info","vm":".."}"#), "vm ..", id: 1, code: -32602,
                     message: "invalid argument vm: must be a valid vm name (one directory name, no /)")
    expectTool(call(fresh, "device", #"{"action":"device.info","vm":"zz"}"#), "unknown vm", unknownVMMessage("zz", root), isError: true)
    expect(a.connections.get() + b.connections.get() == before, "no socket was contacted for a bad vm")

    // Several VMs at once, each call on its own connection.
    let results = Text()
    let group = DispatchGroup()
    let collected = Log()
    for index in 0..<8 {
        group.enter()
        Thread.detachNewThread {
            let name = index % 2 == 0 ? "a" : "b"
            let mine = try! MCPServer(deadlines: testDeadlines, env: env, catalogJSON: catalogJSON)
            let text = outcome(call(mine, "rpc", #"{"method":"device.info","vm":"\#(name)"}"#)).text
            collected.add("\(name)=\(text)")
            group.leave()
        }
    }
    group.wait()
    results.set(collected.requests.sorted().joined(separator: ";"))
    expect(results.get() == (["a", "b"].flatMap { name in Array(repeating: "\(name)=\(#"{"model":"\#(name)"}"#)", count: 4) }).joined(separator: ";"),
           "eight concurrent calls on two VMs each reach their own VM: \(results.get())")
    print("vm argument tests passed")
}

/// A small catalog: `device.wait` takes `timeout_ms`, `ui.snap` returns an image.
let smallCatalog = #"{"methods":[{"name":"ui.snap","description":"Snap.","area":"ui","access":"read","force":"never","params":[]},"#
    + #"{"name":"device.wait","description":"Wait.","area":"device","access":"read","force":"never","params":[{"name":"timeout_ms","type":"integer","required":false,"description":"ms"}]}]}"#

func catalogReply(_ result: String) -> Reply { Reply(line: #"{"ok":true,"result":"# + result + "}") }

func vmOrderTests() throws {
    // (a) vm is checked before the host tool's unknown-argument check and before action.
    let (held, _, _) = guestFake(catalogTable)
    _ = listedTools(held)
    expectErrorReply(callRaw(held, "shell", #"{"timeout_seconds":0}"#), "shell without vm", id: 1, code: -32602,
                     message: "invalid argument vm: missing")
    expectErrorReply(callRaw(held, "push", #"{"bogus":1}"#), "push with an unknown key and no vm", id: 1, code: -32602,
                     message: "invalid argument vm: missing")
    expectErrorReply(callRaw(held, "device", "{}"), "group call with neither vm nor action", id: 1, code: -32602,
                     message: "invalid argument vm: missing")
    expectErrorReply(call(held, "device", #"{"action":"nope"}"#), "invalid action with vm", id: 1, code: -32602,
                     message: "invalid argument action: must be one of device.info")

    let root = "/tmp/vmcp-order-\(getpid())"
    try? FileManager.default.removeItem(atPath: root)
    defer { try? FileManager.default.removeItem(atPath: root) }
    for name in ["a", "b", "c"] {
        try FileManager.default.createDirectory(atPath: "\(root)/\(name)", withIntermediateDirectories: true)
    }
    let env = ["VPHONE_LIBRARY_ROOT": root]

    // (b) tools/list is the same with no VM, with VMs present and with a missing library, and sends no request.
    let logA = Log(), logB = Log()
    let a1 = FakeSocket(path: "\(root)/a/vphone.sock", handler: tableHandler(catalogTable, log: logA))
    let b1 = FakeSocket(path: "\(root)/b/vphone.sock", handler: tableHandler(catalogTable, log: logB))
    let withVMs = try! MCPServer(deadlines: testDeadlines, env: env, catalogJSON: catalogJSON)
    let withoutVMs = try! MCPServer(deadlines: testDeadlines, env: ["VPHONE_LIBRARY_ROOT": "/tmp/vmcp-nonexistent-\(getpid())"], catalogJSON: catalogJSON)
    let listLine = #"{"id":1,"method":"tools/list"}"#
    expect(withVMs.handle(line: listLine) == withoutVMs.handle(line: listLine), "tools/list is identical with and without VMs")
    expect(a1.connections.get() == 0 && b1.connections.get() == 0 && logA.requests.isEmpty && logB.requests.isEmpty,
           "tools/list contacted no VM")

    // (c) A group call naming b asks b only, with the method itself.
    expectTool(call(withVMs, "device", #"{"action":"device.info","vm":"b"}"#), "group call naming b", #"{"model":"x"}"#)
    expect(a1.connections.get() == 0 && logA.requests.isEmpty, "a was not contacted")
    expect(logB.sent("rpc").map { $0["method"] as? String ?? "" } == ["device.info"], "b got only the method")

    // (f) Every tool describes vm as a library entry.
    for tool in listedTools(held) {
        let vm = ((tool["inputSchema"] as? [String: Any])?["properties"] as? [String: Any])?["vm"] as? [String: Any]
        let text = vm?["description"] as? String ?? ""
        expect(!text.isEmpty && text.contains("library"), "\(tool["name"] ?? "") vm description names the library")
    }
    // (g) Group order: vm, profile by actions, then action.
    let rootG = "/tmp/vmcp-order3-\(getpid())"
    try? FileManager.default.removeItem(atPath: rootG)
    defer { try? FileManager.default.removeItem(atPath: rootG) }
    for name in ["a", "b"] {
        try FileManager.default.createDirectory(atPath: "\(rootG)/\(name)", withIntermediateDirectories: true)
    }
    let envG = ["VPHONE_LIBRARY_ROOT": rootG]
    let logGA = Log(), logGB = Log()
    let ga = FakeSocket(path: "\(rootG)/a/vphone.sock", handler: tableHandler(catalogTable, log: logGA))
    _ = FakeSocket(path: "\(rootG)/b/vphone.sock", handler: tableHandler(catalogTable, log: logGB))
    func fresh(_ profile: Profile = .full) -> MCPServer { try! MCPServer(profile: profile, deadlines: testDeadlines, env: envG, catalogJSON: catalogJSON) }
    expectErrorReply(callRaw(fresh(.readonly), "apps", #"{"action":"apps.uninstall","vm":"a"}"#), "readonly, valid vm, no allowed action", id: 1,
                     code: -32602, message: notInProfileMessage("apps", "readonly"))
    expectTool(callRaw(fresh(.readonly), "apps", #"{"action":"apps.uninstall","vm":"nosuch"}"#), "readonly, unknown vm",
               "unknown vm nosuch; \(rootG) has no such directory; use the name of a directory in \(rootG)", isError: true)
    expectErrorReply(callRaw(fresh(.readonly), "apps", #"{"action":"apps.uninstall"}"#), "readonly, no vm", id: 1, code: -32602,
                     message: "invalid argument vm: missing")
    expectErrorReply(callRaw(fresh(), "device", #"{"action":"nope","vm":"a"}"#), "invalid action", id: 1, code: -32602,
                     message: "invalid argument action: must be one of device.info")
    expect(logGA.requests.isEmpty, "none of these sent a request")

    // (h) A host tool without vm sends nothing, even with an answering VM in the library.
    let before = ga.connections.get()
    for tool in hostTools {
        expectErrorReply(callRaw(fresh(), tool.name, "{}"), "\(tool.name) without vm", id: 1, code: -32602, message: "invalid argument vm: missing")
    }
    expect(ga.connections.get() == before && logGA.requests.isEmpty, "no host tool without vm touched a socket")

    // (i) Exact vm messages.
    expectTool(callRaw(fresh(), "device", #"{"action":"device.info","vm":"nosuch"}"#), "unknown vm",
               "unknown vm nosuch; \(rootG) has no such directory; use the name of a directory in \(rootG)", isError: true)
    expectErrorReply(callRaw(fresh(), "device", #"{"action":"device.info","vm":"a/b"}"#), "vm a/b", id: 1, code: -32602,
                     message: "invalid argument vm: must be a valid vm name (one directory name, no /)")
    // (j) Host order: vm name, unknown argument, then unknown vm.
    expectErrorReply(callRaw(fresh(), "screenshot", #"{"vm":"a","x":1}"#), "screenshot with x", id: 1, code: -32602,
                     message: "invalid argument x: unknown argument; screenshot takes vm")
    expectErrorReply(callRaw(fresh(), "screenshot", #"{"vm":"nosuch","x":1}"#), "unknown vm and unknown argument", id: 1, code: -32602,
                     message: "invalid argument x: unknown argument; screenshot takes vm")
    expectTool(callRaw(fresh(), "screenshot", #"{"vm":"nosuch"}"#), "screenshot of an unknown vm",
               "unknown vm nosuch; \(rootG) has no such directory; use the name of a directory in \(rootG)", isError: true)
    expect(logGA.requests.isEmpty, "none of these sent a request")

    let countB = logGB.requests.count
    // (l) An empty or absent VPHONE_LIBRARY_ROOT names ~/.vphone/machines, expanded.
    let home = NSHomeDirectory() + "/.vphone/machines"
    for environment in [["VPHONE_LIBRARY_ROOT": ""], [:]] as [[String: String]] {
        for tool in ["screenshot", "device"] {
            let server = try! MCPServer(deadlines: testDeadlines, env: environment)
            let text = "unknown vm nosuch; \(home) has no such directory; use the name of a directory in \(home)"
            expectTool(callRaw(server, tool, #"{"vm":"nosuch"}"#.replacingOccurrences(of: "}", with: tool == "device" ? #","action":"device.info"}"# : "}")),
                       "\(tool) with library env \(environment)", text, isError: true)
        }
    }
    // (m) A known group tool with no action in the catalog is not-in-profile, whatever the profile.
    let (small, _, _) = guestFake(catalog: smallCatalog)
    expectErrorReply(call(small, "input", #"{"action":"input.tap"}"#), "empty area under full", id: 1, code: -32602,
                     message: notInProfileMessage("input", "full"))
    // (k) A present vm that is not a valid name is invalid, never missing, for host and group tools.
    for value in ["null", "5", #""""#, "true", "[]"] {
        for tool in ["screenshot", "device"] {
            expectErrorReply(callRaw(fresh(), tool, #"{"action":"device.info","vm":\#(value)}"#.replacingOccurrences(of: tool == "device" ? "" : #""action":"device.info","#, with: "")),
                             "\(tool) vm \(value)", id: 1, code: -32602,
                             message: "invalid argument vm: must be a valid vm name (one directory name, no /)")
        }
    }
    expect(logGA.requests.isEmpty && logGB.requests.count == countB, "no request was sent for an invalid vm")
    print("vm order tests passed")
}

/// A catalog JSON from method entries (JSON object texts).
func catalogOf(_ entries: [String]) -> String { #"{"methods":["# + entries.joined(separator: ",") + "]}" }

/// The tool named `name` in tools/list.
func tool(_ server: MCPServer, _ name: String) -> [String: Any]? { listedTools(server).first { $0["name"] as? String == name } }

/// The action names a group tool offers.
func actionNames(_ tool: [String: Any]?) -> [String] {
    ((((tool?["inputSchema"] as? [String: Any])?["properties"] as? [String: Any])?["action"] as? [String: Any])?["enum"] as? [String]) ?? []
}

/// Startup failure, parse rules, hostile entries, duplicates and host check order.
func catalogRuleTests() throws {
    // A catalog that does not parse is a startup failure with the documented two stderr lines.
    for bad in ["not json", #"{"methods":[]}"#, "[]", #"{"methods":[{"name":"x"}]}"#] {
        do {
            _ = try MCPServer(catalogJSON: bad)
            expect(false, "catalog \(bad) throws")
        } catch let error as StartupError {
            expect(error.problem == catalogProblem, "catalog \(bad) throws the catalog problem")
        }
    }
    expect(usageText(catalogProblem) == "vphone-mcp: guest catalog does not parse; rebuild vphone-mcp from a GuestCatalog.swift generated by run-methods-tests.sh --write-catalog\n"
           + "usage: vphone-mcp [--profile full|standard|readonly] [--tools a,b,c]\n", "the startup failure prints exactly two stderr lines")

    // Parse rules: a bad method drops only itself; entries that are not methods are ignored; no valid method is a failure.
    let good = #"{"name":"device.info","description":"d","area":"device","access":"read","force":"never","params":[]}"#
    let badParam = #"{"name":"device.bad","description":"d","area":"device","access":"read","force":"never","params":[{"type":"string"}]}"#
    let badType = #"{"name":"device.bad2","description":"d","area":"device","access":"read","force":"never","params":[{"name":"p","type":"weird"}]}"#
    let parsed = parseCatalog(catalogOf([good, badParam, badType, "5", #""x""#, "null"]))
    expect(parsed?.methods.map(\.name) == ["device.info"], "a method with a bad param is dropped alone and non-methods are ignored: \(parsed?.methods.map(\.name) ?? [])")
    expect(parseCatalog(catalogOf([badParam, badType])) == nil, "a catalog with no valid method does not parse")

    // Fail closed: a missing, non-string or unknown force is destructive and offers no force property.
    let hostile = [
        #"{"name":"files.noforce","description":"n","area":"files","access":"read","params":[]}"#,
        #"{"name":"files.oddforce","description":"o","area":"files","access":"read","force":"required","params":[]}"#,
        #"{"name":"files.numforce","description":"o","area":"files","access":"read","force":5,"params":[]}"#,
        #"{"name":"files.emptykey","description":"o","area":"files","access":"read","force":"when:","params":[]}"#,
    ]
    let sibling = #"{"name":"files.list","description":"l","area":"files","access":"read","force":"never","params":[]}"#
    let log = Log()
    let path = freshPath()
    _ = FakeSocket(path: path, handler: tableHandler([:], log: log))
    func server(_ profile: Profile, _ entries: [String]) -> MCPServer {
        try! MCPServer(defaultSocket: path, profile: profile, deadlines: testDeadlines, catalog: catalogOf(entries))
    }
    for profile in [Profile.readonly, .standard] {
        expect(actionNames(tool(server(profile, hostile + [sibling]), "files")) == ["files.list"], "hostile entries are not offered under \(profile)")
    }
    let fullFiles = tool(server(.full, hostile + [sibling]), "files")
    expect(actionNames(fullFiles) == ["files.emptykey", "files.noforce", "files.numforce", "files.oddforce", "files.list"].sorted(), "hostile entries are offered under full")
    expect((fullFiles?["annotations"] as? [String: Any])?["destructiveHint"] as? Bool == true, "a hostile entry makes its tool destructive")
    let branches = ((fullFiles?["inputSchema"] as? [String: Any])?["oneOf"] as? [[String: Any]]) ?? []
    expect(branches.allSatisfy { ($0["properties"] as? [String: Any])?["force"] == nil }, "a hostile entry offers no force property")
    for profile in [Profile.readonly, .standard] {
        expectErrorReply(call(server(profile, hostile + [sibling]), "files", #"{"action":"files.noforce"}"#), "hostile action under \(profile)", id: 1,
                         code: -32602, message: "invalid argument action: must be one of files.list")
    }
    let alone = tool(server(.full, [hostile[0], good]), "files")
    expect(actionNames(alone) == ["files.noforce"], "a hostile entry alone is offered under full")
    expectErrorReply(call(server(.readonly, [hostile[0], good]), "files", #"{"action":"files.noforce"}"#), "hostile entry alone under readonly",
                     id: 1, code: -32602, message: notInProfileMessage("files", "readonly"))
    expect(log.requests.isEmpty, "refused hostile calls send no request")

    // Entries that share a name are all dropped.
    let dupA = #"{"name":"files.x","description":"a","area":"files","access":"read","force":"never","params":[]}"#
    let dupB = #"{"name":"files.x","description":"b","area":"files","access":"destructive","force":"always","params":[]}"#
    for profile in [Profile.full, .standard, .readonly] {
        let held = server(profile, [dupA, dupB, sibling])
        expect(actionNames(tool(held, "files")) == ["files.list"], "a duplicated name is absent under \(profile)")
        expectErrorReply(call(held, "files", #"{"action":"files.x"}"#), "duplicated name call under \(profile)", id: 1, code: -32602,
                         message: "invalid argument action: must be one of files.list")
    }
    expect(log.requests.isEmpty, "duplicate-name calls send no request")

    // A shared top-level property takes the first action's description; Returns keys are sorted; a branch force object has
    // no description without force_action.
    let shareA = #"{"name":"device.a","description":"A.","area":"device","access":"read","force":"never","params":[{"name":"p","type":"string","required":false,"description":"first"}],"result":[{"name":"b"},{"name":"a"}]}"#
    let shareB = #"{"name":"device.b","description":"B.","area":"device","access":"mutating","force":"always","params":[{"name":"p","type":"string","required":false,"description":"second"}]}"#
    let shared = tool(server(.full, [shareB, shareA]), "device")
    let sharedProperties = (shared?["inputSchema"] as? [String: Any])?["properties"] as? [String: Any]
    expect((sharedProperties?["p"] as? [String: Any])?["description"] as? String == "first", "a shared property takes the first action's description")
    expect((shared?["description"] as? String ?? "").contains("device.a: A.\ndevice.b: B. Needs force."), "each action is one line: its text and whether it needs force")
    let sharedBranches = (shared?["inputSchema"] as? [String: Any])?["oneOf"] as? [[String: Any]] ?? []
    expect(canonical(((sharedBranches.last?["properties"] as? [String: Any])?["force"])) == "{}" && canonical((sharedProperties?["force"])) == canonical(["type": "boolean", "description": "Required to confirm a destructive action"] as [String: Any]),
           "a branch lists force as {} and the top level defines it once")

    // Host order: unknown argument before the socket, other argument checks after it.
    let (host, hostLog, _) = guestFake()
    let root = libraryRoot(env: host.env)
    let bad = #""local":"/a","path":"rel","mode":"9""#
    expectTool(callRaw(host, "push", #"{"vm":"nosuch",\#(bad)}"#), "push to an unknown vm with a bad mode", unknownVMMessage("nosuch", root), isError: true)
    expectErrorReply(callRaw(host, "push", #"{"vm":"t","bogus":1,\#(bad)}"#), "unknown argument before argument checks", id: 1, code: -32602,
                     message: "invalid argument bogus: unknown argument; push takes local, mode, path, vm")
    let running = outcome(callRaw(host, "push", #"{"vm":"t",\#(bad)}"#))
    let runningError = parse(callRaw(host, "push", #"{"vm":"t",\#(bad)}"#))["error"] as? [String: Any]
    expect(runningError?["code"] as? Int == -32602 && !running.text.contains("unknown vm"), "a running vm gets the argument error: \(runningError ?? [:])")
    expect(hostLog.requests.isEmpty, "host argument errors send no request")

    // Group order: vm, unknown vm, profile, action, unknown argument.
    let (group, groupLog, _) = guestFake()
    let groupRoot = libraryRoot(env: group.env)
    let readonlyGroup = try! MCPServer(profile: .readonly, deadlines: testDeadlines, env: group.env, catalogJSON: catalogJSON)
    expectErrorReply(callRaw(readonlyGroup, "apps", #"{"action":"apps.uninstall"}"#), "no allowed action and no vm", id: 1, code: -32602,
                     message: "invalid argument vm: missing")
    expectTool(callRaw(group, "device", #"{"vm":"nosuch","action":"nope","bogus":1}"#), "unknown vm before action", unknownVMMessage("nosuch", groupRoot), isError: true)
    expectErrorReply(callRaw(group, "device", #"{"vm":"t","action":"nope","bogus":1}"#), "action before unknown argument", id: 1, code: -32602,
                     message: "invalid argument action: must be one of device.info")
    expect(groupLog.requests.isEmpty, "group argument errors send no request")
    print("catalog rule tests passed")
}

/// The embedded catalog: it parses, it matches its methods count, and tools/list is built from it and the profile alone.
func staticCatalogTests() throws {
    let raw = (try? JSONSerialization.jsonObject(with: Data(guestCatalogJSON.utf8))) as? [String: Any]
    let entries = raw?["methods"] as? [[String: Any]] ?? []
    expect(!entries.isEmpty, "the embedded catalog is JSON with methods")
    expect(guestCatalogJSON.split(separator: "\n").filter { $0.hasPrefix(#"{"access""#) }.count == entries.count,
           "the embedded catalog has one method per line")
    let names = entries.compactMap { $0["name"] as? String }
    expect(names == names.sorted() && Set(names).count == names.count, "the embedded methods are sorted by name and unique")
    guard let catalog = parseCatalog(guestCatalogJSON) else { expect(false, "the embedded catalog parses"); return }
    let hostOnly = names.filter { ["screen.screenshot", "methods.list"].contains($0) }.count
    expect(catalog.methods.count == entries.count - hostOnly, "every embedded method but the host ones is in the catalog: \(catalog.methods.count) of \(entries.count)")

    // tools/list is identical with no VM and with VMs present, and sends no socket request.
    let root = "/tmp/vmcp-static-\(getpid())"
    try? FileManager.default.removeItem(atPath: root)
    defer { try? FileManager.default.removeItem(atPath: root) }
    for name in ["a", "b"] { try FileManager.default.createDirectory(atPath: "\(root)/\(name)", withIntermediateDirectories: true) }
    let line = #"{"id":1,"method":"tools/list"}"#
    for profile in [Profile.full, .standard, .readonly] {
        let empty = try! MCPServer(profile: profile, deadlines: testDeadlines, env: ["VPHONE_LIBRARY_ROOT": "/tmp/vmcp-nonexistent-\(getpid())"])
        let before = empty.handle(line: line)
        let log = Log()
        let a = FakeSocket(path: "\(root)/a/vphone.sock", handler: tableHandler(catalogTable, log: log))
        let b = FakeSocket(path: "\(root)/b/vphone.sock", handler: tableHandler([:], log: log))
        let present = try! MCPServer(profile: profile, deadlines: testDeadlines, env: ["VPHONE_LIBRARY_ROOT": root])
        expect(present.handle(line: line) == before && before != nil, "tools/list is identical with VMs present under \(profile)")
        expect(present.handle(line: line) == before, "tools/list is identical on a second call under \(profile)")
        expect(a.connections.get() == 0 && b.connections.get() == 0 && log.requests.isEmpty, "tools/list sent no socket request under \(profile)")
        unlink("\(root)/a/vphone.sock")
        unlink("\(root)/b/vphone.sock")
    }

    // Profiles come from the static catalog.
    let missing = ["VPHONE_LIBRARY_ROOT": "/tmp/vmcp-nonexistent-\(getpid())"]
    let destructive = Set(entries.filter { ($0["access"] as? String) == "destructive" || ($0["force"] as? String) != "never" }.compactMap { $0["name"] as? String })
    expect(!destructive.isEmpty, "the embedded catalog has destructive methods")
    let readNames = Set(entries.filter { ($0["access"] as? String) == "read" && !destructive.contains($0["name"] as? String ?? "") }.compactMap { $0["name"] as? String })
    for (profile, absent) in [(Profile.full, Set<String>()), (.standard, ["rpc", "shell"]), (.readonly, ["rpc", "shell", "push", "pull"])] {
        let listed = listedTools(try! MCPServer(profile: profile, deadlines: testDeadlines, env: missing))
        let names = Set(listed.compactMap { $0["name"] as? String })
        expect(names.isDisjoint(with: absent), "\(profile) lists none of \(absent.sorted())")
        if profile == .full { expect(names.count == 19 && names.isSuperset(of: toolNames), "full lists all 19 tools") }
        for tool in listed {
            guard let area = tool["name"] as? String, areaNames.contains(area) else { continue }
            let actions = actionNames(tool)
            expect(actions == actions.sorted() && !actions.isEmpty, "\(profile) \(area) lists its actions in method name order")
            if profile != .full { expect(Set(actions).isDisjoint(with: destructive), "\(profile) \(area) offers no destructive action") }
            if profile == .readonly { expect(Set(actions).isSubset(of: readNames), "readonly \(area) offers only read actions") }
        }
    }
    let readonly = Set(toolNamesListed(try! MCPServer(profile: .readonly, deadlines: testDeadlines, env: missing)))
    let standard = Set(toolNamesListed(try! MCPServer(profile: .standard, deadlines: testDeadlines, env: missing)))
    let full = Set(toolNamesListed(try! MCPServer(deadlines: testDeadlines, env: missing)))
    expect(readonly.isSubset(of: standard) && standard.isSubset(of: full) && readonly != full, "the profiles narrow the embedded tools")
    print("static catalog tests passed")
}

func groupDeadlineImageTests() throws {
    let table: [String: Reply] = [
        "rpc:device.wait": Reply(line: #"{"ok":true,"result":{"waited":true}}"#, delay: 2.5),
        "rpc:ui.snap": Reply(line: #"{"ok":true,"result":{"data":"AAEC","mime_type":"image/png"}}"#),
    ]
    let (server, _, _) = guestFake(table, catalog: smallCatalog)
    // (d) timeout_ms lifts the deadline to timeout_ms + 30 s, past the 2 s rpc deadline.
    expectTool(call(server, "device", #"{"action":"device.wait","timeout_ms":1000}"#), "a reply past the base deadline within timeout_ms + 30 s",
               #"{"waited":true}"#)
    // (e) An image result is MCP image content.
    expect(canonical(contentBlocks(call(server, "ui", #"{"action":"ui.snap"}"#))) == canonical([
        ["type": "image", "data": "AAEC", "mimeType": "image/png"],
        ["type": "text", "text": #"{"mime_type":"image/png"}"#],
    ] as [[String: Any]]), "a group image result is image content")

    // (f) screen.screenshot and methods.list are in no action enum, and a call naming one is refused.
    let (full, _, _) = guestFake(catalogTable)
    for tool in listedTools(full) {
        let schema = tool["inputSchema"] as? [String: Any]
        let actions = (((schema?["properties"] as? [String: Any])?["action"] as? [String: Any])?["enum"] as? [String]) ?? []
        expect(!actions.contains("screen.screenshot") && !actions.contains("methods.list"), "\(tool["name"] ?? "") lists neither host action")
    }
    expectErrorReply(call(full, "ui", #"{"action":"screen.screenshot"}"#), "screen.screenshot as an action", id: 1, code: -32602,
                     message: "invalid argument action: must be one of ui.elements")
    expectErrorReply(call(full, "device", #"{"action":"methods.list"}"#), "methods.list as an action", id: 1, code: -32602,
                     message: "invalid argument action: must be one of device.info")
    print("group deadline and image tests passed")
}

/// A valid 8200 by 8200 one-bit PNG (67.2 million pixels, over the 64 million limit) of about 8 KB.
func overLimitPNG() -> Data {
    func be(_ value: UInt32) -> [UInt8] { [UInt8(value >> 24), UInt8((value >> 16) & 255), UInt8((value >> 8) & 255), UInt8(value & 255)] }
    var table = [UInt32](repeating: 0, count: 256)
    for n in 0..<256 {
        var c = UInt32(n)
        for _ in 0..<8 { c = c & 1 == 1 ? 0xEDB88320 ^ (c >> 1) : c >> 1 }
        table[n] = c
    }
    func chunk(_ type: String, _ body: [UInt8]) -> [UInt8] {
        let name = Array(type.utf8)
        var crc: UInt32 = 0xFFFFFFFF
        for byte in name + body { crc = table[Int((crc ^ UInt32(byte)) & 255)] ^ (crc >> 8) }
        return be(UInt32(body.count)) + name + body + be(crc ^ 0xFFFFFFFF)
    }
    let side: UInt32 = 8200
    let raw = [UInt8](repeating: 0, count: Int(side) * (1 + (Int(side) + 7) / 8))
    var deflated = [UInt8](repeating: 0, count: 65536)
    let size = compression_encode_buffer(&deflated, deflated.count, raw, raw.count, nil, COMPRESSION_ZLIB)
    let adler = (UInt32(raw.count % 65521) << 16) | 1
    let zlib: [UInt8] = [0x78, 0x01] + deflated.prefix(size) + be(adler)
    let png = [137, 80, 78, 71, 13, 10, 26, 10] as [UInt8]
        + chunk("IHDR", be(side) + be(side) + [1, 0, 0, 0, 0]) + chunk("IDAT", zlib) + chunk("IEND", [])
    return Data(png)
}

/// An image embedded in a group result leaves the text and comes back as image content.
func embeddedImageTests() throws {
    let big = pngData(width: 300, height: 600).base64EncodedString()
    let hugeHeader = overLimitPNG().base64EncodedString()
    let nested = #"{"elements":[1],"frontmost":{"bundle_id":"a.b"},"screenshot":{"data":"\#(big)","mime_type":"image/png","width":300,"coordinate_scale":3}}"#
    let flat = #"{"data":"AAEC","mime_type":"image/jpeg","note":"x"}"#
    let two = #"{"shots":[{"data":"AAEC","mime_type":"image/png"},{"data":"BAUG","mime_type":"image/jpeg"}],"other":{"data":"AAEC"}}"#
    let (server, _, _) = guestFake([
        "rpc:ui.snap": Reply(line: #"{"ok":true,"result":\#(nested)}"#),
        "rpc:ui.flat": Reply(line: #"{"ok":true,"result":\#(flat)}"#),
        "rpc:ui.two": Reply(line: #"{"ok":true,"result":\#(two)}"#),
        "rpc:ui.junk": Reply(line: #"{"ok":true,"result":{"data":"AAEC","mime_type":"image/png","coordinate_scale":3}}"#),
        "rpc:ui.badb64": Reply(line: #"{"ok":true,"result":{"data":"!!","mime_type":"image/png"}}"#),
        "rpc:ui.empty": Reply(line: #"{"ok":true,"result":{"data":"","mime_type":"image/png"}}"#),
        "rpc:ui.strscale": Reply(line: #"{"ok":true,"result":{"data":"AAEC","mime_type":"image/png","coordinate_scale":"3"}}"#),
        "rpc:ui.huge": Reply(line: #"{"ok":true,"result":{"data":"\#(hugeHeader)","mime_type":"image/png","coordinate_scale":1.01}}"#),
        "rpc:ui.text": Reply(line: #"{"ok":true,"result":{"screenshot":{"data":"AAEC","mime_type":"text/plain"}}}"#),
    ], catalog: #"{"methods":["#
        + ["ui.snap", "ui.flat", "ui.two", "ui.text", "ui.junk", "ui.badb64", "ui.empty", "ui.strscale", "ui.huge"].map {
            #"{"name":"\#($0)","description":"x","area":"ui","access":"read","force":"never","params":[]}"#
        }.joined(separator: ",") + "]}")

    let blocks = contentBlocks(call(server, "ui", #"{"action":"ui.snap"}"#))
    expect(blocks.count == 2 && blocks[0]["type"] as? String == "image" && blocks[1]["type"] as? String == "text",
           "a nested image is image content and a text: \(blocks.count) blocks")
    let text = blocks.last?["text"] as? String ?? ""
    expect(!text.contains(big) && !text.contains("\"data\"") && text.contains(#""bundle_id":"a.b""#) && text.contains(#""mime_type":"image/png""#),
           "the text holds the result without the base64: \(text.count) bytes")
    let size = (Data(base64Encoded: blocks[0]["data"] as? String ?? "")).flatMap(decodeImage).map { ($0.width, $0.height) } ?? (0, 0)
    expect(blocks[0]["mimeType"] as? String == "image/png" && size == (100, 200),
           "an image with coordinate_scale 3 is scaled to point size: \(size)")

    let unscaled = contentBlocks(call(server, "ui", #"{"action":"ui.flat"}"#))
    expect(canonical(unscaled) == canonical([
        ["type": "image", "data": "AAEC", "mimeType": "image/jpeg"],
        ["type": "text", "text": #"{"mime_type":"image/jpeg","note":"x"}"#],
    ] as [[String: Any]]), "an image without coordinate_scale is passed on as it is: \(unscaled)")

    let several = contentBlocks(call(server, "ui", #"{"action":"ui.two"}"#))
    expect(several.map { $0["type"] as? String ?? "" } == ["image", "image", "text"]
           && several.prefix(2).map { $0["data"] as? String ?? "" } == ["AAEC", "BAUG"]
           && several[2]["text"] as? String == #"{"other":{"data":"AAEC"},"shots":[{"mime_type":"image/png"},{"mime_type":"image/jpeg"}]}"#,
           "every embedded image is a block, in order, and a data field without an image mime_type stays: \(several)")

    let plain = contentBlocks(call(server, "ui", #"{"action":"ui.text"}"#))
    expect(plain.count == 1 && (plain[0]["text"] as? String)?.contains(#""data":"AAEC""#) == true, "a non-image data field is left in the text")
    for method in ["ui.junk", "ui.strscale", "ui.huge"] {
        let reply = contentBlocks(call(server, "ui", #"{"action":"\#(method)"}"#))
        let sent = method == "ui.huge" ? hugeHeader : "AAEC"
        expect(reply.count == 2 && reply[0]["type"] as? String == "image" && reply[0]["mimeType"] as? String == "image/png"
                   && reply[0]["data"] as? String == sent, "\(method) passes the image on as given")
        expect(outcome(call(server, "ui", #"{"action":"\#(method)"}"#)).isError == false, "\(method) is not an error")
    }
    for method in ["ui.badb64", "ui.empty"] {
        let reply = contentBlocks(call(server, "ui", #"{"action":"\#(method)"}"#))
        expect(reply.count == 1 && reply[0]["type"] as? String == "text", "\(method) keeps its data in the text")
    }
    print("embedded image tests passed")
}

/// Every parameter is typed, arrays say what they hold, and tools/list stays under its size budget.
func schemaTypeTests() throws {
    let missing = ["VPHONE_LIBRARY_ROOT": "/tmp/vmcp-no-lib-\(getpid())"]
    let server = try! MCPServer(deadlines: testDeadlines, env: missing)
    let tools = listedTools(server)
    func isTyped(_ property: [String: Any]) -> Bool {
        property["type"] is String || ((property["type"] as? [String])?.isEmpty == false)
    }
    var checked = 0
    var untyped: [String] = []
    for tool in tools {
        guard let schema = tool["inputSchema"] as? [String: Any], let properties = schema["properties"] as? [String: Any] else { continue }
        for (name, value) in properties {
            checked += 1
            let property = value as? [String: Any] ?? [:]
            if !isTyped(property) { untyped.append("\(tool["name"] ?? "").\(name)") }
            if property["type"] as? String == "array" && property["items"] == nil { untyped.append("\(tool["name"] ?? "").\(name) items") }
        }
        for branch in schema["oneOf"] as? [[String: Any]] ?? [] {
            for (name, value) in branch["properties"] as? [String: Any] ?? [:] {
                let property = value as? [String: Any] ?? [:]
                if property.isEmpty || property["const"] != nil { continue }
                if !isTyped(property) { untyped.append("\(tool["name"] ?? "") branch \(name)") }
            }
        }
    }
    expect(checked > 200 && untyped.isEmpty, "every parameter of \(checked) properties has a type, and every array its items: \(untyped)")

    let input = (tools.first { $0["name"] as? String == "input" }?["inputSchema"] as? [String: Any])?["properties"] as? [String: Any] ?? [:]
    expect(canonical(input["from"]) == canonical(["description": "Start point as [x, y] in screen points", "type": "array",
                                                  "items": ["type": "number"], "minItems": 2, "maxItems": 2] as [String: Any]),
           "input.swipe from is an array of two numbers: \(canonical(input["from"]))")
    expect(canonical((input["points"] as? [String: Any])?["items"]) == canonical(["type": "array", "items": ["type": "number"], "minItems": 2, "maxItems": 2] as [String: Any]),
           "input.drag points holds [x, y] pairs")
    expect(input["force"] == nil, "input has no force")
    let system = (tools.first { $0["name"] as? String == "system" }?["inputSchema"] as? [String: Any])?["properties"] as? [String: Any] ?? [:]
    expect(canonical(system["force"]) == canonical(["type": "boolean", "description": "Required to confirm a destructive action"] as [String: Any]),
           "force is a boolean that says what it confirms: \(canonical(system["force"]))")
    let device = (tools.first { $0["name"] as? String == "device" }?["inputSchema"] as? [String: Any])?["properties"] as? [String: Any] ?? [:]
    expect(canonical((device["position"] as? [String: Any])?["type"]) == canonical(["string", "number"]), "an any parameter lists its types")
    expect(canonical((device["name"] as? [String: Any])?["type"]) == canonical(["string", "null"]), "device.name.set name takes a string or null")

    let size = listedBytes(server)
    expect(size < toolsListBudget, "tools/list is \(size) bytes, under \(toolsListBudget)")

    // The checks follow the typed schema.
    let log = Log()
    let (guest, _, _) = guestFake(["rpc:input.swipe": Reply(line: #"{"ok":true,"result":{}}"#), "rpc:device.name.set": Reply(line: #"{"ok":true,"result":{}}"#)],
                                  log: log, catalog: guestCatalogJSON)
    let swipe = #"{"action":"input.swipe","#
    let refused: [(String, String)] = [
        (swipe + #""from":"1,2","to":[3,4]}"#, "invalid argument from: must be an array"),
        (swipe + #""from":[1],"to":[3,4]}"#, "invalid argument from: must have 2 items"),
        (swipe + #""from":[1,2,3],"to":[3,4]}"#, "invalid argument from: must have 2 items"),
        (swipe + #""from":["a","b"],"to":[3,4]}"#, "invalid argument from: must be an array of numbers"),
        (swipe + #""from":[1,2],"to":[true,4]}"#, "invalid argument to: must be an array of numbers"),
    ]
    for (arguments, message) in refused {
        expectErrorReply(call(guest, "input", arguments), arguments, id: 1, code: -32602, message: message)
    }
    expect(guestRequests(log).isEmpty, "a malformed array sends nothing")
    expectTool(call(guest, "input", swipe + #""from":[1,2],"to":[3,4]}"#), "a well-formed swipe", "{}")
    expectTool(call(guest, "device", #"{"action":"device.name.set","name":null}"#), "name null is accepted", "{}")
    expectErrorReply(call(guest, "device", #"{"action":"device.name.set","name":5}"#), "name 5", id: 1, code: -32602,
                     message: "invalid argument name: must be a string or null")
    expectErrorReply(call(guest, "device", #"{"action":"display.posture","position":true}"#), "position true", id: 1, code: -32602,
                     message: "invalid argument position: must be a string or a number")
    print("schema type tests passed")
}

/// Array bounds and item kinds, and a parameter the actions define differently.
func arrayAndMergeTests() throws {
    func method(_ name: String, _ params: String) -> String {
        #"{"name":"\#(name)","description":"x","area":"device","access":"read","force":"never","params":[\#(params)]}"#
    }
    func array(_ name: String, items: String, min: Int? = nil, max: Int? = nil) -> String {
        #"{"name":"\#(name)","type":"array","required":false,"description":"d","items":"\#(items)""# + (min.map { #","minimum":\#($0)"# } ?? "")
            + (max.map { #","maximum":\#($0)"# } ?? "") + "}"
    }
    let catalog = #"{"methods":["# + [
        method("device.a", array("ranged", items: "string", min: 1, max: 3) + "," + array("lower", items: "integer", min: 2)
            + "," + array("upper", items: "object", max: 1) + "," + array("nums", items: "number") + "," + array("pts", items: "point")),
        method("device.b", #"{"name":"q","type":"string","required":false,"description":"first","enum":["a","b"],"default":"a"}"#),
        method("device.c", #"{"name":"q","type":"integer","required":false,"description":"second","minimum":1,"maximum":5}"#),
    ].joined(separator: ",") + "]}"
    let log = Log()
    let (server, _, _) = guestFake(["rpc:device.a": Reply(line: #"{"ok":true,"result":{}}"#)], log: log, catalog: catalog)
    let refused: [(String, String)] = [
        (#""ranged":[]"#, "invalid argument ranged: must have from 1 to 3 items"),
        (#""ranged":["a","b","c","d"]"#, "invalid argument ranged: must have from 1 to 3 items"),
        (#""ranged":[1]"#, "invalid argument ranged: must be an array of strings"),
        (#""lower":[1]"#, "invalid argument lower: must have at least 2 items"),
        (#""lower":[1,1.5]"#, "invalid argument lower: must be an array of integers"),
        (#""upper":[{"a":1},{"a":1}]"#, "invalid argument upper: must have at most 1 item"),
        (#""upper":[5]"#, "invalid argument upper: must be an array of objects"),
        (#""nums":["a"]"#, "invalid argument nums: must be an array of numbers"),
        (#""pts":[[1]]"#, "invalid argument pts: must be an array of [x, y] pairs of numbers"),
        (#""pts":[[1,2],[3,"x"]]"#, "invalid argument pts: must be an array of [x, y] pairs of numbers"),
    ]
    for (arguments, message) in refused {
        expectErrorReply(call(server, "device", #"{"action":"device.a",\#(arguments)}"#), arguments, id: 1, code: -32602, message: message)
    }
    expect(guestRequests(log).isEmpty, "an array refusal sends nothing")
    expectTool(call(server, "device", #"{"action":"device.a","ranged":["a"],"lower":[1,2],"upper":[{"a":1}],"nums":[1.5],"pts":[[1,2]]}"#), "valid arrays", "{}")

    let tool = listedTools(server).first { $0["name"] as? String == "device" } ?? [:]
    let schema = tool["inputSchema"] as? [String: Any] ?? [:]
    let q = (schema["properties"] as? [String: Any])?["q"] as? [String: Any] ?? [:]
    expect(canonical(q) == canonical(["description": "first", "type": ["string", "integer"]] as [String: Any]),
           "a parameter the actions define differently has the first description and the union of types only: \(canonical(q))")
    let branches = schema["oneOf"] as? [[String: Any]] ?? []
    let own = branches.map { ($0["properties"] as? [String: Any])?["q"] as? [String: Any] ?? [:] }
    expect(own.count == 3 && own[0].isEmpty && own[1]["enum"] != nil && own[1]["default"] as? String == "a" && own[1]["type"] as? String == "string"
               && own[2]["type"] as? String == "integer" && jsonNumber(own[2]["minimum"]) == 1 && jsonNumber(own[2]["maximum"]) == 5,
           "each branch carries its own definition: \(own.map(canonical))")
    print("array and merge tests passed")
}

/// The tools/list reply, in bytes.
func listedBytes(_ server: MCPServer) -> Int {
    (server.handle(line: #"{"id":1,"method":"tools/list"}"#) ?? "").utf8.count
}

/// The size budget for `tools/list`, in bytes: every client reads it into its context.
let toolsListBudget = 100_000

@main
enum MCPTests {
    static func main() throws {
        signal(SIGPIPE, SIG_IGN)
        try machineSocketTests()
        try serverTests()
        try stdioTests()
        try scaleTests()
        try screenshotTests()
        try hostToolTests()
        try shellTests()
        try guestErrorTests()
        try rpcDeadlineImageTests()
        try methodsFilterTests()
        try annotationTests()
        try unknownArgumentTests()
        try groupToolTests()
        try profileTests()
        try vmArgumentTests()
        try staticCatalogTests()
        try catalogRuleTests()
        try vmOrderTests()
        try groupDeadlineImageTests()
        try embeddedImageTests()
        try schemaTypeTests()
        try arrayAndMergeTests()
        print("all MCPTests passed")
    }
}

import Darwin
import Foundation

struct TestFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

func checked<T: FixedWidthInteger>(_ result: T, _ name: String) throws -> T {
    guard result >= 0 else { throw TestFailure("\(name): \(String(cString: strerror(errno)))") }
    return result
}

func socketAddress(_ ip: in_addr, _ port: UInt16) -> sockaddr_in {
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr = ip
    address.sin_port = port.bigEndian
    return address
}

func withAddress<T>(_ address: sockaddr_in, _ body: (UnsafePointer<sockaddr>, socklen_t) -> T) -> T {
    withUnsafePointer(to: address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(address.sin_len)) }
    }
}

func localAddress(_ fd: Int32) throws -> sockaddr_in {
    var address = sockaddr_in()
    var size = socklen_t(MemoryLayout.size(ofValue: address))
    _ = try checked(withUnsafeMutablePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &size) }
    }, "getsockname")
    return address
}

func openSocket(_ type: Int32) throws -> Int32 {
    let fd = try checked(socket(AF_INET, type, 0), "socket")
    var timeout = timeval(tv_sec: 5, tv_usec: 0)
    guard setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout))) == 0 else {
        let failure = TestFailure("receive timeout: \(String(cString: strerror(errno)))")
        close(fd)
        throw failure
    }
    return fd
}

func receive(_ fd: Int32, count: Int) throws -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: count)
    let size = try checked(recv(fd, &bytes, count, MSG_WAITALL), "receive")
    guard size == count else { throw TestFailure("Expected \(count) bytes, received \(size)") }
    return bytes
}

func octets<T: FixedWidthInteger>(_ networkOrder: T) -> [UInt8] {
    withUnsafeBytes(of: networkOrder) { Array($0) }
}

func testAssociation(proxy: sockaddr_in, announcePort: Bool) throws {
    let control = try openSocket(SOCK_STREAM)
    defer { close(control) }
    _ = try checked(withAddress(proxy) { connect(control, $0, $1) }, "connect to proxy")
    let host = try localAddress(control).sin_addr
    let client = try openSocket(SOCK_DGRAM)
    defer { close(client) }
    let echo = try openSocket(SOCK_DGRAM)
    defer { close(echo) }
    for fd in [client, echo] {
        _ = try checked(withAddress(socketAddress(host, 0)) { bind(fd, $0, $1) }, "bind UDP")
    }

    let stream = FileHandle(fileDescriptor: control, closeOnDealloc: false)
    try stream.write(contentsOf: Data([5, 1, 0]))
    guard try receive(control, count: 2) == [5, 0] else { throw TestFailure("SOCKS5 greeting failed") }
    let sourcePort: UInt16 = announcePort ? try localAddress(client).sin_port : 0
    try stream.write(contentsOf: Data([5, 3, 0, 1, 0, 0, 0, 0] + octets(sourcePort)))
    let reply = try receive(control, count: 10)
    guard Array(reply.prefix(4)) == [5, 0, 0, 1] else { throw TestFailure("UDP ASSOCIATE replied \(reply[1])") }
    var relay = socketAddress(in_addr(), 0)
    withUnsafeMutableBytes(of: &relay.sin_addr.s_addr) { $0.copyBytes(from: reply[4..<8]) }
    withUnsafeMutableBytes(of: &relay.sin_port) { $0.copyBytes(from: reply[8..<10]) }
    guard relay.sin_port != 0 else { throw TestFailure("Missing relay port") }
    if relay.sin_addr.s_addr == 0 { relay.sin_addr = proxy.sin_addr }
    _ = try checked(withAddress(relay) { connect(client, $0, $1) }, "connect UDP")

    let destination = try localAddress(echo)
    let header: [UInt8] = [0, 0, 0, 1] + octets(host.s_addr) + octets(destination.sin_port)
    let capacity = 256
    var buffer = [UInt8](repeating: 0, count: capacity)
    // Exercise both the initial datagram and another one on the established association.
    for _ in 0 ..< 2 {
        let payload = Array(UUID().uuidString.utf8)
        let request = header + payload
        _ = try checked(send(client, request, request.count, 0), "send datagram")
        var sender = sockaddr_in()
        var size = socklen_t(MemoryLayout.size(ofValue: sender))
        let received = try checked(withUnsafeMutablePointer(to: &sender) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(echo, &buffer, capacity, 0, $0, &size) }
        }, "receive at echo endpoint")
        guard buffer.prefix(received).elementsEqual(payload) else { throw TestFailure("Unexpected echo payload") }
        _ = try checked(withAddress(sender) { sendto(echo, payload, payload.count, 0, $0, $1) }, "echo datagram")
        let returned = try checked(recv(client, &buffer, capacity, 0), "receive from relay")
        guard buffer.prefix(returned).elementsEqual(request) else { throw TestFailure("Unexpected UDP relay response") }
    }
}

do {
    let args = CommandLine.arguments
    var ip = in_addr()
    guard args.count == 3, inet_pton(AF_INET, args[1], &ip) == 1, let port = UInt16(args[2]), port > 0 else {
        throw TestFailure("Usage: swift UDPAssociate.swift <proxy-ipv4> <proxy-port>")
    }
    for known in [true, false] {
        try testAssociation(proxy: socketAddress(ip, port), announcePort: known)
        print("UDP round trip passed (\(known ? "announced port" : "unknown endpoint"))")
    }
} catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8))
    exit(1)
}

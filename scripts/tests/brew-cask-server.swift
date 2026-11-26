// Fixture HTTP server for scripts/tests/brew-cask-tests.zsh.
// Usage: brew-cask-server <root> <port-file>
// Serves GET and HEAD for files in <root> by the last path component: 200
// with the file, 404 when absent, and 503 for one asset that stands in for a
// server error. Binds 127.0.0.1 on a free port and writes the port to
// <port-file>. Handles one connection at a time.
import Darwin
import Foundation

let args = CommandLine.arguments
guard args.count == 3 else {
    FileHandle.standardError.write(Data("usage: brew-cask-server <root> <port-file>\n".utf8))
    exit(2)
}
let root = URL(fileURLWithPath: args[1])
let failing = "vphone-launchpad-1.0.3-notarized.zip"
// A client that hangs up mid-download must not kill the server.
signal(SIGPIPE, SIG_IGN)

let listener = socket(AF_INET, SOCK_STREAM, 0)
guard listener >= 0 else { perror("socket"); exit(1) }
var address = sockaddr_in()
address.sin_family = sa_family_t(AF_INET)
address.sin_addr.s_addr = inet_addr("127.0.0.1")
address.sin_port = 0
var length = socklen_t(MemoryLayout<sockaddr_in>.size)
let bound = withUnsafeMutablePointer(to: &address) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { pointer in
        bind(listener, pointer, length) == 0
            && listen(listener, 16) == 0
            && getsockname(listener, pointer, &length) == 0
    }
}
guard bound else { perror("bind"); exit(1) }
let port = UInt16(bigEndian: address.sin_port)
do {
    try String(port).write(toFile: args[2], atomically: true, encoding: .utf8)
} catch {
    FileHandle.standardError.write(Data("cannot write \(args[2]): \(error)\n".utf8))
    exit(1)
}

func send(_ connection: Int32, _ data: Data) {
    data.withUnsafeBytes { buffer in
        var offset = 0
        while offset < buffer.count {
            let sent = write(connection, buffer.baseAddress! + offset, buffer.count - offset)
            if sent <= 0 { return }
            offset += sent
        }
    }
}

func reply(_ connection: Int32, _ status: String, _ body: Data, head: Bool) {
    let header = "HTTP/1.1 \(status)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
    send(connection, Data(header.utf8))
    if !head { send(connection, body) }
}

while true {
    let connection = accept(listener, nil, nil)
    if connection < 0 { continue }
    var request = Data()
    var chunk = [UInt8](repeating: 0, count: 4096)
    while request.range(of: Data("\r\n\r\n".utf8)) == nil {
        let count = read(connection, &chunk, chunk.count)
        if count <= 0 { break }
        request.append(contentsOf: chunk[0..<count])
    }
    let line = String(decoding: request, as: UTF8.self).split(separator: "\r\n").first ?? ""
    let parts = line.split(separator: " ")
    if parts.count >= 2, parts[0] == "GET" || parts[0] == "HEAD" {
        let head = parts[0] == "HEAD"
        let name = String(parts[1].split(separator: "?").first ?? "").split(separator: "/").last.map(String.init) ?? ""
        if name == failing {
            reply(connection, "503 Service Unavailable", Data(), head: head)
        } else if !name.isEmpty, let body = FileManager.default.contents(atPath: root.appendingPathComponent(name).path) {
            reply(connection, "200 OK", body, head: head)
        } else {
            reply(connection, "404 Not Found", Data(), head: head)
        }
    } else {
        reply(connection, "405 Method Not Allowed", Data(), head: false)
    }
    close(connection)
}

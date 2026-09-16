// Standalone regressions for environments without SwiftPM/XCTest.
// swiftc -swift-version 6 sources/VPhoneCore/*.swift tests/security_regressions.swift -o /tmp/vphone-security-tests
import Foundation
import Darwin

@main
struct SecurityRegressions {
    static func rejects(_ body: () throws -> Void) {
        do { try body(); fatalError("Expected rejected untrusted input") } catch {}
    }

    static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let bundle = root.appendingPathComponent("bundle")
        let output = root.appendingPathComponent("output")
        try fm.createDirectory(at: bundle, withIntermediateDirectories: true)
        try fm.createDirectory(at: output, withIntermediateDirectories: true)
        let sentinel = root.appendingPathComponent("sentinel")
        let original = Data("untouched".utf8)
        try original.write(to: sentinel)
        let manifest = VPhoneVirtualMachineManifest(cpuCount: 1, memorySize: 1024, romImages: nil)
        for path in ["", "/tmp/outside", "../sentinel", "a/../../sentinel", "a//b", "a/./b", "a\0b"] {
            rejects { _ = try manifest.resolve(path: path, in: bundle) }
        }
        _ = try manifest.resolve(path: "new/output", in: bundle)
        try manifest.write(to: bundle.appendingPathComponent("config.plist"))
        _ = try VPhoneVirtualMachineManifest.load(from: bundle.appendingPathComponent("config.plist"))
        try fm.createSymbolicLink(at: bundle.appendingPathComponent("link"), withDestinationURL: root)
        rejects { _ = try manifest.resolve(path: "link/sentinel", in: bundle) }
        try fm.createSymbolicLink(at: bundle.appendingPathComponent("dangling"), withDestinationURL: root.appendingPathComponent("missing"))
        rejects { _ = try manifest.resolve(path: "dangling", in: bundle) }
        try fm.createSymbolicLink(at: bundle.appendingPathComponent("other.plist"), withDestinationURL: sentinel)
        rejects { try manifest.write(to: bundle.appendingPathComponent("other.plist")) }
        rejects { _ = try VPhoneVirtualMachineManifest.load(from: bundle.appendingPathComponent("other.plist")) }

        for name in ["", ".", "..", "a/b", "a\0b"] {
            rejects { try VPhoneDownloadPath.validateComponent(name) }
        }
        let directory = try VPhoneDownloadPath.openDirectory(output)
        defer { close(directory) }
        try fm.createSymbolicLink(at: output.appendingPathComponent("child"), withDestinationURL: root)
        rejects { _ = try VPhoneDownloadPath.openChildDirectory(directory, "child") }
        rejects { _ = try VPhoneDownloadPath.openDirectory(output.appendingPathComponent("child")) }
        try fm.createSymbolicLink(at: output.appendingPathComponent("dangling"), withDestinationURL: root.appendingPathComponent("missing"))
        rejects { _ = try VPhoneDownloadPath.openChildDirectory(directory, "dangling") }
        for name in ["symlink", "hardlink"] {
            let destination = output.appendingPathComponent(name)
            if name == "symlink" { try fm.createSymbolicLink(at: destination, withDestinationURL: sentinel) }
            else { try fm.linkItem(at: sentinel, to: destination) }
            let temp = try VPhoneDownloadPath.openAtomicOutput(directory, name: name)
            close(temp.fd)
            try VPhoneDownloadPath.commit(directory, temporary: temp.temporary, name: name)
            precondition(tryData(sentinel) == original)
        }
        let anchored = try VPhoneDownloadPath.openChildDirectory(directory, "anchored")
        defer { close(anchored) }
        try fm.moveItem(at: output.appendingPathComponent("anchored"), to: output.appendingPathComponent("moved"))
        try fm.createSymbolicLink(at: output.appendingPathComponent("anchored"), withDestinationURL: root)
        let temp = try VPhoneDownloadPath.openAtomicOutput(anchored, name: "sentinel")
        close(temp.fd)
        try VPhoneDownloadPath.commit(anchored, temporary: temp.temporary, name: "sentinel")
        precondition(tryData(sentinel) == original)

        for json in ["true", "-1", "1.5", "\"3\"", "9223372036854775808", "null"] {
            let value = try JSONSerialization.jsonObject(with: Data(json.utf8), options: .fragmentsAllowed)
            rejects { _ = try VPhoneControlTransfer.length(value) }
        }
        rejects { _ = try VPhoneControlTransfer.length(nil) }
        let zero = try VPhoneControlTransfer.length(NSNumber(value: 0))
        precondition(zero == 0)
        rejects { _ = try VPhoneControlTransfer.payloadLength(message: ["t": "file_data", "size": 1], requestType: "ping", streaming: false) }
        rejects { _ = try VPhoneControlTransfer.payloadLength(message: ["t": "file_data", "size": Int.max], requestType: "file_get", streaming: false) }
        rejects { _ = try VPhoneControlTransfer.payloadLength(message: ["t": "clipboard_get", "has_image": true, "image_size": Int.max], requestType: "clipboard_get", streaming: false) }
        let huge = try VPhoneControlTransfer.payloadLength(message: ["t": "file_data", "size": Int.max], requestType: "file_get", streaming: true)
        precondition(huge == Int.max)
        var sockets: [Int32] = [-1, -1]
        precondition(socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets) == 0)
        defer { close(sockets[0]); close(sockets[1]) }
        rejects { _ = try VPhoneControlTransfer.receive(fd: sockets[0], count: 1, deadline: ProcessInfo.processInfo.systemUptime + 0.02) }
        let payload = Data("payload".utf8)
        _ = payload.withUnsafeBytes { write(sockets[1], $0.baseAddress!, $0.count) }
        let received = try VPhoneControlTransfer.receive(fd: sockets[0], count: payload.count, deadline: ProcessInfo.processInfo.systemUptime + 1)
        precondition(received == payload)
        let empty = try VPhoneControlTransfer.receive(fd: sockets[0], count: 0, deadline: ProcessInfo.processInfo.systemUptime + 1)
        precondition(empty.isEmpty)
        _ = payload.withUnsafeBytes { write(sockets[1], $0.baseAddress!, $0.count) }
        let streamed = try VPhoneDownloadPath.openAtomicOutput(directory, name: "stream")
        let inMemory = try VPhoneControlTransfer.receive(fd: sockets[0], count: payload.count, deadline: ProcessInfo.processInfo.systemUptime + 1, output: streamed.fd)
        close(streamed.fd)
        try VPhoneDownloadPath.commit(directory, temporary: streamed.temporary, name: "stream")
        precondition(inMemory.isEmpty && tryData(output.appendingPathComponent("stream")) == payload)
        // A body larger than the receive buffer must preserve every chunk.
        let largePayload = Data((0..<(256 * 1024)).map { UInt8($0 % 251) })
        let writerFD = sockets[1]
        let writer = DispatchGroup()
        writer.enter()
        DispatchQueue.global().async {
            defer { writer.leave() }
            largePayload.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    let count = Darwin.write(writerFD, bytes.baseAddress! + offset, bytes.count - offset)
                    precondition(count > 0)
                    offset += count
                }
            }
        }
        let largeFile = try VPhoneDownloadPath.openAtomicOutput(directory, name: "large")
        let buffered = try VPhoneControlTransfer.receive(fd: sockets[0], count: largePayload.count,
            deadline: ProcessInfo.processInfo.systemUptime + 5, output: largeFile.fd)
        close(largeFile.fd)
        writer.wait()
        try VPhoneDownloadPath.commit(directory, temporary: largeFile.temporary, name: "large")
        precondition(buffered.isEmpty && tryData(output.appendingPathComponent("large")) == largePayload)
        shutdown(sockets[1], SHUT_WR)
        rejects { _ = try VPhoneControlTransfer.receive(fd: sockets[0], count: 1, deadline: ProcessInfo.processInfo.systemUptime + 1) }
        var stalled: [Int32] = [-1, -1]
        precondition(socketpair(AF_UNIX, SOCK_STREAM, 0, &stalled) == 0)
        defer { close(stalled[0]); close(stalled[1]) }
        try payload.withUnsafeBytes {
            try VPhoneControlTransfer.send(fd: stalled[0], bytes: $0,
                deadline: ProcessInfo.processInfo.systemUptime + 1)
        }
        let sent = try VPhoneControlTransfer.receive(fd: stalled[1], count: payload.count,
            deadline: ProcessInfo.processInfo.systemUptime + 1)
        precondition(sent == payload)
        let oversized = Data(repeating: 0x41, count: 4 * 1024 * 1024)
        let start = ProcessInfo.processInfo.systemUptime
        rejects {
            try oversized.withUnsafeBytes {
                try VPhoneControlTransfer.send(fd: stalled[0], bytes: $0, deadline: start + 0.05)
            }
        }
        precondition(ProcessInfo.processInfo.systemUptime - start < 2)
        close(stalled[1])
        stalled[1] = -1
        rejects {
            try payload.withUnsafeBytes {
                try VPhoneControlTransfer.send(fd: stalled[0], bytes: $0,
                    deadline: ProcessInfo.processInfo.systemUptime + 1)
            }
        }
        print("Security regressions passed: manifest paths, atomic downloads, strict transfer sizes, streaming, read/write deadlines, EOF")
    }

    static func tryData(_ url: URL) -> Data { try! Data(contentsOf: url) }
}

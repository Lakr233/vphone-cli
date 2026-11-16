import Foundation
import Testing
@testable import VPhoneCommandKit

/// Serialised so only one `hdiutil create -srcfolder` talks to the DiskImages
/// helper at a time; each create is also time-bounded and retried (see
/// `makeImage`).
@Suite(.serialized)
struct SealToolTests {
    private static let relativePath = "System/Library/Filesystems/apfs.fs/Contents/Resources/apfs_sealvolume"

    private func makeTemp() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sealtool-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Runs hdiutil, killing it after `timeout` seconds. The DiskImages helper
    /// that `hdiutil create` talks to stalls now and then on a busy host, and an
    /// unbounded wait would hang the whole run. Status 124 means it was killed.
    private func hdiutil(_ arguments: [String], timeout: TimeInterval = 60) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let timedOut = Flag()
        let pid = process.processIdentifier
        let killer = DispatchWorkItem {
            timedOut.set()
            kill(pid, SIGKILL)
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        killer.cancel()
        return (timedOut.value ? 124 : process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    /// A dmg holding `Self.relativePath` with `contents`, built from a folder.
    /// A create that stalls or leaves no file is retried, up to three times.
    private func makeImage(in dir: URL, contents: String?) throws -> URL {
        let source = dir.appendingPathComponent("src")
        let tool = source.appendingPathComponent(Self.relativePath)
        try FileManager.default.createDirectory(at: tool.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let contents { try Data(contents.utf8).write(to: tool) }
        let dmg = dir.appendingPathComponent("ramdisk.dmg")
        var last = ""
        for _ in 1 ... 3 {
            try? FileManager.default.removeItem(at: dmg)
            let made = try hdiutil(["create", "-srcfolder", source.path, "-format", "UDZO",
                                    "-volname", "Seal-\(UUID().uuidString.prefix(8))", "-quiet", dmg.path])
            if made.status == 0, FileManager.default.fileExists(atPath: dmg.path) { return dmg }
            last = "status \(made.status): \(made.output)"
        }
        throw HdiutilCreateFailure(detail: last)
    }

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var raised = false
        func set() { lock.lock(); raised = true; lock.unlock() }
        var value: Bool { lock.lock(); defer { lock.unlock() }; return raised }
    }

    struct HdiutilCreateFailure: Error, CustomStringConvertible {
        let detail: String
        var description: String { "hdiutil create failed three times, last \(detail)" }
    }

    @Test("copyOut copies the tool out of the image, marks it executable and detaches the image")
    func copyOutCopiesAndDetaches() throws {
        let dir = try makeTemp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let dmg = try makeImage(in: dir, contents: "sealvolume-bytes")
        let destination = dir.appendingPathComponent("apfs_sealvolume_26.0")
        var attached = false
        try VPhoneSealTool.copyOut(of: dmg, to: destination, attached: &attached)
        #expect(attached == false)
        #expect(try String(contentsOf: destination, encoding: .utf8) == "sealvolume-bytes")
        let mode = try FileManager.default.attributesOfItem(atPath: destination.path)[.posixPermissions] as? Int
        #expect(mode == 0o755)
        let info = try hdiutil(["info"])
        #expect(!info.output.contains(dir.lastPathComponent))
    }

    @Test("copyOut throws when the image has no tool, and still detaches the image")
    func copyOutMissingFile() throws {
        let dir = try makeTemp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let dmg = try makeImage(in: dir, contents: nil)
        let destination = dir.appendingPathComponent("apfs_sealvolume_26.0")
        var attached = false
        #expect(throws: (any Error).self) {
            try VPhoneSealTool.copyOut(of: dmg, to: destination, attached: &attached)
        }
        #expect(attached == false)
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        let info = try hdiutil(["info"])
        #expect(!info.output.contains(dir.lastPathComponent))
    }

    @Test("run returns the tool's stdout")
    func runReturnsStdout() throws {
        #expect(try VPhoneSealTool.run("/bin/echo", ["hello", "seal"]) == "hello seal\n")
    }

    @Test("run throws on a non-zero exit")
    func runThrowsOnFailure() {
        #expect(throws: (any Error).self) {
            try VPhoneSealTool.run("/usr/bin/false", [])
        }
    }

    @Test("isAppleHost accepts only credential-free https URLs on Apple restore hosts")
    func appleHostAllowList() throws {
        func ok(_ text: String) throws -> Bool {
            try VPhoneSealTool.isAppleHost(#require(URL(string: text)))
        }
        for host in ["updates.cdn-apple.com", "updates-http.cdn-apple.com", "appldnld.apple.com", "swcdn.apple.com"] {
            #expect(try ok("https://\(host)/a/b.ipsw"))
        }
        #expect(try !ok("http://updates.cdn-apple.com/a.ipsw"))
        #expect(try !ok("ftp://updates.cdn-apple.com/a.ipsw"))
        #expect(try !ok("https://example.com/a.ipsw"))
        #expect(try !ok("https://updates.cdn-apple.com.evil.example/a.ipsw"))
        #expect(try !ok("https://user@updates.cdn-apple.com/a.ipsw"))
        #expect(try !ok("https://user:pw@updates.cdn-apple.com/a.ipsw"))
        #expect(try !ok("https://evil.example/updates.cdn-apple.com"))
    }
}

import Foundation
import Testing
@testable import VPhoneCoreKit

struct MachineConsoleLogTests {
    private let root = "/Volumes/A/machines"

    @Test func `default root gives plain name`() {
        let url = VPhoneMachineConsoleLog.url(libraryRoot: root, name: "m1", defaultRoot: root)
        #expect(url.lastPathComponent == "m1.log")
        #expect(url.deletingLastPathComponent().path.hasSuffix("Library/Logs/vphone-launchpad"))
    }

    @Test func `other root gives name and eight hex digest`() {
        let url = VPhoneMachineConsoleLog.url(libraryRoot: "/Volumes/B", name: "m1", defaultRoot: root)
        let stem = url.deletingPathExtension().lastPathComponent
        #expect(stem.hasPrefix("m1-"))
        let digest = String(stem.dropFirst(3))
        #expect(digest.count == 8)
        #expect(digest.allSatisfy { $0.isHexDigit })
        #expect(url.pathExtension == "log")
    }

    @Test func `suffix is kept`() {
        #expect(VPhoneMachineConsoleLog.url(libraryRoot: root, name: "m1", suffix: "-patch", defaultRoot: root).lastPathComponent == "m1-patch.log")
        let other = VPhoneMachineConsoleLog.url(libraryRoot: "/Volumes/B", name: "m1", suffix: "-patch", defaultRoot: root)
        #expect(other.lastPathComponent == "m1-\(VPhoneMachineConsoleLog.digest("/Volumes/B"))-patch.log")
    }

    @Test func `same input gives same digest and different roots differ`() {
        #expect(VPhoneMachineConsoleLog.digest("/a") == VPhoneMachineConsoleLog.digest("/a"))
        #expect(VPhoneMachineConsoleLog.digest("/a") != VPhoneMachineConsoleLog.digest("/b"))
    }

    @Test func `library root variable is honoured as default`() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mcl-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let previous = getenv("VPHONE_LIBRARY_ROOT").map { String(cString: $0) }
        setenv("VPHONE_LIBRARY_ROOT", dir.path, 1)
        defer {
            if let previous { setenv("VPHONE_LIBRARY_ROOT", previous, 1) } else { unsetenv("VPHONE_LIBRARY_ROOT") }
        }
        let resolved = VPhoneMachineConsoleLog.defaultRoot(chosen: URL(fileURLWithPath: "/Volumes/Chosen"))
        #expect(resolved == VPhoneMachineConsoleLog.canonical(dir))
        #expect(VPhoneMachineConsoleLog.url(libraryRoot: resolved, name: "m1", defaultRoot: resolved).lastPathComponent == "m1.log")
    }
}

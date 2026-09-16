import Testing
import Foundation
@testable import VPhoneCore

struct DownloadPathTests {
    @Test func rejectsProtocolComponents() {
        for value in ["", ".", "..", "a/b", "a\0b"] {
            #expect(throws: VPhoneDownloadPathError.self) { try VPhoneDownloadPath.validateComponent(value) }
        }
    }

    @Test func atomicCommitDoesNotFollowDestinationSymlink() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let outside = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("sentinel".utf8).write(to: outside)
        let fd = try VPhoneDownloadPath.openDirectory(root)
        defer { close(fd) }
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("out"), withDestinationURL: outside)
        let temp = try VPhoneDownloadPath.openAtomicOutput(fd, name: "out.new")
        close(temp.fd)
        try VPhoneDownloadPath.commit(fd, temporary: temp.temporary, name: "out")
        #expect(String(data: try Data(contentsOf: outside), encoding: .utf8) == "sentinel")
    }
}

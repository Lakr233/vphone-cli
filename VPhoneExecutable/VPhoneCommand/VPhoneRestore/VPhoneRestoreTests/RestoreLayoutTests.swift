import Foundation
import Testing
@testable import VPhoneRestore

/// Restore directory and ticket naming rules. Both are contracts:
/// `--offline` picks the first `*.shsh` in a bundle, and restoring from
/// whichever of two firmware trees happened to sort first would flash a build
/// nobody chose.
struct RestoreLayoutTests {
    // MARK: - Fixtures

    /// A throwaway directory, removed when `body` returns.
    private func withTemporaryDirectory<R>(_ body: (URL) throws -> R) throws -> R {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vphone-layout-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        return try body(root)
    }

    private func makeDirectory(_ name: String, in root: URL) throws {
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(name, isDirectory: true),
            withIntermediateDirectories: true,
        )
    }

    // MARK: - Restore directory

    @Test func `finds the one restore tree`() throws {
        try withTemporaryDirectory { root in
            try makeDirectory("iPhone17,3_Restore", in: root)
            try makeDirectory("cfw_input", in: root)
            let found = try VPhoneRestoreLayout.findRestoreDirectory(in: root)
            #expect(found.lastPathComponent == "iPhone17,3_Restore")
        }
    }

    @Test func `no restore tree is an error`() throws {
        try withTemporaryDirectory { root in
            try makeDirectory("cfw_input", in: root)
            #expect(throws: VPhoneRestoreBackendError.noRestoreDirectory(root)) {
                try VPhoneRestoreLayout.findRestoreDirectory(in: root)
            }
        }
    }

    @Test func `missing bundle directory is the same error`() throws {
        // contentsOfDirectory fails rather than returning nothing; the caller
        // should still hear "no restore tree", not a Cocoa error.
        let absent = FileManager.default.temporaryDirectory
            .appendingPathComponent("vphone-absent-\(UUID().uuidString)", isDirectory: true)
        #expect(throws: VPhoneRestoreBackendError.noRestoreDirectory(absent)) {
            try VPhoneRestoreLayout.findRestoreDirectory(in: absent)
        }
    }

    @Test func `two restore trees are an error naming both`() throws {
        try withTemporaryDirectory { root in
            try makeDirectory("iPhone17,3_Restore", in: root)
            try makeDirectory("iPhone16,1_Restore", in: root)
            let expected = VPhoneRestoreBackendError
                .multipleRestoreDirectories(["iPhone16,1_Restore", "iPhone17,3_Restore"])
            #expect(throws: expected) {
                try VPhoneRestoreLayout.findRestoreDirectory(in: root)
            }
        }
    }

    @Test func `three restore trees are still an error`() throws {
        try withTemporaryDirectory { root in
            try makeDirectory("iPhone17,3_Restore", in: root)
            try makeDirectory("iPhone16,1_Restore", in: root)
            try makeDirectory("iPhone_Restore", in: root)
            let names = try VPhoneRestoreLayout.restoreDirectoryNames(in: root)
            #expect(names == ["iPhone16,1_Restore", "iPhone17,3_Restore", "iPhone_Restore"])
            #expect(throws: VPhoneRestoreBackendError.self) {
                try VPhoneRestoreLayout.findRestoreDirectory(in: root)
            }
        }
    }

    @Test func `a file with the right name is not A restore tree`() throws {
        try withTemporaryDirectory { root in
            // A stray file must not be handed to idevicerestore as a restore directory.
            try Data("not a tree".utf8)
                .write(to: root.appendingPathComponent("iPhone17,3_Restore"))
            #expect(throws: VPhoneRestoreBackendError.noRestoreDirectory(root)) {
                try VPhoneRestoreLayout.findRestoreDirectory(in: root)
            }
        }
    }

    @Test func `the glob star may match nothing`() throws {
        try withTemporaryDirectory { root in
            // "iPhone*_Restore" with an empty star. `hasPrefix` + `hasSuffix`
            // has to accept it, and the two literals cannot overlap, so it does.
            try makeDirectory("iPhone_Restore", in: root)
            let found = try VPhoneRestoreLayout.findRestoreDirectory(in: root)
            #expect(found.lastPathComponent == "iPhone_Restore")
        }
    }

    @Test(arguments: ["iPhone17,3", "iPhone", "17,3_Restore", "Restore", "iphone17,3_restore"])
    func `neighbouring names are not restore trees`(_ name: String) throws {
        try withTemporaryDirectory { root in
            try makeDirectory(name, in: root)
            let names = try VPhoneRestoreLayout.restoreDirectoryNames(in: root)
            #expect(names.isEmpty)
        }
    }

    @Test func `a symlink to a shared directory is not a restore tree`() throws {
        try withTemporaryDirectory { root in
            try makeDirectory("real_tree", in: root)
            try FileManager.default.createSymbolicLink(
                at: root.appendingPathComponent("iPhone17,3_Restore"),
                withDestinationURL: root.appendingPathComponent("real_tree"),
            )
            #expect(throws: VPhoneRestoreBackendError.noRestoreDirectory(root)) {
                try VPhoneRestoreLayout.findRestoreDirectory(in: root)
            }
        }
    }

    // MARK: - SHSH filename

    @Test func `shsh is named after the ECID in sixteen hex digits`() {
        let root = URL(fileURLWithPath: "/tmp/vm")
        #expect(VPhoneRestoreLayout.shshOutput(vmDir: root, ecid: 0x0000_0001_1A2B_3C4D).path
            == "/tmp/vm/000000011A2B3C4D.shsh")
        #expect(VPhoneRestoreLayout.shshOutput(vmDir: root, ecid: 1).path
            == "/tmp/vm/0000000000000001.shsh")
    }

    @Test func `shsh falls back to auto without an ECID`() {
        let root = URL(fileURLWithPath: "/tmp/vm")
        #expect(VPhoneRestoreLayout.shshOutput(vmDir: root, ecid: nil).path == "/tmp/vm/auto.shsh")
    }

    @Test func `the derived name is the one offline restores look for`() {
        // `vphone-cli restore --offline` takes the first *.shsh in the bundle.
        // Whatever else changes, the extension has to stay.
        let derived = VPhoneRestoreLayout.shshOutput(
            vmDir: URL(fileURLWithPath: "/tmp/vm"),
            ecid: 0xAABB,
        )
        #expect(derived.pathExtension == "shsh")
        #expect(derived.deletingPathExtension().lastPathComponent == "000000000000AABB")
    }
}

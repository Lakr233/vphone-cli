import Darwin
import Foundation
import Testing
@testable import VPhoneCoreKit

struct ConfinedDirectoryTests {
    /// A canonical scratch tree: `root/` is the confinement root, `outside/`
    /// holds `keep`, and `root/link` points at `outside/`.
    private struct Tree {
        let base: URL
        let root: URL
        let outside: URL
        let kept: URL

        init() throws {
            let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
            guard let resolved = realpath(temporary.path, nil) else { throw POSIXError(.ENOENT) }
            base = URL(fileURLWithPath: String(cString: resolved))
            free(resolved)
            root = base.appendingPathComponent("root")
            outside = base.appendingPathComponent("outside")
            kept = outside.appendingPathComponent("keep")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
            try Data("keep".utf8).write(to: kept)
            try FileManager.default.createSymbolicLink(
                at: root.appendingPathComponent("link"),
                withDestinationURL: outside,
            )
        }

        func remove() {
            try? FileManager.default.removeItem(at: base)
        }

        func outsideNames() throws -> [String] {
            try FileManager.default.contentsOfDirectory(atPath: outside.path).sorted()
        }

        func source(_ text: String) throws -> URL {
            let url = base.appendingPathComponent("source-\(UUID().uuidString)")
            try Data(text.utf8).write(to: url)
            return url
        }
    }

    private func mode(_ url: URL) -> mode_t {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0 else { return 0 }
        return metadata.st_mode
    }

    // MARK: - Intermediate links

    @Test func `an intermediate symlink is refused by every operation`() throws {
        let tree = try Tree()
        defer { tree.remove() }
        let root = try VPhoneConfinedDirectory(root: tree.root.path)
        let source = try tree.source("new")

        #expect(throws: (any Error).self) { try root.replaceFile("link/new", fromFileAt: source, mode: 0o644) }
        #expect(throws: (any Error).self) { try root.writeFile("link/new", contents: Data(), mode: 0o644) }
        #expect(throws: (any Error).self) { try root.removeItem("link/keep") }
        #expect(throws: (any Error).self) { try root.createSymlink(target: "/etc", at: "link/alias") }
        #expect(throws: (any Error).self) { try root.directory("link") }
        #expect(throws: (any Error).self) { try root.directory("link/sub", create: true) }
        #expect(throws: (any Error).self) { try root.readData("link/keep") }
        #expect(throws: (any Error).self) { try root.setMode("link/keep", 0o777) }
        #expect(throws: (any Error).self) { try root.status("link/keep") }

        #expect(try tree.outsideNames() == ["keep"])
        #expect(try Data(contentsOf: tree.kept) == Data("keep".utf8))
        #expect(mode(tree.kept) & 0o777 != 0o777)
    }

    @Test func `pin refuses a symlink anywhere in the path and checks the owner`() throws {
        let tree = try Tree()
        defer { tree.remove() }

        #expect(throws: VPhoneConfinedDirectoryError.self) {
            try VPhoneConfinedDirectory.pin(absolutePath: tree.root.appendingPathComponent("link").path)
        }
        let pinned = try VPhoneConfinedDirectory.pin(absolutePath: tree.root.path, requireOwner: getuid())
        #expect(try pinned.path == tree.root.path)
        #expect(throws: VPhoneConfinedDirectoryError.self) {
            try VPhoneConfinedDirectory.pin(absolutePath: tree.root.path, requireOwner: getuid() &+ 1)
        }
    }

    // MARK: - Leaf links

    @Test func `a leaf symlink is replaced, not followed`() throws {
        let tree = try Tree()
        defer { tree.remove() }
        let root = try VPhoneConfinedDirectory(root: tree.root.path)
        let leaf = tree.root.appendingPathComponent("leaf")
        try FileManager.default.createSymbolicLink(at: leaf, withDestinationURL: tree.kept)

        try root.replaceFile("leaf", fromFileAt: tree.source("replaced"), mode: 0o644)

        #expect(mode(leaf) & S_IFMT == S_IFREG)
        #expect(mode(leaf) & 0o7777 == 0o644)
        #expect(try Data(contentsOf: leaf) == Data("replaced".utf8))
        #expect(try Data(contentsOf: tree.kept) == Data("keep".utf8))
        #expect(try tree.outsideNames() == ["keep"])
        // The temporary beside the leaf is gone.
        #expect(try FileManager.default.contentsOfDirectory(atPath: tree.root.path).sorted() == ["leaf", "link"])
    }

    @Test func `reading a leaf symlink is refused`() throws {
        let tree = try Tree()
        defer { tree.remove() }
        let root = try VPhoneConfinedDirectory(root: tree.root.path)
        try FileManager.default.createSymbolicLink(
            at: tree.root.appendingPathComponent("leaf"),
            withDestinationURL: tree.kept,
        )
        #expect(throws: (any Error).self) { try root.readData("leaf") }
        #expect(throws: (any Error).self) { try root.copyFile(from: "leaf", to: "copy") }
        #expect(try root.readLink("leaf") == tree.kept.path)
        #expect(try root.isSymlink("leaf"))
    }

    @Test func `createSymlink replaces an existing link and removeItem removes only the link`() throws {
        let tree = try Tree()
        defer { tree.remove() }
        let root = try VPhoneConfinedDirectory(root: tree.root.path)

        try root.createSymlink(target: "../elsewhere", at: "link")
        #expect(try root.readLink("link") == "../elsewhere")
        try root.removeItem("link")
        #expect(try !root.exists("link"))
        #expect(try tree.outsideNames() == ["keep"])
    }

    // MARK: - Removal

    @Test func `removeItem on a folder holding a link to outside leaves the target intact`() throws {
        let tree = try Tree()
        defer { tree.remove() }
        let root = try VPhoneConfinedDirectory(root: tree.root.path)
        let folder = tree.root.appendingPathComponent("tree/nested")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("file".utf8).write(to: folder.appendingPathComponent("file"))
        try FileManager.default.createSymbolicLink(
            at: folder.appendingPathComponent("escape"),
            withDestinationURL: tree.outside,
        )
        #expect(chmod(folder.path, 0o555) == 0)

        try root.removeItem("tree")

        #expect(!FileManager.default.fileExists(atPath: tree.root.appendingPathComponent("tree").path))
        #expect(try tree.outsideNames() == ["keep"])
        #expect(try Data(contentsOf: tree.kept) == Data("keep".utf8))
        // Absent is not an error.
        try root.removeItem("tree")
    }

    // MARK: - Tree copy

    @Test func `copyTree refuses a hard-linked source file`() throws {
        let tree = try Tree()
        defer { tree.remove() }
        let root = try VPhoneConfinedDirectory(root: tree.root.path)
        let sourceURL = tree.base.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: sourceURL, withIntermediateDirectories: true)
        #expect(link(tree.kept.path, sourceURL.appendingPathComponent("linked").path) == 0)
        let source = try VPhoneConfinedDirectory(root: sourceURL.path)

        #expect(throws: VPhoneConfinedDirectoryError.hardLinked("copy/linked")) {
            try root.copyTree(from: source, to: "copy", requireSourceOwner: getuid())
        }
        #expect(throws: VPhoneConfinedDirectoryError.self) {
            try root.copyTree(from: source, to: "copy-foreign", requireSourceOwner: getuid() &+ 1)
        }
    }

    @Test func `copyTree recreates links as links and never follows them`() throws {
        let tree = try Tree()
        defer { tree.remove() }
        let root = try VPhoneConfinedDirectory(root: tree.root.path)
        let sourceURL = tree.base.appendingPathComponent("source")
        try FileManager.default.createDirectory(
            at: sourceURL.appendingPathComponent("Contents"),
            withIntermediateDirectories: true,
        )
        let executable = sourceURL.appendingPathComponent("Contents/binary")
        try Data("binary".utf8).write(to: executable)
        #expect(chmod(executable.path, 0o4755) == 0)
        try FileManager.default.createSymbolicLink(
            at: sourceURL.appendingPathComponent("escape"),
            withDestinationURL: tree.outside,
        )
        let source = try VPhoneConfinedDirectory(root: sourceURL.path)

        try root.copyTree(from: source, to: "deep/copy", requireSourceOwner: getuid())

        let copy = tree.root.appendingPathComponent("deep/copy")
        #expect(try FileManager.default.destinationOfSymbolicLink(
            atPath: copy.appendingPathComponent("escape").path,
        ) == tree.outside.path)
        let copied = copy.appendingPathComponent("Contents/binary")
        #expect(try Data(contentsOf: copied) == Data("binary".utf8))
        #expect(mode(copied) & 0o7777 == 0o755)
        #expect(try tree.outsideNames() == ["keep"])
        // The destination must be new.
        #expect(throws: VPhoneConfinedDirectoryError.self) {
            try root.copyTree(from: source, to: "deep/copy")
        }
    }

    // MARK: - Path validation

    @Test func `dot-dot and absolute relative paths are rejected`() throws {
        let tree = try Tree()
        defer { tree.remove() }
        let root = try VPhoneConfinedDirectory(root: tree.root.path)
        let source = try tree.source("x")

        for path in ["..", "../outside/keep", "a/../b", "/tmp/x", "", ".", "a//b", "a/"] {
            #expect(throws: VPhoneConfinedDirectoryError.invalidPath(path)) { try root.directory(path) }
            #expect(throws: VPhoneConfinedDirectoryError.invalidPath(path)) { try root.removeItem(path) }
            #expect(throws: VPhoneConfinedDirectoryError.invalidPath(path)) {
                try root.replaceFile(path, fromFileAt: source, mode: 0o644)
            }
        }
        #expect(try tree.outsideNames() == ["keep"])
    }

    // MARK: - Round trip

    @Test func `write, copy, rename and read stay inside the root`() throws {
        let tree = try Tree()
        defer { tree.remove() }
        let root = try VPhoneConfinedDirectory(root: tree.root.path)

        _ = try root.directory("a/b", create: true, mode: 0o700)
        try root.writeFile("a/b/file", contents: Data("one".utf8), mode: 0o640)
        try root.copyFile(from: "a/b/file", to: "a/b/file.bak")
        try root.rename("a/b/file.bak", to: "a/moved")
        #expect(try root.readData("a/moved") == Data("one".utf8))
        #expect(mode(tree.root.appendingPathComponent("a/moved")) & 0o7777 == 0o640)
        #expect(try root.directory("a").entries() == ["b", "moved"])
        try root.setMode("a/moved", 0o600)
        #expect(mode(tree.root.appendingPathComponent("a/moved")) & 0o7777 == 0o600)
    }
}

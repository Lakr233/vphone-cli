// CryptexFileOpsTests.swift — the file operations that replaced chmod, chown, ln and find.
//
// These are not wrappers with obvious behaviour: each one reproduces a specific
// flag of the tool it replaced, and the defaults differ. `chown -R` does not
// follow symlinks; `ln -sf` stores its destination verbatim and replaces what
// is already there; `find -name '._*' -delete` reaches nested directories. What
// is asserted here is exactly those properties, because they are what a guest
// volume ends up depending on.
//
// The diskutil plist parse is here too. It replaced a `/bin/sh -c` pipeline into
// `plutil`, and it has to survive the thing that pipeline could not: runProcess
// merges stderr into stdout, so diskutil's own chatter can arrive in front of
// the plist.

@testable import FirmwarePatcher
import Foundation
import Testing

@Suite("Cryptex file operations")
struct CryptexFileOpsTests {
    /// A patcher is only needed for the methods; nothing here reads a manifest.
    private func makePatcher(_ scratch: URL) -> CryptexFilesystemPatcher {
        CryptexFilesystemPatcher(buildManiest: Data(), restoreDir: scratch, verbose: false)
    }

    private func makeScratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("vphone-fileops-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func mode(of url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    /// `open(2)`, and it has to be: Foundation intercepts a `._name` and folds
    /// what you write into the partner file's extended attributes instead of
    /// creating a directory entry. A fixture made with `Data.write(to:)` is
    /// therefore invisible to `readdir` — to `find`, to the code under test,
    /// and to `contentsOfDirectory`, which lists the directory as empty. tar
    /// and libarchive write with `open(2)`, which is why these files really do
    /// turn up on a volume and really do have to be swept.
    private func touch(_ url: URL) throws {
        let fd = open(url.path, O_CREAT | O_WRONLY | O_TRUNC, 0o644)
        guard fd >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [
                NSFilePathErrorKey: url.path,
            ])
        }
        close(fd)
    }

    /// What the directory actually contains, read the way `find` reads it.
    ///
    /// The counterpart to `touch`: `FileManager.contentsOfDirectory` omits
    /// `._*` entries and `fileExists(atPath:)` answers *true* for one that was
    /// never there, because Foundation reads those names as a partner file's
    /// metadata. Neither can tell this test whether a sweep worked. `readdir`
    /// can, and it is deliberately a second implementation rather than a call
    /// into the code under test.
    private func realEntryNames(in directory: URL) -> [String] {
        guard let handle = opendir(directory.path) else { return [] }
        defer { closedir(handle) }
        var names: [String] = []
        while let entry = readdir(handle) {
            var storage = entry.pointee.d_name
            let name = withUnsafePointer(to: &storage) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) {
                    String(cString: $0)
                }
            }
            if name != ".", name != ".." {
                names.append(name)
            }
        }
        return names.sorted()
    }

    // MARK: - chmod

    @Test func `the mode is the mode it was given`() throws {
        let scratch = try makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let patcher = makePatcher(scratch)

        let file = scratch.appendingPathComponent("binary")
        try Data("x".utf8).write(to: file)

        try patcher.setMode(0o755, at: file)
        #expect(try mode(of: file) == 0o755)

        // Down as well as up: the umask must not get a say, which is the part
        // `chmod 0644` guaranteed and a FileManager create does not.
        try patcher.setMode(0o644, at: file)
        #expect(try mode(of: file) == 0o644)
    }

    // MARK: - ln -sf

    @Test func `a symlink stores its destination verbatim`() throws {
        let scratch = try makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let patcher = makePatcher(scratch)

        // The real one. It is relative because it is resolved inside the guest,
        // where these ../.. hops land in the cryptex — resolving it here would
        // bake in a host path and break the volume.
        let destination = "../../../System/Cryptexes/OS/System/Library/Caches/com.apple.dyld"
        let link = scratch.appendingPathComponent("com.apple.dyld")
        try patcher.createSymlink(at: link, to: destination)

        let stored = try FileManager.default.destinationOfSymbolicLink(atPath: link.path)
        #expect(stored == destination)
    }

    @Test func `rerunning replaces the link instead of failing`() throws {
        let scratch = try makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let patcher = makePatcher(scratch)

        // `ln -sf is idempotent` is what cfw_install.sh said about running this
        // step twice, and the installer does run it twice.
        let link = scratch.appendingPathComponent("dyld")
        try patcher.createSymlink(at: link, to: "../first")
        try patcher.createSymlink(at: link, to: "../second")

        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == "../second")
    }

    @Test func `a plain file in the way is replaced`() throws {
        let scratch = try makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let patcher = makePatcher(scratch)

        let link = scratch.appendingPathComponent("dyld")
        try Data("not a link".utf8).write(to: link)
        try patcher.createSymlink(at: link, to: "../elsewhere")

        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == "../elsewhere")
    }

    @Test func `a directory in the way is an error rather than A nested link`() throws {
        let scratch = try makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let patcher = makePatcher(scratch)

        let link = scratch.appendingPathComponent("dyld")
        try FileManager.default.createDirectory(at: link, withIntermediateDirectories: false)

        // This is the one place the port deliberately differs from ln(1), which
        // would have created the link *inside* the directory and left the guest
        // with a dyld path resolving to nothing.
        #expect(throws: CryptexFileOperationError.self) {
            try patcher.createSymlink(at: link, to: "../elsewhere")
        }
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: link.path, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
    }

    // MARK: - find -name '._*' -delete

    @Test func `apple double files go including nested ones`() throws {
        let scratch = try makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let patcher = makePatcher(scratch)

        let bundle = scratch.appendingPathComponent("Driver.bundle")
        let codeSignature = bundle.appendingPathComponent("_CodeSignature")
        try FileManager.default.createDirectory(at: codeSignature, withIntermediateDirectories: true)

        let doomed = [
            bundle.appendingPathComponent("._Info.plist"),
            bundle.appendingPathComponent("._Driver"),
            codeSignature.appendingPathComponent("._CodeResources"),
        ]
        let kept = [
            bundle.appendingPathComponent("Info.plist"),
            codeSignature.appendingPathComponent("CodeResources"),
        ]
        for file in doomed + kept {
            try touch(file)
        }
        // The fixture has to be real before the sweep is worth anything: if
        // `touch` had gone through Foundation, these names would not be here
        // and the sweep would "pass" by finding nothing.
        #expect(realEntryNames(in: bundle) == ["._Driver", "._Info.plist", "Info.plist", "_CodeSignature"])

        let removed = try patcher.deleteAppleDoubleFiles(under: bundle)
        #expect(removed == 3)

        // A `._CodeResources` beside the real `CodeResources` is how the bundle
        // came out unloadable; removing the wrong one of the pair would be the
        // same bug facing the other way.
        #expect(realEntryNames(in: bundle) == ["Info.plist", "_CodeSignature"])
        #expect(realEntryNames(in: codeSignature) == ["CodeResources"])
    }

    @Test func `a tree with none of them is not A failure`() throws {
        let scratch = try makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let patcher = makePatcher(scratch)

        try Data("x".utf8).write(to: scratch.appendingPathComponent("Info.plist"))
        #expect(try patcher.deleteAppleDoubleFiles(under: scratch) == 0)
    }

    // MARK: - chown -R

    @Test func `the ownership walk does not follow symlinks`() throws {
        let scratch = try makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let patcher = makePatcher(scratch)

        let nested = scratch.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: false)
        try Data("x".utf8).write(to: nested.appendingPathComponent("file"))
        // A dangling link is the observable difference between lchown and chown
        // without root: chown(2) resolves the target and fails with ENOENT,
        // lchown(2) changes the link itself and succeeds. BSD `chown -R`
        // defaults to the latter, and so must this.
        try FileManager.default.createSymbolicLink(
            atPath: nested.appendingPathComponent("dangling").path,
            withDestinationPath: "../../gone/missing",
        )

        // Re-applying the ids this process already has: a no-op that still
        // walks and still calls lchown on every entry, so it is the whole code
        // path minus the privilege.
        try patcher.chownRecursively(uid: getuid(), gid: getgid(), at: scratch)
    }

    // MARK: - diskutil image resize --plist

    private static let sizesPlist = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" \
    "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
        <key>current</key><integer>8589934592</integer>
        <key>max</key><integer>21474836480</integer>
        <key>min</key><integer>1073741824</integer>
    </dict>
    </plist>
    """

    @Test func `the max size comes back as the string diskutil wants back`() throws {
        #expect(try CryptexFilesystemPatcher.maxResizeSize(
            fromDiskutilPlist: Self.sizesPlist,
        ) == "21474836480")
    }

    @Test func `noise in front of the plist does not break the parse`() throws {
        // runProcess points stderr at the same pipe as stdout, so this is what
        // a diskutil with anything to say actually returns. The shell pipeline
        // this replaced handed that whole string to `--size`.
        let noisy = "Warning: some warning from diskutil\n" + Self.sizesPlist
        #expect(try CryptexFilesystemPatcher.maxResizeSize(
            fromDiskutilPlist: noisy,
        ) == "21474836480")
    }

    @Test func `output that is not A plist is an error`() {
        #expect(throws: ProcessError.self) {
            try CryptexFilesystemPatcher.maxResizeSize(
                fromDiskutilPlist: "Could not find disk: /tmp/nope.img",
            )
        }
    }

    @Test func `a plist without A max key is an error`() {
        let withoutMax = Self.sizesPlist.replacingOccurrences(
            of: "<key>max</key>", with: "<key>maximum</key>",
        )
        #expect(throws: ProcessError.self) {
            try CryptexFilesystemPatcher.maxResizeSize(fromDiskutilPlist: withoutMax)
        }
    }
}

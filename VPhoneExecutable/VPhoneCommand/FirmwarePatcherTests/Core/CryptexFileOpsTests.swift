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
    @Test("Guest file edits reject symlink parents and leaves")
    func guestEditsStayInsideImage() throws {
        let root = try makeScratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let image = root.appending(path: "image")
        let outside = root.appending(path: "outside")
        try FileManager.default.createDirectory(at: image, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let file = outside.appending(path: "payload")
        try Data("unchanged".utf8).write(to: file)
        let patcher = makePatcher(root)
        try FileManager.default.createSymbolicLink(at: image.appending(path: "parent"), withDestinationURL: outside)
        #expect(throws: (any Error).self) {
            try patcher.editGuestFile("parent/payload", targetMount: image.path, mode: 0o644) { _ in Issue.record("Followed a guest symlink") }
        }
        try FileManager.default.createSymbolicLink(at: image.appending(path: "leaf"), withDestinationURL: file)
        #expect(throws: (any Error).self) {
            try patcher.editGuestFile("leaf", targetMount: image.path, mode: 0o644) { _ in Issue.record("Followed a guest symlink") }
        }
        #expect(try String(contentsOf: file, encoding: .utf8) == "unchanged")
    }

    @Test("Cryptex copying keeps symlinks as links")
    func cryptexCopyDoesNotFollowLinks() throws {
        let root = try makeScratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "source")
        let destination = root.appending(path: "destination")
        try FileManager.default.createDirectory(at: source.appending(path: "folder"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data("file".utf8).write(to: source.appending(path: "folder/file"))
        try FileManager.default.createSymbolicLink(atPath: source.appending(path: "link").path, withDestinationPath: "folder/file")
        try makePatcher(root).copyImageContents(source: source, destination: destination)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: destination.appending(path: "link").path) == "folder/file")
        #expect(try String(contentsOf: destination.appending(path: "folder/file"), encoding: .utf8) == "file")
    }

    /// A patcher is only needed for the methods; nothing here reads a manifest.
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

    // MARK: - Seal remap time

    private func writeMtree(root: String, in scratch: URL) throws -> URL {
        let mtree = scratch.appendingPathComponent("mtree.txt")
        try ("""
        #\t   tree: /Volumes/LuckG23G71.D47OS

        # .
        /set type=file uid=0 gid=0 mode=0755 nlink=1 flags=none

        """ + root + """
            .file       gid=80 mode=0 size=0 time=1784253250.000000000

        # ./private/var
        var             type=dir nlink=31 size=992 time=1792405582.936736187

        # ./private/var/MobileAsset
        MobileAsset     type=dir uid=0 gid=0 nlink=2 size=64 \\
                        time=1792405581.550614134

        """).write(to: mtree, atomically: true, encoding: .utf8)
        return mtree
    }

    @Test(arguments: [
        ".               type=dir nlink=19 size=608 time=1792405582.069334279\n",
        ".               type=dir nlink=19 \\\n                size=608 time=1792405582.069334279\n",
    ])
    func `the remap time is the first edited entry's, not the newest one's`(root: String) throws {
        // 26.6, 2026-10-19 (browsable mounts): removing the host's
        // .fseventsd edited the root, and the device took the root's time.
        let scratch = try makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let mtree = try writeMtree(root: root, in: scratch)
        let since = Date(timeIntervalSince1970: 1_792_405_580.9)
        #expect(try makePatcher(scratch).parseEditTime(mtree: mtree, since: since) == "1792405582069334279")
    }

    @Test func `an unedited root leaves the remap time to the first edited directory`() throws {
        // 18.6, 2026-10-23 (-nobrowse mounts): the root kept the IPSW's
        // time, and the device took /private/var's, which comes before
        // MobileAsset in walk order.
        let scratch = try makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let root = ".               type=dir nlink=19 size=608 time=1753444429.383219423\n"
        let mtree = try writeMtree(root: root, in: scratch)
        let since = Date(timeIntervalSince1970: 1_792_405_580.9)
        #expect(try makePatcher(scratch).parseEditTime(mtree: mtree, since: since) == "1792405582936736187")
    }

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

    @Test func `only an image with no partition map is grown past diskutil's limit`() {
        // `diskutil image attach -noMount` on macOS 27.0: a GPT image, then
        // one whose APFS container is the whole image, as watchOS 26.4's is.
        let partitioned = "/dev/disk18  \tGUID_partition_scheme\n/dev/disk18s1\tApple_APFS\n"
            + "/dev/disk19  \tApple_APFS_Container\n/dev/disk19s1\tApple_APFS_Volume\n"
        let whole = "/dev/disk18\n/dev/disk19  \tApple_APFS_Container\n/dev/disk19s1\tApple_APFS_Volume\n"
        #expect(CryptexFilesystemPatcher.hasPartitionMap(attachOutput: partitioned))
        #expect(!CryptexFilesystemPatcher.hasPartitionMap(attachOutput: whole))
        #expect(!CryptexFilesystemPatcher.hasPartitionMap(attachOutput: ""))
    }

    @Test func `a plist without A max key is an error`() {
        let withoutMax = Self.sizesPlist.replacingOccurrences(
            of: "<key>max</key>",
            with: "<key>maximum</key>",
        )
        #expect(throws: ProcessError.self) {
            try CryptexFilesystemPatcher.maxResizeSize(fromDiskutilPlist: withoutMax)
        }
    }
}

import CryptoKit
import Darwin
import Foundation

/// Installs one VPhone.bundle release into the root-owned store.
enum VPhoneLaunchpadHelperBundleInstaller {
    static func install(version: String, archive: FileHandle, sha256: String) throws {
        guard VPhoneLaunchpadNames.isValidVersion(version) else {
            throw VPhoneLaunchpadHelperError("\"\(version)\" is not a valid bundle version.")
        }
        let expected = sha256.lowercased().replacingOccurrences(of: "sha256:", with: "")
        guard expected.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else {
            throw VPhoneLaunchpadHelperError("The published SHA-256 \"\(sha256)\" is not valid.")
        }

        let fileManager = FileManager.default
        try prepareStoreRoot()
        let staging = VPhoneLaunchpadBundleStore.root
            .appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(
            at: staging,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700],
        )
        defer { try? fileManager.removeItem(at: staging) }

        // Copy and hash in one pass, so the bytes that were checked are the
        // bytes that get extracted. The caller's file stays out of reach.
        let archiveURL = staging.appendingPathComponent("VPhone.zip")
        let actual = try copyAndHash(from: archive, to: archiveURL)
        guard actual == expected else {
            throw VPhoneLaunchpadHelperError("The download does not match the published SHA-256. Download it again.")
        }

        let extracted = staging.appendingPathComponent("extracted", isDirectory: true)
        try runTool("/usr/bin/ditto", ["-x", "-k", "--noqtn", archiveURL.path, extracted.path])
        let bundle = extracted.appendingPathComponent("VPhone.bundle", isDirectory: true)
        try requireDirectory(bundle, "The download does not contain VPhone.bundle. Download it again.")
        for name in VPhoneLaunchpadBundleStore.pinnedExecutables {
            let executable = bundle.appendingPathComponent("Contents/MacOS/\(name)")
            try requireRegularFile(executable, "VPhone.bundle is missing \(name). Download it again.")
        }

        try VPhoneLaunchpadHelperCodeCheck.requireValidBundle(bundle)
        var cdhashes: [String: String] = [:]
        for name in VPhoneLaunchpadBundleStore.pinnedExecutables {
            cdhashes[name] = try VPhoneLaunchpadHelperCodeCheck.cdhash(
                of: bundle.appendingPathComponent("Contents/MacOS/\(name)"),
            )
        }
        try makeRootOwned(bundle)

        let destination = VPhoneLaunchpadBundleStore.directory(version: version)
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.createDirectory(
            at: destination,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o755],
        )
        try fileManager.moveItem(at: bundle, to: VPhoneLaunchpadBundleStore.bundle(version: version))

        let receipt = VPhoneLaunchpadBundleReceipt(
            version: version,
            sha256: actual,
            installedAt: Date(),
            cdhashes: cdhashes,
        )
        let receiptURL = VPhoneLaunchpadBundleStore.receipt(version: version)
        try VPhoneLaunchpadBundleReceipt.encoder.encode(receipt).write(to: receiptURL, options: .atomic)
        chmod(receiptURL.path, 0o644)
    }

    static func remove(version: String) throws {
        guard VPhoneLaunchpadNames.isValidVersion(version) else {
            throw VPhoneLaunchpadHelperError("\"\(version)\" is not a valid bundle version.")
        }
        let directory = VPhoneLaunchpadBundleStore.directory(version: version)
        guard FileManager.default.fileExists(atPath: directory.path) else {
            return
        }
        try FileManager.default.removeItem(at: directory)
    }

    // MARK: - Store root

    /// Creates the store and refuses to use one that anyone but root could
    /// have prepared, since the helper later executes from it.
    private static func prepareStoreRoot() throws {
        let parent = VPhoneLaunchpadBundleStore.root.deletingLastPathComponent()
        for directory in [parent, VPhoneLaunchpadBundleStore.root] {
            if !FileManager.default.fileExists(atPath: directory.path) {
                try FileManager.default.createDirectory(
                    at: directory,
                    withIntermediateDirectories: false,
                    attributes: [.posixPermissions: 0o755, .ownerAccountID: 0, .groupOwnerAccountID: 0],
                )
            }
            var info = stat()
            guard lstat(directory.path, &info) == 0,
                  (info.st_mode & S_IFMT) == S_IFDIR,
                  info.st_uid == 0,
                  info.st_mode & 0o022 == 0
            else {
                throw VPhoneLaunchpadHelperError(
                    "\(directory.path) is not secure. It must be a folder owned by root that only root can modify.",
                )
            }
        }
    }

    // MARK: - File helpers

    private static func copyAndHash(from source: FileHandle, to destination: URL) throws -> String {
        guard FileManager.default.createFile(
            atPath: destination.path,
            contents: nil,
            attributes: [.posixPermissions: 0o600],
        ) else {
            throw VPhoneLaunchpadHelperError("Unable to save the download. Try again.")
        }
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        var hasher = SHA256()
        try source.seek(toOffset: 0)
        while let chunk = try source.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
            try output.write(contentsOf: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// root:wheel and no group or other write bit anywhere in the tree.
    /// lchown and a symlink check keep this from following links out. The
    /// tree is checked first, and the mode mask also clears setuid, setgid
    /// and sticky bits, so nothing in the store runs as root by itself.
    private static func makeRootOwned(_ root: URL) throws {
        var entries = [(path: root.path, relative: "")]
        if let enumerator = FileManager.default.enumerator(atPath: root.path) {
            for case let relative as String in enumerator {
                entries.append((root.appendingPathComponent(relative).path, relative))
            }
        }
        for entry in entries {
            try requireSafeEntry(entry.path, relative: entry.relative)
        }
        for entry in entries {
            var info = stat()
            guard lstat(entry.path, &info) == 0 else {
                throw VPhoneLaunchpadHelperError("Unable to install VPhone.bundle. Try again.")
            }
            guard lchown(entry.path, 0, 0) == 0 else {
                throw VPhoneLaunchpadHelperError("Unable to install VPhone.bundle. Try again.")
            }
            if (info.st_mode & S_IFMT) != S_IFLNK {
                chmod(entry.path, info.st_mode & 0o0755)
            }
        }
    }

    /// Refuses setuid or setgid entries, hard-linked files, devices, FIFOs,
    /// sockets, and symbolic links that point outside the bundle.
    private static func requireSafeEntry(_ path: String, relative: String) throws {
        var info = stat()
        guard lstat(path, &info) == 0 else {
            throw VPhoneLaunchpadHelperError("Unable to install VPhone.bundle. Try again.")
        }
        let unsafe = VPhoneLaunchpadHelperError("VPhone.bundle contains an unsafe file at \(relative). Download it again.")
        guard info.st_mode & (S_ISUID | S_ISGID) == 0 else {
            throw unsafe
        }
        switch info.st_mode & S_IFMT {
        case S_IFDIR:
            break
        case S_IFREG:
            guard info.st_nlink == 1 else {
                throw unsafe
            }
        case S_IFLNK:
            var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
            let length = readlink(path, &buffer, Int(PATH_MAX))
            guard length > 0 else {
                throw unsafe
            }
            let target = String(decoding: buffer[..<length].map { UInt8(bitPattern: $0) }, as: UTF8.self)
            guard !target.hasPrefix("/"), staysInside(link: relative, target: target) else {
                throw unsafe
            }
        default:
            throw unsafe
        }
    }

    /// Resolves `target` lexically from the folder holding `link` (both
    /// relative to the bundle root) and reports whether it stays inside.
    ///
    /// The enumerator walks only real folders, so leading `..` components
    /// climb real folders. A `..` after a named component is refused: that
    /// name may itself be a link (`sub/up -> ..`, then `sub/x -> up/..`), and
    /// the climb would then land above where the lexical walk says.
    private static func staysInside(link: String, target: String) -> Bool {
        var stack = link.split(separator: "/").dropLast().map(String.init)
        var descended = false
        for component in target.split(separator: "/") {
            switch component {
            case ".":
                continue
            case "..":
                guard !descended, !stack.isEmpty else {
                    return false
                }
                stack.removeLast()
            default:
                descended = true
                stack.append(String(component))
            }
        }
        return true
    }

    private static func requireDirectory(_ url: URL, _ message: String) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else {
            throw VPhoneLaunchpadHelperError(message)
        }
    }

    private static func requireRegularFile(_ url: URL, _ message: String) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            throw VPhoneLaunchpadHelperError(message)
        }
    }

    private static func runTool(_ path: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw VPhoneLaunchpadHelperError(
                "Unable to extract the downloaded archive. Download it again.",
            )
        }
    }
}

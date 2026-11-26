import Darwin
import Foundation
import VPhoneSign

// MARK: - RootHide root

extension GuestIrisinInstaller {
    static let roothideParent = "/private/var/containers/Bundle/Application"
    /// The one RootHide root vphone installs and loads: a user-selected stem,
    /// zero-padded to 16 hex digits with RootHide's XOR checksum in the final
    /// byte (0C instead of the proposed 10). The launchd hook names it too.
    static let roothideRoot = roothideParent + "/.jbroot-000114514191980C"

    static func roothideName(_ name: String) -> Bool {
        guard name.range(of: "^\\.jbroot-[0-9a-fA-F]{16}$", options: .regularExpression) != nil,
              let value = UInt64(name.dropFirst(8), radix: 16)
        else { return false }
        let check = (1 ... 7).reduce(UInt8(0)) {
            $0 ^ UInt8(truncatingIfNeeded: value >> ($1 * 8))
        }
        return check == UInt8(truncatingIfNeeded: value)
    }

    /// Every valid `.jbroot-<16 hex>` directory entry, sorted. Only
    /// `roothideRoot` is used; the others are listed so they can be removed.
    ///
    /// tvOS has no `/private/var/containers/Bundle/Application` until a
    /// bootstrap creates it (performInstall does, with intermediate
    /// directories). A missing parent means there are no roots yet, so return
    /// an empty list rather than throwing — otherwise every install, uninstall
    /// and status call on a fresh tvOS guest fails before it starts.
    static func roothideRoots() throws -> [String] {
        guard try directoryExistsWithoutSymlink(roothideParent) else { return [] }
        return try FileManager.default.contentsOfDirectory(atPath: roothideParent)
            .sorted()
            .filter(roothideName)
            .map { roothideParent + "/" + $0 }
    }

    /// A RootHide bootstrap under any other name has to be uninstalled first.
    static func roothideBootstrapRoot(detected: String?) throws -> String {
        let others = try roothideRoots().filter { $0 != roothideRoot && isDirectory($0) }
        guard detected == nil || detected == roothideRoot, others.isEmpty else {
            throw GuestAPIError.operationFailed("Another RootHide bootstrap exists; uninstall it first")
        }
        return roothideRoot
    }

    /// Runs at install and on every vphoned start: the loader links, dylib
    /// ad-hoc signatures, then the bootstrap base. Returns the base report.
    static func repairRootHide(root: String) throws -> [String: Any] {
        try ensureRootHideLinks(root: root)
        let resigned = ensureRootHideDylibSignatures(root: root)
        if !resigned.isEmpty {
            NSLog("vphoned: RootHide ad-hoc re-signed dylibs: %@", resigned.joined(separator: ", "))
        }
        return try ensureRootHideBase(root: root)
    }
}

// MARK: - RootHide loader links

extension GuestIrisinInstaller {
    /// RootHide's @loader_path references resolve through a .jbroot link in
    /// each directory containing bootstrap Mach-O files. Seed the standard
    /// directories before a package manager installs its first shell.
    static func ensureRootHideLinks(root: String) throws {
        guard try directoryExistsWithoutSymlink(root) else {
            throw GuestAPIError.operationFailed("RootHide bootstrap root is missing: \(root)")
        }
        let files = FileManager.default

        func link(_ path: String, target: String) throws {
            var info = stat()
            if lstat(path, &info) == 0 {
                guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFLNK),
                      try files.destinationOfSymbolicLink(atPath: path) == target
                else {
                    throw GuestAPIError.operationFailed("RootHide loader link has an unexpected target: \(path)")
                }
                return
            }
            guard errno == ENOENT else {
                throw GuestAPIError.operationFailed("Could not inspect RootHide loader link: \(path)")
            }
            try files.createSymbolicLink(atPath: path, withDestinationPath: target)
        }

        try link(root + "/.jbroot", target: ".")
        for relative in ["bin", "sbin", "usr/bin", "usr/sbin", "usr/lib", "usr/libexec", "usr/lib/pam"] {
            var directory = root
            for component in relative.split(separator: "/") {
                directory += "/" + component
                if try !directoryExistsWithoutSymlink(directory) {
                    try files.createDirectory(atPath: directory, withIntermediateDirectories: false)
                }
            }
            let depth = relative.split(separator: "/").count
            let target = String(repeating: "../", count: depth) + ".jbroot"
            try link(directory + "/.jbroot", target: target)
        }
        let seeded = ensureRootHideMachOLinks(root: root)
        if !seeded.isEmpty {
            NSLog("vphoned: RootHide loader links: %@", seeded.joined(separator: ", "))
        }
    }

    /// RootHide's dpkg puts a .jbroot link beside every Mach-O it installs.
    /// Irisin unpacks packages without that hook, so a dylib in a directory
    /// outside the fixed list, such as usr/libexec/sudo, cannot load its
    /// @loader_path/.jbroot dependencies. Walk the package directories without
    /// following symlinks and link each directory holding a Mach-O file. An
    /// existing .jbroot entry is left alone. The spawn hooks repair a
    /// program's dependencies before it starts; this pass covers the rest.
    static func ensureRootHideMachOLinks(root: String) -> [String] {
        let files = FileManager.default
        let skipped: Set = ["usr/share", "usr/include"]
        var linked: Set<String> = []
        var created: [String] = []
        for top in ["bin", "sbin", "usr", "Library"] {
            guard (try? directoryExistsWithoutSymlink(root + "/" + top)) == true,
                  let walk = files.enumerator(atPath: root + "/" + top)
            else { continue }
            while let entry = walk.nextObject() as? String {
                let relative = top + "/" + entry
                switch walk.fileAttributes?[.type] as? FileAttributeType {
                case .typeDirectory?:
                    if skipped.contains(relative) {
                        walk.skipDescendants()
                    }
                    continue
                case .typeRegular?:
                    break
                default:
                    continue
                }
                let directory = (relative as NSString).deletingLastPathComponent
                let link = root + "/" + directory + "/.jbroot"
                guard !linked.contains(directory) else { continue }
                var info = stat()
                if lstat(link, &info) == 0 {
                    linked.insert(directory)
                    continue
                }
                guard errno == ENOENT, isMachO(root + "/" + relative) else { continue }
                linked.insert(directory)
                let depth = directory.split(separator: "/").count
                let target = String(repeating: "../", count: depth) + ".jbroot"
                if (try? files.createSymbolicLink(atPath: link, withDestinationPath: target)) != nil {
                    created.append("/" + directory)
                }
            }
        }
        return created
    }

    /// Under `txm-cfw-executable_remap`, CMS-less ldid dylibs (`flags == 0`)
    /// inside RootHide's `/private/var/containers/Bundle/` tree classify as
    /// type 5 and are rejected by TXM selector 38 in higher-trust hosts.
    /// Re-sign any such Mach-O dylib or loadable bundle to Apple ad-hoc
    /// (`CS_ADHOC`, type 10) while preserving its identifier and entitlements.
    static func ensureRootHideDylibSignatures(root: String) -> [String] {
        let files = FileManager.default
        let skipped: Set = ["usr/share", "usr/include", "Library/dpkg", "Library/Caches"]
        var resigned: [String] = []
        for top in ["usr", "Library"] {
            guard (try? directoryExistsWithoutSymlink(root + "/" + top)) == true,
                  let walk = files.enumerator(atPath: root + "/" + top)
            else { continue }
            while let entry = walk.nextObject() as? String {
                let relative = top + "/" + entry
                switch walk.fileAttributes?[.type] as? FileAttributeType {
                case .typeDirectory?:
                    if skipped.contains(relative) {
                        walk.skipDescendants()
                    }
                    continue
                case .typeRegular?:
                    break
                default:
                    continue
                }
                let path = root + "/" + relative
                guard isMachO(path) else { continue }
                let url = URL(fileURLWithPath: path)
                guard VPhoneSigner.needsAdHocLibraryResign(fileAt: url) else { continue }
                let identifier = try? VPhoneSigner.identifier(ofFileAt: url)
                let options = VPhoneSignOptions(
                    identifier: identifier,
                    mergesExisting: true,
                    style: .appleAdHoc,
                )
                do {
                    try VPhoneSigner.sign(fileAt: url, options: options)
                    resigned.append("/" + relative)
                } catch {
                    NSLog("vphoned: could not ad-hoc re-sign %@: %@", path, String(describing: error))
                }
            }
        }
        return resigned
    }

    /// After a package operation: relinks the new package's Mach-O
    /// directories right away. The spawn hooks cannot do it for a mobile
    /// shell: running sudo there cannot create a link in the root-owned
    /// usr/libexec/sudo. Also re-signs any CMS-less ldid dylibs/bundles to
    /// Apple ad-hoc so TXM admits them in every host process. The base steps
    /// that waited for pwd_mkdb or ssh-keygen run then too, so sshd has host
    /// keys as soon as openssh is installed.
    static func repairRootHidePackages(root: String) {
        let seeded = ensureRootHideMachOLinks(root: root)
        if !seeded.isEmpty {
            NSLog("vphoned: RootHide loader links: %@", seeded.joined(separator: ", "))
        }
        let resigned = ensureRootHideDylibSignatures(root: root)
        if !resigned.isEmpty {
            NSLog("vphoned: RootHide ad-hoc re-signed dylibs: %@", resigned.joined(separator: ", "))
        }
        do {
            let base = try ensureRootHideBase(root: root)
            if base["created"] as? [String] != [] {
                NSLog("vphoned: RootHide bootstrap base: %@", String(describing: base))
            }
        } catch {
            NSLog("vphoned: could not repair RootHide bootstrap: %@", String(describing: error))
        }
    }

    static func isMachO(_ path: String) -> Bool {
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        var magic: UInt32 = 0
        guard read(descriptor, &magic, 4) == 4 else { return false }
        // Thin 64-bit and fat, in either byte order.
        return [0xFEED_FACF, 0xCFFA_EDFE, 0xCAFE_BABE, 0xBEBA_FECA].contains(magic)
    }
}

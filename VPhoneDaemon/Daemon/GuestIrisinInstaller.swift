import CryptoKit
import Darwin
import Foundation
import IcliKit
import IcliSystem

/// Installs the published Irisin payload without dpkg or maintainer scripts.
enum GuestIrisinInstaller {
    private static let releaseURL = URL(string: "https://api.github.com/repos/Lakr233/Irisin/releases/latest")!
    private static let serviceLabel = "wiki.qaq.irisind"
    private static let installLock = NSLock()
    private static let progressLock = NSLock()
    private nonisolated(unsafe) static var progress: [String: Any] = ["phase": "idle"]
    private static let completionMarker = URL(fileURLWithPath: "/private/var/db/vphoned/bootstrap.json")
    private static let legacyCompletionMarker = Bundle.main.executableURL!
        .deletingLastPathComponent()
        .appendingPathComponent(".vphoned-boostrap-completed")

    static func install(jailbreak: [String: Any], layout: String, packagePath: String? = nil) throws -> [String: Any] {
        installLock.lock()
        defer { installLock.unlock() }
        guard try completedBootstrap() == nil else {
            throw GuestAPIError.operationFailed("Irisin bootstrap already completed")
        }
        setProgress(["phase": "preparing", "layout": layout])
        do {
            let result = try performInstall(jailbreak: jailbreak, layout: layout, packagePath: packagePath)
            setProgress(["phase": "completed", "layout": layout,
                         "version": result["version"] ?? "", "jbroot": result["jbroot"] ?? ""])
            return result
        } catch {
            setProgress(["phase": "failed", "layout": layout, "error": String(describing: error)])
            throw error
        }
    }

    static func status() -> [String: Any] {
        progressLock.lock()
        defer { progressLock.unlock() }
        return progress
    }

    static func installedBootstrap() throws -> [String: Any] {
        let roots = try bootstrapRoots()
        var result: [String: Any] = ["installed": !roots.isEmpty, "roots": roots.map(\.root)]
        if let installation = try completedBootstrap() {
            result["layout"] = installation.layout
            result["jbroot"] = installation.root
        }
        return result
    }

    static func uninstall(expectedRoots: [String], reboot: Bool = true) throws -> [String: Any] {
        installLock.lock()
        defer { installLock.unlock() }
        let roots = try bootstrapRoots()
        guard !roots.isEmpty else {
            throw GuestAPIError.operationFailed("No bootstrap environment was found")
        }
        guard expectedRoots == roots.map(\.root) else {
            throw GuestAPIError.invalidRequest("Bootstrap paths changed; inspect them again before uninstalling")
        }

        for installation in roots {
            try removeBootstrap(root: installation.root, layout: installation.layout)
        }
        // A legacy marker may live beside vphoned on the read-only system
        // volume. Shadow it with a writable tombstone after removal.
        try writeMarker(["installed": false])
        if reboot {
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                do {
                    _ = try requestReboot(userspace: false, force: true)
                } catch {
                    NSLog("vphoned: bootstrap removed but reboot failed: %@", String(describing: error))
                }
            }
        }
        return ["roots": expectedRoots, "deleted": true, "reboot_scheduled": reboot]
    }

    private static func bootstrapRoots() throws -> [(layout: String, root: String)] {
        var roots: [(layout: String, root: String)] = []
        if let installation = try completedBootstrap() {
            roots.append(installation)
        }
        if itemExists(URL(fileURLWithPath: "/var/jb")), !roots.contains(where: { $0.root == "/var/jb" }) {
            roots.append(("rootless", "/var/jb"))
        }
        let parent = "/private/var/containers/Bundle/Application"
        for name in try FileManager.default.contentsOfDirectory(atPath: parent).sorted() where roothideName(name) {
            let root = parent + "/" + name
            if !roots.contains(where: { $0.root == root }) {
                roots.append(("roothide", root))
            }
        }
        return roots.sorted { $0.root < $1.root }
    }

    private static func removeBootstrap(root: String, layout: String) throws {
        let files = FileManager.default
        let rootURL = URL(fileURLWithPath: root, isDirectory: true)
        let removal = try removalRoot(root, layout: layout)
        if try directoryExistsWithoutSymlink(removal.physicalPath) {
            for relative in ["Library/LaunchDaemons", "basebin/LaunchDaemons"] {
                let directory = rootURL.appendingPathComponent(relative, isDirectory: true).path
                guard try physicalChildDirectoryExists(root: root, relative: relative) else { continue }
                let plists = try files.contentsOfDirectory(atPath: directory)
                    .filter { $0.hasSuffix(".plist") }
                    .sorted()
                    .map { directory + "/" + $0 }
                for plist in plists {
                    var info = stat()
                    guard lstat(plist, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
                        throw GuestAPIError.operationFailed("Bootstrap service is not a regular plist: \(plist)")
                    }
                }
                if !plists.isEmpty {
                    _ = try loadServices(plists, load: false, override: false)
                }
            }

            let apps = rootURL.appendingPathComponent("Applications", isDirectory: true).path
            if try physicalChildDirectoryExists(root: root, relative: "Applications") {
                _ = try unregisterAppsInDirectory(apps, force: true)
            }
            try files.removeItem(atPath: removal.physicalPath)
        }
        if removal.isSymlink {
            try files.removeItem(at: rootURL)
        }
    }

    private static func completedBootstrap() throws -> (layout: String, root: String)? {
        guard let markerURL = markerForRead() else { return nil }
        let data = try Data(contentsOf: markerURL)
        guard let marker = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GuestAPIError.operationFailed("Completed bootstrap marker is invalid")
        }
        if marker["installed"] as? Bool == false {
            return nil
        }
        guard let layout = marker["layout"] as? String,
              let root = marker["jbroot"] as? String,
              (layout == "rootless" && root == "/var/jb") ||
              (layout == "roothide" && root.hasPrefix("/private/var/containers/Bundle/Application/")
                  && roothideName(String(root.dropFirst("/private/var/containers/Bundle/Application/".count))))
        else { throw GuestAPIError.operationFailed("Completed bootstrap marker has an invalid root") }
        return (layout, root)
    }

    private static func markerForRead() -> URL? {
        if itemExists(completionMarker) {
            return completionMarker
        }
        if itemExists(legacyCompletionMarker) {
            return legacyCompletionMarker
        }
        return nil
    }

    private static func writeMarker(_ marker: [String: Any]) throws {
        try FileManager.default.createDirectory(
            at: completionMarker.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755],
        )
        try JSONSerialization.data(withJSONObject: marker).write(to: completionMarker, options: .atomic)
    }

    private static func directoryExistsWithoutSymlink(_ path: String) throws -> Bool {
        var info = stat()
        if lstat(path, &info) != 0 {
            if errno == ENOENT {
                return false
            }
            throw GuestAPIError.operationFailed("Could not inspect bootstrap directory: \(path)")
        }
        guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else {
            throw GuestAPIError.operationFailed("Bootstrap directory is not a physical directory: \(path)")
        }
        return true
    }

    private static func physicalChildDirectoryExists(root: String, relative: String) throws -> Bool {
        var path = root
        for component in relative.split(separator: "/") {
            path += "/" + component
            guard try directoryExistsWithoutSymlink(path) else { return false }
        }
        return true
    }

    private static func removalRoot(_ root: String, layout: String) throws -> (physicalPath: String, isSymlink: Bool) {
        var info = stat()
        guard lstat(root, &info) == 0 else {
            if errno == ENOENT {
                return (root, false)
            }
            throw GuestAPIError.operationFailed("Could not inspect bootstrap root: \(root)")
        }
        if info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) {
            return (root, false)
        }
        guard layout == "rootless", info.st_mode & mode_t(S_IFMT) == mode_t(S_IFLNK) else {
            throw GuestAPIError.operationFailed("Bootstrap root is not a directory: \(root)")
        }
        var target = [CChar](repeating: 0, count: Int(PATH_MAX))
        let count = readlink(root, &target, target.count - 1)
        guard count > 0 else { throw GuestAPIError.operationFailed("Could not read bootstrap link: \(root)") }
        guard let physicalPath = String(
            bytes: target.prefix(count).map { UInt8(bitPattern: $0) }, encoding: .utf8,
        ) else { throw GuestAPIError.operationFailed("Bootstrap link has an invalid path: \(root)") }
        guard physicalPath.hasPrefix("/private/preboot/"),
              physicalPath != "/private/preboot/",
              physicalPath == (physicalPath as NSString).standardizingPath
        else {
            throw GuestAPIError.operationFailed("Rootless bootstrap link has an unexpected target: \(physicalPath)")
        }
        return (physicalPath, true)
    }

    private static func setProgress(_ value: [String: Any]) {
        progressLock.lock()
        progress = value
        progressLock.unlock()
    }

    private static func downloadProgress(received: Int64, total: Int64) {
        progressLock.lock()
        progress["downloaded_bytes"] = received
        if total > 0 {
            progress["total_bytes"] = total
        }
        progressLock.unlock()
    }

    private static func performInstall(jailbreak: [String: Any], layout: String, packagePath: String?) throws -> [String: Any] {
        let detectedLayout = jailbreak["layout"] as? String
        guard layout == "rootless" || layout == "roothide" else {
            throw GuestAPIError.invalidRequest("layout must be rootless or roothide")
        }
        if let detectedLayout, layout != detectedLayout {
            throw GuestAPIError.invalidRequest("Requested layout does not match the guest bootstrap")
        }
        let root = try bootstrapRoot(layout: layout, detected: jailbreak["jbroot"] as? String)
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o755])
        try FileManager.default.createDirectory(atPath: root + "/usr/lib", withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o755])
        guard isDirectory(root) else {
            throw GuestAPIError.operationFailed("Jailbreak root is not a directory: \(root)")
        }

        let architecture = layout == "roothide" ? "iphoneos-arm64e" : "iphoneos-arm64"
        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("vphoned-irisin-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        let package = work.appendingPathComponent("Irisin.deb")
        let tag: String
        let expectedVersion: String?
        if let packagePath {
            try copyLocalPackage(packagePath, to: package)
            tag = "local"
            expectedVersion = nil
        } else {
            let release = try releaseAsset(architecture: architecture)
            setProgress(["phase": "downloading", "layout": layout, "tag": release.tag,
                         "downloaded_bytes": 0])
            let packageData = try fetch(release.url, reportDownload: true)
            let digest = SHA256.hash(data: packageData).map { String(format: "%02x", $0) }.joined()
            guard digest == release.digest else {
                throw GuestAPIError.operationFailed("Irisin release asset SHA-256 mismatch")
            }
            try packageData.write(to: package, options: .atomic)
            tag = release.tag
            expectedVersion = release.version
        }
        setProgress(["phase": "extracting", "layout": layout, "tag": tag])

        let metadata = try readDeb(package.path)
        let control = metadata["control"] as? [String: String] ?? [:]
        let version = control["Version"] ?? ""
        guard control["Package"] == "wiki.qaq.irisin",
              !version.isEmpty, version.count <= 128,
              expectedVersion == nil || version == expectedVersion,
              control["Architecture"] == architecture
        else { throw GuestAPIError.operationFailed("Irisin package metadata does not match the selected layout") }

        let extracted = work.appendingPathComponent("extracted", isDirectory: true)
        _ = try extractDeb(package.path, to: extracted.path)
        let payload = layout == "rootless"
            ? extracted.appendingPathComponent("var/jb", isDirectory: true)
            : extracted
        let app = payload.appendingPathComponent("Applications/irisin.app", isDirectory: true)
        let daemon = payload.appendingPathComponent("usr/libexec/irisind")
        let helper = payload.appendingPathComponent("usr/libexec/irisin-install")
        let plist = payload.appendingPathComponent("Library/LaunchDaemons/\(serviceLabel).plist")
        try validatePayload(app: app, daemon: daemon, helper: helper, plist: plist,
                            version: version, architecture: architecture, layout: layout)

        if layout == "roothide" {
            try prepareRootHidePlist(plist, executable: root + "/usr/libexec/irisind")
        }
        try prepareAppData()

        let rootURL = URL(fileURLWithPath: root, isDirectory: true)
        let installedApp = rootURL.appendingPathComponent("Applications/irisin.app", isDirectory: true)
        let installedPlist = rootURL.appendingPathComponent("Library/LaunchDaemons/\(serviceLabel).plist")
        let hadApp = itemExists(installedApp)
        let components = try payloadComponents(from: payload, to: rootURL, app: app)
        let hadService = itemExists(installedPlist)
        if hadService {
            _ = try loadServices([installedPlist.path], load: false, override: false)
        }

        var replaced: [(target: URL, backup: URL?)] = []
        do {
            setProgress(["phase": "installing", "layout": layout, "tag": tag])
            for (source, target) in components {
                try replaced.append(replace(source, at: target))
            }
            var base: [String: Any]?
            if layout == "roothide" {
                try ensureRootHideLinks(root: root)
                base = try ensureRootHideBase(root: root)
            }
            let registration = try registerApp(installedApp.path)
            let loaded = try loadServices([installedPlist.path], load: true, override: false)
            var started: [String: Any]?
            var startWarning: String?
            do {
                started = try startService(serviceLabel)
            } catch {
                // Some VM launchd builds can load the job but cannot start it
                // until the service-configure hook is available. The app and
                // bootstrap payload are still usable in that state.
                startWarning = String(describing: error)
            }
            let status = try serviceStatus(serviceLabel)
            guard status["loaded"] as? Bool == true else {
                throw GuestAPIError.operationFailed("Irisin daemon is not loaded")
            }
            setProgress(["phase": "firmware", "layout": layout, "tag": tag])
            let firmware = try ensureFirmwareRecord(root: root)
            let marker = ["tag": tag, "layout": layout, "jbroot": root]
            try writeMarker(marker)
            for entry in replaced {
                if let backup = entry.backup {
                    try? FileManager.default.removeItem(at: backup)
                }
            }
            var result: [String: Any] = [
                "tag": tag,
                "version": version,
                "architecture": architecture,
                "layout": layout,
                "jbroot": root,
                "app_path": installedApp.path,
                "registration": registration,
                "service_load": loaded,
                "service_status": status,
                "firmware_version": firmware.version,
                "maintainer_scripts_executed": false,
                "dpkg_database_updated": firmware.updated,
            ]
            if let base {
                result["roothide_base"] = base
            }
            if let started {
                result["service_start"] = started
            }
            if let startWarning {
                result["service_start_warning"] = startWarning
            }
            return result
        } catch {
            if itemExists(installedPlist) {
                _ = try? loadServices([installedPlist.path], load: false, override: false)
            }
            if !hadApp, itemExists(installedApp) {
                _ = try? unregisterApp(installedApp.path, force: true)
            }
            for entry in replaced.reversed() {
                try? FileManager.default.removeItem(at: entry.target)
                if let backup = entry.backup {
                    try? FileManager.default.moveItem(at: backup, to: entry.target)
                }
            }
            if itemExists(installedApp) {
                _ = try? registerApp(installedApp.path)
            }
            if hadService {
                _ = try? loadServices([installedPlist.path], load: true, override: false)
            }
            throw error
        }
    }

    static func repairFirmwareRecord() throws -> [String: Any] {
        installLock.lock()
        defer { installLock.unlock() }
        guard let marker = try completedBootstrap(),
              try marker.root == bootstrapRoot(layout: marker.layout, detected: nil),
              isDirectory(marker.root)
        else { throw GuestAPIError.operationFailed("No valid completed vphoned bootstrap was found") }
        let firmware = try ensureFirmwareRecord(root: marker.root)
        return ["layout": marker.layout, "jbroot": marker.root,
                "firmware_version": firmware.version, "dpkg_database_updated": firmware.updated]
    }

    static func refreshBootstrapOnStartup() {
        do {
            guard let installation = try completedBootstrap() else { return }
            if installation.layout == "roothide" {
                try ensureRootHideLinks(root: installation.root)
                let base = try ensureRootHideBase(root: installation.root)
                if base["created"] as? [String] != [] || base["deferred"] as? [String] != [] {
                    NSLog("vphoned: RootHide bootstrap base: %@", String(describing: base))
                }
            }
        } catch {
            NSLog("vphoned: could not repair RootHide bootstrap: %@", String(describing: error))
        }
        do {
            _ = try repairFirmwareRecord()
        } catch {
            NSLog("vphoned: could not refresh bootstrap firmware record: %@", String(describing: error))
        }
    }

    /// RootHide's @loader_path references resolve through a .jbroot link in
    /// each directory containing bootstrap Mach-O files. Seed the standard
    /// directories before a package manager installs its first shell.
    private static func ensureRootHideLinks(root: String) throws {
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
    }

    // MARK: - RootHide bootstrap base

    /// A jailbreak's bootstrap installer creates what no package owns: vroot
    /// `/tmp` and `/dev`, the account files and the databases user lookup
    /// reads, root's home and the SSH host keys. Irisin only unpacks packages,
    /// so vphoned is that installer. Paths are physical; `root/x` is `/x`
    /// under vroot. A missing item is created and an existing one is left
    /// alone, so a changed password, key or mode survives. A step that needs a
    /// bootstrap tool waits for a later refresh until Irisin's Bootstrap
    /// Install has unpacked the tool.
    private static func ensureRootHideBase(root: String) throws -> [String: Any] {
        guard try directoryExistsWithoutSymlink(root) else {
            throw GuestAPIError.operationFailed("RootHide bootstrap root is missing: \(root)")
        }
        var created: [String] = []
        var deferred: [String] = []

        // Everything under vroot resolves /tmp and /var/tmp here. Without it
        // iGhostVT never starts: libghostty only logs the failed config write.
        for (path, mode) in [("tmp", 0o1777), ("var", 0o755), ("var/root", 0o700), ("etc", 0o755)] {
            if try ensureBaseDirectory(root + "/" + path, mode: mode_t(mode)) {
                created.append("/" + path)
            }
        }
        // /dev follows RootHide's own private/preboot -> /rootfs/private/preboot.
        for (path, target) in [("var/tmp", "../tmp"), ("dev", "/rootfs/dev")] {
            if try ensureBaseLink(root + "/" + path, target: target) {
                created.append("/" + path)
            }
        }
        for (name, mode) in [("passwd", 0o644), ("group", 0o644), ("master.passwd", 0o600)] {
            if try seedAccountFile(name, root: root, mode: mode_t(mode)) {
                created.append("/etc/" + name)
            }
        }

        switch try ensureAccountDatabases(root: root) {
        case true?:
            created += ["/etc/pwd.db", "/etc/spwd.db"]
        case false?:
            break
        case nil:
            deferred.append("/etc/pwd.db and /etc/spwd.db wait for /usr/sbin/pwd_mkdb")
            return ["created": created, "deferred": deferred]
        }
        // ssh-keygen needs getpwuid(0), so host keys follow the databases.
        switch try ensureHostKeys(root: root) {
        case true?:
            created.append("/etc/ssh host keys")
        case false?:
            break
        case nil:
            deferred.append("/etc/ssh host keys wait for /usr/bin/ssh-keygen")
        }
        return ["created": created, "deferred": deferred]
    }

    /// Creates a root-owned directory with exactly `mode`, since mkdir applies
    /// the umask. An existing directory keeps its owner and mode.
    private static func ensureBaseDirectory(_ path: String, mode: mode_t) throws -> Bool {
        if mkdir(path, mode) == 0 {
            guard chown(path, 0, 0) == 0, chmod(path, mode) == 0 else {
                throw GuestAPIError.operationFailed(
                    "Could not set the owner and mode of \(path): \(String(cString: strerror(errno)))",
                )
            }
            return true
        }
        let reason = String(cString: strerror(errno))
        guard errno == EEXIST else {
            throw GuestAPIError.operationFailed("Could not create \(path): \(reason)")
        }
        guard isDirectory(path) else {
            throw GuestAPIError.operationFailed("RootHide bootstrap path is not a directory: \(path)")
        }
        return false
    }

    /// Unlike a loader link, an existing entry here is not checked: whatever
    /// the user or a package put at the path stays.
    private static func ensureBaseLink(_ path: String, target: String) throws -> Bool {
        var info = stat()
        if lstat(path, &info) == 0 {
            return false
        }
        guard errno == ENOENT else {
            throw GuestAPIError.operationFailed("Could not inspect \(path): \(String(cString: strerror(errno)))")
        }
        try FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: target)
        return true
    }

    /// The bootstrap's account files start as copies of the system's. The
    /// copy is created with its final mode, so master.passwd, the shadow file,
    /// is never readable by others.
    private static func seedAccountFile(_ name: String, root: String, mode: mode_t) throws -> Bool {
        let destination = root + "/etc/" + name
        var info = stat()
        if lstat(destination, &info) == 0 {
            return false
        }
        guard errno == ENOENT else {
            throw GuestAPIError.operationFailed("Could not inspect \(destination): \(String(cString: strerror(errno)))")
        }
        let source = "/private/etc/" + name
        let input = open(source, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard input >= 0 else {
            throw GuestAPIError.operationFailed("Could not open \(source): \(String(cString: strerror(errno)))")
        }
        defer { close(input) }
        let data = try FileHandle(fileDescriptor: input, closeOnDealloc: false).readToEnd() ?? Data()

        let temporary = destination + ".vphoned-" + UUID().uuidString
        let output = open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode)
        guard output >= 0 else {
            throw GuestAPIError.operationFailed("Could not create \(temporary): \(String(cString: strerror(errno)))")
        }
        let written = data.withUnsafeBytes { write(output, $0.baseAddress, $0.count) }
        let prepared = written == data.count && fchown(output, 0, 0) == 0 && fchmod(output, mode) == 0
        let failure = errno
        close(output)
        guard prepared, rename(temporary, destination) == 0 else {
            let reason = String(cString: strerror(prepared ? errno : failure))
            unlink(temporary)
            throw GuestAPIError.operationFailed("Could not write \(destination): \(reason)")
        }
        return true
    }

    /// Procursus tools look users up through libiosexec, which reads the
    /// Berkeley databases rather than the text files. Without them every
    /// getpwnam and getpwuid under vroot fails with EINVAL while group lookups
    /// work. They are rebuilt only when missing or older than master.passwd,
    /// so a password changed with passwd survives a refresh. Returns nil while
    /// the bootstrap has no pwd_mkdb.
    private static func ensureAccountDatabases(root: String) throws -> Bool? {
        let etc = root + "/etc/"
        guard let master = try modificationTime(etc + "master.passwd") else {
            throw GuestAPIError.operationFailed("RootHide account file is missing: \(etc)master.passwd")
        }
        if let database = try modificationTime(etc + "pwd.db"), database >= master,
           let shadow = try modificationTime(etc + "spwd.db"), shadow >= master
        {
            return false
        }
        let tool = root + "/usr/sbin/pwd_mkdb"
        guard FileManager.default.isExecutableFile(atPath: tool) else {
            return nil
        }
        // pwd_mkdb also regenerates /etc/passwd from master.passwd.
        try runBootstrapTool(tool, ["-p", "/etc/master.passwd"])
        for (name, mode) in [("pwd.db", 0o644), ("spwd.db", 0o600)] {
            let path = etc + name
            guard chown(path, 0, 0) == 0, chmod(path, mode_t(mode)) == 0 else {
                throw GuestAPIError.operationFailed(
                    "Could not set the owner and mode of \(path): \(String(cString: strerror(errno)))",
                )
            }
        }
        let id = root + "/usr/bin/id"
        if FileManager.default.isExecutableFile(atPath: id) {
            try runBootstrapTool(id, ["root"])
        }
        return true
    }

    /// sshd resets every connection before its banner when it has no host
    /// key. `ssh-keygen -A` creates each missing default key type and leaves
    /// existing keys alone. Nothing happens until openssh has created
    /// /etc/ssh; returns nil while ssh-keygen is missing.
    private static func ensureHostKeys(root: String) throws -> Bool? {
        let directory = root + "/etc/ssh"
        guard isDirectory(directory) else {
            return false
        }
        let keys = ["ed25519", "ecdsa", "rsa"].map { "\(directory)/ssh_host_\($0)_key" }
        if keys.allSatisfy({ itemExists(URL(fileURLWithPath: $0)) }) {
            return false
        }
        let tool = root + "/usr/bin/ssh-keygen"
        guard FileManager.default.isExecutableFile(atPath: tool) else {
            return nil
        }
        try runBootstrapTool(tool, ["-A"])
        return true
    }

    private static func modificationTime(_ path: String) throws -> Double? {
        var info = stat()
        guard lstat(path, &info) == 0 else {
            if errno == ENOENT {
                return nil
            }
            throw GuestAPIError.operationFailed("Could not inspect \(path): \(String(cString: strerror(errno)))")
        }
        return Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1_000_000_000
    }

    /// Runs a bootstrap tool by its physical path. It loads libroothide
    /// through the `.jbroot` link beside it, so its arguments are vroot
    /// paths: `/etc` in the child is `root/etc`.
    private static func runBootstrapTool(_ path: String, _ arguments: [String]) throws {
        var argv = ([path] + arguments).map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        var outputPipe: [Int32] = [0, 0]
        guard pipe(&outputPipe) == 0 else {
            throw GuestAPIError.operationFailed("pipe: \(String(cString: strerror(errno)))")
        }
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, outputPipe[1], STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, outputPipe[1], STDERR_FILENO)
        posix_spawn_file_actions_addclose(&actions, outputPipe[0])
        posix_spawn_file_actions_addclose(&actions, outputPipe[1])
        var pid: pid_t = 0
        let spawned = posix_spawn(&pid, path, &actions, nil, &argv, environ)
        posix_spawn_file_actions_destroy(&actions)
        close(outputPipe[1])
        guard spawned == 0 else {
            close(outputPipe[0])
            throw GuestAPIError.operationFailed("Could not run \(path): \(String(cString: strerror(spawned)))")
        }
        // Drain to EOF so a chatty tool never blocks on a full pipe.
        var output = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while true {
            let count = read(outputPipe[0], &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            if count <= 0 { break }
            if output.count < 4096 {
                output.append(contentsOf: buffer.prefix(min(count, 4096 - output.count)))
            }
        }
        close(outputPipe[0])
        var status: Int32 = 0
        var waited = waitpid(pid, &status, 0)
        while waited < 0, errno == EINTR {
            waited = waitpid(pid, &status, 0)
        }
        guard waited == pid, status == 0 else {
            let details = String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw GuestAPIError.operationFailed("\(path) \(arguments.joined(separator: " ")) exited with status \(status): \(details)")
        }
    }

    /// This vphone bootstrap has no firmware maintainer script. Write the
    /// virtual package into the same dpkg status file Irisin and its helper read.
    private static func ensureFirmwareRecord(root: String) throws -> (version: String, updated: Bool) {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let version = "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
        let database = URL(fileURLWithPath: root, isDirectory: true)
            .appendingPathComponent("Library/dpkg", isDirectory: true)
        try FileManager.default.createDirectory(at: database, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o755])
        let statusURL = database.appendingPathComponent("status")
        var info = stat()
        let statusResult = lstat(statusURL.path, &info)
        if statusResult != 0, errno != ENOENT {
            throw GuestAPIError.operationFailed("Could not inspect dpkg status")
        }
        if statusResult == 0, info.st_mode & mode_t(S_IFMT) != mode_t(S_IFREG) {
            throw GuestAPIError.operationFailed("dpkg status is not a regular file")
        }
        let existing = statusResult == 0
            ? try String(contentsOf: statusURL, encoding: .utf8)
            : ""
        var paragraphs = existing.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n\n")
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let matches = paragraphs.indices.filter { index in
            paragraphs[index].split(separator: "\n").contains("Package: firmware")
        }
        guard matches.count <= 1 else {
            throw GuestAPIError.operationFailed("dpkg status contains duplicate firmware records")
        }
        if let index = matches.first {
            let lines = paragraphs[index].split(separator: "\n").map(String.init)
            let oldVersion = lines.first(where: { $0.hasPrefix("Version: ") })
                .map { String($0.dropFirst("Version: ".count)) } ?? ""
            guard lines.contains("Status: install ok installed") else {
                throw GuestAPIError.operationFailed("Existing firmware record is not installed")
            }
            if !lines.contains("Maintainer: vphoned") {
                return (oldVersion, false)
            }
            if oldVersion == version {
                return (version, false)
            }
            var updated = lines.map {
                $0.hasPrefix("Version: ") ? "Version: \(version)" : $0
            }
            if oldVersion.isEmpty {
                updated.append("Version: \(version)")
            }
            paragraphs[index] = updated.joined(separator: "\n")
        } else {
            paragraphs.append("""
            Package: firmware
            Essential: yes
            Status: install ok installed
            Priority: required
            Section: System
            Installed-Size: 0
            Maintainer: vphoned
            Architecture: all
            Version: \(version)
            Description: virtual package for this vphone iOS firmware
            """)
        }
        try (paragraphs.joined(separator: "\n\n") + "\n\n")
            .write(to: statusURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: statusURL.path)
        return (version, true)
    }

    // MARK: - Release and payload

    private static func bootstrapRoot(layout: String, detected: String?) throws -> String {
        if layout == "rootless" {
            return "/var/jb"
        }
        if let detected {
            return detected
        }

        let parent = "/private/var/containers/Bundle/Application"
        let names = try FileManager.default.contentsOfDirectory(atPath: parent)
            .filter { roothideName($0) && isDirectory(parent + "/" + $0) }
        guard names.count <= 1 else {
            throw GuestAPIError.operationFailed("Multiple RootHide bootstrap roots exist")
        }
        if let name = names.first {
            return parent + "/" + name
        }

        // User-selected stem, zero-padded to 16 hex digits with RootHide's
        // XOR checksum in the final byte (0C instead of the proposed 10).
        let name = ".jbroot-000114514191980C"
        guard roothideName(name) else {
            throw GuestAPIError.operationFailed("Configured RootHide bootstrap name is invalid")
        }
        return parent + "/" + name
    }

    private static func roothideName(_ name: String) -> Bool {
        guard name.range(of: "^\\.jbroot-[0-9a-fA-F]{16}$", options: .regularExpression) != nil,
              let value = UInt64(name.dropFirst(8), radix: 16)
        else { return false }
        let check = (1 ... 7).reduce(UInt8(0)) {
            $0 ^ UInt8(truncatingIfNeeded: value >> ($1 * 8))
        }
        return check == UInt8(truncatingIfNeeded: value)
    }

    private struct Asset {
        let tag: String
        let version: String
        let name: String
        let url: URL
        let digest: String
    }

    private static func copyLocalPackage(_ path: String, to destination: URL) throws {
        let prefix = "/var/root/Library/Caches/vphoned-irisin-"
        guard path.hasPrefix(prefix), path.hasSuffix(".deb"),
              let id = UUID(uuidString: String(path.dropFirst(prefix.count).dropLast(4))),
              path == prefix + id.uuidString + ".deb"
        else { throw GuestAPIError.invalidRequest("Invalid staged Irisin package path") }

        let descriptor = open(path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw GuestAPIError.operationFailed("Could not open staged Irisin package")
        }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              info.st_size > 0, info.st_size <= 64 * 1024 * 1024
        else { throw GuestAPIError.invalidRequest("Irisin package must be a regular file under 64 MiB") }
        let data = try FileHandle(fileDescriptor: descriptor, closeOnDealloc: false).readToEnd() ?? Data()
        guard data.count == info.st_size else {
            throw GuestAPIError.operationFailed("Could not read the complete Irisin package")
        }
        try data.write(to: destination, options: .atomic)
        try? FileManager.default.removeItem(atPath: path)
    }

    private static func releaseAsset(architecture: String) throws -> Asset {
        let data = try fetch(releaseURL)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String,
              tag.range(of: "^v[0-9]+(\\.[0-9]+){2,3}$", options: .regularExpression) != nil,
              let assets = json["assets"] as? [[String: Any]]
        else { throw GuestAPIError.operationFailed("GitHub did not return a valid Irisin release") }
        let version = String(tag.dropFirst())
        let name = "wiki.qaq.irisin_\(version)_\(architecture).deb"
        guard let asset = assets.first(where: { $0["name"] as? String == name }),
              let address = asset["browser_download_url"] as? String,
              let url = URL(string: address), url.scheme == "https", url.host == "github.com",
              url.path == "/Lakr233/Irisin/releases/download/\(tag)/\(name)",
              let rawDigest = asset["digest"] as? String,
              rawDigest.range(of: "^sha256:[0-9a-f]{64}$", options: .regularExpression) != nil
        else { throw GuestAPIError.operationFailed("The latest Irisin release has no verified \(architecture) package") }
        return Asset(tag: tag, version: version, name: name, url: url,
                     digest: String(rawDigest.dropFirst("sha256:".count)))
    }

    private static func validatePayload(
        app: URL, daemon: URL, helper: URL, plist: URL,
        version: String, architecture: String, layout: String,
    ) throws {
        let info = NSDictionary(contentsOf: app.appendingPathComponent("Info.plist"))
        guard info?["CFBundleIdentifier"] as? String == "wiki.qaq.irisin",
              info?["CFBundleShortVersionString"] as? String == version,
              info?["IrisinCurrentArchitecture"] as? String == architecture,
              FileManager.default.isExecutableFile(atPath: app.appendingPathComponent("irisin").path),
              FileManager.default.isExecutableFile(atPath: daemon.path),
              FileManager.default.isExecutableFile(atPath: helper.path),
              let properties = NSDictionary(contentsOf: plist) as? [String: Any],
              properties["Label"] as? String == serviceLabel,
              let arguments = properties["ProgramArguments"] as? [String],
              arguments == [layout == "roothide" ? "/usr/libexec/irisind" : "/var/jb/usr/libexec/irisind"]
        else { throw GuestAPIError.operationFailed("Irisin release payload is incomplete or has the wrong layout") }
    }

    private static func prepareRootHidePlist(_ url: URL, executable: String) throws {
        let data = try Data(contentsOf: url)
        guard var plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw GuestAPIError.operationFailed("Irisin launchd plist is invalid")
        }
        plist["ProgramArguments"] = [executable]
        plist["__Patched"] = true
        let updated = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try updated.write(to: url, options: .atomic)
    }

    /// mobile owns /var/mobile/Documents, so either path component may be a
    /// symlink it planted to have root hand another directory to mobile. Both
    /// are opened without following a link, and ownership is set through the
    /// descriptor rather than the path.
    private static func prepareAppData() throws {
        let documents = "/var/mobile/Documents"
        let name = "wiki.qaq.irisin"
        if mkdir(documents, 0o755) != 0, errno != EEXIST {
            throw GuestAPIError.operationFailed("Could not create \(documents): \(String(cString: strerror(errno)))")
        }
        let parent = open(documents, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else {
            throw GuestAPIError.operationFailed("\(documents) is not a real directory")
        }
        defer { close(parent) }
        if mkdirat(parent, name, 0o755) != 0, errno != EEXIST {
            throw GuestAPIError.operationFailed("Could not create Irisin app data: \(String(cString: strerror(errno)))")
        }
        var info = stat()
        guard fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0,
              info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR)
        else { throw GuestAPIError.operationFailed("Irisin app data path is not a real directory") }
        let directory = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else {
            throw GuestAPIError.operationFailed("Irisin app data path is not a real directory")
        }
        defer { close(directory) }
        guard fchown(directory, 501, 501) == 0, fchmod(directory, 0o755) == 0 else {
            throw GuestAPIError.operationFailed("Could not assign Irisin app data to mobile")
        }
    }

    // MARK: - Installation

    private static func payloadComponents(from payload: URL, to root: URL, app: URL) throws -> [(URL, URL)] {
        let files = FileManager.default
        var components: [(URL, URL)] = []

        func collect(_ source: URL, _ destination: URL) throws {
            var info = stat()
            guard lstat(source.path, &info) == 0 else {
                throw GuestAPIError.operationFailed("Could not inspect Irisin payload: \(source.path)")
            }
            if info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR), source != app {
                let children = try files.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)
                    .sorted { $0.lastPathComponent < $1.lastPathComponent }
                if children.isEmpty {
                    try files.createDirectory(at: destination, withIntermediateDirectories: true)
                }
                for child in children {
                    try collect(child, destination.appendingPathComponent(child.lastPathComponent))
                }
            } else {
                components.append((source, destination))
            }
        }

        for source in try files.contentsOfDirectory(at: payload, includingPropertiesForKeys: nil)
            .sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
            where source.lastPathComponent != "DEBIAN"
        {
            try collect(source, root.appendingPathComponent(source.lastPathComponent))
        }
        return components
    }

    private static func isDirectory(_ path: String) -> Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &directory) && directory.boolValue
    }

    private static func itemExists(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0
    }

    private static func replace(_ source: URL, at target: URL) throws -> (target: URL, backup: URL?) {
        let files = FileManager.default
        let parent = target.deletingLastPathComponent()
        try files.createDirectory(at: parent, withIntermediateDirectories: true,
                                  attributes: [.posixPermissions: 0o755])
        let suffix = UUID().uuidString
        let candidate = parent.appendingPathComponent(".\(target.lastPathComponent).vphoned-\(suffix)")
        let backup = parent.appendingPathComponent(".\(target.lastPathComponent).backup-\(suffix)")
        try files.copyItem(at: source, to: candidate)
        var old: URL?
        do {
            if itemExists(target) {
                var info = stat()
                guard lstat(target.path, &info) == 0, info.st_mode & mode_t(S_IFMT) != mode_t(S_IFLNK) else {
                    throw GuestAPIError.operationFailed("Irisin destination is a symlink: \(target.path)")
                }
                try files.moveItem(at: target, to: backup)
                old = backup
            }
            try files.moveItem(at: candidate, to: target)
            return (target, old)
        } catch {
            try? files.removeItem(at: candidate)
            if let old {
                try? files.moveItem(at: old, to: target)
            }
            throw error
        }
    }

    // MARK: - HTTPS

    private final class HTTPResult: @unchecked Sendable {
        let semaphore = DispatchSemaphore(value: 0)
        var value: Result<(Data, URLResponse), Error>?

        func finish(data: Data?, response: URLResponse?, error: Error?) {
            if let error {
                value = .failure(error)
            } else if let data, let response {
                value = .success((data, response))
            } else {
                value = .failure(GuestAPIError.operationFailed("Empty Irisin download response"))
            }
            semaphore.signal()
        }
    }

    private static func fetch(_ url: URL, reportDownload: Bool = false) throws -> Data {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 180
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("vphoned-Irisin-installer", forHTTPHeaderField: "User-Agent")
        let result = HTTPResult()
        let task = session.dataTask(with: request) { data, response, error in
            result.finish(data: data, response: response, error: error)
        }
        task.resume()
        let deadline = Date().addingTimeInterval(190)
        while result.semaphore.wait(timeout: .now() + 0.2) != .success {
            if reportDownload {
                downloadProgress(received: task.countOfBytesReceived,
                                 total: task.countOfBytesExpectedToReceive)
            }
            if Date() >= deadline {
                task.cancel()
                throw GuestAPIError.operationFailed("Irisin download timed out")
            }
        }
        if reportDownload {
            downloadProgress(received: task.countOfBytesReceived,
                             total: task.countOfBytesExpectedToReceive)
        }
        let (data, response) = try result.value!.get()
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw GuestAPIError.operationFailed("Irisin download returned HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        guard data.count <= 64 * 1024 * 1024 else {
            throw GuestAPIError.operationFailed("Irisin download exceeds 64 MiB")
        }
        return data
    }
}

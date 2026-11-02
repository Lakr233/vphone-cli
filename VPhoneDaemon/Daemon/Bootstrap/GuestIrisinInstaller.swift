import CryptoKit
import Darwin
import Foundation
import IcliKit
import IcliSystem

/// Installs the published Irisin payload without dpkg or maintainer scripts.
///
/// This file holds the layout-independent flow. RootHide's root, loader links
/// and bootstrap base live in `RootHide/`, rootless's `/var/jb` in `Rootless/`,
/// and the firmware record, release download and payload copy beside this file.
enum GuestIrisinInstaller {
    static let serviceLabel = "wiki.qaq.irisind"
    /// Error code of `bootstrap.install` when a completed install exists.
    static let alreadyInstalledCode = "bootstrap_already_installed"
    static let installLock = NSLock()
    private static let progressLock = NSLock()
    private nonisolated(unsafe) static var progress: [String: Any] = ["phase": "idle"]
    private static let completionMarker = URL(fileURLWithPath: "/private/var/db/vphoned/bootstrap.json")
    private static let legacyCompletionMarker = Bundle.main.executableURL!
        .deletingLastPathComponent()
        .appendingPathComponent(".vphoned-boostrap-completed")

    static func install(jailbreak: [String: Any], layout: String, packagePath: String? = nil) throws -> [String: Any] {
        installLock.lock()
        defer { installLock.unlock() }
        // Installation runs once. A second request is not a failure: answer
        // with a code the host recognizes, and leave reinstalling to
        // uninstall followed by install.
        if let installation = try completedBootstrap() {
            throw GuestAPIError.alreadyDone(
                code: alreadyInstalledCode,
                message: "Irisin bootstrap already completed in \(installation.root) (\(installation.layout))",
            )
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

        stopWatchingBootstrapPackages()
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

    static func refreshBootstrapOnStartup() {
        var installation: (layout: String, root: String)?
        do {
            installation = try completedBootstrap()
            if let installation, installation.layout == "roothide" {
                let base = try repairRootHide(root: installation.root)
                if base["created"] as? [String] != [] || base["deferred"] as? [String] != [] {
                    NSLog("vphoned: RootHide bootstrap base: %@", String(describing: base))
                }
            }
        } catch {
            NSLog("vphoned: could not repair RootHide bootstrap: %@", String(describing: error))
        }
        if let installation {
            watchBootstrapPackages(layout: installation.layout, root: installation.root)
            // Off the startup path: the server should not wait for launchd.
            DispatchQueue.global().async {
                loadBootstrapDaemons(layout: installation.layout, root: installation.root)
            }
        }
        do {
            _ = try repairFirmwareRecord()
        } catch {
            NSLog("vphoned: could not refresh bootstrap firmware record: %@", String(describing: error))
        }
    }

    // MARK: - Roots and completion marker

    static func bootstrapRoot(layout: String, detected: String?) throws -> String {
        layout == "rootless" ? rootlessRoot : try roothideBootstrapRoot(detected: detected)
    }

    private static func bootstrapRoots() throws -> [(layout: String, root: String)] {
        var roots: [(layout: String, root: String)] = []
        if let installation = try completedBootstrap() {
            roots.append(installation)
        }
        if itemExists(URL(fileURLWithPath: rootlessRoot)), !roots.contains(where: { $0.root == rootlessRoot }) {
            roots.append(("rootless", rootlessRoot))
        }
        for root in try roothideRoots() where !roots.contains(where: { $0.root == root }) {
            roots.append(("roothide", root))
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

    /// A RootHide root must be a physical directory; only rootless `/var/jb`
    /// may be a link, and then its target is removed with it.
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
        return try (rootlessLinkTarget(root), true)
    }

    static func completedBootstrap() throws -> (layout: String, root: String)? {
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
              layout == "rootless" || layout == "roothide"
        else { throw GuestAPIError.operationFailed("Completed bootstrap marker has an invalid root") }
        // A RootHide root under another name is left for uninstall to find.
        guard root == (layout == "rootless" ? rootlessRoot : roothideRoot) else { return nil }
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

    // MARK: - Progress

    static func setProgress(_ value: [String: Any]) {
        progressLock.lock()
        progress = value
        progressLock.unlock()
    }

    static func downloadProgress(received: Int64, total: Int64) {
        progressLock.lock()
        progress["downloaded_bytes"] = received
        if total > 0 {
            progress["total_bytes"] = total
        }
        progressLock.unlock()
    }

    // MARK: - Installation

    private static func performInstall(jailbreak: [String: Any], layout: String, packagePath: String?) throws -> [String: Any] {
        let detectedLayout = jailbreak["layout"] as? String
        guard layout == "rootless" || layout == "roothide" else {
            throw GuestAPIError.invalidRequest("layout must be rootless or roothide")
        }
        if let detectedLayout, layout != detectedLayout {
            throw GuestAPIError.invalidRequest("Requested layout does not match the guest bootstrap")
        }
        // Before anything is created, so a refused layout leaves no root behind.
        guard let architecture = GuestBootstrapPlatform.packageArchitecture(
            layout: layout, tvOS: GuestBootstrapPlatform.isTVOS,
        ) else {
            throw GuestAPIError.invalidRequest("Irisin serves only a roothide bootstrap on tvOS")
        }
        let root = try bootstrapRoot(layout: layout, detected: jailbreak["jbroot"] as? String)
        // icli refuses to refresh an Applications directory that is not there,
        // and the Apple TV package carries no app to create it.
        for directory in [root, root + "/usr/lib", root + "/Applications"] {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o755])
        }
        guard isDirectory(root) else {
            throw GuestAPIError.operationFailed("Jailbreak root is not a directory: \(root)")
        }

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
                throw GuestAPIError.operationFailed("The download is damaged. Try again.")
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
            ? extracted.appendingPathComponent(String(rootlessRoot.dropFirst()), isDirectory: true)
            : extracted
        let app = payload.appendingPathComponent("Applications/irisin.app", isDirectory: true)
        let daemon = payload.appendingPathComponent("usr/libexec/irisind")
        let helper = payload.appendingPathComponent("usr/libexec/irisin-install")
        let plist = payload.appendingPathComponent("Library/LaunchDaemons/\(serviceLabel).plist")
        let carriesApp = itemExists(app)
        guard carriesApp || !GuestBootstrapPlatform.packageRequiresApp(architecture: architecture) else {
            throw GuestAPIError.operationFailed("Irisin release payload is incomplete or has the wrong layout")
        }
        try validatePayload(app: carriesApp ? app : nil, daemon: daemon, helper: helper, plist: plist,
                            version: version, architecture: architecture, layout: layout)

        if layout == "roothide" {
            _ = try patchRootHideDaemon(at: plist.path, root: root)
        }
        if carriesApp {
            try prepareAppData(home: appHome(layout: layout, root: root))
        }

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
                base = try repairRootHide(root: root)
            }
            let registration: Any = carriesApp ? try registerApp(installedApp.path) : NSNull()
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
            watchBootstrapPackages(layout: layout, root: root)
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
                "app_path": carriesApp ? installedApp.path : NSNull(),
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

    // MARK: - Filesystem checks

    static func directoryExistsWithoutSymlink(_ path: String) throws -> Bool {
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

    static func isDirectory(_ path: String) -> Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &directory) && directory.boolValue
    }

    static func itemExists(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0
    }
}

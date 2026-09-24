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
    nonisolated(unsafe) private static var progress: [String: Any] = ["phase": "idle"]
    private static let completionMarker = Bundle.main.executableURL!
        .deletingLastPathComponent()
        .appendingPathComponent(".vphoned-boostrap-completed")

    static func install(jailbreak: [String: Any], layout: String) throws -> [String: Any] {
        installLock.lock()
        defer { installLock.unlock() }
        guard !itemExists(completionMarker) else {
            throw GuestAPIError.operationFailed("Irisin bootstrap already completed: \(completionMarker.path)")
        }
        setProgress(["phase": "preparing", "layout": layout])
        do {
            let result = try performInstall(jailbreak: jailbreak, layout: layout)
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
        guard let installation = try completedBootstrap() else { return ["installed": false] }
        return ["installed": true, "layout": installation.layout, "jbroot": installation.root]
    }

    static func uninstall(expectedRoot: String) throws -> [String: Any] {
        installLock.lock()
        defer { installLock.unlock() }
        guard let installation = try completedBootstrap() else {
            throw GuestAPIError.operationFailed("No completed vphoned bootstrap was found")
        }
        let root = installation.root
        guard expectedRoot == root else {
            throw GuestAPIError.invalidRequest("Bootstrap path changed; inspect it again before uninstalling")
        }

        let files = FileManager.default
        let rootURL = URL(fileURLWithPath: root, isDirectory: true)
        let removal = try removalRoot(root, layout: installation.layout)
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
                if !plists.isEmpty { _ = try loadServices(plists, load: false, override: false) }
            }

            let apps = rootURL.appendingPathComponent("Applications", isDirectory: true).path
            if try physicalChildDirectoryExists(root: root, relative: "Applications") {
                _ = try unregisterAppsInDirectory(apps, force: true)
            }
            try files.removeItem(atPath: removal.physicalPath)
        }
        if removal.isSymlink { try files.removeItem(at: rootURL) }
        try files.removeItem(at: completionMarker)
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
            do {
                _ = try requestReboot(userspace: false, force: true)
            } catch {
                NSLog("vphoned: bootstrap removed but reboot failed: %@", String(describing: error))
            }
        }
        return ["jbroot": root, "layout": installation.layout, "deleted": true, "reboot_scheduled": true]
    }

    private static func completedBootstrap() throws -> (layout: String, root: String)? {
        guard itemExists(completionMarker) else { return nil }
        let data = try Data(contentsOf: completionMarker)
        guard let marker = try JSONSerialization.jsonObject(with: data) as? [String: String],
              let layout = marker["layout"], let root = marker["jbroot"],
              (layout == "rootless" && root == "/var/jb") ||
              (layout == "roothide" && root.hasPrefix("/private/var/containers/Bundle/Application/")
               && roothideName(String(root.dropFirst("/private/var/containers/Bundle/Application/".count))))
        else { throw GuestAPIError.operationFailed("Completed bootstrap marker has an invalid root") }
        return (layout, root)
    }

    private static func directoryExistsWithoutSymlink(_ path: String) throws -> Bool {
        var info = stat()
        if lstat(path, &info) != 0 {
            if errno == ENOENT { return false }
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
            if errno == ENOENT { return (root, false) }
            throw GuestAPIError.operationFailed("Could not inspect bootstrap root: \(root)")
        }
        if info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) { return (root, false) }
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
              physicalPath == (physicalPath as NSString).standardizingPath else {
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
        if total > 0 { progress["total_bytes"] = total }
        progressLock.unlock()
    }

    private static func performInstall(jailbreak: [String: Any], layout: String) throws -> [String: Any] {
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
        let release = try releaseAsset(architecture: architecture)
        setProgress(["phase": "downloading", "layout": layout, "tag": release.tag,
                     "downloaded_bytes": 0])
        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("vphoned-irisin-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        let package = work.appendingPathComponent(release.name)
        let packageData = try fetch(release.url, reportDownload: true)
        let digest = SHA256.hash(data: packageData).map { String(format: "%02x", $0) }.joined()
        guard digest == release.digest else {
            throw GuestAPIError.operationFailed("Irisin release asset SHA-256 mismatch")
        }
        try packageData.write(to: package, options: .atomic)
        setProgress(["phase": "extracting", "layout": layout, "tag": release.tag])

        let metadata = try readDeb(package.path)
        let control = metadata["control"] as? [String: String] ?? [:]
        guard control["Package"] == "wiki.qaq.irisin",
              control["Version"] == release.version,
              control["Architecture"] == architecture
        else { throw GuestAPIError.operationFailed("Irisin package metadata does not match the release") }

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
                            version: release.version, architecture: architecture, layout: layout)

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
            setProgress(["phase": "installing", "layout": layout, "tag": release.tag])
            for (source, target) in components {
                replaced.append(try replace(source, at: target))
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
            setProgress(["phase": "firmware", "layout": layout, "tag": release.tag])
            let firmware = try ensureFirmwareRecord(root: root)
            let marker = ["tag": release.tag, "layout": layout, "jbroot": root]
            try JSONSerialization.data(withJSONObject: marker).write(to: completionMarker, options: .atomic)
            for entry in replaced {
                if let backup = entry.backup { try? FileManager.default.removeItem(at: backup) }
            }
            var result: [String: Any] = [
                "tag": release.tag,
                "version": release.version,
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
            if let started { result["service_start"] = started }
            if let startWarning { result["service_start_warning"] = startWarning }
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
            if itemExists(installedApp) { _ = try? registerApp(installedApp.path) }
            if hadService { _ = try? loadServices([installedPlist.path], load: true, override: false) }
            throw error
        }
    }

    static func repairFirmwareRecord() throws -> [String: Any] {
        installLock.lock()
        defer { installLock.unlock() }
        let data = try Data(contentsOf: completionMarker)
        guard let marker = try JSONSerialization.jsonObject(with: data) as? [String: String],
              let layout = marker["layout"], let root = marker["jbroot"],
              layout == "rootless" || layout == "roothide",
              root == (try bootstrapRoot(layout: layout, detected: nil)),
              isDirectory(root)
        else { throw GuestAPIError.operationFailed("No valid completed vphoned bootstrap was found") }
        let firmware = try ensureFirmwareRecord(root: root)
        return ["layout": layout, "jbroot": root,
                "firmware_version": firmware.version, "dpkg_database_updated": firmware.updated]
    }

    static func refreshFirmwareOnStartup() {
        guard itemExists(completionMarker) else { return }
        do {
            _ = try repairFirmwareRecord()
        } catch {
            NSLog("vphoned: could not refresh bootstrap firmware record: %@", String(describing: error))
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
            if oldVersion == version { return (version, false) }
            var updated = lines.map {
                $0.hasPrefix("Version: ") ? "Version: \(version)" : $0
            }
            if oldVersion.isEmpty { updated.append("Version: \(version)") }
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
        if layout == "rootless" { return "/var/jb" }
        if let detected { return detected }

        let parent = "/private/var/containers/Bundle/Application"
        let names = try FileManager.default.contentsOfDirectory(atPath: parent)
            .filter { roothideName($0) && isDirectory(parent + "/" + $0) }
        guard names.count <= 1 else {
            throw GuestAPIError.operationFailed("Multiple RootHide bootstrap roots exist")
        }
        if let name = names.first { return parent + "/" + name }

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
        version: String, architecture: String, layout: String
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

    private static func prepareAppData() throws {
        let path = "/var/mobile/Documents/wiki.qaq.irisin"
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o755])
        guard chown(path, 501, 501) == 0 else {
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
            if let old { try? files.moveItem(at: old, to: target) }
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

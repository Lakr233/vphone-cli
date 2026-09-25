import Darwin
import Foundation

/// The object exported to one app connection.
final class VPhoneLaunchpadHelperService: NSObject, VPhoneLaunchpadHelperProtocol, @unchecked Sendable {
    private weak var connection: NSXPCConnection?
    private let callerUID: uid_t
    private let callerGID: gid_t
    private let work = DispatchQueue(label: "com.vphone.launchpad.helper.work")

    /// One CFW install at a time across every connection: two installs
    /// host-mounting disks at once is never what anyone wants.
    private static let firmwareLock = NSLock()
    nonisolated(unsafe) private static var firmwareProcess: Process?

    init(connection: NSXPCConnection) {
        self.connection = connection
        callerUID = connection.effectiveUserIdentifier
        callerGID = connection.effectiveGroupIdentifier
    }

    // MARK: - Version

    func helperVersion(reply: @escaping @Sendable (String) -> Void) {
        reply(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0")
    }

    // MARK: - Bundles

    func installBundle(
        version: String,
        archive: FileHandle,
        sha256: String,
        reply: @escaping @Sendable (String?) -> Void,
    ) {
        work.async {
            do {
                try VPhoneLaunchpadHelperBundleInstaller.install(version: version, archive: archive, sha256: sha256)
                reply(nil)
            } catch {
                reply(error.localizedDescription)
            }
        }
    }

    func removeBundle(version: String, reply: @escaping @Sendable (String?) -> Void) {
        work.async {
            do {
                try VPhoneLaunchpadHelperBundleInstaller.remove(version: version)
                reply(nil)
            } catch {
                reply(error.localizedDescription)
            }
        }
    }

    func allowVirtualMachine(bundleVersion: String, reply: @escaping @Sendable (String?) -> Void) {
        work.async {
            do {
                try VPhoneLaunchpadHelperAMFI.allow(bundleVersion: bundleVersion)
                reply(nil)
            } catch {
                reply(error.localizedDescription)
            }
        }
    }

    // MARK: - CFW install

    func installCustomFirmware(
        bundleVersion: String,
        machineName: String,
        libraryRoot: String,
        forceDyldSharedCacheMaxSlide: Bool,
        keepArtifacts: Bool,
        reply: @escaping @Sendable (Int32, String?) -> Void,
    ) {
        let callerUID = callerUID
        let callerGID = callerGID
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let request: VPhoneLaunchpadHelperFirmwareRequest
            do {
                request = try VPhoneLaunchpadHelperFirmwareRequest(
                    bundleVersion: bundleVersion,
                    machineName: machineName,
                    libraryRoot: libraryRoot,
                    forceDyldSharedCacheMaxSlide: forceDyldSharedCacheMaxSlide,
                    keepArtifacts: keepArtifacts,
                    callerUID: callerUID,
                    callerGID: callerGID,
                )
            } catch {
                reply(-1, error.localizedDescription)
                return
            }

            let process = Process()
            process.executableURL = request.executable
            process.arguments = request.arguments
            process.environment = request.environment
            process.currentDirectoryURL = request.workingDirectory
            let pipe = Pipe()
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = pipe
            process.standardError = pipe

            Self.firmwareLock.lock()
            guard Self.firmwareProcess == nil else {
                Self.firmwareLock.unlock()
                reply(-1, "Another CFW install is in progress. Wait for it to finish, then try again.")
                return
            }
            Self.firmwareProcess = process
            Self.firmwareLock.unlock()
            defer {
                Self.firmwareLock.lock()
                Self.firmwareProcess = nil
                Self.firmwareLock.unlock()
            }

            do {
                try process.run()
            } catch {
                reply(-1, "Unable to start vphone-cli. \(error.localizedDescription)")
                return
            }
            emit("$ vphone-cli \(request.arguments.joined(separator: " "))  (as root)")
            VPhoneLaunchpadLineReader.readLines(from: pipe.fileHandleForReading) { emit($0) }
            process.waitUntilExit()
            reply(process.terminationStatus, nil)
        }
    }

    func cancelCustomFirmware(reply: @escaping @Sendable () -> Void) {
        Self.firmwareLock.lock()
        Self.firmwareProcess?.interrupt()
        Self.firmwareLock.unlock()
        reply()
    }

    // MARK: - Uninstall

    func uninstallHelper(reply: @escaping @Sendable (String?) -> Void) {
        let label = VPhoneLaunchpadHelperIdentity.label
        let fileManager = FileManager.default
        try? fileManager.removeItem(atPath: "/Library/LaunchDaemons/\(label).plist")
        try? fileManager.removeItem(atPath: "/Library/PrivilegedHelperTools/\(label)")
        reply(nil)
        // Booting out our own job ends this process; give the reply a moment
        // to leave first.
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            process.arguments = ["bootout", "system/\(label)"]
            try? process.run()
            process.waitUntilExit()
            exit(0)
        }
    }

    // MARK: - Output

    private func emit(_ line: String) {
        let client = connection?.remoteObjectProxy as? VPhoneLaunchpadHelperClientProtocol
        client?.helperDidEmit(line: line)
    }
}

import Darwin
import Foundation

/// The object exported to one app connection.
final class VPhoneLaunchpadHelperService: NSObject, VPhoneLaunchpadHelperProtocol, @unchecked Sendable {
    private weak var connection: NSXPCConnection?
    private let callerUID: uid_t
    private let callerGID: gid_t
    private let work = DispatchQueue(label: "com.vphone.launchpad.helper.work")

    /// One CFW install at a time across every connection: two installs
    /// host-mounting disks at once is never what anyone wants. The owner is
    /// the user that started it, the only one allowed to cancel it.
    private static let firmwareLock = NSLock()
    private nonisolated(unsafe) static var firmwareProcess: Process?
    private nonisolated(unsafe) static var firmwareOwner: uid_t?

    init(connection: NSXPCConnection) {
        self.connection = connection
        callerUID = connection.effectiveUserIdentifier
        callerGID = connection.effectiveGroupIdentifier
    }

    // MARK: - Version

    func helperVersion(reply: @escaping @Sendable (String) -> Void) {
        reply(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0")
    }

    func unattendedVMManagementEnabled(reply: @escaping @Sendable (Bool) -> Void) {
        reply(VPhoneLaunchpadHelperUnattendedGrant.enabled(for: callerUID))
    }

    func enableUnattendedVMManagement(authorization: Data, reply: @escaping @Sendable (String?) -> Void) {
        let callerUID = callerUID
        work.async {
            do {
                try VPhoneLaunchpadHelperAuthorization.require(authorization)
                try VPhoneLaunchpadHelperUnattendedGrant.enable(for: callerUID)
                reply(nil)
            } catch {
                reply(error.localizedDescription)
            }
        }
    }

    func disableUnattendedVMManagement(reply: @escaping @Sendable (String?) -> Void) {
        let callerUID = callerUID
        work.async {
            do {
                try VPhoneLaunchpadHelperUnattendedGrant.disable(for: callerUID)
                reply(nil)
            } catch {
                reply(error.localizedDescription)
            }
        }
    }

    // MARK: - Bundles

    func installBundle(
        authorization: Data,
        version: String,
        archive: FileHandle,
        sha256: String,
        reply: @escaping @Sendable (String?) -> Void,
    ) {
        work.async {
            do {
                try VPhoneLaunchpadHelperAuthorization.require(authorization)
                try VPhoneLaunchpadHelperBundleInstaller.install(version: version, archive: archive, sha256: sha256)
                reply(nil)
            } catch {
                reply(error.localizedDescription)
            }
        }
    }

    func removeBundle(authorization: Data, version: String, reply: @escaping @Sendable (String?) -> Void) {
        work.async {
            do {
                try VPhoneLaunchpadHelperAuthorization.require(authorization)
                try VPhoneLaunchpadHelperBundleInstaller.remove(version: version)
                reply(nil)
            } catch {
                reply(error.localizedDescription)
            }
        }
    }

    func allowVirtualMachine(authorization: Data, bundleVersion: String, reply: @escaping @Sendable (String?) -> Void) {
        let callerUID = callerUID
        work.async {
            do {
                try VPhoneLaunchpadHelperAuthorization.requireVMManagement(authorization, callerUID: callerUID)
                try VPhoneLaunchpadHelperAMFI.allow(bundleVersion: bundleVersion)
                reply(nil)
            } catch {
                reply(error.localizedDescription)
            }
        }
    }

    // MARK: - CFW install

    func installCustomFirmware(
        authorization: Data,
        bundleVersion: String,
        machineName: String,
        libraryRoot: String,
        keepArtifacts: Bool,
        reply: @escaping @Sendable (Int32, String?) -> Void,
    ) {
        runFirmware(
            .install(keepArtifacts: keepArtifacts),
            authorization: authorization,
            bundleVersion: bundleVersion,
            machineName: machineName,
            libraryRoot: libraryRoot,
            reply: reply,
        )
    }

    func updateGuestEnvironment(
        authorization: Data,
        bundleVersion: String,
        machineName: String,
        libraryRoot: String,
        reply: @escaping @Sendable (Int32, String?) -> Void,
    ) {
        runFirmware(
            .updateEnvironment,
            authorization: authorization,
            bundleVersion: bundleVersion,
            machineName: machineName,
            libraryRoot: libraryRoot,
            reply: reply,
        )
    }

    func updateKernel(
        authorization: Data,
        bundleVersion: String,
        machineName: String,
        libraryRoot: String,
        reply: @escaping @Sendable (Int32, String?) -> Void,
    ) {
        runFirmware(
            .updateKernel,
            authorization: authorization,
            bundleVersion: bundleVersion,
            machineName: machineName,
            libraryRoot: libraryRoot,
            reply: reply,
        )
    }

    /// Both operations share one slot, so an install and an environment
    /// update never write the same machine at once, and one cancel stops
    /// either.
    private func runFirmware(
        _ operation: VPhoneLaunchpadHelperFirmwareRequest.Operation,
        authorization: Data,
        bundleVersion: String,
        machineName: String,
        libraryRoot: String,
        reply: @escaping @Sendable (Int32, String?) -> Void,
    ) {
        let callerUID = callerUID
        let callerGID = callerGID
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let request: VPhoneLaunchpadHelperFirmwareRequest
            do {
                try VPhoneLaunchpadHelperAuthorization.requireVMManagement(authorization, callerUID: callerUID)
                request = try VPhoneLaunchpadHelperFirmwareRequest(
                    operation: operation,
                    bundleVersion: bundleVersion,
                    machineName: machineName,
                    libraryRoot: libraryRoot,
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
                reply(-1, "Another CFW install or environment update is in progress. Wait for it to finish, then try again.")
                return
            }
            Self.firmwareProcess = process
            Self.firmwareOwner = callerUID
            Self.firmwareLock.unlock()
            defer {
                Self.firmwareLock.lock()
                Self.firmwareProcess = nil
                Self.firmwareOwner = nil
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
            finishOutput()
            reply(process.terminationStatus, nil)
        }
    }

    // MARK: - DHCP leases

    func releaseOrphanedLeases(
        authorization: Data,
        bundleVersion: String,
        libraryRoots: [String],
        reply: @escaping @Sendable (String?, String?) -> Void,
    ) {
        let callerUID = callerUID
        let callerGID = callerGID
        // Not on `work`: a bundle install queued there would hold it up, and
        // the lease list has its own guard against a concurrent writer.
        DispatchQueue.global(qos: .userInitiated).async {
            let request: VPhoneLaunchpadHelperLeasesRequest
            do {
                try VPhoneLaunchpadHelperAuthorization.requireVMManagement(authorization, callerUID: callerUID)
                request = try VPhoneLaunchpadHelperLeasesRequest(
                    bundleVersion: bundleVersion,
                    libraryRoots: libraryRoots,
                    callerUID: callerUID,
                    callerGID: callerGID,
                )
            } catch {
                reply(nil, error.localizedDescription)
                return
            }

            let process = Process()
            process.executableURL = request.executable
            process.arguments = request.arguments
            process.environment = request.environment
            process.currentDirectoryURL = URL(fileURLWithPath: "/", isDirectory: true)
            process.standardInput = FileHandle.nullDevice
            let output = Pipe()
            let errors = Pipe()
            process.standardOutput = output
            process.standardError = errors
            do {
                try process.run()
            } catch {
                reply(nil, "Unable to start vphone-cli. \(error.localizedDescription)")
                return
            }
            // stderr is drained alongside, so a full pipe cannot stall the child.
            nonisolated(unsafe) var errorData = Data()
            let drained = DispatchGroup()
            DispatchQueue.global().async(group: drained) {
                errorData = errors.fileHandleForReading.readDataToEndOfFile()
            }
            let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            drained.wait()
            process.waitUntilExit()
            guard process.terminationReason == .exit, process.terminationStatus == 0 else {
                // ArgumentParser puts the reason on an "Error: " line, then usage.
                let message = String(decoding: errorData, as: UTF8.self)
                    .split(separator: "\n")
                    .first { $0.hasPrefix("Error: ") }
                    .map { String($0.dropFirst("Error: ".count)) }
                reply(nil, message ?? "Unable to release the DHCP leases (vphone-cli exited with \(process.terminationStatus)).")
                return
            }
            reply(text, nil)
        }
    }

    func cancelCustomFirmware(reply: @escaping @Sendable () -> Void) {
        let callerUID = callerUID
        // Not on `work`: a bundle install queued there must not delay a cancel.
        // No authorization check: the install's right may have expired by
        // now, and a prompt here could leave the install running. Only the
        // user who started the install can stop it.
        DispatchQueue.global(qos: .userInitiated).async {
            defer { reply() }
            Self.firmwareLock.lock()
            if Self.firmwareOwner == callerUID {
                Self.firmwareProcess?.interrupt()
            }
            Self.firmwareLock.unlock()
        }
    }

    // MARK: - Uninstall

    func uninstallHelper(authorization: Data, reply: @escaping @Sendable (String?) -> Void) {
        work.async { [self] in
            do {
                try VPhoneLaunchpadHelperAuthorization.require(authorization)
                try VPhoneLaunchpadHelperUnattendedGrant.removeAllForHelperUninstall()
            } catch {
                reply(error.localizedDescription)
                return
            }
            removeHelper(reply: reply)
        }
    }

    private func removeHelper(reply: @escaping @Sendable (String?) -> Void) {
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

    /// Waits until the app has handled every line emitted so far, the
    /// connection fails, or 30 seconds pass. Without it the request's reply
    /// could overtake the last lines, which then reach an app that has stopped
    /// listening: the output a command flushes when it exits never made the
    /// console log. Bounded, so a stuck app cannot hold the install lock.
    private func finishOutput() {
        let handled = DispatchSemaphore(value: 0)
        let proxy = connection?.remoteObjectProxyWithErrorHandler { _ in handled.signal() }
        guard let client = proxy as? VPhoneLaunchpadHelperClientProtocol else {
            return
        }
        client.helperDidFinishOutput { handled.signal() }
        _ = handled.wait(timeout: .now() + 30)
    }
}

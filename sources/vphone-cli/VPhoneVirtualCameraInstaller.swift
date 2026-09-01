import Foundation
import VPhoneCameraShared

/// Starts the independently signed Camera Installer app before VM boot. The
/// installer owns Apple's System Extension provisioning boundary; this VM app
/// owns VM startup and the loopback frame endpoint.
@MainActor
final class VPhoneVirtualCameraInstaller {
    enum Result {
        case enabled
        case awaitingApproval
    }

    var onStatusChange: ((String) -> Void)?

    func activate() async throws -> Result {
        let appURL = installerAppURL()
        let executable = appURL.appendingPathComponent(
            "Contents/MacOS/vphone-camera-installer", isDirectory: false)
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw VPhoneError.virtualCameraUnavailable(
                "Camera Installer is missing at \(appURL.path); install both vphone-cli and "
                    + "vphone-cli-camera-installer.app in /Applications"
            )
        }

        let process = Process()
        let output = Pipe()
        process.executableURL = executable
        process.arguments = ["--activate"]
        process.standardOutput = output
        process.standardError = output
        try process.run()
        await wait(for: process)

        let message = String(data: output.fileHandleForReading.readDataToEndOfFile(),
                             encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !message.isEmpty {
            message.split(separator: "\n").forEach { onStatusChange?(String($0)) }
        }

        switch process.terminationStatus {
        case 0:
            if let conflict = activeTeamConflict() {
                throw VPhoneError.virtualCameraUnavailable(conflict)
            }
            onStatusChange?("VPhone Display: installer reports enabled")
            return .enabled
        case 3:
            onStatusChange?("VPhone Display: awaiting approval; the VM endpoint will remain ready")
            return .awaitingApproval
        case 4:
            throw VPhoneError.virtualCameraUnavailable(
                "Camera Installer completed only after reboot; restart macOS, then launch the VM again"
            )
        default:
            throw VPhoneError.virtualCameraUnavailable(
                "Camera Installer failed (exit \(process.terminationStatus))"
                    + (message.isEmpty ? "" : ": \(message)")
            )
        }
    }

    private func installerAppURL() -> URL {
        if let override = ProcessInfo.processInfo.environment["VPHONE_CAMERA_INSTALLER_APP"],
           !override.isEmpty {
            return URL(fileURLWithPath: override).standardizedFileURL
        }
        let mainApp = Bundle.main.bundleURL.resolvingSymlinksInPath().standardizedFileURL
        return mainApp.deletingLastPathComponent()
            .appendingPathComponent("vphone-cli-camera-installer.app", isDirectory: true)
    }

    /// A bundle identifier is not sufficient to identify a system extension:
    /// macOS can retain an older installation signed by another team. In that
    /// state activation succeeds but CoreMediaIO may launch the stale provider,
    /// leaving the current registry invisible to AVFoundation clients.
    private func activeTeamConflict() -> String? {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/systemextensionsctl")
        process.arguments = ["list", "com.apple.system_extension.cmio"]
        process.standardOutput = output
        process.standardError = output
        guard (try? process.run()) != nil else { return nil }
        process.waitUntilExit()
        guard let text = String(
            data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8
        ) else { return nil }

        var teams = Set<String>()
        for line in text.split(separator: "\n") where line.contains(VPhoneVirtualCamera.extensionIdentifier) {
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            // Enabled + active rows begin with "* *". Pending/terminated rows
            // are intentionally ignored because they do not own the provider.
            guard fields.count >= 4, fields[0] == "*", fields[1] == "*" else { continue }
            teams.insert(String(fields[2]))
        }
        guard teams.count > 1 else { return nil }
        let ids = teams.sorted().joined(separator: ", ")
        return "multiple active Camera Extensions share \(VPhoneVirtualCamera.extensionIdentifier) "
            + "(teams: \(ids)); disable/remove the older VPhone Display Camera in "
            + "System Settings > General > Login Items & Extensions > Camera Extensions, "
            + "then restart macOS"
    }

    private func wait(for process: Process) async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                process.waitUntilExit()
                continuation.resume()
            }
        }
    }
}

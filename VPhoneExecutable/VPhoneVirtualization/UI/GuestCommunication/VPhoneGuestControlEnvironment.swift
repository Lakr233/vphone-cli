import CryptoKit
import Foundation
import VPhoneCoreKit

// MARK: - vphone Environment

/// Keeps the guest's /usr/lib hooks in step with this bundle, the way the
/// probe keeps vphoned in step: compare hashes, upload what differs, install.
extension VPhoneGuestControl {
    struct EnvironmentUpdate {
        let installed: [String]
        let rebootRequired: Bool
    }

    /// Uploads each bundled library whose hash differs from the guest's copy,
    /// then installs them together. An up-to-date guest installs nothing.
    func updateEnvironment() async throws -> EnvironmentUpdate {
        guard guestCapabilities.contains("environment_update") else {
            throw ControlError.unsupportedCapability("environment_update")
        }
        let status = try await call("environment.status")
        guard let staging = status["staging"] as? String,
              let rows = status["libraries"] as? [[String: Any]]
        else {
            throw ControlError.protocolError("missing environment status")
        }
        let guestHashes = Dictionary(
            rows.compactMap { row -> (String, String)? in
                guard let name = row["name"] as? String, let hash = row["sha256"] as? String else { return nil }
                return (name, hash)
            },
            uniquingKeysWith: { first, _ in first },
        )
        typealias Library = (name: String, data: Data, hash: String)
        let changed = try VPhoneGuestEnvironment.libraries.compactMap { name -> Library? in
            let data = try Data(contentsOf: VPhoneGuestBinaries.resolve(name), options: .mappedIfSafe)
            let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            return guestHashes[name] == hash ? nil : (name, data, hash)
        }
        guard !changed.isEmpty else {
            return EnvironmentUpdate(installed: [], rebootRequired: false)
        }

        try await createDirectory(path: staging)
        for library in changed {
            try await uploadFile(path: staging + "/" + library.name, data: library.data)
        }
        let result = try await call(
            "environment.install",
            params: ["libraries": changed.map { ["name": $0.name, "sha256": $0.hash] }],
        )
        return EnvironmentUpdate(
            installed: result["installed"] as? [String] ?? [],
            rebootRequired: result["reboot_required"] as? Bool ?? false,
        )
    }

    /// Runs once per connection. A failure is logged and leaves the guest's
    /// current libraries in place.
    func syncEnvironment() async {
        do {
            let update = try await updateEnvironment()
            guard !update.installed.isEmpty else { return }
            print("[environment] installed \(update.installed.joined(separator: ", "))")
            if update.rebootRequired {
                print("[environment] restart the guest to load the new launchd hook")
            }
        } catch {
            print("[environment] update failed: \(error)")
        }
    }
}

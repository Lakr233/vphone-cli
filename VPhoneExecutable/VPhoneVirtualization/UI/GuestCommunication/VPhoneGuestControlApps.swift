import Foundation

extension VPhoneGuestControl {
    // MARK: - App Management

    /// Every registered app with its running PID; the browser filters locally.
    func appList() async throws -> [String: Any] {
        try await call("apps.list", params: ["filter": "all"])
    }

    func appLaunch(bundleID: String) async throws -> [String: Any] {
        try await call("apps.launch", params: ["bundle_id": bundleID])
    }

    func appTerminate(bundleID: String) async throws -> [String: Any] {
        try await call("apps.terminate", params: ["bundle_id": bundleID])
    }

    /// Removes the app and its data container. Confirm with the user first.
    func appUninstall(bundleID: String) async throws -> [String: Any] {
        try await call("apps.uninstall", params: ["bundle_id": bundleID, "force": true])
    }

    func appOpenURL(_ url: String, bundleID: String) async throws -> [String: Any] {
        try await call("apps.open_url", params: ["url": url, "bundle_id": bundleID])
    }

    // MARK: - App Detail

    func appInfo(bundleID: String) async throws -> [String: Any] {
        try await call("apps.info", params: ["bundle_id": bundleID])
    }

    func appBinary(bundleID: String) async throws -> [String: Any] {
        try await call("apps.binary", params: ["bundle_id": bundleID])
    }

    func appDataDirectory(bundleID: String) async throws -> [String: Any] {
        try await call("apps.data_dir", params: ["bundle_id": bundleID])
    }

    /// `schemes`: bundle identifier → URL schemes, for every app.
    func appURLSchemes() async throws -> [String: Any] {
        try await call("apps.url_schemes")
    }

    func appNetworkPolicy(bundleID: String, repair: Bool = false) async throws -> [String: Any] {
        try await call("apps.network_policy", params: ["bundle_id": bundleID, "repair": repair])
    }
}

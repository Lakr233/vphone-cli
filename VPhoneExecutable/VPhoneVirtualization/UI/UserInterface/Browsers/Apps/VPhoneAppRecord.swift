import Foundation

// MARK: - App Record

/// One row of `apps.list`: a LaunchServices registration (or an app bundle
/// found in an application directory) with vphoned's running PID and type.
struct VPhoneAppRecord: Identifiable, Hashable {
    let bundleID: String
    let name: String
    let version: String
    let build: String
    /// `system` or `user`, as vphoned normalizes it.
    let type: String
    let pid: Int
    let bundlePath: String
    let dataPath: String

    var id: String {
        bundleID
    }

    var displayName: String {
        name.isEmpty ? bundleID : name
    }

    var isRunning: Bool {
        pid > 0
    }

    /// System apps live on the sealed system volume and cannot be uninstalled.
    var isSystem: Bool {
        type == "system"
    }

    var typeTitle: String {
        isSystem
            ? String(localized: "System", bundle: VPhoneLocalization.bundle)
            : String(localized: "User", bundle: VPhoneLocalization.bundle)
    }

    init?(json: [String: Any]) {
        guard let bundleID = json.string("bundle_id"), !bundleID.isEmpty else { return nil }
        self.bundleID = bundleID
        name = json.string("name") ?? ""
        version = json.string("version") ?? ""
        build = json.string("build") ?? ""
        type = json.string("type")?.lowercased() ?? ""
        pid = json.int("pid") ?? 0
        bundlePath = json.string("path") ?? json.string("bundle_path") ?? ""
        dataPath = json.string("data_path") ?? ""
    }
}

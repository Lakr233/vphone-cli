import Foundation
import IcliKit
import IcliSystem
import VphonedNative

enum AppDetailMethod: String, GuestMethod {
    case appsInfo = "apps.info"
    case appsBinary = "apps.binary"
    case appsDataDir = "apps.data_dir"
    case appsUrlSchemes = "apps.url_schemes"
    case appsHandlers = "apps.handlers"
    case appsRegistration = "apps.registration"
    case appsRegister = "apps.register"
    case appsUnregister = "apps.unregister"
    case appsUnregisterDir = "apps.unregister_dir"
    case appsNetworkPolicy = "apps.network_policy"
    case systemUicache = "system.uicache"
    case systemSystemApps = "system.system_apps"
    case systemRespring = "system.respring"
    case systemReboot = "system.reboot"
    case systemShutdown = "system.shutdown"

    var spec: MethodSpec {
        switch self {
        case .appsInfo: MethodSpec(.required("bundle_id", .string, "Bundle identifier of the app, such as com.apple.mobilesafari"),
                                   summary: "Return an installed app's metadata: name, version, paths, signer, entitlements, schemes and running state.", result: [
                                       .optional("build", .any),
                                       .required("bundle_id", .any),
                                       .required("bundle_path", .any),
                                       .optional("data_path", .any),
                                       .optional("encrypted", .any),
                                       .optional("entitlements", .any).open(),
                                       .optional("executable", .any),
                                       .optional("group_containers", .object).open(),
                                       .optional("minimum_os", .string),
                                       .required("name", .any),
                                       .optional("running", .any),
                                       .optional("schemes", .array),
                                       .optional("sdk", .string),
                                       .optional("signer", .any),
                                       .optional("signing_error", .string),
                                       .optional("type", .any),
                                       .optional("version", .any)])
        case .appsBinary: MethodSpec(.required("bundle_id", .string, "Bundle identifier of the app, such as com.apple.mobilesafari"),
                                     summary: "Return an app's executable path, encryption state and entitlements.", result: [
                                         .required("bundle_id", .string),
                                         .required("encrypted", .boolean),
                                         .required("entitlements", .any).open(),
                                         .required("executable", .string)])
        case .appsDataDir: MethodSpec(.required("bundle_id", .string, "Bundle identifier of the app, such as com.apple.mobilesafari"),
                                      summary: "Return the path of an app's data container.", result: [.required("bundle_id", .string), .required("data_path", .any)])
        case .appsUrlSchemes: MethodSpec(summary: "List every URL scheme registered on the guest with the apps that claim it.", result: [.required("schemes", .object).open()])
        case .appsHandlers: MethodSpec(.required("url", .string, "URL whose scheme to look up, such as https://example.com"),
                                       summary: "List the apps that can open a URL, based on its scheme.", result: [
                                           .optional("apps", .array),
                                           .optional("count", .any),
                                           .optional("error", .string),
                                           .optional("scheme", .string),
                                           .optional("url", .string)])
        case .appsRegistration: MethodSpec(.required("path", .string, "Absolute guest path of the app bundle directory"),
                                           summary: "Report whether an app bundle path is registered with LaunchServices, with its metadata.", result: [
                                               .optional("build", .any),
                                               .optional("bundle_id", .any),
                                               .optional("bundle_path", .any),
                                               .optional("data_path", .any),
                                               .optional("error", .string),
                                               .optional("group_containers", .object).open(),
                                               .optional("name", .any),
                                               .optional("path", .any),
                                               .optional("plugins", .any),
                                               .optional("registered", .boolean),
                                               .optional("running", .any),
                                               .optional("schemes", .array),
                                               .optional("signer", .any),
                                               .optional("type", .any),
                                               .optional("version", .any)])
        case .appsRegister: MethodSpec(.required("path", .string, "Absolute guest path of the app bundle directory"),
                                       summary: "Register an app bundle with LaunchServices so it appears on the home screen.", result: [
                                           .optional("build", .any),
                                           .optional("bundle_id", .any),
                                           .optional("bundle_path", .any),
                                           .optional("data_path", .any),
                                           .optional("error", .string),
                                           .optional("group_containers", .object).open(),
                                           .optional("name", .any),
                                           .required("path", .any),
                                           .optional("plugins", .any),
                                           .optional("registered", .boolean),
                                           .optional("running", .any),
                                           .optional("schemes", .array),
                                           .optional("signer", .any),
                                           .optional("type", .any),
                                           .optional("version", .any)])
        case .appsUnregister:
            MethodSpec(.required("path", .string, "Absolute guest path of the app bundle directory"),
                       summary: "Remove an app bundle's registration from LaunchServices without deleting the files.",
                       force: .always("unregister `<path>`") { p in try "unregister \(GuestAPI.string(p, "path"))" }, result: [
                           .optional("bundle_id", .any),
                           .optional("message", .string),
                           .required("path", .string),
                           .required("unregistered", .boolean)])
        case .appsUnregisterDir:
            MethodSpec(.required("directory", .string, "Absolute guest path of a directory containing app bundles"),
                       summary: "Unregister every app bundle found in a directory from LaunchServices.",
                       force: .always("unregister every app in `<directory>`") { p in try "unregister every app in \(GuestAPI.string(p, "directory"))" }, result: [
                           .optional("directory", .string),
                           .optional("error", .string),
                           .optional("failed", .any),
                           .optional("unregistered", .array),
                           .optional("unverified", .array)])
        case .appsNetworkPolicy: MethodSpec(.required("bundle_id", .string, "Bundle identifier of the app, such as com.apple.mobilesafari"),
                                            .optional("repair", .boolean, "Set the app's cellular and Wi-Fi data policy to always allow when it is not already", default: false),
                                            summary: "Read an app's cellular and Wi-Fi data usage policy and optionally set both to always allow.", result: [
                                                .optional("allowed", .any),
                                                .optional("bundle_id", .string),
                                                .optional("changed", .boolean),
                                                .optional("error", .string),
                                                .optional("policy", .object).open()])
        case .systemUicache: MethodSpec(.optional("directory", .string, "Applications directory to refresh; defaults to the Applications folder of the installed bootstrap"),
                                     summary: "Refresh LaunchServices registrations for the apps in a directory, like uicache -a.", result: [.required("directory", .string),
                                                 .required("failed", .array),
                                                 .required("registered", .array),
                                                 .required("skipped", .array),
                                                 .required("unchanged", .array),
                                                 .required("unregistered", .array),
                                                 .required("unverified", .array)])
        case .systemSystemApps: MethodSpec(.optional("visible", .boolean, "True shows system apps, false hides them; omit to only read the current setting"),
                                        summary: "Read or set whether hidden system apps are visible on the home screen.", result: [.optional("changed", .boolean),
                                                    .optional("configured", .boolean),
                                                    .optional("error", .string),
                                                    .optional("requires_respring", .boolean),
                                                    .required("visible", .any)])
        case .systemRespring: MethodSpec(summary: "Restart SpringBoard, the home screen process, without rebooting the guest.", force: .always("restart SpringBoard"), result: [.required("method", .string),
                                                  .required("pid", .any),
                                                  .required("previous_pid", .integer),
                                                  .required("restarted", .boolean)])
        case .systemReboot:
            MethodSpec(.optional("userspace", .boolean, "True restarts userspace only instead of a full reboot", default: false),
                       summary: "Reboot the guest, or restart only its userspace; the connection drops.",
                       force: .always("reboot the guest") { p in GuestMethodArea.flag(p, "userspace") ? "restart userspace" : "reboot the guest" }, result: [.required("accepted", .boolean), .required("completion", .string), .required("kind", .string)])
        case .systemShutdown: MethodSpec(summary: "Shut the guest down, which ends the virtual machine; the connection drops.", force: .always("shut down the guest"), result: [.required("accepted", .boolean), .required("completion", .string)])
        }
    }
}

// MARK: - App Detail and System Control

extension GuestAPI {
    static func executeAppDetail(_ m: AppDetailMethod, _ params: [String: Any]) throws -> [String: Any] {
        switch m {
        case .appsInfo:
            return try appInfo(string(params, "bundle_id"))
        case .appsBinary:
            return try appBinaryInfo(string(params, "bundle_id"))
        case .appsDataDir:
            return try appDataDir(string(params, "bundle_id"))
        case .appsUrlSchemes:
            return try appURLSchemes()
        case .appsHandlers:
            return try appHandlers(string(params, "url"))
        case .appsRegistration:
            return try appRegistration(string(params, "path"))
        case .appsRegister:
            return try registerApp(string(params, "path"))
        case .appsUnregister:
            return try unregisterApp(string(params, "path"), force: true)
        case .appsUnregisterDir:
            return try unregisterAppsInDirectory(string(params, "directory"), force: true)
        case .appsNetworkPolicy:
            return try appNetworkPolicy(string(params, "bundle_id"), repair: bool(params, "repair"))
        case .systemUicache:
            return try refreshAppRegistrations(directory: optionalString(params, "directory"))
        case .systemSystemApps:
            return try systemAppsVisibility(set: params["visible"] as? Bool)
        case .systemRespring:
            return try respring()
        case .systemReboot:
            let userspace = bool(params, "userspace")
            return try requestReboot(userspace: userspace, force: true)
        case .systemShutdown:
            return try requestShutdown()
        }
    }
}

// MARK: - App Registrations

extension GuestAPI {
    /// `uicache -a`. Without a directory, IcliKit looks for the bootstrap from
    /// the running executable, and vphoned runs from the system volume, so it
    /// finds none and refreshes the system's /Applications, where every app is
    /// Apple's and is skipped. The bootstrap vphoned installed names the
    /// directory instead.
    static func refreshAppRegistrations(directory: String?) throws -> [String: Any] {
        guard let directory = try directory ?? GuestIrisinInstaller.completedBootstrap().map({ $0.root + "/Applications" })
        else {
            throw GuestAPIError.operationFailed("No bootstrap environment was found")
        }
        do {
            return try refreshApps(directory: directory)
        } catch let IcliError.commandFailed(output) {
            // The output names the bundles; the error itself gives only a status.
            let names = { (key: String) in
                (output[key] as? [String] ?? []).map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")
            }
            var sentences: [String] = []
            if !names("failed").isEmpty {
                sentences.append("LaunchServices did not register or remove \(names("failed")).")
            }
            if !names("unverified").isEmpty {
                sentences.append("LaunchServices does not list \(names("unverified")) as expected after the refresh.")
            }
            throw GuestAPIError.operationFailed(sentences.joined(separator: " "))
        }
    }
}

// MARK: - Shutdown

extension GuestAPI {
    /// Asks launchd to shut the guest down. Success means launchd accepted the
    /// request; the guest then stops, which ends the virtual machine on the
    /// host, so the caller usually loses the connection before the reply.
    static func requestShutdown() throws -> [String: Any] {
        guard geteuid() == 0 else { throw GuestAPIError.operationFailed("shutdown requires root") }
        let status = vp_system_halt()
        guard status == 0 else {
            throw GuestAPIError.operationFailed("shutdown request rejected: \(String(cString: strerror(status)))")
        }
        return ["accepted": true, "completion": "the virtual machine stops"]
    }
}

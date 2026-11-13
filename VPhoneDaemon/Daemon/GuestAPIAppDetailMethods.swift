import Foundation

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
                                       .optional("build", .string),
                                       .required("bundle_id", .string),
                                       .required("bundle_path", .string),
                                       .optional("data_path", .string),
                                       .optional("encrypted", .boolean),
                                       .optional("entitlements", .object).open(),
                                       .optional("executable", .string),
                                       .optional("group_containers", .object).open(),
                                       .optional("minimum_os", .string),
                                       .required("name", .string),
                                       .optional("running", .boolean),
                                       .optional("schemes", .array),
                                       .optional("sdk", .string),
                                       .optional("signer", .string),
                                       .optional("signing_error", .string),
                                       .optional("type", .string),
                                       .optional("version", .string)])
        case .appsBinary: MethodSpec(.required("bundle_id", .string, "Bundle identifier of the app, such as com.apple.mobilesafari"),
                                     summary: "Return an app's executable path, encryption state and entitlements.", result: [
                                         .required("bundle_id", .string),
                                         .required("encrypted", .boolean),
                                         .required("entitlements", .object).open(),
                                         .required("executable", .string)])
        case .appsDataDir: MethodSpec(.required("bundle_id", .string, "Bundle identifier of the app, such as com.apple.mobilesafari"),
                                      summary: "Return the path of an app's data container.", result: [.required("bundle_id", .string), .required("data_path", .string)])
        case .appsUrlSchemes: MethodSpec(summary: "List every URL scheme registered on the guest with the apps that claim it.", result: [.required("schemes", .object).open()])
        case .appsHandlers: MethodSpec(.required("url", .string, "URL whose scheme to look up, such as https://example.com"),
                                       summary: "List the apps that can open a URL, based on its scheme.", result: [
                                           .optional("apps", .array),
                                           .optional("count", .integer),
                                           .hidden("error", .string),
                                           .optional("scheme", .string),
                                           .optional("url", .string)])
        case .appsRegistration: MethodSpec(.required("path", .string, "Absolute guest path of the app bundle directory"),
                                           summary: "Report whether an app bundle path is registered with LaunchServices, with its metadata.", result: [
                                               .optional("build", .string),
                                               .optional("bundle_id", .string),
                                               .optional("bundle_path", .string),
                                               .optional("data_path", .string),
                                               .hidden("error", .string),
                                               .optional("group_containers", .object).open(),
                                               .optional("name", .string),
                                               .optional("path", .string),
                                               .optional("plugins", .array),
                                               .optional("registered", .boolean),
                                               .optional("running", .boolean),
                                               .optional("schemes", .array),
                                               .optional("signer", .string),
                                               .optional("type", .string),
                                               .optional("version", .string)])
        case .appsRegister: MethodSpec(.required("path", .string, "Absolute guest path of the app bundle directory"),
                                       summary: "Register an app bundle with LaunchServices so it appears on the home screen.", result: [
                                           .optional("build", .string),
                                           .optional("bundle_id", .string),
                                           .optional("bundle_path", .string),
                                           .optional("data_path", .string),
                                           .hidden("error", .string),
                                           .optional("group_containers", .object).open(),
                                           .optional("name", .string),
                                           .required("path", .string),
                                           .optional("plugins", .array),
                                           .optional("registered", .boolean),
                                           .optional("running", .boolean),
                                           .optional("schemes", .array),
                                           .optional("signer", .string),
                                           .optional("type", .string),
                                           .optional("version", .string)])
        case .appsUnregister:
            MethodSpec(.required("path", .string, "Absolute guest path of the app bundle directory"),
                       summary: "Remove an app bundle's registration from LaunchServices without deleting the files.",
                       force: .always("unregister `<path>`") { p in try "unregister \(GuestAPI.string(p, "path"))" }, result: [
                           .optional("bundle_id", .string),
                           .optional("message", .string),
                           .required("path", .string),
                           .required("unregistered", .boolean)])
        case .appsUnregisterDir:
            MethodSpec(.required("directory", .string, "Absolute guest path of a directory containing app bundles"),
                       summary: "Unregister every app bundle found in a directory from LaunchServices.",
                       force: .always("unregister every app in `<directory>`") { p in try "unregister every app in \(GuestAPI.string(p, "directory"))" }, result: [
                           .optional("directory", .string),
                           .optional("error", .string),
                           .optional("failed", .array),
                           .optional("unregistered", .array),
                           .optional("unverified", .array)])
        case .appsNetworkPolicy: MethodSpec(.required("bundle_id", .string, "Bundle identifier of the app, such as com.apple.mobilesafari"),
                                            .optional("repair", .boolean, "Set the app's cellular and Wi-Fi data policy to always allow when it is not already", default: false),
                                            summary: "Read an app's cellular and Wi-Fi data usage policy and optionally set both to always allow.", result: [
                                                .optional("allowed", .boolean),
                                                .optional("bundle_id", .string),
                                                .optional("changed", .boolean),
                                                .hidden("error", .string),
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
                                                    .hidden("error", .string),
                                                    .optional("requires_respring", .boolean),
                                                    .required("visible", .boolean)])
        case .systemRespring: MethodSpec(summary: "Restart SpringBoard, the home screen process, without rebooting the guest.", force: .always("restart SpringBoard"), result: [.required("method", .string),
                                                  .required("pid", .integer),
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

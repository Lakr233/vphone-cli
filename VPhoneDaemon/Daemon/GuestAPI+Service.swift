import Foundation
import IcliKit
import IcliSystem

enum ServiceMethod: String, GuestMethod {
    case servicesList = "services.list"
    case servicesStatus = "services.status"
    case servicesPrint = "services.print"
    case servicesDump = "services.dump"
    case servicesDisabled = "services.disabled"
    case servicesProfile = "services.profile"
    case servicesProfileApply = "services.profile.apply"
    case servicesStart = "services.start"
    case servicesKickstart = "services.kickstart"
    case servicesEnable = "services.enable"
    case servicesStop = "services.stop"
    case servicesDisable = "services.disable"
    case servicesRemove = "services.remove"
    case servicesSignal = "services.signal"
    case servicesLoad = "services.load"
    case servicesUnload = "services.unload"
    case launchdGetenv = "launchd.getenv"
    case launchdSetenv = "launchd.setenv"
    case launchdUnsetenv = "launchd.unsetenv"

    var spec: MethodSpec {
        switch self {
        case .servicesList: MethodSpec(summary: "List launchd services with their pids and disabled flags", result: [.required("count", .integer), .required("services", .any)])
        case .servicesStatus: MethodSpec(.required("label", .string, "Launchd service label, such as com.apple.mobilekeybagd"), summary: "Report whether one launchd service is loaded, enabled and running, with its pid and exit status", result: [.required("domains", .array), .required("enabled", .boolean), .required("label", .string), .required("loaded", .boolean), .required("override", .boolean), .required("running", .boolean),
                                                  .optional("last_exit_status", .any), .optional("pid", .integer), .optional("program", .any)])
        case .servicesPrint: MethodSpec(.required("label", .string, "Launchd service label, such as com.apple.mobilekeybagd"), summary: "Return launchd's description text of one service, like launchctl print", result: [.required("description", .string), .required("domain", .string), .required("label", .string)])
        case .servicesDump: MethodSpec(summary: "Describe every launchd service in one call, with per-service errors collected separately", result: [.required("count", .integer), .required("described", .integer), .required("errors", .object).open(), .required("services", .array)])
        case .servicesDisabled: MethodSpec(summary: "List the launchd disabled-override map (label to disabled flag)", result: [.required("count", .integer), .required("disabled", .object).open()])
        case .servicesProfile: MethodSpec(summary: "Report the service profile state: supported iOS versions, groups, what is disabled and whether reboot is needed", result: [.required("disabled", .any), .required("enabled_since", .any), .required("groups", .any), .required("ios_major", .integer), .required("list_version", .integer), .required("never_disable", .array), .required("profile", .string), .required("reboot_required", .boolean), .required("record", .any), .required("running", .any), .required("supported", .boolean), .required("supported_ios", .array)])
        case .servicesProfileApply:
            MethodSpec(.required("profile", .string, "Profile name", values: ["none", "trimmed"]), .optional("groups", .array, "Names of non-default service groups to add to the profile; unknown names are refused"), .optional("allow", .array, "Service labels to keep enabled despite the profile"),
                       summary: "Disable the launchd services a profile selects and re-enable ones it owned earlier; idempotent", force: .always("apply a service profile"), result: [.required("allowed", .array), .required("disabled", .array), .required("enabled", .array), .required("failed", .array), .required("groups", .array), .required("ios_major", .integer), .required("kept", .array), .required("list_version", .integer), .required("owned", .integer), .required("profile", .string), .required("reboot_required", .boolean), .required("skipped", .any)])
        case .servicesStart: MethodSpec(.required("label", .string, "Launchd service label, such as com.apple.mobilekeybagd"), summary: "Start a launchd service by label", result: [.required("accepted", .boolean), .required("action", .string), .optional("domain", .string), .required("label", .string), .required("launchd_status", .integer), .required("message", .string), .optional("pid", .integer), .required("unchanged", .boolean)])
        case .servicesKickstart:
            MethodSpec(.required("label", .string, "Launchd service label, such as com.apple.mobilekeybagd"),
                       .optional("kill", .boolean, "Kill the running instance before restarting", default: false),
                       summary: "Kickstart a launchd service, optionally killing a running instance first", force: .when("kill", "kill and restart <label>") { p in try "kill and restart \(GuestAPI.string(p, "label"))" }, result: [.required("accepted", .boolean), .required("action", .string), .optional("domain", .string), .required("kill", .boolean), .required("label", .string), .required("launchd_status", .integer), .required("message", .string), .optional("pid", .integer), .required("unchanged", .boolean)])
        case .servicesEnable: MethodSpec(.required("label", .string, "Launchd service label, such as com.apple.mobilekeybagd"), summary: "Clear the launchd disabled override so a service may run", result: [.required("changed", .boolean), .required("enabled", .boolean), .required("label", .string)])
        case .servicesStop:
            MethodSpec(.required("label", .string, "Launchd service label, such as com.apple.mobilekeybagd"), summary: "Stop a running launchd service", force: .always("stop <label>") { p in try "stop \(GuestAPI.string(p, "label"))" }, result: [.required("accepted", .boolean), .required("action", .string), .optional("domain", .string), .required("label", .string), .required("launchd_status", .integer), .required("message", .string), .optional("pid", .integer), .required("unchanged", .boolean)])
        case .servicesDisable:
            MethodSpec(.required("label", .string, "Launchd service label, such as com.apple.mobilekeybagd"), summary: "Set the launchd disabled override so a service will not run", force: .always("disable <label>") { p in try "disable \(GuestAPI.string(p, "label"))" }, result: [.required("changed", .boolean), .required("enabled", .boolean), .required("label", .string)])
        case .servicesRemove:
            MethodSpec(.required("label", .string, "Launchd service label, such as com.apple.mobilekeybagd"), summary: "Remove a launchd service from its domain", force: .always("remove <label>") { p in try "remove \(GuestAPI.string(p, "label"))" }, result: [.required("accepted", .boolean), .required("action", .string), .optional("domain", .string), .required("label", .string), .required("launchd_status", .integer), .required("message", .string), .optional("pid", .integer), .required("unchanged", .boolean)])
        case .servicesSignal:
            MethodSpec(.required("label", .string, "Launchd service label, such as com.apple.mobilekeybagd"),
                       .required("signal", .string, "Signal name such as TERM or HUP, with or without SIG, or a number from 1 to 31"),
                       summary: "Send a signal to a launchd service process", force: .always("send <signal> to <label>") { p in
                           let label = try GuestAPI.string(p, "label")
                           let signal = try GuestAPI.string(p, "signal")
                           return "send \(signal) to \(label)"
                       }, result: [.required("accepted", .boolean), .required("action", .string), .optional("domain", .string), .required("label", .string), .required("launchd_status", .integer), .required("message", .string), .optional("pid", .integer), .required("signal", .integer), .required("unchanged", .boolean)])
        case .servicesLoad: MethodSpec(.required("paths", .array, "Plist files or directories to load"), .optional("override", .boolean, "Also clear the disabled override for the loaded services", default: false), summary: "Load launchd service plists from files or directories and verify they loaded", result: [.required("errors", .object).open(), .required("loaded", .boolean), .optional("patched", .array), .required("paths", .array), .required("services", .array), .optional("unchanged", .boolean), .required("verified", .boolean)])
        case .servicesUnload:
            MethodSpec(.required("paths", .array, "Plist files or directories to unload"),
                       .optional("override", .boolean, "Also set the disabled override for the unloaded services", default: false),
                       summary: "Unload launchd service plists from files or directories and verify they unloaded", force: .always("unload services") { p in
                           _ = try GuestAPI.servicePaths(p)
                           return "unload services"
                       }, result: [.required("errors", .object).open(), .required("loaded", .boolean), .optional("patched", .array), .required("paths", .array), .required("services", .array), .optional("unchanged", .boolean), .required("verified", .boolean)])
        case .launchdGetenv: MethodSpec(.required("key", .string, "Variable name; must be non-empty and contain no ="), summary: "Read one launchd environment variable", result: [.required("exists", .boolean), .required("key", .string), .optional("value", .string)])
        case .launchdSetenv: MethodSpec(.required("key", .string, "Variable name; must be non-empty and contain no ="), .required("value", .string, "Variable value"), summary: "Set one launchd environment variable and verify it", result: [.required("exists", .boolean), .required("key", .string), .required("value", .any), .required("verified", .boolean)])
        case .launchdUnsetenv: MethodSpec(.required("key", .string, "Variable name; must be non-empty and contain no ="), summary: "Remove one launchd environment variable and verify it", result: [.required("exists", .boolean), .required("key", .string), .required("value", .any), .required("verified", .boolean)])
        }
    }
}

// MARK: - launchd Services

extension GuestAPI {
    static func executeService(_ m: ServiceMethod, _ params: [String: Any]) throws -> [String: Any] {
        switch m {
        case .servicesList:
            var result = try listServices()
            if let disabled = try? disabledServiceOverrides()["disabled"] as? [String: Bool] {
                let rows = result["services"] as? [[String: Any]] ?? []
                result["services"] = rows.map { row -> [String: Any] in
                    var service = row
                    if let label = row["label"] as? String, let isDisabled = disabled[label] {
                        service["disabled"] = isDisabled
                    }
                    return service
                }
            }
            return result
        case .servicesStatus:
            return try serviceStatus(string(params, "label"))
        case .servicesPrint:
            return try printService(string(params, "label"))
        case .servicesDump:
            return try servicesDump()
        case .servicesDisabled:
            return try disabledServiceOverrides()
        case .servicesProfile:
            return try serviceProfileState()
        case .servicesProfileApply:
            return try applyServiceProfile(params)
        case .servicesStart:
            return try startService(string(params, "label"))
        case .servicesKickstart:
            let label = try string(params, "label")
            return try kickstartService(label, kill: bool(params, "kill"))
        case .servicesEnable:
            return try setServiceEnabled(string(params, "label"), enabled: true)
        case .servicesStop:
            let label = try string(params, "label")
            return try stopService(label)
        case .servicesDisable:
            let label = try string(params, "label")
            return try setServiceEnabled(label, enabled: false)
        case .servicesRemove:
            let label = try string(params, "label")
            return try removeService(label)
        case .servicesSignal:
            let label = try string(params, "label")
            let signal = try string(params, "signal")
            return try signalService(label, signal: signal)
        case .servicesLoad, .servicesUnload:
            let paths = try servicePaths(params)
            let load = m == .servicesLoad
            if load {
                try GuestIrisinInstaller.prepareBootstrapDaemons(paths)
            }
            return try loadServices(paths, load: load, override: bool(params, "override"))
        case .launchdGetenv:
            return try launchdEnvironment(string(params, "key"))
        case .launchdSetenv:
            return try setLaunchdEnvironment(string(params, "key"), value: string(params, "value"))
        case .launchdUnsetenv:
            return try setLaunchdEnvironment(string(params, "key"), value: nil)
        }
    }

    fileprivate static func servicePaths(_ params: [String: Any]) throws -> [String] {
        guard let paths = params["paths"] as? [String], !paths.isEmpty else {
            throw GuestAPIError.invalidRequest("paths must list plist files or directories")
        }
        return paths
    }
}

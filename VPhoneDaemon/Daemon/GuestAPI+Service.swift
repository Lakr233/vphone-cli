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
        case .servicesList: MethodSpec()
        case .servicesStatus: MethodSpec(.required("label", .string))
        case .servicesPrint: MethodSpec(.required("label", .string))
        case .servicesDump: MethodSpec()
        case .servicesDisabled: MethodSpec()
        case .servicesProfile: MethodSpec()
        case .servicesProfileApply:
            MethodSpec(.required("profile", .string), .optional("groups", .array), .optional("allow", .array),
                       force: .always { _ in "apply a service profile" })
        case .servicesStart: MethodSpec(.required("label", .string))
        case .servicesKickstart:
            MethodSpec(.required("label", .string),
                       .optional("kill", .boolean),
                       force: .when("kill") { p in try "kill and restart \(GuestAPI.string(p, "label"))" })
        case .servicesEnable: MethodSpec(.required("label", .string))
        case .servicesStop:
            MethodSpec(.required("label", .string), force: .always { p in try "stop \(GuestAPI.string(p, "label"))" })
        case .servicesDisable:
            MethodSpec(.required("label", .string), force: .always { p in try "disable \(GuestAPI.string(p, "label"))" })
        case .servicesRemove:
            MethodSpec(.required("label", .string), force: .always { p in try "remove \(GuestAPI.string(p, "label"))" })
        case .servicesSignal:
            MethodSpec(.required("label", .string),
                       .required("signal", .string),
                       force: .always { p in
                           let label = try GuestAPI.string(p, "label")
                           let signal = try GuestAPI.string(p, "signal")
                           return "send \(signal) to \(label)"
                       })
        case .servicesLoad: MethodSpec(.required("paths", .array), .optional("override", .boolean))
        case .servicesUnload:
            MethodSpec(.required("paths", .array),
                       .optional("override", .boolean),
                       force: .always { p in
                           _ = try GuestAPI.servicePaths(p)
                           return "unload services"
                       })
        case .launchdGetenv: MethodSpec(.required("key", .string))
        case .launchdSetenv: MethodSpec(.required("key", .string), .required("value", .string))
        case .launchdUnsetenv: MethodSpec(.required("key", .string))
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

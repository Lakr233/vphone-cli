import Foundation
import IcliKit
import IcliSystem

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

    static func servicePaths(_ params: [String: Any]) throws -> [String] {
        guard let paths = params["paths"] as? [String], !paths.isEmpty else {
            throw GuestAPIError.invalidRequest("paths must list plist files or directories")
        }
        return paths
    }
}

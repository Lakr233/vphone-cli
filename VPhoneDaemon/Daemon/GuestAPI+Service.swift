import Foundation
import IcliKit
import IcliSystem

// MARK: - launchd Services

extension GuestAPI {
    static func executeService(_ method: String, _ params: [String: Any]) throws -> [String: Any]? {
        switch method {
        case "services.list":
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
        case "services.status":
            return try serviceStatus(string(params, "label"))
        case "services.print":
            return try printService(string(params, "label"))
        case "services.dump":
            return try servicesDump()
        case "services.disabled":
            return try disabledServiceOverrides()
        case "services.start":
            return try startService(string(params, "label"))
        case "services.enable":
            return try setServiceEnabled(string(params, "label"), enabled: true)
        case "services.stop":
            let label = try string(params, "label")
            try requireForce(params, "stop \(label)")
            return try stopService(label)
        case "services.disable":
            let label = try string(params, "label")
            try requireForce(params, "disable \(label)")
            return try setServiceEnabled(label, enabled: false)
        case "services.remove":
            let label = try string(params, "label")
            try requireForce(params, "remove \(label)")
            return try removeService(label)
        case "services.signal":
            let label = try string(params, "label")
            let signal = try string(params, "signal")
            try requireForce(params, "send \(signal) to \(label)")
            return try signalService(label, signal: signal)
        case "services.load", "services.unload":
            guard let paths = params["paths"] as? [String], !paths.isEmpty else {
                throw GuestAPIError.invalidRequest("paths must list plist files or directories")
            }
            let load = method == "services.load"
            if !load {
                try requireForce(params, "unload services")
            }
            return try loadServices(paths, load: load, override: bool(params, "override"))
        case "launchd.getenv":
            return try launchdEnvironment(string(params, "key"))
        case "launchd.setenv":
            return try setLaunchdEnvironment(string(params, "key"), value: string(params, "value"))
        case "launchd.unsetenv":
            return try setLaunchdEnvironment(string(params, "key"), value: nil)
        default:
            return nil
        }
    }
}

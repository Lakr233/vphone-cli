import Foundation
import IcliKit

// MARK: - App Detail and System Control

extension GuestAPI {
    static func executeAppDetail(_ method: String, _ params: [String: Any]) throws -> [String: Any]? {
        switch method {
        case "apps.info":
            return try appInfo(string(params, "bundle_id"))
        case "apps.binary":
            return try appBinaryInfo(string(params, "bundle_id"))
        case "apps.data_dir":
            return try appDataDir(string(params, "bundle_id"))
        case "apps.url_schemes":
            return try appURLSchemes()
        case "apps.handlers":
            return try appHandlers(string(params, "url"))
        case "apps.registration":
            return try appRegistration(string(params, "path"))
        case "apps.register":
            return try registerApp(string(params, "path"))
        case "apps.unregister":
            let path = try string(params, "path")
            try requireForce(params, "unregister \(path)")
            return try unregisterApp(path, force: true)
        case "apps.unregister_dir":
            let directory = try string(params, "directory")
            try requireForce(params, "unregister every app in \(directory)")
            return try unregisterAppsInDirectory(directory, force: true)
        case "apps.network_policy":
            return try appNetworkPolicy(string(params, "bundle_id"), repair: bool(params, "repair"))
        case "system.uicache":
            return try refreshApps(directory: optionalString(params, "directory"))
        case "system.system_apps":
            return try systemAppsVisibility(set: params["visible"] as? Bool)
        case "system.respring":
            try requireForce(params, "restart SpringBoard")
            return try respring()
        case "system.reboot":
            let userspace = bool(params, "userspace")
            try requireForce(params, userspace ? "restart userspace" : "reboot the guest")
            return try requestReboot(userspace: userspace, force: true)
        default:
            return nil
        }
    }
}

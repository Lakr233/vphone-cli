import Foundation
import IcliKit
import IcliSystem

// MARK: - Files, Keychain, Packages

extension GuestAPI {
    static func executeFileTool(_ method: String, _ params: [String: Any]) throws -> [String: Any]? {
        switch method {
        case "files.read":
            return try readFile(
                string(params, "path"),
                binary: bool(params, "binary"),
                limit: (params["limit"] as? NSNumber)?.intValue,
            )
        case "files.write":
            guard let content = params["content"] as? String else {
                throw GuestAPIError.invalidRequest("content is required")
            }
            return try writeFile(
                string(params, "path"),
                content: content,
                encoding: optionalString(params, "encoding") ?? "utf8",
            )
        case "files.find":
            return try findFiles(root: string(params, "root"), pattern: string(params, "pattern"))
        case "files.copy":
            return try copyPath(string(params, "from"), to: string(params, "to"))
        case "files.symlink":
            return try createSymlink(
                target: string(params, "target"),
                link: string(params, "link"),
                replace: bool(params, "replace"),
            )
        case "files.chmod":
            return try changeMode(string(params, "path"), mode: string(params, "mode"))
        case "files.chown":
            return try changeOwner(string(params, "path"), owner: string(params, "owner"))
        case "files.plist":
            return try readPlist(string(params, "path"))
        case "files.plist_set":
            let json: String? =
                if bool(params, "remove") {
                    nil
                } else if let value = params["value"] {
                    try String(
                        decoding: JSONSerialization.data(withJSONObject: value, options: .fragmentsAllowed),
                        as: UTF8.self,
                    )
                } else {
                    throw GuestAPIError.invalidRequest("value is required unless remove is true")
                }
            return try setPlistValue(string(params, "path"), key: string(params, "key"), json: json)
        case "keychain.get":
            return try getKeychain(
                className: optionalString(params, "class") ?? "genp",
                service: optionalString(params, "service"),
                account: optionalString(params, "account"),
                server: optionalString(params, "server"),
                group: optionalString(params, "group"),
            )
        case "keychain.update":
            return try updateKeychain(
                className: optionalString(params, "class") ?? "genp",
                service: optionalString(params, "service"),
                account: string(params, "account"),
                server: optionalString(params, "server"),
                group: optionalString(params, "group"),
                data: string(params, "data"),
            )
        case "keychain.database":
            return try listKeychainDatabaseMetadata(className: optionalString(params, "class"))
        case "packages.list":
            return try listPackages(filter: optionalString(params, "filter"))
        case "packages.status":
            return try packageStatus(string(params, "name"))
        case "packages.info":
            return try readDeb(string(params, "path"))
        case "packages.compare":
            return try compareDebianVersions(string(params, "left"), string(params, "right"))
        case "packages.tweaks":
            return try listTweaks()
        case "packages.repos":
            return try listRepos()
        default:
            return nil
        }
    }
}

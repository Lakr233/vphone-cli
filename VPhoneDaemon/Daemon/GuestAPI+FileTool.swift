import Foundation
import IcliKit
import IcliSystem

// MARK: - Files, Keychain, Packages

enum FileToolMethod: String, GuestMethod {
    case filesRead = "files.read"
    case filesWrite = "files.write"
    case filesFind = "files.find"
    case filesCopy = "files.copy"
    case filesSymlink = "files.symlink"
    case filesChmod = "files.chmod"
    case filesChown = "files.chown"
    case filesSaveToFilesApp = "files.save_to_files_app"
    case filesPlist = "files.plist"
    case filesPlistSet = "files.plist_set"
    case keychainDatabase = "keychain.database"
    case packagesList = "packages.list"
    case packagesStatus = "packages.status"
    case packagesInfo = "packages.info"
    case packagesCompare = "packages.compare"
    case packagesTweaks = "packages.tweaks"
    case packagesRepos = "packages.repos"

    var spec: MethodSpec {
        switch self {
        case .filesRead: MethodSpec(.required("path", .string), .optional("binary", .boolean), .optional("limit", .integer))
        case .filesWrite: MethodSpec(.required("path", .string), .required("content", .string), .optional("encoding", .string))
        case .filesFind: MethodSpec(.required("root", .string), .required("pattern", .string))
        case .filesCopy: MethodSpec(.required("from", .string), .required("to", .string))
        case .filesSymlink: MethodSpec(.required("target", .string), .required("link", .string), .optional("replace", .boolean))
        case .filesChmod: MethodSpec(.required("path", .string), .required("mode", .string))
        case .filesChown: MethodSpec(.required("path", .string), .required("owner", .string))
        case .filesSaveToFilesApp: MethodSpec(.required("path", .string), .required("name", .string))
        case .filesPlist: MethodSpec(.required("path", .string))
        case .filesPlistSet: MethodSpec(.required("path", .string), .required("key", .string), .optional("value", .any),
                       .optional("remove", .boolean))
        case .keychainDatabase: MethodSpec(.optional("class", .string))
        case .packagesList: MethodSpec(.optional("filter", .string))
        case .packagesStatus: MethodSpec(.required("name", .string))
        case .packagesInfo: MethodSpec(.required("path", .string))
        case .packagesCompare: MethodSpec(.required("left", .string), .required("right", .string))
        case .packagesTweaks: MethodSpec()
        case .packagesRepos: MethodSpec()
        }
    }
}

extension GuestAPI {
    static func executeFileTool(_ m: FileToolMethod, _ params: [String: Any]) throws -> [String: Any] {
        switch m {
        case .filesRead:
            return try readFile(
                string(params, "path"),
                binary: bool(params, "binary"),
                limit: (params["limit"] as? NSNumber)?.intValue,
            )
        case .filesWrite:
            guard let content = params["content"] as? String else {
                throw GuestAPIError.invalidRequest("content is required")
            }
            return try writeFile(
                string(params, "path"),
                content: content,
                encoding: optionalString(params, "encoding") ?? "utf8",
            )
        case .filesFind:
            return try findFiles(root: string(params, "root"), pattern: string(params, "pattern"))
        case .filesCopy:
            return try copyPath(string(params, "from"), to: string(params, "to"))
        case .filesSymlink:
            return try createSymlink(
                target: string(params, "target"),
                link: string(params, "link"),
                replace: bool(params, "replace"),
            )
        case .filesChmod:
            return try changeMode(string(params, "path"), mode: string(params, "mode"))
        case .filesChown:
            return try changeOwner(string(params, "path"), owner: string(params, "owner"))
        case .filesSaveToFilesApp:
            return try saveToFilesApp(string(params, "path"), name: string(params, "name"))
        case .filesPlist:
            return try readPlist(string(params, "path"))
        case .filesPlistSet:
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
        case .keychainDatabase:
            return try listKeychainDatabaseMetadata(className: optionalString(params, "class"))
        case .packagesList:
            return try listPackages(filter: optionalString(params, "filter"))
        case .packagesStatus:
            return try packageStatus(string(params, "name"))
        case .packagesInfo:
            return try readDeb(string(params, "path"))
        case .packagesCompare:
            return try compareDebianVersions(string(params, "left"), string(params, "right"))
        case .packagesTweaks:
            return try listTweaks()
        case .packagesRepos:
            return try listRepos()
        }
    }
}

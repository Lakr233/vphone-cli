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
        case .filesRead: MethodSpec(.required("path", .string), .optional("binary", .boolean), .optional("limit", .integer), result: [
                                        .required("content", .string),
                                        .required("encoding", .string),
                                        .required("path", .string),
                                        .required("size", .any),
                                        .required("truncated", .boolean)])
        case .filesWrite: MethodSpec(.required("path", .string), .required("content", .string), .optional("encoding", .string), result: [.required("bytes", .integer), .required("path", .string)])
        case .filesFind: MethodSpec(.required("root", .string), .required("pattern", .string), result: [
                                        .required("matches", .array),
                                        .required("pattern", .string),
                                        .required("root", .string)])
        case .filesCopy: MethodSpec(.required("from", .string), .required("to", .string), result: [.required("destination", .string), .required("source", .string)])
        case .filesSymlink: MethodSpec(.required("target", .string), .required("link", .string), .optional("replace", .boolean), result: [
                                           .required("link", .string),
                                           .required("resolved", .any),
                                           .required("target", .string)])
        case .filesChmod: MethodSpec(.required("path", .string), .required("mode", .string), result: [.required("mode", .string), .required("path", .string)])
        case .filesChown: MethodSpec(.required("path", .string), .required("owner", .string), result: [.required("gid", .integer), .required("path", .string), .required("uid", .integer)])
        case .filesSaveToFilesApp: MethodSpec(.required("path", .string), .required("name", .string), result: [
                                                  .required("folder", .string),
                                                  .required("name", .string),
                                                  .required("path", .string)])
        case .filesPlist: MethodSpec(.required("path", .string), result: [.required("path", .string), .required("plist", .any).open()])
        case .filesPlistSet: MethodSpec(.required("path", .string), .required("key", .string), .optional("value", .any),
                       .optional("remove", .boolean), result: [
                                            .required("format", .string),
                                            .required("key", .string),
                                            .required("path", .string),
                                            .required("previous", .any).open(),
                                            .required("value", .any).open()])
        case .keychainDatabase: MethodSpec(.optional("class", .string), result: [
                                               .required("count", .integer),
                                               .required("counts", .object),
                                               .required("items", .array),
                                               .required("source", .string)])
        case .packagesList: MethodSpec(.optional("filter", .string), result: [.required("count", .integer), .required("packages", .array)])
        case .packagesStatus: MethodSpec(.required("name", .string), result: [
                                             .optional("architecture", .any),
                                             .optional("fields", .object),
                                             .optional("files", .array),
                                             .required("installed", .boolean),
                                             .required("known", .boolean),
                                             .required("package", .string),
                                             .optional("status", .any),
                                             .optional("version", .any)])
        case .packagesInfo: MethodSpec(.required("path", .string), result: [
                                           .optional("control", .object).open(),
                                           .optional("control_files", .array),
                                           .optional("control_member", .string),
                                           .optional("control_order", .array),
                                           .hidden("control_texts", .object),
                                           .optional("data_member", .string),
                                           .optional("destination", .string),
                                           .optional("error", .string),
                                           .optional("extracted", .boolean),
                                           .optional("files", .array),
                                           .optional("format", .string),
                                           .optional("scripts", .any)])
        case .packagesCompare: MethodSpec(.required("left", .string), .required("right", .string), result: [
                                              .required("comparison", .integer),
                                              .required("left", .string),
                                              .required("relation", .string),
                                              .required("right", .string)])
        case .packagesTweaks: MethodSpec(result: [.required("tweaks", .array)])
        case .packagesRepos: MethodSpec(result: [.required("repos", .array)])
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

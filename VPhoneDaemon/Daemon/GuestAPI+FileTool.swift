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
        case .filesRead: MethodSpec(.required("path", .string, "Absolute guest file path"), .optional("binary", .boolean, "Force base64; non-UTF-8 or binary content is returned as base64 regardless", default: false), .optional("limit", .integer, "Maximum bytes to return; 512 KiB when omitted", default: 524288, min: 0, max: 67108864), summary: "Read a guest file as UTF-8 text or base64, up to a byte limit, with a truncated flag", result: [
                                        .required("content", .string),
                                        .required("encoding", .string),
                                        .required("path", .string),
                                        .required("size", .any),
                                        .required("truncated", .boolean)])
        case .filesWrite: MethodSpec(.required("path", .string, "Absolute guest file path"), .required("content", .string, "File content, encoded per encoding"), .optional("encoding", .string, "How content is encoded; the file gets the decoded bytes", values: ["utf8", "base64"], default: "utf8"), summary: "Write content to a guest file atomically, creating parent directories and replacing any existing file", result: [.required("bytes", .integer), .required("path", .string)])
        case .filesFind: MethodSpec(.required("root", .string, "Absolute directory to search"), .required("pattern", .string, "Text to look for, ignoring case, anywhere in the path relative to root; not a glob"), summary: "Find paths under a root directory containing a text, ignoring case; returns at most 500 matches", result: [
                                        .required("matches", .array),
                                        .required("pattern", .string),
                                        .required("root", .string)])
        case .filesCopy: MethodSpec(.required("from", .string, "Absolute source path"), .required("to", .string, "Absolute destination path; must not exist"), summary: "Copy a guest file or directory to a new path; fails if the destination exists", result: [.required("destination", .string), .required("source", .string)])
        case .filesSymlink: MethodSpec(.required("target", .string, "Path the link points to"), .required("link", .string, "Absolute path of the link to create"), .optional("replace", .boolean, "Replace an existing symbolic link at that path; other existing files are never replaced", default: false), summary: "Create a symbolic link on the guest", result: [
                                           .required("link", .string),
                                           .required("resolved", .any),
                                           .required("target", .string)])
        case .filesChmod: MethodSpec(.required("path", .string, "Absolute guest path"), .required("mode", .string, "Octal mode string such as 755 or 0755, from 0 to 7777"), summary: "Change permission mode of a guest file or directory", result: [.required("mode", .string), .required("path", .string)])
        case .filesChown: MethodSpec(.required("path", .string, "Absolute guest path"), .required("owner", .string, "New owner as uid:gid or user:group; both parts required, names or numbers"), summary: "Change owner and group of a guest file or directory; a symlink itself is changed, not its target", result: [.required("gid", .integer), .required("path", .string), .required("uid", .integer)])
        case .filesSaveToFilesApp: MethodSpec(.required("path", .string, "Absolute guest source file path; the file is moved, not copied"), .required("name", .string, "File name in the Files app; a single name with no slash, numbered if already taken"), summary: "Move a guest file into the Files app On My iPhone vphone-drop folder so it shows in the Files UI", result: [
                                                  .required("folder", .string),
                                                  .required("name", .string),
                                                  .required("path", .string)])
        case .filesPlist: MethodSpec(.required("path", .string, "Absolute plist file path"), summary: "Read a guest plist file and return it as JSON", result: [.required("path", .string), .required("plist", .any).open()])
        case .filesPlistSet: MethodSpec(.required("path", .string, "Absolute plist file path"), .required("key", .string, "Top-level key to set or remove"), .optional("value", .any, "New JSON value; required unless remove is true"),
                       .optional("remove", .boolean, "Remove the key instead of setting it", default: false), summary: "Set or remove one top-level key in a guest plist file", result: [
                                            .required("format", .string),
                                            .required("key", .string),
                                            .required("path", .string),
                                            .required("previous", .any).open(),
                                            .required("value", .any).open()])
        case .keychainDatabase: MethodSpec(.optional("class", .string, "Restrict to one item class", values: ["genp", "inet", "cert", "keys", "generic_password", "internet_password", "certificate", "key", "generic", "internet"]), summary: "List keychain database item metadata only, without secret values, with per-class counts", result: [
                                               .required("count", .integer),
                                               .required("counts", .object),
                                               .required("items", .array),
                                               .required("source", .string)])
        case .packagesList: MethodSpec(.optional("filter", .string, "Text matched, ignoring case, against package ids and display names"), summary: "List installed dpkg packages, optionally filtered by name", result: [.required("count", .integer), .required("packages", .array)])
        case .packagesStatus: MethodSpec(.required("name", .string, "Package name"), summary: "Report install status and version of one dpkg package", result: [
                                             .optional("architecture", .any),
                                             .optional("fields", .object),
                                             .optional("files", .array),
                                             .required("installed", .boolean),
                                             .required("known", .boolean),
                                             .required("package", .string),
                                             .optional("status", .any),
                                             .optional("version", .any)])
        case .packagesInfo: MethodSpec(.required("path", .string, "Absolute path of the .deb file"), summary: "Read control metadata and file list from a .deb file on the guest", result: [
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
        case .packagesCompare: MethodSpec(.required("left", .string, "First version string"), .required("right", .string, "Second version string"), summary: "Compare two Debian version strings and return their ordering", result: [
                                              .required("comparison", .integer),
                                              .required("left", .string),
                                              .required("relation", .string),
                                              .required("right", .string)])
        case .packagesTweaks: MethodSpec(summary: "List installed tweaks (injected extensions) on the guest", result: [.required("tweaks", .array)])
        case .packagesRepos: MethodSpec(summary: "List configured package repositories on the guest", result: [.required("repos", .array)])
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

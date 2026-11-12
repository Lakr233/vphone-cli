import Foundation

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
        case .filesRead: MethodSpec(.required("path", .string, "Absolute guest file path"), .optional("binary", .boolean, "Force base64; non-UTF-8 or binary content is returned as base64 regardless", default: false), .optional("limit", .integer, "Maximum bytes to return; 512 KiB when omitted", default: 524288, min: 0, max: 67108864), .optional("offset", .integer, "Byte position to start reading at; past the end returns empty content", default: 0, min: 0, max: 1099511627776), summary: "Read a guest file as UTF-8 text or base64 from a byte offset up to a byte limit; next_offset continues where it ended", result: [
                                        .required("content", .string),
                                        .required("encoding", .string),
                                        .optional("next_offset", .integer),
                                        .required("path", .string),
                                        .required("size", .integer),
                                        .optional("total", .integer),
                                        .required("truncated", .boolean)])
        case .filesWrite: MethodSpec(.required("path", .string, "Absolute guest file path"), .required("content", .string, "File content, encoded per encoding"), .optional("encoding", .string, "How content is encoded; the file gets the decoded bytes", values: ["utf8", "base64"], default: "utf8"), summary: "Write content to a guest file atomically, creating parent directories and replacing any existing file", result: [.required("bytes", .integer), .required("path", .string)])
        case .filesFind: MethodSpec(.required("root", .string, "Absolute directory to search"), .required("pattern", .string, "Text to look for, ignoring case, anywhere in the path relative to root; not a glob"), summary: "Find paths under a root directory containing a text, ignoring case; returns at most 500 matches", result: [
                                        .required("matches", .array),
                                        .required("pattern", .string),
                                        .required("root", .string)], paged: MethodSpec.Paged(key: "matches", order: .strings))
        case .filesCopy: MethodSpec(.required("from", .string, "Absolute source path"), .required("to", .string, "Absolute destination path; must not exist"), summary: "Copy a guest file or directory to a new path; fails if the destination exists", result: [.required("destination", .string), .required("source", .string)])
        case .filesSymlink: MethodSpec(.required("target", .string, "Path the link points to"), .required("link", .string, "Absolute path of the link to create"), .optional("replace", .boolean, "Replace an existing symbolic link at that path; other existing files are never replaced", default: false), summary: "Create a symbolic link on the guest", result: [
                                           .required("link", .string),
                                           .required("resolved", .string),
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
                                            .required("previous", .any).open().nullable(),
                                            .required("value", .any).open().nullable()])
        case .keychainDatabase: MethodSpec(.optional("class", .string, "Restrict to one item class", values: ["genp", "inet", "cert", "keys", "generic_password", "internet_password", "certificate", "key", "generic", "internet"]), summary: "List keychain database item metadata only, without secret values, with per-class counts", result: [
                                               .required("count", .integer),
                                               .required("counts", .object),
                                               .required("items", .array),
                                               .required("source", .string)])
        case .packagesList: MethodSpec(.optional("filter", .string, "Text matched, ignoring case, against package ids and display names"), summary: "List installed dpkg packages, optionally filtered by name", result: [.required("count", .integer), .required("packages", .array)])
        case .packagesStatus: MethodSpec(.required("name", .string, "Package name"), summary: "Report install status and version of one dpkg package", result: [
                                             .optional("architecture", .string),
                                             .optional("fields", .object),
                                             .optional("files", .array),
                                             .required("installed", .boolean),
                                             .required("known", .boolean),
                                             .required("package", .string),
                                             .optional("status", .string),
                                             .optional("version", .string)])
        case .packagesInfo: MethodSpec(.required("path", .string, "Absolute path of the .deb file"), summary: "Read control metadata and file list from a .deb file on the guest", result: [
                                           .optional("control", .object).open(),
                                           .optional("control_files", .array),
                                           .optional("control_member", .string),
                                           .optional("control_order", .array),
                                           .hidden("control_texts", .object),
                                           .optional("data_member", .string),
                                           .optional("destination", .string),
                                           .hidden("error", .string),
                                           .optional("extracted", .boolean),
                                           .optional("files", .array),
                                           .optional("format", .string),
                                           .optional("scripts", .array)])
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

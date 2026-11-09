import Foundation
import IcliKit

// MARK: - Unified Log and Crash Reports

enum LogMethod: String, GuestMethod {
    case logsSyslog = "logs.syslog"
    case logsCrashes = "logs.crashes"
    case logsCrash = "logs.crash"

    var spec: MethodSpec {
        switch self {
        case .logsSyslog: MethodSpec(.optional("seconds", .number, "Length of the capture window in seconds", default: 2, min: 0.1, max: 60),
                                .optional("process", .string, "Keep only lines from this process name"),
                                .optional("level", .string, "Minimum severity to include; default and notice are the same level", values: ["all", "debug", "info", "default", "notice", "error", "fault"], default: "all"),
                                .optional("max_lines", .integer, "Cap on returned lines, applied after filters", default: 500, min: 1, max: 5000),
                                .optional("subsystem", .string, "Keep only lines from this log subsystem"),
                                .optional("category", .string, "Keep only lines from this log category"),
                                .optional("message_contains", .string, "Keep only lines whose message contains this text"),
                                summary: "Capture a bounded window of the guest unified log, filtered by process, level, subsystem or text.", result: [.optional("count", .any), .optional("entries", .array), .optional("error", .string), .optional("seconds", .number), .optional("source", .string), .optional("truncated", .boolean)])
        case .logsCrashes: MethodSpec(.optional("bundle_id", .string, "Keep only reports whose file name contains this bundle id or the app executable name, ignoring case"), summary: "List crash reports newest first with path, name, process name, size and modification time.", result: [.required("count", .integer), .required("crashes", .any)])
        case .logsCrash: MethodSpec(.required("path", .string, "Crash report path as returned by logs.crashes"), summary: "Read one crash report as UTF-8 text with its size; fails for non-text files.", result: [.required("bytes", .integer), .required("content", .string), .required("encoding", .string), .required("path", .string), .required("size", .integer), .required("truncated", .boolean)])
        }
    }
}

extension GuestAPI {
    static func executeLog(_ m: LogMethod, _ params: [String: Any]) throws -> [String: Any] {
        switch m {
        case .logsSyslog:
            return try captureSyslog(
                seconds: number(params, "seconds", default: 2),
                process: optionalString(params, "process"),
                level: optionalString(params, "level") ?? "all",
                maxLines: (params["max_lines"] as? NSNumber)?.intValue ?? 500,
                subsystem: optionalString(params, "subsystem"),
                category: optionalString(params, "category"),
                messageContains: optionalString(params, "message_contains"),
            )
        case .logsCrashes:
            let paths = try crashLogs(bundleID: optionalString(params, "bundle_id"))["crashes"] as? [String] ?? []
            let reports = paths.map { path -> [String: Any] in
                let name = (path as NSString).lastPathComponent
                let attributes = try? FileManager.default.attributesOfItem(atPath: path)
                return [
                    "path": path,
                    "name": name,
                    "process": crashProcessName(name),
                    "size": attributes?[.size] as? Int ?? 0,
                    "mtime": (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0,
                ]
            }
            return ["crashes": reports, "count": reports.count]
        case .logsCrash:
            return try readCrashLog(string(params, "path"))
        }
    }

    /// Crash report names start with the process name, then a date or a kind:
    /// `SpringBoard-2026-09-25-101500.ips`, `JetsamEvent-2026-….ips`.
    private static func crashProcessName(_ name: String) -> String {
        let stem = (name as NSString).deletingPathExtension
        if let range = stem.range(of: #"-\d{4}-\d{2}-\d{2}"#, options: .regularExpression) {
            return String(stem[..<range.lowerBound])
        }
        return stem.split(separator: "-").first.map(String.init) ?? stem
    }
}

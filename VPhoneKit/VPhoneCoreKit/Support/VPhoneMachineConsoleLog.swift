import CryptoKit
import Darwin
import Foundation

/// Console-log naming shared by Launchpad and the CLI's detached launch.
public enum VPhoneMachineConsoleLog {
    /// `VPHONE_LIBRARY_ROOT`, else `chosen`, else `~/.vphone/machines`, canonical.
    public static func defaultRoot(chosen: URL? = nil) -> String {
        let environment = ProcessInfo.processInfo.environment["VPHONE_LIBRARY_ROOT"]
            .flatMap { $0.isEmpty ? nil : $0 }
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
        return canonical(
            environment ?? chosen
                ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".vphone/machines", isDirectory: true),
        )
    }

    /// The resolved path of an existing folder, else the standardized path.
    public static func canonical(_ url: URL) -> String {
        let path = url.standardizedFileURL.path
        guard let resolved = realpath(path, nil) else {
            return path
        }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// Eight hex digits that tell libraries apart in log file names.
    public static func digest(_ root: String) -> String {
        SHA256.hash(data: Data(root.utf8)).prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    /// Machines in the default library keep their log names. Elsewhere the
    /// name gains a digest of the library. Pure path composition: no file
    /// access and no name validation.
    public static func url(libraryRoot: String, name: String, suffix: String = "", defaultRoot: String) -> URL {
        let stem = libraryRoot == defaultRoot ? name : "\(name)-\(digest(libraryRoot))"
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/vphone-launchpad", isDirectory: true)
            .appendingPathComponent("\(stem)\(suffix).log")
    }
}

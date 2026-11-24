import Foundation
import VPhoneCoreKit

/// Names a machine's console-log file the way both Launchpad and the CLI's
/// detached launch name it, so the two agree on one file per machine.
///
/// The "default library" for log naming is `VPHONE_LIBRARY_ROOT`, else
/// `~/.vphone/machines` — never the Host-Setup chosen library, which the CLI
/// cannot read. A machine in the default library keeps a plain `<name>.log`;
/// elsewhere the name gains a digest of its library root so two libraries'
/// like-named machines do not collide. `url` is pure path composition with no
/// file access; `migrateLegacy` is the only file access, and neither depends
/// on GUI-only state.
enum VPhoneLaunchpadConsoleLog {
    static func url(libraryRoot: String, name: String, suffix: String = "") -> URL {
        VPhoneMachineConsoleLog.url(
            libraryRoot: libraryRoot,
            name: name,
            suffix: suffix,
            defaultRoot: VPhoneMachineConsoleLog.defaultRoot(),
        )
    }

    /// Before the CLI's detached launch shared this naming, the default library
    /// also honoured Host Setup: a machine in that library kept a plain
    /// `<name>.log`, and one in the home library carried a digest. Moves a log
    /// named by that former rule to the current name the first time it is
    /// asked for, so an old log is not orphaned. `legacyDefaultRoot` is the
    /// former default (`VPHONE_LIBRARY_ROOT`, else Host Setup, else the home
    /// folder). Best effort: never overwrites a log that already has the
    /// current name, and a failed move leaves the old file where it was.
    static func migrateLegacy(libraryRoot: String, name: String, suffix: String = "", legacyDefaultRoot: String) {
        let current = url(libraryRoot: libraryRoot, name: name, suffix: suffix)
        let legacy = VPhoneMachineConsoleLog.url(
            libraryRoot: libraryRoot,
            name: name,
            suffix: suffix,
            defaultRoot: legacyDefaultRoot,
        )
        let files = FileManager.default
        guard files.fileExists(atPath: legacy.path), !files.fileExists(atPath: current.path) else {
            return
        }
        try? files.moveItem(at: legacy, to: current)
    }
}

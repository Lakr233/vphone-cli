import Foundation
import VPhoneCoreKit

/// Names a machine's console-log file the way both Launchpad and the CLI's
/// detached launch name it, so the two agree on one file per machine.
///
/// The "default library" for log naming is `VPHONE_LIBRARY_ROOT`, else
/// `~/.vphone/machines` — never the Host-Setup chosen library, which the CLI
/// cannot read. A machine in the default library keeps a plain `<name>.log`;
/// elsewhere the name gains a digest of its library root so two libraries'
/// like-named machines do not collide. Pure path composition: no file access
/// and no dependency on GUI-only state.
enum VPhoneLaunchpadConsoleLog {
    static func url(libraryRoot: String, name: String, suffix: String = "") -> URL {
        VPhoneMachineConsoleLog.url(
            libraryRoot: libraryRoot,
            name: name,
            suffix: suffix,
            defaultRoot: VPhoneMachineConsoleLog.defaultRoot(),
        )
    }
}

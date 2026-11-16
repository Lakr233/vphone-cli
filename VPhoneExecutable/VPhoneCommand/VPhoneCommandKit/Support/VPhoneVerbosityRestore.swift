import Foundation
import VPhoneCoreKit
import VPhoneRestore

// MARK: - Verbosity → restore logging

extension VPhoneVerbosity {
    /// What `-v` meant when the restore ran as a Python subprocess: one `-v`
    /// for `.info` (pymobiledevice3's colorful INFO), two for `.debug` and
    /// `.trace`. In process that single count becomes two knobs, and both are
    /// needed — see `restoreDebugLevel`.
    public var restoreLogLevel: VPhoneRestoreLogLevel {
        self >= .debug ? .debug : .info
    }

    /// idevicerestore's own level ceiling (`-d`). Raising the console sink
    /// without raising this one prints nothing extra, because the messages it
    /// would show are never emitted.
    public var restoreDebugLevel: Int32 {
        self >= .debug ? 1 : 0
    }
}

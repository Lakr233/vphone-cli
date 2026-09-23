import Foundation
import MobileRestoreCore

// MARK: - VPhoneRestoreLogLevel

/// idevicerestore's `enum loglevel`, one for one. Lower is more severe.
public enum VPhoneRestoreLogLevel: Int32, Sendable, Comparable, CaseIterable {
    case error = 0
    case warning = 1
    case notice = 2
    case info = 3
    case verbose = 4
    case debug = 5

    public static func < (lhs: VPhoneRestoreLogLevel, rhs: VPhoneRestoreLogLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// A level the C side reported that this enum does not know becomes
    /// `.info`, which is where an unlabelled line belongs.
    init(clamping raw: Int32) {
        self = VPhoneRestoreLogLevel(rawValue: raw) ?? .info
    }
}

// MARK: - VPhoneRestoreStep

/// One of idevicerestore's `RESTORE_STEP_*` phases.
///
/// A struct rather than an enum so a step this build has not heard of still
/// round-trips; `name` then comes back as "unknown" from the C side, which is
/// exactly what `vphone_restore_step_name` promises.
public struct VPhoneRestoreStep: RawRepresentable, Sendable, Hashable, CustomStringConvertible {
    public let rawValue: Int32

    public init(rawValue: Int32) { self.rawValue = rawValue }

    public static let detect = VPhoneRestoreStep(rawValue: VPHONE_RESTORE_STEP_DETECT)
    public static let prepare = VPhoneRestoreStep(rawValue: VPHONE_RESTORE_STEP_PREPARE)
    public static let uploadFilesystem = VPhoneRestoreStep(rawValue: VPHONE_RESTORE_STEP_UPLOAD_FS)
    public static let verifyFilesystem = VPhoneRestoreStep(rawValue: VPHONE_RESTORE_STEP_VERIFY_FS)
    public static let flashFirmware = VPhoneRestoreStep(rawValue: VPHONE_RESTORE_STEP_FLASH_FW)
    public static let flashBaseband = VPhoneRestoreStep(rawValue: VPHONE_RESTORE_STEP_FLASH_BB)
    public static let flashFUD = VPhoneRestoreStep(rawValue: VPHONE_RESTORE_STEP_FUD)
    public static let uploadImage = VPhoneRestoreStep(rawValue: VPHONE_RESTORE_STEP_UPLOAD_IMG)

    /// The short label the C bridge prints for this step.
    public var name: String {
        String(cString: vphone_restore_step_name(rawValue))
    }

    public var description: String { name }
}

// MARK: - VPhoneRestoreEvent

/// Everything a running restore reports.
///
/// `message` arrives with whatever line ending idevicerestore produced — the
/// levelled channel keeps its newline, the captured `printf` channel does not —
/// so a sink that renders it should normalize rather than assume.
public enum VPhoneRestoreEvent: Sendable {
    case log(level: VPhoneRestoreLogLevel, message: String)
    case progress(step: VPhoneRestoreStep, fraction: Double)
}

// MARK: - VPhoneRestoreEventHandler

/// Called from idevicerestore's worker threads, so it has to be safe to call
/// concurrently — hence `@Sendable`, not a convention.
public typealias VPhoneRestoreEventHandler = @Sendable (VPhoneRestoreEvent) -> Void

// MARK: - VPhoneRestoreConsole

/// The sink that stands in for what the CLI used to see.
///
/// `vphone-cli restore` ran the Python bridge through
/// `VPhoneProcessRunner.runStreaming`, which teed the child's stdout straight
/// to the terminal, so the user watched the restore log scroll by. This prints
/// the same stream from in-process: one line per message, errors on stderr,
/// everything else on stdout.
public enum VPhoneRestoreConsole {
    /// An event handler that writes to the terminal.
    ///
    /// - Parameters:
    ///   - level: lines above this are dropped. `.info` is what the Python
    ///     bridge's single `-v` produced; `.debug` is its `-vv`.
    ///   - showsProgress: whether `[step]  42%` lines are printed. Off by
    ///     default — idevicerestore already narrates its phases through the log
    ///     channel, and the progress callback fires often enough to bury it.
    ///
    /// Writes are serialized: the levelled channel holds idevicerestore's own
    /// mutex, but the captured `printf` channel does not, and two threads
    /// interleaving mid-line is the kind of log nobody can read. Each call
    /// returns an independently locked sink, so use one per restore.
    public static func handler(
        level: VPhoneRestoreLogLevel = .info,
        showsProgress: Bool = false
    ) -> VPhoneRestoreEventHandler {
        let lock = NSLock()
        return { event in
            switch event {
            case let .log(messageLevel, message):
                guard messageLevel <= level else { return }
                let line = message.trimmingCharacters(in: .newlines)
                guard !line.isEmpty else { return }
                lock.lock()
                defer { lock.unlock() }
                if messageLevel == .error {
                    FileHandle.standardError.write(Data("\(line)\n".utf8))
                } else {
                    print(line)
                }
            case let .progress(step, fraction):
                guard showsProgress else { return }
                lock.lock()
                defer { lock.unlock() }
                print(String(format: "[%@] %3.0f%%", step.name, fraction * 100))
            }
        }
    }
}

import Foundation
import MobileRestoreCore

// MARK: - VPhoneRestoreRunner

/// The thin layer over `vphone_restore_run`: closures in, C function pointers
/// out, a result code turned into a typed error.
///
/// Everything above this — `VPhoneRestoreService` — is about which directory and
/// which ticket; everything below it is idevicerestore.
public enum VPhoneRestoreRunner {
    /// Runs one restore to completion.
    ///
    /// Three things about this call are not negotiable, and all three come from
    /// the C bridge rather than from here:
    ///
    /// - It BLOCKS for the whole restore, which is minutes.
    /// - Only one may run at a time in a process; a second concurrent call
    ///   throws `.restoreAlreadyRunning` rather than corrupting the first.
    /// - It swaps the process's `stdout` while it runs, so anything else
    ///   printing from another thread meanwhile arrives at `onEvent` instead of
    ///   on the terminal.
    ///
    /// `onEvent` is called from idevicerestore's worker threads, concurrently,
    /// which is why it is `@Sendable`.
    public static func run(
        _ options: VPhoneRestoreOptions,
        onEvent: @escaping VPhoneRestoreEventHandler = { _ in },
    ) throws {
        let sink = VPhoneRestoreEventSink(onEvent)
        let result = options.withCOptions { base -> Int32 in
            var c = base
            c.context = Unmanaged.passUnretained(sink).toOpaque()
            c.log_cb = { level, message, context in
                guard let context, let message else { return }
                let sink = Unmanaged<VPhoneRestoreEventSink>.fromOpaque(context).takeUnretainedValue()
                sink.handler(.log(
                    level: VPhoneRestoreLogLevel(clamping: level),
                    message: String(cString: message),
                ))
            }
            c.progress_cb = { step, fraction, context in
                guard let context else { return }
                let sink = Unmanaged<VPhoneRestoreEventSink>.fromOpaque(context).takeUnretainedValue()
                sink.handler(.progress(step: VPhoneRestoreStep(rawValue: step), fraction: fraction))
            }
            return vphone_restore_run(&c)
        }
        // `sink` is passed unretained, so it has to outlive the C call. It
        // does — `withCOptions` returns first — but say so, or a release build
        // is free to drop it the moment the closure above stops naming it.
        withExtendedLifetime(sink) {}

        try throwIfFailed(result, options: options)
    }

    // MARK: Result codes

    private static func throwIfFailed(_ result: Int32, options: VPhoneRestoreOptions) throws {
        switch result {
        case VPHONE_RESTORE_OK:
            return
        case VPHONE_RESTORE_E_BUSY:
            throw VPhoneRestoreBackendError.restoreAlreadyRunning
        case VPHONE_RESTORE_E_NO_RESTORE_DIR:
            throw VPhoneRestoreBackendError.restoreDirectoryUnusable(options.restoreDirectory)
        case VPHONE_RESTORE_E_TICKET:
            throw VPhoneRestoreBackendError.ticketUnreadable(
                options.ticketPath ?? options.restoreDirectory,
            )
        default:
            // Everything else, including the small negatives idevicerestore
            // returns itself. The log stream carries what actually went wrong.
            throw VPhoneRestoreBackendError.restoreFailed(
                code: result,
                reason: String(cString: vphone_restore_error_string(result)),
            )
        }
    }
}

// MARK: - VPhoneRestoreEventSink

/// Carries the caller's closure through `void *context`.
///
/// `Sendable` without `@unchecked`: the only stored property is a `let` holding
/// an already-`@Sendable` function.
final class VPhoneRestoreEventSink: Sendable {
    let handler: VPhoneRestoreEventHandler

    init(_ handler: @escaping VPhoneRestoreEventHandler) {
        self.handler = handler
    }
}

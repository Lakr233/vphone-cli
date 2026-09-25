import Foundation

// MARK: - VPhoneRestoreBackendError

/// Everything this module can fail with.
///
/// Deliberately NOT named `VPhoneRestoreError`: `VPhoneCoreKit` already exports a
/// type by that name and `vphone-cli` imports both, so sharing it would make
/// every unqualified use ambiguous.
///
/// The messages of the first five cases are word for word the ones
/// `scripts/pymobiledevice3_bridge.py` printed, because scripts and people
/// have been reading them for a while.
public enum VPhoneRestoreBackendError: Error, Equatable {
    // MARK: ECID

    /// `--ecid ""`, `--ecid "  "` or `--ecid 0x` — a value that is present but
    /// carries no digits. Python's `ValueError("ECID is empty")`.
    case ecidEmpty

    /// A value with a character outside `0-9a-f`. Carries the ORIGINAL string,
    /// not the normalized one, which is what Python reported.
    case ecidInvalid(String)

    /// More than 16 hex digits. Python's ints are unbounded so it had no such
    /// error; an ECID is a 64-bit chip identifier and `UInt64` is where it
    /// lands, so rejecting it here beats silently truncating.
    case ecidTooLarge(String)

    // MARK: Restore tree

    case noRestoreDirectory(URL)
    case multipleRestoreDirectories([String])

    // MARK: Probe

    /// `timeout` seconds went by without a matching endpoint. The payload is
    /// Python's `mode_label`: "recovery" when recovery was demanded,
    /// "dfu/recovery" otherwise.
    case recoveryProbeTimedOut(mode: String)

    /// The endpoint answered but `irecv_get_mode`/`irecv_get_device_info` did
    /// not, which means the USB handle went away mid-probe.
    case recoveryDeviceUnreadable

    // MARK: Running

    /// `VPHONE_RESTORE_E_BUSY`: one restore at a time, per the C bridge.
    case restoreAlreadyRunning

    /// `VPHONE_RESTORE_E_NO_RESTORE_DIR` from the bridge, which checks the
    /// path again on its own side and also rejects a `.ipsw` archive.
    case restoreDirectoryUnusable(URL)

    /// `VPHONE_RESTORE_E_TICKET`: the `.shsh` is not a TSS response plist.
    case ticketUnreadable(URL)

    /// Anything else idevicerestore stopped on. `reason` is
    /// `vphone_restore_error_string(code)`; the log stream carries the detail.
    case restoreFailed(code: Int32, reason: String)

    // MARK: SHSH

    /// The TSS fetch reported success but wrote no `.shsh` under the cache.
    case shshNotProduced(URL)

    /// A `.shsh` was written but is not a property-list dictionary.
    case shshMalformed(URL)

    /// The `.shsh` is gzipped and zlib could not inflate it.
    case shshNotDecompressible(URL)
}

// MARK: - CustomStringConvertible

extension VPhoneRestoreBackendError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .ecidEmpty:
            "ECID is empty"
        case let .ecidInvalid(value):
            "Invalid ECID: \(value)"
        case let .ecidTooLarge(value):
            "ECID is too long: \(value). Enter up to 16 hexadecimal digits."
        case let .noRestoreDirectory(dir):
            "No iPhone*_Restore directory found in \(dir.path)"
        case .multipleRestoreDirectories:
            "Multiple iPhone*_Restore directories found; keep only one active restore tree"
        case let .recoveryProbeTimedOut(mode):
            "Timed out waiting for \(mode) endpoint"
        case .recoveryDeviceUnreadable:
            "The recovery endpoint stopped answering while it was being read"
        case .restoreAlreadyRunning:
            "Another restore is already running. Wait for it to finish, then try again."
        case let .restoreDirectoryUnusable(dir):
            "Unable to use \(dir.path) as a restore directory. Choose an extracted iPhone*_Restore directory, not an .ipsw archive."
        case let .ticketUnreadable(path):
            "Unable to read the SHSH ticket at \(path.path). Fetch a new ticket and try again."
        case let .restoreFailed(_, reason):
            "Restore failed. \(reason)"
        case let .shshNotProduced(dir):
            "The SHSH ticket was fetched, but no file was saved in \(dir.path). Try again."
        case let .shshMalformed(path):
            "\(path.path) is not a valid SHSH ticket. Fetch a new ticket and try again."
        case let .shshNotDecompressible(path):
            "The SHSH ticket at \(path.path) is damaged. Fetch a new ticket and try again."
        }
    }
}

// MARK: - LocalizedError

extension VPhoneRestoreBackendError: LocalizedError {
    public var errorDescription: String? {
        description
    }
}

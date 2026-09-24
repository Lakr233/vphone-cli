import Foundation

// MARK: - VPhoneRestoreBackendError

/// Everything this module can fail with.
///
/// Deliberately NOT named `VPhoneRestoreError`: `VPhoneCore` already exports a
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
            "ECID does not fit in 64 bits: \(value)"
        case let .noRestoreDirectory(dir):
            "No iPhone*_Restore directory found in \(dir.path)"
        case .multipleRestoreDirectories:
            "Multiple iPhone*_Restore directories found; keep only one active restore tree"
        case let .recoveryProbeTimedOut(mode):
            "Timed out waiting for \(mode) endpoint"
        case .recoveryDeviceUnreadable:
            "The recovery endpoint stopped answering while it was being read"
        case .restoreAlreadyRunning:
            "Another restore is already running in this process"
        case let .restoreDirectoryUnusable(dir):
            "\(dir.path) cannot be used as a restore directory; it must be an extracted "
                + "iPhone*_Restore directory, not a .ipsw archive"
        case let .ticketUnreadable(path):
            "\(path.path) could not be read as a TSS response plist"
        case let .restoreFailed(code, reason):
            "Restore failed (\(code)): \(reason)"
        case let .shshNotProduced(dir):
            "The TSS record was fetched but no .shsh appeared under \(dir.path)"
        case let .shshMalformed(path):
            "\(path.path) is not a TSS response dictionary"
        case let .shshNotDecompressible(path):
            "\(path.path) is gzipped and could not be decompressed"
        }
    }
}

// MARK: - LocalizedError

extension VPhoneRestoreBackendError: LocalizedError {
    public var errorDescription: String? {
        description
    }
}

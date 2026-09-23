import Foundation
import MobileRestoreCore

// MARK: - VPhoneRestoreOptions

/// One run of `vphone_restore_run`, in Swift terms.
///
/// This is the whole of `struct vphone_restore_options` except its three
/// callback fields, which `VPhoneRestoreRunner` fills in — a caller passes a
/// closure, never a function pointer.
public struct VPhoneRestoreOptions: Sendable, Equatable {
    /// The extracted `iPhone*_Restore` directory. A `.ipsw` archive is
    /// rejected: this build has no libzip (see `sources/MobileRestoreCore/zip.h`).
    public var restoreDirectory: URL

    /// Where personalized components and `shshOnly`'s output land. `nil` is
    /// idevicerestore's default, the process's current directory.
    public var cacheDirectory: URL?

    /// Target one device by UDID. Only a device in normal mode has one, so a
    /// DFU or recovery target is matched by `ecid` alone.
    public var udid: String?

    /// Target one device by ECID. `0` means "the only one attached".
    public var ecid: UInt64

    /// `true` erases (upstream's `-e`, pymobiledevice3's `Behavior.Erase`),
    /// `false` updates in place (`Behavior.Update`).
    public var erase: Bool

    /// `nil` fetches a ticket from Apple. Non-`nil` restores offline from a
    /// saved TSS response — the WHOLE response, not a bare AP ticket.
    public var ticketPath: URL?

    /// Fetch the TSS record into `cacheDirectory/shsh/` and stop without
    /// touching the device. Upstream's `-t/--shsh`.
    public var shshOnly: Bool

    /// Also write each personalized component to a file. Upstream's `-k`.
    public var keepPers: Bool

    /// `0` is normal output; anything higher turns on idevicerestore's debug
    /// logging, which is also what raises the log callback's level ceiling.
    public var debugLevel: Int32

    public init(
        restoreDirectory: URL,
        cacheDirectory: URL? = nil,
        udid: String? = nil,
        ecid: UInt64 = 0,
        erase: Bool = true,
        ticketPath: URL? = nil,
        shshOnly: Bool = false,
        keepPers: Bool = false,
        debugLevel: Int32 = 0
    ) {
        self.restoreDirectory = restoreDirectory
        self.cacheDirectory = cacheDirectory
        self.udid = udid
        self.ecid = ecid
        self.erase = erase
        self.ticketPath = ticketPath
        self.shshOnly = shshOnly
        self.keepPers = keepPers
        self.debugLevel = debugLevel
    }
}

// MARK: - C mapping

public extension VPhoneRestoreOptions {
    /// Builds the C struct and hands it to `body`.
    ///
    /// Every `const char *` in it points into storage that lives exactly as
    /// long as the call, so nothing here may be stashed for later — which is
    /// fine, because `vphone_restore_run` copies what it keeps.
    ///
    /// The callback fields are left `NULL`; `VPhoneRestoreRunner` sets them on
    /// its own copy.
    func withCOptions<R>(_ body: (vphone_restore_options) throws -> R) rethrows -> R {
        let strings = VPhoneCStringBag()
        defer { strings.releaseAll() }

        var options = vphone_restore_options()
        options.restore_dir = strings.duplicate(restoreDirectory.path)
        options.cache_dir = strings.duplicate(cacheDirectory?.path)
        options.udid = strings.duplicate(udid)
        options.ecid = ecid
        options.erase = erase
        options.ticket_path = strings.duplicate(ticketPath?.path)
        options.shsh_only = shshOnly
        options.keep_pers = keepPers
        options.debug_level = debugLevel
        return try body(options)
    }
}

// MARK: - VPhoneCStringBag

/// C strings that all go away together.
///
/// Nesting seven `withCString` closures would say the same thing and read like
/// a staircase; this keeps `withCOptions` flat and frees in one place.
final class VPhoneCStringBag {
    private var allocations: [UnsafeMutablePointer<CChar>] = []

    /// `nil` in, `nil` out — which is what every optional field of
    /// `vphone_restore_options` means by "not set".
    func duplicate(_ value: String?) -> UnsafePointer<CChar>? {
        guard let value, let copy = strdup(value) else { return nil }
        allocations.append(copy)
        return UnsafePointer(copy)
    }

    func releaseAll() {
        for allocation in allocations { free(allocation) }
        allocations.removeAll()
    }
}

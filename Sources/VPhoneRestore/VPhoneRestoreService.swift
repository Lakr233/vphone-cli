import Foundation

// MARK: - VPhoneRestoreService

/// What `scripts/pymobiledevice3_bridge.py` did, in process.
///
/// The Python had four commands. `usbmux-list` is not here: nothing in this
/// repository ever called it. The other three are, with the same arguments,
/// the same errors and the same two lines of output that scripts and people
/// have been reading — `[+] SHSH saved: …` and `[+] Using cached SHSH: …`.
///
/// Everything below blocks for as long as the work takes and reports through
/// `onEvent`, which idevicerestore calls from its worker threads.
public enum VPhoneRestoreService {
    // MARK: recovery-probe

    /// `recovery-probe`. See `VPhoneRecoveryProbe.probe`.
    @discardableResult
    public static func recoveryProbe(
        ecid: UInt64?,
        timeout: Int,
        isRecovery: Bool? = nil,
    ) throws -> VPhoneRecoveryDevice {
        try VPhoneRecoveryProbe.probe(ecid: ecid, timeout: timeout, isRecovery: isRecovery)
    }

    // MARK: restore-get-shsh

    /// `restore-get-shsh`: fetch the TSS record for the firmware staged in
    /// `vmDir` and save it beside the VM.
    ///
    /// Python fetched it with `Behavior.Erase`, so this asks for an erase
    /// ticket too — an update ticket signs a different set of components, and
    /// every restore this project drives is an erase.
    ///
    /// The device is never touched: idevicerestore's `-t/--shsh` reads its
    /// identity, asks Apple, writes the blob and stops.
    ///
    /// - Returns: the path written, which is `out` when given and
    ///   `<vmDir>/<ECID as %016X>.shsh` otherwise.
    @discardableResult
    public static func fetchSHSH(
        vmDir: URL,
        ecid: UInt64?,
        udid: String?,
        out: URL?,
        debugLevel: Int32 = 0,
        onEvent: @escaping VPhoneRestoreEventHandler = { _ in },
    ) throws -> URL {
        let restoreDirectory = try VPhoneRestoreLayout.findRestoreDirectory(in: vmDir)

        // A cache of its own, so "the .shsh idevicerestore just wrote" is
        // unambiguous. It matters: the FLAG_SHSHONLY block skips the write
        // when a file of that name is already there ("SHSH '%s' already
        // present."), and a stale blob from a previous firmware would then be
        // what got copied out.
        let cacheDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vphone-shsh-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: cacheDirectory) }

        try VPhoneRestoreRunner.run(
            VPhoneRestoreOptions(
                restoreDirectory: restoreDirectory,
                cacheDirectory: cacheDirectory,
                udid: VPhoneRestoreIdentity.normalizeUDID(udid),
                ecid: ecid ?? 0,
                erase: true,
                shshOnly: true,
                debugLevel: debugLevel,
            ),
            onEvent: onEvent,
        )

        let written = try locateWrittenSHSH(under: cacheDirectory, requestedECID: ecid)
        let onDisk = try Data(contentsOf: written, options: .mappedIfSafe)
        let contents = try VPhoneRestoreTicket.plistData(of: onDisk, at: written)

        // Python named the file after the ECID the DEVICE reported, not the one
        // that was asked for; idevicerestore puts that same value at the front
        // of its filename, so it survives a fetch with no --ecid at all.
        let deviceECID = VPhoneRestoreTicket.ecid(fromSHSHFilename: written.lastPathComponent)
        let destination = out ?? VPhoneRestoreLayout.shshOutput(vmDir: vmDir, ecid: deviceECID ?? ecid)
        try contents.write(to: destination, options: .atomic)

        onEvent(.log(level: .notice, message: "[+] SHSH saved: \(destination.path)"))
        return destination
    }

    // MARK: restore-update

    /// `restore-update`: erase or update the device from the firmware staged
    /// in `vmDir`.
    ///
    /// - Parameters:
    ///   - erase: `true` is `Behavior.Erase`, `false` is `Behavior.Update`.
    ///   - ticketPath: a saved TSS response for an offline restore, or `nil` to
    ///     ask Apple. It must be a WHOLE response — what `fetchSHSH` writes —
    ///     not a bare AP ticket; see `vphone_restore_bridge.c`.
    public static func restore(
        vmDir: URL,
        ecid: UInt64?,
        udid: String?,
        erase: Bool,
        ticketPath: URL?,
        debugLevel: Int32 = 0,
        onEvent: @escaping VPhoneRestoreEventHandler = { _ in },
    ) throws {
        let restoreDirectory = try VPhoneRestoreLayout.findRestoreDirectory(in: vmDir)

        if let ticketPath {
            onEvent(.log(level: .notice, message: "[+] Using cached SHSH: \(ticketPath.path)"))
        }

        try VPhoneRestoreRunner.run(
            VPhoneRestoreOptions(
                restoreDirectory: restoreDirectory,
                // The Python bridge ran with the bundle as its working
                // directory, and idevicerestore's default cache IS the working
                // directory, so naming it keeps personalized components landing
                // where they always have — no matter where the CLI is invoked.
                cacheDirectory: vmDir,
                udid: VPhoneRestoreIdentity.normalizeUDID(udid),
                ecid: ecid ?? 0,
                erase: erase,
                ticketPath: ticketPath,
                debugLevel: debugLevel,
            ),
            onEvent: onEvent,
        )
    }

    // MARK: - Helpers

    /// The `.shsh` idevicerestore wrote, under `<cache>/shsh/`.
    ///
    /// A fresh cache directory means there is exactly one. The ECID match is
    /// for the case where there somehow is not, so the wrong device's blob
    /// cannot be picked up silently.
    private static func locateWrittenSHSH(under cacheDirectory: URL, requestedECID: UInt64?) throws -> URL {
        let shshDirectory = cacheDirectory.appendingPathComponent("shsh", isDirectory: true)
        let candidates = ((try? FileManager.default.contentsOfDirectory(
            at: shshDirectory,
            includingPropertiesForKeys: nil,
        )) ?? [])
            .filter { $0.pathExtension == "shsh" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        guard !candidates.isEmpty else {
            throw VPhoneRestoreBackendError.shshNotProduced(shshDirectory)
        }
        if let requestedECID {
            let match = candidates.first {
                VPhoneRestoreTicket.ecid(fromSHSHFilename: $0.lastPathComponent) == requestedECID
            }
            if let match {
                return match
            }
        }
        return candidates[0]
    }
}

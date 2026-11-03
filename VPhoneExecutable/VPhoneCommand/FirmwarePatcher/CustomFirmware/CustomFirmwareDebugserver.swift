// CustomFirmwareDebugserver.swift — the debugserver re-sign shared by both install stages.
//
// debugserver reaches a guest two ways, and both need the same entitlement
// change. `cfw install` re-signs it in the restored, mounted system
// (VPhoneCustomFirmwareInstaller.patchDebugserver). The `minimal` restore-image
// merge re-signs it in the pre-reseal image
// (CryptexFilesystemPatcher.patchDebugserver), so its new hash lands in the
// regenerated trust cache the stock kernel already trusts. The entitlement
// transform lives here once so the two stages cannot drift.

import Foundation

public enum CustomFirmwareDebugserver {
    /// debugserver's path in the guest system volume. A stock userland carries it
    /// only inside the Developer disk image; a research/cloudOS build is where one
    /// is present to re-sign. Both stages treat its absence as a logged no-op.
    public static let guestPath = "usr/libexec/debugserver"

    public enum Error: Swift.Error, CustomStringConvertible {
        case unreadableEntitlements
        public var description: String {
            switch self {
            case .unreadableEntitlements:
                "debugserver's entitlements are not a readable property list; cannot grant task_for_pid."
            }
        }
    }

    /// Turn debugserver's own entitlements into the set it needs to attach in the
    /// guest: drop the `seatbelt-profiles` that would confine it, and grant
    /// `task_for_pid-allow` so it can take another process's task port. The result
    /// is the complete entitlement set to embed by **replacement** — merging it
    /// back over the file's own entitlements would re-add the `seatbelt-profiles`
    /// removed here, because a merge updates and appends keys but cannot delete
    /// one.
    ///
    /// This only grants the entitlement. Whether the kernel honours it for a
    /// system daemon is a separate matter: that needs the kernel's task-port,
    /// debugger and port-to-map patches, which a stock `minimal` kernel lacks
    /// (``FirmwarePatchSetCatalog/userspaceDebugging``).
    public static func attachEntitlements(from source: Data) throws -> Data {
        guard var plist = try PropertyListSerialization.propertyList(from: source, format: nil) as? [String: Any] else {
            throw Error.unreadableEntitlements
        }
        plist.removeValue(forKey: "seatbelt-profiles")
        plist["task_for_pid-allow"] = true
        return try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    }
}

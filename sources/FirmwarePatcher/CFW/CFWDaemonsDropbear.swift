// CFWDaemonsDropbear.swift — dropbear's ProgramArguments rewrite.
//
// Translated from: scripts/patchers/cfw_daemons.py (patch_dropbear_daemon,
// patch_dropbear_plist). Covered by tests/FirmwarePatcherTests/CFWDaemonsTests.swift,
// which carries both cases of the retired tests/test_dropbear_plist.py.

import Foundation

public extension CFWDaemons {
    // MARK: - Host keys

    /// The host keys dropbear is pointed at instead of generating its own.
    ///
    /// `/var` is on the writable Data volume; `/etc/dropbear`, where `-R` would
    /// put them, is on a read-only root during a normal VM boot.  `cfw_install`
    /// seeds these two files.
    static let dropbearKeyArguments: [String] = [
        "-r",
        "/var/dropbear/dropbear_rsa_host_key",
        "-r",
        "/var/dropbear/dropbear_ecdsa_host_key",
    ]

    // MARK: - Rewrite

    /// Strip dropbear's key-generation flags and append the seeded host keys.
    ///
    /// Drops `-R` (generate defaults under the read-only `/etc/dropbear`) and
    /// every `-r <path>` pair, so a stale explicit key path cannot survive, then
    /// appends `dropbearKeyArguments`.  An empty or missing argument list is left
    /// alone: there is nothing to point at a key.
    ///
    /// Elements are compared as strings but carried through as read, so a plist
    /// holding a non-string in `ProgramArguments` round-trips unchanged rather
    /// than failing.
    static func patchedDropbearArguments(_ arguments: [Any]) -> [Any] {
        guard !arguments.isEmpty else { return arguments }

        var cleaned: [Any] = []
        var index = 0
        while index < arguments.count {
            switch arguments[index] as? String {
            case "-R":
                index += 1
            case "-r":
                index += 2
            default:
                cleaned.append(arguments[index])
                index += 1
            }
        }
        return cleaned + dropbearKeyArguments
    }

    /// Apply `patchedDropbearArguments` to a loaded daemon plist in place.
    static func patchDropbearDaemon(_ daemon: inout PlistDict) {
        guard let arguments = daemon["ProgramArguments"] as? [Any], !arguments.isEmpty else {
            return
        }
        daemon["ProgramArguments"] = patchedDropbearArguments(arguments)
    }

    /// Rewrite a dropbear daemon plist on disk. Implements `cfw.py patch-dropbear-plist`.
    static func patchDropbearPlist(at url: URL) throws {
        var daemon = try loadPlist(url)
        patchDropbearDaemon(&daemon)
        try savePlist(daemon, to: url)
    }
}

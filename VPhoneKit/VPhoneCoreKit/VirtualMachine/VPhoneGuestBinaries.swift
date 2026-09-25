// VPhoneGuestBinaries.swift — where the prebuilt iOS binaries live.
//
// Guest payloads are cross-compiled on the build machine and shipped in the
// bundle's guest resources. The bundle carries the signed vphoned for
// installation and host auto-update.

import Foundation

public enum VPhoneGuestBinaries {
    public enum Error: Swift.Error, LocalizedError {
        case missing(String, [URL])

        public var errorDescription: String? {
            switch self {
            case let .missing(name, searched):
                """
                Guest binary '\(name)' not found. Build the VPhone scheme in VPhone.xcworkspace.
                Searched: \(searched.map(\.path).joined(separator: ", "))
                """
            }
        }
    }

    /// `Contents/Resources/guest-resources` in the bundle, `.build/guest` in a
    /// dev tree.
    ///
    /// Both are derived from `VPhoneResources.base`, which is already the
    /// running image's own location rather than anything on `PATH` — so this
    /// finds the binaries that were built beside this one, not whatever else is
    /// on the machine.
    public static func directories() -> [URL] {
        let resources = VPhoneResources.resolve()
        return [
            resources.guestResources,
            resources.base.appendingPathComponent(".build/guest"),
        ]
    }

    public static func resolve(_ name: String) throws -> URL {
        let searched = directories()
        for directory in searched {
            let candidate = directory.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        throw Error.missing(name, searched)
    }
}

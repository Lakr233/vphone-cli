// VPhoneGuestBinaries.swift — where the prebuilt iOS binaries live.
//
// Five Mach-Os run inside the guest and are built for it, not for this host:
// vphoned, TweakLoader.dylib, vpregister, libvcamcaptured.dylib and
// libcamfix.dylib. Every one of them used to be cross-compiled at CFW-install
// time — three by `scripts/cfw_install*.sh` through `xcrun --sdk iphoneos`, and
// vphoned by `FirmwarePatcher` doing the same thing from Swift. That made Xcode
// and the iPhoneOS SDK a prerequisite for `cfw install`, on a machine whose only
// job is to run a virtual phone.
//
// They are compiled by `scripts/guest_binaries.mk` on the machine that builds
// the .app and shipped in `Contents/Resources/guest`. What is left at install
// time is signing, which cannot move: it uses the target VM's own
// `cfw_input/signcert.p12`, and that does not exist until a VM does.

import Foundation

public enum VPhoneGuestBinaries {
    public enum Error: Swift.Error, LocalizedError {
        case missing(String, [URL])

        public var errorDescription: String? {
            switch self {
            case let .missing(name, searched):
                """
                no prebuilt guest binary '\(name)'. Run 'make build'.
                Looked in: \(searched.map(\.path).joined(separator: ", "))
                """
            }
        }
    }

    /// `Contents/Resources/guest` in the bundle, `.build/guest` in a dev tree.
    ///
    /// Both are derived from `VPhoneResources.base`, which is already the
    /// running image's own location rather than anything on `PATH` — so this
    /// finds the binaries that were built beside this one, not whatever else is
    /// on the machine.
    public static func directories() -> [URL] {
        let base = VPhoneResources.resolve().base
        return [
            base.appendingPathComponent("guest"),
            base.appendingPathComponent(".build/guest"),
        ]
    }

    public static func resolve(_ name: String) throws -> URL {
        let searched = directories()
        for directory in searched {
            let candidate = directory.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        throw Error.missing(name, searched)
    }
}

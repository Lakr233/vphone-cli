// CustomFirmwareDaemons.swift — Cryptex path lookup and the plist I/O the CFW daemon rewrites share.
//
// Translated from: scripts/patchers/cfw_daemons.py (cryptex-paths, inject-daemons,
// patch-dropbear-plist). None of these three touch code or signatures — they are
// plist reads and rewrites, which is why they come over ahead of the disassembly
// patchers.

import Foundation
import VPhoneCoreKit

// MARK: - CustomFirmwareDaemons

/// The three non-disassembly CFW commands: Cryptex path lookup, LaunchDaemon
/// injection into `launchd.plist`, and the dropbear `ProgramArguments` rewrite.
public enum CustomFirmwareDaemons {
    // MARK: - Errors

    public enum DaemonError: Error, CustomStringConvertible {
        case fileNotFound(String)
        case invalidPlist(String)
        case cryptexPathsNotFound(String)
        case unsafeCryptexPath(String)

        public var description: String {
            switch self {
            case let .fileNotFound(path):
                "File not found: \(path)"
            case let .invalidPlist(path):
                "Invalid plist: \(path)"
            case let .cryptexPathsNotFound(path):
                "Cryptex1,SystemOS/AppOS paths not found in any BuildIdentity: \(path)"
            case let .unsafeCryptexPath(path):
                "Cryptex image path is not a plain path inside the restore folder: \(path)"
            }
        }
    }

    // MARK: - Cryptex paths

    /// The two Cryptex DMG paths a BuildManifest names, relative to the IPSW root.
    public struct CryptexPaths: Sendable, Equatable {
        public let systemOS: String
        public let appOS: String

        public init(systemOS: String, appOS: String) {
            self.systemOS = systemOS
            self.appOS = appOS
        }
    }

    /// tvOS on AppleTV5,3 carries its frameworks and cache in the OS image,
    /// rather than the two cryptexes iPhone/iPad firmware supplies. This is
    /// manifest admission only; it does not establish that the userland boots.
    public enum FilesystemLayout: Sendable, Equatable {
        case cryptex(CryptexPaths)
        case monolithic
    }

    public static func filesystemLayout(buildManifest url: URL) throws -> FilesystemLayout {
        let manifest = try loadPlist(url)
        guard let identities = manifest["BuildIdentities"] as? [PlistDict], !identities.isEmpty else {
            throw DaemonError.invalidPlist(url.path)
        }
        // A partial or malformed cryptex declaration is never evidence for a
        // monolithic image. Keep the original lookup and its path validation.
        let hasCryptex = identities.contains { identity in
            let entries = identity["Manifest"] as? PlistDict ?? [:]
            return entries["Cryptex1,SystemOS"] != nil || entries["Cryptex1,AppOS"] != nil
        }
        if hasCryptex {
            return .cryptex(try cryptexPaths(buildManifest: url))
        }
        guard let products = manifest["SupportedProductTypes"] as? [String], !products.isEmpty,
              (products.allSatisfy { VPhoneGuestDevice.named($0)?.usesTVOS == true }
                  || products.allSatisfy { VPhoneGuestDevice.named($0)?.family == .vision }),
              let erase = identities.first(where: {
                  ($0["Info"] as? PlistDict)?["RestoreBehavior"] as? String == "Erase"
              }),
              erase["Ap,SDKPlatform"] as? String == (products.allSatisfy { VPhoneGuestDevice.named($0)?.family == .vision } ? "xros" : "appletvos"),
              let entries = erase["Manifest"] as? PlistDict
        else { throw DaemonError.cryptexPathsNotFound(url.path) }
        for component in ["OS", "SystemVolume", "StaticTrustCache", "Ap,SystemVolumeCanonicalMetadata"] {
            let path = componentPath(entries, component)
            guard !path.isEmpty else { throw DaemonError.invalidPlist(url.path) }
            guard isPlainRelativePath(path) else { throw DaemonError.unsafeCryptexPath(path) }
        }
        return .monolithic
    }

    /// Extract the Cryptex DMG paths from a BuildManifest.
    ///
    /// Every BuildIdentity is searched, not just the first: vResearch IPSWs carry
    /// their Cryptex entries in a later identity, and the last identity in a real
    /// manifest has none at all.  The first identity carrying *both* wins.
    ///
    /// The manifest sits in a caller-controlled VM folder and root opens what
    /// it names, so a path that is absolute or has a `.` or `..` component is
    /// refused rather than joined onto the restore folder.
    public static func cryptexPaths(buildManifest url: URL) throws -> CryptexPaths {
        let manifest = try loadPlist(url)
        let identities = manifest["BuildIdentities"] as? [Any] ?? []

        for identity in identities {
            let manifestSection = (identity as? PlistDict)?["Manifest"] as? PlistDict ?? [:]
            let systemOS = componentPath(manifestSection, "Cryptex1,SystemOS")
            let appOS = componentPath(manifestSection, "Cryptex1,AppOS")
            if !systemOS.isEmpty, !appOS.isEmpty {
                for path in [systemOS, appOS] where !isPlainRelativePath(path) {
                    throw DaemonError.unsafeCryptexPath(path)
                }
                return CryptexPaths(systemOS: systemOS, appOS: appOS)
            }
        }

        throw DaemonError.cryptexPathsNotFound(url.path)
    }

    /// Non-empty, relative, and made only of non-empty names other than `.`
    /// and `..`.
    static func isPlainRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\0") else { return false }
        return path.split(separator: "/", omittingEmptySubsequences: false)
            .allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    /// `Manifest -> <component> -> Info -> Path`, or "" when any link is missing.
    private static func componentPath(_ manifest: PlistDict, _ component: String) -> String {
        let info = (manifest[component] as? PlistDict)?["Info"] as? PlistDict
        return info?["Path"] as? String ?? ""
    }

    // MARK: - Plist I/O

    /// Read a plist of any format.
    ///
    /// The Python ran `plutil -convert xml1` first, which was only ever needed
    /// because `plistlib` cannot read old-style ASCII plists.  CoreFoundation
    /// reads all three formats, so the conversion step drops out.
    static func loadPlist(_ url: URL) throws -> PlistDict {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw DaemonError.fileNotFound(url.path)
        }
        let data = try Data(contentsOfFileToRewrite: url)
        guard let dict = try PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil,
        ) as? PlistDict else {
            throw DaemonError.invalidPlist(url.path)
        }
        return dict
    }

    /// Write a plist as XML, matching what `plistlib.dump` produced.
    ///
    /// XML rather than binary because that is what the Python wrote, and the
    /// installer's `/System/Library/xpc/launchd.plist` has been an XML file ever
    /// since.  Note that CoreFoundation orders dictionary keys alphabetically
    /// while `plistlib.dump(sort_keys=False)` kept the order it read; a plist
    /// dictionary is unordered to every consumer of these files, and the
    /// migration plan's equivalence bar for plists is the key *set*.
    static func savePlist(_ plist: PlistDict, to url: URL) throws {
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0,
        )
        try data.write(to: url)
    }
}

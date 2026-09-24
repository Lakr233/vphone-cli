// CFWDaemons.swift — Cryptex path lookup and the plist I/O the CFW daemon rewrites share.
//
// Translated from: scripts/patchers/cfw_daemons.py (cryptex-paths, inject-daemons,
// patch-dropbear-plist). None of these three touch code or signatures — they are
// plist reads and rewrites, which is why they come over ahead of the disassembly
// patchers.

import Foundation

// MARK: - CFWDaemons

/// The three non-disassembly CFW commands: Cryptex path lookup, LaunchDaemon
/// injection into `launchd.plist`, and the dropbear `ProgramArguments` rewrite.
public enum CFWDaemons {
    // MARK: - Errors

    public enum DaemonError: Error, CustomStringConvertible {
        case fileNotFound(String)
        case invalidPlist(String)
        case cryptexPathsNotFound(String)

        public var description: String {
            switch self {
            case let .fileNotFound(path):
                "File not found: \(path)"
            case let .invalidPlist(path):
                "Invalid plist: \(path)"
            case let .cryptexPathsNotFound(path):
                "Cryptex1,SystemOS/AppOS paths not found in any BuildIdentity: \(path)"
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

    /// Extract the Cryptex DMG paths from a BuildManifest.
    ///
    /// Every BuildIdentity is searched, not just the first: vResearch IPSWs carry
    /// their Cryptex entries in a later identity, and the last identity in a real
    /// manifest has none at all.  The first identity carrying *both* wins.
    public static func cryptexPaths(buildManifest url: URL) throws -> CryptexPaths {
        let manifest = try loadPlist(url)
        let identities = manifest["BuildIdentities"] as? [Any] ?? []

        for identity in identities {
            let manifestSection = (identity as? PlistDict)?["Manifest"] as? PlistDict ?? [:]
            let systemOS = componentPath(manifestSection, "Cryptex1,SystemOS")
            let appOS = componentPath(manifestSection, "Cryptex1,AppOS")
            if !systemOS.isEmpty, !appOS.isEmpty {
                return CryptexPaths(systemOS: systemOS, appOS: appOS)
            }
        }

        throw DaemonError.cryptexPathsNotFound(url.path)
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

// CFWMachLookupExceptions.swift — Campo backboard/frontboard mach-lookups.
//
// Swift port of scripts/patchers/campo_mach_lookup_exceptions.py (JB-3b).
// See research/0_binary_patch_comparison.md #14.
//
// iOS 27's temporary sandbox denies Campo.app the backboard/frontboard
// services it needs to put a window on screen. The install step dumps
// Campo's entitlements with `ldid -e`, merges the missing global-name
// lookups into the mach-lookup exception array, and re-signs with the
// merged plist.
//
// The merge is append-only and order-preserving: entries already present
// keep their position, and anything the binary carried that is not in this
// list survives. That matters because the plist is fed straight back to
// `ldid`, and dropping an entitlement Campo already had would be a silent
// downgrade.

import Foundation

/// Merges the mach-lookup global-name exceptions Campo needs into an
/// entitlements plist, in place.
public enum CFWMachLookupExceptions {
    /// The entitlement array this patcher merges into.
    public static let exceptionKey = "com.apple.security.exception.mach-lookup.global-name"

    /// The services Campo needs and iOS 27's temporary sandbox denies.
    /// Order is load-bearing only in that it is the order new entries are
    /// appended in — it has to match the Python for the comparison to hold.
    public static let services: [String] = [
        "com.apple.backboard.display.services",
        "com.apple.iohideventsystem",
        "com.apple.CARenderServer",
        "com.apple.backboard.hid.services",
        "com.apple.backboard.hid-services.xpc",
        "com.apple.backboard.TouchDeliveryPolicyServer",
        "com.apple.backboard.system-app-server",
        "com.apple.backboard.watchdog",
        "com.apple.backboard.oswatchdog",
        "com.apple.backboard.altsysapp",
        "com.apple.AttentionAwareness",
        "PurpleSystemEventPort",
        "PurpleWorkspacePort",
        "com.apple.frontboard.systemappservices",
        "com.apple.frontboard.workspace",
        "com.apple.frontboardservices.systemappmanager",
        "com.apple.frontboard.watchdog",
    ]

    /// What the merge did.
    public struct Outcome: Sendable, Equatable {
        /// Size of the exception array after the merge.
        public let total: Int
        /// How many entries this run appended.
        public let added: Int
    }

    // MARK: - Merging

    /// Merge ``services`` into the exception array at `url`, in place.
    ///
    /// The file is written back as an XML plist regardless of the input
    /// format, which is what `plistlib.dump()` defaults to and what `ldid`
    /// expects on the way back in.
    @discardableResult
    public static func merge(at url: URL, verbose: Bool = true) throws -> Outcome {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw PatcherError.fileNotFound(url.path)
        }

        guard let parsed = try? PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        ) else {
            throw PatcherError.invalidFormat("cannot parse as plist: \(url.path)")
        }
        guard var entitlements = parsed as? [String: Any] else {
            throw PatcherError.invalidFormat(
                "top-level plist is \(type(of: parsed)), expected dict: \(url.path)"
            )
        }

        let existing = try existingExceptions(entitlements[exceptionKey], path: url.path)
        let added = services.filter { !existing.contains($0) }
        let merged = existing + added
        entitlements[exceptionKey] = merged

        let output = try PropertyListSerialization.data(
            fromPropertyList: entitlements,
            format: .xml,
            options: 0
        )
        try output.write(to: url)

        if verbose {
            print("  [+] Campo mach-lookup exception count: \(merged.count) (+\(added.count) added)")
        }
        return Outcome(total: merged.count, added: added.count)
    }

    /// Read the existing exception array.
    ///
    /// A missing key means an empty array, matching the Python's
    /// `entitlements.get(KEY, [])`. A present-but-not-an-array value is an
    /// error here, where the Python would run `list()` over it — turning a
    /// string entitlement into one array entry per character and re-signing
    /// Campo with the result. Refusing is the only sane reading of a file
    /// that is about to be handed to `ldid`.
    private static func existingExceptions(_ value: Any?, path: String) throws -> [String] {
        guard let value else { return [] }
        guard let array = value as? [Any] else {
            throw PatcherError.invalidFormat(
                "'\(exceptionKey)' is \(type(of: value)), expected array: \(path)"
            )
        }
        return try array.map { element in
            guard let string = element as? String else {
                throw PatcherError.invalidFormat(
                    "'\(exceptionKey)' holds a non-string entry (\(type(of: element))): \(path)"
                )
            }
            return string
        }
    }
}

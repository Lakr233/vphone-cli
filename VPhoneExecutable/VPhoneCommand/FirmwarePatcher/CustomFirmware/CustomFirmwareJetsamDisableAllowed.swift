import CoreFoundation
import Foundation
import VPhonePatchKit

/// Let launchd's disabled overrides hold on iOS 27. Its jetsam properties mark
/// some daemons `DisableAllowed = false`, and launchd then loads them whatever
/// the override says (`force-enabled` in `launchctl print`). launchd reads the
/// file named after the device tree's `target-type`, so every guest that
/// presents its board gets it, and the trimmed service profile and the OTA
/// block cannot turn those daemons off. See Research/Guest/service_trimming.md.
public enum CustomFirmwareJetsamDisableAllowed {
    public static let directory = "System/Library/LaunchDaemons"
    public static let key = "DisableAllowed"

    /// `com.apple.jetsamproperties.<board>.plist`: one per board the image serves.
    public static func isJetsamProperties(_ name: String) -> Bool {
        name.hasPrefix("com.apple.jetsamproperties.") && name.hasSuffix(".plist")
    }

    /// Removes every `DisableAllowed = false`, at any depth, and returns how
    /// many. The installer owns the pristine backup and rollback. Everything
    /// else and the input plist's encoding are preserved; a file without the
    /// key is not written.
    @discardableResult
    public static func patch(at url: URL, dryRun: Bool = false) throws -> Int {
        let input = try Data(contentsOf: url)
        var format = PropertyListSerialization.PropertyListFormat.xml
        guard let root = try PropertyListSerialization.propertyList(
            from: input, options: [], format: &format,
        ) as? [String: Any] else {
            throw PatcherError.invalidFormat("Jetsam properties are not a dictionary: \(url.path)")
        }
        var removed = 0
        let stripped = strip(root, removed: &removed)
        guard removed > 0 else { return 0 }
        let output = try PropertyListSerialization.data(fromPropertyList: stripped, format: format, options: 0)
        if !dryRun {
            try output.write(to: url, options: .atomic)
        }
        return removed
    }

    private static func strip(_ value: Any, removed: inout Int) -> Any {
        if let dictionary = value as? [String: Any] {
            var result: [String: Any] = [:]
            for (name, child) in dictionary {
                if name == key, let number = child as? NSNumber,
                   CFGetTypeID(number) == CFBooleanGetTypeID(), !number.boolValue
                {
                    removed += 1
                    continue
                }
                result[name] = strip(child, removed: &removed)
            }
            return result
        }
        if let array = value as? [Any] {
            return array.map { strip($0, removed: &removed) }
        }
        return value
    }
}

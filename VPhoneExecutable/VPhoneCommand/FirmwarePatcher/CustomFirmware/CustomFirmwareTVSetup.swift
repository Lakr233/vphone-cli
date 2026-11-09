import CoreFoundation
import Foundation
import VPhonePatchKit

/// Select the native TVSetup app retained in tvOS 27.2. The new Setup Hello
/// scene does not respond to the virtual keyboard/consumer remote. This does
/// not mark setup complete or change any setup choices.
public enum CustomFirmwareTVSetup {
    public static let relativePath = "System/Library/FeatureFlags/Domain/CompanionServices.plist"
    public static let features = ["TVSetupV2", "TVSetupV2HW"]

    /// Preserve unrelated flags, per-feature metadata and the plist encoding.
    /// Require both known dictionaries before writing either change.
    @discardableResult
    public static func patch(at url: URL, dryRun: Bool = false) throws -> Bool {
        let input = try Data(contentsOf: url)
        var format = PropertyListSerialization.PropertyListFormat.xml
        guard var root = try PropertyListSerialization.propertyList(
            from: input, options: [], format: &format,
        ) as? [String: Any] else {
            throw PatcherError.invalidFormat("Not a feature flag dictionary: \(url.path)")
        }
        var changed = false
        for name in features {
            guard var feature = root[name] as? [String: Any] else {
                throw PatcherError.invalidFormat("Missing \(name) feature dictionary: \(url.path)")
            }
            if let enabled = feature["Enabled"] {
                guard let number = enabled as? NSNumber,
                      CFGetTypeID(number) == CFBooleanGetTypeID()
                else {
                    throw PatcherError.invalidFormat("\(name).Enabled is not a boolean: \(url.path)")
                }
                if !number.boolValue { continue }
            }
            feature["Enabled"] = false
            root[name] = feature
            changed = true
        }
        guard changed else { return false }
        let output = try PropertyListSerialization.data(fromPropertyList: root, format: format, options: 0)
        if !dryRun { try output.write(to: url, options: .atomic) }
        return true
    }
}

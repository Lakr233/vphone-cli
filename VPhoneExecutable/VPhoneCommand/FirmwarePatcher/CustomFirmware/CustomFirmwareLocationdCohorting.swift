import Foundation
import VPhonePatchKit

/// Keep iOS 27 location silos on their independent serial queues. Automatic
/// cohort queues trigger startup PAC failures and hangs on the tested research
/// guest. See Research/Guest/locationd_27_0_1_startup_race.md; the underlying
/// libdispatch/kernel cause is not established by this compatibility fix.
public enum CustomFirmwareLocationdCohorting {
    public static let relativePath = "System/Library/FeatureFlags/Domain/CoreLocation.plist"
    public static let feature = "CLAutoCohort"

    /// The installer owns the iOS version gate, pristine backup and rollback.
    /// Preserve every other feature and the input plist's encoding.
    @discardableResult
    public static func patch(at url: URL, dryRun: Bool = false) throws -> Bool {
        let input = try Data(contentsOf: url)
        var format = PropertyListSerialization.PropertyListFormat.xml
        guard var root = try PropertyListSerialization.propertyList(
            from: input, options: [], format: &format,
        ) as? [String: Any],
            var feature = root[Self.feature] as? [String: Any]
        else {
            throw PatcherError.invalidFormat("Missing CLAutoCohort feature dictionary: \(url.path)")
        }
        if let enabled = feature["Enabled"] {
            guard let number = enabled as? NSNumber,
                  CFGetTypeID(number) == CFBooleanGetTypeID()
            else {
                throw PatcherError.invalidFormat("CLAutoCohort.Enabled is not a boolean: \(url.path)")
            }
            if !number.boolValue, feature["DevelopmentPhase"] == nil {
                return false
            }
        }
        feature["Enabled"] = false
        feature.removeValue(forKey: "DevelopmentPhase")
        root[Self.feature] = feature
        let output = try PropertyListSerialization.data(fromPropertyList: root, format: format, options: 0)
        if !dryRun {
            try output.write(to: url, options: .atomic)
        }
        return true
    }
}

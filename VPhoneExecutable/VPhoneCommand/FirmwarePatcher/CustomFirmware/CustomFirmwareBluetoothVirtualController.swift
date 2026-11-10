import CoreFoundation
import Foundation
import VPhonePatchKit

/// Let bluetoothd connect over its virtual controller. On a VM (DT
/// `arm-io/bluetooth` `transport-encoding` 10, `kern.hv_vmm_present`)
/// bluetoothd drives a built-in virtual LE controller, BTVC, whose radio is
/// Bonjour `_btvc._tcp` on the VMs' shared network. The shipped feature flag
/// `EnableBTVCLeConnection` is off, which keeps it from connecting: a watch and
/// its phone pair over NetworkRelay, then talk over this link.
/// See Research/Guest/watch_pairing.md.
public enum CustomFirmwareBluetoothVirtualController {
    public static let relativePath = "System/Library/FeatureFlags/Domain/BluetoothFeatures.plist"
    public static let feature = "EnableBTVCLeConnection"

    /// Turn the feature on, keeping every other feature and the plist's
    /// encoding. Returns false when it already is on.
    @discardableResult
    public static func patch(at url: URL, dryRun: Bool = false) throws -> Bool {
        let input = try Data(contentsOf: url)
        var format = PropertyListSerialization.PropertyListFormat.xml
        guard var root = try PropertyListSerialization.propertyList(
            from: input, options: [], format: &format,
        ) as? [String: Any] else {
            throw PatcherError.invalidFormat("Not a feature flag dictionary: \(url.path)")
        }
        var feature = root[Self.feature] as? [String: Any] ?? [:]
        if let enabled = feature["Enabled"] as? NSNumber, CFGetTypeID(enabled) == CFBooleanGetTypeID(), enabled.boolValue {
            return false
        }
        feature["Enabled"] = true
        root[Self.feature] = feature
        let output = try PropertyListSerialization.data(fromPropertyList: root, format: format, options: 0)
        if !dryRun {
            try output.write(to: url, options: .atomic)
        }
        return true
    }
}

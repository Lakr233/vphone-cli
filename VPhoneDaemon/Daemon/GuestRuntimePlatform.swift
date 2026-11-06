import Foundation
import Darwin

/// visionOS runs the iOS agent through its iPad compatibility environment.
/// Compile-time os(iOS) alone must not select iPhone startup policy there.
enum GuestRuntimePlatform {
    static let isVisionOS: Bool = {
        let version = NSDictionary(contentsOfFile: "/System/Library/CoreServices/SystemVersion.plist")
        var size = 0
        var machine = ""
        if sysctlbyname("hw.machine", nil, &size, nil, 0) == 0, size > 0 {
            var bytes = [CChar](repeating: 0, count: size)
            if sysctlbyname("hw.machine", &bytes, &size, nil, 0) == 0 {
                machine = String(cString: bytes)
            }
        }
        return isVisionOS(productName: version?["ProductName"] as? String, machine: machine)
    }()

    static func isVisionOS(productName: String?, machine: String = "") -> Bool {
        productName == "xrOS" || productName == "visionOS" || machine.hasPrefix("RealityDevice")
    }

    static let visionOSCapabilities = [
        "hid", "apps", "url", "ipa_install", "bootstrap_install", "bootstrap_packages",
        "bootstrap_uninstall", "bootstrap_rootless_only", "files", "port_forward", "device_info", "processes", "services",
    ]
}

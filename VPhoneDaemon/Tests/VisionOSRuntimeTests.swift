import Foundation

@main
struct VisionOSRuntimeTests {
    static func main() {
        for name in ["xrOS", "visionOS"] {
            precondition(GuestRuntimePlatform.isVisionOS(productName: name))
        }
        precondition(GuestRuntimePlatform.isVisionOS(productName: "iPhone OS", machine: "RealityDevice14,1"))
        precondition(!GuestRuntimePlatform.isVisionOS(productName: "iPhone OS", machine: "iPad16,1"))
        for name: String? in [nil, "iPhone OS", "iOS", "tvOS", "darwinOS", "visionOS Simulator"] {
            precondition(!GuestRuntimePlatform.isVisionOS(productName: name))
        }
        let capabilities = Set(GuestRuntimePlatform.visionOSCapabilities)
        precondition(capabilities.isSuperset(of: ["apps", "url", "ipa_install", "bootstrap_install", "bootstrap_uninstall", "bootstrap_rootless_only"]))
        precondition(capabilities.isDisjoint(with: ["camera", "touch", "keychain", "location", "screen_unlock", "environment_update"]))
        print("visionOS runtime classification and capability policy passed")
    }
}

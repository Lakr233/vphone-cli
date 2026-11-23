@testable import FirmwarePatcher
import Testing
import VPhoneCoreKit
import VPhonePatchKit

/// The preset `vm create` and `vm template find` both take when none is named,
/// so they key the same template.
@Suite("Default patch preset")
struct DefaultPresetTests {
    @Test(
        "Each guest family takes its own default preset",
        arguments: [
            ("AppleTV5,3", VPhonePatchPreset.tvOSIdentifier),
            ("AppleTV14,1", VPhonePatchPreset.tvOS4KIdentifier),
            ("HomeAccessory17,1", VPhonePatchPreset.homeViewIdentifier),
            ("AudioAccessory5,1", VPhonePatchPreset.homePodMiniIdentifier),
            ("Watch7,18", VPhonePatchPreset.watchOSIdentifier),
            ("RealityDevice14,1", VPhonePatchPreset.visionOSIdentifier),
            ("iPhone11,6", VPhonePatchPreset.minimalIdentifier),
            ("iPhone17,3", VPhonePatchPreset.standardIdentifier),
        ],
    )
    func guestDefault(productType: String, expected: String) throws {
        let guest = try #require(VPhoneGuestDevice.named(productType))
        #expect(VPhoneGuestDevice.defaultPresetIdentifier(for: guest) == expected)
    }

    @Test("No guest takes standard")
    func noGuest() {
        #expect(VPhoneGuestDevice.defaultPresetIdentifier(for: nil) == VPhonePatchPreset.standardIdentifier)
    }
}

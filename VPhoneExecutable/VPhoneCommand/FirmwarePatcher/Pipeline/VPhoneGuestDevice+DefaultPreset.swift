// VPhoneGuestDevice+DefaultPreset.swift — The patch preset a guest takes when none is named.
//
// One choice for `vm create` and `vm template find`, so both key the same template.

import VPhoneCoreKit
import VPhonePatchKit

public extension VPhoneGuestDevice {
    /// An Apple TV takes the TV preset; one whose userland comes from an OTA
    /// takes the arm64e one, with the GPU driver and the userland swap. An
    /// Apple Watch takes the watch preset, an iPhone XS Max `minimal`, the preset
    /// checked on every iOS 18 release (`standard` is checked on 18.6).
    static func defaultPresetIdentifier(for guest: VPhoneGuestDevice?) -> String {
        switch guest {
        case let guest? where guest.family == .appleTV:
            guest.restoreBase == nil ? VPhonePatchPreset.tvOSIdentifier : VPhonePatchPreset.tvOS4KIdentifier
        case let guest? where guest.family == .homeView:
            VPhonePatchPreset.homeViewIdentifier
        case let guest? where guest.family == .homePod:
            VPhonePatchPreset.homePodMiniIdentifier
        case let guest? where guest.family == .watch:
            VPhonePatchPreset.watchOSIdentifier
        case let guest? where guest.family == .vision:
            VPhonePatchPreset.visionOSIdentifier
        case let guest? where guest.notchedArtworkSubtype != nil:
            VPhonePatchPreset.minimalIdentifier
        default:
            VPhonePatchPreset.standardIdentifier
        }
    }
}

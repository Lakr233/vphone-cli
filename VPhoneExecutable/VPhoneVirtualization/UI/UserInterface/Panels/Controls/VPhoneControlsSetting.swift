import Foundation

/// A guest value the Controls window writes, named as it reads mid-sentence.
enum VPhoneControlsSetting: Equatable {
    case brightness
    case orientation
    case rotationLock
    case volume
    case lowPowerMode

    var title: String {
        switch self {
        case .brightness: String(localized: "brightness", bundle: VPhoneLocalization.bundle)
        case .orientation: String(localized: "orientation", bundle: VPhoneLocalization.bundle)
        case .rotationLock: String(localized: "Rotation Lock", bundle: VPhoneLocalization.bundle)
        case .volume: String(localized: "volume", bundle: VPhoneLocalization.bundle)
        case .lowPowerMode: String(localized: "Low Power Mode", bundle: VPhoneLocalization.bundle)
        }
    }
}

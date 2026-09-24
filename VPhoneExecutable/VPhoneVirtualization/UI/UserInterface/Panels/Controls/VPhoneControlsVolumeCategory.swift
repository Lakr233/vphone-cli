import Foundation

/// AVSystemController volume categories `audio.volume` reads and sets.
enum VPhoneControlsVolumeCategory: String, CaseIterable, Identifiable {
    case media = "Audio/Video"
    case ringer = "Ringtone"

    var id: Self {
        self
    }

    var title: String {
        switch self {
        case .media: String(localized: "Media", bundle: VPhoneLocalization.bundle)
        case .ringer: String(localized: "Ringer", bundle: VPhoneLocalization.bundle)
        }
    }
}

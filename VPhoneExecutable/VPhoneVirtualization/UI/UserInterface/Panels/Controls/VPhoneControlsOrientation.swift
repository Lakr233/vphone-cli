import Foundation

/// The interface rotations `display.rotation` accepts, by icli's rotation spec.
enum VPhoneControlsOrientation: Int, CaseIterable, Identifiable {
    case portrait = 0
    case landscapeLeft = 90
    case landscapeRight = 270
    case upsideDown = 180

    var id: Self {
        self
    }

    init?(degrees: Int) {
        self.init(rawValue: degrees)
    }

    /// The `orientation` parameter `display.rotation` parses.
    var spec: String {
        switch self {
        case .portrait: "portrait"
        case .landscapeLeft: "landscape-left"
        case .landscapeRight: "landscape-right"
        case .upsideDown: "upside-down"
        }
    }

    var title: String {
        switch self {
        case .portrait: String(localized: "Portrait", bundle: VPhoneLocalization.bundle)
        case .landscapeLeft: String(localized: "Landscape Left", bundle: VPhoneLocalization.bundle)
        case .landscapeRight: String(localized: "Landscape Right", bundle: VPhoneLocalization.bundle)
        case .upsideDown: String(localized: "Upside Down", bundle: VPhoneLocalization.bundle)
        }
    }
}

import Foundation

enum VPhoneError: Error, CustomStringConvertible {
    case hardwareModelNotSupported
    case romNotFound(String)
    case diskNotFound(String)

    var description: String {
        switch self {
        case .hardwareModelNotSupported:
            """
            PV=3 hardware model not supported. Check:
              1. macOS >= 15.0 (Sequoia)
              2. Signed with com.apple.private.virtualization + \
            com.apple.private.virtualization.security-research
              3. SIP/AMFI disabled
            """
        case let .romNotFound(p):
            "ROM not found: \(p)"
        case let .diskNotFound(p):
            "Disk image not found: \(p)"
        }
    }
}

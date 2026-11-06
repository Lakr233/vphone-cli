import Foundation

enum HomePodDisplayMethod: String, GuestMethod {
    case homepodDisplayState = "homepod.display.state"

    var spec: MethodSpec {
        switch self {
        case .homepodDisplayState: MethodSpec()
        }
    }
}

extension GuestAPI {
    static func executeHomePodDisplay(_ m: HomePodDisplayMethod, _ params: [String: Any]) throws -> [String: Any] {
        switch m {
        case .homepodDisplayState:
            try GuestHomePodDisplay.state()
        }
    }
}

import Foundation

extension GuestAPI {
    static func executeHomePodDisplay(_ m: HomePodDisplayMethod, _ params: [String: Any]) throws -> [String: Any] {
        switch m {
        case .homepodDisplayState:
            try GuestHomePodDisplay.state()
        }
    }
}

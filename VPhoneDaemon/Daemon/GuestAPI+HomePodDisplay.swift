import Foundation

enum HomePodDisplayMethod: String, GuestMethod {
    case homepodDisplayState = "homepod.display.state"

    var spec: MethodSpec {
        switch self {
        case .homepodDisplayState: MethodSpec(result: [.required("available", .boolean),
                                                       .required("bit_depth", .any),
                                                       .required("configured", .any),
                                                       .required("display_count", .any),
                                                       .required("displays", .array),
                                                       .required("error", .any),
                                                       .optional("frame_timestamp", .any),
                                                       .required("frames_received", .any),
                                                       .required("generation", .any),
                                                       .required("geometry", .any),
                                                       .required("hardware_version", .any),
                                                       .required("last_report_id", .any),
                                                       .required("last_report_length", .any),
                                                       .required("minus", .any),
                                                       .required("pixels", .any),
                                                       .required("plus", .any),
                                                       .required("rejected_reports", .any),
                                                       .required("report_bit_depth", .integer),
                                                       .required("state", .any)])
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

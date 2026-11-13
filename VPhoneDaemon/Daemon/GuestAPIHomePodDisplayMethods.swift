import Foundation

enum HomePodDisplayMethod: String, GuestMethod {
    case homepodDisplayState = "homepod.display.state"

    var spec: MethodSpec {
        switch self {
        case .homepodDisplayState: MethodSpec(summary: "Read the HomePod display state: availability, geometry, pixel format and frame counters.", result: [.required("available", .boolean),
                                                       .required("bit_depth", .integer),
                                                       .required("configured", .boolean),
                                                       .required("display_count", .integer),
                                                       .required("displays", .array),
                                                       .required("message", .string).nullable(),
                                                       .required("error", .string).nullable(),
                                                       .optional("frame_timestamp", .integer),
                                                       .required("frames_received", .integer),
                                                       .required("generation", .integer),
                                                       .required("geometry", .object),
                                                       .required("hardware_version", .integer),
                                                       .required("last_report_id", .integer),
                                                       .required("last_report_length", .integer),
                                                       .required("minus", .number),
                                                       .required("pixels", .array),
                                                       .required("plus", .number),
                                                       .required("rejected_reports", .integer),
                                                       .required("report_bit_depth", .integer),
                                                       .required("state", .string)])
        }
    }
}

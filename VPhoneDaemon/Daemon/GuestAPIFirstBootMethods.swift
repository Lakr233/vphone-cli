import Foundation

enum FirstBootMethod: String, GuestMethod {
    case setupSettle = "setup.settle"

    var spec: MethodSpec {
        switch self {
        case .setupSettle:
            MethodSpec(.optional("timeout_s", .number, "Longest wait in seconds before returning settled false; clamped to the range", default: 90, min: 0, max: 110),
                       .optional("poll_s", .number, "Seconds between checks; clamped to the range", default: 5, min: 1, max: 30),
                       .optional("stable_polls", .number, "Consecutive unchanged checks required to count as settled; clamped to the range", default: 3, min: 2, max: 20), summary: "Wait until first-boot work (app staging, installd, data migration) settles or the timeout passes.", result: [.required("elapsed_s", .number),
                                .required("poll_s", .number),
                                .required("polls", .integer),
                                .required("reasons", .array),
                                .required("settled", .boolean),
                                .required("signals", .object),
                                .required("stable_polls", .integer),
                                .required("timeout_s", .number)])
        }
    }
}

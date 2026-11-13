import Foundation

enum FirstBootMethod: String, GuestMethod {
    case setupSettle = "setup.settle"

    var spec: MethodSpec {
        switch self {
        case .setupSettle:
            MethodSpec(.optional("timeout_ms", .number, "Longest wait in milliseconds before returning settled false; clamped to the range", default: 90000, min: 0, max: 110000),
                       .optional("poll_ms", .number, "Milliseconds between checks; clamped to the range", default: 5000, min: 1000, max: 30000),
                       .optional("stable_polls", .number, "Consecutive unchanged checks required to count as settled; clamped to the range", default: 3, min: 2, max: 20), summary: "Wait until first-boot work (app staging, installd, data migration) settles or the timeout passes.", result: [.required("elapsed_ms", .number),
                                .required("poll_ms", .number),
                                .required("polls", .integer),
                                .required("reasons", .array),
                                .required("settled", .boolean),
                                .required("signals", .object),
                                .required("stable_polls", .integer),
                                .required("timeout_ms", .number),
                                .required("elapsed_s", .number),
                                .required("poll_s", .number),
                                .required("timeout_s", .number)])
        }
    }
}

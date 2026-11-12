import Foundation

enum HomeViewDistanceMethod: String, GuestMethod {
    case homeviewDistanceGet = "homeview.distance.get"
    case homeviewDistanceSet = "homeview.distance.set"

    var spec: MethodSpec {
        switch self {
        case .homeviewDistanceGet: MethodSpec(summary: "Read the HomeView viewing-distance mode, level of detail and override state.", result: [.required("applied", .integer),
                                                       .required("available", .boolean),
                                                       .required("backlight_state", .integer).nullable(),
                                                       .required("display_style", .integer).nullable(),
                                                       .required("level_of_detail", .integer),
                                                       .required("mode", .string),
                                                       .required("override_active", .integer).nullable(),
                                                       .required("reset_scope", .string)])
        case .homeviewDistanceSet: MethodSpec(.required("mode", .string, "Viewing distance mode", values: ["automatic", "near", "standard", "far"]), .optional("reset_environment", .boolean, "Allow clearing persona, display style, detail and backlight overrides; required true for automatic", default: false), summary: "Set the HomeView viewing-distance mode, or return to automatic with reset_environment.", result: [.required("applied", .integer),
                                                       .required("available", .boolean),
                                                       .required("backlight_state", .integer).nullable(),
                                                       .required("display_style", .integer).nullable(),
                                                       .required("level_of_detail", .integer),
                                                       .required("mode", .string),
                                                       .required("override_active", .integer).nullable(),
                                                       .required("reset_scope", .string)])
        }
    }
}
